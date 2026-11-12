// 录屏讲解工具箱：沿用 HUDBar、ToggleButton 和截图样式托盘，工具窗口排除在成片之外。

import AppKit

/// 录制控制条旁的工具箱，三行分别放画图工具、颜色线宽、鼠标焦点，状态由画板单向同步。
final class RecordingToolsBar: NSView {
  let panel: NSPanel
  var onAction: (RecordingTools.Action) -> Void = { _ in }
  private let tools = HUDBar(radius: Style.Radius.panel, height: 40, blending: .behindWindow)
  private let styles = StyleBar(blending: .behindWindow)
  private let focus = HUDBar(radius: Style.Radius.panel, height: 40, blending: .behindWindow)
  private var modes: [RecordingTools.Mode: ToggleButton] = [:]
  private var focuses: [RecordingTools.Focus: ToggleButton] = [:]
  private var sizes: [Annotation.Weight: BarButton] = [:]
  private var undo: BarButton!
  private var clear: BarButton!
  private let hint = NSTextField(labelWithString: "操作窗口")

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
    makeTools()
    makeFocus()
    styles.onColor = { [weak self] in self?.onAction(.color($0)) }
    styles.onWeight = { [weak self] in self?.onAction(.weight($0)) }
    update(RecordingTools(), escapes: false)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("录屏讲解工具")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 建立画图工具与撤销、清空、收起入口，符号与截图工具栏共用。
  private func makeTools() {
    var views: [NSView] = RecordingTools.Mode.allCases.map { mode in
      let button = ToggleButton()
      button.tag = mode.rawValue
      button.target = self
      button.action = #selector(modeClicked(_:))
      button.describe = { mode.title }
      modes[mode] = button
      return button
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
    tools.install(views)
    addSubview(tools)
    addSubview(styles)
    addSubview(focus)
  }

  /// 焦点与范围独立选择，关闭焦点不影响已经画好的笔迹。
  private func makeFocus() {
    let label = NSTextField(labelWithString: "鼠标焦点")
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = Style.HUD.text
    var views: [NSView] = [label]
    for mode in RecordingTools.Focus.allCases {
      let button = ToggleButton()
      button.tag = mode.rawValue
      button.target = self
      button.action = #selector(focusClicked(_:))
      button.describe = { mode.title }
      focuses[mode] = button
      views.append(button)
    }
    views.append(barSeparator())
    for (size, title) in zip(Annotation.Weight.allCases, ["小", "中", "大"]) {
      let button = BarButton(title: title, target: self, action: #selector(sizeClicked(_:)))
      button.tag = size.rawValue
      button.isBordered = false
      button.refusesFirstResponder = true
      button.font = .systemFont(ofSize: 12, weight: .medium)
      button.toolTip = "焦点范围：\(title)"
      button.setAccessibilityLabel("焦点范围：\(title)")
      button.widthAnchor.constraint(equalToConstant: 28).isActive = true
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      sizes[size] = button
      views.append(button)
    }
    focus.install(views)
    hint.font = .systemFont(ofSize: 11, weight: .medium)
    hint.textColor = Style.HUD.text
    hint.alignment = .center
    hint.wantsLayer = true
    hint.layer?.backgroundColor = Style.HUD.solidFill.cgColor
    hint.layer?.cornerRadius = Style.Radius.control
    addSubview(hint)
  }

  /// 同步当前工具、颜色线宽、焦点和可用动作；范围开关使用选中底与无障碍值共同表示状态。
  func update(_ state: RecordingTools, escapes: Bool) {
    for (mode, button) in modes {
      button.show(mode.symbol, on: state.mode == mode, animated: false)
      button.showsHover = state.mode != mode
      button.layer?.backgroundColor = state.mode == mode ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(state.mode == mode ? "已选择" : "未选择")
    }
    for (mode, button) in focuses {
      button.show(mode.symbol, on: state.focus == mode, animated: false)
      button.showsHover = state.focus != mode
      button.layer?.backgroundColor = state.focus == mode ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(state.focus == mode ? "已选择" : "未选择")
    }
    for (size, button) in sizes {
      button.contentTintColor = state.focusSize == size ? Style.Shot.accent : Style.HUD.text
      button.layer?.backgroundColor = state.focusSize == size ? Style.HUD.selectedFill.cgColor : nil
      button.setAccessibilityValue(state.focusSize == size ? "已选择" : "未选择")
      button.isEnabled = state.focus != .off
    }
    // 颜色和线宽复用画笔的托盘形态，避免把矩形的实心选项带入本次讲解范围。
    styles.update(tool: .pen, style: state.style)
    undo.isEnabled = state.canUndo
    clear.isEnabled = state.canUndo
    hint.stringValue =
      state.isDrawing
      ? "\(state.mode.title) · \(escapes ? "Esc 返回操作窗口" : "点箭头返回操作窗口")"
      : "操作窗口 · 标注会录入视频"
    arrange()
  }

  /// 三行使用现有 HUD 刻度，较窄的一行居中，提示留在深色底上保证明暗背景均可读。
  private func arrange() {
    let width = max(tools.frame.width, styles.preferredSize.width, focus.frame.width)
    let margin: CGFloat = 16
    frame.size = CGSize(
      width: width + margin * 2, height: 40 + 6 + 34 + 6 + 40 + 6 + 22 + margin * 2)
    hint.frame = CGRect(x: margin, y: margin, width: width, height: 22)
    focus.frame.origin = CGPoint(x: (frame.width - focus.frame.width) / 2, y: hint.frame.maxY + 6)
    styles.frame = CGRect(
      x: (frame.width - styles.preferredSize.width) / 2, y: focus.frame.maxY + 6,
      width: styles.preferredSize.width, height: styles.preferredSize.height)
    styles.applyGeometry()
    tools.frame.origin = CGPoint(x: (frame.width - tools.frame.width) / 2, y: styles.frame.maxY + 6)
  }

  /// 贴着录制控制条展开，全部位于当前屏幕可见区域，永不当 key。
  func present(anchor: CGRect, visible: CGRect) {
    panel.setFrame(
      RecordingTools.frame(size: frame.size, anchor: anchor, visible: visible), display: false)
    panel.orderFrontRegardless()
  }

  /// 收起但保留本次会话的工具状态，下一次展开时复用。
  func hide() { panel.orderOut(nil) }

  /// 停止录制时拆开窗口和内容的相互持有关系。
  func close() {
    hide()
    onAction = { _ in }
    removeFromSuperview()
    panel.contentView = nil
  }

  /// 返回工具按钮供屏外测试核对选择和回调。
  func button(for mode: RecordingTools.Mode) -> NSButton? { modes[mode] }
  /// 选择画图工具或操作窗口。
  @objc private func modeClicked(_ sender: NSButton) {
    guard let mode = RecordingTools.Mode(rawValue: sender.tag) else { return }
    onAction(.mode(mode))
  }
  /// 选择鼠标焦点效果。
  @objc private func focusClicked(_ sender: NSButton) {
    guard let focus = RecordingTools.Focus(rawValue: sender.tag) else { return }
    onAction(.focus(focus))
  }
  /// 调整鼠标焦点范围。
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
