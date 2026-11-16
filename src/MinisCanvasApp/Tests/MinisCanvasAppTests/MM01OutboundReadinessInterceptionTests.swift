import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class MM01ReadinessLocalProtocol: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable { let lock = NSLock(); var count = 0 }
    private static let counter = Counter()
    static func reset() { counter.lock.lock(); counter.count = 0; counter.lock.unlock() }
    static var count: Int { counter.lock.lock(); defer { counter.lock.unlock() }; return counter.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.lock.lock(); Self.counter.count += 1; Self.counter.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MM01ReadinessLocalProtocol.self]
        c.timeoutIntervalForRequest = 1; c.timeoutIntervalForResource = 2
        return URLSession(configuration: c)
    }
}

@Suite("MM01 readiness explicit attribution interception", .serialized)
@MainActor struct MM01OutboundReadinessInterceptionTests {
    private func request() -> ProviderReadinessTransportRequest {
        ProviderReadinessTransportRequest(operation: .reachability, providerID: "synthetic-provider",
            baseURL: URL(string: "https://fixture.invalid")!, apiKey: "[configured locally]",
            modelID: nil, protocolType: .openaiCompatible)
    }
    @Test func nilAuditKeepsOriginalReadinessTransport() async throws {
        MM01ReadinessLocalProtocol.reset()
        let session = MM01ReadinessLocalProtocol.session(); defer { session.invalidateAndCancel() }
        let response = try await URLSessionProviderReadinessTransport(remoteContractSession: session).send(request())
        #expect(response.statusCode == 200 && MM01ReadinessLocalProtocol.count == 1)
    }
    @Test func auditedMissingTicketStopsBeforeLocalInterceptor() async {
        MM01ReadinessLocalProtocol.reset()
        let session = MM01ReadinessLocalProtocol.session(); defer { session.invalidateAndCancel() }
        let ledger = OwnedMMOutboundLedger(runIdentity: "synthetic", pid: 1234, sink: { _ in })
        let transport = URLSessionProviderReadinessTransport(session: session, ownedMMOutboundLedger: ledger)
        do { _ = try await transport.send(request()); Issue.record("missing ticket was accepted") }
        catch { }
        #expect(MM01ReadinessLocalProtocol.count == 0 && ledger.snapshot.admitted == 0)
        #expect(ledger.snapshot.stopped)
    }
    @Test func typedCompositionReadySchemaIsSecretFreeAndNonMMIsSilent() throws {
        let flag = DeepSeekMM01FieldLane.activationArgument
        var output: [Data] = []
        func emit(_ arguments: [String], mode: RuntimeIsolationProfile.Mode = .packagedField,
                  ready: Bool = true, nonce: String? = "synthetic-window-nonce") -> Bool {
            MM01CompositionReadyMarker.emit(arguments: arguments, mode: mode, pid: 1234,
                profileIdentity: "packagedField:synthetic-root", windowNonce: nonce,
                compositionPresent: ready, laneInstalled: ready, actionLedgerInstalled: ready,
                budgetCounts: (installed: true, limit: 7, reserved: 1, refused: 0),
                monotonicNanoseconds: 42, sink: { output.append($0) })
        }
        #expect(!emit(["synthetic-App"]))
        #expect(!emit(["synthetic-App", flag, flag]))
        #expect(!emit(["synthetic-App", flag], mode: .production))
        #expect(output.isEmpty)
        #expect(emit(["synthetic-App", flag]))
        #expect(output.count == 1 && output[0].last == 10)
        let decoded = try JSONSerialization.jsonObject(with: output[0])
        let row = try #require(decoded as? [String: Any])
        #expect(Set(row.keys) == Set(["schema", "pid", "profile_identity", "window_nonce",
            "monotonic_nanoseconds", "composition_present", "lane_installed", "action_ledger_installed",
            "read_budget_installed", "read_budget_limit", "read_budget_reserved", "read_budget_refused"]))
        #expect(row["schema"] as? String == "MM01_TYPED_COMPOSITION_READY_V1")
        #expect(row["pid"] as? Int == 1234 && row["window_nonce"] as? String == "synthetic-window-nonce")
        #expect(row["composition_present"] as? Bool == true && row["lane_installed"] as? Bool == true
            && row["action_ledger_installed"] as? Bool == true)
        #expect(row["read_budget_limit"] as? Int == 7 && row["read_budget_reserved"] as? Int == 1)
        let forbidden = ["credential", "secret", "length", "hash", "url", "header", "body", "env", "error"]
        #expect(!row.keys.contains { key in forbidden.contains { key.lowercased().contains($0) } })
        #expect(emit(["synthetic-App", flag], ready: false, nonce: nil))
        let refusedDecoded = try JSONSerialization.jsonObject(with: output[1])
        let refused = try #require(refusedDecoded as? [String: Any])
        #expect(refused["composition_present"] as? Bool == false && refused["lane_installed"] as? Bool == false
            && refused["action_ledger_installed"] as? Bool == false && refused["window_nonce"] is NSNull)
    }

}
