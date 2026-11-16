import AVFAudio
import Foundation
import Testing
@testable import MinisCore

/// D-MULTIMODAL-07: actual WAV decoding and the production SDK wire/history
/// boundary. The controlled response verifies transport parsing, not speech
/// recognition or understanding by an external Provider.
@Suite("Audio2910 WAV encoding and actual SDK history", .serialized)
struct AudioEncodingBoundary2910Tests {
    private let audioModel = LLMModel(id: "owned-audio-input2910", displayName: "Owned audio input",
        provider: "OpenAI", modalityOverride: [.textInput, .textOutput, .audioInput])

    private func ownedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Audio2910-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func floatingWAV(bits: UInt16) -> Data {
        var data = MediaPayloadFixtures589.wav
        let alignment = bits / 8
        let byteRate = UInt32(alignment) * 8000
        data.replaceSubrange(20..<22, with: [3, 0])
        data.replaceSubrange(28..<32, with: [UInt8(byteRate & 255), UInt8((byteRate >> 8) & 255),
            UInt8((byteRate >> 16) & 255), UInt8(byteRate >> 24)])
        data.replaceSubrange(32..<34, with: [UInt8(alignment), 0])
        data.replaceSubrange(34..<36, with: [UInt8(bits), 0])
        return data
    }

    private func decodedFrames(_ data: Data, root: URL) throws -> AVAudioFrameCount {
        let fileURL = root.appendingPathComponent("owned-\(UUID().uuidString).wav")
        try data.write(to: fileURL)
        let file = try AVAudioFile(forReading: fileURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32))
        try file.read(into: buffer)
        return buffer.frameLength
    }

    private func provider(model: LLMModel, session: URLSession) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: "owned-noncredential2910", model: model,
            customBaseURL: "https://audio2910.invalid", session: session)
    }

    private func sendAndReopen(_ message: LLMMessage, validFollowup: Data,
                               model: LLMModel, root: URL) async throws -> [Data] {
        Audio2910Protocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Audio2910Protocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sdk = provider(model: model, session: session)
        let store = SessionStore(directory: root.appendingPathComponent("history", isDirectory: true))
        let history = try store.createSession()
        try store.saveMessage(message, sessionID: history.id)
        let first = try await sdk.sendMessage(messages: [message], systemPrompt: "owned trusted prompt",
            maxTokens: 16, temperature: nil)
        #expect(first.text == "owned SDK response2910")
        try store.saveMessage(.init(role: .assistant, content: first.text), sessionID: history.id)
        let reopened = SessionStore(directory: store.directory)
        let replay = try reopened.resumeMessages(sessionID: history.id)
        #expect(replay.first?.audios.map(\.base64Data) == message.audios.map(\.base64Data),
                "wire rejection must preserve canonical source bytes")
        #expect(replay.first?.audios.map(\.format) == message.audios.map(\.format))
        let second = try await sdk.sendMessage(messages: replay + [.init(role: .user, content: "owned next turn",
            audios: [.init(format: "wav", base64Data: validFollowup.base64EncodedString())])],
            systemPrompt: "owned trusted prompt", maxTokens: 16, temperature: nil)
        #expect(second.text == "owned SDK response2910")
        let bodies = Audio2910Protocol.bodies
        try #require(bodies.count == 2, "both actual SDK sends must reach the controlled HTTP boundary")
        return bodies
    }

    @Test("decoded PCM16 and IEEE float32 are sent byte-for-byte and replayed from history")
    func supportedEncodingSurvivesActualSendAndHistory() async throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for data in [MediaPayloadFixtures589.wav, floatingWAV(bits: 32)] {
            #expect(try decodedFrames(data, root: root) > 0)
            #expect(MediaPayloadValidation.audioFormat(data) == "wav")
            let message = LLMMessage(role: .user, content: "owned legal audio",
                audios: [.init(format: "WAV", base64Data: data.base64EncodedString())])
            let bodies = try await sendAndReopen(message, validFollowup: MediaPayloadFixtures589.wav,
                model: audioModel, root: root)
            for body in bodies {
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["model"] as? String == audioModel.id)
                let messages = try #require(json["messages"] as? [[String: Any]])
                let user = try #require(messages.first { $0["role"] as? String == "user" })
                let parts = try #require(user["content"] as? [[String: Any]])
                let audio = try #require(parts.first { $0["type"] as? String == "input_audio" }?["input_audio"] as? [String: String])
                #expect(audio == ["format": "wav", "data": data.base64EncodedString()])
            }
        }
    }

    @Test("undecodable IEEE float16 cannot be emitted on the first send or after reopen")
    func invalidFloatingEncodingIsRefusedOnActualSendAndHistory() async throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = floatingWAV(bits: 16)
        #expect(throws: (any Error).self) { _ = try decodedFrames(invalid, root: root) }
        #expect(MediaPayloadValidation.audioFormat(invalid) == nil)
        #expect(MediaPayloadValidation.failure(data: invalid, mimeType: "audio/wav") == .invalidAudioContainer)
        let message = LLMMessage(role: .user, content: "owned invalid audio text",
            audios: [.init(format: "wav", base64Data: invalid.base64EncodedString())])
        let parts = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: audioModel.capabilities).content
        #expect(parts.allSatisfy { $0.type != "input_audio" })
        #expect(parts.contains { $0.text?.contains("[media-gate]") == true })
        let bodies = try await sendAndReopen(message, validFollowup: MediaPayloadFixtures589.wav,
            model: audioModel, root: root)
        for body in bodies {
            let raw = try #require(String(data: body, encoding: .utf8))
            #expect(!raw.contains(invalid.base64EncodedString()))
            #expect(raw.contains("[media-gate]") && raw.contains("owned invalid audio text"))
        }
        #expect(String(data: bodies[1], encoding: .utf8)?.contains(MediaPayloadFixtures589.wav.base64EncodedString()) == true)
    }

    @Test("declared format and explicit model capability remain independent refusal gates")
    func formatAndModelRefusalDoNotPoisonFollowupText() async throws {
        let root = try ownedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = MediaPayloadFixtures589.wav
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/mp3") == .declaredFormatMismatch)
        let textModel = LLMModel(id: "owned-text2910", displayName: "Owned text", provider: "Unknown")
        #expect(!textModel.capabilities.supportedModalities.contains(.audioInput))
        let message = LLMMessage(role: .user, content: "owned text remains usable",
            audios: [.init(format: "wav", base64Data: wav.base64EncodedString())])
        let bodies = try await sendAndReopen(message, validFollowup: wav, model: textModel, root: root)
        for body in bodies {
            let raw = try #require(String(data: body, encoding: .utf8))
            #expect(!raw.contains(wav.base64EncodedString()))
            #expect(raw.contains("[media-gate]") && raw.contains("owned text remains usable"))
        }
        #expect(String(data: bodies[1], encoding: .utf8)?.contains("owned next turn") == true)
    }
}

private final class Audio2910Protocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [Data] = []
    }
    private static let state = State()
    static func reset() { state.lock.withLock { state.bodies = [] } }
    static var bodies: [Data] { state.lock.withLock { state.bodies } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio2910.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
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
        Self.state.lock.withLock { Self.state.bodies.append(body) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"owned2910","choices":[{"message":{"role":"assistant","content":"owned SDK response2910"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
