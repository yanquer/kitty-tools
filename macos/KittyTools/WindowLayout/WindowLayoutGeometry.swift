// 窗口布局的纯几何计算，覆盖细分网格、尺寸调整、跨屏映射和多窗口排布。

import CoreGraphics
import Foundation

/// 仅包含值的布局参数，界面、设置校验和执行层共用范围。
nonisolated struct WindowLayoutOptions: Equatable {
  var gap: CGFloat = 0
  var edgeGap: CGFloat = 0
  var step: CGFloat = 30
  var width: CGFloat = 1680
  var height: CGFloat = 1050
  var almost: CGFloat = 0.9
  var cascade: CGFloat = 30
  var sidebar: CGFloat = 400
  var portrait = true
  var screenProportions = true
  var keepCentered = true
  var minimumWidth: CGFloat = 0.25
  var minimumHeight: CGFloat = 0.25
}

/// 坐标使用辅助功能的主屏左上原点，避免混用 AppKit 的向上坐标。
nonisolated enum WindowLayoutGeometry {
  /// 计算单窗口动作，集合、还原和跨屏动作交给协调层处理。
  static func frame(
    for action: WindowLayoutAction, current: CGRect, in screen: CGRect,
    options: WindowLayoutOptions = .init()
  ) -> CGRect? {
    guard valid(current), valid(screen) else { return nil }
    let bounds = screen.insetBy(
      dx: min(options.edgeGap, screen.width / 4),
      dy: min(options.edgeGap, screen.height / 4))
    if let unit = action.unitRect(portrait: options.portrait && bounds.height > bounds.width) {
      return region(unit, in: bounds, gap: options.gap)
    }
    switch action {
    case .maximize: return bounds
    case .almostMaximize:
      return centered(
        CGSize(
          width: bounds.width * options.almost,
          height: bounds.height * options.almost), in: bounds)
    case .maximizeHeight:
      return clamped(
        CGRect(
          x: current.minX, y: bounds.minY,
          width: current.width, height: bounds.height), in: bounds)
    case .center: return centered(current.size, in: bounds)
    case .centerProminently:
      let size = CGSize(
        width: min(current.width, bounds.width), height: min(current.height, bounds.height))
      return clamped(
        CGRect(
          x: bounds.midX - size.width / 2, y: bounds.minY + (bounds.height - size.height) / 4,
          width: size.width, height: size.height), in: bounds)
    case .specified:
      let width = options.width <= 1 ? bounds.width * options.width : options.width
      let height = options.height <= 1 ? bounds.height * options.height : options.height
      return centered(CGSize(width: width, height: height), in: bounds)
    case .moveLeft, .moveRight, .moveUp, .moveDown:
      return moved(action, current: current, in: bounds)
    case .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight:
      let amount =
        [.smaller, .smallerWidth, .smallerHeight].contains(action) ? -options.step : options.step
      let width = current.width + ([.largerHeight, .smallerHeight].contains(action) ? 0 : amount)
      let height = current.height + ([.largerWidth, .smallerWidth].contains(action) ? 0 : amount)
      if amount < 0,
        width < bounds.width * options.minimumWidth
          || height < bounds.height * options.minimumHeight
      {
        return clamped(current, in: bounds)
      }
      let rect = CGRect(
        x: current.midX - max(1, width) / 2,
        y: current.midY - max(1, height) / 2, width: max(1, width), height: max(1, height))
      return clamped(
        options.keepCentered ? rect : CGRect(origin: current.origin, size: rect.size), in: bounds)
    case .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight,
      .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight:
      return scaled(action, current: current, in: bounds, options: options)
    default: return nil
    }
  }

  /// 加倍和折半保留动作名称对应的边缘，随后夹回可用屏幕。
  private static func scaled(
    _ action: WindowLayoutAction, current: CGRect, in bounds: CGRect,
    options: WindowLayoutOptions
  )
    -> CGRect
  {
    let vertical = action.rawValue.contains("Height")
    let factor: CGFloat = action.rawValue.hasPrefix("double") ? 2 : 0.5
    var rect = current
    if vertical {
      rect.size.height *= factor
      if action == .doubleHeightUp || action == .halveHeightDown {
        rect.origin.y = current.maxY - rect.height
      }
    } else {
      rect.size.width *= factor
      if action == .doubleWidthLeft || action == .halveWidthRight {
        rect.origin.x = current.maxX - rect.width
      }
    }
    if factor < 1,
      rect.width < bounds.width * options.minimumWidth
        || rect.height < bounds.height * options.minimumHeight
    {
      return clamped(current, in: bounds)
    }
    return clamped(rect, in: bounds)
  }

  /// 边缘移动保持原始尺寸，即使窗口大于当前屏幕也不将移动变成缩放。
  private static func moved(_ action: WindowLayoutAction, current: CGRect, in bounds: CGRect)
    -> CGRect
  {
    var rect = current
    switch action {
    case .moveLeft: rect.origin.x = bounds.minX
    case .moveRight: rect.origin.x = bounds.maxX - current.width
    case .moveUp: rect.origin.y = bounds.minY
    case .moveDown: rect.origin.y = bounds.maxY - current.height
    default: break
    }
    return rect
  }

  /// 相邻区域各退半个间距，外边缘由 edgeGap 独立控制。
  static func region(_ unit: CGRect, in bounds: CGRect, gap: CGFloat) -> CGRect {
    // 区域过小时限制间距，保证仍有可用像素，避免把最后一格推到屏幕外。
    let spacing = min(
      max(0, gap), max(0, min(bounds.width * unit.width, bounds.height * unit.height) - 1))
    let left = unit.minX > 0 ? spacing / 2 : 0
    let top = unit.minY > 0 ? spacing / 2 : 0
    let right = unit.maxX < 0.999999 ? spacing / 2 : 0
    let bottom = unit.maxY < 0.999999 ? spacing / 2 : 0
    let x = (bounds.minX + bounds.width * unit.minX).rounded() + left
    let y = (bounds.minY + bounds.height * unit.minY).rounded() + top
    let maxX = (bounds.minX + bounds.width * unit.maxX).rounded() - right
    let maxY = (bounds.minY + bounds.height * unit.maxY).rounded() - bottom
    return CGRect(x: x, y: y, width: max(1, maxX - x), height: max(1, maxY - y))
  }

  /// 窗口跨屏时保留位置与尺寸比例，也支持仅保留点尺寸并居中。
  static func transferred(
    _ frame: CGRect, from source: CGRect, to target: CGRect, proportional: Bool
  ) -> CGRect? {
    guard valid(frame), valid(source), valid(target) else { return nil }
    guard proportional else { return centered(frame.size, in: target) }
    return clamped(
      CGRect(
        x: target.minX + (frame.minX - source.minX) / source.width * target.width,
        y: target.minY + (frame.minY - source.minY) / source.height * target.height,
        width: frame.width / source.width * target.width,
        height: frame.height / source.height * target.height), in: target)
  }

  /// 拖离窗口保持指针在标题栏中的水平比例与垂直偏移。
  static func unsnapped(original: CGSize, current: CGRect, pointer: CGPoint, in bounds: CGRect)
    -> CGRect
  {
    let ratio = min(max((pointer.x - current.minX) / current.width, 0), 1)
    let offset = min(max(pointer.y - current.minY, 0), 40)
    return clamped(
      CGRect(
        x: pointer.x - original.width * ratio, y: pointer.y - offset,
        width: original.width, height: original.height), in: bounds)
  }

  /// 镜像保持窗口大小与纵坐标，仅翻转到屏幕另一侧的对称位置。
  static func mirrored(_ frame: CGRect, in bounds: CGRect) -> CGRect {
    CGRect(
      x: bounds.maxX - (frame.minX - bounds.minX) - frame.width,
      y: frame.minY, width: frame.width, height: frame.height)
  }

  /// 固定尺寸窗口保留原大小，在目标区域对应的边缘或中心放置。
  static func positionedFixed(_ current: CGRect, desired: CGRect, in bounds: CGRect) -> CGRect {
    let left = abs(desired.minX - bounds.minX) <= 1
    let right = abs(desired.maxX - bounds.maxX) <= 1
    let top = abs(desired.minY - bounds.minY) <= 1
    let bottom = abs(desired.maxY - bounds.maxY) <= 1
    let x =
      left && !right
      ? desired.minX
      : right && !left ? desired.maxX - current.width : desired.midX - current.width / 2
    let y =
      top && !bottom
      ? desired.minY
      : bottom && !top ? desired.maxY - current.height : desired.midY - current.height / 2
    return CGRect(
      x: max(bounds.minX, min(x, bounds.maxX - current.width)).rounded(),
      y: max(bounds.minY, min(y, bounds.maxY - current.height)).rounded(),
      width: current.width, height: current.height)
  }

  /// 平铺按行、按列或近方形网格排列，最后一行铺满剩余宽度。
  static func tiled(count: Int, in bounds: CGRect, action: WindowLayoutAction, gap: CGFloat)
    -> [CGRect]
  {
    guard (1...128).contains(count), valid(bounds) else { return [] }
    let columns =
      action == .tileRows ? 1 : action == .tileColumns ? count : Int(ceil(sqrt(Double(count))))
    let rows = (count + columns - 1) / columns
    return (0..<count).map { index in
      let row = index / columns
      let rowCount = min(columns, count - row * columns)
      let unit = CGRect(
        x: Double(index % columns) / Double(rowCount), y: Double(row) / Double(rows),
        width: 1 / Double(rowCount), height: 1 / Double(rows))
      return region(unit, in: bounds, gap: gap)
    }
  }

  /// 层叠窗口保留可见标题区域，数量很多时缩小错位距离。
  static func cascaded(count: Int, in bounds: CGRect, step: CGFloat) -> [CGRect] {
    guard (1...128).contains(count), valid(bounds) else { return [] }
    let offset = min(step, min(bounds.width, bounds.height) / CGFloat(max(1, count * 3)))
    let inset = CGFloat(count - 1) * offset
    return (0..<count).map { index in
      CGRect(
        x: bounds.minX + CGFloat(index) * offset, y: bounds.minY + CGFloat(index) * offset,
        width: bounds.width - inset, height: bounds.height - inset)
    }
  }

  /// 按最大相交面积选择窗口所属屏幕，完全在屏外时选择距离最近的屏幕。
  static func screenIndex(for frame: CGRect, screens: [CGRect]) -> Int? {
    guard valid(frame), !screens.isEmpty else { return nil }
    return screens.indices.max { a, b in
      let first = frame.intersection(screens[a])
      let second = frame.intersection(screens[b])
      let firstArea = first.isNull ? 0 : first.width * first.height
      let secondArea = second.isNull ? 0 : second.width * second.height
      if firstArea != secondArea { return firstArea < secondArea }
      return hypot(frame.midX - screens[a].midX, frame.midY - screens[a].midY)
        > hypot(frame.midX - screens[b].midX, frame.midY - screens[b].midY)
    }
  }

  /// 多屏编号优先按不重叠的上下排，再按横向位置，原始下标作为同位置的稳定退路。
  static func screenOrder(_ frames: [CGRect]) -> [Int] {
    let vertical = frames.indices.sorted {
      frames[$0].minY == frames[$1].minY ? $0 < $1 : frames[$0].minY < frames[$1].minY
    }
    var rows: [(end: CGFloat, indices: [Int])] = []
    for index in vertical {
      if let last = rows.indices.last, frames[index].minY < rows[last].end {
        rows[last].end = max(rows[last].end, frames[index].maxY)
        rows[last].indices.append(index)
      } else {
        rows.append((frames[index].maxY, [index]))
      }
    }
    return rows.flatMap { row in
      row.indices.sorted {
        if frames[$0].minX != frames[$1].minX { return frames[$0].minX < frames[$1].minX }
        if frames[$0].minY != frames[$1].minY { return frames[$0].minY < frames[$1].minY }
        return $0 < $1
      }
    }
  }

  /// 上下半屏跨屏只选择横向有重叠的上下显示器，回绕选择对侧最远的一块。
  static func verticalNeighbor(from index: Int, screens: [CGRect], above: Bool, wrap: Bool) -> Int?
  {
    guard screens.indices.contains(index) else { return nil }
    let source = screens[index]
    let candidates = screens.indices.compactMap {
      other -> (index: Int, distance: CGFloat, overlap: CGFloat, opposite: Bool)? in
      let target = screens[other]
      let overlap = min(source.maxX, target.maxX) - max(source.minX, target.minX)
      guard other != index, overlap > 0 else { return nil }
      return (
        other, above ? source.minY - target.maxY : target.minY - source.maxY, overlap,
        above ? target.minY >= source.maxY : target.maxY <= source.minY
      )
    }
    let ordered = candidates.sorted {
      $0.distance == $1.distance ? $0.overlap > $1.overlap : $0.distance < $1.distance
    }
    if let next = ordered.first(where: { $0.distance >= 0 }) { return next.index }
    return wrap ? ordered.first(where: \.opposite)?.index : nil
  }

  /// 排除非有限或空尺寸，避免无效坐标传给辅助功能接口。
  static func valid(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
      && rect.width > 0 && rect.height > 0
  }

  /// 将窗口夹在目标区域里，尺寸始终为正。
  static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
    let width = min(max(1, rect.width), bounds.width)
    let height = min(max(1, rect.height), bounds.height)
    return CGRect(
      x: min(max(rect.minX, bounds.minX), bounds.maxX - width).rounded(),
      y: min(max(rect.minY, bounds.minY), bounds.maxY - height).rounded(), width: width.rounded(),
      height: height.rounded())
  }

  /// 不超出可用区域的居中尺寸。
  private static func centered(_ size: CGSize, in bounds: CGRect) -> CGRect {
    let width = min(size.width, bounds.width)
    let height = min(size.height, bounds.height)
    return clamped(
      CGRect(
        x: bounds.midX - width / 2, y: bounds.midY - height / 2,
        width: width, height: height), in: bounds)
  }
}
