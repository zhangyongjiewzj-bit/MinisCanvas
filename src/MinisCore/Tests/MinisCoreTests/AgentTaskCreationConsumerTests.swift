import Foundation
import Testing
@testable import MinisCore

@Suite("Agent task creation consumer", .serialized)
struct AgentTaskCreationConsumerTests {
    private let source = ParentRuntimeIdentity(
        sessionID: "session-1",
        conversationID: "conversation-1",
        turnID: "turn-handle:7",
        taskID: "parent-1",
        actorID: "actor-1"
    )

    private func request(
        taskID: String = "child-1",
        parentID: String = "parent-1",
        projectID: String = "project-1",
        scopeID: String = "scope-1",
        idempotencyKey: String = "create-1"
    ) -> AgentTaskCreationRequest {
        AgentTaskCreationRequest(
            taskID: taskID,
            parentID: parentID,
            source: source,
            title: "New task",
            projectID: projectID,
            workingDirectory: "/tmp/project-1",
            scopeID: scopeID,
            idempotencyKey: idempotencyKey,
            providerID: "provider-1",
            modelID: "model-1",
            configurationFingerprint: "config-1",
            routeReceiptID: "route-1",
            parentContextSnapshotID: "context-1"
        )
    }

    private func service(for store: AgentTaskStore) -> AgentTaskCommandService {
        AgentTaskCommandService(
            store: store,
            knownProjectIDs: ["project-1"],
            authorizedScopeIDs: ["scope-1"]
        )
    }

    private func consumer(for store: AgentTaskStore) -> AgentTaskCreationConsumer {
        AgentTaskCreationConsumer(
            store: store,
            knownProjectIDs: ["project-1"],
            authorizedScopeIDs: ["scope-1"]
        )
    }

    @Test("creates a durable linked task without switching")
    func createsLinkedTaskWithoutSwitch() throws {
        let store = AgentTaskStore()
        let receipt = try consumer(for: store).consume(request())

        #expect(receipt.didCreate)
        #expect(receipt.action.action == .new)
        #expect(receipt.action.switchAfterCreate == false)
        #expect(receipt.action.source == source)
        #expect(receipt.snapshot.status == .queued)
        #expect(receipt.snapshot.creation?.scopeID == "scope-1")
        #expect(receipt.snapshot.creation?.idempotencyKey == "create-1")
        #expect(receipt.snapshot.creation?.action.projectID == "project-1")
    }

    @Test("replay is idempotent and changed payload is rejected")
    func replayAndConflict() throws {
        let store = AgentTaskStore()
        let creationConsumer = consumer(for: store)
        let first = try creationConsumer.consume(request())
        let replay = try creationConsumer.consume(request())
        #expect(replay.didCreate == false)
        #expect(replay.snapshot == first.snapshot)
        #expect(throws: AgentTaskCommandServiceError.creationIdempotencyConflict) {
            try creationConsumer.consume(request(taskID: "child-2"))
        }
    }

    @Test("unknown project and unauthorized scope fail closed")
    func rejectsProjectAndScope() throws {
        let store = AgentTaskStore()
        let creationConsumer = consumer(for: store)
        #expect(throws: AgentTaskCommandServiceError.invalidCreationRequest(.unknownProject)) {
            try creationConsumer.consume(request(projectID: "missing"))
        }
        #expect(throws: AgentTaskCommandServiceError.invalidCreationRequest(.scopeDenied)) {
            try creationConsumer.consume(request(scopeID: "scope-denied"))
        }
    }

    @Test("source identity must bind to the parent")
    func rejectsSourceMismatch() throws {
        let store = AgentTaskStore()
        let creationConsumer = consumer(for: store)
        #expect(throws: AgentTaskCommandServiceError.invalidCreationRequest(.sourceParentMismatch)) {
            try creationConsumer.consume(request(parentID: "other-parent"))
        }
    }

    @Test("provenance and idempotency survive store restart")
    func survivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskCreationConsumer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")

        let firstStore = try AgentTaskStore(persistenceURL: url)
        let first = try consumer(for: firstStore).consume(request())
        let recoveredStore = try AgentTaskStore(persistenceURL: url)
        let replay = try consumer(for: recoveredStore).consume(request())

        #expect(replay.didCreate == false)
        #expect(replay.snapshot == first.snapshot)
        #expect(replay.snapshot.creation?.source == source)
        #expect(replay.action.switchAfterCreate == false)
    }

    @Test("receipt preserves the canonical parent-turn identity")
    func receiptCarriesCanonicalIdentity() throws {
        let store = AgentTaskStore()
        let original = request()
        let receipt = try consumer(for: store).consume(original)
        let requestIdentity = AgentTaskCreationIdentity(request: original)
        let receiptIdentity = AgentTaskCreationIdentity(receipt: receipt)

        #expect(requestIdentity.isValid)
        #expect(receiptIdentity == requestIdentity)
        #expect(receipt.snapshot.sourceSessionID == source.sessionID)
        #expect(receipt.snapshot.parentID == source.taskID)
        #expect(receipt.snapshot.status == .queued)
    }

    @Test("empty creation identity fails before store admission")
    func emptyIdentityFailsClosed() throws {
        let store = AgentTaskStore()
        let invalid = AgentTaskCreationRequest(
            taskID: " ",
            parentID: source.taskID,
            source: source,
            title: "New task",
            projectID: "project-1",
            scopeID: "scope-1",
            idempotencyKey: "create-empty"
        )

        #expect(throws: AgentTaskCommandServiceError.invalidCreationRequest(.blankTaskID)) {
            try consumer(for: store).consume(invalid)
        }
        #expect(store.snapshot(taskID: " ", parentID: source.taskID) == nil)
    }

    @Test("creation request is recoverable from a fresh command service")
    func recoversCreationAfterServiceRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskCreationRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")

        let firstStore = try AgentTaskStore(persistenceURL: url)
        let first = try service(for: firstStore).create(request())
        let recoveredStore = try AgentTaskStore(persistenceURL: url)
        let recovered = try #require(
            service(for: recoveredStore).recoverCreation(idempotencyKey: "create-1")
        )

        #expect(recovered.receipt.didCreate == false)
        #expect(recovered.receipt.request == first.request)
        #expect(recovered.receipt.action == first.action)
        #expect(recovered.receipt.snapshot == first.snapshot)
        #expect(service(for: recoveredStore).recoverCreation(idempotencyKey: "missing") == nil)
    }
}
