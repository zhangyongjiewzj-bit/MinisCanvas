import Foundation
import Testing
@testable import MinisCore

@Suite("Provider stream cancellation policy")
struct ProviderStreamCancellationPolicyTests {
    @Test("terminated consumer stops the producer before a value is published")
    func terminatedContinuationThrowsCancellation() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var stream: AsyncThrowingStream<String, Error>? = AsyncThrowingStream { value in
            continuation = value
        }
        let producer = try! #require(continuation)
        #expect(stream != nil)
        stream = nil

        #expect(throws: CancellationError.self) {
            try ProviderStreamCancellationPolicy.yield("after-stop", to: producer)
        }
    }

    @Test("producer task cancellation is checked before parsing")
    func cancelledTaskThrowsCancellation() async {
        let task = Task {
            try await Task.sleep(for: .milliseconds(1))
            try ProviderStreamCancellationPolicy.check()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
