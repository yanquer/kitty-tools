// 截图增强的行为验证：拼图尺寸与像素、PDF 页序、失败不覆盖文件，以及自动扫码的过期结果隔离。

import AppKit
import Carbon.HIToolbox
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
    let options = ShotComposition.Options(spacing: 0, margin: 0, pdfMargin: 0)
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

  /// A4 真实尺寸、毫米边距与横竖方向共用同一几何，宽图和长图都完整居中。
  @Test func pdfPaperGeometryUsesPhysicalUnits() throws {
    for orientation in ShotComposition.Orientation.allCases {
      for margin: CGFloat in [0, 10, 40] {
        let options = ShotComposition.Options(
          paper: .a4, orientation: orientation, pdfMargin: margin)
        for size in [CGSize(width: 4000, height: 1000), CGSize(width: 1000, height: 4000)] {
          let page = try ShotComposition.pdfPagePlan(size: size, options: options)
          let short: CGFloat = 210 * 72 / 25.4
          let long: CGFloat = 297 * 72 / 25.4
          #expect(abs(page.size.width - (orientation == .portrait ? short : long)) < 0.001)
          #expect(abs(page.size.height - (orientation == .portrait ? long : short)) < 0.001)
          let frame = try #require(page.frames.first)
          #expect(
            abs(frame.midX - page.size.width / 2) < 0.001
              && abs(frame.midY - page.size.height / 2) < 0.001)
          #expect(abs(frame.width / frame.height - size.width / size.height) < 0.001)
          let inset = margin * 72 / 25.4
          #expect(frame.minX >= inset - 0.001 && frame.minY >= inset - 0.001)
          #expect(
            frame.maxX <= page.size.width - inset + 0.001
              && frame.maxY <= page.size.height - inset + 0.001)
        }
      }
    }
    let original = try ShotComposition.pdfPagePlan(
      size: CGSize(width: 100, height: 60), options: .init(pdfMargin: 0))
    #expect(original.size == CGSize(width: 100, height: 60))
  }

  /// 校验只作用于所属输出，PDF 不继承 PNG 的间距、圆角与透明背景参数。
  @Test func compositionParametersRespectTheirOutputScope() throws {
    let size = CGSize(width: 120, height: 80)
    let mixed = ShotComposition.Options(
      spacing: .nan, margin: -1, cornerRadius: -8, background: .transparent, paper: .a4)
    #expect(
      try ShotComposition.pdfPagePlan(size: size, options: mixed)
        == ShotComposition.pdfPagePlan(size: size, options: .init(paper: .a4)))
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.plan(sizes: [size], options: mixed)
    }
    for value: CGFloat in [-1, 40.01, .nan] {
      #expect(throws: ShotComposition.Failure.self) {
        try ShotComposition.pdfPagePlan(size: size, options: .init(pdfMargin: value))
      }
    }
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.pdfPagePlan(size: size, options: .init(pdfBackground: .transparent))
    }
    #expect(throws: ShotComposition.Failure.self) {
      try ShotComposition.plan(sizes: [size], options: .init(cornerRadius: 65))
    }
  }

  /// 透明底和圆角进入真实 PNG，缩小预览按最终输出比例缩放圆角，不烘焙棋盘格。
  @Test func pngTransparencyAndScaledCornersMatchPreview() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let red = try await source(
      image(1, 0, size: CGSize(width: 800, height: 400)), at: folder.appending(path: "red.png"))
    let options = ShotComposition.Options(cornerRadius: 32, background: .transparent)
    let layout = try ShotComposition.plan(sizes: [red.size, red.size], options: options)
    let full = try await ShotComposition.render([red, red], options: options)
    let preview = try await ShotComposition.render([red, red], options: options, maximum: 200)
    let frame = layout.frames[0]
    let scale = min(1, 200 / max(layout.size.width, layout.size.height))
    #expect(try pixel(full, at: CGPoint(x: 2, y: 2))[3] == 0)
    #expect(try pixel(full, at: CGPoint(x: frame.minX + 1, y: frame.minY + 1))[3] == 0)
    let inside = CGPoint(x: frame.minX + 16, y: frame.minY + 16)
    #expect(try pixel(full, at: inside)[3] > 240)
    #expect(try pixel(preview, at: CGPoint(x: inside.x * scale, y: inside.y * scale))[3] > 230)
    let target = folder.appending(path: "transparent.png")
    try await ShotComposition.export([red, red], options: options, pdf: false, to: target)
    let input = try #require(CGImageSourceCreateWithURL(target as CFURL, nil))
    let output = try #require(CGImageSourceCreateImageAtIndex(input, 0, nil))
    #expect(try pixel(output, at: CGPoint(x: 2, y: 2))[3] == 0)
    for background in ShotComposition.Background.allCases where background != .transparent {
      let rendered = try await ShotComposition.render(
        [red], options: .init(background: background), maximum: 200)
      let corner = try pixel(rendered, at: CGPoint(x: 1, y: 1))
      #expect(corner[3] == 255)
      #expect(background == .dark ? corner[0] < 30 : corner[0] > 200)
    }
  }

  /// 回读真实 PDF 页框和图像颜色，与当前页预览核对尺寸、页序与背景。
  @Test func a4PDFReadbackMatchesPagePreviews() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = [
      try await source(image(1, 0), at: folder.appending(path: "red.png")),
      try await source(
        image(0, 1, size: CGSize(width: 60, height: 100)), at: folder.appending(path: "blue.png")),
    ]
    for orientation in ShotComposition.Orientation.allCases {
      let options = ShotComposition.Options(
        paper: .a4, orientation: orientation, pdfMargin: 12, pdfBackground: .cream)
      let url = folder.appending(path: orientation.rawValue + ".pdf")
      try await ShotComposition.export(sources, options: options, pdf: true, to: url)
      let document = try #require(CGPDFDocument(url as CFURL))
      #expect(document.numberOfPages == sources.count)
      for (index, source) in sources.enumerated() {
        let expected = try ShotComposition.pdfPagePlan(size: source.size, options: options)
        let page = try #require(document.page(at: index + 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(
          abs(box.width - expected.size.width) < 0.01
            && abs(box.height - expected.size.height) < 0.01)
        let context = try #require(
          CGContext(
            data: nil, width: Int(ceil(box.width)), height: Int(ceil(box.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.drawPDFPage(page)
        let rendered = try #require(context.makeImage())
        let preview = try await ShotComposition.renderPDFPage(source, options: options)
        let center = CGPoint(x: box.midX, y: box.midY)
        #expect(try pixel(rendered, at: center)[index == 0 ? 0 : 2] > 240)
        #expect(try pixel(preview, at: center)[index == 0 ? 0 : 2] > 240)
        let paper = try pixel(preview, at: CGPoint(x: 2, y: 2))
        #expect(paper[0] > 240 && paper[2] < 235 && paper[3] == 255)
      }
    }
  }

  /// 翻页保留稳定图片身份与导出提示，移除、排序、快速切页和关闭不出现旧页回填。
  @Test func pageNavigationPreservesSourcesAndRejectsStalePreviews() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = [
      try await source(image(1, 0), at: folder.appending(path: "red.png")),
      try await source(image(0, 1), at: folder.appending(path: "blue.png")),
    ]
    let model = ShotCompositionModel()
    defer { model.clear() }
    model.sources = sources
    model.pdf = true
    model.options.paper = .a4
    model.refreshPreview()
    try await settlePreview(model)
    model.exported = folder.appending(path: "already-exported.pdf")
    model.showPage(1)
    try await settlePreview(model)
    #expect(
      model.previewSourceID == sources[1].id && model.previewPage == 1 && model.exported != nil)
    #expect(model.sources.map(\.id) == sources.map(\.id))
    model.showPage(0)
    model.showPage(1)
    try await settlePreview(model)
    let preview = try #require(model.preview)
    #expect(try pixel(preview, at: CGPoint(x: preview.width / 2, y: preview.height / 2))[2] > 240)
    model.showPage(2)
    #expect(model.previewSourceID == sources[1].id)
    model.move(sources[1].id, by: -1)
    #expect(model.previewSourceID == sources[1].id && model.previewPage == 0)
    model.remove(sources[1].id)
    try await settlePreview(model)
    #expect(model.previewSourceID == sources[0].id && model.previewPage == 0)
    model.refreshPreview()
    model.clear()
    try await Task.sleep(for: .milliseconds(180))
    #expect(model.preview == nil && !model.rendering && model.previewSourceID == nil)
  }

  /// 页面加载失败明确显示，切到有效页可恢复；整体 PDF 失败保持原文件。
  @Test func pageFailuresDoNotBecomeBlankSuccess() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = try await source(image(1, 0), at: folder.appending(path: "red.png"))
    let missing = ShotComposition.Source(
      id: UUID(), url: folder.appending(path: "missing.png"), size: valid.size, label: "缺失的第二页")
    let model = ShotCompositionModel()
    defer { model.clear() }
    model.sources = [missing, valid]
    model.pdf = true
    model.refreshPreview()
    try await settlePreview(model)
    #expect(model.preview == nil && model.error?.contains("缺失的第二页") == true)
    model.showPage(1)
    try await settlePreview(model)
    #expect(model.preview != nil && model.error == nil)
    let url = folder.appending(path: "keep.pdf")
    try Data("old PDF".utf8).write(to: url)
    await #expect(throws: ShotComposition.Failure.self) {
      try await ShotComposition.export(
        [valid, missing], options: .init(paper: .a4), pdf: true, to: url)
    }
    #expect(try Data(contentsOf: url) == Data("old PDF".utf8))
  }

  /// 异步等待当前预览，超时不能当作成功结果。
  private func settlePreview(_ model: ShotCompositionModel) async throws {
    for _ in 0..<300 where model.rendering { try await Task.sleep(for: .milliseconds(20)) }
    try #require(!model.rendering, "预览未在测试时限内完成")
  }

  /// 单张裁剪和旋转同时进入 PNG、PDF 与缩略图，原文件内容保持不变。
  @Test func perImageEditsReachBothExportsWithoutChangingFiles() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let picture = try ScreenshotTests.image(size: 120) { context in
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 60, y: 0, width: 60, height: 120))
    }
    var first = try await source(picture, at: folder.appending(path: "split.png"))
    let second = try await source(image(0, 1), at: folder.appending(path: "blue.png"))
    let before = try Data(contentsOf: first.url)
    first.edit = .init(crop: CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5), turns: 1)
    #expect(try first.adjustedSize() == CGSize(width: 60, height: 60))
    let thumbnail = try await ShotComposition.thumbnail(for: first)
    #expect(thumbnail.width == 60)
    let options = ShotComposition.Options(spacing: 0, margin: 0, pdfMargin: 0)
    let png = try await ShotComposition.render([first, second], options: options)
    #expect(try pixel(png, at: CGPoint(x: png.width / 2, y: png.height - 10))[0] > 240)
    let url = folder.appending(path: "edited.pdf")
    try await ShotComposition.export([first, second], options: options, pdf: true, to: url)
    let document = try #require(CGPDFDocument(url as CFURL))
    let page = try #require(document.page(at: 1))
    #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 60, height: 60))
    let context = try #require(
      CGContext(
        data: nil, width: 60, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.drawPDFPage(page)
    let pageImage = try #require(context.makeImage())
    #expect(try pixel(pageImage, at: CGPoint(x: 30, y: 30))[0] > 240)
    #expect(try Data(contentsOf: first.url) == before)
  }

  /// 像素对齐的小范围保留细节，转向前后的裁剪框往返不漂移；无效范围明确拒绝。
  @Test func cropGeometryAndQuarterTurnsRemainReversible() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    var item = try await source(
      image(1, 0, size: CGSize(width: 121, height: 79)), at: folder.appending(path: "odd.png"))
    item.edit = try ShotComposition.Edit(
      crop: CGRect(x: 13.0 / 121, y: 17.0 / 79, width: 37.0 / 121, height: 29.0 / 79)
    ).aligned(in: item.size)
    for turns in 0..<4 {
      item.edit.turns = turns
      let draft = ShotCropDraft(source: item, image: try await ShotComposition.cropPreview(item))
      #expect(try draft.appliedEdit() == item.edit)
      #expect(
        try item.adjustedSize()
          == (turns % 2 == 0 ? CGSize(width: 37, height: 29) : CGSize(width: 29, height: 37)))
    }
    let pixel = try ShotComposition.Edit(
      crop: CGRect(x: 0, y: 0, width: 1.0 / 121, height: 1.0 / 79)
    ).pixelRect(in: item.size)
    #expect(pixel.size == CGSize(width: 1, height: 1))
    for edit in [
      ShotComposition.Edit(crop: .zero), .init(crop: CGRect(x: -0.1, y: 0, width: 1, height: 1)),
      .init(turns: 4),
    ] {
      #expect(throws: ShotComposition.Failure.self) { try edit.pixelRect(in: item.size) }
    }
    var options = ShotComposition.Options(
      spacing: 0, margin: 0, widthMode: .custom, customWidth: 1001)
    item.edit = .init(crop: CGRect(x: 0, y: 0, width: 1.0 / 121, height: 1.0 / 79))
    let result = try await ShotComposition.render([item, item], options: options)
    #expect(result.width == 1001 && result.height == 2002)
    options.customWidth = 8192
    let limited = try ShotComposition.plan(
      sizes: [CGSize(width: 1, height: 1), CGSize(width: 1, height: 1)], options: options)
    #expect(limited.isLimited && limited.size.width < 8192)
  }

  /// 预设、自定义、自动与像素预算共同生效，最终宽度精确，整张图范围和比例保持。
  @Test func outputWidthControlsActualPNGAndReportsLimits() async throws {
    let sizes = [CGSize(width: 137, height: 83), CGSize(width: 61, height: 105)]
    for layout in ShotComposition.Layout.allCases {
      for (mode, custom, expected) in [
        (ShotComposition.WidthMode.compact, 0, 1024), (.wide, 0, 1920), (.custom, 1001, 1001),
      ] {
        let options = ShotComposition.Options(layout: layout, widthMode: mode, customWidth: custom)
        let plan = try ShotComposition.plan(sizes: sizes, options: options)
        #expect(plan.size.width == CGFloat(expected) && !plan.isLimited)
        for (frame, original) in zip(plan.frames, sizes) {
          #expect(abs(frame.width / frame.height - original.width / original.height) < 0.001)
          #expect(
            frame.minX >= -0.001 && frame.minY >= -0.001 && frame.maxX <= plan.size.width + 0.001
              && frame.maxY <= plan.size.height + 0.001)
        }
      }
    }
    let options = ShotComposition.Options(widthMode: .custom, customWidth: 8192)
    let long = try ShotComposition.plan(
      sizes: [CGSize(width: 100, height: 10000)], options: options)
    #expect(
      long.isLimited && long.requestedSize?.width == 8192
        && max(long.size.width, long.size.height) <= 8192)
    for value in [0, 8193] {
      #expect(throws: ShotComposition.Failure.self) {
        try ShotComposition.plan(
          sizes: sizes, options: .init(widthMode: .custom, customWidth: value))
      }
    }
    #expect(
      try ShotComposition.plan(sizes: sizes, options: .init(customWidth: -1))
        == ShotComposition.plan(sizes: sizes, options: .init()))
    #expect(
      try ShotComposition.pdfPagePlan(
        size: sizes[0], options: .init(paper: .a4, widthMode: .custom, customWidth: -1))
        == ShotComposition.pdfPagePlan(size: sizes[0], options: .init(paper: .a4)))
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = [
      try await source(image(1, 0), at: folder.appending(path: "a.png")),
      try await source(image(0, 1), at: folder.appending(path: "b.png")),
    ]
    let url = folder.appending(path: "width.png")
    try await ShotComposition.export(sources, options: .init(widthMode: .wide), pdf: false, to: url)
    let input = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(
      CGImageSourceCopyPropertiesAtIndex(input, 0, nil).map {
        ($0 as NSDictionary)[kCGImagePropertyPixelWidth] as? Int
      } == 1920)
  }

  /// 裁剪草稿只有应用才改变当前项，取消、替换、恢复及来源变化遵守同一版本契约。
  @Test func cropDraftLifecycleRejectsChangedSourceAndRestoresOriginal() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try await source(
      image(1, 0, size: CGSize(width: 200, height: 100)), at: folder.appending(path: "red.png"))
    let second = try await source(image(0, 1), at: folder.appending(path: "blue.png"))
    let model = ShotCompositionModel()
    defer { model.clear() }
    model.sources = [first, second]
    model.rotate(first.id, by: 1)
    #expect(model.sources[0].edit.turns == 1)
    model.beginCrop(first.id)
    try await settleCrop(model)
    let draft = try #require(model.cropDraft)
    #expect(!model.canImport)
    draft.selection = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    model.applyCrop()
    try await settlePreview(model)
    #expect(model.canImport && model.sources[0].edit.turns == 1)
    #expect(try model.sources[0].adjustedSize() == CGSize(width: 50, height: 200))
    model.restore(first.id)
    #expect(model.sources[0].edit.isIdentity && model.sources[0].url == first.url)
    model.beginCrop(first.id)
    model.cancelCrop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.cropDraft == nil && model.sources[0].edit.isIdentity)
    model.beginCrop(first.id)
    try await settleCrop(model)
    model.sources[0] = ShotComposition.Source(
      id: first.id, url: second.url, size: second.size, label: second.label)
    model.applyCrop()
    #expect(model.error?.contains("图片已变化") == true && model.sources[0].edit.isIdentity)
    model.beginCrop(first.id)
    model.clear()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.cropDraft == nil && model.cropTarget == nil && model.sources.isEmpty)
  }

  /// 缺失图片的缩略图失败独立呈现，不覆盖主流程错误，也不拿旧图冒充新调整。
  @Test func thumbnailFailurePreservesMainErrorAndOtherImages() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let valid = try await source(image(1, 0), at: folder.appending(path: "valid.png"))
    let missing = ShotComposition.Source(
      id: UUID(), url: folder.appending(path: "missing.png"), size: valid.size,
      label: "缺失的测试图片", thumbnail: valid.thumbnail)
    let model = ShotCompositionModel()
    defer { model.clear() }
    model.sources = [valid, missing]
    model.pdf = true
    model.rotate(missing.id, by: 1)
    model.showPage(0)
    model.error = "主流程错误保持原样"
    for _ in 0..<100 where model.sources[1].thumbnailError == nil || model.rendering {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.sources[1].thumbnailError?.contains(missing.label) == true)
    #expect(model.sources[1].adjustedThumbnail == nil)
    #expect(model.sources[0].edit.isIdentity && model.sources[0].thumbnailError == nil)
    #expect(model.error == "主流程错误保持原样")
    #expect(model.preview != nil && !model.rendering)
  }

  /// 原生裁剪画布从真实鼠标入口缩框、按原图像素移动，回车和 Esc 都只回调本草稿。
  @Test func nativeCropCanvasUsesImageCoordinatesWithoutTakingKey() throws {
    let picture = try image(1, 0, size: CGSize(width: 200, height: 100))
    let view = ShotCropView(image: picture, pixelSize: CGSize(width: 200, height: 100))
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 240, height: 240), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }
    let frame = view.imageFrame
    let start = CGPoint(x: frame.maxX, y: frame.maxY)
    let end = CGPoint(x: frame.midX, y: frame.midY)
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
    let move = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    )
    view.mouseDown(with: down)
    view.mouseDragged(with: move)
    view.mouseUp(with: move)
    #expect(abs(view.selection.width - 0.5) < 0.001 && abs(view.selection.height - 0.5) < 0.001)
    var applied = false
    var cancelled = false
    view.onApply = { applied = true }
    view.onCancel = { cancelled = true }
    for code in [kVK_RightArrow, kVK_Return, kVK_Escape] {
      let key = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: "",
          charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)))
      view.keyDown(with: key)
    }
    #expect(abs(view.selection.minX - 1.0 / 200) < 0.001)
    #expect(applied && cancelled && !window.isKeyWindow)
    view.selection = CGRect(x: 0, y: 0, width: 1, height: 1)
    let shrink = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
    view.keyDown(with: shrink)
    #expect(abs(view.selection.width - 199.0 / 200) < 0.00001)
    let expand = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
    view.keyDown(with: expand)
    #expect(view.selection == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  /// 等待当前草稿加载，读取失败或超时保持明确错误，不把缺失草稿当作成功。
  private func settleCrop(_ model: ShotCompositionModel) async throws {
    for _ in 0..<300 where model.cropTarget != nil && model.cropDraft == nil && model.error == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(model.cropDraft != nil, "裁剪草稿未就绪")
  }

  /// 单像素细节在导出与后台缩略图中都来自原图，缓存位图不继续持有完整原图存储。
  @Test func tinyCropKeepsDetailAndThumbnailStorageBounded() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let picture = try ScreenshotTests.image(size: 1500) { context in
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 1500, height: 1500))
      context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
      context.fill(CGRect(x: 997, y: 551, width: 1, height: 1))
    }
    let item = try await source(picture, at: folder.appending(path: "pixel.png"))
    let before = try Data(contentsOf: item.url)
    let model = ShotCompositionModel()
    defer { model.clear() }
    let other = ShotComposition.Source(
      id: UUID(), url: item.url, size: item.size, label: "第二张图片", thumbnail: item.thumbnail)
    model.sources = [item, other]
    model.beginCrop(item.id)
    try await settleCrop(model)
    let draft = try #require(model.cropDraft)
    draft.selection = CGRect(
      x: 997.0 / 1500, y: 551.0 / 1500, width: 1.0 / 1500, height: 1.0 / 1500)
    model.applyCrop()
    for _ in 0..<300 where model.sources[0].adjustedThumbnail == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    let thumbnail = try #require(model.sources[0].adjustedThumbnail)
    #expect(thumbnail.width == 1 && thumbnail.height == 1)
    let value = try pixel(thumbnail, at: .zero)
    #expect(value[1] > 240 && value[2] < 10)
    let data = try #require(thumbnail.dataProvider?.data)
    #expect(CFDataGetLength(data) < 4096)
    let output = try await ShotComposition.render(
      [model.sources[0], model.sources[0]],
      options: .init(spacing: 0, margin: 0, widthMode: .compact))
    let center = try pixel(output, at: CGPoint(x: output.width / 2, y: output.height / 2))
    #expect(center[1] > 240 && center[2] < 10)
    #expect(try Data(contentsOf: item.url) == before)
  }

  /// RGB 广色域图片在正交旋转时保留原色彩空间，逆操作还原尺寸。
  @Test func perImageRotationPreservesRGBColorSpace() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(
      CGContext(
        data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    let image = try #require(context.makeImage())
    let turned = try ShotComposition.adjusted(image, edit: .init(turns: 1))
    let restored = try ShotComposition.adjusted(turned, edit: .init(turns: 3))
    #expect(turned.width == 4 && turned.height == 8)
    #expect(turned.colorSpace?.name == space.name && restored.colorSpace?.name == space.name)
    #expect(restored.width == 8 && restored.height == 4)
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
