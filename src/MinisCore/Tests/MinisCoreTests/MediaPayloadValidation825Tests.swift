import Foundation
import ImageIO
import Testing
@testable import MinisCore

@Suite("M02 actual image pixels and production media wire825", .serialized)
struct MediaPayloadValidation825Tests {
    private let caps = ModelCapabilities(supportedModalities: .fullMultimodalInput, supportedAuth: [.apiKey])

    @Test func headerOnlyPNGNeverEntersAnyProductionImageWire() throws {
        // Owned real PNG truncated immediately after its complete IHDR chunk.
        // Dimensions alone do not prove that any image pixels were received.
        let original = try MediaPayloadFixtures589.png()
        let headerOnly = Data(original.prefix(33))
        let metadataSource = try #require(CGImageSourceCreateWithData(headerOnly as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(metadataSource, 0, nil)
        let width = (properties as NSDictionary?)?[kCGImagePropertyPixelWidth] as? NSNumber
        let height = (properties as NSDictionary?)?[kCGImagePropertyPixelHeight] as? NSNumber
        print("MEDIA825_HEADER_ONLY bytes=\(headerOnly.count) metadataWidth=\(width?.intValue ?? -1) metadataHeight=\(height?.intValue ?? -1) pixelsDecoded=\(CGImageSourceCreateImageAtIndex(metadataSource, 0, nil) != nil)")
        #expect(MediaPayloadValidation.failure(data: headerOnly, mimeType: "image/png") == .invalidImageDimensions)
        let message = LLMMessage(role: .user, content: "owned unrelated text", images: [.init(mimeType: "image/png", data: headerOnly)])
        for value in [OpenAICompatibleProvider.openAIMessageDict(message, mediaCapabilities: caps),
                      AnthropicProvider.anthropicMessageDict(message, mediaCapabilities: caps)] {
            let wire = try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
            #expect(!wire.contains(headerOnly.base64EncodedString()))
            #expect(wire.contains("[media-gate]") && wire.contains("owned unrelated text"))
        }
        let parts = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: caps).content
        #expect(parts.allSatisfy { $0.type != "input_image" })
        #expect(parts.contains { $0.text?.contains("[media-gate]") == true })
        let agent = AgentMessage(role: .user, parts: [.text("owned text"), .imageData(data: headerOnly, mimeType: "image/png")]).gatingInlineMedia(for: caps)
        #expect(agent.parts.count == 2)
        if case .text(let note) = agent.parts[1] { #expect(note.contains("[media-gate]")) }
        else { Issue.record("Header-only bytes cannot be advertised as a consumed image") }
    }

    @Test func completePNGStillReachesEveryImageConsumerUnchanged() throws {
        let png = try MediaPayloadFixtures589.png()
        #expect(MediaPayloadValidation.failure(data: png, mimeType: "image/png") == nil)
        let message = LLMMessage(role: .user, content: "owned complete image", images: [.init(mimeType: "image/png", data: png)])
        for value in [OpenAICompatibleProvider.openAIMessageDict(message, mediaCapabilities: caps),
                      AnthropicProvider.anthropicMessageDict(message, mediaCapabilities: caps)] {
            let wire = try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
            #expect(wire.contains(png.base64EncodedString()))
            #expect(!wire.contains("[media-gate]"))
        }
        let parts = OpenAIResponsesProvider.responsesInputItem(message, mediaCapabilities: caps).content
        #expect(parts.first?.imageURL?.url == "data:image/png;base64," + png.base64EncodedString())
        let agent = AgentMessage(role: .user, parts: [.imageData(data: png, mimeType: "image/png")]).gatingInlineMedia(for: caps)
        if case .imageData(let actual, let mime, _) = agent.parts.first {
            #expect(actual == png && mime == "image/png")
        } else { Issue.record("Complete image must remain available to the actual AgentProvider") }
    }

    @Test(arguments: ["byte-rate", "partial-frame"])
    func inconsistentWAVCannotEnterActualSendOrFollowup(kind: String) async throws {
        var invalid = MediaPayloadFixtures589.wav
        if kind == "byte-rate" {
            invalid.replaceSubrange(28..<32, with: [1, 0, 0, 0])
        } else {
            // PCM mono16 blockAlign=2; 15 sample bytes plus RIFF pad is not
            // a complete sample frame. RIFF extent/chunk padding stay valid.
            invalid.replaceSubrange(40..<44, with: [15, 0, 0, 0])
        }
        print("MEDIA825_WAV kind=\(kind) bytes=\(invalid.count) actualFormat=\(MediaPayloadValidation.audioFormat(invalid) ?? "nil")")
        #expect(MediaPayloadValidation.failure(data: invalid, mimeType: "audio/wav") == .invalidAudioContainer)
        let first = LLMMessage(role: .user, content: "owned audio text survives", audios: [.init(format: "wav", base64Data: invalid.base64EncodedString())])
        let responseParts = OpenAIResponsesProvider.responsesInputItem(first, mediaCapabilities: caps).content
        #expect(responseParts.allSatisfy { $0.type != "input_audio" })
        #expect(responseParts.contains { $0.text?.contains("[media-gate]") == true })

        Media825WireProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Media825WireProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = LLMModel(id: "owned825", displayName: "Owned825", provider: "Synthetic", modalityOverride: .fullMultimodalInput)
        let provider = OpenAICompatibleProvider(apiKey: "[configured locally]", model: model,
            customBaseURL: "http://127.0.0.1:1", session: session)
        _ = try await provider.sendMessage(messages: [first], systemPrompt: nil, maxTokens: 16, temperature: nil)
        let valid = MediaPayloadFixtures589.wav
        _ = try await provider.sendMessage(messages: [first, .init(role: .assistant, content: "owned synthetic"),
            .init(role: .user, content: "owned legal followup", audios: [.init(format: "wav", base64Data: valid.base64EncodedString())])],
            systemPrompt: nil, maxTokens: 16, temperature: nil)
        let bodies = Media825WireProtocol.bodies
        #expect(bodies.count == 2)
        for body in bodies {
            let text = try #require(String(data: body, encoding: .utf8))
            #expect(!text.contains(invalid.base64EncodedString()))
            #expect(text.contains("[media-gate]") && text.contains("owned audio text survives"))
        }
        let followup = try #require(bodies.last)
        #expect(String(data: followup, encoding: .utf8)?.contains(valid.base64EncodedString()) == true)
        #expect(first.audios.first?.base64Data == invalid.base64EncodedString(), "wire gate cannot rewrite canonical history")
    }

}


private final class Media825WireProtocol: URLProtocol, @unchecked Sendable {
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
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"owned825","choices":[{"message":{"role":"assistant","content":"synthetic transport only"},"finish_reason":"stop"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
