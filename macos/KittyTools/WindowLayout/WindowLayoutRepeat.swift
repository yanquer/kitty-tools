// 重复窗口动作的策略，区分分区循环、相邻显示器、显示器轮换和对侧切换。

import Foundation

/// 使用稳定字符串存储重复行为，默认对应本机旧工具的相邻显示器模式。
nonisolated enum WindowLayoutRepeat: String, CaseIterable, Identifiable {
  case none, resize, across, acrossAndResize, displays, quadrants, opposite
  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: "保持同一区域"
    case .resize: "循环调整分区"
    case .across: "半屏动作移到相邻显示器"
    case .acrossAndResize: "跨屏并在边界调整分区"
    case .displays: "循环切换显示器"
    case .quadrants: "四角换位置，半屏换大小"
    case .opposite: "半屏动作移到对侧"
    }
  }

  /// 计算下一次动作、屏幕与历史动作，跨到对侧后下一次按键先回到所按的半屏。
  func target(
    for action: WindowLayoutAction, count: Int, screen: Int, screens: [CGRect],
    portrait: Bool
  ) -> (action: WindowLayoutAction, screen: Int, recorded: WindowLayoutAction) {
    let screenCount = screens.count
    guard self != .none else { return (action, screen, action) }
    let facing: [WindowLayoutAction: WindowLayoutAction] = [
      .leftHalf: .rightHalf, .rightHalf: .leftHalf, .topHalf: .bottomHalf, .bottomHalf: .topHalf,
    ]
    if self == .displays, screenCount > 1 { return (action, (screen + 1) % screenCount, action) }
    if self == .opposite, let opposite = facing[action] { return (opposite, screen, opposite) }
    if self == .across || self == .acrossAndResize, let opposite = facing[action] {
      guard screenCount > 1 else {
        return (
          self == .acrossAndResize
            ? WindowLayout.repeated(action, count: count, portrait: portrait) : action, screen,
          action
        )
      }
      if action == .topHalf || action == .bottomHalf {
        guard
          let destination = WindowLayoutGeometry.verticalNeighbor(
            from: screen, screens: screens,
            above: action == .topHalf, wrap: self == .across)
        else {
          return (
            self == .acrossAndResize
              ? WindowLayout.repeated(action, count: count, portrait: portrait) : action, screen,
            action
          )
        }
        return (opposite, destination, opposite)
      }
      let reverse = action == .leftHalf || action == .topHalf
      let destination = (screen + (reverse ? screenCount - 1 : 1)) % screenCount
      let atBoundary = reverse ? screen == 0 : screen == screenCount - 1
      if self == .acrossAndResize, atBoundary {
        return (WindowLayout.repeated(action, count: count, portrait: portrait), screen, action)
      }
      return (opposite, destination, opposite)
    }
    if self == .quadrants {
      let corners: [WindowLayoutAction] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
      if let index = corners.firstIndex(of: action) {
        return (corners[(index + count) % corners.count], screen, action)
      }
    }
    return (WindowLayout.repeated(action, count: count, portrait: portrait), screen, action)
  }
}
