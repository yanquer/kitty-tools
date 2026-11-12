// 不用 key 的两个服务（2026-11-05 S1 S2）：有道词典的词条怎么写成单词卡、词典类服务只在查词时出卡片、
// 不当主结果；系统翻译支持自动、仅离线、在线快捷指令三种模式
import Foundation
import Testing
import Translation

@testable import KittyTools

struct FreeServicesTests {
  /// 自动模式只按已安装语言选路；仅离线缺少语言包时仍留在离线路径报告配置错误。
  @Test func appleTranslationModesAndLegacyPreferences() throws {
    #expect(AppleTranslation.Mode.automatic.usesOffline(languagesInstalled: true))
    #expect(!AppleTranslation.Mode.automatic.usesOffline(languagesInstalled: false))
    #expect(AppleTranslation.Mode.offline.usesOffline(languagesInstalled: false))
    #expect(!AppleTranslation.Mode.online.usesOffline(languagesInstalled: true))
    let name = "kitty-apple-mode-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(AppleTranslation.mode(in: defaults) == .automatic)
    for mode in AppleTranslation.Mode.allCases {
      defaults.set(mode.rawValue, forKey: Prefs.translateAppleMode)
      #expect(AppleTranslation.mode(in: defaults) == mode)
    }
    defaults.set("invalid", forKey: Prefs.translateAppleMode)
    #expect(AppleTranslation.mode(in: defaults) == .offline)
  }

  /// 自有工作流只做输入解析、三个字段读取、系统翻译和输出；没有脚本、网络地址或 Bob 依赖。
  @Test func appleShortcutHasOnlyTranslationActions() throws {
    let data = try AppleOnlineTranslation.workflowData()
    let workflow = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(workflow["WFWorkflowName"] as? String == AppleOnlineTranslation.shortcutName)
    let actions = try #require(workflow["WFWorkflowActions"] as? [[String: Any]])
    #expect(
      actions.compactMap { $0["WFWorkflowActionIdentifier"] as? String } == [
        "is.workflow.actions.detect.dictionary", "is.workflow.actions.getvalueforkey",
        "is.workflow.actions.getvalueforkey", "is.workflow.actions.getvalueforkey",
        "is.workflow.actions.text.translate", "is.workflow.actions.output",
      ])
    let parameters = actions.compactMap { $0["WFWorkflowActionParameters"] as? [String: Any] }
    #expect(parameters.compactMap { $0["WFDictionaryKey"] as? String } == ["from", "to", "text"])
    let result = try #require(parameters.last?["WFOutput"] as? [String: Any])
    #expect(result["WFSerializationType"] as? String == "WFTextTokenString")
    #expect(AppleOnlineTranslation.languageCode(.en) == "en_US")
    #expect(AppleOnlineTranslation.languageCode(.zhHans) == "zh_CN")
    #expect(AppleOnlineTranslation.languageCode(.zhHant) == "zh_TW")
  }

  /// 输出文件分别验证正常、有效空、缺失、无效编码及超过上限，错误不变成成功的空译文。
  @Test func appleShortcutOutputValidation() throws {
    let file = FileManager.default.temporaryDirectory.appending(
      path: "kitty-apple-output-\(UUID())")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: (any Error).self) { try AppleOnlineTranslation.readOutput(file) }
    try Data("你好，世界".utf8).write(to: file)
    #expect(try AppleOnlineTranslation.readOutput(file) == "你好，世界")
    try Data(" \n".utf8).write(to: file)
    #expect(throws: TranslateError.emptyResult) { try AppleOnlineTranslation.readOutput(file) }
    try Data([0xff, 0xfe]).write(to: file)
    #expect(throws: (any Error).self) { try AppleOnlineTranslation.readOutput(file) }
    try Data(repeating: 65, count: AppleOnlineTranslation.outputLimit + 1).write(to: file)
    #expect(throws: (any Error).self) { try AppleOnlineTranslation.readOutput(file) }
  }

  /// 诊断只保留有界错误，原文、请求地址和个人目录从展示与日志中移除。
  @Test func appleShortcutDiagnosticRedactsInput() {
    let message = "failed: 私密原文 https://example.com/private \(NSHomeDirectory())/Library error 42"
    let cleaned = AppleOnlineTranslation.diagnostic(message, source: "私密原文")
    #expect(!cleaned.contains("私密原文") && !cleaned.contains("example.com"))
    #expect(!cleaned.contains(NSHomeDirectory()) && cleaned.contains("error 42"))
    #expect(
      AppleOnlineTranslation.diagnostic(String(repeating: "x", count: 1000), source: "").count
        == 300)
  }

  /// AppleEvent 的授权拒绝与超时保留原始错误码，终止和一般执行错误保持各自含义。
  @Test func appleShortcutFailuresKeepTheirMeaning() {
    let denied = AppleOnlineTranslation.failure(
      .init(status: 1, error: "not authorized (-1743)"), source: "")
    #expect(denied.kind == .config && denied.message.contains("-1743"))
    let timeout = AppleOnlineTranslation.failure(
      .init(status: 1, error: "AppleEvent timed out (-1712)"), source: "")
    #expect(timeout.kind == .service && timeout.message.contains("超时"))
    let stopped = AppleOnlineTranslation.failure(.init(status: 15, signaled: true), source: "")
    #expect(stopped.message.contains("被终止") && !stopped.message.contains("超时"))
    let failed = AppleOnlineTranslation.failure(.init(status: 1, error: "failed 原文"), source: "原文")
    #expect(failed.kind == .service && !failed.message.contains("failed 原文"))
    #expect(!AppleOnlineTranslation.script.contains("Hello, world"))
    #expect(AppleOnlineTranslation.script.contains("Shortcuts Events"))
  }

  /// 使用当前机器未下载语言包的真实状态，核对仅离线模式如实返回配置错误。
  @Test func appleOfflineReportsMissingLanguages() async throws {
    let status = await LanguageAvailability().status(
      from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
    guard status == .supported else { return }
    do {
      _ = try await AppleTranslation.translate(
        TranslateRequest(text: "Hello, world", from: .en, to: .zhHans), mode: .offline,
        id: "test-offline")
      Issue.record("未下载语言包时仅离线模式不应成功")
    } catch let error as TranslateError {
      #expect(error.kind == .config && error.message.contains("下载"))
    }
  }

  /// 按需实测自有快捷指令的英译中和中译英，沿用已有联网测试开关。
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] == "1"))
  func liveAppleOnlineTranslation() async throws {
    for request in [
      TranslateRequest(text: "Hello, world", from: .en, to: .zhHans),
      TranslateRequest(text: "智谱", from: .zhHans, to: .en),
    ] {
      let text = try await AppleTranslation.translate(request, mode: .online, id: "test-online")
      #expect(!text.isEmpty && text != request.text)
    }
    let automatic = try await AppleTranslation.translate(
      TranslateRequest(text: "Hello, world", from: nil, to: .zhHans), mode: .automatic,
      id: "test-auto")
    #expect(!automatic.isEmpty && automatic != "Hello, world")
  }

  /// 有道词典接口返回的英汉词条（2026-11-05 真实返回里摘的几段，结构原样）
  static let stuff: [String: Any] = [
    "ec": [
      "word": [
        [
          "usphone": "stʌf", "ukphone": "stʌf",
          "trs": [
            ["tr": [["l": ["i": ["n. 东西，物品；基本特征，特质"]]]]],
            ["tr": [["l": ["i": ["v. 塞进，填进；填满，装满"]]]]],
          ],
          "wfs": [
            ["wf": ["name": "现在分词", "value": "stuffing"]],
            ["wf": ["name": "过去式", "value": "stuffed"]],
          ],
        ]
      ]
    ],
    "blng_sents_part": [
      "sentence-pair": [
        [
          "sentence": "It's amazing how people collect so much stuff over the years.",
          "sentence-translation": "人们这些年下来竟能收集到这么多东西，真令人惊奇。",
        ]
      ]
    ],
  ]

  @Test func youdaoEnglishEntryLooksLikeAWordCard() throws {
    let entry = try #require(YoudaoDict.entry(Self.stuff))
    #expect(
      entry == """
        美 /stʌf/  英 /stʌf/
        n. 东西，物品；基本特征，特质
        v. 塞进，填进；填满，装满
        变形：现在分词 stuffing；过去式 stuffed
        例：It's amazing how people collect so much stuff over the years. 人们这些年下来竟能收集到这么多东西，真令人惊奇。
        """)
    // 第一行是读音行：卡片上换成带小喇叭的一行；右上角的喇叭读第一条释义
    #expect(Speaker.phoneticLine(entry)?.phonetics.count == 2)
    #expect(Speaker.speechText(entry, wordStyle: true) == "东西，物品；基本特征，特质")
  }

  @Test func youdaoChineseEntryAndMisses() throws {
    let name: [String: Any] = [
      "ce": [
        "word": [
          [
            "phone": "míng zì",
            "trs": [
              ["tr": [["l": ["pos": "n.", "i": ["", ["#text": "name", "@action": "link"]]]]]],
              ["tr": [["l": ["pos": "n.", "i": ["", ["#text": "monicker"]]]]]],
            ],
          ]
        ]
      ]
    ]
    #expect(YoudaoDict.entry(name) == "míng zì\nn. name\nn. monicker")
    // 没查到（空、只有读音没有释义）
    #expect(YoudaoDict.entry([:]) == nil)
    #expect(YoudaoDict.entry(["ec": ["word": [["usphone": "x"]]]]) == nil)
  }

  @Test func dictionaryServicesOnlyAnswerWords() async throws {
    var ai = TranslateService.newAI()
    ai.isEnabled = true
    var dict = TranslateService.builtin(.youdaoDict)
    dict.isEnabled = true
    let coordinator = TranslateCoordinator(
      services: TranslateServiceStore(services: [dict, ai]),
      history: try HistoryStore(db: Database(path: ":memory:")))
    coordinator.stream = { service, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(service.kind == .youdaoDict ? "美 /stʌf/\nn. 东西" : "东西")
        continuation.finish()
      }
    }
    // 句子：不开有道词典的卡片
    coordinator.translate("How are you doing today?", fromCopy: true)
    for _ in 0..<2000 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(2)) }
    #expect(coordinator.cards.map(\.id) == [ai.id])
    // 单词：两张都开；主结果跳过排在前面的词典卡
    coordinator.translate("stuff", fromCopy: true)
    for _ in 0..<2000 where coordinator.isRunning { try await Task.sleep(for: .milliseconds(2)) }
    #expect(coordinator.cards.map(\.id) == [dict.id, ai.id])
    #expect(coordinator.primaryResult?.service.id == ai.id)
  }

  @Test func newBuiltinsAreOffered() {
    let store = TranslateServiceStore(services: [.zhipu])
    #expect(store.missingBuiltins.contains(.youdaoDict))
    #expect(store.missingBuiltins.contains(.apple) == AppleTranslation.isAvailable)
    // 不用填 key、id 就是种类原值（设置的导出和同步按它认）
    for kind in [TranslateService.Kind.apple, .youdaoDict] {
      #expect(TranslateService.builtin(kind).secretFields.isEmpty)
      #expect(TranslateService.builtin(kind).id == kind.rawValue)
    }
  }

  /// 联网冒烟（TEST_RUNNER_KITTY_LIVE_TRANSLATE=1，同内置智谱那条）：真查一次有道词典，接口格式变了这里先红
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_TRANSLATE"] == "1"))
  func liveYoudaoDict() async throws {
    var text = ""
    let request = TranslateRequest(text: "stuff", from: .en, to: .zhHans)
    for try await chunk in TranslateService.builtin(.youdaoDict).translate(request) { text = chunk }
    #expect(Speaker.phoneticLine(text) != nil)
    #expect(text.contains("n. ") && text.contains("例："))
  }
}
