// 系统翻译的快捷指令路径：生成自有翻译指令、经系统工具签名供用户安装，串行调用并有界读取结果。
// 原文只经权限为 0700 的临时目录传递，不进入命令行参数、剪贴板或日志；在线处理位置遵循苹果系统设置。

import Foundation
import OSLog

enum AppleOnlineTranslation {
  static let shortcutName = "Kitty Tools 翻译"
  static let outputLimit = 1_048_576
  private static var isRunning = false
  /// 通过系统的 Shortcuts Events 执行翻译，输入和输出均用私有文件传递，脚本内容不拼接原文。
  static let script = """
    on run arguments
      set inputText to read (POSIX file (item 1 of arguments)) as «class utf8»
      with timeout of 25 seconds
        tell application "Shortcuts Events"
          set translatedText to run the shortcut named (item 3 of arguments) with input inputText
        end tell
      end timeout
      set destination to open for access (POSIX file (item 2 of arguments)) with write permission
      try
        set eof destination to 0
        write translatedText to destination as «class utf8»
        close access destination
      on error messageText number errorNumber
        try
          close access destination
        end try
        error messageText number errorNumber
      end try
      return ""
    end run
    """

  /// 检查自有快捷指令是否已安装；命令失败和输出超限分别报错，不冒充尚未安装。
  static func isInstalled() async throws -> Bool {
    let result = try await Subprocess.run(
      "/usr/bin/shortcuts", ["list"], captures: true, timeout: .seconds(10),
      stopsOnCancel: true, outputLimit: 262_144)
    try Task.checkCancellation()
    guard result.status == 0, !result.overflowed else {
      let cause = diagnostic(result.error, source: "")
      Log.translate.error(
        "system_translate phase=list status=\(result.status) signal=\(result.signaled) overflow=\(result.overflowed) cause=\(cause, privacy: .public)"
      )
      throw TranslateError.config("读取快捷指令列表失败（退出码 \(result.status)），打开「快捷指令」App 后重试")
    }
    return result.output.split(separator: "\n").contains { $0 == shortcutName }
  }

  /// 快捷指令引擎串行运行；等待和执行都可取消，排队超过 30 秒明确报错。
  static func translate(_ request: TranslateRequest, from: Lang, id: String) async throws -> String
  {
    let queued = ContinuousClock.now
    while isRunning {
      try await Task.sleep(for: .milliseconds(50))
      guard queued.duration(to: .now) < .seconds(30) else {
        throw TranslateError(message: "系统在线翻译仍在处理上一项请求，请稍后重试")
      }
    }
    try Task.checkCancellation()
    isRunning = true
    defer { isRunning = false }
    guard try await isInstalled() else {
      throw TranslateError.config("先在 设置 › 翻译 › 系统翻译 中安装「\(shortcutName)」快捷指令")
    }
    return try await run(request, from: from, id: id)
  }

  /// 使用私有临时文件传入 JSON 并读取纯文本输出，保留退出状态和脱敏后的原始错误。
  private static func run(_ request: TranslateRequest, from: Lang, id: String) async throws
    -> String
  {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "kitty-translate-\(UUID())")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
      do { try FileManager.default.removeItem(at: directory) } catch {
        Log.translate.error(
          "system_translate id=\(id, privacy: .public) phase=cleanup error=\((error as NSError).code)"
        )
      }
    }
    let input = directory.appending(path: "input.json")
    let output = directory.appending(path: "output.txt")
    let payload = try JSONSerialization.data(withJSONObject: [
      "from": languageCode(from), "to": languageCode(request.to), "text": request.text,
    ])
    try payload.write(to: input, options: .atomic)
    let result = try await Subprocess.run(
      "/usr/bin/osascript", ["-e", script, input.path, output.path, shortcutName],
      captures: true, timeout: .seconds(30), stopsOnCancel: true, outputLimit: 8192)
    try Task.checkCancellation()
    guard result.status == 0, !result.signaled, !result.overflowed else {
      let cause = diagnostic(result.error, source: request.text)
      Log.translate.error(
        "system_translate id=\(id, privacy: .public) phase=shortcut status=\(result.status) signal=\(result.signaled) overflow=\(result.overflowed) cause=\(cause, privacy: .public)"
      )
      throw failure(result, source: request.text)
    }
    return try readOutput(output)
  }

  /// 快捷指令的系统在线引擎使用完整区域标识，复用已有朗读语言码并转换为系统 locale 写法。
  static func languageCode(_ language: Lang) -> String {
    language.speechCode.replacingOccurrences(of: "-", with: "_")
  }

  /// 按原始 AppleEvent 错误码区分授权拒绝、超时、进程终止与其他失败，详细原因由执行层记录。
  static func failure(_ result: Subprocess.Result, source: String) -> TranslateError {
    if result.error.contains("-1743") {
      return .config(
        "系统在线翻译需要自动化授权：到 系统设置 › 隐私与安全性 › 自动化 中允许 Kitty Tools 控制 Shortcuts Events（-1743）")
    }
    if result.error.contains("-1712") {
      return TranslateError(message: "系统在线翻译等待快捷指令超时（-1712），请稍后重试")
    }
    if result.signaled {
      return TranslateError(message: "系统在线翻译进程被终止（信号 \(result.status)）")
    }
    if result.overflowed {
      return TranslateError(message: "快捷指令的诊断输出超过大小上限，执行已停止")
    }
    return TranslateError(
      message: "系统在线翻译失败（退出码 \(result.status)）：\(diagnostic(result.error, source: source))")
  }

  /// 校验快捷指令输出的存在性、大小、编码及非空正文，读取有界且不采用标准输出冒充译文。
  static func readOutput(_ output: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: output.path) else {
      throw TranslateError(message: "快捷指令没有返回翻译结果")
    }
    let handle = try FileHandle(forReadingFrom: output)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: outputLimit + 1) ?? Data()
    guard data.count <= outputLimit, let text = String(data: data, encoding: .utf8) else {
      throw TranslateError(message: "快捷指令返回的内容超过大小上限或不是有效文字")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TranslateError.emptyResult
    }
    return text
  }

  /// 生成自有指令并调用系统签名工具；仅准备安装文件，打开安装窗口由用户按钮触发。
  static func prepareInstallation() async throws -> URL {
    let directory = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appending(path: Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native")
    .appending(path: "TranslationShortcut")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appending(path: "template.shortcut")
    let output = directory.appending(path: "\(shortcutName).shortcut")
    try workflowData().write(to: input, options: .atomic)
    defer { try? FileManager.default.removeItem(at: input) }
    Log.translate.notice("system_translate phase=sign_start")
    let result = try await Subprocess.run(
      "/usr/bin/shortcuts",
      ["sign", "--mode", "anyone", "--input", input.path, "--output", output.path],
      captures: true, timeout: .seconds(30), stopsOnCancel: true, outputLimit: 8192)
    try Task.checkCancellation()
    guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
      let cause = diagnostic(result.error, source: "")
      Log.translate.error(
        "system_translate phase=sign_failed status=\(result.status) cause=\(cause, privacy: .public)"
      )
      throw TranslateError.config("无法准备在线翻译快捷指令（退出码 \(result.status)）：\(cause)")
    }
    Log.translate.notice("system_translate phase=sign_complete")
    return output
  }

  /// 对外部工具的错误去除原文、地址及个人目录，再保留最多 300 字用于诊断和提示。
  static func diagnostic(_ message: String, source: String) -> String {
    let hidden = source.isEmpty ? message : message.replacingOccurrences(of: source, with: "<原文>")
    return String(
      hidden.replacing(/https?:\/\/\S+/, with: "<地址>")
        .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        .trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
  }

  /// 自有快捷指令只读取原文、源语言和目标语言，调用系统翻译后输出文字；不包含网络地址、脚本或其他应用依赖。
  static func workflowData() throws -> Data {
    let ids = (0..<5).map { "8BA7638A-11F8-4EBC-A156-\(String(format: "%012d", $0))" }
    /// 将动作输出连接到下一个动作的参数。
    func output(_ index: Int) -> [String: Any] {
      [
        "Value": ["Type": "ActionOutput", "OutputUUID": ids[index], "OutputName": "Result"],
        "WFSerializationType": "WFTextTokenAttachment",
      ]
    }
    /// 创建一个系统内置动作及其参数。
    func action(_ name: String, _ parameters: [String: Any]) -> [String: Any] {
      [
        "WFWorkflowActionIdentifier": "is.workflow.actions.\(name)",
        "WFWorkflowActionParameters": parameters,
      ]
    }
    var actions = [
      action(
        "detect.dictionary",
        [
          "WFInput": [
            "Value": ["Type": "ExtensionInput"], "WFSerializationType": "WFTextTokenAttachment",
          ],
          "UUID": ids[0],
        ])
    ]
    for (index, key) in ["from", "to", "text"].enumerated() {
      actions.append(
        action(
          "getvalueforkey", ["WFInput": output(0), "WFDictionaryKey": key, "UUID": ids[index + 1]]))
    }
    actions.append(
      action(
        "text.translate",
        [
          "WFSelectedFromLanguage": output(1), "WFSelectedLanguage": output(2), "UUID": ids[4],
          "WFInputText": [
            "Value": ["string": "\u{fffc}", "attachmentsByRange": ["{0, 1}": output(3)["Value"]!]],
            "WFSerializationType": "WFTextTokenString",
          ],
        ]))
    actions.append(
      action(
        "output",
        [
          "WFOutput": [
            "Value": [
              "string": "\u{fffc}",
              "attachmentsByRange": [
                "{0, 1}": [
                  "Type": "ActionOutput", "OutputUUID": ids[4], "OutputName": "翻译后的文本",
                ]
              ],
            ],
            "WFSerializationType": "WFTextTokenString",
          ]
        ]))
    return try PropertyListSerialization.data(
      fromPropertyList: [
        "WFWorkflowName": shortcutName, "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "3036.0.4", "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowIcon": [
          "WFWorkflowIconStartColor": 4_282_601_983, "WFWorkflowIconGlyphNumber": 59733,
        ],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowOutputContentItemClasses": ["WFStringContentItem"],
        "WFWorkflowTypes": [String](), "WFWorkflowImportQuestions": [String](),
        "WFWorkflowHasOutputFallback": true,
      ], format: .binary, options: 0)
  }
}
