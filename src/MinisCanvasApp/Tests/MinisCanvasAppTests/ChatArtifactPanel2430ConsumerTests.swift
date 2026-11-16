import CryptoKit
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private actor Artifact2430Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

/// Same fixed two-response provider seam as ChatFileArtifactEvidenceTests.
/// The real AgentLoop mints and settles facts; this fixture never writes them.
private final class Artifact2430Provider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    let name = "artifact2430-synthetic"
    var model = LLMModel(id: "artifact2430-model", displayName: "Synthetic", provider: "artifact2430-synthetic")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "artifact2430-fixed-config"
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
        Issue.record("Artifact2430 fixture unexpectedly used streaming")
        return AsyncThrowingStream { $0.finish() }
    }
}

/// Plain production functions; no NSWindow, Bridge defaults, network or UI.
/// Receipt/provenance come from the actual loop and a fixture-owned durable
/// fact ledger. The App projection is the exact call used by ContentView.
@MainActor
struct ChatArtifactPanel2430ConsumerTests {
    private struct Fixture {
        let root: URL
        let ledger: FileChangeLedger
        let facts: ToolExecutionFactLedger
        let session = "artifact2430-session"
        let defaults: UserDefaults
        init() throws {
            let paths = try FormalTestIsolationPaths.resolveCurrentProcess()
            let isolation = try #require(paths)
            root = isolation.rootDirectory
                .appendingPathComponent("Artifact2430-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defaults = try #require(UserDefaults(suiteName: isolation.userDefaultsSuiteName + "." + UUID().uuidString))
            ledger = FileChangeLedger(workspaceRoot: root.path)
            facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        }
        func artifacts(facts selected: [ToolExecutionFact]? = nil, sessionID: String? = nil) -> [ProducedFileArtifactEvidence] {
            AgentOutputLedgerCardAdapter.fileArtifacts(sessionID: sessionID ?? session,
                ledger: ledger, facts: selected ?? facts.facts, limit: ChatInspectorSnapshot.maxFileChangeRows)
        }
    }

    /// Mutable executor/provider stay within this producer invocation.
    private func write(_ fixture: Fixture, name: String = "output.txt", content: String,
                       append: Bool, operation: String = "first", attempt: Int = 1) async throws {
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: fixture.session, turnID: 1, messageID: "message2430"),
            operationID: "operation2430-\(operation)", attempt: attempt)
        let executor = BuiltinToolExecutor(allowedRoot: fixture.root, deniedRoots: [])
        executor.fileChangeLedger = fixture.ledger
        executor.fileChangeSessionID = fixture.session
        let envelope = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": "write2430", "name": "file_write", "input": [
                "path": fixture.root.appendingPathComponent(name).path, "content": content, "append": append
            ]
        ]]])
        let provider = Artifact2430Provider(envelope: String(decoding: envelope, as: UTF8.self))
        let loop = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(delegate: Artifact2430Approval()), turnController: TurnController(),
            timeout: 30, toolExecutionFactLedger: fixture.facts)
        let tool = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_write" })
        _ = try await loop.run(messages: [], systemPrompt: "synthetic file artifact", provider: provider,
            toolExecutor: executor, tools: [tool], currentConversationID: fixture.session,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: fixture.session,
                conversationID: fixture.session, taskID: "task2430-\(operation)", actorID: "fixture2430"),
            executionIdentity: identity)
    }

    private func snapshot(_ fixture: Fixture, facts: [ToolExecutionFact]? = nil, session: String? = nil) -> ChatInspectorSnapshot {
        let viewer = session ?? fixture.session
        return ChatInspectorSnapshot(sessionID: viewer,
            providerLabel: "synthetic", modelLabel: "synthetic", engineLabel: "AgentLoop",
            messageCount: 0, activeSessionCount: 1, archivedSessionCount: 0,
            tokenUsageLabel: "synthetic", budgetIsWarning: false, budgetIsOverLimit: false,
            currentTaskID: nil, taskSnapshots: [], receiptRows: [], sourceItems: [],
            toolEvents: [], omittedToolEventCount: 0, activityEvents: [], omittedActivityEventCount: 0,
            fileChanges: ChatInspectorFileChangeConsumer.changes(from: [], viewerSessionID: viewer, limit: ChatInspectorSnapshot.maxFileChangeRows),
            fileArtifacts: fixture.artifacts(facts: facts, sessionID: viewer),
            persistence: SessionCompactProjection(sessionID: nil, store: nil))
    }

    @Test func ordinaryChatAssetEntryExistsWithoutCanvasEvenWhenEmpty() {
        #expect(ContentView.assetPanelContent(canvasAvailable: false, isCanvasActive: false) == .chatFiles)
        #expect(ContentView.assetPanelContent(canvasAvailable: false, isCanvasActive: true) == .chatFiles)
        #expect(ContentView.assetPanelContent(canvasAvailable: true, isCanvasActive: true) == .canvasMedia)
    }

    @Test func actualWriteReachesChatPanelWithoutBorrowingOtherSessionOrReceipt() async throws {
        let fixture = try Fixture()
        try await write(fixture, content: "synthetic2430\n", append: false)
        let snapshot = snapshot(fixture)
        let evidence = try #require(snapshot.fileArtifacts.first)
        #expect(snapshot.fileArtifacts.count == 1)
        let panel = ChatArtifactPanelView(snapshot: snapshot, preferencesDefaults: fixture.defaults)
        #expect(panel.snapshot.fileArtifacts == snapshot.fileArtifacts)
        #expect(ContentView.assetPanelContent(canvasAvailable: false, isCanvasActive: false) == .chatFiles)
        #expect(evidence.producerReceiptID == fixture.facts.facts.first?.receiptID)
        #expect(evidence.producerAttemptID == fixture.facts.facts.first?.attemptID)
        #expect(self.snapshot(fixture, facts: []).fileArtifacts.isEmpty)
        #expect(self.snapshot(fixture, session: "other2430").fileArtifacts.isEmpty)
        let oldFact = try #require(fixture.facts.facts.first)
        try await write(fixture, content: "synthetic2430\n", append: false, operation: "replacement", attempt: 2)
        #expect(self.snapshot(fixture, facts: [oldFact]).fileArtifacts.isEmpty)
        #expect(self.snapshot(fixture).fileArtifacts.first?.producerReceiptID != evidence.producerReceiptID)
    }

    @Test func actualPanelFactoryPersistsDraggedWidthWithoutChangingContextWidth() throws {
        let fixture = try Fixture()
        fixture.defaults.set(380, forKey: ContextPanelWidthDragState.settingsKey)
        let panel = ChatArtifactPanelView(snapshot: .empty, preferencesDefaults: fixture.defaults)
        panel.widthSetting.applyDragTranslation(120)
        panel.widthSetting.applyDragTranslation(160)
        #expect(panel.widthSetting.width == 880)
        panel.widthSetting.endDrag()
        let reopened = ChatArtifactPanelView(snapshot: .empty, preferencesDefaults: fixture.defaults)
        #expect(reopened.widthSetting.width == 880)
        reopened.widthSetting.adjust(by: 40)
        #expect(reopened.widthSetting.width == 920)
        #expect(ChatArtifactPanelView(snapshot: .empty, preferencesDefaults: fixture.defaults).widthSetting.width == 920)
        #expect(fixture.defaults.double(forKey: ContextPanelWidthDragState.settingsKey) == 380)
        #expect(panel.snapshot.fileArtifacts.isEmpty)
    }
}
