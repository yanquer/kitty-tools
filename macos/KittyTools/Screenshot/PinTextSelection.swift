// 钉图原位选字：复用系统实况文本，仅手动开启；识别合成图，选区不进入图片和历史。

import AppKit
import Carbon.HIToolbox
import OSLog
import VisionKit

/// 系统文字选择的钉图宿主，管理识别生命周期、状态、复制与取景几何。
@MainActor final class PinTextSelection: NSView, ImageAnalysisOverlayViewDelegate {
  enum State: Equatable { case off, loading, ready, empty, failed }
  private(set) var state: State = .off
  var isEnabled: Bool { state != .off }
  var hasSelection: Bool { state == .ready && !overlay.selectedText.isEmpty }
  let overlay = ImageAnalysisOverlayView(frame: .zero)
  var viewport = CGRect(x: 0, y: 0, width: 1, height: 1) {
    didSet { if viewport != oldValue { overlay.setContentsRectNeedsUpdate() } }
  }
  var onCopy: (String) -> Void = { Paster.write(string: $0) }
  var onState: () -> Void = {}
  var contextMenu: (NSEvent) -> NSMenu? = { _ in nil }
  var acceptsPoint: (CGPoint) -> Bool = { _ in true }
  /// 可注入受控识别，测试不改剪贴板或触发真实窗口。
  var scan: @MainActor (CGImage) async throws -> ImageAnalysis = { image in
    try await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init(.text))
  }
  private let selectionID = UUID().uuidString
  private var generation = 0
  private var pending: (image: CGImage, ticket: Int)?
  private var worker: Task<Void, Never>?
  private let notice = NSTextField(labelWithString: "")

  /// 原生选择层与状态提示均留在钉图内，不创建置顶窗口或激活应用。
  override init(frame: NSRect) {
    super.init(frame: frame)
    overlay.delegate = self
    overlay.preferredInteractionTypes = .textSelection
    overlay.isSupplementaryInterfaceHidden = true
    overlay.frame = bounds
    overlay.autoresizingMask = [.width, .height]
    addSubview(overlay)
    notice.font = .systemFont(ofSize: 11)
    notice.textColor = Style.HUD.text
    notice.backgroundColor = Style.HUD.fill
    notice.drawsBackground = true
    notice.alignment = .center
    notice.autoresizingMask = [.width]
    notice.wantsLayer = true
    notice.layer?.cornerRadius = Style.Radius.control
    notice.layer?.masksToBounds = true
    notice.isHidden = true
    addSubview(notice)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 合成图变更或重新开启时只保留最新请求，同一钉图始终只有一个识别循环。
  func open(_ image: CGImage) {
    generation += 1
    pending = (image, generation)
    overlay.analysis = nil
    isHidden = false
    setState(.loading)
    guard worker == nil else { return }
    worker = Task { [weak self] in await self?.process() }
  }

  /// 关闭立即撤下选区并作废结果；正在执行的系统识别返回后释放，不累积后台任务。
  func stop() {
    if isEnabled {
      Log.capture.notice(
        "钉图选字停止 selection=\(self.selectionID, privacy: .public) generation=\(self.generation) state=\(String(describing: self.state), privacy: .public)"
      )
    }
    generation += 1
    pending = nil
    overlay.resetSelection()
    overlay.analysis = nil
    isHidden = true
    setState(.off)
  }

  /// 顺序识别并记录原始失败，不将无文字和识别失败混作同一状态。
  private func process() async {
    defer { worker = nil }
    while let request = pending {
      pending = nil
      let began = ContinuousClock.now
      Log.capture.notice(
        "钉图选字开始 selection=\(self.selectionID, privacy: .public) generation=\(request.ticket) width=\(request.image.width) height=\(request.image.height)"
      )
      do {
        let result = try await scan(request.image)
        guard request.ticket == generation, isEnabled else {
          Log.capture.debug(
            "钉图选字跳过过期结果 selection=\(self.selectionID, privacy: .public) generation=\(request.ticket)"
          )
          continue
        }
        overlay.analysis = result
        overlay.selectableItemsHighlighted = true
        setState(result.hasResults(for: .text) ? .ready : .empty)
        Log.capture.notice(
          "钉图选字完成 selection=\(self.selectionID, privacy: .public) generation=\(request.ticket) hasText=\(self.state == .ready) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
        )
      } catch {
        Log.capture.error(
          "钉图选字失败 selection=\(self.selectionID, privacy: .public) generation=\(request.ticket) cause=\(String(reflecting: error), privacy: .public)"
        )
        if request.ticket == generation, isEnabled { setState(.failed) }
      }
    }
  }

  /// 状态提示只在加载、空结果和失败时显示，成功时使用系统原位选字反馈。
  private func setState(_ value: State) {
    state = value
    switch value {
    case .loading: notice.stringValue = "正在识字… · Esc 返回图片"
    case .empty: notice.stringValue = "没有识别到文字 · Esc 返回图片"
    case .failed: notice.stringValue = "识字失败，请关闭后重试 · Esc 返回图片"
    case .off, .ready: notice.stringValue = ""
    }
    notice.isHidden = notice.stringValue.isEmpty
    needsLayout = true
    onState()
  }

  /// 提示适配小钉图，长文字由系统截断，不遮挡右上角悬停控件。
  override func layout() {
    super.layout()
    notice.frame = CGRect(x: 4, y: 4, width: max(0, bounds.width - 8), height: 24)
  }

  /// 只截取文字上的鼠标事件，图片空白仍交给原钉图拖动和右键菜单。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard state == .ready, acceptsPoint(point) else { return nil }
    let local = overlay.convert(point, from: self)
    // VisionKit 的识别命中使用左上原点，原生视图自身仍使用 AppKit 的左下原点。
    let textPoint = CGPoint(x: local.x, y: overlay.bounds.height - local.y)
    guard overlay.hasText(at: textPoint) else { return nil }
    return overlay.hitTest(local)
  }

  /// 复制只作用于明确选中文字，统一经过本应用剪贴板入口；未选中不改剪贴板。
  @discardableResult func copySelection() -> Bool {
    let text = overlay.selectedText
    guard state == .ready, !text.isEmpty else { return false }
    onCopy(text)
    return true
  }

  /// 归一化取景对应整图在当前窗口中的位置，局部放大和拖动使用同一映射。
  func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
    let rect = CGRect(
      x: -viewport.minX / viewport.width, y: -viewport.minY / viewport.height,
      width: 1 / viewport.width, height: 1 / viewport.height)
    // 内容矩形同识别几何采用左上原点，不能依据 NSView.isFlipped 推断。
    return CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
  }

  /// 系统只处理选字，不识别网址动作、主体或查询按钮。
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
    forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
  ) -> Bool {
    let local = CGPoint(x: point.x, y: overlayView.bounds.height - point.y)
    return analysisType == .textSelection && acceptsPoint(convert(local, from: overlayView))
  }

  /// 有宿主菜单时允许系统显示，实际条目由下一回调整体替换，复制仍经应用入口。
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldShowMenuForEvent event: NSEvent,
    atPoint point: CGPoint
  ) -> Bool { contextMenu(event) != nil }

  /// 原位文字上的右键与图片空白处使用同一菜单，不留下系统复制或查询动作。
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu,
    for event: NSEvent, at point: CGPoint
  ) -> NSMenu { contextMenu(event) ?? NSMenu() }

  /// 复制和退出交给宿主响应链，其余原生选字键继续由系统处理。
  func overlayView(
    _ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent
  ) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == kVK_ANSI_C && flags == .command || event.keyCode == kVK_Escape {
      return false
    }
    return true
  }
}
