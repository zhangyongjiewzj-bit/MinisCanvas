import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C7, the ChatStore half (C-L4 owns the clamp itself in
/// `SettingsCenter.captureContextTurnSettingsInputs`): the clamp reaches the
/// turn, the turn is not aborted with `invalidContextSettings`, and the
/// one-line notice appears once per (session, clamp) pair.
///
/// Depends on C-L4's `ContextClampNotice` / `ContextTurnSettingsInputs.clampNotice`.
@Suite("C7 clamp notice wiring", .serialized)
@MainActor
struct ContextClampNoticeWiring_C7_Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test func explicitLengthAboveWindowIsClampedAndNoticedOncePerSession() async throws {
        let fixture = try Fixture(initialHistory: [])
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        // The dialogue model has no explicit window: 128_000 from the catalog fallback.
        #expect(fixture.settings.setContextLengthTokens(200_000))
        chat.streamingProviderOverride = dialogue
        for text in ["C7_FIRST_SEND", "C7_SECOND_SEND"] {
            chat.draftText = text
            chat.submitComposer()
            let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
            #expect(ended)
        }
        #expect(dialogue.requests.count == 2, "a clamped length must not abort the turn")
        #expect(!chat.messages.contains { $0.content.contains("invalidContextSettings") })
        let notices = chat.messages.filter { $0.role == .system && $0.content.contains("200000") }
        #expect(notices.count == 1, "one notice per (session, clamp) pair")
        #expect(notices.first?.content.contains("128000") == true)
    }

    @Test func lengthWithinWindowShowsNoNotice() async throws {
        let fixture = try Fixture(initialHistory: [])
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        #expect(fixture.settings.setContextLengthTokens(100_000))
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C7_WITHIN_WINDOW"
        chat.submitComposer()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(dialogue.requests.count == 1)
        #expect(!chat.messages.contains { $0.role == .system && $0.content.contains("100000") })
    }
}
