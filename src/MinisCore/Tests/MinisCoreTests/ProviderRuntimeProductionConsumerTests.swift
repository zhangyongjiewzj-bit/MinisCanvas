import Foundation
import Testing
@testable import MinisCore

@Suite("Provider runtime production consumer")
struct ProviderRuntimeProductionConsumerTests {
    @Test("production chat send carries the frozen route and records served identity")
    @MainActor
    func productionSendUsesFrozenRouteAndObservation() async throws {
        let fixture = try makeFixture(
            primaryError: LLMError.invalidAPIKey(),
            fallbackError: nil
        )
        let runtime = try fixture.makeRuntime()
        let context = try await runtime.makeContext(sessionID: fixture.session.id)

        let result = try await runtime.sendProduction(
            fixture.makeRequest(text: "hello", context: context)
        )

        #expect(result.messages.last?.content == "backup-response")
        #expect(fixture.primary.sendCalls == 1)
        #expect(fixture.fallback.sendCalls == 1)

        let observation = try #require(fixture.probe.value)
        #expect(observation.routeReceiptID == fixture.snapshot.routeReceiptID)
        #expect(observation.servedProviderID == "backup")
        #expect(observation.servedModelID == "backup-model")
        #expect(observation.attemptedProviderIDs == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.status == .served)
        #expect(observation.attempts[0].succeeded == false)
        #expect(observation.attempts[1].succeeded)
    }

    @Test("production chat send preserves terminal failure and every ordered attempt")
    @MainActor
    func productionSendRecordsTerminalFailure() async throws {
        let fixture = try makeFixture(
            primaryError: LLMError.invalidAPIKey(),
            fallbackError: LLMError.providerError(message: "backup unavailable")
        )
        let runtime = try fixture.makeRuntime()
        let context = try await runtime.makeContext(sessionID: fixture.session.id)

        await #expect(throws: FallbackRouterError.self) {
            try await runtime.sendProduction(
                fixture.makeRequest(text: "hello", context: context)
            )
        }

        let observation = try #require(fixture.probe.value)
        #expect(observation.servedProviderID == nil)
        #expect(observation.servedModelID == nil)
        #expect(observation.attemptedProviderIDs == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.status == .terminalFailure)
        #expect(observation.isTerminalFailure)
        #expect(observation.attempts.allSatisfy { !$0.failureDescription.isEmpty })
    }

    @Test("production chat send fails closed when no route snapshot is supplied")
    func productionSendFailsClosedWithoutSnapshot() async throws {
        let fixture = try makeFixture(primaryError: nil, fallbackError: nil)
        let runtime = ChatSessionRuntime(
            sessionStore: fixture.sessions,
            memoryStore: fixture.memory,
            skillStore: fixture.skills,
            soulStore: fixture.souls,
            provider: fixture.primary,
            toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root)
        )
        let context = try await runtime.makeContext(sessionID: fixture.session.id)

        await #expect(
            throws: ChatSessionRuntimeError.providerRuntimeSnapshotMissing
        ) {
            try await runtime.sendProduction(
                ChatTurnRequest(text: "must not send", context: context)
            )
        }
        #expect(fixture.primary.sendCalls == 0)
        #expect(fixture.fallback.sendCalls == 0)
        #expect(fixture.probe.value == nil)
    }

    @Test("retry/recovery rejects changed live provider configuration")
    @MainActor
    func retryRecoveryRejectsChangedLiveProviderConfiguration() async throws {
        let fixture = try makeFixture(
            primaryError: LLMError.providerError(message: "primary unavailable"),
            fallbackError: nil
        )
        let runtime = try fixture.makeRuntime()
        let context = try await runtime.makeContext(sessionID: fixture.session.id)
        let request = fixture.makeRequest(text: "retry", context: context)

        // The route is frozen from the snapshot at construction time. A
        // later live-provider mutation must not be adopted by recovery.
        fixture.fallback.model = LLMModel(
            id: "changed-live-model",
            displayName: "changed-live-model",
            provider: "backup"
        )

        do {
            _ = try await runtime.sendProduction(request)
            Issue.record("recovery silently adopted changed live provider config")
        } catch let error as ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected runtime error: \(error)")
                return
            }
            #expect(envelope.providerID == fixture.snapshot.providerID)
            #expect(envelope.modelID == fixture.snapshot.modelID)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(fixture.primary.sendCalls == 1)
        #expect(fixture.fallback.sendCalls == 0)
        #expect(fixture.probe.value?.status == .terminalFailure)
    }

    @Test("production chat rejects same-id model revision drift")
    @MainActor
    func productionChatRejectsSameIDModelRevisionDrift() async throws {
        let fixture = try makeFixture(primaryError: nil, fallbackError: nil)
        let runtime = try fixture.makeRuntime()
        let context = try await runtime.makeContext(sessionID: fixture.session.id)

        // A model revision is more than its wire ID: capability metadata is
        // part of the frozen route contract and must not change mid-turn.
        fixture.primary.model = LLMModel(
            id: "primary-model",
            displayName: "primary-model",
            provider: "primary",
            contextWindow: 8_192
        )

        await #expect(throws: ChatSessionRuntimeError.self) {
            try await runtime.sendProduction(
                fixture.makeRequest(text: "must reject revision drift", context: context)
            )
        }
        #expect(fixture.primary.sendCalls == 0)
        #expect(fixture.fallback.sendCalls == 0)
    }

    private func makeFixture(
        primaryError: Error?,
        fallbackError: Error?
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderRuntimeProductionConsumer-\(UUID().uuidString)")
        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(
            id: UUID().uuidString,
            projectID: "project-a"
        )
        let memory = MemoryStore(directory: root)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root)
        let primary = ProductionConsumerProvider(
            name: "primary",
            modelID: "primary-model",
            responseText: "primary-response",
            error: primaryError
        )
        let fallback = ProductionConsumerProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "backup-response",
            error: fallbackError
        )
        let probe = ProductionConsumerObservationProbe()
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "mock-primary",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "mock-backup",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )
        return Fixture(
            root: root,
            session: session,
            sessions: sessions,
            memory: memory,
            skills: skills,
            souls: souls,
            primary: primary,
            fallback: fallback,
            snapshot: snapshot,
            probe: probe
        )
    }

    private struct Fixture {
        let root: URL
        let session: ChatSession
        let sessions: SessionStore
        let memory: MemoryStore
        let skills: SkillStore
        let souls: SoulStore
        let primary: ProductionConsumerProvider
        let fallback: ProductionConsumerProvider
        let snapshot: ProviderRuntimeSnapshot
        let probe: ProductionConsumerObservationProbe

        @MainActor
        func makeRuntime() throws -> ChatSessionRuntime {
            try ChatSessionRuntime(
                sessionStore: sessions,
                memoryStore: memory,
                skillStore: skills,
                soulStore: souls,
                provider: primary,
                toolExecutor: BuiltinToolExecutor(allowedRoot: root),
                providerRuntimeSnapshot: snapshot,
                fallbackProviders: [fallback],
                providerRuntimeObservationSink: { observation in
                    probe.record(observation)
                },
                toolCatalog: AgentToolCatalog.makeTools(),
                toolExecutionFactLedger: try ToolExecutionFactLedger(
                    persistenceURL: root.appendingPathComponent(
                        "tool-execution-facts-v4.json"
                    )
                )
            )
        }

        func makeRequest(
            text: String,
            context: ChatRuntimeContext
        ) -> ChatTurnRequest {
            ChatTurnRequest(
                text: text,
                context: context,
                policySnapshotID: "provider-runtime-policy",
                grantSnapshotID: "provider-runtime-grant",
                executionIdentity: AgentExecutionIdentity(
                    turn: AgentTurnIdentity(
                        sessionID: context.sessionID,
                        turnID: 1,
                        messageID: "provider-runtime-message"
                    ),
                    operationID: "provider-runtime-send",
                    attempt: 1
                )
            )
        }
    }
}

private final class ProductionConsumerProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let responseText: String
    let error: Error?
    private(set) var sendCalls = 0

    init(name: String, modelID: String, responseText: String, error: Error?) {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.responseText = responseText
        self.error = error
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCalls += 1
        if let error {
            throw error
        }
        return LLMResponse(text: responseText, stopReason: "stop", usage: nil)
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
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private final class ProductionConsumerObservationProbe: @unchecked Sendable {
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
