import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Provider fallback route consumer")
@MainActor
struct ProviderFallbackRouteConsumerTests {
    @Test("primary failure serves backup with ordered terminal provenance")
    func primaryFailureServesBackupWithOrderedTerminalProvenance() async throws {
        let primary = CountingFallbackProvider(
            name: "primary",
            modelID: "primary-model",
            sendError: LLMError.invalidAPIKey()
        )
        let backup = CountingFallbackProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "backup response"
        )
        let probe = RouteObservationProbe()
        let route = try makeRoute(
            primary: primary,
            backup: backup,
            observationSink: probe.record
        )

        let result = try await route.sendMessage(
            messages: [LLMMessage(role: .user, content: "fallback")],
            systemPrompt: nil,
            maxTokens: 64,
            temperature: nil
        )

        let observation = try #require(probe.value)
        #expect(result.text == "backup response")
        #expect(primary.sendCount == 1)
        #expect(backup.sendCount == 1)
        #expect(observation.routeReceiptID == route.snapshot.routeReceiptID)
        #expect(observation.servedProviderID == "backup")
        #expect(observation.servedModelID == "backup-model")
        #expect(observation.attemptedProviderIDs == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary"])
        #expect(observation.fallbackEvents.map(\.attempt) == [1])
        #expect(observation.status == .served)
        #expect(observation.terminalErrorDescription == nil)
    }

    @Test("all provider failures preserve ordered terminal trail")
    func allProviderFailuresPreserveOrderedTerminalTrail() async throws {
        let primary = CountingFallbackProvider(
            name: "primary",
            modelID: "primary-model",
            sendError: LLMError.invalidAPIKey()
        )
        let backup = CountingFallbackProvider(
            name: "backup",
            modelID: "backup-model",
            sendError: LLMError.providerError(message: "backup unavailable")
        )
        let probe = RouteObservationProbe()
        let route = try makeRoute(
            primary: primary,
            backup: backup,
            observationSink: probe.record
        )

        do {
            _ = try await route.sendMessage(
                messages: [LLMMessage(role: .user, content: "all fail")],
                systemPrompt: nil,
                maxTokens: 64,
                temperature: nil
            )
            Issue.record("expected all providers to fail")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error else {
                Issue.record("unexpected fallback error: \(error)")
                return
            }
            #expect(events.map(\.providerID) == ["primary", "backup"])
            #expect(events.map(\.attempt) == [1, 2])
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let observation = try #require(probe.value)
        #expect(primary.sendCount == 1)
        #expect(backup.sendCount == 1)
        #expect(observation.servedProviderID == nil)
        #expect(observation.servedModelID == nil)
        #expect(observation.attemptedProviderIDs == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.attempts.allSatisfy { !$0.failureDescription.isEmpty })
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary", "backup"])
        #expect(observation.status == .terminalFailure)
        #expect(observation.terminalErrorDescription != nil)
    }

    @Test("cancellation does not invoke fallback or emit a fallback event")
    func cancellationDoesNotInvokeFallbackOrEmitFallbackEvent() async throws {
        let primary = CountingFallbackProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: CancellationError()
        )
        let backup = CountingFallbackProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "must not serve"
        )
        let probe = RouteObservationProbe()
        let route = try makeRoute(
            primary: primary,
            backup: backup,
            observationSink: probe.record
        )

        do {
            let stream = try await route.streamMessage(
                messages: [LLMMessage(role: .user, content: "cancel")],
                systemPrompt: nil,
                maxTokens: 64,
                temperature: nil
            )
            for try await _ in stream {}
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not fallbackable.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }

        let observation = try #require(probe.value)
        #expect(primary.streamCount == 1)
        #expect(backup.streamCount == 0)
        #expect(observation.servedProviderID == nil)
        #expect(observation.fallbackEvents.isEmpty)
        #expect(observation.attemptedProviderIDs == ["primary"])
        #expect(observation.attempts.map(\.attempt) == [1])
        #expect(observation.status == .terminalFailure)
        #expect(observation.terminalErrorDescription != nil)
    }

    @Test("missing route provenance fails closed before any provider call")
    func missingRouteProvenanceFailsClosedBeforeProviderCall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "provider-fallback-missing-provenance-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = CountingFallbackProvider(
            name: "primary",
            modelID: "primary-model",
            responseText: "must not send"
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "provider-fallback-workspace",
            revision: "provider-fallback-revision",
            grantEpoch: "provider-fallback-epoch",
            leaseID: "provider-fallback-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l3
        )
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: { _ in
                throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
            },
            chatRuntimeDependencies: .init(
                sessionStore: SessionStore(directory: root),
                memoryStore: MemoryStore(directory: root),
                skillStore: SkillStore(
                    skillsRoot: root.appendingPathComponent("skills")
                ),
                soulStore: SoulStore(directory: root)
            ),
            composerPolicyFacts: facts
        )
        let turn = AgentTurnIdentity(
            sessionID: "provider-fallback-session",
            turnID: 1,
            messageID: "provider-fallback-message"
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            taskID: "provider-fallback-task",
            attemptID: "provider-fallback-attempt",
            messageID: turn.messageID,
            inputDigest: "provider-fallback-input",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: facts.autonomyCeiling
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(
                store: SkillStore(
                    skillsRoot: root.appendingPathComponent("skills")
                )
            ).snapshotForTurn(),
            mcpBridge: nil,
            requiresProviderRuntimeRoute: true
        )

        await #expect(
            throws: ProviderRuntimeSnapshotError.missingPrimaryProvenance
        ) {
            let stream = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "no route")],
                systemPrompt: "test",
                maxTokens: 64,
                conversationID: turn.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: turn.turnID,
                composerSnapshot: composerSnapshot,
                executionIdentity: AgentExecutionIdentity(turn: turn),
                turnRuntimeSnapshot: runtimeSnapshot
            )
            for try await _ in stream {}
        }

        #expect(provider.sendCount == 0)
        #expect(provider.streamCount == 0)
    }

    // MARK: - D-PROVIDER-11/12 class -> decision mapping (lane W6-PROVIDER-ERRORCLASS-104)
    //
    // 排重结论：037 已交付 classify 单一权威与 typed 字段，063 已把分类投影到
    // 聊天错误面（MinisCore ProviderRequestFailureClassificationTests 钉映射，
    // F18bRetryTests 钉重试判定表），但「每个 canonical 类在真实生产链路上的
    // fallback/终止决策」没有任何测试钉住。以下用例驱动真实链路
    // （ProviderRuntimeRoute → makeRouter shouldFallback = LLMError.isFallbackable
    // + 终态边界 + 缓冲 POST 重放闸），逐类断言：可 fallback 的类按序换源且
    // trail/observation 携带同一 typed 依据；不可 fallback 的类原样直抛且绝不
    // 触碰下一个 provider；未分类失败 fail-closed 保持 nil。映射被删除或翻转
    // 时这些断言必须失败。

    private struct DecisionProbeResult {
        let thrown: Error?
        let primary: CountingFallbackProvider
        let backup: CountingFallbackProvider
        let observation: ProviderRuntimeRouteObservation
    }

    /// primary 抛 `sendError`、backup 成功的一次真实链路调用。
    private func probeDecision(
        sendError: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DecisionProbeResult {
        let primary = CountingFallbackProvider(
            name: "primary",
            modelID: "primary-model",
            sendError: sendError
        )
        let backup = CountingFallbackProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "backup response"
        )
        let probe = RouteObservationProbe()
        let route = try makeRoute(
            primary: primary,
            backup: backup,
            observationSink: probe.record
        )
        var thrown: Error?
        do {
            _ = try await route.sendMessage(
                messages: [LLMMessage(role: .user, content: "class decision")],
                systemPrompt: nil,
                maxTokens: 64,
                temperature: nil
            )
        } catch {
            thrown = error
        }
        let observation = try #require(probe.value)
        return DecisionProbeResult(
            thrown: thrown,
            primary: primary,
            backup: backup,
            observation: observation
        )
    }

    @Test("policy-allowed kinds fall back to backup carrying the typed reason on trail and observation")
    func fallbackEligibleKindsServeBackupWithTypedReason() async throws {
        let rows: [(error: Error, kind: ProviderRequestFailureKind, statusCode: Int?)] = [
            (LLMError.httpStatus(code: 401, detail: "key rejected"), .unauthorized, 401),
            (LLMError.invalidAPIKey(detail: "legacy key shape"), .unauthorized, nil),
            (LLMError.httpStatus(code: 403, detail: "forbidden"), .permissionDenied, 403),
            (LLMError.httpStatus(code: 404, detail: "model gone"), .notFound, 404),
            (LLMError.httpStatus(code: 429, detail: "slow down"), .rateLimited, 429),
            (LLMError.rateLimited, .rateLimited, nil),
        ]
        for row in rows {
            let result = try await probeDecision(sendError: row.error)
            #expect(
                result.thrown == nil,
                "kind \(row.kind) must fall back to backup, not terminate"
            )
            // 每个 provider 只被调用一次：整回合重放禁止（D-PROVIDER-13）。
            #expect(result.primary.sendCount == 1)
            #expect(result.backup.sendCount == 1)
            #expect(result.observation.status == .served)
            #expect(result.observation.servedProviderID == "backup")
            #expect(result.observation.fallbackEvents.count == 1)
            #expect(result.observation.fallbackEvents[0].providerID == "primary")
            #expect(result.observation.fallbackEvents[0].failureKind == row.kind)
            #expect(result.observation.fallbackEvents[0].statusCode == row.statusCode)
            #expect(result.observation.attempts.count == 2)
            #expect(result.observation.attempts[0].failureKind == row.kind)
            #expect(result.observation.attempts[0].statusCode == row.statusCode)
            #expect(result.observation.attempts[1].succeeded)
        }
    }

    @Test("policy-refused kinds terminate untouched without invoking the next provider")
    func nonFallbackableKindsTerminateWithoutTryingBackup() async throws {
        let rows: [(error: Error, kind: ProviderRequestFailureKind?, statusCode: Int?)] = [
            (LLMError.httpStatus(code: 500, detail: "boom"), .server, 500),
            (LLMError.transientError(message: "later"), .server, nil),
            (LLMError.httpStatus(code: 400, detail: "bad config"), .unconfigured, 400),
            (LLMError.networkError(underlying: URLError(.cannotConnectToHost)), .transport, nil),
            // fail-closed：未分类既不改写消息流也不猜类别。
            (LLMError.decodingError(underlying: URLError(.cannotParseResponse)), nil, nil),
        ]
        for row in rows {
            let result = try await probeDecision(sendError: row.error)
            #expect(
                (result.thrown as? LLMError) != nil,
                "non-fallbackable kind \(String(describing: row.kind)) must propagate the original LLMError"
            )
            #expect(result.primary.sendCount == 1)
            #expect(
                result.backup.sendCount == 0,
                "policy does not allow fallback for kind \(String(describing: row.kind))"
            )
            #expect(result.observation.status == .terminalFailure)
            #expect(result.observation.servedProviderID == nil)
            #expect(result.observation.fallbackEvents.isEmpty)
            #expect(result.observation.attempts.count == 1)
            #expect(result.observation.attempts[0].providerID == "primary")
            #expect(result.observation.attempts[0].failureKind == row.kind)
            #expect(result.observation.attempts[0].statusCode == row.statusCode)
        }
    }

    @Test("ambiguous buffered timeout hits the replay fence before any fallback")
    func ambiguousTimeoutHitsReplayFenceBeforeFallback() async throws {
        let result = try await probeDecision(
            sendError: LLMError.networkError(underlying: URLError(.timedOut))
        )
        #expect(
            result.thrown is ProviderRequestReplayBlockedError,
            "delivery-unknown timeout must surface as the typed replay-blocked failure"
        )
        #expect(result.primary.sendCount == 1)
        #expect(result.backup.sendCount == 0)
        #expect(result.observation.status == .terminalFailure)
        #expect(result.observation.fallbackEvents.isEmpty)
        #expect(result.observation.attempts.count == 1)
        #expect(result.observation.attempts[0].failureKind == .timeout)
        #expect(result.observation.attempts[0].statusCode == nil)
    }

    @Test("buffered cancellation is terminal with cancelled kind and never enters the fallback trail")
    func bufferedCancellationNeverFallsBack() async throws {
        let result = try await probeDecision(sendError: CancellationError())
        #expect(result.thrown is CancellationError)
        #expect(result.primary.sendCount == 1)
        #expect(result.backup.sendCount == 0)
        #expect(result.observation.status == .terminalFailure)
        #expect(result.observation.fallbackEvents.isEmpty)
        #expect(result.observation.attempts.count == 1)
        #expect(result.observation.attempts[0].failureKind == .cancelled)
        #expect(result.observation.attempts[0].statusCode == nil)
    }

    private func makeRoute(
        primary: CountingFallbackProvider,
        backup: CountingFallbackProvider,
        observationSink: @escaping @Sendable (ProviderRuntimeRouteObservation) -> Void
    ) throws -> ProviderRuntimeRoute {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: primary.name,
            modelID: primary.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: backup.name,
                    modelID: backup.model.id,
                    readinessEvidenceID: "mock-backup",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )
        return try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup],
            observationSink: observationSink
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private final class RouteObservationProbe: @unchecked Sendable {
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

private final class CountingFallbackProvider: LLMProvider, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = []
    let responseText: String
    let sendError: Error?
    let streamError: Error?
    private let lock = NSLock()
    private(set) var sendCount = 0
    private(set) var streamCount = 0

    init(
        name: String,
        modelID: String,
        responseText: String = "",
        sendError: Error? = nil,
        streamError: Error? = nil
    ) {
        self.name = name
        self.model = LLMModel(
            id: modelID,
            displayName: modelID,
            provider: name
        )
        self.responseText = responseText
        self.sendError = sendError
        self.streamError = streamError
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock { sendCount += 1 }
        if let sendError {
            throw sendError
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
        lock.withLock { streamCount += 1 }
        if let streamError {
            throw streamError
        }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
