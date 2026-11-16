import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Attachment617Gate: @unchecked Sendable {
    enum Failure: Error { case ownedSourceRejected }
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var didReturn = false
    private var mainThread: Bool?
    var entered: Bool { lock.withLock { didEnter } }
    var returned: Bool { lock.withLock { didReturn } }
    var enteredOnMainThread: Bool? { lock.withLock { mainThread } }
    func source(_ url: URL) throws -> any MediaVideoFrameSource {
        lock.withLock { mainThread = Thread.isMainThread; didEnter = true }
        _ = releaseSignal.wait(timeout: .now() + 10)
        lock.withLock { didReturn = true }
        throw Failure.ownedSourceRejected
    }
    func release() { releaseSignal.signal() }
}

private struct Attachment617Provider: LLMProvider {
    let name = "owned617-offline"
    var model = LLMModel(id: "owned617", displayName: "Owned 617", provider: "owned617-offline")
    var capabilities: Set<ProviderCapability> { [.tools] }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "owned617-final", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: "owned617-final", stopReason: "end_turn", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("owned617-final"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@Suite("PERF617 unknown files use the real detached attachment resolver", .serialized)
@MainActor
struct UnknownAttachmentPreprocessing617Tests {
    private func fixture() throws -> (ChatStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment617-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "attachment617-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        return (chat, root)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "owned attachment lifecycle did not reach its observed boundary")
    }
    @Test("unknown reference remains immediately ready without pretending metadata was read",
          arguments: ["bin", "zip", ""])
    func unknownReferenceMetadata(ext: String) async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent(ext.isEmpty ? "owned" : "owned.\(ext)")
        let bytes = Data(repeating: 0, count: 13)
        try bytes.write(to: url)
        let owner = try #require(chat.activeSessionID)
        let history = chat.messages
        let revision = chat.transcriptRevision(forSession: owner)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        #expect(staged.status == .ready)
        #expect(staged.kind == .file && staged.fileType == .unknown)
        #expect(staged.statusText == nil)
        #expect(staged.size == nil && staged.data == nil)
        #expect(staged.mimeType == FileImporter.mimeType(forExtension: ext))
        #expect(chat.pendingAttachments == [staged])
        #expect(chat.canSubmitComposerAttachments)
        try await waitUntil { chat.pendingAttachments.first?.size != nil }
        let resolved = try #require(chat.pendingAttachments.first)
        #expect(resolved.id == staged.id && resolved.fileURL == url.path)
        #expect(resolved.status == .ready && resolved.statusText == nil)
        #expect(resolved.kind == .file && resolved.fileType == .unknown)
        #expect(resolved.data == nil && resolved.size == Int64(bytes.count))
        #expect(resolved.mimeType == staged.mimeType)
        #expect(chat.messages == history && chat.activeSessionID == owner)
        #expect(chat.transcriptRevision(forSession: owner) == revision)
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("a sniffed unknown image retains exact payload and the actual model gate")
    func unknownImagePayloadAndGate() async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("owned.bin")
        let bytes = try ComposerMediaFixtures589.png()
        try bytes.write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        #expect(staged.status == .ready && staged.fileType == .unknown)
        #expect(staged.kind == .file && staged.data == nil && staged.mimeType == nil && staged.size == nil)
        try await waitUntil { chat.pendingAttachments.first?.kind == .image }
        let resolved = try #require(chat.pendingAttachments.first)
        #expect(resolved.status == .ready && resolved.fileType == .image)
        #expect(resolved.id == staged.id && resolved.fileURL == staged.fileURL)
        #expect(resolved.mimeType == "image/png" && resolved.size == Int64(bytes.count))
        #expect(resolved.data == bytes)
        let textOnly = LLMModel(id: "owned617-text", displayName: "Owned text", provider: "Owned",
                               modalityOverride: .textOnly)
        chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "[owned fixture]", model: textOnly)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: resolved.id)?.readiness == .unsupported)
        let vision = LLMModel(id: "owned617-vision", displayName: "Owned vision", provider: "Owned",
                             modalityOverride: .fullMultimodalInput)
        chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "[owned fixture]", model: vision)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: resolved.id)?.readiness == .supported)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("the real late sniff respects removal, edited identity, submission and session ownership",
          arguments: ["remove", "edit", "submit", "switch"])
    func actualWorkerOwnership(action: String) async throws {
        let (chat, root) = try fixture()
        let url = root.appendingPathComponent("owned.bin")
        let bytes = Data([0, 0, 0, 12] + Array("ftyp".utf8) + [0, 0, 0, 0])
        try bytes.write(to: url)
        let gate = Attachment617Gate()
        defer { gate.release(); chat.stopAllStreamingForSafety() }
        chat.videoFrameSourceFactory = { try gate.source($0) }
        let owner = try #require(chat.activeSessionID)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        #expect(staged.status == .ready && staged.fileType == .unknown)
        #expect(staged.size == nil && staged.mimeType == nil && staged.data == nil)
        let preparation: Task<ChatAttachment, Never> = try #require(chat.attachmentPreparationTask(for: staged, sessionID: owner))
        try await waitUntil { gate.entered }
        #expect(gate.enteredOnMainThread == false)
        chat.draftText = "MainActor remains editable while owned resolver is held"
        #expect(chat.draftText.hasPrefix("MainActor remains editable"))
        var edited: ChatAttachment?
        switch action {
        case "remove": chat.removePendingAttachment(id: staged.id)
        case "edit":
            chat.removePendingAttachment(id: staged.id)
            let replacement = ChatAttachment(id: staged.id, kind: .file, fileName: "edited.bin",
                fileType: .unknown, mimeType: "application/zip", size: 99,
                fileURL: staged.fileURL, status: .ready)
            chat.addComposerDraftAttachment(replacement); edited = replacement
        case "submit":
            let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
                allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "owned617",
                grantEpoch: "owned617", leaseID: "owned617", expiresAt: .distantFuture, autonomyCeiling: .l3)
            chat.configureComposerPolicy(facts)
            let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
            chat.turnRuntimeSnapshotFactory = { turn, box in
                let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                    readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                    applyReceiptID: "provider-readiness-apply:owned617")
                let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
                return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                    mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
            }
            chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
                requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
            chat.streamingProviderOverride = Attachment617Provider()
            chat.submitComposer()
            #expect(chat.messages.allSatisfy { $0.role != .user })
            #expect(chat.pendingAttachments == [staged])
            #expect(chat.isComposerAttachmentPreflightPending)
        case "switch":
            chat.newSession()
            #expect(chat.activeSessionID != owner && chat.pendingAttachments.isEmpty)
        default: Issue.record("unknown owned fixture action")
        }
        gate.release()
        _ = await preparation.value
        #expect(gate.returned)
        // The captured original worker has completed its actual owner-fenced
        // MainActor publication; no timing sleep or replacement callback is used.
        switch action {
        case "remove": #expect(chat.pendingAttachments.isEmpty)
        case "edit":
            let replacement = try #require(edited)
            #expect(chat.pendingAttachments == [replacement])
        case "submit":
            try await waitUntil { !chat.isComposerAttachmentPreflightPending }
            #expect(chat.messages.allSatisfy { $0.role != .user })
            let failed = try #require(chat.pendingAttachments.first)
            #expect(failed.id == staged.id && failed.fileURL == staged.fileURL)
            #expect(failed.fileType == .video && failed.status == .failed)
            #expect(!chat.canSubmitComposerAttachments)
        case "switch":
            #expect(chat.pendingAttachments.isEmpty)
            #expect(chat.messages.isEmpty)
            chat.switchSession(id: owner)
            try await waitUntil { chat.pendingAttachments.first?.status == .failed }
            let failed = try #require(chat.pendingAttachments.first)
            #expect(failed.id == staged.id && failed.fileURL == staged.fileURL)
            #expect(failed.fileType == .video && failed.videoFrames == nil)
            #expect(!chat.canSubmitComposerAttachments)
        default: break
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
