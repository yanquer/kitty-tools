// 尺寸线与对象橡皮擦：共用屏幕显示、导出和几何命中，擦除只删除矢量标注。

import AppKit

extension Annotation {
  /// 说明文字属于线条本体；旧数据缺省为无说明，不引入悬空的对象引用。
  struct Caption: Codable, Equatable, Sendable {
    var text: String
    var style: Style
    var orientation: ImageTransform.Pose?
  }

  var acceptsCaption: Bool { (tool == .arrow || tool == .line) && !isDimension }

  /// 关联说明使用正向输入与绘制，跟随线条中点而不是持久化绝对位置。
  var captionStyle: Style {
    if let caption { return caption.style }
    var value = style
    value.fontSize = 13
    value.option = 2
    return value
  }

  /// 线条的几何中点，位置调整后即时重新计算，不保存易失效的绝对文字位置。
  private var captionCenter: CGPoint {
    switch shape {
    case .arrow(let from, let to, let bend), .line(let from, let to, let bend):
      return Self.curveMidpoint(from: from, to: to, bend: bend)
    default: return .zero
    }
  }

  /// 原生输入框保持正向；图像转向后的文字仍保存自己的方向。
  var captionOrigin: CGPoint {
    guard let label = captionAnnotation else {
      return CGPoint(x: captionCenter.x, y: captionCenter.y + 28)
    }
    if caption?.orientation != nil { return CGPoint(x: label.bounds.minX, y: label.bounds.maxY) }
    if case .text(_, let origin) = label.shape {
      return origin.applying(label.textTransform?.affine ?? .identity)
    }
    return .zero
  }

  /// 说明文字是线条的一部分；像素变换和矢量绘制保持同一局部方向及相对位置。
  var captionAnnotation: Annotation? {
    guard acceptsCaption, let caption, !caption.text.isEmpty else { return nil }
    let value = caption.style
    let box = Self.textFrame(caption.text, origin: .zero, size: value.textSize)
    let gap = max(14, value.textSize / 3 + style.weight.lineWidth * 4)
    var pose = caption.orientation?.affine ?? .identity
    pose.tx = captionCenter.x
    pose.ty = captionCenter.y
    return Annotation(
      id: id, shape: .text(caption.text, origin: CGPoint(x: -box.width / 2, y: gap + box.height)),
      style: value, textTransform: ImageTransform.Pose(pose))
  }

  var isDimension: Bool { tool == .line && style.option == 1 }

  /// 为尺寸文字预留有界区域，包含 4000 万像素范围内的读数，防止局部重画裁掉文字。
  var dimensionBounds: CGRect {
    guard case .line(let from, let to, _) = shape else { return .zero }
    return CGRect(x: (from.x + to.x) / 2 - 60, y: (from.y + to.y) / 2 - 15, width: 120, height: 30)
  }

  /// 图像真实像素长度，显示缩放、视网膜倍率和导出使用同一口径。
  func dimensionLabel(imageSize: CGSize, viewSize: CGSize) -> String {
    guard case .line(let from, let to, _) = shape, viewSize.width > 0, viewSize.height > 0 else {
      return "尺寸无效"
    }
    let length = hypot(
      (to.x - from.x) * imageSize.width / viewSize.width,
      (to.y - from.y) * imageSize.height / viewSize.height)
    guard length.isFinite, length >= 0, length < CGFloat(Int.max) else { return "尺寸无效" }
    return "\(Int(length.rounded())) px"
  }

  /// 端点刻度与中间读数一起绘制，文字保持正向，避免斜线上的倒置数字。
  func drawDimension(in context: CGContext, imageSize: CGSize, viewSize: CGSize) {
    context.saveGState()
    defer { context.restoreGState() }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    guard case .line(let from, let to, _) = shape else { return }
    let distance = max(hypot(to.x - from.x, to.y - from.y), 0.001)
    let normal = CGPoint(x: -(to.y - from.y) / distance * 5, y: (to.x - from.x) / distance * 5)
    context.setStrokeColor(style.paint.cgColor)
    context.setLineWidth(style.weight.lineWidth)
    context.move(to: from)
    context.addLine(to: to)
    for end in [from, to] {
      context.move(to: CGPoint(x: end.x - normal.x, y: end.y - normal.y))
      context.addLine(to: CGPoint(x: end.x + normal.x, y: end.y + normal.y))
    }
    context.strokePath()
    let label = NSAttributedString(
      string: dimensionLabel(imageSize: imageSize, viewSize: viewSize),
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: style.ink,
      ])
    let size = label.size()
    let frame = CGRect(
      x: dimensionBounds.midX - size.width / 2, y: dimensionBounds.midY - size.height / 2,
      width: size.width, height: size.height)
    context.setFillColor(style.paint.cgColor)
    context.addPath(
      CGPath(
        roundedRect: frame.insetBy(dx: -5, dy: -3), cornerWidth: 4, cornerHeight: 4, transform: nil)
    )
    context.fillPath()
    label.draw(in: frame)
  }

  /// 橡皮笔画与对象轮廓求交，快速拖动跨过细线也能命中，不以鼠标采样点代替整段轨迹。
  func intersectsEraser(from: CGPoint, to: CGPoint, radius: CGFloat = 4) -> Bool {
    if captionAnnotation?.intersectsEraser(from: from, to: to, radius: radius) == true {
      return true
    }
    if let pose = textTransform {
      return untransformedText.intersectsEraser(
        from: from.applying(pose.affine.inverted()), to: to.applying(pose.affine.inverted()),
        radius: radius)
    }
    let area = CGRect(
      x: min(from.x, to.x), y: min(from.y, to.y), width: max(abs(from.x - to.x), 0.01),
      height: max(abs(from.y - to.y), 0.01)
    ).insetBy(dx: -radius, dy: -radius)
    guard bounds.intersects(area) else { return false }
    let stroke = CGMutablePath()
    stroke.move(to: from)
    stroke.addLine(to: to == from ? CGPoint(x: to.x + 0.01, y: to.y) : to)
    let brush = stroke.copy(
      strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let path = eraserPath
    return !brush.intersection(path).isEmpty
  }

  /// 构造当前可见对象的擦除轮廓，文字、序号与打码按完整对象处理。
  private var eraserPath: CGPath {
    let path = CGMutablePath()
    var width = style.weight.lineWidth
    switch shape {
    case .rectangle(let rect):
      path.addRect(rect)
      if style.option == 1 { return path }
    case .ellipse(let rect):
      path.addEllipse(in: rect)
      if style.option == 1 { return path }
    case .spotlight(let rect): path.addRect(rect)
    case .line(let from, let to, let bend), .arrow(let from, let to, let bend):
      path.move(to: from)
      if bend != .zero && !isDimension {
        path.addQuadCurve(to: to, control: Self.curveControl(from: from, to: to, bend: bend))
      } else {
        path.addLine(to: to)
      }
      if isDimension {
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
          .union(CGPath(rect: dimensionBounds, transform: nil))
      }
      if tool == .arrow,
        let arrow = Self.arrowInk(
          from: from, to: to, width: width, bend: bend, double: style.option == 1)
      {
        return arrow
      }
    case .pen(let points):
      return Self.penPath(points).copy(
        strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    case .highlighter(let from, let to):
      path.move(to: from)
      path.addLine(to: to)
      width = style.weight.highlighterHeight
    case .text, .counter, .mosaic: return CGPath(rect: bounds, transform: nil)
    }
    return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
  }
}
