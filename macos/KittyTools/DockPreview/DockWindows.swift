// 程序坞预览：列一个 App 的窗口、切过去、关掉（第九族，2026-10-22）。
// 列：辅助功能的窗口表（kAXWindows：当前桌面上的，加最小化的）+ 窗口服务器全表里这个 App 在别的桌面上的（辅助功能看不到它们，
// AltTab 的 README 讲过；要知道在哪个桌面，WindowServer.place）。只要普通窗口：标准窗口和对话框、宽高都不小于 100 点；
// 调色板、浮动工具条、关掉却还留着的（哪个桌面都不在）不要。排序按打开先后（窗口编号随创建递增），最小化的排最后（拍板 C3）。
// 窗口编号靠私有的 _AXUIElementGetWindow；接口不在时按「标题 + 位置大小」去窗口服务器的表里配，配不上唯一一扇的不列。
// 切：最小化的先还原、隐藏的 App 先显示，再按编号拿到最前（WindowServer.bringToFront，不成就 activate），最后让它当主窗口、抬到前面。
// 关：按那扇窗口的关闭钮（别的桌面上的拿不到辅助功能对象，关不了，界面不给 ✕，拍板 C4）。
// 读别的 App 的辅助功能：每个对象读之前先设 0.3 秒超时（卡住的 App 默认要等 6 秒；DockWatcher.value 里统一设），在主线程读。
// ponytail: 在主线程列，实测中位约 20 ms、最长约 50 ms（PLAN §10）；碰上卡住的 App 每个属性最多等 0.3 秒，几扇窗口就是一两秒——
// 真碰到了再改成第一次超时（.cannotComplete）就不往下读，或者整个挪出主线程（要先把 AXUIElement 的读法收进 @concurrent 的一类）。

import AppKit
import ApplicationServices
import OSLog

/// 预览里的一扇窗口
struct DockWindow: Identifiable, Equatable {
  enum State: Equatable {
    /// 在当前桌面上（可能被别的窗口挡着）
    case shown
    case minimized
    /// App 被隐藏了（⌘H）
    case hidden
    /// 在别的桌面上（包括全屏 App 自己占的那个）
    case elsewhere
  }

  let id: CGWindowID
  let title: String
  let state: State
  /// 窗口大小（点），缩略图按它的比例
  let size: CGSize
}

@MainActor final class DockWindows {
  /// 一次窗口布局操作的目标，辅助功能对象只在主线程的短会话里持有。
  struct LayoutWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
  }

  /// 当前前台 App 的新窗口观察者，停用时同步移除主运行循环源。
  final class LayoutObservation {
    private var observer: AXObserver?
    private let application: AXUIElement
    private let pid: pid_t
    private let onWindow: (LayoutWindow) -> Void
    private var active = true
    private var pending: [UUID: Task<Void, Never>] = [:]

    /// 观察新建窗口，不接收标题、正文等内容属性。
    init(app: NSRunningApplication, onWindow: @escaping (LayoutWindow) -> Void) throws {
      pid = app.processIdentifier
      application = AXUIElementCreateApplication(pid)
      self.onWindow = onWindow
      var created: AXObserver?
      let status = AXObserverCreate(
        pid,
        { _, element, _, context in
          guard let context else { return }
          MainActor.assumeIsolated {
            let owner = Unmanaged<LayoutObservation>.fromOpaque(context).takeUnretainedValue()
            guard owner.active else { return }
            owner.created(element)
          }
        }, &created)
      guard status == .success, let created else {
        throw DockWindows.problem(status, stage: "创建新窗口观察者")
      }
      AXUIElementSetMessagingTimeout(application, DockWatcher.messagingTimeout)
      let added = AXObserverAddNotification(
        created, application, kAXWindowCreatedNotification as CFString,
        Unmanaged.passUnretained(self).toOpaque())
      guard added == .success else { throw DockWindows.problem(added, stage: "观察新建窗口") }
      observer = created
      CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    isolated deinit { stop() }

    /// 移除观察通知和运行循环源，后续回调不会再触发窗口动作。
    func stop() {
      active = false
      for task in pending.values { task.cancel() }
      pending.removeAll()
      guard let observer else { return }
      AXObserverRemoveNotification(observer, application, kAXWindowCreatedNotification as CFString)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
      self.observer = nil
    }

    /// 给目标应用一次初始布局的时间，随后只读取普通窗口，退出时取消待处理回调。
    private func created(_ element: AXUIElement) {
      guard pending.count < 32 else {
        Log.windows.error("layout created window queue full pid=\(self.pid)")
        return
      }
      let token = UUID()
      pending[token] = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        guard let self, active else { return }
        defer { pending.removeValue(forKey: token) }
        do {
          guard
            try DockWindows.checkedValue(element, kAXSubroleAttribute) as? String
              == kAXStandardWindowSubrole,
            try DockWindows.checkedValue(element, kAXMinimizedAttribute) as? Bool != true
          else { return }
          onWindow(try DockWindows.layoutWindow(element, pid: pid))
        } catch {
          Log.windows.error(
            "layout created window read failed pid=\(self.pid) error=\(String(describing: error), privacy: .public)"
          )
        }
      }
    }
  }

  /// 读取指定 App 的焦点窗口，完整保留系统返回的失败原因。
  static func layoutFocused(_ app: NSRunningApplication) throws -> LayoutWindow {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    guard let raw = try checkedValue(application, kAXFocusedWindowAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { throw problem(.noValue, stage: "取得当前窗口") }
    return try layoutWindow(raw as! AXUIElement, pid: app.processIdentifier)
  }

  /// 读取 App 的普通可见窗口，批量排布不处理最小化、全屏和无效窗口。
  static func layoutWindows(_ app: NSRunningApplication) throws -> [LayoutWindow] {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    let windows = try checkedValue(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    var targets: [LayoutWindow] = []
    for element in windows.prefix(128) {
      guard try checkedValue(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
        try checkedValue(element, kAXMinimizedAttribute) as? Bool != true,
        try checkedValue(element, "AXFullScreen") as? Bool != true
      else { continue }
      targets.append(try layoutWindow(element, pid: app.processIdentifier))
    }
    return targets
  }

  /// 命中指定 App 的窗口，供拖拽和鼠标侧键使用，不激活或抬起窗口。
  static func layoutAt(_ point: CGPoint, app: NSRunningApplication) throws -> LayoutWindow? {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, DockWatcher.messagingTimeout)
    var found: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(
      application, Float(point.x), Float(point.y), &found)
    guard status == .success else { throw problem(status, stage: "取得鼠标下的窗口") }
    guard let found else { return nil }
    if try checkedValue(found, kAXRoleAttribute) as? String == kAXWindowRole {
      return try layoutWindow(found, pid: app.processIdentifier)
    }
    guard let raw = try checkedValue(found, kAXWindowAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    return try layoutWindow(raw as! AXUIElement, pid: app.processIdentifier)
  }

  /// 只认标题或工具栏空白处的双击，按钮、标签页和正文元素保持原有行为。
  static func layoutTitleBar(at point: CGPoint, app: NSRunningApplication) throws -> LayoutWindow? {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, DockWatcher.messagingTimeout)
    var found: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(
      application, Float(point.x), Float(point.y), &found)
    guard status == .success else { throw problem(status, stage: "读取标题栏") }
    guard let found, let window = try layoutAt(point, app: app),
      point.y - window.frame.minY >= 0, point.y - window.frame.minY <= 40
    else { return nil }
    let role = try checkedValue(found, kAXRoleAttribute) as? String
    if role == kAXToolbarRole || role == kAXWindowRole { return window }
    if let title = try checkedValue(window.element, kAXTitleUIElementAttribute),
      CFEqual(title, found)
    {
      return window
    }
    return nil
  }

  /// 核对普通窗口身份、有限尺寸与全屏状态，系统未返回编号时拒绝缓存身份。
  private static func layoutWindow(_ element: AXUIElement, pid: pid_t) throws -> LayoutWindow {
    guard try checkedValue(element, kAXRoleAttribute) as? String == kAXWindowRole,
      try checkedValue(element, "AXFullScreen") as? Bool != true,
      try checkedValue(element, kAXMinimizedAttribute) as? Bool != true
    else { throw problem(.actionUnsupported, stage: "取得可布局的普通窗口") }
    let frame = try layoutFrame(element)
    let id: CGWindowID
    if let known = WindowServer.windowID(of: element) {
      id = known
    } else {
      let title = try checkedValue(element, kAXTitleAttribute) as? String ?? ""
      let matches = serverEntries(pid: pid).filter {
        $0.layer == 0 && WindowLayout.matches($0.frame, frame)
          && (title.isEmpty || $0.title == title)
      }
      guard matches.count == 1, let matched = matches.first else {
        throw problem(.actionUnsupported, stage: "核对目标窗口身份")
      }
      id = matched.id
    }
    return LayoutWindow(id: id, pid: pid, element: element, frame: frame)
  }

  /// 重新读取窗口实际位置和尺寸，供操作后验收及拖拽识别使用。
  static func layoutFrame(_ element: AXUIElement) throws -> CGRect {
    let origin = try checkedGeometry(element, kAXPositionAttribute, point: true)
    let size = try checkedGeometry(element, kAXSizeAttribute, point: false)
    let frame = CGRect(x: origin.width, y: origin.height, width: size.width, height: size.height)
    guard WindowLayoutGeometry.valid(frame) else {
      throw problem(.illegalArgument, stage: "读取窗口位置和尺寸")
    }
    return frame
  }

  /// 明确查询窗口是否支持尺寸写入，通信失败与不支持调整大小分别传递。
  static func layoutCanResize(_ window: LayoutWindow) throws -> Bool {
    AXUIElementSetMessagingTimeout(window.element, DockWatcher.messagingTimeout)
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(
      window.element, kAXSizeAttribute as CFString, &settable)
    if status == .attributeUnsupported { return false }
    guard status == .success else { throw problem(status, stage: "检查窗口是否可调整大小") }
    return settable.boolValue
  }

  /// 读取动作选择器显示的目标标题，内容只展示在本机界面中。
  static func layoutTitle(_ window: LayoutWindow) throws -> String? {
    try checkedValue(window.element, kAXTitleAttribute) as? String
  }

  /// 写入尺寸和位置后再写一次尺寸，兼容跨屏时 App 按旧屏限制大小的行为。
  static func layoutApply(_ frame: CGRect, to window: LayoutWindow) throws {
    guard WindowLayoutGeometry.valid(frame) else {
      throw problem(.illegalArgument, stage: "校验目标区域")
    }
    AXUIElementSetMessagingTimeout(window.element, DockWatcher.messagingTimeout)
    var sizeSettable = DarwinBoolean(false)
    var positionSettable = DarwinBoolean(false)
    let sizeStatus = AXUIElementIsAttributeSettable(
      window.element, kAXSizeAttribute as CFString, &sizeSettable)
    let positionStatus = AXUIElementIsAttributeSettable(
      window.element, kAXPositionAttribute as CFString, &positionSettable)
    guard positionStatus == .success, positionSettable.boolValue else {
      throw problem(
        positionStatus == .success ? .attributeUnsupported : positionStatus, stage: "检查窗口是否可移动")
    }
    var size = frame.size
    var point = frame.origin
    let changes =
      abs(window.frame.width - frame.width) > 1 || abs(window.frame.height - frame.height) > 1
    if changes, sizeStatus != .success || !sizeSettable.boolValue {
      throw problem(
        sizeStatus == .success ? .attributeUnsupported : sizeStatus, stage: "检查窗口是否可调整大小")
    }
    if changes {
      try layoutSet(AXValueCreate(.cgSize, &size), attribute: kAXSizeAttribute, on: window.element)
    }
    try layoutSet(
      AXValueCreate(.cgPoint, &point), attribute: kAXPositionAttribute, on: window.element)
    if changes {
      try layoutSet(AXValueCreate(.cgSize, &size), attribute: kAXSizeAttribute, on: window.element)
    }
    try layoutSet(
      AXValueCreate(.cgPoint, &point), attribute: kAXPositionAttribute, on: window.element)
  }

  /// 单个属性写入失败时向上保留原始 AX 错误，调用方记录阶段和回退结果。
  private static func layoutSet(_ value: AXValue?, attribute: String, on element: AXUIElement)
    throws
  {
    guard let value else { throw problem(.illegalArgument, stage: attribute) }
    let status = AXUIElementSetAttributeValue(element, attribute as CFString, value)
    guard status == .success else { throw problem(status, stage: attribute) }
  }

  /// 最近一次列出来的窗口的辅助功能对象（切过去、关掉要用；别的桌面上的没有）
  private var elements: [CGWindowID: AXUIElement] = [:]

  /// 辅助功能表里的一扇（纯数据，给 merge 用）
  struct AXEntry: Equatable {
    var id: CGWindowID?
    var title: String
    var subrole: String
    var minimized: Bool
    /// 窗口服务器的坐标（原点主屏左上、y 向下），和 ServerEntry.frame 同一套
    var frame: CGRect
  }

  /// 窗口服务器全表里的一扇（纯数据）
  struct ServerEntry: Equatable {
    var id: CGWindowID
    var title: String
    var layer: Int
    var alpha: Double
    var frame: CGRect
    /// nil = 不知道（查桌面的接口不在）
    var place: WindowServer.Place?
  }

  /// 小于这个（点）的不算普通窗口
  static let minimumSide: CGFloat = 100

  /// 最近一次读取或操作的原始错误；调用方据此区分失败与有效空结果。
  private(set) var lastError: NSError?

  /// 列出窗口，可共用一次取得的窗口服务器全表；遇到无响应的进程立即结束本次读取。
  func list(_ app: NSRunningApplication, serverInfo: [[String: Any]]? = nil) -> [DockWindow] {
    elements = [:]
    lastError = nil
    guard Permissions.isAccessibilityTrusted else {
      lastError = Self.problem(.apiDisabled, stage: "辅助功能授权")
      return []
    }
    let began = CACurrentMediaTime()
    do {
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      let windows = try Self.checkedValue(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
      var axEntries: [AXEntry] = []
      for window in windows {
        let origin = try Self.checkedGeometry(window, kAXPositionAttribute, point: true)
        let size = try Self.checkedGeometry(window, kAXSizeAttribute, point: false)
        let id = WindowServer.windowID(of: window)
        axEntries.append(
          AXEntry(
            id: id, title: try Self.checkedValue(window, kAXTitleAttribute) as? String ?? "",
            subrole: try Self.checkedValue(window, kAXSubroleAttribute) as? String ?? "",
            minimized: try Self.checkedValue(window, kAXMinimizedAttribute) as? Bool ?? false,
            frame: CGRect(x: origin.width, y: origin.height, width: size.width, height: size.height)
          ))
      }
      let server = Self.serverEntries(pid: app.processIdentifier, info: serverInfo)
      let ids = Self.resolveIDs(axEntries, server: server)
      for (index, window) in windows.enumerated() {
        if let id = ids[index] { elements[id] = window }
      }
      for index in axEntries.indices { axEntries[index].id = ids[index] }
      return Self.merge(ax: axEntries, server: server, appHidden: app.isHidden)
    } catch {
      lastError = error as NSError
      Log.windows.error(
        "list failed pid=\(app.processIdentifier) elapsed=\(CACurrentMediaTime() - began) error=\(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  /// 读取辅助功能属性，保留原始错误码；可选属性没有值时返回 nil。
  private static func checkedValue(_ element: AXUIElement, _ attribute: String) throws -> AnyObject?
  {
    AXUIElementSetMessagingTimeout(element, DockWatcher.messagingTimeout)
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard status == .success || status == .noValue || status == .attributeUnsupported else {
      throw problem(status, stage: attribute)
    }
    return value
  }

  /// 读取窗口位置或大小，并核对系统返回值的类型。
  private static func checkedGeometry(
    _ element: AXUIElement, _ attribute: String, point: Bool
  ) throws -> CGSize {
    guard let value = try checkedValue(element, attribute) else { return .zero }
    guard CFGetTypeID(value) == AXValueGetTypeID() else {
      throw problem(.illegalArgument, stage: attribute)
    }
    let ax = value as! AXValue
    if point {
      var result = CGPoint.zero
      guard AXValueGetValue(ax, .cgPoint, &result) else {
        throw problem(.illegalArgument, stage: attribute)
      }
      return CGSize(width: result.x, height: result.y)
    }
    var result = CGSize.zero
    guard AXValueGetValue(ax, .cgSize, &result) else {
      throw problem(.illegalArgument, stage: attribute)
    }
    return result
  }

  /// 将系统错误转换为可跨界面传递的原始阶段和错误码。
  private static func problem(_ status: AXError, stage: String) -> NSError {
    let names = [
      kAXPositionAttribute: "窗口位置", kAXSizeAttribute: "窗口大小",
      kAXWindowsAttribute: "应用窗口列表", kAXFocusedWindowAttribute: "当前窗口",
      kAXRoleAttribute: "窗口类型", kAXSubroleAttribute: "窗口子类型",
      kAXMinimizedAttribute: "窗口最小化状态", kAXTitleAttribute: "窗口标题",
      kAXTitleUIElementAttribute: "标题栏", "AXFullScreen": "窗口全屏状态",
    ]
    return NSError(
      domain: "KittyTools.WindowAccessibility", code: Int(status.rawValue),
      userInfo: [
        NSLocalizedDescriptionKey: "\(names[stage] ?? stage)失败（系统代码 \(status.rawValue)）",
        "KittyTools.AXStage": stage,
      ])
  }

  /// 提交目标窗口的激活操作；只能激活应用时明确返回失败，供调用方说明结果。
  @discardableResult func focus(_ window: DockWindow, of app: NSRunningApplication) -> Bool {
    lastError = nil
    if app.isHidden { app.unhide() }
    let element = elements[window.id]
    if window.state == .minimized, !setMinimized(false, window: window) { return false }
    let exact = WindowServer.bringToFront(pid: app.processIdentifier, window: window.id)
    if !exact { app.activate() }
    if let element {
      let main = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
      let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
      if raised == .success { return true }
      if !exact { return failed(raised, stage: "抬起窗口", id: window.id) }
      Log.windows.notice(
        "focus AX fallback id=\(window.id) main=\(main.rawValue) raise=\(raised.rawValue)")
    }
    guard exact else { return failed(.cannotComplete, stage: "应用已激活，目标窗口未确认", id: window.id) }
    return true
  }

  /// 能取得辅助功能对象时，才提供窗口管理操作。
  func canManage(_ window: DockWindow) -> Bool { elements[window.id] != nil }

  /// 能否取得关闭钮；其他桌面的窗口可能只支持切换。
  func canClose(_ window: DockWindow) -> Bool {
    guard let element = elements[window.id] else { return false }
    return DockWatcher.value(element, kAXCloseButtonAttribute) != nil
  }

  /// 按窗口关闭钮，失败保留系统原始原因；关闭请求可能由目标应用转为保存确认。
  @discardableResult func close(_ window: DockWindow) -> Bool {
    lastError = nil
    guard let element = elements[window.id] else {
      return failed(.invalidUIElement, stage: "取得窗口", id: window.id)
    }
    do {
      guard let button = try Self.checkedValue(element, kAXCloseButtonAttribute),
        CFGetTypeID(button) == AXUIElementGetTypeID()
      else { return failed(.actionUnsupported, stage: "取得关闭按钮", id: window.id) }
      let press = button as! AXUIElement
      AXUIElementSetMessagingTimeout(press, DockWatcher.messagingTimeout)
      let status = AXUIElementPerformAction(press, kAXPressAction as CFString)
      return status == .success || failed(status, stage: "关闭窗口", id: window.id)
    } catch {
      lastError = error as NSError
      Log.windows.error(
        "close failed id=\(window.id) error=\(String(describing: error), privacy: .public)")
      return false
    }
  }

  /// 设置最小化状态，目标不支持或系统拒绝时返回原始错误。
  @discardableResult func setMinimized(_ minimized: Bool, window: DockWindow) -> Bool {
    lastError = nil
    guard let element = elements[window.id] else {
      return failed(.invalidUIElement, stage: "取得窗口", id: window.id)
    }
    AXUIElementSetMessagingTimeout(element, DockWatcher.messagingTimeout)
    let status = AXUIElementSetAttributeValue(
      element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    return status == .success || failed(status, stage: "设置最小化", id: window.id)
  }

  /// 统一记录操作失败的阶段、窗口编号和原始系统错误。
  private func failed(_ status: AXError, stage: String, id: CGWindowID) -> Bool {
    lastError = Self.problem(status, stage: stage)
    Log.windows.error(
      "window operation failed id=\(id) stage=\(stage, privacy: .public) AXError=\(status.rawValue)"
    )
    return false
  }

  // MARK: 窗口服务器的全表

  /// 窗口服务器全表里这个 App 的窗口（含别的桌面上的、最小化的、关掉却留着的）
  private static func serverEntries(pid: pid_t, info supplied: [[String: Any]]? = nil)
    -> [ServerEntry]
  {
    let info =
      supplied ?? CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return info.compactMap { window in
      guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
        let number = window[kCGWindowNumber as String] as? Int,
        let id = CGWindowID(exactly: number),
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return nil }
      let layer = window[kCGWindowLayer as String] as? Int ?? 0
      return ServerEntry(
        id: id, title: window[kCGWindowName as String] as? String ?? "", layer: layer,
        alpha: window[kCGWindowAlpha as String] as? Double ?? 1, frame: frame,
        // 只有可能列进来的才问在哪个桌面（一扇约 0.02 ms）
        place: layer == 0 ? WindowServer.place(of: id) : nil)
    }
  }

  // MARK: 纯函数

  /// 每扇辅助功能里的窗口的编号：有私有接口给的就用；没有的按「标题 + 位置大小」在全表里找唯一一扇（同样标题同样位置的
  /// 两扇都不认），已经被别的认走的不再认
  static func resolveIDs(_ ax: [AXEntry], server: [ServerEntry]) -> [CGWindowID?] {
    var taken = Set(ax.compactMap(\.id))
    return ax.map { entry in
      if let id = entry.id { return id }
      let matches = server.filter {
        $0.layer == 0 && !taken.contains($0.id) && $0.title == entry.title
          && abs($0.frame.minX - entry.frame.minX) < 1 && abs($0.frame.minY - entry.frame.minY) < 1
          && abs($0.frame.width - entry.frame.width) < 1
          && abs($0.frame.height - entry.frame.height) < 1
      }
      guard matches.count == 1 else { return nil }
      taken.insert(matches[0].id)
      return matches[0].id
    }
  }

  /// 两张表并成预览里的窗口：辅助功能的（普通窗口、有编号、不太小）在前，再加只在全表里、确定在别的桌面上的；
  /// 按编号排，最小化的放最后。全表里拿不到子角色：别的桌面上贴在文稿窗口上的表单（存储对话框）也是一扇层级 0 的窗口，
  /// 没标题、整个落在同一个 App 另一扇别的桌面上的窗口里面的，当它是那种，不列。没有屏幕录制授权时全表里的标题都是空的
  /// （界面写 App 名）。没标题、又扁又宽（宽至少是高的 4 倍）、搭在同一个 App 一扇更高的窗口上（相交或贴边）的也不列：
  /// 2026-11-06 用户报别的桌面上全屏的 Chrome 多出两张扁扁的「Google Chrome」卡片——除了 1760 × 868 的主窗口，全表里
  /// 还有 1508 × 178、1760 × 166 两扇没标题的，伸出主窗口上沿、只和它部分重叠，原来只认「整个套在里面」的漏掉了
  /// （是 Chrome 的哪个控件分不清，按形状认）。
  /// ponytail: 表单是按「没标题 + 套在别的窗口里」猜的，别的桌面上没标题的小窗口恰好套在大窗口里会被漏掉；
  /// 要准得拿到它的辅助功能对象（AltTab 用 _AXUIElementCreateWithRemoteToken 逐个试），手测看了再说（HANDTEST「程序坞预览手测」3）。
  static func merge(ax: [AXEntry], server: [ServerEntry], appHidden: Bool) -> [DockWindow] {
    let normal: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole]
    var result: [DockWindow] = []
    var seen = Set<CGWindowID>()
    for entry in ax {
      guard let id = entry.id, normal.contains(entry.subrole), isBigEnough(entry.frame.size),
        seen.insert(id).inserted
      else { continue }
      let state: DockWindow.State =
        entry.minimized ? .minimized : appHidden ? .hidden : .shown
      result.append(DockWindow(id: id, title: entry.title, state: state, size: entry.frame.size))
    }
    let elsewhere = server.filter {
      $0.layer == 0 && $0.alpha > 0 && $0.place == .other && isBigEnough($0.frame.size)
    }
    for entry in elsewhere {
      let attached =
        entry.title.isEmpty
        && elsewhere.contains {
          $0.id != entry.id && $0.frame != entry.frame
            && ($0.frame.contains(entry.frame)
              || (isStrip(entry.frame.size) && $0.frame.height > entry.frame.height
                && $0.frame.insetBy(dx: -1, dy: -1).intersects(entry.frame)))
        }
      guard !attached, seen.insert(entry.id).inserted else { continue }
      result.append(
        DockWindow(id: entry.id, title: entry.title, state: .elsewhere, size: entry.frame.size))
    }
    return result.sorted {
      let left = $0.state == .minimized
      let right = $1.state == .minimized
      return left != right ? right : $0.id < $1.id
    }
  }

  /// 又扁又宽的条（工具栏、标签栏这类附属窗口的形状）
  private static func isStrip(_ size: CGSize) -> Bool { size.width >= size.height * 4 }

  private static func isBigEnough(_ size: CGSize) -> Bool {
    size.width >= minimumSide && size.height >= minimumSide
  }
}
