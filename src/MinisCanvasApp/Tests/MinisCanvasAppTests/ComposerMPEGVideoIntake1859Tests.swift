import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-MULTIMODAL-06 actual MPEG video intake and rejection")
@MainActor
struct ComposerMPEGVideoIntake1859Tests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/video1859-mpeg2.mpg")
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mpeg-video-1859-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeChat(in root: URL) throws -> ChatStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "mpeg-video-1859-\(UUID().uuidString)"))
        return ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")))
    }

    private func localProvider() -> (host: String, provider: OpenAICompatibleProvider) {
        let host = "mpeg-video-1859-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MPEG1859RequestProtocol.self]
        let provider = OpenAICompatibleProvider(apiKey: "offline-test-only",
            model: LLMModel(id: "mpeg-video-1859", displayName: "MPEG video fixture",
                provider: "Synthetic", modalityOverride: .vision),
            customBaseURL: "https://\(host)",
            session: URLSession(configuration: configuration))
        return (host, provider)
    }

    private func settledAttachment(in chat: ChatStore) async throws -> ChatAttachment {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while chat.pendingAttachments.first?.status == .pending, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(chat.pendingAttachments.first)
    }

    @Test("real MPEG bytes become indexed PNG slots in a locally captured Provider request")
    func mpegVideoTraversesPreparationHistoryAndWire() async throws {
        let original = try Data(contentsOf: fixture)
        #expect(original.count == 30_720)
        #expect(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
            == "c4fedd72ea997b00238b7417a9182433da00fa33de6b2d03e16e7b13d3244c56")
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("selected.mpeg")
        try original.write(to: path)
        #expect(FileImporter.type(forExtension: "mpg") == .video)
        #expect(FileImporter.mimeType(forExtension: "mpeg") == "video/mpeg")
        #expect(FileImporter.classify(url: path) == .video)
        let chat = try makeChat(in: base)
        defer { chat.stopAllStreamingForSafety() }
        let local = localProvider()
        defer { MPEG1859RequestProtocol.forget(host: local.host) }
        chat.streamingProviderOverride = local.provider
        let pending = try #require(chat.addAttachments(urls: [path]).first)
        #expect(pending.fileType == .video && pending.status == .pending)
        let ready = try await settledAttachment(in: chat)
        #expect(ready.id == pending.id)
        #expect(ready.status == .ready)
        let frames = try #require(ready.videoFrames)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.hasValidPayload })
        #expect(frames[0].timecodeSeconds < frames[1].timecodeSeconds)
        #expect(frames[1].timecodeSeconds < frames[2].timecodeSeconds)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: ready.id)?.readiness == .supported)
        let composed = ChatStore.composeUserContentWithOwnership(
            text: "检查抽取的实际画面", attachments: [ready])
        #expect(composed.content.contains("第1帧 \(ChatAttachment.videoTimecode(frames[0].timecodeSeconds))"))
        #expect(composed.content.contains("不应视为已看完整视频"))
        #expect(!composed.content.contains(path.path))
        let thread = ChatThread(messages: [.init(role: .user, content: composed.content,
            attachments: [ready], composedContentOwnership: composed.ownership)])
        let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
        try sessions.updateSession(thread.asPersisted())
        try ChatAttachmentPersistence.save(sessions: [thread], to: sessions.directory)
        let reopened = try makeChat(in: base.appendingPathComponent("reopen"))
        defer { reopened.stopAllStreamingForSafety() }
        #expect(reopened.attachPersistence(SessionStore(directory: sessions.directory)))
        #expect(reopened.messages.first?.attachments.first?.videoImageAttachments?.count == 3)
        reopened.appendUser("继续检查")
        let canonical = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: sessions, sessionID: thread.id.uuidString)
        #expect(canonical.first?.images.count == 3)
        _ = try await local.provider.sendMessage(messages: canonical,
            systemPrompt: nil, maxTokens: 128, temperature: nil)
        let body = try #require(MPEG1859RequestProtocol.body(for: local.host))
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let parts = try #require(messages.first?["content"] as? [[String: Any]])
        let urls = parts.compactMap { ($0["image_url"] as? [String: String])?["url"] }
        #expect(urls == canonical[0].images.map {
            "data:image/png;base64," + $0.data.base64EncodedString()
        })
        #expect(parts.contains { ($0["text"] as? String) == composed.content })
        #expect(parts.allSatisfy { $0["type"] as? String != "input_audio" })
    }

    @Test("a video extension with non-video bytes is failed, retained as draft, and never sent")
    func forgedMPEGExtensionFailsClosed() async throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("forged.mpg")
        try Data("not a video container".utf8).write(to: path)
        #expect(FileImporter.type(forExtension: "mpg") == .video)
        let chat = try makeChat(in: base)
        defer { chat.stopAllStreamingForSafety() }
        let local = localProvider()
        defer { MPEG1859RequestProtocol.forget(host: local.host) }
        chat.streamingProviderOverride = local.provider
        chat.draftText = "保留正文"
        let staged = try #require(chat.addAttachments(urls: [path]).first)
        #expect(staged.status == .pending)
        let failed = try await settledAttachment(in: chat)
        #expect(failed.id == staged.id)
        #expect(failed.status == .failed)
        #expect(failed.videoImageAttachments == nil)
        #expect(chat.composerMediaReadinessSnapshot.attachment(id: failed.id)?.readiness == .failed)
        #expect(!chat.canSubmitComposerAttachments)
        chat.submitComposer()
        #expect(chat.pendingAttachments.map(\.id) == [failed.id])
        #expect(chat.draftText == "保留正文")
        #expect(!chat.messages.contains { $0.role == .user })
        #expect(MPEG1859RequestProtocol.body(for: local.host) == nil)
    }
}

/// One unique .invalid host per method. URLSession is intercepted in-process;
/// no credential, DNS lookup, or real Provider service participates.
private final class MPEG1859RequestProtocol: URLProtocol, @unchecked Sendable {
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
        return host.hasPrefix("mpeg-video-1859-") && host.hasSuffix(".invalid")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host,
              let body = Self.bodyData(from: request),
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lock.lock(); Self.bodies[host] = body; Self.lock.unlock()
        let result = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
