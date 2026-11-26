// 截图历史多选后的简单拼图面板：调整顺序、横竖拼接与网格，或每图一页导出 PDF。

import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 一次本地拖动的插入位置，按可见行的上半或下半定位，不依赖文件路径。
struct ShotCompositionInsertion: Equatable {
  let anchor: UUID
  let before: Bool

  /// 只在滚动区与有效图片行重叠时接受落点，外部松手不改变顺序。
  static func at(
    _ point: CGPoint, viewport: CGRect, rows: [UUID: CGRect], order: [UUID]
  ) -> Self? {
    guard viewport.contains(point),
      let id = order.first(where: { rows[$0]?.contains(point) == true }), let row = rows[id]
    else { return nil }
    return Self(anchor: id, before: point.y < row.midY)
  }
}

/// 面板只持有文件快照与缩小的预览，原图逐张解码，不跨任务缓存。
@Observable final class ShotCompositionModel {
  var sources: [ShotComposition.Source] = []
  var options = ShotComposition.Options()
  var pdf = false
  private(set) var previewSourceID: UUID?
  var previewPage: Int { sources.firstIndex { $0.id == previewSourceID } ?? 0 }
  var previewSource: ShotComposition.Source? {
    sources.first { $0.id == previewSourceID } ?? sources.first
  }
  var preview: CGImage?
  var preparing = false
  var rendering = false
  var exporting = false
  var error: String?
  var exported: URL? { didSet { exportedImageCount = nil } }
  private(set) var exportedImageCount: Int?
  var choosing = false
  private var directories: [URL] = []
  private var importedBytes = 0
  private(set) var cropTarget: UUID?
  private(set) var cropDraft: ShotCropDraft?
  private var cropTask: Task<Void, Never>?
  private var thumbnailWorker: Task<Void, Never>?
  private var pendingThumbnails: [UUID: ShotComposition.Source] = [:]
  var canImport: Bool { !preparing && !exporting && !choosing && cropTarget == nil }
  var outputPlan: ShotComposition.Plan? {
    try? ShotComposition.plan(sizes: sources.map { try $0.adjustedSize() }, options: options)
  }
  @ObservationIgnored var close: () -> Void = {}
  private var loadingTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var generation = 0
  private var filePanel: NSSavePanel?
  private var undoEdits: [[ShotComposition.Source]] = []
  private var redoEdits: [[ShotComposition.Source]] = []
  private(set) var reorderingID: UUID?
  private(set) var reorderInsertion: ShotCompositionInsertion?
  var canUndoEdit: Bool { canImport && reorderingID == nil && !undoEdits.isEmpty }
  var canRedoEdit: Bool { canImport && reorderingID == nil && !redoEdits.isEmpty }

  /// 先固定用户提交的那批图片，后续预览和导出始终读取同一批已合成标注的快照。
  func prepare(_ items: [ShotHistory.Item], history: ShotHistory) {
    clear()
    guard ShotComposition.accepts(items) else {
      error = "请选择 2–20 张截图或长截图；录屏、录音和动图不能参与拼图"
      return
    }
    preparing = true
    let ticket = generation
    loadingTask = Task { [weak self] in
      do {
        var urls: [URL] = []
        var labels: [String] = []
        for item in items {
          try Task.checkCancellation()
          guard let current = history.item(item.id), let url = await history.dragFile(for: current)
          else {
            throw ShotComposition.Failure(message: "无法读取选中的图片，请回到截图历史重新选择")
          }
          urls.append(url)
          labels.append(ShotHistoryModel.caption(current))
        }
        let batch = try await ImageImport.snapshots(urls, labels: labels)
        guard !Task.isCancelled, let self, generation == ticket else {
          ImageImport.discard(batch.directory)
          return
        }
        adopt(batch)
        preparing = false
        refreshPreview()
      } catch {
        guard !Task.isCancelled, let self, generation == ticket else { return }
        preparing = false
        self.error = error.localizedDescription
        Log.storage.error(
          "准备截图合成失败 count=\(items.count) cause=\(String(reflecting: error), privacy: .public)")
      }
    }
  }

  /// 采用一批完整副本，直到会话关闭才回收，避免正在生成的预览读到被移除的文件。
  private func adopt(_ batch: ImageImport.Batch, replacing id: UUID? = nil) {
    directories.append(batch.directory)
    importedBytes += batch.bytes
    if let id, let index = sources.firstIndex(where: { $0.id == id }),
      let first = batch.sources.first
    {
      sources[index] = ShotComposition.Source(
        id: id, url: first.url, size: first.size, label: first.label, thumbnail: first.thumbnail,
        originalFilename: first.originalFilename)
    } else {
      sources.append(contentsOf: batch.sources)
    }
  }

  /// 添加或替换整批成功才改变列表；失败保持原图片、原顺序与预览。
  func importFiles(_ urls: [URL], replacing id: UUID? = nil) {
    guard canImport, reorderingID == nil, !urls.isEmpty else { return }
    let count = id == nil ? sources.count + urls.count : sources.count
    guard count <= ShotComposition.maximumCount,
      id == nil || (urls.count == 1 && sources.contains(where: { $0.id == id }))
    else {
      error = id == nil ? "最多只能放 20 张图片，请先移除部分图片" : "请选择一张图片替换当前项"
      Log.storage.notice("导入图片拒绝 stage=selection count=\(urls.count) replacing=\(id != nil)")
      return
    }
    preparing = true
    error = nil
    exported = nil
    let ticket = generation
    let budget = ImageImport.maximumSessionBytes - importedBytes
    loadingTask = Task { [weak self] in
      do {
        let batch = try await ImageImport.snapshots(urls, remainingBytes: budget)
        guard !Task.isCancelled, let self, generation == ticket else {
          ImageImport.discard(batch.directory)
          return
        }
        adopt(batch, replacing: id)
        undoEdits.removeAll()
        redoEdits.removeAll()
        preparing = false
        refreshPreview()
      } catch {
        guard !Task.isCancelled, let self, generation == ticket else { return }
        preparing = false
        self.error = error.localizedDescription
      }
    }
  }

  /// 文件选择由用户按钮发起；取消或面板已关闭时不改变当前会话。
  func chooseFiles(replacing id: UUID? = nil) {
    guard canImport, reorderingID == nil else { return }
    choosing = true
    let ticket = generation
    Task { [weak self] in
      guard self?.generation == ticket else { return }
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.image]
      panel.allowsMultipleSelection = id == nil
      panel.canChooseDirectories = false
      panel.title = id == nil ? "添加图片" : "替换图片"
      self?.filePanel = panel
      let response = await FilePanel.begin(panel)
      if self?.filePanel === panel { self?.filePanel = nil }
      guard let self, generation == ticket else { return }
      choosing = false
      if response == .OK { importFiles(panel.urls, replacing: id) }
    }
  }

  /// 移除只影响本次输出，不删除外部原文件或截图历史。
  func remove(_ id: UUID) {
    guard canImport, let index = sources.firstIndex(where: { $0.id == id }) else { return }
    recordEdit()
    pendingThumbnails.removeValue(forKey: id)
    sources.remove(at: index)
    if previewSourceID == id {
      previewSourceID = sources.isEmpty ? nil : sources[min(index, sources.count - 1)].id
    }
    refreshPreview()
  }

  /// 快速换布局只保留最后一轮预览，旧结果不会覆盖新参数；失败时撤掉旧预览。
  func refreshPreview(contentsChanged: Bool = true) {
    previewTask?.cancel()
    preview = nil
    error = nil
    if contentsChanged { exported = nil }
    rendering = false
    guard !sources.isEmpty else {
      previewSourceID = nil
      return
    }
    if !sources.contains(where: { $0.id == previewSourceID }) { previewSourceID = sources[0].id }
    rendering = true
    let sources = sources
    let selected = previewSource!
    let page = previewPage + 1
    let pdf = pdf
    let options = options
    previewTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(120))
        let image =
          pdf
          ? try await ShotComposition.renderPDFPage(selected, options: options)
          : try await ShotComposition.render(sources, options: options, maximum: 1000)
        guard !Task.isCancelled, let self else { return }
        preview = image
        rendering = false
      } catch {
        guard !Task.isCancelled, let self else { return }
        rendering = false
        self.error = error.localizedDescription
        Log.storage.error(
          "截图合成预览失败 pdf=\(pdf) page=\(page) source=\(selected.id.uuidString, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
        )
      }
    }
  }

  /// 翻页只改变当前预览，保留图片顺序和已导出文件的成功提示。
  func showPage(_ index: Int) {
    guard pdf, canImport, sources.indices.contains(index) else { return }
    previewSourceID = sources[index].id
    refreshPreview(contentsChanged: false)
  }

  /// 上下按钮与拖动共用同一排序入口，保持原来正在看的 PDF 图片。
  func move(_ id: UUID, by step: Int) {
    guard canImport, let from = sources.firstIndex(where: { $0.id == id }) else { return }
    let (to, overflow) = from.addingReportingOverflow(step)
    guard !overflow, to != from, sources.indices.contains(to) else { return }
    reorder(id, to: ShotCompositionInsertion(anchor: sources[to].id, before: to < from))
  }

  /// 开始会话内拖动，仅记录身份；直到有效落点提交才改变列表。
  func beginReorder(_ id: UUID) {
    guard canImport, sources.count > 1, sources.contains(where: { $0.id == id }) else { return }
    reorderingID = id
    reorderInsertion = nil
  }

  /// 只显示有实际变化的插入线，包含拖离面板、落回原位或目标失效的情况。
  func previewReorder(at insertion: ShotCompositionInsertion?) {
    guard let id = reorderingID else { return }
    let valid = insertion.flatMap { target in moveIndices(id, to: target).map { _ in target } }
    if reorderInsertion != valid { reorderInsertion = valid }
  }

  /// 一次松手最多提交一次排序，插入位置按图片身份重新核对。
  func finishReorder() {
    let id = reorderingID
    let target = reorderInsertion
    cancelReorder()
    if let id, let target { reorder(id, to: target) }
  }

  /// 清理临时拖动状态，不记入历史。
  func cancelReorder() {
    reorderingID = nil
    reorderInsertion = nil
  }

  /// 将行间位置换算为移除来源后的插入索引，拒绝原位和失效目标。
  private func moveIndices(_ id: UUID, to insertion: ShotCompositionInsertion) -> (Int, Int)? {
    guard let from = sources.firstIndex(where: { $0.id == id }),
      let anchor = sources.firstIndex(where: { $0.id == insertion.anchor })
    else { return nil }
    let slot = anchor + (insertion.before ? 0 : 1)
    let to = slot > from ? slot - 1 : slot
    return to == from ? nil : (from, to)
  }

  /// 按插入边界移动单张图片，中间各张保持相对顺序。
  private func reorder(_ id: UUID, to insertion: ShotCompositionInsertion) {
    guard canImport, let (from, to) = moveIndices(id, to: insertion) else { return }
    recordEdit()
    let source = sources.remove(at: from)
    sources.insert(source, at: to)
    refreshPreview()
    Log.storage.notice(
      "拼图排序采用 source=\(id.uuidString, privacy: .public) from=\(from + 1) to=\(to + 1)")
  }

  /// 历史共享会话副本与原始小图，跳过可重新生成的调整缓存。
  private func editSnapshot() -> [ShotComposition.Source] {
    sources.map {
      ShotComposition.Source(
        id: $0.id, url: $0.url, size: $0.size, label: $0.label, thumbnail: $0.thumbnail,
        edit: $0.edit, originalFilename: $0.originalFilename)
    }
  }

  /// 设置撤销上限，新提交的编辑会结束原来的重做分支。
  private func recordEdit() {
    cancelReorder()
    undoEdits.append(editSnapshot())
    if undoEdits.count > 30 { undoEdits.removeFirst() }
    redoEdits.removeAll()
  }

  /// 撤销当前拼图会话的最后一次列表编辑。
  func undoEdit() {
    guard canUndoEdit, let snapshot = undoEdits.popLast() else { return }
    redoEdits.append(editSnapshot())
    restoreEdit(snapshot, redo: false)
  }

  /// 重做刚撤销的列表编辑。
  func redoEdit() {
    guard canRedoEdit, let snapshot = redoEdits.popLast() else { return }
    undoEdits.append(editSnapshot())
    restoreEdit(snapshot, redo: true)
  }

  /// 保留同版本缩略图和仍在列表中的预览页，只为恢复的不同版本发出新请求。
  private func restoreEdit(_ snapshot: [ShotComposition.Source], redo: Bool) {
    let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    let index = previewPage
    sources = snapshot.map { source in
      if let previous = current[source.id], previous.url == source.url, previous.edit == source.edit
      {
        return previous
      }
      return source
    }
    if !sources.contains(where: { $0.id == previewSourceID }) {
      previewSourceID = sources.isEmpty ? nil : sources[min(index, sources.count - 1)].id
    }
    pendingThumbnails.removeAll()
    for source in sources where !source.edit.isIdentity && source.thumbnailEdit != source.edit {
      requestThumbnail(source.id)
    }
    refreshPreview()
    Log.storage.notice("拼图编辑历史 redo=\(redo) count=\(self.sources.count)")
  }

  /// 局部快捷键交给当前面板；自定义宽度输入时仍由原来的字段撤销栈处理。
  func handleHistoryShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
    guard !(window.firstResponder is NSTextView), Int(event.keyCode) == kVK_ANSI_Z,
      flags == .command || flags == [.command, .shift]
    else { return false }
    if flags.contains(.shift) {
      guard canRedoEdit else { return false }
      redoEdit()
    } else {
      guard canUndoEdit else { return false }
      undoEdit()
    }
    return true
  }

  /// 只加载当前图片的有界整图预览，取消或关闭后不回填旧编辑器。
  func beginCrop(_ id: UUID) {
    guard canImport, reorderingID == nil, let source = sources.first(where: { $0.id == id }) else {
      return
    }
    cropTask?.cancel()
    cropTarget = id
    cropDraft = nil
    error = nil
    let ticket = generation
    Log.storage.notice(
      "拼图裁剪开始 source=\(id.uuidString, privacy: .public) turns=\(source.edit.turns)")
    cropTask = Task { [weak self] in
      do {
        let image = try await ShotComposition.cropPreview(source)
        guard !Task.isCancelled, let self, generation == ticket, cropTarget == id else { return }
        cropDraft = ShotCropDraft(source: source, image: image)
      } catch {
        guard !Task.isCancelled, let self, generation == ticket, cropTarget == id else { return }
        cancelCrop()
        self.error = error.localizedDescription
        Log.storage.error(
          "拼图裁剪准备失败 source=\(id.uuidString, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
        )
      }
    }
  }

  /// 草稿采用前核对来源版本，图片变更时不能把旧裁剪应用到新内容。
  func applyCrop() {
    guard let draft = cropDraft,
      let index = sources.firstIndex(where: { $0.id == draft.source.id }),
      sources[index].url == draft.source.url, sources[index].size == draft.source.size,
      sources[index].edit == draft.source.edit
    else {
      cancelCrop()
      error = "图片已变化，请重新打开裁剪"
      Log.storage.notice("拼图裁剪拒绝 stage=source-version")
      return
    }
    do {
      let edit = try draft.appliedEdit()
      guard edit != sources[index].edit else {
        cancelCrop()
        return
      }
      recordEdit()
      sources[index].edit = edit
      requestThumbnail(sources[index].id)
      if pdf { previewSourceID = sources[index].id }
      cancelCrop()
      refreshPreview()
      Log.storage.notice(
        "拼图裁剪采用 source=\(draft.source.id.uuidString, privacy: .public) crop=\(String(describing: edit.crop), privacy: .public) turns=\(edit.turns)"
      )
    } catch {
      self.error = error.localizedDescription
      Log.storage.error(
        "拼图裁剪采用失败 source=\(draft.source.id.uuidString, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
      )
    }
  }

  /// 取消只撤下草稿，原图片、顺序和已导出提示保持原样。
  func cancelCrop() {
    if let cropTarget {
      Log.storage.notice("拼图裁剪收起 source=\(cropTarget.uuidString, privacy: .public)")
    }
    cropTask?.cancel()
    cropTask = nil
    cropTarget = nil
    cropDraft = nil
  }

  /// 单张正交旋转仅修改元数据，PNG 与 PDF 后续读取同一调整结果。
  func rotate(_ id: UUID, by step: Int) {
    guard canImport, step % 4 != 0, let index = sources.firstIndex(where: { $0.id == id }) else {
      return
    }
    recordEdit()
    sources[index].edit.turns = (sources[index].edit.turns + step % 4 + 4) % 4
    requestThumbnail(id)
    if pdf { previewSourceID = id }
    refreshPreview()
    Log.storage.notice(
      "拼图单张旋转 source=\(id.uuidString, privacy: .public) turns=\(self.sources[index].edit.turns)")
  }

  /// 恢复读取会话中的未修改副本，同时清除裁剪与旋转，不重新读取外部原文件。
  func restore(_ id: UUID) {
    guard canImport, let index = sources.firstIndex(where: { $0.id == id }),
      !sources[index].edit.isIdentity
    else { return }
    recordEdit()
    sources[index].edit = .init()
    sources[index].editedThumbnail = nil
    sources[index].thumbnailEdit = nil
    sources[index].thumbnailError = nil
    pendingThumbnails.removeValue(forKey: id)
    if pdf { previewSourceID = id }
    refreshPreview()
    Log.storage.notice("拼图单张恢复 source=\(id.uuidString, privacy: .public)")
  }

  /// 缩略图只保留各图片最新版本，整段会话使用一个后台工作循环。
  private func requestThumbnail(_ id: UUID) {
    guard let index = sources.firstIndex(where: { $0.id == id })
    else {
      pendingThumbnails.removeValue(forKey: id)
      return
    }
    sources[index].thumbnailError = nil
    guard !sources[index].edit.isIdentity else {
      pendingThumbnails.removeValue(forKey: id)
      return
    }
    let source = sources[index]
    pendingThumbnails[id] = source
    guard thumbnailWorker == nil else { return }
    let ticket = generation
    thumbnailWorker = Task { [weak self] in await self?.updateThumbnails(ticket: ticket) }
  }

  /// 读取失败独立标记在当前项；过期或关闭的结果不能修改新图片，也不覆盖导出失败原因。
  private func updateThumbnails(ticket: Int) async {
    defer { if generation == ticket { thumbnailWorker = nil } }
    while !Task.isCancelled, generation == ticket, let (id, source) = pendingThumbnails.first {
      pendingThumbnails.removeValue(forKey: id)
      do {
        let image = try await ShotComposition.thumbnail(for: source)
        guard !Task.isCancelled, generation == ticket,
          let index = sources.firstIndex(where: {
            $0.id == id && $0.url == source.url && $0.size == source.size && $0.edit == source.edit
          })
        else { continue }
        sources[index].editedThumbnail = image
        sources[index].thumbnailEdit = source.edit
        sources[index].thumbnailError = nil
      } catch {
        guard !Task.isCancelled, generation == ticket else { return }
        Log.storage.error(
          "拼图缩略图调整失败 source=\(id.uuidString, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
        )
        if let index = sources.firstIndex(where: {
          $0.id == id && $0.url == source.url && $0.size == source.size && $0.edit == source.edit
        }) {
          sources[index].editedThumbnail = nil
          sources[index].thumbnailEdit = source.edit
          sources[index].thumbnailError = error.localizedDescription
        }
      }
    }
  }

  /// 用户确认保存路径后固定参数执行导出；取消关闭不会显示成功或留下半成品。
  func save() {
    guard canImport, reorderingID == nil, !rendering, preview != nil, sources.count >= 2 else {
      return
    }
    exporting = true
    error = nil
    exported = nil
    let sources = sources
    let options = options
    let pdf = pdf
    let ticket = generation
    exportTask = Task { [weak self] in
      guard !Task.isCancelled, self?.generation == ticket else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = pdf ? [.pdf] : [.png]
      panel.nameFieldStringValue = pdf ? "截图合集.pdf" : "截图拼图.png"
      panel.canCreateDirectories = true
      panel.title = pdf ? "导出多页 PDF" : "导出拼图"
      self?.filePanel = panel
      let response = await FilePanel.begin(panel)
      if self?.filePanel === panel { self?.filePanel = nil }
      guard !Task.isCancelled, let self, generation == ticket else { return }
      guard response == .OK, let url = panel.url else {
        exporting = false
        return
      }
      do {
        try await ShotComposition.export(sources, options: options, pdf: pdf, to: url)
        guard !Task.isCancelled, generation == ticket else { return }
        exporting = false
        exported = url
        Island.announce("已导出\(pdf ? " PDF" : "拼图")")
      } catch {
        guard !Task.isCancelled, generation == ticket else { return }
        exporting = false
        self.error = error.localizedDescription
      }
    }
  }

  /// 独立 PNG 不依赖拼图预览是否可导出，也允许处理一张图。
  var canExportIndividualPNGs: Bool {
    canImport && reorderingID == nil && !rendering
      && (1...ShotComposition.maximumCount).contains(sources.count)
  }

  /// 用户启动逐张导出时固定来源顺序和调整，成功后显示整个已发布目录。
  func saveIndividualPNGs(into selectedDirectory: URL? = nil) {
    guard canExportIndividualPNGs else { return }
    exporting = true
    error = nil
    exported = nil
    let sources = sources
    let ticket = generation
    exportTask = Task { [weak self] in
      guard let self, !Task.isCancelled, generation == ticket else { return }
      let directory: URL?
      if let selectedDirectory {
        directory = selectedDirectory
      } else {
        directory = await chooseIndividualPNGDirectory()
      }
      guard !Task.isCancelled, generation == ticket else { return }
      guard let directory else {
        exporting = false
        return
      }
      do {
        let result = try await ShotComposition.exportIndividualPNGs(sources, into: directory)
        guard !Task.isCancelled, generation == ticket else { return }
        exporting = false
        exported = result
        exportedImageCount = sources.count
        Island.announce("已导出 \(sources.count) 张 PNG")
      } catch {
        guard !Task.isCancelled, generation == ticket else { return }
        exporting = false
        self.error = error.localizedDescription
      }
    }
  }

  /// 文件夹选择沿用现有原生面板，关闭当前会话时可以取消。
  private func chooseIndividualPNGDirectory() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.title = "逐张导出 PNG"
    panel.message = "按当前顺序导出每张调整后的图片，完成后在所选位置创建新文件夹。"
    panel.prompt = "导出到此处"
    filePanel = panel
    let response = await FilePanel.begin(panel)
    if filePanel === panel { filePanel = nil }
    return response == .OK ? panel.url : nil
  }

  /// 关闭、重开或功能停用时停止任务并释放缩略图、快照引用。
  func clear() {
    generation &+= 1
    cancelCrop()
    cancelReorder()
    undoEdits.removeAll()
    redoEdits.removeAll()
    thumbnailWorker?.cancel()
    thumbnailWorker = nil
    pendingThumbnails = [:]
    let panel = filePanel
    filePanel = nil
    panel?.cancel(nil)
    loadingTask?.cancel()
    previewTask?.cancel()
    exportTask?.cancel()
    loadingTask = nil
    previewTask = nil
    exportTask = nil
    sources = []
    previewSourceID = nil
    for directory in directories { ImageImport.discard(directory) }
    directories = []
    importedBytes = 0
    choosing = false
    preview = nil
    preparing = false
    rendering = false
    exporting = false
    error = nil
    exported = nil
  }
}

/// 原生浮层复用既有显示和释放机制，不建立新的窗口子类。
final class ShotCompositionPanel {
  let model = ShotCompositionModel()
  private let history: ShotHistory
  private lazy var surface = TransientPanel { [unowned self] in
    let panel = OverlayPanel(
      size: NSSize(width: 820, height: 620), autoHide: .clickOutside, isPinned: { true },
      content: ShotCompositionView(model: model))
    panel.onHide = { [weak self] in self?.model.clear() }
    panel.keyEquivalentHandler = { [weak self, weak panel] event in
      guard let self, let panel else { return false }
      return model.handleHistoryShortcut(event, in: panel)
    }
    return panel
  }

  /// 依赖当前截图历史，不自行创建数据库或读取其他用户目录。
  init(history: ShotHistory) { self.history = history }

  /// 以当前多选内容打开面板，加载阶段明确提示。
  func show(_ items: [ShotHistory.Item]) {
    model.close = { [weak self] in self?.surface.panel?.dismiss() }
    model.prepare(items, history: history)
    surface.open().present()
  }

  /// 从独立入口打开空面板，直接添加或拖入外部图片。
  func showFiles() {
    model.clear()
    model.close = { [weak self] in self?.surface.panel?.dismiss() }
    surface.open().present()
  }

  /// 截图功能关闭时取消正在处理的任务并收起已有窗口。
  func hide() {
    surface.panel?.hide()
    model.clear()
  }
}

/// 左侧内容预览、右侧布局与顺序，底栏始终显示处理结果和保存入口。
struct ShotCompositionView: View {
  @Bindable var model: ShotCompositionModel
  @State private var dropTargeted = false
  @State private var rowFrames: [UUID: CGRect] = [:]
  @State private var viewport = CGRect.null
  @State private var scrollPosition = ScrollPosition()
  @State private var scrollOffset: CGFloat = 0
  @State private var dragPoint: CGPoint?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("拼图与 PDF", systemImage: "square.grid.2x2").labelStyle(.titleAndIcon).font(.headline)
        Spacer()
        Button("撤销拼图编辑", systemImage: "arrow.uturn.backward", action: model.undoEdit)
          .disabled(!model.canUndoEdit).help("撤销拼图编辑（⌘Z）")
        Button("重做拼图编辑", systemImage: "arrow.uturn.forward", action: model.redoEdit)
          .disabled(!model.canRedoEdit).help("重做拼图编辑（⇧⌘Z）")
        Button("关闭", systemImage: "xmark", action: model.close)
          .help("关闭（Esc）")
      }.labelStyle(.iconOnly).buttonStyle(.plain).padding(16)
      Hairline()
      HStack(spacing: 0) {
        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            RoundedRectangle(cornerRadius: Style.Radius.card)
              .stroke(dropTargeted ? Style.brand : .clear, lineWidth: 2).padding(8)
          }
          .dropDestination(for: URL.self) { urls, _ in
            guard model.canImport, model.reorderingID == nil, !urls.isEmpty else { return false }
            model.importFiles(urls)
            return true
          } isTargeted: {
            dropTargeted = $0
          }
        Divider()
        controls.frame(width: 260)
      }
      Hairline()
      footer.padding(16)
    }
    .onChange(of: model.options) { _, _ in model.refreshPreview() }
    .onChange(of: model.pdf) { _, _ in model.refreshPreview() }
    .onChange(of: model.reorderingID) { _, id in
      if id == nil { dragPoint = nil }
    }
    .appAccent()
  }

  /// PDF 使用当前页的真实页框，PNG 的棋盘底只说明透明区域，不写入输出。
  private var preview: some View {
    VStack(spacing: 12) {
      if let draft = model.cropDraft {
        ShotCropEditor(draft: draft, apply: model.applyCrop, cancel: model.cancelCrop)
      } else if model.cropTarget != nil {
        ProgressView("正在准备裁剪…")
        Button("取消", action: model.cancelCrop)
      } else if model.preparing {
        ProgressView("正在准备图片…")
      } else if model.rendering {
        ProgressView("正在生成预览…")
      } else if let image = model.preview {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .background {
            if !model.pdf && model.options.background == .transparent { transparencyGrid }
          }
          .accessibilityLabel(model.pdf ? "PDF 第 \(model.previewPage + 1) 页预览" : "拼图预览")
        Text(model.pdf ? "每图一页，共 \(model.sources.count) 页" : "按右侧顺序排列，保留每张图的完整内容")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        EmptyState(
          symbol: "photo.on.rectangle",
          title: model.sources.isEmpty ? "添加要合成的图片" : "暂时无法预览"
        ) {
          Text(model.sources.isEmpty ? "拖入图片，或点右侧「添加…」。两张起可拼图，也可逐张导出。" : "请查看下方原因，或替换无法读取的图片")
            .foregroundStyle(.secondary)
        }
      }
      if model.cropTarget == nil {
        if model.pdf, !model.sources.isEmpty {
          pageNavigation
        } else if !model.sources.isEmpty, let plan = model.outputPlan {
          Text("输出：\(Int(plan.size.width)) × \(Int(plan.size.height)) 像素")
            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
          if plan.isLimited {
            Text(
              "受尺寸或像素预算限制，输出已按比例缩小；目标宽度 \(model.options.requestedWidth.map { String(Int($0)) } ?? "自动")。"
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
              horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(20)
    .background(.quaternary.opacity(0.3))
  }

  /// 上下页和当前文件名始终可见，加载或单页失败后也能查看其他页。
  private var pageNavigation: some View {
    VStack(spacing: 6) {
      HStack(spacing: 12) {
        Button("上一页", systemImage: "chevron.left") { model.showPage(model.previewPage - 1) }
          .disabled(!model.canImport || model.previewPage == 0)
        Text("第 \(model.previewPage + 1) / \(model.sources.count) 页").monospacedDigit()
        Button("下一页", systemImage: "chevron.right") { model.showPage(model.previewPage + 1) }
          .disabled(!model.canImport || model.previewPage + 1 == model.sources.count)
      }
      Text(model.previewSource?.label ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
        .lineLimit(2).help(model.previewSource?.label ?? "")
    }
  }

  /// 棋盘仅用于透明像素检查，随图片的适配框缩放，不把整块面板画成网格。
  private var transparencyGrid: some View {
    Canvas { context, size in
      let side: CGFloat = 10
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      for row in 0..<Int(ceil(size.height / side)) {
        for column in 0..<Int(ceil(size.width / side)) where (row + column) % 2 == 0 {
          let rect = CGRect(
            x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
          context.fill(Path(rect), with: .color(Color(white: 0.86)))
        }
      }
    }.accessibilityHidden(true)
  }

  /// 保持设置控件原生样式，导出期间锁定内容和顺序。
  private var controls: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Picker("输出", selection: $model.pdf) {
          Text("拼图 PNG").tag(false)
          Text("多页 PDF").tag(true)
        }.pickerStyle(.segmented)
        if !model.pdf {
          Picker("排列", selection: $model.options.layout) {
            ForEach(ShotComposition.Layout.allCases) { Text($0.title).tag($0) }
          }
          widthControls
          Stepper(
            "间距 \(Int(model.options.spacing)) 像素", value: $model.options.spacing, in: 0...64,
            step: 4)
          Stepper(
            "圆角 \(Int(model.options.cornerRadius)) 像素", value: $model.options.cornerRadius,
            in: 0...64, step: 4)
          Stepper(
            "留白 \(Int(model.options.margin)) 像素", value: $model.options.margin, in: 0...64, step: 4)
          backgroundPicker
        }
        if model.pdf { pdfControls }
        Divider()
        HStack {
          Text("图片 \(model.sources.count)/20").font(.system(size: 13, weight: .semibold))
          Spacer()
          Button("添加…", systemImage: "plus") { model.chooseFiles() }
            .disabled(
              model.reorderingID != nil || model.sources.count >= ShotComposition.maximumCount)
        }
        VStack(spacing: 0) {
          ForEach(model.sources) { source in
            orderRow(source)
              .padding(.vertical, 5)
              .overlay(alignment: model.reorderInsertion?.before == true ? .top : .bottom) {
                if model.reorderInsertion?.anchor == source.id {
                  Capsule().fill(Style.brand).frame(height: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
              }
              .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
              } action: { frame in
                rowFrames[source.id] = frame
                if let dragPoint { updateReorder(at: dragPoint) }
              }
          }
        }
        .padding(.vertical, model.sources.isEmpty ? 0 : -5)
        Text("最多 20 张静态图片，单张 64 MB，会话累计 256 MB；拼图最长边 8192 像素，超过上限等比缩小。PDF 每页图片最长边 4096 像素。")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
    }
    .scrollPosition($scrollPosition)
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      max(0, geometry.contentOffset.y + geometry.contentInsets.top)
    } action: { _, y in
      scrollOffset = y
    }
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: { frame in
      viewport = frame
      if let dragPoint { updateReorder(at: dragPoint) }
    }
    .onChange(of: model.sources.map(\.id)) { _, ids in
      let current = Set(ids)
      rowFrames = rowFrames.filter { current.contains($0.key) }
    }
    .task(id: edgeScrollStep) { await scrollWhileReordering() }
    .disabled(!model.canImport)
  }

  /// 图片列表靠近滚动区边缘时逐步滚动；到第一张或最后一张时停止。
  private var edgeScrollStep: CGFloat {
    guard model.reorderingID != nil, let point = dragPoint, viewport.contains(point),
      let first = model.sources.first.flatMap({ rowFrames[$0.id] }),
      let last = model.sources.last.flatMap({ rowFrames[$0.id] }),
      point.x >= first.minX, point.x <= first.maxX
    else { return 0 }
    if point.y <= viewport.minY + 28, first.minY < viewport.minY - 1 { return -12 }
    if point.y >= viewport.maxY - 28, last.maxY > viewport.maxY + 1 { return 12 }
    return 0
  }

  /// 仅在拖动触边时推进滚动，几何更新会重新计算插入线；手势结束随任务一起取消。
  private func scrollWhileReordering() async {
    let step = edgeScrollStep
    guard step != 0 else { return }
    while !Task.isCancelled, edgeScrollStep == step {
      scrollPosition.scrollTo(y: max(0, scrollOffset + step))
      do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
    }
  }

  /// 指针和行都使用面板中的同一坐标空间，滚动时用最新几何复算落点。
  private func updateReorder(at point: CGPoint) {
    model.previewReorder(
      at: ShotCompositionInsertion.at(
        point, viewport: viewport, rows: rowFrames, order: model.sources.map(\.id)))
  }

  /// 恢复图标与滚动状态，取消手势或离开面板不会提交排序。
  private func endReorder() {
    dragPoint = nil
    model.cancelReorder()
  }

  /// 把原生把手的局部坐标转换到行几何使用的坐标系，只有松手才提交。
  private func dragThumbnail(_ id: UUID, at point: CGPoint, ending: Bool) {
    if !ending, dragPoint == nil { model.beginReorder(id) }
    guard model.reorderingID == id else {
      if ending { endReorder() }
      return
    }
    dragPoint = point
    updateReorder(at: point)
    if ending {
      model.finishReorder()
      endReorder()
    }
  }

  /// 宽度预设和自定义共用唯一生效模式，高度由排版比例决定。
  private var widthControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("输出宽度", selection: $model.options.widthMode) {
        ForEach(ShotComposition.WidthMode.allCases) { Text($0.title).tag($0) }
      }
      if model.options.widthMode == .custom {
        HStack {
          Text("宽度")
          TextField("像素", value: $model.options.customWidth, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).accessibilityLabel("自定义 PNG 输出宽度")
          Text("像素").foregroundStyle(.secondary)
        }
      }
      if model.options.widthMode != .automatic {
        Text("宽度按整体排版等比缩放，间距与留白随之缩放。")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// 拼图使用固定内容底色，保留透明 PNG 的明确选项。
  private var backgroundPicker: some View {
    Picker("背景", selection: $model.options.background) {
      ForEach(ShotComposition.Background.allCases) { Text($0.title).tag($0) }
    }
  }

  /// PDF 参数单独计量，切换输出不改变 PNG 的背景、圆角或像素留白。
  private var pdfControls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker("纸张", selection: $model.options.paper) {
        ForEach(ShotComposition.Paper.allCases) { Text($0.title).tag($0) }
      }
      if model.options.paper == .a4 {
        Picker("方向", selection: $model.options.orientation) {
          ForEach(ShotComposition.Orientation.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
      }
      Stepper(
        "页边距 \(Int(model.options.pdfMargin)) 毫米", value: $model.options.pdfMargin, in: 0...40,
        step: 2)
      Picker("纸张背景", selection: $model.options.pdfBackground) {
        ForEach(ShotComposition.Background.allCases.filter { $0 != .transparent }) {
          Text($0.title).tag($0)
        }
      }
      Text("图片等比居中，保留完整内容；按图片尺寸时保留原始比例。")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
    }
  }

  /// 顺序号与图片的时间、来源同时展示，避免只靠编号辨认内容。
  private func orderRow(_ source: ShotComposition.Source) -> some View {
    let index = model.sources.firstIndex(where: { $0.id == source.id }) ?? 0
    return HStack(spacing: 6) {
      Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
      orderThumbnail(source)
      VStack(alignment: .leading, spacing: 3) {
        Text(source.label).font(.system(size: 12)).lineLimit(2).help(source.label)
        if !source.edit.isIdentity {
          Text(source.adjustmentDescription)
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button("上移", systemImage: "arrow.up") { model.move(source.id, by: -1) }
        .disabled(index == 0).help("上移第 \(index + 1) 张")
      Button("下移", systemImage: "arrow.down") { model.move(source.id, by: 1) }
        .disabled(index == model.sources.count - 1).help("下移第 \(index + 1) 张")
      Menu("更多", systemImage: "ellipsis") {
        Button("裁剪…") { model.beginCrop(source.id) }
        Button("向左旋转 90°") { model.rotate(source.id, by: -1) }
        Button("向右旋转 90°") { model.rotate(source.id, by: 1) }
        Button("恢复原图") { model.restore(source.id) }.disabled(source.edit.isIdentity)
        Divider()
        Button("替换图片…") { model.chooseFiles(replacing: source.id) }
        Button("移除", role: .destructive) { model.remove(source.id) }
      }
      .menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("第 \(index + 1) 张图片的更多操作")
    }
    .labelStyle(.iconOnly).buttonStyle(.borderless)
  }

  /// 缩略图既是拖动把手也是状态反馈，键盘与旁白仍可用旁边的上下按钮。
  private func orderThumbnail(_ source: ShotComposition.Source) -> some View {
    Group {
      if let thumbnail = source.adjustedThumbnail {
        Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "photo").foregroundStyle(.secondary)
          .accessibilityLabel(source.thumbnailError == nil ? "缩略图尚未就绪" : "缩略图生成失败")
      }
    }
    .frame(width: 36, height: 36)
    .opacity(model.reorderingID == source.id ? 0.45 : 1)
    .overlay {
      GeometryReader { proxy in
        let origin = proxy.frame(in: .global).origin
        ShotCompositionGrip(
          id: source.id, enabled: model.sources.count > 1 && model.canImport,
          help: source.thumbnailError ?? "拖动缩略图调整顺序",
          move: { point, ending in
            dragThumbnail(
              source.id, at: CGPoint(x: origin.x + point.x, y: origin.y + point.y),
              ending: ending)
          })
      }
      .accessibilityHidden(true)
    }
  }

  /// 错误、处理中与成功分别展示，保存失败可以在原面板重新尝试。
  private var footer: some View {
    HStack(spacing: 12) {
      if model.exporting {
        ProgressView().controlSize(.small)
        Text("正在导出…").font(.system(size: 12))
      } else if let error = model.error {
        Text(error).font(.system(size: 12)).foregroundStyle(Style.danger).lineLimit(3)
      } else if let url = model.exported {
        let title =
          model.exportedImageCount.map { "已导出 \($0) 张 PNG · \(url.lastPathComponent)" }
          ?? "已导出：\(url.lastPathComponent)"
        Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(title)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      } else {
        Text("预览与导出使用同一批图片快照").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("逐张导出 PNG…") { model.saveIndividualPNGs() }
        .help("按当前顺序保存裁剪和旋转后的图片")
        .disabled(!model.canExportIndividualPNGs)
      Button(model.pdf ? "导出 PDF…" : "导出 PNG…", action: model.save)
        .buttonStyle(BrandButtonStyle())
        .disabled(
          !model.canImport || model.reorderingID != nil || model.rendering || model.preview == nil
            || model.sources.count < 2)
    }
  }
}

/// 缩略图内的拖动把手只处理本窗口鼠标，和系统文件拖入及面板背景移动分开。
private struct ShotCompositionGrip: NSViewRepresentable {
  let id: UUID
  let enabled: Bool
  let help: String
  let move: (CGPoint, Bool) -> Void

  /// 为每张图片建立独立鼠标目标，滚动只移动同一个目标的位置。
  func makeNSView(context: Context) -> ShotCompositionDragView {
    ShotCompositionDragView(id: id)
  }

  /// 每次滚动后同步最新坐标和操作许可。
  func updateNSView(_ view: ShotCompositionDragView, context: Context) {
    view.enabled = enabled
    view.toolTip = help
    view.move = move
  }

  /// 拆除时只释放 AppKit 状态，面板关闭由模型清理，不能回写正在销毁的 SwiftUI 视图。
  static func dismantleNSView(_ view: ShotCompositionDragView, coordinator: ()) {
    view.endTracking()
    view.move = { _, _ in }
  }
}

/// 使用 AppKit 的本地鼠标序列，拖动时即使缩略图滚出可见范围也继续接收事件。
final class ShotCompositionDragView: NSView {
  let id: UUID
  var enabled = false {
    didSet {
      if oldValue != enabled { window?.invalidateCursorRects(for: self) }
    }
  }
  var move: (CGPoint, Bool) -> Void = { _, _ in }
  private var start: CGPoint?
  private var dragging = false

  /// 绑定稳定行身份，排序后仍使用同一个 AppKit 视图。
  init(id: UUID) {
    self.id = id
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// 可拖动时在缩略图范围显示抓手光标，交给系统管理其生命周期。
  override func resetCursorRects() {
    if enabled { addCursorRect(bounds, cursor: .openHand) }
  }

  /// 按下只记录起点，普通点击不改变顺序。
  override func mouseDown(with event: NSEvent) {
    if enabled { start = event.locationInWindow }
  }

  /// 移动超过四个点才开始拖动，坐标使用视图当前滚动位置。
  override func mouseDragged(with event: NSEvent) {
    guard enabled, let start else { return }
    let point = event.locationInWindow
    guard dragging || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
    dragging = true
    move(convert(point, from: nil), false)
  }

  /// 松手仅提交一次，窗外落点由排序模型判断。
  override func mouseUp(with event: NSEvent) {
    let wasDragging = dragging
    endTracking()
    if wasDragging { move(convert(event.locationInWindow, from: nil), true) }
  }

  /// 退出窗口或卸载时撤下拖动，不造成列表变更。
  func endTracking() {
    dragging = false
    start = nil
  }
}
