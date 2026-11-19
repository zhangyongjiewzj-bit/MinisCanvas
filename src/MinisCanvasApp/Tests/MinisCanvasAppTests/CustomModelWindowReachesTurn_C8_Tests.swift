import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C8, the ChatStore half (C-L4 owns the input field and the persistence in
/// `CustomModelWindow_C8_Tests` / `EnvVarModelWindowPersistence_C8_Tests`): the
/// window the user entered for a custom model reaches the model the turn runs
/// with, the occupancy window and the compaction threshold.
///
/// Depends on C-L4's `EnvVarEntry.modelContextWindows`.
@Suite("C8 custom model window reaches the turn", .serialized)
@MainActor
struct CustomModelWindowReachesTurn_C8_Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias HeldSummary = OrdinaryAutoCompactionCancellation2669Tests.HeldSummary
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func record() -> EnvVarEntry {
        EnvVarEntry(name: "C8_TURN", value: "synthetic-credential", isSecret: true,
            baseURL: "https://example.invalid/v1", modelNames: ["small-local", "unset-local"],
            protocolType: .openaiCompatible, modelContextWindows: ["small-local": 32_000])
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test func customProviderModelCarriesTheEnteredWindowEverywhereItIsBuilt() throws {
        let record = record()
        let entered = ChatStore.customProviderModel(record: record, modelID: "small-local")
        #expect(entered.contextWindow == 32_000 && entered.contextWindowTokens == 32_000)
        #expect(ChatStore.customProviderModel(record: record, modelID: "unset-local").contextWindow == nil)
        // The picker's model list and the runtime provider's model share that construction.
        let options = ChatStore.ChatProvider.custom(record).modelOptions
        #expect(options.first { $0.id == "small-local" }?.contextWindowTokens == 32_000)
        let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: "c8-turn-\(UUID().uuidString)")!,
            logManager: LogManager(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("c8-turn-\(UUID().uuidString)"), ringCapacity: 20))
        let provider = try chat.makeCustomProvider(record: record, modelID: "small-local")
        #expect(provider.model.contextWindowTokens == 32_000)
    }

    /// R3-05: background, project and scheduled turns are admitted against the running
    /// model's window with the user's trigger, but never compact; the foreground keeps compaction.
    @Test func admissionOfUnattendedTurnsUsesTheModelWindowAndDisallowsCompaction() throws {
        let chat = ChatStore(preferencesDefaults: UserDefaults(suiteName: "c8-admission-\(UUID().uuidString)")!,
            logManager: LogManager(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("c8-admission-\(UUID().uuidString)"), ringCapacity: 20))
        var settings = AgentSettings.default
        settings.autoCompactThreshold = 0.8
        chat.configureBudget(from: settings)
        let model = ChatStore.customProviderModel(record: record(), modelID: "small-local")
        let unattended = try #require(chat.contextAdmissionConfig(
            sessionID: nil, model: model, settings: nil, allowsCompaction: false))
        #expect(unattended.windowTokens == 32_000)
        #expect(unattended.triggerFraction == 0.8)
        #expect(!unattended.allowsCompaction && !unattended.appliesReductionInLoop)
        let foreground = try #require(chat.contextAdmissionConfig(sessionID: nil, model: model, settings: nil))
        #expect(foreground.allowsCompaction)
    }

    /// R3-08: the max output the user entered for a custom model becomes the request ceiling;
    /// models without one keep the default.
    @Test func customProviderModelCarriesTheEnteredMaxOutput() {
        var record = record()
        record.modelMaxOutputTokens = ["small-local": 8_192]
        let entered = ChatStore.customProviderModel(record: record, modelID: "small-local")
        #expect(entered.maxOutputTokens == 8_192)
        #expect(ChatStore.chatMaxOutputTokens(model: entered) == 8_192)
        let unset = ChatStore.customProviderModel(record: record, modelID: "unset-local")
        #expect(unset.maxOutputTokens == nil)
        #expect(ChatStore.chatMaxOutputTokens(model: unset) == ChatStore.defaultChatMaxOutputTokens)
    }

    /// The window of the model the turn runs with is the occupancy denominator and
    /// the base of the compaction threshold: 27_000 tokens is 84% of 32_000 (it
    /// would be 21% of the 128_000 fallback and never compact).
    @Test func windowOfTheRunningModelIsTheCompactionDenominator() async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        dialogue.model = LLMModel(id: Dialogue.modelID, displayName: "Owned dialogue",
            provider: Dialogue.providerID, contextWindow: 32_000)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: original.messages.count,
            inputTokens: 27_000, windowTokens: 32_000)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C8_SMALL_WINDOW_SEND"
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered, "84% of the 32_000 window must trigger the compaction")
        #expect(chat.latestContextWindows[fixture.sessionID] == 32_000)
        guard entered else { return }
        summary.release(1)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        #expect(chat.latestContextWindows[fixture.sessionID] == 32_000)
    }
}
