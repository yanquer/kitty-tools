// 多选与关联文字的真实画布验证：用独立偏好、假图片和非 key 屏外窗口，不向系统发送键鼠。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor @Suite(.serialized)
struct AnnotationGroupTests {
  /// 独立画布和样式域，避免测试改变用户的工具记忆。
  private func harness() throws -> (canvas: ScrollCanvas, window: NSWindow, suite: String) {
    let picture = try ScreenshotTests.image(size: 240) { context in
      context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
    }
    let canvas = ScrollCanvas(image: picture, scale: 1)
    let suite = "kitty-group-tests-" + UUID().uuidString
    canvas.styleDefaults = try #require(UserDefaults(suiteName: suite))
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 240, height: 240), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    return (canvas, window, suite)
  }

  /// 仅回收本次隔离窗口与偏好。
  private func dispose(_ h: (canvas: ScrollCanvas, window: NSWindow, suite: String)) {
    h.canvas.cancelTransform()
    h.window.contentView = nil
    h.window.orderOut(nil)
    h.canvas.styleDefaults.removePersistentDomain(forName: h.suite)
  }

  /// 直接交给屏外视图的鼠标事件，不进入系统跟踪循环。
  private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags = [])
    throws -> NSEvent
  {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  /// 一次完整拖动，保留真实 mouseDown/Dragged/Up 调用链。
  private func drag(
    _ canvas: ScrollCanvas, from: CGPoint, to: CGPoint, flags: NSEvent.ModifierFlags = []
  ) throws {
    canvas.mouseDown(with: try mouse(.leftMouseDown, from, flags: flags))
    canvas.mouseDragged(with: try mouse(.leftMouseDragged, to, flags: flags))
    canvas.mouseUp(with: try mouse(.leftMouseUp, to, flags: flags))
  }

  /// 两个可辨认且不重叠的对象，使用空心矩形边线命中。
  private func pair() -> [Annotation] {
    [
      Annotation(shape: .rectangle(CGRect(x: 20, y: 30, width: 40, height: 40))),
      Annotation(shape: .rectangle(CGRect(x: 130, y: 30, width: 40, height: 40))),
    ]
  }

  /// 命令点选和命令框选只改变选择，后续整组移动一笔撤销，不改底图。
  @Test func commandSelectionAndGroupMoveUseOneUndoStep() throws {
    let h = try harness()
    defer { dispose(h) }
    let values = pair()
    h.canvas.annotations = values
    for point in [CGPoint(x: 20, y: 50), CGPoint(x: 130, y: 50)] {
      h.canvas.mouseDown(with: try mouse(.leftMouseDown, point, flags: .command))
      h.canvas.mouseUp(with: try mouse(.leftMouseUp, point, flags: .command))
    }
    #expect(Set(h.canvas.selectedItems.map(\.id)) == Set(values.map(\.id)))
    #expect(!h.canvas.canUndo)
    try drag(h.canvas, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 40, y: 60))
    #expect(h.canvas.annotations == values.map { $0.offset(by: CGSize(width: 20, height: 10)) })
    h.canvas.undo()
    #expect(
      h.canvas.annotations == values && !h.canvas.canUndo && h.canvas.selectedItems.count == 2)
    h.canvas.selectAnnotations([])
    try drag(h.canvas, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 185, y: 90), flags: .command)
    #expect(h.canvas.selectedItems.count == 2 && !h.window.isKeyWindow)
  }

  /// 混合工具只共同改色，不把矩形的实心选项或线宽静默套到箭头上。
  @Test func mixedStylesPreserveToolSpecificProperties() throws {
    let h = try harness()
    defer { dispose(h) }
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 20, y: 20, width: 30, height: 30)),
      style: .init(color: .red, weight: .small, option: 0))
    let arrow = Annotation(
      shape: .arrow(from: CGPoint(x: 80, y: 40), to: CGPoint(x: 180, y: 40)),
      style: .init(color: .blue, weight: .medium, option: 1))
    h.canvas.annotations = [rectangle, arrow]
    h.canvas.selectAnnotations([rectangle.id, arrow.id])
    #expect(h.canvas.selectionMix.mixedTools && h.canvas.selectionMix.color)
    h.canvas.restyle {
      $0.color = .pink
      $0.weight = .large
      $0.option = 1
    }
    #expect(
      h.canvas.annotations[0].style.color == .pink && h.canvas.annotations[1].style.color == .pink)
    #expect(
      h.canvas.annotations[0].style.weight == .small && h.canvas.annotations[0].style.option == 0)
    #expect(
      h.canvas.annotations[1].style.weight == .medium && h.canvas.annotations[1].style.option == 1)
    h.canvas.undo()
    #expect(h.canvas.annotations == [rectangle, arrow])
    let mask = Annotation(shape: .mosaic(CGRect(x: 0, y: 0, width: 10, height: 10)))
    #expect(!Annotation.selectionStyle([mask, arrow]).color)
  }

  /// 同类对象共用粗细与填充，原有不同值被明确识别为混合。
  @Test func sameToolBatchStyleAndDeleteRoundTrip() throws {
    let h = try harness()
    defer { dispose(h) }
    var values = pair()
    values[0].style.weight = .small
    values[1].style.weight = .large
    h.canvas.annotations = values
    h.canvas.selectAnnotations(Set(values.map(\.id)))
    #expect(h.canvas.selectionMix.weight)
    h.canvas.restyle {
      $0.weight = .medium
      $0.option = 1
    }
    #expect(h.canvas.annotations.allSatisfy { $0.style.weight == .medium && $0.style.option == 1 })
    h.canvas.deleteSelected()
    #expect(h.canvas.annotations.isEmpty)
    h.canvas.undo()
    #expect(h.canvas.annotations.count == 2)
    h.canvas.undo()
    #expect(h.canvas.annotations == values)
  }

  /// 批量复制经真实组合键入口，关联说明属于父对象，序号不与现有对象重复。
  @Test func duplicateGroupKeepsCaptionsAndAssignsFreshIds() throws {
    let h = try harness()
    defer { dispose(h) }
    let counter = Annotation(shape: .counter(1, center: CGPoint(x: 30, y: 30)))
    let letter = Annotation(
      shape: .counter(26, center: CGPoint(x: 30, y: 120)), style: .init(option: 1))
    var line = Annotation(shape: .line(from: CGPoint(x: 60, y: 70), to: CGPoint(x: 180, y: 70)))
    line.caption = .init(text: "下一步", style: line.captionStyle)
    h.canvas.annotations = [counter, line, letter]
    h.canvas.selectAnnotations([counter.id, line.id, letter.id])
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false,
        keyCode: UInt16(kVK_ANSI_D)))
    #expect(h.canvas.performKeyEquivalent(with: event))
    #expect(h.canvas.annotations.count == 6 && h.canvas.selectedItems.count == 3)
    #expect(Set(h.canvas.annotations.map(\.id)).count == 6)
    #expect(h.canvas.selectedItems.contains { $0.caption?.text == "下一步" })
    #expect(
      h.canvas.selectedItems.contains {
        if case .counter(2, _) = $0.shape { return $0.style.counterFormat == .digits }
        return false
      })
    #expect(
      h.canvas.selectedItems.contains {
        if case .counter(27, _) = $0.shape { return $0.style.counterFormat == .letters }
        return false
      })
    h.canvas.undo()
    #expect(h.canvas.annotations == [counter, line, letter])
  }

  /// 空剪贴板、平铺水印、放不下的整组和异常视口都走明确分支。
  @Test func annotationClipboardKeepsValueSnapshotAndPlacesOversizedGroup() throws {
    let clipboard = AnnotationClipboard()
    let viewport = CGRect(x: -40, y: 1200, width: 80, height: 60)
    #expect(clipboard.paste(in: viewport, existing: []).isEmpty)
    let watermark = Annotation.watermark(in: CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(!AnnotationClipboard.canCopy([watermark]))
    var marks = pair()
    #expect(clipboard.copy(marks + [watermark]) == 2)
    #expect(clipboard.copy([watermark]) == 0)
    marks[0].style.color = .green
    #expect(clipboard.paste(in: .zero, existing: []).isEmpty)
    let copies = clipboard.paste(in: viewport, existing: [])
    let first = try #require(copies.first)
    #expect(copies.count == 2 && first.style.color == .red)
    #expect(first.bounds.midX == viewport.midX && first.bounds.midY == viewport.midY)
    #expect(copies[1].bounds.midX - first.bounds.midX == 110)
  }

  /// 截图画布的框选、拖动与撤销保持原截图区域。
  @Test func selectionCanvasGroupActionsPreserveScreenshotRegion() {
    let h = SelectionInteractionTests.Harness()
    let region = CGRect(x: 100, y: 100, width: 900, height: 600)
    h.view.select(region)
    let values = [
      Annotation(shape: .rectangle(CGRect(x: 250, y: 250, width: 40, height: 40))),
      Annotation(shape: .rectangle(CGRect(x: 450, y: 250, width: 40, height: 40))),
    ]
    h.view.annotations = values
    h.drag(CGPoint(x: 210, y: 210), CGPoint(x: 510, y: 320), flags: .command)
    #expect(h.view.selectedItems.count == 2 && h.view.selection == region)
    h.drag(CGPoint(x: 250, y: 270), CGPoint(x: 270, y: 280))
    #expect(h.view.annotations == values.map { $0.offset(by: CGSize(width: 20, height: 10)) })
    h.key(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == values && h.view.selection == region)
    h.key(kVK_Delete, "")
    #expect(h.view.annotations.isEmpty)
    h.key(kVK_ANSI_Z, "z", flags: .command)
    #expect(h.view.annotations == values)
  }

  /// 关联文字通过真实输入框提交，空文字只移除说明，线条形态与身份保留。
  @Test func captionEditingAndUndoKeepTheParentShape() throws {
    let h = try harness()
    defer { dispose(h) }
    let line = Annotation(shape: .arrow(from: CGPoint(x: 30, y: 50), to: CGPoint(x: 180, y: 50)))
    h.canvas.annotations = [line]
    h.canvas.selectedAnnotation = line.id
    h.canvas.editCaption()
    let field = try #require(h.canvas.subviews.compactMap { $0 as? EditorField }.first)
    field.string = "请求成功"
    h.canvas.endEditing()
    let updated = try #require(h.canvas.annotations.first)
    #expect(updated.id == line.id && updated.shape == line.shape && updated.caption?.text == "请求成功")
    let moved = updated.offset(by: CGSize(width: 12, height: 20))
    let first = try #require(updated.captionAnnotation)
    let second = try #require(moved.captionAnnotation)
    #expect(abs(second.bounds.minX - first.bounds.minX - 12) < 0.001)
    #expect(abs(second.bounds.minY - first.bounds.minY - 20) < 0.001)
    h.canvas.editCaption()
    let editing = try #require(h.canvas.subviews.compactMap { $0 as? EditorField }.first)
    editing.string = ""
    h.canvas.endEditing()
    #expect(
      h.canvas.annotations.first?.shape == line.shape && h.canvas.annotations.first?.caption == nil)
    h.canvas.undo()
    #expect(h.canvas.annotations.first?.caption?.text == "请求成功")
    h.canvas.undo()
    #expect(h.canvas.annotations == [line])
  }

  /// 说明的命中与编码绑定所属对象，图像转向后保持与像素画面相同的局部方向。
  @Test func captionGeometrySurvivesRotationAndEncoding() throws {
    var line = Annotation(shape: .arrow(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 180, y: 60)))
    line.caption = .init(text: "说明", style: line.captionStyle)
    let label = try #require(line.captionAnnotation)
    #expect(line.contains(CGPoint(x: label.bounds.midX, y: label.bounds.midY)))
    #expect(
      line.intersectsEraser(
        from: CGPoint(x: label.bounds.midX, y: label.bounds.midY),
        to: CGPoint(x: label.bounds.midX, y: label.bounds.midY)))
    let size = CGSize(width: 240, height: 240)
    for action in ImageTransform.Action.allCases {
      let changed = line.transformed(action, size: size)
      let text = try #require(changed.captionAnnotation)
      let expected = label.bounds.applying(ImageTransform.mapping(action, size: size))
      #expect(
        abs(text.bounds.minX - expected.minX) < 0.001
          && abs(text.bounds.minY - expected.minY) < 0.001)
      let data = try JSONEncoder().encode(changed)
      #expect(try JSONDecoder().decode(Annotation.self, from: data) == changed)
    }
    let old = Annotation(shape: line.shape)
    #expect(
      try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(old)).caption == nil)
  }

  /// 超长说明不替换正在编辑的有效内容；多选时不能把文字误绑定到某一条线。
  @Test func captionInputBudgetAndSingleHostAreEnforced() throws {
    let h = try harness()
    defer { dispose(h) }
    let first = Annotation(shape: .line(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 150, y: 40)))
    let second = Annotation(shape: .line(from: CGPoint(x: 30, y: 120), to: CGPoint(x: 150, y: 120)))
    h.canvas.annotations = [first, second]
    h.canvas.selectAnnotations([first.id, second.id])
    #expect(!h.canvas.canEditCaption)
    h.canvas.selectAnnotations([first.id])
    h.canvas.editCaption()
    let field = try #require(h.canvas.subviews.compactMap { $0 as? EditorField }.first)
    var problems: [String] = []
    h.canvas.onProblem = { problems.append($0) }
    field.insertText(
      String(repeating: "x", count: 2001), replacementRange: NSRange(location: 0, length: 0))
    #expect(field.string.isEmpty && !problems.isEmpty)
    h.canvas.endEditing()
    #expect(h.canvas.annotations.count == 2)
  }

  /// 组复制未拖开时恢复原选择，真正拖开后副本一起移动并可整步撤销。
  @Test func optionGroupDragAndCancelledMarquee() throws {
    let h = try harness()
    defer { dispose(h) }
    let values = pair()
    let ids = Set(values.map(\.id))
    h.canvas.annotations = values
    h.canvas.selectAnnotations(ids)
    try drag(h.canvas, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 20, y: 50), flags: .option)
    #expect(h.canvas.annotations == values && Set(h.canvas.selectedItems.map(\.id)) == ids)
    #expect(!h.canvas.canUndo)
    try drag(h.canvas, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 40, y: 80), flags: .option)
    #expect(h.canvas.annotations.count == 4 && h.canvas.selectedItems.count == 2)
    #expect(
      h.canvas.selectedItems.map(\.shape)
        == values.map { $0.offset(by: CGSize(width: 20, height: 30)).shape })
    h.canvas.undo()
    #expect(h.canvas.annotations == values && !h.canvas.canUndo)
    h.canvas.selectAnnotations([values[0].id])
    h.canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 5, y: 5), flags: .command))
    h.canvas.mouseDragged(
      with: try mouse(.leftMouseDragged, CGPoint(x: 190, y: 90), flags: .command))
    #expect(h.canvas.selectedItems.count == 2)
    let escape = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
        keyCode: UInt16(kVK_Escape)))
    h.canvas.keyDown(with: escape)
    h.canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 190, y: 90)))
    #expect(h.canvas.selectedItems.map(\.id) == [values[0].id])
  }

  /// 变换缓存保留每个历史版本自己的说明内容、样式与方向，不复用另一版本的元数据。
  @Test func captionTransformCachePreservesHistoryVersions() throws {
    var line = Annotation(shape: .line(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 150, y: 70)))
    line.caption = .init(text: "原说明", style: line.captionStyle)
    var edited = line
    edited.caption?.text = "修改后的说明"
    edited.caption?.style.fontSize = 25
    var oriented = edited
    oriented.caption?.orientation = ImageTransform.Pose(CGAffineTransform(rotationAngle: .pi / 2))
    let batches = [[line], [edited], [oriented], [Annotation(id: line.id, shape: line.shape)]]
    for action in ImageTransform.Action.allCases {
      let size = CGSize(width: 240, height: 240)
      #expect(
        ImageTransform.annotations(batches, action: action, size: size)
          == batches.map { $0.map { $0.transformed(action, size: size) } })
    }
  }

  /// 截图工具栏回调和双击说明进入同一编辑器，编辑字号不改变普通文字工具记忆。
  @Test func selectionCaptionButtonAndDoubleClickUseNativeEditor() throws {
    let h = SelectionInteractionTests.Harness()
    h.view.select(CGRect(x: 80, y: 80, width: 900, height: 600))
    let line = Annotation(shape: .arrow(from: CGPoint(x: 250, y: 240), to: CGPoint(x: 650, y: 240)))
    h.view.annotations = [line]
    h.view.selectedAnnotation = line.id
    let before = h.view.styleDefaults.dictionaryRepresentation()
    let bar = try #require(h.view.subviews.compactMap { $0 as? EditorToolbar }.first)
    let button = try #require(bar.button(for: .caption))
    #expect(button.isEnabled)
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    let field = try #require(h.view.subviews.compactMap { $0 as? EditorField }.first)
    field.string = "关联说明"
    let tray = try #require(h.view.subviews.compactMap { $0 as? StyleBar }.first)
    tray.onFontStep(1)
    _ = h.view.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(
      h.view.styleDefaults.dictionaryRepresentation() as NSDictionary == before as NSDictionary)
    let label = try #require(h.view.annotations[0].captionAnnotation)
    h.down(CGPoint(x: label.bounds.midX, y: label.bounds.midY), clicks: 2)
    #expect(h.view.subviews.compactMap { $0 as? EditorField }.first?.string == "关联说明")
    _ = h.view.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    #expect(h.view.annotations[0].shape == line.shape)
  }
}
