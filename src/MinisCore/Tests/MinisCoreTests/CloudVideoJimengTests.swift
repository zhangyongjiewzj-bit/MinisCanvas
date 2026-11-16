import Foundation
import Testing
@testable import MinisCore

// JimengProvider（M2i）离线测试：签名 KAT + 请求组装 + 响应解析 + 轮询全流程。
//
// 规格来源：火山引擎「即梦AI-视频生成3.0 Pro-接口文档」（docs 85621/1777001）：
//   - 提交：POST https://visual.volcengineapi.com?Action=CVSync2AsyncSubmitTask&Version=2022-08-31
//   - 查询：POST ...?Action=CVSync2AsyncGetResult&Version=2022-08-31
//   - 鉴权：火山引擎签名 V4（HMAC-SHA256），Region=cn-north-1，Service=cv，AK/SK 凭证。
// 全部用例走 URLProtocol mock，不联网、不需要真实密钥。
//
// 注意：不复用 CloudVideoHTTPTests 的 JimengMockURLProtocol（其静态 handler 与另一 suite
// 并行时会互相覆盖），本文件自带独立的 JimengMockURLProtocol，保证隔离。

// MARK: - 独立 Mock URLProtocol（与 CloudVideoHTTPTests 的实现等价，静态状态不共享）

final class JimengMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var pollCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        JimengMockURLProtocol.receivedRequests.append(request)
        JimengMockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        guard let handler = JimengMockURLProtocol.requestHandler else {
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
        config.protocolClasses = [JimengMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 签名 KAT（与独立 Python 实现交叉验证的值）

@Suite(.serialized)
struct VolcSignerTests {
    let signer = VolcSigner(
        accessKey: "AKLTtest123",
        secretKey: "SECRETtest456",
        region: "cn-north-1",
        service: "cv",
        host: "visual.volcengineapi.com"
    )

    @Test func signatureKATSubmit() {
        let body = Data(#"{"prompt":"test","req_key":"jimeng_ti2v_v30_pro"}"#.utf8)
        let sig = signer.signature(
            method: "POST",
            path: "/",
            query: "Action=CVSync2AsyncSubmitTask&Version=2022-08-31",
            body: body,
            xDate: "20240801T120000Z"
        )
        #expect(sig == "3c8dade9fe36aa1ddf29086009247fe62b2f245d4a2483c8a7f76a859b52d459")
    }

    @Test func signatureKATQuery() {
        let body = Data(#"{"req_key":"jimeng_ti2v_v30_pro","task_id":"7392616336519610409"}"#.utf8)
        let sig = signer.signature(
            method: "POST",
            path: "/",
            query: "Action=CVSync2AsyncGetResult&Version=2022-08-31",
            body: body,
            xDate: "20240801T120100Z"
        )
        #expect(sig == "625ac86158f23e0b2843e34d82c0eda65aa076a28a23fc873ef2e069f68d304b")
    }

    @Test func headersKAT() {
        let body = Data(#"{"prompt":"test","req_key":"jimeng_ti2v_v30_pro"}"#.utf8)
        let headers = signer.headers(
            method: "POST",
            path: "/",
            query: "Action=CVSync2AsyncSubmitTask&Version=2022-08-31",
            body: body,
            xDate: "20240801T120000Z"
        )
        #expect(headers["x-date"] == "20240801T120000Z")
        #expect(headers["x-content-sha256"] == "5a4ae8a458ec8a4b0e9be31146c813d57b405020d888067ad6e01c619de761b2")
        #expect(headers["Authorization"] == "HMAC-SHA256 Credential=AKLTtest123/20240801/cn-north-1/cv/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=3c8dade9fe36aa1ddf29086009247fe62b2f245d4a2483c8a7f76a859b52d459")
    }

    @Test func signatureChangesWithInput() {
        let bodyA = Data(#"{"prompt":"a","req_key":"jimeng_ti2v_v30_pro"}"#.utf8)
        let bodyB = Data(#"{"prompt":"b","req_key":"jimeng_ti2v_v30_pro"}"#.utf8)
        let query = "Action=CVSync2AsyncSubmitTask&Version=2022-08-31"
        let sigA = signer.signature(method: "POST", path: "/", query: query, body: bodyA, xDate: "20240801T120000Z")
        let sigB = signer.signature(method: "POST", path: "/", query: query, body: bodyB, xDate: "20240801T120000Z")
        let sigSame = signer.signature(method: "POST", path: "/", query: query, body: bodyA, xDate: "20240801T120000Z")
        #expect(sigA != sigB)          // body 变化 → 签名变化
        #expect(sigA == sigSame)       // 幂等
        #expect(sigA.count == 64)      // SHA256 hex
    }
}

// MARK: - JimengProvider 行为测试

@Suite(.serialized)
struct CloudVideoJimengTests {
    /// 构造带注入 AK/SK 的 provider（mock session）。
    private func makeProvider() -> JimengProvider {
        let provider = JimengProvider(
            apiKey: nil,
            model: "jimeng_ti2v_v30_pro",
            accessKey: "AKLTtest123",
            secretKey: "SECRETtest456"
        )
        provider.session = JimengMockURLProtocol.makeSession()
        return provider
    }

    // MARK: 凭证解析

    @Test func credentialResolutionInjectionWins() {
        let p = JimengProvider(accessKey: "inj-ak", secretKey: "inj-sk")
        #expect(p.accessKey == "inj-ak")
        #expect(p.secretKey == "inj-sk")
        #expect(p.isConfigured)
    }

    @Test func credentialResolutionFromEnv() {
        let origAK = EnvCredentials.value(for: "JIMENG_ACCESS_KEY")
        let origSK = EnvCredentials.value(for: "JIMENG_SECRET_KEY")
        defer {
            if let origAK { setenv("JIMENG_ACCESS_KEY", origAK, 1) } else { unsetenv("JIMENG_ACCESS_KEY") }
            if let origSK { setenv("JIMENG_SECRET_KEY", origSK, 1) } else { unsetenv("JIMENG_SECRET_KEY") }
        }
        setenv("JIMENG_ACCESS_KEY", "env-ak", 1)
        setenv("JIMENG_SECRET_KEY", "env-sk", 1)
        let p = JimengProvider()
        #expect(p.accessKey == "env-ak")
        #expect(p.secretKey == "env-sk")
        #expect(p.isConfigured)
    }

    @Test func notConfiguredWithoutCredentials() {
        // 清空全部 AK/SK 相关环境变量后构造，避免测试机残留配置干扰。
        for name in JimengProvider.accessKeyEnvVars + JimengProvider.secretKeyEnvVars {
            unsetenv(name)
        }
        let p = JimengProvider()
        #expect(!p.isConfigured)
        #expect(p.accessKey == nil)
        #expect(p.secretKey == nil)
    }

    @Test func missingCredentialsThrows() async {
        for name in JimengProvider.accessKeyEnvVars + JimengProvider.secretKeyEnvVars {
            unsetenv(name)
        }
        let p = JimengProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await p.submitVideo(CloudVideoRequest(prompt: "test"))
        }
    }

    // MARK: 提交任务

    @Test func submitVideoAssemblesRequestAndReturnsTaskID() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { request in
            let json: [String: Any] = ["code": 10000, "data": ["task_id": "7392616336519610409"], "message": "Success"]
            return JimengMockURLProtocol.jsonResponse(json)
        }
        let provider = makeProvider()
        let taskID = try await provider.submitVideo(
            CloudVideoRequest(
                prompt: "千军万马",
                imageURL: "https://img.test/first-frame.png",
                aspectRatio: "16:9",
                duration: "10",
                extraParams: ["seed": "-1"]
            )
        )
        #expect(taskID == "7392616336519610409")

        let request = try #require(JimengMockURLProtocol.receivedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://visual.volcengineapi.com?Action=CVSync2AsyncSubmitTask&Version=2022-08-31")

        // 签名头
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Authorization"]?.hasPrefix("HMAC-SHA256 Credential=AKLTtest123/") == true)
        #expect(headers["Authorization"]?.contains("SignedHeaders=content-type;host;x-content-sha256;x-date") == true)
        #expect(headers["x-date"]?.count == 16)
        #expect(headers["x-content-sha256"]?.count == 64)

        // body 字段
        let bodyData = try #require(JimengMockURLProtocol.lastRequestBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["req_key"] as? String == "jimeng_ti2v_v30_pro")
        #expect(body["prompt"] as? String == "千军万马")
        #expect(body["image_urls"] as? [String] == ["https://img.test/first-frame.png"])
        #expect(body["aspect_ratio"] as? String == "16:9")
        #expect(body["frames"] as? Int == 241)   // duration 10s → 24*10+1
        #expect(body["seed"] as? String == "-1") // extraParams 透传
    }

    @Test func submitVideoTextOnlyBody() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["task_id": "t1"]])
        }
        let provider = makeProvider()
        _ = try await provider.submitVideo(CloudVideoRequest(prompt: "海浪"))
        let bodyData = try #require(JimengMockURLProtocol.lastRequestBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["image_urls"] == nil)
        #expect(body["frames"] == nil)          // 无 duration 不传
        #expect(body["aspect_ratio"] == nil)
    }

    @Test func submitVideoBusinessErrorThrows() async {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 50413, "data": NSNull(), "message": "Post Text Risk Not Pass"])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.submitVideo(CloudVideoRequest(prompt: "bad"))
        }
    }

    // MARK: 轮询

    @Test func pollRunning() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "generating"]])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "task-1")
        #expect(state.phase == .running)
        #expect(state.videoURL == nil)

        // 请求校验（在测试上下文断言，不在 mock handler 内）
        let request = try #require(JimengMockURLProtocol.receivedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://visual.volcengineapi.com?Action=CVSync2AsyncGetResult&Version=2022-08-31")
        let bodyData = try #require(JimengMockURLProtocol.lastRequestBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["task_id"] as? String == "task-1")
        #expect(body["req_key"] as? String == "jimeng_ti2v_v30_pro")
    }

    @Test func pollQueuedInQueue() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "in_queue"]])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "t")
        #expect(state.phase == .queued)
    }

    @Test func pollQueuedNotFound() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "not_found"]])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "t")
        #expect(state.phase == .queued)  // 传播延迟，继续轮询
    }

    @Test func pollSucceededWithVideoURL() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "done", "video_url": "https://v.test/result.mp4"]])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "t")
        #expect(state.phase == .succeeded)
        #expect(state.videoURL == "https://v.test/result.mp4")
    }

    @Test func pollDoneWithBusinessErrorIsFailed() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 50516, "data": ["status": "done"], "message": "Post Video Risk Not Pass"])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "t")
        #expect(state.phase == .failed)
        #expect(state.message == "Post Video Risk Not Pass")
    }

    @Test func pollExpiredIsFailed() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { _ in
            JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "expired"]])
        }
        let provider = makeProvider()
        let state = try await provider.pollVideo(taskID: "t")
        #expect(state.phase == .failed)
    }

    @Test func cancelVideoIsExplicitlyUnsupportedWithoutAProviderContract() async throws {
        JimengMockURLProtocol.reset()
        let provider = makeProvider()
        let outcome = try await provider.cancelVideo(taskID: "task-1")
        #expect(outcome == .unsupported)
        #expect(JimengMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: 全流程（submit → poll → done）

    @Test func generateVideoFullFlow() async throws {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains("CVSync2AsyncSubmitTask") == true {
                return JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["task_id": "task-42"], "message": "Success"])
            }
            // 查询：第一次 generating，第二次 done
            JimengMockURLProtocol.pollCount += 1
            if JimengMockURLProtocol.pollCount == 1 {
                return JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "generating"]])
            }
            return JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["status": "done", "video_url": "https://v.test/out.mp4"]])
        }
        let provider = makeProvider()
        let result = try await provider.generateVideo(
            CloudVideoRequest(prompt: "赛博朋克城市"),
            pollInterval: 0.05,
            timeout: 5
        )
        #expect(result.providerID == "jimeng")
        #expect(result.taskID == "task-42")
        #expect(result.videoURL == "https://v.test/out.mp4")
        #expect(JimengMockURLProtocol.pollCount == 2)
    }

    @Test func generateVideoFailsOnTaskFailure() async {
        JimengMockURLProtocol.reset()
        JimengMockURLProtocol.requestHandler = { request in
            if request.url?.absoluteString.contains("CVSync2AsyncSubmitTask") == true {
                return JimengMockURLProtocol.jsonResponse(["code": 10000, "data": ["task_id": "task-1"]])
            }
            return JimengMockURLProtocol.jsonResponse(["code": 50516, "data": ["status": "done"], "message": "Post Video Risk Not Pass"])
        }
        let provider = makeProvider()
        await #expect(throws: CloudBackendError.self) {
            _ = try await provider.generateVideo(CloudVideoRequest(prompt: "x"), pollInterval: 0.05, timeout: 5)
        }
    }
}
