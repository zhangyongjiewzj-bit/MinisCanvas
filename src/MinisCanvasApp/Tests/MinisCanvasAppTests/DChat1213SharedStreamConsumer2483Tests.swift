import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// The App's one BridgeStore-owned ChatStore consumes both streams. The
/// controlled engines only supply events; session routing, frame coalescing,
/// terminalization, and SessionStore writes all use production consumers.
@Suite("D-CHAT-12/13 shared stream routing", .serialized)
@MainActor
struct DChat1213SharedStreamConsumer2483Tests {
    @Test("late long-answer chunks finish in their origin while another session streams")
    func backgroundAnswerReturnsCompleteAndDurable() async throws {
        let (bridge, sessionStore, root) = try makeFixture()
        let source = ControlledFrameStreamEngine()
        let other = ControlledFrameStreamEngine()
        defer {
            source.continuation.finish()
            other.continuation.finish()
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let chat = bridge.chat
        chat.agentEngine = source
        chat.draftText = "A：生成一段长回复"
        chat.sendDraft()
        #expect(try await waitUntil { source.executionIdentity != nil })
        let originID = try #require(chat.activeSessionID)
        let originTurn = try #require(chat.turnTaskForTests(sessionID: originID))
        source.continuation.yield(.textDelta("A-首段\n"))
        #expect(try await waitUntil { chat.messages.last?.content == "A-首段\n" })

        _ = try bridge.performSessionAction(.new(title: "B：独立会话"))
        let otherID = try #require(chat.activeSessionID)
        #expect(otherID != originID)
        #expect(chat.isStreaming && !chat.isActiveSessionStreaming)
        chat.agentEngine = other
        chat.draftText = "B：同时生成"
        chat.sendDraft()
        #expect(try await waitUntil { other.executionIdentity != nil })
        let otherTurn = try #require(chat.turnTaskForTests(sessionID: otherID))
        other.continuation.yield(.textDelta("B-只属于 B"))
        #expect(try await waitUntil { chat.messages.last?.content == "B-只属于 B" })

        let lateChunks = (0..<48).map { index in
            "A-后续-\(index):" + String(repeating: "甲🙂", count: 128) + "\n"
        }
        for chunk in lateChunks { source.continuation.yield(.textDelta(chunk)) }
        source.continuation.yield(.done(stopReason: .endTurn))
        source.continuation.finish()
        await originTurn.value

        #expect(chat.activeSessionID == otherID)
        #expect(chat.messages.last?.content == "B-只属于 B")
        #expect(chat.messages.last?.isStreaming == true)
        let origin = try #require(chat.sessions.first { $0.id == originID })
        let fullAnswer = "A-首段\n" + lateChunks.joined()
        #expect((fullAnswer as NSString).length >= 18_000)
        #expect(origin.messages.last?.content == fullAnswer)
        #expect(origin.messages.last?.isStreaming == false)
        #expect(origin.unread, "后台完成的 A 应在 B 可见时标为未读")
        let durableOrigin = try #require(sessionStore.loadSession(id: originID.uuidString))
        #expect(durableOrigin.messages.last?.content == fullAnswer)

        _ = try bridge.performSessionAction(.switch(sessionID: originID.uuidString))
        #expect(chat.messages.last?.content == fullAnswer)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(!chat.isActiveSessionStreaming)
        #expect(chat.sessions.first(where: { $0.id == originID })?.unread == false)
        _ = try bridge.performSessionAction(.switch(sessionID: otherID.uuidString))
        #expect(chat.messages.last?.content == "B-只属于 B")
        other.continuation.finish()
        await otherTurn.value
        #expect(chat.messages.last?.isStreaming == false)

        let reopenedStore = SessionStore(directory: root)
        let reopened = ChatStore()
        #expect(reopened.attachPersistence(reopenedStore))
        let reopenedOther = try #require(reopened.sessions.first { $0.id == otherID })
        #expect(reopenedOther.messages.allSatisfy { !$0.content.contains("A-后续-") })
        reopened.switchSession(id: originID)
        #expect(reopened.messages.last?.content == fullAnswer)
        #expect(reopened.messages.last?.isStreaming == false)
    }

    @Test("a stopped origin rejects late chunks after session switching")
    func cancellationCannotRewriteOriginOrCurrentSession() async throws {
        let (bridge, sessionStore, root) = try makeFixture()
        let source = ControlledFrameStreamEngine()
        defer {
            source.continuation.finish()
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: root)
        }
        let chat = bridge.chat
        chat.agentEngine = source
        chat.draftText = "A：可取消流"
        chat.sendDraft()
        #expect(try await waitUntil { source.executionIdentity != nil })
        let originID = try #require(chat.activeSessionID)
        let originTurn = try #require(chat.turnTaskForTests(sessionID: originID))
        source.continuation.yield(.textDelta("A-已显示"))
        #expect(try await waitUntil { chat.messages.last?.content == "A-已显示" })

        _ = try bridge.performSessionAction(.new(title: "B：当前会话"))
        let otherID = try #require(chat.activeSessionID)
        chat.stopStreaming()
        #expect(chat.isStreaming, "B 的停止不能取消后台 A 流")
        _ = try bridge.performSessionAction(.switch(sessionID: originID.uuidString))
        let originalAssistant = try #require(chat.messages.last)
        chat.stopStreaming()
        let frozen = try #require(chat.messages.last?.content)
        #expect(chat.messages.last?.id == originalAssistant.id)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.wasInterrupted == true)
        #expect(frozen == originalAssistant.content)
        _ = try bridge.performSessionAction(.switch(sessionID: otherID.uuidString))
        let otherMessages = chat.messages
        source.continuation.yield(.textDelta("A-取消后的迟到块"))
        source.continuation.yield(.done(stopReason: .endTurn))
        source.continuation.finish()
        await originTurn.value

        #expect(chat.activeSessionID == otherID)
        #expect(chat.messages == otherMessages)
        _ = try bridge.performSessionAction(.switch(sessionID: originID.uuidString))
        #expect(chat.messages.last?.content == frozen)
        #expect(chat.messages.last?.isStreaming == false)
        let durableOrigin = try #require(sessionStore.loadSession(id: originID.uuidString))
        #expect(durableOrigin.messages.last?.content == frozen)
    }

    private func makeFixture() throws -> (BridgeStore, SessionStore, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent(
            "chat-1213-2483-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionStore = SessionStore(directory: root)
        let bridge = BridgeStore(
            sessionStore: sessionStore, canvasRuntimeState: .disabled,
            agentTaskStore: AgentTaskStore(), canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(sessionStore))
        return (bridge, sessionStore, root)
    }

    private func waitUntil(
        timeout: Duration = .seconds(4), _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
