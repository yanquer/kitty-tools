// 第五轮标注增强：用假图片与非 key 屏外窗口验证方向、文字元数据、整笔擦除、尺寸和真实撤销顺序。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct AnnotationEnhancementTests {
  /// 创建带方向特征的小图，不截取用户屏幕。
  private func image() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 240, height: 160, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
    context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 5, y: 10, width: 30, height: 25))
    return try #require(context.makeImage())
  }

  /// 转成统一 RGBA 后比较像素，不依赖 CGImage 内部通道顺序。
  private func pixels(_ image: CGImage) throws -> Data {
    var data = Data(count: image.width * image.height * 4)
    try data.withUnsafeMutableBytes { bytes in
      let context = try #require(
        CGContext(
          data: bytes.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
  }

  /// 异步等候局部变换，期间让出主线程，不向系统发送键鼠。
  private func settle(_ working: () -> Bool) async throws {
    for _ in 0..<250 {
      if !working() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("图片变换未在五秒内结束")
  }

  /// 四次旋转和两次镜像是无损逆操作，垂直翻转也必须确实改变画面。
  @Test func orthogonalPixelsRoundTripWithoutResampling() async throws {
    let original = try image()
    var rotated = original
    for _ in 0..<4 { rotated = try await ImageTransform.image(rotated, action: .right) }
    #expect(try pixels(rotated) == pixels(original))
    for action in [ImageTransform.Action.horizontal, .vertical, .left, .right] {
      let changed = try await ImageTransform.image(original, action: action)
      #expect(try pixels(changed) != pixels(original))
      let restored = try await ImageTransform.image(changed, action: action.inverse)
      #expect(try pixels(restored) == pixels(original))
    }
  }

  /// 文字、序号与弯箭头的方向/命中跟随画面，旧编码缺省新字段时仍可读取。
  @Test func transformedAnnotationsRemainEditableAndCodable() throws {
    let size = CGSize(width: 240, height: 160)
    let original = Annotation(shape: .text("可编辑文字", origin: CGPoint(x: 20, y: 90)))
    let changed = original.transformed(.right, size: size)
    #expect(changed.id == original.id && changed.textTransform != nil)
    let probe = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
    let position = probe.applying(ImageTransform.mapping(.right, size: size))
    #expect(changed.contains(position))
    let restored = changed.transformed(.left, size: CGSize(width: 160, height: 240))
    #expect(abs(restored.bounds.minX - original.bounds.minX) < 0.001)
    #expect(abs(restored.bounds.maxY - original.bounds.maxY) < 0.001)
    let encoded = try JSONEncoder().encode(changed)
    #expect(try JSONDecoder().decode(Annotation.self, from: encoded) == changed)
    let old = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(Annotation.self, from: old).textTransform == nil)
    let arrow = Annotation(
      shape: .arrow(
        from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 60), bend: CGVector(dx: 0.1, dy: 0.3)))
    let reflected = arrow.transformed(.horizontal, size: size).transformed(.horizontal, size: size)
    #expect(reflected.shape == arrow.shape)
    #expect(
      changed.offset(by: CGSize(width: 20, height: 10)).contains(
        CGPoint(x: position.x + 20, y: position.y + 10)))
  }

  /// 尺寸使用输出像素，缩放或视网膜倍率不会被误当作厘米。
  @Test func dimensionsUseImagePixelsAndRenderTheirLabel() throws {
    let picture = try image()
    let line = Annotation(
      shape: .line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 120, y: 50)),
      style: .init(color: .red, option: 1))
    #expect(
      line.dimensionLabel(
        imageSize: CGSize(width: 240, height: 160), viewSize: CGSize(width: 120, height: 80))
        == "200 px")
    #expect(
      line.dimensionLabel(
        imageSize: CGSize(width: 240, height: 160), viewSize: CGSize(width: 240, height: 160))
        == "100 px")
    #expect(line.handles.count == 2)
    let rendered = try #require(
      Annotation.render(
        [line], over: picture, pixelRect: CGRect(x: 0, y: 0, width: 240, height: 160),
        viewSize: CGSize(width: 240, height: 160)))
    let bytes = [UInt8](try pixels(rendered))
    let white = stride(from: 0, to: bytes.count, by: 4).filter {
      bytes[$0] > 220 && bytes[$0 + 1] > 220 && bytes[$0 + 2] > 220
    }.count
    #expect(white > 5, "尺寸读数字形必须进入实际导出图")
  }

  /// 擦除按整段轨迹命中细线与文字，而不是只判断两端鼠标点。
  @Test func fastEraserStrokeHitsWholeObjects() {
    let line = Annotation(shape: .line(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 100)))
    #expect(line.intersectsEraser(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 200, y: 50)))
    #expect(!line.intersectsEraser(from: CGPoint(x: 0, y: 150), to: CGPoint(x: 200, y: 150)))
    let text = Annotation(shape: .text("文字", origin: CGPoint(x: 80, y: 75)))
    #expect(
      text.intersectsEraser(
        from: CGPoint(x: 0, y: text.bounds.midY), to: CGPoint(x: 200, y: text.bounds.midY)))
  }

  /// 屏外画布承载实际鼠标回调，整笔擦除只记一步，原图和未命中的对象保留。
  @Test func nativeCanvasEraserIsOneUndoStep() throws {
    let original = try image()
    let canvas = ScrollCanvas(image: original, scale: 1)
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 240, height: 160), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }
    let first = Annotation(shape: .line(from: CGPoint(x: 80, y: 10), to: CGPoint(x: 80, y: 90)))
    let second = Annotation(shape: .line(from: CGPoint(x: 150, y: 10), to: CGPoint(x: 150, y: 90)))
    let kept = Annotation(shape: .counter(1, center: CGPoint(x: 100, y: 135)))
    canvas.annotations = [first, second, kept]
    canvas.chooseEraser()
    for (type, point) in [
      (NSEvent.EventType.leftMouseDown, CGPoint(x: 10, y: 50)),
      (.leftMouseDragged, CGPoint(x: 220, y: 50)), (.leftMouseUp, CGPoint(x: 220, y: 50)),
    ] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      switch type {
      case .leftMouseDown: canvas.mouseDown(with: event)
      case .leftMouseDragged: canvas.mouseDragged(with: event)
      default: canvas.mouseUp(with: event)
      }
    }
    #expect(canvas.annotations == [kept] && canvas.canUndo)
    canvas.undo()
    #expect(canvas.annotations == [first, second, kept] && !canvas.canUndo)
    canvas.redo()
    #expect(canvas.annotations == [kept] && canvas.image === original && !window.isKeyWindow)
  }

  /// 变换和笔画撤销共享顺序，撤销变换不会丢失可编辑文字。
  @Test func nativeCanvasTransformUndoRedoKeepsAnnotations() async throws {
    let picture = try image()
    let canvas = ScrollCanvas(image: picture, scale: 1)
    let label = Annotation(shape: .text("继续编辑", origin: CGPoint(x: 20, y: 90)))
    canvas.annotations = [label]
    canvas.transform(.right)
    try await settle { canvas.isTransforming }
    #expect(canvas.image.width == 160 && canvas.image.height == 240 && canvas.canUndo)
    #expect(canvas.annotations.first?.textTransform != nil)
    canvas.undo()
    try await settle { canvas.isTransforming }
    #expect(try pixels(canvas.image) == pixels(picture))
    #expect(abs((canvas.annotations.first?.bounds.minX ?? -1) - label.bounds.minX) < 0.001)
    canvas.redo()
    try await settle { canvas.isTransforming }
    #expect(canvas.image.width == 160 && canvas.annotations.first?.id == label.id)
    canvas.cancelTransform()
  }

  /// 钉图本体的底图与成品同步变换，取消、锁定和撤销不生成新窗口。
  @Test func pinTransformsPreserveSourceAndRespectLock() async throws {
    let picture = try image()
    let board = PinBoard()
    let pin = PinPanel(
      image: picture, frame: CGRect(x: -20000, y: -20000, width: 240, height: 160), board: board)
    defer {
      pin.cancelTransform()
      pin.orderOut(nil)
    }
    pin.setLocked(true)
    pin.transform(.right)
    #expect(!pin.isTransforming && pin.original === picture)
    pin.setLocked(false)
    pin.transform(.right)
    try await settle { pin.isTransforming }
    #expect(pin.original.width == 160 && pin.image?.height == 240 && pin.canUndoTransform)
    pin.undoTransform()
    try await settle { pin.isTransforming }
    #expect(try pixels(pin.original) == pixels(picture))
    #expect(pin.outputScale == 1 && !pin.isKeyWindow)
    pin.transform(.vertical)
    pin.cancelTransform()
    try await Task.sleep(for: .milliseconds(60))
    #expect(try pixels(pin.original) == pixels(picture))
  }

  /// 真实截图框选视图中的擦除和撤销复用同一事件入口，测试窗口永远不成为 key。
  @Test func selectionCanvasEraserAndEscapePreserveTheFrame() {
    let h = SelectionInteractionTests.Harness()
    let region = CGRect(x: 100, y: 100, width: 900, height: 600)
    h.view.select(region)
    let line = Annotation(shape: .line(from: CGPoint(x: 500, y: 300), to: CGPoint(x: 500, y: 500)))
    h.view.annotations = [line]
    h.key(kVK_ANSI_E, "e")
    h.drag(CGPoint(x: 400, y: 400), CGPoint(x: 600, y: 400))
    #expect(h.view.annotations.isEmpty && h.view.selection == region)
    h.key(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == [line])
    h.key(kVK_Escape, "")
    #expect(h.view.selection == region)
  }

  /// 已旋转的文字通过真实编辑框改字后保留方向，撤销先回文字，再回图像方向。
  @Test func editingRotatedTextPreservesPoseAndUndoOrder() async throws {
    let canvas = ScrollCanvas(image: try image(), scale: 1)
    let origin = CGPoint(x: 20, y: 100)
    canvas.annotations = [Annotation(shape: .text("原文字", origin: origin))]
    canvas.transform(.right)
    try await settle { canvas.isTransforming }
    let text = try #require(canvas.annotations.first)
    canvas.beginEditing(at: origin, existing: text)
    let field = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
    field.string = "新文字"
    canvas.endEditing()
    #expect(canvas.annotations.first?.textTransform == text.textTransform)
    #expect(canvas.annotations.first?.shape == .text("新文字", origin: origin))
    canvas.undo()
    #expect(canvas.annotations.first?.shape == .text("原文字", origin: origin))
    canvas.undo()
    try await settle { canvas.isTransforming }
    #expect(canvas.image.width == 240 && canvas.image.height == 160)
    canvas.cancelTransform()
  }

  /// 超限和无效尺寸在真实分配入口的预算检查被拒绝，不能申请巨型画布。
  @Test func imageTransformRejectsInvalidAllocationBudget() {
    #expect(throws: ImageTransform.Failure.self) {
      try ImageTransform.validate(width: 40_000_001, height: 1)
    }
    #expect(throws: ImageTransform.Failure.self) {
      try ImageTransform.validate(width: 0, height: 100)
    }
  }

  /// P3 图片沿用其 RGB 色彩空间，方向改变不把广色域静默压成 sRGB。
  @Test func orthogonalTransformPreservesRGBColorSpace() async throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(
      CGContext(
        data: nil, width: 16, height: 12, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(colorSpace: space, components: [1, 0.2, 0.1, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
    let source = try #require(context.makeImage())
    let result = try await ImageTransform.image(source, action: .right)
    #expect(result.colorSpace?.name == source.colorSpace?.name)
    let restored = try await ImageTransform.image(result, action: .left)
    #expect(try pixels(restored) == pixels(source))
  }

  /// 自定义组合键通过真实 key-equivalent 入口采用，临时参数域不会写入用户偏好。
  @Test func customEraserCombinationUsesNativeKeyEquivalent() throws {
    let defaults = UserDefaults.standard
    let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    var temporary = previous
    temporary[ShotKey.erase.prefsKey] = try JSONEncoder().encode(
      HotKey(keyCode: kVK_ANSI_E, modifiers: cmdKey | shiftKey))
    defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
    let canvas = ScrollCanvas(image: try image(), scale: 1)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "E", charactersIgnoringModifiers: "e",
        isARepeat: false, keyCode: UInt16(kVK_ANSI_E)))
    #expect(canvas.performKeyEquivalent(with: event))
    #expect(canvas.erasing)
  }

  /// 双头箭头两端的实际轮廓均可擦除，不能只使用单头箭头的命中路径。
  @Test func eraserIncludesBothArrowheads() throws {
    let mark = Annotation(
      shape: .arrow(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 140, y: 60)),
      style: .init(option: 1))
    let ink = try #require(
      Annotation.arrowInk(
        from: CGPoint(x: 40, y: 60), to: CGPoint(x: 140, y: 60), width: mark.style.weight.lineWidth,
        double: true))
    var missed = 0
    for x in stride(from: 25, through: 155, by: 2) {
      for y in stride(from: 40, through: 80, by: 2) {
        let point = CGPoint(x: x, y: y)
        if ink.contains(point) && !mark.intersectsEraser(from: point, to: point, radius: 1) {
          missed += 1
        }
      }
    }
    #expect(missed == 0)
  }

}
