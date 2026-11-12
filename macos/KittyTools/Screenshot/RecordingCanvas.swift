// 录屏中的透明画板：复用截图标注层，叠加跟随焦点与短暂激光轨迹。普通 NSPanel 永不当 key，操作模式点穿。

import AppKit
import OSLog

/// 一次录制的画板与鼠标监听，窗口在开流前进入录制过滤器，停止时统一释放。
final class RecordingCanvas {
  let panel: NSPanel
  let view: RecordingDrawingView
  private(set) var state = RecordingTools()
  var onChange: (RecordingTools) -> Void = { _ in }
  /// 沿用录制会话的提示通道，测试可收集拒绝原因而不显示真实提示。
  var onNotice: (String) -> Void = { _ in }
  /// 用户操作工具栏时隐藏焦点，避免工具栏位置在成片中出现光圈或暗层。
  var excludedFrames: () -> [CGRect] = { [] }
  private var monitors: [Any] = []
  private let focus = CAShapeLayer()
  private let laser = CALayer()
  private var previousLaserPoint: CGPoint?
  private var lastLaserTime: CFTimeInterval = 0
  private var isPresented = false
  private let sessionID = UUID().uuidString

  /// 只建透明窗口，不上屏、不安装监听；位图仅用于满足 AnnotationCanvas 的冻结帧参数，不采集屏幕。
  init?(region: CGRect) {
    guard
      let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let image = context.makeImage()
    else {
      Log.record.error("录屏画板初始化失败：无法分配透明占位图")
      return nil
    }
    view = RecordingDrawingView(image: image)
    panel = NSPanel(
      contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    // 与录制 HUD 同为状态栏层级，显式排在它下面；截图冻结帧按层级排除画板。
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = true
    panel.acceptsMouseMovedEvents = true
    panel.contentView = view
    view.frame = CGRect(origin: .zero, size: panel.frame.size)
    view.autoresizingMask = [.width, .height]
    focus.fillRule = .evenOdd
    focus.contentsScale = panel.backingScaleFactor
    laser.zPosition = 3
    view.layer?.addSublayer(focus)
    view.layer?.addSublayer(laser)
    view.onMouse = { [weak self] in self?.handle($0) }
    view.setAccessibilityLabel("录屏画板")
    view.setAccessibilityHelp("使用录屏工具箱切换画笔或返回操作窗口")
  }

  var windowID: CGWindowID? { ScreenCapture.windowID(panel.windowNumber) }
  var laserCount: Int { laser.sublayers?.count ?? 0 }
  var focusPath: CGPath? { focus.path }

  /// 开流前显示空画板，保证窗口号能进入过滤器；未开启工具时不监听鼠标。
  func present(below windowNumber: Int? = nil) {
    isPresented = true
    if let windowNumber {
      panel.order(.below, relativeTo: windowNumber)
    } else {
      panel.orderFrontRegardless()
    }
    Log.record.notice(
      "录屏画板就绪 session=\(self.sessionID, privacy: .public) window=\(self.panel.windowNumber)")
    syncMonitors()
  }

  /// 应用工具栏动作，同步点穿状态与鼠标监听，笔迹始终由截图标注层显示。
  func apply(_ action: RecordingTools.Action) {
    let wasDrawing = state.isDrawing
    state.apply(action)
    panel.ignoresMouseEvents = !state.isDrawing
    // 完全透明的像素会被窗口系统点穿，画图期间垫一个最低可见度的命中底。
    view.layer?.backgroundColor = state.isDrawing ? CGColor(gray: 0, alpha: 1 / 255) : nil
    view.drawingEnabled = state.isDrawing
    renderAnnotations()
    previousLaserPoint = nil
    if state.mode != .laser { clearLaser() }
    syncMonitors()
    if isPresented { updatePointer(at: NSEvent.mouseLocation, animated: true) }
    if wasDrawing != state.isDrawing {
      Log.record.notice(
        "录屏画板交互变化 session=\(self.sessionID, privacy: .public) drawing=\(self.state.isDrawing)")
    }
    onChange(state)
  }

  /// 原子收尾：先停止监听、还原点穿，再收窗口并释放笔迹和图层，重复调用安全。
  func close() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    panel.ignoresMouseEvents = true
    panel.orderOut(nil)
    view.onMouse = { _ in }
    onNotice = { _ in }
    onChange = { _ in }
    excludedFrames = { [] }
    state = RecordingTools()
    renderAnnotations()
    focus.path = nil
    clearLaser()
    if isPresented {
      Log.record.notice("录屏画板结束 session=\(self.sessionID, privacy: .public)")
    }
    isPresented = false
  }

  /// 只在跟随焦点或激光笔启用时装被动监听，不吞掉原窗口输入，也不要求辅助功能授权。
  private func syncMonitors() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    guard isPresented, state.focus != .off || state.mode == .laser else { return }
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.updatePointer(at: NSEvent.mouseLocation, animated: true) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated { self?.updatePointer(at: NSEvent.mouseLocation, animated: true) }
      return event
    }
    monitors = [global, local].compactMap { $0 }
    if monitors.count != 2 {
      Log.record.error(
        "录屏画板鼠标监听未全部建立 session=\(self.sessionID, privacy: .public) installed=\(self.monitors.count)"
      )
    }
  }

  /// 更新轻量图层路径，不重画整块屏幕；指针离开录制区域或进入工具栏时隐藏焦点。
  func updatePointer(at global: CGPoint, animated: Bool) {
    let point = InputOverlay.local(global, in: panel.frame)
    let visible = panel.frame.contains(global) && !excludedFrames().contains { $0.contains(global) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    focus.path = nil
    if visible, state.focus != .off {
      let circle = CGRect(
        x: point.x - state.radius, y: point.y - state.radius,
        width: state.radius * 2, height: state.radius * 2)
      let path = CGMutablePath()
      if state.focus == .spotlight { path.addRect(view.bounds) }
      path.addEllipse(in: circle)
      focus.path = path
      focus.fillColor =
        state.focus == .spotlight
        ? CGColor(gray: 0, alpha: 0.5) : state.style.color.color.withAlphaComponent(0.24).cgColor
      focus.strokeColor = state.focus == .halo ? state.style.color.color.cgColor : nil
      focus.lineWidth = 2
    }
    CATransaction.commit()
    guard visible, state.mode == .laser else {
      previousLaserPoint = nil
      return
    }
    addLaser(to: point, at: CACurrentMediaTime(), animated: animated)
  }

  /// 激光轨迹按短线段独立淡出，最多留 96 段；空闲或离开选区后的新轨迹不连回旧位置。
  func addLaser(to point: CGPoint, at now: CFTimeInterval, animated: Bool) {
    let elapsed = now - lastLaserTime
    let from = elapsed >= 0 && elapsed < 0.12 ? (previousLaserPoint ?? point) : point
    previousLaserPoint = point
    lastLaserTime = now
    let mark = CAShapeLayer()
    let path = CGMutablePath()
    path.move(to: from)
    path.addLine(to: from == point ? CGPoint(x: point.x + 0.1, y: point.y) : point)
    mark.path = path
    mark.strokeColor = state.style.color.color.cgColor
    mark.lineWidth = state.style.weight.lineWidth + 2
    mark.lineCap = .round
    mark.fillColor = nil
    while (laser.sublayers?.count ?? 0) >= 96 { laser.sublayers?.first?.removeFromSuperlayer() }
    laser.addSublayer(mark)
    guard animated else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { mark.removeFromSuperlayer() }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1
    fade.toValue = 0
    fade.duration = Style.reduceMotion ? 0.2 : 0.8
    mark.opacity = 0
    mark.add(fade, forKey: "fade")
    CATransaction.commit()
  }

  /// 清除尚未消失的激光，切换工具与结束录制时不保留动画。
  private func clearLaser() {
    for mark in laser.sublayers ?? [] { mark.removeFromSuperlayer() }
    previousLaserPoint = nil
  }

  /// 鼠标手势只在画图模式下接收；超出条数上限时保留既有笔迹并给出明确提示。
  private func handle(_ event: NSEvent) {
    guard state.isDrawing else { return }
    let point = view.convert(event.locationInWindow, from: nil)
    let constrained = event.modifierFlags.contains(.shift)
    switch event.type {
    case .leftMouseDown:
      guard state.begin(at: point) else {
        Log.record.notice(
          "录屏画板拒绝新笔迹 session=\(self.sessionID, privacy: .public) count=\(self.state.annotations.count) limit=\(RecordingTools.maximumAnnotations)"
        )
        onNotice("画板已达 256 条标注，请撤销或清空后继续")
        return
      }
    case .leftMouseDragged: state.update(to: point, constrained: constrained)
    case .leftMouseUp:
      state.finish(at: point, constrained: constrained)
      onChange(state)
    default: return
    }
    renderAnnotations()
    updatePointer(at: NSEvent.mouseLocation, animated: true)
  }

  /// 显示和最终录入共用截图的 AnnotationCanvas，不另写一套形状绘制。
  private func renderAnnotations() {
    view.ink.annotations = state.annotations + (state.draft.map { [$0] } ?? [])
    view.ink.isHidden = view.ink.annotations.isEmpty
  }
}

/// 仅负责鼠标手势的透明根视图，键盘保留在原 App，Esc 由现有临时 Carbon 热键处理。
final class RecordingDrawingView: NSView {
  let ink: AnnotationCanvas
  var onMouse: (NSEvent) -> Void = { _ in }
  var drawingEnabled = false

  /// 复用截图标注层，尺寸跟随录制区域，不接入截图的选区或冻结画面交互。
  init(image: CGImage) {
    ink = AnnotationCanvas(image: image)
    super.init(frame: .zero)
    wantsLayer = true
    ink.wantsLayer = true
    // 未画标注的录制不显示绘制层，避免为整屏空画布分配 backing store。
    ink.isHidden = true
    ink.layer?.zPosition = 1
    ink.autoresizingMask = [.width, .height]
    addSubview(ink)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 空白区域也由根视图接收，操作模式则通过窗口的 ignoresMouseEvents 点穿。
  override func hitTest(_ point: NSPoint) -> NSView? { drawingEnabled ? self : nil }
  /// 非激活窗口中的第一下点击直接起笔。
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// 左键按下开始笔迹。
  override func mouseDown(with event: NSEvent) { onMouse(event) }
  /// 拖动只更新本次笔迹。
  override func mouseDragged(with event: NSEvent) { onMouse(event) }
  /// 松开提交笔迹。
  override func mouseUp(with event: NSEvent) { onMouse(event) }
}
