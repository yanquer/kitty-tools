// 设置 › 窗口管理，提供动作快捷键、拖拽区域、布局参数、自动操作和停用 App。

import SwiftUI

/// 与窗口执行层共用动作与参数定义，避免设置出现无法执行的内部动作。
struct WindowLayoutTab: View {
  let center: HotKeyCenter
  @AppStorage(Prefs.layoutSnapping) private var snapping = true
  @AppStorage(Prefs.layoutUnsnap) private var unsnap = true
  @AppStorage(Prefs.layoutGap) private var gap = 0.0
  @AppStorage(Prefs.layoutEdgeGap) private var edgeGap = 0.0
  @AppStorage(Prefs.layoutStep) private var step = 30.0
  @AppStorage(Prefs.layoutWidth) private var width = 1680.0
  @AppStorage(Prefs.layoutHeight) private var height = 1050.0
  @AppStorage(Prefs.layoutAlmost) private var almost = 0.9
  @AppStorage(Prefs.layoutCascade) private var cascade = 30.0
  @AppStorage(Prefs.layoutSidebar) private var sidebar = 400.0
  @AppStorage(Prefs.layoutPortrait) private var portrait = true
  @AppStorage(Prefs.layoutProportions) private var proportions = true
  @AppStorage(Prefs.layoutRepeat) private var repeated = WindowLayoutRepeat.across.rawValue
  @AppStorage(Prefs.layoutSnapModifier) private var modifier = "none"
  @AppStorage(Prefs.layoutSnapAreas) private var areas =
    "topLeft,maximize,topRight,leftHalf,rightHalf,bottomLeft,bottomHalf,bottomRight"
  @AppStorage(Prefs.layoutMouseBindings) private var mouse = "[]"
  @AppStorage(Prefs.layoutNewWindowAction) private var newWindow = ""
  @AppStorage(Prefs.layoutDoubleClick) private var doubleClick = ""
  @AppStorage(Prefs.layoutKeepCentered) private var keepCentered = true
  @AppStorage(Prefs.layoutMinimumWidth) private var minimumWidth = 0.25
  @AppStorage(Prefs.layoutMinimumHeight) private var minimumHeight = 0.25
  @State private var ignored =
    UserDefaults.standard.stringArray(forKey: Prefs.layoutIgnoredApps) ?? []
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var query = ""

  private var groups: [String] { ["分屏布局", "细分网格", "尺寸与位置", "显示器", "多个窗口"] }

  var body: some View {
    Form {
      Section {
        FeatureToggle(feature: .windowLayout, inPage: true)
        ShortcutsButton()
      } header: {
        Text("窗口管理")
      } footer: {
        SectionFootnote("调整前台窗口的位置与大小，支持细分网格、多显示器、平铺和层叠。还原记录仅保留在本次运行中，最多 128 扇窗口。")
      }
      Section("权限") {
        PermissionRow(
          title: "辅助功能", detail: "读取窗口位置，移动窗口并调整大小",
          symbol: "hand.raised.fill", color: Style.Family.dockPreview, granted: trusted
        ) {
          Permissions.grant(.accessibility)
        }
      }
      Section {
        Toggle("拖到屏幕边缘吸附", isOn: $snapping)
        Toggle("拖离布局区域时还原原始大小", isOn: $unsnap).disabled(!snapping)
        Picker("吸附需要按住", selection: $modifier) {
          Text("直接拖拽").tag("none")
          Text("⌥ Option").tag("option")
          Text("⌃ Control").tag("control")
          Text("⇧ Shift").tag("shift")
          Text("⌘ Command").tag("command")
        }.disabled(!snapping)
        DisclosureGroup("屏幕边缘与角落") {
          ForEach(WindowLayoutSnap.allCases) { area in
            WindowLayoutActionMenu(
              title: area.title, selection: areaBinding(area), layoutOnly: true)
          }
        }.disabled(!snapping)
      } header: {
        Text("拖拽")
      } footer: {
        SectionFootnote("拖动窗口并触及边缘时显示目标区域，松开鼠标执行。系统也启用了窗口平铺时，两者可能同时响应，可在系统设置 › 桌面与程序坞中选择使用方式。")
        if !WindowLayoutSnap.valid(areas) {
          Text("屏幕边缘动作设置无法识别，重新选择布局后再使用吸附。")
            .foregroundStyle(Color(nsColor: .systemOrange))
        }
      }.gated(by: .windowLayout)
      Section {
        Stepper("窗口间距  \(Int(gap)) 点", value: $gap, in: 0...100, step: 1)
        Stepper("屏幕边缘间距  \(Int(edgeGap)) 点", value: $edgeGap, in: 0...100, step: 1)
        Stepper("放大缩小步长  \(Int(step)) 点", value: $step, in: 1...300, step: 1)
        Stepper("接近最大化  \(Int(almost * 100))%", value: $almost, in: 0.5...1, step: 0.05)
        Stepper("层叠错位  \(Int(cascade)) 点", value: $cascade, in: 1...150, step: 1)
        Stepper("待办预留宽度  \(Int(sidebar)) 点", value: $sidebar, in: 100...3000, step: 20)
        Toggle("分区按屏幕方向排列", isOn: $portrait)
        Toggle("跨屏时按比例保留位置和尺寸", isOn: $proportions)
        Toggle("放大缩小时保持窗口中心", isOn: $keepCentered)
        Stepper("缩小最小宽度  \(Int(minimumWidth * 100))%", value: $minimumWidth, in: 0...1, step: 0.05)
        Stepper(
          "缩小最小高度  \(Int(minimumHeight * 100))%", value: $minimumHeight, in: 0...1, step: 0.05)
        Picker("重复执行同一布局", selection: $repeated) {
          ForEach(WindowLayoutRepeat.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
      } header: {
        Text("布局")
      } footer: {
        SectionFootnote("区域较小时，窗口间距随可用空间缩小。缩小最小宽度和高度只约束放大缩小、尺寸折半动作。")
      }.gated(by: .windowLayout)
      Section {
        TextField("宽度", value: $width, format: .number)
        TextField("高度", value: $height, format: .number)
      } header: {
        Text("自定义尺寸")
      } footer: {
        SectionFootnote("填 0.1 到 1 表示屏幕比例，大于 1 表示点数，最大 20000。执行「自定义尺寸」时在可用区域内居中。")
        if !width.isFinite || !height.isFinite || !(0.1...20000).contains(width)
          || !(0.1...20000).contains(height)
        {
          Text("宽度和高度需要在 0.1 到 20000 之间，尺寸无效时无法执行这个动作。")
            .foregroundStyle(Color(nsColor: .systemOrange))
        }
      }.gated(by: .windowLayout)
      Section {
        WindowLayoutActionMenu(title: "新建窗口自动布局", selection: $newWindow, layoutOnly: true)
        WindowLayoutActionMenu(title: "双击标题栏", selection: $doubleClick, layoutOnly: true)
        DisclosureGroup("鼠标按钮") {
          ForEach(2..<32, id: \.self) { button in
            WindowLayoutActionMenu(
              title: button == 2 ? "鼠标中键" : "鼠标按钮 \(button + 1)",
              selection: mouseBinding(button), layoutOnly: false)
          }
        }
      } header: {
        Text("自动操作与鼠标")
      } footer: {
        SectionFootnote("自动布局作用于 App 新建的普通窗口。鼠标动作作用于指针下的窗口，原始按键仍交给该 App，系统标题栏双击设置也会响应。")
        if WindowLayoutMouseBinding.decode(mouse) == nil {
          Text("鼠标按钮设置无法读取，请重新选择动作。")
            .foregroundStyle(Color(nsColor: .systemOrange))
        }
      }.gated(by: .windowLayout)
      Section {
        TextField("搜索动作", text: $query)
        ForEach(groups, id: \.self) { group in
          let actions = WindowLayoutAction.allCases.filter {
            $0.group == group
              && (query.isEmpty || $0.title.localizedStandardContains(query)
                || $0.rawValue.localizedStandardContains(query))
          }
          if !actions.isEmpty {
            DisclosureGroup(group) {
              ForEach(actions) { action in
                HotKeyRow(target: .global(.windowLayout(action)), center: center)
              }
            }
          }
        }
      } header: {
        Text("布局快捷键")
      } footer: {
        SectionFootnote("半屏为 ⌃⌥方向键，最大化为 ⌃⌥↩，居中为 ⌃⌥C，还原为 ⌃⌥⌫。多个窗口布局使用同一组合时按动作顺序循环。")
      }.gated(by: .windowLayout)
      Section {
        ForEach(ignored, id: \.self) { id in
          HStack {
            AppListRow(bundleID: id)
            Spacer()
            Button("移除", systemImage: "minus.circle") {
              changeIgnored { $0.removeAll { $0 == id } }
            }
            .labelStyle(.iconOnly).buttonStyle(.plain).help("移出停用名单")
          }
        }
        Button("添加 App…", systemImage: "plus") {
          let chosen = AppListRow.chooseApps(prompt: "添加", message: "这些 App 中停用窗口管理")
          changeIgnored { entries in
            for id in chosen where !entries.contains(id) { entries.append(id) }
          }
        }
      } header: {
        Text("在这些 App 里停用")
      } footer: {
        SectionFootnote("名单中的 App 停用窗口管理的快捷键、拖拽吸附和自动操作。其他功能的快捷键可在快捷键页单独设置。")
      }.gated(by: .windowLayout)
    }
    .formStyle(.grouped)
    .onSettingsBecameKey { trusted = Permissions.isAccessibilityTrusted }
    .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
      ignored = UserDefaults.standard.stringArray(forKey: Prefs.layoutIgnoredApps) ?? []
    }
  }

  /// 改名单前现读偏好，避免覆盖同步或其他设置入口刚写入的 App。
  private func changeIgnored(_ edit: (inout [String]) -> Void) {
    var entries = UserDefaults.standard.stringArray(forKey: Prefs.layoutIgnoredApps) ?? []
    edit(&entries)
    UserDefaults.standard.set(entries, forKey: Prefs.layoutIgnoredApps)
    ignored = entries
  }

  /// 将一个吸附区域的动作写回完整顺序，关闭使用 off 占位。
  private func areaBinding(_ area: WindowLayoutSnap) -> Binding<String> {
    Binding(
      get: { WindowLayoutSnap.actions(areas)[area.rawValue]?.rawValue ?? "" },
      set: { value in
        var entries = WindowLayoutSnap.actions(areas)
        entries[area.rawValue] = WindowLayoutAction(rawValue: value)
        areas = entries.map { $0?.rawValue ?? "off" }.joined(separator: ",")
      })
  }

  /// 对鼠标按钮就地添加、替换或移除动作，存储仍是受限映射。
  private func mouseBinding(_ button: Int) -> Binding<String> {
    Binding(
      get: {
        WindowLayoutMouseBinding.decode(mouse)?.first { $0.button == button }?.action.rawValue ?? ""
      },
      set: { value in
        var entries = WindowLayoutMouseBinding.decode(mouse) ?? []
        entries.removeAll { $0.button == button }
        if let action = WindowLayoutAction(rawValue: value) {
          entries.append(.init(button: button, action: action))
        }
        if let text = WindowLayoutMouseBinding.encode(entries) { mouse = text }
      })
  }
}

/// 大量动作使用分组子菜单，当前选择始终显示中文业务名称。
private struct WindowLayoutActionMenu: View {
  let title: String
  @Binding var selection: String
  let layoutOnly: Bool

  var body: some View {
    LabeledContent(title) {
      Menu {
        Button("关闭") { selection = "" }
        Divider()
        ForEach(["分屏布局", "细分网格", "尺寸与位置", "显示器", "多个窗口"], id: \.self) { group in
          let actions = WindowLayoutAction.allCases.filter {
            $0.group == group && (!layoutOnly || WindowLayoutSnap.canSnap($0))
          }
          if !actions.isEmpty {
            Menu(group) {
              ForEach(actions) { action in
                Button(action.displayTitle) { selection = action.rawValue }
              }
            }
          }
        }
      } label: {
        Text(
          selection.isEmpty
            ? "关闭" : WindowLayoutAction(rawValue: selection)?.displayTitle ?? "无法识别的动作"
        ).lineLimit(1).truncationMode(
          .tail)
      }
      .fixedSize()
      .accessibilityLabel(title)
    }
  }
}
