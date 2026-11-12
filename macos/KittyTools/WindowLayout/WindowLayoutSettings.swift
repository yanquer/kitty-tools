// 窗口管理偏好读取、吸附区域和鼠标侧键的有界配置解析。

import AppKit

extension WindowLayoutOptions {
  /// 与执行层和设置控件一致的导入范围。
  static let ranges: [String: ClosedRange<Double>] = [
    Prefs.layoutGap: 0...100, Prefs.layoutEdgeGap: 0...100, Prefs.layoutStep: 1...300,
    Prefs.layoutWidth: 0.1...20000, Prefs.layoutHeight: 0.1...20000, Prefs.layoutAlmost: 0.5...1,
    Prefs.layoutCascade: 1...150, Prefs.layoutSidebar: 100...3000,
    Prefs.layoutMinimumWidth: 0...1, Prefs.layoutMinimumHeight: 0...1,
  ]

  /// 自定义尺寸可从文本框直接输入，执行前拒绝无效值，避免静默采用默认尺寸。
  @MainActor static func customSizeProblem(_ defaults: UserDefaults = .standard) -> String? {
    for (key, title) in [(Prefs.layoutWidth, "自定义宽度"), (Prefs.layoutHeight, "自定义高度")] {
      guard let stored = defaults.object(forKey: key) else { continue }
      guard let value = stored as? NSNumber, value.doubleValue.isFinite,
        (0.1...20000).contains(value.doubleValue)
      else { return title + "需要在 0.1 到 20000 之间" }
    }
    return nil
  }
  /// 从注册偏好读取有限范围的几何参数，损坏设置按该项默认值处理。
  @MainActor static func read(_ defaults: UserDefaults = .standard) -> Self {
    Self(
      gap: number(Prefs.layoutGap, in: defaults, range: 0...100, fallback: 0),
      edgeGap: number(Prefs.layoutEdgeGap, in: defaults, range: 0...100, fallback: 0),
      step: number(Prefs.layoutStep, in: defaults, range: 1...300, fallback: 30),
      width: number(Prefs.layoutWidth, in: defaults, range: 0.1...20000, fallback: 1680),
      height: number(Prefs.layoutHeight, in: defaults, range: 0.1...20000, fallback: 1050),
      almost: number(Prefs.layoutAlmost, in: defaults, range: 0.5...1, fallback: 0.9),
      cascade: number(Prefs.layoutCascade, in: defaults, range: 1...150, fallback: 30),
      sidebar: number(Prefs.layoutSidebar, in: defaults, range: 100...3000, fallback: 400),
      portrait: defaults.object(forKey: Prefs.layoutPortrait) as? Bool ?? true,
      screenProportions: defaults.object(forKey: Prefs.layoutProportions) as? Bool ?? true,
      keepCentered: defaults.object(forKey: Prefs.layoutKeepCentered) as? Bool ?? true,
      minimumWidth: number(Prefs.layoutMinimumWidth, in: defaults, range: 0...1, fallback: 0.25),
      minimumHeight: number(Prefs.layoutMinimumHeight, in: defaults, range: 0...1, fallback: 0.25))
  }

  /// 读取范围受控的数值，导入校验使用同样的上下限。
  @MainActor private static func number(
    _ key: String, in defaults: UserDefaults,
    range: ClosedRange<Double>, fallback: Double
  ) -> CGFloat {
    guard let value = defaults.object(forKey: key) as? NSNumber,
      value.doubleValue.isFinite, range.contains(value.doubleValue)
    else { return fallback }
    return CGFloat(value.doubleValue)
  }
}

/// 八个拖拽吸附位置的顺序与偏好字符串一一对应。
nonisolated enum WindowLayoutSnap: Int, CaseIterable, Identifiable {
  case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
  var id: Int { rawValue }
  var title: String {
    switch self {
    case .topLeft: "左上角"
    case .top: "上边缘"
    case .topRight: "右上角"
    case .left: "左边缘"
    case .right: "右边缘"
    case .bottomLeft: "左下角"
    case .bottom: "下边缘"
    case .bottomRight: "右下角"
    }
  }

  static let defaults: [WindowLayoutAction?] = [
    .topLeft, .maximize, .topRight, .leftHalf, .rightHalf, .bottomLeft, .bottomHalf, .bottomRight,
  ]

  /// 文件导入拒绝损坏的区域设置，运行时读取旧数据仍可按项回退。
  static func valid(_ text: String) -> Bool {
    let entries = text.split(separator: ",", omittingEmptySubsequences: false)
    return entries.count == allCases.count
      && entries.allSatisfy { value in
        value == "off" || WindowLayoutAction(rawValue: String(value)).map(canSnap) == true
      }
  }

  /// 只允许可计算的单窗口布局或关闭，未知项保留该区域默认动作。
  static func actions(_ text: String) -> [WindowLayoutAction?] {
    let entries = text.split(separator: ",", omittingEmptySubsequences: false)
    guard entries.count == allCases.count else { return defaults }
    return entries.enumerated().map { index, value in
      if value == "off" { return nil }
      guard let action = WindowLayoutAction(rawValue: String(value)), canSnap(action) else {
        return defaults[index]
      }
      return action
    }
  }

  /// 纯布局动作可放在拖拽区域，新建窗口与标题栏动作也使用这个集合。
  static func canSnap(_ action: WindowLayoutAction) -> Bool {
    WindowLayoutGeometry.frame(
      for: action, current: CGRect(x: 0, y: 0, width: 800, height: 600),
      in: CGRect(x: 0, y: 0, width: 1600, height: 1000)) != nil
  }

  /// 根据屏幕左上坐标判断边缘或角落，显示器接缝使用指针当前所属屏幕。
  static func area(at point: CGPoint, in bounds: CGRect, margin: CGFloat = 8) -> Self? {
    guard bounds.insetBy(dx: -margin, dy: -margin).contains(point) else { return nil }
    let nearLeft = point.x <= bounds.minX + margin
    let nearRight = point.x >= bounds.maxX - margin
    let nearTop = point.y <= bounds.minY + margin
    let nearBottom = point.y >= bounds.maxY - margin
    let corner: CGFloat = min(80, min(bounds.width, bounds.height) / 5)
    if nearLeft || nearTop, point.x <= bounds.minX + corner, point.y <= bounds.minY + corner {
      return .topLeft
    }
    if nearRight || nearTop, point.x >= bounds.maxX - corner, point.y <= bounds.minY + corner {
      return .topRight
    }
    if nearLeft || nearBottom, point.x <= bounds.minX + corner, point.y >= bounds.maxY - corner {
      return .bottomLeft
    }
    if nearRight || nearBottom, point.x >= bounds.maxX - corner, point.y >= bounds.maxY - corner {
      return .bottomRight
    }
    if nearLeft { return .left }
    if nearRight { return .right }
    if nearTop { return .top }
    if nearBottom { return .bottom }
    return nil
  }
}

/// 鼠标侧键映射只接受 2–31 号键，不覆盖主键和右键。
nonisolated struct WindowLayoutMouseBinding: Codable, Identifiable, Equatable {
  var button: Int
  var action: WindowLayoutAction
  var id: Int { button }

  /// 配置文件按不可信输入处理，拒绝超长、重复和不支持的按键。
  static func decode(_ text: String) -> [Self]? {
    guard text.utf8.count <= 16384, let data = text.data(using: .utf8),
      let entries = try? JSONDecoder().decode([Self].self, from: data), entries.count <= 30,
      entries.allSatisfy({ (2...31).contains($0.button) }),
      Set(entries.map(\.button)).count == entries.count
    else { return nil }
    return entries
  }

  /// 用于设置页的小型、受限 JSON，不写入鼠标事件或其他个人信息。
  static func encode(_ entries: [Self]) -> String? {
    guard let data = try? JSONEncoder().encode(entries) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
