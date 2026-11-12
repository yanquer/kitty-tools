// 窗口切换器的数据与纯交互规则，统一搜索、最近使用排序和循环选择。

import AppKit
import Observation

/// 窗口与所属应用的展示快照，窗口编号用于追溯及操作定位。
struct SwitchWindow: Identifiable {
  let window: DockWindow
  let pid: pid_t
  let appName: String
  var id: CGWindowID { window.id }
  var title: String { window.title.isEmpty ? "未提供窗口标题" : window.title }
}

/// 保持搜索与选中状态，异步刷新期间按稳定窗口编号保留选择。
@Observable final class WindowSwitcherModel {
  var windows: [SwitchWindow] = [] {
    didSet { updateResults() }
  }
  var query = "" {
    didSet { updateResults() }
  }
  var selectedID: CGWindowID? {
    didSet { if selectedID != oldValue { onSelectionChange() } }
  }
  var columns = 4
  private(set) var results: [SwitchWindow] = []
  var loading = false
  var issue: String?
  var searching = false
  var focusRequest = 0
  var images: [CGWindowID: CGImage] = [:]
  var icons: [pid_t: NSImage] = [:]
  var manageable = Set<CGWindowID>()
  var closable = Set<CGWindowID>()
  var onSelectionChange: () -> Void = {}
  var screenRecording = false
  var onConfirm: () -> Void = {}
  var onClose: () -> Void = {}
  var onMinimize: () -> Void = {}
  var onSearch: () -> Void = {}
  var onRetry: () -> Void = {}

  /// 只在窗口列表或搜索词变化时过滤，缩略图到达时不重复扫描标题。
  private func updateResults() {
    results = Self.filtered(windows, query: query)
    reconcileSelection()
  }
  var selected: SwitchWindow? { results.first { $0.id == selectedID } }

  /// 所有关键词都须匹配应用名或标题，忽略大小写与重音差异。
  static func filtered(_ windows: [SwitchWindow], query: String) -> [SwitchWindow] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return windows }
    return windows.filter { item in
      let text = item.appName + " " + item.window.title
      return terms.allSatisfy {
        text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
  }

  /// 已观察到的焦点顺序优先，其余沿用窗口服务器的前后顺序作为启动基线。
  static func ordered(
    _ windows: [SwitchWindow], recent: [CGWindowID: UInt64], stacking: [CGWindowID: Int]
  ) -> [SwitchWindow] {
    windows.sorted {
      let left = recent[$0.id] ?? 0
      let right = recent[$1.id] ?? 0
      if left != right { return left > right }
      let a = stacking[$0.id] ?? Int.max
      let b = stacking[$1.id] ?? Int.max
      return a == b ? $0.id < $1.id : a < b
    }
  }

  /// 只有完整读取全部应用后才移除已消失窗口，当前应用或部分失败的刷新保留全局焦点历史。
  static func historyAfterRefresh(
    _ recent: [CGWindowID: UInt64], windows: [SwitchWindow], complete: Bool
  ) -> [CGWindowID: UInt64] {
    guard complete else { return recent }
    let ids = Set(windows.map(\.id))
    return recent.filter { ids.contains($0.key) }
  }

  /// 向前或向后循环选择，没有结果时清除选择。
  func move(_ delta: Int) {
    let items = results
    guard !items.isEmpty else {
      selectedID = nil
      return
    }
    let current = items.firstIndex { $0.id == selectedID }
    let base = current ?? (delta < 0 ? 0 : -1)
    let next = ((base + delta) % items.count + items.count) % items.count
    selectedID = items[next].id
  }

  /// 搜索或列表变化后优先保留原来的窗口，原窗口消失时选择第一项。
  func reconcileSelection() {
    let items = results
    if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
  }

  /// 命令键忽略仍按住的呼出修饰键，让按住 ⌥ 时的 ⌘F 能进入搜索。
  static func acceptsCommand(_ flags: NSEvent.ModifierFlags, held: NSEvent.ModifierFlags) -> Bool {
    let modifiers = flags.intersection([.command, .control, .option, .shift])
    return modifiers.contains(.command) && modifiers.subtracting(held).subtracting(.command).isEmpty
  }

  /// 读屏卡片的关闭动作绑定对应窗口，避免把旁白焦点误当作旧选择。
  func close(_ id: CGWindowID) {
    guard closable.contains(id), results.contains(where: { $0.id == id }) else { return }
    selectedID = id
    onClose()
  }

  /// 读屏卡片的最小化动作同样按稳定窗口编号选择目标。
  func minimize(_ id: CGWindowID) {
    guard manageable.contains(id), results.contains(where: { $0.id == id }) else { return }
    selectedID = id
    onMinimize()
  }

  /// 输入框内的命令键，组字中的按键由系统输入法优先消费。
  func command(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.insertTab(_:)):
      move(1)
    case #selector(NSResponder.moveUp(_:)),
      #selector(NSResponder.insertBacktab(_:)):
      move(-1)
    case #selector(NSResponder.insertNewline(_:)): onConfirm()
    default: return false
    }
    return true
  }
}
