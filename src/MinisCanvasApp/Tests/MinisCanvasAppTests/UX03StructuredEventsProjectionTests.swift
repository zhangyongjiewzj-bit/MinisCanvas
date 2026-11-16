import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("UX-03 结构化对话事件投影")
struct UX03StructuredEventsProjectionTests {

    private func identity(
        sessionID: String = "session-a",
        turnID: String = "turn-7",
        taskID: String = "task-9",
        attempt: Int = 1,
        scopeID: String = "scope-a"
    ) -> MinisCanvasApp.ConversationEventIdentity {
        #expect(attempt > 0)
        guard let identity = MinisCanvasApp.ConversationEventIdentity(
            sessionID: sessionID,
            turnID: turnID,
            taskID: taskID,
            attempt: attempt,
            scopeID: scopeID
        ) else {
            fatalError("UX03 fixture identity must be valid")
        }
        return identity
    }

    private func event(
        id: String,
        sequence: Int64,
        kind: MinisCanvasApp.ConversationEventKind,
        status: MinisCanvasApp.ConversationEventStatus,
        summary: String,
        identity: MinisCanvasApp.ConversationEventIdentity? = nil,
        providerID: String? = "provider-a",
        modelID: String? = "model-a",
        toolName: String? = nil,
        elapsedMilliseconds: Int? = nil,
        errorCategory: MinisCanvasApp.ConversationEventErrorCategory? = nil
    ) -> MinisCanvasApp.ConversationEvent {
        MinisCanvasApp.ConversationEvent(
            id: id,
            identity: identity ?? self.identity(),
            sequence: sequence,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            kind: kind,
            status: status,
            summary: summary,
            providerID: providerID,
            modelID: modelID,
            toolName: toolName,
            elapsedMilliseconds: elapsedMilliseconds,
            errorCategory: errorCategory
        )
    }

    private func coreEvent(from event: MinisCanvasApp.ConversationEvent) -> MinisCore.ConversationEvent {
        guard let identity = MinisCore.ConversationEventIdentity(
            sessionID: event.identity.sessionID,
            turnID: event.identity.turnID,
            taskID: event.identity.taskID,
            attempt: event.identity.attempt,
            scopeID: event.identity.scopeID
        ) else {
            fatalError("UX03 core event identity must be valid")
        }
        return MinisCore.ConversationEvent(
            id: event.id,
            identity: identity,
            sequence: event.sequence,
            occurredAt: event.occurredAt,
            kind: MinisCore.ConversationEventKind(rawValue: event.kind.rawValue)!,
            status: MinisCore.ConversationEventStatus(rawValue: event.status.rawValue)!,
            summary: event.summary,
            providerID: event.providerID,
            modelID: event.modelID,
            toolName: event.toolName,
            elapsedMilliseconds: event.elapsedMilliseconds,
            errorCategory: event.errorCategory.flatMap {
                MinisCore.ConversationEventErrorCategory(rawValue: $0.rawValue)
            }
        )
    }

    @Test("事件按 sequence 稳定排序并保留完整身份")
    func eventsAreSortedAndBoundToRuntimeIdentity() {
        var projection = MinisCanvasApp.ConversationEventProjection()
        let acceptedTask = projection.ingest(event(
            id: "task",
            sequence: 30,
            kind: .task,
            status: .succeeded,
            summary: "任务完成"
        ))
        let acceptedThinking = projection.ingest(event(
            id: "thinking",
            sequence: 10,
            kind: .thinking,
            status: .running,
            summary: "正在思考"
        ))
        let acceptedTool = projection.ingest(event(
            id: "tool",
            sequence: 20,
            kind: .tool,
            status: .succeeded,
            summary: "读取文件完成",
            toolName: "file_read",
            elapsedMilliseconds: 420
        ))
        #expect(acceptedTask)
        #expect(acceptedThinking)
        #expect(acceptedTool)

        #expect(projection.events.map(\.id) == ["thinking", "tool", "task"])
        #expect(projection.events.map(\.kind) == [.thinking, .tool, .task])
        let context = projection.events[1].identity
        #expect(context.sessionID == "session-a")
        #expect(context.turnID == "turn-7")
        #expect(context.taskID == "task-9")
        #expect(context.attempt == 1)
        #expect(context.scopeID == "scope-a")
    }

    @Test("stop/thinking/model/tool/task 五类都进入同一投影")
    func allEventKindsAreProjectable() {
        let kinds = MinisCanvasApp.ConversationEventKind.allCases
        let projection = MinisCanvasApp.ConversationEventProjection(events: kinds.enumerated().map { index, kind in
            event(
                id: kind.rawValue,
                sequence: Int64(index),
                kind: kind,
                status: kind == .stop ? .stopped : .running,
                summary: "\(kind.label)事件"
            )
        })

        #expect(Set(projection.events.map(\.kind)) == Set(kinds))
        #expect(projection.events.map(\.sequence) == [0, 1, 2, 3, 4])
    }

    @Test("摘要只保留脱敏后的短文本")
    func summariesAreRedactedAndBounded() {
        let event = event(
            id: "tool",
            sequence: 1,
            kind: .tool,
            status: .failed,
            summary: "读取 /Users/alice/秘密.txt，authorization: Bearer super-secret-token",
            toolName: "file_read",
            errorCategory: .authorization
        )

        #expect(!event.summary.contains("/Users/alice"))
        #expect(!event.summary.contains("super-secret-token"))
        #expect(event.summary.count <= MinisCanvasApp.ConversationEventRedactor.maximumSummaryLength)
        #expect(event.errorCategory == .authorization)
    }

    @Test("终态拒绝迟到事件覆盖")
    func terminalStateRejectsLateEvents() {
        var projection = MinisCanvasApp.ConversationEventProjection()
        let running = event(
            id: "tool-1",
            sequence: 1,
            kind: .tool,
            status: .running,
            summary: "执行命令",
            toolName: "shell_execute"
        )
        let succeeded = event(
            id: "tool-1",
            sequence: 2,
            kind: .tool,
            status: .succeeded,
            summary: "命令完成",
            toolName: "shell_execute",
            elapsedMilliseconds: 900
        )
        let lateFailure = event(
            id: "tool-1",
            sequence: 3,
            kind: .tool,
            status: .failed,
            summary: "迟到错误",
            toolName: "shell_execute",
            errorCategory: .tool
        )

        let acceptedRunning = projection.ingest(running)
        let acceptedSucceeded = projection.ingest(succeeded)
        let acceptedLateFailure = projection.ingest(lateFailure)
        #expect(acceptedRunning)
        #expect(acceptedSucceeded)
        #expect(!acceptedLateFailure)
        #expect(projection.events.first?.status == .succeeded)
        #expect(projection.events.first?.elapsedMilliseconds == 900)
    }

    @Test("卡片展示面只包含允许的脱敏字段")
    func cardPresentationHasNoRawPayloadSurface() {
        let event = event(
            id: "model",
            sequence: 4,
            kind: .model,
            status: .failed,
            summary: "模型请求失败",
            providerID: "provider-a",
            modelID: "model-a",
            elapsedMilliseconds: 1_250,
            errorCategory: .provider
        )

        let display = ToolEventCard.displayModel(for: coreEvent(from: event))
        #expect(display.summary == "模型请求失败")
        #expect(display.status == "失败")
        #expect(display.elapsed == "1.25 s")
        #expect(display.provider == "provider-a")
        #expect(display.model == "model-a")
        #expect(display.errorCategory == "provider")
        #expect(display.accessibilityLabel == "模型，失败，耗时 1.25 s，Provider provider-a，Model model-a，错误 provider")
        #expect(!display.accessibilityLabel.contains("payload"))
    }

    @Test("空身份不会进入事件合同")
    func emptyIdentityIsRejected() {
        #expect(MinisCanvasApp.ConversationEventIdentity(
            sessionID: "",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 1,
            scopeID: "scope-a"
        ) == nil)
        #expect(MinisCanvasApp.ConversationEventIdentity(
            sessionID: "session-a",
            turnID: "turn-7",
            taskID: "task-9",
            attempt: 0,
            scopeID: "scope-a"
        ) == nil)
    }
}
