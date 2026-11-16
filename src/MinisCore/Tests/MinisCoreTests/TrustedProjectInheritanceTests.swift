import Foundation
import Testing
@testable import MinisCore

private actor M02PromptLog {
    var prompts: [String?] = []
    func record(_ prompt: String?) { prompts.append(prompt) }
}
private final class M02Provider: LLMProvider {
    let name = "M02 synthetic"
    var model: LLMModel = .claudeHaiku45
    let log: M02PromptLog
    init(log: M02PromptLog) { self.log = log }
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

@Suite("Child trusted instruction inheritance")
struct TrustedProjectInheritanceTests {
    @Test func childProviderGetsFrozenTrustedPrefixBeforeModelPrompt() async throws {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw FormalTestIsolationPaths.IsolationError.missingContract
        }
        let root = paths.rootDirectory.appendingPathComponent("M02-synthetic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instruction = root.appendingPathComponent("CLAUDE.md")
        try Data("follow project rule".utf8).write(to: instruction)
        let snapshot = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        // The live file changes after admission; the child inherits the parent value.
        try Data("later edit".utf8).write(to: instruction)
        let log = M02PromptLog()
        let owner = AgentOrchestrator(provider: M02Provider(log: log), toolExecutor: NoopToolExecutor())
        let tasks = [SubAgentTask(id: "m02", title: "synthetic", instructions: "untrusted task data", agentType: .builtin)]
        let reports = await TrustedProjectInstructionContext.$current.withValue(snapshot) {
            await owner.orchestrate(tasks: tasks, strategy: .sequential, systemPrompt: "child-specific prompt")
        }
        #expect(reports.first?.result.isSuccess == true)
        let prompts = await log.prompts
        #expect(prompts.first == AgentOrchestrator.childSafetyPrompt + "\n\n" + snapshot.appendingChildPrompt("child-specific prompt"))
        #expect(TrustedProjectInstructionContext.current == nil)
        // A task description cannot turn its project-looking text into a prefix.
        let untrustedReports = await owner.orchestrate(tasks: tasks, strategy: .sequential,
            systemPrompt: "child-specific prompt")
        #expect(untrustedReports.first?.result.isSuccess == true)
        #expect(await log.prompts.last == AgentOrchestrator.childSafetyPrompt + "\n\n" + "child-specific prompt")
    }
}
