// 截图历史标签编辑表单。按打开时的记录编号暂存增删，保存时由历史库一次性提交。

import SwiftUI

/// 固定这次编辑的记录编号和可审阅的标签覆盖情况。
struct ShotTagEdit: Identifiable {
  struct Coverage: Identifiable {
    let name: String
    var count: Int
    var id: String { ShotTags.key(name) }
  }

  let id = UUID()
  let targets: [UUID]
  let summary: String
  let tags: [Coverage]

  /// 只保留名称和数量，编辑几张大图时不保留额外的图片或标注数据。
  init(items: [ShotHistory.Item]) {
    targets = items.map(\.id)
    summary =
      items.count == 1
      ? items.map(ShotHistoryModel.caption).joined()
      : ShotHistoryModel.summary(items)
    var counts: [String: Coverage] = [:]
    for item in items {
      for name in item.tags {
        let key = ShotTags.key(name)
        counts[key, default: Coverage(name: name, count: 0)].count += 1
      }
    }
    tags = counts.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// 单条与多选共用表单，暂存操作可以逐项撤回并在保存前检查范围。
struct ShotHistoryTagEditor: View {
  let edit: ShotTagEdit
  let save: ([UUID], [String], [String]) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var adding: [String] = []
  @State private var removing: [String] = []
  @State private var error: String?
  @FocusState private var entering: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("编辑标签").font(.headline)
        Text("\(edit.targets.count) 项 · \(edit.summary)")
          .font(.subheadline).foregroundStyle(.secondary).lineLimit(2).help(edit.summary)
      }
      HStack {
        TextField("标签名称", text: $input).focused($entering).onSubmit(stageInput)
        Button("添加", action: stageInput).disabled(trimmedInput.isEmpty)
      }
      Hairline()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if edit.tags.isEmpty && adding.isEmpty {
            Text("所选记录还没有标签").foregroundStyle(.secondary).frame(maxWidth: .infinity)
          }
          ForEach(edit.tags) { tag in tagRow(tag) }
          ForEach(
            adding.filter { name in !edit.tags.contains { $0.id == ShotTags.key(name) } },
            id: \.self
          ) { name in
            tagRow(.init(name: name, count: 0))
          }
        }
        .padding(.vertical, 2)
      }
      .frame(minHeight: 76, maxHeight: 222)
      Text(error ?? "每项最多 \(ShotTags.maximumPerItem) 个标签。保存后应用到所选记录。")
        .font(.footnote).foregroundStyle(
          error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Style.danger)
        )
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存标签", action: apply).buttonStyle(BrandButtonStyle())
          .keyboardShortcut("s")
          .help("保存标签（⌘S）")
          .disabled(adding.isEmpty && removing.isEmpty && trimmedInput.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 440)
    .onAppear { entering = true }
    .appAccent()
  }

  private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// 显示该标签当前覆盖的记录数，以及本次待保存的变更。
  private func tagRow(_ tag: ShotTagEdit.Coverage) -> some View {
    let isAdding = adding.contains { ShotTags.key($0) == tag.id }
    let isRemoving = removing.contains { ShotTags.key($0) == tag.id }
    return HStack(spacing: 10) {
      Text(tag.name).lineLimit(1).help(tag.name)
      Spacer(minLength: 8)
      if isAdding || isRemoving {
        Text(isRemoving ? "将移除" : "将添加到全部").foregroundStyle(.secondary)
        Button("撤回") { revert(tag.id) }.accessibilityLabel("撤回「\(tag.name)」的更改")
      } else {
        Text(tag.count == edit.targets.count ? "全部" : "\(tag.count)/\(edit.targets.count) 项")
          .foregroundStyle(.secondary)
        if tag.count < edit.targets.count {
          Button("添加到全部") { stageAddition(tag.name) }
            .accessibilityLabel("将「\(tag.name)」添加到全部")
        }
        Button(role: .destructive) {
          removing.append(tag.name)
          error = nil
        } label: {
          Image(systemName: "xmark.circle").accessibilityLabel("移除「\(tag.name)」")
        }
        .buttonStyle(.borderless).help("从所选记录移除「\(tag.name)」")
      }
    }
    .font(.system(size: 13))
    .controlSize(.small)
  }

  /// 非法名称留在输入框中供修改，有效名称才进入待保存列表。
  private func stageInput() {
    guard !trimmedInput.isEmpty else { return }
    do {
      let name = try ShotTags.name(input)
      stageAddition(name)
      input = ""
    } catch let failure { error = failure.localizedDescription }
  }

  /// 同一标签的最新操作优先，已有的拼写继续沿用。
  private func stageAddition(_ name: String) {
    let key = ShotTags.key(name)
    revert(key)
    let original = edit.tags.first { $0.id == key }
    if original?.count != edit.targets.count { adding.append(original?.name ?? name) }
  }

  /// 恢复当前标签的原有状态，其余待保存变更保留。
  private func revert(_ key: String) {
    adding.removeAll { ShotTags.key($0) == key }
    removing.removeAll { ShotTags.key($0) == key }
    error = nil
  }

  /// 所有记录成功更新才收起表单，失败后保留输入和准备提交的操作。
  private func apply() {
    if !trimmedInput.isEmpty {
      stageInput()
      guard input.isEmpty else { return }
    }
    do {
      try save(edit.targets, adding, removing)
      dismiss()
    } catch let failure {
      error = (failure as? ShotTags.Failure ?? .storageUnavailable).localizedDescription
    }
  }
}
