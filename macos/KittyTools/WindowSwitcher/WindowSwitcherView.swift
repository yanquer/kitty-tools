// 窗口切换面板，使用 Whisker 材质与网格卡片展示应用归属、窗口标题和状态。

import AppKit
import SwiftUI

/// 展示窗口归属、搜索结果和对所选目标的操作。
struct WindowSwitcherView: View {
  @Bindable var model: WindowSwitcherModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      if model.loading {
        ProgressView("正在读取窗口…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.results.isEmpty {
        ContentUnavailableView(
          model.query.isEmpty ? "没有可切换的窗口" : "没有匹配的窗口",
          systemImage: "rectangle.on.rectangle",
          description: Text(model.query.isEmpty ? "打开应用窗口后刷新列表" : "试试应用名称或窗口标题")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        grid
      }
      if let issue = model.issue {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
          Text(issue).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("重试", action: model.onRetry).buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(nsColor: .systemOrange))
        .padding(.horizontal, 16).padding(.vertical, 8)
      }
      if !model.screenRecording {
        Button("允许屏幕录制以显示窗口缩略图") { Permissions.grant(.screenRecording) }
          .buttonStyle(.plain).foregroundStyle(Style.brandInk)
          .font(.system(size: 11)).padding(.bottom, 8)
      }
      Hairline()
      footer
    }
    .accessibilityLabel("窗口切换")
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
      if model.searching {
        CommandTextField(
          text: $model.query, placeholder: "搜索应用名或窗口标题", isDialogField: true,
          focusRequest: model.focusRequest, onCommand: model.command
        )
        .frame(height: 24)
        .accessibilityLabel("搜索窗口")
      } else {
        Text("窗口切换").font(.system(size: 15, weight: .semibold))
        Spacer()
        Button(action: model.onSearch) { Label("搜索窗口 ⌘F", systemImage: "magnifyingglass") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
      }
      Button(action: model.onRetry) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.plain).disabled(model.loading)
        .help("刷新窗口列表").accessibilityLabel("刷新窗口列表")
    }
    .padding(.horizontal, 16).frame(height: 52)
  }

  private var grid: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
          ForEach(model.results) { item in
            SwitchWindowCard(
              item: item, image: model.images[item.id], icon: model.icons[item.pid],
              selected: model.selectedID == item.id,
              closable: model.closable.contains(item.id),
              manageable: model.manageable.contains(item.id),
              close: { model.close(item.id) }, minimize: { model.minimize(item.id) }
            ) {
              model.selectedID = item.id
              model.onConfirm()
            }
            .id(item.id)
          }
        }
        .padding(12)
      }
      .onAppear {
        if let id = model.selectedID { proxy.scrollTo(id, anchor: .center) }
      }
      .onChange(of: model.selectedID) { _, id in
        if let id { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("\(model.results.count) 扇窗口").foregroundStyle(.secondary)
      Spacer(minLength: 4)
      if model.selected != nil {
        Button("关闭 ⌘W", action: model.onClose)
          .foregroundStyle(Style.danger)
          .disabled(!model.closable.contains(model.selectedID ?? 0))
          .help("关闭选中的窗口，未保存内容由所属 App 确认")
        Button(
          model.selected?.window.state == .minimized ? "还原 ⌘M" : "最小化 ⌘M", action: model.onMinimize
        )
        .disabled(!model.manageable.contains(model.selectedID ?? 0))
        .help("管理选中的窗口；部分其他桌面的窗口只支持切换")
        Button("切换 ↩", action: model.onConfirm).foregroundStyle(Style.brandInk)
      }
    }
    .buttonStyle(.plain).font(.system(size: 11))
    .padding(.horizontal, 16).frame(height: 38)
  }
}

/// 一扇窗口的可访问卡片，鼠标悬停与键盘选择分别显示。
private struct SwitchWindowCard: View {
  let item: SwitchWindow
  let image: CGImage?
  let icon: NSImage?
  let selected: Bool
  let closable: Bool
  let manageable: Bool
  let close: () -> Void
  let minimize: () -> Void
  let open: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: open) { content }
      .buttonStyle(.plain)
      .background { HoverTracker { hovered = $0 } }
      .help("\(item.appName) · \(item.title)\n窗口编号 \(item.id)")
      .accessibilityLabel(item.appName + "，" + item.title)
      .accessibilityValue(state ?? "当前桌面")
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityActions {
        if closable { Button("关闭窗口", action: close) }
        if manageable {
          Button(item.window.state == .minimized ? "还原窗口" : "最小化窗口", action: minimize)
        }
      }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 7) {
      thumbnail.frame(height: 116)
      HStack(spacing: 5) {
        if let icon {
          Image(nsImage: icon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
        }
        Text(item.appName).font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 0)
        if let state { Text(state).font(.system(size: 10)).foregroundStyle(.secondary) }
      }
      Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .lineLimit(1).truncationMode(.tail)
    .padding(8)
    .background(RoundedRectangle(cornerRadius: Style.Radius.card).fill(fill))
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: Style.Radius.card).contrastSelectionBorder()
      }
    }
    .contentShape(.rect)
  }

  private var thumbnail: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Style.Radius.control).fill(Style.inputFill)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4)
      } else if let icon {
        Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
      } else {
        Image(systemName: "macwindow").font(.system(size: 32)).foregroundStyle(.secondary)
      }
    }
  }

  private var fill: Color { selected ? Style.selectedFill : hovered ? Style.hoverFill : .clear }

  private var state: String? {
    switch item.window.state {
    case .shown: nil
    case .minimized: "已最小化"
    case .hidden: "已隐藏"
    case .elsewhere: "其他桌面"
    }
  }
}
