import Foundation
import MinisCore

struct UsageAttribution: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case conversation, subagent }
    let kind: Kind
    let taskID: String?
    let childTranscriptLocator: ChildTranscriptLocator?

    init(kind: Kind, taskID: String?, childTranscriptLocator: ChildTranscriptLocator? = nil) {
        self.kind = kind; self.taskID = taskID
        self.childTranscriptLocator = childTranscriptLocator
    }

    var label: String {
        kind == .subagent ? "子智能体 · " + (taskID ?? "身份未验证") : "主会话"
    }
}

struct UsageMCPCallRecord: Codable, Equatable, Sendable {
    let timestamp: Date
    let serverID: String
    let fullName: String
    let succeeded: Bool
}

extension UsageStore {
    /// Reads the existing durable records; task ID or a time window alone is
    /// never sufficient to attribute tokens to a retry. No records means unknown.
    func childTokenUsage(for locator: ChildTranscriptLocator) async -> ChildResultTokenUsage? {
        guard locator.isWellFormed, await waitForPersistence(), hasLoadedSnapshot else { return nil }
        let records = callHistory.filter {
            $0.attribution?.kind == .subagent && $0.attribution?.taskID == locator.taskID
                && $0.attribution?.childTranscriptLocator == locator
        }
        guard !records.isEmpty else { return nil }
        var input = 0, output = 0, totalInput = 0
        for record in records {
            guard record.inputTokens >= 0, record.outputTokens >= 0, record.totalInputTokens >= 0 else { return nil }
            let i = input.addingReportingOverflow(record.inputTokens)
            let o = output.addingReportingOverflow(record.outputTokens)
            let t = totalInput.addingReportingOverflow(record.totalInputTokens)
            guard !i.overflow, !o.overflow, !t.overflow else { return nil }
            input = i.partialValue; output = o.partialValue; totalInput = t.partialValue
        }
        // C9：inputTokens 保持新鲜输入口径；总输入走 C-L2 新增的可选字段 totalInputTokens。
        let result = ChildResultTokenUsage(inputTokens: input, outputTokens: output,
                                          reportedCallCount: records.count,
                                          totalInputTokens: totalInput)
        return result.isWellFormed ? result : nil
    }

    func recordTelemetry(_ observation: UsageTelemetryObservation) {
        switch observation {
        case .childUsage(let origin, let usage, let route):
            recordCall(provider: route?.provider ?? "子智能体", model: route?.model ?? "服务路由未确认", usage: usage,
                attribution: UsageAttribution(kind: .subagent, taskID: origin.taskID,
                    childTranscriptLocator: origin.childTranscriptLocator.flatMap {
                        $0.isWellFormed && $0.taskID == origin.taskID ? $0 : nil
                    }), sessionID: origin.childTranscriptLocator.flatMap {
                        $0.isWellFormed && $0.taskID == origin.taskID ? $0.parentSessionID : nil
                    })
        case .mcpCall(let serverID, let fullName, let succeeded):
            recordMCPCall(UsageMCPCallRecord(timestamp: Date(),
                serverID: ProductRedactionPolicy.redact(serverID, maxLength: 256),
                fullName: ProductRedactionPolicy.redact(fullName, maxLength: 512), succeeded: succeeded))
        }
    }
}
