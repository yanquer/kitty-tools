// 窗口切换器的纯交互与受控失败验证，不切换或关闭真实窗口，不写用户偏好。

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor struct WindowSwitcherTests {
  /// 构造带稳定身份和应用归属的测试窗口。
  private func item(_ id: CGWindowID, app: String = "Safari", title: String = "文稿") -> SwitchWindow
  {
    SwitchWindow(
      window: DockWindow(
        id: id, title: title, state: .shown,
        size: CGSize(width: 1200, height: 800)), pid: 42, appName: app)
  }

  /// 搜索同时覆盖应用名、窗口标题、多个词与大小写重音处理。
  @Test func searchesApplicationAndWindow() {
    let rows = [
      item(1, app: "Safari", title: "开发文档"), item(2, app: "编辑器", title: "项目方案"),
      item(3, app: "Café", title: "项目文档"),
    ]
    #expect(WindowSwitcherModel.filtered(rows, query: "  ").map(\.id) == [1, 2, 3])
    #expect(WindowSwitcherModel.filtered(rows, query: "SAFARI 文档").map(\.id) == [1])
    #expect(WindowSwitcherModel.filtered(rows, query: "cafe 项目").map(\.id) == [3])
    #expect(WindowSwitcherModel.filtered(rows, query: "编辑器 文档").isEmpty)
  }

  /// 焦点事件的顺序优先，未观察到的使用系统窗口顺序及稳定编号。
  @Test func ordersByObservedFocusThenStacking() {
    let rows = (1...5).map { item(CGWindowID($0)) }
    let sorted = WindowSwitcherModel.ordered(rows, recent: [2: 9, 3: 10], stacking: [1: 0, 4: 1])
    #expect(sorted.map(\.id) == [3, 2, 1, 4, 5])
  }

  /// 当前应用刷新及读取失败均不会擦掉其他应用的最近使用记录。
  @Test func partialRefreshPreservesGlobalHistory() {
    let history: [CGWindowID: UInt64] = [1: 5, 2: 9, 3: 7]
    let scoped = WindowSwitcherModel.historyAfterRefresh(
      history, windows: [item(1)], complete: false)
    #expect(scoped == history)
    #expect(
      WindowSwitcherModel.ordered([item(1), item(2), item(3)], recent: scoped, stacking: [:])
        .map(\.id) == [2, 3, 1])
    let complete = WindowSwitcherModel.historyAfterRefresh(
      history, windows: [item(1), item(3)], complete: true)
    #expect(complete == [1: 5, 3: 7])
  }

  /// 从当前窗口跳到下一扇，反向、循环、大步数与空结果均有确定行为。
  @Test func cyclesAndKeepsStableSelection() {
    let model = WindowSwitcherModel()
    model.windows = [item(1), item(2), item(3)]
    model.selectedID = 1
    model.move(1)
    #expect(model.selectedID == 2)
    model.move(-1)
    #expect(model.selectedID == 1)
    model.move(-1)
    #expect(model.selectedID == 3)
    model.move(4)
    #expect(model.selectedID == 1)
    model.selectedID = nil
    model.move(1)
    #expect(model.selectedID == 1)
    model.selectedID = nil
    model.move(-1)
    #expect(model.selectedID == 3)
    model.windows = []
    model.move(1)
    #expect(model.selectedID == nil)
  }

  /// 搜索保留仍匹配的选择，移除选中目标后选择首项，无结果时清除。
  @Test func searchReconcilesSelection() {
    let model = WindowSwitcherModel()
    model.windows = [
      item(1, app: "编辑器", title: "方案 A"), item(2, app: "编辑器", title: "方案 B"),
      item(3, app: "编辑器", title: "笔记"),
    ]
    model.selectedID = 2
    model.query = "方案"
    #expect(model.selectedID == 2)
    model.query = "方案 A"
    #expect(model.selectedID == 1)
    model.query = "不存在"
    #expect(model.selected == nil && model.selectedID == nil)
    model.query = ""
    #expect(model.selectedID == 1)
  }

  /// 输入框保留横向编辑按键，导航和确认通过项目原有命令入口派发。
  @Test func commandsPreserveTextEditing() {
    let model = WindowSwitcherModel()
    model.windows = [item(1), item(2)]
    model.selectedID = nil
    var confirmations = 0
    model.onConfirm = { confirmations += 1 }
    #expect(model.command(#selector(NSResponder.moveDown(_:))))
    #expect(model.selectedID == 1)
    #expect(model.command(#selector(NSResponder.insertTab(_:))))
    #expect(model.selectedID == 2)
    #expect(!model.command(#selector(NSResponder.moveLeft(_:))))
    #expect(!model.command(#selector(NSResponder.cancelOperation(_:))))
    #expect(model.command(#selector(NSResponder.insertNewline(_:))))
    #expect(confirmations == 1)
  }

  /// 保持呼出键时也能按命令进入搜索，额外修饰键不会误触操作。
  @Test func commandRoutingWhileHoldingSummonModifiers() {
    #expect(WindowSwitcherModel.acceptsCommand([.command, .option], held: .option))
    #expect(WindowSwitcherModel.acceptsCommand([.command, .control], held: .control))
    #expect(WindowSwitcherModel.acceptsCommand(.command, held: .command))
    #expect(!WindowSwitcherModel.acceptsCommand(.option, held: .option))
    #expect(!WindowSwitcherModel.acceptsCommand([.command, .option, .shift], held: .option))
  }

  /// 旁白卡片动作明确选择自身窗口，不沿用其他键盘选择。
  @Test func accessibleActionsUseTheirWindowIdentity() {
    let model = WindowSwitcherModel()
    model.windows = [item(1), item(2)]
    model.closable = [2]
    model.manageable = [1, 2]
    var closed: CGWindowID?
    var minimized: CGWindowID?
    model.onClose = { closed = model.selectedID }
    model.onMinimize = { minimized = model.selectedID }
    model.close(2)
    #expect(closed == 2)
    model.minimize(1)
    #expect(minimized == 1)
    model.close(1)
    #expect(closed == 2)
  }

  /// 缺少目标对象的失败记录原始 AXError，关闭与最小化均不冒充成功。
  @Test func missingWindowRetainsOriginalFailure() {
    let reader = DockWindows()
    let window = item(99).window
    #expect(!reader.canManage(window) && !reader.canClose(window))
    #expect(!reader.setMinimized(true, window: window))
    #expect(reader.lastError?.domain == "KittyTools.WindowAccessibility")
    #expect(reader.lastError?.code == Int(AXError.invalidUIElement.rawValue))
    #expect(reader.lastError?.localizedDescription.contains("取得窗口") == true)
    #expect(!reader.close(window))
    #expect(reader.lastError?.code == Int(AXError.invalidUIElement.rawValue))
  }

  /// 目标进程退出及窗口快照失效分开提示，确认、关闭和最小化都不会静默返回。
  @Test func missingTargetReportsRefreshForEveryAction() {
    let switcher = WindowSwitcher()
    let window = item(99).window
    switcher.model.windows = [SwitchWindow(window: window, pid: Int32.max, appName: "已退出应用")]
    for action in [switcher.model.onConfirm, switcher.model.onClose, switcher.model.onMinimize] {
      switcher.model.issue = nil
      action()
      #expect(switcher.model.issue == "目标 App 已退出，请刷新窗口列表")
    }
    switcher.model.windows = [
      SwitchWindow(
        window: window,
        pid: NSRunningApplication.current.processIdentifier, appName: "本进程测试目标")
    ]
    for action in [switcher.model.onConfirm, switcher.model.onClose, switcher.model.onMinimize] {
      switcher.model.issue = nil
      action()
      #expect(switcher.model.issue == "窗口信息已失效，请刷新窗口列表")
    }
  }

  /// 默认键独立配置并归属功能开关，授权相关开关只留在本机。
  @Test func defaultsAndFeatureGates() {
    #expect(
      HotKeyAction.windowSwitch.defaultHotKey == HotKey(keyCode: kVK_Tab, modifiers: optionKey))
    #expect(
      HotKeyAction.windowSwitchPrevious.defaultHotKey
        == HotKey(keyCode: kVK_Tab, modifiers: optionKey | shiftKey))
    #expect(
      HotKeyAction.appWindowSwitch.defaultHotKey
        == HotKey(keyCode: kVK_ANSI_Grave, modifiers: optionKey))
    #expect(!Feature.windowSwitcher.defaultOn)
    #expect(SettingsSync.localKeys.contains(Feature.windowSwitcher.prefsKey))
    let enabled = HotKeyAction.visibleSections(enabled: [.windowSwitcher]).flatMap(\.actions)
    #expect(enabled.contains(.windowSwitch) && enabled.contains(.appWindowSwitchPrevious))
    #expect(!HotKeyAction.visibleSections(enabled: []).flatMap(\.actions).contains(.windowSwitch))
  }
}
