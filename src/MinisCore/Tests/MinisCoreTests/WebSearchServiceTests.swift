import Foundation
import Testing
@testable import MinisCore

// E1 联网搜索 web_search：三种后端的请求构造与结果解析、未配置时不可用/不广播、
// 密钥脱敏、重定向拒绝。全部用 URLProtocol 桩与合成密钥，不联网。

final class WebSearchStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.requests.append((request, body))
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data, headers) = handler(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { handler = nil; requests = [] }

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
}

@Suite(.serialized)
struct WebSearchServiceTests {
    private let syntheticKey = "synthetic-search-key-0123456789abcdef"

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func service(_ configuration: WebSearchConfiguration, key: String? = nil) -> WebSearchService {
        let lookedUp = key
        return WebSearchService(
            configurationProvider: { configuration },
            keyLookup: { _ in lookedUp },
            session: stubSession())
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: Brave

    @Test func braveRequestAndParsing() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in
            (200, self.json(["web": ["results": [
                ["title": "Swift <strong>语言</strong>", "url": "https://swift.org/", "description": "A &amp; B <b>bold</b>"],
                ["title": "坏链接", "url": "javascript:alert(1)", "description": "x"],
                ["title": "Second", "url": "https://example.com/2", "description": "two"],
                ["title": "Third", "url": "https://example.com/3", "description": "three"],
            ]]]), ["Content-Type": "application/json"])
        }
        let svc = service(WebSearchConfiguration(backend: .brave, maxResults: 2), key: syntheticKey)
        let output = try decode(try await svc.execute(input: ["query": "swift 并发 c++"]))
        let request = try #require(WebSearchStubProtocol.requests.first?.request)
        #expect(request.url?.host == "api.search.brave.com")
        #expect(request.url?.path == "/res/v1/web/search")
        let query = request.url?.query ?? ""
        #expect(query.contains("count=2"))
        #expect(query.contains("c%2B%2B"), "加号必须编码，否则搜索词会被服务端当成空格")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == syntheticKey)
        let results = try #require(output["untrustedResults"] as? [[String: String]])
        #expect(results.count == 2, "条数受配置限制，非 http(s) 链接被丢弃")
        #expect(results[0]["title"] == "Swift 语言")
        #expect(results[0]["snippet"] == "A & B bold")
        #expect(results[1]["url"] == "https://example.com/2")
        #expect(output["backend"] as? String == "brave")
    }

    @Test func braveWithoutResultsFieldIsEmptyNotError() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in (200, self.json(["type": "search"]), [:]) }
        let svc = service(WebSearchConfiguration(backend: .brave), key: syntheticKey)
        let output = try decode(try await svc.execute(input: ["query": "nothing"]))
        #expect((output["untrustedResults"] as? [Any])?.isEmpty == true)
    }

    // MARK: Tavily

    @Test func tavilyRequestAndParsing() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in
            (200, self.json(["results": [["title": "T", "url": "https://t.example/1", "content": "snippet"]]]), [:])
        }
        let svc = service(WebSearchConfiguration(backend: .tavily, maxResults: 3), key: syntheticKey)
        let output = try decode(try await svc.execute(input: ["query": "hello"]))
        let captured = try #require(WebSearchStubProtocol.requests.first)
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.url?.host == "api.tavily.com")
        #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(syntheticKey)")
        let body = try #require(captured.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["query"] as? String == "hello")
        #expect(sent["max_results"] as? Int == 3)
        #expect(sent["api_key"] == nil, "密钥只放 Authorization 头，不进请求体")
        let results = try #require(output["untrustedResults"] as? [[String: String]])
        #expect(results.first?["snippet"] == "snippet")
    }

    // MARK: SearXNG

    @Test func searxngRequestAndParsing() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in
            (200, self.json(["results": [["title": "S", "url": "http://news.example/a", "content": "c"]]]), [:])
        }
        let svc = service(WebSearchConfiguration(backend: .searxng, searxngBaseURL: "http://localhost:8080/"))
        _ = try await svc.execute(input: ["query": "a b&c"])
        let request = try #require(WebSearchStubProtocol.requests.first?.request)
        #expect(request.url?.host == "localhost")
        #expect(request.url?.port == 8080)
        #expect(request.url?.path == "/search")
        #expect(request.url?.query == "q=a%20b%26c&format=json")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func searxngMissingResultsFieldIsInvalidResponse() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in (200, Data("<html>forbidden format</html>".utf8), [:]) }
        let svc = service(WebSearchConfiguration(backend: .searxng, searxngBaseURL: "https://s.example"))
        await #expect(throws: WebSearchError.invalidResponse) {
            _ = try await svc.execute(input: ["query": "x"])
        }
    }

    // MARK: 可用性与失败

    @Test func unusableConfigurationsAreUnavailableAndRefuseToRun() async throws {
        let cases: [(WebSearchConfiguration, String?)] = [
            (WebSearchConfiguration(backend: .off), syntheticKey),
            (WebSearchConfiguration(backend: .brave), nil),
            (WebSearchConfiguration(backend: .tavily), ""),
            (WebSearchConfiguration(backend: .searxng, searxngBaseURL: nil), nil),
            (WebSearchConfiguration(backend: .searxng, searxngBaseURL: "ftp://x.example"), nil),
            (WebSearchConfiguration(backend: .searxng, searxngBaseURL: "http://user:pw@x.example"), nil),
        ]
        for (configuration, key) in cases {
            WebSearchStubProtocol.reset()
            let svc = service(configuration, key: key)
            #expect(!svc.isAvailable, "\(configuration.backend) 配置不可用时不得算可用")
            await #expect(throws: ToolExecutorError.toolNotConfigured("web_search")) {
                _ = try await svc.execute(input: ["query": "x"])
            }
            #expect(WebSearchStubProtocol.requests.isEmpty, "不可用时不得发出任何网络请求")
        }
    }

    @Test func httpFailuresAreErrorsAndNeverLeakTheKey() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        let svc = service(WebSearchConfiguration(backend: .brave), key: syntheticKey)
        for status in [401, 429, 500, 302] {
            WebSearchStubProtocol.handler = { _, _ in
                (status, Data("echo \(self.syntheticKey)".utf8), status == 302 ? ["Location": "https://evil.example/"] : [:])
            }
            do {
                _ = try await svc.execute(input: ["query": "x"])
                Issue.record("HTTP \(status) 必须抛错")
            } catch let error as WebSearchError {
                #expect(error == .httpStatus(status))
                #expect(!(error.errorDescription ?? "").contains(syntheticKey))
            }
        }
        #expect(!WebSearchStubProtocol.requests.contains { $0.request.url?.host == "evil.example" },
                "带密钥的请求不得跟随重定向")
    }

    @Test func resultTextIsRedactedOfKnownKey() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in
            (200, self.json(["web": ["results": [
                ["title": "t", "url": "https://x.example/", "description": "leak \(self.syntheticKey) end"],
            ]]]), [:])
        }
        let svc = service(WebSearchConfiguration(backend: .brave), key: syntheticKey)
        let text = try await svc.execute(input: ["query": "x"])
        #expect(!text.contains(syntheticKey))
    }

    @Test func invalidQueriesAreRejectedBeforeAnyRequest() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        let svc = service(WebSearchConfiguration(backend: .searxng, searxngBaseURL: "https://s.example"))
        await #expect(throws: ToolExecutorError.missingParameter("query")) {
            _ = try await svc.execute(input: [:])
        }
        await #expect(throws: ToolExecutorError.missingParameter("query")) {
            _ = try await svc.execute(input: ["query": "   "])
        }
        await #expect(throws: ToolExecutorError.invalidParameter("query")) {
            _ = try await svc.execute(input: ["query": String(repeating: "a", count: 401)])
        }
        #expect(WebSearchStubProtocol.requests.isEmpty)
    }

    // MARK: 执行器接线

    @Test func executorAdvertisesOnlyWhenConfiguredAndDispatches() async throws {
        WebSearchStubProtocol.reset()
        defer { WebSearchStubProtocol.reset() }
        WebSearchStubProtocol.handler = { _, _ in
            (200, self.json(["results": [["title": "S", "url": "https://s.example/a", "content": "c"]]]), [:])
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 默认执行器：无服务，不广播，调用诚实失败（见 WebSearchHonestFailureTests）。
        let plain = BuiltinToolExecutor(allowedRoot: root)
        #expect(!plain.webSearchConfigured)
        #expect(!plain.webSearchAvailable)

        let unusable = BuiltinToolExecutor(allowedRoot: root, webSearch: service(WebSearchConfiguration(backend: .off)))
        unusable.registerToolNames([WebSearchToolContract.toolName])
        #expect(unusable.webSearchConfigured)
        #expect(!unusable.webSearchAvailable)
        await #expect(throws: ToolExecutorError.toolNotConfigured("web_search")) {
            _ = try await unusable.execute(name: "web_search", input: ["query": "x"])
        }

        let configured = BuiltinToolExecutor(
            allowedRoot: root,
            webSearch: service(WebSearchConfiguration(backend: .searxng, searxngBaseURL: "https://s.example")))
        configured.registerToolNames([WebSearchToolContract.toolName])
        #expect(configured.webSearchAvailable)
        let output = try decode(try await configured.execute(name: "web_search", input: ["query": "x"]))
        #expect((output["untrustedResults"] as? [[String: String]])?.count == 1)
    }

    // MARK: 配置

    @Test func oldOrEmptyJSONDecodesToOffAndStoreRoundTrips() throws {
        let empty = try JSONDecoder().decode(WebSearchConfiguration.self, from: Data("{}".utf8))
        #expect(empty.backend == .off)
        #expect(empty.maxResults == WebSearchConfiguration.defaultMaxResults)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSearchServiceTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WebSearchSettingsStore(fileURL: file)
        #expect(store.configuration.backend == .off)
        #expect(store.update(WebSearchConfiguration(
            backend: .tavily, apiKeyEnvVar: "  MY_TAVILY_API_KEY ", searxngBaseURL: "  ", maxResults: 99)))
        let reloaded = WebSearchSettingsStore(fileURL: file).configuration
        #expect(reloaded.backend == .tavily)
        #expect(reloaded.apiKeyEnvVar == "MY_TAVILY_API_KEY")
        #expect(reloaded.searxngBaseURL == nil)
        #expect(reloaded.maxResults == 10)
        let stored = try String(contentsOf: file, encoding: .utf8)
        #expect(!stored.lowercased().contains("secret"), "文件里只有环境变量名，没有密钥值")
    }
}
