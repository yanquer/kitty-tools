// 窗口管理动作选择器，复用统一浮层、输入框、键帽与中性列表高亮。

import AppKit
import SwiftUI

/// 动作选择会话只持有回调，关闭时释放捕获的目标窗口。
@MainActor final class WindowLayoutPicker {
  private var panel: OverlayPanel?
  let model = WindowLayoutPickerModel()

  isolated deinit {
    panel?.hide()
    panel?.close()
  }

  /// 按需建立面板，显示前重置搜索与选择。
  func show(targetName: String, portrait: Bool, run: @escaping (WindowLayoutAction) -> Void) {
    model.query = ""
    model.targetName = targetName
    model.portrait = portrait
    model.selected = .leftHalf
    model.perform = { [weak self] action in
      self?.hide()
      run(action)
    }
    if panel == nil {
      let created = OverlayPanel(
        size: CGSize(width: 540, height: 460), autoHide: .clickOutside,
        isPinned: { false }, content: WindowLayoutPickerView(model: model))
      created.isMovableByWindowBackground = false
      created.onHide = { [weak self] in self?.model.perform = { _ in } }
      panel = created
    }
    panel?.present(atTop: true)
  }

  /// 关闭时即刻归还键盘，执行闭包由调用者当前栈保留到动作发出。
  func hide() {
    panel?.hide()
    model.perform = { _ in }
  }
}

/// 纯文本搜索与键盘选择状态，截图可独立构造而不碰真实窗口。
@Observable final class WindowLayoutPickerModel {
  var query = ""
  var targetName = ""
  var portrait = false
  var selected: WindowLayoutAction? = .leftHalf
  var scrollRequest = 0
  var perform: (WindowLayoutAction) -> Void = { _ in }

  var results: [WindowLayoutAction] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return WindowLayoutAction.allCases.filter {
      term.isEmpty || $0.title(portrait: portrait).localizedStandardContains(term)
        || $0.rawValue.localizedStandardContains(term)
        || $0.group.localizedStandardContains(term)
    }
  }

  /// 输入法确认之后的方向键和回车交给动作选择，其他编辑命令仍由系统处理。
  func command(_ selector: Selector) -> Bool {
    let entries = results
    guard !entries.isEmpty else { return false }
    let index = entries.firstIndex(of: selected ?? entries[0]) ?? 0
    switch NSStringFromSelector(selector) {
    case "moveDown:":
      selected = entries[min(entries.count - 1, index + 1)]
      scrollRequest += 1
    case "moveUp:":
      selected = entries[max(0, index - 1)]
      scrollRequest += 1
    case "insertNewline:": perform(entries[index])
    default: return false
    }
    return true
  }
}

/// 以文字、区域缩略图和快捷键提供完整动作入口。
struct WindowLayoutPickerView: View {
  @Bindable var model: WindowLayoutPickerModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          CommandTextField(
            text: $model.query, placeholder: "搜索窗口布局", maxLength: 100,
            onCommand: model.command
          )
          .frame(height: 22)
          .accessibilityLabel("搜索窗口布局")
          if !model.targetName.isEmpty {
            Text(model.targetName).font(.system(size: 11)).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
          }
        }
      }
      .padding(.horizontal, 16).frame(height: 52)
      Hairline()
      if model.results.isEmpty {
        ContentUnavailableView.search(text: model.query)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(model.results) { action in row(action).id(action) }
            }.padding(6)
          }
          .onChange(of: model.scrollRequest) { _, _ in
            if let action = model.selected { proxy.scrollTo(action, anchor: .center) }
          }
        }
      }
      Hairline()
      HStack {
        Text("\(model.results.count) 个动作").foregroundStyle(.secondary)
        Spacer()
        KeyCombo("↑↓")
        Text("选择").foregroundStyle(.secondary)
        KeyCombo("↩")
        Text("执行").foregroundStyle(.secondary)
      }
      .font(.system(size: 11)).padding(.horizontal, 16).frame(height: 36)
    }
    .onChange(of: model.query) { _, _ in
      model.selected = model.results.first
      model.scrollRequest += 1
    }
    .accessibilityLabel("窗口管理")
  }

  /// 列表行共用窗口动作名称，悬停通过现有跟踪视图处理。
  private func row(_ action: WindowLayoutAction) -> some View {
    Button {
      model.perform(action)
    } label: {
      HStack(spacing: 12) {
        WindowLayoutGlyph(action: action, portrait: model.portrait).frame(width: 36, height: 26)
          .accessibilityHidden(true)
        Text(action.title(portrait: model.portrait)).lineLimit(1).truncationMode(.tail)
        Spacer()
        Text(action.group).font(.system(size: 11)).foregroundStyle(.tertiary)
        if let key = HotKeyAction.windowLayout(action).hotKey { KeyCombo(key.display) }
      }
      .padding(.horizontal, 10).frame(height: 42)
      .background(
        model.selected == action ? Style.selectedFill : .clear,
        in: RoundedRectangle(cornerRadius: Style.Radius.card)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(HoverTracker { inside in if inside { model.selected = action } })
    .accessibilityAddTraits(model.selected == action ? .isSelected : [])
  }
}

/// 由同一归一化区域画出网格位置，避免图标和实际布局规则分叉。
struct WindowLayoutGlyph: View {
  let action: WindowLayoutAction
  var portrait = false

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - 2)
      let height = max(1, geometry.size.height - 2)
      let previewWidth = portrait ? min(width, height * height / width) : width
      let bounds = CGRect(
        x: (geometry.size.width - previewWidth) / 2, y: 1,
        width: previewWidth, height: height)
      RoundedRectangle(cornerRadius: Style.Radius.mini).stroke(.secondary.opacity(0.4))
        .frame(width: bounds.width, height: bounds.height).offset(x: bounds.minX, y: bounds.minY)
      if let unit = action.unitRect(portrait: portrait) {
        let rect = WindowLayoutGeometry.region(unit, in: bounds, gap: 2)
        RoundedRectangle(cornerRadius: 2).fill(Style.brand.opacity(0.55))
          .frame(width: rect.width, height: rect.height)
          .offset(x: rect.minX, y: rect.minY)
      } else {
        Image(
          systemName: WindowLayoutAction.multiple.contains(action)
            ? "square.grid.2x2" : "arrow.up.left.and.arrow.down.right"
        )
        .font(.system(size: 11)).frame(width: geometry.size.width, height: geometry.size.height)
        .foregroundStyle(.secondary)
      }
    }
  }
}
