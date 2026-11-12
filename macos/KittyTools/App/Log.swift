// 统一日志（os.Logger）。查看：log stream --predicate 'subsystem BEGINSWITH "com.yy.kitty-tools.native"'
// 红线：日志里不得出现密钥、请求 URL、请求头、剪贴板正文。

import OSLog

nonisolated enum Log {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"
  static let storage = Logger(subsystem: subsystem, category: "storage")
  static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
  /// 系统翻译的模式选择、快捷指令执行、取消及失败原因，不记录翻译正文。
  static let translate = Logger(subsystem: subsystem, category: "translate")
  static let record = Logger(subsystem: subsystem, category: "record")
  /// 访达右键（FinderLink）：交给别的 App 打开没成
  static let finder = Logger(subsystem: subsystem, category: "finder")
  /// 刘海岛（Island）：每块屏认成刘海 / 胶囊 / 系统灵动岛和它的几何（屏幕变了时写一次）
  static let island = Logger(subsystem: subsystem, category: "island")
  /// 窗口枚举、最近使用跟踪及窗口操作的原始系统错误。
  static let windows = Logger(subsystem: subsystem, category: "windows")
}
