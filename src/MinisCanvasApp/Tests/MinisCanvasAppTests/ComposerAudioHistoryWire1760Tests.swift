import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-MULTIMODAL-07 canonical audio history wire")
@MainActor
struct ComposerAudioHistoryWire1760Tests {
    private static let mp3 = Data([0xFF, 0xFB, 0x90, 0x00]
        + [UInt8](repeating: 0, count: 413))

    private func audio(_ name: String, _ mime: String, _ bytes: Data) -> ChatAttachment {
        ChatAttachment(kind: .audio, fileName: name, fileType: .audio,
            mimeType: mime, size: Int64(bytes.count), data: bytes)
    }

    private func actualRequest(_ messages: [LLMMessage]) async throws -> [[String: Any]] {
        let host = "owned-audio-\(UUID().uuidString.lowercased()).invalid"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioHistoryRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            AudioHistoryRequestProtocol.forget(host: host)
            session.invalidateAndCancel()
        }
        let provider = OpenAICompatibleProvider(
            apiKey: "offline-test-only",
            model: LLMModel(id: "owned-audio", displayName: "Owned Audio",
                provider: "Synthetic", modalityOverride: .fullMultimodalInput),
            customBaseURL: "https://\(host)", session: session
        )
        _ = try await provider.sendMessage(messages: messages,
            systemPrompt: nil, maxTokens: 128, temperature: nil)
        let body = try #require(AudioHistoryRequestProtocol.body(for: host))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["messages"] as? [[String: Any]])
    }

    private func reopenedHistory(
        canonical: ChatThread, sidecar: ChatThread
    ) throws -> (ChatStore, SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audio-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(directory: root)
        try store.updateSession(canonical.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [sidecar], to: root)
        let defaults = try #require(UserDefaults(suiteName: "audio-history-\(UUID().uuidString)"))
        let reopened = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
        #expect(reopened.attachPersistence(SessionStore(directory: root)))
        return (reopened, store, root)
    }

    @Test("WAV and MP3 survive reopen and reach the actual next-turn request")
    func canonicalWAVAndMP3Positive() async throws {
        let wav = ComposerMediaFixtures589.wav
        #expect(MediaPayloadValidation.audioFormat(Self.mp3) == "mp3")
        let attachments = [audio("voice.wav", "audio/wav", wav),
            audio("music.mp3", "audio/mpeg", Self.mp3)]
        let content = ChatStore.composeUserContent(text: "请比较", attachments: attachments)
        let thread = ChatThread(messages: [ChatMessageUI(role: .user,
            content: content, attachments: attachments)])
        let (reopened, store, root) = try reopenedHistory(canonical: thread, sidecar: thread)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(reopened.messages.first?.attachments.map(\.status) == [.ready, .ready])
        reopened.appendUser("继续比较")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: store, sessionID: thread.id.uuidString)
        #expect(canonical.first?.audios.map(\.base64Data)
            == [wav.base64EncodedString(), Self.mp3.base64EncodedString()])
        let sent = try await actualRequest(canonical)
        let parts = try #require(sent.first?["content"] as? [[String: Any]])
        let audios = parts.compactMap { $0["input_audio"] as? [String: String] }
        #expect(audios.map { $0["format"] } == ["wav", "mp3"])
        #expect(audios.map { $0["data"] }
            == [wav.base64EncodedString(), Self.mp3.base64EncodedString()])
    }

    @Test("a replaced valid WAV sidecar cannot overwrite Core or borrow MP3 slot")
    func changedSidecarAudioFailsClosedThroughProviderRequest() async throws {
        let wav = ComposerMediaFixtures589.wav
        let original = [audio("voice.wav", "audio/wav", wav),
            audio("music.mp3", "audio/mpeg", Self.mp3)]
        let content = ChatStore.composeUserContent(text: "请比较", attachments: original)
        let canonicalThread = ChatThread(messages: [ChatMessageUI(role: .user,
            content: content, attachments: original)])
        var alternate = wav
        alternate[alternate.count - 1] = 1
        #expect(MediaPayloadValidation.audioFormat(alternate) == "wav")
        let changed = ChatAttachment(id: original[0].id, kind: .audio,
            fileName: original[0].fileName, fileType: .audio,
            mimeType: "audio/wav", size: Int64(alternate.count), data: alternate)
        let sidecarThread = ChatThread(id: canonicalThread.id,
            messages: [ChatMessageUI(role: .user, content: content,
                attachments: [changed, original[1]])])
        let (reopened, store, root) = try reopenedHistory(
            canonical: canonicalThread, sidecar: sidecarThread)
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = try #require(reopened.messages.first)
        #expect(restored.attachments.map(\.status) == [.failed, .ready])
        #expect(restored.attachments[0].data == nil)
        #expect(restored.content == content)
        #expect(store.loadSession(id: canonicalThread.id.uuidString)?
            .messages.first?.audios.map(\.base64Data)
            == [wav.base64EncodedString(), Self.mp3.base64EncodedString()])
        reopened.appendUser("继续比较")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: store, sessionID: canonicalThread.id.uuidString)
        #expect(canonical.first?.audios.map(\.base64Data) == [Self.mp3.base64EncodedString()])
        #expect(canonical.first?.content.contains("音频 voice.wav 的历史字节恢复校验失败") == true)
        #expect(canonical.first?.content.contains("请比较") == true)
        let sent = try await actualRequest(canonical)
        let parts = try #require(sent.first?["content"] as? [[String: Any]])
        let audios = parts.compactMap { $0["input_audio"] as? [String: String] }
        #expect(audios.count == 1)
        #expect(audios.first?["data"] == Self.mp3.base64EncodedString())
        let requestText = try #require(String(
            data: JSONSerialization.data(withJSONObject: sent), encoding: .utf8))
        #expect(!requestText.contains(alternate.base64EncodedString()))

        let again = ChatStore(preferencesDefaults: UserDefaults(
            suiteName: "audio-history-again-\(UUID().uuidString)"),
            logManager: LogManager(directory: root.appendingPathComponent("logs-again")))
        #expect(again.attachPersistence(SessionStore(directory: root)))
        #expect(again.messages.first?.asLLMMessage().content == canonical.first?.content)
        #expect(again.messages.first?.asLLMMessage().audios.map(\.base64Data)
            == [Self.mp3.base64EncodedString()])
    }

    @Test("invalid WAV header and failed status cannot replay stale audio bytes")
    func invalidHeaderAndFailedStatusAreNotPayloads() throws {
        let invalid = audio("broken.wav", "audio/wav",
            Data(ComposerMediaFixtures589.wav.prefix(12)))
        #expect(invalid.audioAttachment == nil)
        let failed = ChatAttachment(kind: .audio, fileName: "failed.wav",
            fileType: .audio, mimeType: "audio/wav",
            data: ComposerMediaFixtures589.wav, status: .failed)
        #expect(failed.audioAttachment == nil)
        let thread = ChatThread(messages: [ChatMessageUI(role: .user,
            content: "这两段不应被发送", attachments: [invalid, failed])])
        let record = try #require(ChatAttachmentPersistence.records(for: thread).messages.first)
        let restored = ChatAttachmentPersistence.restoreAttachments(
            from: thread.asPersisted(), records: [record])
        #expect(restored.messages.first?.attachments.first?.status == .failed)
        #expect(restored.messages.first?.asLLMMessage().audios.isEmpty == true)
    }
}

private final class AudioHistoryRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func body(for host: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bodies[host]
    }

    static func forget(host: String) {
        lock.lock(); defer { lock.unlock() }
        bodies.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasPrefix("owned-audio-") && host.hasSuffix(".invalid")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        Self.lock.lock(); Self.bodies[host] = body; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
