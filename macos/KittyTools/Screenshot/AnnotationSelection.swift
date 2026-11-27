// 两种标注画布共用的多选运算：稳定身份、批量复制与样式状态，不持久化临时选中信息。

import AppKit
import Carbon.HIToolbox

/// 两种截图画布共享的进程内标注剪贴板，只持有最近一组可编辑对象。
@MainActor final class AnnotationClipboard {
  static let shared = AnnotationClipboard()

  /// 菜单与画布局部键使用同一命令，已配置的截图快捷键优先。
  enum Action: CaseIterable {
    case copy, paste

    var title: String { self == .copy ? "复制标注" : "粘贴标注" }
    var shortcut: HotKey {
      HotKey(keyCode: self == .copy ? kVK_ANSI_C : kVK_ANSI_V, modifiers: cmdKey | optionKey)
    }
    var availableKeyLabel: String? { ShotKey.matching(shortcut) == nil ? shortcut.display : nil }

    /// 只匹配没有分配给现有截图命令的组合。
    static func matching(_ event: NSEvent) -> Action? {
      let key = HotKey(keyCode: event.keyCode, flags: event.modifierFlags)
      guard let action = allCases.first(where: { $0.shortcut == key }), ShotKey.matching(key) == nil
      else { return nil }
      return action
    }
  }

  private var annotations: [Annotation] = []
  var hasContent: Bool { !annotations.isEmpty }

  /// 平铺水印的范围来自原画布，只把可独立摆放的对象放入剪贴板。
  static func canCopy(_ selected: [Annotation]) -> Bool {
    selected.contains { $0.watermark == nil }
  }

  /// 复制值快照，后续编辑源对象不会改变已复制的组。
  func copy(_ selected: [Annotation]) -> Int {
    let copied = selected.filter { $0.watermark == nil }
    if !copied.isEmpty { annotations = copied }
    return copied.count
  }

  /// 放到当前视口中心；整组过大时优先让第一条标注出现在视口内。
  func paste(in viewport: CGRect, existing: [Annotation]) -> [Annotation] {
    guard !viewport.isEmpty, let first = annotations.first else { return [] }
    let group = annotations.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    let anchor =
      group.width > viewport.width || group.height > viewport.height ? first.bounds : group
    let offset = CGSize(width: viewport.midX - anchor.midX, height: viewport.midY - anchor.midY)
    return Annotation.duplicateGroup(annotations, offset: offset, existing: existing)
  }
}

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
      let numberingFrom = original.tool == .counter ? existing + copies : nil
      copies.append(original.duplicated(offset: offset, numberingFrom: numberingFrom))
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
      mixedTools: chosen.contains {
        $0.tool != first.tool || ($0.watermark == nil) != (first.watermark == nil)
      },
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
