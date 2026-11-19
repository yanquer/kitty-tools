// 免框选截图的动作与区域校验：复制/存储意图明确，上次区域失效时拒绝静默改变截取范围。

import AppKit

nonisolated enum QuickScreenshot {
  enum Area: Sendable { case lastRegion, window, screen }

  enum Action: String, CaseIterable, Sendable {
    case lastCopy, lastSave, windowCopy, windowSave, screenCopy, screenSave
    var area: Area {
      switch self {
      case .lastCopy, .lastSave: .lastRegion
      case .windowCopy, .windowSave: .window
      case .screenCopy, .screenSave: .screen
      }
    }
    var saves: Bool { [.lastSave, .windowSave, .screenSave].contains(self) }
    var title: String {
      switch self {
      case .lastCopy: "复制上次区域"
      case .lastSave: "存储上次区域"
      case .windowCopy: "复制前台窗口"
      case .windowSave: "存储前台窗口"
      case .screenCopy: "复制当前屏幕"
      case .screenSave: "存储当前屏幕"
      }
    }
  }

  /// 动作发生时的上下文，采集期间切换前台应用不会改变目标与历史来源名称。
  struct Request: Sendable {
    let action: Action
    let pointer: CGPoint
    let foregroundPID: pid_t?
    let sourceName: String?
    let lastRegion: CGRect?
    let includesCursor: Bool
  }

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  /// 只接受完整位于单块屏幕内的上次区域，屏幕变化时要求重新框选，避免无提示裁小图片。
  static func region(for request: Request, screens: [CGRect]) throws -> (index: Int, region: CGRect)
  {
    if request.action.area == .lastRegion {
      guard let rect = request.lastRegion else { throw Failure(message: "还没有上次截图区域，请先框选截图一次") }
      guard valid(rect), let index = screens.firstIndex(where: { $0.contains(rect) }) else {
        throw Failure(message: "上次区域不在当前可用屏幕内，请重新框选截图")
      }
      return (index, rect)
    }
    guard request.action.area == .screen,
      let index = screens.firstIndex(where: { $0.contains(request.pointer) }), valid(screens[index])
    else {
      throw Failure(message: "鼠标所在屏幕不可用，请移动鼠标后重试")
    }
    return (index, screens[index])
  }

  /// 可直接用于采集的有限矩形，拒绝空范围与非有限坐标。
  static func valid(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
      && rect.width >= 8 && rect.height >= 8
  }

  /// 从真实窗口堆叠中寻找指定前台应用最前面的普通窗口，不把菜单和桌面当成窗口。
  static func windowID(in windows: [[String: Any]], pid: pid_t) -> CGWindowID? {
    for row in windows {
      guard row[kCGWindowOwnerPID as String] as? Int == Int(pid),
        row[kCGWindowLayer as String] as? Int == 0,
        (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let number = row[kCGWindowNumber as String] as? Int,
        let id = CGWindowID(exactly: number), id > 0,
        let bounds = row[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), valid(rect)
      else { continue }
      return id
    }
    return nil
  }
}
