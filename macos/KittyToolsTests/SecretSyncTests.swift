// 加密密钥同步回归：临时云盘、两台模拟 Mac 和内存钥匙串，验证加密、合并、重启、篡改及写入失败回滚。

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import KittyTools

@MainActor struct SecretSyncTests {
  private let root = FileManager.default.temporaryDirectory.appending(
    path: "kitty-secret-sync-\(UUID().uuidString)")
  /// 模拟系统 iCloud 钥匙串；不同 Mac 可以暂时看不到已经上传的密钥。
  private final class Cloud {
    var keys: [String: Data] = [:]
  }

  /// 两台电脑各自的偏好、服务与钥匙串，所有测试读写均与用户真实数据隔离。
  private final class Mac {
    let suite = "kitty-secret-sync-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: NoteStore
    let services: TranslateServiceStore
    let syncer: NoteSyncer
    let cloud: Cloud
    var cloudAvailable = true
    var keys: [String: String] = [:]
    var readFailure = false
    var writeFailure: String?
    var rollbackFailure = false
    var writes = 0
    var secrets: SecretSync!

    /// 创建内存数据库与可控制故障的钥匙串，接入真实的同步执行层。
    init(host: String, cloud: Cloud = Cloud()) throws {
      self.cloud = cloud
      defaults = UserDefaults(suiteName: suite)!
      store = try NoteStore(db: Database(path: ":memory:"), wait: { _ in }, host: host)
      services = TranslateServiceStore(services: [.builtin(.baidu), .zhipu])
      syncer = NoteSyncer(store: store, defaults: defaults)
      syncer.editing = { [] }
      syncer.computerName = { host }
      wire()
    }

    /// 重建密钥同步对象，模拟退出之后从本机钥匙串自动解锁。
    func wire() {
      secrets = SecretSync(
        services: services, defaults: defaults,
        read: { [unowned self] account in
          if readFailure { throw Keychain.Failure(status: -25293) }
          return keys[account]
        },
        write: { [unowned self] value, account in
          if writeFailure == account { throw Keychain.Failure(status: -25293) }
          if rollbackFailure, account == "baidu.appId", value == "local-id" {
            throw Keychain.Failure(status: -25308)
          }
          writes += 1
          keys[account] = value
        },
        readCloudKey: { [unowned self] id in
          cloudAvailable ? cloud.keys[id] : nil
        },
        addCloudKey: { [unowned self] value, id in
          if cloud.keys[id] == nil { cloud.keys[id] = value }
        })
      syncer.secretSync = secrets
      syncer.sources = [TranslateServiceSync(store: services, defaults: defaults), secrets]
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
  }

  /// 准备空的同步文件夹并让两台电脑先同步服务配置。
  private func join(_ computers: [Mac]) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for mac in computers {
      #expect(await mac.syncer.enable(folder: root) == nil)
      await mac.syncer.round()
    }
  }

  /// 真实执行几轮同步，使两个内存仓库和临时同步文件收敛。
  private func settle(_ computers: [Mac]) async {
    for _ in 0..<3 { for mac in computers { await mac.syncer.round() } }
  }

  /// 清理临时文件夹，失败由测试框架记录。
  private func clean() {
    do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
  }

  /// 在同步目录和临时偏好中查明文及加密密钥，目录枚举保持在同步函数内。
  private func assertNoPlaintext(_ forbidden: [String], preferences: Data) throws {
    let files = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var contents = [preferences]
    for case let url as URL in files
    where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
      contents.append(try Data(contentsOf: url))
    }
    for value in forbidden {
      for data in contents { #expect(data.range(of: Data(value.utf8)) == nil) }
    }
  }

  /// 验证首次自动接入、密文落盘、重启恢复、修改删除及暂停行为。
  @Test func credentialsTravelEncryptedAndResumeAfterRestart() async throws {
    defer { clean() }
    let cloud = Cloud()
    let a = try Mac(host: "a", cloud: cloud)
    let b = try Mac(host: "b", cloud: cloud)
    a.keys["baidu.appId"] = "private-app-id"
    a.keys["baidu.secret"] = "private-secret-value"
    try await join([a, b])
    #expect(a.secrets.status == .ready)
    await settle([a, b])
    #expect(b.keys["baidu.secret"] == "private-secret-value")
    #expect(b.keys["baidu.appId"] == "private-app-id")
    #expect(b.syncer.status == .idle)
    let preferences = try PropertyListSerialization.data(
      fromPropertyList: b.defaults.persistentDomain(forName: b.suite) ?? [:], format: .xml,
      options: 0)
    try assertNoPlaintext(
      ["private-secret-value", "private-app-id"]
        + cloud.keys.values.map { $0.base64EncodedString() }, preferences: preferences)
    b.wire()
    #expect(b.secrets.status == .preparing)
    await b.syncer.round()
    #expect(b.secrets.status == .ready)
    a.keys["baidu.secret"] = "updated-secret"
    await settle([a, b])
    #expect(b.keys["baidu.secret"] == "updated-secret")
    a.keys["baidu.secret"] = nil
    await settle([a, b])
    #expect(b.keys["baidu.secret"] == nil)
    #expect(b.keys["baidu.appId"] == "private-app-id")
    b.syncer.setSyncs(SyncRecords.Kind.services.rawValue, false)
    a.keys["baidu.secret"] = "after-stop"
    await settle([a, b])
    #expect(b.keys["baidu.secret"] == nil && b.secrets.status == .paused)
  }

  /// 钥匙串尚未同步到第二台时保持本机密钥，云盘配置和密文均不能被自动重建覆盖。
  @Test func delayedCloudKeyAndCorruptCiphertextDoNotOverwriteCredentials() async throws {
    defer { clean() }
    let cloud = Cloud()
    let a = try Mac(host: "a", cloud: cloud)
    let b = try Mac(host: "b", cloud: cloud)
    a.keys["zhipu.apiKey"] = "source-secret"
    b.keys["zhipu.apiKey"] = "local-secret"
    b.cloudAvailable = false
    try await join([a, b])
    let library = try #require(b.syncer.library)
    let configuration = try await NoteSyncDisk.secretConfiguration(in: root, library: library)
    #expect(b.secrets.status == .waiting && b.keys["zhipu.apiKey"] == "local-secret")
    #expect(cloud.keys.count == 1)
    await b.syncer.round()
    #expect(try await NoteSyncDisk.secretConfiguration(in: root, library: library) == configuration)
    b.cloudAvailable = true
    let file = root.appending(path: "devices/\(a.store.deviceID)/secrets.json")
    let good = try Data(contentsOf: file)
    try Data("{\"format\":1,\"sealed\":\"AAAA\"}".utf8).write(to: file, options: .atomic)
    await b.syncer.round()
    #expect(b.keys["zhipu.apiKey"] == "local-secret")
    if case .stopped = b.syncer.status {} else { Issue.record("损坏密文必须显示同步失败") }
    #expect(b.defaults.data(forKey: SyncLedger.key(.secrets)) == nil)
    try good.write(to: file, options: .atomic)
    await settle([b, a])
    #expect(b.keys["zhipu.apiKey"] == "source-secret")
    #expect(b.syncer.status == .idle)
  }

  /// 验证钥匙串访问拒绝不能被发布为空密钥。
  @Test func inaccessibleKeychainDoesNotPublishEmptySecrets() async throws {
    defer { clean() }
    let a = try Mac(host: "a")
    a.keys["zhipu.apiKey"] = "source-secret"
    try await join([a])
    await a.syncer.round()
    let file = root.appending(path: "devices/\(a.store.deviceID)/secrets.json")
    let before = try Data(contentsOf: file)
    a.readFailure = true
    await a.syncer.round()
    #expect(try Data(contentsOf: file) == before)
    if case .stopped(.failed(let reason)) = a.syncer.status {
      #expect(reason.contains("-25293"))
    } else {
      Issue.record("钥匙串拒绝访问必须显示原始系统错误码")
    }
    a.readFailure = false
    await a.syncer.round()
    #expect(a.syncer.status == .idle)
  }

  /// 验证一批密钥写入中途失败时恢复原值并保持旧账本。
  @Test func failedKeychainWriteRollsBackAndRetriesWithoutAdvancingLedger() async throws {
    defer { clean() }
    let cloud = Cloud()
    let a = try Mac(host: "a", cloud: cloud)
    let b = try Mac(host: "b", cloud: cloud)
    a.keys["baidu.appId"] = "remote-id"
    a.keys["baidu.secret"] = "remote-key"
    b.keys["baidu.appId"] = "local-id"
    b.keys["baidu.secret"] = "local-key"
    b.cloudAvailable = false
    try await join([a, b])
    await a.syncer.round()
    b.cloudAvailable = true
    b.writeFailure = "baidu.secret"
    await b.syncer.round()
    #expect(b.keys["baidu.appId"] == "local-id" && b.keys["baidu.secret"] == "local-key")
    #expect(b.defaults.data(forKey: SyncLedger.key(.secrets)) == nil)
    b.writeFailure = nil
    await settle([b, a])
    #expect(b.keys["baidu.appId"] == "remote-id" && b.keys["baidu.secret"] == "remote-key")
  }

  /// 验证认证上下文能拒绝跨库、跨设备及明文替换。
  @Test func authenticatedFilesCannotMoveBetweenDevicesOrLibraries() async throws {
    let access = try SecretSyncCipher.access(
      configuration: .init(keyID: UUID()), key: SecretSyncCipher.randomKey(), library: "library")
    let plain = Data("密钥测试内容".utf8)
    let sealed = try access.seal(plain, device: "a")
    #expect(try access.open(sealed, device: "a") == plain)
    #expect(throws: SecretSyncCipher.Failure.self) { try access.open(sealed, device: "b") }
    let other = SecretSyncCipher.Access(
      library: "other", configuration: access.configuration, key: access.key)
    #expect(throws: SecretSyncCipher.Failure.self) { try other.open(sealed, device: "a") }
    #expect(throws: SecretSyncCipher.Failure.self) { try access.open(plain, device: "a") }
    var changed = sealed
    changed[changed.count / 2] ^= 1
    #expect(throws: (any Error).self) { try access.open(changed, device: "a") }
  }

  /// 原值回滚也失败时保留加密恢复记录，模拟重启后先恢复再重新应用完整密钥。
  @Test func interruptedWriteRecoversAfterRestart() async throws {
    defer { clean() }
    let cloud = Cloud()
    let a = try Mac(host: "a", cloud: cloud)
    let b = try Mac(host: "b", cloud: cloud)
    a.keys["baidu.appId"] = "remote-id"
    a.keys["baidu.secret"] = "remote-key"
    b.keys["baidu.appId"] = "local-id"
    b.keys["baidu.secret"] = "local-key"
    b.cloudAvailable = false
    try await join([a, b])
    b.cloudAvailable = true
    b.writeFailure = "baidu.secret"
    b.rollbackFailure = true
    await b.syncer.round()
    let library = try #require(b.syncer.library)
    let recoveryKey = "\(Prefs.syncSecretsRecovery).\(library)"
    let journal = try #require(b.defaults.data(forKey: recoveryKey))
    #expect(journal.range(of: Data("local-id".utf8)) == nil)
    #expect(b.defaults.data(forKey: SyncLedger.key(.secrets)) == nil)
    b.writeFailure = nil
    b.rollbackFailure = false
    b.wire()
    await settle([b, a])
    #expect(b.keys["baidu.appId"] == "remote-id" && b.keys["baidu.secret"] == "remote-key")
    #expect(b.defaults.data(forKey: recoveryKey) == nil && b.syncer.status == .idle)
  }

  /// 已有密文时丢失配置必须停下来，避免另造加密密钥让所有设备的旧密文失效。
  @Test func missingConfigurationDoesNotRegenerateKey() async throws {
    defer { clean() }
    let mac = try Mac(host: "a")
    mac.keys["zhipu.apiKey"] = "secret"
    try await join([mac])
    let config = root.appending(path: SecretSyncCipher.configurationName)
    let original = try Data(contentsOf: config)
    let count = mac.cloud.keys.count
    try FileManager.default.removeItem(at: config)
    await mac.syncer.round()
    if case .failed(let reason) = mac.secrets.status {
      #expect(reason.contains("配置缺失"))
    } else {
      Issue.record("已有密文但缺配置必须显示失败")
    }
    #expect(mac.cloud.keys.count == count && mac.keys["zhipu.apiKey"] == "secret")
    #expect(!FileManager.default.fileExists(atPath: config.path))
    try original.write(to: config, options: .atomic)
    await mac.syncer.round()
    #expect(mac.secrets.status == .ready)
  }

  /// 验证密钥与服务去向不匹配时在任何写入之前拒绝。
  @Test func routingAndUnknownCredentialFieldsAreRejectedBeforeWriting() throws {
    let mac = try Mac(host: "a")
    let service = TranslateService.newAI()
    var changed = service
    changed.baseURL = "https://different.example/v1"
    mac.services.services.append(changed)
    let credential = SecretSync.Credential(
      routing: SettingsArchive.routing(of: [service]), fields: ["apiKey": "private-key"])
    let value = String(decoding: try SyncRecords.encoder.encode(credential), as: UTF8.self)
    let writes = mac.writes
    let result = mac.secrets.applySync([service.id: value], ledger: .init(), library: "test")
    if case .failure(let reason) = result {
      #expect(reason.contains("不匹配"))
    } else {
      Issue.record("地址不匹配必须拒绝")
    }
    #expect(mac.writes == writes && mac.keys.isEmpty)
    #expect(mac.defaults.data(forKey: SyncLedger.key(.secrets)) == nil)
  }

  /// 系统钥匙串查询必须启用同步、使用数据保护钥匙串且禁止后台弹认证窗口。
  @Test func cloudKeychainQueryIsSynchronizableAndNoninteractive() {
    let query = Keychain.syncKeyQuery("test-key")
    #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(
      (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    #expect(
      query[kSecAttrService as String] as? String
        == (Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native") + ".sync-encryption")
  }

  /// 验证文件写入必须经过加密，首次配置创建禁止覆盖其他设备。
  @Test func diskWriterRequiresUnlockedAccessAndConfigurationDoesNotOverwrite() async throws {
    defer { clean() }
    let mac = try Mac(host: "a")
    try await join([mac])
    let secretFile = root.appending(path: "devices/\(mac.store.deviceID)/secrets.json")
    try FileManager.default.removeItem(at: secretFile)
    let written = await NoteSyncDisk.write(
      .init(), folder: root, device: mac.store.deviceID, name: "a", epoch: 0, images: nil,
      kinds: [.secrets: Data("plaintext".utf8)])
    #expect(written.problem != nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: "devices/\(mac.store.deviceID)/secrets.json").path))
    await mac.syncer.round()
    let library = try #require(mac.syncer.library)
    let before = try await NoteSyncDisk.secretConfiguration(in: root, library: library)
    let competing = SecretSyncCipher.Configuration(keyID: UUID())
    await #expect(throws: (any Error).self) {
      try await NoteSyncDisk.createSecretConfiguration(competing, in: root, library: library)
    }
    #expect(try await NoteSyncDisk.secretConfiguration(in: root, library: library) == before)
  }
}
