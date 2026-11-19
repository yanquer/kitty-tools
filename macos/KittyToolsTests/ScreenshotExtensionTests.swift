// 第二轮截图增强验证：钉图编辑与取景、静态指针坐标、演示画板复用及插件默认状态；不激活窗口。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct ScreenshotExtensionTests {
  /// 创建已知像素颜色的图片，不读取真实屏幕或用户图片。
  private func image(red: CGFloat, blue: CGFloat, size: CGSize = CGSize(width: 80, height: 60))
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

  /// 在绘图坐标中采样一个像素，统一颜色通道，不依赖源图存储布局。
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

  /// 直接交给屏外视图的按键，不发到系统，不抢键盘。
  private func key(_ code: Int, flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)))
  }

  @Test func localZoomAnchorsAndClampsWithoutChangingTheImage() {
    var zoom = PinZoom()
    zoom.toggle()
    zoom.zoom(by: 2, at: CGPoint(x: 0.25, y: 0.75))
    #expect(zoom.magnification == 2)
    let anchored = CGPoint(
      x: zoom.viewport.minX + 0.25 * zoom.viewport.width,
      y: zoom.viewport.minY + 0.75 * zoom.viewport.height)
    #expect(anchored == CGPoint(x: 0.25, y: 0.75))
    zoom.pan(
      from: zoom.center, by: CGSize(width: 10000, height: -10000),
      viewSize: CGSize(width: 200, height: 100))
    #expect(zoom.viewport.minX == 0 && zoom.viewport.maxY == 1)
    zoom.zoom(by: 100, at: .zero)
    #expect(zoom.magnification == 8)
    zoom.zoom(by: 0.0001, at: .zero)
    #expect(zoom.viewport == CGRect(x: 0, y: 0, width: 1, height: 1))
    let before = zoom
    zoom.zoom(by: .nan, at: .zero)
    #expect(zoom == before)
    zoom.toggle()
    #expect(!zoom.isEnabled && zoom.magnification == 1)
  }

  @Test func pinEditingAndLocalZoomKeepOnePanelAndCopyFullImage() throws {
    let original = try image(red: 0, blue: 1)
    let replacement = try image(red: 1, blue: 0)
    let board = PinBoard()
    let panel = PinPanel(
      image: original, frame: CGRect(x: -20000, y: -20000, width: 80, height: 60), board: board)
    #expect(panel.outputScale == 1 && panel.editingScale == 1)
    let view = try #require(panel.contentView)
    var edits = 0
    board.edit = { chosen in
      #expect(chosen === panel)
      edits += 1
    }
    view.keyDown(with: try key(kVK_ANSI_E, flags: .command, window: panel))
    #expect(edits == 1)
    let annotation = Annotation(shape: .rectangle(CGRect(x: 5, y: 5, width: 20, height: 10)))
    panel.applyEdits(image: replacement, annotations: [annotation])
    #expect(panel.original === original)
    #expect(panel.image === replacement && panel.annotations == [annotation])
    let frame = panel.frame
    view.keyDown(with: try key(kVK_ANSI_Z, flags: .command, window: panel))
    #expect(panel.frame == frame)
    let menu = try #require(view.menu(for: try key(kVK_ANSI_Z, flags: .command, window: panel)))
    #expect(menu.items.contains { $0.title == "退出局部放大" && $0.state == .on })
    var copied: CGImage?
    board.output = { action, image, _ in if action == .copy { copied = image } }
    view.keyDown(with: try key(kVK_ANSI_C, flags: .command, window: panel))
    #expect(copied === replacement)
    #expect(copied?.width == original.width && copied?.height == original.height)
    #expect(!panel.isVisible && !panel.isKeyWindow)
  }

  @Test func pinEditorHasExplicitApplyAndStrictRendering() throws {
    let bar = EditorToolbar(mode: .pinShot)
    #expect(bar.button(for: .output(.pin))?.accessibilityLabel() == "应用到钉图")
    #expect(bar.button(for: .output(.copy)) == nil)
    #expect(bar.button(for: .output(.pin))?.toolTip == "应用到钉图（↩）")
    let base = try image(red: 0, blue: 1)
    let board = PinBoard()
    let fitted = PinPanel(
      image: base, frame: CGRect(x: -20000, y: -20000, width: 40, height: 30), board: board,
      scale: 1)
    #expect(fitted.editingScale == 1 && fitted.outputScale == 2)
    let canvas = ScrollCanvas(image: base, scale: 1)
    #expect(canvas.composedStrictly() === base)
    canvas.annotations = [Annotation(shape: .rectangle(CGRect(x: 5, y: 5, width: 20, height: 20)))]
    #expect(canvas.composedStrictly() !== base)
  }

  @Test func cursorUsesTopLeftHotspotAndRealDisplayScale() async throws {
    let frame = ScreenshotCursor.rectangle(
      location: CGPoint(x: 10, y: 10),
      size: CGSize(width: 4, height: 8), hotSpot: CGPoint(x: 1, y: 2))
    #expect(frame == CGRect(x: 9, y: 4, width: 4, height: 8))
    let cursor = ScreenshotCursor(
      image: try image(red: 1, blue: 0, size: CGSize(width: 8, height: 16)), frame: frame)
    let background = try image(red: 0, blue: 1)
    let result = try await cursor.render(
      over: background, screen: CGRect(x: 0, y: 0, width: 40, height: 30))
    #expect(result.width == 80 && result.height == 60)
    #expect(try pixel(result, at: CGPoint(x: 20, y: 12))[0] > 240)
    #expect(try pixel(result, at: CGPoint(x: 2, y: 2))[2] > 240)
    let shifted = ScreenshotCursor(image: cursor.image, frame: frame.offsetBy(dx: -100, dy: 80))
    let other = try await shifted.render(
      over: background, screen: CGRect(x: -100, y: 80, width: 40, height: 30))
    #expect(try pixel(other, at: CGPoint(x: 20, y: 12))[0] > 240)
  }

  @Test func cursorDoesNotAllocateOnOtherScreensAndRejectsInvalidGeometry() async throws {
    let background = try image(red: 0, blue: 1)
    let cursor = ScreenshotCursor(
      image: try image(red: 1, blue: 0), frame: CGRect(x: -200, y: -200, width: 20, height: 20))
    #expect(
      try await cursor.render(over: background, screen: CGRect(x: 0, y: 0, width: 40, height: 30))
        === background)
    await #expect(throws: ScreenshotCursor.Failure.self) {
      try await cursor.render(over: background, screen: .zero)
    }
    #expect(Prefs.defaults[Prefs.screenshotShowsCursor] as? Bool == false)
  }

  @Test func whiteboardAndOperationModeReuseRecordingCanvasWithoutShowingWindows() throws {
    let canvas = try #require(
      RecordingCanvas(region: CGRect(x: -20000, y: -20000, width: 400, height: 300), label: "演示画布"))
    defer { canvas.close() }
    canvas.apply(.mode(.pen))
    canvas.setWhiteboard(true)
    #expect(!canvas.panel.ignoresMouseEvents)
    #expect(canvas.view.layer?.backgroundColor?.alpha == 1)
    canvas.setWhiteboard(false)
    canvas.apply(.mode(.pointer))
    #expect(canvas.panel.ignoresMouseEvents && canvas.view.layer?.backgroundColor == nil)
    #expect(!canvas.panel.isVisible && !canvas.panel.isKeyWindow)
    canvas.setWhiteboard(true)
    canvas.close()
    #expect(canvas.view.layer?.backgroundColor == nil)
    let bar = RecordingToolsBar(presentation: true)
    defer { bar.close(animated: false) }
    var changed = false
    bar.onWhiteboard = { changed = true }
    let button = try #require(bar.whiteboardButton())
    NSApp.sendAction(button.action!, to: button.target, from: button)
    #expect(changed)
    let recordingBar = RecordingToolsBar()
    defer { recordingBar.close(animated: false) }
    #expect(recordingBar.whiteboardButton() == nil)
  }

  @Test func presentationInkLimitKeepsExistingStrokesAndReportsRejection() throws {
    let canvas = try #require(
      RecordingCanvas(region: CGRect(x: -20000, y: -20000, width: 120, height: 80), label: "演示画布"))
    defer { canvas.close() }
    canvas.apply(.mode(.pen))
    var notices: [String] = []
    canvas.onNotice = { notices.append($0) }
    for _ in 0...RecordingTools.maximumAnnotations {
      for (type, point) in [
        (NSEvent.EventType.leftMouseDown, CGPoint(x: 10, y: 10)),
        (.leftMouseUp, CGPoint(x: 35, y: 25)),
      ] {
        let event = try #require(
          NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
        canvas.view.onMouse(event)
      }
    }
    #expect(canvas.state.annotations.count == RecordingTools.maximumAnnotations)
    #expect(notices.count == 1 && notices[0].contains("256"))
    #expect(!canvas.panel.isVisible)
  }

  @Test func presentationPluginIsOptInAndAppendsHotKeyIdentity() {
    #expect(Feature.presentation.isPlugin && !Feature.presentation.defaultOn)
    #expect(Feature.presentation.pluginFacts != nil)
    #expect(Feature.presentation.page == .presentation)
    #expect(HotKeyAction.presentation.feature == .presentation)
    #expect(HotKeyAction.presentation.defaultHotKey == nil)
    #expect(HotKeyAction.allCases.last == .presentation)
    #expect(HotKeyAction(rawValue: "presentation") == .presentation)
    #expect(ShortcutsSheet.groups(enabled: []).allSatisfy { $0.page != .presentation })
    #expect(ShortcutsSheet.groups(enabled: [.presentation]).contains { $0.page == .presentation })
    #expect(
      HotKeyAction.visibleSections(enabled: [.presentation]).contains {
        $0.actions == [.presentation]
      })
    #expect(!HotKeyAction.visibleSections(enabled: []).flatMap(\.actions).contains(.presentation))
  }
}
