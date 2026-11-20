// 外部图片的有界读取与会话快照：标注不写原文件，拼图预览和导出始终读取同一份内容。

import AppKit
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated enum ImageImport {
  static let maximumFileBytes = 64 * 1024 * 1024
  static let maximumSessionBytes = 256 * 1024 * 1024

  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  /// 一批已验证的只读副本；所属面板负责在关闭后删除目录。
  struct Batch: Sendable {
    let directory: URL
    let sources: [ShotComposition.Source]
    let bytes: Int
  }

  /// 分块读取用户指定的本机图片，限制内存并保留权限、缺失或读取失败的原始异常。
  @concurrent static func read(_ url: URL) async throws -> Data {
    guard url.isFileURL else { throw Failure(message: "请选择本机图片文件") }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while let part = try handle.read(upToCount: 1024 * 1024), !part.isEmpty {
      try Task.checkCancellation()
      guard data.count + part.count <= maximumFileBytes else {
        throw Failure(message: "单张图片不能超过 64 MB，请先缩小文件")
      }
      data.append(part)
    }
    return data
  }

  /// 只接受可解码的静态图片，避免把动画或多页文件悄悄变成第一帧。
  private static func inspect(_ data: Data) throws -> CGImageSource {
    guard data.count <= maximumFileBytes else {
      throw Failure(message: "单张图片不能超过 64 MB，请先缩小文件")
    }
    guard let input = CGImageSourceCreateWithData(data as CFData, nil),
      let kind = CGImageSourceGetType(input), UTType(kind as String)?.conforms(to: .image) == true,
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.doubleValue.isFinite, height.doubleValue.isFinite,
      width.doubleValue > 0, height.doubleValue > 0
    else { throw Failure(message: "图片无法读取，请检查文件是否完整及格式是否受支持") }
    guard CGImageSourceGetStatus(input) == .statusComplete else {
      throw Failure(message: "图片数据不完整，请重新导出后再打开")
    }
    guard CGImageSourceGetCount(input) == 1 else {
      throw Failure(message: "暂不支持动画或多页图片，请先导出需要的静态图片")
    }
    guard width.doubleValue * height.doubleValue <= Double(ImageStore.maxPixels) else {
      throw Failure(message: "图片超过 4000 万像素，请先缩小后再打开")
    }
    return input
  }

  /// 按原像素解码并应用 EXIF 方向，异常由调用方显示，不用空图冒充成功。
  @concurrent static func decode(_ source: PinBoard.Source) async throws -> CGImage {
    let data: Data
    switch source {
    case .file(let url): data = try await read(url)
    case .data(let value): data = value
    }
    try Task.checkCancellation()
    let input = try inspect(data)
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        input, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: ImageStore.maxPixels,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw Failure(message: "图片解码失败，请尝试重新导出这张图片") }
    return try rgbImage(image)
  }

  /// 灰度、索引色和印刷色图片转换成可标注的 RGB，避免后续合成使用不支持的位图组合。
  private static func rgbImage(_ image: CGImage) throws -> CGImage {
    guard image.colorSpace?.model != .rgb else { return image }
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(message: "无法转换图片颜色，请缩小图片后重试") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else {
      throw Failure(message: "图片颜色转换未完成，请重试")
    }
    return result
  }

  /// 逐张生成会话副本；任意文件失败整批不采用，并删除本批半成品。
  @concurrent static func snapshots(
    _ urls: [URL], labels: [String]? = nil, remainingBytes: Int = maximumSessionBytes
  ) async throws -> Batch {
    guard !urls.isEmpty, urls.count <= ShotComposition.maximumCount,
      labels == nil || labels?.count == urls.count
    else { throw Failure(message: "一次请选择 1–20 张静态图片") }
    let operation = UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-image-import-\(operation)", directoryHint: .isDirectory)
    let began = ContinuousClock.now
    Log.storage.notice(
      "导入图片开始 operation=\(operation, privacy: .public) count=\(urls.count)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      var prepared: [ShotComposition.Source] = []
      var bytes = 0
      for (index, url) in urls.enumerated() {
        let data = try await read(url)
        _ = try inspect(data)
        guard data.count <= remainingBytes - bytes else {
          throw Failure(message: "本次会话导入量已达 256 MB，请关闭后分批处理")
        }
        try Task.checkCancellation()
        let id = UUID()
        let copy = directory.appending(path: id.uuidString)
        try data.write(to: copy, options: .atomic)
        let source = try await ShotComposition.source(
          id: id, url: copy, label: labels?[index] ?? url.lastPathComponent)
        guard source.thumbnail != nil else {
          throw Failure(message: "图片像素无法解码，未采用本批图片，请检查文件是否完整")
        }
        prepared.append(source)
        bytes += data.count
      }
      try Task.checkCancellation()
      Log.storage.notice(
        "导入图片完成 operation=\(operation, privacy: .public) count=\(prepared.count) bytes=\(bytes) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
      )
      return Batch(directory: directory, sources: prepared, bytes: bytes)
    } catch {
      Log.storage.error(
        "导入图片未采用 operation=\(operation, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
      )
      discard(directory)
      throw error
    }
  }

  /// 删除自建的会话目录，清理失败单独记录，不能覆盖首次导入或输出失败。
  static func discard(_ directory: URL) {
    guard directory.lastPathComponent.hasPrefix("kitty-image-import-"),
      FileManager.default.fileExists(atPath: directory.path)
    else { return }
    do { try FileManager.default.removeItem(at: directory) } catch {
      Log.storage.error("清理导入图片副本失败 cause=\(String(reflecting: error), privacy: .public)")
    }
  }
}
