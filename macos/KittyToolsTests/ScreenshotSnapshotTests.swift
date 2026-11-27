import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import VisionKit

@testable import KittyTools

// 截图重设计（Whisker §6 截图，2026-09-26）的屏外截图自检（按需启用，同 SnapshotProbeTests）：遮罩待选 / 框选 / 调整、
// 工具栏上下、按工具的样式托盘、10 种标注与选中手柄、弯箭头和弯直线（选中 / 拖弯曲手柄 / 各种颜色粗细 / 弯到头）、尺寸输入、文字输入（三种样式）、比例和保存菜单、右键提示、截图翻译框选、常驻缩略图
// （飞行卡片落地后交接的同一张卡）、长截图面板与边框，按 2x 写成 PNG（带 -crop 的是局部，看线和图标对不对齐）。
// 录屏框选（待选提示、调整阶段的录制条、截图里按 R 切过去的录制条）和录制 HUD（倒数、录制中、放弃上膛）也在这里；
// 第 3 批补了常驻缩略图的视频卡（落地、悬停、矮卡、没有最后一帧的占位）；第 4 批补了录制条的三个开关（默认 = 混合、全开、
// 全关，全开 / 全关再按石墨、黄色强调色各一遍）和录制 HUD 的声音状态（两个都开、只开系统声音、麦克风断开变橙）；录音第 5 批补了
// 录音 HUD（录制中带电平、暂停、没听到声音、响到橙色的一根）和录音卡（波形 + 左上 waveform 标记 + 时长：落地、悬停、矮卡）；
// 录音第 6 批补了录系统声音的录音 HUD（⏸ 原位置灰、「两者」麦克风断开的橙字）。第 7 批：视频卡悬停多一枚「转成 GIF」胶囊，
// 补了 GIF 卡（落地、悬停）。手测反馈第 1 批：录屏的点按圈（InputOverlay：左键圆盘 / 右键空心环，各放在浅色、深色、
// 和强调色一样的底上，再按石墨、黄色强调色各一遍；另一张压在假桌面上）。手测反馈第 2 批：录制条第四个开关「显示按键」
// （原来带录制条的图都宽了一格）和按键胶囊（整屏：短的 ⌘C、带 ×n 的，下面是录制 HUD；选区：一长串溢出从左边丢、小选区、字缩小的窄选区）。手测反馈第 3 批：录音控制条的
// 待录态（[系统声音][麦克风] ｜ [✕][●]：只开麦克风、两者、只开系统声音、按了开始还没录起来的置灰）。
// 状态用 SelectionInteractionTests 的屏外窗口 + 合成事件摆（不弹遮罩、不抢键盘）；图层要在窗口里显示过才有内容，
// 所以把屏外 (-20000, -20000) 的无边框窗口（当不了 key）orderFront 一下再 layer.render(in:)。材质在屏外会发灰，只锁布局。
//   TEST_RUNNER_KITTY_SNAPSHOT_DIR=/tmp/shots xcodebuild -project macos/KittyTools.xcodeproj \
//     -scheme KittyTools test -only-testing:KittyToolsTests/ScreenshotSnapshotTests
@MainActor @Suite(.serialized)
struct ScreenshotSnapshotTests {
  typealias Harness = SelectionInteractionTests.Harness
  nonisolated private static let directory =
    ProcessInfo.processInfo.environment["KITTY_SNAPSHOT_DIR"]

  /// 假桌面上的两个窗口（视图坐标，从前到后）：前面是备忘录（文字），后面是表格（色块）
  static let windows = [
    CGRect(x: 140, y: 380, width: 460, height: 300),
    CGRect(x: 520, y: 120, width: 560, height: 420),
  ]

  @Test(.enabled(if: directory != nil)) func renderOverlay() throws {
    let desktop = try Self.desktop()
    let capture = { Harness(windows: Self.windows, image: desktop) }
    let top = CGRect(x: 0, y: 560, width: 1200, height: 240)

    // 待选：悬停窗口（洞 + 粉框 + 窗口像素尺寸）+ 放大镜 + 顶部提示；桌面上（整屏轻暗）；按住 ⌘ 的十字准线
    var h = capture()
    h.move(CGPoint(x: 330, y: 520))
    try shoot(h.window, "idle-window", crop: CGRect(x: 100, y: 340, width: 620, height: 460))
    // 取色格式切换只换文字，提示始终可见，HEX / RGB 的信息卡和放大镜保持同一尺寸和位置。
    h.modifiers(.shift)
    h.modifiers([])
    try shoot(h.window, "idle-window-rgb", crop: CGRect(x: 100, y: 300, width: 620, height: 500))
    h.modifiers(.shift)
    h.modifiers([])
    try shoot(
      h.window, "idle-window-hex-restored", crop: CGRect(x: 100, y: 300, width: 620, height: 500))
    h.modifiers(.shift)
    h.modifiers([])
    h.move(CGPoint(x: 1190, y: 10))
    try shoot(h.window, "idle-edge-rgb", crop: CGRect(x: 900, y: 0, width: 300, height: 260))
    h = Harness(mode: .record, image: desktop)
    h.move(CGPoint(x: 330, y: 520))
    h.modifiers(.shift)
    h.modifiers([])
    try shoot(h.window, "record-idle-rgb", crop: CGRect(x: 250, y: 280, width: 400, height: 300))
    try snapshot(
      ShortcutsSheet(page: .screenshot), over: desktop,
      size: NSSize(width: ShortcutsSheet.width, height: 1200), dark: false,
      to: "\(try #require(Self.directory))/shot-shortcuts-color-format.png")
    // 认窗口里的元素（2026-11-08）：悬停停在指针下最小的那层（备忘录的第三行），滚轮往上大一层（正文区），尺寸胶囊跟着换
    let element = {
      let h = Harness(
        windows: Self.windows, owners: [[4242], [4243]], findsElements: true, image: desktop)
      _ = h.fakeElements([
        CGRect(x: 150, y: 536, width: 420, height: 32),
        CGRect(x: 140, y: 380, width: 460, height: 272), Self.windows[0],
      ])
      h.move(CGPoint(x: 330, y: 552))
      return h
    }
    try shoot(
      element().window, "idle-element", crop: CGRect(x: 100, y: 340, width: 620, height: 460))
    h = element()
    h.scroll(up: true)
    try shoot(
      h.window, "idle-element-parent", crop: CGRect(x: 100, y: 340, width: 620, height: 460))
    h = element()
    try shoot(h.window, "idle-element-hint", crop: top)
    h = capture()
    h.move(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "idle-desktop", crop: top)
    // 设置 › 截图「框选时保持屏幕原色」（2026-11-06）：不压暗、悬停的窗口只描边、放大镜的十字带只描边；框好之后洞外也不压
    h = Harness(windows: Self.windows, image: desktop, keepsColors: true)
    h.move(CGPoint(x: 330, y: 520))
    try shoot(
      h.window, "idle-window-original-colors", crop: CGRect(x: 100, y: 340, width: 620, height: 460)
    )
    h = Harness(windows: Self.windows, image: desktop, keepsColors: true)
    h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
    try shoot(
      h.window, "adjust-original-colors", crop: CGRect(x: 40, y: 190, width: 1010, height: 420))
    h = capture()
    h.move(CGPoint(x: 300.4, y: 300.6))
    h.modifiers(.command)
    try shoot(h.window, "idle-crosshair", crop: CGRect(x: 200, y: 100, width: 300, height: 300))

    // 框选中：⇧ 正方形，右边吸到后面窗口的左边（整屏粉色虚线参考线），放大镜、尺寸胶囊
    h = capture()
    h.begin(CGPoint(x: 200, y: 150), to: CGPoint(x: 517, y: 260), flags: .shift)
    try shoot(h.window, "draw-shift-snap", crop: CGRect(x: 150, y: 80, width: 600, height: 480))

    // 调整：手柄、悬停右边（加粗 + 手柄放大）、下方工具栏（默认靠右：右边线对齐选区右边线，栏比选区宽、往左伸出去）、
    // 左上尺寸胶囊（可点、比例按钮），深浅色
    let adjust = {
      let h = capture()
      // 鼠标给的是小数点（触控板）：边框、手柄要落在整像素上
      h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
      h.move(CGPoint(x: 801, y: 420))
      return h
    }
    for dark in [false, true] {
      try shoot(
        adjust().window, "adjust", dark: dark, crop: CGRect(x: 40, y: 190, width: 1010, height: 420)
      )
    }
    // 设置 › 截图「工具栏位置」选居中（0.7.1 及之前的样子）
    h = capture()
    h.view.styleDefaults.set("center", forKey: Prefs.screenshotToolbarAlign)
    h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
    h.move(CGPoint(x: 801, y: 420))
    try shoot(h.window, "adjust-center", crop: CGRect(x: 40, y: 190, width: 1010, height: 420))
    // 工具栏放不下选区下方 → 上方（托盘在栏上方）；整屏选区 → 栏放进选区底部、尺寸胶囊放进左上角
    h = capture()
    h.drag(CGPoint(x: 250, y: 30), CGPoint(x: 850, y: 330))
    h.view.tool = .arrow
    try shoot(h.window, "toolbar-above", crop: CGRect(x: 90, y: 0, width: 960, height: 460))
    h = capture()
    h.view.select(CGRect(x: 0, y: 0, width: 1200, height: 800))
    try shoot(h.window, "toolbar-inside")

    // 样式托盘：矩形（色点 + 三档 + 空心 / 实心）、文字（三个选项）、马赛克（没有色点）、聚光灯（浅 / 中 / 深）
    let trays: [(String, Annotation.Tool, Annotation.Style)] = [
      ("tray-rectangle", .rectangle, .init(color: .pink, weight: .medium, option: 1)),
      ("tray-text", .text, .init(color: .red, weight: .large, option: 2)),
      ("tray-mosaic", .mosaic, .init(weight: .small, option: 1)),
      ("tray-spotlight", .spotlight, .init(weight: .large)),
      // 吸管取过色：预设色后面多一个取的颜色（亮着），最后是吸管
      ("tray-custom", .rectangle, .init(color: .pink, custom: 0x7A5CFA)),
      ("tray-arrow", .arrow, .init(color: .blue, option: 1)),
    ]
    for (name, tool, style) in trays {
      let h = adjust()
      h.move(CGPoint(x: 550, y: 400))
      h.view.style = style
      h.view.tool = tool
      try shoot(h.window, name, crop: barsFrame(h))
      try shootContent(
        try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first), name)
    }

    // 10 种标注（有 / 没有聚光灯各一张）
    let selection = CGRect(x: 120, y: 150, width: 960, height: 580)
    for (name, spotlight) in [("annotations", true), ("annotations-nospot", false)] {
      let h = capture()
      h.view.select(selection)
      h.view.annotations = Self.allAnnotations(spotlight: spotlight)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, name)
    }
    // 选中的矩形（虚线框 + 四角和边中点手柄）、选中的箭头（两端手柄，托盘显示它的颜色）
    for (name, shape, style) in [
      (
        "selected-rectangle",
        Annotation.Shape.rectangle(CGRect(x: 360, y: 330, width: 220, height: 120)),
        Annotation.Style(color: .pink)
      ),
      (
        "selected-arrow", .arrow(from: CGPoint(x: 700, y: 330), to: CGPoint(x: 480, y: 470)),
        .init(color: .blue, weight: .large)
      ),
    ] {
      let h = adjust()
      let annotation = Annotation(shape: shape, style: style)
      h.view.annotations = [annotation]
      h.view.tool = annotation.tool
      h.view.selectedAnnotation = annotation.id
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, name, crop: CGRect(x: 40, y: 150, width: 1010, height: 460))
    }
    // 弯箭头、弯直线各一套（同样的摆法）
    for (tool, noun) in [(Annotation.Tool.arrow, "arrow"), (.line, "line")] {
      // 选中的：两端手柄 + 弧线中点小一号的弯曲手柄；拖着弯曲手柄（跟手、放大镜不出）
      let curved = Annotation(
        shape: .bendable(
          tool, from: CGPoint(x: 400, y: 330), to: CGPoint(x: 720, y: 380),
          bend: CGVector(dx: 0, dy: 0.3)), style: .init(color: .pink))
      for (name, dragging) in [("selected-curved-\(noun)", false), ("bending-\(noun)", true)] {
        let h = adjust()
        h.view.annotations = [curved]
        h.view.tool = tool
        h.view.selectedAnnotation = curved.id
        if dragging {
          let handle = try #require(curved.handles.first { $0.0 == .bend }?.1)
          h.begin(handle, to: CGPoint(x: 600, y: 280))
        } else {
          h.move(CGPoint(x: 1150, y: 760))
        }
        try shoot(h.window, name, crop: CGRect(x: 360, y: 250, width: 400, height: 220))
      }
      // 各种颜色、粗细：往两边弯、偏向一端、弯成 U 形，各配一条同样式的直的对照
      h = capture()
      h.view.select(selection)
      h.view.annotations = Self.curved(tool)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, "curved-\(noun)s", crop: CGRect(x: 120, y: 150, width: 480, height: 300))
      if tool == .arrow {
        // 双头（拍板 O4）：同一组摆法全换成双头
        h = capture()
        h.view.select(selection)
        h.view.annotations = Self.curved(tool).map {
          var double = $0
          double.style.option = 1
          return double
        }
        h.move(CGPoint(x: 1150, y: 760))
        try shoot(h.window, "double-arrows", crop: CGRect(x: 120, y: 150, width: 480, height: 300))
        h = capture()
        h.view.select(selection)
        h.view.annotations = Self.extreme(tool).map {
          var double = $0
          double.style.option = 1
          return double
        }
        h.move(CGPoint(x: 1150, y: 760))
        try shoot(h.window, "double-arrows-extreme", crop: selection)
      }
      // 弯到头的：手柄拖过尖端 / 尾端（沿弦停在 ¾ / ¼ 处）、贴着尖端的钩（箭头颈部不折）、弦很短的深 U、弯过后被拖短的
      h = capture()
      h.view.select(selection)
      h.view.annotations = Self.extreme(tool)
      h.move(CGPoint(x: 1150, y: 760))
      try shoot(h.window, "curved-\(noun)s-extreme", crop: selection)
    }

    // 尺寸胶囊：输入中（宽拿到键盘，粉色焦点环）；比例菜单开着；保存 ▾ 菜单开着
    h = adjust()
    h.clickSize(.width)
    let field = try #require(h.sizeField)
    try shoot(h.window, "size-editing", crop: field.frame.insetBy(dx: -40, dy: -30))
    // 文字输入中：焦点环（1 pt 粉 0.55 + 粉色外发光，底色时圆角同色块）、粉色光标；无底 / 描边 / 底色
    for (name, style) in [
      ("text-editing", Annotation.Style(color: .red, weight: .medium, option: 0)),
      ("text-editing-outline", .init(color: .white, weight: .medium, option: 1)),
      ("text-editing-plate", .init(color: .yellow, weight: .medium, option: 2)),
    ] {
      h = adjust()
      h.view.style = style
      h.view.tool = .text
      h.view.beginEditing(at: CGPoint(x: 420, y: 470))
      h.fieldEditor?.insertText(
        "输入中 Typing", replacementRange: NSRange(location: NSNotFound, length: 0))
      try shoot(h.window, name, crop: CGRect(x: 380, y: 400, width: 320, height: 110))
    }

    h = adjust()
    h.clickSize(nil)
    let menu = try #require(h.menu)
    try shoot(
      h.window, "ratio-menu",
      crop: menu.frame.union(try #require(h.sizeField).frame).insetBy(dx: -40, dy: -30))
    // 文字托盘的字号菜单（2026-11-12 拍板 A1），选中序号时托盘多一段编号（O2）
    h = adjust()
    h.move(CGPoint(x: 550, y: 400))
    h.view.style = .init(color: .red, fontSize: 32)
    h.view.tool = .text
    let fontBar = try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first)
    let sizeButton = try #require(
      Self.descendants(of: fontBar).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "字号"
      })
    sizeButton.sendAction(sizeButton.action, to: sizeButton.target)
    try shoot(
      h.window, "font-menu",
      crop: try #require(h.menu).frame.union(fontBar.frame).insetBy(dx: -30, dy: -30))
    try shootContent(fontBar, "tray-text")
    try shootContent(try #require(h.menu), "font-menu")
    h = adjust()
    let counter = Annotation(
      shape: .counter(7, center: CGPoint(x: 500, y: 400)), style: .init(color: .blue))
    h.view.annotations = [counter]
    h.view.selectedAnnotation = counter.id
    h.move(CGPoint(x: 1150, y: 760))
    try shoot(h.window, "tray-counter-selected", crop: barsFrame(h))
    try shootContent(
      try #require(h.view.subviews.lazy.compactMap { $0 as? StyleBar }.first),
      "tray-counter-selected")
    h = adjust()
    let caret = try #require(h.toolbar?.button(for: .saveMenu))
    caret.sendAction(caret.action, to: caret.target)
    try shoot(
      h.window, "save-menu",
      crop: try #require(h.menu).frame.union(try #require(h.toolbar).frame).insetBy(
        dx: -30, dy: -30))
    // 工具栏按钮上右键改快捷键（2026-11-06）：钉图钮的菜单（右边写现在的键），选了之后顶部提示等新的键
    h = adjust()
    let toolbar = try #require(h.toolbar)
    let pin = try #require(toolbar.button(for: .output(.pin)))
    toolbar.rightMouseDown(
      with: h.event(
        .rightMouseDown, pin.convert(CGPoint(x: pin.bounds.midX, y: pin.bounds.midY), to: nil)))
    let rebindMenu = try #require(h.menu)
    try shoot(
      h.window, "rebind-menu", crop: rebindMenu.frame.union(toolbar.frame).insetBy(dx: -30, dy: -30)
    )
    func buttons(in view: NSView) -> [NSView] {
      view.subviews.flatMap { $0.accessibilityRole() == .button ? [$0] : buttons(in: $0) }
    }
    _ = try #require(buttons(in: rebindMenu).first).accessibilityPerformPress()
    // 等着时：钉图钮一圈粉、提示挂在它下面（2026-11-06 用户：放在屏幕顶上不够明显）
    try shoot(
      h.window, "rebind-waiting", crop: toolbar.frame.insetBy(dx: -40, dy: -70))
    // 左段的工具（用户截图里等的是「椭圆」）：圈画在那段栏的内容层里，同当前工具的底块
    h = adjust()
    let tools = try #require(h.toolbar)
    let ellipse = try #require(tools.button(for: .tool(.ellipse)))
    tools.rightMouseDown(
      with: h.event(
        .rightMouseDown,
        ellipse.convert(CGPoint(x: ellipse.bounds.midX, y: ellipse.bounds.midY), to: nil)))
    let toolMenu = try #require(h.menu)
    _ = try #require(buttons(in: toolMenu).first).accessibilityPerformPress()
    try shoot(
      h.window, "rebind-waiting-tool", crop: tools.frame.insetBy(dx: -40, dy: -70))

    // 有标注时右键：不清空，顶部提示怎么退出
    h = adjust()
    h.view.annotations = [
      Annotation(shape: .rectangle(CGRect(x: 360, y: 330, width: 200, height: 100)))
    ]
    h.rightClick(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "right-click-hint", crop: top)

    // 截图翻译 / 识字（quick）：待选（提示 + 放大镜）、框选中（粉线、只读尺寸、放大镜、吸附参考线）
    let quick = {
      Harness(
        mode: .quick, windows: Self.windows, image: desktop, hint: "拖动框选要翻译的文字 · Esc 取消")
    }
    h = quick()
    h.move(CGPoint(x: 330, y: 520))
    try shoot(h.window, "quick-idle", crop: CGRect(x: 100, y: 340, width: 700, height: 460))
    h = quick()
    h.begin(CGPoint(x: 150, y: 560), to: CGPoint(x: 460, y: 638))
    try shoot(h.window, "quick-draw", crop: CGRect(x: 100, y: 340, width: 700, height: 460))

    // 录屏（录屏第 1 批）：待选的顶部提示；调整阶段同截图（手柄、尺寸胶囊），选区下方是录制条 [取消][● 开始录制]
    // （HUD 永远深色，不出深色版）；-bar 是录制条的局部
    let record = { Harness(mode: .record, windows: Self.windows, image: desktop) }
    h = record()
    h.move(CGPoint(x: 1000, y: 700))
    try shoot(h.window, "record-idle", crop: top)
    h = record()
    h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
    h.move(CGPoint(x: 801, y: 420))
    try shoot(h.window, "record-adjust", crop: CGRect(x: 150, y: 190, width: 900, height: 420))
    let bar = try #require(h.recordBar)
    try shoot(h.window, "record-adjust-bar", crop: bar.frame.insetBy(dx: -24, dy: -24))
    // 录制条的四个开关（录屏第 4 批；第四个显示按键是手测反馈第 2 批）：上面那张是默认（系统声音开，麦克风、显示点按、
    // 显示按键关）；全开、全关（偏好在 Harness 的临时域）。
    // 再换石墨（强调色比主文字色还暗）、黄色（最亮）各拍一遍：开和关要靠形状分得清。只换内存里的强调色，拍完换回
    let savedAccent = Accent.shared.choice
    defer { Accent.shared.select(savedAccent, persists: false) }
    for (accent, suffix) in [
      (AccentChoice?.none, ""), (.graphite, "-graphite"), (.yellow, "-yellow"),
    ] {
      if let accent { Accent.shared.select(accent, persists: false) }
      for (name, on) in [("record-bar-on", true), ("record-bar-off", false)] {
        h = record()
        let prefs = h.view.styleDefaults
        for key in [
          Prefs.screenRecordSystemAudio, Prefs.screenRecordMicrophone,
          Prefs.screenRecordShowsClicks, Prefs.screenRecordShowsKeys,
        ] {
          prefs.set(on, forKey: key)
        }
        h.drag(CGPoint(x: 300.3, y: 260.7), CGPoint(x: 800.4, y: 560.2))
        let toggled = try #require(h.recordBar)
        try shoot(h.window, name + suffix, crop: toggled.frame.insetBy(dx: -24, dy: -24))
      }
    }
    Accent.shared.select(savedAccent, persists: false)
    // 截图调整时按 R（录屏第 2 批）：工具栏原地换成录制条，选区、尺寸胶囊不变
    h = adjust()
    h.key(kVK_ANSI_R, "r")
    let switched = try #require(h.recordBar)
    let chosen = try #require(h.view.selection)
    try shoot(
      h.window, "record-switched", crop: switched.frame.union(chosen).insetBy(dx: -24, dy: -24))
  }

  @Test(.enabled(if: directory != nil)) func renderPeripherals() throws {
    let out = try #require(Self.directory)
    let desktop = try Self.desktop()
    // 常驻缩略图：飞行卡片落地后原地交接的同一张卡（同样的圆角、阴影、描边、右上角粉色角标），悬停时的 HUD 操作
    let shot = try #require(desktop.cropping(to: CGRect(x: 280, y: 240, width: 920, height: 600)))
    let card = CGSize(width: 200, height: 130)
    // 真的桌面目录：角标写访达里的名字（中文系统是「桌面」）
    let desktopFolder = try #require(
      FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
    let saved = FlyCard.Badge.saved(desktopFolder.appending(path: "a.png"))
    for (name, badge, hovered) in [
      ("shot-flycard-landed", FlyCard.Badge.copied, false), ("shot-flycard-saved", saved, false),
      ("shot-shelf-hover", saved, true),
    ] {
      let shelf = ShelfCard(
        image: shot, scale: 2, source: CGRect(origin: .zero, size: card),
        rect: CGRect(origin: .zero, size: card), badge: badge, screen: nil, panel: NSPanel(),
        shelf: ShotShelf())
      shelf.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: shelf), over: desktop,
          size: NSSize(
            width: card.width + ShotShelf.margin * 2, height: card.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 矮卡（体检 B46）：悬停的「拷贝」「存储」胶囊只剩图标（名字靠 accessibilityLabel），四角圆钮不画
    let compact = CGSize(width: 110, height: 70)
    let small = ShelfCard(
      image: shot, scale: 2, source: CGRect(origin: .zero, size: compact),
      rect: CGRect(origin: .zero, size: compact), badge: .copied, screen: nil, panel: NSPanel(),
      shelf: ShotShelf())
    small.isHovered = true
    for dark in [false, true] {
      try snapshot(
        ShelfCardView(card: small), over: desktop,
        size: NSSize(
          width: compact.width + ShotShelf.margin * 2, height: compact.height + ShotShelf.margin * 2
        ),
        dark: dark, to: "\(out)/shot-shelf-compact-hover\(dark ? "-dark" : "").png")
    }

    // 录屏的视频卡（第 3 批）：飞行卡片落地后交接的同一张卡（最后一帧 + 播放符号 + 左下角时长 + 文件夹角标）、悬停（「拷贝」
    // 「转成 GIF」+ 关闭 / 在访达中显示，第二轮体检 R1 起右下角多一个「压缩」圆钮）、矮卡（播放符号缩小；悬停胶囊只剩图标、
    // 没有四角圆钮）、没取到最后一帧的占位；压缩出来的那张悬停时右下角没有「压缩」
    for (name, size, poster, hovered, compressed) in [
      ("shot-video-landed", card, true, false, false),
      ("shot-video-hover", card, true, true, false),
      ("shot-video-compact", compact, true, false, false),
      ("shot-video-compact-hover", compact, true, true, false),
      ("shot-video-placeholder", card, false, false, false),
      ("shot-video-compressed-hover", card, true, true, true),
    ] {
      let video = ShelfCard(
        file: .video(desktopFolder.appending(path: "录屏 2026-09-30 10.00.00.mp4"), seconds: 83),
        poster: poster ? shot : nil, source: CGRect(origin: .zero, size: size),
        rect: CGRect(origin: .zero, size: size), screen: nil, panel: NSPanel(), shelf: ShotShelf(),
        isCompressed: compressed)
      video.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: video), over: desktop,
          size: NSSize(
            width: size.width + ShotShelf.margin * 2, height: size.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 录屏转成的 GIF 卡（第 7 批）：第一帧 + 左下「GIF」胶囊（没有播放符号）+ 文件夹角标；悬停只有「拷贝」+ 关闭 / 在访达中显示
    // （视频卡悬停的「拷贝」「转成 GIF」两枚胶囊在上面的 shot-video-hover / -compact-hover）
    for (name, hovered) in [("shot-gif-landed", false), ("shot-gif-hover", true)] {
      let gif = ShelfCard(
        file: .gif(desktopFolder.appending(path: "录屏 2026-09-30 10.00.00.gif")), poster: shot,
        source: CGRect(origin: .zero, size: card), rect: CGRect(origin: .zero, size: card),
        screen: nil, panel: NSPanel(), shelf: ShotShelf())
      gif.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: gif), over: desktop,
          size: NSSize(
            width: card.width + ShotShelf.margin * 2, height: card.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 录音卡（录音第 5 批）：波形 poster（HUD 底色 + 竖条）+ 左上角 waveform 标记 + 左下时长；落地、悬停（只有「拷贝」+ 关闭 /
    // 在访达中显示）、矮卡（实际落地总是 poster 的 200 × 125，矮卡只为看标记在小卡上挤不挤）
    let envelope = (0..<160).map { index -> Float in
      let x = Float(index)
      return index % 37 < 5 ? -58 : -30 + 16 * sin(x * 0.45) * sin(x * 0.07)
    }
    let wave = try #require(AudioRecorder.waveform(envelope))
    for (name, size, hovered) in [
      ("shot-audio-landed", AudioRecorder.posterSize, false),
      ("shot-audio-hover", AudioRecorder.posterSize, true),
      ("shot-audio-compact", CGSize(width: 112, height: 70), false),
    ] {
      let audio = ShelfCard(
        recording: desktopFolder.appending(path: "录音 2026-09-30 10.00.00.m4a"), seconds: 65,
        audio: true, poster: wave, source: CGRect(origin: .zero, size: size),
        rect: CGRect(origin: .zero, size: size), screen: nil, panel: NSPanel(), shelf: ShotShelf())
      audio.isHovered = hovered
      for dark in [false, true] {
        try snapshot(
          ShelfCardView(card: audio), over: desktop,
          size: NSSize(
            width: size.width + ShotShelf.margin * 2, height: size.height + ShotShelf.margin * 2),
          dark: dark, to: "\(out)/\(name)\(dark ? "-dark" : "").png")
      }
    }

    // 长截图：选区外的粉色边框（呼吸 / 自动滚动时的蚂蚁线）+ 贴在右边的 HUD 面板（预览、高度读数、粉色自动滚动钮和拷贝钮）
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 1200, height: 480)))
    let second = try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 1200, height: 480)))
    var stitcher = try #require(
      ScrollStitcher(first: first, scrollbarWidth: 32, maxHeight: 30_000))
    _ = stitcher.add(second)
    let region = CGRect(x: 160, y: 200, width: 600, height: 420)
    for (name, auto) in [("scroll", false), ("scroll-auto", true)] {
      let root = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
      root.wantsLayer = true
      root.layer?.contents = desktop
      let border = ScrollBorderView()
      border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
      border.update(lost: false, marching: auto)
      root.addSubview(border)
      let hud = ScrollCaptureHUD()
      hud.frame = CGRect(
        x: region.maxX + 10, y: region.minY, width: ScrollCaptureHUD.width,
        height: region.height)
      hud.isAutoScrolling = auto
      root.addSubview(hud)
      let window = offscreen(root)
      try shoot(window, name, crop: region.insetBy(dx: -30, dy: -30).union(hud.frame)) {
        hud.show(
          ScrollCapture.status(notice: nil, isFull: false, isLost: false, isAutoScrolling: auto)
            .text, width: stitcher.width, height: stitcher.outputHeight)
        hud.updatePreview(stitcher: stitcher, scale: 2)
      }
    }
  }

  /// 录屏讲解工具在屏外渲染：跟随光圈、聚光灯、画笔和激光轨迹，工具箱使用与录制相同的状态和尺寸。
  @Test(.enabled(if: directory != nil)) func renderRecordingTools() throws {
    let out = try #require(Self.directory)
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let desktop = try Self.desktop()
    for (name, focus, mode) in [
      ("idle", RecordingTools.Focus.off, RecordingTools.Mode.pointer),
      ("collapsed", .off, .pointer),
      ("collapsed-drawing", .off, .pen),
      ("halo", RecordingTools.Focus.halo, RecordingTools.Mode.pointer),
      ("spotlight", .spotlight, .pointer),
      ("drawing", .off, .pen),
      ("drawing-focus", .halo, .pen),
      ("laser", .halo, .laser),
    ] {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let canvas = try #require(RecordingCanvas(region: bounds))
      let bar = RecordingToolsBar()
      let hud = RecordingHUD(state: .recording(75), stopKey: "⌥R")
      defer {
        canvas.close()
        bar.close()
        hud.close()
      }
      canvas.panel.contentView = nil
      canvas.view.frame = bounds
      root.addSubview(canvas.view)
      bar.removeFromSuperview()
      bar.frame.origin = CGPoint(x: 570, y: 60)
      root.addSubview(bar)
      hud.setToolsAvailable(true, selected: true)
      hud.removeFromSuperview()
      hud.frame.origin = CGPoint(x: 720, y: 18)
      root.addSubview(hud)
      let window = offscreen(root)
      try shoot(window, "record-tools-\(name)") {
        /// 合成事件直接交给屏外视图，不发送到系统或用户的前台窗口。
        @MainActor func draw(
          _ tool: RecordingTools.Mode, color: Annotation.Palette, from: CGPoint, to: CGPoint
        ) {
          canvas.apply(.mode(tool))
          canvas.apply(.color(color))
          for (type, point) in [
            (NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to),
          ] {
            guard
              let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)
            else { continue }
            switch type {
            case .leftMouseDown: canvas.view.mouseDown(with: event)
            case .leftMouseDragged: canvas.view.mouseDragged(with: event)
            default: canvas.view.mouseUp(with: event)
            }
          }
        }
        draw(.rectangle, color: .red, from: CGPoint(x: 160, y: 390), to: CGPoint(x: 450, y: 540))
        draw(.arrow, color: .blue, from: CGPoint(x: 490, y: 560), to: CGPoint(x: 410, y: 510))
        draw(
          .highlighter, color: .yellow, from: CGPoint(x: 190, y: 430), to: CGPoint(x: 390, y: 430))
        canvas.apply(.color(.red))
        canvas.apply(.focus(focus))
        canvas.apply(.mode(mode))
        if mode == .laser {
          let began = CACurrentMediaTime()
          for index in 0..<35 {
            canvas.addLaser(
              to: CGPoint(x: 220 + index * 5, y: 280 + Int(sin(Double(index) * 0.15) * 25)),
              at: began + Double(index) * 0.01, animated: false)
          }
          canvas.updatePointer(at: CGPoint(x: 390, y: 257), animated: false)
        } else {
          canvas.updatePointer(at: CGPoint(x: 370, y: 480), animated: false)
        }
        bar.update(canvas.state, escapes: true)
        if name == "drawing-focus" {
          bar.onAction = { [weak bar, weak canvas] action in
            guard let canvas else { return }
            canvas.apply(action)
            bar?.update(canvas.state, escapes: true)
          }
          bar.focusButton(for: .halo)?.performClick(nil)
          bar.focusButton(for: .halo)?.performClick(nil)
        }
        bar.arrange(anchor: hud.frame, visible: bounds)
        if name.hasPrefix("collapsed") { bar.setCollapsed(true) }
        bar.frame.origin = bar.panel.frame.origin
        if bar.hasOptions, let bubble = bar.optionsPanel.contentView {
          bubble.removeFromSuperview()
          bubble.frame = bar.optionsPanel.frame
          root.addSubview(bubble)
        }
        Self.snapshotRecordingHUDs(in: root)
      }
    }
  }

  /// 屏外 render 不绘制系统玻璃及其内容，测试中将内容移到纯色 HUD 底上，仅验证布局、符号和选择状态。
  private static func snapshotRecordingHUDs(in view: NSView) {
    if #available(macOS 26, *), let bar = view as? HUDBar {
      let rows = bar.effect.subviews.compactMap { $0 as? NSStackView }.filter { !$0.isHidden }
      for material in bar.subviews { material.isHidden = true }
      for row in rows {
        let center = bar.effect.constraints.first {
          $0.firstItem === row && $0.firstAttribute == .centerY
        }?.constant
        let bottom = bar.effect.constraints.first {
          $0.firstItem === row && $0.firstAttribute == .bottom
        }?.constant
        let size = row.fittingSize
        row.removeFromSuperview()
        row.translatesAutoresizingMaskIntoConstraints = true
        row.isHidden = false
        row.frame = CGRect(
          x: row === bar.stack ? HUDBar.materialInset : (bar.bounds.width - size.width) / 2,
          y: bottom ?? ((bar.bounds.height - size.height) / 2 + (center ?? 0)),
          width: size.width, height: size.height)
        bar.addSubview(row)
        row.layoutSubtreeIfNeeded()
      }
      bar.layer?.backgroundColor = Style.HUD.solidFill.cgColor
      bar.layer?.cornerRadius = bar is StyleBar ? Style.Radius.card : Style.Radius.panel
    }
    for child in view.subviews { snapshotRecordingHUDs(in: child) }
  }

  /// 录制 HUD（录屏第 2 批）：倒数（边框走蚂蚁线、HUD「3 秒后开始」）、录制中 0:12（边框静止、红点、计时、✕、■）、
  /// 放弃上膛（✕ 变红）、整屏（没有边框，可见区底部居中）。HUD 永远深色，不出深色版；-crop 是 HUD 的局部。
  /// 2026-10-12 视觉对齐：选区录制的 HUD 右边线对着录制条的右边线（各张 -crop 右边都留 24 pt：✕、主圆钮离右边一样远）；
  /// record-hud-align / audio-hud-align 把各种形态按真实的摆位上下叠在一张图里，看右边线、✕、主圆钮是不是各在一条竖线上
  @Test(.enabled(if: directory != nil)) func renderRecordingHUD() throws {
    let desktop = try Self.desktop()
    let region = CGRect(x: 160, y: 260, width: 640, height: 400)
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let visible = bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12)
    // 录制条的开关、录音待录的来源开关读临时偏好域
    let suite = "kitty-snapshot-\(UUID().uuidString)"
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    // 第 4 批：声音状态（-sound 两个都开、-system 只开系统声音、-mic-lost 麦克风断开变橙）；原来那四张不录声音，和以前一样
    for (name, state, counting, armed) in [
      ("record-hud-countdown", RecordingHUD.State.countdown(3), true, false),
      ("record-hud", .recording(12), false, false),
      ("record-hud-armed", .recording(12), false, true),
      ("record-hud-full", .recording(12), false, false),
      ("record-hud-sound", .recording(12), false, false),
      ("record-hud-system", .recording(12), false, false),
      ("record-hud-mic-lost", .recording(12), false, false),
    ] {
      let full = name.hasSuffix("full")
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      if !full {
        let border = ScrollBorderView(animates: counting)
        border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
        if counting { border.update(lost: false, marching: true) }
        root.addSubview(border)
      }
      let sound = ["record-hud-sound", "record-hud-system", "record-hud-mic-lost"].contains(name)
      let hud = RecordingHUD(
        state: state, stopKey: "⌥R", systemAudio: sound,
        microphone: sound && name != "record-hud-system")
      if armed { try #require(hud.button(for: .discard)).performClick(nil) }
      if name == "record-hud-mic-lost" { hud.microphoneLost(animated: false) }
      hud.removeFromSuperview()  // 从它自己的窗口里拿出来，摆到假桌面上
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: full ? bounds : region, screen: bounds, visible: visible,
        isFullScreen: full, dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
    }

    // 右边线对齐：从上到下是录制条（toolbarPlacement）、倒数、录制态（不带 / 带声音图标）、录了一小时多的（计时多三位），
    // HUD 各按 origin 算 x，再往下错开摆
    do {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let bar = RecordBar(defaults: prefs)
      bar.frame.origin =
        SelectionView.toolbarPlacement(
          size: bar.frame.size, selection: region, in: bounds, tray: 0
        ).origin
      root.addSubview(bar)
      var frames = [bar.frame]
      let rows: [(RecordingHUD.State, Bool)] = [
        (.countdown(3), true), (.recording(12), false), (.recording(12), true),
        (.recording(3725), true),
      ]
      for (index, (state, sound)) in rows.enumerated() {
        let hud = RecordingHUD(state: state, stopKey: "⌥R", systemAudio: sound, microphone: sound)
        hud.removeFromSuperview()
        hud.frame.origin = RecordingHUD.origin(
          size: hud.frame.size, region: region, screen: bounds, visible: visible,
          isFullScreen: false, dragged: nil)
        hud.frame.origin.y -= CGFloat(index + 1) * 48
        root.addSubview(hud)
        frames.append(hud.frame)
      }
      try shoot(
        offscreen(root), "record-hud-align",
        crop: frames.dropFirst().reduce(frames[0]) { $0.union($1) }.insetBy(dx: -24, dy: -24))
    }

    // 录音 HUD（录音第 5 批）：整屏的摆法（可见区底部居中、离底 24），[● 0:42][电平] ｜ [⏸] ｜ [✕][■]；
    // 录制中（说话的电平）、暂停（暂停符号、计时和电平变灰）、没听到声音（橙字）、最新一根超过 −1 dB（橙）；
    // 录音第 6 批：录系统声音（⏸ 原位置灰）、「两者」录着时麦克风断开（橙字「麦克风断开了」）
    let speech = (0..<24).map { index -> Float in -38 + 16 * sin(Float(index) * 0.9) }
    for (name, levels, paused, silent, pausable) in [
      ("audio-hud", speech, false, false, true), ("audio-hud-paused", speech, true, false, true),
      ("audio-hud-silent", [Float](repeating: -120, count: 24), false, true, true),
      ("audio-hud-loud", speech.dropLast() + [-0.4], false, false, true),
      ("audio-hud-system", speech, false, false, false),
      ("audio-hud-mic-lost", speech, false, false, false),
    ] {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let hud = RecordingHUD(
        state: .recording(42), stopKey: nil, medium: .audio, pausable: pausable)
      hud.updateMeter(levels)
      if paused { hud.setPaused(true) }
      if silent { hud.setSilent(true) }
      if name == "audio-hud-mic-lost" { hud.microphoneLost(animated: false) }
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: bounds, screen: bounds, visible: visible,
        isFullScreen: true, dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
    }

    // 录音控制条的待录态（手测反馈第 3 批）：[系统声音][麦克风] ｜ [✕][●]，同一个位置；来源读临时偏好域——只开麦克风
    // （默认）、两者、只开系统声音；-starting 是按了开始、还没录起来（开关和 ● 置灰，✕ 不灰）
    for (name, source, starting) in [
      ("audio-hud-ready", AudioRecorder.Source.microphone, false),
      ("audio-hud-ready-both", .both, false), ("audio-hud-ready-system", .system, false),
      ("audio-hud-ready-starting", .both, true),
    ] {
      prefs.set(source.rawValue, forKey: Prefs.audioRecordSource)
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let hud = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: prefs)
      if starting { hud.setStarting() }
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: bounds, screen: bounds, visible: visible,
        isFullScreen: true, dragged: nil)
      root.addSubview(hud)
      try shoot(offscreen(root), name, crop: hud.frame.insetBy(dx: -24, dy: -24))
      hud.close()
    }

    // 录音的右边线对齐：最下面是待录（可见区底部居中），往上是从它原地换成的录制态、出了「没听到声音」的、录了一小时多的
    // ——右边线不动（RecordingHUD.x），条往左长
    do {
      prefs.set(AudioRecorder.Source.microphone.rawValue, forKey: Prefs.audioRecordSource)
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      let ready = RecordingHUD(state: .ready, stopKey: nil, medium: .audio, defaults: prefs)
      ready.removeFromSuperview()
      ready.frame.origin = RecordingHUD.origin(
        size: ready.frame.size, region: bounds, screen: bounds, visible: visible,
        isFullScreen: true, dragged: nil)
      root.addSubview(ready)
      var frames = [ready.frame]
      for (index, (seconds, silent)) in [(42, false), (3, true), (3725, false)].enumerated() {
        let hud = RecordingHUD(state: .recording(seconds), stopKey: nil, medium: .audio)
        hud.updateMeter(silent ? [Float](repeating: -120, count: 24) : speech)
        if silent { hud.setSilent(true) }
        hud.removeFromSuperview()
        hud.frame.origin = CGPoint(
          x: RecordingHUD.x(width: hud.frame.width, maxX: ready.frame.maxX, in: visible),
          y: ready.frame.minY + CGFloat(index + 1) * 48)
        root.addSubview(hud)
        frames.append(hud.frame)
      }
      try shoot(
        offscreen(root), "audio-hud-align",
        crop: frames.dropFirst().reduce(frames[0]) { $0.union($1) }.insetBy(dx: -24, dy: -24))
      ready.close()
    }
  }

  /// 录屏的点按圈（手测反馈第 1 批，InputOverlay）：上排左键按下（实心圆盘）、下排右键按下（空心环），三栏底色是白、
  /// 近黑、强调色本身（最不利：圈的强调色融进底里，只剩白描边和阴影）；默认强调色、石墨（最暗）、黄色（最亮）各一张。
  /// -desktop 是压在假桌面上的样子：左键点在备忘录的字上、右键点在壁纸上、再一个左键点在表格的粉色柱子上。
  /// 都用不带动画的入口摆到按住的终态（render(in:) 画的也是模型值，拍不到过渡的半截）
  @Test(.enabled(if: directory != nil)) func renderInputOverlay() throws {
    /// 覆盖层的内容视图从它自己的窗口里拿出来（窗口不显示），摆到 frame 上；frame 也是它的窗口位置，全局坐标就是 root 的坐标
    func overlay(on root: NSView, frame: CGRect) throws -> InputOverlay {
      let overlay = InputOverlay(frame: frame)
      let view = try #require(overlay.panel.contentView)
      overlay.panel.contentView = nil
      view.frame = frame
      root.addSubview(view)
      return overlay
    }
    let savedAccent = Accent.shared.choice
    defer { Accent.shared.select(savedAccent, persists: false) }
    for (accent, suffix) in [
      (AccentChoice?.none, ""), (.graphite, "-graphite"), (.yellow, "-yellow"),
    ] {
      if let accent { Accent.shared.select(accent, persists: false) }
      let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 240))
      root.wantsLayer = true
      let grounds = [NSColor.white, NSColor(white: 0.11, alpha: 1), Style.Shot.accent]
      var overlays: [InputOverlay] = []
      for (index, color) in grounds.enumerated() {
        let column = CGRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 240)
        let ground = NSView(frame: column)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = color.cgColor
        root.addSubview(ground)
        let made = try overlay(on: root, frame: column)
        made.press(0, at: CGPoint(x: column.midX, y: 180), animated: false)
        made.press(1, at: CGPoint(x: column.midX, y: 60), animated: false)
        overlays.append(made)
      }
      try shoot(offscreen(root), "record-clicks" + suffix)
      for overlay in overlays { overlay.close() }
    }
    Accent.shared.select(savedAccent, persists: false)

    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let root = NSView(frame: bounds)
    root.wantsLayer = true
    root.layer?.contents = try Self.desktop()
    let made = try overlay(on: root, frame: bounds)
    made.press(0, at: CGPoint(x: 300, y: 620), animated: false)
    made.press(1, at: CGPoint(x: 700, y: 640), animated: false)
    // 同一个键同时只有一个圈：第二个左键用另一块覆盖层摆
    let second = try overlay(on: root, frame: bounds)
    second.press(0, at: CGPoint(x: 905, y: 225), animated: false)
    try shoot(
      offscreen(root), "record-clicks-desktop",
      crop: CGRect(x: 140, y: 120, width: 960, height: 580)
    )
    made.close()
    second.close()
  }

  /// 录屏的按键胶囊（手测反馈第 2 批，InputOverlay）：
  /// - keys-full：整屏录制，胶囊在可见区底边上方 88 pt，下面是录制 HUD（HUD 不进画面，在屏幕上不能和胶囊叠着）；短的 ⌘C；
  /// - keys-repeat：录备忘录那个窗口，几个记号 + 按住不放的 ×n（次要文字色、小一号）；压在字上（底不透明，不透字）；
  /// - keys-overflow：选区录制，敲了一长串：放不下的从左边丢，胶囊不超过选区宽减两边各 16，离选区底边 32；
  /// - keys-small：小选区（200 × 64，录屏的下限）：胶囊夹进选区里；
  /// - keys-narrow：很窄的选区（64 宽）：一个记号就比胶囊放得下的宽，字等比缩小、留在胶囊里。
  /// 都走不带动画的入口（终态）；-crop 是胶囊附近的局部
  @Test(.enabled(if: directory != nil)) func renderKeys() throws {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let visible = bounds.insetBy(dx: 0, dy: 24).offsetBy(dx: 0, dy: -12)
    let desktop = try Self.desktop()
    /// 假桌面 + 被录区域的边框（整屏没有）+ 录制 HUD + 开着显示按键的覆盖层（内容视图拿出来摆到 region 上）
    func stage(_ region: CGRect, full: Bool) throws -> (NSView, InputOverlay, RecordingHUD) {
      let root = NSView(frame: bounds)
      root.wantsLayer = true
      root.layer?.contents = desktop
      if !full {
        let border = ScrollBorderView(animates: false)
        border.frame = region.insetBy(dx: -ScrollBorderView.margin, dy: -ScrollBorderView.margin)
        root.addSubview(border)
      }
      let hud = RecordingHUD(state: .recording(12), stopKey: "⌥R", systemAudio: true)
      hud.removeFromSuperview()
      hud.frame.origin = RecordingHUD.origin(
        size: hud.frame.size, region: region, screen: bounds, visible: visible, isFullScreen: full,
        dragged: nil)
      root.addSubview(hud)
      let overlay = InputOverlay(
        frame: region,
        keysBottom: InputOverlay.keysBottom(
          region: region, screen: bounds, visible: visible, isFullScreen: full))
      let view = try #require(overlay.panel.contentView)
      overlay.panel.contentView = nil
      view.frame = region
      root.addSubview(view)
      return (root, overlay, hud)
    }
    /// 胶囊（视图坐标）连同 HUD 的外框，外扩一圈
    func around(_ overlay: InputOverlay, _ region: CGRect, _ hud: RecordingHUD) throws -> CGRect {
      try #require(overlay.keysBarFrame).offsetBy(dx: region.minX, dy: region.minY)
        .union(hud.frame).insetBy(dx: -60, dy: -30)
    }

    var (root, overlay, hud) = try stage(bounds, full: true)
    overlay.showKey("⌘C", animated: false)
    try shoot(offscreen(root), "record-keys-full", crop: try around(overlay, bounds, hud))
    overlay.close()

    // 录备忘录那个窗口：胶囊压在最下面两行字上
    (root, overlay, hud) = try stage(Self.windows[0], full: false)
    for name in ["⌘A", "⌘C", "⇧A", "空格", "↩"] { overlay.showKey(name, animated: false) }
    overlay.showKey("⌫", animated: false)
    for _ in 0..<11 { overlay.showKey("⌫", isRepeat: true, animated: false) }
    try shoot(
      offscreen(root), "record-keys-repeat", crop: try around(overlay, Self.windows[0], hud))
    overlay.close()

    let region = CGRect(x: 160, y: 260, width: 480, height: 400)
    (root, overlay, hud) = try stage(region, full: false)
    for letter in "THE QUICK BROWN FOX JUMPS OVER" {
      overlay.showKey(letter == " " ? "空格" : String(letter), animated: false)
    }
    overlay.showKey("⌘S", animated: false)
    try shoot(
      offscreen(root), "record-keys-overflow",
      crop: region.union(hud.frame).insetBy(dx: -30, dy: -30))
    overlay.close()

    let small = CGRect(x: 700, y: 560, width: 200, height: 64)
    (root, overlay, hud) = try stage(small, full: false)
    for name in ["⌃⌥⇧⌘K", "⌘V", "⌘V"] { overlay.showKey(name, animated: false) }
    try shoot(
      offscreen(root), "record-keys-small", crop: small.union(hud.frame).insetBy(dx: -40, dy: -30))
    overlay.close()

    let narrow = CGRect(x: 760, y: 500, width: 64, height: 160)
    (root, overlay, hud) = try stage(narrow, full: false)
    overlay.showKey("⇧A", animated: false)
    try shoot(
      offscreen(root), "record-keys-narrow",
      crop: narrow.union(hud.frame).insetBy(dx: -40, dy: -30))
    overlay.close()
  }

  // MARK: 摆状态

  /// 10 种标注摆在假桌面上：荧光笔压在第一行字上、马赛克像素 / 模糊各压一段表格、文字三种样式、三个序号、聚光灯照着色块
  private static func allAnnotations(spotlight: Bool) -> [Annotation] {
    var list = [
      Annotation(
        shape: .highlighter(from: CGPoint(x: 160, y: 621), to: CGPoint(x: 430, y: 621)),
        style: .init(color: .yellow)),
      Annotation(shape: .rectangle(CGRect(x: 152, y: 530, width: 262, height: 34))),
      Annotation(
        shape: .rectangle(CGRect(x: 160, y: 400, width: 150, height: 50)),
        style: .init(color: .pink, option: 1)),
      Annotation(
        shape: .ellipse(CGRect(x: 610, y: 400, width: 170, height: 70)),
        style: .init(color: .green, weight: .small)),
      Annotation(
        shape: .arrow(from: CGPoint(x: 470, y: 250), to: CGPoint(x: 600, y: 360)),
        style: .init(color: .blue, weight: .large)),
      Annotation(
        shape: .line(from: CGPoint(x: 160, y: 300), to: CGPoint(x: 420, y: 300)),
        style: .init(color: .orange)),
      Annotation(
        shape: .pen(
          stride(from: 0.0, through: 1, by: 0.05).map {
            CGPoint(x: 170 + 240 * $0, y: 230 + 26 * sin($0 * .pi * 4))
          }), style: .init(color: .black, weight: .small)),
      Annotation(shape: .mosaic(CGRect(x: 540, y: 300, width: 250, height: 56))),
      Annotation(
        shape: .mosaic(CGRect(x: 540, y: 200, width: 250, height: 56)), style: .init(option: 1)),
      Annotation(shape: .text("看这里", origin: CGPoint(x: 640, y: 716))),
      Annotation(
        shape: .text("描边文字", origin: CGPoint(x: 820, y: 716)),
        style: .init(color: .white, weight: .medium, option: 1)),
      Annotation(
        shape: .text("底色 Plate", origin: CGPoint(x: 150, y: 716)),
        style: .init(color: .yellow, weight: .medium, option: 2)),
    ]
    for (index, weight) in Annotation.Weight.allCases.enumerated() {
      let center = CGPoint(x: 460 + CGFloat(index) * 50, y: 650)
      list.append(
        Annotation(
          shape: .counter(index + 1, center: center), style: .init(color: .pink, weight: weight)))
    }
    if spotlight {
      list.append(Annotation(shape: .spotlight(CGRect(x: 850, y: 190, width: 200, height: 170))))
    }
    return list
  }

  /// 弯箭头 / 弯直线一组（选区 (120, 150, 960 × 580) 里）：左列细 / 中 / 粗各一条弯的 + 一条同样式直的，右边偏向一端、
  /// U 形、压在表格上的白色和黄色
  private static func curved(_ tool: Annotation.Tool) -> [Annotation] {
    func item(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector, _ style: Annotation.Style)
      -> Annotation
    {
      Annotation(shape: .bendable(tool, from: from, to: to, bend: bend), style: style)
    }
    return [
      item(
        CGPoint(x: 160, y: 180), CGPoint(x: 380, y: 190), CGVector(dx: 0, dy: 0.15),
        .init(color: .pink, weight: .small)),
      item(
        CGPoint(x: 160, y: 300), CGPoint(x: 380, y: 300), CGVector(dx: 0, dy: -0.2),
        .init(color: .red, weight: .medium)),
      item(CGPoint(x: 160, y: 350), CGPoint(x: 380, y: 350), .zero, .init(color: .red)),
      item(
        CGPoint(x: 420, y: 170), CGPoint(x: 470, y: 420), CGVector(dx: 0, dy: 0.25),
        .init(color: .blue, weight: .large)),
      item(
        CGPoint(x: 520, y: 170), CGPoint(x: 570, y: 420), .zero,
        .init(color: .blue, weight: .large)),
      item(
        CGPoint(x: 160, y: 560), CGPoint(x: 420, y: 700), CGVector(dx: 0.25, dy: -0.25),
        .init(color: .green, weight: .medium)),
      item(
        CGPoint(x: 640, y: 660), CGPoint(x: 540, y: 660), CGVector(dx: 0, dy: 1.1),
        .init(color: .orange, weight: .large)),
      item(
        CGPoint(x: 760, y: 300), CGPoint(x: 1040, y: 480), CGVector(dx: -0.15, dy: -0.3),
        .init(color: .white, weight: .large)),
      item(
        CGPoint(x: 1050, y: 680), CGPoint(x: 780, y: 600), CGVector(dx: 0, dy: 0.45),
        .init(color: .yellow, weight: .medium)),
      item(
        CGPoint(x: 660, y: 720), CGPoint(x: 900, y: 725), CGVector(dx: 0, dy: -0.2),
        .init(color: .black, weight: .small)),
    ]
  }

  /// 弯到头的箭头 / 直线（选区 (120, 150, 960 × 580) 里）：左列三档粗细的手柄拖过尖端、离弦不远（尖端带钩）+ 拖过尾端；
  /// 右边拖过尖端很远（J 形，一白一橙）、斜弦上的钩、弦 30 的深 U、弯过后被拖到弦 10 的粗 / 细（箭头头缩短）；
  /// 横贯选区的一条弦 900、手柄拖过尖端 20 点、离弦 4.5 点（长弦上很短的钩）
  private static func extreme(_ tool: Annotation.Tool) -> [Annotation] {
    func stored(_ from: CGPoint, _ to: CGPoint, _ bend: CGVector, _ style: Annotation.Style)
      -> Annotation
    {
      Annotation(shape: .bendable(tool, from: from, to: to, bend: bend), style: style)
    }
    func dragged(_ from: CGPoint, _ to: CGPoint, _ handle: CGPoint, _ style: Annotation.Style)
      -> Annotation
    {
      stored(
        from, to, Annotation.curveBend(from: from, to: to, through: handle, constrained: false),
        style)
    }
    return [
      dragged(
        CGPoint(x: 160, y: 700), CGPoint(x: 400, y: 700), CGPoint(x: 420, y: 712),
        .init(color: .pink, weight: .small)),
      dragged(
        CGPoint(x: 160, y: 620), CGPoint(x: 400, y: 620), CGPoint(x: 420, y: 638),
        .init(color: .red, weight: .medium)),
      dragged(
        CGPoint(x: 160, y: 530), CGPoint(x: 400, y: 530), CGPoint(x: 420, y: 555),
        .init(color: .blue, weight: .large)),
      dragged(
        CGPoint(x: 160, y: 420), CGPoint(x: 400, y: 420), CGPoint(x: 60, y: 410),
        .init(color: .green, weight: .medium)),
      dragged(
        CGPoint(x: 480, y: 520), CGPoint(x: 720, y: 520), CGPoint(x: 820, y: 660),
        .init(color: .orange, weight: .large)),
      dragged(
        CGPoint(x: 720, y: 330), CGPoint(x: 480, y: 330), CGPoint(x: 400, y: 250),
        .init(color: .white, weight: .large)),
      dragged(
        CGPoint(x: 800, y: 700), CGPoint(x: 1040, y: 600), CGPoint(x: 1080, y: 600),
        .init(color: .green, weight: .large)),
      stored(
        CGPoint(x: 820, y: 250), CGPoint(x: 850, y: 250), CGVector(dx: 0, dy: 5),
        .init(color: .yellow, weight: .medium)),
      stored(
        CGPoint(x: 950, y: 300), CGPoint(x: 960, y: 300), CGVector(dx: 0, dy: 1.8),
        .init(color: .red, weight: .large)),
      stored(
        CGPoint(x: 1010, y: 300), CGPoint(x: 1020, y: 300), CGVector(dx: 0, dy: 2),
        .init(color: .black, weight: .small)),
      dragged(
        CGPoint(x: 140, y: 175), CGPoint(x: 1040, y: 175), CGPoint(x: 1060, y: 179.5),
        .init(color: .red, weight: .large)),
    ]
  }

  /// view 底下所有的子视图（深度优先）
  static func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  /// 工具栏 + 样式托盘（+ 开着的菜单）外扩 24
  private func barsFrame(_ h: Harness) -> CGRect {
    let bars = h.view.subviews.filter {
      ($0 is EditorToolbar || $0 is StyleBar || $0 is HUDMenu) && !$0.isHidden
    }
    return bars.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -24)
  }

  /// 假桌面（1200 × 800 点 @2x）：渐变壁纸、菜单栏，后面一个表格窗口（行、色块），前面一个备忘录窗口（多语种文字）
  static func desktop() throws -> CGImage {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1600, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = NSSize(width: 1200, height: 800)  // 按点画，像素是 2 倍
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor = .black)
    {
      NSAttributedString(
        string: string,
        attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]
      ).draw(at: NSPoint(x: x, y: y))
    }
    NSGradient(
      starting: NSColor(srgbRed: 0.24, green: 0.19, blue: 0.50, alpha: 1),
      ending: NSColor(srgbRed: 0.10, green: 0.56, blue: 0.58, alpha: 1))?
      .draw(in: NSRect(x: 0, y: 0, width: 1200, height: 800), angle: -30)
    NSColor.white.withAlphaComponent(0.8).setFill()
    NSRect(x: 0, y: 776, width: 1200, height: 24).fill()
    text("Finder    文件    编辑    显示    前往    窗口", 16, 780, size: 13)
    for (index, frame) in windows.enumerated().reversed() {
      let shadow = NSShadow()
      shadow.shadowColor = .black.withAlphaComponent(0.35)
      shadow.shadowBlurRadius = 20
      shadow.shadowOffset = NSSize(width: 0, height: -8)
      NSGraphicsContext.saveGraphicsState()
      shadow.set()
      NSColor(white: index == 0 ? 1 : 0.97, alpha: 1).setFill()
      NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).fill()
      NSGraphicsContext.restoreGraphicsState()
      NSColor(white: 0.93, alpha: 1).setFill()
      NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 18).fill()
      NSBezierPath(
        roundedRect: NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28),
        xRadius: 10, yRadius: 10
      ).fill()
      for (dot, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(
          ovalIn: NSRect(
            x: frame.minX + 12 + CGFloat(dot) * 20, y: frame.maxY - 20, width: 12, height: 12)
        ).fill()
      }
      text(index == 0 ? "备忘录" : "季度数据.numbers", frame.midX - 30, frame.maxY - 22, size: 13)
    }
    // 前面的备忘录：一行一种文字
    let notes = [
      "The quick brown fox jumps over", "敏捷的棕色狐狸跳过了懒狗", "Hello World  #FF4D7E", "日本語のテキスト",
      "Привет мир", "한국어 텍스트", "第七行：截图自检",
    ]
    for (index, line) in notes.enumerated() {
      text(line, 160, 610 - CGFloat(index) * 34, size: 18)
    }
    // 后面的表格：斑马纹行（前面的窗口盖住左上角）+ 一组色块
    let table = windows[1]
    for row in 0..<9 {
      let y = table.maxY - 60 - CGFloat(row) * 38
      if row % 2 == 0 {
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(x: table.minX + 90, y: y - 8, width: 280, height: 34).fill()
      }
      text("Q\(row % 4 + 1)   ¥\(1200 + row * 317)   +\(row * 3)%", table.minX + 100, y, size: 16)
    }
    for (index, color) in [NSColor.systemPink, .systemOrange, .systemTeal, .systemIndigo]
      .enumerated()
    {
      color.setFill()
      let height = CGFloat([150, 90, 200, 120][index])
      NSBezierPath(
        roundedRect: NSRect(
          x: table.maxX - 190 + CGFloat(index) * 42, y: table.minY + 30, width: 30, height: height),
        xRadius: 4, yRadius: 4
      ).fill()
    }
    return try #require(bitmap.cgImage)
  }

  // MARK: 渲染

  private func offscreen(_ view: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: view.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    view.wantsLayer = true
    window.contentView = view
    return window
  }

  /// 只画栏里的内容（按钮、字），垫一块 HUD 深底：macOS 26 起样式托盘、HUD 菜单单独的玻璃在屏外画成一块白，
  /// 看不到里面排成什么样（工具栏两段在玻璃容器里，不受影响）。要在 shoot 之后调（窗口显示过，图层才有内容）
  private func shootContent(_ bar: HUDBar, _ name: String) throws {
    let out = try #require(Self.directory)
    let size = bar.bounds.size
    let scale: CGFloat = 2
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(gray: 0.12, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    let origin = bar.effect.convert(CGPoint.zero, to: bar)
    context.translateBy(x: origin.x, y: origin.y)
    try #require(bar.effect.layer).render(in: context)
    try write(try #require(bitmap.cgImage), to: "\(out)/shot-\(name)-content.png")
  }

  /// 同 SnapshotProbeTests.renderLayers：屏外窗口显示一下、跑几轮 RunLoop，再按 2x 渲染内容视图的图层
  /// （cacheDisplay 画不出直接加的子图层）。prepare 在布局之后跑；crop（点，视图坐标）另存一张局部

  private func shoot(
    _ window: NSWindow, _ name: String, dark: Bool = false, crop: CGRect? = nil,
    prepare: () -> Void = {}
  ) throws {
    let out = try #require(Self.directory)
    let view = try #require(window.contentView)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.orderFront(nil)
    window.layoutIfNeeded()
    prepare()
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let scale: CGFloat = 2
    let size = view.bounds.size
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
    context.scaleBy(x: scale, y: scale)
    try #require(view.layer).render(in: context)
    window.orderOut(nil)
    let image = try #require(bitmap.cgImage)
    let stem = "\(out)/shot-\(name)\(dark ? "-dark" : "")"
    try write(image, to: "\(stem).png")
    guard let crop = crop?.intersection(view.bounds), !crop.isEmpty else { return }
    // 图像行从上往下：y 翻过来
    let pixels = CGRect(
      x: crop.minX * scale, y: (size.height - crop.maxY) * scale, width: crop.width * scale,
      height: crop.height * scale
    ).integral
    try write(try #require(image.cropping(to: pixels)), to: "\(stem)-crop.png")
  }

  // 钉图的透明度滑块（2026-10-03）：右键「透明度 ▸」、悬停圆钮弹出的那一行（60%、最低 10%，浅 / 深色），垫在菜单材质上看对齐
  @Test(.enabled(if: directory != nil)) func renderPinOpacity() throws {
    let out = try #require(Self.directory)
    let board = PinBoard()
    let image = try #require(
      try Self.desktop().cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200)))
    board.pin(image, frame: CGRect(x: -20000, y: -20000, width: 200, height: 100))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    let pin = try #require(panel.contentView)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    for (percent, dark) in [(60, false), (60, true), (10, false)] {
      panel.opacity = CGFloat(percent) / 100
      let row = try #require(
        pin.menu(for: event)?.items.first { $0.title == "透明度" }?.submenu?.items.first?.view)
      // 菜单上下各有约 5 pt 的内边距
      let size = NSSize(width: row.frame.width, height: row.frame.height + 10)
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
      material.material = .menu
      material.state = .active
      row.frame.origin = CGPoint(x: 0, y: 5)
      material.addSubview(row)
      window.contentView = material
      window.orderFront(nil)
      for _ in 0..<3 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
      let bitmap = try #require(material.bitmapImageRepForCachingDisplay(in: material.bounds))
      material.cacheDisplay(in: material.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(filePath: "\(out)/shot-pin-opacity-\(percent)\(dark ? "-dark" : "").png"))
      window.orderOut(nil)
    }

    // 缩放时钉图中央的百分比（和尺寸胶囊同一种小标签：高 26、圆角 6、SF Mono 12 semibold、字离两边约 13）：合成一下滚轮让它
    // 出来（钉图在屏外，跟着放大到 122%）；它 0.7 s 后自己淡出，所以只转两轮就出图
    panel.opacity = 1
    let scroll = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0,
        wheel3: 0
      ).flatMap(NSEvent.init(cgEvent:)))
    pin.scrollWheel(with: scroll)
    pin.layoutSubtreeIfNeeded()
    for _ in 0..<2 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let size = pin.bounds.size
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
    context.scaleBy(x: 2, y: 2)
    try #require(pin.layer).render(in: context)
    try write(try #require(bitmap.cgImage), to: "\(out)/shot-pin-zoom.png")

    for (name, dark) in [("pin-opacity-wheel", false), ("pin-opacity-wheel-mini", true)] {
      if dark {
        panel.setMiniature(true)
        panel.setLocked(true)
      }
      panel.opacity = 0.7
      pin.scrollWheel(with: try pinScrollEvent(-7, option: true))
      #expect(panel.opacityPercent == 35)
      try shoot(panel, name, dark: dark)
      let hud = try #require(pin.subviews.compactMap { $0 as? HUDBar }.first)
      try shootContent(hud, name)
    }
    panel.setFrame(
      CGRect(origin: panel.frame.origin, size: CGSize(width: 58, height: 40)), display: false)
    panel.layoutIfNeeded()
    pin.scrollWheel(with: try pinScrollEvent(1, option: true))
    try shoot(panel, "pin-opacity-wheel-narrow", dark: true)
    let hud = try #require(pin.subviews.compactMap { $0 as? HUDBar }.first)
    try shootContent(hud, "pin-opacity-wheel-narrow")
  }

  /// 屏外渲染贴边缩放前后的钉图，核对普通尺寸与窄图的百分比位置。
  @Test(.enabled(if: directory != nil)) func renderPinFixedScrollZoom() throws {
    let board = PinBoard()
    let desktop = try Self.desktop()
    for (width, height, dark) in [(200, 100, false), (64, 100, true)] {
      let image = try #require(
        desktop.cropping(to: CGRect(x: 0, y: 0, width: width * 2, height: height * 2)))
      let frame = CGRect(x: -20000, y: -20000, width: width, height: height)
      let panel = PinPanel(image: image, frame: frame, board: board)
      let pin = try #require(panel.contentView)
      let point = CGPoint(x: frame.maxX - 3, y: frame.midY)
      let scroll = try pinScrollEvent(20, precise: true, phase: .began, at: point)
      let menu = try #require(pin.menu(for: scroll)?.item(withTitle: "缩放锚点")?.submenu)
      let item = try #require(menu.item(withTitle: "固定最近边"))
      #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
      try shoot(panel, "pin-edge-before", dark: dark)
      pin.scrollWheel(with: scroll)
      #expect(abs(panel.frame.maxX - frame.maxX) <= 0.5)
      #expect(panel.frame.width > frame.width)
      try shoot(panel, "pin-edge-zoom", dark: dark)
      let hud = try #require(pin.subviews.compactMap { $0 as? HUDBar }.first)
      #expect(!hud.isHidden && abs(hud.frame.midX - pin.bounds.midX) <= 0.5)
      try shootContent(hud, dark ? "pin-edge-zoom-dark" : "pin-edge-zoom")
    }
  }

  /// 检查长图跟随、拖动和小面板可读性，以及半透明钉图上实际显示的操作区。
  @Test(.enabled(if: directory != nil)) func renderScrollAndPinAppearance() async throws {
    try renderScrollPositions()
    try await renderPinPictureOpacity()
  }

  /// 使用实际拼接结果渲染定位控件，直接调用控件的本地鼠标入口。
  private func renderScrollPositions() throws {
    let page = try ScreenshotTests.render([
      "The quick brown fox jumps over the lazy dog", "敏捷的棕色狐狸跳过了懒狗", "日本語のテキスト",
      "한국어 텍스트", "Привет мир", "Hello World", "第七行", "第八行",
    ])
    let first = try #require(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 480)))
    let second = try #require(page.cropping(to: CGRect(x: 0, y: 360, width: 400, height: 480)))
    var stitcher = try #require(ScrollStitcher(first: first, scrollbarWidth: 8, maxHeight: 30_000))
    _ = stitcher.add(second)
    #expect(stitcher.outputHeight > first.height)
    for (name, height, dark, drag, sampling) in [
      ("scroll-position-following", 360, false, false, ScrollCapture.Sampling.capturing),
      ("scroll-position-dragging", 260, true, true, .capturing),
      ("scroll-sampling-paused", 260, true, false, .paused),
      ("scroll-sampling-reconnect", 360, false, false, .reconnecting),
    ] {
      let hud = ScrollCaptureHUD()
      hud.frame = CGRect(x: 0, y: 0, width: ScrollCaptureHUD.width, height: CGFloat(height))
      let window = offscreen(hud)
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      hud.layoutSubtreeIfNeeded()
      let control = try #require(firstSubview(ScrollPreviewScrubber.self, in: hud))
      hud.updatePreview(stitcher: stitcher, scale: 2)
      #expect(!control.isHidden && window.canBecomeKey == false)
      hud.onBrowse = { [weak hud] in hud?.updatePreview(stitcher: stitcher, scale: 2) }
      hud.sampling = sampling
      let status = ScrollCapture.status(
        notice: nil, isFull: false, isLost: sampling == .reconnecting, isAutoScrolling: false,
        sampling: sampling)
      hud.show(status.text, tone: status.tone, width: stitcher.width, height: stitcher.outputHeight)
      if drag {
        let point = control.convert(
          CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let event = try #require(
          NSEvent.mouseEvent(
            with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        control.mouseDown(with: event)
        #expect(hud.isScrubbing && hud.browseFrom != nil)
        hud.show("双击预览回到最新", width: stitcher.width, height: stitcher.outputHeight)
      }
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.35))
      let material = try #require(hud.subviews.first)
      // 液态玻璃在屏外会拦下整层绘制，直接读取实际承载控件的内容视图。
      let content: NSView
      if #available(macOS 26, *), let glass = material as? NSGlassEffectView {
        content = try #require(glass.contentView)
      } else {
        content = material
      }
      content.displayIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let out = try #require(Self.directory)
      try write(try #require(bitmap.cgImage), to: "\(out)/shot-\(name)\(dark ? "-dark" : "").png")
    }
  }

  /// 使用同一张钉图核对 100% 与 10% 的画面变化，确保解锁、关闭和透明度按钮清晰可见。
  private func renderPinPictureOpacity() async throws {
    let out = try #require(Self.directory)
    let board = PinBoard()
    let desktop = try Self.desktop()
    let picture = try #require(
      desktop.cropping(to: CGRect(x: 240, y: 450, width: 640, height: 360)))
    board.pin(picture, frame: CGRect(x: -20000, y: -20000, width: 320, height: 180))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    let pin = try #require(panel.contentView)
    panel.finishPopIn()
    panel.setLocked(true)
    let hover = try #require(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        eventNumber: 0, trackingNumber: 0, userData: nil))
    pin.mouseEntered(with: hover)
    let close = try #require(
      firstSubview(NSButton.self, in: pin, matching: { $0.toolTip == "关闭" }))
    for _ in 0..<80 where close.isHiddenOrHasHiddenAncestor {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(180))
    let ancestry = sequence(first: close as NSView, next: { $0.superview }).prefix { $0 !== pin }
    let description = ancestry.map { "\(type(of: $0)) \($0.isHidden) \($0.alphaValue) \($0.frame)" }
    #expect(!close.isHiddenOrHasHiddenAncestor, "\(description)")
    let layer = try #require(pin.layer)
    for (name, percent, key) in [
      ("alpha-100", 100, nil), ("alpha-10", 10, nil),
      ("space-before", 35, nil), ("space-held", 35, NSEvent.EventType.keyDown),
      ("space-released", 35, .keyUp),
    ] {
      panel.opacity = CGFloat(percent) / 100
      if let key {
        #expect(panel.handleOpaquePreviewKey(try pinSpaceEvent(key), ownsKeyboard: true))
      }
      CATransaction.flush()
      let bitmap = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 640,
          pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
      context.scaleBy(x: 2, y: 2)
      context.setFillColor(CGColor(gray: 0.75, alpha: 1))
      context.fill(pin.bounds)
      layer.render(in: context)
      try write(try #require(bitmap.cgImage), to: "\(out)/shot-pin-picture-\(name).png")
      #expect(panel.alphaValue == 1 && !panel.isKeyWindow && close.alphaValue == 1)
      let buttonPoint = close.convert(
        CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: pin.superview)
      let hit = pin.hitTest(buttonPoint)
      #expect(
        hit === close || hit?.isDescendant(of: close) == true,
        "\(String(describing: hit)), \(buttonPoint), \(description)")
    }
  }

  /// 查找真实 AppKit 子视图，用于屏外调用产品控件。
  private func firstSubview<View: NSView>(
    _ type: View.Type, in root: NSView,
    matching: (View) -> Bool = { _ in true }
  ) -> View? {
    if let found = root as? View, matching(found) { return found }
    for child in root.subviews {
      if let found = firstSubview(type, in: child, matching: matching) { return found }
    }
    return nil
  }

  // issue #4：剪贴板里的文字钉成卡片——一行、带缩进的几行代码、超过上限截掉的长段（浅 / 深色，2x）
  @Test(.enabled(if: directory != nil)) func renderPinText() throws {
    let out = try #require(Self.directory)
    let limit = PinBoard.textCardLimit(visible: CGRect(x: 0, y: 0, width: 1440, height: 400))
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      for (name, text) in [
        ("short", "会议室 3F-07，密码 kitty2026"),
        ("code", "func pin(_ text: String) {\n    // 钉到屏幕上\n    board.pin(card(text))\n}"),
        (
          "long",
          String(repeating: "剪贴板里是文字时，把文字排成一张卡片钉在屏幕上。Long English words wrap too. ", count: 30)
        ),
      ] {
        let card = try #require(
          PinBoard.textCard(text, scale: 2, limit: limit, appearance: appearance))
        try write(card, to: "\(out)/shot-pin-text-\(name)\(dark ? "-dark" : "").png")
      }
    }
  }

  /// 识字结果、拼图与条码卡片均在屏外渲染，不打开真实截图会话。
  @Test(.enabled(if: directory != nil)) func renderScreenshotEnhancements() throws {
    let desktop = try Self.desktop()
    let recognition = RecognitionModel()
    recognition.image = desktop
    recognition.accept("项目进度\n第一阶段：识字结果与原图对照\n第二阶段：多张截图拼接与 PDF 导出\n\n请选择需要的文字，按 ⌘C 复制。")
    for dark in [false, true] {
      try enhancement(
        RecognitionResultView(model: recognition), size: NSSize(width: 780, height: 540),
        name: "recognition-result", dark: dark)
    }
    try enhancement(
      ShortcutsSheet(page: .screenshot),
      size: NSSize(width: ShortcutsSheet.width, height: 1200), name: "recognition-shortcuts")
    recognition.accept("")
    try enhancement(
      RecognitionResultView(model: recognition), size: NSSize(width: 780, height: 540),
      name: "recognition-empty")
    recognition.error = "无法完成文字识别，请重新框选后再试"
    try enhancement(
      RecognitionResultView(model: recognition), size: NSSize(width: 780, height: 540),
      name: "recognition-error")
    let composition = ShotCompositionModel()
    composition.preview = desktop
    composition.sources = (1...3).map { index in
      ShotComposition.Source(
        id: UUID(), url: URL(filePath: "/tmp/fixture-\(index).png"),
        size: CGSize(width: desktop.width, height: desktop.height),
        label: "15:30 · 1200 × 800 · 测试窗口 \(index)", thumbnail: desktop)
    }
    for dark in [false, true] {
      try enhancement(
        ShotCompositionView(model: composition), size: NSSize(width: 820, height: 620),
        name: "composition", dark: dark)
    }
    let window = NSWindow(
      contentRect: CGRect(x: -20000, y: -20000, width: 480, height: 300), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 480, height: 300))
    host.wantsLayer = true
    host.layer?.backgroundColor = Style.HUD.solidFill.cgColor
    window.contentView = host
    let card = CodeResultCard(
      code: OCR.Code(text: "https://example.com/docs/kitten?section=tools", box: .zero))
    card.frame = CGRect(x: 60, y: 40, width: 360, height: 220)
    host.addSubview(card)
    card.applyGeometry()
    card.placeContent()
    #expect(card.effect.bounds.width >= 350 && card.effect.bounds.height >= 210)
    card.grow(true)
    try shoot(window, "code-result")
    try shootContent(card, "code-result")
    window.orderOut(nil)
  }

  /// 钉图继续标注的工具栏、演示白板与设置页均使用假桌面和屏外窗口。
  @Test(.enabled(if: directory != nil)) func renderReferenceAndPresentation() throws {
    let desktop = try Self.desktop()
    let suite = "kitty-reference-snapshot-" + UUID().uuidString
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite) }
    prefs.set(true, forKey: Prefs.screenshotShowsCursor)
    prefs.set(false, forKey: Prefs.shotHistory)
    for dark in [false, true] {
      try enhancement(
        ScreenshotTab(shots: nil).defaultAppStorage(prefs).environment(
          SettingsNavigation(defaults: nil)),
        size: NSSize(width: 780, height: 800), name: "screenshot-cursor-settings", dark: dark)
    }
    try enhancement(
      PresentationTab(canvas: PresentationCanvas(), toggle: {}),
      size: NSSize(width: 780, height: 580), name: "presentation-settings")
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 720))
    root.wantsLayer = true
    root.layer?.contents = desktop
    let board = PinBoard()
    let pin = PinPanel(
      image: desktop, frame: CGRect(x: -20000, y: -20000, width: 600, height: 400), board: board)
    let view = try #require(pin.contentView)
    pin.contentView = nil
    view.frame = CGRect(x: 250, y: 190, width: 600, height: 400)
    root.addSubview(view)
    let toolbar = EditorToolbar(mode: .pinShot)
    toolbar.frame.origin = CGPoint(x: 230, y: 130)
    root.addSubview(toolbar)
    toolbar.grow(true)
    try shoot(offscreen(root), "pin-edit-toolbar")
    for (index, hud) in referenceBars(in: toolbar).enumerated() {
      try shootContent(hud, "pin-edit-toolbar-\(index)")
    }
    let zoom = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "z",
        charactersIgnoringModifiers: "z",
        isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)))
    view.keyDown(with: zoom)
    let wheel = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0
      ))
    view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
    try shoot(offscreen(root), "pin-local-zoom")
    for whiteboard in [false, true] {
      let bounds = CGRect(x: 0, y: 0, width: 1000, height: 640)
      let scene = NSView(frame: bounds)
      scene.wantsLayer = true
      scene.layer?.contents = desktop
      let canvas = try #require(RecordingCanvas(region: bounds, label: "演示画布"))
      let bar = RecordingToolsBar(presentation: true)
      defer {
        canvas.close()
        bar.close(animated: false)
      }
      canvas.panel.contentView = nil
      canvas.view.frame = bounds
      scene.addSubview(canvas.view)
      let sceneWindow = offscreen(scene)
      canvas.apply(.mode(.arrow))
      canvas.apply(.color(.red))
      canvas.setWhiteboard(whiteboard)
      for (type, point) in [
        (NSEvent.EventType.leftMouseDown, CGPoint(x: 180, y: 240)),
        (.leftMouseDragged, CGPoint(x: 450, y: 360)), (.leftMouseUp, CGPoint(x: 450, y: 360)),
      ] {
        let event = try #require(
          NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        )
        canvas.view.onMouse(event)
      }
      bar.removeFromSuperview()
      bar.frame.origin = CGPoint(x: 100, y: 40)
      scene.addSubview(bar)
      bar.update(canvas.state, escapes: true)
      bar.setWhiteboard(whiteboard)
      try shoot(sceneWindow, whiteboard ? "presentation-whiteboard" : "presentation-desktop")
      try shootContent(
        try #require(bar.subviews.first as? HUDBar),
        whiteboard ? "presentation-tools-whiteboard" : "presentation-tools-desktop")
    }
  }

  /// 纠错后的工具栏、小卡片与恢复后的钉图使用真实编辑器和原钉图窗口屏外渲染。
  @Test(.enabled(if: directory != nil)) func renderScreenshotWorkflow() throws {
    let desktop = try Self.desktop()
    for dark in [false, true] {
      let model = RecognitionModel()
      model.image = desktop
      model.accept("会议时间：周三 14:O0\n请核对文字后再复制。")
      try enhancement(
        RecognitionResultView(model: model), size: NSSize(width: 780, height: 540),
        name: "recognition-edited", dark: dark
      ) { host in
        if let text = self.recognitionEditor(in: host) {
          text.insertText("0", replacementRange: NSRange(location: 11, length: 1))
          text.breakUndoCoalescing()
          text.setSelectedRange(NSRange(location: 6, length: 6))
        }
      }
      #expect(model.isEdited && model.canUndo)
    }
    let board = PinBoard()
    let pin = PinPanel(
      image: desktop, frame: CGRect(x: -20000, y: -20000, width: 600, height: 400), board: board)
    defer { pin.orderOut(nil) }
    pin.setMiniature(true)
    try shoot(pin, "pin-miniature")
    pin.setMiniature(false)
    try shoot(pin, "pin-expanded")
  }

  /// 用 Vision 实际识别合成表格，再经原生选区和实际像素按钮核对原图滚动。
  @Test(.enabled(if: directory != nil)) func renderRecognitionLocations() async throws {
    for (rows, row, zoom, name) in [
      (12, 7, false, "recognition-location-table"), (46, 42, true, "recognition-location-long"),
    ] {
      let image = try recognitionTable(rows: rows)
      let lines = try await OCR.inspectLines(in: image)
      let expected = String(format: "ORD-%04d", row)
      let index = try #require(lines.firstIndex { $0.text.contains(expected) })
      let box = lines[index].box
      let rowCenter = 1 - (CGFloat(row - 1) * 42 + 45) / CGFloat(image.height)
      #expect(abs(box.midY - rowCenter) < 20 / CGFloat(image.height))
      let model = RecognitionModel()
      model.image = image
      model.accept(lines: lines)
      try enhancement(
        RecognitionResultView(model: model),
        size: NSSize(width: zoom ? 700 : 780, height: zoom ? 460 : 540), name: name, dark: zoom
      ) { host in
        let editor = try #require(recognitionEditor(in: host))
        let match = (editor.string as NSString).range(of: expected)
        try #require(match.location != NSNotFound)
        editor.setSelectedRange(match)
        editor.scrollRangeToVisible(match)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.12))
        #expect(
          model.location == .init(line: index + 1, box: box) && host.window?.isKeyWindow == false)
        if zoom {
          let action = try #require(compositionButton(in: host, label: "实际像素"))
          #expect(action() == true)
          RunLoop.main.run(until: Date.now.addingTimeInterval(0.28))
          let imageScroll = try #require(
            firstSubview(
              NSScrollView.self, in: host,
              matching: {
                $0 !== editor.enclosingScrollView
                  && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height
              }))
          #expect(imageScroll.contentView.bounds.minY > 400)
          #expect(compositionButton(in: host, label: "适合窗口") != nil)
          let nearTop = (editor.string as NSString).range(of: "ORD-0002")
          try #require(nearTop.location != NSNotFound)
          editor.setSelectedRange(nearTop)
          RunLoop.main.run(until: Date.now.addingTimeInterval(0.16))
          #expect(imageScroll.contentView.bounds.minY < 150)
          editor.setSelectedRange(match)
          editor.scrollRangeToVisible(match)
          RunLoop.main.run(until: Date.now.addingTimeInterval(0.16))
          #expect(imageScroll.contentView.bounds.minY > 400)
        }
      }
    }
  }

  /// 绘制一张可由 Vision 实际识别的小字表格，行号和列位置可验证且没有用户内容。
  private func recognitionTable(rows: Int) throws -> CGImage {
    let width = 1180
    let height = rows * 42 + 46
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width,
        pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let headerY = height - 27
    let label: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .medium),
      .foregroundColor: NSColor.black,
    ]
    for (x, title) in [(28, "ORDER NUMBER"), (420, "PICKUP WINDOW"), (842, "PACKAGE STATUS")] {
      NSAttributedString(string: title, attributes: label).draw(at: CGPoint(x: x, y: headerY))
    }
    for row in 1...rows {
      let y = height - 42 * row - 25
      if row.isMultiple(of: 2) {
        NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1).setFill()
        NSRect(x: 0, y: y - 6, width: width, height: 41).fill()
      }
      let order = String(format: "ORD-%04d", row)
      NSAttributedString(string: order, attributes: label).draw(at: CGPoint(x: 28, y: y))
      NSAttributedString(string: "09:30 - 10:15", attributes: label).draw(at: CGPoint(x: 420, y: y))
      NSAttributedString(string: row.isMultiple(of: 3) ? "Packed" : "Pending", attributes: label)
        .draw(at: CGPoint(x: 842, y: y))
    }
    return try #require(bitmap.cgImage)
  }

  /// 图片导入与锁定钉图在假数据、屏外窗口中检查空态、长文件名、失败与浅深色。
  @Test(.enabled(if: directory != nil)) func renderImageImport() throws {
    let desktop = try Self.desktop()
    for dark in [false, true] {
      let empty = ShotCompositionModel()
      try enhancement(
        ShotCompositionView(model: empty), size: NSSize(width: 820, height: 620),
        name: "image-import-empty", dark: dark)
      let populated = ShotCompositionModel()
      populated.preview = desktop
      populated.sources = (1...5).map { index in
        ShotComposition.Source(
          id: UUID(), url: URL(filePath: "/tmp/fixture-\(index).png"),
          size: CGSize(width: 1200, height: 800),
          label: index == 1 ? "设计评审-第3版-包含非常长文件名的原始截图-2026年11月.png" : "参考图片 \(index).png",
          thumbnail: desktop)
      }
      try enhancement(
        ShotCompositionView(model: populated), size: NSSize(width: 820, height: 620),
        name: "image-import-populated", dark: dark)
      populated.error = "图片无法读取，原列表与预览保持不变。请检查文件是否完整及格式是否受支持。"
      try enhancement(
        ShotCompositionView(model: populated), size: NSSize(width: 720, height: 520),
        name: "image-import-error-compact", dark: dark)
    }
    let board = PinBoard()
    let pin = PinPanel(
      image: desktop, frame: CGRect(x: -20000, y: -20000, width: 600, height: 400), board: board)
    defer { pin.orderOut(nil) }
    pin.setLocked(true)
    let view = try #require(pin.contentView)
    let hover = try #require(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    try shoot(pin, "pin-locked") { view.mouseEntered(with: hover) }
    for (index, hud) in referenceBars(in: view).enumerated() {
      try shootContent(hud, "pin-locked-controls-\(index)")
    }
  }

  /// 新工具栏、尺寸读数及旋转后的文字使用假图屏外渲染，绝不打开真实遮罩。
  @Test(.enabled(if: directory != nil)) func renderAnnotationEnhancements() async throws {
    let desktop = try Self.desktop()
    try enhancement(
      ShortcutsSheet(page: .screenshot), size: NSSize(width: ShortcutsSheet.width, height: 1200),
      name: "annotation-shortcuts")
    for (name, query) in [("erase", "橡皮擦"), ("dimension", "尺寸"), ("transform", "镜像")] {
      try enhancement(
        ShortcutsSheet(page: .screenshot, query: query),
        size: NSSize(width: ShortcutsSheet.width, height: 520), name: "annotation-shortcuts-" + name
      )
    }
    let h = Harness(image: desktop)
    h.view.select(CGRect(x: 120, y: 160, width: 900, height: 500))
    h.view.annotations = [
      Annotation(
        shape: .line(from: CGPoint(x: 260, y: 360), to: CGPoint(x: 780, y: 360)),
        style: .init(color: .red, option: 1)),
      Annotation(
        shape: .text("尺寸随端点实时更新", origin: CGPoint(x: 300, y: 510)),
        style: .init(color: .white, option: 2)),
    ]
    h.move(CGPoint(x: 1100, y: 740))
    try shoot(h.window, "annotation-dimension")
    h.view.tool = .line
    let option = try #require(annotationOption(in: h.view, title: "尺寸（px）"))
    let action = try #require(option.action)
    #expect(NSApp.sendAction(action, to: option.target, from: option))
    #expect(h.view.style.option == 1)
    h.move(CGPoint(x: 1100, y: 740))
    try shoot(h.window, "annotation-dimension-tray")
    if let tray = h.styleBar { try shootContent(tray, "annotation-dimension-tray") }
    h.key(kVK_ANSI_E, "e")
    try shoot(h.window, "annotation-eraser")
    if let toolbar = h.view.subviews.compactMap({ $0 as? EditorToolbar }).first {
      for (index, hud) in referenceBars(in: toolbar).enumerated() {
        try shootContent(hud, "annotation-tools-\(index)")
      }
    }
    let editor = AnnotateOverlay(image: desktop, scale: 1, strictOutput: true) { _, _, _, _ in }
    defer { editor.close() }
    editor.panel.setFrameOrigin(CGPoint(x: -20000, y: -20000))
    try #require(editor.panel.frame.maxX < 0 && editor.panel.frame.maxY < 0)
    try shoot(editor.panel, "image-transform-editor")
    if let root = editor.panel.contentView {
      for (index, hud) in referenceBars(in: root).enumerated() {
        try shootContent(hud, "image-transform-tools-\(index)")
      }
    }
    let canvas = ScrollCanvas(image: desktop, scale: 1)
    canvas.annotations = [
      Annotation(
        shape: .text("文字仍然可以编辑", origin: CGPoint(x: 180, y: 500)),
        style: .init(color: .white, option: 2))
    ]
    canvas.transform(.right)
    for _ in 0..<250 where canvas.isTransforming { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!canvas.isTransforming)
    try shoot(offscreen(canvas), "image-transformed-text")
    canvas.cancelTransform()
  }

  /// 屏外核对普通宽度和靠屏边的窄窗口中，混排序号及托盘的选中状态。
  @Test(.enabled(if: directory != nil)) func renderCounterFormats() throws {
    let desktop = try Self.desktop()
    for (width, dark) in [(CGFloat(1200), false), (CGFloat(800), true)] {
      let h = Harness(image: desktop)
      h.window.setContentSize(CGSize(width: width, height: 620))
      h.view.frame.size = CGSize(width: width, height: 620)
      let area = CGRect(x: width - 412, y: 160, width: 400, height: 370)
      h.view.select(area)
      let counters = [(7, 0), (26, 1), (27, 1)].enumerated().map { index, value in
        Annotation(
          shape: .counter(
            value.0, center: CGPoint(x: area.minX + 60 + CGFloat(index) * 65, y: area.midY)),
          style: .init(color: .blue, option: value.1))
      }
      h.view.annotations = counters
      h.view.selectedAnnotation = counters.last?.id
      h.move(CGPoint(x: width - 12, y: 600))
      let tray = try #require(h.styleBar)
      #expect(tray.frame.minX >= 0 && tray.frame.maxX <= width)
      let name = "counter-formats-\(Int(width))"
      try shoot(h.window, name, dark: dark, crop: area.union(barsFrame(h)).insetBy(dx: -8, dy: -8))
      try shootContent(tray, name)
    }
  }

  /// 多选框、混合托盘与关联说明用假桌面屏外渲染，两个画布沿用同一套选中外观。
  @Test(.enabled(if: directory != nil)) func renderAnnotationGroups() async throws {
    let desktop = try Self.desktop()
    let h = Harness(image: desktop)
    h.view.select(CGRect(x: 120, y: 160, width: 900, height: 500))
    var arrow = Annotation(
      shape: .arrow(from: CGPoint(x: 300, y: 370), to: CGPoint(x: 760, y: 370)),
      style: .init(color: .red))
    arrow.caption = .init(text: "请求返回后更新列表", style: arrow.captionStyle)
    let rectangle = Annotation(
      shape: .rectangle(CGRect(x: 300, y: 210, width: 230, height: 100)),
      style: .init(color: .blue))
    h.view.annotations = [arrow, rectangle]
    h.view.selectAnnotations([arrow.id, rectangle.id])
    h.move(CGPoint(x: 1100, y: 740))
    try shoot(h.window, "annotation-group-mixed")
    if let tray = h.styleBar { try shootContent(tray, "annotation-group-mixed") }
    if let toolbar = h.view.subviews.compactMap({ $0 as? EditorToolbar }).first {
      for (index, hud) in referenceBars(in: toolbar).enumerated() {
        try shootContent(hud, "annotation-group-tools-\(index)")
      }
    }
    h.view.selectAnnotations([])
    h.begin(CGPoint(x: 240, y: 185), to: CGPoint(x: 800, y: 460), flags: .command)
    try shoot(h.window, "annotation-group-marquee")
    h.release(CGPoint(x: 800, y: 460), flags: .command)
    h.view.selectedAnnotation = arrow.id
    let bar = try #require(h.view.subviews.compactMap { $0 as? EditorToolbar }.first)
    let button = try #require(bar.button(for: .caption))
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    try shoot(h.window, "annotation-caption-edit")
    let field = try #require(h.view.subviews.compactMap { $0 as? EditorField }.first)
    #expect(field.frame.width > 100 && field.frame.height >= 20)
    _ = h.view.textView(field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    try shoot(h.window, "annotation-caption-selected")
    let canvas = ScrollCanvas(image: desktop, scale: 2)
    let suite = "kitty-group-snapshot-" + UUID().uuidString
    canvas.styleDefaults = try #require(UserDefaults(suiteName: suite))
    defer { canvas.styleDefaults.removePersistentDomain(forName: suite) }
    canvas.annotations = [arrow, rectangle]
    canvas.selectAnnotations([arrow.id, rectangle.id])
    let window = offscreen(canvas)
    for child in canvas.subviews { child.wantsLayer = true }
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }
    try shoot(window, "annotation-group-canvas")
    canvas.transform(.right)
    for _ in 0..<250 where canvas.isTransforming { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!canvas.isTransforming)
    window.setContentSize(canvas.frame.size)
    canvas.selectedAnnotation = arrow.id
    try shoot(window, "annotation-caption-rotated")
    canvas.editCaption()
    try shoot(window, "annotation-caption-canvas-edit")
    let canvasField = try #require(canvas.subviews.compactMap { $0 as? EditorField }.first)
    #expect(canvasField.frame.width > 100 && canvasField.string == arrow.caption?.text)
    canvas.endEditing()
    for dark in [false, true] {
      try enhancement(
        ShortcutsSheet(page: .screenshot, query: "标注"),
        size: NSSize(width: ShortcutsSheet.width, height: 1000),
        name: "annotation-group-shortcuts", dark: dark)
    }
  }

  /// 查看标注剪贴板的工具栏、启用和禁用菜单项，以及窄屏的最终摆放。
  @Test(.enabled(if: directory != nil)) func renderAnnotationClipboard() throws {
    let desktop = try Self.desktop()
    let clipboard = AnnotationClipboard()
    for dark in [false, true] {
      let h = Harness(image: desktop)
      let size = CGSize(width: dark ? 860 : 1200, height: dark ? 620 : 800)
      h.window.setContentSize(size)
      h.view.frame.size = size
      h.view.select(CGRect(x: 70, y: 210, width: 620, height: 340))
      h.view.annotationClipboard = clipboard
      let mark = Annotation(
        shape: .arrow(from: CGPoint(x: 180, y: 320), to: CGPoint(x: 325, y: 400)))
      if dark {
        _ = clipboard.copy([mark])
      } else {
        h.view.annotations = [mark]
        h.view.selectAnnotations([mark.id])
      }
      let toolbar = try #require(h.toolbar)
      let button = try #require(toolbar.button(for: .annotationClipboard))
      button.performClick(nil)
      let menu = try #require(h.menu)
      #expect(h.view.bounds.contains(toolbar.frame) && h.view.bounds.contains(menu.frame))
      try shoot(h.window, "annotation-clipboard", dark: dark)
      try shootContent(menu, dark ? "annotation-clipboard-dark" : "annotation-clipboard")
      for (index, bar) in referenceBars(in: toolbar).enumerated() {
        try shootContent(bar, "annotation-clipboard-bar-\(index)\(dark ? "-dark" : "")")
      }
      let output = try #require(toolbar.button(for: .output(.copy)))
      #expect(h.view.bounds.contains(output.convert(output.bounds, to: h.view)))
      if dark {
        h.pick("粘贴标注")
        #expect(h.view.selectedItems.count == 1)
        try shoot(h.window, "annotation-clipboard-pasted", dark: true)
      }
    }
  }

  /// 原位选字使用系统真实分析与合成桌面，在非 key 屏外窗口查看选择层及局部放大。
  @Test(.enabled(if: directory != nil)) func renderPinSelection() async throws {
    let desktop = try Self.desktop()
    let board = PinBoard()
    let pin = PinPanel(
      image: desktop, frame: CGRect(x: -20000, y: -20000, width: 1200, height: 800), board: board)
    let view = try #require(pin.contentView)
    let selecting = try #require(pin.textSelection)
    pin.contentView = NSView()
    let window = offscreen(view)
    defer {
      selecting.stop()
      window.contentView = nil
      window.orderOut(nil)
    }
    selecting.onCopy = { _ in Issue.record("截图自检不应复制文字") }
    selecting.open(desktop)
    for _ in 0..<300 where selecting.state == .loading {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(selecting.state == .ready && !window.isKeyWindow)
    let text = selecting.overlay.text
    let range = try #require(text.range(of: "Hello"))
    selecting.overlay.selectedRanges = [range]
    try shoot(window, "pin-text-selection")
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
    )
    let zoom = try #require(view.menu(for: event)?.items.first { $0.title == "局部放大" })
    #expect(NSApp.sendAction(try #require(zoom.action), to: zoom.target, from: zoom))
    let scroll = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0
      ))
    scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    try shoot(window, "pin-text-local-zoom")
    try enhancement(
      ShortcutsSheet(page: .screenshot, query: "原位"),
      size: NSSize(width: ShortcutsSheet.width, height: 700), name: "pin-text-shortcuts")
  }

  /// 平铺水印与参数菜单从真实工具栏进入，检查截图和整图两个画布的最终渲染。
  @Test(.enabled(if: directory != nil)) func renderWatermark() throws {
    let desktop = try Self.desktop()
    let h = Harness(image: desktop)
    h.view.select(CGRect(x: 120, y: 160, width: 900, height: 500))
    let bar = try #require(h.view.subviews.compactMap { $0 as? EditorToolbar }.first)
    let add = try #require(bar.button(for: .watermark))
    #expect(NSApp.sendAction(try #require(add.action), to: add.target, from: add))
    let field = try #require(h.fieldEditor)
    field.insertText(
      "仅供评审 · 不公开",
      replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
    try shoot(h.window, "watermark-edit")
    h.key(kVK_Escape, "")
    try shoot(h.window, "watermark-selected")
    let tray = try #require(h.styleBar)
    try shootContent(tray, "watermark-tray")
    let angle = try #require(
      Self.descendants(of: tray).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == "水印角度"
      })
    #expect(NSApp.sendAction(try #require(angle.action), to: angle.target, from: angle))
    try shoot(h.window, "watermark-angle-menu")
    try shootContent(try #require(h.menu), "watermark-angle-menu")
    let currentMenu = try #require(h.menu)
    let row = try #require(
      Self.descendants(of: currentMenu).first { $0.accessibilityLabel() == "-45°" })
    #expect(row.accessibilityPerformPress())
    try shoot(h.window, "watermark-tilted")
    let canvas = ScrollCanvas(image: desktop, scale: 2)
    canvas.annotations = h.view.annotations
    canvas.selectedAnnotation = canvas.annotations.first?.id
    let window = offscreen(canvas)
    for child in canvas.subviews { child.wantsLayer = true }
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }
    try shoot(window, "watermark-canvas")
    try enhancement(
      ShortcutsSheet(page: .screenshot, query: "水印"),
      size: NSSize(width: ShortcutsSheet.width, height: 700), name: "watermark-shortcuts",
      dark: true)
  }

  /// PDF 页框、翻页按钮、透明拼图及圆角在实际预览上检查，文件只写本次临时目录。
  @Test(.enabled(if: directory != nil)) func renderCompositionOutput() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-output-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    var urls: [URL] = []
    for (index, rect) in [
      CGRect(x: 0, y: 0, width: 1800, height: 1000), CGRect(x: 200, y: 0, width: 600, height: 1500),
      CGRect(x: 400, y: 400, width: 900, height: 700),
    ].enumerated() {
      let url = folder.appending(
        path: index == 0 ? "设计评审-包含长文件名的第一张参考图.png" : "参考图-\(index + 1).png")
      try write(try #require(desktop.cropping(to: rect)), to: url.path)
      urls.append(url)
    }
    model.importFiles(urls)
    try await waitForComposition(model)
    model.pdf = true
    model.options.paper = .a4
    model.refreshPreview()
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-a4-portrait")
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-pdf-switching"
    ) { host in
      let button = compositionButton(in: host, label: "下一页")
      #expect(button != nil)
      #expect(button?() == true)
      #expect(model.previewPage == 1)
    }
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-a4-second-page", dark: true)
    model.options.orientation = .landscape
    model.options.pdfMargin = 40
    model.refreshPreview()
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-a4-landscape-compact")
    model.pdf = false
    model.options.layout = .grid
    model.options.background = .transparent
    model.options.cornerRadius = 32
    model.refreshPreview()
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-transparent")
    model.options.background = .mint
    model.options.cornerRadius = 64
    model.refreshPreview()
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-mint-compact", dark: true)
  }

  /// 单张调整、裁剪草稿与输出宽度使用真实文件和预览，在屏外核对应用按钮和最终图像。
  @Test(.enabled(if: directory != nil)) func renderCompositionAdjustments() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-edit-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    var urls: [URL] = []
    for (index, rect) in [
      CGRect(x: 0, y: 0, width: 1800, height: 1000), CGRect(x: 100, y: 0, width: 600, height: 1500),
    ].enumerated() {
      let url = folder.appending(path: index == 0 ? "项目设计评审-需要单独裁剪的第一张参考图.png" : "第二张竖图.png")
      try write(try #require(desktop.cropping(to: rect)), to: url.path)
      urls.append(url)
    }
    model.importFiles(urls)
    try await waitForComposition(model)
    let id = try #require(model.sources.first?.id)
    model.options.widthMode = .custom
    model.options.customWidth = 1001
    model.rotate(id, by: 1)
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-single-rotated")
    model.beginCrop(id)
    for _ in 0..<300 where model.cropDraft == nil && model.error == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    let draft = try #require(model.cropDraft)
    draft.selection = CGRect(x: 0.15, y: 0.2, width: 0.65, height: 0.6)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-crop-draft")
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-crop-compact", dark: true)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-crop-applying"
    ) { host in
      let action = compositionButton(in: host, label: "应用裁剪")
      #expect(action != nil && action?() == true)
      #expect(model.cropTarget == nil)
    }
    try await waitForComposition(model)
    #expect(model.sources[0].edit != .init())
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-crop-applied", dark: true)
    model.pdf = true
    model.options.paper = .a4
    model.refreshPreview()
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-crop-pdf")
    model.pdf = false
    model.restore(id)
    model.options.customWidth = 8192
    model.refreshPreview()
    try await waitForComposition(model)
    #expect(model.outputPlan?.isLimited == true)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-width-limited")
  }

  /// 核对「自动」与手动列数在不同面板尺寸的选中状态及对应网格。
  @Test(.enabled(if: directory != nil)) func renderCompositionGridColumns() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-grid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let urls = try (0..<6).map { index in
      let url = folder.appending(path: "参考图-\(index + 1).png")
      let area = CGRect(x: 120 + index * 240, y: 420, width: 610, height: 460)
      try write(try #require(desktop.cropping(to: area)), to: url.path)
      return url
    }
    model.options.layout = .grid
    model.importFiles(urls)
    try await waitForComposition(model)
    let order = model.sources.map(\.id)
    #expect(model.preview.map { $0.width > $0.height } == true)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-grid-automatic")
    model.options.gridColumns = 2
    model.refreshPreview()
    try await waitForComposition(model)
    #expect(model.preview.map { $0.width < $0.height } == true)
    #expect(model.sources.map(\.id) == order)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-grid-manual", dark: true)
    for source in model.sources.dropFirst() { model.remove(source.id) }
    try await waitForComposition(model)
    #expect(model.options.gridColumns == 2)
    #expect(try #require(model.outputPlan).frames.count == 1)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-grid-fewer-images", dark: true)
  }

  /// 核对 PDF 默认质量、小体积说明及由真实导出结果提供的文件大小。
  @Test(.enabled(if: directory != nil)) func renderCompositionPDFQuality() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-pdf-quality-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let urls = try (0..<2).map { index in
      let url = folder.appending(path: "项目核对-第\(index + 1)页.png")
      let area = CGRect(x: 200 + index * 440, y: 80, width: 1540, height: 920)
      try write(try #require(desktop.cropping(to: area)), to: url.path)
      return url
    }
    model.pdf = true
    model.importFiles(urls)
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-pdf-standard")
    model.options.pdfQuality = .compact
    model.refreshPreview()
    try await waitForComposition(model)
    let output = folder.appending(path: "项目核对-长文件名多页截图合集.pdf")
    let result = try await ShotComposition.export(
      model.sources, options: model.options, pdf: true, to: output)
    model.recordExportedDocument(output, pdfResult: result)
    #expect(model.exportedPDF?.bytes == Int64(try Data(contentsOf: output).count))
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-pdf-compact", dark: true)
    model.showPage(1)
    try await waitForComposition(model)
    #expect(model.exportedPDF?.bytes == result.bytes)
    model.refreshPreview()
    #expect(model.exported == nil && model.exportedPDF == nil)

    model.clear()
    let solid = try ScreenshotTests.image(size: 100) { context in
      context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    }
    let solidURL = folder.appending(path: "纯色.png")
    try write(solid, to: solidURL.path)
    model.importFiles([solidURL, solidURL])
    try await waitForComposition(model)
    let smallOutput = folder.appending(path: "纯色测试.pdf")
    let kept = try await ShotComposition.export(
      model.sources, options: model.options, pdf: true, to: smallOutput)
    #expect(kept.keptStandardPDF)
    model.recordExportedDocument(smallOutput, pdfResult: kept)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-pdf-smaller-standard", dark: true)
  }

  /// 核对插入线和撤销按钮在面板中的最终位置，调用真实的本进程按钮动作。
  @Test(.enabled(if: directory != nil)) func renderCompositionHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-order-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let urls = try (0..<3).map { index in
      let name = index == 0 ? "项目评审-较长文件名排序与撤销核对.png" : "参考图-\(index).png"
      let url = folder.appending(path: name)
      let box = CGRect(x: index * 360, y: 0, width: 760, height: 520)
      try write(try #require(desktop.cropping(to: box)), to: url.path)
      return url
    }
    model.pdf = true
    model.importFiles(urls)
    try await waitForComposition(model)
    let order = model.sources.map(\.id)
    model.showPage(2)
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-reorder-insertion"
    ) { host in
      try compositionDrag(in: host, from: order[2], to: order[0], commit: false)
      #expect(model.reorderInsertion == .init(anchor: order[0], before: true))
      #expect(model.sources.map(\.id) == order && host.window?.isKeyWindow == false)
    }
    model.cancelReorder()
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-reorder-commit"
    ) { host in
      try compositionDrag(in: host, from: order[2], to: order[0], commit: true)
      #expect(model.sources.first?.id == order[2] && model.previewPage == 0)
    }
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-reorder-undo"
    ) { host in
      let action = compositionButton(in: host, label: "撤销拼图编辑")
      #expect(action != nil && action?() == true)
      #expect(model.sources.map(\.id) == order && model.previewPage == 2)
    }
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-reorder-redo", dark: true
    ) { host in
      let action = compositionButton(in: host, label: "重做拼图编辑")
      #expect(action != nil && action?() == true)
      #expect(model.sources.first?.id == order[2] && model.previewPage == 0)
    }
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-reorder-compact", dark: true)
  }

  /// 将构造的鼠标序列直接交给屏外原生缩略图，不向系统事件队列发送事件。
  private func compositionDrag(in host: NSView, from: UUID, to: UUID, commit: Bool) throws {
    let source = try #require(compositionGrip(in: host, id: from))
    let target = try #require(compositionGrip(in: host, id: to))
    let start = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
    let end = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY - 8), to: nil)
    source.mouseDown(with: try compositionMouse(.leftMouseDown, at: start, in: host))
    source.mouseDragged(with: try compositionMouse(.leftMouseDragged, at: end, in: host))
    if commit { source.mouseUp(with: try compositionMouse(.leftMouseUp, at: end, in: host)) }
  }

  /// 构造仅供本进程视图直接调用的 AppKit 输入事件。
  private func compositionMouse(_ type: NSEvent.EventType, at point: CGPoint, in host: NSView)
    throws -> NSEvent
  {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: host.window?.windowNumber ?? 0, context: nil, eventNumber: 1,
        clickCount: 1, pressure: 1))
  }

  /// 用具名拖放剪贴板驱动真实 AppKit 接收视图，并检查悬停、拒绝、替换和撤销后的画面。
  @Test(.enabled(if: directory != nil)) func renderCompositionReplacementDrop() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-replacement-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    let pasteboard = NSPasteboard(name: .init("kitty-composition-drop-\(UUID().uuidString)"))
    defer {
      model.clear()
      pasteboard.releaseGlobally()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let urls = try ["截图-初稿", "截图-仅对照", "截图-修订稿"].enumerated().map { index, name in
      let url = folder.appending(path: name + ".png")
      let rect = CGRect(x: index * 460, y: 0, width: 520 + index * 80, height: 460)
      try write(try #require(desktop.cropping(to: rect)), to: url.path)
      return url
    }
    model.pdf = true
    model.importFiles(Array(urls.prefix(2)))
    try await waitForComposition(model)
    let original = try #require(model.sources.first)
    let order = model.sources.map(\.id)
    model.rotate(original.id, by: 1)
    try await waitForComposition(model)

    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-replacement-hover"
    ) { host in
      let target = try #require(compositionGrip(in: host, id: original.id))
      let other = try #require(compositionGrip(in: host, id: order[1]))
      let drop = CompositionDrop(pasteboard: pasteboard)
      #expect(target.registeredDraggedTypes.contains(.fileURL))
      pasteboard.clearContents()
      #expect(pasteboard.writeObjects([urls[1] as NSURL, urls[2] as NSURL]))
      #expect(target.draggingEntered(drop).isEmpty && !target.performDragOperation(drop))
      pasteboard.clearContents()
      #expect(pasteboard.writeObjects([urls[2] as NSURL]))
      drop.draggingSourceOperationMask = .move
      #expect(target.draggingUpdated(drop).isEmpty)
      drop.draggingSourceOperationMask = .copy
      #expect(other.draggingEntered(drop) == .copy && other.replacementTargeted)
      other.draggingExited(drop)
      #expect(!other.replacementTargeted)
      #expect(target.draggingEntered(drop) == .copy && target.replacementTargeted)
      #expect(!model.preparing && model.sources.map(\.id) == order)
      #expect(target.window?.isKeyWindow == false)
    }
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-replacement-drop", dark: true
    ) { host in
      let target = try #require(compositionGrip(in: host, id: original.id))
      let drop = CompositionDrop(pasteboard: pasteboard)
      #expect(target.draggingEntered(drop) == .copy && target.prepareForDragOperation(drop))
      #expect(target.performDragOperation(drop) && !target.replacementTargeted)
    }
    try await waitForComposition(model)
    #expect(model.sources.map(\.id) == order && model.previewSourceID == original.id)
    #expect(model.sources.first?.label == urls[2].lastPathComponent && model.canUndoEdit)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-replacement-result", dark: true)
    model.undoEdit()
    #expect(model.sources.first?.url == original.url && model.sources.first?.edit.turns == 1)
  }

  /// 真实滚动容器在指针停在边缘时继续移动，直到第 12 张可作为落点。
  @Test(.enabled(if: directory != nil)) func renderCompositionEdgeScroll() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-scroll-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let url = folder.appending(path: "参考图.png")
    let pixels = try #require(
      Self.desktop().cropping(to: CGRect(x: 0, y: 0, width: 760, height: 520)))
    try write(pixels, to: url.path)
    let original = try await ShotComposition.source(id: UUID(), url: url, label: "参考图")
    model.sources = (1...12).map { index in
      ShotComposition.Source(
        id: UUID(), url: original.url, size: original.size, label: "参考图 \(index).png",
        thumbnail: original.thumbnail)
    }
    model.pdf = true
    model.showPage(0)
    try await waitForComposition(model)
    let size = NSSize(width: 820, height: 620)
    let host = NSHostingView(
      rootView: ShotCompositionView(model: model)
        .frame(width: size.width, height: size.height).background(
          Color(nsColor: .windowBackgroundColor)))
    host.frame = CGRect(origin: .zero, size: size)
    let window = offscreen(host)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(200))
    let order = model.sources.map(\.id)
    let grip = try #require(compositionGrip(in: host, id: order[0]))
    let scroll = try #require(grip.enclosingScrollView)
    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
    let center = CGPoint(x: grip.bounds.midX, y: grip.bounds.midY)
    let start = grip.convert(center, to: nil)
    let edge = CGPoint(x: start.x, y: clip.minY + 10)
    #expect(clip.contains(start) && window.canBecomeKey == false)
    grip.mouseDown(with: try compositionMouse(.leftMouseDown, at: start, in: host))
    grip.mouseDragged(with: try compositionMouse(.leftMouseDragged, at: edge, in: host))
    let target = ShotCompositionInsertion(anchor: order[11], before: false)
    for _ in 0..<200 where model.reorderInsertion != target {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(150))
    #expect(grip.convert(center, to: nil).y > start.y + 80)
    #expect(model.reorderInsertion == target && model.sources.map(\.id) == order)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let out = try #require(Self.directory)
    try write(try #require(bitmap.cgImage), to: "\(out)/shot-composition-reorder-scroll.png")
    grip.mouseUp(with: try compositionMouse(.leftMouseUp, at: edge, in: host))
    #expect(model.sources.last?.id == order[0] && model.previewPage == 11 && model.canUndoEdit)
  }

  /// 通过稳定图片身份定位渲染出来的 AppKit 鼠标目标。
  private func compositionGrip(in view: NSView, id: UUID) -> ShotCompositionDragView? {
    if let grip = view as? ShotCompositionDragView, grip.id == id { return grip }
    return view.subviews.lazy.compactMap { compositionGrip(in: $0, id: id) }.first
  }

  /// 屏外调用标签表单和筛选的实际按钮，核对待提交、筛选结果和最窄历史窗。
  @Test(.enabled(if: directory != nil)) func renderShotHistoryTags() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-history-tag-shots-\(UUID())")
    let history = try ShotHistory(db: Database(path: ":memory:"), directory: root)
    let preferenceDomain = "kitty-history-tag-shots-pref-\(UUID())"
    let prefs = try #require(UserDefaults(suiteName: preferenceDomain))
    prefs.set(true, forKey: Prefs.shotHistory)
    history.defaults = prefs
    defer {
      prefs.removePersistentDomain(forName: preferenceDomain)
      try? FileManager.default.removeItem(at: root)
    }
    let page = try Self.desktop()
    let first = try #require(await history.record(page, scale: 2, source: "Safari"))
    let secondImage = try #require(
      page.cropping(to: CGRect(x: 120, y: 100, width: 1200, height: 700)))
    let second = try #require(
      await history.record(secondImage, scale: 2, kind: .scroll, source: "终端"))
    let other = try #require(await history.record(secondImage, scale: 2, source: "便签"))
    try history.applyTags(to: [first], adding: ["项目验收", "用于下次发布的多个主题和界面细节对照"], removing: [])
    try history.applyTags(to: [second], adding: ["跟进"], removing: [])
    try history.applyTags(to: [other], adding: ["个人"], removing: [])
    for id in [first, second] {
      let item = try #require(history.item(id))
      _ = try #require(await ShotThumbnails.shared.image(for: item, in: history))
    }
    defer { for id in [first, second] { ShotThumbnails.shared.forget(id) } }
    let model = ShotHistoryModel(history: history)
    model.pick(first)
    model.toggle(second)
    let edit = ShotTagEdit(items: model.chosen)
    let editor = ShotHistoryTagEditor(edit: edit) { ids, adding, removing in
      try model.applyTags(ids, adding: adding, removing: removing)
    }
    try enhancement(editor, size: NSSize(width: 456, height: 352), name: "history-tags-draft") {
      host in
      let action = try #require(compositionButton(in: host, label: "将「项目验收」添加到全部"))
      #expect(action() == true)
      #expect(history.item(second)?.tags == ["跟进"])
    }
    try enhancement(
      editor, size: NSSize(width: 456, height: 352), name: "history-tags-save", dark: true
    ) { host in
      let stage = try #require(compositionButton(in: host, label: "将「项目验收」添加到全部"))
      #expect(stage() == true)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.12))
      let save = try #require(compositionButton(in: host, label: "保存标签"))
      #expect(save() == true)
      #expect(history.item(second)?.tags == ["跟进", "项目验收"])
    }
    try enhancement(
      ShotHistoryTagPicker(names: model.availableTags, selection: model.tagFilter) {
        model.setTagFilter($0)
      }, size: NSSize(width: 264, height: 206), name: "history-tags-picker"
    ) { host in
      let choose = try #require(compositionButton(in: host, label: "项目验收"))
      #expect(choose() == true)
      #expect(model.tagFilter == "项目验收" && Set(model.shown.map(\.id)) == [first, second])
    }
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 960, height: 620),
      name: "history-tags-filtered")
    model.pick(first)
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 720, height: 420),
      name: "history-tags-detail", dark: true)
  }

  /// 从实际日期按钮应用与取消草稿，检查窄窗里的条件摘要和无结果状态。
  @Test(.enabled(if: directory != nil)) func renderShotHistoryDates() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "kitty-history-dates-\(UUID())")
    let history = try ShotHistory(db: Database(path: ":memory:"), directory: root)
    let suite = "kitty-history-dates-\(UUID())"
    let prefs = try #require(UserDefaults(suiteName: suite))
    prefs.set(true, forKey: Prefs.shotHistory)
    history.defaults = prefs
    defer {
      prefs.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let id = try #require(await history.record(Self.desktop(), scale: 2, source: "Safari"))
    let item = try #require(history.item(id))
    _ = try #require(await ShotThumbnails.shared.image(for: item, in: history))
    defer { ShotThumbnails.shared.forget(id) }
    let tag = "用于下次发布的多个主题和界面细节对照"
    try history.applyTags(to: [id], adding: [tag], removing: [])
    let model = ShotHistoryModel(history: history)
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: item.createdAt)
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    try enhancement(
      ShotHistoryDatePicker(selection: .today) { model.setDateFilter($0) },
      size: NSSize(width: 240, height: 136), name: "history-date-options"
    ) { host in
      let choose = try #require(compositionButton(in: host, label: "最近 7 天"))
      #expect(choose() && model.dateFilter == .lastSevenDays)
    }
    try enhancement(
      ShotHistoryDatePicker(selection: model.dateFilter) { model.setDateFilter($0) },
      size: NSSize(width: 270, height: 136), name: "history-date-edit", dark: true
    ) { host in
      let custom = try #require(compositionButton(in: host, label: "自选日期…"))
      #expect(custom())
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
      let cancel = try #require(compositionButton(in: host, label: "取消"))
      #expect(cancel() && model.dateFilter == .lastSevenDays)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
      let reopen = try #require(compositionButton(in: host, label: "自选日期…"))
      #expect(reopen())
    }
    try enhancement(
      ShotHistoryDateRangeEditor(start: today, end: yesterday, cancel: {}) {
        model.setDateFilter($0)
      }, size: NSSize(width: 270, height: 144), name: "history-date-invalid"
    ) { host in
      _ = compositionButton(in: host, label: "应用")?()
      #expect(model.dateFilter == .lastSevenDays)
    }
    try enhancement(
      ShotHistoryDateRangeEditor(start: yesterday, end: today, cancel: {}) {
        model.setDateFilter($0)
      }, size: NSSize(width: 270, height: 124), name: "history-date-apply"
    ) { host in
      let apply = try #require(compositionButton(in: host, label: "应用"))
      #expect(apply() && model.dateFilter == .custom(start: yesterday, end: today))
    }
    model.setTagFilter(tag)
    model.pick(id)
    try historyDateWindowSnapshot(
      ShotHistoryView(model: model).defaultAppStorage(prefs),
      size: NSSize(width: 720, height: 420), name: "history-date-detail", dark: true)
    try historyDateWindowSnapshot(
      ShotHistoryView(model: model).defaultAppStorage(prefs),
      size: NSSize(width: 720, height: 420), name: "history-date-compact", dark: false)
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs),
      size: NSSize(width: 720, height: 420), name: "history-date-detail-content", dark: true)
    model.setDateFilter(.custom(start: yesterday, end: yesterday))
    #expect(model.shown.isEmpty)
    try historyDateWindowSnapshot(
      ShotHistoryView(model: model).defaultAppStorage(prefs),
      size: NSSize(width: 960, height: 620), name: "history-date-empty", dark: false)
  }

  /// 保留原生标题栏桥接，在屏外核对日历、标签、类型和搜索的实际位置。
  private func historyDateWindowSnapshot(
    _ view: some View, size: NSSize, name: String, dark: Bool
  ) throws {
    let window = OffscreenTitledWindow(contentViewController: .windowContent(view))
    window.title = "截图历史"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.setContentSize(size)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    #expect(window.screen == nil && !window.isKeyWindow)
    for _ in 0..<8 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let frame = try #require(window.contentView?.superview)
    let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    let out = try #require(Self.directory)
    try write(try #require(bitmap.cgImage), to: "\(out)/shot-\(name).png")
  }

  /// 检查独立入口和成功底栏在两种面板尺寸下的位置，不打开真实文件面板。
  @Test(.enabled(if: directory != nil)) func renderIndividualPNGExport() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-png-batch-shots-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let first = folder.appending(path: "待核对的页面 A.png")
    let second = folder.appending(path: "待核对的页面 B.png")
    try write(
      try #require(desktop.cropping(to: CGRect(x: 0, y: 0, width: 1000, height: 720))),
      to: first.path)
    try write(
      try #require(desktop.cropping(to: CGRect(x: 200, y: 100, width: 700, height: 1000))),
      to: second.path)
    model.importFiles([first, second])
    try await waitForComposition(model)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-individual-png-action"
    ) { host in
      #expect(compositionButton(in: host, label: "逐张导出 PNG…") != nil)
      #expect(compositionButton(in: host, label: "导出 PNG…") != nil)
    }
    model.pdf = true
    model.refreshPreview()
    try await waitForComposition(model)
    model.saveIndividualPNGs(into: folder)
    for _ in 0..<200 where model.exporting { try await Task.sleep(for: .milliseconds(20)) }
    try #require(model.exportedImageCount == 2)
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-individual-png-completed", dark: true
    ) { host in
      #expect(compositionButton(in: host, label: "在访达中显示") != nil)
      #expect(compositionButton(in: host, label: "逐张导出 PNG…") != nil)
      #expect(compositionButton(in: host, label: "导出 PDF…") != nil)
    }
  }

  /// 屏外按下实际入口，核对交给标注的最终尺寸，并保存一张带箭头与说明的假成品。
  @Test(.enabled(if: directory != nil)) func renderCompositionAnnotation() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-compose-annotation-shots-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = ShotCompositionModel()
    defer {
      model.clear()
      try? FileManager.default.removeItem(at: folder)
    }
    let desktop = try Self.desktop()
    let files = try ["调整前.png", "调整后.png"].enumerated().map { index, name in
      let url = folder.appending(path: name)
      let picture = try #require(
        desktop.cropping(to: CGRect(x: index * 380, y: 20, width: 1120, height: 720)))
      try write(picture, to: url.path)
      return url
    }
    model.importFiles(files)
    try await waitForComposition(model)
    model.options = .init(
      layout: .horizontal, spacing: 48, margin: 24, widthMode: .custom, customWidth: 1600)
    model.refreshPreview()
    try await waitForComposition(model)
    var received: CGImage?
    model.openAnnotation = {
      received = $0
      return true
    }
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 820, height: 620),
      name: "composition-annotate-entry"
    ) { host in
      let button = try #require(compositionButton(in: host, label: "标注拼图…"))
      #expect(button() == true && model.preparingAnnotation)
    }
    for _ in 0..<200 where model.preparingAnnotation {
      try await Task.sleep(for: .milliseconds(20))
    }
    let base = try #require(received)
    #expect(base.width == 1600 && model.preview?.width == 1000)
    let canvas = ScrollCanvas(image: base, scale: 1)
    let y = CGFloat(base.height) * 0.3
    canvas.annotations = [
      .init(
        shape: .arrow(from: CGPoint(x: 560, y: y), to: CGPoint(x: 1040, y: y)),
        style: .init(color: .red, weight: .large)),
      .init(
        shape: .text("调整前 → 调整后", origin: CGPoint(x: 740, y: y + 56)),
        style: .init(color: .red, weight: .large, option: 2, fontSize: 24)),
    ]
    let result = try #require(canvas.composedStrictly())
    let output = try #require(Self.directory)
    try write(result, to: "\(output)/shot-composition-annotated-result.png")
    try enhancement(
      ShotCompositionView(model: model), size: NSSize(width: 720, height: 520),
      name: "composition-annotate-return", dark: true)
  }

  /// 核对历史中的完整成品、实际像素与返回网格，使用不可成为 key 的屏外窗口。
  @Test(.enabled(if: directory != nil)) func renderShotHistoryQuickPreview() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "kitty-history-preview-shots-\(UUID())")
    let history = try ShotHistory(db: Database(path: ":memory:"), directory: folder)
    let domain = "kitty-history-preview-pref-\(UUID())"
    let prefs = try #require(UserDefaults(suiteName: domain))
    prefs.set(true, forKey: Prefs.shotHistory)
    history.defaults = prefs
    let model = ShotHistoryModel(history: history)
    defer {
      model.quickPreview.close()
      prefs.removePersistentDomain(forName: domain)
      try? FileManager.default.removeItem(at: folder)
    }
    let long = try ScreenshotTests.render((1...30).map { "验收条目 \($0)   Review item \($0)" })
    let original = try #require(
      await history.record(
        long, scale: 2, kind: .scroll,
        annotations: [
          Annotation(
            shape: .rectangle(CGRect(x: 8, y: 1680, width: 400, height: 84)),
            style: .init(color: .red, weight: .large))
        ], source: "Safari"))
    let regular = try #require(await history.record(try Self.desktop(), scale: 2, source: "备忘录"))
    try history.applyTags(to: [original, regular], adding: ["验收"], removing: [])
    model.setTagFilter("验收")
    model.pick(original)
    #expect(model.openQuickPreview())
    for _ in 0..<250 where model.quickPreview.image == nil && model.quickPreview.error == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(model.quickPreview.image?.height == long.height)
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 960, height: 620),
      name: "history-quick-preview-fit")
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 720, height: 420),
      name: "history-quick-preview-actual", dark: true
    ) { host in
      let actual = try #require(compositionButton(in: host, label: "实际像素"))
      #expect(actual() == true)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.20))
      let scroll = try #require(
        firstSubview(
          NSScrollView.self, in: host,
          matching: {
            ($0.documentView?.bounds.height ?? 0) > 1200
          }))
      #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentSize.height)
      #expect(scroll.contentView.bounds.origin.y > 1200)
      if let bounds = scroll.documentView?.bounds, bounds.width < scroll.contentView.bounds.width {
        let left = (bounds.width - scroll.contentView.bounds.width) / 2
        #expect(abs(scroll.contentView.bounds.minX - left) <= 1)
      }
      #expect(host.window?.isKeyWindow == false)
    }
    model.quickPreview.close()
    #expect(model.picked == [original])
    for id in [original, regular] {
      let item = try #require(history.item(id))
      _ = try #require(await ShotThumbnails.shared.image(for: item, in: history))
    }
    defer { for id in [original, regular] { ShotThumbnails.shared.forget(id) } }
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 960, height: 620),
      name: "history-quick-preview-return"
    ) { host in
      #expect(compositionButton(in: host, label: "快速预览") != nil)
    }
    try enhancement(
      ShotHistoryView(model: model).defaultAppStorage(prefs), size: NSSize(width: 720, height: 420),
      name: "history-quick-preview-reopen"
    ) { host in
      let open = try #require(compositionButton(in: host, label: "快速预览"))
      #expect(open() == true && model.quickPreview.item?.id == original)
    }
  }

  /// 等待实际导入与预览，不把尚未产生图片的加载界面当作完成。
  private func waitForComposition(_ model: ShotCompositionModel) async throws {
    for _ in 0..<400
    where model.preparing || model.rendering
      || model.sources.contains(where: {
        !$0.edit.isIdentity && $0.thumbnailEdit != $0.edit && $0.thumbnailError == nil
      })
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(!model.preparing && !model.rendering && model.preview != nil, "拼图预览未就绪")
  }

  /// 只调用本进程辅助功能节点的公开方法，兼容 SwiftUI 未正式声明协议的节点，不发送系统 AX 请求。
  private func compositionButton(in value: Any, label: String) -> (() -> Bool)? {
    guard let node = value as? NSObject else { return nil }
    let read: (String) -> AnyObject? = { name in
      let selector = NSSelectorFromString(name)
      return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }
    let role = read("accessibilityRole") as? String
    let title = read("accessibilityLabel") as? String ?? read("accessibilityTitle") as? String
    let action = NSSelectorFromString("accessibilityPerformPress")
    if role == NSAccessibility.Role.button.rawValue, title == label,
      node.responds(to: action), let implementation = node.method(for: action)
    {
      // 公开方法返回 BOOL，按原生签名调用，不能用返回对象的 perform 冒充。
      typealias Press = @convention(c) (AnyObject, Selector) -> Bool
      let press = unsafeBitCast(implementation, to: Press.self)
      return { press(node, action) }
    }
    for child in read("accessibilityChildren") as? [Any] ?? [] {
      if let found = compositionButton(in: child, label: label) { return found }
    }
    return nil
  }

  /// 经真实按钮回调选择样式，避免仅改测试字段而未刷新托盘的选中态。
  private func annotationOption(in view: NSView, title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { annotationOption(in: $0, title: title) }.first
  }

  /// 查找桥接出的原生编辑器，只改变本次假文字，不发送系统键鼠。
  private func recognitionEditor(in view: NSView) -> RecognitionText? {
    if let editor = view as? RecognitionText { return editor }
    return view.subviews.lazy.compactMap { recognitionEditor(in: $0) }.first
  }

  /// 玻璃在屏外可能不呈现内容，单独收集 HUD 内容层以核对按钮和文字布局。
  private func referenceBars(in view: NSView) -> [HUDBar] {
    if let bar = view as? HUDBar { return [bar] }
    return view.subviews.flatMap { referenceBars(in: $0) }
  }

  /// 只在不可成为 key 的屏外窗口中检查布局，背景使用当前系统窗口色。
  private func enhancement(
    _ view: some View, size: NSSize, name: String, dark: Bool = false,
    prepare: ((NSView) throws -> Void)? = nil
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: view.frame(width: size.width, height: size.height).background(
        Color(nsColor: .windowBackgroundColor)))
    host.frame = CGRect(origin: .zero, size: size)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    try prepare?(host)
    RunLoop.main.run(until: Date.now.addingTimeInterval(0.1))
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let out = try #require(Self.directory)
    try write(try #require(bitmap.cgImage), to: "\(out)/shot-\(name)\(dark ? "-dark" : "").png")
  }

  private func write(_ image: CGImage, to path: String) throws {
    let data = try #require(
      NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try data.write(to: URL(filePath: path))
  }

  /// SwiftUI 视图放在假桌面的一角上渲染（常驻缩略图是透明窗口，看它压在画面上的样子）
  private func snapshot(
    _ view: some View, over desktop: CGImage, size: NSSize, dark: Bool, to path: String
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let background = NSImageView(frame: NSRect(origin: .zero, size: size))
    background.imageScaling = .scaleAxesIndependently
    background.image = NSImage(
      cgImage: try #require(
        desktop.cropping(
          to: CGRect(x: 1400, y: 900, width: size.width * 2, height: size.height * 2))),
      size: size)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = background.bounds
    background.addSubview(host)
    window.contentView = background
    window.orderFront(nil)
    for _ in 0..<5 { RunLoop.main.run(until: Date.now.addingTimeInterval(0.1)) }
    let bitmap = try #require(background.bitmapImageRepForCachingDisplay(in: background.bounds))
    background.cacheDisplay(in: background.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
    window.orderOut(nil)
  }
}

/// 只提供具名剪贴板和操作许可，直接驱动接收端而不发起系统拖放会话。
@MainActor private final class CompositionDrop: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingSourceOperationMask: NSDragOperation = .copy
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 0 }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }

  /// 接收现成的测试剪贴板，读写只发生在该拖放会话。
  init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

  func slideDraggedImage(to screenPoint: NSPoint) {}
  func enumerateDraggingItems(
    options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
  func resetSpringLoading() {}
}
