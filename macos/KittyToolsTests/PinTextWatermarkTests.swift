// 原位选字与水印的真实原生入口验证：只使用合成图、隔离偏好和屏外窗口，复制在出口拦截。

import AppKit
import Carbon.HIToolbox
import Testing
import VisionKit

@testable import KittyTools

@MainActor @Suite(.serialized)
struct PinTextWatermarkTests {
  /// 构造两行明确文字与空白图，绝不采集用户屏幕。
  private func picture(text: Bool = true) throws -> CGImage {
    try ScreenshotTests.image(size: 240) { context in
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
      guard text else { return }
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      for (value, y) in [("Alpha 123", 155), ("Beta 456", 85)] {
        NSAttributedString(
          string: value,
          attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
        ).draw(at: CGPoint(x: 20, y: y))
      }
    }
  }

  /// 等待异步识别完成，超时明确失败，不能把没有样本当作正常结果。
  private func settle(_ running: () -> Bool) async throws {
    for _ in 0..<300 where running() { try await Task.sleep(for: .milliseconds(20)) }
    try #require(!running(), "识别未在测试时限内完成")
  }

  /// 将原生文字层放在不可成为 key 的屏外窗口，建立真实布局但不激活应用。
  private func stage(_ view: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 240, height: 240), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFront(nil)
    return window
  }

  /// 系统实况文本产生跨行选区，复制经受控出口，原图与用户剪贴板均保持独立。
  @Test func nativeTextSelectionCopiesAcrossLines() async throws {
    let image = try picture()
    let view = PinTextSelection(frame: CGRect(x: 0, y: 0, width: 240, height: 240))
    let window = stage(view)
    defer {
      view.stop()
      window.orderOut(nil)
      window.contentView = nil
    }
    var copies: [String] = []
    view.onCopy = { copies.append($0) }
    view.open(image)
    try await settle { view.state == .loading }
    #expect(view.state == .ready && !window.isKeyWindow && copies.isEmpty)
    try await Task.sleep(for: .milliseconds(150))
    #expect(view.hitTest(CGPoint(x: 70, y: 170)) != nil)
    #expect(view.hitTest(CGPoint(x: 210, y: 210)) == nil)
    let text = view.overlay.text
    let start = try #require(text.range(of: "123")?.lowerBound)
    let end = try #require(text.range(of: "Beta")?.upperBound)
    view.overlay.selectedRanges = [start..<end]
    #expect(view.copySelection())
    #expect(copies.count == 1 && copies[0].contains("123") && copies[0].contains("Beta"))
    view.overlay.resetSelection()
    #expect(!view.copySelection() && copies.count == 1)
    #expect(view.overlay.preferredInteractionTypes == .textSelection)
    view.viewport = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.5)
    view.overlay.setContentsRectNeedsUpdate()
    try await Task.sleep(for: .milliseconds(150))
    #expect(view.overlay.contentsRect.width == 2 && view.overlay.contentsRect.minX == -0.5)
    #expect(abs(view.overlay.contentsRect.minY + 0.8) < 0.001)
    #expect(view.hitTest(CGPoint(x: 20, y: 152)) != nil)
    view.stop()
    #expect(view.state == .off && view.overlay.analysis == nil && !view.hasSelection)
  }

  /// 空图、失败、关闭后的晚到结果及重新开启均保持真实状态，识别请求顺序执行。
  @Test func textStatesAndStaleResultsAreSeparated() async throws {
    let image = try picture(text: false)
    let view = PinTextSelection(frame: .zero)
    view.open(image)
    try await settle { view.state == .loading }
    #expect(view.state == .empty)
    let blank = try #require(view.overlay.analysis)
    enum ControlledFailure: Error { case offlineProbe }
    view.scan = { _ in throw ControlledFailure.offlineProbe }
    view.open(image)
    try await settle { view.state == .loading }
    #expect(view.state == .failed)
    var active = 0
    var maximum = 0
    var calls = 0
    view.scan = { _ in
      calls += 1
      active += 1
      maximum = max(maximum, active)
      defer { active -= 1 }
      try await Task.sleep(for: .milliseconds(60))
      return blank
    }
    view.open(image)
    try await Task.sleep(for: .milliseconds(20))
    view.stop()
    view.open(image)
    try await settle { view.state == .loading }
    #expect(view.state == .empty && calls == 2 && maximum == 1)
    view.open(image)
    view.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(view.state == .off && view.overlay.analysis == nil)
  }

  /// 钉图菜单、窗口分发和图像变更使用真实入口，退出选字先保留钉图。
  @Test func pinMenuAndWindowDispatchKeepImageOperations() async throws {
    let image = try picture()
    let board = PinBoard()
    var imageCopies: [CGImage] = []
    board.copyAsFile = { image, _ in imageCopies.append(image) }
    let pin = PinPanel(
      image: image, frame: CGRect(x: -20000, y: -20000, width: 240, height: 240), board: board)
    defer {
      pin.textSelection?.stop()
      pin.orderOut(nil)
    }
    let view = try #require(pin.contentView)
    let selector = try #require(pin.textSelection)
    var copies: [String] = []
    selector.onCopy = { copies.append($0) }
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let command = try #require(view.menu(for: event)?.items.first { $0.title == "原位选字" })
    #expect(NSApp.sendAction(try #require(command.action), to: command.target, from: command))
    try await settle { selector.state == .loading }
    let systemMenu = NSMenu()
    systemMenu.addItem(NSMenuItem(title: "系统复制占位", action: nil, keyEquivalent: ""))
    let sharedMenu = selector.overlayView(
      selector.overlay, updatedMenuFor: systemMenu, for: event, at: .zero)
    #expect(sharedMenu.items.contains { $0.title == "退出原位选字" })
    #expect(!sharedMenu.items.contains { $0.title == "系统复制占位" })
    let text = selector.overlay.text
    selector.overlay.selectedRanges = [try #require(text.range(of: "Alpha"))]
    let copy = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: pin.windowNumber, context: nil, characters: "c",
        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))
    pin.sendEvent(copy)
    #expect(copies == ["Alpha"] && pin.image === image)
    let file = try #require(sharedMenu.items.first { $0.title == "拷贝为 PNG 文件" })
    #expect(file.isEnabled)
    #expect(NSApp.sendAction(try #require(file.action), to: file.target, from: file))
    #expect(imageCopies.count == 1 && imageCopies.first === image)
    #expect(copies == ["Alpha"])
    let escape = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: pin.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Escape)))
    pin.sendEvent(escape)
    #expect(selector.state == .off && pin.image === image && !pin.isKeyWindow)
    selector.open(image)
    pin.applyEdits(image: image, annotations: [])
    #expect(selector.state == .off)
  }

  /// 水印编码、复制、平移与四次旋转保留同一文档语义，旧文字仍可正常解码。
  @Test func watermarkMetadataRoundTripsWithTransforms() throws {
    let item = Annotation.watermark(in: CGRect(x: 10, y: 20, width: 180, height: 160))
    let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(item))
    #expect(decoded == item)
    let copy = item.duplicated(offset: CGSize(width: 10, height: 12))
    #expect(
      copy.id != item.id && copy.watermark?.area == item.watermark?.area.offsetBy(dx: 10, dy: 12))
    var rotated = item
    for _ in 0..<4 { rotated = rotated.transformed(.right, size: CGSize(width: 240, height: 240)) }
    #expect(rotated == item)
    let old = Annotation(shape: .text("原文字", origin: .zero))
    #expect(
      try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(old)).watermark == nil)
  }

  /// 水印使用真实画布文本框、样式与撤销；样式记忆隔离，清空只删除当前水印。
  @Test func watermarkCanvasEditingAndUndoAreIndependent() throws {
    let canvas = ScrollCanvas(image: try picture(), scale: 1)
    let suite = "kitty-watermark-tests-" + UUID().uuidString
    canvas.styleDefaults = try #require(UserDefaults(suiteName: suite))
    let window = stage(canvas)
    defer {
      window.orderOut(nil)
      canvas.styleDefaults.removePersistentDomain(forName: suite)
    }
    let before = canvas.styleDefaults.data(forKey: Prefs.screenshotToolStyles)
    canvas.addWatermark()
    let field = try #require(canvas.subviews.compactMap { $0 as? EditorField }.first)
    field.string = "内部资料"
    canvas.restyle {
      $0.color = .blue
      $0.fontSize = 30
    }
    canvas.endEditing()
    canvas.restyleWatermark {
      $0.angle = -45
      $0.opacity = 0.5
    }
    #expect(
      canvas.annotations[0].watermark?.angle == -45
        && canvas.annotations[0].watermark?.opacity == 0.5)
    #expect(canvas.annotations[0].style.color == .blue)
    #expect(
      canvas.styleDefaults.data(forKey: Prefs.screenshotToolStyles) == before)
    canvas.undo()
    #expect(canvas.annotations[0].watermark?.angle == 30)
    let current = canvas.annotations[0]
    if case .text(_, let origin) = current.shape {
      canvas.beginEditing(at: origin, existing: current)
    }
    let editing = try #require(canvas.subviews.compactMap { $0 as? EditorField }.first)
    var refused = false
    canvas.onProblem = { _ in refused = true }
    editing.insertText(
      String(repeating: "a", count: 201),
      replacementRange: NSRange(location: 0, length: (editing.string as NSString).length))
    #expect(refused && editing.string == "内部资料")
    editing.string = ""
    canvas.endEditing()
    #expect(canvas.annotations.isEmpty)
    canvas.undo()
    #expect(canvas.annotations == [current])
  }

  /// 截图真实按钮和原生 HUD 菜单贯通水印参数及撤销，不直接改模型冒充入口。
  @Test func watermarkSelectionButtonsApplyParameters() throws {
    let h = SelectionInteractionTests.Harness()
    let area = CGRect(x: 100, y: 100, width: 900, height: 600)
    h.view.select(area)
    let toolbar = try #require(h.view.subviews.compactMap { $0 as? EditorToolbar }.first)
    let add = try #require(toolbar.button(for: .watermark))
    #expect(NSApp.sendAction(try #require(add.action), to: add.target, from: add))
    let field = try #require(h.fieldEditor)
    field.string = "评审专用"
    h.key(kVK_Escape, "")
    let tray = try #require(h.styleBar)
    let button = try #require(
      ScreenshotSnapshotTests.descendants(of: tray).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "水印透明度"
      })
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    let menu = try #require(h.menu)
    let half = try #require(
      ScreenshotSnapshotTests.descendants(of: menu).first { $0.accessibilityLabel() == "50%" })
    #expect(half.accessibilityPerformPress())
    #expect(h.view.annotations.count == 1 && h.view.annotations[0].watermark?.opacity == 0.5)
    #expect(h.view.annotations[0].watermark?.area == area && h.view.selection == area)
    h.key(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations[0].watermark?.opacity == 0.2)
    let normal = Annotation(shape: .text("普通文字", origin: .zero))
    #expect(Annotation.selectionStyle([normal, h.view.annotations[0]]).mixedTools)
  }

  /// 水印只在指定区域改变像素，透明度单调生效，背景不透明度与原图保留。
  @Test func watermarkExportClipsAndHonorsOpacity() throws {
    let image = try picture(text: false)
    let size = CGSize(width: 240, height: 240)
    var item = Annotation.watermark(in: CGRect(x: 30, y: 30, width: 180, height: 180))
    item.style.color = .black
    let rect = CGRect(origin: .zero, size: size)
    let faint = try #require(
      Annotation.render([item], over: image, pixelRect: rect, viewSize: size))
    item.watermark?.opacity = 0.8
    let strong = try #require(
      Annotation.render([item], over: image, pixelRect: rect, viewSize: size))
    let a = try rgba(faint)
    let b = try rgba(strong)
    var changed = 0
    var invalidAlpha = 0
    var outsideChanges = 0
    var faintInk = 0
    var strongInk = 0
    for y in 0..<240 {
      for x in 0..<240 {
        let index = (y * 240 + x) * 4
        if a[index + 3] != 255 || b[index + 3] != 255 { invalidAlpha += 1 }
        if x < 30 || x >= 210 || y < 30 || y >= 210 {
          if a[index] != 255 || b[index] != 255 { outsideChanges += 1 }
        } else {
          if a[index] < 255 { changed += 1 }
          faintInk += 255 - Int(a[index])
          strongInk += 255 - Int(b[index])
        }
      }
    }
    #expect(changed > 100 && strongInk > faintInk * 2 && invalidAlpha == 0 && outsideChanges == 0)
  }

  /// 像素统一为 RGBA，避免图像内部通道顺序影响输出断言。
  private func rgba(_ image: CGImage) throws -> Data {
    var data = Data(count: image.width * image.height * 4)
    try data.withUnsafeMutableBytes { bytes in
      let context = try #require(
        CGContext(
          data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
  }
}
