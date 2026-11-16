import Darwin
import Foundation
import Testing
@testable import MinisCore

private final class FieldHTTPFixture: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var received = 0
    private var stopped = false
    private var workerStarted = false
    private let response: String
    let port: UInt16

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return received }

    init(response: String) throws {
        self.response = response
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotCreateFile) }
        self.descriptor = descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(descriptor)
            throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            _ = Darwin.close(descriptor)
            throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            _ = Darwin.close(descriptor)
            throw URLError(.cannotConnectToHost)
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            _ = Darwin.close(descriptor)
            throw URLError(.cannotConnectToHost)
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serveOne() }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        // Before worker handoff stop owns the FD; afterwards the worker does.
        if !workerStarted { _ = Darwin.close(descriptor) }
    }

    private func serveOne() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        workerStarted = true
        lock.unlock()
        defer { _ = Darwin.close(descriptor) }

        var client: Int32 = -1
        while client < 0 {
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            guard !shouldStop else { return }

            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            guard event.revents & Int16(POLLIN) != 0 else { return }

            // Nonblocking accept stays bounded even if readiness disappears.
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            client = accept(descriptor, nil, nil)
            let acceptError = errno
            lock.unlock()
            if client < 0, acceptError != EINTR && acceptError != EAGAIN && acceptError != EWOULDBLOCK {
                return
            }
        }
        defer { _ = Darwin.close(client) }
        // Preserve the original blocking client read/write contract on BSD,
        // where accepted sockets may inherit the listener's status flags.
        let clientFlags = fcntl(client, F_GETFL, 0)
        guard clientFlags >= 0, fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        guard recv(client, &buffer, buffer.count, 0) > 0 else { return }
        lock.lock(); received += 1; lock.unlock()
        response.withCString { bytes in
            _ = send(client, bytes, strlen(bytes), 0)
        }
    }
}

@Suite(.serialized)
struct ControlledFieldLoopbackProviderTests {
    private static func provider(_ base: String) throws -> OpenAICompatibleProvider {
        var config = ProviderConfig(
            label: "field-fixture", providerType: .openAI,
            runtimeProviderID: "field-fixture", customBaseURL: base,
            apiKey: "synthetic-field-key"
        )
        config.controlledFieldLoopbackOnly = true
        return try #require(ProviderFactory().makeProvider(for: config) as? OpenAICompatibleProvider)
    }

    @Test func exactLoopbackFactorySendsRealRequest() async throws {
        let body = #"{"id":"field","object":"chat.completion","created":0,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"field-ok"},"finish_reason":"stop"}]}"#
        let server = try FieldHTTPFixture(response:
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        defer { server.stop() }
        let provider = try Self.provider("http://127.0.0.1:\(server.port)")
        let answer = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "field request")],
            systemPrompt: nil, maxTokens: 10, temperature: nil
        )
        #expect(answer.text == "field-ok")
        #expect(server.requestCount == 1)
    }

    @Test func externalBaseAndRedirectAreDeniedBeforeTargetRequest() async throws {
        for base in ["https://example.com", "http://127.0.0.2:9911", "http://localhost.evil.test"] {
            #expect(throws: ProviderFactory.FactoryError.self) { try Self.provider(base) }
        }
        let target = try FieldHTTPFixture(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        defer { target.stop() }
        let source = try FieldHTTPFixture(response:
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { source.stop() }
        let provider = try Self.provider("http://127.0.0.1:\(source.port)")
        await #expect(throws: Error.self) {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "redirect")],
                systemPrompt: nil, maxTokens: 10, temperature: nil
            )
        }
        #expect(source.requestCount == 1)
        #expect(target.requestCount == 0)
        #expect(!ControlledFieldLoopbackPolicy.accepts(URL(string: "https://example.com")!))
    }
}
