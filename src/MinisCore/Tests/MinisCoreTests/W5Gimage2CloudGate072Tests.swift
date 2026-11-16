import Foundation
import Testing
@testable import MinisCore

// W5-GIMAGE2-CLOUD-GATE-072：P1-13「参考图必须云端可访问」在 Gimage2 云端生图侧的把关回归测试。
//
// 背景：`MediaReferenceGate.resolveForCloud`（MediaReference.swift:103-119）要求本地路径
// 参考图要么经托管上传换成云端 URL，要么失败关闭（抛 `MediaReferenceError.localNotAccessible`）。
// Kling（KlingProvider.swift:130-132）已接入；Gimage2Provider.generateImage 此前把
// request.imageURL 原样写进出站 body 的 `image` 字段（且 extraParams 可整体覆写同键），
// 本地路径会被直接发给云端生图 API。
//
// 本文件全部离线：URLProtocol mock，不联网、不需要真实密钥，凭证与路径均为明显合成值。
// 每个「本地引用」用例既断言具体错误，也断言出站请求数为 0
// （即关卡在组装 body / 发出计费请求之前，本地路径绝不进任何云端请求体）。
//
// Mock 结构整体复制同 target 已编译先例 CloudVideoJimengTests.swift:18-84
// （nonisolated(unsafe) 静态记录 + makeSession），命名独立避免与其互相覆盖状态。

// MARK: - 独立 Mock URLProtocol（先例：CloudVideoJimengTests.swift:18-84）

private final class W5Gimage2GateMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        W5Gimage2GateMockURLProtocol.receivedRequests.append(request)
        W5Gimage2GateMockURLProtocol.lastRequestBody = Self.bodyData(from: request)
        guard let handler = W5Gimage2GateMockURLProtocol.requestHandler else {
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

    /// 任何「本地引用」用例都不应走到网络；默认给出「成功」响应，
    /// 使误发请求在 receivedRequests 断言里显式暴露。
    static func succeedWithImageURL(_ url: String = "https://synthetic.test/out-072.png") {
        requestHandler = { _ in
            let data = try! JSONSerialization.data(
                withJSONObject: ["created": 1, "data": [["url": url]]]
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
        config.protocolClasses = [W5Gimage2GateMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 合成托管桩（actor 可变记录先例：ProviderCancellationBoundarySecurityTests.swift:122-131）

/// 记录被要求上传的本地路径，并按 `result` 返回托管 URL（nil = 当前环境无法托管）。
private actor W5Gimage2StubHosting: MediaReferenceHosting {
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
struct W5Gimage2CloudGate072Tests {
    private static let localRefPath = "/tmp/miniscanvas-synthetic/ref-072.png"
    private static let remoteRefURL = "https://synthetic.test/ref-072.png"
    private static let hostedRefURL = "https://hosted-synthetic.test/uploaded-ref-072.png"

    private func makeProvider(hoster: (any MediaReferenceHosting)? = nil) -> Gimage2Provider {
        let provider = Gimage2Provider(
            apiKey: "synthetic-key-072",
            baseURL: "https://synthetic.test",
            mediaHosting: hoster
        )
        provider.session = W5Gimage2GateMockURLProtocol.makeSession()
        return provider
    }

    private func capturedBody() throws -> [String: Any] {
        let data = try #require(W5Gimage2GateMockURLProtocol.lastRequestBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 本地引用：失败关闭，且不发任何出站请求

    @Test func localFilePathReferenceIsRejectedAndNeverSentToCloud() async {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()   // 无托管 = 只能阻断

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localRefPath)) {
            _ = try await provider.generateImage(
                CloudImageRequest(prompt: "合成用例：本地图生图", imageURL: Self.localRefPath)
            )
        }
        // 把关必须发生在组装 body 与计费 POST 之前：一条出站请求都不许有。
        #expect(W5Gimage2GateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func fileURIAndDataURLReferencesAreAlsoTreatedAsLocalAndRejected() async {
        for raw in ["file:///tmp/miniscanvas-synthetic/ref-072.png",
                    "data:image/png;base64,c3ludGhldGljLXJlZi0wNzI="] {
            W5Gimage2GateMockURLProtocol.reset()
            W5Gimage2GateMockURLProtocol.succeedWithImageURL()
            let provider = makeProvider()
            await #expect(throws: MediaReferenceError.self) {
                _ = try await provider.generateImage(
                    CloudImageRequest(prompt: "p", imageURL: raw)
                )
            }
            #expect(W5Gimage2GateMockURLProtocol.receivedRequests.isEmpty,
                    "云端不可访问的引用 \(raw.prefix(12))… 不得发出请求")
        }
    }

    @Test func extraParamsImageCannotBypassTheGate() async {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()
        let leaked = "/tmp/miniscanvas-synthetic/via-extra-072.png"

        await #expect(throws: MediaReferenceError.localNotAccessible(path: leaked)) {
            _ = try await provider.generateImage(
                CloudImageRequest(prompt: "p", extraParams: ["image": leaked])
            )
        }
        #expect(W5Gimage2GateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func localPrimaryReferenceIsNotSilentlySwappedForARemoteExtraParam() async {
        // 本地路径优先来源仍须阻断，而不是悄悄改用 extraParams 里的远程值。
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localRefPath)) {
            _ = try await provider.generateImage(
                CloudImageRequest(
                    prompt: "p",
                    imageURL: Self.localRefPath,
                    extraParams: ["image": Self.remoteRefURL]
                )
            )
        }
        #expect(W5Gimage2GateMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test func hostingThatCannotUploadStillFailsClosed() async {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let hoster = W5Gimage2StubHosting(result: nil)   // 托管不可用
        let provider = makeProvider(hoster: hoster)

        await #expect(throws: MediaReferenceError.localNotAccessible(path: Self.localRefPath)) {
            _ = try await provider.generateImage(
                CloudImageRequest(prompt: "p", imageURL: Self.localRefPath)
            )
        }
        #expect(await hoster.uploadedPaths == [Self.localRefPath])
        #expect(W5Gimage2GateMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: 云端可访问引用：原样/托管后透传

    @Test func remoteReferencePassesThroughUnchanged() async throws {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()

        let result = try await provider.generateImage(
            CloudImageRequest(prompt: "合成用例：远程图生图", imageURL: Self.remoteRefURL)
        )
        #expect(result.images.first?.url == "https://synthetic.test/out-072.png")
        let body = try capturedBody()
        #expect(body["image"] as? String == Self.remoteRefURL)
    }

    @Test func localReferenceWithHostingIsUploadedAndOnlyTheHostedURLIsSent() async throws {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let hoster = W5Gimage2StubHosting(result: Self.hostedRefURL)
        let provider = makeProvider(hoster: hoster)

        _ = try await provider.generateImage(
            CloudImageRequest(prompt: "合成用例：托管后图生图", imageURL: Self.localRefPath)
        )
        #expect(await hoster.uploadedPaths == [Self.localRefPath])
        let body = try capturedBody()
        #expect(body["image"] as? String == Self.hostedRefURL)
        // 出站 body 里不得残留任何本地路径。
        let bodyText = String(data: W5Gimage2GateMockURLProtocol.lastRequestBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("/tmp/miniscanvas-synthetic"))
    }

    @Test func extraParamsRemoteReferenceIsGatedAndSentOnce() async throws {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()

        _ = try await provider.generateImage(
            CloudImageRequest(prompt: "p", extraParams: ["image": Self.remoteRefURL, "seed": "-1"])
        )
        let body = try capturedBody()
        #expect(body["image"] as? String == Self.remoteRefURL)
        #expect(body["seed"] as? String == "-1")   // 非引用字段照常透传
    }

    // MARK: 无引用与既有行为不受影响

    @Test func textOnlyRequestSendsNoImageFieldAndIsUnaffected() async throws {
        W5Gimage2GateMockURLProtocol.reset()
        W5Gimage2GateMockURLProtocol.succeedWithImageURL()
        let provider = makeProvider()

        _ = try await provider.generateImage(
            CloudImageRequest(prompt: "合成用例：纯文生图", negativePrompt: "模糊", size: "1024x1024")
        )
        let body = try capturedBody()
        #expect(body["image"] == nil)
        #expect(body["size"] as? String == "1024x1024")
        #expect(body["negative_prompt"] as? String == "模糊")
        #expect(body["response_format"] as? String == "b64_json")
        #expect(W5Gimage2GateMockURLProtocol.receivedRequests.count == 1)
    }

    @Test func emptyAndWhitespaceReferencesAreTreatedAsAbsent() async throws {
        for raw in ["", "   "] {
            W5Gimage2GateMockURLProtocol.reset()
            W5Gimage2GateMockURLProtocol.succeedWithImageURL()
            let provider = makeProvider()
            _ = try await provider.generateImage(
                CloudImageRequest(prompt: "p", imageURL: raw)
            )
            let body = try capturedBody()
            #expect(body["image"] == nil, "空引用不写入 image 字段")
        }
    }
}
