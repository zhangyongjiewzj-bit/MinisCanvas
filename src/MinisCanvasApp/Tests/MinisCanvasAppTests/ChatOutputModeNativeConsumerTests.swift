import AppKit
import ApplicationServices
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

// CHAT-11: operate the shipped ChatMainView segmented picker, not a recreated
// Binding. Only the remote model is scripted. Admission, AgentLoop, settings
// persistence and the native transcript remain production consumers.
@Suite("Chat output mode native consumer", .serialized)
@MainActor
struct ChatOutputModeNativeConsumerTests {
    @Test func selectedHeaderPresetReachesTheNextActualRequestAndRenderedReply() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "chat11-picker",
            processEnvironment: [:], processArguments: ["ChatOutputModeNativeConsumerTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        defer { chat.stopAllStreamingForSafety() }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        #expect(chat.attachPersistence(sessions))
        let skills = SkillStore(skillsRoot: profile.hermesSkillsDirectory)
        let keychain = profile.makeKeychainStore()
        let center = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: profile.makeEnvironmentStore(keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory), sessionStore: sessions,
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain))
        center.bindChatOutputMode(to: chat)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "chat11-native", grantEpoch: "chat11-native",
            leaseID: "chat11-native", expiresAt: .distantFuture, autonomyCeiling: .l1)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection.mode = .manual
        let provider = HeaderPresetProvider()
        let snapshot = try ProviderRuntimeSnapshot(providerID: provider.model.provider, modelID: provider.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:chat11-native")
        let route = try ProviderRuntimeRoute(snapshot: snapshot, primary: provider)
        chat.turnRuntimeSnapshotFactory = { turn, box in
            #expect(box.model.id == provider.model.id)
            return .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route,
                requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: profile.rootDirectory),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider

        let lease = NativeTestHostLifecycle.begin("Chat11HeaderPreset")
        let controller = NSHostingController(rootView: ChatMainView(chat: chat, documentStore: nil,
            transcriptEnvStore: center.envStore))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NativeTestHostLifecycle.bind(lease, to: window)
        window.contentViewController = controller
        window.setAccessibilityIdentifier("chat11-header-" + UUID().uuidString)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        NativeTestHostLifecycle.observe(window, phase: "sampled")

        // Deliberately list observable expectations independently of the enum's
        // instruction accessor. The provider uses request text, never chat state.
        let cases: [(ChatOutputMode, String, String?, String)] = [
            (.concise, "简洁", "只输出最终结果与工作状态", "CHAT11_RESULT_ONLY"),
            (.detailed, "详细", "简要、可核验的步骤摘要", "CHAT11_STEPS_AND_RESULT"),
            (.explanatory, "讲解", "关键概念", "CHAT11_CONCEPT_AND_EXAMPLE"),
            (.normal, "默认", nil, "CHAT11_DEFAULT_REPLY")
        ]
        let originalAssistantIDs = Set(chat.messages.filter { $0.role == .assistant }.map(\.id))
        let originalUserCount = chat.messages.filter { $0.role == .user }.count
        var replyIDs: [UUID] = []
        var originalAuthority: ComposerSubmissionSnapshot?
        for (index, item) in cases.enumerated() {
            let segment = try #require(try await waitForSegment(item.1, in: window))
            #expect(NativeConsumerOwnedAX.press(segment))
            pump(window)
            #expect(chat.outputMode == item.0 && center.chatOutputMode == item.0)
            let selected = try #require(try await waitForSegment(item.1, in: window))
            let selectedValue = try #require(NativeConsumerOwnedAX.attribute(selected,
                kAXValueAttribute as CFString) as? NSNumber)
            #expect(selectedValue.intValue == 1)
            #expect(SettingsStore(directory: profile.settingsDirectory).settings.general.chatOutputMode == item.0)

            let session = try #require(chat.activeSessionID)
            chat.draftText = "CHAT11_NATIVE_PICKER_\(index)"
            #expect(await chat.submitComposerAwaitingAdmission())
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            await task.value
            #expect(!chat.isStreaming && provider.requests.count == index + 1)
            let request = try #require(provider.requests.last)
            #expect(request.messages.last(where: { $0.role == .user })?.content == "CHAT11_NATIVE_PICKER_\(index)")
            if let instruction = item.2 {
                #expect(request.system.contains(instruction))
            } else {
                #expect(!request.system.contains("只输出最终结果与工作状态"))
                #expect(!request.system.contains("简要、可核验的步骤摘要"))
                #expect(!request.system.contains("回答风格：讲解"))
            }
            let reply = try #require(chat.messages.last(where: { $0.role == .assistant }))
            #expect(reply.content == item.3)
            #expect(try await waitForRenderedReply(item.3, in: window))
            #expect(chat.messages.filter { $0.role == .user }.count == originalUserCount + index + 1)
            #expect(!originalAssistantIDs.contains(reply.id) && !replyIDs.contains(reply.id))
            replyIDs.append(reply.id)
            let current = try #require(chat.lastComposerSubmissionSnapshot)
            #expect(current.mode == .manual)
            if let originalAuthority {
                #expect(current.policyRevision == originalAuthority.policyRevision)
                #expect(current.approvalScope == originalAuthority.approvalScope)
                #expect(current.workspaceID == originalAuthority.workspaceID)
            } else { originalAuthority = current }
        }
        let durableSessionID = try #require(chat.activeSessionID)
        let durable = try #require(SessionStore(directory: profile.sessionDirectory)
            .loadSession(id: durableSessionID.uuidString))
        #expect(durable.messages.filter { $0.role == .assistant && $0.content.hasPrefix("CHAT11_") }
            .map(\.content) == cases.map { $0.3 })
    }

    private func pump(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private func waitForSegment(_ label: String, in window: NSWindow) async throws -> AnyObject? {
        for _ in 0..<30 {
            pump(window)
            if let segment = NativeConsumerOwnedAX.find(in: window, label: label) { return segment }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func waitForRenderedReply(_ reply: String, in window: NSWindow) async throws -> Bool {
        @MainActor func rendered(_ view: NSView) -> Bool {
            if let text = view as? NSTextView, !text.isEditable, text.string.contains(reply) { return true }
            for child in view.subviews {
                if rendered(child) { return true }
            }
            return false
        }
        for _ in 0..<30 {
            pump(window)
            if let root = window.contentView, rendered(root) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private final class HeaderPresetProvider: LLMProvider, @unchecked Sendable {
    struct Request { let system: String; let messages: [LLMMessage] }
    let name = "chat11-offline"
    var model = LLMModel(id: "chat11-offline", displayName: "Chat11 offline", provider: "chat11-offline")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [Request] = []
    var requests: [Request] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let system = systemPrompt ?? ""
        lock.withLock { captured.append(Request(system: system, messages: messages)) }
        let reply: String
        if system.contains("只输出最终结果与工作状态") { reply = "CHAT11_RESULT_ONLY" }
        else if system.contains("简要、可核验的步骤摘要") { reply = "CHAT11_STEPS_AND_RESULT" }
        else if system.contains("回答风格：讲解") { reply = "CHAT11_CONCEPT_AND_EXAMPLE" }
        else { reply = "CHAT11_DEFAULT_REPLY" }
        return LLMResponse(text: reply, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens,
                              temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}
