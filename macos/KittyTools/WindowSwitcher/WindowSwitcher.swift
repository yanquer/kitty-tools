// 独立窗口切换入口，负责按住修饰键的会话、窗口管理及按需缩略图。
// 使用现有 OverlayPanel，不激活本 App，不安装系统事件拦截。

import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI

/// 协调窗口切换会话，沿用项目统一浮层和系统热键入口。
@MainActor final class WindowSwitcher {
  let model = WindowSwitcherModel()
  let catalog = WindowSwitcherCatalog()
  var isSuppressed: () -> Bool = { false }
  var onHide: () -> Void = {}
  var onProblem: (String) -> Void = { _ in }
  private var panel: OverlayPanel?
  private let shots = WindowShots()
  private var loadTask: Task<Void, Never>?
  private var captureTask: Task<Void, Never>?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private var releaseTimer: Timer?
  private var held: NSEvent.ModifierFlags = []
  private var pendingConfirm = false
  private var initialSteps = 0
  private var scopePID: pid_t?
  private var session = UUID()
  var isOpen: Bool { panel?.isVisible == true }

  /// 配置展示回调，闭包弱引用执行层，面板关闭后不形成持有环。
  init() {
    model.onConfirm = { [weak self] in self?.confirm() }
    model.onClose = { [weak self] in self?.manage(closing: true) }
    model.onMinimize = { [weak self] in self?.manage(closing: false) }
    model.onSearch = { [weak self] in self?.beginSearch() }
    model.onSelectionChange = { [weak self] in self?.capture() }
    model.onRetry = { [weak self] in self?.reload() }
  }

  isolated deinit { stop() }

  /// 功能启用时只启动焦点观察，不建面板或截取缩略图。
  func start() { catalog.start() }

  /// 关闭功能，停止会话并释放跨进程对象及缓存。
  func stop() {
    hide()
    catalog.stop()
    reclaim()
  }

  /// 空闲时释放已经收起的面板和有界缩略图缓存。
  func reclaim() {
    guard !isOpen else { return }
    let old = panel
    panel = nil
    old?.contentView = nil
    shots.clear()
    catalog.releaseSnapshots()
  }

  /// 从快捷键或菜单开始切换，同一会话再次触发时只移动选中项。
  func show(_ action: HotKeyAction, byKey: Bool) {
    guard !isSuppressed() else {
      Log.windows.notice("switcher skipped: conflicting capture or full-screen session")
      return
    }
    guard Permissions.isAccessibilityTrusted else {
      onProblem("需要辅助功能授权才能读取和切换窗口")
      Permissions.grant(.accessibility)
      return
    }
    let appOnly = action == .appWindowSwitch || action == .appWindowSwitchPrevious
    let backwards = action == .windowSwitchPrevious || action == .appWindowSwitchPrevious
    let pid = appOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
    let delta = backwards ? -1 : 1
    if isOpen, scopePID == pid {
      if model.loading {
        initialSteps += delta
      } else {
        model.move(delta)
      }
      return
    }
    hide()
    scopePID = pid
    catalog.attachRunning()
    catalog.recordCurrentFocus()
    model.query = ""
    model.searching = false
    model.issue = nil
    model.windows = []
    model.selectedID = nil
    model.loading = true
    initialSteps = byKey ? delta : 0
    held =
      byKey ? (action.hotKey?.modifierFlags ?? []).intersection([.command, .option, .control]) : []
    model.screenRecording = Permissions.isScreenRecordingAllowed
    let screen =
      NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1000, height: 700)
    let size = CGSize(width: min(940, visible.width - 40), height: min(570, visible.height - 40))
    if panel == nil { buildPanel(size: size) }
    model.columns = max(1, Int((size.width - 24 + 8) / (190 + 8)))
    panel?.setContentSize(size)
    panel?.present()
    installMonitors()
    reload()
  }

  /// 建立遵循统一材质、点外关闭及键盘归还规则的浮层。
  private func buildPanel(size: CGSize) {
    let created = OverlayPanel(
      size: size, autoHide: .clickOutside, isPinned: { false },
      content: WindowSwitcherView(model: model))
    created.isMovableByWindowBackground = false
    created.onHide = { [weak self] in
      self?.ended()
      self?.onHide()
    }
    created.keyEquivalentHandler = { [weak self] event in self?.shortcut(event) ?? false }
    panel = created
  }

  /// 先展示加载状态，再逐应用读取；每个应用之间让出主运行循环。
  private func reload() {
    guard isOpen else { return }
    loadTask?.cancel()
    captureTask?.cancel()
    let token = UUID()
    session = token
    model.loading = true
    model.issue = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      let began = CACurrentMediaTime()
      Log.windows.info("switcher list started session=\(token.uuidString, privacy: .public)")
      guard
        let info = CGWindowListCopyWindowInfo(
          [.optionAll, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]]
      else {
        model.loading = false
        model.issue = "读取系统窗口列表失败，可重试"
        Log.windows.error("switcher list failed: CGWindowListCopyWindowInfo returned nil")
        return
      }
      var items: [SwitchWindow] = []
      var failures = 0
      let apps = catalog.applications().filter {
        scopePID == nil || $0.processIdentifier == scopePID
      }
      for app in apps {
        guard !Task.isCancelled, session == token, isOpen else { return }
        items += catalog.read(app, info: info)
        if catalog.readers[app.processIdentifier]?.lastError != nil { failures += 1 }
        model.icons[app.processIdentifier] = app.icon
        await Task.yield()
      }
      guard !Task.isCancelled, session == token, isOpen else { return }
      let sorted = catalog.ordered(items, info: info, complete: scopePID == nil && failures == 0)
      model.windows = Array(sorted.prefix(512))
      model.manageable = Set(
        model.windows.filter { catalog.readers[$0.pid]?.canManage($0.window) == true }.map(\.id))
      model.closable = Set(
        model.windows.filter { catalog.readers[$0.pid]?.canClose($0.window) == true }.map(\.id))
      model.selectedID = model.selectedID ?? catalog.focusedID
      if initialSteps == 0 { model.reconcileSelection() } else { model.move(initialSteps) }
      initialSteps = 0
      var issues: [String] = []
      if failures > 0 { issues.append("\(failures) 个 App 的窗口读取失败，列表可能不完整") }
      if !catalog.trackingFailures.isEmpty { issues.append("部分 App 无法跟踪窗口焦点，使用系统窗口顺序") }
      if sorted.count > 512 { issues.append("当前只显示最近的 512 扇窗口") }
      if !WindowServer.missing.isEmpty {
        issues += WindowServer.consequences(of: WindowServer.missing)
      }
      model.issue = issues.isEmpty ? nil : issues.joined(separator: "。")
      model.loading = false
      Log.windows.info(
        "switcher list finished count=\(items.count) failedApps=\(failures) elapsed=\(CACurrentMediaTime() - began)"
      )
      if pendingConfirm { confirm() } else { capture() }
    }
  }

  /// 用户进入搜索后会话保持打开，允许松开修饰键并使用中文输入法。
  private func beginSearch() {
    held = []
    pendingConfirm = false
    model.searching = true
    model.focusRequest += 1
  }

  /// ⌘F 搜索、⌘W 关闭目标、⌘M 最小化目标，其余编辑快捷键沿用输入框行为。
  private func shortcut(_ event: NSEvent) -> Bool {
    guard WindowSwitcherModel.acceptsCommand(event.modifierFlags, held: held) else {
      return false
    }
    switch Int(event.keyCode) {
    case kVK_ANSI_F: beginSearch()
    case kVK_ANSI_W: manage(closing: true)
    case kVK_ANSI_M: manage(closing: false)
    default: return false
    }
    return true
  }

  /// 仅在会话打开时监听修饰键释放和本面板按键，保留输入法的组字优先权。
  private func installMonitors() {
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handleLocal(event) ?? false }
      return handled ? nil : event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkRelease() }
    }
    let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.isSuppressed() { self.hide() } else { self.checkRelease() }
        if self.model.screenRecording, !Permissions.isScreenRecordingAllowed {
          self.model.screenRecording = false
          self.model.images = [:]
          self.captureTask?.cancel()
          self.shots.clear()
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    releaseTimer = timer
  }

  /// 处理本面板的导航键，只返回是否消费，避免跨隔离边界返回非 Sendable 的 NSEvent。
  private func handleLocal(_ event: NSEvent) -> Bool {
    guard isOpen else { return false }
    if event.type == .flagsChanged {
      checkRelease()
      return false
    }
    guard event.window === panel else { return false }
    if shortcut(event) { return true }
    if model.searching { return false }
    switch Int(event.keyCode) {
    case kVK_Escape: hide()
    case kVK_Return, kVK_ANSI_KeypadEnter: confirm()
    case kVK_LeftArrow: model.move(-1)
    case kVK_RightArrow: model.move(1)
    case kVK_UpArrow: model.move(-model.columns)
    case kVK_DownArrow: model.move(model.columns)
    case kVK_Tab:
      model.move(event.modifierFlags.contains(.shift) ? -1 : 1)
    default: return false
    }
    return true
  }

  /// 释放用于呼出的修饰键即确认；Carbon 派发较晚时由当前硬件状态兜底。
  private func checkRelease() {
    guard !held.isEmpty, !NSEvent.modifierFlags.isSuperset(of: held) else { return }
    held = []
    confirm()
  }

  /// 确认当前目标，先归还键盘，再把窗口激活请求交给系统。
  private func confirm() {
    if model.loading {
      pendingConfirm = true
      return
    }
    guard let selected = model.selected else { return }
    guard let app = NSRunningApplication(processIdentifier: selected.pid), !app.isTerminated else {
      model.issue = "目标 App 已退出，请刷新窗口列表"
      return
    }
    guard let reader = catalog.readers[selected.pid] else {
      model.issue = "窗口信息已失效，请刷新窗口列表"
      return
    }
    hide()
    DispatchQueue.main.async { [weak self] in
      Log.windows.info("focus requested pid=\(selected.pid) window=\(selected.id)")
      if !reader.focus(selected.window, of: app) {
        self?.onProblem(reader.lastError?.localizedDescription ?? "目标窗口切换结果未确认")
      } else {
        Log.windows.info("focus submitted pid=\(selected.pid) window=\(selected.id)")
      }
    }
  }

  /// 管理窗口时先显示目标，保存确认由所属应用处理；操作失败保留原始原因。
  private func manage(closing: Bool) {
    guard !model.loading, let selected = model.selected else { return }
    guard let app = NSRunningApplication(processIdentifier: selected.pid), !app.isTerminated else {
      model.issue = "目标 App 已退出，请刷新窗口列表"
      return
    }
    guard let reader = catalog.readers[selected.pid] else {
      model.issue = "窗口信息已失效，请刷新窗口列表"
      return
    }
    guard closing ? reader.canClose(selected.window) : reader.canManage(selected.window) else {
      model.issue = "当前无法取得这扇窗口的管理接口，可先切换到窗口再操作"
      return
    }
    hide()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if closing, !reader.focus(selected.window, of: app) {
        onProblem(reader.lastError?.localizedDescription ?? "目标窗口切换结果未确认")
        return
      }
      Log.windows.info(
        "window action requested pid=\(selected.pid) window=\(selected.id) close=\(closing)")
      let accepted =
        closing
        ? reader.close(selected.window)
        : reader.setMinimized(selected.window.state != .minimized, window: selected.window)
      if accepted {
        Log.windows.info("window action submitted window=\(selected.id) close=\(closing)")
      } else {
        onProblem(reader.lastError?.localizedDescription ?? "窗口操作失败")
      }
    }
  }

  /// 只为选中项附近最多 20 扇窗口串行截图，搜索与快速切换会取消过时任务。
  private func capture() {
    captureTask?.cancel()
    guard isOpen, !model.loading, model.screenRecording else {
      model.images = [:]
      return
    }
    let results = model.results
    let index = results.firstIndex { $0.id == model.selectedID } ?? 0
    let start = max(0, min(index - 8, results.count - 20))
    let targets = Array(results.dropFirst(start).prefix(WindowShots.capacity))
    let ids = Set(targets.map(\.id))
    model.images = model.images.filter { ids.contains($0.key) }
    captureTask = Task { [weak self] in
      guard let self else { return }
      for item in targets {
        guard !Task.isCancelled, isOpen, Permissions.isScreenRecordingAllowed else { return }
        if let image = await shots.shoot(item.window, maxPixels: CGSize(width: 440, height: 260)) {
          guard !Task.isCancelled, isOpen else { return }
          model.images[item.id] = image
        }
      }
    }
  }

  /// 收起面板时立即归还键盘，不让后续窗口操作落进自己的面板。
  func hide() {
    panel?.hide()
    ended()
  }

  /// 结束时取消后台任务、卸载监听、清除当前窗口内容和像素引用。
  private func ended() {
    session = UUID()
    loadTask?.cancel()
    loadTask = nil
    captureTask?.cancel()
    captureTask = nil
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    localMonitor = nil
    globalMonitor = nil
    releaseTimer?.invalidate()
    releaseTimer = nil
    held = []
    pendingConfirm = false
    model.windows = []
    model.images = [:]
    model.icons = [:]
  }
}
