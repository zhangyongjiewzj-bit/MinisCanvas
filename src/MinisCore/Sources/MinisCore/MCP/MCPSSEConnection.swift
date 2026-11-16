import Foundation

/// Bounded SSE framing shared by streamable HTTP and the legacy event stream.
/// Comments and unknown event fields never become JSON-RPC messages.
struct MCPSSEEventDecoder {
    struct Event: Equatable, Sendable {
        let name: String
        let data: String
    }
    private var eventName = "message"
    private var dataLines: [String] = []
    private var byteCount = 0
    static let maximumEventBytes = 1_048_576

    mutating func append(line: String) throws -> Event? {
        if line.isEmpty {
            defer { eventName = "message"; dataLines.removeAll(keepingCapacity: true); byteCount = 0 }
            return dataLines.isEmpty ? nil : Event(name: eventName, data: dataLines.joined(separator: "\n"))
        }
        byteCount += line.utf8.count
        guard byteCount <= Self.maximumEventBytes else {
            throw MCPClientError.invalidMessage("MCP event exceeds byte limit")
        }
        if line.hasPrefix(":") { return nil }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(fields[0])
        var value = fields.count > 1 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if key == "event" { eventName = value }
        if key == "data" { dataLines.append(value) }
        return nil
    }

    static func endpoint(_ value: String, relativeTo origin: URL) throws -> URL {
        guard let result = URL(string: value, relativeTo: origin)?.absoluteURL,
              result.scheme?.lowercased() == origin.scheme?.lowercased(),
              result.host?.lowercased() == origin.host?.lowercased(),
              (result.port ?? (result.scheme == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme == "https" ? 443 : 80)),
              result.user == nil, result.password == nil, result.fragment == nil else {
            throw MCPClientError.badResponse("MCP event endpoint must remain on the configured origin")
        }
        return result
    }
}

/// Bound the unfinished line too, before Foundation can accumulate an
/// arbitrarily long server-controlled string. Accept LF, CRLF and lone CR.
struct MCPSSELineDecoder {
    private var data = Data()
    private var skipLF = false
    mutating func append(_ byte: UInt8) throws -> String? {
        if skipLF { skipLF = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            defer { data.removeAll(keepingCapacity: true) }
            guard let line = String(data: data, encoding: .utf8) else {
                throw MCPClientError.invalidMessage("MCP event is not UTF-8")
            }
            return line
        }
        guard data.count < MCPSSEEventDecoder.maximumEventBytes else {
            throw MCPClientError.invalidMessage("MCP event line exceeds byte limit")
        }
        data.append(byte)
        return nil
    }
}

/// Do not forward authentication headers to a redirect destination.
final class MCPNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class MCPSSEReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.withLock { ready } }
    func set(_ value: Bool) { lock.withLock { ready = value } }
}

/// One legacy SSE session. The GET stream owns endpoint discovery and all
/// response correlation; POST acknowledgements do not count as RPC results.
actor MCPSSEConnection {
    nonisolated let readiness = MCPSSEReadiness()
    private let url: URL
    private let headers: [String: String]
    private let timeoutSeconds: Int
    private let session: URLSession
    private let oauthAuthorization: MCPOAuthHTTPAuthorization?
    private var endpoint: URL?
    private var stream: Task<Void, Never>?
    private var epoch = UUID()
    private var endpointWaiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var pending: [MCPID: CheckedContinuation<MCPJSONRPCResponse, Error>] = [:]

    init(url: URL, headers: [String: String], timeoutSeconds: Int, session: URLSession, oauthAuthorization: MCPOAuthHTTPAuthorization? = nil) {
        self.url = url
        self.headers = headers
        self.timeoutSeconds = timeoutSeconds
        self.session = session
        self.oauthAuthorization = oauthAuthorization
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        let target = try await connect()
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(request)
        let generation = epoch
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending[request.id] == nil else {
                    continuation.resume(throwing: MCPClientError.invalidMessage("duplicate MCP request id"))
                    return
                }
                pending[request.id] = continuation
                Task {
                    do { try await self.post(body, to: target) }
                    catch { self.fail(request.id, generation: generation, error: error) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    self.fail(request.id, generation: generation, error: MCPClientError.badResponse("MCP event response timed out"))
                }
            }
        } onCancel: {
            Task { await self.fail(request.id, generation: generation, error: CancellationError()) }
        }
    }

    func notify(_ notification: MCPJSONRPCNotification) async throws {
        let target = try await connect()
        try await post(JSONEncoder().encode(notification), to: target)
    }

    private func connect() async throws -> URL {
        if let endpoint { return endpoint }
        try Task.checkCancellation()
        let waiter = UUID()
        if stream == nil {
            let generation = epoch
            stream = Task { await self.readStream(generation: generation) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                endpointWaiters[waiter] = continuation
                Task {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    self.failWaiter(waiter, error: MCPClientError.badResponse("MCP event endpoint timed out"))
                }
            }
        } onCancel: {
            Task { await self.failWaiter(waiter, error: CancellationError()) }
        }
    }

    private func readStream(generation: UUID) async {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = TimeInterval(timeoutSeconds)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let authorized = try await oauthAuthorization?.prepare(request) ?? request
            let (bytes, response) = try await session.bytes(for: authorized)
            if let oauthAuthorization, try await oauthAuthorization.recordUnauthorized(response) {
                throw MCPOAuthError.loginRequired
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType?.lowercased() == "text/event-stream" else {
                throw MCPClientError.badResponse("MCP event stream was not accepted")
            }
            var decoder = MCPSSEEventDecoder()
            var lines = MCPSSELineDecoder()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard epoch == generation else { return }
                guard let line = try lines.append(byte),
                      let event = try decoder.append(line: line) else { continue }
                if event.name == "endpoint" {
                    let target = try MCPSSEEventDecoder.endpoint(event.data, relativeTo: url)
                    guard endpoint == nil else {
                        throw MCPClientError.badResponse("MCP event endpoint changed during a session")
                    }
                    endpoint = target
                    readiness.set(true)
                    let waiters = endpointWaiters.values
                    endpointWaiters.removeAll()
                    for waiter in waiters { waiter.resume(returning: target) }
                } else if event.name == "message" {
                    guard let response = try? MCPMessage.decodeResponseData(Data(event.data.utf8)) else { continue }
                    if let id = response.id, let waiter = pending.removeValue(forKey: id) {
                        waiter.resume(returning: response)
                    }
                }
            }
            throw MCPClientError.badResponse("MCP event stream closed")
        } catch {
            guard epoch == generation else { return }
            stop(error: error)
        }
    }

    private func post(_ body: Data, to endpoint: URL) async throws {
        guard body.count <= MCPSSEEventDecoder.maximumEventBytes else {
            throw MCPClientError.invalidMessage("MCP outbound payload exceeds byte limit")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let authorized = try await oauthAuthorization?.prepare(request) ?? request
        let (_, response) = try await session.data(for: authorized)
        if let oauthAuthorization, try await oauthAuthorization.recordUnauthorized(response) {
            throw MCPOAuthError.loginRequired
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPClientError.badResponse("MCP event message was not accepted")
        }
    }

    private func fail(_ id: MCPID, generation: UUID, error: Error) {
        guard generation == epoch else { return }
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failWaiter(_ id: UUID, error: Error) {
        endpointWaiters.removeValue(forKey: id)?.resume(throwing: error)
        if endpoint == nil && endpointWaiters.isEmpty { stop(error: error) }
    }

    func stop(error: Error = MCPClientError.transportNotStarted) {
        epoch = UUID()
        readiness.set(false)
        stream?.cancel()
        stream = nil
        endpoint = nil
        let requests = pending.values
        pending.removeAll()
        let waiters = endpointWaiters.values
        endpointWaiters.removeAll()
        for request in requests { request.resume(throwing: error) }
        for waiter in waiters { waiter.resume(throwing: error) }
    }
}
