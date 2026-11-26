// 截图历史的大图核对界面。窗口内切换与缩放，只绘制当前可见的图像像素。

import AppKit
import SwiftUI

/// 展示当前截图、当前位置和前后切换，可按图像实际像素查看长截图。
struct ShotHistoryPreviewView: View {
  let preview: ShotHistoryPreview
  @State private var actualPixels = false
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Label("截图预览", systemImage: "photo.on.rectangle").font(.headline)
        if let item = preview.item {
          Text(ShotHistoryModel.caption(item)).font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button(
          actualPixels ? "适合窗口" : "实际像素",
          systemImage: actualPixels ? "arrow.down.right.and.arrow.up.left" : "magnifyingglass"
        ) {
          actualPixels.toggle()
        }
        .disabled(preview.image == nil)
        Button("关闭预览", systemImage: "xmark", action: preview.close)
          .labelStyle(.iconOnly).buttonStyle(.plain).help("关闭预览（Esc 或空格）")
      }
      .padding(16)
      Hairline()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.25))
      Hairline()
      HStack(spacing: 14) {
        Button("上一张", systemImage: "chevron.left") { preview.move(by: -1) }
          .help("上一张（←）").disabled(!preview.canMoveBack)
        Text("第 \((preview.index ?? 0) + 1) / \(preview.count) 张")
          .monospacedDigit().foregroundStyle(.secondary)
        Button("下一张", systemImage: "chevron.right") { preview.move(by: 1) }
          .help("下一张（→）").disabled(!preview.canMoveForward)
      }
      .frame(maxWidth: .infinity).padding(14)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("截图历史大图预览")
  }

  /// 对加载和真实失败给出各自的反馈，失败时还能跳到其它结果。
  @ViewBuilder private var content: some View {
    if let image = preview.image {
      GeometryReader { proxy in
        let scale =
          actualPixels
          ? 1 / max(displayScale, 1)
          : min(
            1, proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
        ShotHistoryPreviewImage(
          image: image,
          size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale),
          actualPixels: actualPixels)
      }
      .padding(16)
    } else if let error = preview.error {
      EmptyState(symbol: "photo.badge.exclamationmark", title: "无法预览截图") {
        Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("重试", action: preview.retry)
      }.padding(20)
    } else {
      ProgressView("正在读取截图…")
    }
  }
}

/// 只读图片画布通过原生滚动显示实际像素，长图不会整张铺成一个纹理。
private struct ShotHistoryPreviewImage: NSViewRepresentable {
  let image: CGImage
  let size: CGSize
  let actualPixels: Bool

  /// 使用现有居中夹层，图像比视口小的时候保留对称留白。
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.scrollerStyle = .overlay
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let clip = CenteringClipView()
    clip.drawsBackground = false
    scroll.contentView = clip
    scroll.documentView = ShotHistoryPreviewCanvas()
    return scroll
  }

  /// 只在图片或尺寸变化时重置位置，实际像素从图的顶部开始浏览。
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let canvas = scroll.documentView as? ShotHistoryPreviewCanvas,
      canvas.image !== image || canvas.bounds.size != size || canvas.actualPixels != actualPixels
    else { return }
    canvas.image = image
    canvas.actualPixels = actualPixels
    canvas.setFrameSize(size)
    canvas.needsDisplay = true
    let clip = scroll.contentView
    var viewport = clip.bounds
    viewport.origin = CGPoint(x: 0, y: max(0, size.height - viewport.height))
    clip.scroll(to: clip.constrainBoundsRect(viewport).origin)
    scroll.reflectScrolledClipView(clip)
  }
}

/// 复用长图标注的脏区坐标换算，只绘制滚动窗口实际需要的像素。
private final class ShotHistoryPreviewCanvas: NSView {
  var image: CGImage?
  var actualPixels = false

  /// 绘制局部图像，实际像素模式保持一比一像素采样。
  override func draw(_ dirtyRect: NSRect) {
    guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
    let size = CGSize(width: image.width, height: image.height)
    let pixels = ScrollCanvas.pixelRect(of: dirtyRect, in: bounds.size, pixels: size)
    guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels) else {
      return
    }
    context.interpolationQuality = actualPixels ? .none : .medium
    context.draw(crop, in: ScrollCanvas.pointRect(of: pixels, in: bounds.size, pixels: size))
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .image }
  override func accessibilityLabel() -> String? { "截图成品" }
}
