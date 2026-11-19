import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class HistoryProjectionGate3072: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private var wasMain = false
    private var didTimeOut = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { didEnter } }
    var ranOnMain: Bool { lock.withLock { wasMain } }
    var timedOut: Bool { lock.withLock { didTimeOut } }

    func project(_ history: [ChatMessageUI]) throws -> [LLMMessage] {
        let main = Thread.isMainThread
        lock.withLock { wasMain = main; didEnter = true }
        // A regression must fail without blocking the test's MainActor itself.
        if !main, release.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { didTimeOut = true }
        }
        return try ChatHistoryPreprocessor.project(history)
    }
}

private actor HistoryProviderRecorder3072 {
    private(set) var requests: [[LLMMessage]] = []
    func record(_ messages: [LLMMessage]) { requests.append(messages) }
}

private struct HistoryProvider3072: LLMProvider {
    let name = "history3072"
    var model = LLMModel(id: "history3072", displayName: "History", provider: "offline", modalityOverride: .fullMultimodalInput)
    let recorder: HistoryProviderRecorder3072
    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await recorder.record(messages)
        return LLMResponse(text: "history3072-complete", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await recorder.record(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("history3072-complete"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@Suite("PERF06 actual engine history preparation 3072")
@MainActor
struct ChatHistoryPreprocessing3072Tests {
    private func history() -> [ChatMessageUI] {
        [ChatMessageUI(role: .assistant, content: "prior3072"),
         ChatMessageUI(role: .user, content: "audio3072", attachments: [
            ChatAttachment(kind: .audio, fileName: "synthetic.wav", fileType: .audio,
                           data: ComposerMediaFixtures589.wav)
         ])]
    }

    private func waitForEntry(_ gate: HistoryProjectionGate3072) async throws {
        for _ in 0..<5000 {
            if gate.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("actual history worker did not enter")
        throw CancellationError()
    }

    @Test func blockingActualFallbackProjectionAllowsMainActorAndPreservesProviderPayload() async throws {
        let gate = HistoryProjectionGate3072()
        defer { gate.release.signal() }
        let recorder = HistoryProviderRecorder3072()
        let provider = HistoryProvider3072(recorder: recorder)
        let input = history()
        let engine = FallbackChatEngine(historyPreprocessor: .init(projection: { try gate.project($0) }))
        let turn = Task {
            let stream = try await engine.streamReply(provider: provider, history: input,
                systemPrompt: "offline", maxTokens: 4096)
            var text = ""
            for try await event in stream {
                if case .textDelta(let delta) = event { text += delta }
            }
            return text
        }
        try await waitForEntry(gate)
        var inputPulse = 0
        let pulse = Task { @MainActor in inputPulse += 1 }
        await pulse.value
        #expect(inputPulse == 1)
        #expect(!gate.ranOnMain && !gate.timedOut)
        #expect(await recorder.requests.isEmpty, "Provider cannot run before history preparation completes")
        gate.release.signal()
        #expect(try await turn.value == "history3072-complete")
        let requests = await recorder.requests
        #expect(requests == [input.map { $0.asLLMMessage() }])
        #expect(requests.first?.last?.audios.first?.base64Data == ComposerMediaFixtures589.wav.base64EncodedString())
    }

    @Test func cancelledPreparationCannotCallProviderAndNextTurnStillWorks() async throws {
        let gate = HistoryProjectionGate3072()
        defer { gate.release.signal() }
        let recorder = HistoryProviderRecorder3072()
        let provider = HistoryProvider3072(recorder: recorder)
        let engine = FallbackChatEngine(historyPreprocessor: .init(projection: { try gate.project($0) }))
        let input = history()
        let turn = Task {
            let stream = try await engine.streamReply(provider: provider, history: input,
                systemPrompt: "offline", maxTokens: 4096)
            for try await _ in stream {}
            try Task.checkCancellation()
        }
        try await waitForEntry(gate)
        turn.cancel()
        gate.release.signal()
        do {
            _ = try await turn.value
            Issue.record("cancelled stream consumption completed without cancellation")
        } catch is CancellationError {} catch {
            Issue.record("unexpected cancellation error: \(type(of: error))")
        }
        #expect(await recorder.requests.isEmpty)
        #expect(!gate.ranOnMain && !gate.timedOut)
        let stream = try await FallbackChatEngine().streamReply(provider: provider,
            history: input, systemPrompt: "offline", maxTokens: 4096)
        for try await _ in stream {}
        #expect(await recorder.requests == [input.map { $0.asLLMMessage() }])
    }

    @Test func agentLoopWithoutCanonicalSessionPreservesActualProjectedHistory() async throws {
        let recorder = HistoryProviderRecorder3072()
        let input = history()
        let engine = AgentLoopChatEngine()
        #expect(engine.chatRuntimeDependencies == nil)
        let stream = try await engine.streamReply(
            provider: HistoryProvider3072(recorder: recorder), history: input,
            systemPrompt: "offline", maxTokens: 4096, conversationID: "history3072-\(UUID().uuidString)",
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: 1)
        var text = ""
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
        }
        #expect(text == "history3072-complete")
        #expect(await recorder.requests == [input.map { $0.asLLMMessage() }])
    }

    @Test func providerHistoryDropsTheDisplayedErrorLineButKeepsModelText() throws {
        let kept = ChatMessageUI(role: .assistant, content: "已完成前半部分\n\n**错误**（服务商）: 网络请求未完成")
        let errorOnly = ChatMessageUI(role: .assistant, content: "\n\n**错误**：额度不足")
        let user = ChatMessageUI(role: .user, content: "你好")
        let messages = try ChatHistoryPreprocessor.projectProviderHistory([user, errorOnly, kept])
        #expect(messages.count == 2)
        #expect(messages.last?.content == "已完成前半部分")
        // 画面上的错误行不受影响。
        #expect(kept.content.contains("**错误**"))
    }

    @Test func markdownExportUsesDisplayContentAndSkipsWelcome() {
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let welcome = ChatMessageUI(role: .assistant, content: ChatStore.welcomeText)
        let markdown = SessionMarkdownExport.markdown(
            title: "导出", messages: [welcome, ChatMessageUI(role: .user, content: "你好")], redactor: redactor)
        #expect(!markdown.contains(ChatStore.welcomeText))
        #expect(markdown.contains("你好"))
    }
}
