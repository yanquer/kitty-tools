// 录屏讲解工具的纯状态、资源上限、窗口点穿、焦点与工具回调。全部窗口只建不显示，不注册热键、不修改真实偏好。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct RecordingToolsTests {
  private let region = CGRect(x: -20000, y: -20000, width: 640, height: 360)

  /// 模式切换取消半条笔迹，保留已经提交的标注；关闭工具箱恢复操作模式。
  @Test func modesCancelDraftAndKeepCommittedInk() {
    var tools = RecordingTools()
    let began1 = tools.begin(at: .zero)
    #expect(!began1)
    tools.apply(.mode(.arrow))
    let began2 = tools.begin(at: CGPoint(x: 10, y: 10))
    #expect(began2)
    tools.finish(at: CGPoint(x: 120, y: 90), constrained: false)
    #expect(tools.annotations.count == 1)
    let began3 = tools.begin(at: CGPoint(x: 20, y: 20))
    #expect(began3)
    #expect(tools.draft != nil)
    tools.apply(.mode(.pen))
    #expect(tools.draft == nil && tools.annotations.count == 1)
    tools.apply(.close)
    #expect(!tools.isDrawing && tools.annotations.count == 1)
  }

  /// 每种持久笔迹都沿用 Annotation 的形状构造，激光笔不写入持久笔迹。
  @Test(arguments: RecordingTools.Mode.allCases.filter { $0 != .pointer })
  func allDrawingToolsCommitTheExpectedShape(_ mode: RecordingTools.Mode) {
    var tools = RecordingTools()
    tools.apply(.mode(mode))
    let began4 = tools.begin(at: CGPoint(x: 40, y: 40))
    #expect(began4)
    tools.update(to: CGPoint(x: 60, y: 70), constrained: false)
    tools.finish(at: CGPoint(x: 140, y: 100), constrained: false)
    #expect(tools.draft == nil)
    #expect(tools.annotations.first?.tool == mode.annotationTool)
    #expect(tools.annotations.count == (mode == .laser ? 0 : 1))
  }

  /// Shift 约束与截图一致，颜色线宽跟随新笔迹，已经完成的标注保持原样。
  @Test func constrainedShapesAndIndependentStyles() throws {
    var tools = RecordingTools()
    tools.apply(.mode(.rectangle))
    let began5 = tools.begin(at: .zero)
    #expect(began5)
    tools.finish(at: CGPoint(x: 30, y: 60), constrained: true)
    let first = try #require(tools.annotations.first)
    #expect(first.bounds.width == first.bounds.height)
    tools.apply(.color(.blue))
    tools.apply(.weight(.large))
    let began6 = tools.begin(at: .zero)
    #expect(began6)
    tools.finish(at: CGPoint(x: 100, y: 40), constrained: false)
    #expect(tools.annotations.first == first)
    #expect(tools.annotations.last?.style.color == .blue)
    #expect(tools.annotations.last?.style.weight == .large)
  }

  /// 空笔迹不提交，画笔的单击保留一个点，撤销和清空均能处理空状态。
  @Test func emptyStrokesUndoAndClear() {
    var tools = RecordingTools()
    tools.apply(.mode(.rectangle))
    let began7 = tools.begin(at: .zero)
    #expect(began7)
    tools.finish(at: .zero, constrained: false)
    #expect(tools.annotations.isEmpty)
    tools.apply(.mode(.pen))
    let began8 = tools.begin(at: CGPoint(x: 10, y: 10))
    #expect(began8)
    tools.finish(at: CGPoint(x: 10, y: 10), constrained: false)
    #expect(tools.canUndo && tools.annotations.count == 1)
    tools.apply(.undo)
    tools.apply(.undo)
    #expect(!tools.canUndo)
    tools.apply(.clear)
    #expect(tools.annotations.isEmpty)
  }

  /// 到达上限后拒绝新标注；撤销后可继续画，激光笔也不会被持久标注条数限制。
  @Test func annotationLimitRejectsWithoutDroppingExistingInk() {
    var tools = RecordingTools()
    tools.apply(.mode(.arrow))
    for _ in 0..<RecordingTools.maximumAnnotations {
      let began9 = tools.begin(at: .zero)
      #expect(began9)
      tools.finish(at: CGPoint(x: 40, y: 40), constrained: false)
    }
    let old = tools.annotations
    let began10 = tools.begin(at: .zero)
    #expect(!began10)
    #expect(tools.annotations == old)
    tools.apply(.undo)
    let began11 = tools.begin(at: .zero)
    #expect(began11)
    tools.apply(.mode(.laser))
    let began12 = tools.begin(at: .zero)
    #expect(began12)
  }

  /// 长时间连续画图始终限制采样点，降采样保留起点和最新终点。
  @Test func longStrokesBoundMemoryAndKeepEndpoints() throws {
    var tools = RecordingTools()
    tools.apply(.mode(.pen))
    let began13 = tools.begin(at: .zero)
    #expect(began13)
    for index in 1...20000 {
      tools.update(to: CGPoint(x: index * 2, y: index % 2), constrained: false)
    }
    tools.finish(at: CGPoint(x: 40002, y: 20), constrained: false)
    guard case .pen(let points) = try #require(tools.annotations.first).shape else {
      Issue.record("长笔迹没有保存为画笔")
      return
    }
    #expect(points.count <= RecordingTools.maximumPoints)
    #expect(points.first == .zero && points.last == CGPoint(x: 40002, y: 20))
  }

  /// 画板窗口从不当 key，画图时接收鼠标，返回操作模式和结束时恢复点穿。
  @Test func canvasWindowOnlyCapturesMouseWhileDrawing() throws {
    let canvas = try #require(RecordingCanvas(region: region))
    defer { canvas.close() }
    #expect(type(of: canvas.panel) == NSPanel.self)
    #expect(!canvas.panel.isVisible && !canvas.panel.canBecomeKey && !canvas.panel.canBecomeMain)
    #expect(canvas.panel.ignoresMouseEvents && canvas.windowID != nil)
    #expect(canvas.view.ink.isHidden)
    #expect(canvas.panel.level == .statusBar)
    let windows = [
      ScreenCapture.OwnWindow(
        id: 9, className: "NSPanel", level: canvas.panel.level.rawValue,
        isVisible: true, alpha: 1)
    ]
    #expect(ScreenCapture.keptOwnWindows(windows).isEmpty)
    #expect(ScreenCapture.recordedOwnWindows(windows).isEmpty)
    canvas.apply(.mode(.pen))
    #expect(!canvas.panel.ignoresMouseEvents)
    #expect(canvas.view.hitTest(CGPoint(x: 10, y: 10)) === canvas.view)
    canvas.apply(.mode(.pointer))
    #expect(canvas.panel.ignoresMouseEvents && canvas.view.hitTest(.zero) == nil)
    canvas.close()
    #expect(canvas.panel.ignoresMouseEvents && canvas.state.annotations.isEmpty)
  }

  /// 通过屏外鼠标入口触发满额拒绝，核对真实提示和持久日志路径，不发送系统事件。
  @Test func fullCanvasRejectsWithAnExplicitNotice() throws {
    let canvas = try #require(RecordingCanvas(region: region))
    defer { canvas.close() }
    canvas.apply(.mode(.arrow))
    var notice: String?
    canvas.onNotice = { notice = $0 }
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
        windowNumber: canvas.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))
    let up = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseUp, location: CGPoint(x: 80, y: 80), modifierFlags: [], timestamp: 0,
        windowNumber: canvas.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 0))
    for _ in 0..<RecordingTools.maximumAnnotations {
      canvas.view.mouseDown(with: down)
      canvas.view.mouseUp(with: up)
    }
    canvas.view.mouseDown(with: down)
    #expect(canvas.state.annotations.count == RecordingTools.maximumAnnotations)
    #expect(notice == "画板已达 256 条标注，请撤销或清空后继续")
  }

  /// 焦点只显示在被录区域，工具栏、屏外和关闭状态均不会留下聚光灯。
  @Test func focusRespectsRegionToolsAndSizes() throws {
    let canvas = try #require(RecordingCanvas(region: region))
    defer { canvas.close() }
    canvas.apply(.focus(.halo))
    canvas.updatePointer(at: CGPoint(x: region.midX, y: region.midY), animated: false)
    #expect(canvas.focusPath?.boundingBox.width == 96)
    canvas.apply(.radius(.large))
    canvas.updatePointer(at: CGPoint(x: region.midX, y: region.midY), animated: false)
    #expect(canvas.focusPath?.boundingBox.width == 160)
    canvas.excludedFrames = { [self.region] }
    canvas.updatePointer(at: CGPoint(x: region.midX, y: region.midY), animated: false)
    #expect(canvas.focusPath == nil)
    canvas.excludedFrames = { [] }
    canvas.apply(.focus(.spotlight))
    canvas.updatePointer(at: CGPoint(x: region.midX, y: region.midY), animated: false)
    #expect(canvas.focusPath?.boundingBox == canvas.view.bounds)
    canvas.updatePointer(at: CGPoint(x: region.maxX + 10, y: region.midY), animated: false)
    #expect(canvas.focusPath == nil)
  }

  /// 激光轨迹不会无界增长，换回操作模式或收尾时全部移除。
  @Test func laserLayersAreBoundedAndReleased() throws {
    let canvas = try #require(RecordingCanvas(region: region))
    defer { canvas.close() }
    canvas.apply(.mode(.laser))
    for index in 0..<300 {
      canvas.addLaser(to: CGPoint(x: index, y: 100), at: Double(index) * 0.01, animated: false)
    }
    #expect(canvas.laserCount == 96)
    #expect(canvas.state.annotations.isEmpty)
    canvas.apply(.mode(.pointer))
    #expect(canvas.laserCount == 0)
  }

  /// 激光线段淡出后自动移除，停手时不需要定时轮询或真实显示窗口。
  @Test func laserAnimationRemovesItsLayersAfterFading() async throws {
    let canvas = try #require(RecordingCanvas(region: region))
    defer { canvas.close() }
    for index in 0..<3 {
      canvas.addLaser(
        to: CGPoint(x: 100 + index * 10, y: 100), at: Double(index) * 0.01, animated: true)
    }
    #expect(canvas.laserCount == 3)
    for _ in 0..<60 where canvas.laserCount > 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(canvas.laserCount == 0)
  }

  /// 工具窗口只建不显示，入口回调、焦点状态和画笔样式可在屏外同步。
  @Test func toolsBarCallbacksAndWindowProperties() throws {
    let bar = RecordingToolsBar()
    defer { bar.close() }
    #expect(!bar.panel.isVisible && !bar.panel.canBecomeKey)
    #expect(bar.panel.level.rawValue > NSWindow.Level.popUpMenu.rawValue + 2)
    var selected = RecordingTools.Mode.pointer
    bar.onAction = { action in
      if case .mode(let mode) = action { selected = mode }
    }
    try #require(bar.button(for: .pen)).performClick(nil)
    #expect(selected == .pen)
    var state = RecordingTools()
    state.apply(.mode(.pen))
    bar.update(state, escapes: true)
    #expect(bar.button(for: .pen)?.accessibilityValue() as? String == "已选择")
    #expect(bar.frame.width < 500 && bar.frame.height < 200)
  }

  /// 工具箱共用一块表面，参数按需展开，鼠标效果再次点击即关闭，返回操作后收起无关参数。
  @Test func toolsShareOneSurfaceAndRevealOptionsAsNeeded() throws {
    let bar = RecordingToolsBar()
    defer { bar.close() }
    #expect(bar.subviews.count == 1 && bar.subviews.first is HUDBar)
    #expect(bar.frame.height == 72)
    #expect(bar.focusButton(for: .off) == nil)
    var state = RecordingTools()
    bar.onAction = { action in
      state.apply(action)
      bar.update(state, escapes: true)
    }
    try #require(bar.focusButton(for: .halo)).performClick(nil)
    #expect(state.focus == .halo && bar.frame.height == 112)
    try #require(bar.focusButton(for: .halo)).performClick(nil)
    #expect(state.focus == .off && bar.frame.height == 72)
    try #require(bar.button(for: .pen)).performClick(nil)
    #expect(state.mode == .pen && bar.frame.height == 112)
    #expect(bar.accessibilityHelp()?.contains("Esc 返回操作窗口") == true)
    try #require(bar.button(for: .pointer)).performClick(nil)
    #expect(bar.frame.height == 72)
    try #require(bar.focusButton(for: .spotlight)).performClick(nil)
    #expect(state.focus == .spotlight && bar.frame.height == 112)
  }

  /// 小屏、负坐标副屏和控制条贴边时工具箱仍保持在可见区内。
  @Test(arguments: [
    CGRect(x: 0, y: 0, width: 800, height: 600),
    CGRect(x: -1920, y: -200, width: 1920, height: 1056),
  ])
  func toolsPlacementClampsToVisibleScreen(_ visible: CGRect) {
    for y in [visible.minY, visible.midY, visible.maxY - 40] {
      for x in [visible.minX, visible.midX, visible.maxX - 40] {
        let frame = RecordingTools.frame(
          size: CGSize(width: 400, height: 180),
          anchor: CGRect(x: x, y: y, width: 180, height: 40), visible: visible)
        #expect(visible.contains(frame))
      }
    }
  }

  /// 结束时没有窗口和闭包环留住画板或工具箱。
  @Test func closingReleasesCanvasAndToolbar() throws {
    weak var weakCanvas: RecordingCanvas?
    weak var weakBar: RecordingToolsBar?
    try autoreleasepool {
      let canvas = try #require(RecordingCanvas(region: region))
      let bar = RecordingToolsBar()
      weakCanvas = canvas
      weakBar = bar
      canvas.close()
      bar.close()
    }
    #expect(weakCanvas == nil && weakBar == nil)
  }
}
