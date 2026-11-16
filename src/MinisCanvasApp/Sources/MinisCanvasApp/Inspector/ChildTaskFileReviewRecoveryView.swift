import SwiftUI
import MinisCore

struct ChildTaskFileReviewCheckpointScope {
    let childTaskID: String
    let absolutePath: String

    func contains(childTaskID candidateChild: String?, path candidatePath: String) -> Bool {
        candidateChild == childTaskID && candidatePath == absolutePath
    }
}

struct ChildTaskFileReviewRecoveryRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let childTaskID: String
    let absolutePath: String
}

/// A selection surface only. The Bridge callback owns approval, live ownership,
/// mutation lease and expected-after-hash checks; this view never opens files.
@MainActor
struct ChildTaskFileReviewRecoveryView: View {
    let sessionID: UUID
    let childTaskID: String
    let absolutePath: String
    let summaries: () -> [FileCheckpointStore.Summary]
    let onRequestRestore: (UUID) async -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var pendingCheckpointID: UUID?
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("审核子任务文件恢复").font(typography?.headline ?? .headline)
            Text("子任务 \(childTaskID)")
            Text(absolutePath).textSelection(.enabled)
            Text(FileCheckpointStore.scopeDisclosure)
                .foregroundStyle(.secondary)
            ScrollView {
                let scope = ChildTaskFileReviewCheckpointScope(childTaskID: childTaskID, absolutePath: absolutePath)
                let checkpoints = summaries().filter {
                    scope.contains(childTaskID: $0.childTaskID, path: $0.path)
                }
                if checkpoints.isEmpty {
                    Text("此会话、子任务与文件没有可恢复检查点。")
                }
                ForEach(checkpoints) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.createdAt, style: .date)
                        Text(item.createdAt, style: .time)
                        Button(pendingCheckpointID == item.id ? "正在审核…" : "申请恢复此快照…") {
                            request(item.id)
                        }
                        .disabled(pendingCheckpointID != nil)
                        .accessibilityIdentifier("child-checkpoints.restore.\(item.id.uuidString)")
                    }
                    .padding(8)
                }
            }
            Text("每次仅审核所选文件快照；未批准或文件已变化时不会恢复。")
                .foregroundStyle(.secondary)
            if let feedback { Text(feedback).accessibilityIdentifier("child-checkpoints.feedback") }
            Button("关闭") { dismiss() }.disabled(pendingCheckpointID != nil)
        }
        .font(typography?.caption ?? .caption)
        .padding(20).frame(minWidth: 480, minHeight: 360)
        .accessibilityIdentifier("child-checkpoints.review")
    }

    private func request(_ checkpointID: UUID) {
        guard pendingCheckpointID == nil else { return }
        pendingCheckpointID = checkpointID
        feedback = nil
        Task { @MainActor in
            let result = await onRequestRestore(checkpointID)
            guard pendingCheckpointID == checkpointID else { return }
            feedback = result
            pendingCheckpointID = nil
        }
    }
}
