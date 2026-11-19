// 简单截图拼图与多页 PDF：限制画布像素、逐张读取，导出先写临时文件，成功后才交付。

import AppKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated enum ShotComposition {
  /// ponytail: 一次最多 20 张，拼图最长边 8192、总计不超过 2400 万像素；更大批量留给专用文档工具。
  static let maximumCount = 20
  static let maximumSide: CGFloat = 8192
  static let maximumPixels: CGFloat = 24_000_000

  /// 按当前选中内容整体判断，不过滤用户选中的录屏或动图。
  @MainActor static func accepts(_ items: [ShotHistory.Item]) -> Bool {
    (2...maximumCount).contains(items.count) && items.allSatisfy { $0.filePath == nil }
  }

  /// 一张已经合成好标注的不可变临时快照，预览和导出使用同一文件。
  struct Source: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let size: CGSize
    let label: String
    var thumbnail: CGImage? = nil
  }

  enum Layout: String, CaseIterable, Identifiable, Sendable {
    case vertical, horizontal, grid
    var id: String { rawValue }
    var title: String {
      switch self {
      case .vertical: "竖向拼接"
      case .horizontal: "横向拼接"
      case .grid: "网格"
      }
    }
  }

  /// 每次导出固定一份选项，处理中调整界面不会改变正在输出的内容。
  struct Options: Equatable, Sendable {
    var layout = Layout.vertical
    var spacing: CGFloat = 16
    var margin: CGFloat = 16
    var rounded = false
    var dark = false
  }

  struct Plan: Equatable, Sendable {
    let size: CGSize
    /// 与输入图片顺序一致，使用左下原点的输出像素坐标。
    let frames: [CGRect]
  }

  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  /// 根据图片原始比例计算横拼、竖拼或网格；整体等比缩小到像素预算，不拉伸或裁掉内容。
  static func plan(sizes: [CGSize], options: Options, maximum: CGFloat = maximumSide) throws -> Plan
  {
    guard !sizes.isEmpty, sizes.count <= maximumCount,
      sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
      ),
      maximum.isFinite, maximum >= 1,
      options.spacing.isFinite, (0...64).contains(options.spacing),
      options.margin.isFinite, (0...64).contains(options.margin)
    else { throw Failure(message: "图片尺寸或拼图参数无效") }
    let gap = options.spacing
    let margin = options.margin
    var frames: [CGRect] = []
    var size: CGSize
    switch options.layout {
    case .vertical:
      let width = min(sizes.map(\.width).max() ?? 1, 2048)
      var y = margin
      for source in sizes {
        let height = max(1, width * source.height / source.width)
        frames.append(CGRect(x: margin, y: y, width: width, height: height))
        y += height + gap
      }
      size = CGSize(width: width + margin * 2, height: y - gap + margin)
    case .horizontal:
      let height = min(sizes.map(\.height).max() ?? 1, 2048)
      var x = margin
      for source in sizes {
        let width = max(1, height * source.width / source.height)
        frames.append(CGRect(x: x, y: margin, width: width, height: height))
        x += width + gap
      }
      size = CGSize(width: x - gap + margin, height: height + margin * 2)
    case .grid:
      let columns = Int(ceil(sqrt(Double(sizes.count))))
      let rows = (sizes.count + columns - 1) / columns
      let cell: CGFloat = 1024
      size = CGSize(
        width: CGFloat(columns) * cell + CGFloat(columns - 1) * gap + margin * 2,
        height: CGFloat(rows) * cell + CGFloat(rows - 1) * gap + margin * 2)
      for (index, source) in sizes.enumerated() {
        let ratio = min(cell / source.width, cell / source.height)
        let fitted = CGSize(width: source.width * ratio, height: source.height * ratio)
        frames.append(
          CGRect(
            x: margin + CGFloat(index % columns) * (cell + gap) + (cell - fitted.width) / 2,
            y: margin + CGFloat(index / columns) * (cell + gap) + (cell - fitted.height) / 2,
            width: fitted.width, height: fitted.height))
      }
    }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw Failure(message: "拼图尺寸超出可处理范围")
    }
    let ratio = min(
      1, maximum / max(size.width, size.height), sqrt(maximumPixels / (size.width * size.height)))
    let height = max(1, ceil(size.height * ratio))
    frames = frames.map {
      CGRect(
        x: $0.minX * ratio, y: height - $0.maxY * ratio,
        width: $0.width * ratio, height: $0.height * ratio)
    }
    size = CGSize(width: max(1, ceil(size.width * ratio)), height: height)
    return Plan(size: size, frames: frames)
  }

  /// 不解码像素，只读快照文件尺寸，损坏文件与缺失文件都会明确失败。
  @concurrent static func source(id: UUID, url: URL, label: String) async throws -> Source {
    guard let input = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.doubleValue > 0, height.doubleValue > 0
    else { throw Failure(message: "无法读取图片（\(label)），文件可能已移走或损坏") }
    return Source(
      id: id, url: url, size: CGSize(width: width.doubleValue, height: height.doubleValue),
      label: label,
      thumbnail: CGImageSourceCreateThumbnailAtIndex(
        input, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 120,
        ] as CFDictionary))
  }

  /// ImageIO 按实际输出需要缩小解码，避免先解开整张超长原图。
  private static func decode(_ source: Source, side: Int) throws -> CGImage {
    guard let input = CGImageSourceCreateWithURL(source.url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        input, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(1, side),
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw Failure(message: "无法解码图片（\(source.label)），未导出文件") }
    return image
  }

  /// 预览与最终 PNG 共用同一排版和绘制，只改变输出像素上限。
  @concurrent static func render(
    _ sources: [Source], options: Options, maximum: CGFloat = maximumSide
  )
    async throws -> CGImage
  {
    let layout = try plan(sizes: sources.map(\.size), options: options, maximum: maximum)
    guard
      let context = CGContext(
        data: nil, width: Int(layout.size.width), height: Int(layout.size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(message: "无法分配拼图画布，请减少图片数量") }
    context.setFillColor(CGColor(gray: options.dark ? 0.08 : 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: layout.size))
    context.interpolationQuality = .high
    for (source, frame) in zip(sources, layout.frames) {
      try Task.checkCancellation()
      try autoreleasepool {
        let image = try decode(source, side: Int(ceil(max(frame.width, frame.height))))
        context.saveGState()
        if options.rounded {
          let radius = min(16, min(frame.width, frame.height) * 0.04)
          context.addPath(
            CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
          context.clip()
        }
        context.draw(image, in: frame)
        context.restoreGState()
      }
    }
    guard let image = context.makeImage() else { throw Failure(message: "未能生成拼图") }
    return image
  }

  /// 写出完整 PNG 或 PDF 后才替换目标；失败、取消都删除半成品，已有文件保持原状。
  @concurrent static func export(_ sources: [Source], options: Options, pdf: Bool, to target: URL)
    async throws
  {
    guard (2...maximumCount).contains(sources.count) else { throw Failure(message: "请选择 2–20 张截图") }
    let operation = UUID().uuidString
    let temporary = target.deletingLastPathComponent().appending(
      path: ".kitty-compose-\(operation)")
    let began = ContinuousClock.now
    Log.storage.notice(
      "截图合成开始 operation=\(operation, privacy: .public) count=\(sources.count) pdf=\(pdf)")
    defer { cleanup(temporary) }
    do {
      if pdf {
        try writePDF(sources, options: options, to: temporary)
      } else {
        let image = try await render(sources, options: options)
        guard
          let output = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(message: "无法创建 PNG 文件") }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw Failure(message: "PNG 文件写入失败") }
      }
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: target.path) {
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: target)
      }
      Log.storage.notice(
        "截图合成成功 operation=\(operation, privacy: .public) count=\(sources.count) pdf=\(pdf) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
      )
    } catch {
      Log.storage.error(
        "截图合成未完成 operation=\(operation, privacy: .public) count=\(sources.count) pdf=\(pdf) cause=\(String(reflecting: error), privacy: .public)"
      )
      throw error
    }
  }

  /// 每图一页、保留比例与顺序；每页解码后立即释放，不把整批像素留在内存。
  private static func writePDF(_ sources: [Source], options: Options, to url: URL) throws {
    guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
      throw Failure(message: "无法创建 PDF 文件")
    }
    defer { context.closePDF() }
    for source in sources {
      try Task.checkCancellation()
      try autoreleasepool {
        let ratio = min(1, 4096 / max(source.size.width, source.size.height))
        let size = CGSize(
          width: ceil(source.size.width * ratio), height: ceil(source.size.height * ratio))
        let margin = options.margin
        var box = CGRect(
          x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let media = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: media] as CFDictionary)
        context.setFillColor(CGColor(gray: options.dark ? 0.08 : 1, alpha: 1))
        context.fill(box)
        let image = try decode(source, side: Int(max(size.width, size.height)))
        context.draw(image, in: CGRect(origin: CGPoint(x: margin, y: margin), size: size))
        context.endPDFPage()
      }
    }
  }

  /// 清理失败独立记录，避免覆盖首次导出失败的原始原因。
  private static func cleanup(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch {
      Log.storage.error(
        "截图合成临时文件清理失败 temporary=\(url.lastPathComponent, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
      )
    }
  }
}
