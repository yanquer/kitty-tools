// 第三轮截图工作流验证：原生纠错/撤销/复制，快捷截图目标校验，以及钉图收纳和专注的状态恢复。

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

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
    #expect(Array(HotKeyAction.allCases.suffix(expected.count)) == expected)
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
}
