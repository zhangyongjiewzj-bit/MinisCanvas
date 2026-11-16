import Foundation
import Testing
@testable import MinisCore

private actor ChildRolePromptLog {
    var values: [String?] = []
    func record(_ value: String?) { values.append(value) }
}
private final class ChildRolePromptProvider: LLMProvider {
    let name = "child-role-synthetic"
    var model: LLMModel = .claudeHaiku45
    let log: ChildRolePromptLog
    init(log: ChildRolePromptLog) { self.log = log }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await log.record(systemPrompt)
        return LLMResponse(text: "done", stopReason: nil, usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Role preset orchestration consumer")
struct ChildRoleOrchestrationConsumerTests {
    @Test func selectedRoleReachesProviderAndUnknownRoleNeverDispatches() async throws {
        let log = ChildRolePromptLog()
        let tool = OrchestrationToolExecutor(orchestrator: AgentOrchestrator(
            provider: ChildRolePromptProvider(log: log), toolExecutor: NoopToolExecutor()))
        let base: [String: Any] = ["input_version": 1,
            "tasks": [["id": "role", "title": "role", "instructions": "perform assigned task"]],
            "strategy": "sequential", "system_prompt": "original"]
        _ = try await tool.execute(name: "orchestrate", input: base)
        #expect(await log.values.last == AgentOrchestrator.childSafetyPrompt + "\n\n" + "original")
        for role in ChildRolePreset.allCases {
            var input = base
            input["role_preset"] = role.rawValue
            _ = try await tool.execute(name: "orchestrate", input: input)
            #expect(await log.values.last == AgentOrchestrator.childSafetyPrompt + "\n\n" + role.instructionPrefix + "\n\noriginal")
        }
        let count = await log.values.count
        var invalid = base
        invalid["role_preset"] = "administrator"
        do {
            _ = try await tool.execute(name: "orchestrate", input: invalid)
            Issue.record("Unknown role must be rejected before provider dispatch")
        } catch ToolExecutorError.invalidParameter(let field) {
            #expect(field == "role_preset")
        }
        #expect(await log.values.count == count)
    }
}
