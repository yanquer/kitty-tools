// 设置 › 窗口切换，提供独立开关、权限状态和快捷键速查入口。

import SwiftUI

/// 独立窗口切换的开关、操作说明及本机权限。
struct WindowSwitcherTab: View {
  @State private var trusted = Permissions.isAccessibilityTrusted
  @State private var recording = Permissions.isScreenRecordingAllowed

  var body: some View {
    Form {
      Section {
        FeatureToggle(feature: .windowSwitcher, inPage: true)
        ShortcutsButton()
      } header: {
        Text("窗口切换")
      } footer: {
        SectionFootnote(
          "按最近使用顺序列出各个 App 的窗口。按住快捷键的修饰键连续切换，松开确认；⌘F 进入搜索后可以松开修饰键输入。关闭和最小化作用于选中的窗口，其他桌面的部分窗口仅支持切换。")
      }
      Section {
        PermissionRow(
          title: "辅助功能", detail: "读取窗口、跟踪最近使用顺序、切换和管理窗口；没有它用不了",
          symbol: "hand.raised.fill", color: Style.Family.dockPreview, granted: trusted
        ) {
          Permissions.grant(.accessibility)
        }
        PermissionRow(
          title: "屏幕录制", detail: "显示窗口缩略图；没有它显示应用图标和可读取的标题",
          symbol: HotKeyAction.screenRecord.symbol, color: Style.Family.screenshot,
          granted: recording
        ) {
          Permissions.grant(.screenRecording)
        }
      } header: {
        Text("权限")
      } footer: {
        SectionFootnote("启用后开始记录窗口的使用顺序；启动时未观察到的历史使用顺序按系统窗口顺序显示。缩略图仅缓存在内存中，最多 20 张。")
      }
    }
    .formStyle(.grouped)
    .onSettingsBecameKey {
      trusted = Permissions.isAccessibilityTrusted
      recording = Permissions.isScreenRecordingAllowed
    }
  }
}
