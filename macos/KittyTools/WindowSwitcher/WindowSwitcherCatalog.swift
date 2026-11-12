// 窗口切换器的进程目录与焦点观察，复用程序坞预览的窗口读取及管理入口。

import AppKit
import ApplicationServices
import OSLog

/// 跟踪功能启用后的窗口焦点顺序，关闭功能时卸载所有跨进程观察者。
@MainActor final class WindowSwitcherCatalog: NSObject {
  private(set) var readers: [pid_t: DockWindows] = [:]
  private var observers: [pid_t: (AXObserver, AXUIElement)] = [:]
  private var recent: [CGWindowID: UInt64] = [:]
  private(set) var focusedID: CGWindowID?
  private var sequence: UInt64 = 0
  private var started = false
  private(set) var trackingFailures = Set<pid_t>()

  /// 启用工作区通知，辅助功能授权可在稍后呼出时重新检查。
  func start() {
    guard !started else { return }
    started = true
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
    }
    attachRunning()
    recordFrontmost()
  }

  /// 关闭功能，清除辅助功能观察、焦点记录及上次读取的对象。
  func stop() {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    for pid in Array(observers.keys) { detach(pid) }
    readers = [:]
    recent = [:]
    focusedID = nil
    sequence = 0
    trackingFailures = []
    started = false
  }

  isolated deinit { stop() }

  /// 只列普通应用；避免对本进程发辅助功能消息导致主线程等待自己。
  func applications() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated
        && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
  }

  /// 收起后释放窗口辅助功能对象，下次枚举重新取得。
  func releaseSnapshots() { readers = [:] }

  /// 每个应用持有独立的窗口读取器，列表刷新后操作仍对应正确进程。
  func read(_ app: NSRunningApplication, info: [[String: Any]]) -> [SwitchWindow] {
    let reader = readers[app.processIdentifier] ?? DockWindows()
    readers[app.processIdentifier] = reader
    return reader.list(app, serverInfo: info).map {
      SwitchWindow(window: $0, pid: app.processIdentifier, appName: app.localizedName ?? "未提供应用名称")
    }
  }

  /// 更新可用观察者，授权变化或单个应用注册失败时可在下一次呼出重试。
  func attachRunning() {
    guard started, Permissions.isAccessibilityTrusted else { return }
    let apps = applications()
    let alive = Set(apps.map(\.processIdentifier))
    for pid in Array(observers.keys) where !alive.contains(pid) { detach(pid) }
    for app in apps where observers[app.processIdentifier] == nil { attach(app) }
    readers = readers.filter { alive.contains($0.key) }
    trackingFailures.formIntersection(alive)
  }

  /// 只保留当前窗口的焦点记录，防止长期运行时已关闭窗口累积。
  func ordered(_ windows: [SwitchWindow], info: [[String: Any]], complete: Bool) -> [SwitchWindow] {
    recent = WindowSwitcherModel.historyAfterRefresh(recent, windows: windows, complete: complete)
    var stacking: [CGWindowID: Int] = [:]
    for (index, row) in info.enumerated() {
      if let number = row[kCGWindowNumber as String] as? UInt32 { stacking[number] = index }
    }
    return WindowSwitcherModel.ordered(windows, recent: recent, stacking: stacking)
  }

  /// 呼出前记录当前窗口，保持第一下跳到上一个目标。
  func recordCurrentFocus() { recordFrontmost() }

  /// 应用切换和应用内窗口焦点变化都更新同一条顺序。
  fileprivate func recordFrontmost() {
    guard Permissions.isAccessibilityTrusted,
      let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let value = DockWatcher.value(root, kAXFocusedWindowAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID(),
      let id = WindowServer.windowID(of: value as! AXUIElement)
    else { return }
    focusedID = id
    sequence += 1
    recent[id] = sequence
    // ponytail: 焦点账最多 4096 项，完整刷新时按存活窗口裁剪；达到上限时保留最近一半。
    if recent.count > 4096 {
      recent = recent.filter { $0.value > sequence - 2048 }
    }
  }

  /// 工作区的进程生命周期变化只调整观察者，不在后台截取窗口图像。
  @objc private func workspaceChanged(_ notification: Notification) {
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    {
      if notification.name == NSWorkspace.didTerminateApplicationNotification {
        detach(app.processIdentifier)
        readers[app.processIdentifier] = nil
      } else if notification.name == NSWorkspace.didLaunchApplicationNotification {
        attach(app)
      }
    }
    if notification.name == NSWorkspace.didActivateApplicationNotification { recordFrontmost() }
  }

  /// 注册当前应用的窗口焦点通知，失败保留原始错误码并允许后续重试。
  private func attach(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard observers[pid] == nil, app.activationPolicy == .regular, !app.isTerminated,
      pid != ProcessInfo.processInfo.processIdentifier, Permissions.isAccessibilityTrusted
    else { return }
    var observer: AXObserver?
    var status = AXObserverCreate(pid, switcherFocusChanged, &observer)
    guard status == .success, let observer else { return trackingFailed(pid, status) }
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, DockWatcher.messagingTimeout)
    status = AXObserverAddNotification(
      observer, root, kAXFocusedWindowChangedNotification as CFString,
      Unmanaged.passUnretained(self).toOpaque())
    guard status == .success else { return trackingFailed(pid, status) }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    observers[pid] = (observer, root)
    trackingFailures.remove(pid)
  }

  /// 将观察者注册错误保留在可检索日志和当前读取结果中。
  private func trackingFailed(_ pid: pid_t, _ status: AXError) {
    trackingFailures.insert(pid)
    Log.windows.error("focus observer failed pid=\(pid) AXError=\(status.rawValue)")
  }

  /// 移除运行循环源后再释放观察者，避免回调访问已释放实例。
  private func detach(_ pid: pid_t) {
    guard let (observer, root) = observers.removeValue(forKey: pid) else { return }
    AXObserverRemoveNotification(observer, root, kAXFocusedWindowChangedNotification as CFString)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    trackingFailures.remove(pid)
  }
}

/// 辅助功能观察回调运行在主运行循环，只记录当前前台窗口。
nonisolated private func switcherFocusChanged(
  _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }
  let catalog = Unmanaged<WindowSwitcherCatalog>.fromOpaque(context).takeUnretainedValue()
  MainActor.assumeIsolated { catalog.recordFrontmost() }
}
