// 录屏讲解工具的会话状态：工具、鼠标焦点、笔迹与撤销。仅在本次录制中保留，不写截图样式或用户偏好。

import AppKit

/// 录屏画板的纯状态；标注形状与绘制样式沿用截图的 Annotation。
struct RecordingTools {
  /// 操作模式点穿画板，激光笔留下短暂轨迹，其余工具保存笔迹。
  enum Mode: Int, CaseIterable {
    case pointer, pen, highlighter, arrow, rectangle, ellipse, laser

    var title: String {
      switch self {
      case .pointer: "操作窗口"
      case .laser: "激光笔"
      default: annotationTool?.title ?? "画笔"
      }
    }

    var symbol: String {
      switch self {
      case .pointer: "cursorarrow"
      case .laser: "laser.burst"
      default: annotationTool?.symbol ?? "scribble.variable"
      }
    }

    var annotationTool: Annotation.Tool? {
      switch self {
      case .pointer, .laser: nil
      case .pen: .pen
      case .highlighter: .highlighter
      case .arrow: .arrow
      case .rectangle: .rectangle
      case .ellipse: .ellipse
      }
    }
  }

  /// 鼠标焦点独立于画图模式，操作原窗口时也能跟随。
  enum Focus: Int, CaseIterable {
    case off, halo, spotlight

    var title: String {
      switch self {
      case .off: "关闭焦点"
      case .halo: "跟随光圈"
      case .spotlight: "聚光灯"
      }
    }

    var symbol: String {
      switch self {
      case .off: "cursorarrow"
      case .halo: "cursorarrow.rays"
      case .spotlight: "circle.lefthalf.filled"
      }
    }
  }

  /// 工具栏操作统一交给画板，再同步显示状态。
  enum Action {
    case mode(Mode)
    case focus(Focus)
    case color(Annotation.Palette)
    case weight(Annotation.Weight)
    case radius(Annotation.Weight)
    case undo, clear, close
  }

  // ponytail: 单次录制最多 256 条标注，每条画笔最多 4096 个采样点；长笔迹逐次降采样，避免持续画图无界占用内存。
  static let maximumAnnotations = 256
  static let maximumPoints = 4096
  var mode = Mode.pointer
  var focus = Focus.off
  var style = Annotation.Style(color: .red)
  var focusSize = Annotation.Weight.medium
  private(set) var annotations: [Annotation] = []
  private(set) var draft: Annotation?
  private var start: CGPoint?
  private var points: [CGPoint] = []

  var isDrawing: Bool { mode != .pointer }
  var radius: CGFloat { [CGFloat(28), 48, 80][focusSize.rawValue] }
  var canUndo: Bool { !annotations.isEmpty }

  /// 气泡窗口保留的阴影边与圆弧箭头高度。
  static let bubbleMargin: CGFloat = 16
  static let bubbleArrowHeight: CGFloat = 8
  static let bubbleArrowHalfWidth: CGFloat = 12

  /// 气泡指示尾的肩部与尖端均以相切曲线连接，末端留出较宽的圆弧。
  static func bubbleTip(at origin: CGPoint, pointsUp: Bool) -> CGPath {
    let x = origin.x
    let y = origin.y
    let direction: CGFloat = pointsUp ? 1 : -1
    let end = y + direction * bubbleArrowHeight
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x - bubbleArrowHalfWidth, y: y))
    path.addCurve(
      to: CGPoint(x: x, y: end),
      control1: CGPoint(x: x - 7, y: y), control2: CGPoint(x: x - 5, y: end))
    path.addCurve(
      to: CGPoint(x: x + bubbleArrowHalfWidth, y: y),
      control1: CGPoint(x: x + 5, y: end), control2: CGPoint(x: x + 7, y: y))
    path.closeSubpath()
    return path
  }

  /// 气泡的屏幕位置、箭头方向和箭头在窗口内的横坐标。
  struct BubblePlacement: Equatable {
    let frame: CGRect
    let pointsUp: Bool
    let tipX: CGFloat
  }

  /// 参数气泡优先位于触发控件上方，空间不足或遮挡录制控制条时翻到下方。
  static func bubble(size: CGSize, anchor: CGRect, visible: CGRect, avoiding: CGRect? = nil)
    -> BubblePlacement
  {
    let margin = bubbleMargin
    let arrow = bubbleArrowHeight
    let windowSize = CGSize(
      width: size.width + margin * 2, height: size.height + arrow + margin * 2)
    let below = anchor.minY - 4 - size.height - arrow - margin
    let above = anchor.maxY + 4 - margin
    let x = min(
      max(anchor.midX - windowSize.width / 2, visible.minX),
      max(visible.minX, visible.maxX - windowSize.width))
    let coversControl =
      avoiding.map {
        CGRect(x: x, y: above, width: windowSize.width, height: windowSize.height).intersects($0)
      } ?? false
    let pointsUp = above + windowSize.height > visible.maxY || coversControl
    let y = min(
      max(pointsUp ? below : above, visible.minY),
      max(visible.minY, visible.maxY - windowSize.height))
    let frame = CGRect(origin: CGPoint(x: x, y: y), size: windowSize)
    let inset = margin + 10 + bubbleArrowHalfWidth
    let tipX = min(max(anchor.midX - x, inset), windowSize.width - inset)
    return BubblePlacement(frame: frame, pointsUp: pointsUp, tipX: tipX)
  }

  /// 变更工具或样式时取消未完成的笔迹；返回操作模式仍保留已经画好的标注。
  mutating func apply(_ action: Action) {
    cancelStroke()
    switch action {
    case .mode(let mode): self.mode = mode
    case .focus(let focus): self.focus = focus
    case .color(let color): style.color = color
    case .weight(let weight): style.weight = weight
    case .radius(let size): focusSize = size
    case .undo: _ = annotations.popLast()
    case .clear: annotations = []
    case .close: mode = .pointer
    }
  }

  /// 开始一笔；满额时明确拒绝，调用方给出提示，不丢弃已有标注。
  mutating func begin(at point: CGPoint) -> Bool {
    guard isDrawing else { return false }
    guard mode == .laser || annotations.count < Self.maximumAnnotations else { return false }
    cancelStroke()
    start = point
    points = [point]
    update(to: point, constrained: false)
    return true
  }

  /// 更新笔迹，复用截图的形状约束；密集采样过滤近点，超出上限后保留首尾并降采样。
  mutating func update(to point: CGPoint, constrained: Bool) {
    guard let start, let tool = mode.annotationTool else { return }
    let shape: Annotation.Shape?
    if mode == .pen {
      if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 {
        if points.count >= Self.maximumPoints {
          points = points.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
        }
        points.append(point)
      }
      shape = .pen(points.count == 1 ? [start, start] : points)
    } else {
      shape = Annotation.shape(for: tool, from: start, to: point, constrained: constrained)
    }
    draft = shape.map { Annotation(shape: $0, style: style) }
  }

  /// 松开后提交一条有效笔迹，点一下画笔也留下可见的圆点。
  mutating func finish(at point: CGPoint, constrained: Bool) {
    guard let start else { return }
    update(to: point, constrained: constrained)
    if let draft, mode == .pen || hypot(point.x - start.x, point.y - start.y) >= 2 {
      annotations.append(draft)
    }
    cancelStroke()
  }

  /// 取消当前手势，防止切换工具或收起时把半条笔迹提交到下一次操作。
  mutating func cancelStroke() {
    start = nil
    points = []
    draft = nil
  }

  /// 初次显示贴在录制控制条附近；拖过后采用本次记住的位置，并夹回可见区。
  static func frame(size: CGSize, anchor: CGRect, visible: CGRect, dragged: CGPoint? = nil)
    -> CGRect
  {
    let y =
      anchor.maxY + 8 + size.height <= visible.maxY
      ? anchor.maxY + 8 : anchor.minY - size.height - 8
    let proposed = dragged ?? CGPoint(x: anchor.maxX - size.width, y: y)
    return CGRect(
      x: min(max(proposed.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
      y: min(max(proposed.y, visible.minY), max(visible.minY, visible.maxY - size.height)),
      width: size.width, height: size.height)
  }
}
