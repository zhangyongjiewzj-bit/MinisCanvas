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
        #expect(after.contains("next chunk"))
        #expect(after.hasPrefix(masked))
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
}
