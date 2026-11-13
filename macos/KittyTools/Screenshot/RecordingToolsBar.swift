// 录屏讲解工具箱：固定单行工具栏与指向触发控件的参数气泡，两个窗口均排除在成片之外。

import AppKit
import OSLog

/// 录制控制条旁的紧凑工具箱，复用截图色点与线宽控件，状态由画板单向同步。
final class RecordingToolsBar: NSView {
  let panel: NSPanel
  let optionsPanel: NSPanel
  var onDismissOptions: () -> Void = {}
  var onAction: (RecordingTools.Action) -> Void = { _ in }
  private let body = HUDBar(radius: Style.Radius.panel, height: 40, blending: .behindWindow)
  private let parameterBar = HUDBar(radius: Style.Radius.card, height: 34, blending: .behindWindow)
  private let parameterRoot = NSView()
  private let tip = CAShapeLayer()
  private var options: NSStackView { parameterBar.stack }
  private var modes: [RecordingTools.Mode: ToggleButton] = [:]
  private var focuses: [RecordingTools.Focus: ToggleButton] = [:]
  private var colors: [Swatch] = []
  private var weights: [Swatch] = []
  private var sizes: [BarButton] = []
  private var undo: BarButton!
  private var clear: BarButton!
  private var currentFocus = RecordingTools.Focus.off
  private var currentMode = RecordingTools.Mode.pointer
  private var optionsTarget: OptionsTarget?
  private var dismissalMonitors: [Any] = []
  private enum OptionsTarget: Equatable {
    case tool(RecordingTools.Mode)
    case focus(RecordingTools.Focus)
  }
  private var shownOptions: [Bool] = []
  private static let margin: CGFloat = 16

  /// 只构建工具窗口，present 才上屏；所有按钮不拿第一响应者。
  init() {
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    optionsPanel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    super.init(frame: .zero)
    wantsLayer = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.contentView = self
    addSubview(body)
    makeTools()
    makeOptions()
    makeBubble()
    update(RecordingTools(), escapes: false)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("录屏讲解工具")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 主行按操作、画图、鼠标效果、撤销清空与关闭分组，焦点按钮再次点击即关闭效果。
  private func makeTools() {
    var views: [NSView] = RecordingTools.Mode.allCases.map { mode in
      let button = ToggleButton()
      button.tag = mode.rawValue
      button.target = self
      button.action = #selector(modeClicked(_:))
      modes[mode] = button
      return button
    }
    views.append(barSeparator())
    for mode in [RecordingTools.Focus.halo, .spotlight] {
      let button = ToggleButton()
      button.tag = mode.rawValue
      button.target = self
      button.action = #selector(focusClicked(_:))
      focuses[mode] = button
      views.append(button)
    }
    undo = barButton(
      NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)!,
      tip: "撤销上一条标注", action: #selector(undoClicked))
    clear = barButton(
      NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!,
      tip: "清空画板", action: #selector(clearClicked))
    clear.contentTintColor = Style.HUD.danger
    let close = barButton(
      NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
      tip: "收起工具箱并返回操作窗口，保留标注", action: #selector(closeClicked))
    views += [barSeparator(), undo, clear, barSeparator(), close]
    body.install(views)
  }

  /// 参数复用截图的颜色、线宽色点和空心范围圆，由气泡按触发工具组合。
  private func makeOptions() {
    colors = Annotation.Palette.allCases.map { color in
      let button = Swatch(fill: color.color, diameter: 14, outlined: true, label: "\(color.title)色")
      button.tag = color.rawValue
      button.target = self
      button.action = #selector(colorClicked(_:))
      return button
    }
    weights = Annotation.Weight.allCases.map { weight in
      let button = Swatch(
        fill: Style.HUD.text, diameter: [4, 7, 10][weight.rawValue], outlined: false,
        label: "线宽：\(weight.title)")
      button.tag = weight.rawValue
      button.target = self
      button.action = #selector(weightClicked(_:))
      return button
    }
    sizes = Annotation.Weight.allCases.map { size in
      let title = ["小", "中", "大"][size.rawValue]
      let button = barButton(
        NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!,
        tip: "焦点范围：\(title)", action: #selector(sizeClicked(_:)),
        size: CGSize(width: 26, height: 26))
      button.tag = size.rawValue
      button.symbolConfiguration = .init(pointSize: [8, 12, 16][size.rawValue], weight: .medium)
      return button
    }
    options.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
  }

  /// 气泡使用独立的普通 NSPanel，箭头与参数面板共同指向触发控件，永不拿键盘。
  private func makeBubble() {
    optionsPanel.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
    optionsPanel.collectionBehavior = panel.collectionBehavior
    optionsPanel.isOpaque = false
    optionsPanel.backgroundColor = .clear
    optionsPanel.hasShadow = false
    optionsPanel.hidesOnDeactivate = false
    optionsPanel.isReleasedWhenClosed = false
    optionsPanel.animationBehavior = .none
    optionsPanel.allowsToolTipsWhenApplicationIsInactive = true
    parameterRoot.wantsLayer = true
    tip.fillColor = Style.HUD.solidFill.cgColor
    parameterRoot.layer?.addSublayer(tip)
    parameterRoot.addSubview(parameterBar)
    optionsPanel.contentView = parameterRoot
    parameterRoot.setAccessibilityElement(true)
    parameterRoot.setAccessibilityRole(.group)
    parameterRoot.setAccessibilityLabel("录屏工具参数")
  }

  /// 同步选择状态，操作说明保留在工具提示和无障碍帮助中。
  func update(_ state: RecordingTools, escapes: Bool) {
    if state.mode != currentMode, state.isDrawing {
      optionsTarget = .tool(state.mode)
    } else if state.focus != currentFocus, state.focus != .off {
      optionsTarget = .focus(state.focus)
    }
    currentMode = state.mode
    currentFocus = state.focus
    if case .tool(let tool) = optionsTarget, state.mode != tool { optionsTarget = nil }
    if case .focus(let focus) = optionsTarget, state.focus != focus { optionsTarget = nil }
    let exitHint = escapes ? "Esc 返回操作窗口" : "点箭头返回操作窗口"
    for (mode, button) in modes {
      let selected = state.mode == mode
      button.show(mode.symbol, on: selected, animated: false)
      button.showsHover = !selected
      button.layer?.backgroundColor = selected ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(selected ? "已选择" : "未选择")
      let description = mode.title + (selected && state.isDrawing ? "（\(exitHint)）" : "")
      button.describe = { description }
    }
    for (mode, button) in focuses {
      let selected = state.focus == mode
      button.show(mode.symbol, on: selected, animated: false)
      button.showsHover = !selected
      button.layer?.backgroundColor = selected ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(selected ? "已开启" : "已关闭")
      let description = "\(mode.title)：\(selected ? "开，再点关闭" : "关")"
      button.describe = { description }
    }
    for button in colors {
      button.setChosen(button.tag == state.style.color.rawValue, animated: false)
    }
    for button in weights {
      button.setChosen(button.tag == state.style.weight.rawValue, animated: false)
    }
    for button in sizes {
      let selected = button.tag == state.focusSize.rawValue
      button.showsHover = !selected
      button.contentTintColor = selected ? Style.Shot.accent : Style.HUD.text
      button.layer?.backgroundColor = selected ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(selected ? "已选择" : "未选择")
    }
    undo.isEnabled = state.canUndo
    clear.isEnabled = state.canUndo
    setAccessibilityHelp(state.isDrawing ? "\(state.mode.title)，\(exitHint)" : "操作窗口，标注会录入视频")
    arrangeOptions()
    arrange()
  }

  /// 仅在参数种类变化时重排，改变颜色和线宽时保留正在跟踪的按钮。
  private func arrangeOptions() {
    let shown: [Bool]
    switch optionsTarget {
    case .tool: shown = [true, true, false]
    case .focus(.halo): shown = [true, false, true]
    case .focus(.spotlight): shown = [false, false, true]
    default: shown = [false, false, false]
    }
    guard shown != shownOptions else { return }
    shownOptions = shown
    for view in options.arrangedSubviews { view.removeFromSuperview() }
    let groups: [[NSView]] = [
      shown[0] ? colors : [], shown[1] ? weights : [], shown[2] ? sizes : [],
    ]
    for group in groups where !group.isEmpty {
      if !options.arrangedSubviews.isEmpty { options.addArrangedSubview(barSeparator()) }
      group.forEach(options.addArrangedSubview)
    }
    if options.arrangedSubviews.isEmpty {
      optionsTarget = nil
      hideOptionsWindow()
    } else {
      parameterBar.fit()
    }
  }

  /// 主工具行始终保持同样尺寸，参数气泡使用独立窗口。
  private func arrange() {
    body.frame.origin = CGPoint(x: Self.margin, y: Self.margin)
    frame.size = CGSize(width: body.frame.width + Self.margin * 2, height: 40 + Self.margin * 2)
  }

  var hasOptions: Bool { optionsTarget != nil }

  /// 将主栏与气泡摆到屏幕坐标，不显示窗口，供实际呈现和屏外验证共用。
  func arrange(anchor: CGRect, visible: CGRect) {
    panel.setFrame(
      RecordingTools.frame(size: frame.size, anchor: anchor, visible: visible), display: false)
    guard hasOptions, let button = optionsAnchor else { return }
    body.layoutSubtreeIfNeeded()
    let local = button.convert(button.bounds, to: self)
    let source = CGRect(
      x: panel.frame.minX + local.minX, y: panel.frame.minY + body.frame.midY - 16,
      width: button.bounds.width, height: 32)
    let placement = RecordingTools.bubble(
      size: parameterBar.frame.size, anchor: source, visible: visible, avoiding: anchor)
    optionsPanel.setFrame(placement.frame, display: false)
    parameterRoot.frame = CGRect(origin: .zero, size: placement.frame.size)
    parameterBar.frame.origin = CGPoint(
      x: RecordingTools.bubbleMargin,
      y: RecordingTools.bubbleMargin + (placement.pointsUp ? 0 : RecordingTools.bubbleArrowHeight))
    updateTip(placement)
  }

  /// 箭头使用圆弧过渡，尖端对准触发控件，靠屏幕边缘时只移动气泡主体。
  private func updateTip(_ placement: RecordingTools.BubblePlacement) {
    let x = placement.tipX
    let edge = placement.pointsUp ? parameterBar.frame.maxY : parameterBar.frame.minY
    let direction: CGFloat = placement.pointsUp ? 1 : -1
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x - 10, y: edge))
    path.addCurve(
      to: CGPoint(x: x, y: edge + direction * 8),
      control1: CGPoint(x: x - 6, y: edge), control2: CGPoint(x: x - 3, y: edge + direction * 8))
    path.addCurve(
      to: CGPoint(x: x + 10, y: edge),
      control1: CGPoint(x: x + 3, y: edge + direction * 8), control2: CGPoint(x: x + 6, y: edge))
    path.closeSubpath()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tip.contentsScale = optionsPanel.backingScaleFactor
    tip.path = path
    CATransaction.commit()
  }

  private var optionsAnchor: NSButton? {
    switch optionsTarget {
    case .tool(let mode): modes[mode]
    case .focus(let focus): focuses[focus]
    case nil: nil
    }
  }

  /// 贴着录制控制条显示主栏，参数气泡跟随本次点击的按钮，两个窗口均不激活应用。
  func present(anchor: CGRect, visible: CGRect) {
    arrange(anchor: anchor, visible: visible)
    panel.orderFrontRegardless()
    guard hasOptions else { return hideOptionsWindow() }
    let appearing = !optionsPanel.isVisible
    optionsPanel.orderFrontRegardless()
    if appearing { monitorOutsideClicks() }
  }

  /// 气泡打开时才安装被动鼠标监听，点到其他位置只收气泡，原点击继续传递。
  private func monitorOutsideClicks() {
    guard dismissalMonitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismissOptionsIfOutside(at: NSEvent.mouseLocation) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      MainActor.assumeIsolated { self?.dismissOptionsIfOutside(at: NSEvent.mouseLocation) }
      return event
    }
    dismissalMonitors = [global, local].compactMap { $0 }
    if dismissalMonitors.count != 2 {
      Log.record.error(
        "录屏参数气泡点外收起监听未全部建立 window=\(self.optionsPanel.windowNumber) installed=\(self.dismissalMonitors.count)"
      )
    }
  }

  /// 点击主栏或参数区域继续操作，其他位置收起参数气泡。
  func dismissOptionsIfOutside(at point: CGPoint) {
    guard !panel.frame.contains(point), !optionsPanel.frame.contains(point) else { return }
    dismissOptions()
  }

  /// 收起参数并通知会话更新临时 Esc，画板模式与已有笔迹保持当前状态。
  func dismissOptions() {
    guard hasOptions else { return }
    optionsTarget = nil
    hideOptionsWindow()
    onDismissOptions()
  }

  /// 收走气泡并成对卸载鼠标监听，模型同步时不反向发送状态回调。
  private func hideOptionsWindow() {
    dismissalMonitors.forEach(NSEvent.removeMonitor)
    dismissalMonitors = []
    optionsPanel.orderOut(nil)
  }

  /// 收起主栏和参数气泡。
  func hide() {
    panel.orderOut(nil)
    dismissOptions()
  }

  /// 停止录制时拆开窗口和内容的相互持有关系。
  func close() {
    onDismissOptions = {}
    hide()
    onAction = { _ in }
    removeFromSuperview()
    panel.contentView = nil
    optionsPanel.contentView = nil
  }

  /// 返回画图工具按钮供屏外测试核对选择和回调。
  func button(for mode: RecordingTools.Mode) -> NSButton? { modes[mode] }
  /// 返回鼠标效果按钮，关闭状态由再次点击当前效果表达。
  func focusButton(for focus: RecordingTools.Focus) -> NSButton? { focuses[focus] }
  /// 选择画图工具或操作窗口。
  @objc private func modeClicked(_ sender: NSButton) {
    guard let mode = RecordingTools.Mode(rawValue: sender.tag) else { return }
    optionsTarget = mode == .pointer || optionsTarget == .tool(mode) ? nil : .tool(mode)
    onAction(.mode(mode))
  }
  /// 再次点击已开启的鼠标效果时关闭。
  @objc private func focusClicked(_ sender: NSButton) {
    guard let focus = RecordingTools.Focus(rawValue: sender.tag) else { return }
    let next: RecordingTools.Focus = currentFocus == focus ? .off : focus
    optionsTarget = next == .off ? nil : .focus(next)
    if next == .off { hideOptionsWindow() }
    onAction(.focus(next))
  }
  /// 调整后续笔迹与跟随光圈的颜色。
  @objc private func colorClicked(_ sender: NSButton) {
    guard let color = Annotation.Palette(rawValue: sender.tag) else { return }
    onAction(.color(color))
  }
  /// 调整后续笔迹的线宽。
  @objc private func weightClicked(_ sender: NSButton) {
    guard let weight = Annotation.Weight(rawValue: sender.tag) else { return }
    onAction(.weight(weight))
  }
  /// 调整鼠标效果的范围。
  @objc private func sizeClicked(_ sender: NSButton) {
    guard let size = Annotation.Weight(rawValue: sender.tag) else { return }
    onAction(.radius(size))
  }
  /// 撤销上一条标注。
  @objc private func undoClicked() { onAction(.undo) }
  /// 清空本次录制的标注。
  @objc private func clearClicked() { onAction(.clear) }
  /// 收起工具箱并恢复点穿。
  @objc private func closeClicked() { onAction(.close) }
}
