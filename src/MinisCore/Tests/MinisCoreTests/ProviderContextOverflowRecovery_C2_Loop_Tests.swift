import Foundation
import Testing
@testable import MinisCore

// Depends on C-L1: LLMError.contextLengthExceeded.
struct ProviderContextOverflowRecoveryC2LoopTests {
    private func makeLoop(
        admission: ContextAdmissionConfig?, root: URL, budget: BudgetTracker? = nil
    ) throws -> AgentLoop {
        var loop = AgentLoop(
            maxIterations: 10, loopDetector: nil, requestBudget: budget,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root))
        loop.contextAdmission = admission
        return loop
    }

    private var history: [LLMMessage] {
        windowTestRepeatedHistory(messages: 59, characters: 400) + [LLMMessage(role: .user, content: "继续")]
    }

    @Test func overflowThenSuccessCompactsOnceAndRetriesOnce() async throws {
        let root = try minisCoreToolContractRoot("c2-once")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 1_000_000, triggerFraction: 0.8, reduction: reduction))
        let tracker = BudgetTracker(RequestBudget(overBudgetPolicy: .warn))
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded),
                       .response(LLMResponse(text: "好", stopReason: nil, usage: LLMUsage(inputTokens: 10, outputTokens: 2)))],
            deliver: { reduction.apply($0) })
        let result = try await makeLoop(admission: admission, root: root, budget: tracker).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c2-once"))
        #expect(result.messages.last?.content == "好")
        #expect(provider.callCount == 2)
        #expect(windowTestCharacterCount(provider.requests[1]) < windowTestCharacterCount(provider.requests[0]))
        #expect(await tracker.budget.usedRequests == 1, "the failed attempt is not charged")
    }

    @Test func aSecondOverflowSurfacesTheTypedErrorAfterExactlyTwoRequests() async throws {
        let root = try minisCoreToolContractRoot("c2-twice")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 1_000_000, triggerFraction: 0.8))
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded), .failure(LLMError.contextLengthExceeded)])
        do {
            _ = try await makeLoop(admission: admission, root: root).run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c2-twice"))
            Issue.record("expected the overflow error")
        } catch let error as LLMError {
            guard case .contextLengthExceeded = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(provider.callCount == 2)
    }

    // C3-11: the newest message's own media already fills the media budget: no summary request,
    // no retry, and the error is the plain "request too large" one, not "compress the conversation".
    @Test func overflowCausedByTheNewestMessagesOwnMediaIsNotCompactedAndReportsRequestTooLarge() async throws {
        let root = try minisCoreToolContractRoot("c2-own-media")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 1_000_000, triggerFraction: 0.8))
        var messages = windowTestRepeatedHistory(messages: 59, characters: 400)
        messages.append(LLMMessage(role: .user, content: "看这些图", images: [
            .init(mimeType: "image/png", data: Data(count: HistoryMediaBudget.defaultMaxBytes + 1024))]))
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded), .failure(LLMError.contextLengthExceeded)])
        do {
            _ = try await makeLoop(admission: admission, root: root).run(
                messages: messages, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c2-own-media"))
            Issue.record("expected the request-too-large error")
        } catch let error as LLMError {
            guard case .httpStatus(let code, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(code == 413)
        }
        #expect(provider.callCount == 1, "no compaction, no resend")
    }

    // F-05：压缩或缩减做过一次仍然超长，且最新一条用户消息带媒体：报“请求内容太大”，不是“请压缩对话”。
    @Test func aRepeatedOverflowWithMediaInTheNewestUserMessageReportsRequestTooLarge() async throws {
        let root = try minisCoreToolContractRoot("c2-media-after-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 1_000_000, triggerFraction: 0.8))
        var messages = windowTestRepeatedHistory(messages: 59, characters: 400)
        messages.append(LLMMessage(role: .user, content: "看这张图", images: [
            .init(mimeType: "image/png", data: Data(count: 1024))]))
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded), .failure(LLMError.contextLengthExceeded)])
        do {
            _ = try await makeLoop(admission: admission, root: root).run(
                messages: messages, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c2-media-after-recovery"))
            Issue.record("expected the request-too-large error")
        } catch let error as LLMError {
            guard case .httpStatus(let code, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(code == 413)
        }
        #expect(provider.callCount == 2, "the one recovery was tried before the error was reported")
    }

    // MC4-010：超窗重试后无法区分是文字还是附件过大，提示不能只让用户去减图片。
    @Test func requestTooLargeGuidanceCoversTextAndAttachments() {
        let suggestion = HTTPStatusMessages.message(for: 413).suggestionZH
        #expect(suggestion.contains("缩短这条消息") && suggestion.contains("减少附件"))
    }

    // F-05：本回合工具返回的图片不算“最新消息自带的媒体”：文字超窗照常先压缩或缩减再重试。
    @Test func toolImagesAfterTheNewestUserMessageDoNotMakeATextOverflowLookLikeATooBigImage() async throws {
        let root = try minisCoreToolContractRoot("c2-tool-images")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 1_000_000, triggerFraction: 0.8))
        var messages = windowTestRepeatedHistory(messages: 59, characters: 400)
        messages.append(LLMMessage(role: .user, content: "继续"))
        messages.append(LLMMessage(role: .assistant, content: "", toolCalls: [
            LLMToolCall(id: "i1", name: "file_read", rawArguments: "{}", arguments: [:])]))
        messages.append(LLMMessage(role: .tool, content: "图", images: [
            .init(mimeType: "image/png", data: Data(count: 9 * 1024 * 1024)),
            .init(mimeType: "image/png", data: Data(count: 9 * 1024 * 1024)),
        ], toolCallID: "i1"))
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded),
                       .response(LLMResponse(text: "好", stopReason: nil, usage: nil))])
        let result = try await makeLoop(admission: admission, root: root).run(
            messages: messages, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c2-tool-images"))
        #expect(result.messages.last?.content == "好")
        #expect(provider.callCount == 2)
    }

    @Test func overflowWithUncompactableToolHistoryFallsBackToRequestReduction() async throws {
        let root = try minisCoreToolContractRoot("c2-reduce")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 10_000_000, triggerFraction: 0.8, reduction: reduction))
        var messages = [LLMMessage(role: .user, content: "读文件")]
        for index in 1...10 {
            messages.append(LLMMessage(
                role: .assistant, content: "",
                toolCalls: [LLMToolCall(id: "k\(index)", name: "file_read", rawArguments: "{}", arguments: [:])]))
            messages.append(LLMMessage(role: .tool, content: String(repeating: "q", count: 20_000), toolCallID: "k\(index)"))
        }
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded),
                       .response(LLMResponse(text: "好", stopReason: nil, usage: nil))],
            deliver: { reduction.apply($0) })
        let result = try await makeLoop(admission: admission, root: root).run(
            messages: messages, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c2-reduce"))
        #expect(result.messages.last?.content == "好")
        #expect(provider.callCount == 2)
        // Ruling S1 (M_C批派工单_v1): the last 6 tool exchanges stay intact; only older
        // tool results are excerpted. 10 results -> the first 4 shrink, the last 6 do not.
        let retried = provider.requests[1].filter { $0.role == .tool }
        #expect(retried.count == 10)
        #expect(retried.prefix(4).allSatisfy { $0.content.count < 2_000 })
        #expect(retried.suffix(6).allSatisfy { $0.content.count == 20_000 })
        #expect(windowTestCharacterCount(provider.requests[1]) < windowTestCharacterCount(provider.requests[0]))
        #expect(result.messages.filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
    }

    // R3-05: a sub-agent loop has no App delivery projection and no session checkpoint.
    @Test func loopAppliedReductionShrinksTheRequestAndRetriesAfterOverflow() async throws {
        let root = try minisCoreToolContractRoot("c2-standalone")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 10_000_000, triggerFraction: 0.8,
            allowsCompaction: false, appliesReductionInLoop: true))
        var messages = [LLMMessage(role: .user, content: "读文件")]
        for index in 1...10 {
            messages.append(LLMMessage(
                role: .assistant, content: "",
                toolCalls: [LLMToolCall(id: "k\(index)", name: "file_read", rawArguments: "{}", arguments: [:])]))
            messages.append(LLMMessage(role: .tool, content: String(repeating: "q", count: 20_000), toolCallID: "k\(index)"))
        }
        // No `deliver`: the provider sees exactly what the loop sends.
        let provider = ScriptedWindowProvider(
            outcomes: [.failure(LLMError.contextLengthExceeded),
                       .response(LLMResponse(text: "好", stopReason: nil, usage: nil))])
        let result = try await makeLoop(admission: admission, root: root).run(
            messages: messages, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c2-standalone"))
        #expect(result.messages.last?.content == "好")
        #expect(provider.callCount == 2)
        #expect(provider.requests[0].filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
        let retried = provider.requests[1].filter { $0.role == .tool }
        #expect(retried.prefix(4).allSatisfy { $0.content.count < 2_000 })
        #expect(retried.suffix(6).allSatisfy { $0.content.count == 20_000 })
        #expect(result.messages.filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
    }

    @Test func aRunThatDisallowsCompactionNeverCompactsEvenWhenTheHistoryCould() async throws {
        let root = try minisCoreToolContractRoot("c2-standalone-nocompact")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 1_000_000, triggerFraction: 0.8, allowsCompaction: false))
        // Same compactable history as overflowThenSuccessCompactsOnceAndRetriesOnce: nothing
        // to reduce, so the overflow surfaces after one request instead of compacting.
        let provider = ScriptedWindowProvider(outcomes: [.failure(LLMError.contextLengthExceeded)])
        await #expect(throws: LLMError.self) {
            _ = try await makeLoop(admission: admission, root: root).run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c2-standalone-nocompact"))
        }
        #expect(provider.callCount == 1)
    }

    @Test func withoutAdmissionTheErrorPropagatesUnchanged() async throws {
        let root = try minisCoreToolContractRoot("c2-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedWindowProvider(outcomes: [.failure(LLMError.contextLengthExceeded)])
        await #expect(throws: LLMError.self) {
            _ = try await makeLoop(admission: nil, root: root).run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c2-none"))
        }
        #expect(provider.callCount == 1)
    }
}
