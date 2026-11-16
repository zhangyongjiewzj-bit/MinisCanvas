import AppKit
import AVKit
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class Group1TurnFailureCapture {
    var execution: AgentExecutionIdentity?
    var context: String?
}

@Suite("Goal22 shallow production predicates group 1", .serialized)
@MainActor
struct Goal22ShallowProductionPredicateGroup1Tests {
    @Test("SKILL-05 only the requested skill body reaches an ordinary production request")
    func requestedSkillReachesActualAgentLoopWithoutUnrelatedBodies() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("shallow1-skills") { root async throws -> Void in
            let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            await store.waitForInitialLoad()
            _ = try store.importSkill(content: "---\nname: quasar\ndescription: quasar analysis instructions\n---\nSHALLOW1_QUASAR_BODY")
            _ = try store.importSkill(content: "---\nname: nebula\ndescription: nebula diagram instructions\n---\nSHALLOW1_NEBULA_BODY")
            #expect(store.allSkills().count == 2)
            let injector = SkillInjector(store: store)
            let chat = ChatStore()
            defer { chat.stopAllStreamingForSafety() }
            let ownedSessionID = chat.activeSessionID
            let failureCapture = Group1TurnFailureCapture()
            let unobservedFailure = "stage=UNOBSERVED type=UNOBSERVED case=UNOBSERVED"
            let previousFailureObserver = chat.turnFailureObserverForTests
            defer { chat.turnFailureObserverForTests = previousFailureObserver }
            chat.turnFailureObserverForTests = { observation in
                previousFailureObserver?(observation)
                guard let ownedSessionID, let ownedExecution = failureCapture.execution,
                      observation.sessionID == ownedSessionID,
                      observation.executionIdentity == ownedExecution,
                      failureCapture.context == nil else { return }
                failureCapture.context = "stage=\(observation.stage.rawValue) type=\(observation.errorType) case=\(observation.errorCaseName ?? "UNMAPPED")"
            }
            let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
                allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
                revision: "shallow1-skill", grantEpoch: "shallow1-skill", leaseID: "shallow1-skill",
                expiresAt: .distantFuture, autonomyCeiling: .l3)
            chat.configureComposerPolicy(facts)
            chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
                requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
            // Existing external-provider fixture records the actual AgentLoop
            // request; it does not replace the App engine or skill consumer.
            let provider = OETestProvider(probe: OETestProbe(), capabilities: [.tools], acceptsToolRequests: true)
            chat.streamingProviderOverride = provider
            chat.turnRuntimeSnapshotFactory = { turn, _ in
                ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil)
            }
            chat.draftText = "Please use quasar for this analysis."
            chat.submitComposer()
            failureCapture.execution = chat.activeExecutionIdentity(for: ownedSessionID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while chat.isStreaming && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!chat.isStreaming)
            #expect(provider.seenSystemPrompts.count == 1,
                Comment(rawValue: String((failureCapture.context ?? unobservedFailure).prefix(320))))
            #expect(provider.seenToolNames.count == 1 && provider.seenToolNames.first?.isEmpty == false)
            let prompt = try #require(provider.seenSystemPrompts.compactMap { $0 }.last)
            #expect(prompt.contains("SHALLOW1_QUASAR_BODY"))
            #expect(!prompt.contains("SHALLOW1_NEBULA_BODY"))
            #expect(chat.messages.last(where: { $0.role == .assistant })?.content == "子任务完成")
        }
    }

    @Test("TOOL-14 real file execution enters App history while a denied call does not", arguments: [false, true])
    func realApprovalAndBuiltinFeedOnlyExecutedAppHistory(approved: Bool) async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("shallow1-tool-history") { root async throws -> Void in
            let file = root.appendingPathComponent("owned.txt")
            try "SHALLOW1_REAL_FILE".write(to: file, atomically: true, encoding: .utf8)
            let history = ActionHistoryStore()
            let center = ApprovalPromptCenter()
            defer { center.stopGeneration() }
            let executor = RecordingToolExecutor(base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
                onRecorded: { record in Task { @MainActor in history.record(record) } })
            let executorBox = MinisCanvasApp.ToolExecutorBox(value: executor)
            let provider = F18bMockProvider(acceptsToolRequests: true)
            let envelope = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
                "id": "shallow1-read", "name": "file_read", "input": ["path": file.path]
            ]]])
            provider.replyText = String(decoding: envelope, as: UTF8.self)
            let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("tool-facts.json"))
            let loop = AgentLoop(maxIterations: 1,
                approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk],
                    delegate: ApprovalPromptDelegate(center: center)),
                turnController: TurnController(), timeout: 4,
                toolExecutionFactLedger: ledger)
            let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "shallow1-session",
                turnID: 1, messageID: "shallow1-message"), operationID: "shallow1-operation", attempt: 1)
            let tool = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_read" })
            async let result = loop.runOutcome(messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: executorBox.value, tools: [tool], currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                    conversationID: identity.turn.sessionID, taskID: "shallow1-task", actorID: "shallow1-user"),
                executionIdentity: identity)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while center.pendingRequest == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(provider.seenToolNames == [["file_read"]])
            let request = try #require(center.pendingRequest)
            #expect(request.toolName == "file_read" && request.callID == "shallow1-read")
            #expect(history.records.isEmpty && ledger.facts.isEmpty)
            try await Task.sleep(for: .milliseconds(550))
            if approved {
                center.actionsForPresentedRequest().approve()
                if center.awaitingConfirmation {
                    try await Task.sleep(for: .milliseconds(550))
                    center.actionsForPresentedRequest().approve()
                }
            } else {
                center.actionsForPresentedRequest().deny()
            }
            let actual = await result
            if approved {
                let recordedDeadline = ContinuousClock.now.advanced(by: .seconds(4))
                while history.records.isEmpty && ContinuousClock.now < recordedDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(history.records.count == 1)
                let record = try #require(history.latest)
                #expect(record.toolName == "file_read" && record.succeeded)
                #expect(!record.resultSummary.isEmpty)
                #expect(actual.toolExecutionFacts.count == 1)
                #expect(actual.toolExecutionFacts.first?.status == .succeeded)
                #expect(ledger.facts == actual.toolExecutionFacts)
            } else {
                #expect(history.records.isEmpty)
                #expect(actual.toolExecutionFacts.isEmpty && ledger.facts.isEmpty)
                #expect(actual.result == nil)
                #expect(actual.failure?.agentError == .maxIterationsExceeded(1))
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "SHALLOW1_REAL_FILE")
        }
    }

    @Test("CANVAS-16 ordinary attachment selection renders image, video and text without a Canvas", arguments: ["image", "video", "text"])
    func nonCanvasAttachmentSelectionLoadsAndRendersRealFiles(kind: String) async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("shallow1-preview") { root async throws -> Void in
            try #require(NSApplication.shared.isRunning)
            let file: URL
            switch kind {
            case "image":
                file = root.appendingPathComponent("owned.png")
                try ComposerMediaFixtures589.png(color: 0.75).write(to: file)
            case "video":
                file = root.appendingPathComponent("owned.mp4")
                var source = URL(fileURLWithPath: #filePath)
                for _ in 0..<4 { source.deleteLastPathComponent() }
                source.appendPathComponent("MinisCore/Tests/MinisCoreTests/Fixtures/video603-av-caption.mp4")
                try FileManager.default.copyItem(at: source, to: file)
            default:
                file = root.appendingPathComponent("owned.txt")
                try "SHALLOW1_VISIBLE_TEXT".write(to: file, atomically: true, encoding: .utf8)
            }
            let originalBytes = try Data(contentsOf: file)
            let selection = ChatAttachmentPreviewSelection(sessionID: UUID(), url: file)
            let store = FileTreeStore(rootURL: root)
            defer { store.clearChatAttachmentSelection() }
            store.selectAttachment(selection)
            let loadDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while store.preview == nil && ContinuousClock.now < loadDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let preview = try #require(store.preview)
            #expect(store.selectedURL == file && store.canShowPreview(for: selection))
            #expect(preview.error == nil)
            let lease = NativeTestHostLifecycle.begin("Shallow1AttachmentPreview")
            let host = NSHostingView(rootView:
                FilePreviewContents(preview: preview, imageCacheKey: file.path).frame(width: 320, height: 240))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.setAccessibilityIdentifier("shallow1-preview-" + lease.uuidString)
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil); window.contentView = nil; window.close()
                NativeTestHostLifecycle.end(window)
            }
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            if kind == "image" {
                #expect(preview.kind == .image && preview.imageData == originalBytes)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let literalColor = CGColor(red: 0.75, green: 0.2, blue: 0.9, alpha: 1)
                let literalSpace = try #require(literalColor.colorSpace)
                let comparisonSpace = try #require(NSColorSpace(cgColorSpace: literalSpace))
                let pixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                    y: bitmap.pixelsHigh / 2)?.usingColorSpace(comparisonSpace))
                // These components belong to the fixture CGColor literal
                // (Generic RGB), before conversion into the PNG color space.
                #expect(pixel.redComponent > 0.6 && pixel.greenComponent < 0.4 && pixel.blueComponent > 0.7,
                    Comment(rawValue: String("rgb=\(pixel.redComponent),\(pixel.greenComponent),\(pixel.blueComponent) sourceSpace=\(bitmap.colorSpace.localizedName ?? "unknown") sampleSpace=\(pixel.colorSpace.localizedName ?? "unknown") bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)".prefix(320))))
            } else if kind == "video" {
                #expect(preview.kind == .video && preview.videoURL == file)
                var playerView: AVPlayerView?
                let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                repeat {
                    host.layoutSubtreeIfNeeded()
                    var pending: [NSView] = [host]
                    while let view = pending.popLast() {
                        if let player = view as? AVPlayerView { playerView = player; break }
                        pending.append(contentsOf: view.subviews)
                    }
                    if playerView?.player?.currentItem?.status == .readyToPlay { break }
                    try await Task.sleep(for: .milliseconds(20))
                } while ContinuousClock.now < deadline
                let nativePlayer = try #require(playerView)
                #expect(nativePlayer.bounds.width > 0 && nativePlayer.bounds.height > 0)
                #expect((nativePlayer.player?.currentItem?.asset as? AVURLAsset)?.url == file)
                #expect(nativePlayer.player?.currentItem?.status == .readyToPlay)
                nativePlayer.player?.pause()
            } else {
                #expect(preview.kind == .text && preview.text == "SHALLOW1_VISIBLE_TEXT")
                let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                var displayed: AnyObject?
                repeat {
                    displayed = NativeConsumerOwnedAX.findDisplayedText(in: window, exactText: "SHALLOW1_VISIBLE_TEXT")
                    if displayed != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                } while ContinuousClock.now < deadline
                let visibleText = try #require(displayed)
                #expect(NativeConsumerOwnedAX.label(visibleText) == "SHALLOW1_VISIBLE_TEXT")
            }
            #expect(try Data(contentsOf: file) == originalBytes)
        }
    }

}
