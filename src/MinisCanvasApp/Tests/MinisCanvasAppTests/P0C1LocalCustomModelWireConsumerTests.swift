import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Own the production fixed local endpoint before creating ChatStore. If another
// service owns it, fail without connecting, killing or changing that service.
private final class Provider04OwnedLocalWire: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var captured: [(String, Data)] = []
    private var served: [(String, Data, Int)] = []
    private let modelID: String
    private var stopped = false

    init(modelID: String) throws {
        self.modelID = modelID
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        listener = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(11434).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd); throw URLError(.badURL)
        }
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, listen(fd, 2) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "Provider04FixturePortUnavailable", code: Int(errno))
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }

    var requests: [(String, Data)] { lock.lock(); defer { lock.unlock() }; return captured }
    var servedResponses: [(String, Data, Int)] { lock.lock(); defer { lock.unlock() }; return served }

    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        if first { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
    }
    deinit { stop() }

    private func serve() {
        for _ in 0..<2 {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var deadline = timeval(tv_sec: 5, tv_usec: 0)
        withUnsafePointer(to: &deadline) {
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        var bodyLength = 0
        while bytes.count < 131_072 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = end
                let header = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
                let lengths = header.components(separatedBy: "\r\n").filter {
                    $0.lowercased().hasPrefix("content-length:")
                }
                bodyLength = lengths.first.flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            }
            if let end = headerEnd, bytes.count >= end.upperBound + bodyLength { break }
        }
        guard let end = headerEnd else { return }
        let header = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
        let path = header.components(separatedBy: "\r\n").first ?? ""
        let body = Data(bytes[end.upperBound..<(end.upperBound + bodyLength)])
        lock.lock(); captured.append((path, body)); lock.unlock()
        let object: [String: Any]
        if path == "GET /api/tags HTTP/1.1" {
            object = ["models": [["name": modelID]]]
        } else {
            object = ["id": "provider04-controlled", "object": "chat.completion", "model": modelID,
                      "choices": [["index": 0, "message": ["role": "assistant", "content": "provider04-local-response"], "finish_reason": "stop"]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        response.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { return }
                offset += count
            }
            lock.lock(); served.append((path, data, offset)); lock.unlock()
        }
    }
}

extension P0C1CustomProviderMenuTests {
    @Test("local custom input reaches production ChatStore provider and owned loopback response")
    func localCustomInputReachesProductionProviderWire() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let input = "Org/Arbitrary-Provider04-\(UUID().uuidString):Q4_Custom"
        let wire = try Provider04OwnedLocalWire(modelID: input)
        defer { wire.stop() }
        let readiness = ProviderReadinessStore(directory: formal.rootDirectory.appendingPathComponent("provider04-readiness"))
        let chat = ChatStore(providerReadinessStore: readiness)
        defer { chat.stopAllStreamingForSafety() }
        #expect(chat.localModelCatalogSource == nil) // Real production /api/tags, no stub.
        var picker = ModelPickerState(provider: nil, modelID: nil, tier: nil)
        picker.selectProvider(.local)
        picker.selectModel(input) // Same state setter reached by the local text input.
        #expect(picker.modelID == input)
        let prepared = await chat.prepareLocalModelSelection(modelID: input) { true }
        #expect(prepared)
        let suite = "Provider04-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        picker.selectTier(.balanced)
        #expect(picker.apply(to: chat, defaults: defaults))
        #expect(chat.selectedProviderType == .local && chat.selectedModelID == input)
        let provider = try chat.activeProvider()
        let local = try #require(provider as? LocalOpenAIProvider)
        #expect(local.baseURL.absoluteString == "http://127.0.0.1:11434")
        #expect(provider.model.id == input && !local.requiresAPIKey)
        let prompt = "isolated-provider04-request"
        let response = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: prompt)],
            systemPrompt: nil, maxTokens: 32, temperature: nil)
        #expect(response.text == "provider04-local-response")
        let requests = wire.requests
        #expect(requests.count == 2)
        #expect(requests.first?.0 == "GET /api/tags HTTP/1.1")
        #expect(requests.last?.0 == "POST /v1/chat/completions HTTP/1.1")
        let payload = try #require(try JSONSerialization.jsonObject(with: requests.last!.1) as? [String: Any])
        #expect(payload["model"] as? String == input)
        let messages = try #require(payload["messages"] as? [[String: Any]])
        #expect(messages.contains { $0["role"] as? String == "user" && $0["content"] as? String == prompt })
        // Preserve bytes actually captured at recv and sent over the owned socket.
        // No response/provider/request substitute is added for the receipt.
        let served = wire.servedResponses
        try #require(served.count == 2)
        for (index, item) in requests.enumerated() {
            try item.1.write(to: formal.rootDirectory.appendingPathComponent("provider04-request-\(index).body.raw"))
        }
        var servedByteReceipts: [[String: Any]] = []
        for (index, item) in served.enumerated() {
            try item.1.write(to: formal.rootDirectory.appendingPathComponent("provider04-response-\(index).body.json"))
            #expect(item.2 > item.1.count)
            servedByteReceipts.append(["path": item.0, "bodyBytes": item.1.count, "socketSentBytesIncludingHeaders": item.2])
        }
        try JSONSerialization.data(withJSONObject: ["text": response.text, "observedThrough": "production LocalOpenAIProvider actual HTTP decode"],
            options: [.prettyPrinted, .sortedKeys]).write(to: formal.rootDirectory.appendingPathComponent("provider04-actual-provider-response.json"))
        let receipt: [String: Any] = ["inputModel": input, "selectedModel": chat.selectedModelID ?? "",
            "wireModel": payload["model"] as? String ?? "", "endpoint": local.baseURL.absoluteString,
            "paths": requests.map(\.0), "response": response.text, "servedSocketReceipts": servedByteReceipts,
            "actualRequestBodyFiles": requests.indices.map { "provider04-request-\($0).body.raw" },
            "servedResponseBodyFiles": served.indices.map { "provider04-response-\($0).body.json" },
            "providerConstruction": "ChatStore.activeProvider -> LocalOpenAIProvider",
            "credential": "none", "streamingProviderOverrideUsed": false]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: formal.rootDirectory.appendingPathComponent("provider04-custom-model-wire.json"))
        print("PROVIDER04_CUSTOM_INPUT_WIRE_RESPONSE " + String(decoding: data, as: UTF8.self))
    }
}
