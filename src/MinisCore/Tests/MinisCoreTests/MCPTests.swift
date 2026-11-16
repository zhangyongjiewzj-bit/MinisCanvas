import Foundation
import Darwin
import Testing
@testable import MinisCore

// B1f MCP module tests: JSON-RPC 消息编解码、服务器 CRUD/持久化往返、
// MCPClient（mock transport + 真实 stdio 假进程）、工具桥接（registry）。
// Swift Testing（CLT toolchain）— 与项目其他测试一致。

// MARK: - Helpers

private func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func canonicalJSONFixtureData(_ value: Any) throws -> Data {
    func encode(_ value: Any) throws -> Data {
        if let object = value as? [String: Any] {
            var result = Data([0x7b])
            for (index, key) in object.keys.sorted(by: <).enumerated() {
                if index > 0 { result.append(0x2c) }
                result.append(try JSONSerialization.data(
                    withJSONObject: key,
                    options: [.fragmentsAllowed]
                ))
                result.append(0x3a)
                result.append(try encode(object[key]!))
            }
            result.append(0x7d)
            return result
        }
        if let array = value as? [Any] {
            var result = Data([0x5b])
            for (index, element) in array.enumerated() {
                if index > 0 { result.append(0x2c) }
                result.append(try encode(element))
            }
            result.append(0x5d)
            return result
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        )
    }

    return try encode(value)
}

private enum MCPTestError: Error {
    case processIDUnavailable
    case processStillAlive
}

private func tornTempReceiptDiagnostic(
    _ receipts: [MCPStaleTempCleanupReceipt],
    expectedURL: URL
) -> String {
    let expectedName = expectedURL.lastPathComponent
    let expectedStandardizedPath = expectedURL.standardizedFileURL.path
    var expectedInfo = stat()
    let expectedIdentityAvailable = Darwin.lstat(expectedURL.path, &expectedInfo) == 0
    var nameMatches = 0
    var standardizedPathMatches = 0
    var identityMatches = 0
    for receipt in receipts {
        let receiptURL = URL(fileURLWithPath: receipt.temporaryPath)
        if receiptURL.lastPathComponent == expectedName {
            nameMatches += 1
        }
        if receiptURL.standardizedFileURL.path == expectedStandardizedPath {
            standardizedPathMatches += 1
        }
        var receiptInfo = stat()
        if expectedIdentityAvailable,
           Darwin.lstat(receiptURL.path, &receiptInfo) == 0,
           receiptInfo.st_dev == expectedInfo.st_dev,
           receiptInfo.st_ino == expectedInfo.st_ino {
            identityMatches += 1
        }
    }
    return "receipt-count=\(receipts.count); expected-name-matches=\(nameMatches); standardized-path-matches=\(standardizedPathMatches); file-identity-matches=\(identityMatches)"
}

private func waitForProcessID(at url: URL) async throws -> pid_t {
    for _ in 0..<100 {
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let value = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0 {
            return value
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw MCPTestError.processIDUnavailable
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func waitForProcessExit(_ pid: pid_t) async throws {
    for _ in 0..<100 {
        if !processIsAlive(pid) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw MCPTestError.processStillAlive
}

/// A canned JSON-RPC transport for client tests (no real process/network).
private struct MockMCPTransport: MCPTransport {
    var handler: @Sendable (MCPJSONRPCRequest) async -> MCPJSONRPCResponse

    init(handler: @escaping @Sendable (MCPJSONRPCRequest) async -> MCPJSONRPCResponse) {
        self.handler = handler
    }

    /// Default happy-path response logic for a request.
    static func happyResponse(for request: MCPJSONRPCRequest,
                              tools: [MCPTool],
                              callText: String) -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("mock"), "version": .string("1.0")]),
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array(tools.map { tool in
                    var obj: [String: MCPJSONValue] = ["name": .string(tool.name)]
                    if let desc = tool.description { obj["description"] = .string(desc) }
                    if let schema = tool.inputSchema { obj["inputSchema"] = schema }
                    return .object(obj)
                }),
            ]))
        case "tools/call":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(callText)])]),
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }

    /// Happy-path mock: initialize / tools/list / tools/call all succeed.
    static func happy(tools: [MCPTool] = [MCPTool(name: "greet", description: "Greet someone", inputSchema: .object(["type": .string("object")]))], callText: String = "Hello, world!") -> MockMCPTransport {
        MockMCPTransport { request in
            happyResponse(for: request, tools: tools, callText: callText)
        }
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        await handler(request)
    }

    func start() async throws {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

/// Blocks the first handshake step so concurrent client.connect() callers can
/// be forced to overlap deterministically.
private struct BlockingStartMCPTransport: MCPTransport {
    let entered: MCPAsyncSignal
    let release: MCPAsyncSignal

    func start() async throws {
        entered.signal()
        await release.wait()
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        MockMCPTransport.happyResponse(for: request, tools: [], callText: "ok")
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

/// Suspends discovery before the first handshake while still returning a
/// deterministic tools/list payload after release.
private struct SuspendedDiscoveryMCPTransport: MCPTransport {
    let entered: MCPAsyncSignal
    let release: MCPAsyncSignal
    let stopped: MCPAsyncSignal
    let tools: [MCPTool]

    func start() async throws {
        entered.signal()
        await release.wait()
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        MockMCPTransport.happyResponse(for: request, tools: tools, callText: "ok")
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() { stopped.signal() }
}

private struct FailingInitializedNotificationMCPTransport: MCPTransport {
    let stopCount: Counter

    func start() async throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        MockMCPTransport.happyResponse(for: request, tools: [], callText: "ok")
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {
        throw MCPClientError.spawnFailed("initialized notification write failed")
    }

    func stop() {
        stopCount.value += 1
    }
}

private final class ReconnectingPaginationMCPTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var pageCount = 0
    private var readinessChecksAfterFirstPage = 0
    private var fenceAfterFirstPage = false
    private var ready = true

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ready else { return false }
        guard fenceAfterFirstPage else { return true }
        readinessChecksAfterFirstPage += 1
        if readinessChecksAfterFirstPage == 2 {
            fenceAfterFirstPage = false
            ready = false
            return false
        }
        return true
    }

    var pagesServed: Int {
        lock.lock()
        defer { lock.unlock() }
        return pageCount
    }

    func start() async throws {
        lock.withLock {
            startCount += 1
            fenceAfterFirstPage = false
            readinessChecksAfterFirstPage = 0
            ready = true
        }
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "ok")
        case "tools/list":
            let page = lock.withLock {
                pageCount += 1
                let page = pageCount
                if page == 1 {
                    fenceAfterFirstPage = true
                    readinessChecksAfterFirstPage = 0
                }
                return page
            }
            var result: [String: MCPJSONValue] = [
                "tools": .array([.object(["name": .string("page-\(page)")])])
            ]
            if page == 1 {
                result["nextCursor"] = .string("page-2")
            }
            return MCPJSONRPCResponse(id: request.id, result: .object(result))
        default:
            return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }

    func notify(_ notification: MCPJSONRPCNotification) throws {}
    func stop() {}
}

/// 引用盒子：@Sendable 闭包内可安全递增的计数器（测试用）。
private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class MCPToolsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [MCPTool]

    init(_ tools: [MCPTool]) {
        self.tools = tools
    }

    var value: [MCPTool] {
        lock.lock()
        defer { lock.unlock() }
        return tools
    }

    func replace(_ tools: [MCPTool]) {
        lock.lock()
        self.tools = tools
        lock.unlock()
    }
}

private final class MCPToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func schemaBoundGreet(_ valueType: String) -> MCPTool {
    MCPTool(
        name: "greet",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["type": .string(valueType)])]),
            "required": .array([.string("value")]),
        ])
    )
}

private func schemaBoundClientFactory(
    tools: MCPToolsBox,
    calls: MCPToolCallCounter
) -> @Sendable (MCPServer) -> MCPClient {
    { server in
        MCPClient(server: server, transport: MockMCPTransport { request in
            if request.method == "tools/call" { calls.record() }
            return MockMCPTransport.happyResponse(
                for: request, tools: tools.value, callText: "schema-bound"
            )
        })
    }
}

private final class MCPClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPClient?

    func store(_ client: MCPClient) {
        lock.lock()
        stored = client
        lock.unlock()
    }

    var value: MCPClient? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class MCPAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

private final class DiscoveryStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AgentToolCatalogDiscoveryState] = []

    func append(_ state: AgentToolCatalogDiscoveryState) {
        lock.lock()
        states.append(state)
        lock.unlock()
    }

    var snapshot: [AgentToolCatalogDiscoveryState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

private struct FailingCatalogBridge: MCPToolBridge {
    let secret: String

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        throw MCPClientError.rpcError(code: 401, message: "credential=\(secret)")
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        throw MCPClientError.permissionDenied(fullName)
    }
}

private struct StaticCatalogBridge: MCPToolBridge {
    let tools: [MCPBoundTool]

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        tools
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        throw MCPClientError.toolNotFound(fullName)
    }
}

private func makeManager() throws -> (MCPServerManager, URL) {
    let dir = try makeTempDir("MCPServerManagerTests")
    let file = dir.appendingPathComponent("mcps.json")
    return (MCPServerManager(fileURL: file), file)
}

private func writeDiscoveryServerScript() throws -> (script: URL, marker: URL, directory: URL) {
    let directory = try makeTempDir("MCPDiscoveryTests")
    let script = directory.appendingPathComponent("discovery-server.sh")
    let marker = directory.appendingPathComponent("tools-list-started")
    let body = #"""
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      [ -z "$id" ] && continue
      method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\\')
      case "$method" in
        initialize)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"discovery","version":"0.0.1"}}}\n' "$id";;
        tools/list)
          [ -z "$MCP_DISCOVERY_MARKER" ] || : > "$MCP_DISCOVERY_MARKER"
          [ "$MCP_DISCOVERY_DELAY" = "1" ] || true
          [ "$MCP_DISCOVERY_DELAY" = "1" ] && sleep 1
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"greet","description":"cached greet","inputSchema":{"type":"object"}}]}}\n' "$id";;
        *)
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id";;
      esac
    done

    """#
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, marker, directory)
}

private func waitForMarker(_ marker: URL) async throws {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: marker.path) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw MCPTestError.processIDUnavailable
}

private let sampleServers: [MCPServer] = [
    MCPServer(id: "github", name: "GitHub", type: .http, url: "https://api.githubcopilot.com/mcp/", headers: ["Authorization": "Bearer x"], timeoutSeconds: 30),
    MCPServer(id: "filesystem", name: "Filesystem", type: .stdio, enabled: false, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"], env: ["PATH": "/usr/bin"]),
]

// MARK: - Models: JSON-RPC 编解码

struct MCPModelTests {

    @Test func outputLimiterRedactsSensitiveJSONAndBoundsRemoteText() {
        let output = MCPOutputLimiter.project(
            #"{"token":"secret-value","content":"remote body"}"#,
            to: 80
        )
        #expect(!output.contains("secret-value"))
        #expect(output.contains("[REDACTED]"))
        #expect(output.contains("remote body"))

        let truncated = MCPOutputLimiter.project(String(repeating: "正文", count: 100), to: 16)
        #expect(truncated.count <= 16)
        #expect(truncated.hasSuffix(MCPOutputLimiter.truncationMarker))
    }

    @Test func outputLimiterRedactsEmbeddedCredentialFormsDeterministically() {
        let remote = "用户消息 https://user:passphrase@example.test/mcp?token=url-secret-123456&page=2 "
            + "Authorization: Bearer bearer-secret-123456 "
            + "provider key sk-provider-secret-123456"
        let first = MCPOutputLimiter.project(remote, to: 512)
        let second = MCPOutputLimiter.project(remote, to: 512)

        #expect(first == second)
        #expect(!first.contains("passphrase"))
        #expect(!first.contains("url-secret-123456"))
        #expect(!first.contains("bearer-secret-123456"))
        #expect(!first.contains("sk-provider-secret-123456"))
        #expect(first.contains("page=2"))
        #expect(first.contains("用户消息"))
    }

    @Test func outputLimiterKeepsNestedJSONValidUnderByteBound() throws {
        let remote = #"{"nested":{"token":"nested-secret","items":[{"password":"item-secret"}, {"body":"正文"}]},"payload":"长内容"}"#
        let first = MCPOutputLimiter.project(remote, to: 96)
        let second = MCPOutputLimiter.project(remote, to: 96)
        let data = try #require(first.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(first == second)
        #expect(data.count <= 96)
        #expect(object["truncated"] as? Bool == true)
        #expect(!first.contains("nested-secret"))
        #expect(!first.contains("item-secret"))

        let tiny = MCPOutputLimiter.project(remote, to: 8)
        let tinyData = try #require(tiny.data(using: .utf8))
        #expect(tinyData.count <= 8)
        #expect((try? JSONSerialization.jsonObject(with: tinyData)) != nil)
    }

    @Test func outputLimiterUsesUTF8ByteBoundForUnicodeAndStreams() {
        let text = String(repeating: "界", count: 100)
        let bounded = MCPOutputLimiter.limit(text, to: 32)
        let streamed = MCPOutputLimiter.limit([text, text], to: 32)
        let manyChunks = MCPOutputLimiter.limit((0..<100).map { _ in text }, to: 64)

        #expect(bounded.utf8.count <= 32)
        #expect(streamed.utf8.count <= 32)
        #expect(manyChunks.utf8.count <= 64)
        #expect(bounded.hasSuffix(MCPOutputLimiter.truncationMarker))
        #expect(streamed.hasSuffix(MCPOutputLimiter.truncationMarker))
        #expect(manyChunks.hasSuffix(MCPOutputLimiter.truncationMarker))
    }

    @Test func outputLimiterRedactsSplitCredentialsAcrossStreamChunks() throws {
        let chunks = [
            #"{"nested":{"to"#,
            #"ken":"split-secret","items":[{"body":"正文"}]},"auth":"Authorization: Bearer c2VjcmV0"#,
            "LXRva2VuLWJ5dGVz"
        ]
        let output = MCPOutputLimiter.limit(chunks, to: 512)
        let data = try #require(output.data(using: .utf8))

        #expect(data.count <= 512)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
        #expect(!output.contains("split-secret"))
        #expect(!output.contains("c2VjcmV0LXRva2VuLWJ5dGVz"))
    }

    /// filesystem MCP `list_directory` returns plain text whose lines start with
    /// `[FILE]`/`[DIR]`. Text that merely begins with `[` or `{` but is not JSON
    /// must keep its content; only the established newline join applies.
    @Test func outputLimiterKeepsNonJSONTextThatStartsWithBracketAcrossStreamChunks() {
        let listing = MCPOutputLimiter.limit(["[FILE] a.txt", "[FILE] b.txt"], to: 512)
        #expect(listing != "{}")
        #expect(listing.contains("[FILE] a.txt"))
        #expect(listing.contains("[FILE] b.txt"))
        #expect(listing == "[FILE] a.txt\n[FILE] b.txt")

        let error = MCPOutputLimiter.limit(["[ERROR] boom"], to: 512)
        #expect(error != "{}")
        #expect(error.contains("boom"))

        let brace = MCPOutputLimiter.limit(["{not json"], to: 512)
        #expect(brace != "{}")
        #expect(brace.contains("{not json"))
    }

    /// Guard rail: valid JSON still takes the structured JSON path, and a
    /// bracket-prefixed non-JSON text never exposes a credential, whether it is
    /// whole in one chunk or split across two.
    @Test func outputLimiterKeepsJSONPathAndRedactsBracketPrefixedText() throws {
        let json = MCPOutputLimiter.limit([#"{"token":"json-secret-123456","#, #""body":"remote body"}"#], to: 512)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["body"] as? String == "remote body")
        #expect(!json.contains("json-secret-123456"))
        #expect(json.contains("[REDACTED]"))

        let credentialText = "[NOTE] Authorization: Bearer bearer-secret-123456 and key sk-provider-secret-123456"
        let whole = MCPOutputLimiter.limit([credentialText], to: 512)
        #expect(!whole.contains("bearer-secret-123456"))
        #expect(!whole.contains("sk-provider-secret-123456"))

        let split = MCPOutputLimiter.limit(["[NOTE] Authorization: Bearer bearer-secr", "et-123456 tail"], to: 512)
        #expect(!split.contains("bearer-secret-123456"))
    }

    /// RED half of the redaction guard: the safe text must be preserved while the
    /// credential is removed, not replaced wholesale by `{}`.
    @Test func outputLimiterRedactsCredentialInsideBracketPrefixedTextWithoutDiscardingIt() {
        let output = MCPOutputLimiter.limit(
            ["[NOTE] listing page=2 Authorization: Bearer bearer-secret-123456"], to: 512)
        #expect(output.contains("[NOTE]"))
        #expect(output.contains("page=2"))
        #expect(!output.contains("bearer-secret-123456"))
    }

    /// Guard rail for the existing contract that a fix must keep (see also
    /// `outputLimiterRedactsSplitCredentialsAcrossStreamChunks`): text that really
    /// is a cut-off JSON document (starts like JSON and cannot be parsed) is still
    /// published as valid JSON, never as a raw prefix.
    @Test func outputLimiterStillPublishesValidJSONForCutOffJSONDocument() throws {
        let output = MCPOutputLimiter.limit(["{\"nested\":{\"items\":[1,2", ",3"], to: 512)
        let data = try #require(output.data(using: .utf8))
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    /// RED: an incomplete, untruncated JSON array whose first element is a scalar
    /// (`[1,` / `[true,`) is not treated as JSON-shaped, so it takes the plain-text
    /// path. That path only knows `name=value` forms, not the JSON key form
    /// `"password":"..."`, so the value is published unredacted. (No
    /// ContentSecretRedactor / Gitleaks rule matches a `"key":"value"` pair.)
    @Test func outputLimiterDoesNotLeakSensitiveKeysInIncompleteScalarFirstJSONArray() {
        let documents: [(text: String, secret: String)] = [
            (#"[1,{"password":"synthetic-pass-123""#, "synthetic-pass-123"),
            (#"[true,{"token":"synthetic-tok-456""#, "synthetic-tok-456"),
        ]
        for document in documents {
            let whole = MCPOutputLimiter.limit([document.text], to: 512)
            #expect(!whole.contains(document.secret))
            // The same bytes split inside the key name must not leak either.
            let cut = document.text.index(document.text.startIndex, offsetBy: 7)
            let split = MCPOutputLimiter.limit(
                [String(document.text[..<cut]), String(document.text[cut...])], to: 512)
            #expect(!split.contains(document.secret))
        }
    }

    /// Guard rail (expected GREEN before and after): ordinary log-style text that
    /// begins with a bracketed number or time is plain text and stays untouched.
    @Test func outputLimiterKeepsBracketedNumberAndTimePrefixedLogText() {
        for text in ["[1] foo", "[2024-01-01] log line", "[12:30] msg"] {
            let output = MCPOutputLimiter.limit([text], to: 512)
            #expect(output != "{}")
            #expect(output == text)
        }
    }

    @Test func catalogDiscoveryFailurePublishesTypedStateAndKeepsBuiltins() async throws {
        let secret = "mcp-discovery-secret-sentinel"
        let stateBox = DiscoveryStateBox()
        let tools = try await AgentToolCatalog.makeTools(
            includingMCPFrom: FailingCatalogBridge(secret: secret),
            orchestration: nil,
            onDiscoveryState: { stateBox.append($0) }
        )

        #expect(tools.contains { $0.name == "shell_execute" })
        #expect(stateBox.snapshot == [
            .discovering,
            .failed(.protocolError),
        ])
        #expect(!String(describing: stateBox.snapshot).contains(secret))
    }

    @Test func catalogRejectsMalformedMCPToolSchemaInsteadOfSilentlyCoercing() async throws {
        let valid = MCPBoundTool(
            fullName: "mcp_catalog_valid_echo",
            serverID: "catalog-valid",
            tool: MCPTool(
                name: "echo",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "amount": .object(["type": .string("number")]),
                        "flag": .object(["type": .string("boolean")]),
                    ]),
                    "required": .array([.string("amount")]),
                ])
            )
        )
        let validCatalog = try await AgentToolCatalog.makeTools(
            includingMCPFrom: StaticCatalogBridge(tools: [valid])
        )
        let validDefinition = try #require(validCatalog.first { $0.name == valid.fullName })
        #expect(validDefinition.parameters["amount"]?.type == .integer)
        #expect(validDefinition.parameters["flag"]?.type == .boolean)
        #expect(validDefinition.required == ["amount"])

        let malformed: [MCPBoundTool] = [
            MCPBoundTool(
                fullName: "mcp_catalog_invalid_array",
                serverID: "catalog-invalid-array",
                tool: MCPTool(
                    name: "array",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "items": .object(["type": .string("array")]),
                        ]),
                    ])
                )
            ),
            MCPBoundTool(
                fullName: "mcp_catalog_invalid_container",
                serverID: "catalog-invalid-container",
                tool: MCPTool(
                    name: "container",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .string("not-an-object"),
                    ])
                )
            ),
            MCPBoundTool(
                fullName: "mcp_catalog_invalid_required",
                serverID: "catalog-invalid-required",
                tool: MCPTool(
                    name: "required",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "declared": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("missing")]),
                    ])
                )
            ),
            MCPBoundTool(
                fullName: "mcp_catalog_invalid_root",
                serverID: "catalog-invalid-root",
                tool: MCPTool(
                    name: "root",
                    inputSchema: .object(["type": .string("array")])
                )
            ),
        ]

        for tool in malformed {
            let stateBox = DiscoveryStateBox()
            let catalog = try await AgentToolCatalog.makeTools(
                includingMCPFrom: StaticCatalogBridge(tools: [tool]),
                orchestration: nil,
                onDiscoveryState: { stateBox.append($0) }
            )
            #expect(!catalog.contains { $0.name == tool.fullName })
            #expect(stateBox.snapshot == [.discovering, .failed(.protocolError)])
        }
    }

    @Test func invalidSchemaLocalizedDescriptionUsesFixedText() {
        let remoteToolName = "attacker-tool"
        let remotePropertyName = "credential"
        let error = MCPClientError.invalidSchema(
            "tool '\(remoteToolName)' property '\(remotePropertyName)' is not an object"
        )
        let description = error.localizedDescription

        #expect(description == "Invalid MCP tool schema")
        #expect(!description.contains(remoteToolName))
        #expect(!description.contains(remotePropertyName))
    }

    @Test func jsonValueRoundTrip() throws {
        let value = MCPJSONValue.object([
            "type": .string("object"),
            "required": .array([.string("name")]),
            "nullable": .null,
            "count": .number(3),
            "flag": .bool(true),
            "nested": .object(["a": .array([.number(1.5), .bool(false)])]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MCPJSONValue.self, from: data)
        #expect(decoded == value)
        // asAny / fromAny round-trip.
        let any = value.asAny
        #expect(MCPJSONValue.fromAny(any) == value)
        guard case .object(let obj) = decoded else {
            Issue.record("expected object")
            return
        }
        #expect(obj["count"] == .number(3))
        #expect(obj["nullable"] == .null)
    }

    @Test func requestMessageLineRoundTrip() throws {
        let request = MCPJSONRPCRequest(id: .int(7), method: "tools/call", params: .object(["name": .string("greet")]))
        let line = try request.encodeLine()
        let message = try MCPMessage.decodeLine(line)
        #expect(message == .request(request))
        #expect(line.contains("\"jsonrpc\":\"2.0\""))
        #expect(line.contains("\"id\":7"))
    }

    @Test func jsonRPCEncodingRejectsInvalidOutgoingEnvelopes() throws {
        let encoder = JSONEncoder()
        #expect(throws: MCPClientError.invalidMessage("JSON-RPC method must not be empty")) {
            _ = try encoder.encode(MCPJSONRPCRequest(id: .int(1), method: ""))
        }
        #expect(throws: MCPClientError.invalidMessage("JSON-RPC method must not be empty")) {
            _ = try encoder.encode(MCPJSONRPCNotification(method: "line\nfeed"))
        }
        #expect(throws: MCPClientError.invalidMessage("unsupported JSON-RPC version")) {
            _ = try encoder.encode(MCPJSONRPCRequest(id: .int(1), method: "tools/list", jsonrpc: "1.0"))
        }
        #expect(throws: MCPClientError.invalidMessage("JSON-RPC response must contain exactly one of result or error")) {
            _ = try encoder.encode(
                MCPJSONRPCResponse(
                    id: .int(1),
                    result: .object([:]),
                    error: MCPJSONRPCError(code: -1, message: "conflict")
                )
            )
        }
    }

    @Test func responseMessageLineRoundTrip() throws {
        let response = MCPJSONRPCResponse(id: .int(7), result: .object(["ok": .bool(true)]))
        let line = try MCPMessage.response(response).encodeLine()
        let decoded = try MCPMessage.decodeLine(line)
        #expect(decoded == .response(response))
    }

    @Test func errorResponseLineRoundTrip() throws {
        let response = MCPJSONRPCResponse(id: .int(2), error: MCPJSONRPCError(code: -32000, message: "boom", data: .object(["detail": .string("x")])))
        let decoded = try MCPMessage.decodeLine(try MCPMessage.response(response).encodeLine())
        #expect(decoded == .response(response))
        guard case .response(let r) = decoded else {
            Issue.record("expected response")
            return
        }
        #expect(r.isError)
        #expect(r.error?.code == -32000)
    }

    @Test func notificationMessageLineRoundTrip() throws {
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)
        let line = try MCPMessage.notification(notification).encodeLine()
        let decoded = try MCPMessage.decodeLine(line)
        #expect(decoded == .notification(notification))
        #expect(!line.contains("\"id\""))
    }

    @Test func stringIDSupported() throws {
        let request = MCPJSONRPCRequest(id: .string("abc"), method: "ping")
        let decoded = try MCPMessage.decodeLine(try request.encodeLine())
        guard case .request(let r) = decoded else {
            Issue.record("expected request")
            return
        }
        #expect(r.id == .string("abc"))
    }

    @Test func protocolEnvelopeRejectsLegacyVersionAndMixedResponse() throws {
        let legacy = #"{"jsonrpc":"1.0","id":1,"result":{}}"#
        #expect(throws: DecodingError.self) {
            _ = try MCPMessage.decodeLine(legacy)
        }

        let mixed = #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}"#
        #expect(throws: DecodingError.self) {
            _ = try MCPMessage.decodeLine(mixed)
        }
    }

    @Test func protocolEnvelopeDoesNotMisclassifyMixedRequest() throws {
        let mixed = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","result":{}}"#
        #expect(throws: DecodingError.self) {
            _ = try MCPMessage.decodeLine(mixed)
        }
    }

    @Test func protocolDecoderRejectsDuplicateUnknownAndUnboundedInput() throws {
        let duplicate = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"a":1,"\u0061":2}}"#
        #expect(throws: MCPClientError.self) {
            _ = try MCPMessage.decodeLine(duplicate)
        }

        let unknown = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","unexpected":true}"#
        #expect(throws: DecodingError.self) {
            _ = try MCPMessage.decodeLine(unknown)
        }

        let deeplyNested = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(throws: MCPClientError.self) {
            _ = try MCPMessage.decodeLine(deeplyNested)
        }
    }

    @Test func boundToolNameBuildAndParse() {
        let full = MCPBoundTool.makeFullName(serverID: "my-server", toolName: "create_issue")
        #expect(full == "mcp_my-server_create_issue")
        let parsed = MCPBoundTool.parseFullName(full)
        #expect(parsed?.serverID == "my-server")
        #expect(parsed?.toolName == "create_issue")
        // Names with illegal chars get sanitized on the way in.
        #expect(MCPBoundTool.makeFullName(serverID: "a b", toolName: "x|y") == "mcp_a-b_x-y")
        #expect(MCPBoundTool.parseFullName("shell_execute") == nil)
    }

    @Test func agentToolDefinitionRejectsUndeclaredRequiredProperty() {
        let tool = MCPTool(
            name: "strict-required",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["declared": .object(["type": .string("string")])]),
                "required": .array([.string("missing")]),
            ])
        )

        #expect(throws: MCPClientError.invalidSchema(
            "tool 'strict-required' required property 'missing' is not declared"
        )) {
            _ = try tool.makeAgentToolDefinition()
        }
    }

    @Test func agentToolDefinitionRejectsDuplicateRequiredProperty() {
        let tool = MCPTool(
            name: "strict-duplicate-required",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["name": .object(["type": .string("string")])]),
                "required": .array([.string("name"), .string("name")]),
            ])
        )

        #expect(throws: MCPClientError.invalidSchema(
            "tool 'strict-duplicate-required' required contains duplicate property 'name'"
        )) {
            _ = try tool.makeAgentToolDefinition()
        }
    }

    @Test func agentToolDefinitionRejectsLossyEnumValues() {
        let cases: [(String, MCPJSONValue, String)] = [
            (
                "non-string",
                .array([.string("safe"), .number(1)]),
                "tool 'strict-enum' property 'mode' enum contains a non-string value"
            ),
            (
                "empty",
                .array([]),
                "tool 'strict-enum' property 'mode' enum must not be empty"
            ),
            (
                "duplicate",
                .array([.string("safe"), .string("safe")]),
                "tool 'strict-enum' property 'mode' enum contains duplicate values"
            ),
        ]

        for (_, enumValue, message) in cases {
            let tool = MCPTool(
                name: "strict-enum",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mode": .object([
                            "type": .string("string"),
                            "enum": enumValue,
                        ])
                    ]),
                ])
            )

            #expect(throws: MCPClientError.invalidSchema(message)) {
                _ = try tool.makeAgentToolDefinition()
            }
        }
    }

    @Test func agentToolDefinitionRejectsInvalidSchemaContainers() {
        let cases: [(String, MCPJSONValue, String)] = [
            (
                "properties",
                .number(1),
                "tool 'strict-container' properties must be an object"
            ),
            (
                "required",
                .string("name"),
                "tool 'strict-container' required must be an array"
            ),
        ]

        for (field, value, message) in cases {
            let tool = MCPTool(
                name: "strict-container",
                inputSchema: .object([
                    "type": .string("object"),
                    field: value,
                ])
            )

            #expect(throws: MCPClientError.invalidSchema(message)) {
                _ = try tool.makeAgentToolDefinition()
            }
        }
    }

    @Test func agentToolDefinitionRejectsNonStringPropertyDescription() {
        let tool = MCPTool(
            name: "strict-description",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .number(42),
                    ])
                ]),
            ])
        )

        #expect(throws: MCPClientError.invalidSchema(
            "tool 'strict-description' property 'name' description must be a string"
        )) {
            _ = try tool.makeAgentToolDefinition()
        }
    }

    @Test func agentToolDefinitionRejectsEnumOnNonStringProperty() {
        let tool = MCPTool(
            name: "typed-enum",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "count": .object([
                        "type": .string("integer"),
                        "enum": .array([.string("1")]),
                    ])
                ]),
            ])
        )

        #expect(throws: MCPClientError.invalidSchema(
            "tool 'typed-enum' property 'count' enum is unsupported for non-string type"
        )) {
            _ = try tool.makeAgentToolDefinition()
        }
    }

    @Test func agentToolDefinitionRejectsMalformedEnumContainer() {
        let tool = MCPTool(
            name: "enum-container",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .number(1),
                    ])
                ]),
            ])
        )

        #expect(throws: MCPClientError.invalidSchema(
            "tool 'enum-container' property 'mode' enum must be an array"
        )) {
            _ = try tool.makeAgentToolDefinition()
        }
    }
}

// MARK: - Server Manager CRUD + 持久化

struct MCPServerManagerTests {

    @Test func boundedReaderChunkBoundaryAndInvalidLimitMatrix() throws {
        let directory = try makeTempDir("MCPBoundedReaderBoundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let exactURL = directory.appendingPathComponent("exact.bin")
        let overURL = directory.appendingPathComponent("over.bin")
        let exact = Data(repeating: 0x61, count: 64 * 1024)
        let over = Data(repeating: 0x62, count: (64 * 1024) + 1)
        try exact.write(to: exactURL)
        try over.write(to: overURL)

        #expect(MCPBoundedDocumentReader.read(from: exactURL, maxBytes: exact.count) == .data(exact))
        #expect(MCPBoundedDocumentReader.read(from: overURL, maxBytes: exact.count) == .tooLarge)

        let missingURL = directory.appendingPathComponent("missing.bin")
        #expect(MCPBoundedDocumentReader.read(from: missingURL, maxBytes: -1) == .tooLarge)
        #expect(MCPBoundedDocumentReader.read(from: missingURL, maxBytes: Int.max) == .tooLarge)
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))
    }

    @Test func persistedConfigLoadBoundaryRejectsOverLimitAndRevokesTempCapability() throws {
        let limit = 32 * 1024 * 1024
        let server = MCPServer(
            id: "bounded-config",
            name: "Bounded Config",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )
        let seedDirectory = try makeTempDir("MCPConfigLoadSeed")
        let seedFile = seedDirectory.appendingPathComponent("mcps.json")
        let seed = MCPServerManager(fileURL: seedFile)
        try seed.addServer(server)
        let base = try Data(contentsOf: seedFile)
        try? FileManager.default.removeItem(at: seedDirectory)

        for (index, size) in [64 * 1024, (64 * 1024) + 1, limit, limit + 1].enumerated() {
            let directory = try makeTempDir("MCPConfigLoadCase-\(index)")
            let file = directory.appendingPathComponent("mcps.json")
            var payload = base
            try #require(base.count <= size)
            payload.append(Data(repeating: 0x20, count: size - base.count))
            try payload.write(to: file)

            let temporaryPayload = Data("stale-config".utf8)
            let temporary = directory.appendingPathComponent(
                ".mcps.json.tmp-\(UUID().uuidString)-\(DeletionGate.fingerprint(temporaryPayload))"
            )
            try temporaryPayload.write(to: temporary)
            let reloaded = MCPServerManager(fileURL: file)

            if size <= limit {
                #expect(reloaded.server(id: server.id) == server)
            } else {
                #expect(reloaded.server(id: server.id) == nil)
                #expect(reloaded.cleanupJournalLoadValidityDiagnosticStage() == "documentStrictJSON")
                let receipt = try #require(
                    reloaded.staleTempCleanupReceipts().first { $0.targetPath == file.path }
                )
                #expect(reloaded.cleanupStaleTemp(receipt: receipt) == .rejected)
                #expect(FileManager.default.fileExists(atPath: temporary.path))
            }
            #expect(try Data(contentsOf: file) == payload)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func persistedAuthorizationLoadOversizeAndCorruptDefaultToDeny() throws {
        let limit = 32 * 1024 * 1024
        let server = MCPServer(
            id: "bounded-authorization",
            name: "Bounded Authorization",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )
        let seedDirectory = try makeTempDir("MCPAuthorizationLoadSeed")
        let seedFile = seedDirectory.appendingPathComponent("mcps.json")
        let seedAuthorizationFile = seedDirectory.appendingPathComponent("mcp-authorizations.json")
        let seed = MCPServerManager(fileURL: seedFile, authorizationFileURL: seedAuthorizationFile)
        try seed.addServer(server)
        try seed.authorizeServer(id: server.id)
        try seed.authorizeTool(serverID: server.id, toolName: "read")
        let config = try Data(contentsOf: seedFile)
        let authorization = try Data(contentsOf: seedAuthorizationFile)
        try? FileManager.default.removeItem(at: seedDirectory)

        var oversized = authorization
        try #require(authorization.count < limit)
        oversized.append(Data(repeating: 0x20, count: (limit + 1) - authorization.count))

        func assertDeny(_ sidecar: Data, label: String) throws {
            let directory = try makeTempDir("MCPAuthorizationLoad-\(label)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("mcps.json")
            let authorizationFile = directory.appendingPathComponent("mcp-authorizations.json")
            try config.write(to: file)
            try sidecar.write(to: authorizationFile)
            let reloaded = MCPServerManager(fileURL: file, authorizationFileURL: authorizationFile)

            #expect(reloaded.server(id: server.id) == server)
            #expect(reloaded.authorization(serverID: server.id) == nil)
            #expect(!reloaded.isServerAuthorized(server))
            #expect(!reloaded.isToolAuthorized(serverID: server.id, toolName: "read"))
            #expect(try Data(contentsOf: file) == config)
            #expect(try Data(contentsOf: authorizationFile) == sidecar)
        }

        try assertDeny(oversized, label: "oversize")
        try assertDeny(Data("{\"authorizations\":[".utf8), label: "corrupt")
    }

    @Test func persistedConfigSaveBoundaryRejectsOverLimitAndRollsBack() throws {
        let limit = 32 * 1024 * 1024
        let baselineServer = MCPServer(
            id: "config-save-boundary",
            name: "seed",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )
        let calibrationDirectory = try makeTempDir("MCPConfigSaveCalibration")
        let calibrationFile = calibrationDirectory.appendingPathComponent("mcps.json")
        let calibration = MCPServerManager(fileURL: calibrationFile)
        try calibration.addServer(baselineServer)
        let baselineData = try Data(contentsOf: calibrationFile)
        let targetNameLength = limit - baselineData.count + baselineServer.name.utf8.count
        try #require(targetNameLength > baselineServer.name.utf8.count)
        try? FileManager.default.removeItem(at: calibrationDirectory)

        let exactDirectory = try makeTempDir("MCPConfigSaveExact")
        let exactFile = exactDirectory.appendingPathComponent("mcps.json")
        let exactManager = MCPServerManager(fileURL: exactFile)
        try exactManager.addServer(baselineServer)
        var exactServer = baselineServer
        exactServer.name = String(repeating: "n", count: targetNameLength)
        try exactManager.updateServer(exactServer)
        #expect(try Data(contentsOf: exactFile).count == limit)
        #expect(exactManager.server(id: exactServer.id)?.name == exactServer.name)
        try? FileManager.default.removeItem(at: exactDirectory)

        let overDirectory = try makeTempDir("MCPConfigSaveOver")
        defer { try? FileManager.default.removeItem(at: overDirectory) }
        let overFile = overDirectory.appendingPathComponent("mcps.json")
        let overAuthorizationFile = overDirectory.appendingPathComponent("mcp-authorizations.json")
        let overManager = MCPServerManager(fileURL: overFile, authorizationFileURL: overAuthorizationFile)
        try overManager.addServer(baselineServer)
        let oldConfig = try Data(contentsOf: overFile)
        let oldAuthorization = try Data(contentsOf: overAuthorizationFile)
        let oldServers = overManager.listServers()
        let oldRevision = overManager.snapshot().revision
        var oversizedServer = baselineServer
        oversizedServer.name = String(repeating: "o", count: targetNameLength + 1)

        var didThrow = false
        do {
            _ = try overManager.updateServer(oversizedServer)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(overManager.listServers() == oldServers)
        #expect(overManager.snapshot().revision == oldRevision)
        #expect(try Data(contentsOf: overFile) == oldConfig)
        #expect(try Data(contentsOf: overAuthorizationFile) == oldAuthorization)
    }

    @Test func authorizationSaveRejectsOversizeAndRollsBack() throws {
        let limit = 32 * 1024 * 1024
        let server = MCPServer(
            id: "authorization-save-boundary",
            name: "Authorization Save Boundary",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )
        let calibrationDirectory = try makeTempDir("MCPAuthorizationSaveCalibration")
        let calibrationFile = calibrationDirectory.appendingPathComponent("mcps.json")
        let calibrationAuthorizationFile = calibrationDirectory.appendingPathComponent("mcp-authorizations.json")
        let calibration = MCPServerManager(
            fileURL: calibrationFile,
            authorizationFileURL: calibrationAuthorizationFile
        )
        try calibration.addServer(server)
        try calibration.authorizeServer(id: server.id)
        let baseAuthorization = try Data(contentsOf: calibrationAuthorizationFile)
        try calibration.authorizeTool(serverID: server.id, toolName: "x")
        let oneToolAuthorization = try Data(contentsOf: calibrationAuthorizationFile)
        let nameDelta = oneToolAuthorization.count - baseAuthorization.count - 1
        try #require(nameDelta >= 0)
        let oversizedToolLength = (limit - baseAuthorization.count - nameDelta) + 1
        try #require(oversizedToolLength > 0)
        try? FileManager.default.removeItem(at: calibrationDirectory)

        let directory = try makeTempDir("MCPAuthorizationSaveOver")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcps.json")
        let authorizationFile = directory.appendingPathComponent("mcp-authorizations.json")
        let manager = MCPServerManager(fileURL: file, authorizationFileURL: authorizationFile)
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let oldConfig = try Data(contentsOf: file)
        let oldAuthorization = try Data(contentsOf: authorizationFile)
        let oldGrant = try #require(manager.authorization(serverID: server.id))
        let oldRevision = manager.snapshot().revision

        var didThrow = false
        do {
            _ = try manager.authorizeTool(
                serverID: server.id,
                toolName: String(repeating: "t", count: oversizedToolLength)
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(manager.authorization(serverID: server.id) == oldGrant)
        #expect(manager.snapshot().revision == oldRevision)
        #expect(try Data(contentsOf: file) == oldConfig)
        #expect(try Data(contentsOf: authorizationFile) == oldAuthorization)
    }

    @Test func oversizeAuthorizationPreflightPreservesConfigFile() throws {
        let limit = 32 * 1024 * 1024
        let server = MCPServer(
            id: "authorization-preflight",
            name: "Authorization Preflight",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )

        func authorizationData(
            toolName: String,
            options: JSONSerialization.WritingOptions
        ) throws -> Data {
            let grant = MCPToolAuthorization(
                serverID: server.id,
                descriptorFingerprint: server.descriptorFingerprint,
                serverAuthorized: true,
                authorizedToolNames: [toolName],
                schemaBindingDigest: ""
            )
            let grantData = try JSONEncoder().encode(grant)
            let grantObject = try JSONSerialization.jsonObject(with: grantData)
            return try JSONSerialization.data(
                withJSONObject: ["authorizations": [grantObject], "revision": 1],
                options: options
            )
        }

        _ = try authorizationData(toolName: "x", options: [.sortedKeys])
        let prettyBase = try authorizationData(toolName: "x", options: [.prettyPrinted, .sortedKeys])
        let toolNameLength = (limit - prettyBase.count) + 2
        try #require(toolNameLength > 0)
        let compact = try authorizationData(
            toolName: String(repeating: "p", count: toolNameLength),
            options: [.sortedKeys]
        )
        let pretty = try authorizationData(
            toolName: String(repeating: "p", count: toolNameLength),
            options: [.prettyPrinted, .sortedKeys]
        )
        try #require(compact.count < limit)
        try #require(pretty.count > limit)

        let directory = try makeTempDir("MCPAuthorizationPreflight")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcps.json")
        let authorizationFile = directory.appendingPathComponent("mcp-authorizations.json")
        let manager = MCPServerManager(fileURL: file, authorizationFileURL: authorizationFile)
        try manager.addServer(server)
        let configBefore = try Data(contentsOf: file)
        try compact.write(to: authorizationFile)

        let reloaded = MCPServerManager(fileURL: file, authorizationFileURL: authorizationFile)
        #expect(reloaded.authorization(serverID: server.id) != nil)
        #expect(reloaded.isToolAuthorized(serverID: server.id, toolName: String(repeating: "p", count: toolNameLength)))
        let oldServers = reloaded.listServers()
        let oldRevision = reloaded.snapshot().revision
        let oldAuthorization = try Data(contentsOf: authorizationFile)
        let trigger = MCPServer(
            id: "authorization-preflight-trigger",
            name: "Trigger",
            type: .stdio,
            command: "/bin/true",
            timeoutSeconds: 1
        )

        var didThrow = false
        do {
            _ = try reloaded.addServer(trigger)
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(reloaded.listServers() == oldServers)
        #expect(reloaded.snapshot().revision == oldRevision)
        #expect(try Data(contentsOf: file) == configBefore)
        #expect(try Data(contentsOf: authorizationFile) == oldAuthorization)
    }

    @Test func discoveryNormalizationIsStableAcrossDuplicateResponseOrder() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "deterministic-discovery",
            name: "Deterministic Discovery",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let box = MCPToolsBox([
            MCPTool(name: " greet ", description: "a"),
            MCPTool(name: "greet", description: "a"),
            MCPTool(name: "Beta"),
            MCPTool(name: "alpha"),
        ])
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                MockMCPTransport.happyResponse(for: request, tools: box.value, callText: "ok")
            })
        }

        let first = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        box.replace([
            MCPTool(name: "alpha"),
            MCPTool(name: "greet", description: "a"),
            MCPTool(name: " greet ", description: "a"),
            MCPTool(name: "Beta"),
        ])
        let second = try await manager.discoverTools(serverID: server.id, clientFactory: factory)

        #expect(first == second)
        #expect(first.map(\.name) == ["alpha", "Beta", "greet"])
        #expect(first.last?.description == "a")
        #expect(manager.discoverySnapshot(serverID: server.id)?.tools == second)
    }

    @Test func discoveryRejectsConflictingDuplicateToolDefinitionsWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "duplicate-conflict", name: "Duplicate Conflict", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([
                            .object(["name": .string("greet"), "description": .string("first")]),
                            .object(["name": .string("greet"), "description": .string("second")]),
                        ])
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPDiscoveryError.toolConflict(serverID: server.id, toolName: "greet")) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func discoveryRejectsCrossPageToolSchemaConflictWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "cross-page-conflict", name: "Cross Page Conflict", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    pageCount.value += 1
                    let description = pageCount.value == 1 ? "first" : "second"
                    var result: [String: MCPJSONValue] = [
                        "tools": .array([.object([
                            "name": .string("greet"),
                            "description": .string(description),
                        ])])
                    ]
                    if pageCount.value == 1 {
                        result["nextCursor"] = .string("page-2")
                    }
                    return MCPJSONRPCResponse(id: request.id, result: .object(result))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPDiscoveryError.toolConflict(serverID: server.id, toolName: "greet")) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(pageCount.value == 2)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func discoveryCacheBindsRevisionFingerprintAndAuthorization() async throws {
        let fixture = try writeDiscoveryServerScript()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (manager, file) = try makeManager()
        let server = MCPServer(
            id: "cached",
            name: "Cached",
            type: .stdio,
            command: "/bin/sh",
            args: [fixture.script.path],
            env: ["MCP_DISCOVERY_MARKER": fixture.marker.path],
            timeoutSeconds: 2
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let tools = try await manager.discoverTools(serverID: server.id)
        #expect(tools.map(\.name) == ["greet"])
        #expect(manager.cachedTools(serverID: server.id) == tools)

        let snapshot = manager.snapshot()
        #expect(snapshot.discoverySnapshots[server.id]?.revision == snapshot.revision)
        #expect(snapshot.discoverySnapshots[server.id]?.descriptorFingerprint == server.descriptorFingerprint)
        #expect(snapshot.discoverySnapshots[server.id]?.serverID == server.id)
        #expect(snapshot.discoverySnapshots[server.id]?.id == "\(server.id):r\(snapshot.revision):\(server.descriptorFingerprint)")
        #expect((snapshot.discoverySnapshots[server.id]?.transportGeneration ?? 0) > 0)
        #expect(snapshot.discoverySnapshots[server.id]?.schemaDigest == MCPDiscoverySnapshot.schemaDigest(for: tools))
        #expect(manager.makeSnapshotManager().cachedTools(serverID: server.id) == tools)

        try manager.revokeServer(id: server.id)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)

        // Authorization is a generation boundary, not merely a current-map
        // check: reauthorizing the server (and a tool) must not revive the
        // discovery result produced before revocation.
        let afterRevokeRevision = manager.snapshot().revision
        try manager.authorizeServer(id: server.id)
        #expect(manager.snapshot().revision > afterRevokeRevision)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        #expect(manager.cachedTools(serverID: server.id).isEmpty)

        // The generation survives a manager/turn boundary, so a newly loaded
        // manager cannot accidentally reuse an old revision if a cache is
        // later restored by a caller.
        let currentRevision = manager.snapshot().revision
        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.snapshot().revision == currentRevision)
        #expect(reloaded.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func durableDiscoveryCacheReloadRejectsCorruptedSchemaDigest() async throws {
        let (manager, file) = try makeManager()
        let server = MCPServer(
            id: "corrupt-discovery-cache",
            name: "Corrupt Discovery Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy())
        })

        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var snapshots = try #require(root["discoverySnapshots"] as? [String: Any])
        var snapshot = try #require(snapshots[server.id] as? [String: Any])
        #expect((snapshot["transportGeneration"] as? Int ?? 0) > 0)
        #expect(snapshot["schemaDigest"] as? String == MCPDiscoverySnapshot.schemaDigest(for: manager.cachedTools(serverID: server.id)))
        snapshot["schemaDigest"] = "corrupted"
        snapshots[server.id] = snapshot
        root["discoverySnapshots"] = snapshots
        let corrupted = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try corrupted.write(to: file, options: .atomic)

        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.cachedTools(serverID: server.id).isEmpty)
        #expect(reloaded.snapshot().discoverySnapshots.isEmpty)
    }

    @Test func durableCacheRenameFailurePreservesOldMemoryAndRetainsStaleTemp() async throws {
        let (manager, file) = try makeManager()
        let server = MCPServer(
            id: "atomic-discovery-cache",
            name: "Atomic Discovery Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let oldTools = try await manager.discoverTools(serverID: server.id, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(tools: [MCPTool(name: "old")]))
        })
        let oldSnapshot = try #require(manager.discoverySnapshot(serverID: server.id))
        let committedConfig = try Data(contentsOf: file)
        let committedAuthorization = try Data(contentsOf: manager.authorizationFileURL)

        // Keep the committed regular file readable by the pair fence, then
        // fail the actual rename into that existing file. Replacing it with a
        // directory before the operation only exercises the pre-write fence.
        var originalMetadata = stat()
        guard file.path.withCString({ Darwin.lstat($0, &originalMetadata) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let originalFlags = originalMetadata.st_flags
        guard file.path.withCString({ Darwin.chflags($0, originalFlags | UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if file.path.withCString({ Darwin.chflags($0, originalFlags) }) != 0 {
                Issue.record("Failed to restore flags on this test's synthetic config")
            }
        }
        let torn = file.deletingLastPathComponent().appendingPathComponent(".mcps.json.tmp-torn")
        try Data("torn".utf8).write(to: torn)

        await #expect(throws: MCPDurableWriteError.self) {
            do {
                _ = try await manager.discoverTools(serverID: server.id, clientFactory: { server in
                    MCPClient(server: server, transport: MockMCPTransport.happy(tools: [MCPTool(name: "old")]))
                })
            } catch let error as MCPDurableWriteError {
                if case .renameFailed = error { /* the intended write-stage fault */ }
                else { Issue.record("Expected actual rename failure, got \(error)") }
                throw error
            }
        }
        #expect(try Data(contentsOf: file) == committedConfig)
        #expect(try Data(contentsOf: manager.authorizationFileURL) == committedAuthorization)
        // B1431: failed durable publication keeps the strict reopen boundary;
        // cached tools become available again only after a fresh owner reopens.
        #expect(manager.persistenceWriteConflict() == .needsReopen)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)

        guard file.path.withCString({ Darwin.chflags($0, originalFlags) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #expect(throws: MCPPersistenceConflict.needsReopen) { try manager.save() }
        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.cachedTools(serverID: server.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: torn.path))
        #expect(reloaded.persistenceWriteConflict() == nil)
        let reopenedTools = try await reloaded.discoverTools(serverID: server.id, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(tools: [MCPTool(name: "old")]))
        })
        #expect(reopenedTools == oldTools)
        #expect(reloaded.cachedTools(serverID: server.id) == oldTools)
        let reopenedSnapshot = try #require(reloaded.discoverySnapshot(serverID: server.id))
        #expect(reopenedSnapshot.tools == oldSnapshot.tools)
        #expect(reopenedSnapshot.publicationID != oldSnapshot.publicationID)
    }

    @Test func changedSchemaWithCacheRenameFailureStillRetiresOldGrant() async throws {
        let (manager, file) = try makeManager()
        let server = MCPServer(
            id: "atomic-schema-change",
            name: "Atomic Schema Change",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "old")
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(tools: [MCPTool(name: "old")]))
        })
        #expect(manager.isToolAuthorized(serverID: server.id, toolName: "old"))

        // The server-cache rename fails after the changed schema has already
        // been observed. Restoring the old snapshot must not restore its grant.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        await #expect(throws: MCPPersistenceConflict.documentUnavailable(path: file.path, code: EINVAL)) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: { server in
                MCPClient(server: server, transport: MockMCPTransport.happy(tools: [MCPTool(name: "new")]))
            })
        }
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "old"))
        #expect(manager.authorization(serverID: server.id)?.authorizedToolNames.isEmpty == true)
    }

    @Test func tornTempRecoveryPreservesStaleOwnedAndForeignFiles() throws {
        let (_, file) = try makeManager()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = ".\(file.lastPathComponent).tmp-"
        func ownedTempURL(payload: String) -> URL {
            directory.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)-\(DeletionGate.fingerprint(Data(payload.utf8)))"
            )
        }
        let owned = ownedTempURL(payload: "owned")
        try Data("owned".utf8).write(to: owned)
        let candidate = ownedTempURL(payload: "candidate")
        try Data("candidate".utf8).write(to: candidate)

        let foreign = directory.appendingPathComponent("\(prefix)foreign")
        try Data("foreign".utf8).write(to: foreign)
        let target = directory.appendingPathComponent("protected-target")
        try Data("target".utf8).write(to: target)
        let symlink = ownedTempURL(payload: "symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let hardlinkSource = ownedTempURL(payload: "hardlink")
        try Data("hardlink".utf8).write(to: hardlinkSource)
        let hardlink = ownedTempURL(payload: "hardlink")
        try FileManager.default.linkItem(at: hardlinkSource, to: hardlink)

        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.staleTempCleanupReceipts(limit: 0).isEmpty)
        let receipts = reloaded.staleTempCleanupReceipts(limit: 8)
        let receipt = try #require(
            receipts.first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == owned.standardizedFileURL
            },
            "torn-temp-stages=\(reloaded.tornTempRecoveryDiagnosticStages()); counters=\(reloaded.tornTempRecoveryDiagnosticCounters()); \(tornTempReceiptDiagnostic(receipts, expectedURL: owned))"
        )
        let candidateReceipt = try #require(receipts.first { URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL == candidate.standardizedFileURL })
        #expect(receipts.count == 2)
        #expect(receipt.targetPath == file.path)
        #expect(receipt.payloadDigest == DeletionGate.fingerprint(Data("owned".utf8)))
        #expect(receipt.generation > 0)
        #expect(receipt.expiresAt > Date())
        let restarted = MCPServerManager(fileURL: file)
        #expect(restarted.cleanupStaleTemp(receipt: receipt) == .rejected)

        let forged = MCPStaleTempCleanupReceipt(
            targetPath: receipt.targetPath,
            temporaryPath: receipt.temporaryPath,
            transactionToken: receipt.transactionToken,
            payloadDigest: String(repeating: "b", count: 64),
            directoryPath: receipt.directoryPath,
            directoryDevice: receipt.directoryDevice,
            directoryInode: receipt.directoryInode
        )
        #expect(reloaded.cleanupStaleTemp(receipt: forged) == .rejected)
        #expect(FileManager.default.fileExists(atPath: owned.path))
        let expired = MCPStaleTempCleanupReceipt(
            targetPath: receipt.targetPath,
            temporaryPath: receipt.temporaryPath,
            transactionToken: receipt.transactionToken,
            payloadDigest: receipt.payloadDigest,
            directoryPath: receipt.directoryPath,
            directoryDevice: receipt.directoryDevice,
            directoryInode: receipt.directoryInode,
            temporaryDevice: receipt.temporaryDevice,
            temporaryInode: receipt.temporaryInode,
            generation: receipt.generation,
            expiresAt: .distantPast
        )
        #expect(reloaded.cleanupStaleTemp(receipt: expired) == .rejected)

        let replacementSource = directory.appendingPathComponent("replacement-source")
        try Data("replacement".utf8).write(to: replacementSource)
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.moveItem(at: replacementSource, to: owned)
        #expect(reloaded.cleanupStaleTemp(receipt: receipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: owned.path))

        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(reloaded.cleanupStaleTemp(receipt: candidateReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
        #expect(reloaded.staleTempCleanupReceipts().contains(candidateReceipt))
        try FileManager.default.removeItem(at: file)
        #expect(reloaded.cleanupStaleTemp(receipt: candidateReceipt) == .removed)
        #expect(reloaded.cleanupStaleTemp(receipt: candidateReceipt) == .rejected)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        let persistedRoot = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: []) as? [String: Any]
        )
        let persistedJournal = try #require(persistedRoot["staleTempCleanupJournal"] as? [String: Any])
        #expect(persistedJournal.count == 1)
        let persistedEntry = try #require(persistedJournal.values.first as? [String: Any])
        #expect(persistedEntry["state"] as? String == "committed")
        let postConsumption = MCPServerManager(fileURL: file)
        #expect(postConsumption.cleanupStaleTemp(receipt: candidateReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(FileManager.default.fileExists(atPath: hardlinkSource.path))
        #expect(FileManager.default.fileExists(atPath: hardlink.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "target")
    }

    @Test func cleanupReceiptPinsDirectoryIdentityAcrossAliasesAndRejectsSubstitution() throws {
        let publicAliasDirectory = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("MCPReceiptDirectoryAlias-\(UUID().uuidString)", isDirectory: true)
        let privateAliasDirectory = URL(
            fileURLWithPath: "/private" + publicAliasDirectory.path,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: publicAliasDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: publicAliasDirectory) }
        var publicAliasMetadata = stat()
        var privateAliasMetadata = stat()
        try #require(Darwin.lstat(publicAliasDirectory.path, &publicAliasMetadata) == 0)
        try #require(Darwin.lstat(privateAliasDirectory.path, &privateAliasMetadata) == 0)
        #expect(publicAliasDirectory.path != privateAliasDirectory.path)
        #expect(publicAliasMetadata.st_dev == privateAliasMetadata.st_dev)
        #expect(publicAliasMetadata.st_ino == privateAliasMetadata.st_ino)

        let aliasFile = publicAliasDirectory.appendingPathComponent("mcps.json")
        let aliasPayload = Data("alias-positive".utf8)
        let aliasTransaction = UUID().uuidString
        let aliasDigest = DeletionGate.fingerprint(aliasPayload)
        let aliasTemporary = privateAliasDirectory.appendingPathComponent(
            ".mcps.json.tmp-\(aliasTransaction)-\(aliasDigest)"
        )
        try aliasPayload.write(to: aliasTemporary)
        let aliasManager = MCPServerManager(fileURL: aliasFile)
        let aliasReceipts = aliasManager.staleTempCleanupReceipts()
        #expect(aliasReceipts.count == 1)
        let aliasReceipt = try #require(aliasReceipts.first)
        let issuedTemporaryDirectory = URL(fileURLWithPath: aliasReceipt.temporaryPath)
            .deletingLastPathComponent()
        var issuedTemporaryDirectoryMetadata = stat()
        try #require(Darwin.lstat(issuedTemporaryDirectory.path, &issuedTemporaryDirectoryMetadata) == 0)
        #expect(aliasReceipt.directoryPath == publicAliasDirectory.path)
        #expect(issuedTemporaryDirectory.path == privateAliasDirectory.path)
        #expect(aliasReceipt.directoryPath != issuedTemporaryDirectory.path)
        #expect(UInt64(publicAliasMetadata.st_dev) == aliasReceipt.directoryDevice)
        #expect(UInt64(publicAliasMetadata.st_ino) == aliasReceipt.directoryInode)
        #expect(issuedTemporaryDirectoryMetadata.st_dev == publicAliasMetadata.st_dev)
        #expect(issuedTemporaryDirectoryMetadata.st_ino == publicAliasMetadata.st_ino)
        #expect(URL(fileURLWithPath: aliasReceipt.temporaryPath).lastPathComponent == aliasTemporary.lastPathComponent)
        #expect(aliasManager.cleanupStaleTemp(receipt: aliasReceipt) == .removed)

        let trustedDirectory = try makeTempDir("MCPReceiptTrustedDirectory")
        let externalDirectory = try makeTempDir("MCPReceiptExternalDirectory")
        defer { try? FileManager.default.removeItem(at: trustedDirectory) }
        defer { try? FileManager.default.removeItem(at: externalDirectory) }
        var trustedMetadata = stat()
        try #require(Darwin.lstat(trustedDirectory.path, &trustedMetadata) == 0)
        let externalTransaction = UUID().uuidString
        let externalDigest = DeletionGate.fingerprint(Data("external".utf8))
        let externalTemporary = externalDirectory.appendingPathComponent(
            ".mcps.json.tmp-\(externalTransaction)-\(externalDigest)"
        )
        try Data("external".utf8).write(to: externalTemporary)
        let externalReceipt = MCPStaleTempCleanupReceipt(
            targetPath: trustedDirectory.appendingPathComponent("mcps.json").path,
            temporaryPath: externalTemporary.path,
            transactionToken: externalTransaction,
            payloadDigest: externalDigest,
            directoryPath: trustedDirectory.path,
            directoryDevice: UInt64(trustedMetadata.st_dev),
            directoryInode: UInt64(trustedMetadata.st_ino)
        )
        #expect(MCPServerManager.receiptMatchesCurrentFile(externalReceipt) == false)

        let replacementDirectory = try makeTempDir("MCPReceiptDirectoryReplacement")
        let movedDirectory = replacementDirectory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        defer { try? FileManager.default.removeItem(at: movedDirectory) }
        var replacementMetadata = stat()
        try #require(Darwin.lstat(replacementDirectory.path, &replacementMetadata) == 0)
        let replacementTransaction = UUID().uuidString
        let replacementDigest = DeletionGate.fingerprint(Data("replacement".utf8))
        let replacementTemporary = replacementDirectory.appendingPathComponent(
            ".mcps.json.tmp-\(replacementTransaction)-\(replacementDigest)"
        )
        try FileManager.default.moveItem(at: replacementDirectory, to: movedDirectory)
        try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: replacementTemporary)
        let replacementReceipt = MCPStaleTempCleanupReceipt(
            targetPath: replacementDirectory.appendingPathComponent("mcps.json").path,
            temporaryPath: replacementTemporary.path,
            transactionToken: replacementTransaction,
            payloadDigest: replacementDigest,
            directoryPath: replacementDirectory.path,
            directoryDevice: UInt64(replacementMetadata.st_dev),
            directoryInode: UInt64(replacementMetadata.st_ino)
        )
        #expect(MCPServerManager.receiptMatchesCurrentFile(replacementReceipt) == false)

        let symlinkDirectory = try makeTempDir("MCPReceiptLeafSymlink")
        defer { try? FileManager.default.removeItem(at: symlinkDirectory) }
        let symlinkFile = symlinkDirectory.appendingPathComponent("mcps.json")
        let symlinkTarget = symlinkDirectory.appendingPathComponent("external-target")
        let symlinkPayload = Data("symlink-candidate".utf8)
        let symlinkTransaction = UUID().uuidString
        let symlinkDigest = DeletionGate.fingerprint(symlinkPayload)
        let symlinkTemporary = symlinkDirectory.appendingPathComponent(
            ".mcps.json.tmp-\(symlinkTransaction)-\(symlinkDigest)"
        )
        try symlinkPayload.write(to: symlinkTemporary)
        try Data("untouched".utf8).write(to: symlinkTarget)
        let symlinkManager = MCPServerManager(fileURL: symlinkFile)
        let symlinkReceipt = try #require(
            symlinkManager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == symlinkTemporary.standardizedFileURL
            }
        )
        try FileManager.default.removeItem(at: symlinkTemporary)
        try FileManager.default.createSymbolicLink(at: symlinkTemporary, withDestinationURL: symlinkTarget)
        #expect(symlinkManager.cleanupStaleTemp(receipt: symlinkReceipt) == .rejected)
        #expect(try String(contentsOf: symlinkTarget, encoding: .utf8) == "untouched")

        let directorySymlinkTarget = try makeTempDir("MCPReceiptDirectorySymlinkTarget")
        let directorySymlink = directorySymlinkTarget.deletingLastPathComponent()
            .appendingPathComponent("MCPReceiptDirectorySymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directorySymlink) }
        defer { try? FileManager.default.removeItem(at: directorySymlinkTarget) }
        try FileManager.default.createSymbolicLink(
            at: directorySymlink,
            withDestinationURL: directorySymlinkTarget
        )
        let directorySymlinkPayload = Data("directory-symlink-candidate".utf8)
        let directorySymlinkTransaction = UUID().uuidString
        let directorySymlinkDigest = DeletionGate.fingerprint(directorySymlinkPayload)
        let directorySymlinkLeafName = ".mcps.json.tmp-\(directorySymlinkTransaction)-\(directorySymlinkDigest)"
        let directorySymlinkRealTemporary = directorySymlinkTarget.appendingPathComponent(
            directorySymlinkLeafName
        )
        try directorySymlinkPayload.write(to: directorySymlinkRealTemporary)
        var directorySymlinkTargetMetadata = stat()
        var directorySymlinkTemporaryMetadata = stat()
        try #require(Darwin.lstat(directorySymlinkTarget.path, &directorySymlinkTargetMetadata) == 0)
        try #require(Darwin.lstat(directorySymlinkRealTemporary.path, &directorySymlinkTemporaryMetadata) == 0)
        let directorySymlinkReceipt = MCPStaleTempCleanupReceipt(
            targetPath: directorySymlink.appendingPathComponent("mcps.json").path,
            temporaryPath: directorySymlink.appendingPathComponent(directorySymlinkLeafName).path,
            transactionToken: directorySymlinkTransaction,
            payloadDigest: directorySymlinkDigest,
            directoryPath: directorySymlink.path,
            directoryDevice: UInt64(directorySymlinkTargetMetadata.st_dev),
            directoryInode: UInt64(directorySymlinkTargetMetadata.st_ino),
            temporaryDevice: UInt64(directorySymlinkTemporaryMetadata.st_dev),
            temporaryInode: UInt64(directorySymlinkTemporaryMetadata.st_ino),
            generation: 0,
            expiresAt: .distantFuture
        )
        #expect(MCPServerManager.receiptMatchesCurrentFile(directorySymlinkReceipt) == false)
        #expect(try Data(contentsOf: directorySymlinkRealTemporary) == directorySymlinkPayload)
    }

    @Test func preparedCleanupJournalReauditsWithNewGenerationAndReplacement() throws {
        let (_, file) = try makeManager()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = ".\(file.lastPathComponent).tmp-"
        func ownedTempURL(payload: String) -> URL {
            directory.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)-\(DeletionGate.fingerprint(Data(payload.utf8)))"
            )
        }
        let preparedTemp = ownedTempURL(payload: "prepared")
        let committedTemp = ownedTempURL(payload: "committed")
        try Data("prepared".utf8).write(to: preparedTemp)
        try Data("committed".utf8).write(to: committedTemp)

        let initial = MCPServerManager(fileURL: file)
        let publishedReceipts = initial.staleTempCleanupReceipts()
        let oldPreparedReceipt = try #require(
            publishedReceipts.first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == preparedTemp.standardizedFileURL
            },
            "torn-temp-stages=\(initial.tornTempRecoveryDiagnosticStages()); counters=\(initial.tornTempRecoveryDiagnosticCounters()); \(tornTempReceiptDiagnostic(publishedReceipts, expectedURL: preparedTemp))"
        )
        _ = try #require(
            publishedReceipts.first { URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL == committedTemp.standardizedFileURL }
        )
        let preparedReceiptID = MCPServerManager.receiptID(oldPreparedReceipt)
        let previousDigest = String(repeating: "0", count: 64)
        let configFingerprint = MCPServerManager.cleanupConfigFingerprint(
            fileURL: file,
            authorizationFileURL: file.deletingLastPathComponent().appendingPathComponent("mcp-authorizations.json"),
            servers: [],
            authorizations: [:],
            revision: 0
        )
        let preparedReadbackIdentity = MCPServerManager.cleanupReadbackIdentity(
            receiptID: preparedReceiptID,
            scope: oldPreparedReceipt.targetPath,
            transactionUUID: oldPreparedReceipt.transactionToken,
            payloadDigest: oldPreparedReceipt.payloadDigest,
            directoryDevice: oldPreparedReceipt.directoryDevice,
            directoryInode: oldPreparedReceipt.directoryInode,
            temporaryDevice: oldPreparedReceipt.temporaryDevice,
            temporaryInode: oldPreparedReceipt.temporaryInode,
            present: true
        )
        let preparedDigest = MCPServerManager.cleanupJournalRecordDigest(
            receiptID: preparedReceiptID,
            generation: 1,
            previousDigest: previousDigest,
            state: "prepared",
            scope: oldPreparedReceipt.targetPath,
            transactionUUID: oldPreparedReceipt.transactionToken,
            preGeneration: 0,
            postGeneration: 1,
            payloadDigest: oldPreparedReceipt.payloadDigest,
            configFingerprint: configFingerprint,
            readbackIdentity: preparedReadbackIdentity
        )
        let journalEntry: [String: Any] = [
            "consumedAt": Date().timeIntervalSinceReferenceDate,
            "digest": preparedDigest,
            "generation": 1,
            "previousDigest": previousDigest,
            "postGeneration": 1,
            "preGeneration": 0,
            "scope": oldPreparedReceipt.targetPath,
            "state": "prepared",
            "transactionUUID": oldPreparedReceipt.transactionToken,
            "payloadDigest": oldPreparedReceipt.payloadDigest,
            "configFingerprint": configFingerprint,
            "readbackIdentity": preparedReadbackIdentity,
        ]
        let journalHistory: [[String: Any]] = [[
            "entry": journalEntry,
            "receiptID": preparedReceiptID,
        ]]
        let root: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [preparedReceiptID: journalEntry],
            "staleTempCleanupJournalHistory": journalHistory,
        ]
        try canonicalJSONFixtureData(root).write(to: file)

        let restarted = MCPServerManager(fileURL: file)
        #expect(restarted.cleanupJournalLoadValidityDiagnosticStage() == "ready")
        let newPreparedReceipt = try #require(
            restarted.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == preparedTemp.standardizedFileURL
            }
        )
        let newCommittedReceipt = try #require(
            restarted.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == committedTemp.standardizedFileURL
            }
        )
        #expect(newPreparedReceipt.generation != oldPreparedReceipt.generation)
        #expect(restarted.cleanupStaleTemp(receipt: oldPreparedReceipt) == .rejected)

        let replacementSource = directory.appendingPathComponent("prepared-replacement")
        try Data("replacement".utf8).write(to: replacementSource)
        try FileManager.default.removeItem(at: preparedTemp)
        try FileManager.default.moveItem(at: replacementSource, to: preparedTemp)
        #expect(restarted.cleanupStaleTemp(receipt: newPreparedReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: preparedTemp.path))

        #expect(restarted.cleanupStaleTemp(receipt: newCommittedReceipt) == .removed)
        let afterCommit = MCPServerManager(fileURL: file)
        #expect(afterCommit.cleanupStaleTemp(receipt: newCommittedReceipt) == .rejected)
        let remaining = afterCommit.staleTempCleanupReceipts()
        #expect(remaining.count == 1)
        #expect(remaining.first.map { URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL }
            == preparedTemp.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: preparedTemp.path))
    }

    @Test func cleanupJournalDocumentUsesSwiftLexicalReceiptKeyOrder() throws {
        let directory = try makeTempDir("MCPCleanupJournalLexicalOrder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcps.json")
        let key09 = "09" + String(repeating: "a", count: 62)
        let key10 = "10" + String(repeating: "a", count: 62)
        let key2 = "2" + String(repeating: "a", count: 63)
        let zeroDigest = String(repeating: "0", count: 64)
        let transaction = "00000000-0000-0000-0000-000000000001"
        let entry: [String: Any] = [
            "configFingerprint": zeroDigest,
            "consumedAt": 0,
            "digest": zeroDigest,
            "generation": 1,
            "payloadDigest": zeroDigest,
            "postGeneration": 1,
            "preGeneration": 0,
            "previousDigest": zeroDigest,
            "readbackIdentity": zeroDigest,
            "scope": file.path,
            "state": "prepared",
            "transactionUUID": transaction,
        ]
        let root: [String: Any] = [
            "discoverySnapshots": [:],
            "fixtureBool": true,
            "fixtureNull": NSNull(),
            "fixtureUInt64": NSNumber(value: UInt64.max),
            "revision": 0,
            "servers": [],
            "staleTempCleanupJournal": [key2: entry, key10: entry, key09: entry],
            "trashServers": [],
        ]

        let lexicalData = try canonicalJSONFixtureData(root)
        let decoded = try #require(
            JSONSerialization.jsonObject(with: lexicalData) as? [String: Any]
        )
        #expect((decoded["fixtureUInt64"] as? NSNumber)?.uint64Value == UInt64.max)
        #expect(decoded["fixtureBool"] as? Bool == true)
        #expect(decoded["fixtureNull"] is NSNull)
        let lexicalText = try #require(String(data: lexicalData, encoding: .utf8))
        let key09Offset = try #require(lexicalText.range(of: "\"\(key09)\""))
        let key10Offset = try #require(lexicalText.range(of: "\"\(key10)\""))
        let key2Offset = try #require(lexicalText.range(of: "\"\(key2)\""))
        #expect(key09Offset.lowerBound < key10Offset.lowerBound)
        #expect(key10Offset.lowerBound < key2Offset.lowerBound)

        try lexicalData.write(to: file)
        let lexicalManager = MCPServerManager(fileURL: file)
        #expect(lexicalManager.cleanupJournalLoadValidityDiagnosticStage() == "chainValidation")

        let numericData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        #expect(numericData != lexicalData)
        try numericData.write(to: file)
        let numericManager = MCPServerManager(fileURL: file)
        #expect(numericManager.cleanupJournalLoadValidityDiagnosticStage() == "documentStrictJSON")
    }

    @Test func cleanupJournalRejectsNonCanonicalDuplicateConfusableAndOversizedInput() throws {
        let (_, file) = try makeManager()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = ".\(file.lastPathComponent).tmp-"
        let temp = directory.appendingPathComponent(
            "\(prefix)\(UUID().uuidString)-\(DeletionGate.fingerprint(Data("stale".utf8)))"
        )
        try Data("stale".utf8).write(to: temp)
        _ = MCPServerManager(fileURL: file)
        let key = String(repeating: "a", count: 64)

        func assertRejected(_ data: Data) throws {
            try data.write(to: file)
            let reloaded = MCPServerManager(fileURL: file)
            let recovered = try #require(reloaded.staleTempCleanupReceipts().first)
            #expect(reloaded.cleanupStaleTemp(receipt: recovered) == .rejected)
            #expect(FileManager.default.fileExists(atPath: temp.path))
        }

        let duplicate = """
        {"servers":[],"trashServers":[],"revision":0,"discoverySnapshots":{},"staleTempCleanupJournal":{"\(key)":{"consumedAt":0,"generation":1,"state":"prepared"},"\(key)":{"consumedAt":0,"generation":1,"state":"committed"}}}
        """
        try assertRejected(Data(duplicate.utf8))

        let confusableState = "st\u{0430}te"
        let confusable = """
        {"servers":[],"trashServers":[],"revision":0,"discoverySnapshots":{},"staleTempCleanupJournal":{"\(key)":{"consumedAt":0,"generation":1,"\(confusableState)":"prepared"}}}
        """
        try assertRejected(Data(confusable.utf8))

        var tooManyEntries: [String: Any] = [:]
        for index in 0..<65 {
            let suffix = String(index, radix: 16)
            let entryKey = String(repeating: "a", count: 64 - suffix.count) + suffix
            tooManyEntries[entryKey] = ["consumedAt": 0, "generation": 1, "state": "prepared"]
        }
        let boundedRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": tooManyEntries,
        ]
        try assertRejected(JSONSerialization.data(withJSONObject: boundedRoot, options: [.sortedKeys]))

        let oversizedRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [
                key: ["consumedAt": 0, "generation": 1, "state": String(repeating: "x", count: 300_000)],
            ],
        ]
        try assertRejected(JSONSerialization.data(withJSONObject: oversizedRoot, options: [.sortedKeys]))

        var deeplyNested: Any = NSNull()
        for _ in 0..<10 { deeplyNested = [deeplyNested] }
        let deepRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [
                key: ["consumedAt": 0, "generation": 1, "state": deeplyNested],
            ],
        ]
        try assertRejected(JSONSerialization.data(withJSONObject: deepRoot, options: [.sortedKeys]))
    }

    @Test func cleanupJournalFencesForksAndBoundsPreparedRecovery() throws {
        let (_, file) = try makeManager()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = ".\(file.lastPathComponent).tmp-"
        func ownedTempURL(payload: String) -> URL {
            directory.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)-\(DeletionGate.fingerprint(Data(payload.utf8)))"
            )
        }
        let temps = (0..<3).map { ownedTempURL(payload: "candidate-\($0)") }
        for (index, temp) in temps.enumerated() {
            try Data("candidate-\(index)".utf8).write(to: temp)
        }
        let initial = MCPServerManager(fileURL: file)
        let publishedReceipts = initial.staleTempCleanupReceipts()
        let initialReceipts = try temps.map { path in
            try #require(
                publishedReceipts.first {
                    URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                        == path.standardizedFileURL
                },
                "torn-temp-stages=\(initial.tornTempRecoveryDiagnosticStages()); counters=\(initial.tornTempRecoveryDiagnosticCounters()); \(tornTempReceiptDiagnostic(publishedReceipts, expectedURL: path))"
            )
        }
        let zeroDigest = String(repeating: "0", count: 64)
        let configFingerprint = MCPServerManager.cleanupConfigFingerprint(
            fileURL: file,
            authorizationFileURL: file.deletingLastPathComponent().appendingPathComponent("mcp-authorizations.json"),
            servers: [],
            authorizations: [:],
            revision: 0
        )
        var previousDigest = zeroDigest
        var history: [[String: Any]] = []
        var journal: [String: Any] = [:]
        for (index, receipt) in initialReceipts.enumerated() {
            let receiptID = MCPServerManager.receiptID(receipt)
            let digest = MCPServerManager.cleanupJournalRecordDigest(
                receiptID: receiptID,
                generation: UInt64(index + 1),
                previousDigest: previousDigest,
                state: "prepared",
                scope: receipt.targetPath,
                transactionUUID: receipt.transactionToken,
                preGeneration: UInt64(index),
                postGeneration: UInt64(index + 1),
                payloadDigest: receipt.payloadDigest,
                configFingerprint: configFingerprint,
                readbackIdentity: MCPServerManager.cleanupReadbackIdentity(
                    receiptID: receiptID,
                    scope: receipt.targetPath,
                    transactionUUID: receipt.transactionToken,
                    payloadDigest: receipt.payloadDigest,
                    directoryDevice: receipt.directoryDevice,
                    directoryInode: receipt.directoryInode,
                    temporaryDevice: receipt.temporaryDevice,
                    temporaryInode: receipt.temporaryInode,
                    present: true
                )
            )
            let entry: [String: Any] = [
                "consumedAt": 0,
                "digest": digest,
                "generation": index + 1,
                "previousDigest": previousDigest,
                "postGeneration": index + 1,
                "preGeneration": index,
                "scope": receipt.targetPath,
                "state": "prepared",
                "transactionUUID": receipt.transactionToken,
                "payloadDigest": receipt.payloadDigest,
                "configFingerprint": configFingerprint,
                "readbackIdentity": MCPServerManager.cleanupReadbackIdentity(
                    receiptID: receiptID,
                    scope: receipt.targetPath,
                    transactionUUID: receipt.transactionToken,
                    payloadDigest: receipt.payloadDigest,
                    directoryDevice: receipt.directoryDevice,
                    directoryInode: receipt.directoryInode,
                    temporaryDevice: receipt.temporaryDevice,
                    temporaryInode: receipt.temporaryInode,
                    present: true
                ),
            ]
            journal[receiptID] = entry
            history.append(["entry": entry, "receiptID": receiptID])
            previousDigest = digest
        }
        let root: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": journal,
            "staleTempCleanupJournalHistory": history,
        ]
        try canonicalJSONFixtureData(root).write(to: file)

        let bounded = MCPServerManager(fileURL: file)
        #expect(bounded.cleanupJournalLoadValidityDiagnosticStage() == "ready")
        let recovered = bounded.staleTempCleanupReceipts()
        #expect(
            recovered.count == 2,
            "cleanup-load-validity-stage=\(bounded.cleanupJournalLoadValidityDiagnosticStage())"
        )
        #expect(bounded.cleanupStaleTemp(receipt: initialReceipts[0]) == .rejected)
        let second = try #require(recovered.first { URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL == temps[1].standardizedFileURL })
        let third = try #require(recovered.first { URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL == temps[2].standardizedFileURL })
        try Data("tampered".utf8).write(to: temps[1])
        #expect(bounded.cleanupStaleTemp(receipt: second) == .rejected)
        try Data("candidate-1".utf8).write(to: temps[1])
        let restoredCleanupResult = bounded.cleanupStaleTemp(receipt: second)
        #expect(
            restoredCleanupResult == .removed,
            "cleanup-load-validity-stage=\(bounded.cleanupJournalLoadValidityDiagnosticStage()); cleanup-decision-stage=\(bounded.staleTempCleanupDecisionDiagnosticStage())"
        )
        try bounded.addServer(MCPServer(id: "config-change", name: "Config Change", type: .http, url: "https://example.invalid"))
        #expect(bounded.cleanupStaleTemp(receipt: third) == .rejected)
        #expect(FileManager.default.fileExists(atPath: temps[0].path))
        #expect(!FileManager.default.fileExists(atPath: temps[1].path))
        #expect(FileManager.default.fileExists(atPath: temps[2].path))

        let forkedID = MCPServerManager.receiptID(initialReceipts[0])
        let forkedEntry: [String: Any] = [
            "consumedAt": 0,
            "digest": String(repeating: "b", count: 64),
            "generation": 2,
            "previousDigest": zeroDigest,
            "postGeneration": 2,
            "preGeneration": 1,
            "scope": initialReceipts[0].targetPath,
            "state": "prepared",
            "transactionUUID": initialReceipts[0].transactionToken,
            "payloadDigest": initialReceipts[0].payloadDigest,
            "configFingerprint": configFingerprint,
            "readbackIdentity": String(repeating: "b", count: 64),
        ]
        let forkedRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [forkedID: forkedEntry],
            "staleTempCleanupJournalHistory": [["entry": forkedEntry, "receiptID": forkedID]],
        ]
        try canonicalJSONFixtureData(forkedRoot).write(to: file)
        let forked = MCPServerManager(fileURL: file)
        #expect(forked.cleanupJournalLoadValidityDiagnosticStage() != "documentStrictJSON")
        let forkedReceipt = try #require(forked.staleTempCleanupReceipts().first {
            URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                == temps[0].standardizedFileURL
        })
        #expect(forked.cleanupStaleTemp(receipt: forkedReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: temps[0].path))

        let scopedID = MCPServerManager.receiptID(initialReceipts[0])
        let foreignScope = "/foreign-mcp-scope"
        let scopedReadbackIdentity = MCPServerManager.cleanupReadbackIdentity(
            receiptID: scopedID,
            scope: foreignScope,
            transactionUUID: initialReceipts[0].transactionToken,
            payloadDigest: initialReceipts[0].payloadDigest,
            directoryDevice: initialReceipts[0].directoryDevice,
            directoryInode: initialReceipts[0].directoryInode,
            temporaryDevice: initialReceipts[0].temporaryDevice,
            temporaryInode: initialReceipts[0].temporaryInode,
            present: true
        )
        let scopedDigest = MCPServerManager.cleanupJournalRecordDigest(
            receiptID: scopedID,
            generation: 1,
            previousDigest: zeroDigest,
            state: "prepared",
            scope: foreignScope,
            transactionUUID: initialReceipts[0].transactionToken,
            preGeneration: 0,
            postGeneration: 1,
            payloadDigest: initialReceipts[0].payloadDigest,
            configFingerprint: configFingerprint,
            readbackIdentity: scopedReadbackIdentity
        )
        let scopedEntry: [String: Any] = [
            "consumedAt": 0,
            "digest": scopedDigest,
            "generation": 1,
            "previousDigest": zeroDigest,
            "postGeneration": 1,
            "preGeneration": 0,
            "scope": foreignScope,
            "state": "prepared",
            "transactionUUID": initialReceipts[0].transactionToken,
            "payloadDigest": initialReceipts[0].payloadDigest,
            "configFingerprint": configFingerprint,
            "readbackIdentity": scopedReadbackIdentity,
        ]
        let scopedRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [scopedID: scopedEntry],
            "staleTempCleanupJournalHistory": [["entry": scopedEntry, "receiptID": scopedID]],
        ]
        try canonicalJSONFixtureData(scopedRoot).write(to: file)
        let scoped = MCPServerManager(fileURL: file)
        #expect(scoped.cleanupJournalLoadValidityDiagnosticStage() != "documentStrictJSON")
        let scopedReceipt = try #require(scoped.staleTempCleanupReceipts().first {
            URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                == temps[0].standardizedFileURL
        })
        #expect(scoped.cleanupStaleTemp(receipt: scopedReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: temps[0].path))

        let duplicateID = MCPServerManager.receiptID(initialReceipts[0])
        let duplicateReadbackIdentity = MCPServerManager.cleanupReadbackIdentity(
            receiptID: duplicateID,
            scope: initialReceipts[0].targetPath,
            transactionUUID: initialReceipts[0].transactionToken,
            payloadDigest: initialReceipts[0].payloadDigest,
            directoryDevice: initialReceipts[0].directoryDevice,
            directoryInode: initialReceipts[0].directoryInode,
            temporaryDevice: initialReceipts[0].temporaryDevice,
            temporaryInode: initialReceipts[0].temporaryInode,
            present: true
        )
        let duplicateFirstDigest = MCPServerManager.cleanupJournalRecordDigest(
            receiptID: duplicateID,
            generation: 1,
            previousDigest: zeroDigest,
            state: "prepared",
            scope: initialReceipts[0].targetPath,
            transactionUUID: initialReceipts[0].transactionToken,
            preGeneration: 0,
            postGeneration: 1,
            payloadDigest: initialReceipts[0].payloadDigest,
            configFingerprint: configFingerprint,
            readbackIdentity: duplicateReadbackIdentity
        )
        let duplicateSecondDigest = MCPServerManager.cleanupJournalRecordDigest(
            receiptID: duplicateID,
            generation: 2,
            previousDigest: duplicateFirstDigest,
            state: "prepared",
            scope: initialReceipts[0].targetPath,
            transactionUUID: initialReceipts[0].transactionToken,
            preGeneration: 1,
            postGeneration: 2,
            payloadDigest: initialReceipts[0].payloadDigest,
            configFingerprint: configFingerprint,
            readbackIdentity: duplicateReadbackIdentity
        )
        func journalEntry(_ generation: Int, _ previous: String, _ digest: String) -> [String: Any] {
            [
                "consumedAt": 0,
                "digest": digest,
                "generation": generation,
                "previousDigest": previous,
                "postGeneration": generation,
                "preGeneration": generation - 1,
                "scope": initialReceipts[0].targetPath,
                "state": "prepared",
                "transactionUUID": initialReceipts[0].transactionToken,
                "payloadDigest": initialReceipts[0].payloadDigest,
                "configFingerprint": configFingerprint,
                "readbackIdentity": duplicateReadbackIdentity,
            ]
        }
        let duplicateFirst = journalEntry(1, zeroDigest, duplicateFirstDigest)
        let duplicateSecond = journalEntry(2, duplicateFirstDigest, duplicateSecondDigest)
        let duplicateRoot: [String: Any] = [
            "servers": [],
            "trashServers": [],
            "revision": 0,
            "discoverySnapshots": [:],
            "staleTempCleanupJournal": [duplicateID: duplicateSecond],
            "staleTempCleanupJournalHistory": [
                ["entry": duplicateFirst, "receiptID": duplicateID],
                ["entry": duplicateSecond, "receiptID": duplicateID],
            ],
        ]
        try canonicalJSONFixtureData(duplicateRoot).write(to: file)
        let duplicate = MCPServerManager(fileURL: file)
        #expect(duplicate.cleanupJournalLoadValidityDiagnosticStage() != "documentStrictJSON")
        let duplicateReceipt = try #require(duplicate.staleTempCleanupReceipts().first {
            URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                == temps[0].standardizedFileURL
        })
        #expect(duplicate.cleanupStaleTemp(receipt: duplicateReceipt) == .rejected)
        #expect(FileManager.default.fileExists(atPath: temps[0].path))
    }

    @Test func cleanupJournalAggregateRolloverKeepsChainAndReloadsIdempotently() throws {
        let directory = try makeTempDir("MCPCleanupJournalRollover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mcps.json")

        // Each cleanup contributes prepared+committed records. The 65th
        // transaction crosses the 128-record aggregate bound and must retain
        // a signed base predecessor instead of resetting the chain.
        for index in 0..<65 {
            let payload = "rollover-\(index)"
            let transaction = UUID().uuidString
            let digest = DeletionGate.fingerprint(Data(payload.utf8))
            let temporary = directory.appendingPathComponent(
                ".mcps.json.tmp-\(transaction)-\(digest)"
            )
            try Data(payload.utf8).write(to: temporary)

            let manager = MCPServerManager(fileURL: file)
            let publishedReceipts = manager.staleTempCleanupReceipts()
            let receipt = try #require(
                publishedReceipts.first {
                    URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                        == temporary.standardizedFileURL
                },
                "torn-temp-stages=\(manager.tornTempRecoveryDiagnosticStages()); counters=\(manager.tornTempRecoveryDiagnosticCounters()); \(tornTempReceiptDiagnostic(publishedReceipts, expectedURL: temporary))"
            )
            let cleanupResult = manager.cleanupStaleTemp(receipt: receipt)
            #expect(
                cleanupResult == .removed,
                "rollover-index=\(index); cleanup-load-validity-stage=\(manager.cleanupJournalLoadValidityDiagnosticStage()); cleanup-decision-stage=\(manager.staleTempCleanupDecisionDiagnosticStage())"
            )
        }

        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: []) as? [String: Any]
        )
        let baseGeneration = try #require(
            (root["staleTempCleanupJournalBaseGeneration"] as? NSNumber)?.uint64Value
        )
        let baseDigest = try #require(root["staleTempCleanupJournalBaseDigest"] as? String)
        #expect(baseGeneration > 0)
        #expect(baseDigest.count == 64)
        #expect(baseDigest != String(repeating: "0", count: 64))
        let checkpoint = try #require(root["staleTempCleanupJournalCheckpoint"] as? [String: Any])
        let checkpointEpoch = try #require(
            (checkpoint["epoch"] as? NSNumber)?.uint64Value
        )
        let checkpointReceiptID = try #require(checkpoint["receiptID"] as? String)
        let checkpointTransactionUUID = try #require(checkpoint["transactionUUID"] as? String)
        let checkpointGeneration = try #require(
            (checkpoint["generation"] as? NSNumber)?.uint64Value
        )
        let checkpointDigest = try #require(checkpoint["digest"] as? String)
        let checkpointSeal = try #require(checkpoint["checkpointDigest"] as? String)
        #expect(checkpointEpoch > 0)
        #expect(checkpointGeneration == baseGeneration)
        #expect(checkpointDigest == baseDigest)
        #expect(checkpointSeal == MCPServerManager.cleanupJournalCheckpointDigest(
            epoch: checkpointEpoch,
            receiptID: checkpointReceiptID,
            transactionUUID: checkpointTransactionUUID,
            generation: checkpointGeneration,
            digest: checkpointDigest
        ))
        let history = try #require(root["staleTempCleanupJournalHistory"] as? [[String: Any]])
        #expect(history.count < 128)
        #expect(history.count > 0)
        let segments = try #require(root["staleTempCleanupJournalSegments"] as? [[String: Any]])
        let manifestRoot = try #require(root["staleTempCleanupJournalManifestRoot"] as? String)
        let manifestEpoch = try #require(
            (root["staleTempCleanupJournalManifestEpoch"] as? NSNumber)?.uint64Value
        )
        let previousManifestRoot = try #require(
            root["staleTempCleanupJournalPreviousManifestRoot"] as? String
        )
        let tombstone = try #require(
            root["staleTempCleanupJournalManifestTombstone"] as? [String: Any]
        )
        let tombstoneEpoch = try #require(
            (tombstone["epoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneRoot = try #require(tombstone["root"] as? String)
        let successorEpoch = try #require(
            (tombstone["successorEpoch"] as? NSNumber)?.uint64Value
        )
        let successorRoot = try #require(tombstone["successorRoot"] as? String)
        let tombstoneCheckpointEpoch = try #require(
            (tombstone["checkpointEpoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneCheckpointDigest = try #require(
            tombstone["checkpointDigest"] as? String
        )
        let tombstoneHistory = try #require(
            root["staleTempCleanupJournalManifestTombstoneHistory"] as? [[String: Any]]
        )
        let tombstoneBase = try #require(
            root["staleTempCleanupJournalManifestTombstoneBase"] as? [String: Any]
        )
        let tombstoneBaseEpoch = try #require(
            (tombstoneBase["epoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneBaseCompactionEpoch = try #require(
            (tombstoneBase["compactionEpoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneBaseRoot = try #require(tombstoneBase["root"] as? String)
        let tombstoneBaseCheckpointEpoch = try #require(
            (tombstoneBase["checkpointEpoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneBaseCheckpointDigest = try #require(
            tombstoneBase["checkpointDigest"] as? String
        )
        let tombstoneBaseSuccessorEpoch = try #require(
            (tombstoneBase["successorEpoch"] as? NSNumber)?.uint64Value
        )
        let tombstoneBaseSuccessorRoot = try #require(
            tombstoneBase["successorRoot"] as? String
        )
        let lastHistoryEntry = try #require(history.last?["entry"] as? [String: Any])
        let lastHistoryGeneration = try #require(
            (lastHistoryEntry["generation"] as? NSNumber)?.uint64Value
        )
        #expect(manifestEpoch == lastHistoryGeneration)
        #expect(previousManifestRoot.count == 64)
        #expect(previousManifestRoot != String(repeating: "0", count: 64))
        #expect(tombstoneEpoch + 1 == manifestEpoch)
        #expect(tombstoneRoot == previousManifestRoot)
        #expect(successorEpoch == manifestEpoch)
        #expect(successorRoot == manifestRoot)
        #expect(tombstoneCheckpointEpoch == checkpointEpoch)
        #expect(tombstoneCheckpointDigest == checkpointSeal)
        #expect(tombstoneHistory.count == 8)
        #expect(tombstoneBaseEpoch == tombstoneEpoch - 7)
        #expect(tombstoneBaseCompactionEpoch == tombstoneBaseEpoch)
        #expect(tombstoneBaseRoot == (tombstoneHistory.first?["root"] as? String))
        #expect(tombstoneBaseCheckpointEpoch == checkpointEpoch)
        #expect(tombstoneBaseCheckpointDigest == checkpointSeal)
        #expect(tombstoneBaseSuccessorEpoch == manifestEpoch)
        #expect(tombstoneBaseSuccessorRoot == manifestRoot)
        for index in 1..<tombstoneHistory.count {
            let previous = tombstoneHistory[index - 1]
            let current = tombstoneHistory[index]
            #expect(
                (previous["successorEpoch"] as? NSNumber)?.uint64Value ==
                    (current["epoch"] as? NSNumber)?.uint64Value
            )
            #expect(previous["successorRoot"] as? String == current["root"] as? String)
        }
        #expect(segments.count == 3)
        #expect(manifestRoot.count == 64)
        for index in segments.indices {
            let predecessor = try #require(segments[index]["previousDigest"] as? String)
            let expectedPredecessor: String
            if index == 0 {
                expectedPredecessor = baseDigest
            } else {
                expectedPredecessor = try #require(segments[index - 1]["endDigest"] as? String)
            }
            #expect(predecessor == expectedPredecessor)
        }

        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.cleanupJournalLoadValidityDiagnosticStage() == "ready")
        #expect(reloaded.staleTempCleanupReceipts().isEmpty)
        #expect(reloaded.cleanupStaleTemp(receipt: MCPStaleTempCleanupReceipt(
            targetPath: file.path,
            temporaryPath: directory.appendingPathComponent("missing").path,
            transactionToken: UUID().uuidString,
            payloadDigest: String(repeating: "0", count: 64),
            directoryPath: directory.path,
            directoryDevice: 0,
            directoryInode: 0
        )) == .rejected)

        // A pre-manifest journal must migrate its complete bounded tombstone
        // window before the next append, rather than creating an undersized
        // successor that reload would reject.
        var legacyRoot = root
        [
            "staleTempCleanupJournalSegments",
            "staleTempCleanupJournalManifestRoot",
            "staleTempCleanupJournalManifestEpoch",
            "staleTempCleanupJournalPreviousManifestRoot",
            "staleTempCleanupJournalManifestTombstone",
            "staleTempCleanupJournalManifestTombstoneHistory",
            "staleTempCleanupJournalManifestTombstoneBase"
        ].forEach { legacyRoot.removeValue(forKey: $0) }
        try canonicalJSONFixtureData(legacyRoot).write(to: file)
        let legacyPayload = "legacy-manifest-migration"
        let legacyTransaction = UUID().uuidString
        let legacyPayloadDigest = DeletionGate.fingerprint(Data(legacyPayload.utf8))
        let legacyTemp = directory.appendingPathComponent(
            ".mcps.json.tmp-\(legacyTransaction)-\(legacyPayloadDigest)"
        )
        try Data(legacyPayload.utf8).write(to: legacyTemp)
        let legacyManager = MCPServerManager(fileURL: file)
        #expect(legacyManager.cleanupJournalLoadValidityDiagnosticStage() == "ready")
        let legacyReceipt = try #require(
            legacyManager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == legacyTemp.standardizedFileURL
            }
        )
        let legacyCleanupResult = legacyManager.cleanupStaleTemp(receipt: legacyReceipt)
        #expect(
            legacyCleanupResult == .removed,
            "cleanup-load-validity-stage=\(legacyManager.cleanupJournalLoadValidityDiagnosticStage()); cleanup-decision-stage=\(legacyManager.staleTempCleanupDecisionDiagnosticStage())"
        )
        let migratedRoot = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: []) as? [String: Any]
        )
        #expect((migratedRoot["staleTempCleanupJournalManifestTombstoneHistory"] as? [[String: Any]])?.count == 8)

        func writeManifestVariant(_ variant: [[String: Any]], payload: String) throws -> MCPStaleTempCleanupReceipt {
            let transaction = UUID().uuidString
            let payloadDigest = DeletionGate.fingerprint(Data(payload.utf8))
            let temporary = directory.appendingPathComponent(
                ".mcps.json.tmp-\(transaction)-\(payloadDigest)"
            )
            try Data(payload.utf8).write(to: temporary)
            var variantRoot = root
            variantRoot["staleTempCleanupJournalSegments"] = variant
            try canonicalJSONFixtureData(variantRoot).write(to: file)
            let manager = MCPServerManager(fileURL: file)
            return try #require(manager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == temporary.standardizedFileURL
            })
        }

        func writeManifestRootVariant(
            payload: String,
            mutate: (inout [String: Any]) -> Void
        ) throws -> MCPStaleTempCleanupReceipt {
            let transaction = UUID().uuidString
            let payloadDigest = DeletionGate.fingerprint(Data(payload.utf8))
            let temporary = directory.appendingPathComponent(
                ".mcps.json.tmp-\(transaction)-\(payloadDigest)"
            )
            try Data(payload.utf8).write(to: temporary)
            var variantRoot = root
            mutate(&variantRoot)
            try canonicalJSONFixtureData(variantRoot).write(to: file)
            let manager = MCPServerManager(fileURL: file)
            return try #require(manager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == temporary.standardizedFileURL
            })
        }

        var divergentPredecessor = segments
        divergentPredecessor[0]["previousDigest"] = String(repeating: "f", count: 64)
        let divergentPredecessorReceipt = try writeManifestVariant(
            divergentPredecessor,
            payload: "divergent-predecessor"
        )
        let divergentPredecessorManager = MCPServerManager(fileURL: file)
        let divergentPredecessorLoaded = try #require(
            divergentPredecessorManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == divergentPredecessorReceipt.temporaryPath
            }
        )
        #expect(divergentPredecessorManager.cleanupStaleTemp(receipt: divergentPredecessorLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: divergentPredecessorReceipt.temporaryPath))

        var replayedSegment = segments
        replayedSegment[2] = segments[0]
        let replayedSegmentReceipt = try writeManifestVariant(
            replayedSegment,
            payload: "replayed-segment"
        )
        let replayedSegmentManager = MCPServerManager(fileURL: file)
        let replayedSegmentLoaded = try #require(
            replayedSegmentManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == replayedSegmentReceipt.temporaryPath
            }
        )
        #expect(replayedSegmentManager.cleanupStaleTemp(receipt: replayedSegmentLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: replayedSegmentReceipt.temporaryPath))

        var replayedTombstoneHistory = tombstoneHistory
        replayedTombstoneHistory[7] = tombstoneHistory[0]
        let replayedTombstoneReceipt = try writeManifestRootVariant(
            payload: "replayed-tombstone-history"
        ) { variantRoot in
            variantRoot["staleTempCleanupJournalManifestTombstoneHistory"] = replayedTombstoneHistory
        }
        let replayedTombstoneManager = MCPServerManager(fileURL: file)
        let replayedTombstoneLoaded = try #require(
            replayedTombstoneManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == replayedTombstoneReceipt.temporaryPath
            }
        )
        #expect(replayedTombstoneManager.cleanupStaleTemp(receipt: replayedTombstoneLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: replayedTombstoneReceipt.temporaryPath))

        var truncatedTombstoneHistory = tombstoneHistory
        truncatedTombstoneHistory.removeFirst()
        let truncatedTombstoneReceipt = try writeManifestRootVariant(
            payload: "truncated-tombstone-history"
        ) { variantRoot in
            variantRoot["staleTempCleanupJournalManifestTombstoneHistory"] = truncatedTombstoneHistory
        }
        let truncatedTombstoneManager = MCPServerManager(fileURL: file)
        let truncatedTombstoneLoaded = try #require(
            truncatedTombstoneManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == truncatedTombstoneReceipt.temporaryPath
            }
        )
        #expect(truncatedTombstoneManager.cleanupStaleTemp(receipt: truncatedTombstoneLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: truncatedTombstoneReceipt.temporaryPath))

        let oversizedTombstoneReceipt = try writeManifestRootVariant(
            payload: "oversized-tombstone-history"
        ) { variantRoot in
            var oversizedHistory = variantRoot["staleTempCleanupJournalManifestTombstoneHistory"] as! [[String: Any]]
            oversizedHistory[0]["root"] = String(repeating: "a", count: 300_000)
            variantRoot["staleTempCleanupJournalManifestTombstoneHistory"] = oversizedHistory
        }
        let oversizedTombstoneManager = MCPServerManager(fileURL: file)
        let oversizedTombstoneLoaded = try #require(
            oversizedTombstoneManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == oversizedTombstoneReceipt.temporaryPath
            }
        )
        #expect(oversizedTombstoneManager.cleanupStaleTemp(receipt: oversizedTombstoneLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: oversizedTombstoneReceipt.temporaryPath))

        let tamperedHandoffReceipt = try writeManifestRootVariant(
            payload: "tampered-tombstone-handoff"
        ) { variantRoot in
            var tamperedBase = variantRoot["staleTempCleanupJournalManifestTombstoneBase"] as! [String: Any]
            tamperedBase["compactionEpoch"] = tombstoneBaseCompactionEpoch - 1
            variantRoot["staleTempCleanupJournalManifestTombstoneBase"] = tamperedBase
        }
        let tamperedHandoffManager = MCPServerManager(fileURL: file)
        let tamperedHandoffLoaded = try #require(
            tamperedHandoffManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == tamperedHandoffReceipt.temporaryPath
            }
        )
        #expect(tamperedHandoffManager.cleanupStaleTemp(receipt: tamperedHandoffLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: tamperedHandoffReceipt.temporaryPath))

        let resurrectedCompactedManifestReceipt = try writeManifestRootVariant(
            payload: "resurrected-compacted-manifest"
        ) { variantRoot in
            var tamperedBase = variantRoot["staleTempCleanupJournalManifestTombstoneBase"] as! [String: Any]
            tamperedBase["successorRoot"] = previousManifestRoot
            variantRoot["staleTempCleanupJournalManifestTombstoneBase"] = tamperedBase
        }
        let resurrectedCompactedManifestManager = MCPServerManager(fileURL: file)
        let resurrectedCompactedManifestLoaded = try #require(
            resurrectedCompactedManifestManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == resurrectedCompactedManifestReceipt.temporaryPath
            }
        )
        #expect(
            resurrectedCompactedManifestManager.cleanupStaleTemp(
                receipt: resurrectedCompactedManifestLoaded
            ) == .rejected
        )
        #expect(FileManager.default.fileExists(atPath: resurrectedCompactedManifestReceipt.temporaryPath))

        let tamperedTombstoneReceipt = try writeManifestRootVariant(
            payload: "tampered-tombstone"
        ) { variantRoot in
            var tampered = variantRoot["staleTempCleanupJournalManifestTombstone"] as! [String: Any]
            tampered["checkpointDigest"] = String(repeating: "f", count: 64)
            variantRoot["staleTempCleanupJournalManifestTombstone"] = tampered
        }
        let tamperedTombstoneManager = MCPServerManager(fileURL: file)
        let tamperedTombstoneLoaded = try #require(
            tamperedTombstoneManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == tamperedTombstoneReceipt.temporaryPath
            }
        )
        #expect(tamperedTombstoneManager.cleanupStaleTemp(receipt: tamperedTombstoneLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: tamperedTombstoneReceipt.temporaryPath))

        let missingTombstoneReceipt = try writeManifestRootVariant(
            payload: "missing-tombstone"
        ) { variantRoot in
            variantRoot.removeValue(forKey: "staleTempCleanupJournalManifestTombstone")
        }
        let missingTombstoneManager = MCPServerManager(fileURL: file)
        let missingTombstoneLoaded = try #require(
            missingTombstoneManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == missingTombstoneReceipt.temporaryPath
            }
        )
        #expect(missingTombstoneManager.cleanupStaleTemp(receipt: missingTombstoneLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: missingTombstoneReceipt.temporaryPath))

        let resurrectedManifestReceipt = try writeManifestRootVariant(
            payload: "resurrected-manifest"
        ) { variantRoot in
            variantRoot["staleTempCleanupJournalManifestEpoch"] = manifestEpoch - 1
        }
        let resurrectedManifestManager = MCPServerManager(fileURL: file)
        let resurrectedManifestLoaded = try #require(
            resurrectedManifestManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == resurrectedManifestReceipt.temporaryPath
            }
        )
        #expect(resurrectedManifestManager.cleanupStaleTemp(receipt: resurrectedManifestLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: resurrectedManifestReceipt.temporaryPath))

        let partialManifestReceipt = try writeManifestRootVariant(
            payload: "partial-manifest"
        ) { variantRoot in
            variantRoot.removeValue(forKey: "staleTempCleanupJournalManifestRoot")
        }
        let partialManifestManager = MCPServerManager(fileURL: file)
        let partialManifestLoaded = try #require(
            partialManifestManager.staleTempCleanupReceipts().first {
                $0.temporaryPath == partialManifestReceipt.temporaryPath
            }
        )
        #expect(partialManifestManager.cleanupStaleTemp(receipt: partialManifestLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: partialManifestReceipt.temporaryPath))

        let missingSegmentReceipt = try writeManifestVariant(Array(segments.dropLast()), payload: "missing-segment")
        let missingSegmentManager = MCPServerManager(fileURL: file)
        let missingSegmentLoaded = try #require(
            missingSegmentManager.staleTempCleanupReceipts().first { $0.temporaryPath == missingSegmentReceipt.temporaryPath }
        )
        #expect(missingSegmentManager.cleanupStaleTemp(receipt: missingSegmentLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: missingSegmentReceipt.temporaryPath))

        let lastSegment = try #require(segments.last)
        let firstSegment = try #require(segments.first)
        let extraSegmentReceipt = try writeManifestVariant(segments + [lastSegment], payload: "extra-segment")
        let extraSegmentManager = MCPServerManager(fileURL: file)
        let extraSegmentLoaded = try #require(
            extraSegmentManager.staleTempCleanupReceipts().first { $0.temporaryPath == extraSegmentReceipt.temporaryPath }
        )
        #expect(extraSegmentManager.cleanupStaleTemp(receipt: extraSegmentLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: extraSegmentReceipt.temporaryPath))

        let reorderedSegmentReceipt = try writeManifestVariant(Array(segments.reversed()), payload: "reordered-segment")
        let reorderedSegmentManager = MCPServerManager(fileURL: file)
        let reorderedSegmentLoaded = try #require(
            reorderedSegmentManager.staleTempCleanupReceipts().first { $0.temporaryPath == reorderedSegmentReceipt.temporaryPath }
        )
        #expect(reorderedSegmentManager.cleanupStaleTemp(receipt: reorderedSegmentLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: reorderedSegmentReceipt.temporaryPath))

        let overflowSegmentReceipt = try writeManifestVariant(
            Array(repeating: firstSegment, count: 9),
            payload: "overflow-segment"
        )
        let overflowSegmentManager = MCPServerManager(fileURL: file)
        let overflowSegmentLoaded = try #require(
            overflowSegmentManager.staleTempCleanupReceipts().first { $0.temporaryPath == overflowSegmentReceipt.temporaryPath }
        )
        #expect(overflowSegmentManager.cleanupStaleTemp(receipt: overflowSegmentLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: overflowSegmentReceipt.temporaryPath))

        // A durable prepared tail after compaction is a valid crash-recovery
        // state; it must reload only the matching candidate and continue the
        // same chain instead of resetting to the compacted base.
        let preparedPayload = "prepared-after-compaction"
        let preparedTransaction = UUID().uuidString
        let preparedPayloadDigest = DeletionGate.fingerprint(Data(preparedPayload.utf8))
        let preparedTemp = directory.appendingPathComponent(
            ".mcps.json.tmp-\(preparedTransaction)-\(preparedPayloadDigest)"
        )
        try Data(preparedPayload.utf8).write(to: preparedTemp)
        let crashManager = MCPServerManager(fileURL: file)
        let crashReceipt = try #require(
            crashManager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == preparedTemp.standardizedFileURL
            }
        )
        let crashReceiptID = MCPServerManager.receiptID(crashReceipt)
        let lastRecord = try #require(history.last)
        let lastEntry = try #require(lastRecord["entry"] as? [String: Any])
        let lastGeneration = try #require((lastEntry["generation"] as? NSNumber)?.uint64Value)
        let lastDigest = try #require(lastEntry["digest"] as? String)
        let preparedReadback = MCPServerManager.cleanupReadbackIdentity(
            receiptID: crashReceiptID,
            scope: crashReceipt.targetPath,
            transactionUUID: crashReceipt.transactionToken,
            payloadDigest: crashReceipt.payloadDigest,
            directoryDevice: crashReceipt.directoryDevice,
            directoryInode: crashReceipt.directoryInode,
            temporaryDevice: crashReceipt.temporaryDevice,
            temporaryInode: crashReceipt.temporaryInode,
            present: true
        )
        let preparedGeneration = lastGeneration + 1
        let preparedJournalDigest = MCPServerManager.cleanupJournalRecordDigest(
            receiptID: crashReceiptID,
            generation: preparedGeneration,
            previousDigest: lastDigest,
            state: "prepared",
            scope: crashReceipt.targetPath,
            transactionUUID: crashReceipt.transactionToken,
            preGeneration: lastGeneration,
            postGeneration: preparedGeneration,
            payloadDigest: crashReceipt.payloadDigest,
            configFingerprint: MCPServerManager.cleanupConfigFingerprint(
                fileURL: file,
                authorizationFileURL: file.deletingLastPathComponent().appendingPathComponent("mcp-authorizations.json"),
                servers: [],
                authorizations: [:],
                revision: 0
            ),
            readbackIdentity: preparedReadback
        )
        let preparedEntry: [String: Any] = [
            "consumedAt": 0,
            "digest": preparedJournalDigest,
            "generation": preparedGeneration,
            "previousDigest": lastDigest,
            "postGeneration": preparedGeneration,
            "preGeneration": lastGeneration,
            "scope": crashReceipt.targetPath,
            "state": "prepared",
            "transactionUUID": crashReceipt.transactionToken,
            "payloadDigest": crashReceipt.payloadDigest,
            "configFingerprint": MCPServerManager.cleanupConfigFingerprint(
                fileURL: file,
                authorizationFileURL: file.deletingLastPathComponent().appendingPathComponent("mcp-authorizations.json"),
                servers: [],
                authorizations: [:],
                revision: 0
            ),
            "readbackIdentity": preparedReadback,
        ]
        var preparedRoot = legacyRoot
        var preparedJournal = try #require(
            legacyRoot["staleTempCleanupJournal"] as? [String: Any]
        )
        preparedJournal[crashReceiptID] = preparedEntry
        var preparedHistory = history
        preparedHistory.append(["entry": preparedEntry, "receiptID": crashReceiptID])
        preparedRoot["staleTempCleanupJournal"] = preparedJournal
        preparedRoot["staleTempCleanupJournalHistory"] = preparedHistory
        try canonicalJSONFixtureData(preparedRoot).write(to: file)
        let recoveredPrepared = MCPServerManager(fileURL: file)
        #expect(recoveredPrepared.cleanupJournalLoadValidityDiagnosticStage() == "ready")
        let recoveredReceipt = try #require(
            recoveredPrepared.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == preparedTemp.standardizedFileURL
            }
        )
        #expect(recoveredPrepared.cleanupStaleTemp(receipt: recoveredReceipt) == .removed)

        func writeCheckpointVariant(_ variant: [String: Any], payload: String) throws -> MCPStaleTempCleanupReceipt {
            let transaction = UUID().uuidString
            let payloadDigest = DeletionGate.fingerprint(Data(payload.utf8))
            let temporary = directory.appendingPathComponent(
                ".mcps.json.tmp-\(transaction)-\(payloadDigest)"
            )
            try Data(payload.utf8).write(to: temporary)
            var variantRoot = root
            variantRoot["staleTempCleanupJournalCheckpoint"] = variant
            try canonicalJSONFixtureData(variantRoot).write(to: file)
            let manager = MCPServerManager(fileURL: file)
            return try #require(manager.staleTempCleanupReceipts().first {
                URL(fileURLWithPath: $0.temporaryPath).standardizedFileURL
                    == temporary.standardizedFileURL
            })
        }

        var staleEpochCheckpoint = checkpoint
        staleEpochCheckpoint["epoch"] = checkpointEpoch - 1
        let staleEpochReceipt = try writeCheckpointVariant(staleEpochCheckpoint, payload: "stale-epoch")
        let staleEpochManager = MCPServerManager(fileURL: file)
        let staleEpochLoaded = try #require(
            staleEpochManager.staleTempCleanupReceipts().first { $0.temporaryPath == staleEpochReceipt.temporaryPath }
        )
        #expect(staleEpochManager.cleanupStaleTemp(receipt: staleEpochLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: staleEpochReceipt.temporaryPath))

        var substitutedCheckpoint = checkpoint
        substitutedCheckpoint["receiptID"] = String(repeating: "f", count: 64)
        let substitutedReceipt = try writeCheckpointVariant(substitutedCheckpoint, payload: "substituted")
        let substitutedManager = MCPServerManager(fileURL: file)
        let substitutedLoaded = try #require(
            substitutedManager.staleTempCleanupReceipts().first { $0.temporaryPath == substitutedReceipt.temporaryPath }
        )
        #expect(substitutedManager.cleanupStaleTemp(receipt: substitutedLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: substitutedReceipt.temporaryPath))

        let firstTail = try #require(history.first?["entry"] as? [String: Any])
        let reusedUUID = try #require(firstTail["transactionUUID"] as? String)
        var reusedUUIDCheckpoint = checkpoint
        reusedUUIDCheckpoint["transactionUUID"] = reusedUUID
        reusedUUIDCheckpoint["checkpointDigest"] = MCPServerManager.cleanupJournalCheckpointDigest(
            epoch: checkpointEpoch,
            receiptID: checkpointReceiptID,
            transactionUUID: reusedUUID,
            generation: checkpointGeneration,
            digest: checkpointDigest
        )
        let reusedReceipt = try writeCheckpointVariant(reusedUUIDCheckpoint, payload: "reused-uuid")
        let reusedManager = MCPServerManager(fileURL: file)
        let reusedLoaded = try #require(
            reusedManager.staleTempCleanupReceipts().first { $0.temporaryPath == reusedReceipt.temporaryPath }
        )
        #expect(reusedManager.cleanupStaleTemp(receipt: reusedLoaded) == .rejected)
        #expect(FileManager.default.fileExists(atPath: reusedReceipt.temporaryPath))
    }

    @Test func discoveryCacheRejectsStaleCompletionAfterRevisionChange() async throws {
        let fixture = try writeDiscoveryServerScript()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "stale-cache",
            name: "Stale Cache",
            type: .stdio,
            command: "/bin/sh",
            args: [fixture.script.path],
            env: [
                "MCP_DISCOVERY_MARKER": fixture.marker.path,
                "MCP_DISCOVERY_DELAY": "1",
            ],
            timeoutSeconds: 2
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let pending = Task {
            try await manager.discoverTools(serverID: server.id)
        }
        try await waitForMarker(fixture.marker)

        var changedServer = server
        changedServer.timeoutSeconds = 3
        #expect(changedServer.descriptorFingerprint != server.descriptorFingerprint)
        try manager.updateServer(changedServer)

        do {
            _ = try await pending.value
            Issue.record("stale MCP discovery unexpectedly replaced the cache")
        } catch MCPDiscoveryError.stale(let serverID) {
            #expect(serverID == server.id)
        } catch {
            Issue.record("unexpected stale discovery error: \(error)")
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func lateDiscoveryAfterAuthorizationGenerationChangeCannotRepublishCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "authorization-stale-cache",
            name: "Authorization Stale Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    entered.signal()
                    await release.wait()
                }
                return MockMCPTransport.happyResponse(
                    for: request,
                    tools: [MCPTool(name: "greet")],
                    callText: "late"
                )
            })
        }

        let pending = Task {
            try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        await entered.wait()

        let capturedGeneration = manager.snapshot().revision
        try manager.revokeServer(id: server.id)
        try manager.authorizeServer(id: server.id)
        #expect(manager.snapshot().revision > capturedGeneration)
        release.signal()

        do {
            _ = try await pending.value
            Issue.record("late authorized MCP discovery unexpectedly republished a snapshot")
        } catch MCPDiscoveryError.stale(let serverID) {
            #expect(serverID == server.id)
        } catch {
            Issue.record("unexpected authorized stale discovery error: \(error)")
        }
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func paginatedDiscoveryAbortsBeforeNextPageAfterAuthorizationChange() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "authorization-paged-cache",
            name: "Authorization Paged Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let firstPageEntered = MCPAsyncSignal()
        let releaseFirstPage = MCPAsyncSignal()
        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    pageCount.value += 1
                    if pageCount.value == 1 {
                        firstPageEntered.signal()
                        await releaseFirstPage.wait()
                    }
                    var result: [String: MCPJSONValue] = [
                        "tools": .array([.object(["name": .string("page-\(pageCount.value)")])])
                    ]
                    if pageCount.value == 1 {
                        result["nextCursor"] = .string("page-2")
                    }
                    return MCPJSONRPCResponse(id: request.id, result: .object(result))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        let pending = Task {
            try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        await firstPageEntered.wait()
        try manager.revokeServer(id: server.id)
        try manager.authorizeServer(id: server.id)
        releaseFirstPage.signal()

        do {
            _ = try await pending.value
            Issue.record("paginated discovery crossed authorization generation")
        } catch MCPDiscoveryError.stale(let serverID) {
            #expect(serverID == server.id)
        } catch {
            Issue.record("unexpected paginated discovery error: \(error)")
        }
        #expect(pageCount.value == 1)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func paginatedDiscoverySortsCompletePagesBeforePublishing() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "paged-order-cache",
            name: "Paged Order Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                guard request.method == "tools/list" else {
                    return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
                }
                pageCount.value += 1
                var result: [String: MCPJSONValue] = [
                    "tools": .array([
                        .object(["name": .string(pageCount.value == 1 ? "zeta" : "alpha")])
                    ])
                ]
                if pageCount.value == 1 {
                    result["nextCursor"] = .string("page-2")
                }
                return MCPJSONRPCResponse(id: request.id, result: .object(result))
            })
        }

        let tools = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(tools.map(\.name) == ["alpha", "zeta"])
        #expect(manager.cachedTools(serverID: server.id).map(\.name) == ["alpha", "zeta"])
        #expect(pageCount.value == 2)
    }

    @Test func discoveryRejectsFactoryServerIdentityMismatchWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "identity-mismatch",
            name: "Identity Mismatch",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let factory: @Sendable (MCPServer) -> MCPClient = { _ in
            MCPClient(
                server: MCPServer(
                    id: "other-server",
                    name: "Other Server",
                    type: .http,
                    url: "http://127.0.0.1:2"
                ),
                transport: MockMCPTransport.happy()
            )
        }

        await #expect(throws: MCPDiscoveryError.serverIdentityChanged(server.id)) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func discoveryRejectsLatePageAfterSameDescriptorReconnectWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "transport-epoch-discovery",
            name: "Transport Epoch Discovery",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let clientBox = MCPClientBox()
        let firstPageEntered = MCPAsyncSignal()
        let releaseFirstPage = MCPAsyncSignal()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            let client = MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    firstPageEntered.signal()
                    await releaseFirstPage.wait()
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([.object(["name": .string("late")])]),
                        "nextCursor": .string("page-2"),
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
            clientBox.store(client)
            return client
        }

        let pending = Task {
            try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        await firstPageEntered.wait()
        let client = try #require(clientBox.value)
        client.disconnect()
        try await client.reconnect()
        releaseFirstPage.signal()

        await #expect(throws: MCPClientError.processExited(-1)) {
            _ = try await pending.value
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
        client.disconnect()
    }

    @Test func paginatedDiscoveryRejectsAggregateToolLimitWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "tool-limit-cache",
            name: "Tool Limit Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let rawTools = (0..<10_240).map { index in
            MCPJSONValue.object(["name": .string("tool-\(index)")])
        }
        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    pageCount.value += 1
                    let page = pageCount.value
                    let start = (page - 1) * 2_048
                    let pageTools = Array(rawTools[start..<(start + 2_048)])
                    var result: [String: MCPJSONValue] = ["tools": .array(pageTools)]
                    if page < 5 {
                        result["nextCursor"] = .string("page-\(page + 1)")
                    }
                    return MCPJSONRPCResponse(id: request.id, result: .object(result))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPDiscoveryError.limitsExceeded(server.id)) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(pageCount.value == 5)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func paginatedDiscoveryAcceptsPerPageToolBoundary() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "page-tool-boundary", name: "Page Tool Boundary", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let rawTools = (0..<2_048).map { index in
            MCPJSONValue.object(["name": .string("boundary-\(index)")])
        }
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    return MCPJSONRPCResponse(id: request.id, result: .object(["tools": .array(rawTools)]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        let tools = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(tools.count == 2_048)
        #expect(manager.cachedTools(serverID: server.id).count == 2_048)
    }

    @Test func paginatedDiscoveryRejectsOversizedSerializedSchemaWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-limit-cache", name: "Schema Limit Cache", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let oversizedDescription = String(repeating: "x", count: 512 * 1024)
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([.object([
                            "name": .string("oversized"),
                            "inputSchema": .object(["description": .string(oversizedDescription)]),
                        ])])
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPClientError.badResponse("tools/list page exceeded schema byte limit")) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func malformedNextCursorRejectsWholeDiscoveryWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "malformed-cursor-cache",
            name: "Malformed Cursor Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([.object(["name": .string("greet")])]),
                        "nextCursor": .number(1),
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPClientError.badResponse("tools/list result has invalid 'nextCursor'")) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func repeatedCursorRejectsWholeDiscoveryWithoutCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "repeated-cursor-cache",
            name: "Repeated Cursor Cache",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    pageCount.value += 1
                    let nextCursor: String
                    switch pageCount.value {
                    case 1: nextCursor = "cursor-a"
                    case 2: nextCursor = "cursor-b"
                    default: nextCursor = "cursor-a"
                    }
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([.object(["name": .string("greet")])]),
                        "nextCursor": .string(nextCursor),
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPDiscoveryError.repeatedCursor(serverID: server.id, cursor: "cursor-a")) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(pageCount.value == 3)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func excessiveDiscoveryPageCountFailsTypedAndLeavesNoCache() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "page-limit-cache", name: "Page Limit Cache", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let pageCount = Counter()
        let factory: @Sendable (MCPServer) -> MCPClient = { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    pageCount.value += 1
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([]),
                        "nextCursor": .string("page-\(pageCount.value + 1)"),
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
            })
        }

        await #expect(throws: MCPDiscoveryError.pageLimitExceeded(server.id)) {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        }
        #expect(pageCount.value == 1_024)
        #expect(manager.cachedTools(serverID: server.id).isEmpty)
    }

    @Test func cancelledDiscoveryCannotPublishAuthoritativeSnapshot() async throws {
        let fixture = try writeDiscoveryServerScript()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let (manager, _) = try makeManager()
        let server = MCPServer(
            id: "cancelled-cache",
            name: "Cancelled Cache",
            type: .stdio,
            command: "/bin/sh",
            args: [fixture.script.path],
            env: [
                "MCP_DISCOVERY_MARKER": fixture.marker.path,
                "MCP_DISCOVERY_DELAY": "1",
            ],
            timeoutSeconds: 2
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)

        let pending = Task {
            try await manager.discoverTools(serverID: server.id)
        }
        try await waitForMarker(fixture.marker)
        pending.cancel()

        do {
            _ = try await pending.value
            Issue.record("cancelled MCP discovery unexpectedly published a snapshot")
        } catch is CancellationError {
            // Expected: cancellation is checked before cache publication.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)
    }

    @Test func crudAndPersistenceRoundTrip() throws {
        let (manager, file) = try makeManager()
        #expect(manager.listServers().isEmpty)

        try manager.addServer(sampleServers[0])
        try manager.addServer(sampleServers[1])
        #expect(manager.listServers().count == 2)
        #expect(manager.server(id: "github")?.transportSummary == "https://api.githubcopilot.com/mcp/")
        #expect(manager.server(id: "filesystem")?.transportSummary == "npx -y @modelcontextprotocol/server-filesystem")

        // 更新（同 id 覆盖）并 enable。
        var updated = sampleServers[1]
        updated.enabled = true
        try manager.updateServer(updated)
        #expect(manager.server(id: "filesystem")?.enabled == true)

        // 持久化往返：新 manager 实例读同一文件。
        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.listServers().count == 2)
        #expect(reloaded.server(id: "github") == sampleServers[0])
        #expect(reloaded.server(id: "filesystem")?.enabled == true)
        #expect(reloaded.server(id: "filesystem")?.env["PATH"] == "/usr/bin")

        // 删除必须经过 intent + 双确认。
        let deletion = try reloaded.deletionIntent(id: "github")
            .withFirstConfirmation("I reviewed this exact MCP server")
            .withSecondConfirmation("I confirm moving this MCP server to trash")
        let receipt = try reloaded.deleteServer(deletion)
        #expect(receipt.targetID == "github")
        #expect(reloaded.listServers().map(\.id) == ["filesystem"])
        let final = MCPServerManager(fileURL: file)
        #expect(final.listServers().map(\.id) == ["filesystem"])
        #expect(final.trashedServers().map(\.id) == ["github"])
    }

    @Test func enableServerTogglesAndPersists() throws {
        let (manager, file) = try makeManager()
        try manager.addServer(sampleServers[1])
        let enabled = try manager.enableServer(id: "filesystem", enabled: true)
        #expect(enabled?.enabled == true)
        #expect(manager.enabledServers().map(\.id) == ["filesystem"])
        try manager.enableServer(id: "filesystem", enabled: false)
        #expect(manager.enabledServers().isEmpty)
        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.enabledServers().isEmpty)
    }

    @Test func exportMCPJSONMatchesClaudeDesktopShape() throws {
        let (manager, _) = try makeManager()
        try manager.addServer(sampleServers[0])
        let json = try #require(manager.exportMCPJSON(server: sampleServers[0]))
        let data = try #require(json.data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["github"] != nil)
    }

    @Test func malformedEntryDoesNotBlankList() throws {
        let (manager, file) = try makeManager()
        try manager.addServer(sampleServers[0])
        // 写一个含坏条目的文件：bad 条目的 args 是字符串（非法类型）。
        let bad = """
        {"servers":[{"id":"good","name":"Good","type":"http","enabled":true,"url":"https://x","args":[],"env":{},"headers":{},"timeoutSeconds":60},{"id":"bad","name":"Bad","type":"stdio","enabled":true,"command":"npx","args":"oops","env":{},"headers":{},"timeoutSeconds":60}]}
        """
        try bad.write(to: file, atomically: true, encoding: .utf8)
        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.listServers().map(\.id) == ["good"])
    }
}

// MARK: - Deletion safety seam

struct MCPServerDeletionSafetyTests {

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("I reviewed this exact MCP server")
            .withSecondConfirmation("I confirm moving this MCP server to trash")
    }

    private func copy(_ intent: OperationIntent, fingerprint: String? = nil, expiresAt: Date? = nil) -> OperationIntent {
        OperationIntent(
            operationID: intent.operationID,
            operationType: intent.operationType,
            targetID: intent.targetID,
            targetType: intent.targetType,
            targetName: intent.targetName,
            affectedCount: intent.affectedCount,
            impactSummary: intent.impactSummary,
            reversible: intent.reversible,
            scopeID: intent.scopeID,
            revision: intent.revision,
            fingerprint: fingerprint ?? intent.fingerprint,
            firstConfirmation: intent.firstConfirmation,
            secondConfirmation: intent.secondConfirmation,
            expiresAt: expiresAt ?? intent.expiresAt
        )
    }

    @Test func legacyRemoveServerFailsClosedWithoutMutation() throws {
        let (manager, _) = try makeManager()
        try manager.addServer(sampleServers[0])

        #expect(throws: MCPServerDeletionError.legacyEntryDisabled) {
            _ = try manager.removeServer(id: sampleServers[0].id)
        }
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])
        #expect(manager.trashedServers().isEmpty)
    }

    @Test func deletionRequiresBothConfirmationsAndThenMovesToTrash() throws {
        let (manager, file) = try makeManager()
        try manager.addServer(sampleServers[0])
        let intent = try manager.deletionIntent(id: sampleServers[0].id)

        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try manager.deleteServer(intent)
        }
        #expect(throws: DeletionGateError.secondConfirmationRequired) {
            try manager.deleteServer(intent.withFirstConfirmation("reviewed"))
        }
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])

        let receipt = try manager.deleteServer(confirmed(intent))
        #expect(receipt.targetID == sampleServers[0].id)
        #expect(manager.server(id: sampleServers[0].id) == nil)
        #expect(manager.trashedServers() == [sampleServers[0]])

        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.server(id: sampleServers[0].id) == nil)
        #expect(reloaded.trashedServers() == [sampleServers[0]])
    }

    @Test func cancelledExpiredAndReplayedIntentsCannotMutate() throws {
        let (manager, _) = try makeManager()
        try manager.addServer(sampleServers[0])

        let cancelled = try manager.deletionIntent(id: sampleServers[0].id)
        try DeletionGate.cancel(cancelled)
        #expect(throws: DeletionGateError.cancelled) {
            try manager.deleteServer(confirmed(cancelled))
        }
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])

        let expired = try manager.deletionIntent(id: sampleServers[0].id)
        let expiredAt = Date(timeIntervalSince1970: 0)
        #expect(throws: DeletionGateError.expired) {
            try manager.deleteServer(confirmed(copy(expired, expiresAt: expiredAt)))
        }
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])

        let replay = try manager.deletionIntent(id: sampleServers[0].id)
        _ = try manager.deleteServer(confirmed(replay))
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try manager.deleteServer(confirmed(replay))
        }
        #expect(manager.server(id: sampleServers[0].id) == nil)
    }

    @Test func revisionAndFingerprintMismatchCannotDelete() throws {
        let (manager, _) = try makeManager()
        try manager.addServer(sampleServers[0])

        let stale = try manager.deletionIntent(id: sampleServers[0].id)
        var updated = sampleServers[0]
        updated.name = "Renamed GitHub"
        try manager.updateServer(updated)
        #expect(throws: DeletionGateError.targetChanged) {
            try manager.deleteServer(confirmed(stale))
        }
        #expect(manager.server(id: sampleServers[0].id) == updated)

        let current = try manager.deletionIntent(id: sampleServers[0].id)
        #expect(throws: DeletionGateError.targetChanged) {
            try manager.deleteServer(confirmed(copy(current, fingerprint: "tampered")))
        }
        #expect(manager.server(id: sampleServers[0].id) == updated)
    }

    @Test func persistenceFailureRollsBackDeletionAndAllowsRetry() throws {
        let (manager, file) = try makeManager()
        try manager.addServer(sampleServers[0])
        let intent = try manager.deletionIntent(id: sampleServers[0].id)
        let committedConfig = try Data(contentsOf: file)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do {
            _ = try manager.deleteServer(confirmed(intent))
            Issue.record("expected persistence failure")
        } catch {
            // The failed save must leave the active registry untouched.
        }
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])
        #expect(manager.trashedServers().isEmpty)

        try FileManager.default.removeItem(at: file)
        // Repair the injected filesystem fault by restoring the exact committed
        // pair member. A missing config is a different snapshot, not a retry.
        try committedConfig.write(to: file, options: .atomic)
        try manager.save()
        _ = try manager.deleteServer(confirmed(intent))
        #expect(manager.server(id: sampleServers[0].id) == nil)
        #expect(manager.trashedServers() == [sampleServers[0]])
    }

    @Test func restoreReturnsGateDeletedServer() throws {
        let (manager, _) = try makeManager()
        try manager.addServer(sampleServers[0])
        let intent = try manager.deletionIntent(id: sampleServers[0].id)
        _ = try manager.deleteServer(confirmed(intent))

        let restored = try manager.restoreServer(id: sampleServers[0].id)
        #expect(restored == sampleServers[0])
        #expect(manager.server(id: sampleServers[0].id) == sampleServers[0])
        #expect(manager.trashedServers().isEmpty)
    }
}

// MARK: - MCPClient（mock transport）

struct MCPClientMockTests {

    @Test func mismatchedResponseIDIsRejected() async throws {
        let transport = MockMCPTransport { request in
            let response = MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-publish")
            guard request.method == "tools/call" else { return response }
            return MCPJSONRPCResponse(
                id: .int(999),
                result: response.result,
                error: response.error
            )
        }
        let client = MCPClient(
            server: MCPServer(id: "id-fence", name: "ID Fence", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("JSON-RPC response id mismatch")) {
            _ = try await client.callTool(name: "greet", arguments: nil)
        }
        client.disconnect()
    }

    @Test func cancelledCallRejectsLateResponseAfterTaskCancellation() async throws {
        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let transport = MockMCPTransport { request in
            if request.method == "tools/call" {
                entered.signal()
                await release.wait()
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "late-result")
        }
        let client = MCPClient(
            server: MCPServer(id: "cancel-fence", name: "Cancel Fence", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        let pending = Task {
            try await client.callTool(name: "greet", arguments: nil)
        }
        await entered.wait()
        pending.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) {
            _ = try await pending.value
        }
        client.disconnect()
    }

    @Test func concurrentConnectCallersShareOneHandshakeAndTerminalState() async throws {
        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let transport = BlockingStartMCPTransport(entered: entered, release: release)
        let client = MCPClient(
            server: MCPServer(id: "single-flight", name: "Single Flight", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        let first = Task { try await client.connect() }
        await entered.wait()
        let second = Task { try await client.connect() }
        try await Task.sleep(nanoseconds: 20_000_000)
        release.signal()

        try await first.value
        try await second.value
        #expect(client.connectionState == .connected)
        client.disconnect()
        #expect(client.connectionState == .disconnected)
    }

    @Test func failedInitializedNotificationDoesNotPublishConnectedState() async throws {
        let stopCount = Counter()
        let client = MCPClient(
            server: MCPServer(id: "notify-failure", name: "Notify Failure", type: .http, url: "http://127.0.0.1:1"),
            transport: FailingInitializedNotificationMCPTransport(stopCount: stopCount)
        )

        await #expect(throws: MCPClientError.spawnFailed("initialized notification write failed")) {
            try await client.connect()
        }
        #expect(!client.isConnected)
        #expect(client.connectionState != .connected)
        #expect(stopCount.value == 1)
    }

    @Test func invalidTimeoutIsRejectedBeforeMCPDispatch() async throws {
        let requests = Counter()
        let client = MCPClient(
            server: MCPServer(
                id: "invalid-timeout",
                name: "Invalid Timeout",
                type: .http,
                url: "http://127.0.0.1:1",
                timeoutSeconds: 0
            ),
            transport: MockMCPTransport { request in
                requests.value += 1
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "unexpected")
            }
        )

        await #expect(throws: MCPClientError.invalidServer("timeoutSeconds must be between 1 and 86400")) {
            try await client.connect()
        }
        #expect(requests.value == 0)
        #expect(client.connectionState != .connected)

        for timeout in [0, -1, Int.max] {
            let transport = MCPStdioTransport(
                command: "/bin/false",
                args: [],
                env: [:],
                timeoutSeconds: timeout
            )
            await #expect(throws: MCPClientError.invalidServer("timeoutSeconds must be between 1 and 86400")) {
                try await transport.start()
            }
        }
    }

    @Test func httpTransportRejectsNonHTTPURLBeforeDispatch() async throws {
        let invalidURLs = [
            URL(fileURLWithPath: "/tmp/mcp"),
            try #require(URL(string: "ftp://example.test/mcp")),
            try #require(URL(string: "http:///missing-host"))
        ]
        let request = MCPJSONRPCRequest(id: .int(1), method: "tools/list")
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)

        for url in invalidURLs {
            let transport = MCPHTTPTransport(url: url, headers: [:], timeoutSeconds: 1)
            await #expect(throws: MCPClientError.invalidServer("http transport requires an http(s) URL")) {
                try await transport.start()
            }
            await #expect(throws: MCPClientError.invalidServer("http transport requires an http(s) URL")) {
                _ = try await transport.send(request)
            }
            #expect(throws: MCPClientError.invalidServer("http transport requires an http(s) URL")) {
                try transport.notify(notification)
            }
        }
    }

    @Test func httpTransportRejectsUnsafeHeadersBeforeDispatch() async throws {
        let invalidHeaders = [
            ["X-Test": "ok\r\nInjected: yes"],
            ["Bad Header": "value"],
            ["": "value"]
        ]
        let url = try #require(URL(string: "https://example.test/mcp"))
        let request = MCPJSONRPCRequest(id: .int(1), method: "tools/list")
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)

        for headers in invalidHeaders {
            let transport = MCPHTTPTransport(url: url, headers: headers, timeoutSeconds: 1)
            await #expect(throws: MCPClientError.invalidServer("http transport contains invalid headers")) {
                try await transport.start()
            }
            await #expect(throws: MCPClientError.invalidServer("http transport contains invalid headers")) {
                _ = try await transport.send(request)
            }
            #expect(throws: MCPClientError.invalidServer("http transport contains invalid headers")) {
                try transport.notify(notification)
            }
        }
    }

    @Test func httpTransportRejectsURLCredentialsBeforeDispatch() async throws {
        let url = try #require(URL(string: "https://user:password@example.test/mcp"))
        let request = MCPJSONRPCRequest(id: .int(1), method: "tools/list")
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)
        let expected = MCPClientError.invalidServer("http transport URL must not contain credentials")
        let transport = MCPHTTPTransport(url: url, headers: [:], timeoutSeconds: 1)

        await #expect(throws: expected) {
            try await transport.start()
        }
        await #expect(throws: expected) {
            _ = try await transport.send(request)
        }
        #expect(throws: expected) {
            try transport.notify(notification)
        }
    }

    @Test func httpTransportRejectsURLFragmentsBeforeDispatch() async throws {
        let url = try #require(URL(string: "https://example.test/mcp#ignored"))
        let request = MCPJSONRPCRequest(id: .int(1), method: "tools/list")
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: nil)
        let expected = MCPClientError.invalidServer("http transport URL must not contain a fragment")
        let transport = MCPHTTPTransport(url: url, headers: [:], timeoutSeconds: 1)

        await #expect(throws: expected) {
            try await transport.start()
        }
        await #expect(throws: expected) {
            _ = try await transport.send(request)
        }
        #expect(throws: expected) {
            try transport.notify(notification)
        }
    }

    @Test func listToolsRejectsPageAfterTransportReconnect() async throws {
        let transport = ReconnectingPaginationMCPTransport()
        let client = MCPClient(
            server: MCPServer(id: "reconnect-pages", name: "Reconnect Pages", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/list pagination changed transport generation")) {
            _ = try await client.listTools()
        }
        #expect(transport.pagesServed == 2)
        #expect(client.connectionState != .connected)
        client.disconnect()
    }

    @Test func listToolsRejectsOversizedCursorBeforeDispatch() async throws {
        let requests = Counter()
        let client = MCPClient(
            server: MCPServer(id: "cursor-limit", name: "Cursor Limit", type: .http, url: "http://127.0.0.1:1"),
            transport: MockMCPTransport { request in
                requests.value += 1
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "unexpected")
            }
        )
        let cursor = String(repeating: "x", count: 64 * 1024 + 1)

        await #expect(throws: MCPClientError.badResponse("tools/list cursor exceeded byte limit")) {
            _ = try await client.listToolsPage(cursor: cursor)
        }
        #expect(requests.value == 0)

        let boundaryClient = MCPClient(
            server: MCPServer(id: "cursor-boundary", name: "Cursor Boundary", type: .http, url: "http://127.0.0.1:1"),
            transport: MockMCPTransport { request in
                requests.value += 1
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "unexpected")
            }
        )
        let boundary = try await boundaryClient.listToolsPage(
            cursor: String(repeating: "x", count: 64 * 1024)
        )
        #expect(boundary.tools.isEmpty)
        #expect(requests.value == 2)
        boundaryClient.disconnect()
    }

    @Test func listToolsRejectsOversizedNextCursorWithoutReturningPage() async throws {
        let oversized = String(repeating: "x", count: 64 * 1024 + 1)
        let client = MCPClient(
            server: MCPServer(id: "next-cursor-limit", name: "Next Cursor Limit", type: .http, url: "http://127.0.0.1:1"),
            transport: MockMCPTransport { request in
                if request.method == "tools/list" {
                    return MCPJSONRPCResponse(id: request.id, result: .object([
                        "tools": .array([]),
                        "nextCursor": .string(oversized)
                    ]))
                }
                return MockMCPTransport.happyResponse(for: request, tools: [], callText: "unexpected")
            }
        )

        await #expect(throws: MCPClientError.badResponse("tools/list result has invalid 'nextCursor'")) {
            _ = try await client.listToolsPage()
        }
    }

    @Test func transportsRejectOversizedOutboundPayloadBeforeDispatch() async throws {
        let payload = MCPJSONValue.string(String(repeating: "x", count: 1_048_600))
        let request = MCPJSONRPCRequest(
            id: .int(1),
            method: "tools/call",
            params: .object(["payload": payload])
        )
        let notification = MCPJSONRPCNotification(method: "notifications/initialized", params: .object(["payload": payload]))
        let expected = MCPClientError.invalidMessage("MCP outbound payload exceeds byte limit")

        let stdio = MCPStdioTransport(command: "/bin/false", args: [], env: [:], timeoutSeconds: 1)
        await #expect(throws: expected) {
            _ = try await stdio.send(request)
        }
        #expect(throws: expected) {
            try stdio.notify(notification)
        }

        let url = try #require(URL(string: "https://example.test/mcp"))
        let http = MCPHTTPTransport(url: url, headers: [:], timeoutSeconds: 1)
        await #expect(throws: expected) {
            _ = try await http.send(request)
        }
        #expect(throws: expected) {
            try http.notify(notification)
        }
    }

    @Test func httpTransportRejectsOversizedHeadersBeforeDispatch() async throws {
        let url = try #require(URL(string: "https://example.test/mcp"))
        let oversizedValue = ["X-Test": String(repeating: "x", count: 8 * 1024 + 1)]
        let tooManyHeaders = Dictionary(uniqueKeysWithValues: (0..<65).map { ("X-\($0)", "value") })
        let expectedErrors = [
            (oversizedValue, MCPClientError.invalidServer("http transport headers exceed byte limit")),
            (tooManyHeaders, MCPClientError.invalidServer("http transport headers exceed count limit"))
        ]

        for (headers, expected) in expectedErrors {
            let transport = MCPHTTPTransport(url: url, headers: headers, timeoutSeconds: 1)
            await #expect(throws: expected) {
                try await transport.start()
            }
        }
    }

    @Test func initializeHandshakeThenListTools() async throws {
        let tools = [
            MCPTool(name: "greet", description: "Greet someone",
                    inputSchema: .object(["type": .string("object"),
                                          "properties": .object(["name": .object(["type": .string("string")])])])),
            MCPTool(name: "add", description: "Add numbers"),
        ]
        let server = MCPServer(id: "mock", name: "Mock", type: .http, url: "http://127.0.0.1:1", timeoutSeconds: 5)
        let client = MCPClient(server: server, transport: MockMCPTransport.happy(tools: tools))

        #expect(!client.isConnected)
        let listed = try await client.listTools() // connect() runs inside
        #expect(client.isConnected)
        #expect(listed.count == 2)
        #expect(listed.map(\.name) == ["greet", "add"])
        #expect(listed[0].description == "Greet someone")
        let schema = try #require(listed[0].inputSchemaObject)
        #expect(schema["type"] as? String == "object")

        client.disconnect()
        #expect(!client.isConnected)
    }

    @Test func listToolsFollowsCursorPagesAndCarriesCursorForward() async throws {
        let pageCount = Counter()
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                pageCount.value += 1
                if pageCount.value == 2 {
                    guard request.params == .object(["cursor": .string("page-2")]) else {
                        return MCPJSONRPCResponse(
                            id: request.id,
                            error: MCPJSONRPCError(code: -32602, message: "missing cursor")
                        )
                    }
                }
                var result: [String: MCPJSONValue] = [
                    "tools": .array([.object(["name": .string(pageCount.value == 1 ? "first" : "second")])])
                ]
                if pageCount.value == 1 {
                    result["nextCursor"] = .string("page-2")
                }
                return MCPJSONRPCResponse(id: request.id, result: .object(result))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "paged", name: "Paged", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        let listed = try await client.listTools()
        #expect(listed.map(\.name) == ["first", "second"])
        #expect(pageCount.value == 2)
        client.disconnect()
    }

    @Test func listToolsPageBindsServerIdentityAndTransportEpoch() async throws {
        let server = MCPServer(
            id: "page-identity",
            name: "Page Identity",
            type: .http,
            url: "http://127.0.0.1:1"
        )
        let client = MCPClient(server: server, transport: MockMCPTransport.happy())

        let first = try await client.listToolsPage()
        #expect(first.serverIdentity == "\(server.id):\(server.descriptorFingerprint)")
        #expect(first.transportGeneration == client.lifecycleSnapshot.generation)

        client.disconnect()
        let second = try await client.listToolsPage()
        #expect(second.serverIdentity == first.serverIdentity)
        #expect(second.transportGeneration != first.transportGeneration)
        client.disconnect()
    }

    @Test func listToolsPageRejectsLateResponseAfterSameDescriptorReconnect() async throws {
        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                entered.signal()
                await release.wait()
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "same-descriptor-reconnect", name: "Same Descriptor Reconnect", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        let pending = Task { try await client.listToolsPage() }
        await entered.wait()
        let previousGeneration = client.lifecycleSnapshot.generation
        try await client.reconnect()
        #expect(client.lifecycleSnapshot.generation != previousGeneration)
        release.signal()

        await #expect(throws: MCPClientError.processExited(-1)) {
            _ = try await pending.value
        }
        client.disconnect()
    }

    @Test func callToolReturnsJoinedText() async throws {
        // @Sendable 闭包里不能直接改捕获的 var —— 用引用盒子。
        let counter = Counter()
        let transport = MockMCPTransport { request in
            if request.method == "tools/call" {
                counter.value += 1
                // 两个 text 片段用换行拼接。
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("line one")]),
                        .object(["type": .string("text"), "text": .string("line two")]),
                    ]),
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(server: MCPServer(id: "mock", name: "Mock", type: .http, url: "http://127.0.0.1:1"), transport: transport)
        let result = try await client.callTool(name: "greet", arguments: ["name": "world"])
        #expect(result == "line one\nline two")
        #expect(counter.value == 1)
        client.disconnect()
    }

    /// End to end through MCPClient.callTool: a server text result that begins
    /// with `[` but is not JSON (filesystem `list_directory`) must reach the
    /// caller, not the `{}` placeholder.
    @Test func callToolKeepsNonJSONBracketTextFromServer() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/call" {
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("[FILE] a.txt\n[FILE] b.txt")])]),
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(server: MCPServer(id: "mock", name: "Mock", type: .http, url: "http://127.0.0.1:1"), transport: transport)
        let result = try await client.callTool(name: "list_directory", arguments: ["path": "/synthetic"])
        #expect(result != "{}")
        #expect(result == "[FILE] a.txt\n[FILE] b.txt")
        client.disconnect()
    }

    @Test func malformedCallContentRejectsWholeResponse() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/call" {
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("partial")]),
                        .object(["type": .string("text")]),
                        .object(["type": .string("text"), "text": .string("should-not-publish")]),
                    ])
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "malformed-call-content", name: "Malformed Call Content", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/call text content item missing string 'text'")) {
            _ = try await client.callTool(name: "greet", arguments: nil)
        }
        client.disconnect()
    }

    @Test func unsupportedCallArgumentRejectsBeforeDispatch() async throws {
        let requests = Counter()
        let transport = MockMCPTransport { request in
            requests.value += 1
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-dispatch")
        }
        let client = MCPClient(
            server: MCPServer(id: "unsupported-call-argument", name: "Unsupported Call Argument", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/call arguments contain an unsupported value")) {
            _ = try await client.callTool(name: "greet", arguments: ["when": Date(timeIntervalSince1970: 0)])
        }
        #expect(requests.value == 0)
        client.disconnect()
    }

    @Test func nonFiniteCallArgumentRejectsBeforeDispatch() async throws {
        let requests = Counter()
        let transport = MockMCPTransport { request in
            requests.value += 1
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-dispatch")
        }
        let client = MCPClient(
            server: MCPServer(id: "non-finite-call-argument", name: "Non-Finite Call Argument", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/call arguments contain an unsupported value")) {
            _ = try await client.callTool(name: "greet", arguments: ["score": Double.nan])
        }
        #expect(requests.value == 0)
        client.disconnect()
    }

    @Test func nonFiniteMCPJSONValueArgumentRejectsBeforeDispatch() async throws {
        let requests = Counter()
        let transport = MockMCPTransport { request in
            requests.value += 1
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-dispatch")
        }
        let client = MCPClient(
            server: MCPServer(id: "non-finite-json-value", name: "Non-Finite JSON Value", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/call arguments contain an unsupported value")) {
            _ = try await client.callTool(
                name: "greet",
                arguments: ["score": MCPJSONValue.number(.nan)]
            )
        }
        #expect(requests.value == 0)
        client.disconnect()
    }

    @Test func overdeepCallArgumentRejectsBeforeDispatch() async throws {
        let requests = Counter()
        let transport = MockMCPTransport { request in
            requests.value += 1
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-dispatch")
        }
        let client = MCPClient(
            server: MCPServer(id: "overdeep-call-argument", name: "Overdeep Call Argument", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )
        var nested: Any = "leaf"
        for _ in 0..<65 {
            nested = [nested]
        }

        await #expect(throws: MCPClientError.badResponse("tools/call arguments contain an unsupported value")) {
            _ = try await client.callTool(name: "greet", arguments: ["nested": nested])
        }
        #expect(requests.value == 0)
        client.disconnect()
    }

    @Test func emptyCallToolNameRejectsBeforeDispatch() async throws {
        let requests = Counter()
        let transport = MockMCPTransport { request in
            requests.value += 1
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "should-not-dispatch")
        }
        let client = MCPClient(
            server: MCPServer(id: "empty-call-name", name: "Empty Call Name", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.toolNotFound("  ")) {
            _ = try await client.callTool(name: "  ", arguments: nil)
        }
        #expect(requests.value == 0)
        client.disconnect()
    }

    @Test func rpcErrorPropagates() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/call" {
                return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32602, message: "invalid params"))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(server: MCPServer(id: "mock", name: "Mock", type: .http, url: "http://127.0.0.1:1"), transport: transport)
        await #expect(throws: MCPClientError.rpcError(code: -32602, message: "invalid params")) {
            _ = try await client.callTool(name: "greet", arguments: nil)
        }
        client.disconnect()
    }

    @Test func badToolsListResponseThrows() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                return MCPJSONRPCResponse(id: request.id, result: .object(["unexpected": .string("shape")]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(server: MCPServer(id: "mock", name: "Mock", type: .http, url: "http://127.0.0.1:1"), transport: transport)
        await #expect(throws: MCPClientError.badResponse("tools/list result missing 'tools' array")) {
            _ = try await client.listTools()
        }
        client.disconnect()
    }

    @Test func malformedToolEntryRejectsWholeList() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "tools": .array([
                        .object(["description": .string("missing name")]),
                        .object(["name": .string("would-be-partial-result")]),
                    ])
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "malformed-tool-entry", name: "Malformed Tool Entry", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/list tool entry missing non-empty 'name'")) {
            _ = try await client.listTools()
        }
        client.disconnect()
    }

    @Test func listToolsRejectsUnboundedOrControlCharacterNames() async throws {
        let invalidNames = [
            String(repeating: "x", count: 257),
            "line\nfeed",
        ]
        let expectedErrors = [
            MCPClientError.badResponse("tools/list tool entry name exceeds byte limit"),
            MCPClientError.badResponse("tools/list tool entry name contains a control character"),
        ]

        for (name, expected) in zip(invalidNames, expectedErrors) {
            let client = MCPClient(
                server: MCPServer(id: "invalid-tool-name", name: "Invalid Tool Name", type: .http, url: "http://127.0.0.1:1"),
                transport: MockMCPTransport { request in
                    if request.method == "tools/list" {
                        return MCPJSONRPCResponse(id: request.id, result: .object([
                            "tools": .array([
                                .object(["name": .string(name)]),
                                .object(["name": .string("would-be-partial-result")]),
                            ])
                        ]))
                    }
                    return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
                }
            )

            await #expect(throws: expected) {
                _ = try await client.listTools()
            }
            client.disconnect()
        }
    }

    @Test func callToolRejectsUnboundedOrControlCharacterNameBeforeDispatch() async throws {
        let invalidNames = [
            String(repeating: "x", count: 257),
            "line\nfeed",
        ]

        for name in invalidNames {
            let requests = Counter()
            let client = MCPClient(
                server: MCPServer(id: "invalid-call-name", name: "Invalid Call Name", type: .http, url: "http://127.0.0.1:1"),
                transport: MockMCPTransport { request in
                    requests.value += 1
                    return MockMCPTransport.happyResponse(for: request, tools: [], callText: "unexpected")
                }
            )

            await #expect(throws: MCPClientError.toolNotFound(name)) {
                _ = try await client.callTool(name: name, arguments: nil)
            }
            #expect(requests.value == 0)
            client.disconnect()
        }
    }

    @Test func invalidToolDescriptionTypeRejectsWholeList() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "tools": .array([
                        .object([
                            "name": .string("invalid-description"),
                            "description": .number(42),
                        ]),
                        .object(["name": .string("would-be-partial-result")]),
                    ])
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "invalid-tool-description", name: "Invalid Tool Description", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/list tool entry has invalid 'description'")) {
            _ = try await client.listTools()
        }
        client.disconnect()
    }

    @Test func invalidToolInputSchemaTypeRejectsWholeList() async throws {
        let transport = MockMCPTransport { request in
            if request.method == "tools/list" {
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "tools": .array([
                        .object([
                            "name": .string("invalid-schema"),
                            "inputSchema": .array([]),
                        ]),
                        .object(["name": .string("would-be-partial-result")]),
                    ])
                ]))
            }
            return MockMCPTransport.happyResponse(for: request, tools: [], callText: "")
        }
        let client = MCPClient(
            server: MCPServer(id: "invalid-tool-schema", name: "Invalid Tool Schema", type: .http, url: "http://127.0.0.1:1"),
            transport: transport
        )

        await #expect(throws: MCPClientError.badResponse("tools/list tool entry has invalid 'inputSchema'")) {
            _ = try await client.listTools()
        }
        client.disconnect()
    }
}

// MARK: - MCPClient（真实 stdio 假进程）

struct MCPClientStdioTests {

    @Test("a second real stdio client initializes while the first is idle or disconnected",
          arguments: [false, true])
    func independentStdioInitializationWithIdleOwner(disconnectFirst: Bool) async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let firstScript = try writeEchoServerScript()
        let secondScript = try writeEchoServerScript()
        for script in [firstScript, secondScript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                ofItemAtPath: script.deletingLastPathComponent().path)
        }
        defer {
            try? FileManager.default.removeItem(at: firstScript.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondScript.deletingLastPathComponent())
        }
        let firstServer = MCPServer(id: "dual-first", name: "Owned first",
            command: "/bin/sh", args: [firstScript.path], timeoutSeconds: 60)
        let secondServer = MCPServer(id: "dual-second", name: "Owned second",
            command: "/bin/sh", args: [secondScript.path], timeoutSeconds: 60)
        let firstTransport = MCPStdioTransport(command: "/bin/sh",
            args: firstServer.args, env: [:], timeoutSeconds: 60)
        let secondTransport = MCPStdioTransport(command: "/bin/sh",
            args: secondServer.args, env: [:], timeoutSeconds: 60)
        let first = MCPClient(server: firstServer, transport: firstTransport)
        let second = MCPClient(server: secondServer, transport: secondTransport)
        var firstPID: pid_t?
        var secondPID: pid_t?
        func stopOwned(_ client: MCPClient, _ transport: MCPStdioTransport, pid: pid_t?) {
            client.disconnect()
            #expect(!transport.isReady)
            guard let pid else { return }
            #expect(!processIsAlive(pid))
            var status: Int32 = 0
            let waited = Darwin.waitpid(pid, &status, WNOHANG)
            let waitError = errno
            #expect(waited == pid || (waited == -1 && waitError == ECHILD))
            print("MCP_DUAL_CLEANUP stopReturned=true ownedReaped=\(waited == pid) noWaitableChild=\(waited == -1 && waitError == ECHILD)")
        }
        defer {
            stopOwned(second, secondTransport, pid: secondPID ?? secondTransport.runtimeSnapshot().processIdentifier)
            stopOwned(first, firstTransport, pid: firstPID ?? firstTransport.runtimeSnapshot().processIdentifier)
        }
        try await firstTransport.start()
        firstPID = firstTransport.runtimeSnapshot().processIdentifier
        try #require(firstPID != nil)
        try await first.connect()
        let firstTools = try await first.listTools()
        #expect(firstTools.map(\.name) == ["greet"])
        try #require(first.isConnected && firstTransport.isReady)
        if disconnectFirst {
            stopOwned(first, firstTransport, pid: firstPID)
        }
        try await secondTransport.start()
        secondPID = secondTransport.runtimeSnapshot().processIdentifier
        try #require(secondPID != nil)
        try await second.connect()
        let secondTools = try await second.listTools()
        #expect(secondTools == firstTools)
        #expect(second.isConnected && secondTransport.isReady)
        #expect(first.isConnected == !disconnectFirst)
        if !disconnectFirst {
            #expect(firstTransport.isReady)
            #expect(firstPID != secondPID)
        }
    }

    /// 写一个 echo 假 MCP 服务器：读 stdin 行、把请求里的 id 原样带回。
    /// 用原始字符串 #"""..."""# 包 shell 脚本：内容零转义，脚本与文件逐字节一致。
    private func writeEchoServerScript() throws -> URL {
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          [ -z "$id" ] && continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\')
          case "$method" in
            tools/list)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"greet","description":"Echo greet","inputSchema":{"type":"object","properties":{"name":{"type":"string"}}}}]}}\n' "$id";;
            tools/call)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Hello, MCP!"}]}}\n' "$id";;
            initialize)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"echo","version":"0.0.1"}}}\n' "$id";;
            *)
              printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"method not found"}}\n' "$id";;
          esac
        done

        """#
        let url = try makeTempDir("MCPStdioTests").appendingPathComponent("echo-server.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeLifecycleServerScript(ignoresSIGTERM: Bool) throws -> (script: URL, pidFile: URL, directory: URL) {
        let directory = try makeTempDir("MCPLifecycleTests")
        let script = directory.appendingPathComponent("lifecycle-server.sh")
        let pidFile = directory.appendingPathComponent("pid")
        let body: String
        if ignoresSIGTERM {
            body = #"""
            printf '%s' "$$" > "$MCP_PID_FILE"
            trap '' TERM
            while :; do sleep 1; done

            """#
        } else {
            body = #"""
            printf '%s' "$$" > "$MCP_PID_FILE"
            while IFS= read -r line; do :; done

            """#
        }
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, pidFile, directory)
    }

    private func writeEOFServerScript() throws -> (script: URL, pidFile: URL, directory: URL) {
        let directory = try makeTempDir("MCPEOFTests")
        let script = directory.appendingPathComponent("eof-server.sh")
        let pidFile = directory.appendingPathComponent("pid")
        let body = #"""
        printf '%s' "$$" > "$MCP_PID_FILE"
        exec 1>&-
        trap '' TERM
        while :; do sleep 1; done

        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, pidFile, directory)
    }

    @Test func stdioEchoServerEndToEnd() async throws {
        let script = try writeEchoServerScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let server = MCPServer(id: "echo", name: "Echo", type: .stdio,
                               command: "/bin/sh", args: [script.path], timeoutSeconds: 5)
        let client = MCPClient(server: server)
        try await client.connect()
        #expect(client.isConnected)

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "greet")
        #expect(tools[0].description == "Echo greet")

        let result = try await client.callTool(name: "greet", arguments: ["name": "x"])
        #expect(result == "Hello, MCP!")

        client.disconnect()
        #expect(!client.isConnected)
    }

    @Test func registryStableBoundaryEOFKeepsProcessExited() async throws {
        let script = try writeEchoServerScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let original = try String(contentsOf: script, encoding: .utf8)
        let response = #"printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Hello, MCP!"}]}}\n' "$id";;"#
        _ = try #require(original.range(of: response))
        try original.replacingOccurrences(of: response, with: "exit 0;;")
            .write(to: script, atomically: true, encoding: .utf8)
        let manager = MCPServerManager(fileURL: script.deletingLastPathComponent().appendingPathComponent("mcps.json"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        let server = MCPServer(id: "stable-eof", name: "Stable EOF", type: .stdio,
            command: "/bin/sh", args: [script.path], timeoutSeconds: 5)
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager)
        defer { registry.disconnectAll() }
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "greet")
        #expect(try await registry.mcpBoundTools().map(\.fullName) == [fullName])
        #expect(manager.server(id: server.id)?.enabled == true)
        #expect(manager.isServerAuthorized(server))
        do {
            _ = try await registry.callMCPTool(fullName: fullName, arguments: nil,
                invocation: MCPToolInvocationIdentity(correlationID: "stable-eof", attemptID: "attempt-1"))
            Issue.record("A real server EOF must not publish a successful tool result.")
        } catch MCPClientError.processExited(_) {
            // The server exited without any external disable/rebind of the admitted route.
        }
        #expect(manager.server(id: server.id)?.enabled == true)
        #expect(manager.isServerAuthorized(server))
    }

    @Test func stdioTimeoutWhenServerNeverResponds() async throws {
        // /bin/cat 会把请求行原样回显 —— 那是一行 request，不是 response，
        // 客户端解析后丢弃，pending 请求等到超时。
        let server = MCPServer(id: "cat", name: "Cat", type: .stdio,
                               command: "/bin/cat", args: [], timeoutSeconds: 1)
        let client = MCPClient(server: server)
        let start = Date()
        await #expect(throws: MCPClientError.self) {
            _ = try await client.listTools() // initialize 先超时
        }
        #expect(Date().timeIntervalSince(start) < 10)
        client.disconnect()
    }

    /// P2-6 回归（确定性部分）：stop() 置位停止标志后，notify 必须直接
    /// 短路抛 transportNotStarted，绝不再写已关闭的 stdin。
    @Test func stdioNotifyAfterStopShortCircuits() async throws {
        let script = try writeEchoServerScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let transport = MCPStdioTransport(command: "/bin/sh", args: [script.path], env: [:], timeoutSeconds: 5)
        try await transport.start()
        // 握手前发一条通知验证写路径可用。
        try transport.notify(MCPJSONRPCNotification(method: "notifications/initialized", params: nil))
        transport.stop()

        // stop 之后：短路，确定性抛 transportNotStarted。
        #expect(throws: MCPClientError.transportNotStarted) {
            try transport.notify(MCPJSONRPCNotification(method: "notifications/initialized", params: nil))
        }
        // 二次 stop 幂等。
        transport.stop()
    }

    /// P2-6 回归（竞态部分）：notify 与 stop() 并发。修复前 notify 在锁外
    /// 写 stdin，write 可能命中 stop() 已关闭的 FileHandle（非受控异常）。
    /// 修复后写移入锁内 + stopped 标志短路：notify 只可能是「写入成功」或
    /// 「transportNotStarted」两种结果，绝不应崩溃或抛出其他错误。
    @Test func stdioNotifyStopRaceNeverWritesClosedHandle() async throws {
        let script = try writeEchoServerScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        for _ in 0..<10 {
            let transport = MCPStdioTransport(command: "/bin/sh", args: [script.path], env: [:], timeoutSeconds: 5)
            try await transport.start()

            let outcome = await withTaskGroup(of: Bool.self) { group in
                // 一批并发 notify + 一个 stop，制造交错。
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            try transport.notify(MCPJSONRPCNotification(method: "notifications/initialized", params: nil))
                            return true
                        } catch MCPClientError.transportNotStarted {
                            return true // 短路是合法结局
                        } catch {
                            return false // 命中已关闭句柄等 → 修复不彻底
                        }
                    }
                }
                group.addTask {
                    transport.stop()
                    return true
                }
                var allGood = true
                for await ok in group { allGood = allGood && ok }
                return allGood
            }
            #expect(outcome, "notify 与 stop 竞态产生了 transportNotStarted 之外的错误")
        }
    }

    @Test func stdioStopAllowsNaturalExitAfterClosingStdin() async throws {
        let fixture = try writeLifecycleServerScript(ignoresSIGTERM: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let transport = MCPStdioTransport(
            command: "/bin/sh",
            args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path],
            timeoutSeconds: 5
        )
        try await transport.start()
        let pid = try await waitForProcessID(at: fixture.pidFile)

        let started = Date()
        transport.stop()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 2)
        #expect(!processIsAlive(pid))
        transport.stop()
    }

    @Test func stdioStopForceKillsAndReapsWhenSIGTERMIsIgnored() async throws {
        let fixture = try writeLifecycleServerScript(ignoresSIGTERM: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let transport = MCPStdioTransport(
            command: "/bin/sh",
            args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path],
            timeoutSeconds: 5
        )
        try await transport.start()
        let pid = try await waitForProcessID(at: fixture.pidFile)

        let started = Date()
        transport.stop()
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 3)
        #expect(!processIsAlive(pid))
        transport.stop()
    }

    @Test func stdioEOFWhileProcessIsRunningDoesNotReadTerminationStatus() async throws {
        let fixture = try writeEOFServerScript()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let transport = MCPStdioTransport(
            command: "/bin/sh",
            args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path],
            timeoutSeconds: 1
        )
        try await transport.start()
        let pid = try await waitForProcessID(at: fixture.pidFile)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await waitForProcessExit(pid)
        #expect(!transportStarted(transport))
        #expect(!processIsAlive(pid))
        transport.stop()
    }

    @Test func stdioExit127SettlesPendingWithoutTerminationStatusCrash() async throws {
        let server = MCPServer(
            id: "exit-127",
            name: "Exit 127",
            type: .stdio,
            command: "/bin/sh",
            args: ["-c", "exit 127"],
            timeoutSeconds: 1
        )
        let client = MCPClient(server: server)

        await #expect(throws: MCPClientError.self) {
            _ = try await client.listTools()
        }
        client.disconnect()
        #expect(!client.isConnected)
    }

    @Test func stdioMalformedResponseSettlesPendingImmediately() async throws {
        // Read initialize, then initialized, then tools/list. The malformed
        // line must settle an actual pending request, not race process exit
        // while the client is still entering the tools/list call.
        let script = "read line || exit 0; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'; read line || exit 0; read line || exit 0; printf '%s\\n' 'not-json'; read line || exit 0"
        let server = MCPServer(
            id: "malformed-response",
            name: "Malformed Response",
            type: .stdio,
            command: "/bin/sh",
            args: ["-c", script],
            timeoutSeconds: 5
        )
        let transport = try #require(MCPClient.makeTransport(for: server) as? MCPStdioTransport)
        let client = MCPClient(server: server, transport: transport)
        defer { client.disconnect() }

        try await client.connect()
        let pid = try #require(transport.runtimeSnapshot().processIdentifier)
        let started = Date()
        await #expect(throws: MCPClientError.badResponse("malformed MCP response")) {
            _ = try await client.listTools()
        }
        #expect(Date().timeIntervalSince(started) < 2)
        client.disconnect()
        try await waitForProcessExit(pid)
        #expect(!processIsAlive(pid))
    }

    @Test func stdioStopResolvesPendingRequestExactlyOnce() async throws {
        let transport = MCPStdioTransport(command: "/bin/cat", args: [], env: [:], timeoutSeconds: 5)
        try await transport.start()
        let pending = Task {
            try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "tools/list"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.stop()

        await #expect(throws: MCPClientError.self) {
            _ = try await pending.value
        }
        #expect(!transportStarted(transport))
    }

    @Test func stdioSendCancellationSettlesExactPendingRequest() async throws {
        let fixture = try writeLifecycleServerScript(ignoresSIGTERM: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = MCPStdioTransport(command: "/bin/sh", args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path], timeoutSeconds: 5)
        defer { transport.stop() }
        try await transport.start()
        let pending = Task {
            try await transport.send(MCPJSONRPCRequest(id: .int(3), method: "tools/list"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let started = Date()
        pending.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await pending.value
        }
        #expect(Date().timeIntervalSince(started) < 1)
        transport.stop()
    }

    @Test func stdioDuplicateRequestIDCannotOrphanOriginalContinuation() async throws {
        let fixture = try writeLifecycleServerScript(ignoresSIGTERM: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = MCPStdioTransport(command: "/bin/sh", args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path], timeoutSeconds: 5)
        defer { transport.stop() }
        try await transport.start()
        let first = Task {
            try await transport.send(MCPJSONRPCRequest(id: .int(4), method: "tools/list"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        await #expect(throws: MCPClientError.badResponse("duplicate pending request id")) {
            _ = try await transport.send(MCPJSONRPCRequest(id: .int(4), method: "tools/call"))
        }
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        transport.stop()
    }

    @Test func stdioEOFAndStopRaceLeavesNoPendingOrphan() async throws {
        let fixture = try writeEOFServerScript()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let transport = MCPStdioTransport(
            command: "/bin/sh",
            args: [fixture.script.path],
            env: ["MCP_PID_FILE": fixture.pidFile.path],
            timeoutSeconds: 1
        )
        try await transport.start()
        let pid = try await waitForProcessID(at: fixture.pidFile)
        let pending = Task {
            try await transport.send(MCPJSONRPCRequest(id: .int(2), method: "tools/list"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await Task.yield()
        transport.stop()

        await #expect(throws: MCPClientError.self) {
            _ = try await pending.value
        }
        try await waitForProcessExit(pid)
        #expect(!transportStarted(transport))
        #expect(!processIsAlive(pid))
        transport.stop()
    }

    private func transportStarted(_ transport: MCPStdioTransport) -> Bool {
        // The transport has no public started state; a stopped transport must
        // reject notifications without touching a closed stdin handle.
        (try? transport.notify(MCPJSONRPCNotification(method: "notifications/initialized", params: nil))) != nil
    }
}

// MARK: - 工具桥接（MCPToolRegistry）

struct MCPToolBridgeTests {

    @Test func turnSnapshotUsesCacheWhileLiveDiscoveryRunsInBackground() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "background", name: "Background", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let stopped = MCPAsyncSignal()
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(
                server: server,
                transport: SuspendedDiscoveryMCPTransport(
                    entered: entered,
                    release: release,
                    stopped: stopped,
                    tools: [MCPTool(name: "greet")]
                )
            )
        }

        let coldTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        let coldCompleted = MCPAsyncSignal()
        let coldToolsTask = Task {
            defer { coldCompleted.signal() }
            return try await coldTurn.mcpBoundTools()
        }
        for _ in 0..<100 where !entered.isSignaled || !coldCompleted.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.isSignaled)
        #expect(coldCompleted.isSignaled)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)

        release.signal()
        #expect(try await coldToolsTask.value.isEmpty)
        for _ in 0..<100 where manager.discoverySnapshot(serverID: server.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let warmTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        #expect(try await warmTurn.mcpBoundTools().map(\.fullName) == ["mcp_background_greet"])
        #expect(stopped.isSignaled)

        let (staleManager, _) = try makeManager()
        let staleServer = MCPServer(id: "stale-background", name: "Stale", type: .http, url: "http://127.0.0.1:1")
        try staleManager.addServer(staleServer)
        try staleManager.authorizeServer(id: staleServer.id)
        try staleManager.authorizeTool(serverID: staleServer.id, toolName: "greet")
        let staleEntered = MCPAsyncSignal()
        let staleRelease = MCPAsyncSignal()
        let staleStopped = MCPAsyncSignal()
        let staleRegistry = MCPToolRegistry(manager: staleManager) { server in
            MCPClient(
                server: server,
                transport: SuspendedDiscoveryMCPTransport(
                    entered: staleEntered,
                    release: staleRelease,
                    stopped: staleStopped,
                    tools: [MCPTool(name: "greet")]
                )
            )
        }

        let staleColdTurn = try #require(staleRegistry.snapshotForTurn() as? MCPToolRegistry)
        let staleColdCompleted = MCPAsyncSignal()
        let staleColdToolsTask = Task {
            defer { staleColdCompleted.signal() }
            return try await staleColdTurn.mcpBoundTools()
        }
        for _ in 0..<100 where !staleEntered.isSignaled || !staleColdCompleted.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(staleEntered.isSignaled)
        #expect(staleColdCompleted.isSignaled)
        try staleManager.revokeServer(id: staleServer.id)
        staleRelease.signal()
        #expect(try await staleColdToolsTask.value.isEmpty)
        for _ in 0..<100 where !staleStopped.isSignaled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(staleStopped.isSignaled)
        #expect(staleManager.discoverySnapshot(serverID: staleServer.id) == nil)
        #expect(try await staleRegistry.snapshotForTurn().mcpBoundTools().isEmpty)
    }

    @Test func agentTurnUsesManagerDiscoverySnapshotAcrossRegistryClone() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "turn-cache", name: "Turn Cache", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let requestCount = Counter()
        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                requestCount.value += 1
                return MockMCPTransport.happyResponse(
                    for: request,
                    tools: [MCPTool(name: "greet")],
                    callText: "turn-cache"
                )
            })
        })

        let firstTurnTools = try await registry.mcpBoundTools()
        let nextTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        let secondTurnTools = try await nextTurn.mcpBoundTools()

        #expect(firstTurnTools.map(\.fullName) == ["mcp_turn-cache_greet"])
        #expect(secondTurnTools.map(\.fullName) == firstTurnTools.map(\.fullName))
        #expect(requestCount.value == 2) // initialize + one authoritative tools/list

        try manager.revokeServer(id: server.id)
        #expect(try await registry.mcpBoundTools().isEmpty)
    }

    @Test func invocationIdentityRejectsDuplicateCalls() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "dedupe", name: "Dedupe", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(callText: "once"))
        }
        let identity = MCPToolInvocationIdentity(correlationID: "corr-1", attemptID: "attempt-1")
        #expect(try await registry.callMCPTool(
            fullName: "mcp_dedupe_greet",
            arguments: nil,
            invocation: identity
        ) == "once")
        await #expect(throws: MCPToolInvocationFenceError.duplicate(identity)) {
            _ = try await registry.callMCPTool(
                fullName: "mcp_dedupe_greet",
                arguments: nil,
                identity: identity
            )
        }
        let rebound = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        await #expect(throws: MCPToolInvocationFenceError.duplicate(identity)) {
            _ = try await rebound.callMCPTool(
                fullName: "mcp_dedupe_greet",
                arguments: nil,
                identity: identity
            )
        }
        let beforeReset = try #require(registry.runtimeIdentity)
        registry.disconnectAll()
        let afterReset = try #require(registry.runtimeIdentity)
        #expect(beforeReset.ownerID != afterReset.ownerID)
        #expect(!registry.accepts(beforeReset))
    }

    @Test func persistedAuthorizationDefaultsToDenyAndSeparatesServerAndTool() async throws {
        let (manager, file) = try makeManager()
        let server = MCPServer(id: "secure", name: "Secure", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(callText: "authorized"))
        }
        #expect(manager.authorization(serverID: server.id) == nil)
        #expect(try await registry.mcpBoundTools().isEmpty)
        try manager.authorizeServer(id: server.id)
        #expect(try await registry.mcpBoundTools().isEmpty)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        #expect(try await registry.mcpBoundTools().map(\.fullName) == ["mcp_secure_greet"])
        #expect(try await registry.callMCPTool(fullName: "mcp_secure_greet", arguments: nil) == "authorized")

        let reloaded = MCPServerManager(fileURL: file)
        #expect(reloaded.isServerAuthorized(server))
        #expect(reloaded.isToolAuthorized(serverID: server.id, toolName: "greet"))
    }

    @Test func descriptorChangeAndRevokeInvalidateExistingRegistryImmediately() async throws {
        let (manager, _) = try makeManager()
        var server = MCPServer(id: "mutable", name: "Mutable", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let registry = MCPToolRegistry(manager: manager) { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(callText: "ok"))
        }
        #expect(try await registry.callMCPTool(fullName: "mcp_mutable_greet", arguments: nil) == "ok")

        server.url = "http://127.0.0.1:2"
        try manager.updateServer(server)
        #expect(!manager.isServerAuthorized(server))
        #expect(try await registry.mcpBoundTools().isEmpty)

        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        try manager.revokeTool(serverID: server.id, toolName: "greet")
        #expect(try await registry.mcpBoundTools().isEmpty)
    }

    @Test func authorizationRevisionRefreshesRouteBeforeAgentTurnCall() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "route-fence", name: "Route Fence", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let requestCount = Counter()
        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                requestCount.value += 1
                return MockMCPTransport.happyResponse(
                    for: request,
                    tools: [MCPTool(name: "greet"), MCPTool(name: "wave")],
                    callText: "route-fence"
                )
            })
        })

        #expect(try await registry.mcpBoundTools().map(\.fullName) == ["mcp_route-fence_greet"])
        let beforeRevocation = requestCount.value
        try manager.revokeTool(serverID: server.id, toolName: "greet")
        try manager.authorizeTool(serverID: server.id, toolName: "wave")

        await #expect(throws: MCPClientError.permissionDenied("mcp_route-fence_greet")) {
            _ = try await registry.callMCPTool(fullName: "mcp_route-fence_greet", arguments: nil)
        }
        #expect(requestCount.value == beforeRevocation)
        #expect(try await registry.mcpBoundTools().map(\.fullName) == ["mcp_route-fence_wave"])
        #expect(try await registry.callMCPTool(fullName: "mcp_route-fence_wave", arguments: nil) == "route-fence")
    }

    @Test func descriptorRebindRejectsLateBridgeResult() async throws {
        let (manager, _) = try makeManager()
        var server = MCPServer(id: "late-rebind", name: "Late Rebind", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let entered = MCPAsyncSignal()
        let release = MCPAsyncSignal()
        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport { request in
                if request.method == "tools/call" {
                    entered.signal()
                    await release.wait()
                }
                return MockMCPTransport.happyResponse(for: request, tools: [MCPTool(name: "greet")], callText: "late")
            })
        })
        _ = try await registry.mcpBoundTools()

        let identity = MCPToolInvocationIdentity(correlationID: "late-rebind", attemptID: "attempt-1")
        let pending = Task {
            try await registry.callMCPTool(
                fullName: "mcp_late-rebind_greet",
                arguments: nil,
                invocation: identity
            )
        }
        await entered.wait()
        server.url = "http://127.0.0.1:2"
        try manager.updateServer(server)
        release.signal()

        await #expect(throws: MCPToolInvocationFenceError.runtimeRetired(identity)) {
            _ = try await pending.value
        }
        registry.disconnectAll()
    }

    @Test func registryBridgesToolsAndDispatchesCalls() async throws {
        let (manager, _) = try makeManager()
        let echo = MCPServer(id: "echo", name: "Echo", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(echo)
        try manager.authorizeServer(id: echo.id)
        try manager.authorizeTool(serverID: echo.id, toolName: "greet")
        try manager.addServer(MCPServer(id: "dead", name: "Dead", type: .http, enabled: false, url: "http://127.0.0.1:1"))

        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(callText: "pong"))
        }, authorization: .allowing(["mcp_echo_greet"]))

        let tools = try await registry.mcpBoundTools()
        // dead 服务器被禁用，不参与发现。
        #expect(tools.map(\.fullName) == ["mcp_echo_greet"])
        #expect(tools[0].serverID == "echo")
        #expect(tools[0].tool.name == "greet")

        let out = try await registry.callMCPTool(fullName: "mcp_echo_greet", arguments: ["name": "x"])
        #expect(out == "pong")

        // 未知工具 → toolNotFound。
        await #expect(throws: MCPClientError.self) {
            _ = try await registry.callMCPTool(fullName: "mcp_echo_nope", arguments: nil)
        }
        // 未知服务器前缀。
        await #expect(throws: MCPClientError.self) {
            _ = try await registry.callMCPTool(fullName: "mcp_ghost_greet", arguments: nil)
        }

        registry.disconnectAll()
    }

    @Test func registryDiscoveryFailureSkipsServer() async throws {
        let (manager, _) = try makeManager()
        let good = MCPServer(id: "good", name: "Good", type: .http, url: "http://127.0.0.1:1")
        let bad = MCPServer(id: "bad", name: "Bad", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(good)
        try manager.addServer(bad)
        try manager.authorizeServer(id: good.id)
        try manager.authorizeTool(serverID: good.id, toolName: "greet")
        try manager.authorizeServer(id: bad.id)
        try manager.authorizeTool(serverID: bad.id, toolName: "greet")

        let registry = MCPToolRegistry(manager: manager) { server in
            if server.id == "bad" {
                // 用永远不响应的 transport 模拟死服务器 —— 快速超时。
                return MCPClient(server: server, transport: MockMCPTransport { request in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return MCPJSONRPCResponse(id: request.id)
                })
            }
            return MCPClient(server: server, transport: MockMCPTransport.happy())
        }

        let tools = try await registry.mcpBoundTools()
        // bad 服务器发现失败被跳过，good 正常返回。
        #expect(tools.map(\.fullName) == ["mcp_good_greet"])
        registry.disconnectAll()
    }

    /// P2-1 回归：server id 含下划线时，makeFullName → parseFullName 的
    /// 字符串反解非单射（"mcp_my_server_greet" 反解成 server="my"），
    /// registry 必须靠注册时记录的正查表还原，调用才能成功。
    @Test func underscoreServerIdRoundTrip() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "my_server", name: "My Server", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let registry = MCPToolRegistry(manager: manager, clientFactory: { server in
            MCPClient(server: server, transport: MockMCPTransport.happy(callText: "pong-underscore"))
        }, authorization: .allowing(["mcp_my_server_greet"]))

        let tools = try await registry.mcpBoundTools()
        #expect(tools.map(\.fullName) == ["mcp_my_server_greet"])
        #expect(tools[0].serverID == "my_server")

        // 静态反解确实是坏的（证明盲区存在，正查表非可选）：
        let badParse = MCPBoundTool.parseFullName("mcp_my_server_greet")
        #expect(badParse?.serverID == "my") // maxSplits:2 把 "my" 当 server
        #expect(badParse?.toolName == "server_greet")

        // 但 registry 走正查表，往返完整：
        let out = try await registry.callMCPTool(fullName: "mcp_my_server_greet", arguments: ["name": "x"])
        #expect(out == "pong-underscore")

        // 未知工具名仍然 toolNotFound（正查表未命中 → 反解兜底 → 服务器查无）。
        await #expect(throws: MCPClientError.self) {
            _ = try await registry.callMCPTool(fullName: "mcp_my_server_nope", arguments: nil)
        }

        registry.disconnectAll()
    }

    @Test func changedSchemaRejectsOldTurnAndOldGrantBeforeToolCall() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-drift", name: "Schema Drift", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        // This existing product flow grants the name before first discovery.
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let tools = MCPToolsBox([schemaBoundGreet("string")])
        let calls = MCPToolCallCounter()
        let factory = schemaBoundClientFactory(tools: tools, calls: calls)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        let fullName = "mcp_schema-drift_greet"
        #expect(try await registry.mcpBoundTools().map(\.fullName) == [fullName])
        let oldTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        #expect(try await oldTurn.mcpBoundTools().map(\.fullName) == [fullName])
        #expect(manager.isToolAuthorized(serverID: server.id, toolName: "greet"))

        tools.replace([schemaBoundGreet("integer")])
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        // A still-cached route reports the revoked grant before it can call
        // the transport. Once the turn refreshes, that route disappears.
        await #expect(throws: MCPClientError.permissionDenied(fullName)) {
            _ = try await oldTurn.callMCPTool(fullName: fullName, arguments: ["value": "old"])
        }
        #expect(calls.value == 0)
        #expect(try await oldTurn.mcpBoundTools().isEmpty)
        // The old turn has already discarded its invalid route above, so its
        // name lookup fails before either an authorization or transport call.
        await #expect(throws: MCPClientError.toolNotFound(fullName)) {
            _ = try await oldTurn.callMCPTool(fullName: fullName, arguments: ["value": "old"])
        }
        await #expect(throws: MCPClientError.permissionDenied(fullName)) {
            _ = try await registry.callMCPTool(fullName: fullName, arguments: ["value": "old"])
        }
        // The same bytes returning later must not resurrect the original
        // grant or the original turn's frozen route.
        tools.replace([schemaBoundGreet("string")])
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(try await registry.mcpBoundTools().isEmpty)
        #expect(try await oldTurn.mcpBoundTools().isEmpty)
        #expect(calls.value == 0)
        registry.disconnectAll()
        oldTurn.disconnectAll()
    }

    @Test func explicitReauthorizationAfterSchemaChangeRestoresOnlyNewBinding() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-regrant", name: "Schema Regrant", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let tools = MCPToolsBox([schemaBoundGreet("string")])
        let calls = MCPToolCallCounter()
        let factory = schemaBoundClientFactory(tools: tools, calls: calls)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        tools.replace([schemaBoundGreet("integer")])
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))

        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        // The explicit grant rotates the manager revision; discover under that
        // revision before the new turn receives the tool definition.
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        let fullName = "mcp_schema-regrant_greet"
        #expect(try await registry.mcpBoundTools().map(\.fullName) == [fullName])
        #expect(try await registry.callMCPTool(
            fullName: fullName, arguments: ["value": 1]
        ) == "schema-bound")
        #expect(calls.value == 1)
        registry.disconnectAll()
    }

    @Test func failedSchemaRevocationWriteCannotReviveOldGrantWhenSchemaReturns() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-write-failure", name: "Schema Write Failure", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let tools = MCPToolsBox([schemaBoundGreet("string")])
        let calls = MCPToolCallCounter()
        let factory = schemaBoundClientFactory(tools: tools, calls: calls)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        let oldTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        let fullName = "mcp_schema-write-failure_greet"
        #expect(try await oldTurn.mcpBoundTools().map(\.fullName) == [fullName])

        // Only this synthetic manager's authorization target is replaced by
        // a directory, making the revocation write fail deterministically.
        let authorizationFile = manager.authorizationFileURL
        let authorizationRepair = try MCPOwnedAuthorizationDirectoryRepair(
            file: authorizationFile, config: manager.fileURL
        )
        defer { authorizationRepair.close() }
        try authorizationRepair.replaceWithDirectory()
        tools.replace([schemaBoundGreet("integer")])
        do {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
            Issue.record("expected revocation persistence failure")
        } catch { }
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(try await oldTurn.mcpBoundTools().isEmpty)

        // Even when the remote schema returns to A, the pending durable
        // revocation blocks discovery while the write target remains broken.
        tools.replace([schemaBoundGreet("string")])
        do {
            _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
            Issue.record("expected pending revocation persistence failure")
        } catch { }
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(calls.value == 0)

        try authorizationRepair.restoreOriginalBytes()
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(!manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(try await registry.mcpBoundTools().isEmpty)
        #expect(try await oldTurn.mcpBoundTools().isEmpty)
        #expect(calls.value == 0)
        registry.disconnectAll()
        oldTurn.disconnectAll()
    }

    @Test func unchangedSchemaRediscoveryPreservesGrantAndTurn() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-stable", name: "Schema Stable", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let tools = MCPToolsBox([schemaBoundGreet("string")])
        let calls = MCPToolCallCounter()
        let factory = schemaBoundClientFactory(tools: tools, calls: calls)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        let oldTurn = try #require(registry.snapshotForTurn() as? MCPToolRegistry)
        let fullName = "mcp_schema-stable_greet"
        #expect(try await oldTurn.mcpBoundTools().map(\.fullName) == [fullName])
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        #expect(manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
        #expect(try await oldTurn.callMCPTool(
            fullName: fullName, arguments: ["value": "same"]
        ) == "schema-bound")
        #expect(calls.value == 1)
        registry.disconnectAll()
        oldTurn.disconnectAll()
    }

    @Test func unknownMCPNameStillRejectsWithoutToolCall() async throws {
        let (manager, _) = try makeManager()
        let server = MCPServer(id: "schema-unknown", name: "Schema Unknown", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")
        let tools = MCPToolsBox([schemaBoundGreet("string")])
        let calls = MCPToolCallCounter()
        let factory = schemaBoundClientFactory(tools: tools, calls: calls)
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        _ = try await registry.mcpBoundTools()
        let unknown = "mcp_schema-unknown_missing"
        await #expect(throws: MCPClientError.toolNotFound(unknown)) {
            _ = try await registry.callMCPTool(fullName: unknown, arguments: nil)
        }
        #expect(calls.value == 0)
        registry.disconnectAll()
    }
}

/// Repairs the fixture's own temporary directory fault back to the exact
/// committed pair. It never asks the manager to adopt a different baseline.
private final class MCPOwnedAuthorizationDirectoryRepair {
    private var parent: Int32
    private let directory: URL
    private let config: URL
    private let authorization: URL
    private let parentIdentity: stat
    private let originalIdentity: stat
    private let originalBytes: Data
    private let originalPair: MCPPersistentWriteFence.PairToken
    private var faultIdentity: stat?

    init(file: URL, config: URL) throws {
        directory = file.deletingLastPathComponent().resolvingSymlinksInPath()
        self.config = config
        authorization = file
        let prefix = "MCPServerManagerTests-"
        guard file.lastPathComponent == "mcp-authorizations.json", config.lastPathComponent == "mcps.json",
              config.deletingLastPathComponent().resolvingSymlinksInPath() == directory,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              directory.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        else { throw CocoaError(.fileWriteNoPermission) }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        do {
            var p = stat()
            guard Darwin.fstat(fd, &p) == 0, p.st_uid == getuid(), p.st_mode & S_IFMT == S_IFDIR,
                  Darwin.fchmod(fd, 0o700) == 0, Darwin.fstat(fd, &p) == 0, p.st_mode & 0o777 == 0o700
            else { throw CocoaError(.fileWriteNoPermission) }
            let original = Darwin.openat(fd, "mcp-authorizations.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard original >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
            defer { Darwin.close(original) }
            var identity = stat()
            guard Darwin.fstat(original, &identity) == 0, identity.st_uid == getuid(),
                  identity.st_mode & S_IFMT == S_IFREG, identity.st_nlink == 1,
                  identity.st_size >= 0, identity.st_size <= 32 * 1024 * 1024
            else { throw CocoaError(.fileReadNoPermission) }
            let reader = FileHandle(fileDescriptor: original, closeOnDealloc: false)
            var bytes = Data()
            while bytes.count <= 32 * 1024 * 1024 {
                let chunk = try reader.read(upToCount: min(64 * 1024, 32 * 1024 * 1024 + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            guard bytes.count == Int(identity.st_size) else { throw CocoaError(.fileReadCorruptFile) }
            let lease = try MCPPersistentWriteFence.acquire(configURL: config, authorizationURL: file)
            defer { lease.release() }
            let pair = try lease.token(maxBytes: 32 * 1024 * 1024)
            let originalRevision = ((try JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["revision"] as? Int
            guard pair.authorization.present,
                  pair.authorization.sha256 == DeletionGate.fingerprint(bytes),
                  pair.authorization.revision == originalRevision
            else { throw CocoaError(.fileReadCorruptFile) }
            parent = fd
            parentIdentity = p
            originalIdentity = identity
            originalBytes = bytes
            originalPair = pair
            print("MCP_OWNED_REPAIR_BASELINE authSHA=\(pair.authorization.sha256 ?? "nil") authRevision=\(pair.authorization.revision.map { String($0) } ?? "nil") present=\(pair.authorization.present) parentDev=\(pair.authorization.target.device) parentInode=\(pair.authorization.target.inode)")
        } catch { Darwin.close(fd); throw error }
    }

    private func requireParent() throws {
        var opened = stat()
        var named = stat()
        guard parent >= 0, Darwin.fstat(parent, &opened) == 0,
              Darwin.lstat(directory.path, &named) == 0,
              opened.st_dev == parentIdentity.st_dev, opened.st_ino == parentIdentity.st_ino,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_mode & S_IFMT == S_IFDIR, opened.st_uid == getuid(), opened.st_mode & 0o777 == 0o700
        else { throw CocoaError(.fileWriteNoPermission) }
    }

    func replaceWithDirectory() throws {
        try requireParent()
        var current = stat()
        guard faultIdentity == nil,
              Darwin.fstatat(parent, "mcp-authorizations.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == originalIdentity.st_dev, current.st_ino == originalIdentity.st_ino,
              current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
              Darwin.unlinkat(parent, "mcp-authorizations.json", 0) == 0,
              Darwin.mkdirat(parent, "mcp-authorizations.json", 0o700) == 0,
              Darwin.fstatat(parent, "mcp-authorizations.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFDIR, current.st_mode & 0o777 == 0o700
        else { throw CocoaError(.fileWriteUnknown) }
        faultIdentity = current
    }

    func restoreOriginalBytes() throws {
        try requireParent()
        var current = stat()
        guard let fault = faultIdentity,
              Darwin.fstatat(parent, "mcp-authorizations.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == fault.st_dev, current.st_ino == fault.st_ino,
              current.st_uid == getuid(), current.st_mode & S_IFMT == S_IFDIR,
              Darwin.unlinkat(parent, "mcp-authorizations.json", AT_REMOVEDIR) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
        let fd = Darwin.openat(parent, "mcp-authorizations.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
        defer { Darwin.close(fd) }
        try originalBytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n > 0 { offset += n }
                else if n < 0, errno == EINTR { continue }
                else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard Darwin.fsync(fd) == 0, Darwin.fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try requireParent()
        var restored = stat()
        guard Darwin.fstat(fd, &restored) == 0, restored.st_uid == getuid(),
              restored.st_mode & S_IFMT == S_IFREG, restored.st_nlink == 1, restored.st_mode & 0o777 == 0o600
        else { throw CocoaError(.fileWriteNoPermission) }
        let lease = try MCPPersistentWriteFence.acquire(configURL: config, authorizationURL: authorization)
        defer { lease.release() }
        let actualPair = try lease.token(maxBytes: 32 * 1024 * 1024)
        guard actualPair == originalPair else { throw MCPPersistenceConflict.staleSnapshot }
        print("MCP_OWNED_REPAIR_PAIR_EQUAL=true authSHA=\(actualPair.authorization.sha256 ?? "nil") authRevision=\(actualPair.authorization.revision.map { String($0) } ?? "nil") present=\(actualPair.authorization.present) parentDev=\(actualPair.authorization.target.device) parentInode=\(actualPair.authorization.target.inode)")
        faultIdentity = nil
    }

    func close() { if parent >= 0 { Darwin.close(parent); parent = -1 } }
    deinit { close() }
}
