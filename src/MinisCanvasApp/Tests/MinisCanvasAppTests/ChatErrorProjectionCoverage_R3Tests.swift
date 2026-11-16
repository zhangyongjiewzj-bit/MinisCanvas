import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// R3-Z3-02: engine-thrown errors that reach ChatStore.userErrorMessage but had no
/// branch fell to the generic CHAT-UNKNOWN copy, and a project session (whose
/// failure arrives wrapped in ChatSessionRuntimeError.turnFailed with the display
/// string the engine recorded) showed different text than an ordinary session.
/// userErrorMessage is MainActor-isolated, hence the MainActor suite.
@Suite("Chat error projection coverage R3", .serialized)
@MainActor
struct ChatErrorProjectionCoverage_R3Tests {
    private static let unknownFallback =
        "操作未完成（CHAT-UNKNOWN）。请重试；若重复出现，请输入 /doctor 打开环境诊断，导出诊断包并附上此错误信息。"

    private func envelope(_ failureMessage: String) -> ChatRetryEnvelope {
        ChatRetryEnvelope(envelopeID: "coverageR3", inputText: "owned synthetic question",
            sessionID: "coverageR3-session", conversationID: "coverageR3-session",
            turnID: "coverageR3-turn", taskID: "coverageR3-task", attempt: 1,
            providerID: "syntheticR3", modelID: "modelR3", configurationFingerprint: "configR3",
            policySnapshotID: "policyR3", grantSnapshotID: "grantR3", failureMessage: failureMessage)
    }

    /// Every case below is thrown on a path that ends in ChatStore's stream catch:
    /// AgentLoop.run (emptyResponse, timedOut, identity and ledger guards,
    /// compactionCheckpointUnavailable from applyAutomaticCompaction and the
    /// engine's canonical compaction closure), the same closure's SessionStoreError,
    /// ChatStore's capture closure (OrdinaryAutoCompactionError) and the turn-start
    /// capture in AgentLoopChatEngine (AutomaticCompactionSourceUnavailable).
    private func reachableErrors(marker: String) -> [(String, any Error)] {
        [
            ("emptyResponse", AgentLoopError.emptyResponse),
            ("timedOut", AgentLoopError.timedOut(30)),
            ("composerSnapshotMismatch", AgentLoopError.composerSnapshotMismatch),
            ("composerAuthorizationUnavailable", AgentLoopError.composerAuthorizationUnavailable),
            ("toolExecutionFactsUnavailable", AgentLoopError.toolExecutionFactsUnavailable),
            ("invalidToolExecutionAttempt", AgentLoopError.invalidToolExecutionAttempt),
            ("executionIdentityMismatch", AgentLoopError.executionIdentityMismatch),
            ("parentTerminalPersistenceFailed", AgentLoopError.parentTerminalPersistenceFailed),
            ("compactionCheckpointUnavailable",
                AgentLoopError.compactionCheckpointUnavailable("canonical commit not observed")),
            ("sessionNotFound", SessionStoreError.sessionNotFound(marker)),
            ("sessionSnapshotConflict", SessionStoreError.sessionSnapshotConflict(marker)),
            ("sessionCommitUncertain", SessionStoreError.sessionCommitUncertain(marker)),
            ("compactionRefused", SessionStoreError.compactionRefused(marker)),
            ("compactionCheckpointRevisionMismatch",
                SessionStoreError.compactionCheckpointRevisionMismatch(marker)),
            ("ordinaryAutoCompaction", ChatStore.OrdinaryAutoCompactionError.unverifiedHistory),
            ("automaticCompactionSourceUnavailable",
                AgentLoopChatEngine.AutomaticCompactionSourceUnavailable()),
        ]
    }

    @Test func reachableEngineErrorsAreNotTheGenericFallbackAndCarryNoPayload() {
        let marker = "synthetic-r3-payload-/Users/owner/secret-" + UUID().uuidString
        for (label, error) in reachableErrors(marker: marker) {
            let visible = ChatStore.userErrorMessage(error)
            #expect(visible != Self.unknownFallback, "\(label) fell to CHAT-UNKNOWN")
            #expect(!visible.isEmpty, "\(label) has empty copy")
            #expect(!visible.contains(marker), "\(label) leaked its payload")
        }
    }

    @Test func projectSessionWrappedErrorReadsTheSameAsTheBareError() {
        let marker = "synthetic-r3-payload-" + UUID().uuidString
        for (label, error) in reachableErrors(marker: marker) {
            let bare = ChatStore.userErrorMessage(error)
            let display = AgentLoopChatEngine.retryFailureMessage(for: error)
            let wrapped = ChatStore.userErrorMessage(
                ChatSessionRuntimeError.turnFailed(envelope(display)))
            #expect(wrapped == bare, "\(label): project and ordinary sessions show different text")
            #expect(!wrapped.contains(marker), "\(label): wrapped copy leaked its payload")
        }
    }
}
