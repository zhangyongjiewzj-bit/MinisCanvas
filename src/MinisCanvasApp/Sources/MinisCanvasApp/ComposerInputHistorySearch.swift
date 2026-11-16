import SwiftUI
import MinisCore

// Ephemeral values over the already loaded, profile-owned conversation projection.
enum ComposerHistoryScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case session, project, all
    var id: String { rawValue }
    var title: String {
        switch self { case .session: "本会话"; case .project: "本项目"; case .all: "全部" }
    }
}
struct ComposerHistoryEntry: Identifiable, Equatable, Sendable {
    let sourceSessionID: UUID
    let messageID: UUID
    let revision: UInt64
    let projectID: String?
    let title: String
    let text: String
    let reference: PastedTextReferenceCard?
    let updatedAt: Date
    let storeIdentity: ObjectIdentifier?
    var id: String { sourceSessionID.uuidString + ":" + messageID.uuidString }
    var searchText: String { text + (reference.map { "\n" + $0.material } ?? "") }
}

/// Selecting a current source fills the existing Composer; it never sends or navigates.
struct ComposerInputHistorySearch: View {
    let chat: ChatStore
    let redactor: ChatTranscriptRedactor?
    private let sessionID: UUID?
    private let store: SessionStore?
    private let scoped: Bool
    private let legacyHistory: [String]
    private let targetDraft: ComposerEditDraftIdentity
    @State private var query = ""
    @State private var scope: ComposerHistoryScope = .session
    @State private var results: [ComposerHistoryEntry] = []
    @State private var epoch: UInt64 = 0
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss

    init(chat: ChatStore) {
        self.chat = chat; self.redactor = nil; self.sessionID = chat.activeSessionID
        self.store = chat.sessionStore; self.scoped = false
        self.legacyHistory = chat.localInputHistory.reversed()
        self.targetDraft = ComposerEditDraftIdentity.capture(chat)
    }
    init(chat: ChatStore, redactor: ChatTranscriptRedactor?) {
        self.chat = chat; self.redactor = redactor; self.sessionID = chat.activeSessionID
        self.store = chat.sessionStore; self.scoped = true; self.legacyHistory = []
        self.targetDraft = ComposerEditDraftIdentity.capture(chat)
    }
    private var projectAvailable: Bool {
        chat.sessions.first(where: { $0.id == sessionID })?.projectID?.isEmpty == false
    }
    private var queryIdentity: [String] {
        [scope.rawValue, query, chat.activeSessionID?.uuidString ?? "",
         chat.sessionStore.map { String(describing: ObjectIdentifier($0)) } ?? ""]
        + (chat.sessions + chat.archivedSessions).map {
            "\($0.id.uuidString):\($0.transcriptRevision):\($0.projectID ?? "")"
        }
    }
    var body: some View {
        if scoped { scopedBody } else { legacyBody }
    }
    private var legacyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索本会话输入历史").font(.headline)
            TextField("搜索输入…", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("composer.history.search")
            List(Array(legacyHistory.enumerated()).filter {
                query.isEmpty || $0.element.localizedCaseInsensitiveContains(query)
            }, id: \.offset) { item in
                Button { if chat.recallLocalInput(item.element, expectedSessionID: sessionID) { dismiss() } }
                    label: { Text(item.element).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain)
            }
            Text("仅搜索本机会话中已保存的用户输入；选择后可编辑，不会自动发送。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(16).frame(width: 520, height: 380)
        .onChange(of: chat.activeSessionID) { _, value in if value != sessionID { dismiss() } }
    }
    private var scopedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索输入历史").font(.headline)
            Picker("范围", selection: $scope) {
                ForEach(ComposerHistoryScope.allCases) { item in
                    Text(item.title).tag(item).disabled(item == .project && !projectAvailable)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("composer.history.scope")
            TextField("搜索输入…", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("composer.history.search")
            if let redactor {
                List(results) { item in
                    Button {
                        if chat.recallInputHistory(item, scope: scope, expectedSessionID: sessionID,
                            expectedStore: store, expectedDraft: targetDraft) { dismiss() }
                        else { feedback = "来源或当前输入已变化，请刷新后重新选择。" }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(SessionSearchSafeText.sanitized(redactor.redactVisibleConversationBody(item.title)))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(SessionSearchSafeText.sanitized(redactor.redactVisibleConversationBody(
                                item.text.isEmpty ? (item.reference?.preview ?? "引用输入") : item.text)))
                                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("composer.history.result.\(item.id)")
                }
            } else { Text("历史脱敏尚未准备就绪，请稍后重开。") }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            Text("仅当前配置的聊天与归档；不含回收站。选择后替换输入，不自动发送；原附件需重新添加。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(16).frame(width: 520, height: 380)
        .task(id: queryIdentity) {
            epoch &+= 1
            let request = epoch
            results = []
            feedback = nil
            let entries = chat.inputHistoryEntries(scope: scope)
            let needle = query
            let filtering = Task.detached(priority: .userInitiated) {
                var found: [ComposerHistoryEntry] = []
                for entry in entries {
                    try Task.checkCancellation()
                    if needle.isEmpty || entry.searchText.localizedCaseInsensitiveContains(needle) { found.append(entry) }
                }
                return found
            }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await filtering.value },
                    onCancel: { filtering.cancel() })
                guard !Task.isCancelled, epoch == request, chat.activeSessionID == sessionID,
                      chat.sessionStore === store else { return }
                results = value
            } catch { /* A cancelled query never publishes over its replacement. */ }
        }
        .onChange(of: chat.activeSessionID) { _, value in if value != sessionID { results = []; dismiss() } }
        .onChange(of: chat.sessionStore.map { ObjectIdentifier($0) }) { _, value in
            if value != store.map({ ObjectIdentifier($0) }) { results = []; dismiss() }
        }
    }
}
