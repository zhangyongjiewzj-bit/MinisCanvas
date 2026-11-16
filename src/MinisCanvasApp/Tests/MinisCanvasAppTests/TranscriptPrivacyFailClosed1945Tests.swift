import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("转录脱敏缺源时拒绝输出", .serialized)
@MainActor
struct TranscriptPrivacyFailClosed1945Tests {
    @Test("缺少设置 store 时复制全部不得输出原文")
    func missingStoreBlocksCopyOfSyntheticSecret() throws {
        try withChat { chat, profile in
        let secret = "synthetic-transcript-secret-1945"
        chat.messages = [ChatMessageUI(role: .assistant, content: "凭据 \(secret)")]

        let view = ChatMainView(chat: chat, documentStore: nil, transcriptEnvStore: nil)
        #expect(view.transcriptPlainTextForCopy().isEmpty)
        let transcript = ChatTranscriptView(sessionID: chat.activeSessionID,
                                            messages: chat.messages, transcriptEnvStore: nil)
        #expect(transcript.transcriptDocumentForDisplay(baseSize: 13, palette: nil) == nil)
        }
    }

    @Test("同一设置 store 脱敏凭据且保留普通内容")
    func canonicalStoreRedactsSecretAndKeepsOrdinaryText() throws {
        try withChat { chat, profile in
        let secret = "synthetic-transcript-secret-1945"
        let store = EnvVarStore(directory: profile.providerConfigurationDirectory,
                                keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                                privacyStore: EnvVarPrivacyStore(defaults: profile.makeUserDefaults()))
        #expect(store.setEnvVar(name: "SYNTHETIC_TRANSCRIPT_KEY", value: secret, isSecret: true))
        chat.messages = [ChatMessageUI(role: .assistant, content: "普通内容：凭据 \(secret)")]

        let view = ChatMainView(chat: chat, documentStore: nil, transcriptEnvStore: store)
        #expect(view.transcriptEnvStore === store)
        let transcript = ChatTranscriptView(sessionID: chat.activeSessionID,
                                            messages: chat.messages, transcriptEnvStore: store)
        let document = try #require(transcript.transcriptDocumentForDisplay(baseSize: 13, palette: nil))
        #expect(document.attributedString.string.contains("普通内容"))
        #expect(!document.attributedString.string.contains(secret))
        let output = view.transcriptPlainTextForCopy()
        #expect(output.contains("普通内容"))
        #expect(!output.contains(secret))
        }
    }

    @Test("存在设置 store 且无密钥时正常复制")
    func emptyCanonicalStoreAllowsOrdinaryText() throws {
        try withChat { chat, profile in
        let store = EnvVarStore(directory: profile.providerConfigurationDirectory,
                                keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                                privacyStore: EnvVarPrivacyStore(defaults: profile.makeUserDefaults()))
        chat.messages = [ChatMessageUI(role: .assistant, content: "普通消息1945")]

        let view = ChatMainView(chat: chat, documentStore: nil, transcriptEnvStore: store)
        #expect(view.transcriptPlainTextForCopy().contains("普通消息1945"))
        }
    }

    private struct FixtureCleanupError: Error {
        let path: String
        let observedResult: Int32
        let observedErrno: Int32
    }

    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: Error
    }

    /// This original consumer only changes RAM messages and renders strings.
    /// It never attaches persistence, starts streaming or submits a Provider.
    /// Consequently it creates no background writer requiring a cancellation
    /// surrogate or a timeout presented as a join.
    private func withChat(_ body: (ChatStore, RuntimeIsolationProfile) throws -> Void) throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "transcript-privacy1945", canvasRuntimeState: .disabled)
        // Own cleanup as soon as the disposable factory returns. Qualification
        // checks the actual FM parent/UUID/dev/inode/UID and tightens only this
        // exact fresh child to 0700 before any store construction.
        let business = Result<Void, Error> {
            try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
            let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                                 logManager: profile.makeLogManager())
            try body(chat, profile)
        }
        // The existing helper records any identity/cleanup error as a genuine
        // SwiftTesting issue. Do not swallow it; additionally throw if this
        // exact root remains, retaining the original business error as well.
        B1ARCHOriginalFixtureSupport.cleanupProfile(profile)
        var observed = stat()
        errno = 0
        let result = lstat(profile.rootDirectory.path, &observed)
        let observedErrno = errno
        guard result == -1, observedErrno == ENOENT else {
            let cleanup = FixtureCleanupError(path: profile.rootDirectory.path,
                observedResult: result, observedErrno: observedErrno)
            switch business {
            case .success: throw FixtureFailures(business: nil, cleanup: cleanup)
            case .failure(let error): throw FixtureFailures(business: error, cleanup: cleanup)
            }
        }
        print("TRANSCRIPT1945_CLEANUP exactRootAbsent=true")
        try business.get()
    }
}
