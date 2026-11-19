// 设置 › 演示画布：说明工具行为，提供开始/结束入口与插件移除操作。

import SwiftUI

struct PresentationTab: View {
  let canvas: PresentationCanvas
  var toggle: () -> Void

  var body: some View {
    Form {
      Section {
        LabeledContent("当前状态", value: canvas.isActive ? "正在演示" : "未开始")
        Button(canvas.isActive ? "结束演示" : "开始演示", action: toggle)
        ShortcutsButton()
      } footer: {
        SectionFootnote("在鼠标所在屏幕画箭头、圈重点或使用激光笔；工具栏可拖动和折叠。也可以从菜单栏、主界面和启动器进入。")
      }
      Section("操作") {
        Text("选择画笔后直接在屏幕上标注；按 Esc 或点箭头返回操作窗口，已有标注保留。点关闭按钮结束整场演示。")
        Text("白板按钮切换到白色背景；返回操作窗口时同时收起白板。标注只保留在本次演示中。")
        Text("开始其他全局工具、锁屏、睡眠或显示器变化时结束演示。无需屏幕录制授权，演示期间不创建音视频文件。")
      }
      PluginRemoveSection(plugin: .presentation)
    }
    .formStyle(.grouped)
  }
}
