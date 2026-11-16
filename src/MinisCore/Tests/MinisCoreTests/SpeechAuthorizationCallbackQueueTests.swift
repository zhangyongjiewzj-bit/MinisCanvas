import Foundation
import Testing
@testable import MinisCore

@Suite("Speech authorization callback queue")
@MainActor
struct SpeechAuthorizationCallbackQueueTests {
    @Test(arguments: [true, false])
    func backgroundPermissionReplyResumesActorWithoutExecutorAssertion(authorized: Bool) async {
        let granted = await SpeechRecognizer.awaitAuthorizationCallback { complete in
            DispatchQueue.global(qos: .userInitiated).async {
                // The true case also verifies that the injected completion ran
                // off the main queue, as the TCC callback can in production.
                complete(authorized && !Thread.isMainThread)
            }
        }
        #expect(granted == authorized)
    }
}
