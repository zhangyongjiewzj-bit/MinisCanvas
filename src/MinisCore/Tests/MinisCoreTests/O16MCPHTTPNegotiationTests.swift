import Foundation
import Testing
@testable import MinisCore

/// All requests terminate in this in-process URLProtocol, never a listener or
/// external service. The stream remains open until the transport stops it.
private final class O16MCPWire: URLProtocol, @unchecked Sendable {
    enum Mode { case streamable, legacy }
    private struct State {
        var mode = Mode.streamable
        var requests: [URLRequest] = []
        var stream: O16MCPWire?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    static func reset(_ mode: Mode) { lock.withLock { state = State(mode: mode) } }
    static var requests: [URLRequest] { lock.withLock { state.requests } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "o16.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = Self.lock.withLock {
            Self.state.requests.append(request)
            return Self.state.mode
        }
        if request.httpMethod == "GET" {
            Self.lock.withLock { Self.state.stream = self }
            respond(status: 200, contentType: "text/event-stream", data: "event: endpoint\ndata: /messages?session=fixture\n\n", finish: false)
            return
        }
        if mode == .legacy && request.url?.path == "/mcp" {
            respond(status: 405, contentType: "application/json", data: "")
            return
        }
        do {
            let rpc = try JSONDecoder().decode(MCPJSONRPCRequest.self, from: body())
            let encoded = try JSONEncoder().encode(MCPJSONRPCResponse(id: rpc.id, result: .object(["ok": .bool(true), "protocolVersion": .string("2025-06-18")])))
            let event = "data: " + String(decoding: encoded, as: UTF8.self) + "\n\n"
            if mode == .legacy {
                respond(status: 202, contentType: "application/json", data: "")
                let stream = Self.lock.withLock { Self.state.stream }
                stream?.client?.urlProtocol(stream!, didLoad: Data(event.utf8))
            } else {
                respond(status: 200, contentType: "text/event-stream", data: ": heartbeat\n\n" + event)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    private func respond(status: Int, contentType: String, data: String, finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType, "Mcp-Session-Id": "fixture-session"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: Data(data.utf8)) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        Self.lock.withLock { if Self.state.stream === self { Self.state.stream = nil } }
    }
}

@Suite("O16b HTTP and legacy SSE consumer", .serialized)
struct O16MCPHTTPNegotiationTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [O16MCPWire.self]
        return URLSession(configuration: config)
    }

    @Test func streamableResponseRetainsSessionAndAuthentication() async throws {
        O16MCPWire.reset(.streamable)
        let session = session(); defer { session.invalidateAndCancel() }
        let transport = MCPHTTPTransport(url: URL(string: "https://o16.example.invalid/mcp")!,
            headers: ["Authorization": "Bearer synthetic-only"], timeoutSeconds: 2, session: session)
        defer { transport.stop() }
        let first = try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "initialize"))
        let second = try await transport.send(MCPJSONRPCRequest(id: .int(2), method: "tools/list"))
        #expect(first.id == .int(1) && second.id == .int(2))
        let requests = O16MCPWire.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only" })
        #expect(requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session")
        #expect(requests.last?.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
    }

    @Test func protocolRejectionFallsBackToSameOriginSSEAndCorrelatesResponse() async throws {
        O16MCPWire.reset(.legacy)
        let session = session(); defer { session.invalidateAndCancel() }
        let transport = MCPHTTPTransport(url: URL(string: "https://o16.example.invalid/mcp")!,
            headers: ["Authorization": "Bearer synthetic-only"], timeoutSeconds: 2, session: session)
        defer { transport.stop() }
        let response = try await transport.send(MCPJSONRPCRequest(id: .int(7), method: "initialize"))
        #expect(response.id == .int(7))
        let next = try await transport.send(MCPJSONRPCRequest(id: .int(8), method: "tools/list"))
        #expect(next.id == .int(8))
        let requests = O16MCPWire.requests
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "GET", "POST", "POST"])
        #expect(requests.suffix(2).allSatisfy { $0.url?.path == "/messages" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-only" })
        #expect(throws: MCPClientError.self) {
            try MCPSSEEventDecoder.endpoint("https://other.example.invalid/messages", relativeTo: URL(string: "https://o16.example.invalid/mcp")!)
        }
    }
}
