// 识字结果面板：保留原图对照，支持选择部分文字复制；快捷识字仍直接复制，不经过这里。

import AppKit
import OSLog
import SwiftUI

/// 识字面板的短期状态，不持久化识别内容或选中文字。
@Observable final class RecognitionModel {
  var image: CGImage?
  var text = ""
  var selectedText = ""
  var working = false
  var error: String?
  var compares = true
  @ObservationIgnored var close: () -> Void = {}
  /// 沿用统一写入入口；测试注入收集器，不触碰系统剪贴板。
  @ObservationIgnored var write: (String) -> Void = { Paster.write(string: $0, record: true) }

  /// 所有复制入口经 Paster 写入并记录用户主动留下的新文字。
  func copy(selectionOnly: Bool) {
    let value = selectionOnly ? selectedText : text
    guard !value.isEmpty else { return }
    write(value)
    Island.announce(selectionOnly ? "已复制选中文字" : "已复制全部文字")
  }

  /// 收起时释放图像和文字，取消的任务不能再回填内容。
  func clear() {
    image = nil
    text = ""
    selectedText = ""
    error = nil
    working = false
  }
}

/// 复用 OverlayPanel 与 TransientPanel，出现时不激活应用，关闭后释放结果。
final class RecognitionPanel {
  let model = RecognitionModel()
  private var task: Task<Void, Never>?
  private var generation = 0
  private var requested: (image: CGImage, generation: Int)?
  private let scan: @Sendable (CGImage) async throws -> [OCR.Line]

  /// 默认使用设备端 Vision；按需注入识别入口，不创建额外进程或长期模型缓存。
  init(
    scan: @escaping @Sendable (CGImage) async throws -> [OCR.Line] = {
      try await OCR.inspectLines(in: $0)
    }
  ) { self.scan = scan }
  private lazy var surface = TransientPanel { [unowned self] in
    let panel = OverlayPanel(
      size: NSSize(width: 780, height: 540), autoHide: .clickOutside, isPinned: { true },
      content: RecognitionResultView(model: model))
    panel.onHide = { [weak self] in self?.clear() }
    return panel
  }

  /// 显示待识别状态后再打开面板，不激活应用。
  func show(_ image: CGImage) {
    request(image)
    model.close = { [weak self] in self?.surface.panel?.dismiss() }
    surface.open().present()
  }

  /// 更换待识别图；同一时刻只运行一个 Vision 请求，快速连点只保留最新的待处理图。
  func request(_ image: CGImage) {
    clear()
    model.image = image
    model.working = true
    requested = (image, generation)
    guard task == nil else { return }
    task = Task { [weak self] in
      while let (image, ticket) = self?.requested {
        guard let self else { return }
        let began = ContinuousClock.now
        Log.clipboard.notice(
          "查看识字结果开始 generation=\(ticket) width=\(image.width) height=\(image.height)")
        do {
          let lines = try await scan(image)
          if requested?.generation == ticket {
            model.text = OCR.text(lines, joined: false)
            model.working = false
          }
          Log.clipboard.notice(
            "查看识字结果结束 generation=\(ticket) lines=\(lines.count) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
          )
        } catch {
          if requested?.generation == ticket {
            model.working = false
            model.error = error.localizedDescription
          }
          Log.clipboard.error(
            "查看识字结果失败 generation=\(ticket) cause=\(String(reflecting: error), privacy: .public)")
        }
        if requested?.generation == ticket { break }
      }
      self?.task = nil
    }
  }

  /// 功能关闭或应用退出时收起面板，不创建尚未使用的窗口。
  func hide() {
    surface.panel?.hide()
    clear()
  }

  /// 作废旧结果；无法中断的单次 Vision 返回即释放，关闭后不发起下一次请求。
  private func clear() {
    generation &+= 1
    requested = nil
    model.clear()
  }
}

/// 左图右文的识字面板，加载、空结果和失败都有独立状态。
struct RecognitionResultView: View {
  @Bindable var model: RecognitionModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Label("识字结果", systemImage: "text.viewfinder").font(.headline)
        Spacer()
        Toggle("原图对照", isOn: $model.compares).toggleStyle(.checkbox)
        Button("关闭", systemImage: "xmark", action: model.close)
          .labelStyle(.iconOnly).buttonStyle(.plain).help("关闭（Esc）")
      }
      .padding(16)
      Hairline()
      HStack(spacing: 0) {
        if model.compares, let image = model.image {
          GeometryReader { proxy in
            Image(decorative: image, scale: 1)
              .resizable().aspectRatio(contentMode: .fit)
              .frame(width: proxy.size.width, height: proxy.size.height)
              .accessibilityLabel("识别的原图")
          }
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary.opacity(0.3))
          Divider()
        }
        result.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Hairline()
      HStack(spacing: 12) {
        Text(model.working ? "正在识别…" : "拖选文字后按 ⌘C，或使用右侧按钮")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("复制选中") { model.copy(selectionOnly: true) }
          .disabled(model.selectedText.isEmpty)
        Button("复制全部") { model.copy(selectionOnly: false) }
          .disabled(model.text.isEmpty).buttonStyle(BrandButtonStyle())
      }
      .padding(16)
    }
    .appAccent()
  }

  /// 不把失败呈现成“没有文字”；有效空结果才使用空态。
  @ViewBuilder private var result: some View {
    if model.working {
      ProgressView("正在识别文字…")
    } else if let error = model.error {
      EmptyState(symbol: "exclamationmark.triangle", title: "文字识别失败") {
        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
      }.padding(20)
    } else if model.text.isEmpty {
      EmptyState(symbol: "text.viewfinder", title: "没有识别到文字") {
        Text("原图仍可在左侧查看").foregroundStyle(.secondary)
      }.padding(20)
    } else {
      RecognitionTextView(model: model).padding(12)
    }
  }
}

/// 原生只读文本框保留跨行选字与系统键盘操作，复制也走项目统一的剪贴板入口。
private struct RecognitionTextView: NSViewRepresentable {
  let model: RecognitionModel

  /// 创建不自动取得焦点的可选择文本框。
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let text = RecognitionText(frame: .zero)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = false
    text.font = .systemFont(ofSize: 14)
    text.textColor = .labelColor
    text.textContainerInset = NSSize(width: 4, height: 8)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel("识别出的文字")
    text.delegate = context.coordinator
    text.onCopy = { [weak model] in model?.copy(selectionOnly: true) }
    text.onClose = { [weak model] in model?.close() }
    scroll.documentView = text
    return scroll
  }

  /// 只有结果内容变化时更新正文，避免选字时重置选区。
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? RecognitionText else { return }
    if text.string != model.text { text.string = model.text }
  }

  /// 保存选中文字，供按钮与系统复制命令共用。
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  /// 仅监听选区变化，不接管系统按键和文本排版。
  final class Coordinator: NSObject, NSTextViewDelegate {
    private let model: RecognitionModel

    /// 绑定当前面板模型。
    init(model: RecognitionModel) { self.model = model }

    /// 拖选、全选与键盘选区变化都回写同一份选中内容。
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      let string = view.string as NSString
      let range = view.selectedRange()
      model.selectedText = NSMaxRange(range) <= string.length ? string.substring(with: range) : ""
    }
  }
}

/// 系统复制菜单和 ⌘C 共用回调，避免绕过剪贴板历史的自写入规则。
private final class RecognitionText: NSTextView {
  var onCopy: () -> Void = {}
  var onClose: () -> Void = {}

  /// 文本框获得键盘时，Esc 仍只关闭当前结果面板。
  override func cancelOperation(_ sender: Any?) { onClose() }

  /// 把复制交给项目统一入口。
  override func copy(_ sender: Any?) { onCopy() }
}
