@preconcurrency import Network
import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

private final class ProviderLoopbackReadinessServer2687: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "miniscanvas.provider-readiness.2687")
    private let lock = NSLock()
    private var boundPort: UInt16?
    private var startupError: Error?
    private var connections: [UUID: NWConnection] = [:]
    private var paths: [String] = []
    private var syntheticAuthorizationSeen = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock { self.boundPort = self.listener.port?.rawValue }
            case .failed(let error):
                self.lock.withLock { self.startupError = error }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let state = lock.withLock { (boundPort, startupError) }
            if let error = state.1 { throw error }
            if state.0 != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }

    func url(_ path: String) -> URL {
        let port = lock.withLock { boundPort }
        precondition(port != nil)
        return URL(string: "http://127.0.0.1:\(port!)\(path)")!
    }

    var requestPaths: [String] { lock.withLock { paths } }
    var sawSyntheticAuthorization: Bool { lock.withLock { syntheticAuthorizationSeen } }

    func stop() {
        listener.cancel()
        let active = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let connection { self.receive(on: connection) }
            case .failed, .cancelled:
                self.lock.withLock { self.connections[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, accumulated: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 16_384 else { connection.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                guard !complete, error == nil else { connection.cancel(); return }
                self.receive(on: connection, accumulated: bytes)
                return
            }
            let request = String(decoding: bytes, as: UTF8.self)
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ", maxSplits: 2)
                .dropFirst().first.map(String.init) ?? "/"
            self.lock.withLock {
                self.paths.append(path)
                if request.lowercased().contains("authorization: bearer synthetic-local\r\n") {
                    self.syntheticAuthorizationSeen = true
                }
            }
            let response: Data
            if path.hasPrefix("/redirect") {
                response = Data((
                    "HTTP/1.1 302 Found\r\n" +
                    "Location: https://outside.invalid/blocked\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n"
                ).utf8)
            } else {
                let body = "{\"status\":\"reachable\"}"
                response = Data((
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                    "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                ).utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@Suite("D-PROVIDER-01/02 packaged field loopback readiness", .serialized)
@MainActor
struct ProviderLoopbackReadiness2687Tests {
    @Test("packaged session field alone acquires loopback readiness transport")
    func compositionRequiresExactFieldAndPreparedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-field-2687-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "provider-field-2687",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: [
                "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(ProviderReadinessTransportComposition.make(
            profile: profile,
            sessionFieldJourney: true,
            sessionFieldPreparationSucceeded: true
        ) is ControlledLoopbackProviderReadinessTransport)
        #expect(ProviderReadinessTransportComposition.make(
            profile: profile,
            sessionFieldJourney: false,
            sessionFieldPreparationSucceeded: true
        ) is FailClosedProviderReadinessTransport)
        #expect(ProviderReadinessTransportComposition.make(
            profile: profile,
            sessionFieldJourney: true,
            sessionFieldPreparationSucceeded: false
        ) is FailClosedProviderReadinessTransport)
    }

    @Test("real loopback request succeeds; external, alias and redirect never leave loopback")
    func realSocketAndNegativeDestinations() async throws {
        let server = try ProviderLoopbackReadinessServer2687()
        defer { server.stop() }
        try await server.waitUntilReady()
        let transport = ControlledLoopbackProviderReadinessTransport()
        #expect(transport.canProduceLiveEvidence)
        let success = try await transport.send(request(server.url("/v1")))
        #expect(success.statusCode == 200)
        #expect(success.errorCategory == nil)
        #expect(server.requestPaths == ["/v1"])
        #expect(server.sawSyntheticAuthorization)

        for raw in [
            "https://outside.invalid/v1", "http://localhost.evil.invalid/v1",
            "http://127.0.0.2/v1", "http://[::2]/v1"
        ] {
            let destination = try #require(URL(string: raw))
            await #expect(throws: SettingsProviderReadinessTransportError.invalidURL) {
                try await transport.send(request(destination))
            }
        }
        #expect(server.requestPaths == ["/v1"])
        await #expect(throws: SettingsProviderReadinessTransportError.redirectRejected) {
            // 地址带版本段（/v1）时不再补 /v1，请求路径就是 /redirect/v1。
            try await transport.send(request(server.url("/redirect/v1")))
        }
        #expect(server.requestPaths == ["/v1", "/redirect/v1"])
    }

    private func request(_ baseURL: URL) -> ProviderReadinessTransportRequest {
        ProviderReadinessTransportRequest(
            operation: .reachability,
            providerID: "synthetic-local-2687",
            baseURL: baseURL,
            apiKey: "synthetic-local",
            modelID: nil,
            protocolType: .openaiCompatible
        )
    }
}
