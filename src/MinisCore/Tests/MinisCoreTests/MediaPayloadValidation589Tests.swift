import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MinisCore

enum MediaPayloadFixtures589 {
    static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 3,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
    static let wav: Data = {
        var bytes = Array("RIFF".utf8)
        func add16(_ value: UInt16) { bytes += [UInt8(value & 255), UInt8(value >> 8)] }
        func add32(_ value: UInt32) { bytes += [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8(value >> 24)] }
        add32(52); bytes += Array("WAVEfmt ".utf8); add32(16)
        add16(1); add16(1); add32(8000); add32(16000); add16(2); add16(16)
        bytes += Array("data".utf8); add32(16); bytes += [UInt8](repeating: 0, count: 16)
        return Data(bytes)
    }()
}

private final class MediaWire589Protocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [Data] = []
    }
    private static let state = State()
    static func reset() { state.lock.withLock { state.bodies = [] } }
    static var bodies: [Data] { state.lock.withLock { state.bodies } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard request.url?.host == "127.0.0.1" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
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
        Self.state.lock.withLock { Self.state.bodies.append(body) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"owned589","choices":[{"message":{"role":"assistant","content":"synthetic transport only"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Media589 actual byte validation and production wire", .serialized)
struct MediaPayloadValidation589Tests {
    private let caps = ModelCapabilities(supportedModalities: .fullMultimodalInput, supportedAuth: [.apiKey])

    @Test func imageBytesAndDimensionsReachAllThreeWireConsumers() throws {
        let png = try MediaPayloadFixtures589.png()
        #expect(MediaPayloadValidation.failure(data: png, mimeType: "image/png") == nil)
        let message = LLMMessage(role: .user, content: "owned image", images: [.init(mimeType: "image/png", data: png)])
        for value in [OpenAICompatibleProvider.openAIMessageDict(message, mediaCapabilities: caps),
                      AnthropicProvider.anthropicMessageDict(message, mediaCapabilities: caps)] {
            #expect(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)?.contains(png.base64EncodedString()) == true)
        }
        let responses = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: caps)
        #expect(responses.content.first?.imageURL?.url == "data:image/png;base64," + png.base64EncodedString())
    }

    @Test func falseMIMETruncatedImageAndUnsupportedFormatsNeverEmitBinary() throws {
        let png = try MediaPayloadFixtures589.png()
        #expect(MediaPayloadValidation.failure(data: png, mimeType: "image/jpeg") == .declaredFormatMismatch)
        #expect(MediaPayloadValidation.failure(data: Data(png.prefix(8)), mimeType: "image/png") == .invalidImageDimensions)
        #expect(MediaPayloadValidation.failure(data: png, mimeType: "image/png", wire: .other) == .unsupportedWire)
        #expect(MediaPayloadValidation.failure(data: Data("owned heic source".utf8), mimeType: "image/heic") == .unsupportedImageFormat)
        let invalid = LLMMessage(role: .user, content: "unrelated text", images: [.init(mimeType: "image/jpeg", data: png)])
        for value in [OpenAICompatibleProvider.openAIMessageDict(invalid, mediaCapabilities: caps),
                      AnthropicProvider.anthropicMessageDict(invalid, mediaCapabilities: caps)] {
            let wire = try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
            #expect(!wire.contains(png.base64EncodedString()))
            #expect(wire.contains("[media-gate]") && wire.contains("unrelated text"))
        }
        let agent = AgentMessage(role: .user, parts: [.text("kept"), .imageData(data: png, mimeType: "image/jpeg")]).gatingInlineMedia(for: caps)
        #expect(agent.parts.count == 2)
        if case .text(let note) = agent.parts[1] { #expect(note.contains("[media-gate]")) }
        else { Issue.record("invalid bytes may not reach a conforming AgentProvider") }
        let parts = OpenAIResponsesProvider.responsesInputItem(invalid, mediaCapabilities: caps).content
        #expect(parts.allSatisfy { $0.type != "input_image" })
        #expect(parts.contains { $0.text?.contains("[media-gate]") == true })
    }

    @Test func audioContainerAndWireFormatAreCheckedBeforeSerialization() {
        let wav = MediaPayloadFixtures589.wav
        #expect(MediaPayloadValidation.audioFormat(wav) == "wav")
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "AUDIO/WAV; fixture=1", wire: .openaiCompatible) == nil)
        #expect(MediaPayloadValidation.failure(data: Data(wav.prefix(12)), mimeType: "audio/wav") == .invalidAudioContainer)
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/mp3") == .declaredFormatMismatch)
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/aac") == .unsupportedAudioFormat)
        #expect(MediaPayloadValidation.failure(data: wav, mimeType: "audio/wav", wire: .anthropic) == .unsupportedWire)
        let message = LLMMessage(role: .user, content: "owned audio", audios: [.init(format: "WAV", base64Data: wav.base64EncodedString())])
        let allowed = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: caps)
        #expect(allowed.content.first?.inputAudio?.format == "wav")
        #expect(allowed.content.first?.inputAudio?.data == wav.base64EncodedString())
        let invalid = LLMMessage(role: .user, content: "owned invalid", audios: [.init(format: "wav", base64Data: "not-base64")])
        let rejected = OpenAIResponsesProvider.responsesInputItem(invalid, mediaCapabilities: caps)
        #expect(rejected.content.allSatisfy { $0.type != "input_audio" })
        #expect(rejected.content.contains { $0.text?.contains("[media-gate]") == true })
    }

    @Test func actualProviderSendAndFollowupReplayKeepCanonicalAudioBytes() async throws {
        MediaWire589Protocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaWire589Protocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = LLMModel(id: "owned589", displayName: "Owned", provider: "Synthetic", modalityOverride: .fullMultimodalInput)
        let fixtureCredential = "[configured locally]"
        let provider = OpenAICompatibleProvider(apiKey: fixtureCredential, model: model,
            customBaseURL: "http://127.0.0.1:1", session: session)
        let wav = MediaPayloadFixtures589.wav
        let first = LLMMessage(role: .user, content: "fixture audio", audios: [.init(format: "WAV", base64Data: wav.base64EncodedString())])
        _ = try await provider.sendMessage(messages: [first], systemPrompt: nil, maxTokens: 16, temperature: nil)
        _ = try await provider.sendMessage(messages: [first, .init(role: .assistant, content: "synthetic"),
            .init(role: .user, content: "followup")], systemPrompt: nil, maxTokens: 16, temperature: nil)
        #expect(MediaWire589Protocol.bodies.count == 2)
        for data in MediaWire589Protocol.bodies {
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(root["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            let audio = try #require(parts.first?["input_audio"] as? [String: String])
            #expect(audio["format"] == "wav")
            #expect(audio["data"] == wav.base64EncodedString())
        }
        #expect(first.audios.first?.format == "WAV", "assembly never rewrites canonical history")
    }
}
