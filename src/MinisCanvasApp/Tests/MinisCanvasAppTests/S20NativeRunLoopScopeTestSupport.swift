import Foundation
import CoreFoundation

private enum S20NativeRunLoopScopeError: Error {
    case notMainThread
    case fixtureCallbackNotDelivered
}

@MainActor
private final class S20NativeRunLoopScopeState {
    var operation: (() throws -> Void)?
    var completion: Result<Void, any Error>?

    init(_ operation: @escaping () throws -> Void) {
        self.operation = operation
    }
}

/// Keep the native fixture's launch, window teardown and policy restoration
/// inside a run-loop invocation owned by this fixture. A stop requested there
/// must not unwind SwiftPM's outer async-main executor before Testing records
/// the method's completion. This does not change the test's assertions or
/// translate a missing callback/error into success.
@MainActor
func withOwnedS20NativeRunLoopScope(_ body: () throws -> Void) throws {
    guard Thread.isMainThread else { throw S20NativeRunLoopScopeError.notMainThread }
    try withoutActuallyEscaping(body) { escapedBody in
        let state = S20NativeRunLoopScopeState(escapedBody)
        // If delivery fails, a retained CF block can no longer invoke the
        // nonescaping body after this scope has returned.
        defer { state.operation = nil }
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                guard let operation = state.operation else { return }
                state.operation = nil
                nativeTestHostBoundary("s20-owned-loop-fixture-enter")
                state.completion = Result { try operation() }
                nativeTestHostBoundary("s20-owned-loop-fixture-complete")
                // This callback runs inside the invocation below. Completion,
                // including throwing cleanup, ends that invocation immediately.
                CFRunLoopStop(loop)
            }
        }
        CFRunLoopWakeUp(loop)
        nativeTestHostBoundary("s20-owned-loop-enter")
        // A delivery deadline only: the completion callback stops this loop
        // immediately, rather than sleeping after the fixture has finished.
        let returned = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 10, false)
        nativeTestHostBoundary("s20-owned-loop-return", detail:
            "result=\(returned.rawValue) callbackCompleted=\(state.completion != nil)")
        guard let completion = state.completion else {
            throw S20NativeRunLoopScopeError.fixtureCallbackNotDelivered
        }
        try completion.get()
    }
}

