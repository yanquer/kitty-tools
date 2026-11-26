// 识字结果的原图预览。按 Vision 行框绘制定位，在适配窗口和实际像素间切换。

import AppKit
import SwiftUI

/// 原图、行框和目标滚动偏移共用同一套坐标换算。
struct RecognitionImageLayout: Equatable {
  let viewport: CGSize
  let document: CGSize
  let image: CGRect

  /// 适配模式整图居中。实际像素把一个源图像素对应到一个屏幕像素。
  init(pixels: CGSize, viewport: CGSize, displayScale: CGFloat, actualPixels: Bool) {
    self.viewport = viewport
    let scale =
      actualPixels
      ? 1 / max(displayScale, 1)
      : min(viewport.width / pixels.width, viewport.height / pixels.height)
    let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
    document = CGSize(
      width: max(size.width, viewport.width), height: max(size.height, viewport.height))
    image = CGRect(
      x: (document.width - size.width) / 2, y: (document.height - size.height) / 2,
      width: size.width, height: size.height)
  }

  /// 将 Vision 左下原点的归一化框换到预览左上原点的文档坐标。
  func frame(for box: CGRect) -> CGRect {
    CGRect(
      x: image.minX + box.minX * image.width, y: image.minY + (1 - box.maxY) * image.height,
      width: box.width * image.width, height: box.height * image.height)
  }

  /// 让选中行居于视口中心，首尾贴边时夹到可滚动范围。
  func offset(for box: CGRect?) -> CGPoint {
    guard let box else { return .zero }
    let frame = frame(for: box)
    return CGPoint(
      x: min(max(0, frame.midX - viewport.width / 2), document.width - viewport.width),
      y: min(max(0, frame.midY - viewport.height / 2), document.height - viewport.height))
  }
}

/// 保留整图上下文，选中文字后按当前倍率定位到对应原图行。
struct RecognitionImagePreview: View {
  let image: CGImage
  let location: RecognitionLocation?
  @Environment(\.displayScale) private var displayScale
  @State private var actualPixels = false
  @State private var scrollPosition = ScrollPosition()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(location == nil ? "原图" : "已定位")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
          .help("在右侧点选识别文字，原图会标出对应行")
        Spacer(minLength: 8)
        Button(
          actualPixels ? "适合窗口" : "实际像素",
          systemImage: actualPixels ? "arrow.down.right.and.arrow.up.left" : "magnifyingglass"
        ) {
          actualPixels.toggle()
        }
        .controlSize(.small)
        .help(actualPixels ? "显示整张原图" : "按原图像素查看，可滚动到其它位置")
      }
      GeometryReader { proxy in
        let layout = RecognitionImageLayout(
          pixels: CGSize(width: image.width, height: image.height), viewport: proxy.size,
          displayScale: displayScale, actualPixels: actualPixels)
        ScrollView([.horizontal, .vertical]) {
          document(layout)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: layout, initial: true) { _, value in
          scrollPosition.scrollTo(point: value.offset(for: location?.box))
        }
        .onChange(of: location) { _, value in
          if let value { scrollPosition.scrollTo(point: layout.offset(for: value.box)) }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.quaternary.opacity(0.3))
  }

  /// 原图只绘制一份，细描边标出识别框而不遮住小字。
  private func document(_ layout: RecognitionImageLayout) -> some View {
    ZStack(alignment: .topLeading) {
      Image(decorative: image, scale: 1).resizable()
        .interpolation(actualPixels ? .none : .high)
        .frame(width: layout.image.width, height: layout.image.height)
        .position(x: layout.image.midX, y: layout.image.midY)
        .accessibilityLabel("识别的原图")
      if let location {
        let frame = layout.frame(for: location.box).insetBy(dx: -2, dy: -2)
        RoundedRectangle(cornerRadius: Style.Radius.mini)
          .strokeBorder(Style.brand, lineWidth: 2)
          .frame(width: frame.width, height: frame.height)
          .position(x: frame.midX, y: frame.midY)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
    .frame(width: layout.document.width, height: layout.document.height)
  }
}
