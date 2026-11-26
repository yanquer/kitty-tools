// 识字结果面板：保留原图对照，支持选择部分文字复制；快捷识字仍直接复制，不经过这里。

import AppKit
import OSLog
import SwiftUI

/// 一条原始识别行在 Vision 坐标系中的位置，以原始识别顺序区分重复文本。
struct RecognitionLocation: Equatable {
  let line: Int
  let box: CGRect
}

/// 将原始行框附在未经改写的 UTF-16 区间上，跟随 NSTextStorage 实际编辑移动。
private struct RecognitionLocations {
  private struct Span {
    var range: NSRange
    let location: RecognitionLocation
  }

  private var spans: [Span] = []
  private var length = 0

  /// 行之间和 OCR 的逐行文本使用同一个换行符，非法行框只丢位置、不丢文字。
  init(lines: [OCR.Line] = []) {
    let image = CGRect(x: 0, y: 0, width: 1, height: 1)
    for (index, line) in lines.enumerated() {
      let count = line.text.utf16.count
      if index > 0 { length += 1 }
      let box = line.box
      if count > 0, box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite {
        let clipped = box.intersection(image)
        if !clipped.isEmpty {
          spans.append(
            Span(
              range: NSRange(location: length, length: count),
              location: RecognitionLocation(line: index + 1, box: clipped)))
        }
      }
      length += count
    }
  }

  /// 触及原识别区间的编辑让该区间失效，其余位置按实际位移调整。
  mutating func edited(_ range: NSRange, delta: Int, newLength: Int) {
    let oldCount = range.length - delta
    guard range.location != NSNotFound, range.location >= 0, oldCount >= 0,
      length + delta == newLength, range.location <= length, oldCount <= length - range.location
    else {
      spans.removeAll()
      length = newLength
      return
    }
    let oldEnd = range.location + oldCount
    spans = spans.compactMap { span in
      if NSMaxRange(span.range) <= range.location { return span }
      guard span.range.location >= oldEnd else { return nil }
      var moved = span
      moved.range.location += delta
      return moved
    }
    length = newLength
  }

  /// 光标或选区须落在单个可确认区间内，跨行、新增文字及不完整组字都没有定位。
  func location(for selection: NSRange, in text: NSString) -> RecognitionLocation? {
    let start = selection.location
    guard text.length == length, start != NSNotFound, start >= 0, start <= length,
      selection.length <= length - start
    else { return nil }
    // 选区频繁变化，用已排序的区间二分查找，不扫描全部识别行。
    var low = 0
    var high = spans.count
    while low < high {
      let middle = (low + high) / 2
      if spans[middle].range.location <= start { low = middle + 1 } else { high = middle }
    }
    guard low > 0 else { return nil }
    let span = spans[low - 1]
    let end = NSMaxRange(span.range)
    let endOfSelectedLine = end < length && text.character(at: end) == 10 ? end + 1 : end
    if start < end && NSMaxRange(selection) <= endOfSelectedLine { return span.location }
    if selection.length == 0, start == end,
      start == length || text.character(at: start) == 10
    {
      return span.location
    }
    return nil
  }
}

/// 识字面板的短期状态，不持久化识别内容或选中文字。
@Observable final class RecognitionModel {
  var image: CGImage?
  var text = ""
  var selectedText = ""
  private(set) var originalText = ""
  private(set) var location: RecognitionLocation?
  private(set) var documentRevision = 0
  @ObservationIgnored private var originalLocations = RecognitionLocations()
  @ObservationIgnored private var currentLocations = RecognitionLocations()
  var canUndo = false
  var canRedo = false
  var editNotice: String?
  @ObservationIgnored var undo: () -> Void = {}
  @ObservationIgnored var redo: () -> Void = {}
  @ObservationIgnored var replaceText: ((String) -> Void)?
  var isEdited: Bool { text != originalText }
  var working = false
  var error: String?
  var compares = true
  @ObservationIgnored var close: () -> Void = {}
  /// 沿用统一写入入口；测试注入收集器，不触碰系统剪贴板。
  @ObservationIgnored var write: (String) -> Void = { Paster.write(string: $0, record: true) }

  /// 接收原始识别结果，纠错与恢复始终使用同一份原文快照。
  func accept(_ value: String) {
    documentRevision &+= 1
    originalLocations = RecognitionLocations()
    restoreLocations()
    originalText = value
    text = value
    selectedText = ""
    canUndo = false
    canRedo = false
    editNotice = nil
  }

  /// 采纳扫描结果时同时建立原始正文与原图行框。
  func accept(lines: [OCR.Line]) {
    accept(OCR.text(lines, joined: false))
    originalLocations = RecognitionLocations(lines: lines)
    restoreLocations()
  }

  /// 只在加载、恢复原文或确认为完整的撤销时重新采用原始区间。
  func restoreLocations() {
    currentLocations = originalLocations
    clearLocation()
  }

  /// 记录原生存储实际发生的变化，以区间而非文字匹配保留来源。
  func recordLocationEdit(_ range: NSRange, delta: Int, newLength: Int) {
    currentLocations.edited(range, delta: delta, newLength: newLength)
  }

  /// 用真实选区更新选中文字和来源，避免正文纠错时显示旧原图高亮。
  func select(_ range: NSRange, in value: NSString) {
    selectedText =
      range.location >= 0 && range.location != NSNotFound && range.location <= value.length
        && range.length <= value.length - range.location ? value.substring(with: range) : ""
    let next = currentLocations.location(for: range, in: value)
    if next != location { location = next }
  }

  /// 组字、替换结果或关闭时收起高亮。
  func clearLocation() {
    if location != nil { location = nil }
  }

  /// 恢复原始识别结果；存在编辑器时作为一次可撤销的普通编辑执行。
  func restoreOriginal() {
    if let replaceText {
      replaceText(originalText)
    } else {
      text = originalText
      selectedText = ""
    }
    if text == originalText { restoreLocations() }
  }

  /// 所有复制入口经 Paster 写入并记录用户主动留下的新文字。
  func copy(selectionOnly: Bool) {
    let value = selectionOnly ? selectedText : text
    guard !value.isEmpty else { return }
    write(value)
    Island.announce(selectionOnly ? "已复制选中文字" : "已复制全部文字")
  }

  /// 收起时释放图像和文字，取消的任务不能再回填内容。
  func clear() {
    documentRevision &+= 1
    image = nil
    text = ""
    originalText = ""
    originalLocations = RecognitionLocations()
    restoreLocations()
    selectedText = ""
    canUndo = false
    canRedo = false
    editNotice = nil
    undo = {}
    redo = {}
    replaceText = nil
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
            model.accept(lines: lines)
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
        Button("撤销", systemImage: "arrow.uturn.backward", action: model.undo)
          .labelStyle(.iconOnly).disabled(!model.canUndo).help("撤销（⌘Z）")
        Button("重做", systemImage: "arrow.uturn.forward", action: model.redo)
          .labelStyle(.iconOnly).disabled(!model.canRedo).help("重做（⇧⌘Z）")
        Button("恢复原文", action: model.restoreOriginal).disabled(!model.isEdited || model.working)
        Spacer()
        Toggle("原图对照", isOn: $model.compares).toggleStyle(.checkbox)
        Button("关闭", systemImage: "xmark", action: model.close)
          .labelStyle(.iconOnly).buttonStyle(.plain).help("关闭（Esc）")
      }
      .padding(16)
      Hairline()
      HStack(spacing: 0) {
        if model.compares, let image = model.image {
          RecognitionImagePreview(image: image, location: model.location)
            .id(ObjectIdentifier(image))
          Divider()
        }
        result.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Hairline()
      HStack(spacing: 12) {
        Text(
          model.editNotice
            ?? (model.working
              ? "正在识别…" : model.isEdited ? "已编辑 · 拖选文字后按 ⌘C 复制" : "可直接纠错，或拖选文字后按 ⌘C 复制")
        )
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
    } else if model.text.isEmpty && model.originalText.isEmpty {
      EmptyState(symbol: "text.viewfinder", title: "没有识别到文字") {
        Text("原图仍可在左侧查看").foregroundStyle(.secondary)
      }.padding(20)
    } else {
      RecognitionTextView(model: model).id(model.documentRevision).padding(12)
    }
  }
}

/// 原生纯文本编辑器支持纠错与有界撤销，复制和剪切走项目统一的剪贴板入口。
struct RecognitionTextView: NSViewRepresentable {
  let model: RecognitionModel

  /// 创建不自动取得焦点的可选择文本框。
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let text = RecognitionText(frame: .zero)
    text.isEditable = true
    text.allowsUndo = true
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticSpellingCorrectionEnabled = false
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
    text.string = model.text
    text.delegate = context.coordinator
    text.textStorage?.delegate = context.coordinator
    text.write = { [weak model] in model?.write($0) }
    text.onSettled = { [weak coordinator = context.coordinator, weak text] in
      if let text { coordinator?.changed(text) }
    }
    model.undo = { [weak text, weak coordinator = context.coordinator] in
      text?.breakUndoCoalescing()
      text?.undoManager?.undo()
      if let text { coordinator?.changed(text, finishingUndo: true) }
    }
    model.redo = { [weak text, weak coordinator = context.coordinator] in
      text?.undoManager?.redo()
      if let text { coordinator?.changed(text) }
    }
    model.replaceText = { [weak text] value in
      guard let text else { return }
      text.inputContext?.discardMarkedText()
      text.unmarkText()
      text.breakUndoCoalescing()
      text.insertText(
        value, replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
      text.breakUndoCoalescing()
      text.onSettled()
    }
    text.onClose = { [weak model] in model?.close() }
    scroll.documentView = text
    return scroll
  }

  /// 只有结果内容变化时更新正文，避免选字时重置选区。
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? RecognitionText else { return }
    if text.string != model.text, !text.hasMarkedText() {
      context.coordinator.installText(in: text)
    }
  }

  /// 释放文本视图时清空撤销操作，避免栈中的目标对象延长正文与图片的生命期。
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    if let text = scroll.documentView as? RecognitionText {
      text.onSettled = {}
      text.history.removeAllActions()
      text.delegate = nil
      text.textStorage?.delegate = nil
    }
    scroll.documentView = nil
  }

  /// 保存选中文字，供按钮与系统复制命令共用。
  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  /// 监听文字存储和选区，不替换系统编辑、组字及撤销行为。
  final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    private let model: RecognitionModel
    private var installingText = false

    /// 绑定当前面板模型。
    init(model: RecognitionModel) { self.model = model }

    /// 新识别结果的区间随模型一起提供，更新编辑器时不把加载当成用户改写。
    func installText(in text: RecognitionText) {
      installingText = true
      defer { installingText = false }
      text.string = model.text
      text.history.removeAllActions()
      text.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// 原生存储同步报告已提交到存储的字符差异，属性更新不影响来源。
    nonisolated func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard editedMask.contains(.editedCharacters) else { return }
      let newLength = textStorage.length
      MainActor.assumeIsolated {
        guard !installingText else { return }
        model.recordLocationEdit(editedRange, delta: delta, newLength: newLength)
      }
    }

    /// 原生文本变化回写当前正文，组字期间不反向覆盖输入中的候选文本。
    func textDidChange(_ notification: Notification) {
      if let text = notification.object as? RecognitionText { changed(text) }
    }

    /// 同步文字、选区与撤销状态，按钮和快捷键复制均使用当前编辑内容。
    func changed(_ text: RecognitionText, finishingUndo: Bool = false) {
      guard !installingText else { return }
      guard !text.hasMarkedText() else { return model.clearLocation() }
      model.text = text.string
      if finishingUndo || text.history.isUndoing, model.text == model.originalText {
        model.restoreLocations()
      }
      model.select(text.selectedRange(), in: text.string as NSString)
      model.canUndo = text.history.canUndo
      model.canRedo = text.history.canRedo
    }

    /// 限制额外输入规模，原始识别结果超过预算时仍完整保留并允许等长纠错。
    func textView(
      _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      let limit = max(128_000, (model.originalText as NSString).length)
      let length =
        (textView.string as NSString).length - affectedCharRange.length
        + ((replacementString ?? "") as NSString).length
      guard length <= limit else {
        model.editNotice = "文字已达编辑上限，请减少内容后再粘贴"
        return false
      }
      model.editNotice = nil
      return true
    }

    /// 拖选、全选与键盘选区变化都回写同一份选中内容。
    func textViewDidChangeSelection(_ notification: Notification) {
      guard !installingText, let view = notification.object as? NSTextView else { return }
      guard !view.hasMarkedText() else { return model.clearLocation() }
      model.select(view.selectedRange(), in: view.string as NSString)
    }
  }
}

/// 系统复制菜单和 ⌘C 共用回调，避免绕过剪贴板历史的自写入规则。
final class RecognitionText: NSTextView {
  let history: UndoManager = {
    let manager = UndoManager()
    manager.levelsOfUndo = 100
    return manager
  }()
  var write: (String) -> Void = { Paster.write(string: $0, record: true) }
  var onSettled: () -> Void = {}

  /// 每个结果编辑器使用独立撤销栈，不串到其他面板的正文。
  override var undoManager: UndoManager? { history }
  var onClose: () -> Void = {}

  /// 文本框获得键盘时，Esc 仍只关闭当前结果面板。
  override func cancelOperation(_ sender: Any?) { onClose() }

  /// 把复制交给项目统一入口。
  override func copy(_ sender: Any?) {
    let range = selectedRange()
    let value = string as NSString
    guard range.length > 0, NSMaxRange(range) <= value.length else { return }
    write(value.substring(with: range))
    Island.announce("已复制选中文字")
  }

  /// 剪切先经统一入口复制，再由系统删除以保留原生撤销与组字行为。
  override func cut(_ sender: Any?) {
    guard selectedRange().length > 0 else { return }
    copy(sender)
    delete(sender)
  }

  /// 组字确认或取消后立即同步，避免没有额外文本通知时保留旧正文。
  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    onSettled()
  }

  /// 失去组字状态后让复制入口看到已提交文字。
  override func unmarkText() {
    super.unmarkText()
    onSettled()
  }

}
