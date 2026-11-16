import Foundation
import Testing
@testable import MinisCore

private final class OwnedMMLocalProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var status = 200
    }
    private static let state = State()
    static func reset(status: Int = 200) { state.lock.lock(); state.calls = 0; state.status = status; state.lock.unlock() }
    static var calls: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.calls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock(); Self.state.calls += 1; let status = Self.state.status; Self.state.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        let data = Data(#"{"id":"synthetic","choices":[{"message":{"role":"assistant","content":"synthetic"},"finish_reason":"stop"}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OwnedMMLocalProtocol.self]
        config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }
}

@Suite("Owned MM local URLProtocol boundary", .serialized)
struct OwnedMMOutboundURLProtocolTests {
    private func provider(_ session: URLSession, _ ledger: OwnedMMOutboundLedger? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: "[configured locally]", customBaseURL: "https://fixture.invalid",
            appendV1Suffix: false, session: session, ownedMMOutboundLedger: ledger)
    }
    private func send(_ provider: OpenAICompatibleProvider) async throws {
        _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "synthetic")],
            systemPrompt: nil, maxTokens: 8, temperature: nil)
    }
    @Test func nilLedgerKeepsOriginalBufferedRequest() async throws {
        OwnedMMLocalProtocol.reset()
        let session = OwnedMMLocalProtocol.session(); defer { session.invalidateAndCancel() }
        try await send(provider(session))
        #expect(OwnedMMLocalProtocol.calls == 1)
    }
    @Test func missingActionIsRefusedBeforeLocalInterceptor() async {
        OwnedMMLocalProtocol.reset()
        let session = OwnedMMLocalProtocol.session(); defer { session.invalidateAndCancel() }
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234, sink: { _ in })
        do { try await send(provider(session, ledger)); Issue.record("missing action reached success") }
        catch { }
        #expect(OwnedMMLocalProtocol.calls == 0)
        #expect(ledger.snapshot.admitted == 0 && ledger.snapshot.stopped)
    }
    @Test func admittedVisual503StopsAndDoesNotRetryOrFallback() async throws {
        OwnedMMLocalProtocol.reset(status: 503)
        let session = OwnedMMLocalProtocol.session(); defer { session.invalidateAndCancel() }
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234, sink: { _ in })
        let action = try ledger.beginAction(.providerReadinessButton)
        // Pure pre-state, not a claim about observed Darwin metrics.
        for phase in [OwnedMMPhase.reachability, .authentication, .modelDiscovery, .minimalText] {
            let permit = try ledger.beforeSend(action: action, phase: phase)
            ledger.recordMetrics(permit, taskID: phase.rawValue, count: 1)
            ledger.finish(permit, taskID: phase.rawValue, status: 200, errorPresent: false)
        }
        let visual = try ledger.beginAction(.composerSendButton)
        let provider = provider(session, ledger)
        for _ in 0..<2 {
            do {
                try await OwnedMMOutboundContext.$action.withValue(visual) { try await send(provider) }
                Issue.record("503 or stopped window reached success")
            } catch { }
        }
        #expect(OwnedMMLocalProtocol.calls == 1)
        #expect(ledger.snapshot.admitted == 5 && ledger.snapshot.stopped)
    }
}
