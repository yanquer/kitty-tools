// 拼图单张裁剪：在原面板内显示转向后的整图与可拖动选区，只提交几何，不改原文件。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// 草稿与原图片版本绑定，取消时直接丢弃，应用时再交给拼图模型核对身份。
@Observable final class ShotCropDraft {
  let source: ShotComposition.Source
  let image: CGImage
  let pixelSize: CGSize
  var selection: CGRect

  /// 选区在转向后的整图上显示，最终通过逆矩阵回到原图坐标。
  init(source: ShotComposition.Source, image: CGImage) {
    self.source = source
    self.image = image
    pixelSize =
      source.edit.turns % 2 == 0
      ? source.size : CGSize(width: source.size.height, height: source.size.width)
    selection = source.edit.crop.applying(source.edit.rotation).intersection(
      CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  /// 四条边分别落到原图像素格上，反复进入裁剪不累积漂移。
  func appliedEdit() throws -> ShotComposition.Edit {
    var edit = source.edit
    edit.crop = selection.applying(edit.rotation.inverted())
    return try edit.aligned(in: source.size)
  }
}

/// 原面板内的裁剪区域，保留文件名、取消、恢复裁剪与应用出口。
struct ShotCropEditor: View {
  @Bindable var draft: ShotCropDraft
  var apply: () -> Void
  var cancel: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text("裁剪：\(draft.source.label)").font(.system(size: 13, weight: .semibold))
        .lineLimit(2).help(draft.source.label)
      ShotCropCanvas(draft: draft, apply: apply, cancel: cancel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text("拖动边角调整，框内移动，框外重选；方向键移动，⌥方向键收边，⌘方向键扩边。")
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("恢复裁剪") { draft.selection = CGRect(x: 0, y: 0, width: 1, height: 1) }
        Spacer()
        Button("取消", action: cancel)
        Button("应用裁剪", action: apply).buttonStyle(BrandButtonStyle())
      }
    }
  }
}

/// 使用同一原生画布处理鼠标与键盘，窗口不被激活，框选几何复用截图组件。
private struct ShotCropCanvas: NSViewRepresentable {
  let draft: ShotCropDraft
  let apply: () -> Void
  let cancel: () -> Void

  /// 只创建本面板中的视图，不建立新的窗口或全局输入监听。
  func makeNSView(context: Context) -> ShotCropView {
    let view = ShotCropView(image: draft.image, pixelSize: draft.pixelSize)
    updateNSView(view, context: context)
    return view
  }

  /// 外部的恢复裁剪与拖动选区共用草稿，反馈不会写入原图。
  func updateNSView(_ view: ShotCropView, context: Context) {
    view.selection = draft.selection
    view.onChange = { draft.selection = $0 }
    view.onApply = apply
    view.onCancel = cancel
  }

  /// 拆除时解除闭包和键盘目标，避免关闭后回调旧草稿。
  static func dismantleNSView(_ view: ShotCropView, coordinator: ()) {
    view.onChange = { _ in }
    view.onApply = {}
    view.onCancel = {}
  }
}

/// 归一化选区采用左下原点；仅一像素的自然下限，缩放显示不改变裁剪精度。
final class ShotCropView: NSView {
  let image: CGImage
  let pixelSize: CGSize
  var selection = CGRect(x: 0, y: 0, width: 1, height: 1) { didSet { needsDisplay = true } }
  var onChange: (CGRect) -> Void = { _ in }
  var onApply: () -> Void = {}
  var onCancel: () -> Void = {}
  private enum Gesture {
    case resize(RegionSelector.Handle)
    case move, draw
  }
  private var drag: (kind: Gesture, start: CGRect, point: CGPoint)?

  /// 图像只持有有界预览，几何使用原图像素尺寸，拖动不依赖文件读取。
  init(image: CGImage, pixelSize: CGSize) {
    self.image = image
    self.pixelSize = pixelSize
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = Style.Radius.card
    layer?.masksToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("裁剪范围；方向键移动，Option 方向键收边，Command 方向键扩边，Shift 增大步长")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// 键盘只交给当前面板内的裁剪视图，不使窗口成为 key 或切换前台应用。
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { window?.makeFirstResponder(self) }
  }

  /// 预览图片完整放进可用区域，四周留出手柄空间。
  var imageFrame: CGRect {
    let area = bounds.insetBy(dx: 12, dy: 12)
    let scale = max(0, min(area.width / pixelSize.width, area.height / pixelSize.height))
    let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
      height: size.height)
  }

  /// 显示框和命中检测使用相同坐标换算。
  var selectionFrame: CGRect {
    let frame = imageFrame
    return CGRect(
      x: frame.minX + selection.minX * frame.width, y: frame.minY + selection.minY * frame.height,
      width: selection.width * frame.width, height: selection.height * frame.height)
  }

  /// 画面和框外压暗共用一个局部上下文，拖动时直接更新，不播放布局动画。
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(Style.HUD.solidFill.cgColor)
    context.fill(bounds)
    let frame = imageFrame
    guard frame.width > 0, frame.height > 0 else { return }
    context.draw(image, in: frame)
    let crop = selectionFrame
    context.addRect(frame)
    context.addRect(crop)
    context.setFillColor(CGColor(gray: 0, alpha: 0.45))
    context.fillPath(using: .evenOdd)
    context.setStrokeColor(Style.Shot.accent.cgColor)
    context.setLineWidth(1.5)
    context.stroke(crop)
    var handles = [
      CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
      CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY),
    ]
    if crop.width >= 24 {
      handles += [CGPoint(x: crop.midX, y: crop.minY), CGPoint(x: crop.midX, y: crop.maxY)]
    }
    if crop.height >= 24 {
      handles += [CGPoint(x: crop.minX, y: crop.midY), CGPoint(x: crop.maxX, y: crop.midY)]
    }
    for point in handles {
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
      context.strokeEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
    }
  }

  /// 边角优先改大小，框内移动，框外可重新画一个范围。
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard imageFrame.insetBy(dx: -8, dy: -8).contains(point) else { return }
    let kind: Gesture
    if let handle = RegionSelector.handle(at: point, in: selectionFrame) {
      kind = .resize(handle)
    } else {
      guard imageFrame.contains(point) else { return }
      kind = selectionFrame.contains(point) ? .move : .draw
    }
    drag = (kind, selectionFrame, point)
    window?.makeFirstResponder(self)
  }

  /// 拖动边界夹在原图内，选区至少覆盖一个原图像素。
  override func mouseDragged(with event: NSEvent) {
    guard let drag else { return }
    let area = imageFrame
    guard area.width > 0, area.height > 0 else { return }
    let raw = convert(event.locationInWindow, from: nil)
    let point = CGPoint(
      x: min(max(raw.x, area.minX), area.maxX), y: min(max(raw.y, area.minY), area.maxY))
    let toPixels: (CGPoint) -> CGPoint = { point in
      CGPoint(
        x: (point.x - area.minX) / area.width * self.pixelSize.width,
        y: (point.y - area.minY) / area.height * self.pixelSize.height)
    }
    let start = CGRect(
      x: toPixels(drag.start.origin).x, y: toPixels(drag.start.origin).y,
      width: drag.start.width / area.width * pixelSize.width,
      height: drag.start.height / area.height * pixelSize.height)
    let pixelBounds = CGRect(origin: .zero, size: pixelSize)
    let pixelPoint = toPixels(point)
    let pixelDown = toPixels(drag.point)
    let rect: CGRect
    switch drag.kind {
    case .resize(let handle):
      rect = RegionSelector.resized(start, handle, to: pixelPoint, within: pixelBounds)
    case .move:
      rect = RegionSelector.moved(
        start, by: CGSize(width: pixelPoint.x - pixelDown.x, height: pixelPoint.y - pixelDown.y),
        within: pixelBounds)
    case .draw:
      rect = RegionSelector.drawn(from: pixelDown, to: pixelPoint, within: pixelBounds)
    }
    let normalized = CGRect(
      x: rect.minX / pixelSize.width, y: rect.minY / pixelSize.height,
      width: rect.width / pixelSize.width, height: rect.height / pixelSize.height
    ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard normalized.width * pixelSize.width >= 1, normalized.height * pixelSize.height >= 1 else {
      return
    }
    selection = normalized
    onChange(selection)
  }

  /// 旁白读取当前范围的实际像素尺寸，不把预览缩放后的点数当成图片尺寸。
  override func accessibilityValue() -> Any? {
    "\(Int((selection.width * pixelSize.width).rounded())) × \(Int((selection.height * pixelSize.height).rounded())) 像素"
  }

  /// 松手结束本次操作，实际采用仍由明确的应用按钮决定。
  override func mouseUp(with event: NSEvent) { drag = nil }

  /// 裁剪时方向键按原图像素移动，Esc 取消，回车应用；不发送合成系统按键。
  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    guard !flags.contains(.control), flags != [.command, .option] else {
      return super.keyDown(with: event)
    }
    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
    if flags == .command || flags == .option {
      guard
        [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(event.keyCode))
      else { return super.keyDown(with: event) }
      resizeByKeyboard(Int(event.keyCode), amount: step, shrinking: flags == .option)
      return
    }
    var delta = CGSize.zero
    switch Int(event.keyCode) {
    case kVK_Escape:
      onCancel()
      return
    case kVK_Return, kVK_ANSI_KeypadEnter:
      onApply()
      return
    case kVK_LeftArrow: delta.width = -step / pixelSize.width
    case kVK_RightArrow: delta.width = step / pixelSize.width
    case kVK_UpArrow: delta.height = step / pixelSize.height
    case kVK_DownArrow: delta.height = -step / pixelSize.height
    default: return super.keyDown(with: event)
    }
    selection = RegionSelector.moved(
      selection, by: delta, within: CGRect(x: 0, y: 0, width: 1, height: 1))
    onChange(selection)
  }

  /// 推动对应边并保持至少一个像素，键盘收边越过对边时停止，不让选区翻转。
  private func resizeByKeyboard(_ code: Int, amount: CGFloat, shrinking: Bool) {
    let dx = amount / pixelSize.width * (shrinking ? -1 : 1)
    let dy = amount / pixelSize.height * (shrinking ? -1 : 1)
    var point = CGPoint(x: selection.midX, y: selection.midY)
    let handle: RegionSelector.Handle
    switch code {
    case kVK_LeftArrow:
      handle = .left
      point.x = min(max(selection.minX - dx, 0), selection.maxX - 1 / pixelSize.width)
    case kVK_RightArrow:
      handle = .right
      point.x = max(min(selection.maxX + dx, 1), selection.minX + 1 / pixelSize.width)
    case kVK_UpArrow:
      handle = .top
      point.y = max(min(selection.maxY + dy, 1), selection.minY + 1 / pixelSize.height)
    default:
      handle = .bottom
      point.y = min(max(selection.minY - dy, 0), selection.maxY - 1 / pixelSize.height)
    }
    // 共享几何的最小宽高是一个坐标单位，在像素域调用才表示一个原图像素。
    let pixels = CGRect(
      x: selection.minX * pixelSize.width, y: selection.minY * pixelSize.height,
      width: selection.width * pixelSize.width, height: selection.height * pixelSize.height)
    let result = RegionSelector.resized(
      pixels, handle, to: CGPoint(x: point.x * pixelSize.width, y: point.y * pixelSize.height),
      within: CGRect(origin: .zero, size: pixelSize))
    selection = CGRect(
      x: result.minX / pixelSize.width, y: result.minY / pixelSize.height,
      width: result.width / pixelSize.width, height: result.height / pixelSize.height)
    onChange(selection)
  }
}
