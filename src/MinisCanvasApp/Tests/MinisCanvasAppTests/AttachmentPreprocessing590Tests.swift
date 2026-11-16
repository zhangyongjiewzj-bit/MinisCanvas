import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-PERF-06 real attachment preprocessing consumer")
@MainActor
struct AttachmentPreprocessing590Tests {
    @Test("background image proof stays bound to bytes while model and wire are re-evaluated")
    func imageProofIsNotAStaleCapabilityGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf1757-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.png")
        let png = try ComposerMediaFixtures589.png()
        try png.write(to: url)
        let defaults = try #require(UserDefaults(suiteName: "perf1757-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let vision = OpenAICompatibleProvider(apiKey: "[configured locally]",
            model: LLMModel(id: "vision1757", displayName: "Synthetic vision", provider: "Synthetic",
                            modalityOverride: .vision))
        let textOnly = OpenAICompatibleProvider(apiKey: "[configured locally]",
            model: LLMModel(id: "text1757", displayName: "Synthetic text", provider: "Synthetic",
                            modalityOverride: .textOnly))
        chat.streamingProviderOverride = vision
        let owner = chat.activeSessionID
        let initial = try #require(chat.addAttachments(urls: [url]).first)
        #expect(initial.status == .pending)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = try #require(chat.pendingAttachments.first)
        #expect(ready.status == .ready && ready.data == png)
        let proof = try #require(ready.backgroundByteEvidence)
        #expect(proof.source == .backgroundFileRead)
        #expect(proof.attachmentID == ready.id && proof.mimeType == "image/png")
        #expect(proof.byteCount == png.count)
        #expect(proof.sha256 == SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        #expect(proof.failure == nil)
        #expect(ready.withDeliveryQuarantined(true).backgroundByteEvidence == proof)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)
        chat.streamingProviderOverride = textOnly
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .unsupported)
        chat.streamingProviderOverride = vision
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)

        let recovered = try JSONDecoder().decode(ChatAttachment.self, from: JSONEncoder().encode(ready))
        #expect(recovered.backgroundByteEvidence == nil,
                "persisted bytes cannot inherit an unverified worker proof")
        chat.removePendingAttachment(id: ready.id)
        chat.addComposerDraftAttachment(recovered)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)

        // Same ID, path and byte count do not carry the worker's proof into a
        // replacement. A late resolution from the first slot cannot overwrite it.
        let replacement = ChatAttachment(id: ready.id, kind: .image, fileName: ready.fileName,
            fileType: .image, mimeType: "image/png", size: ready.size,
            data: Data(repeating: 0, count: png.count), fileURL: ready.fileURL)
        chat.removePendingAttachment(id: recovered.id)
        chat.addComposerDraftAttachment(replacement)
        #expect(chat.pendingAttachments.first?.backgroundByteEvidence == nil)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .unsupported)
        chat.applyComposerAttachmentResolution(ready, sessionID: owner,
            initialReadyReference: initial)
        #expect(chat.pendingAttachments == [replacement])
        let pendingReplacement = ChatAttachment(id: ready.id, kind: .file,
            fileName: "replaced-same-path.png", fileType: .image,
            mimeType: "image/png", fileURL: ready.fileURL, status: .pending)
        chat.removePendingAttachment(id: replacement.id)
        chat.addComposerDraftAttachment(pendingReplacement)
        chat.applyComposerAttachmentResolution(ready, sessionID: owner,
            initialReadyReference: initial)
        #expect(chat.pendingAttachments == [pendingReplacement],
                "late worker must not write over a different pending slot with the same ID/path")
    }

    @Test("background byte rejection remains visible before a media send")
    func invalidImageProofBlocksComposer() async throws {
        try await B1ProviderAssemblyFixtureSupport.withSession(protocols: [], rejectAllTransport: true) { session in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf1757-invalid-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("truncated.png")
            try Data(try ComposerMediaFixtures589.png().prefix(8)).write(to: url)
            let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: "perf1757-invalid-\(UUID())")!,
                logManager: LogManager(directory: root.appendingPathComponent("logs")))
            chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "[configured locally]",
                model: LLMModel(id: "vision1757", displayName: "Synthetic vision", provider: "Synthetic",
                                modalityOverride: .vision), session: session)
            let initial = try #require(chat.addAttachments(urls: [url]).first)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let ready = try #require(chat.pendingAttachments.first)
            #expect(ready.id == initial.id && ready.status == .ready)
            #expect(ready.backgroundByteEvidence?.failure == .invalidImageDimensions)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .unsupported)
            #expect(!chat.canSubmitComposerAttachments)
            chat.draftText = "owned draft"
            chat.submitComposer()
            #expect(chat.draftText == "owned draft")
            #expect(chat.pendingAttachments.first?.id == ready.id)
            #expect(!chat.messages.contains { $0.role == .user })
        }
    }

    @Test("background audio proof does not carry an old wire decision")
    func audioProofRechecksCurrentWire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf1757-audio-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.wav")
        try ComposerMediaFixtures589.wav.write(to: url)
        let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: "perf1757-audio-\(UUID())")!,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let model = LLMModel(id: "audio1757", displayName: "Synthetic audio", provider: "Synthetic",
                             modalityOverride: .fullMultimodalInput)
        chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "[configured locally]", model: model)
        _ = chat.addAttachments(urls: [url])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = try #require(chat.pendingAttachments.first)
        #expect(ready.status == .ready && ready.backgroundByteEvidence?.failure == nil)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)
        chat.streamingProviderOverride = AnthropicProvider(apiKey: "[configured locally]", model: model)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .unsupported)
        chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "[configured locally]", model: model)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)
    }

    @Test("recognized payload publishes before metadata and preserves resolved bytes",
          arguments: ["txt", "rtf"])
    func placeholderPrecedesFileMetadata(ext: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf590-attachment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("owned.\(ext)")
        let bytes = Data("owned synthetic attachment\n第二行".utf8)
        try bytes.write(to: url)
        let defaults = try #require(UserDefaults(suiteName: "perf590-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let sessionID = try #require(chat.activeSessionID)
        let added = chat.addAttachments(urls: [url])
        let pending = try #require(added.first)
        #expect(pending.status == .pending)
        #expect(pending.size == nil)
        #expect(pending.data == nil)
        #expect(!chat.canSubmitComposerAttachments)
        #expect(chat.pendingAttachments.first?.id == pending.id)
        #expect(chat.activeSessionID == sessionID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let resolved = try #require(chat.pendingAttachments.first)
        #expect(resolved.status == .ready)
        #expect(resolved.id == pending.id)
        #expect(resolved.fileType == .text)
        #expect(resolved.kind == .text)
        #expect(resolved.size == Int64(bytes.count))
        #expect(resolved.data == bytes)
        #expect(resolved.fileURL == url.path)
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.activeSessionID == sessionID)
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("native delegate long edits keep transcript identity and coalesce at the real draft boundary")
    func nativeLongDraftConsumerCosts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf590-native-draft-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "perf590-native-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("draft-store"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        chat.appendAssistant("owned history remains unchanged")
        let history = chat.messages
        let revision = chat.transcriptRevision(forSession: session)
        let key = DraftStore.chatDraftKey(sessionID: session)
        var historyNotifications = 0
        chat.onSessionsChanged = { historyNotifications += 1 }
        let delegate = ScrollableComposerTextView(
            text: Binding(get: { chat.draftText }, set: { chat.draftText = $0 }),
            font: .systemFont(ofSize: 13), onSend: { Issue.record("unsent cost fixture must not send") }
        ).makeCoordinator()
        let editor = ComposerPasteAwareTextView(frame: .zero)
        let base = String(repeating: "长草稿 ordinary owned text\n", count: 2_000)
        let clock = ContinuousClock()
        var total = Duration.zero
        var maximum = Duration.zero
        for index in 0..<80 {
            editor.string = base + "edit-\(index)"
            let start = clock.now
            delegate.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            let elapsed = start.duration(to: clock.now)
            total += elapsed
            maximum = max(maximum, elapsed)
            #expect(chat.draftText == editor.string)
        }
        #expect(chat.messages == history)
        #expect(chat.transcriptRevision(forSession: session) == revision)
        #expect(historyNotifications == 0)
        #expect(drafts.latestPayload(for: key) == nil)
        #expect(chat.longDraftTimerCreationCount == 1)
        #expect(chat.longDraftEncodingCount == 0)
        #expect(chat.flushPendingDraftForTermination())
        let saved = try #require(drafts.load(key: key))
        #expect(saved == Data(editor.string.utf8))
        #expect(chat.longDraftEncodingCount == 1)
        print("PERF590_NATIVE_DELEGATE edits=80 utf8=\(saved.count) total=\(total) max=\(maximum) timer=\(chat.longDraftTimerCreationCount) encode=\(chat.longDraftEncodingCount) window=NONE; excludes input mutation/SwiftUI frame/allocation and remote latency")
    }

}
