import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Lane QODER-DEV-W5-COMPOSER-PENDING-RESOLVE-070.
///
/// Pins the resolve/consume/cancel seam for ChatStore's pending Composer
/// command state (`ChatStore.pendingComposerCommand`, the
/// `routeComposerSlashCommand` consume boundary, and
/// `resolvePendingComposerCommand(requestID:disposition:)`).
///
/// Gap closed: before this seam a `.pending` hand-off could go stale when the
/// terminal user action took the reject/deny path or the `.execute`
/// non-compact path instead of a resolve path, because the property had a
/// private setter and only compact+`.execute` cleared it. The adjudication
/// owner (lane 059's ComposerCommandAdjudicationCenter, escalated seam in
/// QODER-DEV-W5-COMPOSER-CMD-POLICY-WIRE-059.receipt.json) is the intended
/// production consumer of the new transition.
///
/// Idiom precedent for this file (same target, already compiling):
/// ComposerCompactReceiptRecoveryTests.swift:76-107 (suite shape, temp
/// directory persistence, `draftText` + `submitComposer`) and
/// CommandRegistryTests.swift:6-46 (offline counting LLMProvider so the
/// negative "never reached the Provider" assertions are real, not vacuous).
/// No locks, timers, or async-context API are used; every test body is a
/// synchronous @MainActor block.

private final class PendingResolveCountingProvider: LLMProvider, @unchecked Sendable {
    let name = "pending-resolve-test-provider"
    var model = LLMModel(id: "pending-resolve-test", displayName: "Pending Resolve Test", provider: "test")
    private(set) var callCount = 0

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        return LLMResponse(text: "unused", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private func makePersistenceDirectory(named label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("composer-pending-resolve-070-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("Composer pending command resolve seam")
@MainActor
struct ComposerPendingResolve070Tests {
    // MARK: - Terminal transition: cancel (deny / expire / reject)

    @Test func rejectedSubmissionKeepsReceiptButNotFalsePending() throws {
        // A submission-time rejection is already terminal. Only the receipt
        // survives; deny/expiry of an actually pending request still uses the
        // exact-ID resolve seam in the tests below.
        let directory = try makePersistenceDirectory(named: "reject-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.onComposerCommandPolicy = { _, _ in .reject }
        chat.draftText = "/compact"
        let before = chat.messages
        chat.submitComposer()
        #expect(chat.messages == before)

        let requestID = try #require(chat.lastComposerCommandReceipt?.requestID)
        #expect(chat.pendingComposerCommand == nil)
        #expect(!chat.resolvePendingComposerCommand(requestID: requestID, disposition: .reject))

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.pendingComposerCommand == nil)
        // The submission-boundary receipt stays as the audit record.
        #expect(restarted.lastComposerCommandReceipt?.disposition == .reject)
        #expect(restarted.lastComposerCommandReceipt?.requestID == requestID)
    }

    @Test func legacyRejectedEnvelopeDoesNotReviveAnUnanswerablePrompt() throws {
        let directory = try makePersistenceDirectory(named: "legacy-reject")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.onComposerCommandPolicy = { _, _ in .pending }
        chat.draftText = "/compact"
        chat.submitComposer()
        let requestID = try #require(chat.pendingComposerCommand?.id)

        // Model a schema-1 envelope written by the old reject path: its
        // receipt was terminal while the same request remained pending.
        let url = directory.appendingPathComponent("chat-composer-command-state.json")
        var envelope = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var receipt = try #require(envelope["receipt"] as? [String: Any])
        receipt["disposition"] = "reject"
        envelope["receipt"] = receipt
        try JSONSerialization.data(withJSONObject: envelope).write(to: url, options: .atomic)

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.pendingComposerCommand == nil)
        #expect(restarted.lastComposerCommandReceipt?.requestID == requestID)
        #expect(restarted.lastComposerCommandReceipt?.disposition == .reject)
    }

    // MARK: - Terminal transition: consume (approve-and-consume)

    @Test func approvedNonCompactHandoffResolvesAsConsumed() throws {
        let directory = try makePersistenceDirectory(named: "approve-consume")
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.onComposerCommandPolicy = { _, _ in .pending }
        chat.draftText = "/compact"
        chat.submitComposer()

        let requestID = try #require(chat.pendingComposerCommand?.id)
        #expect(chat.resolvePendingComposerCommand(requestID: requestID, disposition: .execute))
        #expect(chat.pendingComposerCommand == nil)

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.pendingComposerCommand == nil)
    }

    // MARK: - Stale / out-of-order determinism

    @Test func staleResolutionIsRejectedWithoutTouchingCurrentPending() throws {
        let directory = try makePersistenceDirectory(named: "stale-reject")
        defer { try? FileManager.default.removeItem(at: directory) }

        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.onComposerCommandPolicy = { _, _ in .pending }
        chat.draftText = "/compact"
        chat.submitComposer()
        let currentID = try #require(chat.pendingComposerCommand?.id)

        // Accepted case: the matching identity resolves.
        // Rejected case: a wrong identity cannot.
        #expect(!chat.resolvePendingComposerCommand(requestID: UUID(), disposition: .reject))
        #expect(chat.pendingComposerCommand?.id == currentID)
        // The rejection had no persistence side effect either.
        let unchangedOnDisk = ChatStore()
        #expect(unchangedOnDisk.attachPersistence(SessionStore(directory: directory)))
        #expect(unchangedOnDisk.pendingComposerCommand?.id == currentID)

        #expect(chat.resolvePendingComposerCommand(requestID: currentID, disposition: .reject))
        #expect(chat.pendingComposerCommand == nil)
        // Resolving twice is deterministically rejected (already resolved).
        #expect(!chat.resolvePendingComposerCommand(requestID: currentID, disposition: .reject))
    }

    @Test func supersededPendingRejectsTheOlderRequestResolution() throws {
        let chat = ChatStore()
        chat.onComposerCommandPolicy = { _, _ in .pending }
        chat.draftText = "/compact"
        chat.submitComposer()
        let olderID = try #require(chat.pendingComposerCommand?.id)

        // The next submission supersedes the pending hand-off with a new
        // request identity.
        chat.draftText = "/compact"
        chat.submitComposer()
        let newerID = try #require(chat.pendingComposerCommand?.id)
        #expect(newerID != olderID)

        // A late resolution for the superseded request must not clear the
        // newer pending command.
        #expect(!chat.resolvePendingComposerCommand(requestID: olderID, disposition: .reject))
        #expect(chat.pendingComposerCommand?.id == newerID)
        #expect(chat.resolvePendingComposerCommand(requestID: newerID, disposition: .reject))
        #expect(chat.pendingComposerCommand == nil)
    }

    @Test func nonTerminalPendingDispositionIsRejected() throws {
        let chat = ChatStore()
        chat.onComposerCommandPolicy = { _, _ in .pending }
        chat.draftText = "/compact"
        chat.submitComposer()
        let requestID = try #require(chat.pendingComposerCommand?.id)

        // `.pending` is a hand-off state, not a terminal transition.
        #expect(!chat.resolvePendingComposerCommand(requestID: requestID, disposition: .pending))
        #expect(chat.pendingComposerCommand?.id == requestID)
    }

    @Test func resolvingWithoutAnyPendingHandoffIsRejected() {
        let chat = ChatStore()
        #expect(chat.pendingComposerCommand == nil)
        #expect(!chat.resolvePendingComposerCommand(requestID: UUID(), disposition: .execute))
    }

    // MARK: - Submission-boundary consume paths

    @Test func synchronousExecuteOnNonCompactConsumesPendingImmediately() throws {
        // The gap's execute-non-compact path: a hook that allows a
        // display-only canonical command at the submission boundary used to
        // leave `pendingComposerCommand` set (stale menu decoration at
        // GlobalComposerView.swift:329) until the next slash submission.
        let directory = try makePersistenceDirectory(named: "execute-non-compact")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = PendingResolveCountingProvider()
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.streamingProviderOverride = provider
        chat.onComposerCommandPolicy = { _, _ in .execute }
        chat.draftText = "/status"
        let before = chat.messages
        chat.submitComposer()

        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.lastComposerCommandReceipt?.commandID == "status")
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.messages == before)
        #expect(provider.callCount == 0)

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.pendingComposerCommand == nil)
    }

    @Test func compactExecuteBoundaryStillClearsAtSubmission() throws {
        // Behavior-unchanged pin for the merged compact branch: `.execute`
        // for compact keeps clearing pending at the submission boundary
        // before invoking the canonical `compactContext()` entry. Actual
        // compaction execution is already pinned by
        // ComposerCompactReceiptRecoveryTests; only the synchronous state
        // transition, the real native path's canonical short-context notice,
        // and command non-leak are asserted here.
        //
        // The whole-transcript equality expectation added in the original
        // lane delivery was wrong, not the product: the boundary delegates to
        // the real native `compactContext()` entry (ChatStore.swift
        // routeComposerSlashCommand `.execute` branch: clear pending, then
        // `compactContext()`), and that entry documents and implements
        // "上下文不足 keepRecent 条时提示无需压缩" by appending exactly one
        // system notice "上下文较短，无需压缩。" (ChatAgentEngine.swift
        // compactContext guard → ChatStore.swift appendCanvasNotice, system
        // role, "区别于对话气泡"). A one-message welcome transcript is below
        // keepRecent, so the notice is a required product feedback, and the
        // requirement forbids suppressing the transcript at the boundary. The
        // pin therefore names the exact permitted delta instead of forbidding
        // it: the pre-boundary messages stay byte-identical, the only added
        // line is the canonical system notice, no message carries the
        // "/compact" command text, and the provider is never reached.
        let directory = try makePersistenceDirectory(named: "compact-execute")
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = PendingResolveCountingProvider()
        let chat = ChatStore()
        #expect(chat.attachPersistence(SessionStore(directory: directory)))
        chat.compactionProviderOverride = provider
        chat.onComposerCommandPolicy = { _, _ in .execute }
        chat.draftText = "/compact"
        let before = chat.messages
        chat.submitComposer()

        #expect(chat.pendingComposerCommand == nil)
        #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
        #expect(chat.messages.count == before.count + 1)
        #expect(Array(chat.messages.dropLast()) == before)
        let boundaryNotice = try #require(chat.messages.last)
        #expect(boundaryNotice.role == .system)
        #expect(boundaryNotice.content == "上下文较短，无需压缩。")
        #expect(chat.messages.allSatisfy { !$0.content.contains("/compact") })
        #expect(provider.callCount == 0)
    }
}
