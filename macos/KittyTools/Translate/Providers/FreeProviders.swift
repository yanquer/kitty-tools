// 不用填 key 的两个服务（2026-11-05 拍板 S1 S2）：
// - 系统翻译（AppleTranslation）：自动优先使用 macOS 26 起的本机语言包，缺少时走在线快捷指令；另可选择仅离线或在线。
//   在线执行和安装在 AppleOnlineTranslation.swift，文字可能由苹果服务器处理。源语言「自动」时用检测出来的语言。
// - 有道词典（YoudaoDict）：有道词典网页版的查词接口（一个普通的 GET、不签名、不冒充别的客户端），只查单词和短语：
//   英文词出美 / 英音标、各词性的释义、变形、一个双语例句，中文词出拼音和英文释义，写成和大模型单词卡同一个样子
//   （第一行读音，卡片上就有读音的小喇叭）。非官方接口：哪天改了格式就是「有道词典里没有这个词」，再来修。
//   不是单词的原文不开它的卡片（TranslateCoordinator.start），也不当主结果、不进静默替换（Kind.isDictionary）。

import Foundation
import OSLog
import Translation

nonisolated enum AppleTranslation {
  /// 系统翻译的运行模式；自动只在缺少本机语言包时使用在线路径，离线执行失败仍如实报错。
  enum Mode: String, CaseIterable, Sendable {
    case automatic, offline, online

    var title: String {
      switch self {
      case .automatic: "自动"
      case .offline: "仅离线"
      case .online: "在线（快捷指令）"
      }
    }

    /// 列表和详情页共用的模式说明。
    var statusText: String {
      switch self {
      case .automatic: "自动 · 离线优先"
      case .offline: "离线 · 本机翻译"
      case .online: "在线 · 快捷指令"
      }
    }

    /// 根据已安装语言决定本次路径；仅离线仍交给离线路径报告缺少语言包。
    func usesOffline(languagesInstalled: Bool) -> Bool {
      self == .offline || self == .automatic && languagesInstalled
    }
  }

  /// 部署支持的 macOS 15 起都能用快捷指令，离线框架另要求 macOS 26。
  static var isAvailable: Bool { true }

  /// 读取模式；旧设置没有此键时使用自动，不认识的值收为仅离线以避免意外联网。
  @MainActor static func mode(in defaults: UserDefaults = .standard) -> Mode {
    guard let raw = defaults.string(forKey: Prefs.translateAppleMode) else { return .automatic }
    return Mode(rawValue: raw) ?? .offline
  }

  /// 翻译入口统一记录执行阶段，正常结果、取消和失败分别收尾。
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    Signing.oneShot {
      let mode = await mode()
      let id = String(UUID().uuidString.prefix(8))
      let started = ContinuousClock.now
      Log.translate.notice(
        "system_translate id=\(id, privacy: .public) mode=\(mode.rawValue, privacy: .public) phase=start"
      )
      do {
        let text = try await translate(request, mode: mode, id: id)
        let elapsed = started.duration(to: .now).components.seconds
        Log.translate.notice(
          "system_translate id=\(id, privacy: .public) phase=complete seconds=\(elapsed)")
        return text
      } catch is CancellationError {
        Log.translate.notice("system_translate id=\(id, privacy: .public) phase=cancelled")
        throw CancellationError()
      } catch {
        let cause = await AppleOnlineTranslation.diagnostic(
          error.localizedDescription, source: request.text)
        Log.translate.error(
          "system_translate id=\(id, privacy: .public) phase=failed cause=\(cause, privacy: .public)"
        )
        throw error
      }
    }
  }

  /// 按模式选择在线或离线，自动模式不掩盖离线引擎已开始执行后的错误。
  static func translate(_ request: TranslateRequest, mode: Mode, id: String) async throws
    -> String
  {
    guard let from = request.from ?? Lang.detect(request.text) else {
      throw TranslateError(message: "认不出原文是什么语言，在浮窗顶上选一下源语言")
    }
    let source = Locale.Language(identifier: from.rawValue)
    let target = Locale.Language(identifier: request.to.rawValue)
    let availability: LanguageAvailability.Status? =
      mode == .online ? nil : await LanguageAvailability().status(from: source, to: target)
    let installed: Bool
    if #available(macOS 26, *) { installed = availability == .installed } else { installed = false }
    guard mode.usesOffline(languagesInstalled: installed) else {
      Log.translate.notice("system_translate id=\(id, privacy: .public) route=online")
      return try await AppleOnlineTranslation.translate(request, from: from, id: id)
    }
    guard #available(macOS 26, *) else {
      throw TranslateError.config("系统离线翻译要 macOS 26 或更新，可以在设置中选择自动或在线")
    }
    guard availability == .installed else {
      if availability == .unsupported {
        throw TranslateError(message: "系统离线翻译不支持\(from.title)译\(request.to.title)")
      }
      throw TranslateError.config(
        "系统离线翻译需要下载\(from.title)和\(request.to.title)：到 系统设置 › 通用 › 语言与地区 › 翻译语言 里下载，或选择自动、在线模式")
    }
    try Task.checkCancellation()
    Log.translate.notice("system_translate id=\(id, privacy: .public) route=offline")
    let session = TranslationSession(installedSource: source, target: target)
    do {
      return try await session.translate(request.text).targetText
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TranslateError(message: "系统翻译出错：\(error.localizedDescription)")
    }
  }
}

nonisolated enum YoudaoDict {
  static func stream(_ request: TranslateRequest, service: TranslateService)
    -> AsyncThrowingStream<String, Error>
  {
    Signing.oneShot {
      let query = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
      var components = URLComponents(string: "https://dict.youdao.com/jsonapi")!
      // 只要英汉、汉英和双语例句三节（整份 130 KB，这样 5 KB）
      components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(
          name: "dicts", value: #"{"count":99,"dicts":[["ec","ce","blng_sents_part"]]}"#),
      ]
      var urlRequest = URLRequest(url: components.url!)
      urlRequest.timeoutInterval = 30
      let (data, response) = try await HTTP.perform { [urlRequest] in
        try await HTTP.session(for: urlRequest.url!).data(for: urlRequest)
      }
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      try HTTP.check(response, object ?? [:])
      guard let object, let entry = entry(object) else {
        throw TranslateError(message: "有道词典里没有这个词")
      }
      return entry
    }
  }

  /// 把接口返回的词条写成单词卡的样子（纯函数，配单测）：
  /// 英汉 = 「美 /…/  英 /…/」+ 每个词性一行 + 变形 + 「例：英文 中文」；汉英 = 拼音 + 「n. name；…」。都没有时 nil
  static func entry(_ object: [String: Any]) -> String? {
    var lines: [String] = []
    if let word = ((object["ec"] as? [String: Any])?["word"] as? [[String: Any]])?.first {
      let phonetics = [("美", word["usphone"]), ("英", word["ukphone"])].compactMap { label, value in
        (value as? String).flatMap { $0.isEmpty ? nil : "\(label) /\($0)/" }
      }
      if !phonetics.isEmpty { lines.append(phonetics.joined(separator: "  ")) }
      for tr in word["trs"] as? [[String: Any]] ?? [] {
        if let line = (firstLine(tr)?["i"] as? [Any])?.compactMap({ $0 as? String }).first,
          !line.isEmpty
        {
          lines.append(line)
        }
      }
      let forms = (word["wfs"] as? [[String: Any]] ?? []).compactMap { item -> String? in
        guard let wf = item["wf"] as? [String: Any], let name = wf["name"] as? String,
          let value = wf["value"] as? String
        else { return nil }
        return "\(name) \(value)"
      }
      if lines.count > (phonetics.isEmpty ? 0 : 1), !forms.isEmpty {
        lines.append("变形：" + forms.joined(separator: "；"))
      }
    } else if let word = ((object["ce"] as? [String: Any])?["word"] as? [[String: Any]])?.first {
      if let phone = word["phone"] as? String, !phone.isEmpty { lines.append(phone) }
      for tr in word["trs"] as? [[String: Any]] ?? [] {
        guard let line = firstLine(tr) else { continue }
        // i 是字符串和 {"#text": "name"} 混着的数组
        let text = (line["i"] as? [Any] ?? []).map { item in
          (item as? String) ?? ((item as? [String: Any])?["#text"] as? String) ?? ""
        }.joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        let pos = (line["pos"] as? String).map { $0 + " " } ?? ""
        lines.append(pos + text)
      }
    }
    // 只有读音、没有释义的不算查到
    guard lines.contains(where: { !$0.hasPrefix("美 /") && !$0.hasPrefix("英 /") }) else {
      return nil
    }
    if let pair =
      ((object["blng_sents_part"] as? [String: Any])?["sentence-pair"] as? [[String: Any]])?
      .first, let sentence = pair["sentence"] as? String,
      let translation = pair["sentence-translation"] as? String
    {
      lines.append("例：\(sentence) \(translation)")
    }
    return lines.joined(separator: "\n")
  }

  /// trs 里一条的 tr[0].l
  private static func firstLine(_ tr: [String: Any]) -> [String: Any]? {
    ((tr["tr"] as? [[String: Any]])?.first)?["l"] as? [String: Any]
  }
}
