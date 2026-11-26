// 第三轮截图工作流验证：原生纠错/撤销/复制，快捷截图目标校验，以及钉图收纳和专注的状态恢复。

import AppKit
import Carbon.HIToolbox
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import KittyTools

@MainActor @Suite(.serialized)
struct ScreenshotWorkflowTests {
  /// 创建可辨识的测试图片，不读取用户屏幕。
  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 200, height: 100, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    return try #require(context.makeImage())
  }

  /// 查找实际 SwiftUI 桥接出来的原生编辑器，避免测试只验证模型副本。
  private func textView(in view: NSView) -> RecognitionText? {
    if let text = view as? RecognitionText { return text }
    for child in view.subviews { if let found = textView(in: child) { return found } }
    return nil
  }

  /// 在不可成为 key 的屏外窗口中建立真实结果编辑器。
  private func editor(_ model: RecognitionModel) throws -> (NSWindow, RecognitionText) {
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 780, height: 540),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: RecognitionResultView(model: model).frame(width: 780, height: 540))
    window.orderFront(nil)
    settle()
    let content = try #require(window.contentView)
    return (window, try #require(textView(in: content)))
  }

  /// 给原生撤销事件组和 SwiftUI 更新一次完整的主循环，不发送按键或抢焦点。
  private func settle() {
    RunLoop.main.run(until: Date.now.addingTimeInterval(0.08))
  }

  /// 直接操作原生编辑器，核对纠错、撤销重做、恢复与剪切复制均读取当前文字。
  @Test func correctionsUndoRestoreAndCopyUseCurrentNativeText() throws {
    let model = RecognitionModel()
    model.accept("号码 1234\n原识别文字")
    var copied: [String] = []
    model.write = { copied.append($0) }
    let (window, text) = try editor(model)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    text.insertText("5678", replacementRange: NSRange(location: 3, length: 4))
    text.breakUndoCoalescing()
    settle()
    #expect(model.text == "号码 5678\n原识别文字" && model.isEdited)
    model.copy(selectionOnly: false)
    #expect(copied.last == "号码 5678\n原识别文字")
    #expect(model.canUndo)
    model.undo()
    settle()
    #expect(model.text == model.originalText)
    model.redo()
    settle()
    #expect(model.text == "号码 5678\n原识别文字")
    model.restoreOriginal()
    settle()
    #expect(model.text == model.originalText && !model.isEdited)
    model.undo()
    settle()
    #expect(model.text == "号码 5678\n原识别文字")
    text.setSelectedRange(NSRange(location: 3, length: 4))
    text.cut(nil)
    settle()
    #expect(copied.last == "5678")
    #expect(model.text == "号码 \n原识别文字")
    #expect(!window.isKeyWindow)
  }

  /// 重复文本通过原始区间区分，光标移动、插入和删除后不按行号或内容猜测来源。
  @Test func recognitionLocationFollowsUnchangedNativeRanges() throws {
    let model = RecognitionModel()
    model.image = try image()
    let lines: [OCR.Line] = [
      .init(text: "相同订单 A-100", box: CGRect(x: 0.15, y: 0.76, width: 0.62, height: 0.12)),
      .init(text: "分隔 🐈", box: CGRect(x: 0.11, y: 0.55, width: 0.6, height: 0.1)),
      .init(text: "相同订单 A-100", box: CGRect(x: 0.15, y: 0.25, width: 0.62, height: 0.12)),
    ]
    model.accept(lines: lines)
    let (window, text) = try editor(model)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    let duplicate = lines[0].text
    let second = (text.string as NSString).range(of: duplicate, options: .backwards)
    text.setSelectedRange(NSRange(location: second.location + 2, length: 0))
    #expect(model.location == .init(line: 3, box: lines[2].box))
    let firstLine = (text.string as NSString).range(of: duplicate + "\n")
    text.setSelectedRange(firstLine)
    #expect(model.location?.line == 1)
    let inserted = "相同订单 A-100\n"
    text.insertText(inserted, replacementRange: NSRange(location: 0, length: 0))
    settle()
    text.setSelectedRange(NSRange(location: 2, length: 3))
    #expect(model.location == nil)
    let insertedCount = (inserted as NSString).length
    text.setSelectedRange(NSRange(location: insertedCount + 2, length: 3))
    #expect(model.location?.line == 1)
    let moved = (text.string as NSString).range(of: duplicate, options: .backwards)
    text.setSelectedRange(moved)
    #expect(model.location?.line == 3 && model.selectedText == duplicate)
    text.insertText("改字", replacementRange: NSRange(location: moved.location, length: 2))
    settle()
    text.setSelectedRange(NSRange(location: moved.location + 1, length: 0))
    #expect(model.location == nil)
    let separator = (text.string as NSString).range(of: lines[1].text + "\n")
    text.insertText("", replacementRange: separator)
    settle()
    text.setSelectedRange(NSRange(location: insertedCount + 3, length: 0))
    #expect(model.location?.line == 1)
    text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
    #expect(model.location == nil)
    model.restoreOriginal()
    settle()
    text.setSelectedRange(second)
    #expect(model.location?.line == 3 && model.text == model.originalText && !window.isKeyWindow)
  }

  /// 原地处于组字时撤下高亮，原生撤销回到完整原文后可重新定位。
  @Test func recognitionLocationHandlesCompositionAndUndo() throws {
    let model = RecognitionModel()
    let lines: [OCR.Line] = [
      .init(text: "第一行 🐈", box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1)),
      .init(text: "第二行", box: CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.1)),
    ]
    model.accept(lines: lines)
    let (window, text) = try editor(model)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    let row = (text.string as NSString).range(of: "第二行")
    text.setSelectedRange(row)
    #expect(model.location?.line == 2)
    text.setMarkedText(
      "zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: row)
    #expect(text.hasMarkedText() && model.location == nil && model.text == model.originalText)
    text.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    text.breakUndoCoalescing()
    settle()
    text.setSelectedRange(NSRange(location: row.location, length: 1))
    #expect(model.location == nil && model.text.hasSuffix("中文"))
    model.undo()
    settle()
    text.setSelectedRange(row)
    #expect(model.text == model.originalText && model.location?.line == 2)
    model.redo()
    settle()
    text.setSelectedRange(NSRange(location: row.location, length: 1))
    #expect(model.location == nil)
  }

  /// 保持 Vision 坐标方向、中心留白和 Retina 的实际像素换算一致。
  @Test func recognitionImageLayoutProjectsAndRevealsBoxes() {
    let box = CGRect(x: 0.5, y: 0.1, width: 0.4, height: 0.1)
    let pixels = CGSize(width: 1000, height: 3000)
    let viewport = CGSize(width: 320, height: 300)
    let fit = RecognitionImageLayout(
      pixels: pixels, viewport: viewport, displayScale: 2, actualPixels: false)
    #expect(fit.image == CGRect(x: 110, y: 0, width: 100, height: 300))
    #expect(fit.offset(for: box) == .zero)
    let actual = RecognitionImageLayout(
      pixels: pixels, viewport: viewport, displayScale: 2, actualPixels: true)
    #expect(actual.document == CGSize(width: 500, height: 1500))
    let frame = actual.frame(for: box)
    #expect(abs(frame.minY - 1200) < 0.001 && frame.minX == 250)
    #expect(actual.offset(for: box) == CGPoint(x: 180, y: 1125))
  }

  /// 删除全部文字后保留原编辑器，并能恢复同一份原始识别结果。
  @Test func deletingAllKeepsEditorAndCanRestoreOriginal() throws {
    let model = RecognitionModel()
    model.accept("完整原文")
    let (window, text) = try editor(model)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    text.insertText(
      "", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
    text.breakUndoCoalescing()
    settle()
    #expect(model.text.isEmpty && model.originalText == "完整原文")
    let content = try #require(window.contentView)
    #expect(textView(in: content) === text)
    model.restoreOriginal()
    settle()
    #expect(model.text == "完整原文")
    #expect(text.history.levelsOfUndo == 100)
  }

  /// 组字确认后使用提交内容，超限输入被明确拒绝，不写入系统剪贴板。
  @Test func compositionAndInputBudgetPreserveCurrentText() throws {
    let model = RecognitionModel()
    model.accept("原文")
    let (window, text) = try editor(model)
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    text.setMarkedText(
      "zhong", selectedRange: NSRange(location: 5, length: 0),
      replacementRange: NSRange(location: 0, length: 2))
    #expect(text.hasMarkedText())
    #expect(model.text == "原文")
    text.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    settle()
    #expect(!text.hasMarkedText() && model.text == "中文")
    text.insertText(
      String(repeating: "x", count: 128_001),
      replacementRange: NSRange(location: 0, length: 2))
    settle()
    #expect(model.text == "中文" && model.editNotice != nil)
    text.insertText("字", replacementRange: NSRange(location: 1, length: 1))
    settle()
    #expect(model.text == "中字" && model.editNotice == nil)
  }

  /// 验证缺少/越界区域拒绝、负坐标屏幕选择及独立复制存储意图。
  @Test func quickTargetsRejectMissingOrPartiallyOffscreenRegions() throws {
    let screens = [
      CGRect(x: -1000, y: 0, width: 1000, height: 800),
      CGRect(x: 0, y: 0, width: 1440, height: 900),
    ]
    let make: (CGRect?) -> QuickScreenshot.Request = {
      QuickScreenshot.Request(
        action: .lastCopy, pointer: .zero, foregroundPID: nil,
        sourceName: nil, lastRegion: $0, includesCursor: false)
    }
    #expect(throws: QuickScreenshot.Failure.self) {
      try QuickScreenshot.region(for: make(nil), screens: screens)
    }
    #expect(throws: QuickScreenshot.Failure.self) {
      try QuickScreenshot.region(
        for: make(CGRect(x: -10, y: 20, width: 200, height: 100)), screens: screens)
    }
    let region = CGRect(x: -800, y: 40, width: 200, height: 100)
    let chosen = try QuickScreenshot.region(for: make(region), screens: screens)
    #expect(chosen.index == 0 && chosen.region == region)
    let screen = QuickScreenshot.Request(
      action: .screenSave, pointer: CGPoint(x: -500, y: 200), foregroundPID: nil, sourceName: nil,
      lastRegion: nil, includesCursor: false)
    #expect(try QuickScreenshot.region(for: screen, screens: screens).region == screens[0])
    #expect(QuickScreenshot.Action.allCases.filter(\.saves).count == 3)
  }

  /// 无上次区域时在系统采集之前拒绝，验证真实入口保留原始原因及关联日志。
  @Test func invalidQuickTargetFailsBeforeCapturing() async {
    let request = QuickScreenshot.Request(
      action: .lastCopy, pointer: .zero, foregroundPID: nil,
      sourceName: nil, lastRegion: nil, includesCursor: false)
    do {
      _ = try await ScreenCapture.quick(request, operation: "round3-invalid-target-probe")
      Issue.record("无上次区域不应产出图片")
    } catch let failure as QuickScreenshot.Failure {
      #expect(failure.message == "还没有上次截图区域，请先框选截图一次")
    } catch {
      Issue.record("错误原因不符：\(error)")
    }
  }

  /// 按前台进程与普通窗口层筛选，并保证新增动作不改变原有快捷键身份。
  @Test func foregroundWindowSelectionSkipsOtherAppsAndMenuLayers() {
    let bounds = CGRect(x: 10, y: 10, width: 200, height: 100).dictionaryRepresentation
    let rows: [[String: Any]] = [
      [
        kCGWindowOwnerPID as String: 77, kCGWindowLayer as String: 24, kCGWindowNumber as String: 1,
        kCGWindowBounds as String: bounds,
      ],
      [
        kCGWindowOwnerPID as String: 88, kCGWindowLayer as String: 0, kCGWindowNumber as String: 2,
        kCGWindowBounds as String: bounds,
      ],
      [
        kCGWindowOwnerPID as String: 77, kCGWindowLayer as String: 0, kCGWindowNumber as String: 3,
        kCGWindowBounds as String: bounds,
      ],
    ]
    #expect(QuickScreenshot.windowID(in: rows, pid: 77) == 3)
    #expect(QuickScreenshot.windowID(in: rows, pid: 99) == nil)
    let expected = QuickScreenshot.Action.allCases.map(HotKeyAction.quickScreenshot)
    #expect(Array(HotKeyAction.allCases.dropLast(3).suffix(expected.count)) == expected)
    #expect(expected.allSatisfy { $0.feature == .screenshot && $0.defaultHotKey == nil })
    #expect(expected.allSatisfy { HotKeyAction(rawValue: $0.rawValue) == $0 })
  }

  /// 收纳展开仅修改几何，原图与输出倍率保持一致，屏幕边缘能恢复可见区域。
  @Test func miniatureRestoresGeometryAndPreservesFullImage() throws {
    let board = PinBoard()
    let original = try image()
    let frame = CGRect(x: -20000, y: -20000, width: 200, height: 100)
    let pin = PinPanel(image: original, frame: frame, board: board)
    pin.setMiniature(true)
    #expect(pin.isMiniature && pin.frame.size == CGSize(width: 96, height: 64))
    #expect(pin.image === original && pin.outputScale == 1)
    pin.setMiniature(false)
    #expect(pin.frame == frame && !pin.isMiniature)
    let restored = PinPanel.restoredMiniature(
      CGRect(x: 780, y: 590, width: 96, height: 64),
      size: CGSize(width: 300, height: 200), within: CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(restored == CGRect(x: 500, y: 400, width: 300, height: 200))
    #expect(!pin.isVisible)
  }

  /// 专注、全局隐藏、关闭及编辑结束使用统一可见性，不重新显示本应隐藏的钉图。
  @Test func closingFocusedPinAndGlobalHideRestoreTheCorrectPictures() throws {
    let board = PinBoard()
    let original = try image()
    for index in 0..<2 {
      board.pin(
        original, frame: CGRect(x: -20000 + index * 240, y: -20000, width: 200, height: 100))
    }
    defer { board.closeAll() }
    let first = try #require(board.panels.first)
    let second = try #require(board.panels.last)
    first.finishPopIn()
    second.finishPopIn()
    board.toggleFocus(first)
    #expect(first.isVisible && !second.isVisible)
    board.toggleHidden()
    #expect(!first.isVisible && !second.isVisible)
    board.close(first)
    #expect(board.focused == nil && !second.isVisible)
    board.toggleHidden()
    #expect(second.isVisible)
    board.setEditing(second, true)
    #expect(!second.isVisible)
    board.toggleHidden()
    board.setEditing(second, false)
    #expect(!second.isVisible)
    board.toggleHidden()
    #expect(second.isVisible && !second.isKeyWindow)
  }

  /// 用真实 PNG 文件验证导入，不访问用户照片、系统剪贴板或屏幕。
  private func importFixture() throws -> (directory: URL, files: [URL]) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-import-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let files = [directory.appending(path: "第一张.png"), directory.appending(path: "第二张.png")]
    let data = try ScreenshotTests.encode(image(), as: .png)
    for file in files { try data.write(to: file) }
    return (directory, files)
  }

  /// 有界等待导入和预览任务完成，异步让出主线程，不创建可交互窗口。
  private func settleImport(_ model: ShotCompositionModel) async throws {
    for _ in 0..<250 {
      if !model.preparing && !model.rendering { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("导入或预览未在五秒内完成")
  }

  /// 复制成功后的源文件改变或删除，不会改变已经提交给预览与输出的图片。
  @Test func importedSnapshotsAreImmutableAndOriginalsUntouched() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let original = try Data(contentsOf: fixture.files[0])
    let batch = try await ImageImport.snapshots(fixture.files)
    defer { ImageImport.discard(batch.directory) }
    #expect(batch.sources.count == 2 && batch.bytes == original.count * 2)
    #expect(try Data(contentsOf: fixture.files[0]) == original)
    try Data("外部文件后续改动".utf8).write(to: fixture.files[0])
    try FileManager.default.removeItem(at: fixture.files[1])
    for source in batch.sources {
      #expect(try Data(contentsOf: source.url) == original)
    }
    let output = try await ShotComposition.render(batch.sources, options: .init())
    #expect(output.width > 0 && output.height > 0)
  }

  /// EXIF 旋转后导入尺寸与解码方向一致，排版不会按未转正尺寸拉伸图片。
  @Test func importedOrientationMatchesPreviewAndDecodedPixels() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let rotated = fixture.directory.appending(path: "旋转方向.jpg")
    try ScreenshotTests.encode(image(), as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
      .write(to: rotated)
    let batch = try await ImageImport.snapshots([rotated])
    defer { ImageImport.discard(batch.directory) }
    let source = try #require(batch.sources.first)
    let decoded = try await ImageImport.decode(.file(rotated))
    #expect(source.size == CGSize(width: 100, height: 200))
    #expect(decoded.width == 100 && decoded.height == 200)
  }

  /// 损坏、超额与非本机地址明确失败；取消不返回可采用的半批副本。
  @Test func invalidImportsAndCancellationPreserveFailureReasons() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let broken = fixture.directory.appending(path: "损坏.png")
    try Data("invalid image".utf8).write(to: broken)
    await #expect(throws: ImageImport.Failure.self) {
      try await ImageImport.snapshots([fixture.files[0], broken])
    }
    await #expect(throws: ImageImport.Failure.self) {
      try await ImageImport.snapshots([fixture.files[0]], remainingBytes: 1)
    }
    await #expect(throws: ImageImport.Failure.self) {
      try await ImageImport.decode(.file(URL(string: "https://example.com/image.png")!))
    }
    let task = Task { try await ImageImport.snapshots(fixture.files) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  /// 动画输入不能被静默截成第一帧；剪贴板图片数据也执行相同输入上限。
  @Test func animatedAndOversizedClipboardImagesAreRejected() async throws {
    let data = NSMutableData()
    let target = try #require(
      CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
    let picture = try image()
    CGImageDestinationAddImage(target, picture, nil)
    CGImageDestinationAddImage(target, picture, nil)
    try #require(CGImageDestinationFinalize(target))
    await #expect(throws: ImageImport.Failure.self) {
      try await ImageImport.decode(.data(data as Data))
    }
    let large = Data(count: ImageImport.maximumFileBytes + 1)
    await #expect(throws: ImageImport.Failure.self) { try await ImageImport.decode(.data(large)) }
  }

  /// 追加、替换与移除保留顺序及稳定身份，失败不丢原列表，最后一项移除后回到可导入空态。
  @Test func compositionImportMutationsAreAtomicAndKeepStableIdentity() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let model = ShotCompositionModel()
    defer { model.clear() }
    model.importFiles([fixture.files[0]])
    try await settleImport(model)
    #expect(model.sources.count == 1 && model.preview != nil)
    let first = try #require(model.sources.first)
    model.importFiles([fixture.files[1]])
    try await settleImport(model)
    #expect(model.sources.count == 2 && model.sources[0].id == first.id)
    model.importFiles([fixture.files[1]], replacing: first.id)
    try await settleImport(model)
    #expect(
      model.sources[0].id == first.id
        && model.sources[0].label == fixture.files[1].lastPathComponent)
    #expect(model.sources[0].url != first.url)
    let before = model.sources.map(\.url)
    model.importFiles([fixture.files[0], fixture.directory.appending(path: "missing.png")])
    try await settleImport(model)
    #expect(model.sources.map(\.url) == before && model.error != nil && model.preview != nil)
    let truncated = fixture.directory.appending(path: "只有文件头.png")
    try Data(Data(contentsOf: fixture.files[0]).prefix(33)).write(to: truncated)
    model.importFiles([fixture.files[0], truncated])
    try await settleImport(model)
    #expect(model.sources.map(\.url) == before && model.error != nil && model.preview != nil)
    model.importFiles(Array(repeating: fixture.files[0], count: 20))
    #expect(model.sources.count == 2 && model.error != nil && !model.preparing)
    for id in model.sources.map(\.id) { model.remove(id) }
    #expect(model.sources.isEmpty && model.preview == nil && !model.rendering && model.error == nil)
    model.clear()
    #expect(!FileManager.default.fileExists(atPath: first.url.path))
    #expect(try Data(contentsOf: fixture.files[0]) == Data(contentsOf: fixture.files[1]))
  }

  /// 导入后立刻关闭，旧请求不得回填列表、预览或错误。
  @Test func closingCompositionInvalidatesPendingImport() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let model = ShotCompositionModel()
    model.importFiles(fixture.files)
    model.clear()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.sources.isEmpty && model.preview == nil && model.error == nil && !model.preparing)
  }

  /// 锁定不改图、不抢键盘，滚轮与捏合保持几何，菜单和旁白仍能解锁与明确关闭。
  @Test func lockedPinKeepsGeometryAndExplicitExitActions() throws {
    let board = PinBoard()
    let pin = PinPanel(
      image: try image(), frame: CGRect(x: -20000, y: -20000, width: 200, height: 100), board: board
    )
    let view = try #require(pin.contentView)
    let frame = pin.frame
    pin.setLocked(true)
    pin.setMiniature(true)
    #expect(pin.isLocked && pin.frame == frame && !pin.isMiniature)
    let wheel = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 120, wheel2: 0,
        wheel3: 0))
    view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
    #expect(pin.frame == frame && !pin.isKeyWindow)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.first { $0.title == "解锁钉图" }?.state == .on)
    #expect(menu.items.first { $0.title == "继续标注" }?.isEnabled == false)
    #expect(menu.items.first { $0.title == "关闭" }?.isEnabled == true)
    let actions = try #require(view.accessibilityCustomActions())
    #expect(actions.contains { $0.name == "解锁钉图" } && actions.contains { $0.name == "关闭" })
    #expect(!actions.contains { $0.name == "继续标注" })
    let unlock = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false,
        keyCode: UInt16(kVK_ANSI_L)))
    view.keyDown(with: unlock)
    #expect(!pin.isLocked && pin.frame == frame && !pin.isKeyWindow)
  }

  /// 图片处理动作只追加在既有 Carbon 身份后，入口归截图且默认不占按键。
  @Test func imageProcessingActionsAppendWithoutChangingEarlierIdentities() {
    let added: [HotKeyAction] = [.imageEditFile, .imageEditClipboard, .imageCompose]
    #expect(Array(HotKeyAction.allCases.suffix(3)) == added)
    #expect(added.allSatisfy { $0.feature == .screenshot && $0.defaultHotKey == nil })
    #expect(added.allSatisfy { HotKeyAction(rawValue: $0.rawValue) == $0 })
  }

  /// 外部图片沿用真实标注遮罩的严格输出，成功返回合成图，原文件保持原样。
  @Test func externalImageAnnotationEmitsComposedPixelsWithoutChangingSource() async throws {
    let fixture = try importFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let bytes = try Data(contentsOf: fixture.files[0])
    let original = try await ImageImport.decode(.file(fixture.files[0]))
    var outputs: [CGImage] = []
    let mark = Annotation(
      shape: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 30)),
      style: .init(color: .red, option: 1))
    let editor = AnnotateOverlay(image: original, scale: 1, annotations: [mark], strictOutput: true)
    {
      action, image, scale, annotations in
      #expect(action == .copy && scale == 1 && annotations.count == 1)
      outputs.append(image)
    }
    defer { editor.close() }
    let content = try #require(editor.panel.contentView as? AnnotateOverlayView)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: UInt16(kVK_Return)))
    content.keyDown(with: event)
    #expect(outputs.count == 1 && outputs.first !== original)
    #expect(outputs.first?.width == original.width && outputs.first?.height == original.height)
    #expect(try Data(contentsOf: fixture.files[0]) == bytes)
    #expect(!editor.panel.isVisible && !editor.panel.isKeyWindow)
  }

  /// 不支持的位图合成返回失败时保留会话并显示原因，不能输出未标注的底图。
  @Test func strictExternalCompositionFailureDoesNotEmitOriginal() throws {
    let bytes = Data(repeating: 0, count: 4 * 16 * 16)
    let provider = try #require(CGDataProvider(data: bytes as CFData))
    let original = try #require(
      CGImage(
        width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceCMYK(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let mark = Annotation(shape: .rectangle(CGRect(x: 1, y: 1, width: 10, height: 10)))
    var emitted = false
    var problem: String?
    var closed = false
    let editor = AnnotateOverlay(image: original, scale: 1, annotations: [mark], strictOutput: true)
    { _, _, _, _ in emitted = true }
    defer { editor.close() }
    editor.onProblem = { problem = $0 }
    editor.onClose = { closed = true }
    let content = try #require(editor.panel.contentView as? AnnotateOverlayView)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: UInt16(kVK_Return)))
    content.keyDown(with: event)
    #expect(!emitted && !closed && problem?.contains("标注合成失败") == true)
    #expect(!editor.panel.isVisible && !editor.panel.isKeyWindow)
  }

  /// 常见灰度 PNG 先转成可绘制 RGB，保证实际图片加标注后能合成。
  @Test func grayscaleImportedImageCanBeAnnotated() async throws {
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    context.setFillColor(CGColor(gray: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    let gray = try #require(context.makeImage())
    let data = try ScreenshotTests.encode(gray, as: .png)
    let image = try await ImageImport.decode(.data(data))
    #expect(image.colorSpace?.model == .rgb && image.width == 32 && image.height == 16)
    let mark = Annotation(shape: .rectangle(CGRect(x: 2, y: 2, width: 15, height: 10)))
    #expect(
      Annotation.render(
        [mark], over: image, pixelRect: CGRect(x: 0, y: 0, width: 32, height: 16),
        viewSize: CGSize(width: 32, height: 16)) != nil)
  }

}
