import Darwin
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Test-only actual TCP server: exact 127.0.0.1, ephemeral port, at most five
/// accepted connections. No request/header/body is retained or printed.
private final class MM01FiveLocalResponses: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let listener: Int32
    private var client: Int32?
    private var stopped = false
    private var requestLines: [String] = []
    private var accepted = 0
    private var parsed = 0
    private var rejected = 0
    private var closedClients = 0
    private var closeErrors = 0
    private var acceptErrno: Int32?
    private var acceptErrorAfterStop: Bool?
    private var responsesSent = 0
    private var recvErrno: Int32?
    private var listenerCloseResult: Int32?
    private var joinSucceeded: Bool?
    struct Diagnostics: Encodable {
        let port: UInt16
        let accepted: Int
        let parsed: Int
        let legalRequests: Int
        let rejected: Int
        let closedClients: Int
        let closeErrors: Int
        let acceptErrno: Int32?
        let acceptErrorAfterStop: Bool?
        let responsesSent: Int
        let recvErrno: Int32?
        let listenerCloseResult: Int32?
        let joinSucceeded: Bool?
        let clientStillOwned: Bool
        let legalRoutes: [String]
    }
    var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(port: port, accepted: accepted, parsed: parsed,
            legalRequests: requestLines.count, rejected: rejected,
            closedClients: closedClients, closeErrors: closeErrors,
            acceptErrno: acceptErrno, acceptErrorAfterStop: acceptErrorAfterStop,
            responsesSent: responsesSent, recvErrno: recvErrno,
            listenerCloseResult: listenerCloseResult, joinSucceeded: joinSucceeded,
            clientStillOwned: client != nil, legalRoutes: requestLines)
    }
    let port: UInt16
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return requestLines }
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        listener = fd
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET); a.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &a.sin_addr) == 1 else {
            Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else { Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        port = UInt16(bigEndian: a.sin_port)
        group.enter()
        DispatchQueue.global().async { [self] in serve(); group.leave() }
    }
    func stopAndJoin() -> Bool {
        lock.lock()
        if !stopped {
            stopped = true
            if let client { _ = Darwin.shutdown(client, SHUT_RDWR) }
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            let closeResult = Darwin.close(listener)
            listenerCloseResult = closeResult
            lock.unlock()
            let joined = group.wait(timeout: .now() + 3) == .success
            lock.lock(); joinSucceeded = joined; lock.unlock()
            return joined && closeResult == 0
        }
        lock.unlock()
        let joined = group.wait(timeout: .now() + 3) == .success
        lock.lock(); joinSucceeded = joined; lock.unlock()
        return joined
    }
    private func serve() {
        for ordinal in 1...5 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                let code = errno
                lock.lock(); acceptErrno = code; acceptErrorAfterStop = stopped; lock.unlock()
                return
            }
            lock.lock(); accepted += 1; client = fd; let stop = stopped; lock.unlock()
            if stop { closeClient(fd); return }
            respond(fd, ordinal: ordinal)
            closeClient(fd)
        }
    }
    private func closeClient(_ fd: Int32) {
        lock.lock()
        if client == fd { client = nil }
        let rc = Darwin.close(fd)
        if rc == 0 { closedClients += 1 } else { closeErrors += 1 }
        lock.unlock()
    }
    private func respond(_ fd: Int32, ordinal: Int) {
        var noSignal: Int32 = 1, timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        var totalRequired: Int?
        while received.count < 65_536 {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else {
                let code: Int32 = n < 0 ? errno : 0
                lock.lock(); recvErrno = code; lock.unlock()
                return
            }
            received.append(contentsOf: buffer.prefix(n))
            if totalRequired == nil, let boundary = received.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                // Persist only a closed, nonsecret method/path classification.
                let parts = (lines.first ?? "").split(separator: " ")
                guard parts.count == 3 else {
                    lock.lock(); rejected += 1; lock.unlock(); return
                }
                lock.lock(); parsed += 1; lock.unlock()
                let expected: [(String, String)] = [
                    ("GET", "/v1"), ("GET", "/v1/models"), ("GET", "/v1/models"),
                    ("POST", "/v1/chat/completions"), ("POST", "/chat/completions")
                ]
                let route = expected[ordinal - 1]
                guard parts[0] == route.0, parts[1] == route.1 else {
                    lock.lock(); rejected += 1; lock.unlock(); return
                }
                lock.lock(); requestLines.append(route.0 + " " + route.1); lock.unlock()
                let lengthLine = lines.first { $0.lowercased().hasPrefix("content-length:") }
                let length = lengthLine.flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard (0...32_768).contains(length) else { return }
                totalRequired = boundary.upperBound + length
            }
            if let totalRequired, received.count >= totalRequired { break }
        }
        guard let totalRequired, received.count >= totalRequired else { return }
        let body: String
        let type: String
        if ordinal == 5 {
            type = "text/event-stream"
            body = "data: {\"id\":\"local\",\"choices\":[{\"delta\":{\"content\":\"local-stream-ok\"},\"finish_reason\":null}]}\n\ndata: [DONE]\n\n"
        } else if ordinal == 4 {
            type = "application/json"
            body = #"{"id":"local","choices":[{"message":{"role":"assistant","content":"local-ok"},"finish_reason":"stop"}]}"#
        } else {
            type = "application/json"
            body = #"{"data":[{"id":"deepseek-flash"}]}"#
        }
        let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
        var responseComplete = false
        response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                guard n > 0 else { return }; offset += n
            }
            responseComplete = true
        }
        if responseComplete { lock.lock(); responsesSent += 1; lock.unlock() }
    }
}

private final class MM01LocalAuditRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [OwnedMMOutboundRecord] = []
    private var cancellationIssued = false
    func append(_ row: OwnedMMOutboundRecord) { lock.lock(); rows.append(row); lock.unlock() }
    var values: [OwnedMMOutboundRecord] { lock.lock(); defer { lock.unlock() }; return rows }
    func cancelCurrentProducerIfPresent() {
        withUnsafeCurrentTask { task in
            guard let task else { return }
            task.cancel()
            lock.lock(); cancellationIssued = true; lock.unlock()
        }
    }
    var didCancelProducer: Bool { lock.lock(); defer { lock.unlock() }; return cancellationIssued }
}
private struct MM01LocalServerCloseReceipt: Encodable {
    let scope = "TEST_ONLY_NOT_UI_OR_MM_LANE"
    let schema = "MM01_LOCAL_SERVER_ACTUAL_CLOSE_V1"
    let server: MM01FiveLocalResponses.Diagnostics
}
private struct MM01LocalAuditEnvelope: Encodable {
    let provenanceScope = "SYNTHETIC_SDK_ACTION_NOT_UI_OR_MM_LANE"
    let record: OwnedMMOutboundRecord
}

@Suite("MM01 same-ledger actual loopback adapter chain, not UI", .serialized)
@MainActor struct MM01OwnedSessionLoopbackIntegrationTests {
    @Test("real Foundation data4 plus bytes1 metrics on same product, synthetic local policy only")
    func actualDataFourThenBytesOneMetricsWithSyntheticWindow() async throws {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        _ = try #require(resolved)
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deadline = Date().addingTimeInterval(60)
        #expect(policy.arm())
        try #require(policy.install(nonce: nonce, limit: 1, deadline: deadline))
        let metadata = try #require(policy.activeWindow)
        let rows = MM01LocalAuditRows()
        let ledger = OwnedMMOutboundLedger(runIdentity: "TEST_ONLY_NOT_UI_LOCAL_ADAPTER:" + nonce,
            windowNonce: metadata.nonce, deadline: metadata.deadline,
            windowIsCurrent: { policy.activeWindow?.nonce == metadata.nonce && policy.activeWindow?.deadline == metadata.deadline },
            sink: { row in
                rows.append(row)
                var data = try JSONEncoder().encode(MM01LocalAuditEnvelope(record: row)); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            })
        let server = try MM01FiveLocalResponses()
        defer {
            #expect(server.stopAndJoin())
            // Always emit actual safe counts/closure, even after the first throw.
            // No lower CFNetwork error is available through the existing private
            // production task delegate; do not fabricate it from .unavailable.
            do {
                var data = try JSONEncoder().encode(MM01LocalServerCloseReceipt(server: server.diagnostics)); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { Issue.record("Test-only server receipt write failed") }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = try #require(URL(string: "http://127.0.0.1:\(server.port)"))
        let transport = URLSessionProviderReadinessTransport(session: session, ownedMMOutboundLedger: ledger)
        let action = try ledger.beginAction(.providerReadinessButton) // SYNTHETIC test action, never UI proof
        let operations: [ProviderReadinessOperation] = [.reachability, .authentication, .modelDiscovery, .minimalModelRequest("deepseek-flash")]
        for operation in operations {
            let modelID: String?
            if case .minimalModelRequest = operation { modelID = "deepseek-flash" } else { modelID = nil }
            var request = ProviderReadinessTransportRequest(operation: operation, providerID: "synthetic-local",
                baseURL: base, apiKey: "[configured locally]",
                modelID: modelID,
                protocolType: .openaiCompatible)
            request.ownedMMAction = action
            let response = try await transport.send(request)
            try #require(response.statusCode == 200 && response.errorCategory == nil)
        }
        let visual = try ledger.beginAction(.composerSendButton) // SYNTHETIC adapter phase, not actual Agent binding
        let provider = OpenAICompatibleProvider(apiKey: "[configured locally]", customBaseURL: base.absoluteString,
            appendV1Suffix: false, session: session, ownedMMOutboundLedger: ledger)
        let stream = try await OwnedMMOutboundContext.$action.withValue(visual) {
            try await provider.streamMessage(messages: [LLMMessage(role: .user, content: "synthetic-local-adapter")],
                systemPrompt: nil, maxTokens: 8, temperature: nil)
        }
        for try await _ in stream { }
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ledger.snapshot.finished < 5 && !ledger.snapshot.stopped && ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = ledger.snapshot
        #expect(!state.stopped && !state.inFlight)
        #expect(state.admitted == 5 && state.finished == 5 && state.transactions == 5)
        #expect(server.lines == ["GET /v1", "GET /v1/models", "GET /v1/models", "POST /v1/chat/completions", "POST /chat/completions"])
        #expect(rows.values.filter { $0.event == .metrics && $0.transactions == 1 }.count == 5)
        #expect(rows.values.filter { $0.event == .finish && !$0.failed }.count == 5)
        #expect(policy.snapshot.reserved == 0 && policy.snapshot.refused == 0) // metadata is not a credential read
        print("MM01_LOCAL_ADAPTER_ONLY requests=\(server.lines.count) admitted=\(state.admitted) transactions=\(state.transactions) UI_PROOF=false MM_LANE_PROOF=false")
    }

    private enum TerminalMode: String, Sendable { case cancelTerminalYield, stopAtDone }

    @Test("successful audited finish survives cancellation at terminal yield")
    func successfulFinishThenTerminalYieldCancellationKeepsSettlement() async throws {
        try await runTerminalBoundary(.cancelTerminalYield)
    }

    @Test("raw consumer stops at the actual DONE line without another request")
    func actualDoneLineConsumerStopsWithOwnedTerminalSettlement() async throws {
        try await runTerminalBoundary(.stopAtDone)
    }

    private func runTerminalBoundary(_ mode: TerminalMode) async throws {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        _ = try #require(resolved)
        let policy = OwnedMMCredentialReadPolicy(requiresPlan: true)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let deadline = Date().addingTimeInterval(60)
        #expect(policy.arm())
        try #require(policy.install(nonce: nonce, limit: 1, deadline: deadline))
        let metadata = try #require(policy.activeWindow)
        let rows = MM01LocalAuditRows()
        let ledger = OwnedMMOutboundLedger(runIdentity: "TEST_ONLY_NOT_UI_LOCAL_TERMINAL_" + mode.rawValue + ":" + nonce,
            windowNonce: metadata.nonce, deadline: metadata.deadline,
            windowIsCurrent: { policy.activeWindow?.nonce == metadata.nonce && policy.activeWindow?.deadline == metadata.deadline },
            sink: { row in
                rows.append(row)
                if mode == .cancelTerminalYield, row.phase == .visual,
                   (row.event == .finish && !row.failed ||
                    row.event == .bytesEOF && rows.values.contains(where: { $0.phase == .visual && $0.event == .finish && !$0.failed })) {
                    // Cancel the real production Task at its success-boundary
                    // sink. If a delegate settled first outside a Task, defer
                    // cancellation to the real producer's EOF record instead.
                    rows.cancelCurrentProducerIfPresent()
                }
                var data = try JSONEncoder().encode(MM01LocalAuditEnvelope(record: row)); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            })
        let server = try MM01FiveLocalResponses()
        defer {
            #expect(server.stopAndJoin())
            // Always emit actual safe counts/closure, even after the first throw.
            // No lower CFNetwork error is available through the existing private
            // production task delegate; do not fabricate it from .unavailable.
            do {
                var data = try JSONEncoder().encode(MM01LocalServerCloseReceipt(server: server.diagnostics)); data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { Issue.record("Test-only server receipt write failed") }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = nil
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let base = try #require(URL(string: "http://127.0.0.1:\(server.port)"))
        let transport = URLSessionProviderReadinessTransport(session: session, ownedMMOutboundLedger: ledger)
        let action = try ledger.beginAction(.providerReadinessButton) // SYNTHETIC test action, never UI proof
        let operations: [ProviderReadinessOperation] = [.reachability, .authentication, .modelDiscovery, .minimalModelRequest("deepseek-flash")]
        for operation in operations {
            let modelID: String?
            if case .minimalModelRequest = operation { modelID = "deepseek-flash" } else { modelID = nil }
            var request = ProviderReadinessTransportRequest(operation: operation, providerID: "synthetic-local",
                baseURL: base, apiKey: "[configured locally]",
                modelID: modelID,
                protocolType: .openaiCompatible)
            request.ownedMMAction = action
            let response = try await transport.send(request)
            try #require(response.statusCode == 200 && response.errorCategory == nil)
        }
        let visual = try ledger.beginAction(.composerSendButton) // SYNTHETIC adapter phase, not actual Agent binding
        let provider = OpenAICompatibleProvider(apiKey: "[configured locally]", customBaseURL: base.absoluteString,
            appendV1Suffix: false, session: session, ownedMMOutboundLedger: ledger)

        if mode == .cancelTerminalYield {
            let stream = try await OwnedMMOutboundContext.$action.withValue(visual) {
                try await provider.streamMessage(messages: [LLMMessage(role: .user, content: "synthetic-local-adapter")],
                    systemPrompt: nil, maxTokens: 8, temperature: nil)
            }
            var sawExpectedCancellation = false
            do {
                for try await _ in stream { }
            } catch {
                if let llm = error as? LLMError, case .cancelled = llm { sawExpectedCancellation = true }
            }
            #expect(rows.didCancelProducer)
            #expect(sawExpectedCancellation)
        } else {
            // The helper's local stream goes out of scope immediately at DONE;
            // it does not drain the returned stream in the test consumer.
            let sawDone = try await consumeOnlyThroughDone(provider: provider, action: visual)
            #expect(sawDone)
        }
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ledger.snapshot.finished < 5 && !ledger.snapshot.stopped && ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = ledger.snapshot
        #expect(!state.stopped && !state.inFlight)
        #expect(state.admitted == 5 && state.finished == 5 && state.transactions == 5)
        #expect(server.lines == ["GET /v1", "GET /v1/models", "GET /v1/models", "POST /v1/chat/completions", "POST /chat/completions"])
        #expect(rows.values.filter { $0.event == .metrics && $0.transactions == 1 }.count == 5)
        #expect(rows.values.filter { $0.event == .finish && !$0.failed }.count == 5)
        #expect(rows.values.filter { $0.event == .bytesEOF && $0.phase == .visual }.count == 1)
        #expect(policy.snapshot.reserved == 0 && policy.snapshot.refused == 0)
        // Raw audit rows preserve actual EOF/metrics/didComplete ordering.
        // No expected callback ordering or fabricated callback is injected.
        print("MM01_LOCAL_TERMINAL_ONLY mode=\(mode.rawValue) requests=\(server.lines.count) admitted=\(state.admitted) transactions=\(state.transactions) UI_PROOF=false MM_LANE_PROOF=false")
    }

    private func consumeOnlyThroughDone(provider: OpenAICompatibleProvider,
                                        action: OwnedMMActionTicket) async throws -> Bool {
        let (stream, status) = try await OwnedMMOutboundContext.$action.withValue(action) {
            try await provider.streamRaw(body: ["model": "deepseek-flash", "stream": true,
                "messages": [["role": "user", "content": "synthetic-local-adapter"]], "max_tokens": 8])
        }
        #expect(status == 200)
        for try await line in stream {
            if line == "data: [DONE]" { return true }
        }
        return false
    }
}
