import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Classification617Provider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var storedModel: LLMModel
    private var recorded: [[LLMMessage]] = []
    let name = "owned617-classification"
    var model: LLMModel {
        get { lock.withLock { storedModel } }
        set { lock.withLock { storedModel = newValue } }
    }
    var calls: [[LLMMessage]] { lock.withLock { recorded } }
    var capabilities: Set<ProviderCapability> { [.tools] }
    init(vision: Bool) {
        storedModel = LLMModel(id: vision ? "owned617-vision" : "owned617-text",
            displayName: "Owned classification", provider: "owned617-classification",
            modalityOverride: vision ? .fullMultimodalInput : .textOnly)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { recorded.append(messages) }
        return LLMResponse(text: "owned617-classified-final", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw MediaVideoExtractionFailure.unreadableSource
    }
}

private final class Classification617VideoGate: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let succeeds: Bool
    private let decodeURL: URL?
    init(succeeds: Bool = false, decodeURL: URL? = nil) {
        self.succeeds = succeeds; self.decodeURL = decodeURL
    }
    private var receivedURLValue: URL?
    var receivedURL: URL? { lock.withLock { receivedURLValue } }
    private var enteredValue = false
    private var returnedValue = false
    var entered: Bool { lock.withLock { enteredValue } }
    var returned: Bool { lock.withLock { returnedValue } }
    func source(_ url: URL) throws -> any MediaVideoFrameSource {
        lock.withLock { enteredValue = true; receivedURLValue = url }
        _ = signal.wait(timeout: .now() + 10)
        lock.withLock { returnedValue = true }
        if succeeds { return try AVFoundationVideoFrameSource(fileURL: decodeURL ?? url) }
        throw MediaVideoExtractionFailure.unreadableSource
    }
    func release() { signal.signal() }
}

@Suite("PERF617 real send waits for unknown classification before media admission", .serialized)
@MainActor
struct AttachmentSubmissionClassification617Tests {
    private func fixture(vision: Bool) throws -> (ChatStore, Classification617Provider, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("classify617-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "classify617-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
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
        let provider = Classification617Provider(vision: vision)
        chat.streamingProviderOverride = provider
        return (chat, provider, root)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "owned real classification/send did not finish")
    }
    @Test("PNG disguised as bin must enter the actual media gate before any user/provider consumption",
          arguments: [false, true])
    func pseudoImage(vision: Bool) async throws {
        let (chat, provider, root) = try fixture(vision: vision)
        defer { chat.stopAllStreamingForSafety() }
        let bytes = try ComposerMediaFixtures589.png()
        let url = root.appendingPathComponent("owned.bin"); try bytes.write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        chat.draftText = "owned image request"
        #expect(staged.status == .ready && staged.statusText == nil)
        chat.submitComposer()
        // Same MainActor turn: no resolver publication can precede this send.
        #expect(!chat.messages.contains { $0.role == .user })
        #expect(chat.pendingAttachments == [staged])
        #expect(provider.calls.isEmpty)
        try await waitUntil { chat.pendingAttachments.first?.kind == .image || !provider.calls.isEmpty }
        if vision {
            try await waitUntil { chat.messages.last?.content == "owned617-classified-final" }
            #expect(provider.calls.count == 1)
            let user = try #require(chat.messages.first(where: { $0.role == .user }))
            #expect(user.attachments.count == 1)
            #expect(user.attachments.first?.id == staged.id)
            #expect(user.attachments.first?.kind == .image && user.attachments.first?.data == bytes)
            #expect(provider.calls.first?.last(where: { $0.role == .user })?.images.map(\.data) == [bytes])
            #expect(chat.pendingAttachments.isEmpty)
        } else {
            #expect(provider.calls.isEmpty)
            #expect(!chat.messages.contains { $0.role == .user })
            let decoded = try #require(chat.pendingAttachments.first)
            #expect(decoded.id == staged.id && decoded.kind == .image && decoded.data == bytes)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: staged.id)?.readiness == .unsupported)
            #expect(chat.draftText == "owned image request")
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("a real unknown blob retains ready UI and completes one normal send with its frozen file reference")
    func genuineBlob() async throws {
        let (chat, provider, root) = try fixture(vision: false)
        defer { chat.stopAllStreamingForSafety() }
        let bytes = Data([0, 1]); let url = root.appendingPathComponent("owned.bin")
        try bytes.write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        #expect(staged.status == .ready && staged.statusText == nil)
        chat.draftText = "owned blob request"; chat.submitComposer()
        try await waitUntil { chat.messages.last?.content == "owned617-classified-final" }
        #expect(provider.calls.count == 1 && chat.pendingAttachments.isEmpty)
        let user = try #require(chat.messages.first(where: { $0.role == .user }))
        let sent = try #require(user.attachments.first)
        #expect(sent.id == staged.id && sent.fileURL == url.path)
        #expect(sent.kind == .file && sent.fileType == .unknown && sent.status == .ready)
        #expect(sent.data == nil && sent.statusText == nil)
        #expect(sent.size == Int64(bytes.count))
        #expect(provider.calls.first?.last(where: { $0.role == .user })?.images.isEmpty == true)
        chat.applyComposerAttachmentResolution(sent, sessionID: chat.activeSessionID,
                                              initialReadyReference: staged)
        #expect(chat.messages.first(where: { $0.role == .user }) == user)
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("held pseudo-video cannot consume before decoding or after cancellation/fence change",
          arguments: ["failed", "cancel", "edit", "remove", "session", "model", "policy"])
    func heldPseudoVideo(action: String) async throws {
        let (chat, provider, root) = try fixture(vision: true)
        let gate = Classification617VideoGate()
        defer { gate.release(); chat.stopAllStreamingForSafety() }
        chat.videoFrameSourceFactory = { try gate.source($0) }
        let bytes = Data([0, 0, 0, 12] + Array("ftyp".utf8) + [0, 0, 0, 0])
        let url = root.appendingPathComponent("owned.bin"); try bytes.write(to: url)
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        let owner = try #require(chat.activeSessionID)
        let preparation: Task<ChatAttachment, Never> = try #require(chat.attachmentPreparationTask(for: staged, sessionID: owner))
        chat.draftText = "owned held request"; chat.submitComposer()
        try await waitUntil { gate.entered }
        #expect(provider.calls.isEmpty)
        #expect(chat.pendingAttachments == [staged])
        #expect(!chat.messages.contains { $0.role == .user })
        var newerProvider: Classification617Provider?
        switch action {
        case "cancel": chat.stopStreaming()
        case "edit": chat.draftText = "owned edited request"
        case "remove": chat.removePendingAttachment(id: staged.id)
        case "session": chat.newSession()
        case "model":
            let next = Classification617Provider(vision: false)
            chat.streamingProviderOverride = next; newerProvider = next
        case "policy": chat.configureComposerPolicy(.unconfigured)
        case "failed": break
        default: Issue.record("unexpected owned action")
        }
        gate.release()
        _ = await preparation.value
        #expect(gate.returned)
        #expect(provider.calls.isEmpty && (newerProvider?.calls.isEmpty ?? true))
        #expect(!chat.sessions.contains { $0.messages.contains { $0.role == .user } })
        if action == "session" {
            #expect(chat.activeSessionID != owner && chat.pendingAttachments.isEmpty)
            chat.switchSession(id: owner)
        }
        if action != "remove" {
            let decoded = try #require(chat.pendingAttachments.first)
            #expect(decoded.id == staged.id && decoded.fileType == .video && decoded.status == .failed)
            #expect(!chat.canSubmitComposerAttachments)
        } else { #expect(chat.pendingAttachments.isEmpty) }
        if action == "edit" { #expect(chat.draftText == "owned edited request") }
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("successful held media proves every send fence before original admission",
          arguments: ["send", "cancel", "edit", "remove", "session", "model", "policy"])
    func successfulHeldVideo(action: String) async throws {
        let (chat, provider, root) = try fixture(vision: true)
        var fixtureURL = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { fixtureURL.deleteLastPathComponent() }
        fixtureURL.appendPathComponent("MinisCore/Tests/MinisCoreTests/Fixtures/video603-av-caption.mp4")
        let bytes = try Data(contentsOf: fixtureURL)
        let url = root.appendingPathComponent("owned-success.bin"); try bytes.write(to: url)
        // Controlled existing decoder transport: .bin is still the actual
        // staged/classified file. The successful factory receives that URL,
        // but decodes an owned .mp4 copy of the exact same fixture bytes.
        // This proves send fences, not AVFoundation's .bin URL compatibility.
        let codecURL = root.appendingPathComponent("owned-codec.mp4"); try bytes.write(to: codecURL)
        let gate = Classification617VideoGate(succeeds: true, decodeURL: codecURL)
        defer { gate.release(); chat.stopAllStreamingForSafety() }
        chat.videoFrameSourceFactory = { try gate.source($0) }
        let staged = try #require(chat.addAttachments(urls: [url]).first)
        let owner = try #require(chat.activeSessionID)
        let preparation: Task<ChatAttachment, Never> = try #require(chat.attachmentPreparationTask(for: staged, sessionID: owner))
        chat.draftText = "owned valid video"; chat.submitComposer()
        try await waitUntil { gate.entered }
        #expect(staged.status == .ready && staged.statusText == nil)
        #expect(chat.isComposerAttachmentPreflightPending)
        #expect(provider.calls.isEmpty && !chat.messages.contains { $0.role == .user })
        let originalFacts = chat.composerPolicyFacts
        var newerProvider: Classification617Provider?
        switch action {
        case "cancel": chat.stopStreaming()
        case "edit":
            chat.draftText = "owned intervening edit"
            chat.draftText = "owned valid video"
        case "remove": chat.removePendingAttachment(id: staged.id)
        case "session":
            chat.newSession(); chat.switchSession(id: owner)
        case "model":
            let next = Classification617Provider(vision: true)
            chat.streamingProviderOverride = next; newerProvider = next
            chat.streamingProviderOverride = provider
        case "policy":
            chat.configureComposerPolicy(.unconfigured)
            chat.configureComposerPolicy(originalFacts)
        case "send": break
        default: Issue.record("unexpected owned successful action")
        }
        gate.release()
        let resolved = await preparation.value
        #expect(gate.returned)
        #expect(gate.receivedURL == url)
        #expect(try Data(contentsOf: codecURL) == bytes)
        // This is the same worker handle captured before mutation, and its
        // return follows actual MainActor publication/registry retirement.
        #expect(resolved.id == staged.id && resolved.fileURL == url.path)
        #expect(resolved.status == .ready && resolved.fileType == .video)
        let frames = try #require(resolved.videoImageAttachments)
        let audio = try #require(resolved.videoContext?.audio?.data)
        #expect(frames.count == 3 && !audio.isEmpty)
        if action == "send" {
            try await waitUntil {
                chat.activeSessionID == owner && !chat.isActiveSessionGenerating
                    && chat.messages.last?.content == "owned617-classified-final"
            }
            #expect(provider.calls.count == 1)
            let user = try #require(chat.messages.first(where: { $0.role == .user }))
            #expect(user.attachments == [resolved] && chat.pendingAttachments.isEmpty)
            let request = try #require(provider.calls.first?.last(where: { $0.role == .user }))
            #expect(request.images.map(\.data) == frames.map(\.data))
            #expect(request.audios.count == 1)
            #expect(Data(base64Encoded: request.audios[0].base64Data) == audio)
        } else {
            #expect(!chat.isComposerAttachmentPreflightPending)
            #expect(provider.calls.isEmpty && (newerProvider?.calls.isEmpty ?? true))
            #expect(chat.sessions.allSatisfy { $0.messages.allSatisfy { $0.role != .user } })
            #expect(chat.activeSessionID == owner && chat.draftText == "owned valid video")
            if action == "remove" { #expect(chat.pendingAttachments.isEmpty) }
            else {
                #expect(chat.pendingAttachments == [resolved])
                #expect(chat.canSubmitComposerAttachments)
            }
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

}
