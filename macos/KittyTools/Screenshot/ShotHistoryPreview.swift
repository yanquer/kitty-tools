// 截图历史的空格预览状态。独立浏览当前筛选集合，单个后台读图工作只保留最后的目标。

import AppKit
import OSLog

/// 预览的图像、错误与游标独立于历史网格的选择。
@Observable final class ShotHistoryPreview {
  private struct Request: Equatable {
    let id: UUID
    let version: Int
    let operation = UUID()
  }

  private let history: ShotHistory
  private let loadOriginal: (UUID) async throws -> CGImage
  private var ordered: [UUID] = []
  private var current: Request?
  private var rendered: (request: Request, image: CGImage)?
  private(set) var error: String?
  @ObservationIgnored private var pending: Request?
  @ObservationIgnored private var worker: Task<Void, Never>?

  var isOpen: Bool { current != nil }
  var item: ShotHistory.Item? { current.flatMap { history.item($0.id) } }
  var index: Int? { current.flatMap { ordered.firstIndex(of: $0.id) } }
  var count: Int { ordered.count }
  var canMoveBack: Bool { (index ?? 0) > 0 }
  var canMoveForward: Bool { index.map { $0 + 1 < ordered.count } ?? false }

  /// 历史条目变化后立即停止采用旧帧，即使视图还没处理变更回调。
  var image: CGImage? {
    guard let current, let rendered, rendered.request == current,
      history.previewVersion(for: current.id) == current.version
    else {
      return nil
    }
    return rendered.image
  }

  /// 与历史窗口共享现有存储，预览只持有当前一张大图。
  init(history: ShotHistory, loadOriginal: ((UUID) async throws -> CGImage)? = nil) {
    self.history = history
    self.loadOriginal = loadOriginal ?? { try await history.quickPreviewOriginal(for: $0) }
  }

  /// 打开时以当前筛选结果为来源列表。
  @discardableResult func open(_ id: UUID, within candidates: [UUID]) -> Bool {
    guard candidates.contains(id), let version = history.previewVersion(for: id) else {
      return false
    }
    ordered = candidates
    request(id, version: version)
    return true
  }

  /// 切换预览位置不改变原网格选中项，首尾停在当前项。
  func move(by offset: Int) {
    guard let index, offset != 0 else { return }
    let (next, overflow) = index.addingReportingOverflow(offset)
    guard !overflow, ordered.indices.contains(next) else { return }
    let id = ordered[next]
    guard let version = history.previewVersion(for: id) else { return }
    request(id, version: version)
  }

  /// 筛选或历史变化后核对当前条目。删掉、过期或离开筛选范围就关闭；改标注则重读。
  func reconcile(with candidates: [UUID]) {
    guard let current else { return }
    guard candidates.contains(current.id), let version = history.previewVersion(for: current.id)
    else {
      return close()
    }
    if ordered != candidates { ordered = candidates }
    if version != current.version { request(current.id, version: version) }
  }

  /// 显式重试只读取当前条目，不回放旧的完结任务。
  func retry() {
    guard let current, let version = history.previewVersion(for: current.id) else { return }
    request(current.id, version: version)
  }

  /// 释放画面和等待读取的请求，在途系统解码返回后直接丢弃。
  func close() {
    current = nil
    pending = nil
    ordered = []
    rendered = nil
    error = nil
  }

  /// 新请求先清掉画面，再进入一个只取最新待处理请求的循环。
  private func request(_ id: UUID, version: Int) {
    let next = Request(id: id, version: version)
    current = next
    pending = next
    rendered = nil
    error = nil
    guard worker == nil else { return }
    worker = Task { [weak self] in await self?.readLatest() }
  }

  /// 解码回来先校验游标和图像版本，过期的原图不进入合成或显示。
  private func readLatest() async {
    defer { worker = nil }
    while let next = pending {
      pending = nil
      let began = ContinuousClock.now
      Log.storage.debug(
        "截图大图预览开始 operation=\(next.operation, privacy: .public) id=\(next.id, privacy: .public)")
      do {
        let original = try await loadOriginal(next.id)
        guard current == next else { continue }
        guard history.previewVersion(for: next.id) == next.version else { continue }
        let image = try history.composeQuickPreview(
          original, id: next.id, expectedVersion: next.version)
        rendered = (next, image)
        Log.storage.debug(
          "截图大图预览完成 operation=\(next.operation, privacy: .public) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
        )
      } catch let failure {
        guard current == next, history.previewVersion(for: next.id) == next.version else {
          continue
        }
        let value = failure as NSError
        let reason: String
        if let failure = failure as? ShotHistory.PreviewFailure {
          reason = failure.localizedDescription
        } else if value.domain == NSCocoaErrorDomain {
          reason = CocoaError(CocoaError.Code(rawValue: value.code)).localizedDescription
        } else {
          reason = "无法读取截图。"
        }
        error = reason
        Log.storage.error(
          "截图大图预览失败 operation=\(next.operation, privacy: .public) id=\(next.id, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code) reason=\(reason, privacy: .public) elapsed=\(String(describing: began.duration(to: .now)), privacy: .public)"
        )
      }
    }
  }
}
