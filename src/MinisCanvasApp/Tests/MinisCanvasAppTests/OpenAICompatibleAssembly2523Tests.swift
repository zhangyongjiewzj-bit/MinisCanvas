import Foundation
import Testing
@testable import MinisCore

private final class CompatibleAssemblyBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedMain = false
    private var observedTimeout = false

    var ranOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedMain
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedTimeout
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func blockAtRealAssembly() {
        lock.lock()
        observedMain = Thread.isMainThread
        lock.unlock()
        entered.signal()
        let expired = release.wait(timeout: .now() + 3) == .timedOut
        lock.lock()
        observedTimeout = expired
        lock.unlock()
    }
}

private final class CompatibleAssemblyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var requestStarted = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestStarted = true
        Self.lastRequestBody = Self.bodyData(from: request)
        let body = Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibleAssemblyURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lastRequestBody = nil
        requestStarted = false
    }
}

@Suite("D-PERF-06 OpenAI-compatible production request assembly", .serialized)
struct OpenAICompatibleAssembly2523Tests {
    private static let fixtureCredential = "fixture"

    private static func makeProvider(gate: CompatibleAssemblyBarrier, session: URLSession) -> OpenAICompatibleProvider {
        let provider = OpenAICompatibleProvider(
            apiKey: fixtureCredential, model: .gpt4oMini,
            customBaseURL: "https://mock.test",
            session: session
        )
        provider.requestAssemblyProbe = { gate.blockAtRealAssembly() }
        return provider
    }

    @Test @MainActor
    func realRequestEncodingLeavesMainActorResponsive() async throws {
        try await B1ProviderAssemblyFixtureSupport.withSession(protocols: [CompatibleAssemblyURLProtocol.self], afterQuiescence: { CompatibleAssemblyURLProtocol.reset() }) { session in
        let gate = CompatibleAssemblyBarrier()
        let provider = Self.makeProvider(gate: gate, session: session)
        let input = String(repeating: "x", count: 64_000)
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: input)],
                systemPrompt: nil, tools: [], maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            gate.release.signal()
            do { _ = try await pending.value } catch { /* original failed admission remains an issue below; real pending is terminal */ }
            Issue.record("the production request assembly point was not reached")
            return
        }
        let heartbeat = Task { @MainActor in true }
        #expect(await heartbeat.value)
        #expect(!gate.ranOnMain)
        #expect(!gate.timedOut)
        gate.release.signal()
        let response = try await pending.value
        #expect(response.text == "ok")

        let body = try #require(CompatibleAssemblyURLProtocol.lastRequestBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == LLMModel.gpt4oMini.id)
        #expect(json["stream"] as? Bool == false)
        #expect(body.count > 64_000)
            }
    }

    @Test @MainActor
    func rebindDuringAssemblyDoesNotDispatchOldConfiguration() async throws {
        try await B1ProviderAssemblyFixtureSupport.withSession(protocols: [CompatibleAssemblyURLProtocol.self], afterQuiescence: { CompatibleAssemblyURLProtocol.reset() }) { session in
        let gate = CompatibleAssemblyBarrier()
        let provider = Self.makeProvider(gate: gate, session: session)
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil, tools: [], maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            gate.release.signal()
            do { _ = try await pending.value } catch { /* original failed admission remains an issue below; real pending is terminal */ }
            Issue.record("the production request assembly point was not reached")
            return
        }
        #expect(!gate.ranOnMain)
        #expect(!gate.timedOut)
        provider.model = LLMModel(
            id: "rebound-model", displayName: "Rebound", provider: "OpenAI"
        )
        provider.model = .gpt4oMini // A→B→A must still invalidate the old request.
        gate.release.signal()
        do {
            _ = try await pending.value
            Issue.record("a superseded request reached transport")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected a cancelled superseded request")
                return
            }
        }
        #expect(!CompatibleAssemblyURLProtocol.requestStarted)
            }
    }

    @Test @MainActor
    func cancellationDuringAssemblyDoesNotDispatch() async throws {
        try await B1ProviderAssemblyFixtureSupport.withSession(protocols: [CompatibleAssemblyURLProtocol.self], afterQuiescence: { CompatibleAssemblyURLProtocol.reset() }) { session in
        let gate = CompatibleAssemblyBarrier()
        let provider = Self.makeProvider(gate: gate, session: session)
        let pending = Task {
            try await provider.sendMessage(
                messages: [LLMMessage(role: .user, content: "fixture")],
                systemPrompt: nil, tools: [], maxTokens: 64, temperature: nil
            )
        }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        guard entered else {
            pending.cancel()
            gate.release.signal()
            do { _ = try await pending.value } catch { /* original failed admission remains an issue below; real pending is terminal */ }
            Issue.record("the production request assembly point was not reached")
            return
        }
        #expect(!gate.ranOnMain)
        pending.cancel()
        gate.release.signal()
        do {
            _ = try await pending.value
            Issue.record("a cancelled request reached transport")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("expected a cancelled request")
                return
            }
        }
        #expect(!CompatibleAssemblyURLProtocol.requestStarted)
            }
    }
}
