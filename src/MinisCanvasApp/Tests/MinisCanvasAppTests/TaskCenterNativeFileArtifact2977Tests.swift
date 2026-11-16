import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Original 9c TASK12 file consumer, isolated from the already registered Task08 suite.
@Suite("Task Center native file artifact 2977")
@MainActor
struct TaskCenterNativeFileArtifact2977Tests {
    @Test("TASK12 真实文件预览打开返回保留原任务行、过滤和父草稿", arguments: [false, true])
    func canonicalFileArtifactPressReturnPreservesOrigin2977(archived: Bool) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "task-file-return2977", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let root = profile.rootDirectory
        let requestedProject = root.appendingPathComponent("native-selected-project", isDirectory: true)
        try FileManager.default.createDirectory(at: requestedProject, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let project = requestedProject.resolvingSymlinksInPath().standardizedFileURL
        let tasksURL = root.appendingPathComponent("tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: tasksURL)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let sourceID = UUID(), activeID = UUID()
        _ = try sessions.createSession(id: sourceID.uuidString, title: "来源2977")
        _ = try sessions.createSession(id: activeID.uuidString, title: "原父视图2977")
        try sessions.saveMessage(.init(role: .user, content: "合成来源2977"), sessionID: sourceID.uuidString)
        try sessions.saveMessage(.init(role: .assistant, content: "原父历史2977"), sessionID: activeID.uuidString)
        let bridge = BridgeStore(preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager(),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            sessionStore: sessions, canvasRuntimeState: .disabled, agentTaskStore: tasks,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled).value
        let handler = try #require(bridge.productionProjectSessionHandler)
        let executor = try #require(bridge.productionBuiltinToolExecutor)
        let ledger = try #require(bridge.productionFileChangeLedger)
        #expect(!ledger.artifactPersistenceUnavailable)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let facts = engine.toolExecutionFactLedger
        let consumer = bridge.taskCenterControlConsumer
        let attached = try #require(bridge.chat.sessionStore)
        #expect(attached === sessions)
        #expect(consumer.sharesChildTranscriptSessionStore(attached))
        #expect(executor.fileChangeLedger === ledger)
        let projectID = try handler.authorizeFolderFromNativePicker(project)
        #expect(bridge.chat.applySwitchSession(id: activeID))
        bridge.chat.draftText = "原父未发送草稿2977"
        let parentMessages = bridge.chat.messages
        let originalSource = try #require(attached.loadSession(id: sourceID.uuidString))
        let originalParent = try #require(attached.loadSession(id: activeID.uuidString))
        let source = ParentRuntimeIdentity(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, turnID: "source-turn2977",
            taskID: "parent2977", actorID: "owned2977")
        let creation = SessionActionCreationMetadata(scopeID: "scope2977", idempotencyKey: "create2977",
            action: .new(title: "文件任务2977", projectID: projectID,
                         workingDirectory: project.path, source: source))
        let task = try tasks.enqueueIdempotent(taskID: "task2977", parentID: source.taskID,
            providerID: "offline", modelID: "synthetic", creation: creation).snapshot
        let run = try tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "run2977")
        let output = project.appendingPathComponent("output2977.txt")
        let receipt = try await Self.produceTaskFile2977(root: root, ledger: ledger, facts: facts,
            tasks: tasks, source: source, task: task, run: run, projectID: projectID,
            project: project, output: output)
        _ = try facts.settle(receipt, status: .succeeded)
        _ = try tasks.settleChildResult(.init(taskID: task.taskID, runID: run.runID,
            attemptID: "\(run.runID):attempt:1", parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "child2977", outcome: .succeeded, outputDigest: "digest2977",
            idempotencyKey: "result2977", output: "真实文件产物2977"))
        if archived {
            _ = try consumer.applyArchive(.init(taskID: task.taskID, parentID: task.parentID,
                actorID: "owned2977", idempotencyKey: "archive2977", action: .archive))
        }
        let row = try #require(consumer.filteredReceiptRows(.init(includeArchived: true))
            .first { $0.taskID == task.taskID })
        #expect(row.isArchived == archived)
        let navigation = try #require(consumer.fileArtifactNavigations(for: row).first)
        #expect(navigation.producerReceiptID == receipt.receiptID)
        #expect(consumer.fileArtifactPresentationAuthorized(navigation: navigation, target: output))
        let originalTask = tasks.snapshot(taskID: task.taskID, parentID: task.parentID)
        let originalReceipt = try #require(tasks.receipt(runID: run.runID))
        let originalEvents = tasks.events(runID: run.runID)
        let originalFile = try Data(contentsOf: output)
        #expect(originalFile == Data("合成生产文件2977".utf8))

        let host = makeHost(TaskCenterObservationView(bridge: bridge))
        defer { closeHost(host) }
        func waitAX2977(_ identifier: String) async throws -> AnyObject? {
            for _ in 0..<100 {
                pumpAXRunLoop()
                if host.window.isVisible, host.window.isKeyWindow, NSApplication.shared.isActive,
                   let object = findAX(host.window, identifier: identifier) { return object }
                try await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let linkID = (archived ? "archived-file-link-" : "task-file-link-") + navigation.id
        if archived {
            // Change the real filter through its actual AX control. The task
            // has no row until this non-default filter is selected.
            #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: host.window, prefix: linkID) == true)
            let archiveToggle = try #require(try await waitAX2977("task-center-filter-archived"))
            #expect(axPress(archiveToggle))
        } else {
            let history = try #require(try await waitAX2977("tasks-history-toggle"))
            #expect(axPress(history))
        }
        let link = try #require(try await waitAX2977(linkID))
        let originalFrame = try #require(NativeConsumerOwnedAX.frame(link)
            ?? (link as? NSAccessibilityProtocol)?.accessibilityFrame())
        let statusFilter = try #require(try await waitAX2977("task-center-filter-status"))
        let sourceFilter = try #require(try await waitAX2977("task-center-filter-source"))
        let statusLabel = try #require(axLabel(statusFilter))
        let sourceLabel = try #require(axLabel(sourceFilter))
        #expect(axPress(link))
        _ = try #require(try await waitAX2977("task-file-view"))
        var displayedBytes: AnyObject?
        for _ in 0..<100 {
            pumpAXRunLoop()
            displayedBytes = NativeConsumerOwnedAX.findDisplayedText(in: host.window, exactText: "合成生产文件2977")
            if displayedBytes != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try #require(displayedBytes, "必须由真实文件页面读取并显示 builtin 生产的字节")
        let back = try #require(try await waitAX2977("task-file-return"))
        #expect(axPress(back))
        let returnedLink = try #require(try await waitAX2977(linkID))
        let returnedFrame = try #require(NativeConsumerOwnedAX.frame(returnedLink)
            ?? (returnedLink as? NSAccessibilityProtocol)?.accessibilityFrame())
        #expect(abs(returnedFrame.minY - originalFrame.minY) <= 1)
        #expect(axLabel(try #require(try await waitAX2977("task-center-filter-status"))) == statusLabel)
        #expect(axLabel(try #require(try await waitAX2977("task-center-filter-source"))) == sourceLabel)
        if !archived {
            #expect(axValue(try #require(try await waitAX2977("tasks-history-toggle"))) == "已展开")
        }
        #expect(consumer.filteredReceiptRows(.init(includeArchived: true))
            .first { $0.taskID == task.taskID }?.isArchived == archived)
        #expect(bridge.chat.activeSessionID == activeID)
        #expect(bridge.chat.draftText == "原父未发送草稿2977")
        #expect(bridge.chat.messages == parentMessages && !bridge.chat.isStreaming)
        #expect(attached.loadSession(id: sourceID.uuidString) == originalSource)
        #expect(attached.loadSession(id: activeID.uuidString) == originalParent)
        #expect(tasks.snapshot(taskID: task.taskID, parentID: task.parentID) == originalTask)
        #expect(tasks.receipt(runID: run.runID) == originalReceipt)
        #expect(tasks.events(runID: run.runID) == originalEvents)
        #expect(try Data(contentsOf: output) == originalFile)
        let reopened = try AgentTaskStore(persistenceURL: tasksURL)
        #expect(reopened.receipt(runID: run.runID) == originalReceipt)
        #expect(reopened.events(runID: run.runID) == originalEvents)
    }

    // Reuse the Bridge's file ledger and canonical fact producer. The scoped
    // executor is created inside this nonisolated worker, as in the 342 fixture.
    nonisolated private static func produceTaskFile2977(root: URL, ledger: FileChangeLedger,
        facts: ToolExecutionFactLedger, tasks: AgentTaskStore, source: ParentRuntimeIdentity,
        task: AgentTaskSnapshot, run: AgentRunSnapshot, projectID: String,
        project: URL, output: URL) async throws -> ToolExecutionReceipt {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        do {
            let producer = "producer2977"
            let parent = try ParentRuntimeIdentitySeed(sessionID: producer, conversationID: producer,
                taskID: task.taskID, actorID: "owned2977").makeIdentity(using: handle)
            let context = AgentExecutionContextSnapshot(provider: TaskCenterFile2977UnusedProvider(),
                approvalGate: nil, turnController: controller, currentConversationID: producer,
                makeChildBudget: nil, deadline: nil, taskStore: tasks,
                parentTurnHandle: handle, parentRuntimeIdentity: parent)
            let identity = AgentExecutionIdentity(turn: .init(sessionID: producer,
                turnID: handle.turnID, messageID: "message2977"), operationID: run.runID, attempt: 1)
            let origin = try #require(try BuiltinToolExecutor.captureTargetTaskOrigin(
                context: context, executionIdentity: identity))
            let receipt = try facts.mint(toolCallID: "write2977", toolName: "file_write",
                attemptID: "tool-attempt2977", attemptNumber: 1, executionIdentity: identity,
                targetTaskBinding: origin.binding, targetTaskSource: origin.source)
            let binding = TargetWorkspaceBinding(source: source, targetSessionID: producer,
                taskID: task.taskID, runID: run.runID, projectID: projectID, workingDirectory: project.path)
            let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            executor.fileChangeLedger = ledger
            _ = try await AgentExecutionContext.$current.withValue(context) {
                try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                    try await executor.executeInTargetWorkspace(name: "file_write",
                        input: ["path": output.path, "content": "合成生产文件2977"], binding: binding)
                }
            }
            await handle.finish()
            return receipt
        } catch {
            await handle.finish()
            throw error
        }
    }

}

@MainActor
private func makeHost<V: View>(_ rootView: V) -> (window: NSWindow, view: NSView) {
    let hostLease = NativeTestHostLifecycle.begin("TaskCenter")
    let controller = NSHostingController(rootView: AnyView(rootView))
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    NativeTestHostLifecycle.bind(hostLease, to: window)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 900, height: 700))
    let view = controller.view
    view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    window.orderFrontRegardless()
    _ = NSRunningApplication.current.activate(options: [])
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.display()
    pumpAXRunLoop()
    NativeTestHostLifecycle.observe(window, phase: "sampled")
    return (window, view)
}

@MainActor
private func closeHost(_ host: (window: NSWindow, view: NSView)) {
    host.window.orderOut(nil)
    host.window.contentViewController = nil
    host.window.close()
    NativeTestHostLifecycle.end(host.window)
}

private enum TaskCenterFile2977Error: Error { case unexpectedProvider }
private struct TaskCenterFile2977UnusedProvider: LLMProvider, Sendable {
    let name = "offline2977"
    var model = LLMModel(id: "synthetic2977", displayName: "Synthetic", provider: "offline2977")
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        throw TaskCenterFile2977Error.unexpectedProvider
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw TaskCenterFile2977Error.unexpectedProvider
    }
}
