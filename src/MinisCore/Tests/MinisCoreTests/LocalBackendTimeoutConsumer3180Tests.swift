import Foundation
import Network
import Testing
@testable import MinisCore

// Reuses the existing WrapperLoopbackSSE 127.0.0.1 listener pattern. Its
// private SSE/single-connection fixture cannot hold concurrent GETs or join
// their terminal states. This fixture only controls real HTTP wire delivery;
// the SUT is the unmodified LocalBackends instance, never a mirrored lock.
private final class OwnedBackendHTTP3180: @unchecked Sendable {
    struct Snapshot: Sendable {
        let paths: [String]
        let connectionCount: Int
        let terminalCount: Int
        let listenerTerminal: Bool
        let responses: Int
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned.backend.timeout.3180")
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var paths: [UUID: String] = [:]
    private var terminal: Set<UUID> = []
    private var listenerTerminal = false
    private var allowResponses = false
    private var responses = 0
    private var port: UInt16 = 0
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed: ready.signal()
            case .cancelled: self?.listenerTerminal = true
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            self.buffers[id] = Data()
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.terminal.insert(id) }
            }
            connection.start(queue: self.queue)
            self.receiveHeaders(connection, id: id)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success,
              let bound = listener.port else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        port = bound.rawValue
    }

    private func receiveHeaders(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let data { self.buffers[id, default: Data()].append(data) }
            if let buffer = self.buffers[id],
               let end = buffer.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
                let first = header.components(separatedBy: "\r\n").first ?? ""
                self.paths[id] = String(first.split(separator: " ").dropFirst().first ?? "")
                if self.allowResponses {
                    self.sendModels(connection, marker: "next-legal-3180")
                } else {
                    // No response or fixture timer closes this request. Its
                    // real URLSession request deadline must produce the error.
                    self.watchEOF(connection)
                }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveHeaders(connection, id: id)
            }
        }
    }

    private func watchEOF(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            if complete || error != nil { connection.cancel() }
            else { self?.watchEOF(connection) }
        }
    }

    private func sendModels(_ connection: NWConnection, marker: String) {
        responses += 1
        let body = "{\"models\":[{\"name\":\"\(marker)\"}]}"
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(wire.utf8), contentContext: .finalMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { connection.cancel() }
            else { self?.watchEOF(connection) }
        })
    }

    func releaseOldAndAllowNew() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                allowResponses = true
                for (id, connection) in connections where paths[id] != nil && !terminal.contains(id) {
                    sendModels(connection, marker: "late-retired-3180")
                }
                continuation.resume()
            }
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Snapshot(
                    paths: Array(paths.values), connectionCount: connections.count,
                    terminalCount: terminal.count, listenerTerminal: listenerTerminal,
                    responses: responses
                ))
            }
        }
    }

    func stopAndJoin() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                listener.cancel()
                connections.values.forEach { $0.cancel() }
                continuation.resume()
            }
        }
        for _ in 0..<300 {
            let current = await snapshot()
            if current.listenerTerminal && current.terminalCount == current.connectionCount {
                return current
            }
            // Bounded polling observes actual cancelled callbacks; it does not
            // choose request order, fabricate timeout, or claim internal NW reap.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await snapshot()
    }
}

private struct BackendDeadlineResult3180: Sendable {
    let domain: String
    let code: Int
    let returnedModels: Bool
}

@Suite("Actual LocalBackends timeout mutation and owned HTTP", .serialized)
struct LocalBackendTimeoutConsumer3180Tests {
    @Test func parallelTimeoutMutationFeedsRealOwnedRequestDeadlinesAndJoins() async throws {
        let server = try OwnedBackendHTTP3180()
        let backend = LocalBackends(configs: [
            .ollama: LocalBackendConfig(kind: .ollama, baseURL: server.baseURL, enabled: true)
        ])
        #expect(backend.probeTimeout == 2.0)
        // Preserve supported public value storage; do not add validation policy.
        for value in [0.0, -1.0, Double.infinity, Double.nan, Double.leastNormalMagnitude] {
            backend.probeTimeout = value
            #expect(backend.probeTimeout.bitPattern == value.bitPattern)
        }
        backend.probeTimeout = 0.3
        let writer = Task.detached {
            let values: [TimeInterval] = [0.15, 0.2, 0.3]
            var writes = 0
            while !Task.isCancelled {
                backend.probeTimeout = values[writes % values.count]
                writes += 1
                if writes % 64 == 0 { await Task.yield() }
            }
            return writes
        }
        // The real probeSession admits six connections per host. Seven held
        // requests in one wave can legitimately time out before one reaches
        // the listener. Keep all seven calls and the continuous setter, but
        // observe the actual detect request's deadline and terminal first.
        let detected = await backend.detect()
        #expect(detected[.ollama] == false)
        let detectedHeld = await server.snapshot()
        #expect(detectedHeld.paths == ["/api/tags"])
        #expect(detectedHeld.responses == 0)
        var detectedJoined = detectedHeld
        for _ in 0..<300 {
            detectedJoined = await server.snapshot()
            if detectedJoined.connectionCount == 1 && detectedJoined.terminalCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(detectedJoined.connectionCount == 1)
        #expect(detectedJoined.terminalCount == 1)
        #expect(!detectedJoined.listenerTerminal)
        // Six model-list requests now fit the same production connection pool.
        // They still race the same writer and must all time out on actual wire.
        let outcomes = await withTaskGroup(of: BackendDeadlineResult3180.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await backend.ollamaModels()
                        return BackendDeadlineResult3180(domain: "", code: 0, returnedModels: true)
                    } catch {
                        let failure = error as NSError
                        return BackendDeadlineResult3180(domain: failure.domain, code: failure.code,
                                                         returnedModels: false)
                    }
                }
            }
            var results: [BackendDeadlineResult3180] = []
            for await result in group { results.append(result) }
            return results
        }
        writer.cancel()
        let writes = await writer.value
        #expect(writes > 0)
        #expect(outcomes.count == 6)
        #expect(outcomes.allSatisfy { !$0.returnedModels && $0.domain == NSURLErrorDomain && $0.code == NSURLErrorTimedOut })
        let held = await server.snapshot()
        #expect(held.paths.count >= 7)
        #expect(held.paths.allSatisfy { $0 == "/api/tags" })
        #expect(held.responses == 0)
        await server.releaseOldAndAllowNew()
        backend.probeTimeout = 2.0
        do {
            let models = try await backend.ollamaModels()
            #expect(models == ["next-legal-3180"])
            #expect(!models.contains("late-retired-3180"))
        } catch {
            let failure = error as NSError
            Issue.record("next legal owned request failed: domain=\(failure.domain) code=\(failure.code)")
        }
        let joined = await server.stopAndJoin()
        #expect(joined.listenerTerminal)
        #expect(joined.connectionCount > 0)
        #expect(joined.terminalCount == joined.connectionCount)
        print("LOCAL_TIMEOUT_3180 writer_joined=true writes=\(writes) requests_joined=\(outcomes.count + 1) received=\(joined.paths.count) connection_terminals=\(joined.terminalCount)/\(joined.connectionCount) listener_terminal=\(joined.listenerTerminal)")
    }
}
