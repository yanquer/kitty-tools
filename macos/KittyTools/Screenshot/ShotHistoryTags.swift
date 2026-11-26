// 截图历史标签规则。统一校验、身份归一、批量修改和磁盘格式。

import Foundation

/// 单条与批量编辑共用的标签规则，保留第一次添加时用户看到的拼写。
nonisolated enum ShotTags {
  static let maximumPerItem = 8
  static let maximumCharacters = 32

  enum Failure: LocalizedError {
    case invalidName, tooLong, tooMany, missingItems, storageUnavailable

    var errorDescription: String? {
      switch self {
      case .invalidName: "请输入标签名称，标签不能包含控制字符或换行。"
      case .tooLong: "标签太长，请缩短名称后再试。"
      case .tooMany: "所选记录中有项目会超过 8 个标签，请先移除部分标签。"
      case .missingItems: "部分历史记录已不存在，请重新选择后再试。"
      case .storageUnavailable: "标签没有保存，请重试。"
      }
    }
  }

  /// 前后空白忽略，内部空格保留，避免把一段文字拆成多个标签。
  static func name(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !trimmed.isEmpty,
      !trimmed.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
      })
    else { throw Failure.invalidName }
    guard trimmed.utf8.count <= 128, trimmed.count <= maximumCharacters else {
      throw Failure.tooLong
    }
    return trimmed
  }

  /// 驼峰和大小写差异不生成重复标签，中文及符号保留原有语义。
  static func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// 按传入顺序去重，当前条目的原有名称优先。
  static func unique(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { seen.insert(key($0)).inserted }
  }

  /// 先移除明确指定的标签，再添加其余标签，单条超限由整个批次一起拒绝。
  static func applying(to existing: [String], adding: [String], removing: Set<String>) throws
    -> [String]
  {
    let next = unique(existing.filter { !removing.contains(key($0)) } + adding)
    guard next.count <= maximumPerItem else { throw Failure.tooMany }
    return next
  }

  /// 旧库的空值是一条无标签记录，异常数据留给读取方诊断。
  static func decode(_ stored: String) -> [String]? {
    guard stored.utf8.count <= 8192,
      let names = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)),
      let validated = try? names.map(name), validated.count <= maximumPerItem
    else { return nil }
    return unique(validated)
  }
}
