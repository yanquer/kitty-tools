// 设置 › 通用「同步」（2026-10-23 全局同步拍板 A1：从 设置 › 便签 挪过来，整个 App 的同步都在这一节。执行在 NoteSyncer）。
// 一键开启 iCloud 同步，由应用自动管理普通云盘中的固定目录；已有自选文件夹继续兼容，打开 iCloud 开关后切换到固定云盘目录。

import AppKit
import SwiftUI

/// iCloud 开关、同步状态和内容分类；云盘定位与文件读写均在执行层的主线程外进行。
struct SyncSection: View {
  let syncer: NoteSyncer
  /// 几部分跟着的功能开着没有（关着的那部分不同步：勾下面说一声）
  @AppStorage(Feature.notes.prefsKey) private var notesOn = true
  @AppStorage(Feature.clipboard.prefsKey) private var clipboardOn = true
  @AppStorage(Feature.translate.prefsKey) private var translateOn = true
  @AppStorage(Feature.launcher.prefsKey) private var launcherOn = true
  @AppStorage(Feature.statusScreen.prefsKey) private var statusScreenOn = true
  @AppStorage(Feature.reminders.prefsKey) private var remindersOn = true
  /// 每分钟走一下：「上次同步：3 分钟前」自己往前走（便签关着时没有新的一轮来刷新）
  @State private var tick = Date.now
  /// 勾上会是第一次合的那一类（NoteSyncer.joins）：先问合不合在一起，确认框开着时有值
  @State private var confirming: String?

  var body: some View {
    Section {
      offRow
      if let folder = syncer.folder {
        folderRow(folder)
          .confirmationDialog(
            "「\(confirming.flatMap(SyncRecords.Kind.init(rawValue:))?.title ?? "")」和已经在同步的 Mac 合在一起？",
            isPresented: Binding {
              confirming != nil
            } set: {
              if !$0 { confirming = nil }
            },
            presenting: confirming
          ) { part in
            Button("合在一起") { syncer.setSyncs(part, true) }
          } message: { _ in
            Text(Self.joinNote)
          }
        part(
          SyncRecords.Kind.settings.rawValue, title: SyncRecords.Kind.settings.title,
          detail: "各页的设置、全局快捷键和功能开关；启动台、录音的麦克风、菜单栏图标这些跟着这台 Mac 的不同步")
        part(
          NoteSyncer.notesPart, title: "便签", detail: "连同正文里的图片", feature: "便签",
          isOn: notesOn)
        part(
          SyncRecords.Kind.clips.rawValue, title: SyncRecords.Kind.clips.title,
          detail: "文字的片段、收藏和收藏夹；图片和文件的收藏不同步", feature: "剪贴板", isOn: clipboardOn)
        part(
          SyncRecords.Kind.vocabulary.rawValue, title: SyncRecords.Kind.vocabulary.title,
          detail: "翻译里收藏的词句", feature: "翻译", isOn: translateOn)
        part(
          SyncRecords.Kind.engines.rawValue, title: SyncRecords.Kind.engines.title,
          detail: "启动器里的网页搜索和快捷链接", feature: "启动器", isOn: launcherOn)
        part(
          SyncRecords.Kind.services.rawValue, title: SyncRecords.Kind.services.title,
          detail: "哪几个服务、顺序和设置；密钥通过 iCloud 钥匙串自动加密同步", feature: "翻译",
          isOn: translateOn)
        if let secrets = syncer.secretSync {
          LabeledContent {
            if case .failed = secrets.status {
              Text(secretStatus(secrets)).foregroundStyle(.orange)
            } else {
              Text(secretStatus(secrets)).foregroundStyle(.secondary)
            }
          } label: {
            Text("翻译密钥")
            Text("同一 Apple 账户并开启 iCloud 钥匙串后自动接入")
          }
        }
        part(
          SyncRecords.Kind.statuses.rawValue, title: SyncRecords.Kind.statuses.title,
          detail: "状态屏里自己写的那几个状态", feature: "状态屏", isOn: statusScreenOn)
        part(
          SyncRecords.Kind.reminders.rawValue, title: SyncRecords.Kind.reminders.title,
          detail: "有哪些提醒、各自的时间和方式；两台都开着时两台都响", feature: "提醒", isOn: remindersOn)
        part(
          SyncRecords.Kind.launcher.rawValue, title: SyncRecords.Kind.launcher.title,
          detail: "空搜索框里收藏的那几个；这台没装的 App 不显示，装上就回来", feature: "启动器",
          isOn: launcherOn)
        LabeledContent {
          EmptyView()
        } label: {
          Text("其他 Mac")
          Text(peersLine)
        }
      }
    } header: {
      Text("同步")
    } footer: {
      SectionFootnote(
        "新加入的 Mac 会采用云端设置和快捷键，按同步后的保留规则清理历史，便签等内容合并保留。翻译密钥加密保存并由 iCloud 钥匙串自动解锁，其他内容以明文保存。关闭同步后，本机和云端的数据都会保留。"
      )
    }
  }

  // MARK: 没开

  /// 独立展示密钥的自动解锁和失败状态，等待钥匙串时其他同步内容继续处理。
  private func secretStatus(_ secrets: SecretSync) -> String {
    switch secrets.status {
    case .preparing: "正在准备加密同步…"
    case .waiting: "等待 iCloud 钥匙串，请确认系统已开启「密码与钥匙串」同步"
    case .ready: "已自动解锁，随翻译服务同步"
    case .paused: "随翻译服务暂停"
    case .failed(let reason): reason
    }
  }

  private var offRow: some View {
    Toggle(
      isOn: Binding {
        syncer.iCloudEnabled
      } set: { enabled in
        if enabled { syncer.enableICloud() } else { syncer.disable() }
      }
    ) {
      Text("iCloud 同步")
      Text(
        syncer.folder != nil && !syncer.iCloudEnabled
          ? "原文件夹同步正在运行，开启后自动切换到 iCloud 云盘的固定同步目录"
          : "在使用同一 Apple 账户的 Mac 上开启，即可自动同步")
      if syncer.iCloudEnabled, syncer.folder == nil {
        Text(statusLine)
        if let trouble { Text(trouble).foregroundStyle(.orange) }
      }
    }
  }

  /// 分类首次加入的说明，供开着同步时勾上还没合过的一类使用
  static let joinNote =
    "合在一起后，这台 Mac 上的便签、片段、收藏、生词和状态屏的状态和它们的会出现在每台 Mac 上（同样的不重复）；设置、快捷键、功能开关（连同内置的网页搜索、翻译服务）换成已经在同步的那几台的——剪贴板的保留天数、「不记录」的 App 也跟着换，超出新保留天数的历史会清掉。同一 Apple 账户开启 iCloud 钥匙串后，翻译密钥也会自动加密同步，首次加入采用已有的同名服务密钥。之后同一条两边都改过的，后改的留下。"

  // MARK: 开着

  private func folderRow(_ folder: URL) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        Label(
          syncer.iCloudEnabled ? "iCloud" : folder.lastPathComponent,
          systemImage: syncer.iCloudEnabled ? "icloud" : "folder"
        )
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .help(syncer.iCloudEnabled ? "由应用自动管理 iCloud 云盘中的固定目录" : Self.shown(folder))
        if !syncer.iCloudEnabled {
          Button("停止同步") { syncer.disable() }
            .buttonStyle(.plain)
            .foregroundStyle(Style.brandInk)
            .pointerStyle(.link)
            .help("文件夹里的东西留着，这台 Mac 上的数据也不动")
        }
        if case .waiting = syncer.status {
          Button("继续同步") { syncer.confirmTrashing() }
        } else {
          // 不停用：一轮没完时按它排在后面（停用的话每 20 秒闪一下灰）
          Button("立即同步") { syncer.syncNow() }
        }
      }
    } label: {
      Text(syncer.iCloudEnabled ? "同步状态" : "原文件夹同步")
      Text(statusLine)
      if syncer.newKindsHint {
        Text("现在也能同步设置、片段和收藏这些了：在下面勾上要同步的几类，勾的时候先问合不合在一起")
      }
      if let trouble {
        Text(trouble).foregroundStyle(Color(nsColor: .systemOrange))
      }
    }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        tick = .now
      }
    }
    // 「现在也能同步…」那句看过了：离开这一节就不再说
    .onDisappear { syncer.dismissHint() }
  }

  /// 「同步的内容」里的一类：勾上才同步；它跟着的功能关着时说一声（勾着也先不同步）
  private func part(
    _ name: String, title: String, detail: String, feature: String = "", isOn featureOn: Bool = true
  ) -> some View {
    Toggle(
      isOn: Binding {
        syncer.syncs(name)
      } set: {
        if $0, syncer.joins(name) { confirming = name } else { syncer.setSyncs(name, $0) }
      }
    ) {
      Text(title)
      Text(featureOn ? detail : "\(feature)关着，先不同步；在上面「功能」里打开就接着同步")
    }
  }

  /// 状态：上次同步的时刻（第一轮还没完时说正在同步）、还在下载几个
  private var statusLine: String {
    var line: String
    if let lastSync = syncer.lastSync {
      line = "上次同步：\(Self.ago(lastSync, now: tick))"
    } else if syncer.status == .syncing {
      line = "正在同步…"
    } else {
      line = "还没同步过"
    }
    if syncer.downloading > 0 { line += "；还有 \(syncer.downloading) 个文件在下载" }
    return line
  }

  /// 停了、等确认：为什么、能怎么办（橙字）
  private var trouble: String? {
    switch syncer.status {
    case .off, .syncing, .idle: nil
    case .waiting(let trashing):
      "这一轮要删掉 \(trashing) 条（便签是放进「最近删除」），先停下来等你确认"
    case .stopped(let problem):
      switch problem {
      case .missingFolder: "找不到同步文件夹：没接上、被挪走或删了，找到了自己接着同步"
      case .notTheFolder:
        syncer.iCloudEnabled
          ? "iCloud 同步记录缺失或已变更，请等待云盘下载完成，或从云盘历史版本恢复同步记录"
          : "原文件夹的同步记录已变更，请停止原文件夹同步后开启 iCloud 同步"
      case .newerFormat: "文件夹里有更新版本的 Kitty Tools 写的东西，先更新这台 Mac 上的 Kitty Tools"
      case .unreadable(let name):
        "\(name.map { "「\($0)」" } ?? "另一台 Mac ")那份同步记录还读不出来（多半是还没下载完），读到了自己接着同步"
      case .downloading: "同步文件夹里有文件还没下载到这台 Mac，下载完自己接着同步"
      case .failed(let reason): "上一轮没同步成：\(Self.clause(reason))"
      }
    }
  }

  private var peersLine: String {
    guard !syncer.peers.isEmpty else {
      // 第一轮还没合完（或者合之前就停了）时不知道有没有
      return syncer.lastSync == nil
        ? "同步一轮之后列在这里" : "还没有——在另一台 Mac 的 设置 › 通用 里开启 iCloud 同步"
    }
    return syncer.peers.map { peer in
      let name = peer.name ?? "没写名字的一台"
      return peer.seen.map { "\(name)（\(Self.ago($0, now: tick))有改动）" } ?? name
    }.joined(separator: "、")
  }

  /// 「刚刚」「3 分钟前」「昨天」
  private static func ago(_ date: Date, now: Date) -> String {
    let now = max(now, .now)
    return now.timeIntervalSince(date) < 60
      ? "刚刚" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
  }

  /// 系统给的原因（localizedDescription）带句号：行副标题一句话不加
  private static func clause(_ text: String) -> String {
    text.trimmingCharacters(in: ["。", "."])
  }

  /// iCloud 云盘在本机的位置（选文件夹的面板先指到这里）
  static let iCloudDrive = NoteSyncDisk.iCloudDrive

  /// 悬停时给人看的路径：iCloud 云盘里的写成「iCloud 云盘/…」，家目录写成 ~
  static func shown(_ folder: URL) -> String {
    let drive = iCloudDrive.path(percentEncoded: false)
    let path = folder.path(percentEncoded: false)
    if path.hasPrefix(drive) {
      return "iCloud 云盘/" + path.dropFirst(drive.count).trimmingCharacters(in: ["/"])
    }
    return (path as NSString).abbreviatingWithTildeInPath
  }
}
