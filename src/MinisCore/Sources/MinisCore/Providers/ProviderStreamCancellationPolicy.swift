import Foundation

/// Small lifecycle seam shared by provider streaming callers.
///
/// `AsyncThrowingStream` reports a consumer that has stopped iterating as a
/// terminated continuation. The producer must observe that result and check
/// task cancellation before parsing another line or publishing another
/// chunk. Throwing `CancellationError` here also releases the
/// `URLSession.AsyncBytes` sequence when the producer task unwinds.
public enum ProviderStreamCancellationPolicy {
    public static func check() throws {
        try Task.checkCancellation()
    }

    public static func yield<Element: Sendable>(
        _ element: Element,
        to continuation: AsyncThrowingStream<Element, Error>.Continuation
    ) throws {
        try check()
        if case .terminated = continuation.yield(element) {
            throw CancellationError()
        }
    }
}
