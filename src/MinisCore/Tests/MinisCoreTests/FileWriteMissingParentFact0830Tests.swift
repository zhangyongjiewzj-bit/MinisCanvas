import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MinisCore

// Original0808 UI defect: a deterministic missing parent must fail before the
// durable uncertain-write marker. All tool feedback is produced by actual
// AgentLoop + BuiltinToolExecutor; HTTP only supplies native calls/reply.
private final class FileWriteWire0830: @unchecked Sendable {
    struct Request: Sendable {
        let line: String
        let body: Data
    }
    private let input: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var captured: [Request] = []
    private var failure: String?
    private var stopped = false
    let port: UInt16
    var requests: [Request] { lock.withLock { captured } }
    var captureFailure: String? { lock.withLock { failure } }

    init(input: String) throws {
        self.input = input
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            _ = Darwin.close(fd); throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else { _ = Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }
    deinit { stop() }
    func stop() {
        let shouldClose = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldClose { _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor) }
    }

    private func serve() {
        for _ in 0..<3 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let complete = serve(client: client)
            _ = Darwin.close(client)
            guard complete else { return }
        }
    }
    private func serve(client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 2_000_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failure = "incomplete HTTP entity" }; return false }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
            let lines = headers.components(separatedBy: "\r\n")
            let entityLength = lines.compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first
            guard let entityLength, entityLength > 0, entityLength < 2_000_000,
                  let requestLine = lines.first else {
                lock.withLock { failure = "missing bounded Content-Length" }; return false
            }
            let offset = boundary.upperBound
            guard received.count >= offset + entityLength else { continue }
            lock.withLock {
                captured.append(Request(line: requestLine,
                    body: received.subdata(in: offset..<(offset + entityLength))))
            }
            let first = requests.count == 1
            // AgentLoop.run uses the actual buffered tools-aware sendMessage
            // witness (stream=false), so return its native JSON message shape.
            let message: [String: Any] = first ? ["role": "assistant", "tool_calls": [["id": "call0830", "type": "function",
                "function": ["name": "file_write", "arguments": input]]]] : ["role": "assistant", "content": "owned final feedback observed"]
            let json = try? JSONSerialization.data(withJSONObject: ["id": "wire0830", "object": "chat.completion",
                "choices": [["index": 0, "message": message, "finish_reason": first ? "tool_calls" : "stop"]]])
            guard let json else { return false }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(json)
            return response.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return false }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, address.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { return false }
                    sent += count
                }
                return true
            }
        }
        lock.withLock { failure = "HTTP entity exceeded owned fixture bound" }
        return false
    }
}

private actor FileWriteApproval0830: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private final class FileWriteObservation0830: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: [ToolExecutionFact] = []
    private var tokens: [ToolExecutionSettlementObservation] = []
    var facts: [ToolExecutionFact] { lock.withLock { observed } }
    func keep(_ value: ToolExecutionSettlementObservation?) {
        if let value { lock.withLock { tokens.append(value) } }
    }
    func receive(_ fact: ToolExecutionFact) { lock.withLock { observed.append(fact) } }
}

@Suite("ARTIFACTA actual native file-write terminal facts0830", .serialized)
struct FileWriteMissingParentFact0830Tests {
    private final class Fixture {
        let root: URL
        let allowed: URL
        let foreign: URL
        let factsURL: URL
        let facts: ToolExecutionFactLedger
        let changes: FileChangeLedger
        let executor: BuiltinToolExecutor
        let identity: AgentExecutionIdentity
        let approval = FileWriteApproval0830()
        let observation = FileWriteObservation0830()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-filewrite0830-\(UUID())")
            allowed = root.appendingPathComponent("allowed", isDirectory: true)
            foreign = root.appendingPathComponent("foreign", isDirectory: true)
            for url in [root, allowed, foreign] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            factsURL = root.appendingPathComponent("tool-facts.json")
            facts = try ToolExecutionFactLedger(persistenceURL: factsURL)
            changes = FileChangeLedger(workspaceRoot: allowed.path)
            executor = BuiltinToolExecutor(allowedRoot: allowed, deniedRoots: [])
            executor.fileChangeLedger = changes
            executor.fileChangeSessionID = "foreign-selected-session0830"
            identity = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: "actual-session0830",
                turnID: 1, messageID: "message0830"), operationID: "operation0830", attempt: 1)
        }
        /// createDirs 为 nil 时不传该参数，走默认值（默认自动建父目录）。
        func run(target: URL, createDirs: Bool? = false) async throws -> (AgentLoopResult?, String?, [FileWriteWire0830.Request]) {
            var arguments: [String: Any] = ["tool_title": "Write owned synthetic artifact",
                "path": target.path, "content": "owned artifact0830\n", "append": false]
            if let createDirs { arguments["create_dirs"] = createDirs }
            let input = try JSONSerialization.data(withJSONObject: arguments)
            let wire = try FileWriteWire0830(input: String(decoding: input, as: UTF8.self))
            defer { wire.stop() }
            var config = ProviderConfig(label: "LUNA", providerType: .openAI, runtimeProviderID: "LUNA",
                customBaseURL: "http://127.0.0.1:\(wire.port)", apiKey: "PUBLIC_SYNTHETIC_0830")
            config.controlledFieldLoopbackOnly = true
            let made = try ProviderFactory().makeProvider(for: config)
            let provider = try #require(made as? OpenAICompatibleProvider)
            #expect(provider.controlledFieldLoopbackOnly)
            let catalog = AgentToolCatalog.makeTools().filter { $0.name == "file_write" }
            #expect(catalog.count == 1)
            var loop = AgentLoop(maxIterations: 2, approvalGate: ApprovalGate(delegate: approval),
                turnController: TurnController(), timeout: 30, toolExecutionFactLedger: facts)
            let facts = facts, observation = observation
            loop.onToolExecutionPhase = { phase in
                guard phase.phase == .queued,
                      let pending = facts.pendingReceipts.first(where: { $0.compositeKey == phase.compositeKey }) else { return }
                observation.keep(facts.observeSettlement(compositeKey: phase.compositeKey,
                    receiptID: pending.receiptID, receive: { observation.receive($0) }))
            }
            var result: AgentLoopResult?
            var failure: String?
            do {
                result = try await loop.run(messages: [.init(role: .user, content: "owned normal file-write0830")],
                    systemPrompt: "synthetic owned request", provider: provider, toolExecutor: executor, tools: catalog,
                    currentConversationID: identity.turn.sessionID,
                    parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                        conversationID: identity.turn.sessionID, taskID: "task0830", actorID: "owned-fixture0830"),
                    executionIdentity: identity)
            } catch { failure = String(describing: error) }
            #expect(wire.captureFailure == nil)
            print("TASK0830_ROOT=\(root.path) actualHTTP=\(wire.requests.count) facts=\(facts.facts.count) pending=\(facts.pendingReceipts.count) error=\(failure ?? "NONE")")
            for (index, request) in wire.requests.enumerated() {
                print("TASK0830_ACTUAL_ENTITY index=\(index) bytes=\(request.body.count) sha256=\(SHA256.hash(data: request.body))")
                #expect(request.line.contains("/chat/completions"))
            }
            return (result, failure, wire.requests)
        }
        func assertFeedback(_ requests: [FileWriteWire0830.Request], failed: Bool) throws {
            #expect(requests.count == 2)
            guard requests.count == 2 else { return }
            let body = try #require(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let feedback = try #require(messages.first { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call0830" })
            let content = try #require(feedback["content"] as? String)
            #expect(failed ? content.contains("Error executing tool file_write") : content.contains("Wrote"))
        }
    }

    @Test("known pre-effect missing/non-directory parent and foreign path settle actual failed facts", arguments: ["missing-parent", "non-directory-parent", "foreign-root"])
    func deterministicRejectionSettlesFailedFactAndFeedsBack(kind: String) async throws {
        let f = try Fixture()
        let target: URL
        if kind == "missing-parent" {
            target = f.allowed.appendingPathComponent("missing/never.md")
        } else if kind == "non-directory-parent" {
            let parent = f.allowed.appendingPathComponent("parent-is-file")
            try Data("owned sentinel".utf8).write(to: parent)
            target = parent.appendingPathComponent("never.md")
        } else { target = f.foreign.appendingPathComponent("never.md") }
        // 缺失父目录显式 create_dirs=false 时仍拒绝；父路径是普通文件时走默认（自动建目录）也要在写入前失败。
        let (outcome, failure, requests) = try await f.run(target: target, createDirs: kind == "non-directory-parent" ? nil : false)
        #expect(failure == nil, "normal file refusal is not durable authority failure")
        #expect(outcome != nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(f.changes.records(sessionID: f.identity.turn.sessionID).isEmpty)
        #expect(f.changes.records(sessionID: "foreign-selected-session0830").isEmpty)
        #expect(f.facts.pendingReceipts.isEmpty)
        #expect(f.observation.facts.count == 1)
        let terminal = try #require(f.facts.facts.first)
        #expect(terminal.status == .failed)
        #expect(terminal.executionIdentity == f.identity && terminal.compositeKey?.toolCallID == "call0830")
        #expect(f.observation.facts == [terminal])
        try f.assertFeedback(requests, failed: true)
        let reopened = try ToolExecutionFactLedger(persistenceURL: f.factsURL)
        #expect(reopened.pendingReceipts.isEmpty && reopened.facts == [terminal])
        if kind == "missing-parent" { #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path)) }
        if kind == "non-directory-parent" {
            #expect(try Data(contentsOf: target.deletingLastPathComponent()) == Data("owned sentinel".utf8))
        }
    }

    @Test("create_dirs defaults to true: missing parents are created, exact receipt/hash/artifact cannot leak to foreign session")
    func requestedParentCreationProducesBoundSuccess() async throws {
        let f = try Fixture(), target = f.allowed.appendingPathComponent("created/by-actual-tool.md")
        let (outcome, failure, requests) = try await f.run(target: target, createDirs: nil)
        #expect(failure == nil && outcome != nil)
        #expect(try Data(contentsOf: target) == Data("owned artifact0830\n".utf8))
        let terminal = try #require(f.facts.facts.first)
        #expect(terminal.status == .succeeded && terminal.executionIdentity == f.identity)
        #expect(f.facts.pendingReceipts.isEmpty && f.observation.facts == [terminal])
        let record = try #require(f.changes.records(sessionID: f.identity.turn.sessionID).first)
        #expect(record.producerReceiptID == terminal.receiptID && record.producerCompositeKey == terminal.compositeKey)
        let artifact = try #require(f.changes.artifactEvidence(diffID: record.diffID,
            sessionID: f.identity.turn.sessionID, fact: terminal))
        #expect(artifact.status == .succeeded && artifact.nextStep == .reviewDiff)
        #expect(artifact.outputSHA256 == SHA256.hash(data: Data("owned artifact0830\n".utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(f.changes.artifactEvidence(diffID: record.diffID, sessionID: "foreign-selected-session0830", fact: terminal) == nil)
        #expect(f.changes.records(sessionID: "foreign-selected-session0830").isEmpty)
        try f.assertFeedback(requests, failed: false)
        let reopened = try ToolExecutionFactLedger(persistenceURL: f.factsURL)
        #expect(reopened.facts == [terminal] && reopened.pendingReceipts.isEmpty)
    }

    @Test("a write that reached durable dispatchStarted remains UNKNOWN when the later atomic write fails")
    func alreadyStartedWriteCannotBecomeFailedTerminal() async throws {
        let f = try Fixture(), target = f.allowed.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("owned-sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let (outcome, failure, requests) = try await f.run(target: target)
        #expect(outcome == nil && failure?.contains("toolExecutionFactsUnavailable") == true)
        #expect(requests.count == 1 && f.facts.facts.isEmpty && f.observation.facts.isEmpty)
        let pending = try #require(f.facts.pendingReceipts.first)
        let evidence = try #require(f.facts.pendingFileWriteEvidence(for: pending))
        #expect(evidence.completedSHA256 == nil && evidence.targetPath == target.standardizedFileURL.path)
        #expect(f.changes.records(sessionID: f.identity.turn.sessionID).isEmpty)
        #expect(try Data(contentsOf: sentinel) == Data("unchanged".utf8))
        let reopened = try ToolExecutionFactLedger(persistenceURL: f.factsURL)
        #expect(reopened.facts.isEmpty && reopened.pendingReceipts == [pending])
        #expect(reopened.pendingFileWriteEvidence(for: pending) == evidence)
        #expect(!reopened.fileWriteWasNeverDispatched(pending))
    }
}
