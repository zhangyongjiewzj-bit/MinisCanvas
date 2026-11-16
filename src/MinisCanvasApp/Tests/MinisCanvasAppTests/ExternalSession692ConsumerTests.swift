import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("External source capability and owned runtime recovery consumers")
@MainActor
struct ExternalSession692ConsumerTests {
    private let sourceID = ExternalSessionSourceID(rawValue: "owned-692")
    private let profileID = ExternalSessionProfileID(rawValue: "owned-profile")
    private let threadID = ExternalSessionThreadID(rawValue: "owned-thread")
    private var now: Date { Date(timeIntervalSince1970: 200) }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("external692-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url // Retain only this owned synthetic fixture for failed-run diagnosis.
    }

    private func readGrant(_ composition: ExternalSessionAuthorizationComposition) async throws -> ExternalSessionReadGrantV1 {
        try await composition.issueReadGrant(authorizationID: .init(rawValue: UUID().uuidString),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.metadata, .messages, .status], issuedAt: now, lifetime: 100)
    }

    private func local(_ composition: ExternalSessionAuthorizationComposition, store: SessionStore,
                       persistence: URL? = nil) -> ExternalSessionAppAdapter {
        composition.makeAdapter(implementation: ExternalSessionLocalStoreAdapter(
            sourceID: sourceID, profileID: profileID, hostID: "owned-local", store: store,
            authorizationLedger: composition.ledger, clock: { Date(timeIntervalSince1970: 200) }),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: persistence)
    }

    @Test(arguments: [ExternalSessionSourceKindV1.codex, .claudeCode, .hermes])
    func successfulOwnedOneShotIsNotAnExistingSessionAdapter(_ kind: ExternalSessionSourceKindV1) async throws {
        let directory = try root()
        let runner: any ExternalAgentRunner
        switch kind {
        case .codex:
            runner = CodexAgentRunner(binaryPath: "/bin/sh", workingDirectory: directory,
                argumentBuilder: { _ in ["-c", "printf owned-one-shot"] })
        case .claudeCode:
            runner = ClaudeAgentRunner(binaryPath: "/bin/sh", workingDirectory: directory,
                argumentBuilder: { _ in ["-c", "printf owned-one-shot"] })
        case .hermes:
            runner = HermesAgentRunner(binaryPath: "/bin/sh", workingDirectory: directory,
                argumentBuilder: { _ in ["-c", "printf owned-one-shot"] })
        case .other: throw TestFailure692.invalidFixture
        }
        #expect(runner.isAvailable)
        let output = try await runner.run(task: SubAgentTask(id: "owned-692", title: "Owned fixture",
            instructions: "owned", executionID: UUID().uuidString))
        #expect(output == "owned-one-shot")
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let support = composition.sourceSupport(for: kind)
        #expect(support.missingPrerequisite == .adapterNotRegistered)
        #expect(support.registeredSourceIDs.isEmpty)
        #expect(support.declaredCapabilities.isEmpty)
        #expect(composition.adapter(for: sourceID) == nil)
        #expect(composition.externalSourceSupport.map(\.kind) == [.codex, .claudeCode, .hermes])
    }

    @Test func actualLocalStoreRegistrationDoesNotClaimConnectionBeforeHandshake() async throws {
        let directory = try root()
        let store = SessionStore(directory: directory.appendingPathComponent("sessions"))
        _ = try store.createSession(id: threadID.rawValue, projectID: "owned-project")
        let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: consumer)
        let adapter = local(composition, store: store)
        #expect(adapter.runtimeSnapshot.state == .disconnected)
        #expect(adapter.runtimeSnapshot.ownerID == nil)
        #expect(consumer.externalSessionRuntime?.snapshot.state == .disconnected)
        let initialSupport = composition.sourceSupport(for: .other)
        #expect(initialSupport.missingPrerequisite == .readOnlyAvailable)
        #expect(initialSupport.declaredCapabilities == [.readMetadata, .readMessages, .status])
        #expect(initialSupport.declaredCapabilities.isDisjoint(with: [.resume, .fork, .steer, .interrupt, .approval, .stream]))
        #expect(composition.sourceSupport(for: .codex).missingPrerequisite == .adapterNotRegistered)
        let early = ExternalSessionOutputBacklink(sourceID: sourceID, threadID: threadID,
            sequence: 1, sourceCursor: .init(rawValue: "unverified"), occurredAt: now,
            connectionGeneration: adapter.runtimeSnapshot.generation, summary: "owned early")
        #expect(adapter.acceptOutput(early, ownerID: "unverified") == .rejectedDisconnected)
        #expect(!adapter.beginExternalAttempt(correlationID: "owned", attemptID: "a1", ownerID: "unverified"))
        let grant = try await readGrant(composition)
        let connected = try await adapter.connect(readGrant: grant)
        #expect(connected.state == .connected)
        #expect(connected.ownerID != nil)
        #expect(consumer.externalSessionRuntime?.snapshot == connected)
        let support = composition.sourceSupport(for: .other)
        #expect(support.missingPrerequisite == .readOnlyAvailable)
        #expect(support.declaredCapabilities == [.readMetadata, .readMessages, .status])
        #expect(support.declaredCapabilities.isDisjoint(with: [.resume, .fork, .steer, .interrupt, .approval, .stream]))
        let page = try await adapter.listThreads(query: .init(sourceID: sourceID, limit: 2), readGrant: grant)
        #expect(page.threads.map(\.threadID) == [threadID])
        let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "owned-control"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID), operations: [.resume],
            issuedAt: now, lifetime: 100)
        await #expect(throws: ExternalSessionAppAdapterError.capabilityUnavailable(.resume)) {
            _ = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: page.observedCursor, idempotencyKey: "owned-resume"), controlGrant: control)
        }
        adapter.disconnect()
        #expect(adapter.runtimeSnapshot.state == .disconnected)
        #expect(adapter.runtimeSnapshot.ownerID == nil)
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            _ = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .resume, expectedCursor: page.observedCursor, idempotencyKey: "owned-resume-after-disconnect"),
                controlGrant: control)
        }
    }

    @Test func unknownSideEffectRequiresStatusReconcileWithoutRepeatingControl() async throws {
        let counts = Counts692()
        let persistence = try root().appendingPathComponent("unknown-control-runtime.json")
        let source = ExternalSessionSourceV1(sourceID: sourceID, kind: .codex, adapterVersion: "owned-fixture",
            profileID: profileID, hostID: "owned-local", capabilities: [.status, .interrupt], authState: .authorized)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let adapter = composition.makeAdapter(implementation: UnknownControl692(source: source, counts: counts),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: persistence)
        #expect(composition.sourceSupport(for: .codex).missingPrerequisite == .connectionHandshakeRequired)
        let grant = try await readGrant(composition)
        let first = try await adapter.connect(readGrant: grant)
        let firstOwner = try #require(first.ownerID)
        let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "owned-interrupt"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID), operations: [.interrupt],
            issuedAt: now, lifetime: 100)
        let receipt = try await adapter.cancel(sourceID: sourceID, threadID: threadID,
            expectedCursor: .init(rawValue: "owned-cursor"), idempotencyKey: "owned-interrupt", controlGrant: control)
        #expect(receipt.outcome == .unknownRequiresRecovery)
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(composition.sourceSupport(for: .codex).missingPrerequisite == .sideEffectReconciliationRequired)
        let before = await counts.snapshot()
        #expect(before.status == 1 && before.control == 1)
        let recovered = try await adapter.reconnect(readGrant: grant)
        let after = await counts.snapshot()
        #expect(after.status == 2 && after.control == 1)
        #expect(recovered.state == .recoveryRequired)
        #expect(recovered.requiresSideEffectReconciliation)
        #expect(recovered.ownerID != firstOwner)
        #expect(recovered.lastOutputBacklink == nil, "transport status is not proof of the unknown control effect")
        let reopenedComposition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let reopened = reopenedComposition.makeAdapter(implementation: UnknownControl692(source: source, counts: counts),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: persistence)
        #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(!reopened.runtimeSnapshot.recoveryActions.contains(.retry))
        #expect(reopenedComposition.sourceSupport(for: .codex).missingPrerequisite == .sideEffectReconciliationRequired)
        await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
            _ = try await reopened.cancel(sourceID: sourceID, threadID: threadID,
                expectedCursor: .beginning, idempotencyKey: "owned-interrupt", controlGrant: control)
        }
        let noRepeat = await counts.snapshot()
        #expect(noRepeat.control == 1)
    }

    @Test func sentControlTimeoutRequiresReconcileInsteadOfRetry() async throws {
        let counts = Counts692()
        let bytes = TimeoutBytes692(counts: counts)
        let transport = ExternalSessionCodexAppServerTransport(byteTransport: bytes,
            timeoutNanoseconds: 50_000_000, requestIDFactory: { "owned-timeout-request" })
        let source = ExternalSessionSourceV1(sourceID: sourceID, kind: .codex, adapterVersion: "owned-fixture",
            profileID: profileID, hostID: "owned-local", capabilities: [.status, .interrupt], authState: .authorized)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let adapter = composition.makeAdapter(implementation: UnknownControl692(source: source, counts: counts, transport: transport),
            clock: { Date(timeIntervalSince1970: 200) })
        let grant = try await readGrant(composition)
        _ = try await adapter.connect(readGrant: grant)
        let control = try await composition.issueControlGrant(authorizationID: .init(rawValue: "owned-timeout"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID), operations: [.interrupt],
            issuedAt: now, lifetime: 100)
        await #expect(throws: ExternalSessionAppServerTransportError.timedOut) {
            _ = try await adapter.cancel(sourceID: sourceID, threadID: threadID,
                expectedCursor: .init(rawValue: "owned-cursor"), idempotencyKey: "owned-timeout", controlGrant: control)
        }
        let captured = try #require(await bytes.payload())
        let object = try JSONSerialization.jsonObject(with: captured)
        let request = try #require(object as? [String: Any])
        #expect(request["method"] as? String == "session.interrupt")
        #expect(request["requestID"] as? String == "owned-timeout-request")
        #expect(request["idempotencyKey"] as? String == "owned-timeout")
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(!adapter.runtimeSnapshot.recoveryActions.contains(.retry))
        #expect(adapter.runtimeSnapshot.recoveryActions.contains(.inspect))
        let before = await counts.snapshot()
        #expect(before.status == 1 && before.control == 1)
        _ = try await adapter.reconnect(readGrant: grant)
        let after = await counts.snapshot()
        #expect(after.status == 2 && after.control == 1)
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
            _ = try await adapter.control(request: .init(sourceID: sourceID, threadID: threadID,
                operation: .interrupt, expectedCursor: .beginning, idempotencyKey: "owned-timeout"), controlGrant: control)
        }
        let noRepeat = await counts.snapshot()
        #expect(noRepeat.control == 1)
    }

    @Test func unavailableRegisteredSourceDeclaresNoUsableCapabilitiesAndMakesNoCall() async throws {
        let counts = Counts692()
        let source = ExternalSessionSourceV1(sourceID: sourceID, kind: .hermes, adapterVersion: "owned-fixture",
            profileID: profileID, hostID: "owned-local", capabilities: [.status, .interrupt], authState: .unavailable)
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let adapter = composition.makeAdapter(implementation: UnknownControl692(source: source, counts: counts),
            clock: { Date(timeIntervalSince1970: 200) })
        let support = composition.sourceSupport(for: .hermes)
        #expect(support.registeredSourceIDs == [sourceID])
        #expect(support.missingPrerequisite == .sourceUnavailable)
        #expect(support.declaredCapabilities.isEmpty)
        let grant = try await readGrant(composition)
        await #expect(throws: ExternalSessionAppAdapterError.sourceUnavailable) {
            _ = try await adapter.connect(readGrant: grant)
        }
        let calls = await counts.snapshot()
        #expect(calls.status == 0 && calls.control == 0)
    }

    @Test func persistedTerminalCheckpointKeepsAttemptAndRejectsRetiredOwnerAfterReopen() async throws {
        let directory = try root()
        let persistence = directory.appendingPathComponent("runtime.json")
        let store = SessionStore(directory: directory.appendingPathComponent("sessions"))
        let composition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let adapter = local(composition, store: store, persistence: persistence)
        let grant = try await readGrant(composition)
        let first = try await adapter.connect(readGrant: grant)
        let owner = try #require(first.ownerID)
        #expect(adapter.beginExternalAttempt(correlationID: "owned-correlation", attemptID: "owned-a1", ownerID: owner))
        func event(attempt: String, generation: UInt64, sequence: UInt64, cursor: String) -> ExternalAgentTerminalEventV1 {
            .init(identity: .init(correlationID: "owned-correlation", attemptID: attempt),
                eventID: "owned-event-\(sequence)", sourceID: sourceID, threadID: threadID, sequence: sequence,
                sourceCursor: .init(rawValue: cursor), occurredAt: now, connectionGeneration: generation,
                outcome: .succeeded, summary: "owned terminal")
        }
        let original = event(attempt: "owned-a1", generation: first.generation, sequence: 1, cursor: "owned-checkpoint-1")
        #expect(adapter.consumeTerminalEvent(original, ownerID: owner) == .accepted)
        let committed = try Data(contentsOf: persistence)
        let reopenedComposition = ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        let reopened = local(reopenedComposition, store: store, persistence: persistence)
        #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
        #expect(reopened.runtimeSnapshot.ownerID == nil)
        #expect(reopened.runtimeSnapshot.lastOutputBacklink?.sourceCursor == original.sourceCursor)
        #expect(reopened.runtimeSnapshot.lastOutputBacklink?.attemptID == "owned-a1")
        #expect(reopened.consumeTerminalEvent(original, ownerID: owner) == .rejectedDisconnected)
        #expect(try Data(contentsOf: persistence) == committed)
        let newGrant = try await readGrant(reopenedComposition)
        let connected = try await reopened.reconnect(readGrant: newGrant)
        let newOwner = try #require(connected.ownerID)
        #expect(newOwner != owner)
        #expect(reopened.beginExternalAttempt(correlationID: "owned-correlation", attemptID: "owned-a1", ownerID: newOwner))
        #expect(reopened.consumeTerminalEvent(original, ownerID: owner) == .rejectedLateResult)
        let duplicateAttempt = event(attempt: "owned-a1", generation: connected.generation, sequence: 2, cursor: "must-not-advance")
        #expect(reopened.consumeTerminalEvent(duplicateAttempt, ownerID: newOwner) == .rejectedLateResult)
        #expect(reopened.runtimeSnapshot.lastOutputBacklink?.sourceCursor == original.sourceCursor)
        #expect(reopened.beginExternalAttempt(correlationID: "owned-correlation", attemptID: "owned-a2", ownerID: newOwner))
        let next = event(attempt: "owned-a2", generation: connected.generation, sequence: 2, cursor: "owned-checkpoint-2")
        #expect(reopened.consumeTerminalEvent(next, ownerID: newOwner) == .accepted)
        #expect(reopened.runtimeSnapshot.lastOutputBacklink?.attemptID == "owned-a2")
        #expect(reopened.runtimeSnapshot.lastOutputBacklink?.sourceCursor == next.sourceCursor)
    }
}

private enum TestFailure692: Error { case invalidFixture }
private actor Counts692 {
    private var statuses = 0
    private var controls = 0
    func status() { statuses += 1 }
    func control() { controls += 1 }
    func snapshot() -> (status: Int, control: Int) { (statuses, controls) }
}
private struct UnknownControl692: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    let counts: Counts692
    var transport: ExternalSessionCodexAppServerTransport? = nil
    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        throw TestFailure692.invalidFixture
    }
    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        throw TestFailure692.invalidFixture
    }
    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        await counts.status()
        return .init(sourceID: source.sourceID, threadID: target.threadID, threadStatus: .active, observedCursor: .beginning)
    }
    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        if let transport { return try await transport.control(request) }
        await counts.control()
        return .init(sourceID: source.sourceID, threadID: request.threadID, operation: request.operation,
            outcome: .unknownRequiresRecovery, sourceCursor: request.expectedCursor)
    }
}

private actor TimeoutBytes692: ExternalSessionAppServerByteTransport {
    let counts: Counts692
    private var sentPayload: Data?
    init(counts: Counts692) { self.counts = counts }
    func send(payload: Data, requestID: String) async throws -> Data {
        sentPayload = payload
        await counts.control()
        try await Task.sleep(for: .seconds(5))
        throw TestFailure692.invalidFixture
    }
    func cancel(requestID: String) async {}
    func payload() -> Data? { sentPayload }
}
