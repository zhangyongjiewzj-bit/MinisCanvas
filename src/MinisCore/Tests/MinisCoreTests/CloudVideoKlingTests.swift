import Foundation
import Testing
@testable import MinisCore

// KlingProvider（M2h 真实 API 接入）离线测试。
//
// 按 docs/kling-api-spec.md 验证：Bearer 认证、POST /image-to-video/kling-3.0
// 与 /text-to-video/kling-3.0 请求体组装（contents/settings/options）、
// GET /tasks?task_ids= 轮询状态流转（submitted→processing→succeeded）、
// code != 0 抛错、generateVideo 全流程。
// 不联网：用独立 KlingMockURLProtocol 拦截，与 CloudVideoHTTPTests 的
// MockURLProtocol 互不依赖（该文件可能被并行任务修改）。

// MARK: - Mock URLProtocol（Kling 专用，独立命名避免冲突）

final class KlingMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// 请求 → (statusCode, body Data, headers) 的脚本化响应。
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    /// 收到的请求记录（供断言请求方法/URL/头）。
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    /// 最近一次请求的 body（httpBody 可能被 URLSession 转为 stream，需手动读）。
    nonisolated(unsafe) static var lastRequestBody: Data?
    /// 轮询计数（状态流转测试用）。
    nonisolated(unsafe) static var pollCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        KlingMockURLProtocol.receivedRequests.append(request)
        KlingMockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        guard let handler = KlingMockURLProtocol.requestHandler else {
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
        config.protocolClasses = [KlingMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 最近请求解码为 JSON 字典（测试断言用）。
    static func lastRequestBodyJSON() -> [String: Any]? {
        guard let data = lastRequestBody else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - 测试

@Suite(.serialized)
struct CloudVideoKlingTests {

    private func makeProvider(apiKey: String = "test-key") -> KlingProvider {
        KlingProvider(apiKey: apiKey, session: KlingMockURLProtocol.makeSession())
    }

    // MARK: submitVideo — 请求体组装

    @Test func submitVideoImageToVideoAssemblesBodyAndHeaders() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse([
                "code": 0,
                "message": "success",
                "request_id": "r-1",
                "data": ["id": "task-abc", "status": "submitted", "create_time": 1781080778802],
            ])
        }
        let provider = makeProvider()
        let taskID = try await provider.submitVideo(CloudVideoRequest(
            prompt: "shot 1, 5, 女孩在火车上望向窗外; shot 2, 5, 火车驶入隧道",
            imageURL: "https://cdn.example.com/first.png",
            duration: "10",
            extraParams: ["last_frame_url": "https://cdn.example.com/last.png"]
        ))
        #expect(taskID == "task-abc")

        let sent = try #require(KlingMockURLProtocol.receivedRequests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://api-singapore.klingai.com/image-to-video/kling-3.0")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let json = try #require(KlingMockURLProtocol.lastRequestBodyJSON())
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 3)
        #expect(contents[0]["type"] as? String == "prompt")
        #expect((contents[0]["text"] as? String)?.hasPrefix("shot 1") == true)
        #expect(contents[1]["type"] as? String == "first_frame")
        #expect(contents[1]["url"] as? String == "https://cdn.example.com/first.png")
        #expect(contents[2]["type"] as? String == "last_frame")
        #expect(contents[2]["url"] as? String == "https://cdn.example.com/last.png")

        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["resolution"] as? String == "1080p")
        #expect(settings["duration"] as? Int == 10)
        #expect(settings["audio"] as? String == "off")
        #expect(settings["multi_shot"] as? Bool == false)

        let options = try #require(json["options"] as? [String: Any])
        let watermark = try #require(options["watermark_info"] as? [String: Any])
        #expect(watermark["enabled"] as? Bool == false)
    }

    @Test func submitVideoTextToVideoUsesTextEndpointAndPromptOnly() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse(["code": 0, "data": ["id": "t-99"]])
        }
        let provider = makeProvider()
        let taskID = try await provider.submitVideo(CloudVideoRequest(prompt: "一朵云缓缓飘过山巅"))
        #expect(taskID == "t-99")

        let sent = try #require(KlingMockURLProtocol.receivedRequests.first)
        #expect(sent.url?.absoluteString == "https://api-singapore.klingai.com/text-to-video/kling-3.0")

        let json = try #require(KlingMockURLProtocol.lastRequestBodyJSON())
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["type"] as? String == "prompt")
        #expect(contents[0]["text"] as? String == "一朵云缓缓飘过山巅")
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["multi_shot"] as? Bool == false)
    }

    @Test func submitVideoExtraParamsControlResolutionAudioMultiShot() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse(["code": 0, "data": ["id": "t-multi"]])
        }
        let provider = makeProvider()
        _ = try await provider.submitVideo(CloudVideoRequest(
            prompt: "shot 1, 4, 远景; shot 2, 6, 近景",
            duration: "5",
            extraParams: [
                "resolution": "4k",
                "audio": "native",
                "multi_shot": "true",
            ]
        ))
        let json = try #require(KlingMockURLProtocol.lastRequestBodyJSON())
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["resolution"] as? String == "4k")
        #expect(settings["duration"] as? Int == 5)
        #expect(settings["audio"] as? String == "native")
        #expect(settings["multi_shot"] as? Bool == true)
    }

    // MARK: submitVideo — 失败路径

    @Test func submitVideoNonZeroCodeThrowsWithMessage() async {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse(["code": 40000, "message": "内容风控：提示词违规"])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.submitVideo(CloudVideoRequest(prompt: "bad"))
        }
    }

    @Test func submitVideoMissingKeyThrows() async {
        defer { KlingMockURLProtocol.reset() }
        // 注入空白串 → resolveAPIKey 返回 nil（无论进程环境变量如何）。
        let provider = KlingProvider(apiKey: "   ", session: KlingMockURLProtocol.makeSession())
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.submitVideo(CloudVideoRequest(prompt: "p"))
        }
    }

    @Test func submitVideoDoesNotRetryOn5xx() async {
        defer { KlingMockURLProtocol.reset() }
        var calls = 0
        KlingMockURLProtocol.requestHandler = { _ in
            calls += 1
            return (500, Data("{\"error\":\"upstream\"}".utf8), ["Content-Type": "application/json"])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.submitVideo(CloudVideoRequest(prompt: "p"))
        }
        // 幂等性铁律：submit 遇 5xx 只发一次，绝不盲目重试（避免重复建任务扣费）。
        #expect(calls == 1)
    }

    @Test func resolveAPIKeyReadsEnvironmentVariable() {
        defer { unsetenv("KLING_API_KEY") }
        setenv("KLING_API_KEY", "env-key-123", 1)
        let provider = KlingProvider(apiKey: nil)
        #expect(provider.resolvedAPIKey == "env-key-123")
        #expect(provider.isConfigured == true)
    }

    // MARK: pollVideo — 状态流转

    @Test func pollVideoMapsStateTransitionsAndExtractsOutputURL() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.pollCount = 0
        KlingMockURLProtocol.requestHandler = { request in
            // 断言轮询请求形态。
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/tasks")
            #expect(request.url?.query?.contains("task_ids=task-1") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            KlingMockURLProtocol.pollCount += 1
            switch KlingMockURLProtocol.pollCount {
            case 1:
                return KlingMockURLProtocol.jsonResponse([
                    "code": 0, "data": [["id": "task-1", "status": "submitted"]],
                ])
            case 2:
                return KlingMockURLProtocol.jsonResponse([
                    "code": 0, "data": [["id": "task-1", "status": "processing"]],
                ])
            default:
                return KlingMockURLProtocol.jsonResponse([
                    "code": 0,
                    "data": [[
                        "id": "task-1",
                        "status": "succeeded",
                        "outputs": [
                            ["type": "video", "id": "vid-1", "url": "https://cdn.example.com/out.mp4", "duration": "10"],
                            ["type": "image", "url": "https://cdn.example.com/poster.png"],
                        ],
                    ]],
                ])
            }
        }
        let provider = makeProvider()

        let q1 = try await provider.pollVideo(taskID: "task-1")
        #expect(q1.phase == .queued)
        #expect(q1.isFinished == false)

        let q2 = try await provider.pollVideo(taskID: "task-1")
        #expect(q2.phase == .running)

        let q3 = try await provider.pollVideo(taskID: "task-1")
        #expect(q3.phase == .succeeded)
        #expect(q3.isFinished == true)
        #expect(q3.videoURL == "https://cdn.example.com/out.mp4")
    }

    @Test func pollVideoFailedCarriesMessage() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse([
                "code": 0,
                "data": [["id": "task-1", "status": "failed", "message": "prompt 违规，请修改后重试"]],
            ])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "task-1")
        #expect(state.phase == .failed)
        #expect(state.message == "prompt 违规，请修改后重试")
    }

    @Test func pollVideoNonZeroCodeThrows() async {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { _ in
            KlingMockURLProtocol.jsonResponse(["code": 40100, "message": "无效的 API Key"])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.pollVideo(taskID: "task-1")
        }
    }

    @Test func cancelVideoIsExplicitlyUnsupportedWithoutAProviderContract() async throws {
        defer { KlingMockURLProtocol.reset() }
        let provider = makeProvider()
        let outcome = try await provider.cancelVideo(taskID: "task-1")
        #expect(outcome == .unsupported)
        #expect(KlingMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: generateVideo — 全流程（提交 → 轮询 → 完成返回 URL）

    @Test func generateVideoFullFlow() async throws {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.pollCount = 0
        KlingMockURLProtocol.requestHandler = { request in
            if request.url?.path == "/image-to-video/kling-3.0" {
                return KlingMockURLProtocol.jsonResponse(["code": 0, "data": ["id": "task-1"]])
            }
            KlingMockURLProtocol.pollCount += 1
            if KlingMockURLProtocol.pollCount == 1 {
                return KlingMockURLProtocol.jsonResponse(["code": 0, "data": [["id": "task-1", "status": "processing"]]])
            }
            return KlingMockURLProtocol.jsonResponse([
                "code": 0,
                "data": [[
                    "id": "task-1",
                    "status": "succeeded",
                    "outputs": [["type": "video", "url": "https://cdn.example.com/final.mp4"]],
                ]],
            ])
        }
        let provider = makeProvider()
        let result = try await provider.generateVideo(
            CloudVideoRequest(prompt: "一只猫在窗台晒太阳", imageURL: "https://cdn.example.com/first.png"),
            pollInterval: 0.01,
            timeout: 5
        )
        #expect(result.providerID == "kling")
        #expect(result.taskID == "task-1")
        #expect(result.videoURL == "https://cdn.example.com/final.mp4")
        #expect(KlingMockURLProtocol.pollCount >= 2)
    }

    @Test func generateVideoThrowsOnTaskFailure() async {
        defer { KlingMockURLProtocol.reset() }
        KlingMockURLProtocol.requestHandler = { request in
            if request.url?.path == "/text-to-video/kling-3.0" {
                return KlingMockURLProtocol.jsonResponse(["code": 0, "data": ["id": "task-1"]])
            }
            return KlingMockURLProtocol.jsonResponse([
                "code": 0,
                "data": [["id": "task-1", "status": "failed", "message": "生成失败：资源不足"]],
            ])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.generateVideo(
                CloudVideoRequest(prompt: "文生视频"),
                pollInterval: 0.01,
                timeout: 5
            )
        }
    }
}
