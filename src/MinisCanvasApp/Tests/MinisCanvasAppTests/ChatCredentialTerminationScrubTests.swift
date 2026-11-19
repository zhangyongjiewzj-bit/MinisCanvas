import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// CRED-TERM-SCRUB contract tests: generation-termination custody.
///
/// When a run is stopped, errors out, falls back, is cancelled, or a new
/// capture/edit replaces the pending custody, every raw copy of secret
/// material must be scrubbed from the in-memory transcript. The broker keeps
/// two kinds of custody: `entries` (captured values) and `streamBuffers`
/// (the raw, un-masked accumulation of one streaming reply). A cancellation
/// that drops `entries` but leaves the raw stream buffer intact lets the
/// next projection re-expose the dropped value in clear, because it is no
/// longer in `knownSecrets` and opaque values match no pattern layer.
///
/// All fixtures are synthetic markers; nothing here uses a real key, token,
/// or Keychain value, and every assertion checks the synthetic secret's
/// ABSENCE from any projected surface.
@Suite("Credential termination scrub") @MainActor
struct ChatCredentialTerminationScrubTests {
    /// Opaque marker: matches none of ContentSecretRedactor's patterns
    /// (no `sk-` prefix, no `key=`/`Bearer`/`:` assignment shape), so it is
    /// masked only while it is still in the broker's known-secret custody.
    private static func opaqueSecret(_ tag: String) -> String {
        "SYNTH-SECRET-" + tag + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    @Test func cancellationScrubsRawStreamSoDroppedCustodyValueCannotReappearOnSurface() {
        let broker = ChatCredentialBroker()
        let session = UUID()
        let secret = Self.opaqueSecret("cancel-resurface")
        // D-CREDG-style SecureField custody: any opaque value is held.
        let request = broker.captureSecureField(secret, sessionID: session)
        #expect(request != nil)
        let messageID = UUID()
        // Provider echoes the still-pending value mid-stream: the projected
        // surface is masked, but the raw accumulation holds it in clear.
        let masked = broker.projectStream(
            messageID: messageID, current: "", append: "server echo " + secret + " done")
        #expect(!masked.contains(secret))
        #expect(masked.contains("server echo"))

        // Termination trigger: card cancel / beginSecureEntry / re-capture /
        // TTL expiry all route through cancel(). Custody is dropped...
        broker.cancel()
        #expect(broker.pending == nil)
        // ...so the raw copy must be gone with it. A continuing stream must
        // rebuild only from the already-masked surface text.
        let after = broker.projectStream(
            messageID: messageID, current: masked, append: " next chunk")
        #expect(!after.contains(secret))
        // Continuity of the protected surface is preserved (tightening only).
        // The stream withholds its last word until the turn settles.
        #expect(after.hasPrefix(masked))
        let settled = broker.finalizeStream(messageID: messageID, current: after)?.text ?? after
        #expect(settled.contains("next chunk"))
        #expect(!settled.contains(secret))
    }

    @Test func sessionScopedCancellationScrubsInFlightStreamBuffers() {
        let broker = ChatCredentialBroker()
        let session = UUID()
        let secret = Self.opaqueSecret("session-cancel")
        #expect(broker.captureSecureField(secret, sessionID: session) != nil)
        let messageID = UUID()
        let masked = broker.projectStream(
            messageID: messageID, current: "", append: "leaked copy: " + secret)
        #expect(!masked.contains(secret))

        // The same call the TTL expiry task performs on a live run.
        broker.cancel(sessionID: session)
        #expect(broker.pending == nil)
        let after = broker.projectStream(
            messageID: messageID, current: masked, append: " tail")
        #expect(!after.contains(secret))
    }

    @Test func newCaptureTriggeredCancellationScrubsPreviousStreamsRawCopy() {
        let broker = ChatCredentialBroker()
        let session = UUID()
        let secret = Self.opaqueSecret("recapture")
        #expect(broker.captureSecureField(secret, sessionID: session) != nil)
        let messageID = UUID()
        let masked = broker.projectStream(
            messageID: messageID, current: "", append: "reply " + secret + " end")
        #expect(!masked.contains(secret))

        // Edit/resubmit duty cycle: a fresh capture (draft set, AX paste,
        // capsule send) cancels the previous custody first. The `api_key=`
        // shape is one of the broker's intercepted credential forms.
        let second = Self.opaqueSecret("recapture-successor")
        let safe = broker.capture("配置 api_key=" + second, sessionID: session)
        #expect(!safe.contains(second))
        #expect(broker.pending != nil)

        let after = broker.projectStream(
            messageID: messageID, current: masked, append: " continuation")
        // The superseded opaque value left custody at cancel; its raw copy
        // must not resurface on the projected transcript afterwards.
        #expect(!after.contains(secret))
        // The new custody is still masked while it is live.
        let echoed = broker.projectStream(
            messageID: messageID, current: after, append: " " + second)
        #expect(!echoed.contains(second))
    }

    @Test func normalFinalizationScrubKeepsFinishedStreamsSecretFree() {
        let broker = ChatCredentialBroker()
        let session = UUID()
        let secret = Self.opaqueSecret("finalize")
        #expect(broker.captureSecureField(secret, sessionID: session) != nil)
        let messageID = UUID()
        let masked = broker.projectStream(
            messageID: messageID, current: "", append: "reply " + secret)
        #expect(!masked.contains(secret))
        broker.finishStream(messageID: messageID)
        broker.cancel()
        // Post-terminal re-projection (late writeback) rebuilds from the
        // caller-held masked text only; no raw companion survives.
        let late = broker.projectStream(
            messageID: messageID, current: masked, append: " late")
        #expect(!late.contains(secret))
        #expect(broker.replaceStream(messageID: UUID(), with: "plain text") == "plain text")
    }

    /// Tightening guard: after a termination scrub, a credential split across
    /// the scrub boundary is still masked, because each projection rescans
    /// the concatenation of the (masked) base and the new append.
    @Test func scrubbedStreamStillMasksCredentialSplitAcrossAppendBoundary() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        var projected = broker.projectStream(messageID: messageID, current: "", append: "prefix sk-synthetic")
        // Complete the token in later chunks; the finished credential shape
        // must end up masked once whole.
        projected = broker.projectStream(messageID: messageID, current: projected, append: "-abcdefgh1234")
        #expect(!projected.contains("sk-synthetic-abcdefgh1234"))
        broker.cancel()
        let continued = broker.projectStream(
            messageID: messageID, current: projected, append: " and sk-synthetic-nextchunk5678 end")
        #expect(!continued.contains("sk-synthetic-nextchunk5678"))
    }

    /// 停止（身份已退役、不再有后续片段）：已渲染的文字，包括流式中被扣住的末尾词，
    /// 以脱敏后的完整形态保留，与旧行为（每片段整条脱敏）一致。
    @Test func stopKeepsRenderedTailExactlyAsFullRedaction() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        let raw = "第一句。 Second sentence with sk-synthetic-stoptail9999 and last word"
        var shown = broker.projectStream(messageID: messageID, current: "", append: String(raw.prefix(30)))
        shown = broker.projectStream(messageID: messageID, current: shown, append: String(raw.dropFirst(30)))
        #expect(!shown.contains("sk-synthetic-stoptail9999"))
        #expect(!shown.hasSuffix("word"))
        let stopped = broker.finalizeStream(messageID: messageID, current: shown)
        #expect(stopped?.text == broker.protect(raw))
        #expect(stopped?.text.hasSuffix("last word") == true)
        // 终态后不再有流状态：同一条消息再没有可取回的内容。
        #expect(broker.finalizeStream(messageID: messageID, current: stopped?.text ?? "") == nil)
    }

    /// 托管撤销发生在尾部被扣住时：尾部按撤销前的已知密钥脱敏后保留，不丢文字、不复活明文。
    @Test func cancelWhileTailIsWithheldKeepsMaskedTailAndNeverResurfacesSecret() {
        let broker = ChatCredentialBroker()
        let session = UUID()
        let secret = Self.opaqueSecret("withheld-tail")
        #expect(broker.captureSecureField(secret, sessionID: session) != nil)
        let messageID = UUID()
        let shown = broker.projectStream(messageID: messageID, current: "", append: "已发送 " + secret)
        #expect(shown == "已发送 ")
        broker.cancel()
        let settled = broker.finalizeStream(messageID: messageID, current: shown)
        #expect(settled?.text == shown + String(repeating: "*", count: secret.count))
        #expect(settled?.extendsPrevious == true)
    }

    /// 工具调用边界：先放开被扣住的尾部，行内锚点才不会落在尚未显示的词之前。
    @Test func settleReleasesWithheldTailBeforeToolAnchor() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        let shown = broker.projectStream(messageID: messageID, current: "", append: "我先运行 build")
        #expect(shown == "我先运行 ")
        let settled = broker.settleStream(messageID: messageID)
        #expect(settled?.text == "我先运行 build")
        #expect(settled?.extendsPrevious == true)
    }

    /// 工具边界上尾部仍像密钥前缀：保持扣住，已显示文字不含前缀。
    @Test func settleKeepsPartialTokenWithheldAtToolBoundary() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        _ = broker.projectStream(messageID: messageID, current: "", append: "请使用 ghp_aB3dE6gH9kaB3dE6")
        let settled = broker.settleStream(messageID: messageID)
        #expect(settled?.text.contains("ghp_aB3d") == false)
        #expect(settled?.text.hasPrefix("请使用") == true)
    }

    /// 终止（停止/出错/安全锁）时被扣住的残缺令牌被遮蔽，普通文字照常放出。
    @Test func terminationMasksPartialTokenTailButKeepsPlainTail() {
        let broker = ChatCredentialBroker()
        let tokenMessage = UUID()
        let shown = broker.projectStream(messageID: tokenMessage, current: "", append: "说明 ghp_aB3dE6gH9kaB3dE6")
        let closed = broker.finalizeStream(messageID: tokenMessage, current: shown)
        #expect(closed?.text.contains("ghp_aB3d") == false)
        #expect(closed?.text.hasPrefix("说明 ") == true)

        let plainMessage = UUID()
        let plainShown = broker.projectStream(messageID: plainMessage, current: "", append: "先说 hello wor")
        #expect(broker.finalizeStream(messageID: plainMessage, current: plainShown)?.text == "先说 hello wor")
    }

    /// 托管撤销时被扣住的残缺令牌同样遮蔽。
    @Test func cancelMasksPartialTokenTail() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        let shown = broker.projectStream(messageID: messageID, current: "", append: "说明 ghp_aB3dE6gH9kaB3dE6")
        broker.cancel()
        let closed = broker.finalizeStream(messageID: messageID, current: shown)
        #expect(closed?.text.contains("ghp_aB3d") == false)
    }

    /// 思考文字显示前同样经过增量脱敏；终态放开普通尾部、遮蔽疑似密钥。
    @Test func thinkingChannelIsRedactedIncrementally() {
        let broker = ChatCredentialBroker()
        let messageID = UUID()
        var shown = broker.projectThinking(messageID: messageID, current: "", append: "想到 sk-abcdef")
        #expect(!shown.contains("sk-abc"))
        shown = broker.projectThinking(messageID: messageID, current: shown, append: "ghijklmnop ")
        #expect(!shown.contains("sk-abc"))
        #expect(broker.finalizeThinking(messageID: messageID, current: shown)?.contains("sk-abc") == false)

        let plain = UUID()
        let plainShown = broker.projectThinking(messageID: plain, current: "", append: "想想 hello wor")
        #expect(broker.finalizeThinking(messageID: plain, current: plainShown) == "想想 hello wor")
    }
}
