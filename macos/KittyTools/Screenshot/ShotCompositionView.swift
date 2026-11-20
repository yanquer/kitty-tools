// 截图历史多选后的简单拼图面板：调整顺序、横竖拼接与网格，或每图一页导出 PDF。

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// 面板只持有文件快照与缩小的预览，原图逐张解码，不跨任务缓存。
@Observable final class ShotCompositionModel {
  var sources: [ShotComposition.Source] = []
  var options = ShotComposition.Options()
  var pdf = false
  var preview: CGImage?
  var preparing = false
  var rendering = false
  var exporting = false
  var error: String?
  var exported: URL?
  var choosing = false
  private var directories: [URL] = []
  private var importedBytes = 0
  var canImport: Bool { !preparing && !exporting && !choosing }
  @ObservationIgnored var close: () -> Void = {}
  private var loadingTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var generation = 0
  private var filePanel: NSSavePanel?

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
        id: id, url: first.url, size: first.size, label: first.label, thumbnail: first.thumbnail)
    } else {
      sources.append(contentsOf: batch.sources)
    }
  }

  /// 添加或替换整批成功才改变列表；失败保持原图片、原顺序与预览。
  func importFiles(_ urls: [URL], replacing id: UUID? = nil) {
    guard canImport, !urls.isEmpty else { return }
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
    guard canImport else { return }
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
    guard canImport, sources.contains(where: { $0.id == id }) else { return }
    sources.removeAll { $0.id == id }
    refreshPreview()
  }

  /// 快速换布局只保留最后一轮预览，旧结果不会覆盖新参数；失败时撤掉旧预览。
  func refreshPreview() {
    previewTask?.cancel()
    preview = nil
    error = nil
    exported = nil
    rendering = false
    guard !sources.isEmpty else { return }
    rendering = true
    let sources = pdf ? Array(sources.prefix(1)) : sources
    var options = options
    if pdf { options.rounded = false }
    previewTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(120))
        let image = try await ShotComposition.render(sources, options: options, maximum: 1000)
        guard !Task.isCancelled, let self else { return }
        preview = image
        rendering = false
      } catch {
        guard !Task.isCancelled, let self else { return }
        rendering = false
        self.error = error.localizedDescription
        Log.storage.error("截图合成预览失败：\(String(reflecting: error), privacy: .public)")
      }
    }
  }

  /// 用明确的上移、下移按钮调整顺序，同时保留稳定图片身份。
  func move(_ id: UUID, by step: Int) {
    guard canImport, let from = sources.firstIndex(where: { $0.id == id }) else { return }
    let to = from + step
    guard sources.indices.contains(to) else { return }
    sources.swapAt(from, to)
    refreshPreview()
  }

  /// 用户确认保存路径后固定参数执行导出；取消关闭不会显示成功或留下半成品。
  func save() {
    guard canImport, !rendering, preview != nil, sources.count >= 2 else { return }
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

  /// 关闭、重开或功能停用时停止任务并释放缩略图、快照引用。
  func clear() {
    generation &+= 1
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

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("拼图与 PDF", systemImage: "square.grid.2x2").font(.headline)
        Spacer()
        Button("关闭", systemImage: "xmark", action: model.close)
          .labelStyle(.iconOnly).buttonStyle(.plain).help("关闭（Esc）")
      }.padding(16)
      Hairline()
      HStack(spacing: 0) {
        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
          .overlay {
            RoundedRectangle(cornerRadius: Style.Radius.card)
              .stroke(dropTargeted ? Style.brand : .clear, lineWidth: 2).padding(8)
          }
          .dropDestination(for: URL.self) { urls, _ in
            guard model.canImport, !urls.isEmpty else { return false }
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
    .appAccent()
  }

  /// 预览明确标注 PDF 每图一页，显示第一页不会伪装成整份文档。
  private var preview: some View {
    VStack(spacing: 12) {
      if model.preparing {
        ProgressView("正在准备图片…")
      } else if model.rendering {
        ProgressView("正在生成预览…")
      } else if let image = model.preview {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .accessibilityLabel(model.pdf ? "PDF 第一页预览" : "拼图预览")
        Text(model.pdf ? "每图一页，共 \(model.sources.count) 页；上方为第一页" : "按右侧顺序排列，保留每张图的完整内容")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        EmptyState(
          symbol: "photo.on.rectangle",
          title: model.sources.isEmpty ? "添加要合成的图片" : "暂时无法预览"
        ) {
          Text(model.sources.isEmpty ? "拖入图片，或点右侧「添加…」；至少两张可导出" : "请查看下方原因，或替换无法读取的图片")
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(20)
    .background(.quaternary.opacity(0.3))
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
          Stepper(
            "间距 \(Int(model.options.spacing)) 像素", value: $model.options.spacing, in: 0...64,
            step: 4)
          Toggle("圆角", isOn: $model.options.rounded)
        }
        Stepper(
          "留白 \(Int(model.options.margin)) 像素", value: $model.options.margin, in: 0...64, step: 4)
        Toggle("深色背景", isOn: $model.options.dark)
        Divider()
        HStack {
          Text("图片 \(model.sources.count)/20").font(.system(size: 13, weight: .semibold))
          Spacer()
          Button("添加…", systemImage: "plus") { model.chooseFiles() }
            .disabled(model.sources.count >= ShotComposition.maximumCount)
        }
        VStack(spacing: 10) {
          ForEach(model.sources) { source in orderRow(source) }
        }
        Text("最多 20 张静态图片，单张 64 MB，会话累计 256 MB；拼图最长边 8192 像素，超过上限等比缩小。PDF 每页图片最长边 4096 像素。")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
    }
    .disabled(!model.canImport)
  }

  /// 顺序号与图片的时间、来源同时展示，避免只靠编号辨认内容。
  private func orderRow(_ source: ShotComposition.Source) -> some View {
    let index = model.sources.firstIndex(where: { $0.id == source.id }) ?? 0
    return HStack(spacing: 6) {
      Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
      if let thumbnail = source.thumbnail {
        Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .frame(width: 36, height: 36).accessibilityHidden(true)
      }
      Text(source.label).font(.system(size: 12)).lineLimit(2).help(source.label)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("上移", systemImage: "arrow.up") { model.move(source.id, by: -1) }
        .disabled(index == 0).help("上移第 \(index + 1) 张")
      Button("下移", systemImage: "arrow.down") { model.move(source.id, by: 1) }
        .disabled(index == model.sources.count - 1).help("下移第 \(index + 1) 张")
      Menu("更多", systemImage: "ellipsis") {
        Button("替换图片…") { model.chooseFiles(replacing: source.id) }
        Button("移除", role: .destructive) { model.remove(source.id) }
      }
      .menuIndicator(.hidden).fixedSize()
      .accessibilityLabel("第 \(index + 1) 张图片的更多操作")
    }
    .labelStyle(.iconOnly).buttonStyle(.borderless)
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
        Text("已导出：\(url.lastPathComponent)").font(.system(size: 12)).lineLimit(1).truncationMode(
          .middle)
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      } else {
        Text("预览与导出使用同一批图片快照").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button(model.pdf ? "导出 PDF…" : "导出 PNG…", action: model.save)
        .buttonStyle(BrandButtonStyle())
        .disabled(
          !model.canImport || model.rendering || model.preview == nil
            || model.sources.count < 2)
    }
  }
}
