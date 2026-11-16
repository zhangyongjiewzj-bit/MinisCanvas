import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Chat conversation indicator consumer")
struct ChatConversationIndicatorConsumerTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("idle session has no runtime badge and exposes idle semantics")
    @MainActor
    func idleSessionHasNoRuntimeBadgeAndExposesIdleSemantics() {
        let session = UUID()
        let settled = ChatStore.ExecutionSnapshot(sessionID: session, turnID: 2, taskID: "done", state: .idle)
        let runtime = SessionRuntimeStatus.project(sessionID: session, execution: settled, events: [])
        #expect(runtime == nil)
        let fallback = ChatStore.ConversationListIndicator.derive(execution: settled, unread: false)
        #expect(fallback == .idle)
        #expect(fallback.accessibilityLabel == "会话空闲")
        #expect(fallback.helpText == "空闲")
    }

    @Test("failed-session retry button owns its VoiceOver action semantics")
    func retryButtonExposesActionSemanticsOnTheButton() throws {
        let source = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )
        let slot = try #require(
            source.range(
                of: "private func conversationIndicatorSlot"
            ).map { String(source[$0.lowerBound...]) }
        )

        #expect(slot.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
        #expect(slot.contains(".accessibilityHint(presentation.helpText)"))
    }

    @Test("message role and elapsed metadata remain visible and accessible")
    func messageMetadataExposesRoleAndElapsedSemantics() throws {
        let source = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )

        for contract in [
            "private enum ChatMessageMetadata",
            "static func roleLabel(for role: ChatRole)",
            "static func elapsedText(since timestamp: Date",
            "ChatMessageMetadataView",
            ".accessibilityLabel(\"\\(roleLabel)消息\")",
            ".accessibilityValue(elapsedText)",
            ".accessibilityIdentifier(\"chat.message.metadata.\\(message.id.uuidString)\")"
        ] {
            #expect(source.contains(contract), "Missing message metadata contract: \(contract)")
        }
    }

    @Test("agent task projection keeps session and child parent identities visible")
    func taskProjectionRetainsParentIdentityForSidebarConsumer() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "session-task",
            parentID: "session-123",
            providerID: "provider",
            modelID: "model"
        )
        _ = try store.enqueue(
            taskID: "child-task",
            parentID: "session-task",
            providerID: "provider",
            modelID: "model"
        )

        let snapshots = store.taskCenterSnapshots()
        #expect(snapshots.contains { $0.taskID == "session-task" && $0.parentID == "session-123" })
        #expect(snapshots.contains { $0.taskID == "child-task" && $0.parentID == "session-task" })
        #expect(store.taskCenterProjection().totalTasks == 2)
    }

    @Test("four states remain distinguishable without relying on color")
    func indicatorSourceKeepsDistinctSymbolsAndLabels() throws {
        let source = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift"
        )

        for contract in [
            "case .failed: \"exclamationmark.triangle.fill\"",
            "case .running: \"circle.dotted\"",
            "case .unread: \"circle.fill\"",
            "case .idle: \"circle\"",
            "case .failed: \"会话失败\"",
            "case .running: \"会话生成中\"",
            "case .unread: \"会话有未读消息\"",
            "case .idle: \"会话空闲\""
        ] {
            #expect(source.contains(contract), "Missing indicator semantic contract: \(contract)")
        }
    }
}


@Suite("O16d sidebar runtime facts")
@MainActor
struct O16SessionRuntimeStatusTests {
    private func event(session: UUID, turn: Int, sequence: Int64,
                       kind: MinisCore.ConversationEventKind, status: MinisCore.ConversationEventStatus,
                       decision: MinisCore.ConversationApprovalDecision? = nil) throws -> MinisCore.ConversationEvent {
        let optionalIdentity = MinisCore.ConversationEventIdentity(sessionID: session.uuidString,
            turnID: String(turn), taskID: "fixture-task", attempt: 1, scopeID: "fixture-scope")
        let identity = try #require(optionalIdentity)
        return MinisCore.ConversationEvent(id: session.uuidString + String(sequence), identity: identity,
            sequence: sequence, occurredAt: Date(), kind: kind, status: status, summary: "合成状态",
            toolCallID: "fixture-call", receiptID: "fixture-receipt", approvalDecision: decision)
    }

    @Test func approvalReviewAndStopRemainBoundToTheirOwnSessions() throws {
        let waiting = UUID(), review = UUID(), stopped = UUID()
        let events = [
            try event(session: waiting, turn: 1, sequence: 1, kind: .approval, status: .waiting, decision: .requested),
            try event(session: review, turn: 1, sequence: 2, kind: .tool, status: .needsReview),
            try event(session: stopped, turn: 1, sequence: 3, kind: .stop, status: .stopped)]
        let projection = MinisCore.ConversationEventProjection(events: events)
        #expect(SessionRuntimeStatus.project(sessionID: waiting, execution: nil, events: projection.events) == .waitingApproval)
        #expect(SessionRuntimeStatus.project(sessionID: review, execution: nil, events: projection.events) == .needsReview)
        #expect(SessionRuntimeStatus.project(sessionID: stopped, execution: nil, events: projection.events) == .interrupted)
        #expect(SessionRuntimeStatus.project(sessionID: UUID(), execution: nil, events: projection.events) == nil)
    }

    @Test func laterTurnAndSettledRunClearOldApprovalWithoutHidingUnreadFallback() throws {
        let session = UUID()
        let waiting = try event(session: session, turn: 1, sequence: 1, kind: .approval, status: .waiting, decision: .requested)
        let next = ChatStore.ExecutionSnapshot(sessionID: session, turnID: 2, taskID: "next", state: .running)
        #expect(SessionRuntimeStatus.project(sessionID: session, execution: next, events: [waiting]) == .running)
        let cancelled = ChatStore.ExecutionSnapshot(sessionID: session, turnID: 2, taskID: "next", state: .idle)
        #expect(SessionRuntimeStatus.project(sessionID: session, execution: cancelled, events: [waiting], terminalOutcome: .cancelled) == .interrupted)
        #expect(SessionRuntimeStatus.project(sessionID: session, execution: cancelled, events: [waiting], terminalOutcome: .succeeded) == nil)
        #expect(ChatStore.ConversationListIndicator.derive(execution: cancelled, unread: true) == .unread)
    }
}
