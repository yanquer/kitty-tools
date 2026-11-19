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
  @ObservationIgnored var close: () -> Void = {}
  private var loadingTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var generation = 0

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
        var prepared: [ShotComposition.Source] = []
        for item in items {
          try Task.checkCancellation()
          guard let current = history.item(item.id), let url = await history.dragFile(for: current)
          else {
            throw ShotComposition.Failure(message: "无法读取选中的图片，请回到截图历史重新选择")
          }
          prepared.append(
            try await ShotComposition.source(
              id: item.id, url: url, label: ShotHistoryModel.caption(current)))
        }
        guard !Task.isCancelled, let self, generation == ticket else { return }
        sources = prepared
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

  /// 快速换布局只保留最后一轮预览，旧结果不会覆盖新参数；失败时撤掉旧预览。
  func refreshPreview() {
    previewTask?.cancel()
    preview = nil
    error = nil
    exported = nil
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
    guard !exporting, let from = sources.firstIndex(where: { $0.id == id }) else { return }
    let to = from + step
    guard sources.indices.contains(to) else { return }
    sources.swapAt(from, to)
    refreshPreview()
  }

  /// 用户确认保存路径后固定参数执行导出；取消关闭不会显示成功或留下半成品。
  func save() {
    guard !exporting, !preparing, !rendering, preview != nil, sources.count >= 2 else { return }
    exporting = true
    error = nil
    exported = nil
    let sources = sources
    let options = options
    let pdf = pdf
    let ticket = generation
    exportTask = Task { [weak self] in
      let panel = NSSavePanel()
      panel.allowedContentTypes = pdf ? [.pdf] : [.png]
      panel.nameFieldStringValue = pdf ? "截图合集.pdf" : "截图拼图.png"
      panel.canCreateDirectories = true
      panel.title = pdf ? "导出多页 PDF" : "导出拼图"
      let response = await FilePanel.begin(panel)
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
    loadingTask?.cancel()
    previewTask?.cancel()
    exportTask?.cancel()
    loadingTask = nil
    previewTask = nil
    exportTask = nil
    sources = []
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

  /// 截图功能关闭时取消正在处理的任务并收起已有窗口。
  func hide() {
    surface.panel?.hide()
    model.clear()
  }
}

/// 左侧内容预览、右侧布局与顺序，底栏始终显示处理结果和保存入口。
struct ShotCompositionView: View {
  @Bindable var model: ShotCompositionModel

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
        ProgressView("正在准备选中的截图…")
      } else if model.rendering {
        ProgressView("正在生成预览…")
      } else if let image = model.preview {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .accessibilityLabel(model.pdf ? "PDF 第一页预览" : "拼图预览")
        Text(model.pdf ? "每图一页，共 \(model.sources.count) 页；上方为第一页" : "按右侧顺序排列，保留每张图的完整内容")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      } else {
        EmptyState(symbol: "photo.on.rectangle", title: "暂时无法预览") {
          Text("请查看下方原因，或回到历史重新选择图片").foregroundStyle(.secondary)
        }
      }
    }
    .padding(20)
    .background(.quaternary.opacity(0.3))
  }

  /// 保持设置控件原生样式，导出期间锁定内容和顺序。
  private var controls: some View {
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
          "间距 \(Int(model.options.spacing)) 像素", value: $model.options.spacing, in: 0...64, step: 4)
        Toggle("圆角", isOn: $model.options.rounded)
      }
      Stepper(
        "留白 \(Int(model.options.margin)) 像素", value: $model.options.margin, in: 0...64, step: 4)
      Toggle("深色背景", isOn: $model.options.dark)
      Divider()
      Text("图片顺序").font(.system(size: 13, weight: .semibold))
      ScrollView {
        VStack(spacing: 10) {
          ForEach(model.sources) { source in orderRow(source) }
        }
      }
      Text("最多 20 张；拼图最长边 8192 像素，超过上限等比缩小。PDF 每页图片最长边 4096 像素。")
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .padding(16)
    .disabled(model.exporting || model.preparing)
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
      Text(source.label).font(.system(size: 12)).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("上移", systemImage: "arrow.up") { model.move(source.id, by: -1) }
        .disabled(index == 0).help("上移第 \(index + 1) 张")
      Button("下移", systemImage: "arrow.down") { model.move(source.id, by: 1) }
        .disabled(index == model.sources.count - 1).help("下移第 \(index + 1) 张")
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
          model.preparing || model.rendering || model.exporting || model.preview == nil
            || model.sources.count < 2)
    }
  }
}
