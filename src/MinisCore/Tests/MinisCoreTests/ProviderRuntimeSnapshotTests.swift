import Foundation
import Testing
@testable import MinisCore

@Suite("Provider runtime snapshot and route")
struct ProviderRuntimeSnapshotTests {
    @Test("terminal error projection is typed and body-free")
    func terminalErrorProjectionIsTypedAndBodyFree() {
        let trail = FallbackRouterError.allProvidersFailed([
            FallbackRouter.FallbackEvent(
                providerID: "provider-with-secret-id",
                errorDescription: "Bearer secret response body /private/tmp/private.json",
                attempt: 1
            )
        ])
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(for: trail)
                == "Provider error"
        )
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(
                for: LLMError.httpStatus(
                    code: 401,
                    detail: "provider response body with PII"
                )
            ) == "HTTP 401"
        )
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(
                for: LLMError.providerError(message: "provider body /private/tmp/secret")
            ) == "Provider error"
        )
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(for: CancellationError())
                == "Request was cancelled"
        )
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(for: LLMError.cancelled)
                == "Request was cancelled"
        )
        let unknown = NSError(
            domain: "provider-response-body",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "PII /private/tmp/evidence/secret"
            ]
        )
        #expect(
            ProviderRuntimeRoute.safeTerminalErrorDescription(for: unknown)
                == "Provider error"
        )
    }

    @Test("snapshot freezes capability, config fingerprint, and creation time")
    func snapshotFreezesCapabilityAndConfigurationFacts() throws {
        let createdAt = Date(timeIntervalSince1970: 1_725_000_000)
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "evidence",
            applyReceiptID: "provider-readiness-apply:primary",
            capabilities: [.streaming, .tools],
            configurationFingerprint: "provider-config:opaque",
            createdAt: createdAt
        )

        #expect(snapshot.capabilities == [.streaming, .tools])
        #expect(snapshot.configurationFingerprint == "provider-config:opaque")
        #expect(snapshot.createdAt == createdAt)

        let encoded = try String(
            data: JSONEncoder().encode(snapshot),
            encoding: .utf8
        )
        #expect(encoded?.contains("provider-config:opaque") == true)
        #expect(encoded?.contains("https://") == false)
        #expect(encoded?.contains("api_key") == false)

        let decoded = try JSONDecoder().decode(
            ProviderRuntimeSnapshot.self,
            from: try #require(encoded?.data(using: .utf8))
        )
        #expect(decoded == snapshot)
    }

    @Test("legacy snapshots decode without newly added provider facts")
    func legacySnapshotDecodesWithoutNewFacts() throws {
        let legacyJSON = """
        {
          "providerID": "primary",
          "modelID": "primary-model",
          "readinessEvidenceID": "evidence",
          "applyReceiptID": "provider-readiness-apply:primary",
          "fallbackProviderIDs": ["backup"],
          "fallbackProvenance": [{
            "providerID": "backup",
            "modelID": "backup-model",
            "readinessEvidenceID": "backup-evidence",
            "applyReceiptID": "provider-readiness-apply:backup"
          }]
        }
        """

        let snapshot = try JSONDecoder().decode(
            ProviderRuntimeSnapshot.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(snapshot.capabilities.isEmpty)
        #expect(snapshot.configurationFingerprint == nil)
        #expect(snapshot.fallbackProvenance[0].capabilities.isEmpty)
        #expect(snapshot.fallbackProvenance[0].configurationFingerprint == nil)
        #expect(snapshot.hasCompleteFallbackProvenance)
    }

    @Test("production recovery fails closed after persisted snapshot restart and live fallback drift")
    @MainActor
    func productionRecoveryFailsClosedAfterPersistedSnapshotRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderRuntimeSnapshotRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(
            id: UUID().uuidString,
            projectID: "project-a"
        )
        let memory = MemoryStore(directory: root)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root)
        let primaryFingerprint = ProviderRuntimeSnapshot.configurationFingerprint(
            providerID: "primary",
            modelID: "primary-model",
            capabilities: [.streaming],
            configurationMaterial: "primary-frozen"
        )
        let fallbackFingerprint = ProviderRuntimeSnapshot.configurationFingerprint(
            providerID: "backup",
            modelID: "backup-model",
            capabilities: [.streaming],
            configurationMaterial: "backup-frozen"
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            toolsError: LLMError.providerError(message: "primary unavailable"),
            configurationMaterial: "primary-frozen"
        )
        let fallback = RuntimeTestProvider(
            name: "backup",
            modelID: "backup-model",
            configurationMaterial: "backup-frozen"
        )
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
                    applyReceiptID: "provider-readiness-apply:backup",
                    configurationFingerprint: fallbackFingerprint
                )
            ],
            configurationFingerprint: primaryFingerprint
        )

        let snapshotURL = root.appendingPathComponent("provider-runtime-snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: [.atomic])
        let restartedSnapshot = try JSONDecoder().decode(
            ProviderRuntimeSnapshot.self,
            from: Data(contentsOf: snapshotURL)
        )
        #expect(restartedSnapshot == snapshot)
        #expect(
            restartedSnapshot.fallbackProvenance[0].configurationFingerprint
                == fallbackFingerprint
        )

        let runtime = try ChatSessionRuntime(
            sessionStore: sessions,
            memoryStore: memory,
            skillStore: skills,
            soulStore: souls,
            provider: primary,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            providerRuntimeSnapshot: restartedSnapshot,
            fallbackProviders: [fallback],
            toolCatalog: AgentToolCatalog.makeTools(),
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent(
                    "tool-execution-facts-v4.json"
                )
            )
        )
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = ChatTurnRequest(
            text: "restart recovery",
            context: context,
            policySnapshotID: "provider-runtime-policy",
            grantSnapshotID: "provider-runtime-grant",
            executionIdentity: AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: context.sessionID,
                    turnID: 1,
                    messageID: "provider-runtime-restart-message"
                ),
                operationID: "provider-runtime-restart",
                attempt: 1
            )
        )

        // A restarted production consumer must keep using the persisted
        // fallback binding instead of adopting a changed live provider.
        fallback.model = LLMModel(
            id: "backup-model",
            displayName: "backup-model",
            provider: "changed-live-provider"
        )

        do {
            _ = try await runtime.sendProduction(request)
            Issue.record("restarted recovery adopted changed live fallback binding")
        } catch let error as ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected runtime error: \(error)")
                return
            }
            #expect(envelope.providerID == restartedSnapshot.providerID)
            #expect(envelope.modelID == restartedSnapshot.modelID)
            #expect(
                envelope.configurationFingerprint
                    == restartedSnapshot.configurationFingerprint
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(primary.toolsCalls == 1)
        #expect(fallback.toolsCalls == 0)
    }

    @Test("route fails closed when provider identity or model binding is stale")
    @MainActor
    func routeRejectsStaleProviderBinding() throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary",
            capabilities: [.streaming]
        )
        let staleProvider = RuntimeTestProvider(
            name: "renamed-primary",
            modelID: "different-model"
        )

        #expect(
            throws: ProviderRuntimeSnapshotError.providerBindingMismatch("primary")
        ) {
            try ProviderRuntimeRoute(snapshot: snapshot, primary: staleProvider)
        }
    }

    @Test("ordinary route requires primary readiness and apply provenance")
    func routeRequiresPrimaryReadinessAndApplyProvenance() throws {
        #expect(
            throws: ProviderRuntimeSnapshotError.missingPrimaryProvenance
        ) {
            try ProviderRuntimeSnapshot(
                providerID: "primary",
                modelID: "primary-model"
            )
        }
    }

    @Test("snapshot rejects a primary provider repeated in the fallback chain")
    func snapshotRejectsPrimaryDuplicateFallbackIdentity() {
        #expect(throws: ProviderRuntimeSnapshotError.duplicateFallback) {
            try ProviderRuntimeSnapshot(
                providerID: "primary",
                modelID: "primary-model",
                readinessEvidenceID: "primary-evidence",
                applyReceiptID: "provider-readiness-apply:primary",
                fallbackProviderIDs: ["primary"]
            )
        }
    }

    @Test("snapshot rejects malformed live readiness evidence")
    func snapshotRejectsMalformedLiveReadinessEvidence() {
        #expect(
            throws: ProviderRuntimeSnapshotError.invalidReadinessEvidence
        ) {
            try ProviderRuntimeSnapshot(
                providerID: "primary",
                modelID: "primary-model",
                readinessEvidenceID: "live-settings:primary",
                applyReceiptID: "provider-readiness-apply:primary"
            )
        }
    }

    @Test @MainActor
    func goalReviewUsesOnePrimaryTextLeafAndItsActualReceipt() async throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review draft"))
        let report = goal.reportCompletion(evidence: ["Draft reviewed"])
        _ = try #require(report)
        let selection = try ProviderRuntimeSnapshot(
            providerID: "primary", modelID: "primary-model", readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary"
        )
        let usage = LLMUsage(inputTokens: 9, outputTokens: 2)
        let primary = RuntimeTestProvider(name: "primary", modelID: "primary-model",
            textResponse: LLMResponse(text: "VERDICT: PASS", stopReason: "stop", usage: usage))
        let result = try await ConversationGoalReviewVerdict.request(
            for: goal, selection: selection, primary: primary, normalStopReasons: ["stop"]
        )
        #expect(primary.sendCalls == 1)
        #expect(primary.toolsCalls == 0)
        #expect(primary.streamCalls == 0)
        #expect(result.receipt.servedProviderID == "primary")
        #expect(result.receipt.servedModelID == "primary-model")
        #expect(result.verdict.outcome == .passed)
        #expect(result.verdict.usage == usage)
    }

    @Test("route revalidates provider and model identity before an in-flight attempt")
    @MainActor
    func routeRejectsInFlightProviderModelDrift() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary"
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model"
        )
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary
        )

        primary.model = LLMModel(
            id: "drifted-model",
            displayName: "drifted-model",
            provider: "primary"
        )

        do {
            _ = try await route.sendMessage(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("drifted provider/model binding was allowed to execute")
        } catch let error as ProviderRuntimeSnapshotError {
            #expect(error == .modelBindingMismatch("primary"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("typed retryable errors do not bypass the fallback policy")
    @MainActor
    func routeDoesNotFallbackForRetryableProviderError() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "backup-evidence",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: LLMError.transientError(message: "retry on primary")
        )
        let backup = RuntimeTestProvider(
            name: "backup",
            modelID: "backup-model"
        )
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup]
        )

        do {
            _ = try await route.streamMessage(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("retryable primary failure unexpectedly fell back")
        } catch let error as LLMError {
            guard case .transientError(let message) = error else {
                Issue.record("unexpected LLM error: \(error)")
                return
            }
            #expect(message == "retry on primary")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(primary.streamCalls == 1)
        #expect(backup.streamCalls == 0)
    }

    @Test("snapshot freezes receipt-backed provenance for every fallback")
    func snapshotCarriesFallbackProvenance() throws {
        let fallback = ProviderRuntimeFallback(
            providerID: "backup",
            modelID: "backup-model",
            readinessEvidenceID: "mock-backup-evidence",
            applyReceiptID: "provider-readiness-apply:backup"
        )
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "mock-primary",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [fallback]
        )

        #expect(snapshot.fallbackProviderIDs == ["backup"])
        #expect(snapshot.fallbackProvenance == [fallback])
        #expect(snapshot.hasCompleteFallbackProvenance)
        #expect(snapshot.routeReceiptID.hasPrefix("provider-route:"))
    }

    @Test("snapshot freezes readiness and fallback identity")
    func snapshotFreezesPublicRuntimeFacts() throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "luna",
            modelID: "gpt-5.6-luna",
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:abc",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "mock-backup",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )

        #expect(snapshot.providerID == "luna")
        #expect(snapshot.modelID == "gpt-5.6-luna")
        #expect(snapshot.fallbackProviderIDs == ["backup"])
        #expect(snapshot.routeReceiptID.hasPrefix("provider-route:"))
    }

    @Test("snapshot rejects missing or forged active Apply provenance")
    func snapshotRejectsInvalidActiveApplyProvenance() {
        #expect(throws: ProviderRuntimeSnapshotError.missingPrimaryProvenance) {
            try ProviderRuntimeSnapshot(
                providerID: "primary",
                modelID: "primary-model"
            )
        }

        do {
            _ = try ProviderRuntimeSnapshot(
                providerID: "primary",
                modelID: "primary-model",
                readinessEvidenceID: "primary-evidence",
                applyReceiptID: "forged-apply"
            )
            Issue.record("forged Apply identity was accepted")
        } catch let error as ProviderRuntimeSnapshotError {
            #expect(error == .invalidApplyReceiptIdentity("primary"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("served-after-fallback receipt binds active and served provenance")
    @MainActor
    func servedAfterFallbackReceiptBindsBothIdentities() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:discovery-primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "backup-evidence",
                    applyReceiptID: "provider-readiness-apply:discovery-backup"
                )
            ]
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = RuntimeTestProvider(
            name: "backup",
            modelID: "backup-model"
        )
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup]
        )

        let result = try await route.streamMessageWithReceipt(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        #expect(result.receipt.routeReceiptID == snapshot.routeReceiptID)
        #expect(result.receipt.activeProviderID == "primary")
        #expect(result.receipt.activeModelID == "primary-model")
        #expect(result.receipt.activeReadinessEvidenceID == "primary-evidence")
        #expect(result.receipt.activeDiscoveryReceiptID == "discovery-primary")
        #expect(result.receipt.activeApplyReceiptID
            == "provider-readiness-apply:discovery-primary")
        #expect(result.receipt.servedProviderID == "backup")
        #expect(result.receipt.servedModelID == "backup-model")
        #expect(result.receipt.servedReadinessEvidenceID == "backup-evidence")
        #expect(result.receipt.servedDiscoveryReceiptID == "discovery-backup")
        #expect(result.receipt.servedApplyReceiptID
            == "provider-readiness-apply:discovery-backup")
        #expect(result.receipt.servedAfterFallback)
    }

    @Test("route revalidates current activeProvider identity before serving")
    @MainActor
    func routeRejectsActiveProviderDriftBeforeReceipt() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:discovery-primary"
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model"
        )
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary
        )
        primary.model = LLMModel(
            id: "primary-model",
            displayName: "primary-model",
            provider: "drifted-provider"
        )

        do {
            _ = try await route.sendMessageWithReceipt(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("drifted activeProvider was allowed to serve")
        } catch let error as ProviderRuntimeSnapshotError {
            #expect(error == .providerBindingMismatch("primary"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("runtime route falls back only after the primary stream acquisition fails")
    @MainActor
    func runtimeRouteFallsBackInOrder() async throws {
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
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: LLMError.invalidAPIKey()
        )
        let backup = RuntimeTestProvider(name: "backup", modelID: "backup-model")
        let routed = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup]
        )

        let stream = try await routed.streamMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        var text = ""
        for try await chunk in stream {
            if case .text(let value) = chunk {
                text += value
            }
        }

        #expect(text == "backup")
        #expect(primary.streamCalls == 1)
        #expect(backup.streamCalls == 1)
    }

    @Test("tools-aware route uses the same ordered chain without replaying primary")
    @MainActor
    func runtimeRouteFallsBackForTools() async throws {
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
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            toolsError: LLMError.providerError(message: "primary tools unavailable")
        )
        let backup = RuntimeTestProvider(
            name: "backup",
            modelID: "backup-model",
            toolsResponseText: "backup-tools"
        )
        let routed = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup]
        )

        let response = try await routed.sendMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            tools: [
                AgentToolDefinition(
                    name: "file_read",
                    description: "read a file",
                    parameters: [:],
                    required: []
                )
            ],
            maxTokens: 32,
            temperature: nil
        )

        #expect(response.text == "backup-tools")
        #expect(primary.toolsCalls == 1)
        #expect(backup.toolsCalls == 1)
    }

    @Test("route observation records served provider and fallback trail")
    @MainActor
    func runtimeRouteEmitsFallbackObservation() async throws {
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
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: LLMError.invalidAPIKey()
        )
        let backup = RuntimeTestProvider(name: "backup", modelID: "backup-model")
        let probe = RouteObservationProbe()
        let routed = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup],
            observationSink: { probe.record($0) }
        )

        let stream = try await routed.streamMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )
        for try await _ in stream {}

        let observation = try #require(probe.value)
        #expect(observation.routeReceiptID == snapshot.routeReceiptID)
        #expect(observation.servedProviderID == "backup")
        #expect(observation.servedModelID == "backup-model")
        #expect(observation.status == .served)
        #expect(observation.attempts.map(\.providerID) == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.attempts.map(\.failureDescription.isEmpty) == [false, true])
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary"])
    }

    @Test("primary success observation records only the served attempt")
    @MainActor
    func runtimeRouteEmitsPrimarySuccessObservation() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "backup-evidence",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )
        let primary = RuntimeTestProvider(name: "primary", modelID: "primary-model")
        let backup = RuntimeTestProvider(name: "backup", modelID: "backup-model")
        let probe = RouteObservationProbe()
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup],
            observationSink: { probe.record($0) }
        )

        _ = try await route.sendMessage(
            messages: [LLMMessage(role: .user, content: "hello")],
            systemPrompt: nil,
            maxTokens: 32,
            temperature: nil
        )

        let observation = try #require(probe.value)
        #expect(observation.servedProviderID == "primary")
        #expect(observation.servedModelID == "primary-model")
        #expect(observation.status == .served)
        #expect(observation.terminalErrorDescription == nil)
        #expect(observation.attempts.map(\.providerID) == ["primary"])
        #expect(observation.attempts.map(\.attempt) == [1])
        #expect(observation.attempts.map(\.failureDescription.isEmpty) == [true])
        #expect(observation.fallbackEvents.isEmpty)
        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 0)
    }

    @Test("terminal fallback failure emits route and ordered attempt provenance")
    @MainActor
    func runtimeRouteEmitsTerminalFallbackObservation() async throws {
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: "primary",
            modelID: "primary-model",
            readinessEvidenceID: "primary-evidence",
            applyReceiptID: "provider-readiness-apply:primary",
            fallbackProvenance: [
                ProviderRuntimeFallback(
                    providerID: "backup",
                    modelID: "backup-model",
                    readinessEvidenceID: "backup-evidence",
                    applyReceiptID: "provider-readiness-apply:backup"
                )
            ]
        )
        let primary = RuntimeTestProvider(
            name: "primary",
            modelID: "primary-model",
            streamError: LLMError.invalidAPIKey()
        )
        let backup = RuntimeTestProvider(
            name: "backup",
            modelID: "backup-model",
            streamError: LLMError.providerError(message: "backup unavailable")
        )
        let probe = RouteObservationProbe()
        let route = try ProviderRuntimeRoute(
            snapshot: snapshot,
            primary: primary,
            fallbacks: [backup],
            observationSink: { probe.record($0) }
        )

        do {
            _ = try await route.streamMessage(
                messages: [LLMMessage(role: .user, content: "hello")],
                systemPrompt: nil,
                maxTokens: 32,
                temperature: nil
            )
            Issue.record("terminal fallback failure unexpectedly succeeded")
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
        #expect(observation.routeReceiptID == snapshot.routeReceiptID)
        #expect(observation.servedProviderID == nil)
        #expect(observation.servedModelID == nil)
        #expect(observation.status == .terminalFailure)
        #expect(observation.terminalErrorDescription == "Provider error")
        #expect(observation.attempts.map(\.providerID) == ["primary", "backup"])
        #expect(observation.attempts.map(\.attempt) == [1, 2])
        #expect(observation.attempts.allSatisfy { !$0.failureDescription.isEmpty })
        #expect(observation.fallbackEvents.map(\.providerID) == ["primary", "backup"])
        #expect(observation.fallbackEvents.map(\.attempt) == [1, 2])
    }
}

private final class RuntimeTestProvider: @unchecked Sendable, LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name: String
    var model: LLMModel
    var runtimeConfigurationMaterial: String?
    let streamError: Error?
    let toolsError: Error?
    let toolsResponseText: String?
    let textResponse: LLMResponse?
    private(set) var streamCalls = 0
    private(set) var sendCalls = 0
    private(set) var toolsCalls = 0

    init(
        name: String,
        modelID: String,
        streamError: Error? = nil,
        toolsError: Error? = nil,
        toolsResponseText: String? = nil,
        configurationMaterial: String? = nil,
        textResponse: LLMResponse? = nil
    ) {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.runtimeConfigurationMaterial = configurationMaterial
        self.streamError = streamError
        self.toolsError = toolsError
        self.toolsResponseText = toolsResponseText
        self.textResponse = textResponse
    }

    var capabilities: Set<ProviderCapability> { [.streaming] }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCalls += 1
        return textResponse ?? LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        toolsCalls += 1
        if let toolsError {
            throw toolsError
        }
        return LLMResponse(
            text: toolsResponseText ?? "ok-tools",
            stopReason: "stop",
            usage: nil
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamCalls += 1
        if let streamError {
            throw streamError
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("backup"))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
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
