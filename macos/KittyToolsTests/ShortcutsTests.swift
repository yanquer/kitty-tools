// 快捷键界面的纯函数单测：键帽拆分（速查表 / 录制框 / 引导共用）、注册失败原因（-9868 只在只带 ⌥ 时才是系统限制）、
// 速查表 sheet 的高度放得进设置窗、录制时拒绝各 App 通用的编辑键、全局默认键与用户自定义键的优先级。

import Carbon.HIToolbox
import Testing

@testable import KittyTools

struct ShortcutsTests {
  @Test func keyCaps() {
    #expect(KeyCombo.caps("⇧⌘S") == ["⇧", "⌘", "S"])
    #expect(KeyCombo.caps("⌥空格") == ["⌥", "空格"])
    #expect(KeyCombo.caps("⌘1–9") == ["⌘", "1–9"])
    #expect(KeyCombo.caps("⌘-") == ["⌘", "-"])
    #expect(KeyCombo.caps("⌘方向键") == ["⌘", "方向键"])
    #expect(KeyCombo.caps("⌥⇧") == ["⌥", "⇧"])  // 录制中只按着修饰键
    #expect(KeyCombo.caps("Esc") == ["Esc"])
    #expect(KeyCombo.caps("↑↓") == ["↑↓"])
    #expect(KeyCombo.caps("") == [])
  }

  @Test func failureMessages() {
    let optionC = HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey)
    let optionShiftC = HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey | shiftKey)
    let commandShiftI = HotKey(keyCode: kVK_ANSI_I, modifiers: cmdKey | shiftKey)
    let internalError = OSStatus(eventInternalErr)
    #expect(HotKeyCenter.failureMessage(internalError, hotKey: optionC).contains("只带 ⌥"))
    #expect(HotKeyCenter.failureMessage(internalError, hotKey: optionShiftC).contains("只带 ⌥"))
    #expect(!HotKeyCenter.failureMessage(internalError, hotKey: commandShiftI).contains("只带 ⌥"))
    #expect(
      HotKeyCenter.failureMessage(OSStatus(eventHotKeyExistsErr), hotKey: commandShiftI)
        .contains("重复"))
  }

  /// 速查表每组至少一行、组名不重复（ForEach 按组名当 id）
  @Test func cheatSheetGroups() {
    // 功能全开着时的样子（不读宿主 App 的偏好：用户在 Dev 版里关过哪个功能也不影响）
    let all = Set(Feature.allCases)
    let groups = ShortcutsSheet.groups(enabled: all)
    let titles = groups.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(groups.allSatisfy { !$0.entries.isEmpty })
    // 每个全局快捷键都出现在速查表里，且只出现一次
    let globals = groups.flatMap(\.globals)
    #expect(
      Set(globals) == Set(HotKeyAction.allCases) && globals.count == HotKeyAction.allCases.count)
    // 快捷键页、速查表里那一行的名字：只有状态屏另写（它的键默认是先选一个状态，设置里改成直进时是进排在最前面的），
    // 别的就是动作名
    #expect(HotKeyAction.statusScreen.rowTitle(statusEntersFirst: false) == "选一个状态进入")
    #expect(HotKeyAction.statusScreen.rowTitle(statusEntersFirst: true) == "进入排在最前面的状态")
    #expect(
      HotKeyAction.allCases.filter { $0 != .statusScreen }.allSatisfy {
        $0.rowTitle(statusEntersFirst: false) == $0.title
          && $0.rowTitle(statusEntersFirst: true) == $0.title
      })
    // 快捷键页的分组同样一个不漏、不重
    let grouped = HotKeyAction.visibleSections(enabled: all).flatMap(\.actions)
    #expect(
      Set(grouped) == Set(HotKeyAction.allCases) && grouped.count == HotKeyAction.allCases.count)
  }

  /// ⌘C、⇧⌘Z 这类各 App 通用的键设成全局会在所有 App 里失效：录制时拒绝；⌥C、⌘⇧C 照常能录
  @Test func reservedEditKeys() {
    #expect(HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey).isReservedEditKey)
    #expect(HotKey(keyCode: kVK_ANSI_Z, modifiers: cmdKey | shiftKey).isReservedEditKey)
    #expect(HotKey(keyCode: kVK_ANSI_Grave, modifiers: cmdKey).isReservedEditKey)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey).isReservedEditKey)
    #expect(!HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | shiftKey).isReservedEditKey)
    #expect(HotKey.reservedEditKeys.count == 12)
  }

  /// 全局默认键沿用用户现有应用的习惯，录屏为 ⌥R；所有默认键有效、互不重复。
  @Test func defaultHotKeys() {
    let expected: [(HotKeyAction, Int, Int)] = [
      (.clipboard, kVK_ANSI_J, cmdKey),
      (.selectionTranslate, kVK_ANSI_A, optionKey),
      (.inputTranslate, kVK_ANSI_F, optionKey),
      (.screenshotTranslate, kVK_ANSI_S, optionKey),
      (.launcher, kVK_Space, optionKey),
      (.screenshot, kVK_ANSI_Q, optionKey),
      (.screenshotLastRegion, kVK_ANSI_X, optionKey),
      (.recognizeText, kVK_ANSI_D, optionKey),
      (.screenRecord, kVK_ANSI_R, optionKey),
      (.pinClipboard, kVK_ANSI_W, optionKey),
      (.shotHistory, kVK_ANSI_E, optionKey),
      (.noteCapture, kVK_ANSI_N, optionKey),
      (.windowSwitch, kVK_Tab, optionKey),
      (.windowSwitchPrevious, kVK_Tab, optionKey | shiftKey),
      (.appWindowSwitch, kVK_ANSI_Grave, optionKey),
      (.appWindowSwitchPrevious, kVK_ANSI_Grave, optionKey | shiftKey),
    ]
    for (action, code, modifiers) in expected {
      let hotKey = HotKey(keyCode: code, modifiers: modifiers)
      #expect(action.defaultHotKey == hotKey)
      #expect(action.resolve { _ in nil } == hotKey)
    }
    let defaults = HotKeyAction.allCases.compactMap(\.defaultHotKey)
    #expect(
      defaults.count == expected.count
        + WindowLayoutAction.allCases.filter { $0.defaultHotKey != nil }.count)
    #expect(Set(defaults).count == defaults.count)
    #expect(defaults.allSatisfy { $0.isUsable })
  }

  /// 新默认键让给用户自己设的组合，已保存的旧键和清除状态照常保留；只用内存里的偏好数据。
  @Test(arguments: [
    HotKeyAction.clipboard, .selectionTranslate, .inputTranslate, .screenshotTranslate, .screenshot,
    .recognizeText, .screenRecord, .pinClipboard, .shotHistory,
  ])
  func defaultYieldsToUserBinding(action: HotKeyAction) throws {
    let hotKey = try #require(action.defaultHotKey)
    let hotKeyData = try JSONEncoder().encode(hotKey)
    var stored: [HotKeyAction: Data] = [:]
    #expect(action.resolve { stored[$0] } == hotKey)
    stored[.translateReplace] = hotKeyData
    #expect(action.resolve { stored[$0] } == nil)
    #expect(HotKeyAction.translateReplace.resolve { stored[$0] } == hotKey)
    stored[action] = hotKeyData
    #expect(action.resolve { stored[$0] } == hotKey)
    // 已保存的键优先，包括用户曾明确保存的旧默认键。
    let oldKey = HotKey(keyCode: kVK_ANSI_T, modifiers: optionKey)
    stored[action] = try JSONEncoder().encode(oldKey)
    #expect(action.resolve { stored[$0] } == oldKey)
    stored[action] = Data()
    #expect(action.resolve { stored[$0] } == nil)
    // 被清除的动作不占默认键
    stored = [.translateReplace: Data()]
    #expect(action.resolve { stored[$0] } == hotKey)
  }

  /// 速查表左栏按设置页分类：和设置侧栏同序、通用排最后，钉图归截图、录屏录音归录制、刘海岛和「设置」归通用。
  /// 搜索跨类找：空格分开的词都要对上（组名 + 说明 + 按键），词全在组名里的整组列出，别的只留对上的行
  @Test func cheatSheetSectionsAndSearch() throws {
    let groups = ShortcutsSheet.groups(enabled: Set(Feature.allCases))
    #expect(
      ShortcutsSheet.sections(groups) == [
        .clipboard, .launcher, .translate, .screenshot, .record, .notes, .reminders, .statusScreen,
        .launchpad, .windowSwitcher, .windowLayout, .general,
      ])
    #expect(groups.first { $0.title == "提醒" }?.page == .reminders)
    func page(_ title: String) -> SettingsPage? { groups.first { $0.title == title }?.page }
    #expect(page("钉图") == .screenshot && page("截图 · 框选") == .screenshot)
    #expect(page("录音") == .record && page("系统命令") == .launcher)
    #expect(page("刘海岛") == .general && page("主界面") == .general && page("设置") == .general)

    let pin = ShortcutsSheet.matching(groups, query: "钉")
    let pinGroup = try #require(groups.first { $0.title == "钉图" })
    #expect(pin.first { $0.title == "钉图" }?.entries == pinGroup.entries)
    #expect(pin.first { $0.title == "截图 · 出图" }?.entries.map(\.keys) == [["T"]])
    let menu = ShortcutsSheet.matching(groups, query: "剪贴板 ⌘K")
    #expect(menu.map(\.title) == ["剪贴板"])
    #expect(menu.first?.globals.isEmpty == true && menu.first?.entries.count == 1)
    #expect(!ShortcutsSheet.matching(groups, query: "esc").isEmpty)
    #expect(ShortcutsSheet.matching(groups, query: "没有这种键").isEmpty)
    #expect(ShortcutsSheet.matching(groups, query: "  ").count == groups.count)
  }

  /// 速查表 sheet 挂在设置窗工具栏下沿：默认内容 600、最小 460，减去约 52 的工具栏后都放得下，窗口再大也只到 520
  @Test func cheatSheetFitsSettingsWindow() {
    #expect(ShortcutsButton.sheetHeight(available: 600 - 52) <= 600 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 460 - 52) <= 460 - 52)
    #expect(ShortcutsButton.sheetHeight(available: 2000) == 520)
  }
}
