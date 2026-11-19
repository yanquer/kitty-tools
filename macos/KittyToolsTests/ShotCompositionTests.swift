// 截图增强的行为验证：拼图尺寸与像素、PDF 页序、失败不覆盖文件，以及自动扫码的过期结果隔离。

import AppKit
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor @Suite(.serialized)
struct ShotCompositionTests {
  /// 创建临时图片，像素颜色用于验证合成后的顺序与完整性。
  private func image(_ red: CGFloat, _ blue: CGFloat, size: CGSize = CGSize(width: 100, height: 60))
    throws -> CGImage
  {
    let context = try #require(
      CGContext(
        data: nil, width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    return try #require(context.makeImage())
  }

  /// 在临时目录写真实 PNG，沿产品入口读取元信息。
  private func source(_ image: CGImage, at url: URL) async throws -> ShotComposition.Source {
    let output = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, nil)
    #expect(CGImageDestinationFinalize(output))
    return try await ShotComposition.source(id: UUID(), url: url, label: url.lastPathComponent)
  }

  /// 每次测试独立目录，不读取用户偏好、截图库或剪贴板。
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// 用 1 像素位图取得绘图坐标中的颜色，不依赖源文件的内部通道顺序。
  private func pixel(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress, width: 1, height: 1,
          bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.translateBy(x: -point.x, y: -point.y)
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  @Test func recognitionCopiesOnlyRequestedTextAndClears() {
    let model = RecognitionModel()
    model.text = "第一行\n第二行完整文字"
    model.selectedText = "第二行"
    var written: [String] = []
    model.write = { written.append($0) }
    model.copy(selectionOnly: true)
    model.copy(selectionOnly: false)
    #expect(written == ["第二行", "第一行\n第二行完整文字"])
    model.clear()
    model.copy(selectionOnly: true)
    #expect(written.count == 2)
    #expect(model.text.isEmpty && model.selectedText.isEmpty && model.image == nil)
  }

  @Test func recognitionKeepsLatestRequestAndDoesNotRefillAfterClose() async throws {
    let probe = CodeScanProbe()
    let panel = RecognitionPanel { image in
      let result = try await probe.scan(image)
      return result.map { OCR.Line(text: $0.text, box: $0.box) }
    }
    panel.request(try image(1, 0))
    try await Task.sleep(for: .milliseconds(30))
    panel.request(try image(0, 1, size: CGSize(width: 200, height: 60)))
    try await Task.sleep(for: .milliseconds(330))
    #expect(panel.model.text == "200")
    #expect(await probe.maximumConcurrent == 1)
    panel.request(try image(1, 0))
    try await Task.sleep(for: .milliseconds(20))
    panel.hide()
    try await Task.sleep(for: .milliseconds(160))
    #expect(panel.model.text.isEmpty && panel.model.image == nil && !panel.model.working)
  }

  @Test func layoutsKeepOrderAspectAndBudget() throws {
    let sizes = [CGSize(width: 100, height: 50), CGSize(width: 50, height: 100)]
    for layout in ShotComposition.Layout.allCases {
      let options = ShotComposition.Options(layout: layout, spacing: 16, margin: 8)
      let plan = try ShotComposition.plan(sizes: sizes, options: options)
      #expect(plan.frames.count == 2)
      #expect(abs(plan.frames[0].width / plan.frames[0].height - 2) < 0.001)
      #expect(abs(plan.frames[1].width / plan.frames[1].height - 0.5) < 0.001)
      for rect in plan.frames { #expect(CGRect(origin: .zero, size: plan.size).contains(rect)) }
      if layout == .vertical { #expect(plan.frames[0].minY > plan.frames[1].minY) }
      if layout == .horizontal || layout == .grid {
        #expect(plan.frames[0].minX < plan.frames[1].minX)
      }
    }
    let huge = try ShotComposition.plan(
      sizes: Array(repeating: CGSize(width: 8000, height: 30000), count: 20), options: .init())
    #expect(max(huge.size.width, huge.size.height) <= ShotComposition.maximumSide)
    #expect(huge.size.width * huge.size.height <= ShotComposition.maximumPixels + 16384)
  }

  @Test func rejectsInvalidSizesAndMixedSelection() throws {
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.plan(sizes: [], options: .init())
    }
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.plan(sizes: [CGSize(width: CGFloat.nan, height: 10)], options: .init())
    }
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.plan(sizes: [CGSize(width: 10, height: 10)], options: .init(spacing: -1))
    }
    let item = ShotHistory.Item(
      id: UUID(), kind: .shot, createdAt: .now, pixelSize: CGSize(width: 10, height: 10), scale: 1)
    var recording = item
    recording.kind = .video
    recording.filePath = "/not-a-real-video.mp4"
    #expect(ShotComposition.accepts([item, item]))
    #expect(!ShotComposition.accepts([item]))
    #expect(!ShotComposition.accepts([item, recording]))
    #expect(!ShotComposition.accepts(Array(repeating: item, count: 21)))
  }

  @Test func pngAndPDFContainAllImagesInOrder() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = [
      try await source(image(1, 0), at: folder.appending(path: "red.png")),
      try await source(image(0, 1), at: folder.appending(path: "blue.png")),
    ]
    let options = ShotComposition.Options(spacing: 0, margin: 0)
    let result = try await ShotComposition.render(sources, options: options)
    #expect(result.width == 100 && result.height == 120)
    #expect(try pixel(result, at: CGPoint(x: 50, y: 90))[0] > 240)
    #expect(try pixel(result, at: CGPoint(x: 50, y: 30))[2] > 240)
    let png = folder.appending(path: "result.png")
    try Data("old destination".utf8).write(to: png)
    try await ShotComposition.export(sources, options: options, pdf: false, to: png)
    let pngInput = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    #expect(CGImageSourceGetCount(pngInput) == 1)
    let pdf = folder.appending(path: "result.pdf")
    try await ShotComposition.export(sources, options: options, pdf: true, to: pdf)
    let document = try #require(CGPDFDocument(pdf as CFURL))
    #expect(document.numberOfPages == 2)
    for pageNumber in 1...2 {
      let page = try #require(document.page(at: pageNumber))
      #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 100, height: 60))
      let context = try #require(
        CGContext(
          data: nil, width: 100, height: 60, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.drawPDFPage(page)
      let output = try #require(context.makeImage())
      #expect(try pixel(output, at: CGPoint(x: 50, y: 30))[pageNumber == 1 ? 0 : 2] > 240)
    }
  }

  @Test func failureAndCancellationPreserveDestination() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = try await source(image(1, 0), at: folder.appending(path: "red.png"))
    let missing = ShotComposition.Source(
      id: UUID(), url: folder.appending(path: "missing.png"), size: valid.size, label: "缺失图片")
    let target = folder.appending(path: "existing.pdf")
    let original = Data("keep existing file".utf8)
    try original.write(to: target)
    await #expect(throws: ShotComposition.Failure.self) {
      try await ShotComposition.export([valid, missing], options: .init(), pdf: true, to: target)
    }
    #expect(try Data(contentsOf: target) == original)
    let task = Task {
      try await ShotComposition.export([valid, valid], options: .init(), pdf: true, to: target)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: target) == original)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy {
        !$0.hasPrefix(".kitty-compose-")
      })
  }

  @Test func generatedQRCodeReturnsContentAndBounds() async throws {
    let payload = "https://example.com/kitty-tools"
    let filter = try #require(
      CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(payload.utf8)]))
    let code = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let extent = code.extent.insetBy(dx: -32, dy: -32)
    let background = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
    let image = try #require(
      CIContext().createCGImage(code.composited(over: background), from: extent))
    let results = try await OCR.scanCodes(in: image)
    #expect(results.map(\.text) == [payload])
    let box = try #require(results.first?.box)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(box))
    #expect(box.width > 0 && box.height > 0)
    let empty = try self.image(1, 0)
    #expect(try await OCR.scanCodes(in: empty).isEmpty)
  }

  @Test func codeLinksOnlyOpenCompleteWebURLs() {
    for value in ["https://example.com/path?q=1", "http://example.com"] {
      #expect(OCR.Code(text: value, box: .zero).url != nil)
    }
    for value in [
      "javascript:alert(1)", "file:///tmp/x", "kitty://action", "https:", "https://example.com hi",
      "hello",
    ] {
      #expect(OCR.Code(text: value, box: .zero).url == nil)
    }
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    for point in [CGPoint.zero, CGPoint(x: 800, y: 600), CGPoint(x: 400, y: 300)] {
      let anchor = CGRect(origin: point, size: CGSize(width: 1, height: 1))
      #expect(bounds.contains(SelectionCodes.badgeFrame(for: anchor, within: bounds)))
      #expect(bounds.contains(SelectionCodes.cardFrame(anchor: anchor, within: bounds)))
    }
  }

  @Test func codeScanningDiscardsOldResultsAndUsesOneWorker() async throws {
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    let probe = CodeScanProbe()
    let codes = SelectionCodes(host: host) { image in try await probe.scan(image) }
    let source = try image(1, 0, size: host.bounds.size)
    codes.update(
      image: source, selection: CGRect(x: 0, y: 0, width: 100, height: 100),
      viewSize: host.bounds.size, enabled: true)
    try await Task.sleep(for: .milliseconds(210))
    codes.update(
      image: source, selection: CGRect(x: 0, y: 0, width: 200, height: 100),
      viewSize: host.bounds.size, enabled: true)
    try await Task.sleep(for: .milliseconds(650))
    #expect(codes.results.map(\.text) == ["200"])
    #expect(await probe.maximumConcurrent == 1)
    codes.update(image: source, selection: nil, viewSize: host.bounds.size, enabled: false)
    #expect(codes.results.isEmpty)
    #expect(codes.overlay.subviews.isEmpty)
    #expect(codes.overlay.hitTest(CGPoint(x: 20, y: 20)) == nil)
  }
}

/// 模拟不会立即完成的 Vision 请求，记录并发数，不触发真实识别或屏幕读取。
private actor CodeScanProbe {
  private var running = 0
  private(set) var maximumConcurrent = 0

  /// 按输入图宽返回内容，区分旧选区与新选区的扫描结果。
  func scan(_ image: CGImage) async throws -> [OCR.Code] {
    running += 1
    maximumConcurrent = max(maximumConcurrent, running)
    defer { running -= 1 }
    try await Task.sleep(for: .milliseconds(120))
    return [OCR.Code(text: "\(image.width)", box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))]
  }
}
