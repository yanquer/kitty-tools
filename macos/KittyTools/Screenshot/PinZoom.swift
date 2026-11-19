// 钉图局部放大的纯几何：固定窗口尺寸，围绕指针缩放、拖动取景，始终保留完整原图用于输出。

import CoreGraphics

nonisolated struct PinZoom: Equatable {
  var isEnabled = false
  private(set) var magnification: CGFloat = 1
  private(set) var center = CGPoint(x: 0.5, y: 0.5)

  /// 归一化取景范围使用左下原点，与 AppKit 钉图坐标一致。
  var viewport: CGRect {
    let side = 1 / magnification
    return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
  }

  /// 切换查看模式时恢复整图，不改变窗口位置和大小。
  mutating func toggle() {
    isEnabled.toggle()
    magnification = 1
    center = CGPoint(x: 0.5, y: 0.5)
  }

  /// 围绕鼠标位置缩放，保持该点对应的图片内容不移动，倍率限定在 1–8 倍。
  mutating func zoom(by factor: CGFloat, at anchor: CGPoint) {
    guard isEnabled, factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite else {
      return
    }
    let previous = viewport
    let anchor = CGPoint(x: min(max(anchor.x, 0), 1), y: min(max(anchor.y, 0), 1))
    magnification = min(max(magnification * factor, 1), 8)
    let side = 1 / magnification
    center = Self.clamped(
      CGPoint(
        x: previous.minX + anchor.x * previous.width + (0.5 - anchor.x) * side,
        y: previous.minY + anchor.y * previous.height + (0.5 - anchor.y) * side), side: side)
  }

  /// 按拖动起点的中心计算平移，图片跟随鼠标移动，取景不会越出原图。
  mutating func pan(from origin: CGPoint, by delta: CGSize, viewSize: CGSize) {
    guard isEnabled, viewSize.width > 0, viewSize.height > 0,
      delta.width.isFinite, delta.height.isFinite
    else { return }
    center = Self.clamped(
      CGPoint(
        x: origin.x - delta.width / viewSize.width / magnification,
        y: origin.y - delta.height / viewSize.height / magnification), side: 1 / magnification)
  }

  /// 将取景中心夹在有效图像内，边缘保持完整覆盖。
  private static func clamped(_ point: CGPoint, side: CGFloat) -> CGPoint {
    CGPoint(
      x: min(max(point.x, side / 2), 1 - side / 2),
      y: min(max(point.y, side / 2), 1 - side / 2))
  }
}
