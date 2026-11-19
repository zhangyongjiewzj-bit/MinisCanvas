import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-MULTIMODAL-07 actual extensionless MP3 intake")
@MainActor
struct ComposerExtensionlessMP3Intake1890Tests {
    private struct Sample {
        let fixtureName: String
        let expectedSHA256: String
        let selectedName: String
    }

    private let samples = [
        Sample(fixtureName: "audio1890-tone-id3.mp3",
            expectedSHA256: "01687079a559622f072338b21a98199f6ebce943821b11f2c6e687c4bce4a8a6",
            selectedName: "tone-id3"),
        Sample(fixtureName: "audio1890-tone-frame.mp3",
            expectedSHA256: "b233cdf52d3b23f564e11f96ee52fbf561cf4c0651c6aabe06c5ffc5887d2db9",
            selectedName: "tone-frame"),
    ]

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "extensionless-mp3-1890-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeChat(in root: URL) throws -> ChatStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "extensionless-mp3-1890-\(UUID().uuidString)"))
        return ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
    }

    private func settledAudio(_ chat: ChatStore, count: Int) async throws -> [ChatAttachment] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let current = chat.pendingAttachments
            if current.count == count && current.allSatisfy({ $0.kind == .audio }) { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        return chat.pendingAttachments
    }

    /// An extensionless file is first a ready unknown reference; the worker's MIME sniff then
    /// re-resolves it as audio. Wait for that audio verdict (pass-through, converted or failed).
    private func settledAttachments(_ chat: ChatStore, count: Int) async throws -> [ChatAttachment] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let current = chat.pendingAttachments
            if current.count == count
                && current.allSatisfy({ $0.fileType == .audio && $0.status != .pending }) { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        return chat.pendingAttachments
    }

    @Test("actual ID3 and frame-only MP3 bytes survive preparation, reopen, and local request")
    func extensionlessMP3BytesReachNextTurnWire() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        var selected: [URL] = []
        var bytes: [Data] = []
        for sample in samples {
            let data = try Data(contentsOf: fixture(sample.fixtureName))
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                == sample.expectedSHA256)
            #expect(MediaPayloadValidation.audioFormat(data) == "mp3")
            let url = base.appendingPathComponent(sample.selectedName)
            try data.write(to: url)
            #expect(FileImporter.mimeType(of: url) == "audio/mpeg")
            #expect(FileImporter.classify(url: url) == .audio)
            selected.append(url)
            bytes.append(data)
        }
        let chat = try makeChat(in: base)
        defer { chat.stopAllStreamingForSafety() }
        let host = "extensionless-mp3-1890-\(UUID().uuidString.lowercased()).invalid"
        defer { MP31890RequestProtocol.forget(host: host) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MP31890RequestProtocol.self]
        let provider = OpenAICompatibleProvider(apiKey: "offline-test-only",
            model: LLMModel(id: "extensionless-mp3-1890", displayName: "MP3 fixture",
                provider: "Synthetic", modalityOverride: .fullMultimodalInput),
            customBaseURL: "https://\(host)", session: URLSession(configuration: config))
        chat.streamingProviderOverride = provider
        let staged = chat.addAttachments(urls: selected)
        #expect(staged.count == 2)
        let resolved = try await settledAudio(chat, count: 2)
        #expect(resolved.map(\.id) == staged.map(\.id))
        #expect(resolved.map(\.status) == [.ready, .ready])
        #expect(resolved.map(\.data) == bytes.map(Optional.some))
        #expect(resolved.allSatisfy {
            chat.composerMediaReadinessSnapshot.attachment(id: $0.id)?.readiness == .supported
        })
        let composed = ChatStore.composeUserContent(text: "请比较两段音频", attachments: resolved)
        let thread = ChatThread(messages: [.init(role: .user, content: composed,
            attachments: resolved)])
        let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
        try sessions.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: sessions.directory)
        let reopened = try makeChat(in: base.appendingPathComponent("reopen"))
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(SessionStore(directory: sessions.directory)))
        #expect(reopened.messages.first?.attachments.map(\.status) == [.ready, .ready])
        reopened.appendUser("继续比较")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: sessions, sessionID: thread.id.uuidString)
        #expect(canonical.first?.audios.map(\.base64Data) == bytes.map { $0.base64EncodedString() })
        _ = try await provider.sendMessage(messages: canonical,
            systemPrompt: nil, maxTokens: 128, temperature: nil)
        let body = try #require(MP31890RequestProtocol.body(for: host))
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        let audios = parts.compactMap { $0["input_audio"] as? [String: String] }
        #expect(audios.map { $0["format"] } == ["mp3", "mp3"])
        #expect(audios.map { $0["data"] } == bytes.map { $0.base64EncodedString() })
        #expect(parts.contains { ($0["text"] as? String) == composed })
    }

    @Test("forged ID3 and frame prefixes fail conversion and are rejected before submit")
    func forgedPrefixesNeverReachWire() async throws {
        for (name, data) in [
            ("fake-id3", Data("ID3\u{0003}\u{0000}\u{0000}\u{0000}\u{0000}\u{0000}\u{0000}xx".utf8)),
            ("fake-frame", Data([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 8))),
        ] {
            let base = try root()
            defer { try? FileManager.default.removeItem(at: base) }
            let path = base.appendingPathComponent(name)
            try data.write(to: path)
            #expect(FileImporter.mimeType(of: path) == "audio/mpeg")
            #expect(MediaPayloadValidation.audioFormat(data) == nil)
            let chat = try makeChat(in: base)
            defer { chat.stopAllStreamingForSafety() }
            chat.streamingProviderOverride = OpenAICompatibleProvider(apiKey: "offline-test-only",
                model: LLMModel(id: "extensionless-mp3-1890", displayName: "MP3 fixture",
                    provider: "Synthetic", modalityOverride: .fullMultimodalInput),
                customBaseURL: "https://extensionless-mp3-1890-fail.invalid")
            chat.draftText = "保留用户正文"
            let staged = try #require(chat.addAttachments(urls: [path]).first)
            let resolved = try #require(await settledAttachments(chat, count: 1).first)
            #expect(resolved.id == staged.id)
            #expect(resolved.status == .failed && resolved.kind == .file && resolved.data == nil)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: resolved.id)?.readiness == .failed)
            #expect(!chat.canSubmitComposerAttachments)
            chat.submitComposer()
            #expect(chat.pendingAttachments.map(\.id) == [resolved.id])
            #expect(chat.draftText == "保留用户正文")
            #expect(!chat.messages.contains { $0.role == .user })
        }
    }
}

private final class MP31890RequestProtocol: URLProtocol, @unchecked Sendable {
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
        return host.hasPrefix("extensionless-mp3-1890-") && host.hasSuffix(".invalid")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let url = request.url,
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
