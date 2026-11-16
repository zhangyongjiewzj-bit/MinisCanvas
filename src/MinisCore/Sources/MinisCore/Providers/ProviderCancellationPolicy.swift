import Foundation

/// Shared cancellation boundary for provider callers.
///
/// URLSession can surface cancellation as either `URLError(.cancelled)` or an
/// `NSError` in `NSURLErrorDomain`. Provider adapters normally map that to
/// `LLMError.cancelled`, while stream wrappers can throw `CancellationError`.
/// A small number of transport layers also wrap one of those errors in an
/// `NSError` or a typed LLM error. All of those forms are one terminal outcome
/// and must not enter retry, fallback, checkpoint, or failure-diagnostic code.
public enum ProviderCancellationPolicy {
    private static let maxUnderlyingDepth = 8

    /// Whether `error` represents a provider/request cancellation.
    ///
    /// Only typed cancellation signals are accepted. Arbitrary localized text
    /// is never inspected, so an error whose message merely says “cancelled”
    /// cannot bypass normal failure handling. Underlying errors are followed
    /// through a bounded chain to cover URLSession wrappers without risking a
    /// malformed cyclic error graph.
    public static func isCancellation(_ error: Error) -> Bool {
        isCancellation(error, depth: 0)
    }

    /// Returns the one cancellation error used at workflow/router boundaries.
    /// Keeping the original provider error out of those surfaces prevents a
    /// raw URLSession diagnostic from being wrapped as a user-visible failure.
    public static func terminalCancellation(for error: Error) -> CancellationError? {
        isCancellation(error) ? CancellationError() : nil
    }

    private static func isCancellation(_ error: Error, depth: Int) -> Bool {
        if error is CancellationError {
            return true
        }

        if let transport = error as? ProviderTransportCodeError,
           transport.code == NSURLErrorCancelled {
            return true
        }

        if let llmError = error as? LLMError {
            switch llmError {
            case .cancelled:
                return true
            case .networkError(let underlying),
                 .decodingError(let underlying):
                guard depth < maxUnderlyingDepth else { return false }
                return isCancellation(underlying, depth: depth + 1)
            case .unknown(let underlying):
                guard let underlying, depth < maxUnderlyingDepth else { return false }
                return isCancellation(underlying, depth: depth + 1)
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return true
        }

        guard depth < maxUnderlyingDepth,
              let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isCancellation(underlying, depth: depth + 1)
    }
}
