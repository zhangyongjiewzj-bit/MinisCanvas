import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private actor Artifact542Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Same fixed two-response provider seam as ChatFileArtifactEvidenceTests.
/// The real AgentLoop mints and settles facts; this fixture never writes them.
private final class Artifact542Provider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name = "artifact542-synthetic"
    var model = LLMModel(id: "artifact542-model", displayName: "Synthetic", provider: "artifact542-synthetic")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "artifact542-fixed-config"
    private var replies: [String]
    init(envelope: String) { replies = [envelope, "synthetic complete"] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let next = try #require(!replies.isEmpty ? replies.removeFirst() : nil)
        return LLMResponse(text: next, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("Artifact542 fixture unexpectedly used streaming")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// Plain production functions; no NSWindow, Bridge defaults, network or UI.
/// Receipt/provenance come from the actual loop and a fixture-owned durable
/// fact ledger. The App projection is the exact call used by ContentView.
struct ChatArtifact542ProductionConsumerTests {
    private struct Fixture: Sendable {
        let root: URL
        let ledger: FileChangeLedger
        let facts: ToolExecutionFactLedger
        let session = "artifact542-session"
        init(persistMetadata: Bool = false, capacity: Int = 512) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Artifact542-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            ledger = FileChangeLedger(workspaceRoot: root.path, capacity: capacity)
            if persistMetadata {
                try ledger.attachPersistence(directory: root.appendingPathComponent("artifact-metadata"), resolveDirectory: {
            URL(fileURLWithPath: try DarwinSystemPathResolver.resolve($0), isDirectory: true)
        })
            }
            facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        }
        func artifacts(facts selected: [ToolExecutionFact]? = nil, sessionID: String? = nil) -> [ProducedFileArtifactEvidence] {
            AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: sessionID ?? session,
                ledger: ledger, facts: selected ?? facts.facts, limit: ChatInspectorSnapshot.maxFileChangeRows)
        }
    }

    /// Mutable executor/provider stay within this producer invocation.
    private func write(_ fixture: Fixture, name: String = "output.txt", content: String,
                       append: Bool, createDirectories: Bool = false,
                       operation: String = "first", attempt: Int = 1) async throws {
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: fixture.session, turnID: 1, messageID: "message542"),
            operationID: "operation542-\(operation)", attempt: attempt)
        let executor = BuiltinToolExecutor(allowedRoot: fixture.root, deniedRoots: [])
        executor.fileChangeLedger = fixture.ledger
        executor.fileChangeSessionID = fixture.session
        let envelope = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "write542", "name": "file_write", "input": [
                "path": fixture.root.appendingPathComponent(name).path, "content": content,
                "append": append, "create_dirs": createDirectories
            ]
        ]]])
        let provider = Artifact542Provider(envelope: String(decoding: envelope, as: UTF8.self))
        let loop = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(delegate: Artifact542Approval()), turnController: TurnController(),
            timeout: 30, toolExecutionFactLedger: fixture.facts)
        let tool = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_write" })
        _ = try await loop.run(messages: [], systemPrompt: "synthetic file artifact", provider: provider,
            toolExecutor: executor, tools: [tool], currentConversationID: fixture.session,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: fixture.session,
                conversationID: fixture.session, taskID: "task542-\(operation)", actorID: "fixture542"),
            executionIdentity: identity)
    }

    @Test func actualWriteReopensOneCanonicalArtifactWithoutReplayingTheToolOrInventingDiffBody() async throws {
        let fixture = try Fixture(persistMetadata: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await write(fixture, content: "first owned result\n", append: false)
        let oldFact = try #require(fixture.facts.facts.first)
        try await write(fixture, content: "first owned result\n", append: false, operation: "retry", attempt: 2)
        let expected = fixture.artifacts()
        #expect(expected.count == 1)
        let record = try #require(fixture.ledger.records(sessionID: fixture.session).first)
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("output.txt"))
        let cold = FileChangeLedger(workspaceRoot: fixture.root.path)
        try cold.attachPersistence(directory: fixture.root.appendingPathComponent("artifact-metadata"), resolveDirectory: {
            URL(fileURLWithPath: try DarwinSystemPathResolver.resolve($0), isDirectory: true)
        })
        let coldFacts = try ToolExecutionFactLedger(persistenceURL: fixture.root.appendingPathComponent("facts.json"))
        let restored = AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: fixture.session,
            ledger: cold, facts: coldFacts.facts, limit: 40)
        #expect(restored == expected)
        #expect(cold.count == 1)
        #expect(!cold.artifactPersistenceUnavailable)
        #expect(cold.diffPayload(diffID: record.diffID, sessionID: fixture.session) == nil)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: fixture.session,
            ledger: cold, facts: [oldFact], limit: 40).isEmpty)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: "foreign542",
            ledger: cold, facts: coldFacts.facts, limit: 40).isEmpty)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: fixture.session,
            ledger: cold, facts: coldFacts.facts + coldFacts.facts, limit: 40) == expected)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("output.txt")) == bytes)
        let metadata = try String(contentsOf: fixture.root.appendingPathComponent("artifact-metadata/metadata.json"), encoding: .utf8)
        #expect(!metadata.contains("first owned result") && !metadata.contains("unifiedDiff"))
    }

    @Test func staleMetadataWriterAndHardlinkedRecoveryCannotOverwriteTheAcceptedReference() async throws {
        let fixture = try Fixture(persistMetadata: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stale = FileChangeLedger(workspaceRoot: fixture.root.path)
        let directory = fixture.root.appendingPathComponent("artifact-metadata")
        try stale.attachPersistence(directory: directory, resolveDirectory: {
            URL(fileURLWithPath: try DarwinSystemPathResolver.resolve($0), isDirectory: true)
        })
        try await write(fixture, content: "accepted owned result\n", append: false)
        let file = directory.appendingPathComponent("metadata.json")
        let before = try Data(contentsOf: file)
        #expect(throws: FileChangeLedger.RegistrationError.stalePersistenceGeneration) {
            _ = try stale.register(sessionID: fixture.session, path: fixture.root.appendingPathComponent("stale.txt").path,
                kind: .created, oldContent: nil, newContent: "unaccepted")
        }
        #expect(try Data(contentsOf: file) == before)
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("owned-hardlink"))
        let unsafe = FileChangeLedger(workspaceRoot: fixture.root.path)
        #expect(throws: (any Error).self) { try unsafe.attachPersistence(directory: directory, resolveDirectory: {
            URL(fileURLWithPath: try DarwinSystemPathResolver.resolve($0), isDirectory: true)
        }) }
        #expect(unsafe.count == 0)
        #expect(unsafe.artifactPersistenceUnavailable)
        #expect(stale.artifactPersistenceUnavailable)
        #expect(try Data(contentsOf: file) == before)
        // A real producer may already have changed the file before metadata fails.
        // The visible state must report unavailable rather than claim rollback or zero history.
        try await write(fixture, name: "write-with-unavailable-metadata.txt", content: "physical effect",
                        append: false, operation: "metadata-failure", attempt: 2)
        #expect(fixture.ledger.artifactPersistenceUnavailable)
        #expect(fixture.artifacts().isEmpty)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("write-with-unavailable-metadata.txt")) == Data("physical effect".utf8))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func metadataRollbackRetainsDisplacedAndFIFOEvictedRecordsAcrossReopen() async throws {
        let fixture = try Fixture(persistMetadata: true, capacity: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await write(fixture, name: "first.txt", content: "first", append: false)
        try await write(fixture, name: "second.txt", content: "second", append: false, operation: "second", attempt: 2)
        let before = fixture.ledger.records(sessionID: fixture.session)
        let displaced = try fixture.ledger.registerWithUndo(sessionID: fixture.session,
            path: fixture.root.appendingPathComponent("first.txt").path, kind: .created,
            oldContent: nil, newContent: "first")
        fixture.ledger.rollbackRegistration(displaced.undo)
        let evicted = try fixture.ledger.registerWithUndo(sessionID: fixture.session,
            path: fixture.root.appendingPathComponent("third.txt").path, kind: .created,
            oldContent: nil, newContent: "third")
        fixture.ledger.rollbackRegistration(evicted.undo)
        #expect(fixture.ledger.records(sessionID: fixture.session) == before)
        let cold = FileChangeLedger(workspaceRoot: fixture.root.path, capacity: 2)
        try cold.attachPersistence(directory: fixture.root.appendingPathComponent("artifact-metadata"), resolveDirectory: {
            URL(fileURLWithPath: try DarwinSystemPathResolver.resolve($0), isDirectory: true)
        })
        #expect(cold.records(sessionID: fixture.session) == before)
        #expect(AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: fixture.session,
            ledger: cold, facts: fixture.facts.facts, limit: 40) == fixture.artifacts())
    }

    @Test(arguments: [false, true])
    func atomicCreationWithEitherAppendIntentReachesInspectorEvidence(append: Bool) async throws {
        let fixture = try Fixture()
        let content = "synthetic artifact542\n完整字节\n"
        try await write(fixture, content: content, append: append)
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("output.txt"))
        #expect(bytes == Data(content.utf8))
        let record = try #require(fixture.ledger.records(sessionID: fixture.session).first)
        let fact = try #require(fixture.facts.facts.first)
        #expect(fixture.facts.facts.count == 1)
        #expect(fact.status == .succeeded)
        #expect(record.producerReceiptID == fact.receiptID)
        #expect(record.producerCompositeKey == fact.compositeKey)
        #expect(fact.compositeKey?.sessionID == fixture.session)
        #expect(fact.compositeKey?.operationID == "operation542-first")
        let artifacts = fixture.artifacts()
        #expect(artifacts.count == 1)
        let artifact = try #require(artifacts.first)
        #expect(artifact.path == "output.txt")
        #expect(artifact.diffID == record.diffID)
        #expect(artifact.outputSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(artifact.producerReceiptID == fact.receiptID)
        #expect(artifact.producerAttemptID == fact.attemptID)
        #expect(artifact.producerToolCallID == fact.toolCallID)
        #expect(artifact.producerToolName == "file_write")
        #expect(artifact.status == .succeeded)
        #expect(artifact.nextStep == .reviewDiff)
        #expect(fixture.artifacts(sessionID: "unrelated542").isEmpty)
        #expect(fixture.artifacts(facts: []).isEmpty)
    }

    @Test func actualFailedWriteProducesNoInspectorArtifact() async throws {
        try #require(geteuid() != 0, "the owned read-only directory fixture requires an unprivileged process")
        let fixture = try Fixture()
        let blocker = fixture.root.appendingPathComponent("absent", isDirectory: true)
        let blockerBytes = Data("synthetic ordinary-file directory blocker542\n".utf8)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let control = blocker.appendingPathComponent("owned-control.txt")
        try blockerBytes.write(to: control)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocker.path) }
            catch { Issue.record("could not restore the owned fixture directory permissions: \(error)") }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocker.path)
        // The built-in executor durably marks dispatch before filesystem I/O.
        // A missing target inside this traversable directory passes preflight;
        // the real atomic write then fails because its parent is not writable.
        // The loop must retain UNKNOWN rather than manufacture a terminal fact.
        await #expect(throws: AgentLoopError.toolExecutionFactsUnavailable) {
            try await write(fixture, name: "absent/output.txt",
                            content: "synthetic failed542", append: true, createDirectories: true)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("absent/output.txt").path))
        let pending = try #require(fixture.facts.pendingReceipts.first)
        #expect(fixture.facts.pendingReceipts == [pending])
        #expect(pending.toolName == "file_write")
        let started = try #require(fixture.facts.pendingFileWriteEvidence(for: pending))
        #expect(started.receiptID == pending.receiptID)
        #expect(started.compositeKey == pending.compositeKey)
        #expect(started.targetPath == fixture.root.appendingPathComponent("absent/output.txt").path)
        #expect(started.expectedSHA256 == SHA256.hash(data: Data("synthetic failed542".utf8))
            .map { String(format: "%02x", $0) }.joined())
        #expect(started.completedSHA256 == nil)
        #expect(try Data(contentsOf: control) == blockerBytes)
        #expect(fixture.facts.facts.isEmpty)
        #expect(fixture.ledger.records(sessionID: fixture.session).isEmpty)
        #expect(fixture.artifacts().isEmpty)
        let reopened = try ToolExecutionFactLedger(
            persistenceURL: fixture.root.appendingPathComponent("facts.json"))
        #expect(reopened.recoveredPendingReceipts == [pending])
        #expect(reopened.facts.isEmpty)
        #expect(reopened.pendingFileWriteEvidence(for: pending) == started)
        #expect(!reopened.fileWriteWasNeverDispatched(pending))
        let executor = BuiltinToolExecutor(allowedRoot: fixture.root, deniedRoots: [])
        #expect(executor.queryRecoveredFileWrite(pending, ledger: reopened) == .unknown)
        #expect(fixture.artifacts(facts: reopened.facts).isEmpty)
    }

    @Test func missingParentRejectedBeforeDispatchHasFailedFactButNoInspectorArtifact() async throws {
        let fixture = try Fixture()
        try await write(fixture, name: "absent/output.txt", content: "synthetic failed542", append: true)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("absent").path))
        let fact = try #require(fixture.facts.facts.first)
        #expect(fixture.facts.facts.count == 1)
        #expect(fact.toolName == "file_write")
        #expect(fact.status == .failed)
        #expect(fact.compositeKey?.sessionID == fixture.session)
        #expect(fact.compositeKey?.operationID == "operation542-first")
        #expect(fixture.facts.pendingReceipts.isEmpty)
        #expect(fixture.ledger.records(sessionID: fixture.session).isEmpty)
        #expect(fixture.artifacts().isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: fixture.root.appendingPathComponent("facts.json"))
        #expect(reopened.facts == [fact])
        #expect(reopened.recoveredPendingReceipts.isEmpty)
        #expect(fixture.artifacts(facts: reopened.facts).isEmpty)
    }

    @Test func rejectedBeforeFileWriteDispatchHasFailedFactButNoInspectorArtifact() async throws {
        let fixture = try Fixture()
        let name = "../escaped-\(UUID().uuidString).txt"
        let escaped = fixture.root.appendingPathComponent(name).standardizedFileURL
        try await write(fixture, name: name, content: "synthetic denied542", append: false)
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        let fact = try #require(fixture.facts.facts.first)
        #expect(fixture.facts.facts.count == 1)
        #expect(fact.toolName == "file_write")
        #expect(fact.status == .failed)
        #expect(fixture.facts.pendingReceipts.isEmpty)
        #expect(fixture.ledger.records(sessionID: fixture.session).isEmpty)
        #expect(fixture.artifacts().isEmpty)
    }

    @Test func actualAppendRetainsDiffWithoutClaimingFullOutputHash() async throws {
        let fixture = try Fixture()
        let file = fixture.root.appendingPathComponent("output.txt")
        try Data("existing542\n".utf8).write(to: file)
        try await write(fixture, content: "appended542\n", append: true)
        #expect(try Data(contentsOf: file) == Data("existing542\nappended542\n".utf8))
        let fact = try #require(fixture.facts.facts.first)
        #expect(fact.status == .succeeded)
        let record = try #require(fixture.ledger.records(sessionID: fixture.session).first)
        #expect(record.outputSHA256 == nil)
        #expect(fixture.ledger.diffPayload(diffID: record.diffID, sessionID: fixture.session) != nil)
        #expect(fixture.artifacts().isEmpty)
    }

    @Test func replacedSameContentCannotUseAnEarlierSuccessfulAttempt() async throws {
        let fixture = try Fixture()
        try await write(fixture, content: "same542\n", append: true)
        let oldFact = try #require(fixture.facts.facts.first)
        let first = try #require(fixture.artifacts().first)
        try await write(fixture, content: "same542\n", append: false, operation: "retry", attempt: 2)
        let newFact = try #require(fixture.facts.facts.last)
        #expect(fixture.facts.facts.count == 2)
        #expect(oldFact.receiptID != newFact.receiptID)
        #expect(oldFact.attemptID != newFact.attemptID)
        #expect(newFact.attemptNumber == 2)
        #expect(fixture.artifacts(facts: [oldFact]).isEmpty)
        let current = fixture.artifacts()
        #expect(current.count == 1)
        let latest = try #require(current.first)
        #expect(latest.diffID == first.diffID)
        #expect(latest.outputSHA256 == first.outputSHA256)
        #expect(latest.producerReceiptID == newFact.receiptID)
        #expect(latest.producerAttemptID == newFact.attemptID)
        // Late presentation of the earlier durable fact cannot borrow the
        // replacement write even when path and generated bytes are identical.
        #expect(fixture.artifacts(facts: [newFact, oldFact]) == current)
    }
}
