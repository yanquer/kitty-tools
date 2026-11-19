// 截图选区稳定后的二维码发现：单个后台工作循环、过期结果隔离，以及码旁的预览和复制卡片。

import AppKit
import Carbon.HIToolbox
import OSLog

/// 只在截图调整阶段工作；拖动、标注、切换模式和结束会话都会作废在途结果。
final class SelectionCodes {
  let overlay = CodeOverlay(frame: .zero)
  private weak var host: NSView?
  private var wanted: Input?
  private var task: Task<Void, Never>?
  private var generation = 0
  private(set) var results: [OCR.Code] = []
  private let scan: @Sendable (CGImage) async throws -> [OCR.Code]
  var onOpen: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  var onFinish: () -> Void = {}

  private struct Input {
    let image: CGImage
    let selection: CGRect
    let viewSize: CGSize
    let generation: Int
  }

  /// 注入扫描入口便于屏外验证，不发送网络请求，不读取实时屏幕。
  init(
    host: NSView,
    scan: @escaping @Sendable (CGImage) async throws -> [OCR.Code] = {
      try await OCR.scanCodes(in: $0)
    }
  ) {
    self.host = host
    self.scan = scan
    overlay.frame = host.bounds
    overlay.autoresizingMask = [.width, .height]
    host.addSubview(overlay)
  }

  /// 仅输入变化时重新排队；指针移动和普通重画不会触发扫描。
  func update(image: CGImage, selection: CGRect?, viewSize: CGSize, enabled: Bool) {
    guard enabled, let selection, selection.width >= 8, selection.height >= 8 else {
      if wanted != nil || !results.isEmpty { clear() }
      return
    }
    if let wanted, wanted.image === image, wanted.selection == selection,
      wanted.viewSize == viewSize
    {
      return
    }
    clear()
    wanted = Input(image: image, selection: selection, viewSize: viewSize, generation: generation)
    startWorker()
  }

  /// 同时最多一个 Vision 请求；选区变化只更新待处理输入，不叠加不可中断的请求。
  private func startWorker() {
    guard task == nil else { return }
    task = Task { [weak self] in
      while let input = self?.wanted {
        try? await Task.sleep(for: .milliseconds(180))
        guard let self else { return }
        guard wanted?.generation == input.generation else { continue }
        let pixels = RegionSelector.pixelRect(
          input.selection, viewSize: input.viewSize,
          imageSize: CGSize(width: input.image.width, height: input.image.height))
        guard let crop = input.image.cropping(to: pixels) else {
          Log.clipboard.error("截图条码扫描无法裁剪选区")
          break
        }
        do {
          Log.clipboard.debug(
            "截图自动条码扫描开始 generation=\(input.generation) width=\(crop.width) height=\(crop.height)")
          let codes = try await scan(crop)
          Log.clipboard.debug("截图自动条码扫描结束 generation=\(input.generation) count=\(codes.count)")
          if wanted?.generation == input.generation {
            display(codes, selection: input.selection)
          }
        } catch {
          Log.clipboard.error(
            "截图自动条码扫描失败 generation=\(input.generation) stage=vision cause=\(String(reflecting: error), privacy: .public)"
          )
        }
        if wanted?.generation == input.generation { break }
      }
      self?.task = nil
    }
  }

  /// 位置从码的归一化图内坐标换回选区视图坐标，按钮不拦截其他区域的操作。
  private func display(_ codes: [OCR.Code], selection: CGRect) {
    results = codes
    for view in overlay.subviews { view.removeFromSuperview() }
    // ponytail: 同一选区最多显示 16 个不同内容的码，避免海报类图片铺满按钮；手动识字仍识别全部。
    for code in codes.prefix(16) {
      let rect = CGRect(
        x: selection.minX + code.box.minX * selection.width,
        y: selection.minY + code.box.minY * selection.height,
        width: code.box.width * selection.width, height: code.box.height * selection.height)
      let button = CodeBadge()
      button.frame = Self.badgeFrame(for: rect, within: overlay.bounds)
      button.onClick = { [weak self] in self?.show(code, anchor: rect) }
      overlay.addSubview(button)
    }
  }

  /// 用统一的夹边规则摆放角标，小码也保留 28 点的点击目标。
  static func badgeFrame(for rect: CGRect, within bounds: CGRect) -> CGRect {
    CGRect(
      x: min(max(rect.midX - 14, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - 32)),
      y: min(max(rect.midY - 14, bounds.minY + 4), max(bounds.minY + 4, bounds.maxY - 32)),
      width: 28, height: 28)
  }

  /// 卡片优先放在码下方，放不下时向上翻转，整体夹回屏内。
  static func cardFrame(anchor: CGRect, within bounds: CGRect) -> CGRect {
    let size = CGSize(
      width: min(360, max(180, bounds.width - 24)), height: min(220, max(140, bounds.height - 24)))
    let below = anchor.minY - 8 - size.height
    return CGRect(
      x: min(
        max(anchor.midX - size.width / 2, bounds.minX + 12),
        max(bounds.minX + 12, bounds.maxX - 12 - size.width)),
      y: min(
        max(below >= bounds.minY + 12 ? below : anchor.maxY + 8, bounds.minY + 12),
        max(bounds.minY + 12, bounds.maxY - 12 - size.height)), width: size.width,
      height: size.height)
  }

  /// 预览不会自动打开网址或改剪贴板，只有明确点击对应按钮才执行。
  private func show(_ code: OCR.Code, anchor: CGRect) {
    dismissCard()
    let card = CodeResultCard(code: code)
    card.frame = Self.cardFrame(anchor: anchor, within: overlay.bounds)
    card.applyGeometry()
    card.placeContent()
    card.onClose = { [weak self] in self?.dismissCard() }
    card.onOpen = { [weak self, weak card] in
      guard let self, let url = code.url else { return }
      if onOpen(url) {
        onFinish()
      } else {
        card?.showProblem("系统未能打开这个网址，可以复制后手动打开")
        Log.clipboard.error("条码网址打开失败：NSWorkspace 返回 false")
      }
    }
    overlay.card = card
    overlay.addSubview(card)
    card.grow(true)
  }

  /// Esc 或点外只关闭卡片，保留当前截图与识别角标。
  @discardableResult func dismissCard() -> Bool {
    guard let card = overlay.card else { return false }
    if host?.window?.firstResponder is CodeText { host?.window?.makeFirstResponder(host) }
    card.removeFromSuperview()
    overlay.card = nil
    return true
  }

  /// 使旧扫描结果失效；不重新发起或并行执行已在途的请求。
  func clear() {
    generation &+= 1
    wanted = nil
    results = []
    dismissCard()
    for view in overlay.subviews { view.removeFromSuperview() }
  }
}

/// 只有角标与卡片命中鼠标，其余区域继续交给截图选区。
final class CodeOverlay: NSView {
  var card: CodeResultCard?

  /// 空白区域返回 nil，避免覆盖框选与标注输入。
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// 沿用截图 HUD 的按钮样式并保留第一次点击响应。
private final class CodeBadge: BarButton {
  var onClick: () -> Void = {}

  /// 以二维码符号提示用户可查看内容，完整内容不放进工具提示。
  init() {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: "qrcode", accessibilityDescription: "查看二维码或条码内容")
    isBordered = false
    imagePosition = .imageOnly
    contentTintColor = Style.Shot.onAccent
    wantsLayer = true
    layer?.backgroundColor = Style.Shot.accent.cgColor
    layer?.cornerRadius = 8
    toolTip = "查看二维码或条码内容"
    target = self
    action = #selector(clicked)
    setAccessibilityLabel("查看二维码或条码内容")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 用户主动点码才打开结果卡片。
  @objc private func clicked() { onClick() }
}

/// 结果卡沿用深色 HUD 材质；内容是可选择原生文本，网址动作独立展示。
final class CodeResultCard: HUDBar {
  private let code: OCR.Code
  private let titleLabel = NSTextField(labelWithString: "二维码 / 条码")
  private let scroll = NSScrollView()
  private let text = CodeText(frame: .zero)
  private let copyButton = NSButton(title: "复制内容", target: nil, action: nil)
  private let openButton = NSButton(title: "打开网址", target: nil, action: nil)
  private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
  var onClose: () -> Void = {}
  var onOpen: () -> Void = {}

  /// 创建只读内容卡；不自动取得键盘或触发外部应用。
  init(code: OCR.Code) {
    self.code = code
    super.init(radius: Style.Radius.panel, height: 220)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = Style.HUD.text
    text.string = code.text
    text.font = .systemFont(ofSize: 13)
    text.textColor = Style.HUD.text
    text.drawsBackground = false
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.onClose = { [weak self] in self?.onClose() }
    text.setAccessibilityLabel("码的完整内容")
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    for view in [titleLabel, scroll, copyButton, openButton, closeButton] {
      effect.addSubview(view)
    }
    for button in [copyButton, openButton, closeButton] {
      button.target = self
      button.bezelStyle = .rounded
      button.font = .systemFont(ofSize: 12)
    }
    copyButton.action = #selector(copyContent)
    openButton.action = #selector(openURL)
    closeButton.action = #selector(closeCard)
    openButton.isHidden = code.url == nil
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 等材质完成布局后再排内容，避免玻璃内容层尚为零尺寸时把文字排到卡外。
  override func layout() {
    super.layout()
    placeContent()
  }

  /// 手工布局与截图 HUD 一致，卡片尺寸变化后正文可以滚动查看全部内容。
  func placeContent() {
    let inset = HUDBar.materialInset
    effect.frame = CGRect(origin: .zero, size: bounds.insetBy(dx: inset, dy: inset).size)
    let width = effect.bounds.width
    let height = effect.bounds.height
    titleLabel.frame = CGRect(x: 14, y: height - 36, width: max(1, width - 28), height: 22)
    scroll.frame = CGRect(x: 12, y: 50, width: max(1, width - 24), height: max(30, height - 96))
    text.frame.size.width = scroll.contentSize.width
    copyButton.frame = CGRect(x: 12, y: 12, width: 90, height: 28)
    openButton.frame = CGRect(x: 108, y: 12, width: 90, height: 28)
    closeButton.frame = CGRect(x: width - 76, y: 12, width: 64, height: 28)
  }

  /// 打开失败保留完整原始内容供复制，不伪装为成功。
  func showProblem(_ message: String) {
    titleLabel.stringValue = message
    titleLabel.toolTip = message
  }

  /// 主动复制完整内容，经统一剪贴板入口记入历史。
  @objc private func copyContent() {
    Paster.write(string: code.text, record: true)
    copyButton.title = "已复制"
    Island.announce("已复制码的内容")
  }

  /// 只运行经过 HTTP(S) 筛选的网址动作。
  @objc private func openURL() { onOpen() }

  /// 关闭卡片并把键盘交回截图。
  @objc private func closeCard() { onClose() }
}

/// 内容中的局部复制同样走 Paster，Esc 只关卡片。
private final class CodeText: NSTextView {
  var onClose: () -> Void = {}

  /// 系统复制菜单与 ⌘C 只复制当前选中的内容。
  override func copy(_ sender: Any?) {
    let range = selectedRange()
    let value = string as NSString
    guard range.length > 0, NSMaxRange(range) <= value.length else { return }
    Paster.write(string: value.substring(with: range), record: true)
  }

  /// 文字框拿着键盘时也能用 Esc 退出结果卡。
  override func cancelOperation(_ sender: Any?) { onClose() }
}
