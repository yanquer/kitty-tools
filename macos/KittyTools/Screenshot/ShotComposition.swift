// 截图拼图、多页 PDF 和逐张 PNG：逐张读取，先写临时产物，成功后才交付。

import AppKit
import Darwin
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
    var edit = Edit()
    var editedThumbnail: CGImage? = nil
    var thumbnailEdit: Edit? = nil
    var thumbnailError: String? = nil
    /// 导入前的文件名，避免把会话副本的临时编号当作导出名称。
    var originalFilename: String? = nil

    /// 排版读取经过像素对齐的裁剪尺寸，四分之一转时交换宽高。
    func adjustedSize() throws -> CGSize {
      let rect = try edit.pixelRect(in: size)
      return edit.turns % 2 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
    }

    /// 列表只读后台生成的当前版本缩略图，不用整图小缩略图冒充细小裁剪结果。
    var adjustedThumbnail: CGImage? {
      if edit.isIdentity { return thumbnail }
      return thumbnailEdit == edit ? editedThumbnail : nil
    }

    /// 调整状态使用可理解的动作说明，未旋转时不显示没有意义的零度。
    var adjustmentDescription: String {
      var parts: [String] = []
      if edit.crop != CGRect(x: 0, y: 0, width: 1, height: 1) { parts.append("已裁剪") }
      switch edit.turns {
      case 1: parts.append("右转 90°")
      case 2: parts.append("旋转 180°")
      case 3: parts.append("左转 90°")
      default: break
      }
      return parts.joined(separator: " · ")
    }
  }

  /// 裁剪以转正原图的左下归一化坐标保存，旋转在裁剪之后采用，恢复不依赖历史副本。
  struct Edit: Equatable, Sendable {
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var turns = 0
    var isIdentity: Bool { crop == CGRect(x: 0, y: 0, width: 1, height: 1) && turns == 0 }

    /// 校验并转换为原点左上的真实像素框；最小范围来自一个像素，不引入额外裁剪配额。
    func pixelRect(in size: CGSize) throws -> CGRect {
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
        crop.minX.isFinite, crop.minY.isFinite, crop.width.isFinite, crop.height.isFinite,
        crop.minX >= -0.000000001, crop.minY >= -0.000000001, crop.width > 0, crop.height > 0,
        crop.maxX <= 1.000000001, crop.maxY <= 1.000000001, (0..<4).contains(turns)
      else { throw Failure(message: "图片裁剪范围或旋转方向无效") }
      let left = max(0, (crop.minX * size.width).rounded())
      let right = min(size.width, (crop.maxX * size.width).rounded())
      let bottom = max(0, (crop.minY * size.height).rounded())
      let top = min(size.height, (crop.maxY * size.height).rounded())
      guard right - left >= 1, top - bottom >= 1 else {
        throw Failure(message: "裁剪范围至少需要 1 × 1 像素")
      }
      return CGRect(x: left, y: size.height - top, width: right - left, height: top - bottom)
    }

    /// 元数据以真实原图像素边界归一化，解码、草稿应用和缩略图使用同一范围。
    func aligned(in size: CGSize) throws -> Edit {
      let rect = try pixelRect(in: size)
      return Edit(
        crop: CGRect(
          x: rect.minX / size.width, y: (size.height - rect.maxY) / size.height,
          width: rect.width / size.width, height: rect.height / size.height), turns: turns)
    }

    /// 显示中的整图旋转与裁剪框使用同一矩阵，应用时可逆向映射回原图。
    var rotation: CGAffineTransform {
      (0..<max(0, min(turns, 3))).reduce(CGAffineTransform.identity) { value, _ in
        value.concatenating(ImageTransform.mapping(.right, size: CGSize(width: 1, height: 1)))
      }
    }
  }

  /// 预设只决定目标宽度，自定义数值仅在自定义模式生效。
  enum WidthMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, compact, wide, custom
    var id: String { rawValue }
    var title: String {
      switch self {
      case .automatic: "自动"
      case .compact: "1024 像素"
      case .wide: "1920 像素"
      case .custom: "自定义"
      }
    }
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

  /// 输出底色不随应用外观变化，透明只适用于 PNG。
  enum Background: String, CaseIterable, Identifiable, Sendable {
    case light, dark, transparent, cream, blue, mint
    var id: String { rawValue }
    var title: String {
      switch self {
      case .light: "白色"
      case .dark: "深灰"
      case .transparent: "透明"
      case .cream: "米色"
      case .blue: "浅蓝"
      case .mint: "浅绿"
      }
    }
    var color: CGColor {
      switch self {
      case .light: CGColor(gray: 1, alpha: 1)
      case .dark: CGColor(gray: 0.08, alpha: 1)
      case .transparent: CGColor(gray: 0, alpha: 0)
      case .cream: CGColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
      case .blue: CGColor(red: 0.89, green: 0.94, blue: 0.99, alpha: 1)
      case .mint: CGColor(red: 0.89, green: 0.97, blue: 0.93, alpha: 1)
      }
    }
  }

  /// 按图尺寸保留原有分页模式，A4 使用真实毫米尺寸换算 PDF 点。
  enum Paper: String, CaseIterable, Identifiable, Sendable {
    case image, a4
    var id: String { rawValue }
    var title: String { self == .image ? "按图片尺寸" : "A4" }
  }

  /// 方向只作用于固定纸张，按图尺寸始终保留图片比例。
  enum Orientation: String, CaseIterable, Identifiable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var title: String { self == .portrait ? "纵向" : "横向" }
  }

  /// 每次导出固定一份选项，处理中调整界面不会改变正在输出的内容。
  struct Options: Equatable, Sendable {
    var layout = Layout.vertical
    var spacing: CGFloat = 16
    var margin: CGFloat = 16
    var cornerRadius: CGFloat = 0
    var background = Background.light
    var paper = Paper.image
    var orientation = Orientation.portrait
    var pdfMargin: CGFloat = 10
    var pdfBackground = Background.light
    var widthMode = WidthMode.automatic
    var customWidth = 1920
    var requestedWidth: CGFloat? {
      switch widthMode {
      case .automatic: nil
      case .compact: 1024
      case .wide: 1920
      case .custom: CGFloat(customWidth)
      }
    }
  }

  struct Plan: Equatable, Sendable {
    let size: CGSize
    /// 与输入图片顺序一致、使用左下原点；PNG 单位为输出像素，PDF 单位为点。
    let frames: [CGRect]
    var requestedSize: CGSize? = nil
    var isLimited = false
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
      options.margin.isFinite, (0...64).contains(options.margin),
      options.cornerRadius.isFinite, (0...64).contains(options.cornerRadius)
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
    if let width = options.requestedWidth, !(1...maximumSide).contains(width) {
      throw Failure(message: "PNG 输出宽度需要在 1–8192 像素之间")
    }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      throw Failure(message: "拼图尺寸超出可处理范围")
    }
    let requestedScale = options.requestedWidth.map { $0 / size.width } ?? 1
    let requestedSize = CGSize(
      width: size.width * requestedScale, height: size.height * requestedScale)
    let ratio = min(
      requestedScale, maximum / max(size.width, size.height),
      sqrt(maximumPixels / (size.width * size.height)))
    let limited = ratio < requestedScale - 0.000000001
    let height = max(1, ceil(size.height * ratio))
    frames = frames.map {
      CGRect(
        x: $0.minX * ratio, y: height - $0.maxY * ratio,
        width: $0.width * ratio, height: $0.height * ratio)
    }
    size = CGSize(
      width: !limited
        ? (options.requestedWidth ?? max(1, ceil(size.width * ratio)))
        : max(1, ceil(size.width * ratio)), height: height)
    return Plan(size: size, frames: frames, requestedSize: requestedSize, isLimited: limited)
  }

  /// PDF 预览与导出共享页框和图片框，毫米边距不与 PNG 像素留白混用。
  static func pdfPagePlan(size: CGSize, options: Options) throws -> Plan {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      options.pdfMargin.isFinite, (0...40).contains(options.pdfMargin),
      options.pdfBackground != .transparent
    else { throw Failure(message: "PDF 图片尺寸、页边距或纸张背景无效") }
    let margin = options.pdfMargin * 72 / 25.4
    var page: CGSize
    if options.paper == .a4 {
      page = CGSize(width: 210 * 72 / 25.4, height: 297 * 72 / 25.4)
      if options.orientation == .landscape { page = CGSize(width: page.height, height: page.width) }
    } else {
      let ratio = min(1, 4096 / max(size.width, size.height))
      page = CGSize(
        width: ceil(size.width * ratio) + margin * 2, height: ceil(size.height * ratio) + margin * 2
      )
    }
    let ratio = min(
      (page.width - margin * 2) / size.width, (page.height - margin * 2) / size.height)
    let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
    let frame = CGRect(
      x: (page.width - fitted.width) / 2, y: (page.height - fitted.height) / 2, width: fitted.width,
      height: fitted.height)
    return Plan(size: page, frames: [frame])
  }

  /// 不解码像素，只读快照文件尺寸，损坏文件与缺失文件都会明确失败。
  @concurrent static func source(id: UUID, url: URL, label: String) async throws -> Source {
    guard let input = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.doubleValue > 0, height.doubleValue > 0
    else { throw Failure(message: "无法读取图片（\(label)），文件可能已移走或损坏") }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let swapsAxes = (5...8).contains(orientation)
    return Source(
      id: id, url: url,
      size: CGSize(
        width: swapsAxes ? height.doubleValue : width.doubleValue,
        height: swapsAxes ? width.doubleValue : height.doubleValue),
      label: label,
      thumbnail: CGImageSourceCreateThumbnailAtIndex(
        input, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 120,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary))
  }

  /// ImageIO 按实际输出需要缩小解码，避免先解开整张超长原图。
  private static func decode(_ source: Source, side: Int) throws -> CGImage {
    let cropped = try source.edit.pixelRect(in: source.size)
    let originalSide = max(source.size.width, source.size.height)
    let needed = min(
      originalSide, ceil(CGFloat(side) * originalSide / max(cropped.width, cropped.height)))
    let image = try decodeOriginal(source, side: Int(needed))
    return try adjusted(image, edit: source.edit.aligned(in: source.size))
  }

  /// 裁剪编辑器只读取整图的有界预览，像素内容不写回会话副本。
  @concurrent static func cropPreview(_ source: Source) async throws -> CGImage {
    _ = try source.edit.pixelRect(in: source.size)
    try Task.checkCancellation()
    let image = try decodeOriginal(source, side: 1400)
    return try adjusted(image, edit: Edit(turns: source.edit.turns))
  }

  /// 调整后的缩略图同样按裁剪需求解码，单像素小范围不会取到整图缩小后的混合颜色。
  @concurrent static func thumbnail(for source: Source) async throws -> CGImage {
    try Task.checkCancellation()
    return try decode(source, side: 120)
  }

  /// 转正解码与裁剪需求分开计算，小范围裁剪不会因为先缩成整图缩略图而丢掉细节。
  private static func decodeOriginal(_ source: Source, side: Int) throws -> CGImage {
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

  /// 小图缩略图与最终输出共用裁剪和正交旋转，坐标始终映射转正后的原图。
  static func adjusted(_ image: CGImage, edit: Edit) throws -> CGImage {
    guard (0..<4).contains(edit.turns), edit.crop.width > 0, edit.crop.height > 0,
      edit.crop.minX.isFinite, edit.crop.minY.isFinite, edit.crop.maxX.isFinite,
      edit.crop.maxY.isFinite,
      edit.crop.minX >= 0, edit.crop.minY >= 0, edit.crop.maxX <= 1.000000001,
      edit.crop.maxY <= 1.000000001
    else { throw Failure(message: "图片调整参数无效") }
    let size = CGSize(width: image.width, height: image.height)
    // 归一化的整数像素边界会有浮点误差；容差远小于一个像素，避免多裁入一行。
    let left = floor(edit.crop.minX * size.width + 0.0000001)
    let right = ceil(edit.crop.maxX * size.width - 0.0000001)
    let top = floor((1 - edit.crop.maxY) * size.height + 0.0000001)
    let bottom = ceil((1 - edit.crop.minY) * size.height - 0.0000001)
    let area = CGRect(x: left, y: top, width: right - left, height: bottom - top)
      .intersection(CGRect(origin: .zero, size: size))
    guard let crop = image.cropping(to: area) else { throw Failure(message: "裁剪范围无法生成图片") }
    if edit.turns == 0, area == CGRect(origin: .zero, size: size) { return image }
    // 裁剪结果也生成独立位图，避免一像素缩略图仍持有整张原图的像素存储。
    var output = CGSize(width: crop.width, height: crop.height)
    var matrix = CGAffineTransform.identity
    for _ in 0..<edit.turns {
      matrix = matrix.concatenating(ImageTransform.mapping(.right, size: output))
      output = CGSize(width: output.height, height: output.width)
    }
    let colorSpace =
      crop.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(
        name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: Int(output.width), height: Int(output.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw Failure(message: "无法分配图片调整画布")
    }
    context.interpolationQuality = .none
    context.concatenate(matrix)
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    guard let result = context.makeImage() else { throw Failure(message: "图片调整未完成") }
    return result
  }

  /// 预览与最终 PNG 共用同一排版和绘制，只改变输出像素上限。
  @concurrent static func render(
    _ sources: [Source], options: Options, maximum: CGFloat = maximumSide
  )
    async throws -> CGImage
  {
    guard maximum.isFinite, maximum >= 1 else { throw Failure(message: "预览尺寸无效") }
    let layout = try plan(sizes: sources.map { try $0.adjustedSize() }, options: options)
    let scale = min(1, maximum / max(layout.size.width, layout.size.height))
    let size = CGSize(
      width: ceil(layout.size.width * scale), height: ceil(layout.size.height * scale))
    let context = try canvas(size: size, background: options.background)
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    for (source, frame) in zip(sources, layout.frames) {
      try Task.checkCancellation()
      try autoreleasepool {
        let image = try decode(source, side: Int(ceil(max(frame.width, frame.height) * scale)))
        context.saveGState()
        let radius = min(options.cornerRadius, min(frame.width, frame.height) / 2)
        if radius > 0 {
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

  /// 按真实 PDF 页框生成当前页的小预览，不借用拼图布局，不读取其余页像素。
  @concurrent static func renderPDFPage(_ source: Source, options: Options, maximum: CGFloat = 1000)
    async throws -> CGImage
  {
    guard maximum.isFinite, maximum >= 1 else { throw Failure(message: "预览尺寸无效") }
    try Task.checkCancellation()
    let page = try pdfPagePlan(size: source.adjustedSize(), options: options)
    let scale = min(1, maximum / max(page.size.width, page.size.height))
    let size = CGSize(width: ceil(page.size.width * scale), height: ceil(page.size.height * scale))
    let context = try canvas(size: size, background: options.pdfBackground)
    context.scaleBy(x: scale, y: scale)
    let frame = page.frames[0]
    let image = try decode(
      source, side: min(4096, Int(ceil(max(frame.width, frame.height) * scale))))
    context.interpolationQuality = .high
    context.draw(image, in: frame)
    try Task.checkCancellation()
    guard let preview = context.makeImage() else { throw Failure(message: "未能生成 PDF 页预览") }
    return preview
  }

  /// 有界位图共用背景填充，透明 PNG 保留真实 alpha，棋盘底仅属于界面。
  private static func canvas(size: CGSize, background: Background) throws -> CGContext {
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw Failure(message: "无法分配预览或拼图画布，请减少图片数量")
    }
    context.setFillColor(background.color)
    context.fill(CGRect(origin: .zero, size: size))
    return context
  }

  /// 写出完整 PNG 或 PDF 后才替换目标；失败、取消都删除半成品，已有文件保持原状。
  @concurrent static func export(_ sources: [Source], options: Options, pdf: Bool, to target: URL)
    async throws
  {
    guard (2...maximumCount).contains(sources.count) else {
      throw Failure(message: "请选择 2–20 张静态图片")
    }
    let operation = UUID().uuidString
    let temporary = target.deletingLastPathComponent().appending(
      path: ".kitty-compose-\(operation)")
    let began = ContinuousClock.now
    Log.storage.notice(
      "截图合成开始 operation=\(operation, privacy: .public) count=\(sources.count) pdf=\(pdf) paper=\(options.paper.rawValue, privacy: .public) orientation=\(options.orientation.rawValue, privacy: .public) marginMM=\(options.pdfMargin)"
    )
    defer { cleanup(temporary) }
    do {
      if pdf {
        try writePDF(sources, options: options, to: temporary, operation: operation)
        guard let document = CGPDFDocument(temporary as CFURL),
          document.numberOfPages == sources.count
        else {
          throw Failure(message: "PDF 写入不完整，未替换已有文件")
        }
      } else {
        let image = try await render(sources, options: options)
        Log.storage.notice(
          "PNG 输出尺寸 operation=\(operation, privacy: .public) widthMode=\(options.widthMode.rawValue, privacy: .public) requestedWidth=\(options.requestedWidth ?? 0) actualWidth=\(image.width) actualHeight=\(image.height)"
        )
        try writePNG(image, to: temporary)
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

  /// 逐张生成原像素 PNG，再把包含全部结果的目录一次性发布到用户选定位置。
  @concurrent static func exportIndividualPNGs(_ sources: [Source], into parent: URL) async throws
    -> URL
  {
    guard (1...maximumCount).contains(sources.count), parent.isFileURL else {
      throw Failure(message: "请选择 1–20 张图片和本机导出文件夹")
    }
    let operation = UUID().uuidString
    let began = ContinuousClock.now
    let scoped = parent.startAccessingSecurityScopedResource()
    defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
    let staging = parent.appending(
      path: ".kitty-compose-png-\(operation)", directoryHint: .isDirectory)
    var stage = "staging"
    var writing: Int?
    Log.storage.notice("逐张导出开始 operation=\(operation, privacy: .public) count=\(sources.count)")
    do {
      try Task.checkCancellation()
      let creationError = staging.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return EINVAL }
        return mkdir(path, mode_t(S_IRWXU)) == 0 ? 0 : errno
      }
      guard creationError == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: creationError) ?? .EIO)
      }
      defer { cleanup(staging) }
      stage = "encode"
      for (index, source) in sources.enumerated() {
        writing = index
        try Task.checkCancellation()
        let filename = individualFilename(
          source.originalFilename ?? source.label, number: index + 1)
        try autoreleasepool {
          try writeIndividual(source, to: staging.appending(path: filename))
        }
      }
      writing = nil
      stage = "publish"
      let published = try publishIndividualDirectory(staging, in: parent)
      Log.storage.notice(
        "逐张导出完成 operation=\(operation, privacy: .public) count=\(sources.count) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
      )
      return published
    } catch {
      let underlying = error as NSError
      let source = writing.map { sources[$0].id.uuidString } ?? "-"
      let reason = individualFailureReason(error, source: writing.map { sources[$0] })
      Log.storage.error(
        "逐张导出未完成 operation=\(operation, privacy: .public) stage=\(stage, privacy: .public) position=\(writing.map { $0 + 1 } ?? 0) source=\(source, privacy: .public) domain=\(underlying.domain, privacy: .public) code=\(underlying.code) reason=\(reason, privacy: .public) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
      )
      if error is CancellationError { throw error }
      if let writing {
        throw Failure(message: "第 \(writing + 1) 张图片导出失败。\(reason)")
      }
      if let failure = error as? Failure { throw failure }
      throw Failure(message: "无法写入所选文件夹。\(reason)")
    }
  }

  /// 逐张导出不经拼图缩放，并回读单页及像素尺寸后才计入完整批次。
  private static func writeIndividual(_ source: Source, to file: URL) throws {
    let size = try source.adjustedSize()
    guard source.size.width * source.size.height <= CGFloat(ImageStore.maxPixels),
      let side = Int(exactly: max(size.width, size.height))
    else { throw Failure(message: "图片尺寸超出单张导出范围") }
    let image = try decode(source, side: side)
    guard CGSize(width: image.width, height: image.height) == size else {
      throw Failure(message: "解码后的像素尺寸与当前调整不一致")
    }
    try writePNG(image, to: file)
    guard let input = CGImageSourceCreateWithURL(file as CFURL, nil),
      CGImageSourceGetStatus(input) == .statusComplete, CGImageSourceGetCount(input) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == image.width,
      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == image.height
    else { throw Failure(message: "PNG 写入不完整或像素尺寸不正确") }
  }

  /// 拼图与逐张导出共用系统 PNG 编码，保留图片色彩空间和透明像素。
  private static func writePNG(_ image: CGImage, to url: URL) throws {
    guard
      let output = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(message: "无法创建 PNG 文件") }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw Failure(message: "PNG 文件写入失败") }
  }

  /// 去掉路径字符及原扩展名，按显示顺序加号，长度留出文件系统规范化空间。
  static func individualFilename(_ original: String, number: Int) -> String {
    let safe = original.unicodeScalars.map { scalar in
      if scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar) {
        return ""
      }
      return "/:\\".unicodeScalars.contains(scalar) ? "-" : String(scalar)
    }.joined()
    let stem = (safe as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    var bytes = 0
    let head = String(
      stem.prefix(while: { character in
        bytes += String(character).decomposedStringWithCanonicalMapping.utf8.count
        return bytes <= 180
      }))
    let prefix = String(format: "%02d", number)
    return "\(prefix)-\(head.isEmpty ? "图片" : head).png"
  }

  /// 使用原子的排他改名。文件系统不支持时停止，不以可能覆盖目标的改名代替。
  private static func publishIndividualDirectory(_ staging: URL, in parent: URL) throws -> URL {
    var number = 1
    while true {
      try Task.checkCancellation()
      let name = number == 1 ? "调整后的 PNG" : "调整后的 PNG \(number)"
      let target = parent.appending(path: name, directoryHint: .isDirectory)
      let code = staging.withUnsafeFileSystemRepresentation { from in
        target.withUnsafeFileSystemRepresentation { to -> Int32 in
          guard let from, let to else { return EINVAL }
          return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
      }
      if code == 0 { return target }
      if code == EEXIST || code == ENOTEMPTY {
        number += 1
        continue
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

  /// 保留编码或系统拒绝的原因，避免统一日志记录文件名、路径和图片内容。
  private static func individualFailureReason(_ error: Error, source: Source?) -> String {
    if let failure = error as? Failure {
      if let label = source?.label, !label.isEmpty {
        return failure.message.replacingOccurrences(of: label, with: "当前图片")
      }
      return failure.message
    }
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain {
      if value.code == Int(ENOTSUP) || value.code == Int(EINVAL) {
        return "此位置无法安全发布整批文件，请选择其它文件夹。"
      }
      return String(cString: strerror(Int32(value.code)))
    }
    if value.domain == NSCocoaErrorDomain {
      return CocoaError(CocoaError.Code(rawValue: value.code)).localizedDescription
    }
    return "\(value.domain) (\(value.code))"
  }

  /// 每图一页、保留比例与顺序；每页解码后立即释放，不把整批像素留在内存。
  private static func writePDF(
    _ sources: [Source], options: Options, to url: URL, operation: String
  ) throws {
    guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
      throw Failure(message: "无法创建 PDF 文件")
    }
    defer { context.closePDF() }
    for (index, source) in sources.enumerated() {
      try Task.checkCancellation()
      do {
        try autoreleasepool {
          let editedSize = try source.adjustedSize()
          let page = try pdfPagePlan(size: editedSize, options: options)
          var box = CGRect(origin: .zero, size: page.size)
          let media = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
          context.beginPDFPage([kCGPDFContextMediaBox: media] as CFDictionary)
          context.setFillColor(options.pdfBackground.color)
          context.fill(box)
          let image = try decode(
            source, side: min(4096, Int(ceil(max(editedSize.width, editedSize.height)))))
          context.draw(image, in: page.frames[0])
          context.endPDFPage()
        }
      } catch {
        Log.storage.error(
          "PDF 页面写入失败 operation=\(operation, privacy: .public) page=\(index + 1) source=\(source.id.uuidString, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
        )
        throw error
      }
    }
  }

  /// 清理失败独立记录，避免覆盖首次导出失败的原始原因。
  private static func cleanup(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do { try FileManager.default.removeItem(at: url) } catch {
      let underlying = error as NSError
      Log.storage.error(
        "截图合成临时文件清理失败 temporary=\(url.lastPathComponent, privacy: .public) domain=\(underlying.domain, privacy: .public) code=\(underlying.code) reason=\(individualFailureReason(error, source: nil), privacy: .public)"
      )
    }
  }
}
