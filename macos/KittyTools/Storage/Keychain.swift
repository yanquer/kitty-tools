// 钥匙串（generic password，service = bundle id）：翻译服务的密钥只存这里，UserDefaults 和日志里不出现。
// 翻译服务条目用文件型登录钥匙串，受 ACL 保护（绑定签名）；自动加密同步的随机密钥另用数据保护钥匙串及 iCloud 同步。

import Foundation
import LocalAuthentication
import Security

nonisolated enum Keychain {
  private static let service = Bundle.main.bundleIdentifier ?? "com.yy.kitty-tools.native"

  /// 无交互读取 iCloud 钥匙串里的同步加密密钥；尚未传到本机返回 nil，访问拒绝保留系统错误码。
  static func readSyncKey(_ account: String) throws -> Data? {
    var query = syncKeyQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = result as? Data, data.count == 32 else { throw Failure(status: errSecDecode) }
    return data
  }

  /// 只新增随机同步密钥；重复条目保留原值，避免重试覆盖其他设备正在使用的密钥。
  static func addSyncKey(_ value: Data, account: String) throws {
    guard value.count == 32 else { throw Failure(status: errSecParam) }
    var item = syncKeyQuery(account)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    item[kSecValueData as String] = value
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw Failure(status: status)
    }
  }

  /// 同步条目使用应用私有访问组和系统端到端加密，禁止后台唤起钥匙串认证界面。
  static func syncKeyQuery(_ account: String) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service + ".sync-encryption",
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: true,
      kSecUseDataProtectionKeychain as String: true,
      kSecUseAuthenticationContext as String: context,
    ]
  }

  /// 区分条目不存在和系统拒绝访问，供加密同步保留钥匙串的原始错误码。
  static func read(_ account: String) throws -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw Failure(status: errSecDecode)
    }
    return value
  }

  /// 写入或删除并检查结果，失败时禁止同步把未落下的密钥记成成功。
  static func write(_ value: String?, for account: String) throws {
    let query = baseQuery(account)
    guard let value, !value.isEmpty else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw Failure(status: status)
      }
      return
    }
    let data = Data(value.utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(status: status) }
  }

  /// 系统钥匙串的错误只包含操作状态，避免账户名或凭据进入提示和日志。
  struct Failure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "钥匙串访问失败（系统错误码 \(status)）" }
  }

  static func get(_ account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 空值即删除
  static func set(_ value: String?, for account: String) {
    let query = baseQuery(account)
    guard let value, !value.isEmpty else {
      SecItemDelete(query as CFDictionary)
      return
    }
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      SecItemAdd(item as CFDictionary, nil)
    }
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
