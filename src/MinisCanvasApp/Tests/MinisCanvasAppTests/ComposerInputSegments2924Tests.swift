import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Segments the same synchronous production methods reached by the native
/// callback test. No window, keyboard cadence or frame rendering is claimed.
@Suite("D-PERF-01/05 long input synchronous segments")
@MainActor
struct ComposerInputSegments2924Tests {
    private func nanoseconds(_ duration: Duration) -> Int64 {
        let value = duration.components
        return value.seconds * 1_000_000_000 + value.attoseconds / 1_000_000_000
    }

    private func p95(_ values: [Int64]) -> Int64 {
        let sorted = values.sorted()
        return sorted[(sorted.count * 95 + 99) / 100 - 1]
    }

    @Test func fastNegativeStillFallsBackForEveryCurrentFormatFamily() {
        for prefix in ["sk", "be", "ap", "to", "pa", "se", "ke", "au", "co", "ht"] {
            #expect(ContentSecretRedactor.mayContainFormatTrigger(prefix.uppercased()))
            #expect(ContentSecretRedactor.mayContainFormatTrigger(prefix.capitalized))
        }
        #expect(!ContentSecretRedactor.mayContainFormatTrigger("普通中文"))
        #expect(!ContentSecretRedactor.mayContainFormatTrigger(String(repeating: "a", count: 100_000)))
        let known = "syntheticOpaqueValue2924Z"
        let source = String(repeating: "a", count: 50_000) + known
        #expect(ContentSecretRedactor.redact(source, knownSecrets: [known])
                == String(repeating: "a", count: 50_000) + ContentSecretRedactor.mask(known))
    }

    @Test(arguments: [50_000, 100_000])
    func actualLongDraftSegmentsRetainSyntheticSecretCustody(bytes: Int) throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("perf2924-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "perf2924-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: session)
        let editor = ComposerPasteAwareTextView(frame: .zero)
        editor.isRichText = false
        editor.string = String(repeating: "a", count: bytes)
        chat.draftText = editor.string
        let broker = ChatCredentialBroker()
        let clock = ContinuousClock()
        var bridge: [Int64] = []
        var protect: [Int64] = []
        var capture: [Int64] = []
        var setter: [Int64] = []
        for index in 0..<32 {
            let storage = try #require(editor.textStorage)
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "z")
            let readStart = clock.now
            let current = editor.string
            bridge.append(nanoseconds(readStart.duration(to: clock.now)))

            let protectStart = clock.now
            let protected = broker.protect(current)
            protect.append(nanoseconds(protectStart.duration(to: clock.now)))
            let captureStart = clock.now
            let captured = broker.capture(current, sessionID: session)
            capture.append(nanoseconds(captureStart.duration(to: clock.now)))
            let setterStart = clock.now
            chat.draftText = current
            setter.append(nanoseconds(setterStart.duration(to: clock.now)))
            #expect(protected == current && captured == current && chat.draftText == current)
            #expect(chat.longDraftTimerCreationCount == 1 && chat.longDraftEncodingCount == 0)
            #expect(drafts.latestPayload(for: key) == nil)
            print("PERF2924_SEGMENT bytes=\(bytes) index=\(index) "
                + "bridge_ns=\(bridge[index]) protect_ns=\(protect[index]) "
                + "capture_ns=\(capture[index]) setter_ns=\(setter[index])")
        }
        print("PERF2924_SEGMENT_P95 bytes=\(bytes) samples=32 "
            + "bridge_ns=\(p95(bridge)) protect_ns=\(p95(protect)) "
            + "capture_ns=\(p95(capture)) setter_ns=\(p95(setter)) "
            + "window=NONE keyboard=NOT_MEASURED CPU=NOT_MEASURED alloc=NOT_MEASURED "
            + "SwiftTask_total=NOT_MEASURED")

        // A synthetic value is entered through the existing secure-field
        // custody API, then the same draft setter must mask it before storage.
        let sentinel = "syntheticOpaqueValue2924Z"
        _ = try #require(chat.credentialBroker.captureSecureField(sentinel, sessionID: session))
        let storage = try #require(editor.textStorage)
        let split = sentinel.index(sentinel.startIndex, offsetBy: sentinel.count / 2)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: " " + String(sentinel[..<split]))
        chat.draftText = editor.string
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0),
                                  with: String(sentinel[split...]))
        chat.draftText = editor.string
        #expect(!chat.draftText.contains(sentinel))
        #expect(chat.draftText.hasPrefix(String(repeating: "a", count: bytes)))
        #expect(chat.flushPendingDraftForTermination())
        let reopened = DraftStore(directory: root.appendingPathComponent("drafts"))
        let stored = try #require(reopened.load(key: key))
        #expect(!String(decoding: stored, as: UTF8.self).contains(sentinel))
        chat.credentialBroker.cancel()

        // A format token completed across two edits must enter the original
        // regex branch, independent of ASCII case and earlier safe prefixes.
        chat.draftText = "Be"
        let formatValue = String(repeating: "v", count: 16)
        chat.draftText = "Be" + "arer " + formatValue
        #expect(!chat.draftText.contains(formatValue))
        chat.credentialBroker.cancel()
    }
}
