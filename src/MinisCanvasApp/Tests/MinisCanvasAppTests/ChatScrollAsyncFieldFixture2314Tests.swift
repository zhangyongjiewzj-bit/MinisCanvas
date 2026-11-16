import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("Packaged-field asynchronous chat scroll producer")
@MainActor
struct ChatScrollAsyncFieldFixture2314Tests {
    @Test("three explicit signals append through ChatStore to A even after B becomes active")
    func stagedAssistantRowsStayWithOriginalSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chat-scroll-field-2314-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "chat-scroll-field-2314",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: [
                "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument,
                ChatScrollAsyncFieldFixture.activationArgument
            ]
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(ChatScrollAsyncFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true,
            arguments: [ChatScrollAsyncFieldFixture.activationArgument]
        ))
        #expect(!ChatScrollAsyncFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true, arguments: []
        ))

        let store = SessionStore(directory: profile.sessionDirectory)
        try SessionPackageFieldFixture.prepare(profile: profile, store: store)
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager(),
            responsesAttemptCheckpointDirectory: profile.minisCanvasDirectory
        )
        #expect(chat.attachPersistence(
            store, badgeStore: SessionBadgeStore(directory: profile.minisCanvasDirectory)
        ))
        let alpha = try #require(chat.sessions.first { $0.title == ChatScrollAsyncFieldFixture.targetTitle })
        let beta = try #require(chat.sessions.first { $0.title == "S1566 青松会话" })
        #expect(chat.applySwitchSession(id: alpha.id))
        let alphaBaseline = try #require(chat.sessions.first { $0.id == alpha.id }).messages.count
        let betaBaseline = try #require(chat.sessions.first { $0.id == beta.id }).messages.count

        // A symlink marker cannot release a row, even when it points to a
        // harmless synthetic file inside this same disposable field root.
        let linkTarget = root.appendingPathComponent("synthetic-link-target")
        let firstReady = root.appendingPathComponent(ChatScrollAsyncFieldFixture.readyName(for: 1))
        try Data().write(to: linkTarget)
        try FileManager.default.createSymbolicLink(at: firstReady, withDestinationURL: linkTarget)
        #expect(ChatScrollAsyncFieldFixture.releaseIfReady(
            step: 1, targetSessionID: alpha.id, profile: profile, chat: chat
        ) == .refused)
        #expect(chat.sessions.first { $0.id == alpha.id }?.messages.count == alphaBaseline)
        try FileManager.default.removeItem(at: firstReady)

        let runner = Task { await ChatScrollAsyncFieldFixture.run(profile: profile, chat: chat) }
        defer { runner.cancel() }
        for step in 1...3 {
            if step == 2 { #expect(chat.applySwitchSession(id: beta.id)) }
            let marker = root.appendingPathComponent(ChatScrollAsyncFieldFixture.readyName(for: step))
            let fd = Darwin.open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            #expect(fd >= 0)
            guard fd >= 0 else { return }
            _ = Darwin.close(fd)
            for _ in 0..<80 {
                if chat.sessions.first(where: { $0.id == alpha.id })?.messages.count
                    == alphaBaseline + step { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let current = try #require(chat.sessions.first { $0.id == alpha.id })
            #expect(current.messages.count == alphaBaseline + step)
            #expect(current.messages.last?.role == .assistant)
            #expect(current.messages.last?.content.contains("异步助手消息 \(step)") == true)
            #expect(chat.sessions.first { $0.id == beta.id }?.messages.count == betaBaseline)
        }
        await runner.value
        #expect(chat.activeSessionID == beta.id)
        #expect(ChatScrollAsyncFieldFixture.releaseIfReady(
            step: 3, targetSessionID: alpha.id, profile: profile, chat: chat
        ) == .alreadyConsumed)
        #expect(chat.sessions.first { $0.id == alpha.id }?.messages.count == alphaBaseline + 3)
    }
}
