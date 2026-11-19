import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("UI06 ChatInspector Canvas 隔离")
struct ChatInspectorIsolationTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("snapshot is a value projection with no mutable store owner")
    func snapshotIsValueOnly() {
        let snapshot = ChatInspectorSnapshot.empty
        let copy = snapshot
        #expect(copy == snapshot)
        #expect(snapshot.taskSnapshots.isEmpty)
        #expect(snapshot.receiptRows.isEmpty)
        #expect(snapshot.sourceItems.isEmpty)
    }

    @Test("ChatInspector source has no Canvas or mutable store dependency")
    func inspectorDoesNotOwnCanvasOrStores() throws {
        let inspector = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/ChatInspectorView.swift"
        )
        let taskSummary = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/TaskSummaryView.swift"
        )

        for forbidden in ["CanvasStore", "ChatStore", "BridgeStore", "FileTreeLogic"] {
            #expect(!inspector.contains(forbidden), "ChatInspector must not reference \(forbidden)")
            #expect(!taskSummary.contains(forbidden), "TaskSummary must not reference \(forbidden)")
        }
        for required in [
            "struct ChatInspectorSnapshot",
            "ContextManifest.Entry",
            "ConversationEventDisplayProjection",
            "SessionCompactProjection",
            "TaskCenterReceiptRow"
        ] {
            #expect(inspector.contains(required), "Missing value projection contract: \(required)")
        }
    }

    @Test("ContextPanel and ContentView keep chat and canvas caller paths separate")
    func callerRoutesAreExplicit() throws {
        let panel = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift"
        )
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )

        let panelFlow = panel.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        // UI06 keeps canvasOverview confined to the canvas-only branch.
        // The chat-only branch still receives the immutable chatSnapshot.
        // The approved compaction feedback adds only a session-matched container.
        // Match that container explicitly; do not weaken the caller-route guard.
        // All owner, forbidden-read and ContentView route assertions below remain.
        let expectedPanelRoute =
            "} else if let canvas { canvasOverview(canvas) } else { "
                + "VStack(alignment: .leading, spacing: 6) { "
                + "if let result = chat.compactionPresentation, let sessionID = result.sessionID, "
                + "sessionID == chat.activeSessionID { Text(result.message) .font(.caption) "
                + ".foregroundStyle(result.state == .failed ? (theme?.statusWarningText ?? AppStatusColor.warning) : Color.secondary) "
                + ".padding(.horizontal, 10) .accessibilityIdentifier(\"context.compaction.result\") } "
                + "ChatInspectorView( snapshot: chatSnapshot,"

        #expect(panelFlow.contains(expectedPanelRoute))
        #expect(panel.contains("let canvas: CanvasStore?"))
        #expect(!panel.contains("private var chatInfoSection"))
        #expect(!panel.contains("sectionTitle(\"画布状态\""))
        #expect(content.contains("let canvasForPanel: CanvasStore?"))
        #expect(content.contains("private var canvasAvailable: Bool { bridge.canvasIfAvailable != nil }"))
        #expect(content.contains("canvasAvailable && (visibleLayoutMode == .canvas"))
        #expect(content.contains("isCanvasActive ? bridge.canvasIfAvailable : nil"))
        #expect(content.contains("nodeContext: isCanvasActive ? bridge.selectedNodeContext : nil"))
        #expect(content.contains("ChatInspectorSnapshot("))
        #expect(content.contains("if isCanvasActive, let boundary = bridge.canvasBoundaryIfAvailable {"))
        #expect(content.contains("canvasStatusBar"))
        #expect(content.contains("chatStatusBar"))
        #expect(!content.contains("statusBar" + "\n        HStack"))
    }

    @Test("structured source and canonical lifecycle projections stay bounded")
    func sourceAndLifecycleContracts() throws {
        let inspector = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/ChatInspectorView.swift"
        )
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )

        #expect(inspector.contains("init(entry: ContextManifest.Entry)"))
        #expect(content.contains("ChatInspectorSourceItem(entry:"))
        #expect(inspector.contains("TaskCenterObservationSnapshot") || content.contains("taskCenterObservation"))
        #expect(inspector.contains("ConversationEventDisplayProjection"))
        #expect(!inspector.contains("scanDirectory"))
        #expect(!inspector.contains("contentsOfDirectory"))
        #expect(content.contains("contextManifestStore.manifest(runID:"))
        #expect(content.contains("conversationEventProjection.events"))
        #expect(content.contains("taskCenterControlConsumer.receiptRows"))
    }

    @Test("existing A7-A adaptive and overlay contracts remain consumed")
    func adaptiveContractsRemain() throws {
        let content = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
        )
        for required in [
            "AdaptiveLayoutPolicy.decision(",
            "rightIsOverlay",
            "contextPanelWidthDragHandle",
            "statusBar",
            "MainPane(rawValue: storedMainPaneRawValue) ?? .chat"
        ] {
            #expect(content.contains(required), "Missing preserved A7-A contract: \(required)")
        }
    }
    @Test("Ordinary context summary rejects another session, turn, drifted revision, foreign scope and missing record",
          arguments: ["foreign-session", "old-turn", "revision-drift", "foreign-scope", "missing",
                      "zero-foreign-session", "zero-foreign-scope", "zero-missing"])
    func ordinaryContextSummaryRejectsMismatchedFacts728(fault: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-inspector728-\(UUID().uuidString)")
        let file = root.appendingPathComponent("contexts.json")
        let store = try ContextManifestStore(persistenceURL: file)
        let session = "context-inspector-A"
        let targetTurnID = fault.hasPrefix("zero-") ? 0 : 3
        let snapshot = ConversationContextSnapshotV1(
            sessionID: (fault == "foreign-session" || fault == "zero-foreign-session") ? "context-inspector-B" : session,
            providerID: "synthetic", modelID: "model-v1", configurationFingerprint: "revision-v1",
            skillIdentifiers: [], conversationID: (fault == "foreign-session" || fault == "zero-foreign-session") ? "context-inspector-B" : session)
        let scope: AgentExecutionScopeIdentity? = (fault == "foreign-scope" || fault == "zero-foreign-scope") ? AgentExecutionScopeIdentity(
            sessionID: "context-inspector-B", workspaceID: "owned-workspace", memoryScopeID: "owned-memory",
            skillsScopeID: "owned-skills", permissionsScopeID: "owned-permissions",
            taskID: "owned-task", budgetScopeID: "owned-budget") : nil
        var manifest = ContextManifest(snapshot: snapshot, entries: [], scopeIdentity: scope)
        let receipt = ContextManifestReceipt(runID: "chat:\(session):\(fault == "old-turn" ? 2 : targetTurnID)",
                                             requestedBudget: 13, usedBudget: 0, droppedEntryIDs: [])
        if fault == "revision-drift" {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            var encodedSnapshot = try #require(json["snapshot"] as? [String: Any])
            encodedSnapshot["configurationFingerprint"] = "revision-v2-with-old-snapshot-identity"
            json["snapshot"] = encodedSnapshot
            manifest = try JSONDecoder().decode(ContextManifest.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(throws: ContextManifestStoreError.invalidManifest) {
                _ = try store.record(manifest: manifest, receipt: receipt)
            }
        } else if fault != "missing" && fault != "zero-missing" {
            _ = try store.record(manifest: manifest, receipt: receipt)
            if let scope {
                #expect(throws: ContextManifestStoreError.scopeMismatch) {
                    try store.validate(manifest: manifest, for: scope)
                }
            }
        }
        #expect(ChatInspectorContextConsumer.capture(store: store, sessionID: session, turnID: targetTurnID) == nil)
        let reopened = try ContextManifestStore(persistenceURL: file)
        #expect(ChatInspectorContextConsumer.capture(store: reopened, sessionID: session, turnID: targetTurnID) == nil)
        #expect(ChatInspectorContextConsumer.capture(store: reopened, sessionID: nil, turnID: targetTurnID) == nil)
        #expect(ChatInspectorContextConsumer.capture(store: reopened, sessionID: session, turnID: nil) == nil)
        #expect(ChatInspectorContextConsumer.capture(store: reopened, sessionID: session, turnID: -1) == nil)
    }

    @Test("Context summary reload preserves frozen revision and budget rather than later selected facts",
          arguments: [0, 3])
    func ordinaryContextSummaryReloadKeepsFrozenFacts728(turnID: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-inspector728-\(UUID().uuidString)")
        let file = root.appendingPathComponent("contexts.json")
        let store = try ContextManifestStore(persistenceURL: file)
        let session = "context-inspector-A"
        let entry = ContextManifest.Entry(identifier: "system-prompt", tokenCost: 2, level: .l1,
                                         scope: "conversation", provenance: "chat.system",
                                         contentHash: ContextItem.hash(content: "synthetic", identifier: "system-prompt"), required: true)
        let first = ContextManifest(snapshot: ConversationContextSnapshotV1(
            sessionID: session, providerID: "provider-v1", modelID: "model-v1", configurationFingerprint: "revision-v1",
            skillIdentifiers: [], conversationID: session), entries: [entry])
        let firstReceipt = ContextManifestReceipt(runID: "chat:\(session):\(turnID)", requestedBudget: 13, usedBudget: 2, droppedEntryIDs: [])
        _ = try store.record(manifest: first, receipt: firstReceipt)
        let frozen = try #require(ChatInspectorContextConsumer.capture(store: store, sessionID: session, turnID: turnID))
        let next = ContextManifest(snapshot: ConversationContextSnapshotV1(
            sessionID: session, providerID: "provider-v2", modelID: "model-v2", configurationFingerprint: "revision-v2",
            skillIdentifiers: [], conversationID: session), entries: [entry])
        let nextReceipt = ContextManifestReceipt(runID: "chat:\(session):\(turnID + 1)", requestedBudget: 5, usedBudget: 2, droppedEntryIDs: ["optional-item"])
        _ = try store.record(manifest: next, receipt: nextReceipt)
        let reopened = try ContextManifestStore(persistenceURL: file)
        let oldSummary = try #require(ChatInspectorContextConsumer.capture(store: reopened, sessionID: session, turnID: turnID))
        let nextSummary = try #require(ChatInspectorContextConsumer.capture(store: reopened, sessionID: session, turnID: turnID + 1))
        #expect(oldSummary == frozen)
        #expect(oldSummary.snapshot == first.snapshot && oldSummary.receipt == firstReceipt)
        #expect(nextSummary.snapshot == next.snapshot && nextSummary.receipt == nextReceipt)
        #expect(oldSummary.entries == [entry] && nextSummary.entries == [entry])
        let source = ChatInspectorSourceItem(entry: entry)
        #expect(source.identifier == entry.identifier && source.provenance == entry.provenance)
        #expect(source.level == .l1 && source.scope == "conversation" && source.tokenCost == 2 && source.required)
    }

}
