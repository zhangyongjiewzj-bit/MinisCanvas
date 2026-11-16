import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Uses the production draft setter, credential broker and persistence store.
/// This measures synchronous setter cost; it makes no live-window frame claim.
@Suite("D-PERF-01 mixed Unicode draft capture")
@MainActor
struct ComposerUnicodeInput2975Tests {
    @Test func longMixedDraftKeepsCustodyAndPersistsOnlyMaskedText() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("perf2975-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "perf2975-\(UUID())"))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        drafts.debounceInterval = .seconds(30)
        chat.attachDraftStore(drafts)
        let session = try #require(chat.activeSessionID)
        let key = DraftStore.chatDraftKey(sessionID: session)
        let ordinary = String(repeating: "中🙂e\u{301}文a", count: 8_000)
        #expect(ordinary.utf8.count >= 100_000)
        #expect(!ContentSecretRedactor.mayContainFormatTrigger(ordinary))

        chat.draftText = ordinary
        let clock = ContinuousClock()
        var setterNS: [Int64] = []
        var current = ordinary
        for _ in 0..<32 {
            current += "z"
            let start = clock.now
            chat.draftText = current
            let elapsed = start.duration(to: clock.now).components
            setterNS.append(elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000)
            #expect(chat.draftText == current)
            #expect(chat.longDraftTimerCreationCount == 1 && chat.longDraftEncodingCount == 0)
            #expect(drafts.latestPayload(for: key) == nil)
        }
        let sorted = setterNS.sorted()
        print("PERF2975_UNICODE_SETTER utf8_bytes=\(ordinary.utf8.count) samples=32 "
            + "p95_ns=\(sorted[30]) window=NONE keyboard=NOT_MEASURED "
            + "CPU=NOT_MEASURED 60Hz_120Hz=NOT_PROVEN")

        // The fast-negative path still performs exact known-value masking.
        let known = "syntheticOpaqueValue2975Z"
        _ = try #require(chat.credentialBroker.captureSecureField(known, sessionID: session))
        chat.draftText = current + known
        #expect(!chat.draftText.contains(known))
        #expect(chat.draftText.hasPrefix(ordinary))
        #expect(chat.flushPendingDraftForTermination())
        let reopened = DraftStore(directory: root.appendingPathComponent("drafts"))
        let persisted = try #require(reopened.load(key: key))
        #expect(!String(decoding: persisted, as: UTF8.self).contains(known))
        chat.credentialBroker.cancel()

        // Any cased Unicode fold or newly completed ASCII format token must
        // still enter the original ICU format matcher before draft storage.
        let formatted = "syntheticFormatValue2975Z"
        chat.draftText = ordinary + " Be"
        chat.draftText = ordinary + " Bearer " + formatted
        #expect(!chat.draftText.contains(formatted))
        chat.credentialBroker.cancel()
        chat.draftText = ordinary + " ſecret=" + formatted
        #expect(!chat.draftText.contains(formatted))
        chat.credentialBroker.cancel()
    }
}
