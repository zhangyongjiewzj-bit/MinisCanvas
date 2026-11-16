import Foundation
import Testing
@testable import MinisCore

// W5-PROVIDERGATE-JIMENG-067：P1-13「参考图必须云端可访问」在即梦侧的把关回归测试。
//
// 背景：`MediaReferenceGate.resolveForCloud`（MediaReference.swift:103）要求本地路径参考图
// 要么上传托管换成云端 URL，要么失败关闭（抛 `MediaReferenceError.localNotAccessible`）。
// KlingProvider.swift:131-132 已接入；JimengProvider.submitVideo 此前把 request.imageURL
// 原样写进 body 的 `image_urls`（并让 extraParams 绕过），本地路径会被发给火山 API。
//
// 本文件全部离线：URLProtocol mock，不联网、不需要真实密钥，凭证与路径均为明显合成值。
// 断言只加不减：每个「本地路径」用例既要求抛错，也要求 submit 请求数为 0
// （即不创建计费任务、不把本地路径写进任何出站 body）。
//
// Mock 独立于 CloudVideoJimengTests 的 JimengMockURLProtocol：静态 handler 在并行 suite
// 之间会互相覆盖，故本文件自带一份，互不共享状态。

// MARK: - 独立 Mock URLProtocol

private final class W5JimengGateMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        W5JimengGateMockURLProtocol.receivedRequests.append(request)
        W5JimengGateMockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        guard let handler = W5JimengGateMockURLProtocol.requestHandler else {
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
    }

    /// 任何用例都不应走到网络；默认给出「成功」响应，使误发请求在断言里显式暴露。
    static func succeedWithTaskID(_ taskID: String = "synthetic-task-067") {
        requestHandler = { _ in
            let data = try! JSONSerialization.data(
                withJSONObject: ["code": 10000, "data": ["task_id": taskID], "message": "Success"]
            )
            return (200, data, ["Content-Type": "application/json"])
        }
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

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [W5JimengGateMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 合成托管桩

/// 记录被要求上传的本地路径，并按 `result` 返回托管 URL（nil = 当前环境无法托管）。
private final class W5JimengStubHosting: MediaReferenceHosting, @unchecked Sendable {
    private let result: String?
    private(set) var uploadedPaths: [String] = []

    init(result: String?) {
        self.result = result
    }

    func upload(localPath: String) async throws -> String? {
        uploadedPaths.append(localPath)
        return result
    }
}

// MARK: - 测试

@Suite(.serialized)
struct W5ProvidergateJimeng067Tests {
    private static let localFramePath = "/tmp/miniscanvas-synthetic/frame-067.png"
    private static let remoteFrameURL = "https://synthetic.test/first-frame-067.png"
    private static let hostedFrameURL = "https://hosted-synthetic.test/uploaded-frame-067.png"

    private func makeProvider(hoster: (any MediaReferenceHosting)? = nil) -> JimengProvider {
        let provider = JimengProvider(
            apiKey: nil,
            model: "jimeng_ti2v_v30_pro",
            accessKey: "AKLTsynthetic",
            secretKey: "SECRETsynthetic",
            mediaHosting: hoster
        )
        provider.session = W5JimengGateMockURLProtocol.makeSession()
        return provider
    }

    private func capturedBody() throws -> [String: Any] {
        let data = try #require(W5JimengGateMockURLProtocol.lastRequestBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 本地引用：失败关闭，且不发计费请求

    @Test func localFilePathReferenceIsRejectedAndNeverSentToCloud() async {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()   // 无托管 = 只能阻断

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localFramePath)) {
            _ = try await provider.submitVideo(
                CloudVideoRequest(prompt: "合成用例：本地首帧", imageURL: Self.localFramePath)
            )
        }
        // 把关必须在创建计费任务之前：一条出站请求都不许有。
        #expect(W5JimengGateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func fileURIAndDataURLReferencesAreAlsoTreatedAsLocalAndRejected() async {
        for raw in ["file:///tmp/miniscanvas-synthetic/frame-067.png",
                    "data:image/png;base64,c3ludGhldGljLWZyYW1l"] {
            W5JimengGateMockURLProtocol.reset()
            W5JimengGateMockURLProtocol.succeedWithTaskID()
            let provider = makeProvider()
            await #expect(throws: MediaReferenceError.self) {
                _ = try await provider.submitVideo(CloudVideoRequest(prompt: "p", imageURL: raw))
            }
            #expect(W5JimengGateMockURLProtocol.receivedRequests.isEmpty,
                    "云端不可访问的引用 \(raw.prefix(12))… 不得发出请求")
        }
    }

    @Test func extraParamsImageURLsCannotBypassTheGate() async {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()
        let leaked = "/tmp/miniscanvas-synthetic/via-extra-067.png"

        await #expect(throws: MediaReferenceError.localNotAccessible(path: leaked)) {
            _ = try await provider.submitVideo(
                CloudVideoRequest(prompt: "合成用例：extraParams 注入", extraParams: ["image_urls": leaked])
            )
        }
        #expect(W5JimengGateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func localPrimaryReferenceIsNotSilentlySwappedForARemoteExtraParam() async {
        // 本地路径优先来源仍须阻断，而不是悄悄改用 extraParams 里的远程值。
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localFramePath)) {
            _ = try await provider.submitVideo(
                CloudVideoRequest(
                    prompt: "p",
                    imageURL: Self.localFramePath,
                    extraParams: ["image_urls": Self.remoteFrameURL]
                )
            )
        }
        #expect(W5JimengGateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func hostingThatCannotUploadStillFailsClosed() async {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let hoster = W5JimengStubHosting(result: nil)   // 托管不可用
        let provider = makeProvider(hoster: hoster)

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localFramePath)) {
            _ = try await provider.submitVideo(
                CloudVideoRequest(prompt: "p", imageURL: Self.localFramePath)
            )
        }
        #expect(hoster.uploadedPaths == [Self.localFramePath])
        #expect(W5JimengGateMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: 云端可访问引用：原样/托管后透传

    @Test func remoteReferencePassesThroughUnchanged() async throws {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()

        let taskID = try await provider.submitVideo(
            CloudVideoRequest(prompt: "合成用例：远程首帧", imageURL: Self.remoteFrameURL)
        )
        #expect(taskID == "synthetic-task-067")
        let body = try capturedBody()
        #expect(body["image_urls"] as? [String] == [Self.remoteFrameURL])
    }

    @Test func localReferenceWithHostingIsUploadedAndOnlyTheHostedURLIsSent() async throws {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let hoster = W5JimengStubHosting(result: Self.hostedFrameURL)
        let provider = makeProvider(hoster: hoster)

        _ = try await provider.submitVideo(
            CloudVideoRequest(prompt: "合成用例：托管后首帧", imageURL: Self.localFramePath)
        )
        #expect(hoster.uploadedPaths == [Self.localFramePath])
        let body = try capturedBody()
        #expect(body["image_urls"] as? [String] == [Self.hostedFrameURL])
        // 出站 body 里不得残留任何本地路径。
        let bodyText = String(data: W5JimengGateMockURLProtocol.lastRequestBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("/tmp/miniscanvas-synthetic"))
    }

    @Test func extraParamsRemoteReferenceIsGatedAndSentOnce() async throws {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()

        _ = try await provider.submitVideo(
            CloudVideoRequest(prompt: "p", extraParams: ["image_urls": Self.remoteFrameURL, "seed": "-1"])
        )
        let body = try capturedBody()
        #expect(body["image_urls"] as? [String] == [Self.remoteFrameURL])
        #expect(body["seed"] as? String == "-1")   // 非引用字段照常透传
    }

    // MARK: 无引用与既有行为不受影响

    @Test func textOnlySubmitSendsNoImageURLsAndIsUnaffected() async throws {
        W5JimengGateMockURLProtocol.reset()
        W5JimengGateMockURLProtocol.succeedWithTaskID()
        let provider = makeProvider()

        _ = try await provider.submitVideo(
            CloudVideoRequest(prompt: "合成用例：纯文生视频", aspectRatio: "16:9", duration: "5")
        )
        let body = try capturedBody()
        #expect(body["image_urls"] == nil)
        #expect(body["aspect_ratio"] as? String == "16:9")
        #expect(body["frames"] as? Int == 121)
    }

    @Test func emptyAndWhitespaceReferencesAreTreatedAsAbsent() async throws {
        for raw in ["", "   "] {
            W5JimengGateMockURLProtocol.reset()
            W5JimengGateMockURLProtocol.succeedWithTaskID()
            let provider = makeProvider()
            _ = try await provider.submitVideo(CloudVideoRequest(prompt: "p", imageURL: raw))
            let body = try capturedBody()
            #expect(body["image_urls"] == nil, "空引用不写入 image_urls")
        }
    }
}
