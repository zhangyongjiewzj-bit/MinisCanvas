import Foundation
import Network
import Testing
@testable import MinisCore

enum HeldHTTPStreamFamily: String, CaseIterable, Sendable {
    case openAICompatible, anthropic, responses

    func delta(_ text: String) -> String {
        switch self {
        case .openAICompatible:
            return "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n"
        case .responses:
            return "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"\(text)\"}\n\n"
        case .anthropic:
            return "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n"
        }
    }

    var terminal: String {
        switch self {
        case .openAICompatible: return "data: [DONE]\n\n"
        case .responses: return "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_owned_fresh\",\"status\":\"completed\"}}\n\n"
        case .anthropic: return "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        }
    }
}

// All socket ownership and mutable connection state stays on queue. The
// lock protects only the immutable snapshots read by the actual consumer.
private final class HeldHTTPStreamServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CONC2.held-http-stream.owned")
    private let listener: NWListener
    private let family: HeldHTTPStreamFamily
    private let lock = NSLock()
    private var requestBodies: [Data] = []
    private var peerClosed = false
    private var watchdogCount = 0
    private var connections: [Int: NWConnection] = [:]
    private var received: [Int: Data] = [:]
    private var forcedConnections: Set<Int> = []
    private var nextID = 0
    private var stopping = false
    private var listenerCancelled = false
    private var peerWaiter: CheckedContinuation<Bool, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)" }

    init(family: HeldHTTPStreamFamily) throws {
        self.family = family
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .failed: ready.signal()
            case .cancelled:
                guard let self else { return }
                self.listenerCancelled = true; self.finishStopIfJoined()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.nextID += 1
            let id = self.nextID
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .cancelled = state {
                    self.connections.removeValue(forKey: id)
                    self.finishStopIfJoined()
                }
            }
            connection.start(queue: self.queue)
            self.readRequest(id, connection)
            // Failure-only watchdog, never used to satisfy peer-close or join.
            self.queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, !self.stopping, self.connections[id] != nil else { return }
                self.forcedConnections.insert(id)
                self.lock.withLock { self.watchdogCount += 1 }
                connection.cancel()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success,
              let port = listener.port, port.rawValue != 0 else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    private func readRequest(_ id: Int, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received[id, default: Data()].append(data) }
            let bytes = self.received[id, default: Data()]
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) {
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = bytes[boundary.upperBound...]
                if body.count >= length {
                    let payload = Data(body.prefix(length))
                    self.lock.withLock { self.requestBodies.append(payload) }
                    let text = id == 1 ? "old-first" : "fresh-positive"
                    let prefix = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                    self.send(connection, prefix + self.chunk(self.family.delta(text)))
                    if id == 1 {
                        self.readOldPeerClose(id, connection)
                    } else {
                        self.send(connection, self.chunk(self.family.terminal) + "0\r\n\r\n", close: true)
                    }
                    return
                }
            }
            if !complete && error == nil { self.readRequest(id, connection) }
        }
    }

    private func readOldPeerClose(_ id: Int, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                guard !self.stopping, !self.forcedConnections.contains(id) else { return }
                self.lock.withLock { self.peerClosed = true }
                print("CONC2_HTTP_PEER_TERMINAL family=\(self.family.rawValue) connection=\(id) eof=\(complete) error=\(String(describing: error))")
                let waiter = self.peerWaiter; self.peerWaiter = nil; waiter?.resume(returning: true)
            } else { self.readOldPeerClose(id, connection) }
        }
    }

    func releaseLateOldDelta() {
        queue.async { [self] in
            guard let old = connections[1] else { return }
            // Deliberately no terminal or EOF: closing the old request must
            // come from the cancelled production transport, not this fixture.
            send(old, chunk(family.delta("late-old-forbidden")))
        }
    }

    func awaitOldPeerClosed() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if lock.withLock({ peerClosed }) { continuation.resume(returning: true); return }
                peerWaiter = continuation
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, let pending = self.peerWaiter else { return }
                    self.peerWaiter = nil; pending.resume(returning: false)
                }
            }
        }
    }

    func stopAndJoin() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopping = true; stopWaiter = continuation
                listener.cancel()
                for connection in connections.values { connection.cancel() }
                finishStopIfJoined()
            }
        }
    }

    private func finishStopIfJoined() {
        guard stopping, listenerCancelled, connections.isEmpty else { return }
        let pending = stopWaiter; stopWaiter = nil; pending?.resume()
    }

    func snapshots() -> (bodies: [Data], peerClosed: Bool, watchdog: Int) {
        lock.withLock { (requestBodies, peerClosed, watchdogCount) }
    }

    private func chunk(_ value: String) -> String { "\(String(value.utf8.count, radix: 16))\r\n\(value)\r\n" }
    private func send(_ connection: NWConnection, _ text: String, close: Bool = false) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in if close { connection.cancel() } })
    }
}

private actor HeldHTTPStreamEvents {
    private(set) var text: [String] = []
    private(set) var finished = 0
    func append(_ chunk: LLMStreamChunk) {
        switch chunk { case .text(let value): text.append(value); case .finished: finished += 1; default: break }
    }
}

@Suite("CONC2 real held HTTP stream cancellation and next request", .serialized)
struct ProviderHeldHTTPStreamLifetimeCurrentConsumerTests {
    @Test("ordinary provider stream cancels its held transport before next legal request", arguments: [HeldHTTPStreamFamily.openAICompatible, .anthropic])
    func cancellationOwnsTransportAndRejectsLateDelta(_ family: HeldHTTPStreamFamily) async throws {
        try await exerciseHeldTransport(family)
    }

    @Test("Responses held wire cancellation closes old transport before fresh owned attempt")
    func responsesCancellationRejectsLateWireAndAllowsNextOwnedAttempt() async throws {
        try await exerciseHeldTransport(.responses)
    }

    private func exerciseHeldTransport(_ family: HeldHTTPStreamFamily) async throws {
        let server = try HeldHTTPStreamServer(family: family)
        let session = URLSession(configuration: .ephemeral)
        let provider: any LLMProvider
        switch family {
        case .openAICompatible:
            provider = OpenAICompatibleProvider(apiKey: "owned-synthetic-key", customBaseURL: server.baseURL, session: session)
        case .anthropic:
            provider = AnthropicProvider(apiKey: "owned-synthetic-key", basePath: server.baseURL, session: session)
        case .responses:
            let paths = try #require(FormalTestIsolationPaths.currentOrFail())
            let checkpoint = paths.rootDirectory.appendingPathComponent("responses-held-" + UUID().uuidString, isDirectory: true)
            provider = OpenAIResponsesProvider(apiKey: "owned-synthetic-key", model: .gpt4oMini,
                customBaseURL: server.baseURL, appendV1Suffix: true, session: session,
                providerName: "OpenAI Responses", attemptCheckpointDirectory: checkpoint)
        }
        do {
        let events = HeldHTTPStreamEvents()
        let stream = try await provider.streamMessage(messages: [LLMMessage(role: .user, content: "owned-first")], systemPrompt: nil, maxTokens: 32, temperature: nil)
        let consumer = Task { for try await chunk in stream { await events.append(chunk) } }
        let firstDeadline = ContinuousClock.now + .seconds(3)
        while await events.text.isEmpty && ContinuousClock.now < firstDeadline { await Task.yield() }
        #expect(await events.text == ["old-first"])
        consumer.cancel()
        server.releaseLateOldDelta()
        do { try await consumer.value }
        catch { #expect(ProviderRequestFailureKind.classify(error) == .cancelled) }
        #expect(await events.text == ["old-first"])
        #expect(await events.finished == 0)
        let peerClosedBeforeFixtureStop = await server.awaitOldPeerClosed()
        #expect(peerClosedBeforeFixtureStop, "held old wire must close without server terminal/EOF or fixture cancellation")

        var freshText: [String] = []; var freshFinished = 0
        let fresh = try await provider.streamMessage(messages: [LLMMessage(role: .user, content: "owned-next")], systemPrompt: nil, maxTokens: 32, temperature: nil)
        for try await chunk in fresh {
            switch chunk { case .text(let value): freshText.append(value); case .finished: freshFinished += 1; default: break }
        }
        #expect(freshText == ["fresh-positive"])
        #expect(freshFinished == 1)
        #expect(await events.text == ["old-first"])
        #expect(await events.finished == 0)
        let snapshots = server.snapshots()
        #expect(snapshots.bodies.count == 2)
        #expect(snapshots.watchdog == 0, "watchdog close is a failure, not physical transport evidence")
        for body in snapshots.bodies {
            let object = try JSONSerialization.jsonObject(with: body)
            let request = try #require(object as? [String: Any])
            #expect(request["stream"] as? Bool == true)
        }
        session.invalidateAndCancel()
        await server.stopAndJoin()
        print("CONC2_HTTP_FIXTURE_JOIN family=\(family.rawValue) listenerCancelled=true connectionsCancelled=true providerRequests=\(snapshots.bodies.count)")
        } catch {
            session.invalidateAndCancel()
            await server.stopAndJoin()
            throw error
        }
    }
}
