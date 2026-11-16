import Dispatch

/// Runs synchronous fixture work off Swift's cooperative executor.
/// This bridge does not propagate Task cancellation or Task-local values into
/// GCD. Use it only where the synchronous operation does not inspect that state.
func runBlockingTestWork<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            // A single worker owns completion, including throws and late finish.
            continuation.resume(with: Swift.Result { try operation() })
        }
    }
}
