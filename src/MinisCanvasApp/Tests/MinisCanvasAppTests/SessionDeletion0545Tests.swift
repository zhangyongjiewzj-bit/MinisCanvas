import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-SESSION-16/17: the App's real permanent-deletion consumer must reject
/// stale or incomplete confirmation without changing the durable session.
@Suite("D-SESSION-16/17 permanent confirmation consumer", .serialized)
@MainActor
struct SessionDeletion0545Tests {
    @Test("expired App preview keeps bytes; a fresh Store preview can continue")
    func expiredPermanentPreviewNeedsFreshConfirmation() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "session-delete-expired-0545", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let sessionDirectory = profile.sessionDirectory
        let store = SessionStore(directory: sessionDirectory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("合成目标会话：过期确认不得删除")
        chat.newSession()
        let survivorID = try #require(chat.activeSessionID)
        chat.appendUser("合成保留会话")
        let targetURL = store.sessionsDirectory.appendingPathComponent("\(targetID.uuidString).json")
        let survivorURL = store.sessionsDirectory.appendingPathComponent("\(survivorID.uuidString).json")
        let targetBefore = try Data(contentsOf: targetURL)
        let survivorBefore = try Data(contentsOf: survivorURL)
        let sessionIDsBefore = chat.sessions.map(\.id)
        let activeBefore = chat.activeSessionID

        // This is the App preview used by ChatSidebarView, not a hand-made intent.
        let old = try chat.previewPermanentDeletion(id: targetID)
        #expect(old.operationType == .permanentDelete)
        #expect(!old.reversible)
        #expect(old.targetID == targetID.uuidString)
        let expiredNow = try #require(old.expiresAt).addingTimeInterval(1)
        let oldConfirmed = old.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("永久删除")
        #expect(throws: DeletionGateError.expired) {
            try chat.permanentlyDeleteSession(id: targetID, intent: oldConfirmed, now: expiredNow)
        }
        #expect(try Data(contentsOf: targetURL) == targetBefore)
        #expect(try Data(contentsOf: survivorURL) == survivorBefore)
        #expect(chat.sessions.map(\.id) == sessionIDsBefore)
        #expect(chat.activeSessionID == activeBefore)
        #expect(SessionStore(directory: sessionDirectory).loadSession(id: targetID.uuidString) != nil)

        // ChatStore's preview delegates to this same attached SessionStore.
        // Its clock is explicit here so the new production ticket is issued
        // after the old ticket's expiry, without waiting five wall minutes.
        let fresh = try store.previewDeletion(id: targetID.uuidString, now: expiredNow, ttl: 60)
        #expect(fresh.operationID != old.operationID)
        #expect(fresh.targetID == old.targetID)
        #expect(fresh.scopeID == old.scopeID)
        #expect(fresh.revision == old.revision)
        #expect(fresh.fingerprint == old.fingerprint)
        let freshConfirmed = fresh.withFirstConfirmation("已核对这份新预览")
            .withSecondConfirmation("永久删除")
        let receipt = try chat.permanentlyDeleteSession(
            id: targetID, intent: freshConfirmed, now: expiredNow.addingTimeInterval(1))
        #expect(receipt.operationID == fresh.operationID)
        #expect(receipt.targetID == targetID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        #expect(!chat.sessions.contains { $0.id == targetID })
        #expect(try Data(contentsOf: survivorURL) == survivorBefore)
    }

    @Test("first step, wrong phrase, and cancellation leave the permanent target intact")
    func incompleteAndCancelledPermanentConfirmationNeverDeletes() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "session-delete-cancel-0545", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let sessionDirectory = profile.sessionDirectory
        let store = SessionStore(directory: sessionDirectory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                             logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store))
        chat.newSession()
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("合成目标会话：未确认不得删除")
        chat.newSession()
        let survivorID = try #require(chat.activeSessionID)
        chat.appendUser("合成保留会话")
        let targetURL = store.sessionsDirectory.appendingPathComponent("\(targetID.uuidString).json")
        let survivorURL = store.sessionsDirectory.appendingPathComponent("\(survivorID.uuidString).json")
        let targetBefore = try Data(contentsOf: targetURL)
        let survivorBefore = try Data(contentsOf: survivorURL)
        let sessionIDsBefore = chat.sessions.map(\.id)
        let activeBefore = chat.activeSessionID

        let preview = try chat.previewPermanentDeletion(id: targetID)
        #expect(!preview.reversible)
        let firstOnly = preview.withFirstConfirmation("已核对这份预览")
        #expect(throws: DeletionGateError.secondConfirmationRequired) {
            try chat.permanentlyDeleteSession(id: targetID, intent: firstOnly)
        }
        #expect(try Data(contentsOf: targetURL) == targetBefore)
        #expect(chat.sessions.map(\.id) == sessionIDsBefore)

        let wrong = firstOnly.withSecondConfirmation("永久删除。")
        #expect(throws: DeletionGateError.irreversibleRequiresPhrase) {
            try chat.permanentlyDeleteSession(id: targetID, intent: wrong)
        }
        #expect(try Data(contentsOf: targetURL) == targetBefore)
        #expect(chat.sessions.map(\.id) == sessionIDsBefore)

        // ChatSidebarView's cancel action uses this production lifecycle gate.
        try DeletionGate.cancel(preview)
        let exactButCancelled = firstOnly.withSecondConfirmation("永久删除")
        #expect(throws: DeletionGateError.cancelled) {
            try chat.permanentlyDeleteSession(id: targetID, intent: exactButCancelled)
        }
        #expect(try Data(contentsOf: targetURL) == targetBefore)
        #expect(try Data(contentsOf: survivorURL) == survivorBefore)
        #expect(chat.sessions.map(\.id) == sessionIDsBefore)
        #expect(chat.activeSessionID == activeBefore)
        #expect(SessionStore(directory: sessionDirectory).loadSession(id: targetID.uuidString) != nil)

        // The cancelled ticket stays unusable; a distinct new App preview works.
        let fresh = try chat.previewPermanentDeletion(id: targetID)
        #expect(fresh.operationID != preview.operationID)
        let receipt = try chat.permanentlyDeleteSession(id: targetID,
            intent: fresh.withFirstConfirmation("已核对新预览")
                .withSecondConfirmation("永久删除"))
        #expect(receipt.operationID == fresh.operationID)
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        #expect(!chat.sessions.contains { $0.id == targetID })
        #expect(try Data(contentsOf: survivorURL) == survivorBefore)
    }
}
