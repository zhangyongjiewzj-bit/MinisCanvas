import Foundation
import Testing
import MinisCore
import CanvasCore
@testable import MinisCanvasApp

@Suite("D-CONC2 N3C0013 command results retain their initiating session", .serialized)
@MainActor
struct CommandLateSessionN3C0013Tests {
    enum Outcome: CaseIterable, Sendable { case success, commandError, otherError }
    private enum BoundaryError: Error { case syntheticFailure }

    // This is the command's asynchronous boundary, not a replacement runner.
    // No sleeps or scheduler timing assumptions determine the interleaving.
    private actor CommandBoundary {
        private var started = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func suspend() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                started = true
                startedWaiter?.resume()
                startedWaiter = nil
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiter = $0 }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }

    @Test("switching sessions during a registered command cannot redirect its late response",
          arguments: Outcome.allCases)
    func lateResponseBelongsToInitiatingSession(_ outcome: Outcome) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("conc2-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "conc2-command-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions,
            canvasFactory: { _ in preconditionFailure("Canvas is outside this regression") },
            canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: bridge.sessionBadgeStore))
        let origin = try #require(bridge.chat.activeSessionID)
        bridge.chat.newSession()
        let destination = try #require(bridge.chat.activeSessionID)
        #expect(origin != destination)
        bridge.chat.switchSession(id: origin)
        let originBefore = try #require(bridge.chat.messages(forSession: origin))
        let destinationBefore = try #require(bridge.chat.messages(forSession: destination))
        let boundary = CommandBoundary()
        let id = "conc2.synthetic.delayed"
        bridge.commandRegistry.register(CommandDefinition(id: id, title: "Owned delayed command", category: .session) { _ in
            await boundary.suspend()
            switch outcome {
            case .success: return .success("N3C0013 owned late response")
            case .commandError: throw CommandExecutionError.unknownCommand("N3C0013-owned")
            case .otherError: throw BoundaryError.syntheticFailure
            }
        })
        let sequence = bridge.commandTaskRegistrationSequence
        bridge.runCommand(id: id)
        await boundary.waitUntilStarted()
        // Capture the real retained product Task before any throwing validation.
        let tasks = bridge.commandTaskSnapshot(after: sequence) ?? []
        bridge.chat.switchSession(id: destination)
        await boundary.release()
        for task in tasks { await task.value }
        #expect(tasks.count == 1)
        #expect(!bridge.hasUnfinishedOwnedCommandTasks)
        #expect(bridge.chat.activeSessionID == destination)
        let originAfter = try #require(bridge.chat.messages(forSession: origin))
        let destinationAfter = try #require(bridge.chat.messages(forSession: destination))
        #expect(destinationAfter == destinationBefore)
        #expect(originAfter.count == originBefore.count + 1)
        #expect(Array(originAfter.prefix(originBefore.count)) == originBefore)
        let response = try #require(originAfter.last)
        #expect(response.role == .assistant)
        switch outcome {
        case .success: #expect(response.content == "N3C0013 owned late response")
        case .commandError: #expect(response.content == "⚠️ 未知命令：N3C0013-owned")
        case .otherError: #expect(response.content.hasPrefix("⚠️ 命令执行失败："))
        }
    }

    enum CanvasScenario: CaseIterable, Sendable {
        case commandApproval, recoverDraft, importNovel
    }

    // The public approval boundary is delayed, while all Bridge/Chat/Canvas
    // dispatch, authorization and session storage remain the real product.
    private actor DelayedApproval: ApprovalDelegate {
        let approvalsBeforePause: Int
        private var calls = 0
        private var paused = false
        private var finished = false
        private var stateWaiter: CheckedContinuation<Bool, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        init(approvalsBeforePause: Int) { self.approvalsBeforePause = approvalsBeforePause }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            calls += 1
            if calls <= approvalsBeforePause {
                return ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                paused = true
                stateWaiter?.resume(returning: true)
                stateWaiter = nil
            }
            return .deny
        }
        func waitUntilPausedOrFinished() async -> Bool {
            if paused { return true }
            if finished { return false }
            return await withCheckedContinuation { stateWaiter = $0 }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
        func productFinished() {
            finished = true
            if !paused { stateWaiter?.resume(returning: false); stateWaiter = nil }
        }
        func callCount() -> Int { calls }
    }

    @Test("Canvas legacy consumers retain the initiating transcript across approval suspension",
          arguments: CanvasScenario.allCases)
    func canvasLateReceiptBelongsToInitiatingSession(_ scenario: CanvasScenario) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("conc2-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "conc2-canvas-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let canvas = CanvasStore(preferencesDefaults: defaults)
        var drafts: DraftStore?
        if scenario == .recoverDraft {
            _ = try #require(canvas.addNode(ofType: ManjuNodeType.novelImport.rawValue))
            let store = DraftStore(directory: root.appendingPathComponent("canvas-drafts"))
            store.scheduleSave(key: DraftStore.canvasKey,
                payload: try JSONEncoder().encode(CanvasDraft(graph: canvas.graph, savedAt: Date())))
            #expect(store.flushAll())
            canvas.attachDraftStore(store)
            _ = try #require(canvas.recoverableCanvasDraft())
            drafts = store
        }
        defer { drafts?.cancelPending(key: DraftStore.canvasKey) }
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, canvas: canvas,
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("contexts.json")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            allowsLegacyCanvasCommandExecutionForTests: true, canvasFeatureLane: .phase4OptIn)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: bridge.sessionBadgeStore))
        let origin = try #require(bridge.chat.activeSessionID)
        bridge.chat.newSession()
        let destination = try #require(bridge.chat.activeSessionID)
        #expect(origin != destination)
        bridge.chat.switchSession(id: origin)
        // Import has an outer command approval and then the actual mutation
        // approval. Pause the latter so finishImportNovel handles the denial.
        let approval = DelayedApproval(approvalsBeforePause: scenario == .importNovel ? 1 : 0)
        var settings = AgentSettings.default
        settings.approvalPolicy = .alwaysAsk
        await bridge.attachProductionServices(agentSettings: settings,
            fileAccessAllowedRoot: root, sessionDirectory: sessions.directory,
            approvalDelegateOverride: approval, enableOrchestration: false,
            externalRunners: [:], externalNetworkAllowed: false).value
        if let drafts {
            // Production attachment installs its ordinary draft root. Rebind
            // only this existing public fixture seam to the owned saved draft.
            canvas.attachDraftStore(drafts)
            _ = try #require(canvas.recoverableCanvasDraft())
        }
        let originBefore = try #require(bridge.chat.messages(forSession: origin))
        let destinationBefore = try #require(bridge.chat.messages(forSession: destination))
        if scenario == .recoverDraft {
            bridge.handleRecoverCanvasDraft()
        } else {
            let input = ComposerToolInput(values: ["command": .string("owned canvas request")])
            let facts = bridge.chat.composerPolicyFacts
            #expect(facts.knownCapabilities.contains("canvas_mutation"))
            let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
                effort: .standard, sessionID: origin.uuidString, turnID: 1,
                taskID: "conc2-canvas-\(UUID().uuidString)", attemptID: UUID().uuidString,
                messageID: UUID().uuidString, inputDigest: input.digest,
                workspaceID: bridge.chat.composerWorkspaceID, createdAt: Date(),
                policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
                autonomyCeiling: facts.autonomyCeiling)
            let command = scenario == .importNovel ? "导入小说 N3C0013 owned novel" : "重置"
            #expect(bridge.chat.onSendCommand?(command, snapshot) == true)
        }
        let productTask = try #require(bridge.lastCanvasMutationTask)
        let completion = Task { await productTask.value; await approval.productFinished() }
        let paused = await approval.waitUntilPausedOrFinished()
        if paused { bridge.chat.switchSession(id: destination) }
        await approval.release()
        await productTask.value
        await completion.value
        #expect(paused, "The real product must reach the declared approval boundary")
        #expect(await approval.callCount() == (scenario == .importNovel ? 2 : 1))
        #expect(bridge.chat.activeSessionID == destination)
        let originAfter = try #require(bridge.chat.messages(forSession: origin))
        let destinationAfter = try #require(bridge.chat.messages(forSession: destination))
        #expect(destinationAfter == destinationBefore)
        #expect(originAfter.count == originBefore.count + 1)
        #expect(Array(originAfter.prefix(originBefore.count)) == originBefore)
        let response = try #require(originAfter.last)
        #expect(response.role == .assistant)
        switch scenario {
        case .commandApproval: #expect(response.content.hasPrefix("⚠️ Composer 已拒绝画布操作："))
        case .recoverDraft: #expect(response.content.hasPrefix("❌ 草稿恢复已拒绝："))
        case .importNovel: #expect(response.content == "❌ 导入失败：无法创建小说节点。")
        }
    }
}
