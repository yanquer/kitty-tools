// 平铺文字水印：作为文字标注的可选元数据保存，屏幕与导出共用布局，不修改原图。

import AppKit

extension Annotation {
  /// 水印区域与文字样式分别保存，方向变换复用文字的仿射姿态，旧文字标注无需迁移。
  struct Watermark: Codable, Equatable, Sendable {
    var area: CGRect
    var angle: CGFloat = 30
    var opacity: CGFloat = 0.2
  }

  /// 在现有文字工具下创建可撤销水印，不占用原十种工具的数字键。
  static func watermark(in area: CGRect) -> Annotation {
    Annotation(
      shape: .text("仅供内部参考", origin: CGPoint(x: area.minX + 16, y: area.maxY - 16)),
      style: .init(color: .red, fontSize: 24), watermark: Watermark(area: area))
  }

  /// 围绕水印区域中心倾斜，命中与绘制都使用同一局部坐标。
  private var watermarkPose: CGAffineTransform {
    guard let watermark else { return .identity }
    return CGAffineTransform(translationX: watermark.area.midX, y: watermark.area.midY)
      .rotated(by: watermark.angle * .pi / 180)
  }

  /// 只生成当前脏区中的平铺位置；超大长图增加间距，使整张最多约 4096 个水印。
  private func watermarkTiles(in clip: CGRect) -> [CGRect] {
    guard let watermark, case .text(let text, _) = shape, !text.isEmpty else { return [] }
    let size = Self.textFrame(text, origin: .zero, size: style.textSize).size
    var step = CGSize(width: size.width + style.textSize * 2, height: size.height * 3)
    let reach = hypot(watermark.area.width, watermark.area.height)
    // ponytail: 4096 个平铺位置上限控制大长图开销，若需要密铺再改为图案单元渲染。
    let spacing = max(1, sqrt(reach * reach / max(step.width * step.height, 1) / 4000))
    step.width *= spacing
    step.height *= spacing
    let region = clip.intersection(watermark.area).applying(watermarkPose.inverted())
    guard !region.isNull, !region.isEmpty, step.width > 0, step.height > 0 else { return [] }
    let rows =
      Int(floor((region.minY - size.height) / step.height))...Int(ceil(region.maxY / step.height))
    let columns =
      Int(floor((region.minX - size.width) / step.width))...Int(ceil(region.maxX / step.width))
    var tiles: [CGRect] = []
    for row in rows {
      let stagger = row % 2 == 0 ? 0 : step.width / 2
      for column in columns {
        tiles.append(
          CGRect(
            x: CGFloat(column) * step.width + stagger, y: CGFloat(row) * step.height,
            width: size.width, height: size.height))
      }
    }
    return tiles
  }

  /// 用相同布局绘制水印；透明度只作用于水印，绝不把底图一起变淡。
  func drawWatermark(in context: CGContext) {
    guard let watermark, case .text(let text, _) = shape else { return }
    let tiles = watermarkTiles(in: context.boundingBoxOfClipPath)
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: watermark.area)
    context.setAlpha(min(max(watermark.opacity, 0.05), 1))
    context.concatenate(watermarkPose)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let value = NSAttributedString(
      string: text,
      attributes: [.font: Self.font(size: style.textSize), .foregroundColor: style.paint])
    for tile in tiles { value.draw(in: tile) }
  }

  /// 只有水印文字自身接收选中，平铺之间的空白留给其他标注和截图区域。
  func watermarkContains(_ point: CGPoint) -> Bool {
    guard let watermark, watermark.area.contains(point) else { return false }
    let local = point.applying(watermarkPose.inverted())
    let sample = CGRect(
      x: point.x - style.textSize * 2, y: point.y - style.textSize * 2, width: style.textSize * 4,
      height: style.textSize * 4)
    return watermarkTiles(in: sample).contains { $0.contains(local) }
  }
}
