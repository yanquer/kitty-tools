// 翻译密钥加密同步：同步开启后自动接入逐条合并，随机加密密钥经 iCloud 钥匙串传递，偏好只记哈希账本和加密恢复记录。

import Foundation
import OSLog
import Observation

@Observable final class SecretSync: SyncSource {
  /// 设置页展示本机的解锁状态，文件读写的结果仍由 NoteSyncer 展示。
  enum Status: Equatable {
    case preparing, waiting, ready, paused
    case failed(String)
  }

  /// 单个服务的密钥快照，认证的请求去向与设置导出共用同一份定义。
  nonisolated struct Credential: Codable, Sendable {
    var routing: Data
    var fields: [String: String]
  }

  /// 多字段钥匙串写入的恢复记录，落到偏好前由当前同步密钥加密。
  private struct Recovery: Codable {
    var originals: [String: String?]
    var ledger: SyncRecords.Ledger
  }

  /// 运行状态；截图自检直接设置各分支。
  var status: Status = .preparing
  @ObservationIgnored private(set) var access: SecretSyncCipher.Access?
  @ObservationIgnored private let services: TranslateServiceStore
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let read: (String) throws -> String?
  @ObservationIgnored private let write: (String?, String) throws -> Void
  @ObservationIgnored private let readCloudKey: (String) throws -> Data?
  @ObservationIgnored private let addCloudKey: (Data, String) throws -> Void
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var lastFailure: String?

  /// 注入钥匙串读写便于两台模拟电脑验证，测试不会接触真实钥匙串。
  init(
    services: TranslateServiceStore, defaults: UserDefaults = .standard,
    read: @escaping (String) throws -> String? = Keychain.read,
    write: @escaping (String?, String) throws -> Void = { try Keychain.write($0, for: $1) },
    readCloudKey: @escaping (String) throws -> Data? = Keychain.readSyncKey,
    addCloudKey: @escaping (Data, String) throws -> Void = Keychain.addSyncKey
  ) {
    self.services = services
    self.defaults = defaults
    self.read = read
    self.write = write
    self.readCloudKey = readCloudKey
    self.addCloudKey = addCloudKey
  }

  var syncKind: SyncRecords.Kind { .secrets }
  var syncJoin: SyncRecords.Join { .union(dedupe: { _ in nil }) }
  var syncBusy: Bool { access == nil }

  /// 同步开启后自动准备密钥；已有云盘配置时等待对应钥匙串条目，禁止另造密钥覆盖。
  func prepare(folder: URL, library: String) async {
    let operation = generation
    do {
      var configuration = try await NoteSyncDisk.secretConfiguration(in: folder, library: library)
      guard operation == generation else { return }
      if configuration == nil {
        configuration = try await createConfiguration(folder: folder, library: library)
      }
      guard operation == generation, let configuration else { return }
      guard configuration.format == 1 else { throw SecretSyncCipher.Failure.newer }
      if let access, access.library == library, access.configuration == configuration { return }
      access = nil
      guard let key = try readCloudKey(configuration.keyID.uuidString) else {
        if status != .waiting {
          Log.storage.info(
            "secret-sync waiting for iCloud Keychain library=\(library, privacy: .public)")
        }
        status = .waiting
        return
      }
      access = try SecretSyncCipher.access(configuration: configuration, key: key, library: library)
      status = .ready
      lastFailure = nil
      Log.storage.info("secret-sync automatic unlock success library=\(library, privacy: .public)")
    } catch {
      guard operation == generation else { return }
      access = nil
      report(error, stage: "prepare", library: library)
    }
  }

  /// 第一次同步生成随机密钥，先存 iCloud 钥匙串再写云盘编号；重试复用同一候选编号。
  private func createConfiguration(folder: URL, library: String) async throws
    -> SecretSyncCipher.Configuration
  {
    let candidateKey = "\(Prefs.syncSecretsCandidate).\(library)"
    let keyID = defaults.string(forKey: candidateKey).flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(keyID.uuidString, forKey: candidateKey)
    if try readCloudKey(keyID.uuidString) == nil {
      try addCloudKey(SecretSyncCipher.randomKey(), keyID.uuidString)
    }
    let candidate = SecretSyncCipher.Configuration(keyID: keyID)
    do {
      try await NoteSyncDisk.createSecretConfiguration(candidate, in: folder, library: library)
    } catch {
      // 同时首次加入的另一台先写了配置时，采用它的编号，等系统传来对应密钥。
      let failure = error as NSError
      guard failure.domain == NSCocoaErrorDomain,
        failure.code == CocoaError.fileWriteFileExists.rawValue
      else {
        throw error
      }
      guard let existing = try await NoteSyncDisk.secretConfiguration(in: folder, library: library)
      else { throw error }
      defaults.removeObject(forKey: candidateKey)
      return existing
    }
    defaults.removeObject(forKey: candidateKey)
    return candidate
  }

  /// 读取所有当前服务的密钥并编码为内存记录；访问拒绝会抛出，不能变成空密钥传播。
  func syncValues() throws -> [String: String] {
    guard access != nil else { throw SecretSyncCipher.Failure.disabled }
    try recover()
    guard services.services.count <= 200 else { throw SecretSyncCipher.Failure.tooLarge }
    var values: [String: String] = [:]
    for service in services.services where !service.secretFields.isEmpty {
      var fields: [String: String] = [:]
      for field in service.secretFields {
        if let value = try read(service.account(field.name)), !value.isEmpty {
          guard value.count <= 4096 else { throw SecretSyncCipher.Failure.tooLarge }
          fields[field.name] = value
        }
      }
      let credential = Credential(routing: SettingsArchive.routing(of: [service]), fields: fields)
      values[service.id] = String(
        decoding: try SyncRecords.encoder.encode(credential), as: UTF8.self)
    }
    return values
  }

  /// 账本仅含内容哈希和版本钟，与服务密钥一起留在本机。
  func syncLedger(library: String) throws -> SyncRecords.Ledger? {
    try SyncLedger.load(.secrets, library: library, in: defaults)
  }

  /// 先校验整批去向及字段，再写钥匙串；部分写入失败时恢复原值，成功之后才存账本。
  func applySync(_ changes: [String: String?], ledger: SyncRecords.Ledger, library: String)
    -> SyncApplied
  {
    var originals: [String: String?] = [:]
    var updates: [String: String?] = [:]
    var written: [String] = []
    var journalCreated = false
    do {
      try recover()
      for (id, value) in changes {
        // 服务被删时只同步移除记录，和翻译服务列表一样保留本机密钥。
        guard let value else { continue }
        guard let service = services.services.first(where: { $0.id == id }) else {
          throw Message("翻译密钥对应的服务尚未同步，请先同步翻译服务")
        }
        guard let credential = SyncRecords.decodeExact(Credential.self, from: value),
          credential.routing == SettingsArchive.routing(of: [service]),
          Set(credential.fields.keys).isSubset(of: Set(service.secretFields.map(\.name))),
          credential.fields.values.allSatisfy({ !$0.isEmpty && $0.count <= 4096 })
        else { throw Message("翻译密钥与服务地址或字段不匹配，已暂停密钥同步") }
        for field in service.secretFields {
          let account = service.account(field.name)
          originals.updateValue(try read(account), forKey: account)
          updates.updateValue(credential.fields[field.name], forKey: account)
        }
      }
      if !updates.isEmpty {
        guard let access, access.library == library else { throw SecretSyncCipher.Failure.disabled }
        let recovery = Recovery(originals: originals, ledger: ledger)
        let encrypted = try access.seal(
          SyncRecords.encoder.encode(recovery), device: "local-keychain-recovery")
        defaults.set(encrypted, forKey: recoveryKey(library))
        journalCreated = true
      }
      for account in updates.keys.sorted() {
        try write(updates[account]!, account)
        written.append(account)
      }
      try SyncLedger.save(ledger, kind: .secrets, library: library, in: defaults)
      defaults.removeObject(forKey: recoveryKey(library))
      status = .ready
      lastFailure = nil
      if !updates.isEmpty {
        Log.storage.info(
          "secret-sync apply success library=\(library, privacy: .public) fields=\(updates.count)")
      }
      return .saved
    } catch {
      var restored = true
      for account in written.reversed() {
        do { try write(originals[account]!, account) } catch {
          restored = false
          Log.storage.error(
            "secret-sync rollback failed type=\(String(reflecting: type(of: error)), privacy: .public) reason=\(error.localizedDescription, privacy: .public)"
          )
        }
      }
      if restored, journalCreated { defaults.removeObject(forKey: recoveryKey(library)) }
      report(error, stage: "apply", library: library)
      return .failure(error.localizedDescription)
    }
  }

  /// 恢复记录按库隔离，切换文件夹后仍能保留原库的待恢复内容。
  private func recoveryKey(_ library: String) -> String {
    "\(Prefs.syncSecretsRecovery).\(library)"
  }

  /// 重试或重启时先恢复未提交的钥匙串写入，恢复失败时禁止采集并发布半份新值。
  private func recover() throws {
    guard let access, let data = defaults.data(forKey: recoveryKey(access.library)) else { return }
    let plain = try access.open(data, device: "local-keychain-recovery")
    let recovery = try JSONDecoder().decode(Recovery.self, from: plain)
    if try SyncLedger.load(.secrets, library: access.library, in: defaults) != recovery.ledger {
      for account in recovery.originals.keys.sorted() {
        try write(recovery.originals[account]!, account)
      }
      Log.storage.info(
        "secret-sync recovered interrupted keychain write library=\(access.library, privacy: .public)"
      )
    }
    defaults.removeObject(forKey: recoveryKey(access.library))
  }

  /// 一轮密钥读写完整成功后恢复就绪状态，包含无需重复落账的重试轮。
  func succeeded() {
    guard access != nil else { return }
    status = .ready
    lastFailure = nil
  }

  /// 停止全局同步时清除内存中的加密密钥，稍后启用从同步钥匙串自动恢复。
  func syncStopped() {
    generation += 1
    access = nil
    status = .paused
  }

  /// 同一故障只记录一次，日志保留阶段、库编号、异常类型和安全的原始系统错误。
  func report(_ error: Error, stage: String, library: String) {
    let message = error.localizedDescription
    status = .failed(message)
    let failure = stage + message
    guard failure != lastFailure else { return }
    lastFailure = failure
    Log.storage.error(
      "secret-sync failed stage=\(stage, privacy: .public) library=\(library, privacy: .public) type=\(String(reflecting: type(of: error)), privacy: .public) reason=\(message, privacy: .public)"
    )
  }

  /// 固定中文业务说明，避免把解密正文带入错误信息。
  private struct Message: LocalizedError {
    let text: String
    /// 保存不含敏感正文的固定业务说明。
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
  }
}
