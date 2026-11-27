// 长截图暂停时的实际像素预览。沿用冻结画布的绝对行号，只读取滚动视口需要的像素。

import AppKit

/// 只读的非激活面板，长截图 HUD 继续接收会话按键。
final class ScrollPixelPreviewPanel: NSPanel {
  private let scrollView = NSScrollView()
  private let canvas: ScrollPixelCanvas
  var onDismiss: () -> Void = {}

  /// 在 HUD 空间较大的一侧打开，初始大小限定在这块屏的可见区域。
  init(
    beside hud: CGRect, in visible: CGRect, width: Int, rows: Range<Int>, scale: CGFloat,
    image: @escaping (Range<Int>, Range<Int>) -> CGImage?, onRenderFailure: @escaping () -> Void
  ) {
    canvas = ScrollPixelCanvas(width: width, rows: rows, scale: scale, image: image)
    let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel]
    let frame = Self.placement(beside: hud, in: visible)
    super.init(
      contentRect: Self.contentRect(forFrameRect: frame, styleMask: style), styleMask: style,
      backing: .buffered, defer: false)
    title = "实际像素"
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    // 保留滚动条槽位，窗口第一次显示时视口尺寸不因滚动条换样式而跳动。
    scrollView.scrollerStyle = .legacy
    scrollView.autohidesScrollers = false
    scrollView.automaticallyAdjustsContentInsets = false
    let clip = CenteringClipView()
    clip.backgroundColor = .windowBackgroundColor
    scrollView.contentView = clip
    scrollView.documentView = canvas
    contentView = scrollView
    standardWindowButton(.closeButton)?.target = self
    standardWindowButton(.closeButton)?.action = #selector(dismissPreview)
    canvas.onRenderFailure = onRenderFailure
    canvas.onScaleChanged = { [weak self] scale in self?.changeScale(to: scale) }
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// 关闭按钮只交回预览生命周期，采集仍由原 HUD 管理。
  @objc private func dismissPreview() { onDismiss() }

  /// 按侧栏起始行跳转。侧栏跟随最新时，从对应的拼接端显示。
  func follow(from row: Int?, growingUp: Bool, column: CGFloat? = nil) {
    layoutIfNeeded()
    scrollView.tile()
    let clip = scrollView.contentView
    let visible = Int((clip.bounds.height * canvas.scale).rounded(.down))
    let range = ScrollStitcher.previewRange(
      rows: canvas.rows, visible: visible, from: row, growingUp: growingUp)
    var bounds = clip.bounds
    if let column { bounds.origin.x = column / canvas.scale }
    bounds.origin.y =
      canvas.bounds.height
      - CGFloat(range.lowerBound - canvas.rows.lowerBound) / canvas.scale - bounds.height
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  /// 视口顶部的绝对行号，包含向上拼接形成的负行号。
  var visibleRow: Int {
    let top = canvas.bounds.height - scrollView.documentVisibleRect.maxY
    return canvas.rows.lowerBound + max(0, Int((top * canvas.scale).rounded()))
  }

  /// 跨屏后按新屏幕倍率绘制，仍停在原先的行附近。
  private func changeScale(to scale: CGFloat) {
    guard canvas.scale != scale else { return }
    let row = visibleRow
    let column = scrollView.documentVisibleRect.minX * canvas.scale
    canvas.setScale(scale)
    follow(from: row, growingUp: false, column: column)
  }

  /// 预览与 HUD 并列，尺寸受可见区域限制，方便同时使用位置条和继续按钮。
  static func placement(beside hud: CGRect, in visible: CGRect) -> CGRect {
    let area = visible.insetBy(dx: 10, dy: 10)
    let left = max(0, min(hud.minX - 10, area.maxX) - area.minX)
    let right = max(0, area.maxX - max(hud.maxX + 10, area.minX))
    let opensLeft = left >= right
    let width = min(820, max(left, right))
    let height = min(620, area.height)
    let x = opensLeft ? area.minX + left - width : area.maxX - right
    let y = max(area.minY, min(hud.maxY, area.maxY) - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}

/// 用 AppKit 的滚动与脏区绘制浏览原始像素，画布从不保留一张完整长图。
private final class ScrollPixelCanvas: NSView {
  let rows: Range<Int>
  private let pixels: CGSize
  private let image: (Range<Int>, Range<Int>) -> CGImage?
  private(set) var scale: CGFloat
  var onScaleChanged: (CGFloat) -> Void = { _ in }
  var onRenderFailure: () -> Void = {}
  private var reportedFailure = false

  /// 保留总像素尺寸用于滚动和坐标转换，切片由会话提供。
  init(
    width: Int, rows: Range<Int>, scale: CGFloat,
    image: @escaping (Range<Int>, Range<Int>) -> CGImage?
  ) {
    self.rows = rows
    self.pixels = CGSize(width: width, height: rows.count)
    self.scale = scale
    self.image = image
    super.init(
      frame: CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(rows.count) / scale))
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("长截图，实际像素")
    setAccessibilityValue("\(width) × \(rows.count) 像素")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 每个源图像素对应当前显示器的一个物理像素。
  func setScale(_ scale: CGFloat) {
    self.scale = scale
    setFrameSize(CGSize(width: pixels.width / scale, height: pixels.height / scale))
    needsDisplay = true
  }

  /// 窗口移到不同倍率屏幕时保留当前查看行。
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if let window { onScaleChanged(window.backingScaleFactor) }
  }

  /// 复用长图标注的点和像素转换，只画实际可见的脏区。
  override func draw(_ dirtyRect: NSRect) {
    let dirty = dirtyRect.intersection(visibleRect)
    guard !dirty.isEmpty else { return }
    let rect = ScrollCanvas.pixelRect(of: dirty, in: bounds.size, pixels: pixels)
    guard !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
    let start = rows.lowerBound + Int(rect.minY)
    let rowRange = start..<(start + Int(rect.height))
    let columns = Int(rect.minX)..<Int(rect.maxX)
    guard let slice = image(rowRange, columns) else {
      if !reportedFailure {
        reportedFailure = true
        onRenderFailure()
      }
      return
    }
    context.interpolationQuality = .none
    context.draw(slice, in: ScrollCanvas.pointRect(of: rect, in: bounds.size, pixels: pixels))
  }
}
