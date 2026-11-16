import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("D-PROVIDER-11 canonical runtime failure public projection 0420", .serialized)
@MainActor
struct ProviderRuntimeFailureProjection0420Tests {
    private func envelope(_ failureMessage: String) -> ChatRetryEnvelope {
        ChatRetryEnvelope(envelopeID: "projection0420", inputText: "owned synthetic question",
            sessionID: "projection0420-session", conversationID: "projection0420-session",
            turnID: "projection0420-turn", taskID: "projection0420-task", attempt: 1,
            providerID: "synthetic0420", modelID: "model0420", configurationFingerprint: "config0420",
            policySnapshotID: "policy0420", grantSnapshotID: "grant0420", failureMessage: failureMessage)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func canonicalHTTPClassificationSurvivesRuntimeEnvelope(code: Int) throws {
        let marker = "synthetic-projection0420-" + UUID().uuidString
        let original = LLMError.httpStatus(code: code,
            detail: "api_key=" + marker + "; Cookie: sid=" + marker + "; Authorization: Bearer " + marker)
        for locale in [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")] {
            let canonical = ChatGenerationFailureProjection(error: original, locale: locale)
            let failure = ChatSessionRuntimeError.turnFailed(envelope(canonical.failureMessage))
            let visible = ChatStore.userErrorMessage(failure)
            #expect(visible == canonical.failureMessage)
            #expect(visible.contains("HTTP \(code)"))
            let absent = !visible.contains(marker)
            #expect(absent, "canonical runtime explanation excludes the complete synthetic credential")
        }
    }

    @Test func cancellationTimeoutAndUnknownFallbackKeepOriginalSemantics() {
        let originals: [any Error] = [LLMError.cancelled, LLMError.networkError(underlying: URLError(.timedOut))]
        for original in originals {
            let canonical = ChatGenerationFailureProjection(error: original)
            let failure = ChatSessionRuntimeError.turnFailed(envelope(canonical.failureMessage))
            #expect(ChatStore.userErrorMessage(failure) == canonical.failureMessage)
        }
        let ordinary = NSError(domain: "owned0420", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "ordinary0420 unknown failure"])
        let visible = ChatStore.userErrorMessage(ordinary)
        #expect(visible == "操作未完成（CHAT-UNKNOWN）。请重试；若重复出现，请输入 /doctor 打开环境诊断，导出诊断包并附上此错误信息。")
        #expect(!visible.contains(ordinary.localizedDescription))
        let normalizedEnvelope = envelope("")
        #expect(normalizedEnvelope.failureMessage == "事件更新")
        #expect(!normalizedEnvelope.failureMessage.isEmpty)
        let empty = ChatSessionRuntimeError.turnFailed(normalizedEnvelope)
        #expect(ChatStore.userErrorMessage(empty) == normalizedEnvelope.failureMessage)
    }
}
