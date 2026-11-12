// 录屏讲解工具箱：统一 HUD 表面承载主工具行与按需显示的参数行，工具窗口排除在成片之外。

import AppKit

/// 录制控制条旁的紧凑工具箱，复用截图色点与线宽控件，状态由画板单向同步。
final class RecordingToolsBar: NSView {
  let panel: NSPanel
  var onAction: (RecordingTools.Action) -> Void = { _ in }
  private let body = HUDBar(radius: Style.Radius.panel, height: 80, blending: .behindWindow)
  private let options = NSStackView()
  private var modes: [RecordingTools.Mode: ToggleButton] = [:]
  private var focuses: [RecordingTools.Focus: ToggleButton] = [:]
  private var colors: [Swatch] = []
  private var weights: [Swatch] = []
  private var sizes: [BarButton] = []
  private var undo: BarButton!
  private var clear: BarButton!
  private var currentFocus = RecordingTools.Focus.off
  private var shownOptions: [Bool] = []
  private var toolsCenter: NSLayoutConstraint?
  private static let margin: CGFloat = 16

  /// 只构建工具窗口，present 才上屏；所有按钮不拿第一响应者。
  init() {
    panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
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
    toolsCenter = body.effect.constraints.first {
      $0.firstItem === body.stack && $0.firstAttribute == .centerY
    }
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

  /// 参数使用截图的颜色、线宽色点和空心范围圆，全部放在同一块材质内。
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
    options.spacing = 2
    options.translatesAutoresizingMaskIntoConstraints = false
    body.effect.addSubview(options)
    NSLayoutConstraint.activate([
      options.centerXAnchor.constraint(equalTo: body.effect.centerXAnchor),
      options.bottomAnchor.constraint(equalTo: body.effect.bottomAnchor, constant: 7),
    ])
  }

  /// 同步选择状态，操作说明保留在工具提示和无障碍帮助中。
  func update(_ state: RecordingTools, escapes: Bool) {
    currentFocus = state.focus
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
    arrangeOptions(state)
    arrange()
  }

  /// 仅在参数种类变化时重排，改变颜色和线宽时保留正在跟踪的按钮。
  private func arrangeOptions(_ state: RecordingTools) {
    let shown = [state.isDrawing || state.focus == .halo, state.isDrawing, state.focus != .off]
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
    options.isHidden = options.arrangedSubviews.isEmpty
  }

  /// 一块材质承载一行或两行，统一宽度；参数行按需展开，四周只留阴影所需的透明边。
  private func arrange() {
    let expanded = !options.isHidden
    let width = ceil(
      max(body.stack.fittingSize.width, options.fittingSize.width) + 2 * HUDBar.materialInset)
    body.frame = CGRect(x: Self.margin, y: Self.margin, width: width, height: expanded ? 80 : 40)
    toolsCenter?.constant = expanded ? 20 : 0
    body.applyGeometry()
    frame.size = CGSize(width: width + Self.margin * 2, height: body.frame.height + Self.margin * 2)
  }

  /// 贴着录制控制条展开，全部位于当前屏幕可见区域，永不当 key。
  func present(anchor: CGRect, visible: CGRect) {
    panel.setFrame(
      RecordingTools.frame(size: frame.size, anchor: anchor, visible: visible), display: false)
    panel.orderFrontRegardless()
  }

  /// 收起并保留本次会话的工具状态。
  func hide() { panel.orderOut(nil) }

  /// 停止录制时拆开窗口和内容的相互持有关系。
  func close() {
    hide()
    onAction = { _ in }
    removeFromSuperview()
    panel.contentView = nil
  }

  /// 返回画图工具按钮供屏外测试核对选择和回调。
  func button(for mode: RecordingTools.Mode) -> NSButton? { modes[mode] }
  /// 返回鼠标效果按钮，关闭状态由再次点击当前效果表达。
  func focusButton(for focus: RecordingTools.Focus) -> NSButton? { focuses[focus] }
  /// 选择画图工具或操作窗口。
  @objc private func modeClicked(_ sender: NSButton) {
    guard let mode = RecordingTools.Mode(rawValue: sender.tag) else { return }
    onAction(.mode(mode))
  }
  /// 再次点击已开启的鼠标效果时关闭。
  @objc private func focusClicked(_ sender: NSButton) {
    guard let focus = RecordingTools.Focus(rawValue: sender.tag) else { return }
    onAction(.focus(currentFocus == focus ? .off : focus))
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
