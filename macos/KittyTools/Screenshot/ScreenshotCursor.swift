// 静态截图的鼠标指针：冻结前读取真实系统指针与热点，按各屏倍率合成，指针位置不随框选移动。

import AppKit
import OSLog

nonisolated struct ScreenshotCursor: Sendable {
  let image: CGImage
  /// 指针图像在 AppKit 全局坐标中的范围，原点在左下。
  let frame: CGRect

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// 在进入任何 await 和框选遮罩前记录系统指针，不用本应用的箭头猜测其他应用的指针。
  @MainActor static func capture() throws -> ScreenshotCursor {
    guard let cursor = NSCursor.currentSystem,
      let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      cursor.image.size.width > 0, cursor.image.size.height > 0
    else { throw Failure(message: "无法读取当前鼠标指针，请关闭「截图中显示鼠标指针」后重试") }
    return ScreenshotCursor(
      image: image,
      frame: rectangle(
        location: NSEvent.mouseLocation,
        size: cursor.image.size, hotSpot: cursor.hotSpot))
  }

  /// 热点从指针图像的左上角计点，转换为 AppKit 的左下角全局矩形。
  static func rectangle(location: CGPoint, size: CGSize, hotSpot: CGPoint) -> CGRect {
    CGRect(
      x: location.x - hotSpot.x, y: location.y - (size.height - hotSpot.y),
      width: size.width, height: size.height)
  }

  /// 与屏幕不相交时沿用原图；相交时在后台按真实像素倍率绘制，只保留合成图。
  @concurrent func render(over background: CGImage, screen: CGRect) async throws -> CGImage {
    guard screen.width.isFinite, screen.height.isFinite, screen.width > 0, screen.height > 0
    else { throw Failure(message: "屏幕尺寸无效，无法合成鼠标指针") }
    guard frame.intersects(screen) else { return background }
    // ponytail: 可选指针合成最多处理约 4000 万像素，与剪贴板图片预算一致；更大屏幕可关闭此选项截图。
    guard screen.width > 0, screen.height > 0,
      Double(background.width) * Double(background.height) <= Double(ImageStore.maxPixels),
      let context = CGContext(
        data: nil, width: background.width, height: background.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: background.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(message: "图片过大或无法分配指针画布，请关闭「截图中显示鼠标指针」后重试") }
    context.draw(
      background, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
    let sx = CGFloat(background.width) / screen.width
    let sy = CGFloat(background.height) / screen.height
    let rect = CGRect(
      x: (frame.minX - screen.minX) * sx, y: (frame.minY - screen.minY) * sy,
      width: frame.width * sx, height: frame.height * sy)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    guard let result = context.makeImage() else { throw Failure(message: "鼠标指针合成失败，请重试") }
    Log.capture.debug("静态截图指针已合成 width=\(background.width) height=\(background.height)")
    return result
  }
}
