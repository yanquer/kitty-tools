// 独立演示画布插件：复用录屏画板与工具栏，在当前屏幕讲解、画图、使用激光笔和白板。

import AppKit
import OSLog
import Observation

/// 不录制音视频；窗口、鼠标监听和临时 Esc 仅在演示期间存在。
@Observable final class PresentationCanvas: NSObject {
  private(set) var isActive = false
  private(set) var isWhiteboard = false
  @ObservationIgnored weak var hotKeys: HotKeyCenter?
  @ObservationIgnored var isSuppressed: () -> Bool = { false }
  @ObservationIgnored var onNotice: (String) -> Void = { _ in }
  @ObservationIgnored private var canvas: RecordingCanvas?
  @ObservationIgnored private var bar: RecordingToolsBar?
  @ObservationIgnored private var visibleFrame = CGRect.zero
  @ObservationIgnored private var attemptedEscape = false
  @ObservationIgnored private var escapes = false

  /// 全局动作与设置页共用同一个开关入口。
  func toggle() {
    if isActive {
      stop()
      return
    }
    start()
  }

  /// 在鼠标所在屏幕创建透明画板，出现时不激活应用，不获取键盘焦点。
  private func start() {
    guard Feature.presentation.isOn else { return }
    guard !isSuppressed() else {
      Log.capture.notice("演示画布未开始 stage=suppressed：其他工具占用输入或屏幕")
      return onNotice("请先结束当前截图、录制或全屏工具，再开始演示")
    }
    guard
      let screen = NSScreen.screens.first(where: {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
      }) ?? NSScreen.main,
      let canvas = RecordingCanvas(region: screen.frame, label: "演示画布")
    else {
      Log.capture.error("演示画布未开始：没有可用屏幕或画板初始化失败")
      return onNotice("无法创建演示画布，请重试")
    }
    visibleFrame = screen.visibleFrame
    let bar = RecordingToolsBar(presentation: true)
    self.canvas = canvas
    self.bar = bar
    isActive = true
    canvas.onChange = { [weak self] in self?.changed($0) }
    canvas.onNotice = { [weak self] in self?.onNotice($0) }
    canvas.excludedFrames = { [weak bar] in
      guard let bar else { return [] }
      return [bar.panel, bar.optionsPanel].filter(\.isVisible).map(\.frame)
    }
    bar.onAction = { [weak self] in self?.apply($0) }
    bar.onWhiteboard = { [weak self] in self?.toggleWhiteboard() }
    bar.onDismissOptions = { [weak self] in
      guard let self, let canvas = self.canvas else { return }
      changed(canvas.state)
    }
    canvas.present()
    canvas.apply(.mode(.pen))
    NotificationCenter.default.addObserver(
      self, selector: #selector(environmentChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)
    for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification]
    {
      NSWorkspace.shared.notificationCenter.addObserver(
        self, selector: #selector(environmentChanged), name: name, object: nil)
    }
    Log.capture.notice("演示画布开始 window=\(canvas.panel.windowNumber)")
    Island.announce("演示画布已开始，Esc 返回操作窗口，工具栏关闭按钮结束演示")
  }

  /// 白板启用时进入画笔，返回操作窗口时撤掉白板以免操作被遮住的应用。
  func toggleWhiteboard() {
    guard isActive, let canvas else { return }
    isWhiteboard.toggle()
    canvas.setWhiteboard(isWhiteboard)
    bar?.setWhiteboard(isWhiteboard)
    if isWhiteboard, !canvas.state.isDrawing { canvas.apply(.mode(.pen)) }
    Log.capture.notice("演示画布白板变化 enabled=\(self.isWhiteboard)")
  }

  /// 复用录屏工具状态，关闭动作结束整个演示，其他动作不写用户偏好。
  func apply(_ action: RecordingTools.Action) {
    guard isActive else { return }
    if case .close = action {
      stop()
      return
    }
    if case .mode(.pointer) = action, isWhiteboard {
      isWhiteboard = false
      canvas?.setWhiteboard(false)
      bar?.setWhiteboard(false)
    }
    canvas?.apply(action)
  }

  /// 绘图与参数气泡期间临时注册 Esc，返回操作窗口即注销，不常驻拦截输入。
  private func changed(_ state: RecordingTools) {
    guard isActive, let bar else { return }
    let needsEscape = state.isDrawing || bar.hasOptions
    if needsEscape, !attemptedEscape {
      attemptedEscape = true
      escapes =
        hotKeys?.registerEscape { [weak self] in
          self?.bar?.dismissOptions()
          self?.apply(.mode(.pointer))
        } ?? false
      if !escapes {
        Log.capture.error("演示画布 Esc 注册失败，保留工具栏返回操作入口")
        onNotice("演示画布的 Esc 不可用，请点工具栏左侧箭头返回操作窗口")
      }
    } else if !needsEscape, attemptedEscape {
      if escapes { hotKeys?.unregisterEscape() }
      attemptedEscape = false
      escapes = false
    }
    bar.update(state, escapes: escapes)
    let anchor = CGRect(x: visibleFrame.midX - 1, y: visibleFrame.minY + 8, width: 2, height: 1)
    bar.present(anchor: anchor, visible: visibleFrame)
  }

  /// 结束时立即释放输入和画板，工具栏沿用已有退场动画；重复调用安全。
  func stop() {
    guard isActive else { return }
    isActive = false
    if escapes { hotKeys?.unregisterEscape() }
    attemptedEscape = false
    escapes = false
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    let canvas = self.canvas
    let bar = self.bar
    self.canvas = nil
    self.bar = nil
    canvas?.close()
    bar?.close()
    isWhiteboard = false
    Log.capture.notice("演示画布结束 window=\(canvas?.panel.windowNumber ?? -1)")
  }

  /// 屏幕拓扑变化、锁屏或睡眠时收尾，不把旧尺寸画板留在新桌面上。
  @objc private func environmentChanged(_ notification: Notification) { stop() }
}
