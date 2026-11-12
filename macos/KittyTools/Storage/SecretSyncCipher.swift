// 翻译密钥同步的文件加密：使用 iCloud 钥匙串传递的随机密钥，AES-GCM 认证同步库与设备，明文只在内存中出现。

import CryptoKit
import Foundation

nonisolated enum SecretSyncCipher {
  static let configurationName = "secret-sync.json"
  static let maxBytes = 2 << 20

  /// 云盘上只保留密钥编号，实际的 256 位密钥经 iCloud 钥匙串传递。
  struct Configuration: Codable, Equatable, Sendable {
    var format = 1
    var keyID: UUID
  }

  /// 一次钥匙串解锁后的访问；标识用于防止更换密钥后沿用旧明文缓存。
  struct Access: Sendable {
    let id = UUID()
    let library: String
    let configuration: Configuration
    let key: SymmetricKey

    /// 整份同步记录加密，版本钟、删除记录及服务去向一并认证。
    func seal(_ plain: Data, device: String) throws -> Data {
      guard plain.count <= SecretSyncCipher.maxBytes else { throw Failure.tooLarge }
      let box = try AES.GCM.seal(plain, using: key, authenticating: context(device))
      guard let combined = box.combined else { throw Failure.invalid }
      return try SyncRecords.encoder.encode(Envelope(sealed: combined))
    }

    /// 只接受通过认证的密文，拒绝明文、被改动的文件和其他设备或库的文件。
    func open(_ data: Data, device: String) throws -> Data {
      guard data.count <= SecretSyncCipher.maxBytes * 2,
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
      else { throw Failure.invalid }
      guard envelope.format == 1 else { throw Failure.newer }
      guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed) else {
        throw Failure.invalid
      }
      do {
        let plain = try AES.GCM.open(box, using: key, authenticating: context(device))
        guard plain.count <= SecretSyncCipher.maxBytes else { throw Failure.tooLarge }
        return plain
      } catch let error as Failure {
        throw error
      } catch {
        throw Failure.authentication
      }
    }

    /// 长度明确的认证上下文，避免跨库、跨设备替换密钥文件。
    private func context(_ device: String) -> Data {
      Data(
        ["Kitty Tools secret sync", "1", library, device].map { "\($0.utf8.count):\($0)" }.joined()
          .utf8)
    }
  }

  /// 磁盘密钥文件的封套，仅含格式号和 AES-GCM combined 密文。
  private struct Envelope: Codable {
    var format = 1
    var sealed: Data
  }

  /// 加密错误采用固定说明，原始凭据及解密正文不会进入错误描述。
  enum Failure: LocalizedError {
    case invalid, newer, authentication, downloading, missing, tooLarge, disabled

    var errorDescription: String? {
      switch self {
      case .invalid: "加密同步记录格式无效，请检查同步文件是否完整"
      case .newer: "加密同步记录来自更新版本，请先更新这台 Mac 上的 Kitty Tools"
      case .authentication: "翻译密钥文件校验失败，文件可能被改动或使用了其他加密密钥"
      case .downloading: "加密同步记录还在下载或暂时无法读取，稍后重试"
      case .missing: "加密同步配置缺失，请等待云盘同步完成，或从云盘历史版本恢复加密同步配置"
      case .tooLarge: "翻译密钥同步记录超过大小限制"
      case .disabled: "正在等待 iCloud 钥匙串中的同步加密密钥"
      }
    }
  }

  /// 校验从钥匙串取回的密钥长度和云盘配置，构建仅驻留内存的解密访问。
  static func access(configuration: Configuration, key: Data, library: String) throws -> Access {
    guard configuration.format == 1 else { throw Failure.newer }
    guard key.count == 32 else { throw Failure.invalid }
    return Access(library: library, configuration: configuration, key: SymmetricKey(data: key))
  }

  /// 随机生成 AES-256 密钥，仅交给同步钥匙串保存。
  static func randomKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }
}
