import Foundation
import Testing
@testable import MinisCore

private final class RequestAssemblyBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedMainThread = false
    private var observedTimeout = false
    private var durableWriteEntered = false

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMainThread
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedTimeout
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func waitForRead(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 1) == .success
    }

    func blockAtRealAssembly() {
        lock.lock()
        observedMainThread = Thread.isMainThread
        lock.unlock()
        entered.signal()
        let expired = release.wait(timeout: .now() + 3) == .timedOut
        lock.lock()
        observedTimeout = expired
        lock.unlock()
    }

    func blockAtDurableWrite() {
        lock.lock()
        let shouldBlock = !durableWriteEntered
        durableWriteEntered = true
        lock.unlock()
        if shouldBlock { blockAtRealAssembly() }
    }
}

// OpenAIResponsesProvider（POST /v1/responses，真 Responses API 协议）离线测试。
// F-resp 第四步：URLProtocol mock 回归。
//
// ⚠️ 不复用 CloudVideoHTTPTests 的 MockURLProtocol（原计划复用、勿重定义）：
// 其 requestHandler/receivedRequests/lastRequestBody 是进程级静态状态，
// swift-testing 默认并行执行不同 suite，共享静态互相覆盖——实测全套回归时
// 本 suite 读到 CloudVideoHTTPTests 的请求体（断言 model 得到 "kling-v1"）
// 而失败；--no-parallel 则全绿。与仓库既有解法保持一致（JimengMockURLProtocol /
// KlingMockURLProtocol / CloudBackendMockURLProtocol 均为同一理由各自独立）：
// 本文件自带独立 ResponsesMockURLProtocol，API 与 MockURLProtocol 完全一致
// （requestHandler / receivedRequests / lastRequestBody / reset() /
//   jsonResponse() / makeSession()），仅静态状态隔离。
// 全程离线，不触真实 endpoint、不依赖任何真实 API key。
//
// ResponsesMockURLProtocol 持有静态 handler/计数器，本 suite 内必须串行执行。

// MARK: - Mock URLProtocol（独立静态状态，避免跨 suite 并行污染）

final class ResponsesMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// 请求 → (statusCode, body Data, headers) 的脚本化响应。
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    /// 收到的请求记录（供断言请求方法/体）。
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    /// 最近一次请求的 body（httpBody 可能被 URLSession 转为 stream，需手动读）。
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var requestStarted = false
    nonisolated(unsafe) static var responseChunks: [Data]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ResponsesMockURLProtocol.receivedRequests.append(request)
        ResponsesMockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        ResponsesMockURLProtocol.requestStarted = true
        guard let handler = ResponsesMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let responseChunks = Self.responseChunks {
                for chunk in responseChunks {
                    client?.urlProtocol(self, didLoad: chunk)
                }
            } else {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        receivedRequests = []
        lastRequestBody = nil
        requestStarted = false
        responseChunks = nil
    }

    /// 从请求中读取 body：优先 httpBody，否则读 httpBodyStream。
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func jsonResponse(_ json: [String: Any], status: Int = 200) -> (Int, Data, [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (status, data, ["Content-Type": "application/json"])
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponsesMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized)
struct OpenAIResponsesProviderTests {

    // MARK: - Helpers

    /// 测试用假 key（非任何真实密钥；构造与断言共用同一常量，避免字面量漂移）。
    private static let testAPIKey: String = "mock-responses-unit-token"

    /// 拼 SSE 字节流：每个事件一对「event: 名」+「data: JSON」行，事件间空行分隔。
    private static func sseBody(_ events: [(event: String, data: String)]) -> Data {
        var lines: [String] = []
        for pair in events {
            lines.append("event: " + pair.event)
            lines.append("data: " + pair.data)
            lines.append("")
        }
        guard !lines.isEmpty else { return Data() }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// 200 + text/event-stream 的 SSE mock 响应三元组。
    private static func sseResponse(_ events: [(event: String, data: String)]) -> (Int, Data, [String: String]) {
        (200, sseBody(events), ["Content-Type": "text/event-stream"])
    }

    private static func makeProvider() -> OpenAIResponsesProvider {
        // A fresh, instance-bound synthetic root per ordinary test provider.
        // Tests that verify reload/replay pass their own shared test root below.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-unit-" + UUID().uuidString, isDirectory: true)
        return makeProvider(checkpointDirectory: directory)
    }

    private static func makeProvider(checkpointDirectory: URL) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            apiKey: testAPIKey,
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: checkpointDirectory
        )
    }

    private enum DurableAttemptDiagnosticPhase: String {
        case begin
        case eventIteration = "event-iteration"
    }

    private static func recordDurableAttemptFailure(
        provider: OpenAIResponsesProvider,
        phase: DurableAttemptDiagnosticPhase
    ) {
        Issue.record("durable-attempt-phase=\(phase.rawValue); durable-attempt-prewrite-stage=\(provider.persistAttemptReceiptDiagnosticStage()); durable-attempt-write-stage=\(provider.durableAttemptWriteDiagnosticStage()); transport-started=\(ResponsesMockURLProtocol.requestStarted)")
    }

    private static func observingDurableAttemptFailure<T>(
        provider: OpenAIResponsesProvider,
        phase: DurableAttemptDiagnosticPhase,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            recordDurableAttemptFailure(provider: provider, phase: phase)
            throw error
        }
    }

    private static let userMessages: [LLMMessage] = [LLMMessage(role: .user, content: "你好")]

    private static func consumeSuccessfulStream(_ provider: OpenAIResponsesProvider) async throws {
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        for try await _ in stream {}
    }

    @Test func sseBodyTerminatesFinalEventWithBlankLine() {
        let body = Self.sseBody([(
            event: "response.created",
            data: #"{"type":"response.created"}"#
        )])
        #expect(Array(body.suffix(2)) == Array("\n\n".utf8))
    }

    // MARK: (a) 请求路径与请求体

    @Test func requestTargetsResponsesEndpointWithInputAndModel() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-request-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let okBody = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, okBody, ["Content-Type": "application/json"])
        }
        let provider = Self.makeProvider(checkpointDirectory: directory)
        _ = try await provider.sendMessage(
            messages: Self.userMessages,
            systemPrompt: "你是助手",
            maxTokens: 256,
            temperature: 0.2
        )

        let sent: URLRequest = try #require(ResponsesMockURLProtocol.receivedRequests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/v1/responses")
        #expect(sent.url?.absoluteString == "https://mock.test/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.testAPIKey)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body: Data = try #require(ResponsesMockURLProtocol.lastRequestBody)
        let json: [String: Any] = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_output_tokens"] as? Int == 256)
        #expect(json["instructions"] as? String == "你是助手")
        let input: [[String: Any]] = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["role"] as? String == "user")
        let content: [[String: Any]] = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "input_text")
        #expect(content.first?["text"] as? String == "你好")
    }

    @Test @MainActor
    func realRequestAssemblyDoesNotHoldMainActor() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-assembly-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let okBody = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, okBody, ["Content-Type": "application/json"])
        }
        let gate = RequestAssemblyBarrier()
        let provider = OpenAIResponsesProvider(
            apiKey: Self.testAPIKey,
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: directory,
            requestAssemblyProbe: { gate.blockAtRealAssembly() }
        )
        let input = String(repeating: "x", count: 64_000)
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: input)],
                systemPrompt: nil,
                maxTokens: 64,
                temperature: nil
            )
        }
        defer { gate.release.signal() }

        let entered = await Task.detached {
            gate.waitUntilEntered()
        }.value
        guard entered else {
            pending.cancel()
            Issue.record("the production request assembly point was not reached")
            return
        }
        // The real encoder is blocked at its entry. A MainActor task must
        // still run before the worker is released; the barrier's bounded
        // fallback prevents an actual main-thread regression from hanging CI.
        let heartbeat = Task { @MainActor in true }
        #expect(await heartbeat.value)
        #expect(!gate.ranOnMainThread)
        #expect(!gate.timedOut)
        gate.release.signal()
        _ = try await pending.value

        let body = try #require(ResponsesMockURLProtocol.lastRequestBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == LLMModel.gpt4oMini.id)
        #expect(json["stream"] as? Bool == false)
        #expect(body.count > 64_000)
    }

    @Test @MainActor
    func durableWriteDoesNotBlockPublicModelRead() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-durable-lock-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            ResponsesMockURLProtocol.jsonResponse([
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]]
            ])
        }
        let gate = RequestAssemblyBarrier()
        let provider = OpenAIResponsesProvider(
            apiKey: Self.testAPIKey, model: .gpt4oMini,
            customBaseURL: "https://mock.test", appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: directory,
            durableWriteProbe: { gate.blockAtDurableWrite() }
        )
        let pending = Task.detached {
            try await provider.sendMessage(
                messages: Self.userMessages, systemPrompt: nil,
                maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            Issue.record("the durable write point was not reached")
            return
        }
        let readFinished = DispatchSemaphore(value: 0)
        let readModel = Task.detached {
            let id = provider.model.id
            readFinished.signal()
            return id
        }
        let completedWhileHeld = await Task.detached {
            gate.waitForRead(readFinished)
        }.value
        gate.release.signal()
        #expect(completedWhileHeld)
        #expect(await readModel.value == LLMModel.gpt4oMini.id)
        #expect(!gate.ranOnMainThread)
        #expect(!gate.timedOut)
        _ = try await pending.value
    }

    @Test @MainActor
    func modelRebindDuringRequestAssemblyCannotDispatchFrozenAttempt() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-assembly-rebind-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            ResponsesMockURLProtocol.jsonResponse(["status": "completed", "output": []])
        }
        let gate = RequestAssemblyBarrier()
        let provider = OpenAIResponsesProvider(
            apiKey: Self.testAPIKey, model: .gpt4oMini,
            customBaseURL: "https://mock.test", appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: directory,
            requestAssemblyProbe: { gate.blockAtRealAssembly() }
        )
        let pending = Task {
            try await provider.sendMessage(
                messages: Self.userMessages, systemPrompt: nil,
                maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            Issue.record("the production request assembly point was not reached")
            return
        }
        #expect(!gate.ranOnMainThread)
        #expect(!gate.timedOut)
        provider.model = LLMModel(
            id: "rebound-model", displayName: "Rebound", provider: "OpenAI Responses"
        )
        gate.release.signal()
        do {
            _ = try await pending.value
            Issue.record("a superseded request reached transport")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected a cancelled superseded attempt")
                return
            }
        }
        #expect(!ResponsesMockURLProtocol.requestStarted)
    }

    @Test @MainActor
    func routeRebindDuringRequestAssemblyKeepsFrozenWireConfiguration() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-route-snapshot-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            ResponsesMockURLProtocol.jsonResponse([
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [["type": "output_text", "text": "ok"]]
                ]]
            ])
        }
        let gate = RequestAssemblyBarrier()
        let provider = OpenAIResponsesProvider(
            apiKey: Self.testAPIKey, model: .gpt4oMini,
            customBaseURL: "https://mock.test", appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "OpenAI Responses",
            attemptCheckpointDirectory: directory,
            requestAssemblyProbe: { gate.blockAtRealAssembly() }
        )
        provider.extraHeaders = ["X-Route": "before"]
        provider.runtimeConfigurationMaterial = "factory"
        let pending = Task {
            try await provider.sendMessage(
                messages: Self.userMessages, systemPrompt: nil,
                maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            Issue.record("the production request assembly point was not reached")
            return
        }
        provider.customBaseURL = "https://later.test"
        provider.appendV1Suffix = false
        provider.extraHeaders = ["X-Route": "after"]
        #expect(provider.runtimeConfigurationMaterial == "https://later.test|append-v1=false")
        gate.release.signal()
        _ = try await pending.value

        let request = try #require(ResponsesMockURLProtocol.receivedRequests.first)
        #expect(request.url?.absoluteString == "https://mock.test/v1/responses")
        #expect(request.value(forHTTPHeaderField: "X-Route") == "before")
    }

    @Test func streamingRejectsConfusableOrOversizedRequestIdentityBeforeTransport() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidIdentities: [(String, String)] = [
            ("OpenAI \u{0430}esponses", "gpt-4o-mini"),
            ("OpenAI Responses", "gpt-\u{0000}mini"),
            ("OpenAI Responses", String(repeating: "m", count: 257)),
        ]
        for (providerName, modelID) in invalidIdentities {
            ResponsesMockURLProtocol.requestHandler = { _ in
                Issue.record("invalid request identity opened transport")
                return Self.sseResponse([
                    (event: "response.completed",
                     data: #"{"type":"response.completed","response":{"id":"resp_invalid_identity","status":"completed"}}"#)
                ])
            }
            let provider = OpenAIResponsesProvider(
                apiKey: Self.testAPIKey,
                model: LLMModel(id: modelID, displayName: modelID, provider: "OpenAI Responses"),
                customBaseURL: "https://mock.test",
                appendV1Suffix: true,
                session: ResponsesMockURLProtocol.makeSession(),
                providerName: providerName,
                attemptCheckpointDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("responses-invalid-identity-" + UUID().uuidString, isDirectory: true)
            )
            do {
                _ = try await provider.streamMessage(
                    messages: Self.userMessages,
                    systemPrompt: nil,
                    maxTokens: 100,
                    temperature: nil
                )
                Issue.record("expected invalid request identity to fail before transport")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected typed identity error, got \(error)")
                    continue
                }
                #expect(message == "Invalid provider request identity")
            }
            #expect(ResponsesMockURLProtocol.requestStarted == false)
            ResponsesMockURLProtocol.reset()
        }
    }

    @Test func attemptGenerationIsMonotonicAndFailsClosedAtUInt64Max() {
        do {
            let next = try OpenAIResponsesProvider.incrementAttemptGeneration(after: 41)
            #expect(next == 42)
        } catch {
            Issue.record("expected attempt generation to advance, got \(error)")
        }

        do {
            _ = try OpenAIResponsesProvider.incrementAttemptGeneration(after: UInt64.max)
            Issue.record("expected attempt generation overflow to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed attempt generation error, got \(error)")
                return
            }
            #expect(message == "Responses API attempt generation exhausted")
        } catch {
            Issue.record("expected typed attempt generation error, got \(error)")
        }
    }

    @Test func streamingRejectsNonContiguousDurableAttemptCheckpointBeforeTransport() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let providerID = "OpenAI Responses"
        let modelID = "gpt-4o-mini"
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-attempt-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: providerID,
            modelID: modelID,
            directoryOverride: directory
        ))

        let invalidCheckpoints: [(UInt64, UInt64)] = [(8, 9), (11, 3)]
        for (generation, previousGeneration) in invalidCheckpoints {
            let invalid = Data("{\"providerID\":\"\(providerID)\",\"modelID\":\"\(modelID)\",\"generation\":\(generation),\"previousGeneration\":\(previousGeneration)}".utf8)
            try invalid.write(to: checkpointURL)
            ResponsesMockURLProtocol.reset()
            ResponsesMockURLProtocol.requestHandler = { _ in
                Issue.record("invalid durable checkpoint opened transport")
                return Self.sseResponse([
                    (event: "response.completed",
                     data: #"{"type":"response.completed","response":{"id":"resp_checkpoint","status":"completed"}}"#)
                ])
            }
            let provider = Self.makeProvider(checkpointDirectory: directory)
            do {
                _ = try await provider.streamMessage(
                    messages: Self.userMessages,
                    systemPrompt: nil,
                    maxTokens: 100,
                    temperature: nil
                )
                Issue.record("expected invalid durable checkpoint to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected typed durable checkpoint error, got \(error)")
                    continue
                }
                #expect(message == "Invalid durable Responses attempt checkpoint")
            }
            #expect(ResponsesMockURLProtocol.requestStarted == false)
            #expect(try Data(contentsOf: checkpointURL) == invalid)
        }

        try fileManager.removeItem(at: checkpointURL)
        ResponsesMockURLProtocol.reset()
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_checkpoint","status":"completed"}}"#)
            ])
        }
        let firstProvider = Self.makeProvider(checkpointDirectory: directory)
        let firstStream = try await Self.observingDurableAttemptFailure(
            provider: firstProvider,
            phase: .begin
        ) {
            try await firstProvider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }
        try await Self.observingDurableAttemptFailure(
            provider: firstProvider,
            phase: .eventIteration
        ) {
            for try await _ in firstStream {}
        }
        let firstBytes = try Data(contentsOf: checkpointURL)
        let secondProvider = Self.makeProvider(checkpointDirectory: directory)
        let secondStream = try await Self.observingDurableAttemptFailure(
            provider: secondProvider,
            phase: .begin
        ) {
            try await secondProvider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }
        try await Self.observingDurableAttemptFailure(
            provider: secondProvider,
            phase: .eventIteration
        ) {
            for try await _ in secondStream {}
        }
        let secondBytes = try Data(contentsOf: checkpointURL)
        #expect(firstBytes != secondBytes)
        #expect(try JSONSerialization.jsonObject(with: secondBytes) is [String: Any])
    }

    @Test func streamingRejectsSymlinkedAttemptCheckpointWithoutTouchingTarget() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-symlink-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let targetURL = directory.appendingPathComponent("target.bytes")
        let targetBytes = Data("untouched".utf8)
        try targetBytes.write(to: targetURL)
        try fileManager.createSymbolicLink(at: checkpointURL, withDestinationURL: targetURL)
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("symlinked durable checkpoint opened transport")
            return Self.sseResponse([])
        }
        let provider = Self.makeProvider(checkpointDirectory: directory)
        do {
            _ = try await provider.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            Issue.record("expected symlinked checkpoint to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed symlink checkpoint error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: targetURL) == targetBytes)
    }

    @Test func streamingRejectsReceiptReplayedAcrossProviderIdentity() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-replay-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_replay","status":"completed"}}"#)
            ])
        }
        let source = Self.makeProvider(checkpointDirectory: directory)
        let sourceStream = try await Self.observingDurableAttemptFailure(
            provider: source,
            phase: .begin
        ) {
            try await source.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
        }
        try await Self.observingDurableAttemptFailure(
            provider: source,
            phase: .eventIteration
        ) {
            for try await _ in sourceStream {}
        }
        let sourceURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let replayURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "Replay Provider", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let sourceBytes = try Data(contentsOf: sourceURL)
        try sourceBytes.write(to: replayURL)
        ResponsesMockURLProtocol.reset()
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("cross-provider receipt replay opened transport")
            return Self.sseResponse([])
        }
        let replay = OpenAIResponsesProvider(
            apiKey: Self.testAPIKey,
            model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            appendV1Suffix: true,
            session: ResponsesMockURLProtocol.makeSession(),
            providerName: "Replay Provider",
            attemptCheckpointDirectory: directory
        )
        do {
            _ = try await replay.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            Issue.record("expected cross-provider receipt replay to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed replay error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: replayURL) == sourceBytes)
    }

    @Test func preparedReceiptRecoveryAdvancesAttemptBeforeNextRequest() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-prepared-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        var requestCount = 0
        ResponsesMockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return requestCount == 1
                ? Self.sseResponse([
                    (event: "response.output_text.delta",
                     data: #"{"type":"response.output_text.delta","delta":"partial"}"#)
                ])
                : Self.sseResponse([
                    (event: "response.completed",
                     data: #"{"type":"response.completed","response":{"id":"resp_recovered","status":"completed"}}"#)
                ])
        }
        let first = Self.makeProvider(checkpointDirectory: directory)
        let firstStream = try await Self.observingDurableAttemptFailure(
            provider: first,
            phase: .begin
        ) {
            try await first.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
        }
        do {
            for try await _ in firstStream {}
            Issue.record("expected EOF after prepared SSE event")
        } catch {
            // The request was intentionally interrupted before terminal commit.
        }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let prepared = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: checkpointURL)
        ) as? [String: Any])
        #expect(prepared["phase"] as? String == "prepared")
        let second = Self.makeProvider(checkpointDirectory: directory)
        let secondStream = try await Self.observingDurableAttemptFailure(
            provider: second,
            phase: .begin
        ) {
            try await second.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
        }
        try await Self.observingDurableAttemptFailure(
            provider: second,
            phase: .eventIteration
        ) {
            for try await _ in secondStream {}
        }
        let committed = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: checkpointURL)
        ) as? [String: Any])
        #expect(committed["phase"] as? String == "committed")
        let preparedGeneration = (prepared["generation"] as? Int) ?? 0
        let committedGeneration = (committed["generation"] as? Int) ?? 0
        #expect(committedGeneration > preparedGeneration)
        #expect(committed["previousDigest"] as? String == prepared["requestDigest"] as? String)
        #expect(requestCount == 2)
    }

    @Test func strictReceiptDecoderRejectsDuplicateAndConfusableKeysWithoutRewrite() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-strict-json-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let payloads = [
            Data(#"{"providerID":"OpenAI Responses","providerID":"OpenAI Responses","modelID":"gpt-4o-mini","generation":1}"#.utf8),
            Data(#"{"providerID":"OpenAI Responses","mоdelID":"gpt-4o-mini","generation":1}"#.utf8),
        ]
        for payload in payloads {
            try payload.write(to: checkpointURL)
            ResponsesMockURLProtocol.reset()
            ResponsesMockURLProtocol.requestHandler = { _ in
                Issue.record("non-canonical receipt opened transport")
                return Self.sseResponse([])
            }
            let provider = Self.makeProvider(checkpointDirectory: directory)
            do {
                _ = try await provider.streamMessage(
                    messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
                )
                Issue.record("expected non-canonical receipt to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected typed strict receipt error, got \(error)")
                    continue
                }
                #expect(message == "Invalid durable Responses attempt checkpoint")
            }
            #expect(ResponsesMockURLProtocol.requestStarted == false)
            #expect(try Data(contentsOf: checkpointURL) == payload)
        }
    }

    @Test func receiptRecoveryRejectsUnreadablePendingForkBeforeTransport() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-pending-fork-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_fork","status":"completed"}}"#)
            ])
        }
        let source = Self.makeProvider(checkpointDirectory: directory)
        let stream = try await source.streamMessage(
            messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
        )
        for try await _ in stream {}
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let original = try Data(contentsOf: checkpointURL)
        let pendingURL = checkpointURL.appendingPathExtension("pending")
        let pendingBytes = Data("truncated pending candidate".utf8)
        try pendingBytes.write(to: pendingURL)
        ResponsesMockURLProtocol.reset()
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("forked pending receipt opened transport")
            return Self.sseResponse([])
        }
        let recovered = Self.makeProvider(checkpointDirectory: directory)
        do {
            _ = try await recovered.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            Issue.record("expected unreadable pending fork to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed pending fork error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: checkpointURL) == original)
        #expect(try Data(contentsOf: pendingURL) == pendingBytes)
    }

    @Test func receiptRecoveryRejectsMissingMainAndUnknownTransactionMarker() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-marker-fence-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let pendingURL = checkpointURL.appendingPathExtension("pending")
        let pendingBytes = Data("prepared-without-main".utf8)
        try pendingBytes.write(to: pendingURL)
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("missing main receipt opened transport")
            return Self.sseResponse([])
        }
        let missingMain = Self.makeProvider(checkpointDirectory: directory)
        do {
            _ = try await missingMain.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            Issue.record("expected missing main receipt to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed missing-main error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: pendingURL) == pendingBytes)

        try fileManager.removeItem(at: pendingURL)
        let unknownMarker = Data(#"{"providerID":"OpenAI Responses","modelID":"gpt-4o-mini","generation":1,"previousGeneration":0,"previousDigest":null,"modelGeneration":0,"requestID":"00000000-0000-0000-0000-000000000001","requestDigest":"0000000000000000000000000000000000000000000000000000000000000000","transactionID":"00000000-0000-0000-0000-000000000002","phase":"unknown","responseID":null,"lastEventID":null,"retryMilliseconds":null,"fileDevice":1,"fileInode":1}"#.utf8)
        try unknownMarker.write(to: checkpointURL)
        ResponsesMockURLProtocol.reset()
        let unknown = Self.makeProvider(checkpointDirectory: directory)
        do {
            _ = try await unknown.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            Issue.record("expected unknown transaction marker to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed marker error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: checkpointURL) == unknownMarker)
    }

    @Test func receiptRecoveryRejectsCrossSchemaAndScopeReplayBeforeTransport() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-scope-fence-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_scope","status":"completed"}}"#)
            ])
        }
        let source = Self.makeProvider(checkpointDirectory: directory)
        let sourceStream = try await source.streamMessage(
            messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
        )
        for try await _ in sourceStream {}
        let original = try String(contentsOf: checkpointURL, encoding: .utf8)
        let zeroDigest = String(repeating: "0", count: 64)
        func replacingDigest(_ field: String) -> String {
            let marker = "\"\(field)\":\""
            guard let markerRange = original.range(of: marker) else { return original }
            let valueStart = markerRange.upperBound
            guard let valueEnd = original.index(valueStart, offsetBy: 64, limitedBy: original.endIndex) else {
                return original
            }
            return String(original[..<valueStart]) + zeroDigest + String(original[valueEnd...])
        }
        let tamperedRecords = [
            original.replacingOccurrences(of: "responses-sse-v1", with: "responses-json-v1"),
            replacingDigest("requestScopeDigest"),
            replacingDigest("payloadDigest"),
            replacingDigest("responseBodyDigest"),
        ]
        for tampered in tamperedRecords {
            try Data(tampered.utf8).write(to: checkpointURL)
            ResponsesMockURLProtocol.reset()
            ResponsesMockURLProtocol.requestHandler = { _ in
                Issue.record("cross-scope receipt opened transport")
                return Self.sseResponse([])
            }
            let replay = Self.makeProvider(checkpointDirectory: directory)
            do {
                _ = try await replay.streamMessage(
                    messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
                )
                Issue.record("expected cross-scope receipt to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected typed scope error, got \(error)")
                    continue
                }
                #expect(message == "Invalid durable Responses attempt checkpoint")
            }
            #expect(ResponsesMockURLProtocol.requestStarted == false)
            #expect(try Data(contentsOf: checkpointURL) == Data(tampered.utf8))
        }
    }

    @Test func receiptHistoryRollsOverWithoutBreakingReload() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-history-rollover-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        var requestCount = 0
        ResponsesMockURLProtocol.requestHandler = { _ in
            requestCount += 1
            if requestCount == 9 {
                return Self.sseResponse([
                    (event: "response.output_text.delta",
                     data: #"{"type":"response.output_text.delta","delta":"prepared"}"#)
                ])
            }
            return Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_history","status":"completed"}}"#)
            ])
        }
        for attempt in 0..<9 {
            let provider = Self.makeProvider(checkpointDirectory: directory)
            let stream = try await provider.streamMessage(
                messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
            )
            if attempt == 8 {
                do {
                    for try await _ in stream {}
                    Issue.record("expected prepared compaction attempt to end at EOF")
                } catch {
                    // The ninth attempt intentionally leaves a prepared receipt.
                }
            } else {
                for try await _ in stream {}
            }
            if attempt == 0 {
                let firstURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
                    providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
                    directoryOverride: directory
                ))
                let firstRecord = try #require(try JSONSerialization.jsonObject(
                    with: Data(contentsOf: firstURL)
                ) as? [String: Any])
                #expect((firstRecord["generation"] as? Int) == 1)
                #expect((firstRecord["receiptHistory"] as? [[String: Any]])?.isEmpty == true)
                #expect((firstRecord["historyDigest"] as? String)?.utf8.count == 64)
                #expect(firstRecord["historyPredecessorDigest"] == nil)
            }
        }
        let preparedURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let preparedBytes = try Data(contentsOf: preparedURL)
        let prepared = try #require(try JSONSerialization.jsonObject(
            with: preparedBytes
        ) as? [String: Any])
        #expect((prepared["phase"] as? String) == "prepared")
        #expect((prepared["generation"] as? Int) == 9)
        #expect((prepared["receiptHistory"] as? [[String: Any]])?.count == 8)
        #expect(prepared["compactionTransactionID"] == nil)

        let recovered = Self.makeProvider(checkpointDirectory: directory)
        let recoveredStream = try await recovered.streamMessage(
            messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
        )
        for try await _ in recoveredStream {}
        #expect(requestCount == 10)

        let checkpointURL = preparedURL
        let originalBytes = try Data(contentsOf: checkpointURL)
        let originalText = try #require(String(data: originalBytes, encoding: .utf8))
        let record = try #require(try JSONSerialization.jsonObject(
            with: originalBytes
        ) as? [String: Any])
        let history = try #require(record["receiptHistory"] as? [[String: Any]])
        let historyDigest = try #require(record["historyDigest"] as? String)
        let payloadDigest = try #require(record["payloadDigest"] as? String)
        let historyPredecessorDigest = try #require(record["historyPredecessorDigest"] as? String)
        let compactionID = try #require(record["compactionTransactionID"] as? String)
        let checkpointDigest = try #require(record["checkpointDigest"] as? String)
        let epochPredecessorDigest = try #require(record["epochPredecessorDigest"] as? String)
        let segmentManifest = try #require(record["segmentManifest"] as? [[String: Any]])
        let segmentManifestRoot = try #require(record["segmentManifestRoot"] as? String)
        let segmentManifestReadbackSeal = try #require(record["segmentManifestReadbackSeal"] as? String)
        let segmentManifestPredecessorRoot = try #require(record["segmentManifestPredecessorRoot"] as? String)
        let segmentGenerationCAS = try #require(record["segmentGenerationCAS"] as? [Int])
        let cleanupTombstone = try #require(record["cleanupTombstone"] as? [String: Any])
        let cleanupTombstoneSeal = try #require(record["cleanupTombstoneSeal"] as? String)
        let firstHistoryTransactionID = try #require(history.first?["transactionID"] as? String)
        #expect((record["generation"] as? Int) == 10)
        #expect(history.count == 8)
        #expect((history.first?["generation"] as? Int) == 2)
        #expect((history.last?["generation"] as? Int) == 9)
        #expect(historyDigest.utf8.count == 64)
        #expect(checkpointDigest.utf8.count == 64)
        #expect(epochPredecessorDigest == history.last?["checkpointDigest"] as? String)
        #expect(segmentManifest.count == 9)
        #expect((segmentManifest.first?["generation"] as? Int) == 2)
        #expect((segmentManifest.last?["generation"] as? Int) == 10)
        #expect(segmentManifestRoot.utf8.count == 64)
        #expect(segmentManifestReadbackSeal.utf8.count == 64)
        #expect(segmentManifestPredecessorRoot.utf8.count == 64)
        #expect(segmentGenerationCAS == segmentManifest.compactMap { $0["generation"] as? Int })
        #expect((cleanupTombstone["generation"] as? Int) == 1)
        #expect((cleanupTombstone["predecessorCheckpointDigest"] as? String) == epochPredecessorDigest)
        #expect((cleanupTombstone["predecessorHistoryDigest"] as? String) == historyPredecessorDigest)
        #expect((cleanupTombstone["predecessorManifestRoot"] as? String) == segmentManifestPredecessorRoot)
        #expect((cleanupTombstone["successorManifestRoot"] as? String) == segmentManifestRoot)
        #expect((cleanupTombstone["successorHistoryDigest"] as? String) == historyDigest)
        #expect((cleanupTombstone["successorPayloadDigest"] as? String) == payloadDigest)
        #expect(cleanupTombstoneSeal.utf8.count == 64)
        #expect(record["cleanupEpochPredecessorSeal"] == nil)
        #expect(compactionID != firstHistoryTransactionID)

        let nextProvider = Self.makeProvider(checkpointDirectory: directory)
        let nextStream = try await nextProvider.streamMessage(
            messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
        )
        for try await _ in nextStream {}
        let nextBytes = try Data(contentsOf: checkpointURL)
        let nextRecord = try #require(try JSONSerialization.jsonObject(
            with: nextBytes
        ) as? [String: Any])
        let nextHistory = try #require(nextRecord["receiptHistory"] as? [[String: Any]])
        let nextCleanupTombstone = try #require(nextRecord["cleanupTombstone"] as? [String: Any])
        let nextManifestRoot = try #require(nextRecord["segmentManifestRoot"] as? String)
        let nextHistoryDigest = try #require(nextRecord["historyDigest"] as? String)
        let nextPayloadDigest = try #require(nextRecord["payloadDigest"] as? String)
        let nextHistoryPredecessorDigest = try #require(nextRecord["historyPredecessorDigest"] as? String)
        #expect((nextRecord["generation"] as? Int) == 11)
        #expect((nextHistory.first?["generation"] as? Int) == 3)
        #expect((nextCleanupTombstone["generation"] as? Int) == 2)
        #expect((nextCleanupTombstone["predecessorCheckpointDigest"] as? String) == checkpointDigest)
        #expect((nextCleanupTombstone["predecessorHistoryDigest"] as? String) == nextHistoryPredecessorDigest)
        #expect((nextCleanupTombstone["successorManifestRoot"] as? String) == nextManifestRoot)
        #expect((nextCleanupTombstone["successorHistoryDigest"] as? String) == nextHistoryDigest)
        #expect((nextCleanupTombstone["successorPayloadDigest"] as? String) == nextPayloadDigest)
        #expect((nextRecord["cleanupEpochPredecessorSeal"] as? String) == cleanupTombstoneSeal)
        try originalBytes.write(to: checkpointURL)

        func replacingStringField(_ field: String, with replacement: String) -> String {
            let marker = "\"\(field)\":\""
            guard let markerRange = originalText.range(of: marker),
                  let valueEnd = originalText[markerRange.upperBound...].firstIndex(of: "\"") else {
                return originalText
            }
            return originalText.replacingCharacters(in: markerRange.upperBound..<valueEnd, with: replacement)
        }
        func tamperingManifest(_ edit: ([[String: Any]]) -> [[String: Any]]) throws -> String {
            var object = record
            let manifest = try #require(object["segmentManifest"] as? [[String: Any]])
            object["segmentManifest"] = edit(manifest)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        var reordered = segmentManifest
        reordered.swapAt(0, 1)
        var missing = segmentManifest
        missing.removeLast()
        var extra = segmentManifest
        extra.append(try #require(segmentManifest.first))
        func tamperingGenerationCAS() throws -> String {
            var object = record
            var cas = segmentGenerationCAS
            cas[0] += 1
            object["segmentGenerationCAS"] = cas
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstonePredecessorRoot() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["predecessorManifestRoot"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstoneSuccessorRoot() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["successorManifestRoot"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstoneSuccessorHistory() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["successorHistoryDigest"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstonePredecessorCheckpoint() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["predecessorCheckpointDigest"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstonePredecessorHistory() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["predecessorHistoryDigest"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func tamperingTombstoneSuccessorPayload() throws -> String {
            var object = record
            var tombstone = try #require(object["cleanupTombstone"] as? [String: Any])
            tombstone["successorPayloadDigest"] = String(repeating: "0", count: 64)
            object["cleanupTombstone"] = tombstone
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func addingStringField(_ field: String, value: String) throws -> String {
            var object = record
            object[field] = value
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        func removingCompactionTransactionID() throws -> String {
            var object = record
            object.removeValue(forKey: "compactionTransactionID")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        let tamperedRecords = [
            replacingStringField("historyDigest", with: String(repeating: "0", count: 64)),
            replacingStringField("checkpointDigest", with: String(repeating: "0", count: 64)),
            replacingStringField("segmentManifestRoot", with: String(repeating: "0", count: 64)),
            replacingStringField("segmentManifestPredecessorRoot", with: String(repeating: "0", count: 64)),
            replacingStringField("segmentManifestReadbackSeal", with: String(repeating: "0", count: 64)),
            replacingStringField("cleanupTombstoneSeal", with: String(repeating: "0", count: 64)),
            try addingStringField("cleanupEpochPredecessorSeal", value: String(repeating: "0", count: 64)),
            try removingCompactionTransactionID(),
            replacingStringField("compactionTransactionID", with: firstHistoryTransactionID),
            try tamperingManifest { _ in reordered },
            try tamperingManifest { _ in missing },
            try tamperingManifest { _ in extra },
            try tamperingGenerationCAS(),
            try tamperingTombstonePredecessorRoot(),
            try tamperingTombstoneSuccessorRoot(),
            try tamperingTombstoneSuccessorHistory(),
            try tamperingTombstonePredecessorCheckpoint(),
            try tamperingTombstonePredecessorHistory(),
            try tamperingTombstoneSuccessorPayload()
        ]
        for tampered in tamperedRecords {
            let tamperedBytes = Data(tampered.utf8)
            try tamperedBytes.write(to: checkpointURL)
            ResponsesMockURLProtocol.reset()
            ResponsesMockURLProtocol.requestHandler = { _ in
                Issue.record("invalid compaction receipt opened transport")
                return Self.sseResponse([])
            }
            let provider = Self.makeProvider(checkpointDirectory: directory)
            do {
                _ = try await provider.streamMessage(
                    messages: Self.userMessages, systemPrompt: nil, maxTokens: 100, temperature: nil
                )
                Issue.record("expected invalid compaction receipt to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected typed compaction receipt error, got \(error)")
                    continue
                }
                #expect(message == "Invalid durable Responses attempt checkpoint")
            }
            #expect(ResponsesMockURLProtocol.requestStarted == false)
            #expect(try Data(contentsOf: checkpointURL) == tamperedBytes)
        }
    }

    // MARK: (b) 非流式响应解析（output[].message.content[].output_text + usage）

    @Test func nonStreamingParsesTextAndUsage() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"""
        {"id":"resp_1","status":"completed","output":[
        {"type":"reasoning","id":"rs_1"},
        {"type":"message","id":"msg_1","role":"assistant","content":[
        {"type":"output_text","text":"Hello, "},
        {"type":"output_text","text":"world!"}]}],
        "usage":{"input_tokens":12,"output_tokens":7,"input_tokens_details":{"cached_tokens":4}}}
        """#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let response: LLMResponse = try await provider.sendMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        #expect(response.text == "Hello, world!")
        #expect(response.stopReason == "completed")
        #expect(response.usage == LLMUsage(inputTokens: 12, outputTokens: 7,
                                           cacheCreationInputTokens: nil, cacheReadInputTokens: 4, cacheHitInputTokens: 12))
    }

    @Test func nonStreamingRejectsNonTerminalStatusWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_in_progress","status":"in_progress","output":[{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected non-terminal Responses status to fail closed")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingFailedStatusReportsTypedProviderError() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_failed","status":"failed","error":{"code":"server_error","message":"fixture response failure"}}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected failed Responses status to fail without projection")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed provider error, got \(error)")
                return
            }
            #expect(message == "Responses API response error")
            #expect(error.errorDescription?.contains("fixture response failure") == false)
            #expect(error.technicalDetail.contains("fixture response failure") == false)
        }
    }

    @Test func nonStreamingRejectsMalformedErrorWithoutPartialProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_malformed_error","status":"completed","error":{"code":"server_error"},"output":[{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected malformed response error to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsMalformedMessagePartWithoutPartialProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_malformed_part","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":17}]},{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected malformed message part to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsMessageWithoutContentWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_missing_content","status":"completed","output":[{"type":"message"},{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected message without content to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsMalformedFunctionCallWithoutPartialProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_malformed_call","status":"completed","output":[{"type":"function_call","name":17,"arguments":"{}"},{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected malformed function call to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsNonObjectFunctionArgumentsWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_array_arguments","status":"completed","output":[{"type":"function_call","name":"lookup","arguments":[]},{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected non-object function arguments to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsIdentityFreeFunctionCallWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"id":"resp_identity_free_call","status":"completed","output":[{"type":"function_call","name":"lookup","arguments":"{}"},{"type":"message","content":[{"type":"output_text","text":"must not project"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected identity-free function call to fail without projection")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsOversizedResponseBody() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1), ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected oversized non-streaming response to fail closed")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRejectsDuplicateOutputIdentity() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"status":"completed","output":[{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"one"}]},{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"two"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected duplicate non-streaming output identity to fail closed")
        } catch let error as LLMError {
            guard case .decodingError = error else {
                Issue.record("expected decoding error, got \(error)")
                return
            }
        }
    }

    @Test func nonStreamingRedactsServerErrorPayload() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(#"{"error":{"code":"auth","message":"Authorization: Bearer fixture-nonstream-secret"}}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "application/json"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected server error to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API response error")
            #expect(error.errorDescription?.contains("fixture-nonstream-secret") == false)
            #expect(error.technicalDetail.contains("fixture-nonstream-secret") == false)
        }
    }

    @Test func lateNonStreamingResponseAfterModelRebindFailsClosed() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let provider = Self.makeProvider()
        let body = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"late"}]}]}"#.utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            provider.model = LLMModel(id: "rebound-model", displayName: "Rebound", provider: "OpenAI Responses")
            return (200, body, ["Content-Type": "application/json"])
        }
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected stale non-streaming response to fail closed")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancellation for stale response, got \(error)")
                return
            }
        }
    }

    // MARK: (c) 流式 delta 累积（created → 多个 delta → completed）

    @Test func streamingAccumulatesDeltasInOrder() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
                (event: "response.in_progress",
                 data: #"{"type":"response.in_progress"}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"你好"}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","delta":"，世界"}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","delta":"！"}"#),
                (event: "response.output_text.done",
                 data: #"{"type":"response.output_text.done","text":"你好，世界！"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":7,"output_tokens":11}}}"#),
            ])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await Self.observingDurableAttemptFailure(
            provider: provider,
            phase: .begin
        ) {
            try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }

        var sawStarted = false
        var textDeltas: [String] = []
        var usage: LLMUsage?
        var finishedStopReason: String?
        var finishedCount = 0
        try await Self.observingDurableAttemptFailure(
            provider: provider,
            phase: .eventIteration
        ) {
            for try await chunk in stream {
                switch chunk {
                case .started:
                    sawStarted = true
                case .text(let delta):
                    textDeltas.append(delta)
                case .usage(let parsed):
                    usage = parsed
                case .finished(let reason):
                    finishedStopReason = reason
                    finishedCount += 1
                }
            }
        }

        #expect(sawStarted)
        #expect(textDeltas == ["你好", "，世界", "！"])
        #expect(textDeltas.joined() == "你好，世界！")
        #expect(usage == LLMUsage(inputTokens: 7, outputTokens: 11, cacheHitInputTokens: 7))
        #expect(finishedStopReason == "completed")
        #expect(finishedCount == 1)
    }

    @Test func streamingDoesNotProjectDeltaWhenReceiptCommitFails() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-delta-commit-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses",
            modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let body = Data(("event: response.output_text.delta\n" +
                         "data: {\"type\":\"response.output_text.delta\",\"delta\":\"must not project\"}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            try? Data("not a durable receipt".utf8).write(to: checkpointURL)
            return (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider(checkpointDirectory: directory)
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected receipt commit failure")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingTerminalWinsOverBufferedLateEvents() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1"}}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#),
                // These events are deliberately buffered behind the terminal
                // event and must never be projected to the consumer.
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","delta":"late"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var lateText = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): lateText += delta
            case .finished: finishedCount += 1
            case .started, .usage: break
            }
        }
        #expect(lateText.isEmpty)
        #expect(finishedCount == 1)
    }

    @Test func streamingRejectsInterleavedResponseIdentityWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","response_id":"resp_2","delta":"wrong response"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        var finishedCount = 0
        do {
            for try await chunk in stream {
                switch chunk {
                case .text(let delta): projectedText += delta
                case .finished: finishedCount += 1
                case .started, .usage: break
                }
            }
            Issue.record("expected interleaved response identity to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsMalformedTextDeltaWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_delta","status":"in_progress"}}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","delta":17}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_delta","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected malformed text delta to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingRejectsOutputItemAddedWithoutItem() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_item","status":"in_progress"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_item","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected output item event without item to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsOutputItemDoneWithoutItem() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_item_done","status":"in_progress"}}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_item_done","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected output item done event without item to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsOutputItemDoneBeforeAddedWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_item_order","status":"in_progress"}}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done","item":{"id":"item_1"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","item":{"id":"item_1"}}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_item_order","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected output item done before added to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsDuplicateOutputItemDoneWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_item_done_duplicate","status":"in_progress"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","item":{"id":"item_1"}}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done","item":{"id":"item_1"}}"#),
                (event: "response.output_item.done",
                 data: #"{"type":"response.output_item.done","item":{"id":"item_1"}}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_item_done_duplicate","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected duplicate output item done to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsMalformedOutputTextDoneWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_text_done","status":"in_progress"}}"#),
                (event: "response.output_text.done",
                 data: #"{"type":"response.output_text.done","text":17}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_text_done","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected malformed output text done event to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsResponseIdentityBeforeCreationWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","response_id":"resp_before_created","delta":"must not project"}"#),
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_created","status":"in_progress"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected response identity before creation to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingRejectsDuplicateResponseCreatedWithoutTerminalProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected duplicate response.created to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsSSEEventTypeMismatchWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.in_progress","response":{"id":"resp_1","status":"in_progress"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected SSE event type mismatch to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsUnsafeResponseIdentityWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidIDs = [#"resp_\u0000"#, String(repeating: "r", count: 257)]
        for invalidID in invalidIDs {
            let body = Data(("event: response.created\n" +
                             "data: {\"type\":\"response.created\",\"response\":{\"id\":\"" +
                             invalidID +
                             "\",\"status\":\"in_progress\"}}\n\n").utf8)
            ResponsesMockURLProtocol.requestHandler = { _ in
                (200, body, ["Content-Type": "text/event-stream"])
            }
            let provider = Self.makeProvider()
            let stream = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )

            var projectedText = ""
            var finishedCount = 0
            do {
                for try await chunk in stream {
                    switch chunk {
                    case .text(let delta): projectedText += delta
                    case .finished: finishedCount += 1
                    case .started, .usage: break
                    }
                }
                Issue.record("expected unsafe response identity to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected payload-free provider error, got \(error)")
                    continue
                }
                #expect(message == "Responses API stream error")
            }
            #expect(projectedText.isEmpty)
            #expect(finishedCount == 0)
        }
    }

    @Test func streamingRejectsDuplicateSSEEventIdentityWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\n" +
                         "id: evt_1\n" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}\n\n" +
                         "event: response.in_progress\n" +
                         "id: evt_1\n" +
                         "data: {\"type\":\"response.in_progress\"}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected duplicate SSE event identity to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingCommitsSSEEventIDOnlyAfterDispatch() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\n" +
                         "id: evt_pending\n" +
                         "data: [DONE]\n\n" +
                         "event: response.created\n" +
                         "id: evt_pending\n" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_pending\",\"status\":\"in_progress\"}}\n\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_pending\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        for try await chunk in stream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingAcceptsRetryWithoutChangingResponseIdentity() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\n" +
                         "retry: 1500\n" +
                         "id: evt_1\n" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}\n\n" +
                         "event: response.output_text.delta\n" +
                         "retry: 2000\n" +
                         "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_1\",\"delta\":\"ok\"}\n\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): projectedText += delta
            case .finished: finishedCount += 1
            case .started, .usage: break
            }
        }
        #expect(projectedText == "ok")
        #expect(finishedCount == 1)
    }

    @Test func streamingResetsReconnectStateAfterTruncatedAttempt() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        var requestCount = 0
        let truncatedBody = Data(("event: response.created\n" +
                                  "id: evt_recover\n" +
                                  "retry: 1500\n" +
                                  "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_recover\",\"status\":\"in_progress\"}}\n\n" +
                                  "event: response.output_text.delta\n" +
                                  "id: evt_partial\n" +
                                  "retry: 2000\n" +
                                  "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_recover\",\"delta\":\"stale\"}").utf8)
        let recoveredBody = Data(("event: response.created\n" +
                                  "id: evt_recover\n" +
                                  "retry: 2500\n" +
                                  "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_recover\",\"status\":\"in_progress\"}}\n\n" +
                                  "event: response.completed\n" +
                                  "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_recover\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return requestCount == 1
                ? (200, truncatedBody, ["Content-Type": "text/event-stream"])
                : (200, recoveredBody, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let firstStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        do {
            for try await _ in firstStream {}
            Issue.record("expected truncated SSE attempt to fail closed")
        } catch let error as LLMError {
            guard case .providerError = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
        }

        let secondStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        var finishedCount = 0
        for try await chunk in secondStream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingStaleAttemptCannotCommitReconnectState() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let staleBody = Data(("event: response.created\n" +
                              "id: evt_generation\n" +
                              "retry: 1000\n" +
                              "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_generation\",\"status\":\"in_progress\"}}\n\n" +
                              "event: response.output_text.delta\n" +
                              "id: evt_late\n" +
                              "retry: 2000\n" +
                              "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_generation\",\"delta\":\"late\"}\n\n").utf8)
        let recoveredBody = Data(("event: response.created\n" +
                                  "id: evt_generation\n" +
                                  "retry: 3000\n" +
                                  "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_generation\",\"status\":\"in_progress\"}}\n\n" +
                                  "event: response.completed\n" +
                                  "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_generation\",\"status\":\"completed\"}}\n\n").utf8)
        let provider = Self.makeProvider()
        var requestCount = 0
        ResponsesMockURLProtocol.requestHandler = { _ in
            requestCount += 1
            if requestCount == 1 {
                provider.model = LLMModel(
                    id: "rebound-model",
                    displayName: "Rebound",
                    provider: "OpenAI Responses"
                )
                return (200, staleBody, ["Content-Type": "text/event-stream"])
            }
            return (200, recoveredBody, ["Content-Type": "text/event-stream"])
        }

        let staleStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        var staleText = ""
        do {
            for try await chunk in staleStream {
                if case .text(let delta) = chunk { staleText += delta }
            }
            Issue.record("expected stale SSE attempt to fail closed")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected stale attempt cancellation, got \(error)")
                return
            }
        }
        #expect(staleText.isEmpty)

        let recoveredStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        var finishedCount = 0
        for try await chunk in recoveredStream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingAllowsEventIDReuseAfterModelGenerationChanges() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\n" +
                         "id: evt_completed\n" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_completed\",\"status\":\"in_progress\"}}\n\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_completed\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let firstStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        var firstFinished = 0
        for try await chunk in firstStream {
            if case .finished = chunk { firstFinished += 1 }
        }
        #expect(firstFinished == 1)

        provider.model = LLMModel(
            id: "rebound-model",
            displayName: "Rebound",
            provider: "OpenAI Responses"
        )
        let secondStream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )
        var secondFinished = 0
        for try await chunk in secondStream {
            if case .finished = chunk { secondFinished += 1 }
        }
        #expect(secondFinished == 1)
    }

    @Test func streamingResumesDurableGenerationAcrossModelRoundTrip() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-model-round-trip-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_round_trip","status":"completed"}}"#)
            ])
        }
        let provider = Self.makeProvider(checkpointDirectory: directory)
        try await Self.consumeSuccessfulStream(provider)
        let modelAURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let firstModelA = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: modelAURL)) as? [String: Any]
        )
        #expect((firstModelA["generation"] as? NSNumber)?.uint64Value == 1)

        provider.model = LLMModel(
            id: "round-trip-model",
            displayName: "Round Trip",
            provider: "OpenAI Responses"
        )
        try await Self.consumeSuccessfulStream(provider)
        let modelBURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "round-trip-model",
            directoryOverride: directory
        ))
        let modelB = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: modelBURL)) as? [String: Any]
        )
        #expect((modelB["generation"] as? NSNumber)?.uint64Value == 1)

        provider.model = .gpt4oMini
        try await Self.consumeSuccessfulStream(provider)
        let secondModelA = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: modelAURL)) as? [String: Any]
        )
        #expect((secondModelA["generation"] as? NSNumber)?.uint64Value == 2)
        #expect((secondModelA["previousGeneration"] as? NSNumber)?.uint64Value == 1)
    }

    @Test func knownModelScopeRejectsLowerDurableGeneration() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-known-scope-lower-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_floor","status":"completed"}}"#)
            ])
        }
        let provider = Self.makeProvider(checkpointDirectory: directory)
        try await Self.consumeSuccessfulStream(provider)
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        let lowerURL = directory.appendingPathComponent("lower-generation-receipt")
        let lowerBytes = try Data(contentsOf: checkpointURL)
        try fileManager.linkItem(at: checkpointURL, to: lowerURL)
        try await Self.consumeSuccessfulStream(provider)
        try fileManager.removeItem(at: checkpointURL)
        try fileManager.moveItem(at: lowerURL, to: checkpointURL)

        ResponsesMockURLProtocol.reset()
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("known-scope durable rollback opened transport")
            return Self.sseResponse([])
        }
        do {
            _ = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected known-scope durable rollback to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed durable rollback error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(try Data(contentsOf: checkpointURL) == lowerBytes)
    }

    @Test func knownModelScopeRejectsMissingDurableGeneration() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("responses-known-scope-missing-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_missing_floor","status":"completed"}}"#)
            ])
        }
        let provider = Self.makeProvider(checkpointDirectory: directory)
        try await Self.consumeSuccessfulStream(provider)
        let checkpointURL = try #require(OpenAIResponsesProvider.attemptCheckpointURL(
            providerID: "OpenAI Responses", modelID: "gpt-4o-mini",
            directoryOverride: directory
        ))
        try fileManager.removeItem(at: checkpointURL)

        ResponsesMockURLProtocol.reset()
        ResponsesMockURLProtocol.requestHandler = { _ in
            Issue.record("known-scope missing durable state opened transport")
            return Self.sseResponse([])
        }
        do {
            _ = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected known-scope missing durable state to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected typed missing durable state error, got \(error)")
                return
            }
            #expect(message == "Invalid durable Responses attempt checkpoint")
        }
        #expect(ResponsesMockURLProtocol.requestStarted == false)
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path) == false)
    }

    @Test func streamingRejectsInvalidSSEEventIDFields() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidIDs = ["", "\u{0000}", "\u{0001}", String(repeating: "x", count: 4 * 1024 + 1)]
        for invalidID in invalidIDs {
            let body = Data(("event: response.created\n" +
                             "id: " + invalidID + "\n" +
                             "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}\n\n").utf8)
            ResponsesMockURLProtocol.requestHandler = { _ in
                (200, body, ["Content-Type": "text/event-stream"])
            }
            let provider = Self.makeProvider()
            let stream = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )

            do {
                for try await _ in stream {}
                Issue.record("expected invalid SSE event identity to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected payload-free provider error, got \(error)")
                    continue
                }
                #expect(message == "Responses API stream error")
            }
        }
    }

    @Test func streamingRejectsOversizedRetryField() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let oversizedRetry = String(repeating: "7", count: 65)
        let body = Data(("retry: " + oversizedRetry + "\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("expected oversized SSE retry field to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
    }

    @Test func streamingRejectsSignedAndOverflowingRetryFields() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidRetries = ["+10", "-10", "18446744073709551616"]
        for invalidRetry in invalidRetries {
            let body = Data(("retry: " + invalidRetry + "\n" +
                             "event: response.completed\n" +
                             "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_retry\",\"status\":\"completed\"}}\n\n").utf8)
            ResponsesMockURLProtocol.requestHandler = { _ in
                (200, body, ["Content-Type": "text/event-stream"])
            }
            let provider = Self.makeProvider()
            let stream = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )

            do {
                for try await _ in stream {}
                Issue.record("expected invalid SSE retry field to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected payload-free provider error, got \(error)")
                    continue
                }
                #expect(message == "Responses API stream error")
            }
        }
    }

    @Test func streamingBuffersUnicodeScalarsAcrossCRLFBoundaries() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\r\n" +
                         "id: evt_crlf\r\n" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_utf8\",\"status\":\"in_progress\"}}\r\n\r\n" +
                         "event: response.output_text.delta\r\n" +
                         "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_utf8\",\"delta\":\"跨 chunk 😀\"}\r\n\r\n" +
                         "event: response.completed\r\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_utf8\",\"status\":\"completed\"}}\r\n\r\n").utf8)
        let bodyBytes = Array(body)
        let emojiStart = try #require(bodyBytes.firstIndex(of: 0xF0))
        let carriageReturn = try #require(bodyBytes.firstIndex(of: 0x0D))
        var responseChunks: [Data] = []
        var chunkStart = 0
        for chunkEnd in [emojiStart + 1, carriageReturn + 1, bodyBytes.count].sorted() {
            responseChunks.append(Data(bodyBytes[chunkStart..<chunkEnd]))
            chunkStart = chunkEnd
        }
        ResponsesMockURLProtocol.responseChunks = responseChunks
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): projectedText += delta
            case .finished: finishedCount += 1
            case .started, .usage: break
            }
        }
        #expect(projectedText == "跨 chunk 😀")
        #expect(finishedCount == 1)
    }

    @Test func streamingAcceptsBareCarriageReturnLineTerminators() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.created\r" +
                         "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_bare_cr\",\"status\":\"in_progress\"}}\r\r" +
                         "event: response.output_text.delta\r" +
                         "data: {\"type\":\"response.output_text.delta\",\"response_id\":\"resp_bare_cr\",\"delta\":\"bare CR\"}\r\r" +
                         "event: response.completed\r" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_bare_cr\",\"status\":\"completed\"}}\r\r").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): projectedText += delta
            case .finished: finishedCount += 1
            case .started, .usage: break
            }
        }
        #expect(projectedText == "bare CR")
        #expect(finishedCount == 1)
    }

    @Test func streamingRejectsDanglingUTF8AtEOFWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        var body = Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"".utf8)
        body.append(0xF0)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected dangling UTF-8 to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingRejectsControlDataWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        var body = Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}".utf8)
        body.append(0x01)
        body.append(contentsOf: Array("\n\n".utf8))
        body.append(contentsOf: Array("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_control\",\"status\":\"completed\"}}\n\n".utf8))
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected control data to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingRejectsUnterminatedOversizedLineAcrossChunksWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let prefix = Data("event: response.output_text.delta\n".utf8)
        let dataPrefix = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"".utf8)
        var oversizedLine = dataPrefix
        oversizedLine.append(contentsOf: Data(repeating: 0x78, count: 256 * 1024 + 1 - dataPrefix.count))
        ResponsesMockURLProtocol.responseChunks = [prefix, oversizedLine]
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, Data(), ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected unterminated oversized SSE line to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingAcceptsSSELineExactlyAtByteLimit() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let boundaryComment = ":" + String(repeating: "x", count: 256 * 1024 - 1)
        let body = Data((boundaryComment + "\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_boundary\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        for try await chunk in stream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingAccumulatesMultipleDataLinesBeforeDispatch() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\n" +
                         "data: \"response\":{\"id\":\"resp_multidata\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        for try await chunk in stream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingAcceptsAccumulatedEventExactlyAtPayloadLimit() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let first = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_payload_boundary\",\"status\":\"completed\","
        let last = "\"marker\":true}}"
        let fillerLineCount = 5
        let separatorBytes = fillerLineCount + 1
        let fillerBytes = 1024 * 1024 - first.utf8.count - last.utf8.count - separatorBytes
        let fillerPerLine = fillerBytes / fillerLineCount
        let remainder = fillerBytes % fillerLineCount
        var payloadLines = [first]
        for index in 0..<fillerLineCount {
            let count = fillerPerLine + (index < remainder ? 1 : 0)
            payloadLines.append(String(repeating: " ", count: count))
        }
        payloadLines.append(last)
        #expect(payloadLines.joined(separator: "\n").utf8.count == 1024 * 1024)
        let lines = ["event: response.completed"] + payloadLines.map { "data: " + $0 }
        let body = Data((lines.joined(separator: "\n") + "\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await Self.observingDurableAttemptFailure(
            provider: provider,
            phase: .begin
        ) {
            try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }

        var finishedCount = 0
        try await Self.observingDurableAttemptFailure(
            provider: provider,
            phase: .eventIteration
        ) {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingRejectsOversizedAccumulatedEventWithoutPartialDispatch() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        var body = Data("event: response.output_text.delta\n".utf8)
        let oversizedDataLine = Data(("data: " + String(repeating: "x", count: 220_000) + "\n").utf8)
        for _ in 0..<5 {
            body.append(contentsOf: oversizedDataLine)
        }
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected accumulated SSE event data to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func streamingRejectsUnterminatedEventAtEOFWithoutTerminalProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_truncated\",\"status\":\"completed\"}}\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected unterminated SSE event to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsInvalidUnknownSSEFieldsBeforeNextEvent() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidFields = [
            "x:" + String(repeating: "v", count: 4 * 1024 + 1),
            "é: value",
            "x: bad\u{0001}value"
        ]
        for invalidField in invalidFields {
            let body = Data((invalidField + "\n" +
                             "event: response.completed\n" +
                             "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_field\",\"status\":\"completed\"}}\n\n").utf8)
            ResponsesMockURLProtocol.requestHandler = { _ in
                (200, body, ["Content-Type": "text/event-stream"])
            }
            let provider = Self.makeProvider()
            let stream = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )

            var finishedCount = 0
            do {
                for try await chunk in stream {
                    if case .finished = chunk { finishedCount += 1 }
                }
                Issue.record("expected invalid unknown SSE field to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected payload-free provider error, got \(error)")
                    continue
                }
                #expect(message == "Responses API stream error")
            }
            #expect(finishedCount == 0)
        }
    }

    @Test func streamingPreservesCommentAndEmptyDataSemantics() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data((": legal comment\n" +
                         "data:\n\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_empty_data\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        for try await chunk in stream {
            if case .finished = chunk { finishedCount += 1 }
        }
        #expect(finishedCount == 1)
    }

    @Test func streamingRejectsMalformedTerminalPayloadWithoutSuccessProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1"}}"#)
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected malformed terminal payload to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected provider stream error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsContentPartAddedWithoutPartWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_content_part","status":"in_progress"}}"#),
                (event: "response.content_part.added",
                 data: #"{"type":"response.content_part.added","item_id":"item_1"}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_content_part","status":"completed"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected content part without part object to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsIncompleteWithoutReasonWithoutSuccessProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_incomplete","status":"in_progress"}}"#),
                (event: "response.incomplete",
                 data: #"{"type":"response.incomplete","response":{"id":"resp_incomplete","status":"incomplete"}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected incomplete response without reason to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsUnsafeIncompleteReasonWithoutSuccessProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_unsafe_reason","status":"in_progress"}}"#),
                (event: "response.incomplete",
                 data: #"{"type":"response.incomplete","response":{"id":"resp_unsafe_reason","status":"incomplete","incomplete_details":{"reason":"\u0001"}}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected unsafe incomplete reason to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsFailedWithoutErrorMessageWithoutSuccessProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_failed_stream","status":"in_progress"}}"#),
                (event: "response.failed",
                 data: #"{"type":"response.failed","response":{"id":"resp_failed_stream","status":"failed","error":{"code":"server_error"}}}"#),
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected failed response without error message to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsMalformedUsageWithoutTerminalProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            let body = Data(("event: response.completed\n" +
                             "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_bad_usage\",\"status\":\"completed\",\"usage\":{\"input_tokens\":\"eleven\",\"output_tokens\":-1}}}\n\n").utf8)
            return (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected malformed usage to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    @Test func streamingRejectsUnknownTerminalStatusWithoutSuccessProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_1","status":"mystery"}}"#)
            ])
        }
        let provider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finishedCount = 0
        do {
            for try await chunk in stream {
                if case .finished = chunk { finishedCount += 1 }
            }
            Issue.record("expected unknown terminal status to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected provider stream error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(finishedCount == 0)
    }

    // MARK: (d) error 事件抛 payload-free provider error

    @Test func streamingErrorEventDropsServerPayload() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created"}"#),
                (event: "error",
                 data: #"{"type":"error","code":"server_error","message":"Something went wrong"}"#),
            ])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var deltasBeforeError: [String] = []
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { deltasBeforeError.append(delta) }
            }
            Issue.record("expected payload-free stream error to be thrown")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(deltasBeforeError.isEmpty)
    }

    // MARK: (e) 空 output 抛 emptyResponseOutput

    @Test func nonStreamingEmptyOutputThrowsEmptyResponseOutput() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            ResponsesMockURLProtocol.jsonResponse(["id": "resp_1", "status": "completed", "output": [] as [Any]])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected ResponsesAPIError.emptyResponseOutput to be thrown")
        } catch let error as ResponsesAPIError {
            #expect(error == .emptyResponseOutput)
        }
    }

    // MARK: (f) 流中途 EOF（无 response.completed）抛 prematureStreamEnd

    @Test func streamingPrematureEOFThrowsPrematureStreamEnd() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created"}"#),
                (event: "response.output_text.delta",
                 data: #"{"type":"response.output_text.delta","delta":"partial"}"#),
            ])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await Self.observingDurableAttemptFailure(
            provider: provider,
            phase: .begin
        ) {
            try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }

        var receivedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { receivedText += delta }
            }
            Issue.record("expected ResponsesAPIError.prematureStreamEnd to be thrown")
        } catch let error as ResponsesAPIError {
            #expect(error == .prematureStreamEnd)
        } catch {
            Self.recordDurableAttemptFailure(provider: provider, phase: .eventIteration)
            throw error
        }
        #expect(receivedText == "partial")
    }

    @Test func streamingRejectsDuplicateOutputItemIdentity() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","item":{"id":"item_1"}}"#),
                (event: "response.output_item.added",
                 data: #"{"type":"response.output_item.added","item":{"id":"item_1"}}"#),
            ])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("expected duplicate output item identity to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
    }

    @Test func streamingRejectsUnsafeOutputItemIdentityWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let invalidEvents: [(event: String, data: String)] = [
            (event: "response.output_text.delta",
             data: #"{"type":"response.output_text.delta","item_id":"item_\u0000","delta":"should not project"}"#),
           (event: "response.output_item.added",
             data: #"{"type":"response.output_item.added","item":{"id":"item_\u0000"}}"#),
        ]
        for invalidEvent in invalidEvents {
            ResponsesMockURLProtocol.requestHandler = { _ in
                Self.sseResponse([
                    (event: "response.created",
                     data: #"{"type":"response.created","response":{"id":"resp_item_identity","status":"in_progress"}}"#),
                    invalidEvent,
                ])
            }
            let provider: OpenAIResponsesProvider = Self.makeProvider()
            let stream = try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )

            var projectedText = ""
            do {
                for try await chunk in stream {
                    if case .text(let delta) = chunk { projectedText += delta }
                }
                Issue.record("expected unsafe output item identity to fail closed")
            } catch let error as LLMError {
                guard case .providerError(let message) = error else {
                    Issue.record("expected payload-free provider error, got \(error)")
                    continue
                }
                #expect(message == "Responses API stream error")
            }
            #expect(projectedText.isEmpty)
        }
    }

    @Test func streamingRejectsConflictingResponseIdentity() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        ResponsesMockURLProtocol.requestHandler = { _ in
            Self.sseResponse([
                (event: "response.created",
                 data: #"{"type":"response.created","response":{"id":"resp_1"}}"#),
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_2"}}"#),
            ])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("expected conflicting response identity to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
    }

    @Test func streamingRejectsOversizedLines() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let oversizedLine = Data(
            ("event: response.created\n" +
             "data: " + String(repeating: "x", count: 256 * 1024 + 1) + "\n\n").utf8
        )
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, oversizedLine, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("expected oversized SSE line to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
    }

    @Test func streamingAcceptsSSELeadingBOM() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("\u{FEFF}event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_bom\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var finished = false
        for try await chunk in stream {
            if case .finished = chunk { finished = true }
        }
        #expect(finished)
    }

    @Test func streamingConcatenatesMultiLineDataBeforeDecoding() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.output_text.delta\r\n" +
                         "data: {\"type\":\"response.output_text.delta\",\r\n" +
                         "data: \"delta\":\"split\"}\r\n\r\n" +
                         "event: response.completed\r\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_split\",\"status\":\"completed\"}}\r\n\r\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var text = ""
        for try await chunk in stream {
            if case .text(let delta) = chunk { text += delta }
        }
        #expect(text == "split")
    }

    @Test func streamingPreservesSSEFieldsWhenEventFollowsData() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("data: {\"type\":\"response.output_text.delta\",\"delta\":\"reordered\"}\n" +
                         "event: response.output_text.delta\n\n" +
                         "event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_reordered\",\"status\":\"completed\"}}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        var finishedCount = 0
        for try await chunk in stream {
            switch chunk {
            case .text(let delta): projectedText += delta
            case .finished: finishedCount += 1
            case .started, .usage: break
            }
        }
        #expect(projectedText == "reordered")
        #expect(finishedCount == 1)
    }

    @Test func streamingRejectsDuplicateJSONKeys() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.completed\n" +
                         "data: {\"type\":\"response.completed\",\"type\":\"response.completed\"}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        do {
            for try await _ in stream {}
            Issue.record("expected duplicate JSON keys to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
    }

    @Test func streamingRejectsEscapedDuplicateJSONKeysWithoutProjection() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let body = Data(("event: response.output_text.delta\n" +
                         "data: {\"type\":\"response.output_text.delta\",\"\\u0074ype\":\"response.output_text.delta\",\"delta\":\"should not project\"}\n\n").utf8)
        ResponsesMockURLProtocol.requestHandler = { _ in
            (200, body, ["Content-Type": "text/event-stream"])
        }
        let provider: OpenAIResponsesProvider = Self.makeProvider()
        let stream: AsyncThrowingStream<LLMStreamChunk, Error> = try await provider.streamMessage(
            messages: Self.userMessages,
            systemPrompt: nil,
            maxTokens: 100,
            temperature: nil
        )

        var projectedText = ""
        do {
            for try await chunk in stream {
                if case .text(let delta) = chunk { projectedText += delta }
            }
            Issue.record("expected escaped duplicate JSON keys to fail closed")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                Issue.record("expected payload-free provider error, got \(error)")
                return
            }
            #expect(message == "Responses API stream error")
        }
        #expect(projectedText.isEmpty)
    }

    @Test func HTTPErrorMappingDropsServerBodyAndHeaders() {
        let provider = Self.makeProvider()
        let body = #"{"error":{"message":"Authorization: Bearer fixture-secret https://api.example.test/path?token=fixture-query"}}"#
        let error = provider.mapHTTPError(statusCode: 401, body: body)

        guard case .httpStatus(let code, let detail) = error else {
            Issue.record("expected typed HTTP status error")
            return
        }
        #expect(code == 401)
        #expect(detail.isEmpty)
        let surfaces = [
            error.errorDescription ?? "",
            error.userMessageZH,
            error.userMessageEN,
            error.technicalDetail,
        ]
        #expect(surfaces.allSatisfy {
            !$0.contains("fixture-secret")
                && !$0.contains("api.example.test")
                && !$0.contains("token=")
                && !$0.contains("Bearer")
        })
    }

    @Test func serverControlledStreamErrorIsPayloadFree() {
        let provider = Self.makeProvider()
        let error = provider.mapError(
            ResponsesAPIError.serverStreamError(
                code: "server_error",
                message: "Authorization: Bearer fixture-stream-secret"
            )
        )
        #expect(error.userMessageZH.contains("fixture-stream-secret") == false)
        #expect(error.userMessageEN.contains("fixture-stream-secret") == false)
        #expect(error.technicalDetail.contains("fixture-stream-secret") == false)
        #expect(error.technicalDetail.contains("serverStreamError") == false)
    }

    @Test func lateHTTPErrorAfterModelRebindFailsClosed() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let provider = Self.makeProvider()
        ResponsesMockURLProtocol.requestHandler = { _ in
            provider.model = LLMModel(
                id: "rebound-model",
                displayName: "Rebound",
                provider: "OpenAI Responses"
            )
            return (401, Data("Authorization: Bearer fixture-secret".utf8), [:])
        }

        do {
            _ = try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
            Issue.record("expected stale response to fail closed")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancellation for stale response, got \(error)")
                return
            }
        }
    }

    @Test func cancelledNonStreamingAttemptDoesNotProjectBufferedResponse() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let release = DispatchSemaphore(value: 0)
        ResponsesMockURLProtocol.requestHandler = { _ in
            release.wait()
            return ResponsesMockURLProtocol.jsonResponse([
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [["type": "output_text", "text": "late"]]
                ]]
            ])
        }
        let provider = Self.makeProvider()
        let requestTask = Task<LLMResponse, Error> {
            try await provider.sendMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }
        for _ in 0..<100 where !ResponsesMockURLProtocol.requestStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            ResponsesMockURLProtocol.requestStarted,
            "durable-attempt-write-stage=\(provider.durableAttemptWriteDiagnosticStage())"
        )
        requestTask.cancel()
        release.signal()

        do {
            _ = try await requestTask.value
            Issue.record("expected cancelled non-streaming attempt to fail closed")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancellation, got \(error)")
                return
            }
        }
        #expect(ResponsesMockURLProtocol.receivedRequests.count == 1)
    }

    @Test func cancelledStreamingAttemptDoesNotReturnBufferedStream() async throws {
        defer { ResponsesMockURLProtocol.reset() }
        let release = DispatchSemaphore(value: 0)
        ResponsesMockURLProtocol.requestHandler = { _ in
            release.wait()
            return Self.sseResponse([
                (event: "response.completed",
                 data: #"{"type":"response.completed","response":{"id":"resp_cancelled","status":"completed"}}"#)
            ])
        }
        let provider = Self.makeProvider()
        let requestTask = Task<AsyncThrowingStream<LLMStreamChunk, Error>, Error> {
            try await provider.streamMessage(
                messages: Self.userMessages,
                systemPrompt: nil,
                maxTokens: 100,
                temperature: nil
            )
        }
        for _ in 0..<100 where !ResponsesMockURLProtocol.requestStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ResponsesMockURLProtocol.requestStarted)
        requestTask.cancel()
        release.signal()

        do {
            _ = try await requestTask.value
            Issue.record("expected cancelled streaming attempt to fail closed")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected cancellation, got \(error)")
                return
            }
        }
        #expect(ResponsesMockURLProtocol.receivedRequests.count == 1)
    }
}
