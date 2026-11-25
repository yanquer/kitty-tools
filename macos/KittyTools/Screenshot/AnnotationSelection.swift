// 两种标注画布共用的多选运算：稳定身份、批量复制与样式状态，不持久化临时选中信息。

import AppKit

extension Annotation {
  /// 多选托盘只显示确实共有的状态；混合工具仅开放共同颜色。
  struct SelectionStyle: Equatable {
    var mixedTools = false
    var color = false
    var weight = false
    var option = false
    var font = false
  }

  /// 按文档顺序取存活对象，不把已删除的编号当作有效选择。
  static func selected(in values: [Annotation], primary: UUID?, extras: Set<UUID>) -> [Annotation] {
    let ids = extras.union(primary.map { [$0] } ?? [])
    return values.filter { ids.contains($0.id) }
  }

  /// 框选采用相交的对象边界，允许追加，不改变截图的原选区。
  static func selected(in values: [Annotation], rect: CGRect, adding ids: Set<UUID>) -> Set<UUID> {
    ids.union(values.filter { $0.bounds.intersects(rect) }.map(\.id))
  }

  /// 多对象复制分配新身份，序号沿用既有规则递增，关联文字随所属线条一起复制。
  static func duplicateGroup(_ chosen: [Annotation], offset: CGSize, existing: [Annotation])
    -> [Annotation]
  {
    var copies: [Annotation] = []
    for original in chosen {
      var copy = original.duplicated(offset: offset)
      if case .counter(_, let center) = copy.shape {
        copy.shape = .counter(nextCounter(in: existing + copies), center: center)
      }
      copies.append(copy)
    }
    return copies
  }

  /// 识别混合值，避免只用主选中对象的样式冒充整组选中状态。
  static func selectionStyle(_ chosen: [Annotation]) -> SelectionStyle {
    guard let first = chosen.first else { return SelectionStyle() }
    let colors = chosen.filter { $0.tool.hasColor }
    let mixedColor =
      colors.first.map { first in colors.contains { $0.style.paint != first.style.paint } } ?? false
    return SelectionStyle(
      mixedTools: chosen.contains { $0.tool != first.tool },
      color: mixedColor,
      weight: chosen.contains {
        $0.style.weight != first.style.weight || $0.style.diameter != first.style.diameter
      },
      option: chosen.contains { $0.style.option != first.style.option },
      font: chosen.contains { $0.style.textSize != first.style.textSize })
  }

  /// 批量样式沿用各工具语义；混合工具只采用颜色，并同步所属关联文字的颜色。
  static func restyled(
    _ values: [Annotation], ids: Set<UUID>, colorOnly: Bool,
    change: (inout Style) -> Void
  ) -> [Annotation] {
    values.map { value in
      guard ids.contains(value.id) else { return value }
      var changed = value.style
      change(&changed)
      var next = value
      if colorOnly {
        guard value.tool.hasColor else { return value }
        next.style.color = changed.color
        next.style.custom = changed.custom
      } else {
        next.style = changed
      }
      if next.style.color != value.style.color || next.style.custom != value.style.custom {
        next.caption?.style.color = next.style.color
        next.caption?.style.custom = next.style.custom
      }
      return next
    }
  }
}
