// 窗口管理的动作覆盖、坐标、网格、边缘吸附、设置校验与现有入口兼容性测试。

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Testing

@testable import KittyTools

@MainActor struct WindowLayoutTests {
  private let screen = CGRect(x: -1600, y: 40, width: 1600, height: 1000)
  private let window = CGRect(x: -1400, y: 140, width: 800, height: 600)

  /// 所有布局动作都能经过现有全局入口往返，旧 Carbon 编号保持不变。
  @Test func actionCoverageAndStableHotKeyIDs() {
    #expect(WindowLayoutAction.allCases.count == 143)
    #expect(Set(WindowLayoutAction.allCases.map(\.rawValue)).count == 143)
    let legacy =
      "clipboard selectionTranslate inputTranslate screenshotTranslate launcher screenshot screenshotLastRegion recognizeText translateReplace screenRecord audioRecord pinClipboard statusScreen noteCapture noteNew noteAll launchpad shotHistory island clothesline home reminderNew windowSwitch windowSwitchPrevious appWindowSwitch appWindowSwitchPrevious"
      .split(separator: " ").map(String.init)
    #expect(HotKeyAction.allCases.prefix(legacy.count).map(\.rawValue) == legacy)
    #expect(HotKeyAction.allCases[legacy.count] == .windowLayoutPicker)
    for action in WindowLayoutAction.allCases {
      let global = HotKeyAction.windowLayout(action)
      #expect(HotKeyAction(rawValue: global.rawValue) == global)
      #expect(global.feature == .windowLayout)
      #expect(global.title == action.displayTitle)
      #expect(!action.title.isEmpty && !action.group.isEmpty)
    }
    #expect(HotKeyAction(rawValue: "windowLayout.future") == nil)
  }

  /// 每个动作都有实际执行路径，尺寸与位置动作在不同方向的显示器内有效。
  @Test func everyActionHasAnExecutionPath() {
    let special = WindowLayoutAction.multiple.union([
      .restore, .leftTodo, .rightTodo, .nextDisplay, .previousDisplay,
    ])
    let screens = [
      screen, CGRect(x: 0, y: -1800, width: 1000, height: 1800),
      CGRect(x: 0, y: 0, width: 200, height: 150),
    ]
    for action in WindowLayoutAction.allCases
    where !special.contains(action) && WindowLayout.displayNumber(action) == nil {
      for bounds in screens {
        let result = WindowLayoutGeometry.frame(for: action, current: window, in: bounds)
        #expect(result != nil, "\(action)")
        if let result {
          #expect(WindowLayoutGeometry.valid(result), "\(action)")
          if [.moveLeft, .moveRight, .moveUp, .moveDown].contains(action) {
            #expect(result.size == window.size)
          } else {
            #expect(bounds.insetBy(dx: -1, dy: -1).contains(result), "\(action) \(result)")
          }
        }
      }
    }
    #expect(WindowLayoutGeometry.frame(for: .maximize, current: .zero, in: screen) == nil)
    #expect(WindowLayoutGeometry.frame(for: .maximize, current: window, in: .null) == nil)
  }

  /// 半屏、角落三分之一与十六分网格有精确、独立的面积语义。
  @Test func regionsAndOrientation() throws {
    let left = try #require(WindowLayoutGeometry.frame(for: .leftHalf, current: window, in: screen))
    #expect(left == CGRect(x: -1600, y: 40, width: 800, height: 1000))
    let third = try #require(
      WindowLayoutGeometry.frame(
        for: .topLeftThird, current: window,
        in: CGRect(x: 0, y: 0, width: 1200, height: 900)))
    #expect(third == CGRect(x: 0, y: 0, width: 800, height: 450))
    let portrait = CGRect(x: 0, y: 0, width: 900, height: 1200)
    #expect(
      WindowLayoutGeometry.frame(for: .firstThird, current: window, in: portrait)
        == CGRect(x: 0, y: 0, width: 900, height: 400))
    #expect(
      WindowLayoutGeometry.frame(for: .bottomRightThird, current: window, in: portrait)
        == CGRect(x: 450, y: 400, width: 450, height: 800))
    let grids = WindowLayoutAction.allCases.filter { $0.rawValue.hasSuffix("Sixteenth") }
    #expect(grids.count == 16)
    let frames = grids.compactMap {
      WindowLayoutGeometry.frame(for: $0, current: window, in: screen)
    }
    #expect(frames.reduce(0) { $0 + $1.width * $1.height } == screen.width * screen.height)
    for first in frames.indices {
      for second in frames.indices where second > first {
        let overlap = frames[first].intersection(frames[second])
        #expect(overlap.isNull || overlap.width * overlap.height == 0)
      }
    }
  }

  /// 相邻区域只产生指定间距，屏幕外边缘另由 edgeGap 控制。
  @Test func gapAndScreenMargins() throws {
    let options = WindowLayoutOptions(gap: 12, edgeGap: 10)
    let left = try #require(
      WindowLayoutGeometry.frame(for: .leftHalf, current: window, in: screen, options: options))
    let right = try #require(
      WindowLayoutGeometry.frame(for: .rightHalf, current: window, in: screen, options: options))
    #expect(right.minX - left.maxX == 12)
    #expect(left.minX == screen.minX + 10 && right.maxX == screen.maxX - 10)
    #expect(left.minY == screen.minY + 10 && left.maxY == screen.maxY - 10)
    let tiny = CGRect(x: 0, y: 0, width: 100, height: 80)
    for action in WindowLayoutAction.allCases where action.unitRect != nil {
      let frame = try #require(
        WindowLayoutGeometry.frame(
          for: action, current: window, in: tiny,
          options: WindowLayoutOptions(gap: 100, edgeGap: 100)))
      #expect(tiny.insetBy(dx: -1, dy: -1).contains(frame))
    }
  }

  /// 多屏映射处理负原点、上下排列、分辨率差异以及无效来源。
  @Test func transferAndDisplaySelection() throws {
    let target = CGRect(x: 0, y: -900, width: 800, height: 500)
    let mapped = try #require(
      WindowLayoutGeometry.transferred(window, from: screen, to: target, proportional: true))
    #expect(mapped == CGRect(x: 100, y: -850, width: 400, height: 300))
    #expect(
      WindowLayoutGeometry.transferred(window, from: .zero, to: target, proportional: true) == nil)
    #expect(WindowLayoutGeometry.screenIndex(for: window, screens: [screen, target]) == 0)
    #expect(WindowLayoutGeometry.screenIndex(for: target, screens: [screen, target]) == 1)
    #expect(WindowLayoutGeometry.screenIndex(for: window, screens: []) == nil)
    #expect(WindowLayout.displayNumber(.displayNine) == 8)
    #expect(WindowLayout.displayNumber(.maximize) == nil)
    #expect(
      WindowLayoutGeometry.screenOrder([
        CGRect(x: 0, y: 0, width: 1600, height: 1000),
        CGRect(x: -1600, y: 0, width: 1600, height: 1000),
        CGRect(x: 0, y: -900, width: 900, height: 900),
      ]) == [2, 1, 0])
  }

  /// 批量平铺无重叠且覆盖所有窗口，过大输入不会分配无界数组。
  @Test func multiWindowGeometry() {
    for count in 1...128 {
      for action in [WindowLayoutAction.tileAll, .tileActiveApp, .tileRows, .tileColumns] {
        let frames = WindowLayoutGeometry.tiled(count: count, in: screen, action: action, gap: 4)
        #expect(frames.count == count)
        #expect(frames.allSatisfy { screen.contains($0) && WindowLayoutGeometry.valid($0) })
      }
      let cascade = WindowLayoutGeometry.cascaded(count: count, in: screen, step: 30)
      #expect(cascade.count == count && cascade.allSatisfy { screen.contains($0) })
    }
    #expect(WindowLayoutGeometry.tiled(count: 129, in: screen, action: .tileAll, gap: 0).isEmpty)
    #expect(WindowLayoutGeometry.cascaded(count: 0, in: screen, step: 30).isEmpty)
    let mirrored = WindowLayoutGeometry.mirrored(window, in: screen)
    #expect(mirrored == CGRect(x: -1000, y: 140, width: 800, height: 600))
    #expect(WindowLayoutGeometry.mirrored(mirrored, in: screen) == window)
  }

  /// 居中与显著居中保留尺寸，拖离吸附区域保持指针相对位置。
  @Test func positioningAndUnsnap() throws {
    #expect(
      WindowLayoutGeometry.frame(for: .centerProminently, current: window, in: screen)
        == CGRect(x: -1200, y: 140, width: 800, height: 600))
    let current = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let result = WindowLayoutGeometry.unsnapped(
      original: CGSize(width: 600, height: 400),
      current: current, pointer: CGPoint(x: 500, y: 20),
      in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
    #expect(result == CGRect(x: 200, y: 0, width: 600, height: 400))
    #expect(WindowLayout.repeated(.leftHalf, count: 1) == .firstTwoThirds)
    #expect(WindowLayout.repeated(.leftHalf, count: 3) == .leftHalf)
    #expect(WindowLayout.repeated(.maximize, count: 1) == .maximize)
  }

  /// 边缘、角落、屏幕外和自定义吸附动作都使用相同判定。
  @Test func snapAreasAndValidation() {
    #expect(WindowLayoutSnap.area(at: CGPoint(x: -1600, y: 40), in: screen) == .topLeft)
    #expect(WindowLayoutSnap.area(at: CGPoint(x: -800, y: 40), in: screen) == .top)
    #expect(WindowLayoutSnap.area(at: CGPoint(x: -1, y: 500), in: screen) == .right)
    #expect(WindowLayoutSnap.area(at: CGPoint(x: -800, y: 500), in: screen) == nil)
    #expect(WindowLayoutSnap.area(at: CGPoint(x: 100, y: 500), in: screen) == nil)
    let entries = "topLeft,maximize,topRight,leftHalf,rightHalf,bottomLeft,bottomHalf,off"
    #expect(WindowLayoutSnap.valid(entries))
    #expect(WindowLayoutSnap.actions(entries).last! == nil)
    #expect(!WindowLayoutSnap.valid("future"))
    #expect(!WindowLayoutSnap.canSnap(.tileAll))
    #expect(!WindowLayoutSnap.canSnap(.restore))
    #expect(WindowLayoutSnap.canSnap(.bottomRightSixteenth))
  }

  /// 配置导入与同步拒绝越界、非有限数、未知动作和损坏的鼠标映射。
  @Test func configurationValidation() throws {
    let gapKind = try #require(SettingsArchive.kinds[Prefs.layoutGap])
    #expect(gapKind.plist(.double(12)) as? Double == 12)
    #expect(gapKind.plist(.double(-1)) == nil)
    #expect(gapKind.plist(.double(.infinity)) == nil)
    #expect(gapKind.plist(.double(101)) == nil)
    #expect(SettingsArchive.kinds[Prefs.layoutRepeat]?.plist(.string("future")) == nil)
    #expect(SettingsArchive.kinds[Prefs.layoutNewWindowAction]?.plist(.string("tileAll")) == nil)
    #expect(WindowLayoutMouseBinding.decode("[]") == [])
    let entries = [WindowLayoutMouseBinding(button: 3, action: .leftHalf)]
    let text = try #require(WindowLayoutMouseBinding.encode(entries))
    #expect(WindowLayoutMouseBinding.decode(text) == entries)
    #expect(WindowLayoutMouseBinding.decode("[{\"button\":1,\"action\":\"leftHalf\"}]") == nil)
    #expect(WindowLayoutMouseBinding.decode("[{\"button\":3,\"action\":\"future\"}]") == nil)
    #expect(
      WindowLayoutMouseBinding.decode(
        "[{\"button\":3,\"action\":\"leftHalf\"},{\"button\":3,\"action\":\"rightHalf\"}]") == nil)
  }

  /// 窗口管理停用名单只释放本功能的按键，原有全局停用规则继续生效。
  @Test func ignoredAppsAndLocalFeature() throws {
    let rule = try #require(HotKeyBlock.rule(for: "test.app", in: [], layoutIgnored: ["test.app"]))
    #expect(rule.blocks(.windowLayout(.leftHalf)))
    #expect(rule.blocks(.windowLayoutPicker))
    #expect(!rule.blocks(.clipboard))
    #expect(
      HotKeyBlock.rule(for: "test.app", in: ["test.app"], layoutIgnored: ["test.app"]) == .all)
    #expect(Feature.windowLayout.defaultOn == false)
    #expect(SettingsSync.localKeys.contains(Feature.windowLayout.prefsKey))
    #expect(OnboardingView.permissions(for: [.windowLayout]) == [.accessibility])
  }

  /// 搜索与键盘选择只调注入动作，不读取、移动或激活真实窗口。
  @Test func pickerSearchAndKeyboard() {
    let model = WindowLayoutPickerModel()
    var performed: WindowLayoutAction?
    model.perform = { performed = $0 }
    model.query = "十六分之一"
    #expect(model.results.count == 16)
    model.selected = model.results.first
    #expect(model.command(NSSelectorFromString("moveDown:")))
    #expect(model.selected == model.results[1])
    #expect(model.command(NSSelectorFromString("insertNewline:")))
    #expect(performed == model.results[1])
    model.query = "没有这种布局"
    #expect(model.results.isEmpty)
    #expect(!model.command(NSSelectorFromString("insertNewline:")))
  }

  /// 受控写入失败在同一操作内回退并保留首次错误，日志进入真实统一日志通道。
  @Test func writeFailureRollsBackAndPreservesCause() async throws {
    let layout = WindowLayout()
    let target = DockWindows.LayoutWindow(
      id: 12345, pid: ProcessInfo.processInfo.processIdentifier,
      element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      frame: window)
    var actual = window
    var writes: [CGRect] = []
    let cause = NSError(
      domain: "KittyTools.LayoutProbe", code: -25202,
      userInfo: [NSLocalizedDescriptionKey: "layout-probe-controlled-write-failure"])
    do {
      _ = try await layout.apply(
        screen, window: target, action: .maximize, readFrame: { _ in actual },
        writeFrame: { frame, _ in
          writes.append(frame)
          actual = frame
          if writes.count == 1 { throw cause }
        })
      Issue.record("失败写入被误报为成功")
    } catch {
      let error = error as NSError
      #expect(error.domain == cause.domain && error.code == cause.code)
      #expect(error.localizedDescription == cause.localizedDescription)
    }
    #expect(writes == [screen, window])
    #expect(actual == window)
  }

  /// 写入后的读取失败也回退，恢复失败的提示同时保留最初原因。
  @Test func verificationAndRollbackFailuresRemainDistinct() async {
    let layout = WindowLayout()
    let target = DockWindows.LayoutWindow(
      id: 12346, pid: ProcessInfo.processInfo.processIdentifier,
      element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      frame: window)
    var reads = 0
    var writes = 0
    let cause = NSError(
      domain: "KittyTools.LayoutProbe", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "layout-probe-controlled-read-back-failure"])
    let recovery = NSError(
      domain: "KittyTools.LayoutProbe", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "layout-probe-controlled-rollback-failure"])
    do {
      _ = try await layout.apply(
        screen, window: target, action: .maximize,
        readFrame: { _ in
          reads += 1
          if reads > 1 { throw cause }
          return window
        },
        writeFrame: { _, _ in
          writes += 1
          if writes > 1 { throw recovery }
        })
      Issue.record("回读失败被误报为成功")
    } catch {
      #expect(error.localizedDescription.contains(cause.localizedDescription))
      #expect(error.localizedDescription.contains(recovery.localizedDescription))
      #expect(error.localizedDescription.contains("未确认"))
    }
    #expect(reads == 2 && writes == 2)
  }

  /// 初始读取失败不写入，实际采用不同区域时通过说明回调表达偏差。
  @Test func initialReadAndAdjustedResult() async throws {
    let layout = WindowLayout()
    let target = DockWindows.LayoutWindow(
      id: 12347, pid: ProcessInfo.processInfo.processIdentifier,
      element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      frame: window)
    var writes = 0
    do {
      _ = try await layout.apply(
        screen, window: target, action: .maximize,
        readFrame: { _ in
          throw NSError(
            domain: "KittyTools.LayoutProbe", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "layout-probe-controlled-initial-read-failure"])
        }, writeFrame: { _, _ in writes += 1 })
      Issue.record("初始读取失败被误报为成功")
    } catch { #expect((error as NSError).code == 3) }
    #expect(writes == 0)
    var messages: [String] = []
    layout.onInfo = { messages.append($0) }
    let adjusted = try await layout.apply(
      screen, window: target, action: .maximize,
      readFrame: { _ in window }, writeFrame: { _, _ in writes += 1 })
    #expect(adjusted && writes == 1)
    #expect(messages.count == 1 && messages[0].contains("不同"))
  }

  /// 共享组合仅允许窗口布局，旧动作默认让出组合的规则保持原行为。
  @Test func sharedLayoutShortcutsAndArchive() throws {
    let first = HotKeyAction.windowLayout(.leftHalf)
    let second = HotKeyAction.windowLayout(.rightHalf)
    let key = try #require(first.defaultHotKey)
    #expect(first.sharesLayoutKey(with: second, hotKey: key))
    #expect(!first.sharesLayoutKey(with: .clipboard, hotKey: key))
    #expect(!first.sharesLayoutKey(with: second, hotKey: HotKey(doubleTap: .option)))
    let stored = HotKeyAction.stored(key)
    #expect(first.resolve { $0 == second ? stored : nil } == key)
    #expect(
      HotKeyAction.clipboard.resolve {
        $0 == second ? HotKeyAction.stored(HotKeyAction.clipboard.defaultHotKey) : nil
      } == nil)
    let json = """
      {"app":"Kitty Tools","format":2,"version":"1","exportedAt":"2026-11-12T00:00:00Z",
       "hotkeys":{"windowLayout.leftHalf":{"keyCode":123,"modifiers":6144},
                  "windowLayout.rightHalf":{"keyCode":123,"modifiers":6144}}}
      """
    let archive = try SettingsArchive.read(Data(json.utf8))
    #expect(archive.hotkeys?[first.rawValue] != nil)
    #expect(archive.hotkeys?[second.rawValue] != nil)
  }

  /// 固定大小窗口保留尺寸，缩小和折半遵守用户指定的最小屏幕比例。
  @Test func fixedWindowsAndMinimumSize() throws {
    let desired = CGRect(
      x: screen.minX, y: screen.minY, width: screen.width / 2, height: screen.height)
    let fixed = WindowLayoutGeometry.positionedFixed(window, desired: desired, in: screen)
    #expect(fixed.size == window.size && fixed.minX == screen.minX)
    let small = CGRect(x: -1500, y: 100, width: 500, height: 300)
    #expect(WindowLayoutGeometry.frame(for: .halveWidthLeft, current: small, in: screen) == small)
    var options = WindowLayoutOptions()
    options.minimumWidth = 0
    options.minimumHeight = 0
    let halved = try #require(
      WindowLayoutGeometry.frame(for: .halveWidthLeft, current: small, in: screen, options: options)
    )
    #expect(halved.width == 250 && halved.minX == small.minX)
  }

  /// 文本框中的无效尺寸必须明确拒绝，不能当作默认尺寸执行。
  @Test func invalidCustomSizeIsRejected() throws {
    let name = "kitty-window-layout-options-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.register(defaults: [Prefs.layoutWidth: 1680.0, Prefs.layoutHeight: 1050.0])
    #expect(WindowLayoutOptions.customSizeProblem(defaults) == nil)
    for value in [0.0, -1, 20001, Double.infinity, Double.nan] {
      defaults.set(value, forKey: Prefs.layoutWidth)
      #expect(WindowLayoutOptions.customSizeProblem(defaults)?.contains("宽度") == true)
    }
    defaults.set(0.75, forKey: Prefs.layoutWidth)
    defaults.set(0.5, forKey: Prefs.layoutHeight)
    #expect(WindowLayoutOptions.customSizeProblem(defaults) == nil)
    defaults.set("invalid", forKey: Prefs.layoutHeight)
    #expect(WindowLayoutOptions.customSizeProblem(defaults)?.contains("高度") == true)
  }

  /// 重复动作区分相邻屏、回绕、边界缩放、对侧和网格方向，复用本机原有模式。
  @Test func repeatModesAndPortraitCycles() {
    let screens = [
      CGRect(x: -1600, y: 0, width: 1600, height: 1000),
      CGRect(x: 0, y: 0, width: 1600, height: 1000),
    ]
    let across = WindowLayoutRepeat.across.target(
      for: .leftHalf, count: 1, screen: 1, screens: screens, portrait: false)
    #expect(across.screen == 0 && across.action == .rightHalf && across.recorded == .rightHalf)
    let boundary = WindowLayoutRepeat.acrossAndResize.target(
      for: .leftHalf, count: 1, screen: 0, screens: screens, portrait: false)
    #expect(boundary.screen == 0 && boundary.action == .firstTwoThirds)
    let top = WindowLayoutRepeat.across.target(
      for: .topHalf, count: 1, screen: 1, screens: screens, portrait: false)
    #expect(top.screen == 1 && top.action == .topHalf)
    let vertical = [CGRect(x: 0, y: -1000, width: 1600, height: 1000), screens[1]]
    let above = WindowLayoutRepeat.across.target(
      for: .topHalf, count: 1, screen: 1, screens: vertical, portrait: false)
    #expect(above.screen == 0 && above.action == .bottomHalf)
    let opposite = WindowLayoutRepeat.opposite.target(
      for: .leftHalf, count: 1, screen: 1, screens: screens, portrait: false)
    #expect(opposite.screen == 1 && opposite.action == .rightHalf)
    #expect(WindowLayout.repeated(.topLeftSixth, count: 1) == .topCenterSixth)
    #expect(WindowLayout.repeated(.topLeftSixth, count: 1, portrait: true) == .topRightSixth)
    #expect(WindowLayout.repeated(.topRightSixth, count: 1, portrait: true) == .topLeftSixth)
    #expect(WindowLayout.repeated(.firstVerticalEighth, count: 1) == .secondVerticalEighth)
    #expect(Prefs.defaults[Prefs.layoutRepeat] as? String == WindowLayoutRepeat.across.rawValue)
  }

  /// 竖屏名称随执行区域改变，搜索到的行和缩略图使用同一方向。
  @Test func portraitLabelsDescribeActualRegions() {
    #expect(WindowLayoutAction.firstThird.title(portrait: true) == "上部三分之一")
    #expect(WindowLayoutAction.topCenterSixth.title(portrait: true) == "中排左侧六分之一")
    #expect(WindowLayoutAction.topRightEighth.title(portrait: true) == "第二排右侧八分之一")
    #expect(WindowLayoutAction.firstVerticalEighth.title(portrait: true).contains("行"))
    let model = WindowLayoutPickerModel()
    model.portrait = true
    model.query = "中排左侧六分之一"
    #expect(model.results == [.topCenterSixth])
  }
  /// 使用本地参考源码 875182d 的纯计算结果，逐一核对横屏与竖屏分区。
  @Test func regionsMatchIndependentReference() throws {
    for (action, landscape, portrait) in Self.referenceRegions {
      let actualLandscape = try #require(action.unitRect(portrait: false))
      let actualPortrait = try #require(action.unitRect(portrait: true))
      for (actual, expected) in [(actualLandscape, landscape), (actualPortrait, portrait)] {
        #expect(abs(actual.minX - expected.minX) < 0.000001, "\(action)")
        #expect(abs(actual.minY - expected.minY) < 0.000001, "\(action)")
        #expect(abs(actual.width - expected.width) < 0.000001, "\(action)")
        #expect(abs(actual.height - expected.height) < 0.000001, "\(action)")
      }
    }
  }

  // 两个上角三分之一的参考竖屏原计算越过屏幕顶部，期望值收回可用区域，避免复制该越界行为。
  private static let referenceRegions: [(WindowLayoutAction, CGRect, CGRect)] = [
    (
      .bottomCenterLeftEighth, CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.5),
      CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.25)
    ),
    (
      .bottomCenterLeftSixteenth, CGRect(x: 0.25, y: 0.75, width: 0.25, height: 0.25),
      CGRect(x: 0.25, y: 0.75, width: 0.25, height: 0.25)
    ),
    (
      .bottomCenterLeftTwelfth,
      CGRect(x: 0.25, y: 0.666666666666667, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0, y: 0.75, width: 0.333333333333333, height: 0.25)
    ),
    (
      .bottomCenterNinth,
      CGRect(
        x: 0.333333333333333, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333),
      CGRect(
        x: 0.333333333333333, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333)
    ),
    (
      .bottomCenterRightEighth, CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5),
      CGRect(x: 0, y: 0.75, width: 0.5, height: 0.25)
    ),
    (
      .bottomCenterRightSixteenth, CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25),
      CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25)
    ),
    (
      .bottomCenterRightTwelfth,
      CGRect(x: 0.5, y: 0.666666666666667, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.333333333333333, y: 0.75, width: 0.333333333333333, height: 0.25)
    ),
    (
      .bottomCenterSixth,
      CGRect(x: 0.333333333333333, y: 0.5, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0.5, y: 0.333333333333333, width: 0.5, height: 0.333333333333333)
    ),
    (
      .bottomLeftEighth, CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5),
      CGRect(x: 0, y: 0.5, width: 0.5, height: 0.25)
    ),
    (
      .bottomLeftNinth,
      CGRect(x: 0, y: 0.666666666666667, width: 0.333333333333333, height: 0.333333333333333),
      CGRect(x: 0, y: 0.666666666666667, width: 0.333333333333333, height: 0.333333333333333)
    ),
    (
      .bottomLeftSixteenth, CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25),
      CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25)
    ),
    (
      .bottomLeftSixth, CGRect(x: 0, y: 0.5, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0, y: 0.666666666666667, width: 0.5, height: 0.333333333333333)
    ),
    (
      .bottomLeftThird, CGRect(x: 0, y: 0.5, width: 0.666666666666667, height: 0.5),
      CGRect(x: 0, y: 0.333333333333333, width: 0.5, height: 0.666666666666667)
    ),
    (
      .bottomLeftTwelfth,
      CGRect(x: 0, y: 0.666666666666667, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.666666666666667, y: 0.5, width: 0.333333333333333, height: 0.25)
    ),
    (
      .bottomRightEighth, CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5),
      CGRect(x: 0.5, y: 0.75, width: 0.5, height: 0.25)
    ),
    (
      .bottomRightNinth,
      CGRect(
        x: 0.666666666666667, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333),
      CGRect(
        x: 0.666666666666667, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333)
    ),
    (
      .bottomRightSixteenth, CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25),
      CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25)
    ),
    (
      .bottomRightSixth,
      CGRect(x: 0.666666666666667, y: 0.5, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0.5, y: 0.666666666666667, width: 0.5, height: 0.333333333333333)
    ),
    (
      .bottomRightThird,
      CGRect(x: 0.333333333333333, y: 0.5, width: 0.666666666666667, height: 0.5),
      CGRect(x: 0.5, y: 0.333333333333333, width: 0.5, height: 0.666666666666667)
    ),
    (
      .bottomRightTwelfth,
      CGRect(x: 0.75, y: 0.666666666666667, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.666666666666667, y: 0.75, width: 0.333333333333333, height: 0.25)
    ),
    (
      .centerThird, CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 1),
      CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.333333333333333)
    ),
    (
      .centerThreeFourths, CGRect(x: 0.125, y: 0, width: 0.75, height: 1),
      CGRect(x: 0, y: 0.125, width: 1, height: 0.75)
    ),
    (
      .centerTwoThirds, CGRect(x: 0.166666666666667, y: 0, width: 0.666666666666667, height: 1),
      CGRect(x: 0, y: 0.166666666666667, width: 1, height: 0.666666666666667)
    ),
    (
      .fifthVerticalEighth, CGRect(x: 0.5, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.5, width: 1, height: 0.125)
    ),
    (
      .fifthVerticalSixth, CGRect(x: 0.666666666666667, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0.666666666666667, width: 1, height: 0.166666666666667)
    ),
    (
      .firstFourth, CGRect(x: 0, y: 0, width: 0.25, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.25)
    ),
    (
      .firstThird, CGRect(x: 0, y: 0, width: 0.333333333333333, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.333333333333333)
    ),
    (
      .firstThreeFourths, CGRect(x: 0, y: 0, width: 0.75, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.75)
    ),
    (
      .firstTwoThirds, CGRect(x: 0, y: 0, width: 0.666666666666667, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.666666666666667)
    ),
    (
      .firstVerticalEighth, CGRect(x: 0, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.125)
    ),
    (
      .firstVerticalSixth, CGRect(x: 0, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0, width: 1, height: 0.166666666666667)
    ),
    (
      .fourthVerticalEighth, CGRect(x: 0.375, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.375, width: 1, height: 0.125)
    ),
    (
      .fourthVerticalSixth, CGRect(x: 0.5, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0.5, width: 1, height: 0.166666666666667)
    ),
    (
      .lastFourth, CGRect(x: 0.75, y: 0, width: 0.25, height: 1),
      CGRect(x: 0, y: 0.75, width: 1, height: 0.25)
    ),
    (
      .lastThird, CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 1),
      CGRect(x: 0, y: 0.666666666666667, width: 1, height: 0.333333333333333)
    ),
    (
      .lastThreeFourths, CGRect(x: 0.25, y: 0, width: 0.75, height: 1),
      CGRect(x: 0, y: 0.25, width: 1, height: 0.75)
    ),
    (
      .lastTwoThirds, CGRect(x: 0.333333333333333, y: 0, width: 0.666666666666667, height: 1),
      CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.666666666666667)
    ),
    (
      .lastVerticalEighth, CGRect(x: 0.875, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.875, width: 1, height: 0.125)
    ),
    (
      .lastVerticalSixth, CGRect(x: 0.833333333333333, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0.833333333333333, width: 1, height: 0.166666666666667)
    ),
    (
      .lowerMiddleCenterLeftSixteenth, CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
      CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)
    ),
    (
      .lowerMiddleCenterRightSixteenth, CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
      CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
    ),
    (
      .lowerMiddleLeftSixteenth, CGRect(x: 0, y: 0.5, width: 0.25, height: 0.25),
      CGRect(x: 0, y: 0.5, width: 0.25, height: 0.25)
    ),
    (
      .lowerMiddleRightSixteenth, CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.25),
      CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.25)
    ),
    (
      .middleCenterLeftTwelfth,
      CGRect(x: 0.25, y: 0.333333333333333, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.666666666666667, y: 0.25, width: 0.333333333333333, height: 0.25)
    ),
    (
      .middleCenterNinth,
      CGRect(
        x: 0.333333333333333, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333),
      CGRect(
        x: 0.333333333333333, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333)
    ),
    (
      .middleCenterRightTwelfth,
      CGRect(x: 0.5, y: 0.333333333333333, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0, y: 0.5, width: 0.333333333333333, height: 0.25)
    ),
    (
      .middleLeftNinth,
      CGRect(x: 0, y: 0.333333333333333, width: 0.333333333333333, height: 0.333333333333333),
      CGRect(x: 0, y: 0.333333333333333, width: 0.333333333333333, height: 0.333333333333333)
    ),
    (
      .middleLeftTwelfth,
      CGRect(x: 0, y: 0.333333333333333, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.333333333333333, y: 0.25, width: 0.333333333333333, height: 0.25)
    ),
    (
      .middleRightNinth,
      CGRect(
        x: 0.666666666666667, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333),
      CGRect(
        x: 0.666666666666667, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333)
    ),
    (
      .middleRightTwelfth,
      CGRect(x: 0.75, y: 0.333333333333333, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.333333333333333, y: 0.5, width: 0.333333333333333, height: 0.25)
    ),
    (
      .secondFourth, CGRect(x: 0.25, y: 0, width: 0.25, height: 1),
      CGRect(x: 0, y: 0.25, width: 1, height: 0.25)
    ),
    (
      .secondVerticalEighth, CGRect(x: 0.125, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.125, width: 1, height: 0.125)
    ),
    (
      .secondVerticalSixth, CGRect(x: 0.166666666666667, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0.166666666666667, width: 1, height: 0.166666666666667)
    ),
    (
      .seventhVerticalEighth, CGRect(x: 0.75, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.75, width: 1, height: 0.125)
    ),
    (
      .sixthVerticalEighth, CGRect(x: 0.625, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.625, width: 1, height: 0.125)
    ),
    (
      .thirdFourth, CGRect(x: 0.5, y: 0, width: 0.25, height: 1),
      CGRect(x: 0, y: 0.5, width: 1, height: 0.25)
    ),
    (
      .thirdVerticalEighth, CGRect(x: 0.25, y: 0, width: 0.125, height: 1),
      CGRect(x: 0, y: 0.25, width: 1, height: 0.125)
    ),
    (
      .thirdVerticalSixth, CGRect(x: 0.333333333333333, y: 0, width: 0.166666666666667, height: 1),
      CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.166666666666667)
    ),
    (
      .topCenterLeftEighth, CGRect(x: 0.25, y: 0, width: 0.25, height: 0.5),
      CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25)
    ),
    (
      .topCenterLeftSixteenth, CGRect(x: 0.25, y: 0, width: 0.25, height: 0.25),
      CGRect(x: 0.25, y: 0, width: 0.25, height: 0.25)
    ),
    (
      .topCenterLeftTwelfth, CGRect(x: 0.25, y: 0, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.25)
    ),
    (
      .topCenterNinth,
      CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.333333333333333),
      CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    ),
    (
      .topCenterRightEighth, CGRect(x: 0.5, y: 0, width: 0.25, height: 0.5),
      CGRect(x: 0, y: 0.25, width: 0.5, height: 0.25)
    ),
    (
      .topCenterRightSixteenth, CGRect(x: 0.5, y: 0, width: 0.25, height: 0.25),
      CGRect(x: 0.5, y: 0, width: 0.25, height: 0.25)
    ),
    (
      .topCenterRightTwelfth, CGRect(x: 0.5, y: 0, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.25)
    ),
    (
      .topCenterSixth, CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0, y: 0.333333333333333, width: 0.5, height: 0.333333333333333)
    ),
    (
      .topLeftEighth, CGRect(x: 0, y: 0, width: 0.25, height: 0.5),
      CGRect(x: 0, y: 0, width: 0.5, height: 0.25)
    ),
    (
      .topLeftNinth, CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.333333333333333),
      CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    ),
    (
      .topLeftSixteenth, CGRect(x: 0, y: 0, width: 0.25, height: 0.25),
      CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
    ),
    (
      .topLeftSixth, CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0, y: 0, width: 0.5, height: 0.333333333333333)
    ),
    (
      .topLeftThird, CGRect(x: 0, y: 0, width: 0.666666666666667, height: 0.5),
      CGRect(x: 0, y: 0, width: 0.5, height: 0.666666666666667)
    ),
    (
      .topLeftTwelfth, CGRect(x: 0, y: 0, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.25)
    ),
    (
      .topRightEighth, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5),
      CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.25)
    ),
    (
      .topRightNinth,
      CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.333333333333333),
      CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    ),
    (
      .topRightSixteenth, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25),
      CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25)
    ),
    (
      .topRightSixth, CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.5),
      CGRect(x: 0.5, y: 0, width: 0.5, height: 0.333333333333333)
    ),
    (
      .topRightThird, CGRect(x: 0.333333333333333, y: 0, width: 0.666666666666667, height: 0.5),
      CGRect(x: 0.5, y: 0, width: 0.5, height: 0.666666666666667)
    ),
    (
      .topRightTwelfth, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.333333333333333),
      CGRect(x: 0, y: 0.25, width: 0.333333333333333, height: 0.25)
    ),
    (
      .upperMiddleCenterLeftSixteenth, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25),
      CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
    ),
    (
      .upperMiddleCenterRightSixteenth, CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25),
      CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
    ),
    (
      .upperMiddleLeftSixteenth, CGRect(x: 0, y: 0.25, width: 0.25, height: 0.25),
      CGRect(x: 0, y: 0.25, width: 0.25, height: 0.25)
    ),
    (
      .upperMiddleRightSixteenth, CGRect(x: 0.75, y: 0.25, width: 0.25, height: 0.25),
      CGRect(x: 0.75, y: 0.25, width: 0.25, height: 0.25)
    ),
  ]

}
