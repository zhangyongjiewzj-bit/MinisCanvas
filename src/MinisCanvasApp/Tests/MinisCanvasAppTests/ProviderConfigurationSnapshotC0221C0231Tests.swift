import Foundation
import Testing
import os
@testable import MinisCore

// Foundation requires restating URLProtocol's inherited unchecked Sendable.
// No custom per-instance mutable fields; all shared test state is under ONE lock.
private final class ConfigurationWireProtocol: URLProtocol, @unchecked Sendable {
    struct Facts: Sendable {
        let host: String
        let model: String
        let config: String
        let authorization: String
    }
    struct State: Sendable {
        var records: [Facts] = []
        var holdFirst = true
        var timedOut = false
        var cleanupFailed = false
        let activeCallbacks = DispatchGroup()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private struct LoadingState: Sendable {
        var stopped = false
        var release: DispatchSemaphore?
    }
    private let loading = OSAllocatedUnfairLock(initialState: LoadingState())
    override func startLoading() {
        let callbacks = Self.state.withLock { value in
            value.activeCallbacks.enter()
            return value.activeCallbacks
        }
        defer { callbacks.leave() }
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while collected.count <= 65536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            body = collected.count <= 65536 ? collected : Data()
        } else { body = Data() }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let anthropic = request.url?.path == "/v1/messages"
        let tuple = Facts(host: request.url?.host ?? "", model: json["model"] as? String ?? "",
                          config: request.value(forHTTPHeaderField: "X-Config") ?? "",
                          authorization: request.value(forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization") ?? "")
        let control = Self.state.withLock { value -> (Bool, DispatchSemaphore, DispatchSemaphore) in
            value.records.append(tuple)
            return (value.holdFirst && value.records.count == 1, value.entered, value.release)
        }
        let stopped = loading.withLock { value in
            value.release = control.2
            return value.stopped
        }
        if stopped { return }
        if control.0 {
            control.1.signal()
            if control.2.wait(timeout: .now() + 4) == .timedOut {
                Self.state.withLock { $0.timedOut = true }
            }
        }
        guard !loading.withLock({ $0.stopped }) else { return }
        let response: [String: Any] = anthropic
            ? ["content": [["type": "text", "text": "synthetic-ok"]], "stop_reason": "end_turn", "usage": ["input_tokens": 1, "output_tokens": 1]]
            : ["choices": [["message": ["role": "assistant", "content": "synthetic-ok"], "finish_reason": "stop"]], "usage": ["prompt_tokens": 1, "completion_tokens": 1]]
        let data = try! JSONSerialization.data(withJSONObject: response)
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        let release = loading.withLock { value in
            value.stopped = true
            return value.release
        }
        release?.signal()
    }
}

private func waitForConfigurationWire(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 3) == .success
}

// didInvalidate is the actual URLSession terminal callback; cancellation is
// only a request. A failed quiescence gate poisons reset rather than allowing
// later serialized methods to overwrite state while an old callback is alive.
private final class ConfigurationSessionTerminal: NSObject, URLSessionDelegate, Sendable {
    let invalidated = DispatchSemaphore(value: 0)
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        invalidated.signal()
    }
}

private func beginConfigurationWire(holdFirst: Bool) throws {
    let clean = ConfigurationWireProtocol.state.withLock { value in
        guard !value.cleanupFailed else { return false }
        value = .init()
        value.holdFirst = holdFirst
        return true
    }
    try #require(clean, "previous session/callback teardown failed; reset forbidden")
}

private func waitForConfigurationTerminal(_ terminal: DispatchSemaphore, callbacks: DispatchGroup) -> Bool {
    let invalidated = terminal.wait(timeout: .now() + 5) == .success
    let callbacksFinished = callbacks.wait(timeout: .now() + 5) == .success
    return invalidated && callbacksFinished
}

private func finishConfigurationWire(_ session: URLSession, terminal: ConfigurationSessionTerminal) async throws {
    let controls = ConfigurationWireProtocol.state.withLock { ($0.release, $0.activeCallbacks) }
    controls.0.signal()
    session.invalidateAndCancel()
    let quiesced = await Task.detached {
        waitForConfigurationTerminal(terminal.invalidated, callbacks: controls.1)
    }.value
    if !quiesced { ConfigurationWireProtocol.state.withLock { $0.cleanupFailed = true } }
    print("CONFIGURATION_WIRE_TERMINAL invalidationAndCallbacksFinished=\(quiesced)")
    try #require(quiesced, "URLSession invalidation AND protocol callback terminal were not observed")
}

private enum ConfigurationSubject: Sendable {
    case anthropic(AnthropicProvider)
    case openAI(OpenAICompatibleProvider)
    func publishB() {
        // Every setter is a published configuration revision. This does NOT
        // pretend multiple independent setter calls form one transaction.
        switch self {
        case .anthropic(let provider):
            provider.model = LLMModel(id: "model-b", displayName: "B", provider: "Anthropic")
            provider.customBasePath = "https://provider-b.invalid"
            provider.extraHeaders = ["X-Config": "B"]
        case .openAI(let provider):
            provider.model = LLMModel(id: "model-b", displayName: "B", provider: "OpenAI")
            provider.customBaseURL = "https://provider-b.invalid"
            provider.appendV1Suffix = true
            provider.extraHeaders = ["X-Config": "B"]
            provider.useOpenRouterCompat = true
        }
    }
    func send() async throws -> LLMResponse {
        switch self {
        case .anthropic(let provider):
            return try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "synthetic")],
                systemPrompt: nil, maxTokens: 8, temperature: nil)
        case .openAI(let provider):
            return try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "synthetic")],
                systemPrompt: nil, maxTokens: 8, temperature: nil)
        }
    }
}

@Suite(.serialized)
struct ProviderConfigurationSnapshotC0221C0231Tests {
    private func make(_ anthropic: Bool, key: String, session: URLSession) -> ConfigurationSubject {
        if anthropic {
            let provider = AnthropicProvider(apiKey: key,
                model: LLMModel(id: "model-a", displayName: "A", provider: "Anthropic"),
                basePath: "https://provider-a.invalid", session: session)
            provider.extraHeaders = ["X-Config": "A"]
            return .anthropic(provider)
        }
        let provider = OpenAICompatibleProvider(apiKey: key,
            model: LLMModel(id: "model-a", displayName: "A", provider: "OpenAI"),
            customBaseURL: "https://provider-a.invalid", session: session)
        provider.extraHeaders = ["X-Config": "A"]
        return .openAI(provider)
    }
    private func exerciseInFlight(_ anthropic: Bool) async throws {
        try beginConfigurationWire(holdFirst: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfigurationWireProtocol.self]
        let terminal = ConfigurationSessionTerminal()
        let session = URLSession(configuration: config, delegate: terminal, delegateQueue: nil)
        let subject = make(anthropic, key: "synthetic-record-A", session: session)
        let pending = Task { try await subject.send() }
        let controls = ConfigurationWireProtocol.state.withLock { ($0.entered, $0.release) }
        do {
        let entered = await Task.detached { waitForConfigurationWire(controls.0) }.value
        try #require(entered, "real URLSession request boundary was not reached")
        subject.publishB()
        controls.1.signal()
        let first = try await pending.value
        #expect(first.text == "synthetic-ok")
        let second = try await subject.send()
        #expect(second.text == "synthetic-ok")
        let differentRecord = make(anthropic, key: "synthetic-record-B", session: session)
        _ = try await differentRecord.send()
        let records = ConfigurationWireProtocol.state.withLock { $0.records }
        try #require(records.count == 3)
        #expect(records[0].host == "provider-a.invalid" && records[0].model == "model-a" && records[0].config == "A")
        #expect(records[1].host == "provider-b.invalid" && records[1].model == "model-b" && records[1].config == "B")
        let a = anthropic ? "synthetic-record-A" : "Bearer synthetic-record-A"
        let b = anthropic ? "synthetic-record-B" : "Bearer synthetic-record-B"
        #expect(records[0].authorization == a && records[1].authorization == a)
        #expect(records[2].authorization == b)
        #expect(!ConfigurationWireProtocol.state.withLock { $0.timedOut })
        } catch {
            controls.1.signal()
            pending.cancel()
            _ = await pending.result // join even when #require or send threw
            try await finishConfigurationWire(session, terminal: terminal)
            throw error
        }
        controls.1.signal()
        _ = await pending.result // explicit join also on successful assertion path
        try await finishConfigurationWire(session, terminal: terminal)
    }
    @Test
    func anthropicAlreadyDispatchedSnapshotAndNextTurnConfigurationStaySeparate() async throws {
        try await exerciseInFlight(true)
    }
    @Test
    func openAIAlreadyDispatchedSnapshotAndNextTurnConfigurationStaySeparate() async throws {
        try await exerciseInFlight(false)
    }

    // These exercise production mutable properties concurrently. The baseline
    // race is a TSan RED input, NOT a guaranteed Release assertion failure.
    // Do not claim observed RED/GREEN until an actual qualified run exists.
    @Test
    func anthropicConcurrentConfigurationAccessAndActualRequestsTSanInput() async throws {
        try await exerciseConcurrent(true)
    }
    @Test
    func openAIConcurrentConfigurationAccessAndActualRequestsTSanInput() async throws {
        try await exerciseConcurrent(false)
    }
    private func exerciseConcurrent(_ anthropic: Bool) async throws {
        try beginConfigurationWire(holdFirst: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfigurationWireProtocol.self]
        let terminal = ConfigurationSessionTerminal()
        let session = URLSession(configuration: config, delegate: terminal, delegateQueue: nil)
        let subject = make(anthropic, key: "synthetic-race-only", session: session)
        let writer = Task.detached {
            DispatchQueue.concurrentPerform(iterations: 200) { i in
                switch subject {
                case .anthropic(let provider):
                    provider.model = LLMModel(id: i.isMultiple(of: 2) ? "model-a" : "model-b", displayName: "synthetic", provider: "Anthropic")
                    provider.extraHeaders = ["X-Config": String(i)]
                    _ = provider.model; _ = provider.extraHeaders
                    provider.runtimeConfigurationMaterial = "synthetic-identity"
                    _ = provider.runtimeConfigurationMaterial
                case .openAI(let provider):
                    provider.model = LLMModel(id: i.isMultiple(of: 2) ? "model-a" : "model-b", displayName: "synthetic", provider: "OpenAI")
                    provider.extraHeaders = ["X-Config": String(i)]
                    provider.appendV1Suffix = true; provider.useOpenRouterCompat = i.isMultiple(of: 2)
                    _ = provider.model; _ = provider.extraHeaders
                    provider.runtimeConfigurationMaterial = "synthetic-identity"
                    _ = provider.runtimeConfigurationMaterial
                }
            }
        }
        do {
            for _ in 0..<8 {
                do { _ = try await subject.send() }
                catch let failure as LLMError {
                    guard case .cancelled = failure else { throw failure }
                }
            }
        await writer.value
        // A stable post-race positive must reach the real provider transport.
        _ = try await subject.send()
        let records = ConfigurationWireProtocol.state.withLock { $0.records }
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { ["model-a", "model-b"].contains($0.model) })
        #expect(records.allSatisfy { $0.authorization == (anthropic ? "synthetic-race-only" : "Bearer synthetic-race-only") })
        } catch {
            writer.cancel()
            await writer.value // join finite writer on EVERY throwing path
            try await finishConfigurationWire(session, terminal: terminal)
            throw error
        }
        await writer.value
        try await finishConfigurationWire(session, terminal: terminal)
    }
}
