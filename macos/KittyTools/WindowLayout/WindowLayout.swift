// 窗口管理执行层，串行安排 AX 写入、结果回读、失败回退与有界还原记录。

import AppKit
import ApplicationServices
import OSLog

/// 布局动作只移动目标窗口，普通布局不激活或抬起应用。
@MainActor final class WindowLayout {
  var onProblem: (String) -> Void = { _ in }
  var onInfo: (String) -> Void = { _ in }
  var isSuppressed: () -> Bool = { false }
  private var task: Task<Void, Never>?
  private var pending: [(WindowLayoutAction, DockWindows.LayoutWindow)] = []
  private var activeWindow: CGWindowID?
  private var history: [CGWindowID: Record] = [:]
  private var order: [CGWindowID] = []
  private var sidebar: (id: CGWindowID, screen: CGRect, left: Bool)?
  private var stackOrder: [CGWindowID] = []
  private var picker: WindowLayoutPicker?
  private(set) var watcher: WindowLayoutWatcher?

  /// 保存窗口的稳定对象和第一份布局前位置，最多保留 128 扇。
  private struct Record {
    let window: DockWindows.LayoutWindow
    var last: CGRect
    var action: WindowLayoutAction
    var repeats = 0
  }

  /// 显示器按物理位置从上到下、同排从左到右编号。
  static var orderedScreens: [NSScreen] {
    let screens = NSScreen.screens
    let top = screens.first?.frame.maxY ?? 0
    let frames = screens.map {
      CGRect(
        x: $0.frame.minX, y: top - $0.frame.maxY,
        width: $0.frame.width, height: $0.frame.height)
    }
    return WindowLayoutGeometry.screenOrder(frames).map { screens[$0] }
  }

  /// 可见显示器的辅助功能坐标，指定编号与跨屏移动共用物理顺序。
  static var screens: [CGRect] {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return orderedScreens.map {
      CGRect(
        x: $0.visibleFrame.minX, y: top - $0.visibleFrame.maxY,
        width: $0.visibleFrame.width, height: $0.visibleFrame.height)
    }
  }

  /// 边缘命中使用屏幕完整区域，菜单栏和程序坞占用只影响最终布局区域。
  static var screenFrames: [CGRect] {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return orderedScreens.map {
      CGRect(
        x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
    }
  }

  isolated deinit { stop() }

  /// 功能启用后监听拖拽和侧键，不建立计时轮询或截屏缓存。
  func start() {
    guard watcher == nil else { return }
    let created = WindowLayoutWatcher(layout: self)
    created.start()
    watcher = created
  }

  /// 停止接受操作并清理监听和界面，在途单窗口写入仍走回读和回退收尾。
  func stop() {
    pending.removeAll()
    watcher?.stop()
    watcher = nil
    picker?.hide()
    picker = nil
    sidebar = nil
    if task == nil {
      history.removeAll()
      order.removeAll()
      stackOrder.removeAll()
    }
  }

  /// 弹出动作选择面板前捕获前台窗口，面板内部执行沿用这份目标。
  func showPicker() {
    do {
      let target = try focused()
      if picker == nil { picker = WindowLayoutPicker() }
      let appName = NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "目标 App"
      let title = try DockWindows.layoutTitle(target)
      let targetName =
        title.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }.map { appName + " · " + $0 }
        ?? appName
      let screens = Self.screens
      let screen = WindowLayoutGeometry.screenIndex(for: target.frame, screens: screens)
      let portrait =
        WindowLayoutOptions.read().portrait
        && screen.map { screens[$0].height > screens[$0].width } == true
      picker?.show(targetName: targetName, portrait: portrait) { [weak self] action in
        self?.run(action, target: target)
      }
    } catch { report(error, action: "打开窗口管理") }
  }

  /// 打开其他工具或设置时收起动作选择器。
  func hide() { picker?.hide() }

  /// 读取当前前台应用的窗口，排除本进程、停用名单和系统全屏窗口。
  func focused() throws -> DockWindows.LayoutWindow {
    guard Permissions.isAccessibilityTrusted else { throw failure("需要辅助功能授权才能移动和调整窗口") }
    guard let app = NSWorkspace.shared.frontmostApplication, app != .current else {
      throw failure("先选中要调整的 App 窗口")
    }
    guard !isIgnored(app) else { throw failure("已在窗口管理中停用 \(app.localizedName ?? "这个 App")") }
    return try DockWindows.layoutFocused(app)
  }

  /// 快捷键、菜单、启动器和拖拽共用同一串行执行入口。
  func run(
    _ action: WindowLayoutAction, target: DockWindows.LayoutWindow? = nil, screen: Int? = nil,
    automatic: Bool = false, cycle: [WindowLayoutAction] = []
  ) {
    guard Feature.windowLayout.isOn, !isSuppressed() else {
      Log.windows.notice(
        "layout skipped action=\(action.rawValue, privacy: .public) reason=disabled-or-suppressed")
      return
    }
    if task != nil {
      if automatic, let target {
        guard target.id != activeWindow, !pending.contains(where: { $0.1.id == target.id }) else {
          return
        }
        guard pending.count < 32 else {
          Log.windows.error("layout automatic queue full pid=\(target.pid) id=\(target.id)")
          onProblem("自动布局队列已满，这个新窗口尚未调整")
          return
        }
        pending.append((action, target))
      } else {
        onProblem("窗口操作正在进行，请稍后再试")
      }
      return
    }
    do {
      let window = try target ?? focused()
      guard let app = NSRunningApplication(processIdentifier: window.pid) else {
        throw failure("目标 App 已退出")
      }
      guard !isIgnored(app) else { throw failure("已在窗口管理中停用 \(app.localizedName ?? "目标 App")") }
      let action = cycle.isEmpty ? action : try cycled(action, window: window, group: cycle)
      activeWindow = window.id
      task = Task { [weak self] in
        guard let self else { return }
        defer {
          task = nil
          activeWindow = nil
          if !Feature.windowLayout.isOn {
            history.removeAll()
            order.removeAll()
          }
          runPending()
        }
        let began = CACurrentMediaTime()
        Log.windows.notice(
          "layout start action=\(action.rawValue, privacy: .public) pid=\(window.pid) id=\(window.id)"
        )
        do {
          if WindowLayoutAction.multiple.contains(action) {
            try await multiple(action, focused: window)
          } else {
            try await single(action, window: window, screen: screen)
          }
          Log.windows.notice(
            "layout finished action=\(action.rawValue, privacy: .public) elapsed=\(CACurrentMediaTime() - began)"
          )
        } catch { report(error, action: action.title, window: window) }
      }
    } catch { report(error, action: action.title) }
  }

  /// 多个布局使用同一快捷键时，窗口仍在上次位置才继续循环，手动移动后从第一项开始。
  private func cycled(
    _ action: WindowLayoutAction, window: DockWindows.LayoutWindow,
    group: [WindowLayoutAction]
  ) throws -> WindowLayoutAction {
    guard group.count > 1, let prior = record(for: window),
      let index = group.firstIndex(of: prior.action),
      Self.matches(try DockWindows.layoutFrame(window.element), prior.last)
    else { return group.first ?? action }
    return group[(index + 1) % group.count]
  }

  /// 自动布局按创建顺序串行执行，配置变化或功能停用后丢弃尚未执行的旧动作。
  private func runPending() {
    guard Feature.windowLayout.isOn else {
      pending.removeAll()
      return
    }
    while !pending.isEmpty {
      let (action, target) = pending.removeFirst()
      guard UserDefaults.standard.string(forKey: Prefs.layoutNewWindowAction) == action.rawValue
      else { continue }
      run(action, target: target, automatic: true)
      return
    }
  }

  /// 当前 App 的停用规则同时用于鼠标与键盘入口。
  func isIgnored(_ app: NSRunningApplication) -> Bool {
    let entries = UserDefaults.standard.stringArray(forKey: Prefs.layoutIgnoredApps) ?? []
    return app.bundleIdentifier.map(entries.contains) ?? false
  }

  /// 拖离已布局窗口时按指针所在比例还原尺寸，回读成功才清除布局记录。
  func unsnap(_ window: DockWindows.LayoutWindow, pointer: CGPoint) throws -> DockWindows
    .LayoutWindow?
  {
    guard task == nil, let prior = record(for: window) else { return nil }
    let current = try DockWindows.layoutFrame(window.element)
    let displays = Self.screens
    guard let index = WindowLayoutGeometry.screenIndex(for: current, screens: displays) else {
      return nil
    }
    let frame = WindowLayoutGeometry.unsnapped(
      original: prior.window.frame.size,
      current: current, pointer: pointer, in: displays[index])
    let live = DockWindows.LayoutWindow(
      id: window.id, pid: window.pid, element: window.element, frame: current)
    do {
      try DockWindows.layoutApply(frame, to: live)
      let actual = try DockWindows.layoutFrame(window.element)
      guard Self.matches(actual, frame) else { throw failure("App 未采用拖离后的原始尺寸") }
      history.removeValue(forKey: window.id)
      order.removeAll { $0 == window.id }
      if sidebar?.id == window.id { sidebar = nil }
      Log.windows.info("layout unsnap verified pid=\(window.pid) id=\(window.id)")
      return DockWindows.LayoutWindow(
        id: window.id, pid: window.pid, element: window.element, frame: actual)
    } catch {
      let original = error
      Log.windows.error(
        "layout unsnap failed pid=\(window.pid) id=\(window.id) error=\(String(describing: error), privacy: .public)"
      )
      do {
        try DockWindows.layoutApply(current, to: live)
        guard Self.matches(try DockWindows.layoutFrame(window.element), current) else {
          throw failure("App 未采用拖拽前的位置或大小")
        }
      } catch {
        Log.windows.error(
          "layout unsnap rollback failed id=\(window.id) error=\(String(describing: error), privacy: .public)"
        )
        throw failure(
          "\(original.localizedDescription)。回到拖拽前的位置未确认，\(error.localizedDescription)",
          cause: original, recovery: error)
      }
      throw original
    }
  }

  /// 单窗口布局处理还原、跨屏、待办预留和重复按键。
  private func single(_ action: WindowLayoutAction, window: DockWindows.LayoutWindow, screen: Int?)
    async throws
  {
    if action == .specified, let problem = WindowLayoutOptions.customSizeProblem() {
      throw failure(problem)
    }
    let current = try DockWindows.layoutFrame(window.element)
    let live = DockWindows.LayoutWindow(
      id: window.id, pid: window.pid, element: window.element, frame: current)
    let displays = Self.screens
    guard let index = WindowLayoutGeometry.screenIndex(for: current, screens: displays) else {
      throw failure("没有可用的显示器")
    }
    if action == .restore {
      guard let record = record(for: live) else { throw failure("这个窗口没有本次运行中的布局前位置") }
      let targetIndex =
        WindowLayoutGeometry.screenIndex(for: record.window.frame, screens: displays) ?? index
      let target = WindowLayoutGeometry.clamped(record.window.frame, in: displays[targetIndex])
      let adjusted = try await apply(target, window: live, action: action, remember: false)
      if !adjusted {
        history.removeValue(forKey: live.id)
        order.removeAll { $0 == live.id }
        if sidebar?.id == live.id { sidebar = nil }
      }
      return
    }
    let options = WindowLayoutOptions.read()
    let specifiedDisplay = Self.displayNumber(action)
    if action == .nextDisplay || action == .previousDisplay || specifiedDisplay != nil {
      let destination =
        specifiedDisplay ?? (index + (action == .previousDisplay ? displays.count - 1 : 1))
        % displays.count
      guard displays.indices.contains(destination) else { throw failure("目标显示器当前不可用") }
      guard destination != index else {
        throw failure(specifiedDisplay == nil ? "没有其他可用的显示器" : "窗口已经位于目标显示器")
      }
      guard
        let target = WindowLayoutGeometry.transferred(
          current, from: displays[index], to: displays[destination],
          proportional: options.screenProportions)
      else { throw failure("无法计算跨屏位置") }
      try await applyLayout(target, window: live, action: action, bounds: displays[destination])
      return
    }
    if action == .leftTodo || action == .rightTodo {
      if sidebar?.id == live.id, sidebar?.left == (action == .leftTodo) {
        try await single(.restore, window: live, screen: nil)
        return
      }
      var target = displays[index]
      target.size.width = min(options.sidebar, target.width * 0.8)
      if action == .rightTodo { target.origin.x = displays[index].maxX - target.width }
      let adjusted = try await apply(target, window: live, action: action)
      guard !adjusted else {
        if sidebar?.id == live.id { sidebar = nil }
        throw failure("窗口已调整，App 采用的区域与请求不同，待办预留区域尚未建立")
      }
      sidebar = (live.id, displays[index], action == .leftTodo)
      return
    }
    let destination = screen.flatMap { displays.indices.contains($0) ? $0 : nil } ?? index
    let bounds = try workArea(displays[destination], for: live.id, options: options)
    var targetAction = action
    var targetBounds = bounds
    var recordedAction = action
    if let prior = record(for: live), prior.action == action, Self.matches(prior.last, current),
      screen == nil
    {
      let mode =
        WindowLayoutRepeat(rawValue: UserDefaults.standard.string(forKey: Prefs.layoutRepeat) ?? "")
        ?? .across
      let next = mode.target(
        for: action, count: prior.repeats + 1, screen: index,
        screens: Self.screenFrames, portrait: options.portrait && bounds.height > bounds.width)
      targetAction = next.action
      if next.screen != index {
        targetBounds = try workArea(displays[next.screen], for: live.id, options: options)
      }
      recordedAction = next.recorded
    }
    guard
      let target = WindowLayoutGeometry.frame(
        for: targetAction, current: current, in: targetBounds, options: options)
    else { throw failure("无法计算这个窗口动作的目标区域") }
    try await applyLayout(target, window: live, action: recordedAction, bounds: targetBounds)
  }

  /// 单屏集合操作逐应用让出主线程，失败与部分完成保留具体数量和原因。
  private func multiple(_ action: WindowLayoutAction, focused: DockWindows.LayoutWindow)
    async throws
  {
    let displays = Self.screens
    guard let index = WindowLayoutGeometry.screenIndex(for: focused.frame, screens: displays) else {
      throw failure("没有可用的显示器")
    }
    let currentAppOnly = action == .tileActiveApp || action == .cascadeActiveApp
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isHidden && $0 != .current && !isIgnored($0)
        && (!currentAppOnly || $0.processIdentifier == focused.pid)
    }
    guard
      let server = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { throw failure("系统窗口列表读取失败") }
    let visible = Set(server.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    var windows: [DockWindows.LayoutWindow] = []
    var failures: [String] = []
    for app in apps {
      do {
        let entries = try DockWindows.layoutWindows(app)
        windows += entries.filter {
          visible.contains($0.id)
            && WindowLayoutGeometry.screenIndex(for: $0.frame, screens: displays) == index
        }
      } catch {
        Log.windows.error(
          "layout enumerate failed pid=\(app.processIdentifier) error=\(String(describing: error), privacy: .public)"
        )
        failures.append("\(app.localizedName ?? "App") · \(error.localizedDescription)")
      }
      await Task.yield()
      if windows.count >= 128 { break }
    }
    windows = Array(windows.prefix(128))
    let zOrder = server.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    let positions = Dictionary(uniqueKeysWithValues: zOrder.enumerated().map { ($1, $0) })
    windows.sort { (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max) }
    guard !windows.isEmpty else { throw failure(failures.first ?? "当前显示器没有可布局的普通窗口") }
    if action == .cycleStackedWindows || action == .cycleStackedWindowsBackward {
      try cycle(windows, focused: focused, backwards: action == .cycleStackedWindowsBackward)
      return
    }
    let options = WindowLayoutOptions.read()
    let base = try workArea(displays[index], for: 0, options: options)
    let bounds = base.insetBy(
      dx: min(options.edgeGap, base.width / 4),
      dy: min(options.edgeGap, base.height / 4))
    windows.removeAll { $0.id == sidebar?.id }
    let frames =
      action == .cascadeAll || action == .cascadeActiveApp
      ? WindowLayoutGeometry.cascaded(count: windows.count, in: bounds, step: options.cascade)
      : WindowLayoutGeometry.tiled(
        count: windows.count, in: bounds, action: action, gap: options.gap)
    guard frames.count == windows.count else { throw failure("无法为当前窗口集合计算有效布局") }
    var succeeded = 0
    var adjusted = 0
    for (offset, window) in windows.enumerated() {
      if !Feature.windowLayout.isOn || isSuppressed() {
        failures.append("窗口管理已暂停，后续窗口未执行")
        break
      }
      do {
        let target: CGRect
        if action == .reverseAll {
          target = WindowLayoutGeometry.mirrored(window.frame, in: displays[index])
        } else {
          target = frames[offset]
        }
        if try await applyLayout(
          target, window: window, action: action, bounds: bounds, notifyAdjusted: false)
        {
          adjusted += 1
        }
        succeeded += 1
      } catch { failures.append(error.localizedDescription) }
      await Task.yield()
    }
    Log.windows.notice(
      "layout batch result action=\(action.rawValue, privacy: .public) succeeded=\(succeeded) adjusted=\(adjusted) failures=\(failures.count)"
    )
    let result = "已处理 \(succeeded) 扇窗口" + (adjusted > 0 ? "，其中 \(adjusted) 扇采用了不同尺寸" : "")
    if let first = failures.first { throw failure("\(result)，\(failures.count) 项未完成。\(first)") }
    onInfo(result)
  }

  /// 固定尺寸窗口按原大小移动，向使用者明确说明降级行为，批量结果计入区域偏差。
  @discardableResult private func applyLayout(
    _ target: CGRect, window: DockWindows.LayoutWindow,
    action: WindowLayoutAction, bounds: CGRect, notifyAdjusted: Bool = true
  ) async throws -> Bool {
    let before = try DockWindows.layoutFrame(window.element)
    let live = DockWindows.LayoutWindow(
      id: window.id, pid: window.pid, element: window.element, frame: before)
    let changesSize = abs(before.width - target.width) > 1 || abs(before.height - target.height) > 1
    let fixed = try changesSize && !DockWindows.layoutCanResize(live)
    let frame =
      fixed ? WindowLayoutGeometry.positionedFixed(before, desired: target, in: bounds) : target
    let adjusted = try await apply(
      frame, window: live, action: action, notifyAdjusted: notifyAdjusted && !fixed)
    if fixed {
      Log.windows.notice(
        "layout fixed-size fallback action=\(action.rawValue, privacy: .public) pid=\(window.pid) id=\(window.id) original=\(String(describing: before), privacy: .public) requested=\(String(describing: target), privacy: .public) applied=\(String(describing: frame), privacy: .public)"
      )
      if notifyAdjusted { onInfo("这个窗口不支持调整大小，已保持原尺寸移动到目标区域") }
    }
    return fixed || adjusted
  }

  /// 提交后回读实际区域，部分失败尝试回到这次操作前，两个错误独立记录。
  @discardableResult func apply(
    _ frame: CGRect, window: DockWindows.LayoutWindow,
    action: WindowLayoutAction, remember: Bool = true, notifyAdjusted: Bool = true,
    readFrame: @MainActor (AXUIElement) throws -> CGRect = DockWindows.layoutFrame,
    writeFrame: @MainActor (CGRect, DockWindows.LayoutWindow) throws -> Void = DockWindows
      .layoutApply
  ) async throws -> Bool {
    let before: CGRect
    do { before = try readFrame(window.element) } catch {
      Log.windows.error(
        "layout initial-read failed action=\(action.rawValue, privacy: .public) pid=\(window.pid) id=\(window.id) error=\(String(describing: error), privacy: .public)"
      )
      throw error
    }
    let live = DockWindows.LayoutWindow(
      id: window.id, pid: window.pid, element: window.element, frame: before)
    var stage = "write"
    do {
      try writeFrame(frame, live)
      stage = "read-back"
      try await Task.sleep(for: .milliseconds(60))
      let actual = try readFrame(window.element)
      if remember { rememberWindow(live, actual: actual, action: action) }
      if sidebar?.id == window.id, action != .leftTodo, action != .rightTodo, action != .restore {
        sidebar = nil
      }
      let adjusted = !Self.matches(frame, actual)
      Log.windows.info(
        "layout verified action=\(action.rawValue, privacy: .public) pid=\(window.pid) id=\(window.id) adjusted=\(adjusted) requested=\(String(describing: frame), privacy: .public) actual=\(String(describing: actual), privacy: .public)"
      )
      if adjusted {
        Log.windows.notice(
          "layout adjusted action=\(action.rawValue, privacy: .public) pid=\(window.pid) id=\(window.id) requested=\(String(describing: frame), privacy: .public) actual=\(String(describing: actual), privacy: .public)"
        )
      }
      if adjusted, notifyAdjusted {
        onInfo("App 实际采用的窗口大小为 \(Int(actual.width)) × \(Int(actual.height))，位置或大小与请求区域不同")
      }
      return adjusted
    } catch {
      let initial = error
      Log.windows.error(
        "layout write-or-verify failed action=\(action.rawValue, privacy: .public) stage=\(stage, privacy: .public) pid=\(window.pid) id=\(window.id) before=\(String(describing: before), privacy: .public) requested=\(String(describing: frame), privacy: .public) error=\(String(describing: initial), privacy: .public)"
      )
      do {
        try writeFrame(before, live)
        let restored = try readFrame(window.element)
        guard Self.matches(restored, before) else { throw failure("App 未采用操作前的位置或大小") }
        Log.windows.notice("layout rollback verified pid=\(window.pid) id=\(window.id)")
      } catch {
        Log.windows.error(
          "layout rollback failed pid=\(window.pid) id=\(window.id) error=\(String(describing: error), privacy: .public)"
        )
        throw failure(
          "\(initial.localizedDescription)。回到操作前的位置未确认，\(error.localizedDescription)",
          cause: initial, recovery: error)
      }
      throw initial
    }
  }

  /// 使用对象身份核对记录，避免窗口编号被系统复用后恢复到其他窗口的位置。
  private func record(for window: DockWindows.LayoutWindow) -> Record? {
    guard let record = history[window.id], record.window.pid == window.pid,
      CFEqual(record.window.element, window.element)
    else { return nil }
    return record
  }

  /// 保留第一份原始位置，更新最后实际位置和连续执行次数。
  private func rememberWindow(
    _ window: DockWindows.LayoutWindow, actual: CGRect, action: WindowLayoutAction
  ) {
    if var prior = record(for: window) {
      prior.repeats =
        prior.action == action && Self.matches(prior.last, window.frame) ? prior.repeats + 1 : 0
      prior.last = actual
      prior.action = action
      history[window.id] = prior
    } else {
      history[window.id] = Record(window: window, last: actual, action: action)
    }
    order.removeAll { $0 == window.id }
    order.append(window.id)
    while order.count > 128 { history.removeValue(forKey: order.removeFirst()) }
  }

  /// 待办窗口位于当前屏幕时为其他窗口预留边栏。
  private func workArea(_ screen: CGRect, for id: CGWindowID, options: WindowLayoutOptions)
    throws -> CGRect
  {
    guard let sidebar, sidebar.id != id, sidebar.screen == screen, history[sidebar.id] != nil else {
      return screen
    }
    if let record = history[sidebar.id] {
      do {
        let actual = try DockWindows.layoutFrame(record.window.element)
        guard Self.matches(actual, record.last), screen.intersects(actual) else {
          self.sidebar = nil
          Log.windows.notice("layout sidebar released id=\(sidebar.id) reason=geometry-changed")
          return screen
        }
      } catch {
        let error = error as NSError
        guard error.domain == "KittyTools.WindowAccessibility",
          error.code == Int(AXError.invalidUIElement.rawValue)
        else { throw error }
        self.sidebar = nil
        Log.windows.notice(
          "layout sidebar released id=\(sidebar.id) reason=invalid-window AXError=\(error.code)")
        return screen
      }
    }
    let width = min(options.sidebar, screen.width * 0.8)
    return CGRect(
      x: screen.minX + (sidebar.left ? width + options.gap : 0), y: screen.minY,
      width: max(1, screen.width - width - options.gap), height: screen.height)
  }

  /// 切换与前台窗口重叠的窗口，名单稳定后按正向或反向循环。
  private func cycle(
    _ windows: [DockWindows.LayoutWindow], focused: DockWindows.LayoutWindow, backwards: Bool
  ) throws {
    let overlapping = windows.filter {
      let shared = $0.frame.intersection(focused.frame)
      return !shared.isNull
        && shared.width * shared.height
          / min(
            $0.frame.width * $0.frame.height,
            focused.frame.width * focused.frame.height) > 0.7
    }
    guard overlapping.count > 1 else { throw failure("当前窗口没有可切换的重叠窗口") }
    let ids = overlapping.map(\.id)
    if Set(ids) != Set(stackOrder) { stackOrder = ids }
    let current = stackOrder.firstIndex(of: focused.id) ?? 0
    let next = (current + (backwards ? stackOrder.count - 1 : 1)) % stackOrder.count
    guard let target = overlapping.first(where: { $0.id == stackOrder[next] }),
      let app = NSRunningApplication(processIdentifier: target.pid)
    else { throw failure("目标窗口已关闭") }
    let access = DockWindows()
    _ = access.list(app)
    guard
      access.focus(
        DockWindow(id: target.id, title: "", state: .shown, size: target.frame.size), of: app)
    else { throw access.lastError ?? failure("目标窗口切换未确认") }
    onInfo("重叠窗口 \(next + 1) / \(stackOrder.count)")
  }

  /// 同一动作重复时依次在基础区域、三分之二和三分之一之间切换。
  nonisolated static func repeated(_ action: WindowLayoutAction, count: Int, portrait: Bool = false)
    -> WindowLayoutAction
  {
    let cycles: [[WindowLayoutAction]] = [
      [.leftHalf, .firstTwoThirds, .firstThird], [.rightHalf, .lastTwoThirds, .lastThird],
      [.topHalf, .topVerticalTwoThirds, .topVerticalThird],
      [.bottomHalf, .bottomVerticalTwoThirds, .bottomVerticalThird],
      [.firstThird, .centerThird, .lastThird], [.lastThird, .centerThird, .firstThird],
      [.centerHalf, .centerTwoThirds, .centerThird],
    ]
    if let cycle = cycles.first(where: { $0.first == action }) { return cycle[count % cycle.count] }
    let families = [
      "VerticalEighth", "VerticalSixth", "Sixteenth", "Twelfth", "Ninth", "Eighth", "Sixth",
      "Fourth",
    ]
    guard let suffix = families.first(where: { action.rawValue.hasSuffix($0) }) else {
      return action
    }
    let cycle = WindowLayoutAction.allCases.filter {
      $0.rawValue.hasSuffix(suffix)
        && (suffix != "Sixth" || !$0.rawValue.contains("Vertical"))
        && (suffix != "Eighth" || !$0.rawValue.contains("Vertical"))
    }.sorted {
      guard let first = $0.unitRect(portrait: portrait),
        let second = $1.unitRect(portrait: portrait)
      else { return $0.rawValue < $1.rawValue }
      return first.minY == second.minY ? first.minX < second.minX : first.minY < second.minY
    }
    guard let start = cycle.firstIndex(of: action) else { return action }
    let delta =
      (action == .topRightSixth || action == .bottomRightSixth)
      ? -(count % cycle.count) : count % cycle.count
    return cycle[(start + delta + cycle.count) % cycle.count]
  }

  /// 指定显示器动作映射为系统屏幕顺序的零基编号。
  nonisolated static func displayNumber(_ action: WindowLayoutAction) -> Int? {
    [
      .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive, .displaySix,
      .displaySeven, .displayEight, .displayNine,
    ].firstIndex(of: action)
  }

  /// 回读允许系统像素取整产生一点评差异。
  nonisolated static func matches(_ first: CGRect, _ second: CGRect) -> Bool {
    abs(first.minX - second.minX) <= 1 && abs(first.minY - second.minY) <= 1
      && abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
  }

  /// 错误文本在使用者提示里保持可读，日志保留原始类型、阶段、关联窗口。
  private func report(_ error: Error, action: String, window: DockWindows.LayoutWindow? = nil) {
    Log.windows.error(
      "layout failed action=\(action, privacy: .public) pid=\(window?.pid ?? 0) id=\(window?.id ?? 0) error=\(String(describing: error), privacy: .public)"
    )
    onProblem("\(action)未完成。\(error.localizedDescription)")
  }

  /// 生成执行层有证据支持的业务错误。
  private func failure(_ message: String, cause: Error? = nil, recovery: Error? = nil) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: message]
    if let cause { info[NSUnderlyingErrorKey] = cause }
    if let recovery { info["KittyTools.RollbackError"] = recovery }
    return NSError(domain: "KittyTools.WindowLayout", code: 1, userInfo: info)
  }
}
