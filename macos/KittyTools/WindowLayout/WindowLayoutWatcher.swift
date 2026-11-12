// 窗口拖拽和鼠标侧键的被动监听，吸附预览点得穿且永不获取键盘焦点。

import AppKit
import OSLog
import SwiftUI

/// 只在拖拽期间读取窗口状态，不拦截、吞掉或合成鼠标键盘事件。
@MainActor final class WindowLayoutWatcher {
  private weak var layout: WindowLayout?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var down: CGPoint?
  private var target: DockWindows.LayoutWindow?
  private var moved = false
  private var candidate: (action: WindowLayoutAction, screen: Int)?
  private var preview: NSPanel?
  private var observations: [pid_t: DockWindows.LayoutObservation] = [:]
  private var activated: NSObjectProtocol?
  private var lifecycle: [NSObjectProtocol] = []
  private var changed: NSObjectProtocol?
  private var attempted = false
  private var triedUnsnap = false
  private var observedAction: WindowLayoutAction?
  private var doubleClickTask: Task<Void, Never>?

  /// 执行层弱引用避免监听闭包形成持有环。
  init(layout: WindowLayout) { self.layout = layout }

  isolated deinit { stop() }

  /// 同时观察外部 App 和本进程，所有回调都返回原事件。
  func start() {
    guard globalMonitor == nil else { return }
    let mask: NSEvent.EventTypeMask = [
      .leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown,
    ]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      self?.event(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      self?.event(event)
      return event
    }
    activated = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.observeNewWindows() } }
    for name in [
      NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ] {
      lifecycle.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        {
          [weak self] _ in MainActor.assumeIsolated { self?.observeNewWindows() }
        })
    }
    changed = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: UserDefaults.standard, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.observeNewWindows() }
    }
    observeNewWindows()
  }

  /// 停用时释放事件监听、窗口观察者和透明预览。
  func stop() {
    doubleClickTask?.cancel()
    doubleClickTask = nil
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let activated { NSWorkspace.shared.notificationCenter.removeObserver(activated) }
    if let changed { NotificationCenter.default.removeObserver(changed) }
    for observer in lifecycle { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    lifecycle.removeAll()
    globalMonitor = nil
    localMonitor = nil
    activated = nil
    changed = nil
    for observation in observations.values { observation.stop() }
    observations.removeAll()
    observedAction = nil
    reset()
    preview?.close()
    preview = nil
  }

  /// 鼠标按下只记坐标，拖动后才读取 AX，普通点击不遍历窗口。
  private func event(_ event: NSEvent) {
    guard let layout, !layout.isSuppressed(), Feature.windowLayout.isOn else {
      reset()
      return
    }
    if event.type == .otherMouseDown {
      mouseButton(event)
      return
    }
    if event.type == .leftMouseDown {
      reset()
      down = Self.pointer
      return
    }
    if event.type == .leftMouseUp {
      if moved, let target, let candidate {
        layout.run(candidate.action, target: target, screen: candidate.screen)
      }
      if !moved, event.clickCount == 2 { doubleClick(at: Self.pointer) }
      reset()
      return
    }
    guard event.type == .leftMouseDragged, let down,
      UserDefaults.standard.object(forKey: Prefs.layoutSnapping) as? Bool ?? true,
      Permissions.isAccessibilityTrusted
    else { return }
    let pointer = Self.pointer
    if target == nil, !attempted, hypot(pointer.x - down.x, pointer.y - down.y) > 4 {
      attempted = true
      do { target = try window(at: pointer) } catch {
        Log.windows.notice(
          "layout drag target failed error=\(String(describing: error), privacy: .public)")
      }
    }
    guard let target else { return }
    do {
      let current = try DockWindows.layoutFrame(target.element)
      let delta = hypot(current.minX - target.frame.minX, current.minY - target.frame.minY)
      if delta > 4, abs(current.width - target.frame.width) <= 1,
        abs(current.height - target.frame.height) <= 1
      {
        moved = true
      }
      if moved, !triedUnsnap {
        triedUnsnap = true
        if UserDefaults.standard.object(forKey: Prefs.layoutUnsnap) as? Bool ?? true,
          let restored = try layout.unsnap(target, pointer: pointer)
        {
          self.target = restored
        }
      }
      guard moved, requiredModifier(event.modifierFlags) else {
        candidate = nil
        preview?.orderOut(nil)
        return
      }
      let screens = WindowLayout.screens
      let frames = WindowLayout.screenFrames
      guard let index = frames.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(pointer) }),
        screens.indices.contains(index),
        let area = WindowLayoutSnap.area(at: pointer, in: frames[index], margin: 10)
      else {
        candidate = nil
        preview?.orderOut(nil)
        return
      }
      let stored = UserDefaults.standard.string(forKey: Prefs.layoutSnapAreas) ?? ""
      guard WindowLayoutSnap.valid(stored) else {
        throw NSError(
          domain: "KittyTools.WindowLayout", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "屏幕边缘动作设置无法识别，请在窗口管理设置中重新选择布局"])
      }
      guard let action = WindowLayoutSnap.actions(stored)[area.rawValue],
        let frame = WindowLayoutGeometry.frame(
          for: action, current: current,
          in: screens[index], options: .read())
      else {
        candidate = nil
        preview?.orderOut(nil)
        return
      }
      candidate = (action, index)
      showPreview(frame)
    } catch {
      Log.windows.error(
        "layout drag read failed pid=\(target.pid) id=\(target.id) error=\(String(describing: error), privacy: .public)"
      )
      layout.onProblem("拖拽窗口操作未完成。\(error.localizedDescription)")
      reset()
    }
  }

  /// 标题栏双击动作在原事件处理后执行，系统原本的双击设置仍会响应。
  private func doubleClick(at point: CGPoint) {
    guard let raw = UserDefaults.standard.string(forKey: Prefs.layoutDoubleClick),
      let action = WindowLayoutAction(rawValue: raw), WindowLayoutSnap.canSnap(action),
      let app = NSWorkspace.shared.frontmostApplication, app != .current,
      layout?.isIgnored(app) == false
    else { return }
    do {
      guard let target = try DockWindows.layoutTitleBar(at: point, app: app) else { return }
      doubleClickTask?.cancel()
      doubleClickTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        guard let self, Feature.windowLayout.isOn else { return }
        layout?.run(action, target: target)
      }
    } catch {
      Log.windows.error(
        "layout title bar failed pid=\(app.processIdentifier) error=\(String(describing: error), privacy: .public)"
      )
      layout?.onProblem("标题栏窗口操作未完成。\(error.localizedDescription)")
    }
  }

  /// 侧键作用于指针下的窗口，配置不匹配时保持系统原有行为。
  private func mouseButton(_ event: NSEvent) {
    let text = UserDefaults.standard.string(forKey: Prefs.layoutMouseBindings) ?? "[]"
    guard let bindings = WindowLayoutMouseBinding.decode(text) else {
      Log.windows.error("layout mouse configuration invalid bytes=\(text.utf8.count)")
      layout?.onProblem("鼠标按钮设置无法读取，请在窗口管理设置中重新选择动作")
      return
    }
    guard
      let binding = bindings.first(where: {
        $0.button == event.buttonNumber
      })
    else { return }
    do {
      guard let target = try window(at: Self.pointer) else {
        layout?.onProblem("指针下没有可调整的窗口")
        return
      }
      layout?.run(binding.action, target: target)
    } catch {
      Log.windows.error(
        "layout mouse failed button=\(event.buttonNumber) error=\(String(describing: error), privacy: .public)"
      )
      layout?.onProblem("鼠标窗口操作未完成。\(error.localizedDescription)")
    }
  }

  /// 使用一次屏幕窗口快照定位所属进程，再只问该 App 的辅助功能。
  private func window(at point: CGPoint) throws -> DockWindows.LayoutWindow? {
    let entries =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    for entry in entries {
      guard entry[kCGWindowLayer as String] as? Int == 0,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
        let app = NSRunningApplication(processIdentifier: pid)
      else { continue }
      guard app != .current, layout?.isIgnored(app) == false else { return nil }
      return try DockWindows.layoutAt(point, app: app)
    }
    return nil
  }

  /// 拖拽修饰键仅用于启用吸附，不截走前台 App 的按键。
  private func requiredModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
    switch UserDefaults.standard.string(forKey: Prefs.layoutSnapModifier) {
    case "option": flags.contains(.option)
    case "control": flags.contains(.control)
    case "shift": flags.contains(.shift)
    case "command": flags.contains(.command)
    default: true
    }
  }

  /// 半透明区域预览不当 key、点得穿，位置随拖拽即时更新。
  private func showPreview(_ frame: CGRect) {
    if preview == nil {
      let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.isReleasedWhenClosed = false
      panel.ignoresMouseEvents = true
      panel.becomesKeyOnlyIfNeeded = true
      panel.level = .statusBar
      panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
      panel.setAccessibilityElement(false)
      let view = NSView()
      view.wantsLayer = true
      panel.contentView = view
      preview = panel
    }
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    preview?.setFrame(
      CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height),
      display: true)
    preview?.contentView?.layer?.backgroundColor =
      NSColor(Style.brand).withAlphaComponent(
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.4 : 0.15
      ).cgColor
    preview?.contentView?.layer?.borderColor = NSColor(Style.brand).cgColor
    preview?.contentView?.layer?.borderWidth = 2
    preview?.contentView?.layer?.cornerRadius = Style.Radius.panel
    preview?.orderFrontRegardless()
  }

  /// 自动布局仅在明确开启后观察普通 App，新启动的应用通过工作区事件增量加入。
  private func observeNewWindows() {
    guard Permissions.isAccessibilityTrusted,
      let raw = UserDefaults.standard.string(forKey: Prefs.layoutNewWindowAction),
      let action = WindowLayoutAction(rawValue: raw), WindowLayoutSnap.canSnap(action)
    else {
      for observation in observations.values { observation.stop() }
      observations.removeAll()
      observedAction = nil
      return
    }
    if observedAction != action {
      for observation in observations.values { observation.stop() }
      observations.removeAll()
      observedAction = action
    }
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0 != .current && layout?.isIgnored($0) == false
    }
    let pids = Set(apps.map(\.processIdentifier))
    for pid in observations.keys.filter({ !pids.contains($0) }) {
      observations.removeValue(forKey: pid)?.stop()
    }
    for app in apps.prefix(128) where observations[app.processIdentifier] == nil {
      do {
        observations[app.processIdentifier] = try DockWindows.LayoutObservation(app: app) {
          [weak self] target in
          guard UserDefaults.standard.string(forKey: Prefs.layoutNewWindowAction) == action.rawValue
          else { return }
          self?.layout?.run(action, target: target, automatic: true)
        }
      } catch {
        Log.windows.error(
          "layout observe new windows failed pid=\(app.processIdentifier) error=\(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  /// 松手、停用或失败都即时收起预览并释放本次窗口对象。
  private func reset() {
    preview?.orderOut(nil)
    down = nil
    target = nil
    moved = false
    candidate = nil
    attempted = false
    triedUnsnap = false
  }

  /// 当前指针转换成辅助功能的主屏左上坐标。
  private static var pointer: CGPoint {
    CGPoint(
      x: NSEvent.mouseLocation.x,
      y: (NSScreen.screens.first?.frame.maxY ?? 0) - NSEvent.mouseLocation.y)
  }
}
