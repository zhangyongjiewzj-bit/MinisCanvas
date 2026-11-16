import AppKit
import ApplicationServices
import Foundation
import Darwin
import os
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center native accessibility consumer")
@MainActor
struct TaskCenterNativeAccessibilityConsumerTests {
    private func ownedSettings(root: URL, sessions: SessionStore) throws -> SettingsCenter {
        let defaults = try #require(UserDefaults(suiteName: "task-center-settings-\(UUID().uuidString)"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("settings-env"),
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("settings-memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("settings-memory-files")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("settings-badges")),
            logManager: LogManager(directory: root.appendingPathComponent("settings-logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("settings-mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("task-center-settings-usage-\(UUID().uuidString)")),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("settings-readiness")))
    }


    @Test("入口和关闭动作由真实原生 AX button 暴露")
    func entryAndCloseAreNativeButtons() async throws {
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        let entryHost = makeHost(ContentView(bridge: bridge))
        defer { closeHost(entryHost) }

        let entry = try #require(findAX(entryHost.window, identifier: "open-task-center"))
        #expect(axRole(entry) == .button)
        #expect(axEnabled(entry))
        #expect(axLabel(entry) == "打开任务中心")
        #expect(axValue(entry) == "任务中心未打开")
        let commandMarker = bridge.commandTaskRegistrationSequence
        #expect(axPress(entry))
        let commandTasks = try #require(bridge.commandTaskSnapshot(after: commandMarker))
        try #require(commandTasks.count == 1)
        for commandTask in commandTasks { await commandTask.value }
        // Public press success alone is not an open/close consumer result.
        // Observe the real sheet owned by the entry host, then dismiss that sheet.
        var opened: AnyObject?
        for _ in 0..<12 {
            pumpAXRunLoop()
            opened = findAX(entryHost.window, identifier: "task-center-observation")
            if opened != nil { break }
        }
        _ = try #require(opened, "按压入口后必须出现真实任务中心表面")
        let presentedClose = try #require(findAX(entryHost.window, identifier: "task-center-close"))
        #expect(axPress(presentedClose))
        var dismissed: Bool?
        for _ in 0..<12 {
            pumpAXRunLoop()
            dismissed = NativeConsumerOwnedAX.hasNoIdentifier(
                in: entryHost.window, prefix: "task-center-observation"
            )
            if dismissed == true { break }
        }
        let absence561_1 = dismissed == true
        try #require(absence561_1, "关闭后必须仍可完整读取宿主 AX 树")
        #expect(absence561_1)
        var openerFocused = false
        for _ in 0..<12 {
            pumpAXRunLoop()
            if let opener = findAX(entryHost.window, identifier: "open-task-center") {
                openerFocused = axFocused(opener)
            }
            if openerFocused { break }
        }
        #expect(openerFocused, "关闭真实 sheet 后，焦点必须回到原工具栏入口")

        let closeHarness = makeHost(TaskCenterObservationView(bridge: bridge))
        defer { closeHost(closeHarness) }
        let close = try #require(findAX(closeHarness.window, identifier: "task-center-close"))
        #expect(axRole(close) == .button)
        #expect(axEnabled(close))
        #expect(axLabel(close) == "关闭任务中心")
        #expect(axValue(close) == "返回当前窗口")
        #expect(axPress(close))
    }

    @Test("普通键盘入口关闭后恢复原窗口的真实 firstResponder")
    func responderOpenerReturnsAfterDismissal() throws {
        let host = makeHost(EmptyView())
        defer { closeHost(host) }
        let editor = NSTextField(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
        host.view.addSubview(editor)
        func originalEditorIsActive() -> Bool {
            guard editor.window === host.window,
                  let fieldEditor = editor.currentEditor(),
                  fieldEditor.isFieldEditor, fieldEditor.window === host.window,
                  let current = host.window.firstResponder else { return false }
            return current === fieldEditor
        }
        try #require(host.window.makeFirstResponder(editor))
        try #require(originalEditorIsActive())
        let focusReturn = TaskCenterOpenerFocus()
        let ownerMatches = focusReturn.capture(toolbarOpener: false, window: host.window)
        #expect(ownerMatches == 1)
        try #require(host.window.makeFirstResponder(nil))
        #expect(!originalEditorIsActive())

        #expect(focusReturn.restore() == .responder)
        #expect(originalEditorIsActive())
    }

    @Test("TASK12 canonical 来源与结果经真实 AX 打开返回，保留历史展开和父草稿")
    func canonicalSourceAndResultPressReturnPreserveOrigin2511() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task2511-native-\(UUID().uuidString)", isDirectory: true)
        let suite = "task2511-native-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let sourceID = UUID(), activeID = UUID()
        _ = try sessions.createSession(id: sourceID.uuidString, title: "来源2511")
        _ = try sessions.createSession(id: activeID.uuidString, title: "原父视图2511")
        try sessions.saveMessage(.init(role: .user, content: "TASK2511 synthetic source request"),
            sessionID: sourceID.uuidString)
        try sessions.saveMessage(.init(role: .assistant, content: "TASK2511 original parent history"),
            sessionID: activeID.uuidString)
        let taskURL = root.appendingPathComponent("tasks.json")
        let tasks = try AgentTaskStore(persistenceURL: taskURL)
        let source = ParentRuntimeIdentity(sessionID: sourceID.uuidString,
            conversationID: sourceID.uuidString, turnID: "turn2511",
            taskID: "parent2511", actorID: "native2511")
        _ = try AgentTaskCreationConsumer(store: tasks, knownProjectIDs: ["project2511"],
            authorizedScopeIDs: ["scope2511"]).consume(.init(taskID: "task2511",
                parentID: "parent2511", source: source, title: "持久任务2511",
                projectID: "project2511", scopeID: "scope2511", idempotencyKey: "create2511"))
        let run = try tasks.startRun(taskID: "task2511", parentID: "parent2511", runID: "run2511")
        let attemptID = try #require(tasks.canonicalAttemptID(runID: run.runID))
        _ = try tasks.settleChildResult(.init(taskID: "task2511", runID: run.runID,
            attemptID: attemptID, parentContextSnapshotID: nil,
            childExecutionID: "execution2511", outcome: .succeeded,
            outputDigest: "synthetic-result2511", evidenceRefs: [], output: "TASK2511 canonical result"))

        let bridge = BridgeStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionStore: sessions, canvasRuntimeState: .disabled, agentTaskStore: tasks,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")))
        // Persistence bootstrap is one-shot; qualify this exact store before production attachment.
        #expect(bridge.chat.attachPersistence(sessions))
        await bridge.attachProductionServices(fileAccessAllowedRoot: root,
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))).value
        #expect(bridge.chat.sessionStore === sessions)
        #expect(bridge.taskCenterControlConsumer.sharesChildTranscriptSessionStore(sessions))
        #expect(bridge.chat.applySwitchSession(id: activeID))
        bridge.chat.draftText = "TASK2511 original unsent draft"
        let consumer = bridge.taskCenterControlConsumer
        let row = try #require(consumer.receiptRows().first { $0.taskID == "task2511" })
        let originalReceipt = try #require(tasks.receipt(runID: run.runID))
        let originalEvents = tasks.events(runID: run.runID)
        let originalParent = try #require(sessions.loadSession(id: activeID.uuidString))
        let originalSource = try #require(sessions.loadSession(id: sourceID.uuidString))
        let host = makeHost(TaskCenterObservationView(bridge: bridge))
        defer { closeHost(host) }
        func waitAX(_ identifier: String) async -> AnyObject? {
            for _ in 0..<32 {
                pumpAXRunLoop()
                // NavigationLink work must resume on MainActor between the original AX samples.
                await Task.yield()
                if let object = findAX(host.window, identifier: identifier) { return object }
            }
            return nil
        }
        let historyToggle = try #require(await waitAX("tasks-history-toggle"))
        #expect(axPress(historyToggle))
        let sourceLinkID = "source-session-link-" + row.stableID
        let sourceLink = try #require(await waitAX(sourceLinkID))
        let sourceFrame = try #require(NativeConsumerOwnedAX.frame(sourceLink)
            ?? (sourceLink as? NSAccessibilityProtocol)?.accessibilityFrame())
        print("TASK2511_SOURCE_LINK_AX_NAME actual=\(axLabel(sourceLink) ?? "UNREADABLE") expected=打开来源会话，返回任务中心")
        #expect(axPress(sourceLink))
        _ = try #require(await waitAX("source-session-view"))
        _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
            exactText: "TASK2511 synthetic source request"))
        // The already-open destination must drop an orphaned live binding.
        // No status setter or synthetic projection replaces the real page.
        consumer.bindChildTranscriptSessionStore(nil)
        // A single run(mode:before:) can return after the first input source.
        // Spend the existing 50ms slice servicing this page's periodic refresh;
        // keep this local so other AX waits retain their original behavior.
        func pumpUnboundSourceRefresh() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        var invalidSource: AnyObject?
        for _ in 0..<32 {
            pumpUnboundSourceRefresh()
            await Task.yield()
            invalidSource = NativeConsumerOwnedAX.findDisplayedText(in: host.window,
                exactText: "来源会话已失效或不可读取；返回任务中心查看当前任务。")
            if invalidSource != nil { break }
        }
        _ = try #require(invalidSource)
        consumer.bindChildTranscriptSessionStore(sessions)
        let sourceReturn = try #require(await waitAX("source-session-return"))
        #expect(axPress(sourceReturn))
        let returnedSource = try #require(await waitAX(sourceLinkID))
        let returnedFrame = try #require(NativeConsumerOwnedAX.frame(returnedSource)
            ?? (returnedSource as? NSAccessibilityProtocol)?.accessibilityFrame())
        #expect(abs(returnedFrame.minY - sourceFrame.minY) <= 1,
                "返回必须保留原任务行在同一历史列表的位置")
        let restoredHistoryToggle = try #require(await waitAX("tasks-history-toggle"))
        #expect(axValue(restoredHistoryToggle) == "已展开")

        let resultLink = try #require(await waitAX("result-detail-link-" + row.stableID))
        print("TASK2511_RESULT_LINK_AX_NAME actual=\(axLabel(resultLink) ?? "UNREADABLE") expected=查看运行结果，返回任务中心")
        #expect(axPress(resultLink))
        _ = try #require(await waitAX("result-detail-view"))
        _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
            exactText: "TASK2511 canonical result"))
        let resultReturn = try #require(await waitAX("result-detail-return"))
        #expect(axPress(resultReturn))
        _ = try #require(await waitAX(sourceLinkID))
        #expect(bridge.chat.activeSessionID == activeID)
        #expect(bridge.chat.draftText == "TASK2511 original unsent draft")
        #expect(!bridge.chat.isStreaming)
        #expect(sessions.loadSession(id: activeID.uuidString) == originalParent)
        #expect(sessions.loadSession(id: sourceID.uuidString) == originalSource)
        #expect(tasks.events(runID: run.runID) == originalEvents)
        #expect(tasks.receipt(runID: run.runID) == originalReceipt)
        let reopened = try AgentTaskStore(persistenceURL: taskURL)
        #expect(reopened.receipt(runID: run.runID) == originalReceipt)
        #expect(reopened.events(runID: run.runID) == originalEvents)
    }

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
                if let object = findAX(host.window, identifier: identifier) { return object }
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

    @Test("原生 AX retry 触发既有 TaskCenter consumer 并保持任务身份")
    func nativeRetryRoutesThroughTaskCenterConsumer() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("native-retry-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let provider = Task05RetryCancelProvider(workspace: workspace,
            taskID: "native-retry-task", title: "重试原任务")
        let bridge = try await TaskCenterRetryProductionFixtureSupport.makeBridge(
            root: root, store: store, provider: provider, runner: Task05RetryCancelRunner())
        let chat = bridge.chat
        let sessions = try #require(chat.sessionStore)
        let settingsOwner = try ownedSettings(root: root, sessions: sessions)
        defer { withExtendedLifetime(settingsOwner) {} }
        var firstTurn: Task<Void, Never>?
        var cleanupOriginalRunID: String?
        var cleanupOriginalParentID: String?
        var businessError: (any Error)?
        var retryParent: ParentRuntimeIdentity?
        var retryExecution: AgentExecutionIdentity?
        var host: (window: NSWindow, view: NSView)?
        do {
            chat.draftText = "owned task05 first request"
            chat.submitComposer()
            firstTurn = chat.turnTaskForTests(sessionID: chat.activeSessionID)
            try #require(firstTurn != nil)
            let firstDeadline = Date().addingTimeInterval(5)
            while Date() < firstDeadline && (chat.isStreaming || provider.childCalls == 0) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(!chat.isStreaming)
            try #require(provider.childCalls == 1)
            await firstTurn?.value
            let previousReceipt = try #require(store.allReceipts().first {
                $0.taskID == "native-retry-task"
            })
            let task = try #require(store.taskSnapshot(runID: previousReceipt.runID))
            let originalRunID = previousReceipt.runID
            cleanupOriginalRunID = originalRunID
            cleanupOriginalParentID = task.parentID
            _ = try #require(store.settledFailedChildLaunchIntent(taskID: task.taskID,
                originalParentID: task.parentID, runID: originalRunID))
            let ownedHost = makeHost(TaskCenterObservationView(bridge: bridge))
            host = ownedHost
            let identifier = "task-center-control-retry-\(task.taskID)"
            let retry = try #require(findAX(ownedHost.window, identifier: identifier))
            #expect(axRole(retry) == .button)
            #expect(axEnabled(retry))
            #expect(axLabel(retry) == "重试任务 重试原任务")
            #expect(axLabel(retry)?.contains(task.taskID) == false)
            #expect(axPress(retry))
            let heldDeadline = Date().addingTimeInterval(5)
            while Date() < heldDeadline && !provider.isHeld {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(provider.isHeld && provider.childCalls == 2)
            let heldRunID = try #require(bridge.taskCenterControlRunID(
                taskID: task.taskID, parentID: task.parentID))
            retryParent = try #require(store.retryRunRuntimeBinding(runID: heldRunID)).parent
            let heldSessionID = try #require(chat.activeSessionID)
            retryExecution = try #require(chat.executionSnapshot(forSessionID: heldSessionID)?.executionIdentity)
            let receipt = try #require(
                bridge.taskCenterControlConsumer.receiptRows(
                    now: Date(timeIntervalSince1970: 1_850_000_000)
                ).first
            )
            let retryRunID = try #require(bridge.taskCenterControlRunID(
                taskID: task.taskID, parentID: task.parentID
            ))
            let retryTask = try #require(store.taskSnapshot(runID: retryRunID))
            let retryAttemptID = try #require(store.canonicalAttemptID(runID: retryRunID))
            let retryAttempt = try #require(store.attempt(runID: retryRunID, attemptID: retryAttemptID))
            #expect(retryRunID != originalRunID)
            #expect(receipt.taskID == task.taskID)
            #expect(receipt.parentID == task.parentID)
            #expect(receipt.runID == retryRunID)
            #expect(receipt.receiptID == retryRunID)
            #expect(receipt.attemptID == retryAttemptID)
            #expect(retryTask.taskID == task.taskID && retryTask.parentID == task.parentID)
            #expect(retryAttempt.runID == retryRunID)
            #expect(retryAttempt.parentContextSnapshotID == task.parentContextSnapshotID)
            #expect(store.receipt(runID: originalRunID) == previousReceipt)
            #expect(previousReceipt.taskID == task.taskID && previousReceipt.runID == originalRunID)
            #expect(previousReceipt.outcome == .failed(reason: "execution-failed"))
            // Keep the real historical-receipt projection contract strict. A new
            // running run is still retrying while the prior terminal receipt remains.
            #expect(receipt.taskState == .retrying)
            #expect(receipt.runState == .retrying)
            #expect(receipt.attemptState == .retrying)
            #expect(receipt.effectState == .retrying)
        } catch {
            businessError = error
        }
        // Cleanup runs after both success and failure. Cancel the real admitted turn,
        // release only the held protocol response, and join the actual child producer.
        chat.stopStreaming()
        let cleanupDeadline = Date().addingTimeInterval(2)
        while Date() < cleanupDeadline && provider.isHeld && !provider.sawCancellation {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
            }
        }
        if provider.isHeld { #expect(provider.sawCancellation) }
        provider.releaseActualResponse()
        await firstTurn?.value
        if let originalRunID = cleanupOriginalRunID, let originalParentID = cleanupOriginalParentID,
           let currentRunID = bridge.taskCenterControlRunID(
                taskID: "native-retry-task", parentID: originalParentID),
           currentRunID != originalRunID {
            let joined = await bridge.joinTaskCenterRetryExecution(runID: currentRunID)
            #expect(joined != nil)
        }
        // The outer UI Task has no handle. Its terminal fact confirms its last durable write,
        // without claiming to join that Task or adding another cleanup budget.
        if let retryParent, let retryExecution {
            while Date() < cleanupDeadline,
                  store.parentTurnTerminalFact(parent: retryParent, execution: retryExecution) == nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
                }
            }
            #expect(store.parentTurnTerminalFact(parent: retryParent, execution: retryExecution) != nil,
                    "retry outer UI Task must finish its last durable write before closing the owned window")
        }
        if let host { closeHost(host) }
        if let businessError { throw businessError }
    }

    @Test("未绑定任务没有可操作控制且原失败回执无副作用")
    func unboundTaskHasNoNativeControlSideEffect() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "native-disabled-task",
            parentID: "native-parent",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "native-disabled-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .failed(reason: "disabled fixture failure"))

        let bridge = BridgeStore(agentTaskStore: store)
        let host = makeHost(TaskCenterObservationView(bridge: bridge))
        defer { closeHost(host) }

        _ = try #require(findAX(host.window, identifier: "task-center-observation"))
        #expect(findAX(
            host.window,
            identifier: "task-center-control-retry-\(task.taskID)"
        ) == nil)
        let absent = NativeConsumerOwnedAX.hasNoIdentifier(
            in: host.window, prefix: "task-center-control-retry-\(task.taskID)"
        ) == true
        try #require(absent, "不可读取宿主 AX 树不等于重试入口不存在")
        #expect(absent)
        let receipt = try #require(
            bridge.taskCenterControlConsumer.receiptRows(
                now: Date(timeIntervalSince1970: 1_850_000_000)
            ).first
        )
        #expect(receipt.taskID == task.taskID)
        #expect(receipt.taskState == .failed)
        #expect(receipt.runID == run.runID)
    }

    private var testGoal: GoalEnvelope {
        GoalEnvelope(
            goalID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            scopeID: "scope:native-task-center",
            allowedCapabilities: ["task.control"],
            budget: 10,
            deadline: Date().addingTimeInterval(3_600),
            createdAt: Date().addingTimeInterval(-60)
        )
    }

    private var testLease: AutonomyLease {
        AutonomyLease(
            leaseID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            goalID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            scopeID: "scope:native-task-center",
            issuedAt: Date().addingTimeInterval(-60),
            expiresAt: Date().addingTimeInterval(3_600)
        )
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
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
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
