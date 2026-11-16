import Foundation
import Testing

private final class B1ProviderAssemblySessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callbackFailed = false
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        lock.withLock { callbackFailed = error != nil }
        finished.signal()
    }
    func waitForRealInvalidation() -> Bool {
        let done = finished.wait(timeout: .now() + 5) == .success
        return done && lock.withLock { !callbackFailed }
    }
}
private final class B1ProviderAssemblyTransportRejection: URLProtocol, @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
    }
    private static let counter = Counter()
    static var dispatchCount: Int { counter.lock.withLock { counter.value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.lock.withLock { Self.counter.value += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
enum B1ProviderAssemblyFixtureSupport {
    private enum Failure: Error { case didNotQuiesce, unexpectedTransport, both(business: any Error, cleanup: any Error) }
    @MainActor static func withSession(protocols: [AnyClass], rejectAllTransport: Bool = false, afterQuiescence: @MainActor () -> Void = {},
        _ body: @MainActor (URLSession) async throws -> Void) async throws {
        let delegate = B1ProviderAssemblySessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = rejectAllTransport ? [B1ProviderAssemblyTransportRejection.self] : protocols
        let previousDispatches = B1ProviderAssemblyTransportRejection.dispatchCount
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let business: Result<Void, any Error>
        do { try await body(session); business = .success(()) }
        catch { business = .failure(error) }
        session.finishTasksAndInvalidate()
        let quiesced = await Task.detached { delegate.waitForRealInvalidation() }.value
        var cleanup: (any Error)?
        if !quiesced { cleanup = Failure.didNotQuiesce }
        if rejectAllTransport && B1ProviderAssemblyTransportRejection.dispatchCount != previousDispatches { cleanup = Failure.unexpectedTransport }
        if let cleanup {
            if case .failure(let original) = business { throw Failure.both(business: original, cleanup: cleanup) }
            throw cleanup
        }
        afterQuiescence()
        print("CONC2_ASSEMBLY_SESSION didInvalidate=true pendingJoined=true")
        try business.get()
    }

    static func withNonActorSession(protocols: [AnyClass], rejectAllTransport: Bool = false, afterQuiescence: () -> Void = {},
        _ body: (URLSession) async throws -> Void) async throws {
        let delegate = B1ProviderAssemblySessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = rejectAllTransport ? [B1ProviderAssemblyTransportRejection.self] : protocols
        let previousDispatches = B1ProviderAssemblyTransportRejection.dispatchCount
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let business: Result<Void, any Error>
        do { try await body(session); business = .success(()) }
        catch { business = .failure(error) }
        session.finishTasksAndInvalidate()
        let quiesced = await Task.detached { delegate.waitForRealInvalidation() }.value
        var cleanup: (any Error)?
        if !quiesced { cleanup = Failure.didNotQuiesce }
        if rejectAllTransport && B1ProviderAssemblyTransportRejection.dispatchCount != previousDispatches { cleanup = Failure.unexpectedTransport }
        if let cleanup {
            if case .failure(let original) = business { throw Failure.both(business: original, cleanup: cleanup) }
            throw cleanup
        }
        afterQuiescence()
        print("CONC2_ASSEMBLY_SESSION didInvalidate=true pendingJoined=true")
        try business.get()
    }
}
