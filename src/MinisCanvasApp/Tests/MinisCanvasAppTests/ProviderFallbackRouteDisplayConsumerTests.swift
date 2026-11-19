import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Provider fallback route display consumer")
@MainActor
struct ProviderFallbackRouteDisplayConsumerTests {
    @Test("fallback route status remains observable while transcript AX identity stays stable")
    func fallbackRouteStatusDoesNotReplaceTranscriptIdentifier() {
        let fallback = ChatMessageUI(
            role: .assistant,
            content: "\(ChatStore.fallbackRouteProjectionPrefix) · synthetic route"
        )
        let ordinary = ChatMessageUI(role: .assistant, content: "ordinary reply")
        let user = ChatMessageUI(
            role: .user,
            content: ChatStore.fallbackRouteProjectionPrefix
        )

        #expect(ChatTranscriptAXContract.identifier == "chat.transcript")
        #expect(ChatTranscriptAXContract.fallbackRouteStatus(in: [ordinary]) == nil)
        #expect(ChatTranscriptAXContract.fallbackRouteStatus(in: [user]) == nil)
        #expect(ChatTranscriptAXContract.fallbackRouteStatus(in: [fallback]) == "回退路由状态已显示")
        #expect(ChatTranscriptAXContract.identifier == "chat.transcript")
    }

    @Test("primary failure to backup stream projects once and survives SessionStore restart")
    func primaryFailureToBackupStreamProjectsOnceAndSurvivesRestart() async throws {
        let observations = RouteDisplayObservationBox()
        let primary = DisplayRouteProvider(
            name: "primary-display",
            modelID: "primary-model",
            streamError: LLMError.httpStatus(
                code: 404,
                detail: "raw-primary /private/tmp/body"
            )
        )
        let backup = DisplayRouteProvider(
            name: "backup-display",
            modelID: "backup-model",
            chunks: [.started, .text("backup response"), .finished(stopReason: "stop")]
        )
        let (chat, store, directory) = try makeChat(
            primary: primary,
            backup: backup,
            observations: observations
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = try #require(chat.activeSessionID)
        let priorMessages = chat.messages.map { (id: $0.id, content: $0.content) }
        let priorIDs = Set(priorMessages.map { $0.id })
        let priorPersistedMessages = chat.messages
            .filter { $0.role != .system }
            .map { (role: $0.role.rawValue, content: $0.content) }

        chat.draftText = "fallback display"
        chat.submitComposer()
        let executionIdentity = try #require(
            chat.activeExecutionIdentity(for: sessionID)
        )
        try await waitUntilStopped(chat)

        #expect(primary.streamCount == 1)
        #expect(backup.streamCount == 1)
        #expect(chat.messages.filter {
            $0.role == .user && !priorIDs.contains($0.id)
        }.count == 1)
        let assistants = chat.messages.filter {
            $0.role == .assistant && !priorIDs.contains($0.id)
        }
        #expect(assistants.count == 1)
        let assistant = try #require(assistants.first)
        for prior in priorMessages {
            #expect(chat.messages.first(where: { $0.id == prior.id })?.content == prior.content)
        }
        #expect(assistant.content.contains("backup response"))
        #expect(assistant.content.contains(ChatStore.fallbackRouteProjectionPrefix))
        #expect(assistant.content.contains("原服务商：`primary-display`"))
        #expect(assistant.content.contains("失败原因：模型或接口不存在 HTTP 404"))
        #expect(assistant.content.contains("最终实际使用的服务商：`backup-display`"))
        #expect(!assistant.content.contains("raw-primary"))
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
        #expect(chat.terminalReceipt(for: executionIdentity)?.outcome == .succeeded)

        if let observation = observations.value {
            #expect(
                chat.ingestProviderRuntimeObservation(
                    observation,
                    executionIdentity: executionIdentity
                ) == false
            )
        } else {
            Issue.record("route observation was not delivered")
        }
        #expect(chat.markExecutionSucceeded(
            sessionID: sessionID,
            executionIdentity: executionIdentity
        ) == false)

        let persisted = try #require(store.loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.count == priorPersistedMessages.count + 2)
        for (message, prior) in zip(persisted.messages, priorPersistedMessages) {
            #expect(message.role.rawValue == prior.role)
            #expect(message.content == prior.content)
        }
        let persistedTurn = Array(persisted.messages.dropFirst(priorPersistedMessages.count))
        #expect(persistedTurn.map { $0.role.rawValue } == ["user", "assistant"])
        #expect(persistedTurn.last?.content == assistant.content)

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(SessionStore(directory: directory)))
        // Core LLMMessage has no UI UUID; the durable transcript preserves order and content.
        #expect(reopened.messages.count == priorPersistedMessages.count + 2)
        for (message, prior) in zip(reopened.messages, priorPersistedMessages) {
            #expect(message.role.rawValue == prior.role)
            #expect(message.content == prior.content)
        }
        let reopenedTurn = Array(reopened.messages.dropFirst(priorPersistedMessages.count))
        #expect(reopenedTurn.map { $0.role.rawValue } == ["user", "assistant"])
        #expect(reopenedTurn.last?.content == assistant.content)
    }

    @Test("all provider failure projects safe attempts without a served route")
    func allProviderFailureProjectsSafeAttemptsWithoutServedRoute() async throws {
        let observations = RouteDisplayObservationBox()
        let primary = DisplayRouteProvider(
            name: "primary-failure",
            modelID: "primary-model",
            streamError: LLMError.providerError(message: "raw-primary token=secret")
        )
        let backup = DisplayRouteProvider(
            name: "backup-failure",
            modelID: "backup-model",
            streamError: LLMError.providerError(message: "raw-backup /Users/private/body")
        )
        let (chat, _, directory) = try makeChat(
            primary: primary,
            backup: backup,
            observations: observations
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = try #require(chat.activeSessionID)
        let priorMessages = chat.messages.map { (id: $0.id, content: $0.content) }
        let priorIDs = Set(priorMessages.map { $0.id })

        chat.draftText = "all providers fail"
        chat.submitComposer()
        let executionIdentity = try #require(
            chat.activeExecutionIdentity(for: sessionID)
        )
        try await waitUntilStopped(chat)

        let assistants = chat.messages.filter {
            $0.role == .assistant && !priorIDs.contains($0.id)
        }
        #expect(chat.messages.filter {
            $0.role == .user && !priorIDs.contains($0.id)
        }.count == 1)
        #expect(assistants.count == 1)
        let assistant = try #require(assistants.first)
        for prior in priorMessages {
            #expect(chat.messages.first(where: { $0.id == prior.id })?.content == prior.content)
        }
        #expect(assistant.content.contains("所有服务商均失败"))
        #expect(assistant.content.contains("回退路由失败"))
        #expect(assistant.content.contains("失败原因：未分类失败"))
        #expect(assistant.content.contains("本次未提供结果"))
        #expect(!assistant.content.contains("最终实际使用的服务商"))
        #expect(!assistant.content.contains("raw-primary"))
        #expect(!assistant.content.contains("raw-backup"))
        #expect(!assistant.content.contains("token=secret"))
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
        #expect(chat.terminalReceipt(for: executionIdentity)?.outcome == .failed)
        #expect(chat.markExecutionFailed(
            sessionID: sessionID,
            executionIdentity: executionIdentity,
            reason: "late duplicate"
        ) == false)
        #expect(chat.markExecutionSucceeded(
            sessionID: sessionID,
            executionIdentity: executionIdentity
        ) == false)

        if let observation = observations.value {
            #expect(
                chat.ingestProviderRuntimeObservation(
                    observation,
                    executionIdentity: executionIdentity
                ) == false
            )
        } else {
            Issue.record("terminal route observation was not delivered")
        }
    }

    @Test("cancellation retires route projection and rejects late observation")
    func cancellationRetiresRouteProjectionAndRejectsLateObservation() async throws {
        let observations = RouteDisplayObservationBox()
        let primary = DisplayRouteProvider(
            name: "primary-cancel",
            modelID: "primary-model",
            streamError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = DisplayRouteProvider(
            name: "backup-cancel",
            modelID: "backup-model",
            blocksAfterPartial: true
        )
        let (chat, _, directory) = try makeChat(
            primary: primary,
            backup: backup,
            observations: observations
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = try #require(chat.activeSessionID)

        chat.draftText = "cancel fallback"
        chat.submitComposer()
        let executionIdentity = try #require(
            chat.activeExecutionIdentity(for: sessionID)
        )
        for _ in 0..<200 {
            if chat.messages.last?.content.contains("partial") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.stopStreaming()
        try await waitUntilStopped(chat)

        let assistant = try #require(chat.messages.last(where: { $0.role == .assistant }))
        #expect(assistant.content.contains("partial"))
        #expect(assistant.wasInterrupted)
        #expect(ChatTranscriptFormatter.attributedString([assistant]).string.contains("已中断"))
        #expect(ChatTranscriptFormatter.accessibilityText([assistant]).contains("已中断"))
        #expect(!assistant.content.contains("已中断"))
        #expect(!assistant.content.contains(ChatStore.fallbackRouteProjectionPrefix))
        #expect(chat.terminalReceipt(for: executionIdentity)?.outcome == .cancelled)
        if let observation = observations.value {
            #expect(
                chat.ingestProviderRuntimeObservation(
                    observation,
                    executionIdentity: executionIdentity
                ) == false
            )
        } else {
            Issue.record("served route observation was not delivered")
        }
    }

    private func makeChat(
        primary: any LLMProvider,
        backup: any LLMProvider,
        observations: RouteDisplayObservationBox
    ) throws -> (ChatStore, SessionStore, URL) {
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "provider-route-display-revision",
            grantEpoch: "provider-route-display-epoch",
            leaseID: "provider-route-display-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l3
        )
        chat.configureComposerPolicy(facts)
        chat.streamingProviderOverride = primary
        chat.agentEngine = FallbackChatEngine(composerPolicyFacts: facts)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-route-display-\(UUID().uuidString)",
                isDirectory: true
            )
        let sessionStore = SessionStore(directory: directory)
        guard chat.attachPersistence(sessionStore) else {
            throw DisplayRouteFixtureError.persistenceUnavailable
        }
        let skillStore = SkillStore(
            skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)
        )

        chat.turnRuntimeSnapshotFactory = { [weak chat] turn, _ in
            let snapshot = try! ProviderRuntimeSnapshot(
                providerID: primary.name,
                modelID: primary.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:primary-display",
                fallbackProvenance: [
                    ProviderRuntimeFallback(
                        providerID: backup.name,
                        modelID: backup.model.id,
                        readinessEvidenceID: "display-backup-readiness",
                        applyReceiptID: "provider-readiness-apply:backup-display"
                    )
                ]
            )
            let route = try! ProviderRuntimeRoute(
                snapshot: snapshot,
                primary: primary,
                fallbacks: [backup],
                observationSink: { [weak chat] observation in
                    observations.record(observation)
                    await MainActor.run {
                        guard let chat,
                              let sessionID = UUID(uuidString: turn.sessionID),
                              let identity = chat.activeExecutionIdentity(for: sessionID)
                        else { return }
                        _ = chat.ingestProviderRuntimeObservation(
                            observation,
                            executionIdentity: identity
                        )
                    }
                }
            )
            return ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil,
                providerRuntimeRoute: route,
                requiresProviderRuntimeRoute: true
            )
        }
        return (chat, sessionStore, directory)
    }

    private func waitUntilStopped(_ chat: ChatStore) async throws {
        for _ in 0..<300 {
            if !chat.isStreaming { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("ChatStore stream did not settle")
    }
}

private enum DisplayRouteFixtureError: Error {
    case persistenceUnavailable
}

private final class RouteDisplayObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ProviderRuntimeRouteObservation?

    var value: ProviderRuntimeRouteObservation? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ observation: ProviderRuntimeRouteObservation) {
        lock.lock()
        storedValue = observation
        lock.unlock()
    }
}

private final class DisplayRouteProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = []
    let responseText: String
    let streamError: Error?
    let chunks: [LLMStreamChunk]
    let blocksAfterPartial: Bool
    private let lock = NSLock()
    private(set) var streamCount = 0

    init(
        name: String,
        modelID: String,
        responseText: String = "",
        streamError: Error? = nil,
        chunks: [LLMStreamChunk] = [],
        blocksAfterPartial: Bool = false
    ) {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.responseText = responseText
        self.streamError = streamError
        self.chunks = chunks
        self.blocksAfterPartial = blocksAfterPartial
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: responseText, stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock {
            streamCount += 1
        }
        if let streamError { throw streamError }
        return AsyncThrowingStream { continuation in
            if self.blocksAfterPartial {
                let task = Task {
                    continuation.yield(.started)
                    continuation.yield(.text("partial"))
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(20))
                        } catch {
                            break
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
