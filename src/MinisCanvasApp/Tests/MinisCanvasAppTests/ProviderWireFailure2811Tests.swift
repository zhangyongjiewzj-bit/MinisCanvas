import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class ProviderFailureWire2811: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var count = 0
    private let reply: String?
    let port: UInt16

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(status: Int? = nil) throws {
        reply = status.map { code in
            let body = "remote-body-must-not-be-shown"
            return "HTTP/1.1 \(code) Failure\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotCreateFile) }
        listener = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd)
            throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            _ = Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else {
            _ = Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }

    deinit { _ = Darwin.shutdown(listener, SHUT_RDWR); _ = Darwin.close(listener) }

    private func serve() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { _ = Darwin.close(client) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        guard recv(client, &buffer, buffer.count, 0) > 0 else { return }
        lock.lock(); count += 1; lock.unlock()
        if let reply {
            reply.withCString { bytes in _ = send(client, bytes, strlen(bytes), 0) }
        } else {
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

@Suite("D-PROVIDER-11 production factory wire failures", .serialized)
@MainActor
struct ProviderWireFailure2811Tests {
    private func config(_ port: UInt16, key: String? = "synthetic-provider-key") -> ProviderConfig {
        var value = ProviderConfig(
            label: "synthetic-provider", providerType: .openAI,
            runtimeProviderID: "synthetic-provider",
            customBaseURL: "http://127.0.0.1:\(port)", apiKey: key
        )
        value.controlledFieldLoopbackOnly = true
        return value
    }

    @Test("real URLSession HTTP failures stay distinct from factory to ChatStore")
    func statusMatrix() async throws {
        let cases: [(Int, ProviderRequestFailureKind)] = [
            (401, .unauthorized), (403, .permissionDenied), (404, .notFound),
            (429, .rateLimited), (500, .server), (503, .server)
        ]
        var visible: [Int: String] = [:]
        for (status, expected) in cases {
            let wire = try ProviderFailureWire2811(status: status)
            let provider = try ProviderFactory().makeProvider(for: config(wire.port))
            do {
                _ = try await provider.sendMessage(
                    messages: [LLMMessage(role: .user, content: "synthetic")],
                    systemPrompt: nil, maxTokens: 16, temperature: nil
                )
                Issue.record("HTTP \(status) unexpectedly succeeded")
            } catch {
                #expect(ProviderRequestFailureKind.classify(error) == expected)
                let message = ChatStore.userErrorMessage(error)
                #expect(message.contains("\(status)"))
                #expect(!message.contains("remote-body-must-not-be-shown"))
                visible[status] = message
            }
            #expect(wire.requestCount == 1)
        }
        #expect(visible[401] != visible[403])
        #expect(visible[403] != visible[404])
        #expect(visible[429] != visible[503])
    }

    @Test("factory missing credential is classified and shown as unconfigured")
    func missingCredential() throws {
        var missing = config(1, key: nil)
        missing.label = "provider-label-must-not-be-shown"
        do {
            _ = try ProviderFactory().makeProvider(for: missing)
            Issue.record("missing key unexpectedly admitted")
        } catch {
            #expect(ProviderRequestFailureKind.classify(error) == .unconfigured)
            let message = ChatStore.userErrorMessage(error)
            #expect(message.contains("未配置"))
            #expect(!message.contains("provider-label-must-not-be-shown"))
        }
    }

    @Test("real URLSession timeout and cancellation remain distinguishable")
    func timeoutAndCancellation() async throws {
        for expected in [ProviderRequestFailureKind.timeout, .cancelled] {
            let wire = try ProviderFailureWire2811()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = expected == .timeout ? 0.2 : 5
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let provider = OpenAICompatibleProvider(
                apiKey: "synthetic-provider-key",
                customBaseURL: "http://127.0.0.1:\(wire.port)",
                session: session
            )
            let request = Task {
                try await provider.sendMessage(
                    messages: [LLMMessage(role: .user, content: "synthetic")],
                    systemPrompt: nil, maxTokens: 16, temperature: nil
                )
            }
            if expected == .cancelled {
                for _ in 0..<100 where wire.requestCount == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(wire.requestCount == 1)
                request.cancel()
            }
            do {
                _ = try await request.value
                Issue.record("\(expected.rawValue) unexpectedly succeeded")
            } catch {
                #expect(ProviderRequestFailureKind.classify(error) == expected)
                let message = ChatStore.userErrorMessage(error)
                #expect(!message.contains("remote-body-must-not-be-shown"))
                #expect(!message.isEmpty)
            }
            #expect(wire.requestCount == 1)
        }
    }
}
