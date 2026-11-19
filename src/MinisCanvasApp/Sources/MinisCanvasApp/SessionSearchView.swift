import Foundation
import Observation
import SwiftUI

/// A search hit carries both the durable Core locator and the current App
/// message identity.  The latter is only a rendering anchor; the former is
/// revalidated by ChatStore before navigation.
struct SessionSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: UUID
    let messageID: String
    let uiMessageID: UUID
    let transcriptIndex: Int
    let title: String
    let snippet: String
    let matchedText: String?
    let isArchived: Bool
    let updatedAt: Date
    let transcriptRevision: UInt64
    let searchEpoch: UInt64

    init(
        sessionID: UUID,
        messageID: String,
        uiMessageID: UUID,
        transcriptIndex: Int,
        title: String,
        snippet: String,
        matchedText: String?,
        isArchived: Bool,
        updatedAt: Date,
        transcriptRevision: UInt64,
        searchEpoch: UInt64 = 0
    ) {
        self.id = "\(sessionID.uuidString)#\(messageID)"
        self.sessionID = sessionID
        self.messageID = messageID
        self.uiMessageID = uiMessageID
        self.transcriptIndex = transcriptIndex
        self.title = title
        self.snippet = snippet
        self.matchedText = matchedText
        self.isArchived = isArchived
        self.updatedAt = updatedAt
        self.transcriptRevision = transcriptRevision
        self.searchEpoch = searchEpoch
    }

    func with(searchEpoch: UInt64) -> Self {
        Self(
            sessionID: sessionID,
            messageID: messageID,
            uiMessageID: uiMessageID,
            transcriptIndex: transcriptIndex,
            title: title,
            snippet: snippet,
            matchedText: matchedText,
            isArchived: isArchived,
            updatedAt: updatedAt,
            transcriptRevision: transcriptRevision,
            searchEpoch: searchEpoch
        )
    }
}

/// One-shot navigation request consumed by the transcript's existing outer
/// ScrollViewReader.  A monotonically changing request ID lets repeated clicks
/// on one message trigger a fresh scroll without changing transcript identity.
struct ChatTranscriptScrollTarget: Equatable, Identifiable, Sendable {
    let id: UInt64
    let sessionID: UUID
    let messageID: UUID
    let stableMessageID: String
}

/// Search rows use the same redaction and tool-envelope boundary as the
/// existing session search donor.  Raw tool arguments and credential-shaped
/// values never enter a user-visible result.
enum SessionSearchSafeText {
    static func displayText(for message: ChatMessageUI) -> String? {
        // 带工具调用的助手回复也要能搜到：工具参数在 toolCalls 里，不在正文，
        // 正文里的工具信封标记仍由 sanitizedFull 整条拒绝。
        guard message.role == .user || message.role == .assistant else { return nil }
        // 全文（不截断）用于匹配，命中位置再由 snippet(around:in:) 截取。
        let value = sanitizedFull(message.displayContent)
        return value.isEmpty ? nil : value
    }

    /// 命中处附近约 limit 字的片段；命中在开头之后时前面加省略号。
    static func snippet(around needle: String, in text: String, limit: Int = 160) -> String {
        guard text.count > limit,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let hit = text.distance(from: text.startIndex, to: range.lowerBound)
        let start = max(0, hit - 40)
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: min(limit, text.count - start))
        return (start > 0 ? "…" : "") + String(text[from..<to]) + (to < text.endIndex ? "…" : "")
    }

    static func sanitized(_ value: String) -> String {
        let text = sanitizedFull(value)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }

    static func sanitizedFull(_ value: String) -> String {
        var text = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return "" }

        let lower = text.lowercased()
        let toolMarkers = [
            "tool_call", "tool-call", "function_call", "function-call",
            "<tool_call>", "<function_call>", "\"arguments\""
        ]
        if toolMarkers.contains(where: { lower.contains($0) }) {
            return ""
        }

        let secretPatterns = [
            #"(?i)\b(?:api[_ -]?key|token|password|secret|authorization|bearer)\b\s*[:=]\s*[^\s,;]+"#,
            #"(?i)\b(?:sk|ghp|github_pat|xoxb|xoxp)-[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}\b"#
        ]
        for pattern in secretPatterns {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = expression.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: range,
                    withTemplate: "[已隐藏]"
                )
            }
        }
        return text
    }
}

enum SessionSearchState: Equatable, Sendable {
    case ready
    case rebuilding
    case corrupt

    var title: String {
        switch self {
        case .ready: "会话搜索"
        case .rebuilding: "正在重建会话索引"
        case .corrupt: "会话搜索暂不可用"
        }
    }

    var notice: String? {
        switch self {
        case .ready: nil
        case .rebuilding: "正在恢复会话列表，请稍候。"
        case .corrupt: "会话索引损坏，已停止读取。请重新打开后重试。"
        }
    }
}

/// Main-actor search consumer.  Query work is cancellable and tagged with an
/// epoch; a result from an older query is never allowed to select a row.
@MainActor
@Observable
final class SessionSearchModel {
    private let chat: ChatStore

    static let resultLimit = 100
    var reachedResultLimit: Bool { results.count >= Self.resultLimit }

    private(set) var query = ""
    private(set) var results: [SessionSearchResult] = []
    private(set) var state: SessionSearchState = .ready
    private(set) var selectedResultID: String?
    /// 后台重搜进行中：旧结果仍显示，但暂不可点（点了也无法对上新结果），界面置灰并提示。
    private(set) var isUpdating = false

    private var searchEpoch: UInt64 = 0
    private var pendingSearch: Task<Void, Never>?

    init(chat: ChatStore) {
        self.chat = chat
    }

    func updateQuery(_ value: String) {
        query = value
        chat.searchText = value
        searchEpoch &+= 1
        let epoch = searchEpoch
        pendingSearch?.cancel()
        selectedResultID = nil
        isUpdating = false
        results = []

        guard state == .ready, !Self.normalized(value).isEmpty else { return }
        pendingSearch = Task { @MainActor [weak self] in
            // 输入防抖：连续输入时只检索最后一次。
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled,
                  let self,
                  self.searchEpoch == epoch,
                  self.query == value,
                  self.state == .ready else { return }
            let found = await self.searchInBackground(value)
            guard !Task.isCancelled, self.searchEpoch == epoch else { return }
            self.results = found.map { $0.with(searchEpoch: epoch) }
        }
    }

    static let debounce: Duration = .milliseconds(200)

    /// 主线程只取会话快照；检索在后台完成，结果回主线程。
    private func searchInBackground(_ value: String) async -> [SessionSearchResult] {
        let snapshot = chat.sessionSearchSnapshot()
        let limit = Self.resultLimit
        return await Task.detached(priority: .userInitiated) {
            ChatStore.searchMessageResults(in: snapshot, query: value, limit: limit)
        }.value
    }

    /// 会话列表变化后的后台重搜：保留旧结果直到新结果回来，不阻塞主线程。
    func refreshInBackground() {
        pendingSearch?.cancel()
        searchEpoch &+= 1
        selectedResultID = nil
        isUpdating = false
        guard state == .ready else {
            results = []
            return
        }
        let value = Self.normalized(query)
        guard !value.isEmpty else {
            results = []
            return
        }
        let epoch = searchEpoch
        isUpdating = !results.isEmpty
        pendingSearch = Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await self.searchInBackground(value)
            guard !Task.isCancelled, self.searchEpoch == epoch else { return }
            self.results = found.map { $0.with(searchEpoch: epoch) }
            self.isUpdating = false
        }
    }

    /// Rebuild synchronously after a ChatStore lifecycle mutation so the
    /// current query reflects the latest session revision before the next tap.
    func refresh() {
        pendingSearch?.cancel()
        searchEpoch &+= 1
        selectedResultID = nil
        isUpdating = false
        guard state == .ready else {
            results = []
            return
        }
        let value = Self.normalized(query)
        guard !value.isEmpty else {
            results = []
            return
        }
        let epoch = searchEpoch
        results = chat.searchMessageResults(query: value, limit: Self.resultLimit)
            .map { $0.with(searchEpoch: epoch) }
    }

    func clear() {
        updateQuery("")
    }

    @discardableResult
    func select(_ result: SessionSearchResult) -> Bool {
        guard state == .ready,
              result.searchEpoch == searchEpoch,
              results.contains(where: { $0.id == result.id && $0.searchEpoch == searchEpoch })
        else { return false }
        guard chat.openSearchResult(result) else {
            selectedResultID = nil
            return false
        }
        selectedResultID = result.id
        return true
    }

    func beginRebuilding() {
        pendingSearch?.cancel()
        state = .rebuilding
        searchEpoch &+= 1
        isUpdating = false
        results = []
        selectedResultID = nil
    }

    func finishRebuilding() {
        state = .ready
        refresh()
    }

    func markCorrupt() {
        pendingSearch?.cancel()
        state = .corrupt
        searchEpoch &+= 1
        isUpdating = false
        results = []
        selectedResultID = nil
    }

    func reopen() {
        guard state != .rebuilding else { return }
        state = .ready
        refresh()
    }

    private static func normalized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Reusable production input used by the sidebar and direct consumer surface.
struct SessionSearchInput: View {
    let model: SessionSearchModel
    @Environment(\.themeTokens) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            MinisIconView(.search, size: 14, accessibilityLabel: "搜索")
            TextField(
                "搜索消息…",
                text: Binding(
                    get: { model.query },
                    set: { model.updateQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($focused)
            .accessibilityIdentifier("session.search.input")
            if !model.query.isEmpty {
                Button {
                    model.clear()
                    focused = true
                } label: {
                    MinisIconView(.close, size: 14, accessibilityLabel: "清空")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空消息搜索")
                .accessibilityIdentifier("session.search.clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((theme?.stroke.opacity(0.5)) ?? Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        )
    }
}

struct SessionSearchResultRow: View {
    @Environment(\.themeTokens) private var theme
    let result: SessionSearchResult
    let isSelected: Bool
    let onSelect: () -> Void
    /// 后台正在更新结果：整行置灰、不可点。
    var isUpdating = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if result.isArchived {
                        Text("已归档")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(result.snippet)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .opacity(isUpdating ? 0.5 : 1)
        .accessibilityIdentifier("session.search.result.\(result.id)")
        .accessibilityLabel(result.title)
        .accessibilityValue(result.snippet)
        .accessibilityHint("定位到命中的确切消息")
    }
}

/// Standalone consumer surface used by direct UI consumers and future sidebar
/// compositions. The SessionSidebarView embeds the same model and row type so
/// its existing grouping and title/date filtering remain available.
struct SessionSearchView: View {
    let model: SessionSearchModel

    init(model: SessionSearchModel) {
        self.model = model
    }

    init(chat: ChatStore) {
        self.init(model: SessionSearchModel(chat: chat))
    }

    var body: some View {
        VStack(spacing: 6) {
            SessionSearchInput(model: model)
            switch model.state {
            case .ready:
                if model.results.isEmpty {
                    Text(model.query.isEmpty ? "输入关键词搜索消息" : "无匹配消息")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    LazyVStack(spacing: 3) {
                        if model.isUpdating {
                            Text("正在更新结果…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("session-search.updating")
                        }
                        if model.reachedResultLimit {
                            Text("仅显示前\(SessionSearchModel.resultLimit)条匹配消息，请缩小关键词。")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("session-search.result-limit")
                        }
                        ForEach(model.results) { result in
                            SessionSearchResultRow(
                                result: result,
                                isSelected: model.selectedResultID == result.id,
                                onSelect: { _ = model.select(result) },
                                isUpdating: model.isUpdating
                            )
                        }
                    }
                }
            case .rebuilding, .corrupt:
                VStack(spacing: 6) {
                    Text(model.state.title)
                        .font(.system(size: 11, weight: .medium))
                    if let notice = model.state.notice {
                        Text(notice)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if model.state == .corrupt {
                        Button("重新打开") { model.reopen() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("session.search.reopen")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
