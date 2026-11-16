import Foundation
import Testing
@testable import MinisCore

// CloudVideoHTTP（M2g 生视频 submit+poll 基础设施）离线测试。
//
// 用 URLProtocol mock 验证「提交 → 轮询 → 完成返回 URL」基础流程，
// 不联网、不涉及任何真实厂商 endpoint。Kling/Jimeng 的真实 endpoint
// 待用户提供 API 文档后接入（见 KlingProvider/JimengProvider TODO）。
//
// MockURLProtocol 持有静态 handler/计数器，必须串行执行。

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// 请求 → (statusCode, body Data, headers) 的脚本化响应。
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    /// 收到的请求记录（供断言请求方法/体）。
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    /// 最近一次请求的 body（httpBody 可能被 URLSession 转为 stream，需手动读）。
    nonisolated(unsafe) static var lastRequestBody: Data?
    /// 轮询计数（全流程测试用：先 running 后 succeeded）。
    nonisolated(unsafe) static var pollCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.receivedRequests.append(request)
        MockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        guard let handler = MockURLProtocol.requestHandler else {
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
            client?.urlProtocol(self, didLoad: data)
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
        pollCount = 0
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
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 测试 Provider（复用通用基础设施，模拟厂商接入形态）

private struct MockVideoProvider: CloudVideoGenerator {
    let providerID = "mockvideo"
    let displayName = "Mock Video"
    let isConfigured = true
    let session: URLSession

    func submitVideo(_ request: CloudVideoRequest) async throws -> String {
        try await CloudVideoHTTP.submitTask(
            providerID: providerID,
            submitURL: URL(string: "https://mock.test/videos")!,
            headers: ["Authorization": "Bearer test-key"],
            body: ["prompt": request.prompt],
            session: session
        )
    }

    func pollVideo(taskID: String) async throws -> CloudTaskState {
        try await CloudVideoHTTP.pollTask(
            providerID: providerID,
            queryURL: URL(string: "https://mock.test/videos/\(taskID)")!,
            headers: ["Authorization": "Bearer test-key"],
            taskID: taskID,
            session: session
        )
    }
}

// MARK: - 测试

@Suite(.serialized)
struct CloudVideoHTTPTests {

    // MARK: submitTask

    @Test func submitTaskExtractsTaskIDAndSendsPost() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { request in
            MockURLProtocol.jsonResponse(["task_id": "t-123"])
        }
        let session = MockURLProtocol.makeSession()
        let taskID = try await CloudVideoHTTP.submitTask(
            providerID: "kling",
            submitURL: URL(string: "https://mock.test/videos")!,
            headers: ["Authorization": "Bearer k"],
            body: ["prompt": "一只猫", "model": "kling-v1"],
            session: session
        )
        #expect(taskID == "t-123")

        let sent = try #require(MockURLProtocol.receivedRequests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://mock.test/videos")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(MockURLProtocol.lastRequestBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == "一只猫")
        #expect(json["model"] as? String == "kling-v1")
    }

    @Test func submitTaskExtractsNestedDataID() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse(["code": 0, "data": ["id": "nested-9"]])
        }
        let taskID = try await CloudVideoHTTP.submitTask(
            providerID: "jimeng",
            submitURL: URL(string: "https://mock.test/async/videos")!,
            headers: [:],
            body: ["prompt": "p"],
            taskIDKeys: ["task_id", "id"],
            session: MockURLProtocol.makeSession()
        )
        #expect(taskID == "nested-9")
    }

    @Test func submitTaskMissingIDThrows() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse(["code": 0, "data": [:]])
        }
        await #expect(throws: CloudBackendError.self) {
            _ = try await CloudVideoHTTP.submitTask(
                providerID: "kling",
                submitURL: URL(string: "https://mock.test/videos")!,
                headers: [:],
                body: [:],
                session: MockURLProtocol.makeSession()
            )
        }
    }

    // MARK: pollTask

    @Test func pollTaskMapsRunningPhase() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse(["status": "PROCESSING", "message": "生成中"])
        }
        let state = try await CloudVideoHTTP.pollTask(
            providerID: "kling",
            queryURL: URL(string: "https://mock.test/videos/t-1")!,
            headers: [:],
            taskID: "t-1",
            session: MockURLProtocol.makeSession()
        )
        #expect(state.phase == .running)
        #expect(state.message == "生成中")
        #expect(state.isFinished == false)
        #expect(state.videoURL == nil)
    }

    @Test func pollTaskMapsSucceededWithVideoURL() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse([
                "status": "SUCCEEDED",
                "video_url": "https://cdn.example.com/out.mp4",
            ])
        }
        let state = try await CloudVideoHTTP.pollTask(
            providerID: "kling",
            queryURL: URL(string: "https://mock.test/videos/t-1")!,
            headers: [:],
            taskID: "t-1",
            session: MockURLProtocol.makeSession()
        )
        #expect(state.phase == .succeeded)
        #expect(state.videoURL == "https://cdn.example.com/out.mp4")
        #expect(state.isFinished == true)
    }

    @Test func pollTaskMapsVideosArrayFallback() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse([
                "status": "succeeded",
                "videos": [["url": "https://cdn.example.com/a.mp4", "duration": "5"]],
            ])
        }
        let state = try await CloudVideoHTTP.pollTask(
            providerID: "jimeng",
            queryURL: URL(string: "https://mock.test/tasks/t-1")!,
            headers: [:],
            taskID: "t-1",
            session: MockURLProtocol.makeSession()
        )
        #expect(state.phase == .succeeded)
        #expect(state.videoURL == "https://cdn.example.com/a.mp4")
    }

    // MARK: 全流程（提交 → 轮询 → 完成返回 URL）

    @Test func generateVideoFullFlow() async throws {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.pollCount = 0
        MockURLProtocol.requestHandler = { request in
            guard let path = request.url?.path else { throw URLError(.badURL) }
            if path == "/videos" {
                return MockURLProtocol.jsonResponse(["task_id": "t-1"])
            }
            // /videos/t-1：第一次 running，之后 succeeded。
            MockURLProtocol.pollCount += 1
            if MockURLProtocol.pollCount == 1 {
                return MockURLProtocol.jsonResponse(["status": "running"])
            }
            return MockURLProtocol.jsonResponse([
                "status": "succeeded",
                "video_url": "https://cdn.example.com/final.mp4",
            ])
        }
        let provider = MockVideoProvider(session: MockURLProtocol.makeSession())
        let result = try await provider.generateVideo(
            CloudVideoRequest(prompt: "一只猫在跑步"),
            pollInterval: 0.01,
            timeout: 5
        )
        #expect(result.providerID == "mockvideo")
        #expect(result.taskID == "t-1")
        #expect(result.videoURL == "https://cdn.example.com/final.mp4")
        #expect(MockURLProtocol.pollCount >= 2)
    }

    @Test func generateVideoThrowsOnTaskFailure() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/videos" {
                return MockURLProtocol.jsonResponse(["task_id": "t-1"])
            }
            return MockURLProtocol.jsonResponse(["status": "failed", "message": "prompt 违规"])
        }
        let provider = MockVideoProvider(session: MockURLProtocol.makeSession())
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.generateVideo(
                CloudVideoRequest(prompt: "bad"),
                pollInterval: 0.01,
                timeout: 5
            )
        }
    }

    @Test func generateVideoTimesOut() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/videos" {
                return MockURLProtocol.jsonResponse(["task_id": "t-1"])
            }
            return MockURLProtocol.jsonResponse(["status": "running"])
        }
        let provider = MockVideoProvider(session: MockURLProtocol.makeSession())
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.generateVideo(
                CloudVideoRequest(prompt: "slow"),
                pollInterval: 0.01,
                timeout: 0.2
            )
        }
    }

    // MARK: 瞬时故障重试

    @Test func withTransientRetryRecoversFrom500() async throws {
        defer { MockURLProtocol.reset() }
        var calls = 0
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            if calls < 3 {
                return MockURLProtocol.jsonResponse(["error": "upstream"], status: 500)
            }
            return MockURLProtocol.jsonResponse(["status": "succeeded", "video_url": "https://cdn/x.mp4"])
        }
        let session = MockURLProtocol.makeSession()
        let state = try await CloudVideoHTTP.withTransientRetry(
            providerID: "kling",
            maxRetries: 3,
            baseDelay: 0.001
        ) {
            try await CloudVideoHTTP.pollTask(
                providerID: "kling",
                queryURL: URL(string: "https://mock.test/videos/t-1")!,
                headers: [:],
                taskID: "t-1",
                session: session
            )
        }
        #expect(state.phase == .succeeded)
        #expect(state.videoURL == "https://cdn/x.mp4")
        #expect(calls == 3)
    }

    @Test func withTransientRetryExhausts() async {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.requestHandler = { _ in
            MockURLProtocol.jsonResponse(["error": "upstream"], status: 503)
        }
        await #expect(throws: CloudBackendError.self) {
            _ = try await CloudVideoHTTP.withTransientRetry(
                providerID: "kling",
                maxRetries: 1,
                baseDelay: 0.001
            ) {
                try await CloudVideoHTTP.pollTask(
                    providerID: "kling",
                    queryURL: URL(string: "https://mock.test/videos/t-1")!,
                    headers: [:],
                    taskID: "t-1",
                    session: MockURLProtocol.makeSession()
                )
            }
        }
    }

    // MARK: 幂等性铁律 — submit 绝不重试

    @Test func submitTaskDoesNotRetryOn5xx() async {
        defer { MockURLProtocol.reset() }
        var calls = 0
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            return (500, Data("{\"error\":\"upstream\"}".utf8), ["Content-Type": "application/json"])
        }
        let session = MockURLProtocol.makeSession()
        await #expect(throws: CloudBackendError.self) {
            _ = try await CloudVideoHTTP.submitTask(
                providerID: "kling",
                submitURL: URL(string: "https://mock.test/videos")!,
                headers: [:],
                body: ["prompt": "p"],
                session: session
            )
        }
        // 5xx 提交只发一次，绝不盲目重试（避免重复建任务扣费）。
        #expect(calls == 1)
    }

    // MARK: 429 尊重 Retry-After（仅 poll 重试）

    @Test func withTransientRetryRespectsRetryAfterOn429() async throws {
        defer { MockURLProtocol.reset() }
        var calls = 0
        let start = Date()
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            if calls == 1 {
                // Retry-After 秒值格式；baseDelay 设 100s，若未尊重 Retry-After 会等 100s 超时。
                return (429, Data(), ["Retry-After": "1"])
            }
            return MockURLProtocol.jsonResponse(["status": "succeeded", "video_url": "https://cdn/x.mp4"])
        }
        let session = MockURLProtocol.makeSession()
        let state = try await CloudVideoHTTP.withTransientRetry(
            providerID: "kling",
            maxRetries: 3,
            baseDelay: 100
        ) {
            try await CloudVideoHTTP.pollTask(
                providerID: "kling",
                queryURL: URL(string: "https://mock.test/videos/t-1")!,
                headers: [:],
                taskID: "t-1",
                session: session
            )
        }
        #expect(state.phase == .succeeded)
        #expect(calls == 2)
        // 用了 Retry-After(1s) 而非 100s 指数退避 → 总耗时远小于 baseDelay。
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func withTransientRetryRetries429WithoutRetryAfterHeader() async throws {
        defer { MockURLProtocol.reset() }
        var calls = 0
        MockURLProtocol.requestHandler = { _ in
            calls += 1
            if calls < 3 {
                return (429, Data("{\"error\":\"rate limited\"}".utf8), ["Content-Type": "application/json"])
            }
            return MockURLProtocol.jsonResponse(["status": "succeeded"])
        }
        let session = MockURLProtocol.makeSession()
        let state = try await CloudVideoHTTP.withTransientRetry(
            providerID: "kling",
            maxRetries: 3,
            baseDelay: 0.001
        ) {
            try await CloudVideoHTTP.pollTask(
                providerID: "kling",
                queryURL: URL(string: "https://mock.test/videos/t-1")!,
                headers: [:],
                taskID: "t-1",
                session: session
            )
        }
        #expect(state.phase == .succeeded)
        #expect(calls == 3)
    }
}
