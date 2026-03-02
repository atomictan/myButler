import SwiftUI

struct VoiceSessionDiffReviewView: View {
    let diff: VoiceSessionDiff
    @ObservedObject var store: ItemStore
    let onApply: (VoiceSessionDiffSelection) -> Void
    let onCancel: () -> Void

    @State private var selection: VoiceSessionDiffSelection

    init(
        diff: VoiceSessionDiff,
        store: ItemStore,
        onApply: @escaping (VoiceSessionDiffSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.diff = diff
        self.store = store
        self.onApply = onApply
        self.onCancel = onCancel
        let mergedCreateIds = Set(diff.merges.map { $0.sourceTempId })
        _selection = State(initialValue: VoiceSessionDiffSelection(
            createTempIds: Set(diff.creates.map { $0.tempId }).subtracting(mergedCreateIds),
            updateIds: Set(diff.updates.map { $0.id }),
            mergeSourceIds: Set(diff.merges.map { $0.sourceTempId }),
            deleteIds: Set(diff.deletes.map { $0.id })
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                if diff.isEmpty {
                    Section {
                        Text("No proposed changes.")
                            .foregroundStyle(.secondary)
                    }
                }
                let mergedCreateIds = Set(diff.merges.map { $0.sourceTempId })
                let createItems = diff.creates.filter { !mergedCreateIds.contains($0.tempId) }
                diffSection(title: "Create", items: createItems) { create in
                    Toggle(isOn: binding(for: create.tempId, in: \.createTempIds)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(create.title)
                                .font(.headline)
                            Text(create.type.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !create.details.isEmpty {
                                Text(create.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                diffSection(title: "Update", items: diff.updates) { update in
                    Toggle(isOn: binding(for: update.id, in: \.updateIds)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(itemTitle(for: update.id) ?? "Unknown item")
                                .font(.headline)
                            Text(updateSummary(update))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                diffSection(title: "Merge", items: diff.merges) { merge in
                    Toggle(isOn: binding(for: merge.sourceTempId, in: \.mergeSourceIds)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Merge into: \(itemTitle(for: merge.targetId) ?? "Unknown item")")
                                .font(.headline)
                            if let source = diff.creates.first(where: { $0.tempId == merge.sourceTempId }) {
                                Text("New item: \(source.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let summary = merge.mergeSummary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                diffSection(title: "Delete", items: diff.deletes) { delete in
                    Toggle(isOn: binding(for: delete.id, in: \.deleteIds)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(itemTitle(for: delete.id) ?? "Unknown item")
                                .font(.headline)
                            if let reason = delete.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Proposed Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(selection)
                    }
                    .disabled(diff.isEmpty)
                }
            }
        }
    }

    private func diffSection<ItemView: View, ItemType>(
        title: String,
        items: [ItemType],
        @ViewBuilder content: @escaping (ItemType) -> ItemView
    ) -> some View {
        Group {
            if !items.isEmpty {
                Section(title) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        content(item)
                    }
                }
            }
        }
    }

    private func itemTitle(for id: String) -> String? {
        store.items.first { $0.id.uuidString == id }?.title
    }

    private func updateSummary(_ update: VoiceSessionDiffUpdate) -> String {
        var parts: [String] = []
        if let title = update.changes.title {
            parts.append("Title → \(title)")
        }
        if let details = update.changes.details, !details.isEmpty {
            parts.append("Details updated")
        }
        if let dueDate = update.changes.dueDate {
            parts.append("Due → \(dueDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let priority = update.changes.priority {
            parts.append("Priority → \(priority.label)")
        }
        if let project = update.changes.project {
            parts.append("Project → \(project)")
        }
        if let tags = update.changes.tags, !tags.isEmpty {
            parts.append("Tags → \(tags.joined(separator: ", "))")
        }
        return parts.isEmpty ? "Changes proposed" : parts.joined(separator: " · ")
    }

    private func binding(for id: String, in keyPath: WritableKeyPath<VoiceSessionDiffSelection, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { selection[keyPath: keyPath].contains(id) },
            set: { isOn in
                if isOn {
                    selection[keyPath: keyPath].insert(id)
                } else {
                    selection[keyPath: keyPath].remove(id)
                }
            }
        )
    }
}
