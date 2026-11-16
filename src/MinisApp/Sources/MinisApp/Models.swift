import Foundation
import SwiftUI
import MinisCore

// MARK: - UI Message Model

/// A chat message as rendered by the UI.
struct ChatMessageUI: Identifiable, Equatable {
    let id: UUID
    let role: LLMMessage.Role
    var content: String
    var isStreaming: Bool
    let timestamp: Date

    init(id: UUID = UUID(), role: LLMMessage.Role, content: String, isStreaming: Bool = false, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }
}

// MARK: - Session

/// A chat session (conversation). `@Observable` so nested mutations
/// (message append / streaming content) drive UI updates.
@MainActor
@Observable
final class ChatSession: Identifiable {
    let id: UUID
    var title: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessageUI]
    /// Model bound to this session (nil = provider default).
    var model: LLMModel?

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessageUI] = [],
        model: LLMModel? = nil
    ) {
        self.id = id
        self.title = title
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.model = model
    }

    var lastMessagePreview: String {
        messages.last?.content.replacingOccurrences(of: "\n", with: " ") ?? "空会话"
    }
}

// MARK: - App State

@MainActor
@Observable
final class AppState {
    private struct StreamingTurn {
        let id: UUID
        let assistantMessageID: UUID
    }

    /// nil provider type = Mock (UI 演示，先跑通管线)
    var selectedProviderType: ProviderType?
    var selectedModel: LLMModel?
    var sessions: [ChatSession] = []
    var selectedSessionID: UUID?
    var draftText: String = ""
    var searchText: String = ""
    var palettePresented: Bool = false
    var settingsPresented: Bool = false
    /// The selected session's active stream, if any. Stream ownership is
    /// tracked per session so an older session cannot block a new one.
    var streamingSessionID: UUID? {
        guard let selectedSessionID, streamingTurns[selectedSessionID] != nil else {
            return nil
        }
        return selectedSessionID
    }
    var scrollTargetID: UUID?
    /// 会话中部栏（消息列表）是否可见
    var showMessageList: Bool = true

    private var streamingTurns: [UUID: StreamingTurn] = [:]
    private var streamingTasks: [UUID: Task<Void, Never>] = [:]
    private let providerOverride: (any LLMProvider)?

    init(provider: (any LLMProvider)? = nil) {
        providerOverride = provider
        let first = ChatSession()
        sessions = [first]
        selectedSessionID = first.id
    }

    // MARK: - Selection helpers

    var selectedSession: ChatSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    var pinnedSessions: [ChatSession] {
        sessions.filter { $0.isPinned }
    }

    var unpinnedSessions: [ChatSession] {
        sessions.filter { !$0.isPinned }
    }

    func session(matching query: String) -> [ChatSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(q) || $0.lastMessagePreview.lowercased().contains(q)
        }
    }

    // MARK: - Providers

    /// Provider types registered in MinisCore's factory (built-ins: openAI/anthropic/openRouter/openAIResponses/local).
    var availableProviders: [ProviderType] {
        ProviderFactory.shared.registeredTypes.filter { !$0.isUnsupported }
    }

    var providerLabel: String {
        guard let type = selectedProviderType else { return "Mock 演示" }
        if let model = selectedModel { return "\(type.displayName) · \(model.displayName)" }
        return type.displayName
    }

    /// The active LLM provider: mock when no real type is selected, otherwise
    /// built from ProviderFactory (credential-free construction; network errors
    /// surface as message text until real credentials/env are configured).
    func activeProvider() throws -> any LLMProvider {
        if let providerOverride {
            return providerOverride
        }
        guard let type = selectedProviderType else {
            return MockProvider.shared
        }
        var config = ProviderConfig(label: type.displayName, providerType: type)
        if type == .local {
            config.customBaseURL = "http://127.0.0.1:11434"
        }
        var provider = try ProviderFactory.shared.makeProvider(for: config, requireCredentials: false)
        if let model = selectedModel {
            provider.model = model
        }
        return provider
    }

    // MARK: - Session actions

    func newSession() {
        let session = ChatSession()
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        draftText = ""
    }

    func deleteSession(_ session: ChatSession) {
        stopStreaming(for: session.id)
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
    }

    func togglePin(_ session: ChatSession) {
        session.isPinned.toggle()
        session.updatedAt = Date()
    }

    // MARK: - Send / stream

    func sendDraft() {
        guard let session = selectedSession else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, streamingTurns[session.id] == nil else { return }

        draftText = ""
        if session.title == "新会话" {
            session.title = String(text.prefix(24)) + (text.count > 24 ? "…" : "")
        }

        session.messages.append(ChatMessageUI(role: .user, content: text))
        let assistantIndex = session.messages.count
        session.messages.append(ChatMessageUI(role: .assistant, content: "", isStreaming: true))
        session.updatedAt = Date()
        let sessionID = session.id
        let turnID = UUID()
        let assistantMessageID = session.messages[assistantIndex].id
        streamingTurns[sessionID] = StreamingTurn(
            id: turnID,
            assistantMessageID: assistantMessageID
        )

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // 具体 Provider 类均为 @unchecked Sendable；用 nonisolated(unsafe)
                // 消除存在类型跨隔离区的发送检查。
                nonisolated(unsafe) let provider = try activeProvider()
                let history = session.messages.prefix(assistantIndex).map {
                    LLMMessage(role: $0.role, content: $0.content)
                }
                let stream = try await provider.streamMessage(
                    messages: history,
                    systemPrompt: Self.systemPrompt,
                    maxTokens: 4096,
                    temperature: 0.7
                )
                for try await chunk in stream {
                    guard !Task.isCancelled,
                          self.isCurrentTurn(
                            sessionID: sessionID,
                            turnID: turnID,
                            assistantMessageID: assistantMessageID
                          ) else {
                        break
                    }
                    switch chunk {
                    case .text(let t):
                        session.messages[assistantIndex].content += t
                    case .started, .usage:
                        break
                    case .finished:
                        self.finishStreaming(
                            sessionID: sessionID,
                            turnID: turnID,
                            assistantMessageID: assistantMessageID
                        )
                        return
                    }
                }
            } catch {
                if !Task.isCancelled,
                   self.isCurrentTurn(
                       sessionID: sessionID,
                       turnID: turnID,
                       assistantMessageID: assistantMessageID
                   ) {
                    session.messages[assistantIndex].content += "\n\n**错误**：\(error.localizedDescription)"
                }
            }
            self.finishStreaming(
                sessionID: sessionID,
                turnID: turnID,
                assistantMessageID: assistantMessageID
            )
        }
        streamingTasks[sessionID] = task
    }

    func stopStreaming() {
        guard let sessionID = selectedSessionID else { return }
        stopStreaming(for: sessionID)
    }

    private func stopStreaming(for sessionID: UUID) {
        guard let turn = streamingTurns.removeValue(forKey: sessionID) else { return }
        let task = streamingTasks.removeValue(forKey: sessionID)
        task?.cancel()

        guard let session = sessions.first(where: { $0.id == sessionID }),
              let index = session.messages.firstIndex(where: {
                  $0.id == turn.assistantMessageID
              }) else {
            return
        }
        session.messages[index].isStreaming = false
        session.updatedAt = Date()
    }

    private func isCurrentTurn(
        sessionID: UUID,
        turnID: UUID,
        assistantMessageID: UUID
    ) -> Bool {
        guard streamingTurns[sessionID]?.id == turnID,
              let session = sessions.first(where: { $0.id == sessionID }),
              session.messages.contains(where: {
                  $0.id == assistantMessageID && $0.role == .assistant
              }) else {
            return false
        }
        return true
    }

    private func finishStreaming(
        sessionID: UUID,
        turnID: UUID,
        assistantMessageID: UUID
    ) {
        guard streamingTurns[sessionID]?.id == turnID else { return }
        if let session = sessions.first(where: { $0.id == sessionID }),
           let index = session.messages.firstIndex(where: { $0.id == assistantMessageID }) {
            session.messages[index].isStreaming = false
            session.updatedAt = Date()
        }
        streamingTurns.removeValue(forKey: sessionID)
        streamingTasks.removeValue(forKey: sessionID)
    }

    static let systemPrompt = """
    你是 MinisCanvas 助手，运行在 macOS 原生应用里。回答简洁、准确，代码用 Markdown 代码块给出。
    """

    // MARK: - Commands

    func runCommand(_ command: PaletteCommand) {
        switch command.id {
        case "new":
            newSession()
        case "settings":
            settingsPresented = true
        case "canvas":
            break // 画布模块（A2 CanvasApp）后续接入
        case "toggleMessages":
            showMessageList.toggle()
        case "toggleMock":
            selectedProviderType = nil
            selectedModel = nil
        default:
            break
        }
        palettePresented = false
    }
}

// MARK: - Mock Provider (UI 管线演示)

/// Deterministic fake provider used until real backends are reachable.
/// Emits a canned Markdown reply word-by-word so streaming UI can be exercised.
final class MockProvider: LLMProvider, @unchecked Sendable {
    static let shared = MockProvider()

    var name: String { "Mock" }
    var model: LLMModel = LLMModel(id: "mock-echo", displayName: "Mock Echo", provider: "Mock")

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(
            text: Self.mockReply(for: messages.last?.content ?? ""),
            stopReason: "end_turn",
            usage: LLMUsage(inputTokens: 0, outputTokens: 0)
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let reply = Self.mockReply(for: messages.last?.content ?? "")
                continuation.yield(.started)
                for word in reply.split(separator: " ") {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(20))
                    continuation.yield(.text(String(word) + " "))
                }
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func mockReply(for userText: String) -> String {
        let topic = userText.isEmpty ? "MinisCanvas" : userText
        return """
        **已收到**：\(topic)

        这是 Mock Provider 的流式回复，用于验证 UI 管线（消息流式追加、Markdown 渲染、停止按钮）。

        - 三栏布局：会话侧栏 / 消息列表 / 聊天区
        - 命令面板：`Cmd+K`
        - 新建会话：`Cmd+N`

        代码示例：

        ```swift
        let provider = try ProviderFactory.shared.makeProvider(for: config)
        ```

        接入真实后端后，这条回复会被 Ollama / 云端模型的实际输出替代。
        """
    }
}
