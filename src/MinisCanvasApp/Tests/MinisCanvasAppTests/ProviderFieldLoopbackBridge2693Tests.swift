import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class FieldBridgeHTTPServer2693: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var count = 0
    private let response: String
    let port: UInt16

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(response: String) throws {
        self.response = response
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw URLError(.cannotConnectToHost) }
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
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serveOne() }
    }

    deinit { _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor) }

    private func serveOne() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { _ = Darwin.close(client) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        guard recv(client, &buffer, buffer.count, 0) > 0 else { return }
        lock.lock(); count += 1; lock.unlock()
        response.withCString { bytes in _ = send(client, bytes, strlen(bytes), 0) }
    }
}

@Suite("D-PROVIDER-01/02 field Bridge real provider route", .serialized)
@MainActor
struct ProviderFieldLoopbackBridge2693Tests {
    private static let modelID = "field-model"
    private static let providerID = "FIELD_SYNTHETIC_API_KEY"
    private static let evidenceID = "live-settings:" + String(repeating: "a", count: 64)

    @Test("Bridge production route sends to exact loopback; remote and redirect stay request-free")
    func realBridgeRouteAndNegativeDestinations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("field-bridge-2693-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "data: " + #"{"choices":[{"index":0,"delta":{"content":"bridge-ok"},"finish_reason":"stop"}]}"#
            + "\n\ndata: [DONE]\n\n"
        let server = try FieldBridgeHTTPServer2693(response:
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("Readiness"))
        let sessionStore = SessionStore(directory: root.appendingPathComponent("Sessions"))
        let bridge = BridgeStore(sessionStore: sessionStore, providerReadinessStore: readiness)
        defer { bridge.chat.stopAllStreamingForSafety() }
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, sessionDirectory: sessionStore.directory,
            externalNetworkAllowed: false, controlledFieldLoopbackAllowed: true
        ).value
        #expect(!bridge.productionExternalNetworkAllowed)
        #expect(bridge.productionControlledFieldLoopbackAllowed)
        bridge.chat.newSession(
            projectID: "field-2693", projectName: "Synthetic field provider",
            workingDirectory: root.path
        )
        let sessionID = try #require(bridge.chat.activeSessionID)

        let record = EnvVarEntry(
            name: Self.providerID, value: "synthetic-field-key", isSecret: true,
            baseURL: "http://127.0.0.1:\(server.port)",
            modelNames: [Self.modelID], protocolType: .openaiCompatible
        )
        bridge.chat.providerRecordsSource = { [record] }
        bridge.chat.schedulerCredentialVersionSource = { _ in "synthetic-revision" }
        readiness.upsert(ProviderReadinessPersistenceRecord(
            providerID: Self.providerID, modelID: Self.modelID,
            status: .passed, readinessState: .live, checkedAt: Date(),
            evidenceID: Self.evidenceID, isApplied: true
        ))
        #expect(bridge.chat.applyChatModel(providerID: Self.providerID, modelID: Self.modelID))
        let primary = try bridge.chat.activeProvider()
        let controlled = try #require(primary as? OpenAICompatibleProvider)
        #expect(controlled.controlledFieldLoopbackOnly)
        let routeFactory = try #require(bridge.chat.providerRuntimeRouteFactory)
        #expect(routeFactory(primary) != nil)
        let previousIDs = Set(bridge.chat.messages.map(\.id))
        bridge.chat.draftText = "field bridge"
        bridge.chat.submitComposer()
        // Concrete Provider construction crosses the production preparation
        // worker before the turn exists. A fast loopback turn may also settle
        // before a test can capture its Task, so observe its published result.
        var completed = false
        for _ in 0..<1_000 {
            completed = bridge.chat.messages.contains {
                $0.role == .assistant && !previousIDs.contains($0.id)
            } && !bridge.chat.isStreaming
            if completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(completed, "production Composer turn must publish a final assistant")
        #expect(!bridge.chat.isStreaming)
        let assistants = bridge.chat.messages.filter {
            $0.role == .assistant && !previousIDs.contains($0.id)
        }
        #expect(assistants.count == 1)
        #expect(assistants.first?.content.contains("bridge-ok") == true)
        #expect(server.requestCount == 1)
        let persisted = try #require(sessionStore.loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.last?.role == .assistant)
        #expect(persisted.messages.last?.content.contains("bridge-ok") == true)

        var remote = ProviderConfig(
            label: "remote-denied", providerType: .openAI,
            runtimeProviderID: "remote-denied", customBaseURL: "https://outside.invalid",
            apiKey: "synthetic-field-key"
        )
        remote.controlledFieldLoopbackOnly = false
        let remoteProvider = try ProviderFactory().makeProvider(for: remote)
        #expect(routeFactory(remoteProvider) == nil)
        #expect(server.requestCount == 1)

        let target = try FieldBridgeHTTPServer2693(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        let redirect = try FieldBridgeHTTPServer2693(response:
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(target.port)/v1/chat/completions\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        var redirectConfig = ProviderConfig(
            label: "redirect-fixture", providerType: .openAI,
            runtimeProviderID: "redirect-fixture",
            customBaseURL: "http://127.0.0.1:\(redirect.port)",
            apiKey: "synthetic-field-key"
        )
        redirectConfig.controlledFieldLoopbackOnly = true
        let redirectProvider = try ProviderFactory().makeProvider(for: redirectConfig)
        // The production gate admits this source, while its concrete transport
        // must reject the 302 before the target sees any request.
        #expect(routeFactory(redirectProvider) == nil) // No readiness receipt for this identity.
        await #expect(throws: Error.self) {
            try await redirectProvider.sendMessage(
                messages: [LLMMessage(role: .user, content: "redirect")],
                systemPrompt: nil, maxTokens: 10, temperature: nil
            )
        }
        #expect(redirect.requestCount == 1)
        #expect(target.requestCount == 0)
        #expect(ControlledFieldLoopbackSession.make().configuration
            .connectionProxyDictionary?["HTTPEnable"] as? Int == 0)
    }
}
