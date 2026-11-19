import Foundation
import Testing
@testable import MinisCore

struct ContextWindowPolicyTests {
    @Test func decisionTable() {
        func d(_ occ: Int, judged: Bool, threshold: Double = 0.8) -> ContextWindowPolicy.Decision {
            ContextWindowPolicy.decide(
                occupancyTokens: occ, windowTokens: 100, threshold: threshold,
                compactionAlreadyJudgedForThisTranscript: judged)
        }
        #expect(d(79, judged: false) == .proceed)
        #expect(d(80, judged: false) == .compact(fraction: 0.8))
        #expect(d(85, judged: true) == .proceedAfterRefusal(fraction: 0.85))
        #expect(d(94, judged: true) == .proceedAfterRefusal(fraction: 0.94))
        #expect(d(95, judged: true) == .blocked(fraction: 0.95))
        // A threshold above the hard block still acts at 95%.
        #expect(d(96, judged: false, threshold: 1.0) == .compact(fraction: 0.96))
        #expect(d(96, judged: true, threshold: 1.0) == .blocked(fraction: 0.96))
    }

    @Test func anchoredEstimateAddsOnlyWhatFollowsTheAnchoredReply() {
        let messages = [
            LLMMessage(role: .user, content: String(repeating: "a", count: 400)),
            LLMMessage(role: .assistant, content: String(repeating: "b", count: 400)),
            LLMMessage(role: .user, content: String(repeating: "c", count: 400)),
        ]
        let anchor = ContextWindowPolicy.Anchor(sentMessageCount: 1, reportedTotalInput: 5_000, reportedOutput: 70)
        // message 1 is the anchored reply (counted by reportedOutput); message 2 adds 100.
        #expect(ContextWindowPolicy.estimateInput(messages: messages, systemPrompt: "", anchor: anchor) == 5_170)
        let pure = ContextWindowPolicy.estimateInput(messages: messages, systemPrompt: "", anchor: nil)
        #expect(pure == 301)
    }
}

struct PerRequestWindowAdmissionC10Tests {
    private func makeLoop(
        admission: ContextAdmissionConfig?, root: URL, budget: BudgetTracker? = nil
    ) throws -> AgentLoop {
        var loop = AgentLoop(
            maxIterations: 30, loopDetector: nil, requestBudget: budget,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root))
        loop.contextAdmission = admission
        return loop
    }

    // S1: one user turn with 20 file_read rounds; occupancy crosses the trigger
    // inside the turn. The older results must shrink and the request must go out.
    @Test func singleTurnTwentyFileReadRoundsReducesOlderResultsAndStillSends() async throws {
        let root = try minisCoreToolContractRoot("c10-s1")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 100_000, triggerFraction: 0.8, reduction: reduction))
        var outcomes: [ScriptedWindowProvider.Outcome] = (1...20).map { .response(windowTestToolCallResponse("c\($0)")) }
        outcomes.append(.response(LLMResponse(text: "读完了", stopReason: nil, usage: nil)))
        let provider = ScriptedWindowProvider(outcomes: outcomes, deliver: { reduction.apply($0) })
        let loop = try makeLoop(admission: admission, root: root)

        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "把这 20 个文件都读一遍")],
            systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 20_000),
            tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("c10-s1"))

        #expect(result.messages.last?.content == "读完了")
        #expect(provider.callCount == 21)
        #expect(reduction.isActive)
        // Canonical history held by the loop is not reduced.
        let tools = result.messages.filter { $0.role == .tool }
        #expect(tools.count == 20)
        #expect(tools.allSatisfy { $0.content.count == 20_000 })
        // The last request carried the older results shortened, the newest six whole.
        let last = provider.requests[20].filter { $0.role == .tool }
        #expect(last.count == 20)
        #expect(last.prefix(14).allSatisfy { $0.content.count < 1_700 })
        #expect(last.suffix(6).allSatisfy { $0.content.count == 20_000 })
        // Below the trigger nothing was reduced.
        #expect(provider.requests[5].filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
    }

    // R3-05: the same 20-round turn in a sub-agent run, with no App projection in
    // front of the provider: the loop must shrink the request itself.
    @Test func loopAppliedReductionShrinksOlderResultsWithoutAnAppProjection() async throws {
        let root = try minisCoreToolContractRoot("c10-standalone")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 100_000, triggerFraction: 0.8,
            allowsCompaction: false, appliesReductionInLoop: true))
        var outcomes: [ScriptedWindowProvider.Outcome] = (1...20).map { .response(windowTestToolCallResponse("c\($0)")) }
        outcomes.append(.response(LLMResponse(text: "读完了", stopReason: nil, usage: nil)))
        let provider = ScriptedWindowProvider(outcomes: outcomes)

        let result = try await makeLoop(admission: admission, root: root).run(
            messages: [LLMMessage(role: .user, content: "把这 20 个文件都读一遍")],
            systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 20_000),
            tools: minisCoreToolContractCatalog(["file_read"]),
            executionIdentity: minisCoreToolContractIdentity("c10-standalone"))

        #expect(result.messages.last?.content == "读完了")
        #expect(provider.callCount == 21)
        #expect(result.messages.filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
        let last = provider.requests[20].filter { $0.role == .tool }
        #expect(last.count == 20)
        #expect(last.prefix(14).allSatisfy { $0.content.count < 1_700 })
        #expect(last.suffix(6).allSatisfy { $0.content.count == 20_000 })
        #expect(provider.requests[5].filter { $0.role == .tool }.allSatisfy { $0.content.count == 20_000 })
    }

    @Test func belowTheTriggerNothingIsReducedAndAdmissionIsInvisible() async throws {
        let root = try minisCoreToolContractRoot("c10-below")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 1_000_000, triggerFraction: 0.8, reduction: reduction))
        let provider = ScriptedWindowProvider(outcomes: [.response(LLMResponse(text: "好", stopReason: nil, usage: nil))])
        let result = try await makeLoop(admission: admission, root: root).run(
            messages: [LLMMessage(role: .user, content: "你好")], systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-below"))
        #expect(result.messages.last?.content == "好")
        #expect(!reduction.isActive)
        #expect(provider.callCount == 1)
    }

    @Test func midTurnGrowthCompactsOnceWhenReductionCannotHelp() async throws {
        let root = try minisCoreToolContractRoot("c10-compact")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        // 60 x 400 chars = 6,000 estimated tokens against a 7,000 window (86%).
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 7_000, triggerFraction: 0.8, reduction: reduction))
        let history = windowTestRepeatedHistory(messages: 59, characters: 400)
            + [LLMMessage(role: .user, content: "继续")]
        let provider = ScriptedWindowProvider(
            outcomes: [.response(LLMResponse(text: "好", stopReason: nil, usage: nil))],
            deliver: { reduction.apply($0) })
        _ = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-compact"))
        #expect(provider.callCount == 1)
        #expect(provider.requests[0].count < history.count)
        #expect(windowTestCharacterCount(provider.requests[0]) * 2 < windowTestCharacterCount(history))
    }

    // R3-05: background, project and scheduled turns must not rewrite their history.
    @Test func aRunThatDisallowsCompactionSendsTheFullHistoryInTheTriggerBand() async throws {
        let root = try minisCoreToolContractRoot("c10-nocompact")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        // About 86% of the 7k window (15 messages of ~400 estimated tokens): inside the 80%-95% band.
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 7_000, triggerFraction: 0.8, reduction: reduction, allowsCompaction: false))
        let history = windowTestRepeatedHistory(messages: 15, characters: 400)
            + [LLMMessage(role: .user, content: "继续")]
        let provider = ScriptedWindowProvider(
            outcomes: [.response(LLMResponse(text: "好", stopReason: nil, usage: nil))],
            deliver: { reduction.apply($0) })
        let result = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-nocompact"))
        #expect(result.messages.last?.content == "好")
        #expect(provider.callCount == 1)
        #expect(provider.requests[0].count == history.count)
        #expect(windowTestCharacterCount(provider.requests[0]) == windowTestCharacterCount(history))
    }

    @Test func firstRequestWithoutAnchorUsesTheLocalEstimate() async throws {
        let root = try minisCoreToolContractRoot("c10-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 7_000, triggerFraction: 0.8, initialAnchor: nil, reduction: reduction))
        let history = windowTestRepeatedHistory(messages: 59, characters: 400)
            + [LLMMessage(role: .user, content: "继续")]
        let provider = ScriptedWindowProvider(outcomes: [])
        _ = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-first"))
        #expect(provider.requests[0].count < history.count)
    }

    @Test func atNinetyFivePercentWithNothingToShrinkNoRequestIsMadeAndTheErrorIsTyped() async throws {
        let root = try minisCoreToolContractRoot("c10-blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        // Distinct, non-repeating plain text: not reducible, not compactable.
        let history = (0..<10).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant,
                       content: String((0..<1_000).map { "w\($0 * 7 + 1)" }.joined(separator: " ").prefix(4_700 + $0)) + "#\($0)")
        }
        let provider = ScriptedWindowProvider(outcomes: [])
        await #expect(throws: AgentLoopError.self) {
            _ = try await makeLoop(admission: admission, root: root).run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                executionIdentity: minisCoreToolContractIdentity("c10-blocked"))
        }
        #expect(provider.callCount == 0)
    }

    @Test func aRefusedCompactionBelowNinetyFivePercentStillSends() async throws {
        let root = try minisCoreToolContractRoot("c10-refused")
        defer { try? FileManager.default.removeItem(at: root) }
        // ~8,500 estimated tokens in a 10,000 window: over the trigger, under 95%.
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        let history = (0..<9).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant,
                       content: String((0..<1_000).map { "v\($0 * 11 + 3)" }.joined(separator: " ").prefix(3_780 + $0)) + "#\($0)")
        }
        let provider = ScriptedWindowProvider(outcomes: [])
        _ = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-refused"))
        #expect(provider.callCount == 1)
        #expect(provider.requests[0] == history)
    }

    // C3-05: a failed summary request (rate limit, timeout, offline) is handled like a refusal.
    @Test func aFailedSummaryRequestBelowNinetyFivePercentStillSends() async throws {
        let root = try minisCoreToolContractRoot("c10-summary-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        let history = (0..<9).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant,
                       content: String((0..<1_000).map { "v\($0 * 11 + 3)" }.joined(separator: " ").prefix(3_780 + $0)) + "#\($0)")
        }
        let provider = ScriptedWindowProvider(outcomes: [])
        var loop = try makeLoop(admission: admission, root: root)
        loop.automaticCompaction = { _, _, _ in throw LLMError.rateLimited }
        _ = try await loop.run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            currentConversationID: "c10-summary-failed",
            executionIdentity: minisCoreToolContractIdentity("c10-summary-failed", sessionID: "c10-summary-failed"))
        #expect(provider.callCount == 1)
        #expect(provider.requests[0] == history)
    }

    @Test func aFailedSummaryRequestAtNinetyFivePercentStillBlocksWithTheTypedError() async throws {
        let root = try minisCoreToolContractRoot("c10-summary-failed-blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        let history = (0..<10).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant,
                       content: String((0..<1_000).map { "w\($0 * 7 + 1)" }.joined(separator: " ").prefix(4_700 + $0)) + "#\($0)")
        }
        let provider = ScriptedWindowProvider(outcomes: [])
        var loop = try makeLoop(admission: admission, root: root)
        loop.automaticCompaction = { _, _, _ in throw LLMError.rateLimited }
        await #expect(throws: AgentLoopError.self) {
            _ = try await loop.run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                currentConversationID: "c10-summary-failed-blocked",
                executionIdentity: minisCoreToolContractIdentity("c10-summary-failed-blocked", sessionID: "c10-summary-failed-blocked"))
        }
        #expect(provider.callCount == 0)
    }

    @Test func aCancelledSummaryRequestStillPropagates() async throws {
        let root = try minisCoreToolContractRoot("c10-summary-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        let history = (0..<9).map {
            LLMMessage(role: $0 % 2 == 0 ? .user : .assistant,
                       content: String((0..<1_000).map { "v\($0 * 11 + 3)" }.joined(separator: " ").prefix(3_780 + $0)) + "#\($0)")
        }
        let provider = ScriptedWindowProvider(outcomes: [])
        var loop = try makeLoop(admission: admission, root: root)
        loop.automaticCompaction = { _, _, _ in throw LLMError.cancelled }
        await #expect(throws: LLMError.self) {
            _ = try await loop.run(
                messages: history, systemPrompt: nil, provider: provider,
                toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
                currentConversationID: "c10-summary-cancelled",
                executionIdentity: minisCoreToolContractIdentity("c10-summary-cancelled", sessionID: "c10-summary-cancelled"))
        }
        #expect(provider.callCount == 0)
    }

    // Judged transcript, 85%: no compaction, reduction still activates, request goes out.
    @Test func anAlreadyJudgedTranscriptSkipsCompactionButStillReducesOldImages() async throws {
        let root = try minisCoreToolContractRoot("c10-judged")
        defer { try? FileManager.default.removeItem(at: root) }
        let reduction = ContextReductionState()
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 7_000, triggerFraction: 0.8, reduction: reduction, compactionAlreadyJudged: true))
        let secretImageBytes = Data(repeating: 0xAB, count: 3_000)
        // 中日韩字符按约 1 个 token 一个字估算：每条 100 字 ≈ 100 token，整体约 85%。
        var history = windowTestRepeatedHistory(messages: 59, characters: 100)
            + [LLMMessage(role: .user, content: "继续")]
        history[0] = LLMMessage(
            role: .user, content: String(repeating: "重复内容", count: 25),
            images: [LLMMessage.ImageAttachment(mimeType: "image/png", data: secretImageBytes)])
        let provider = ScriptedWindowProvider(outcomes: [], deliver: { reduction.apply($0) })
        _ = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-judged"))
        #expect(provider.callCount == 1)
        #expect(provider.requests[0].count == history.count, "no compaction was attempted")
        #expect(reduction.isActive)
        #expect(provider.requests[0].allSatisfy { $0.images.isEmpty })
        #expect(provider.requests[0][0].content.contains("[图片 image/png 3000B 已省略]"))
    }

    // Transcript 200 messages, projection leaves 20, no anchor: estimated on the 20.
    @Test func occupancyIsEstimatedOnTheProjectedMessagesNotTheRawTranscript() async throws {
        let root = try minisCoreToolContractRoot("c10-projected")
        defer { try? FileManager.default.removeItem(at: root) }
        let projection: @Sendable ([LLMMessage]) throws -> [LLMMessage] = { Array($0.suffix(20)) }
        // Raw: 200 x 100 = 20,000 tokens (333% of the window). Projected: 2,000 (33%).
        // 每条 100 个汉字，按中日韩约 1 token 一字估算即 100 token。
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 6_000, triggerFraction: 0.8, deliveryProjection: projection))
        let history = windowTestRepeatedHistory(messages: 199, characters: 100)
            + [LLMMessage(role: .user, content: "继续")]
        let provider = ScriptedWindowProvider(outcomes: [], deliver: { Array($0.suffix(20)) })
        _ = try await makeLoop(admission: admission, root: root).run(
            messages: history, systemPrompt: nil, provider: provider,
            toolExecutor: LargeResultToolExecutor(characters: 1), tools: [],
            executionIdentity: minisCoreToolContractIdentity("c10-projected"))
        #expect(provider.callCount == 1)
        #expect(provider.requests[0].count == 20, "neither compacted nor refused")
        var run = ContextAdmissionRun(config: admission)
        #expect(try run.decide(messages: history, systemPrompt: "") == .proceed)
    }
}

/// C-3：准入给本轮输出留空间（输入 + max_tokens 不能超过窗口的接口）。
struct OutputReserveAdmissionTests {
    // 约 7.6k 估算 token：低于 10k×0.8=8k（无预留时放行），高于 10k-2.5k=7.5k（预留封顶，压缩）。
    private let history = windowTestRepeatedHistory(messages: 19, characters: 400)
        + [LLMMessage(role: .user, content: "继续")]

    @Test func withoutAReserveTheSameInputStillProceeds() throws {
        let admission = try #require(ContextAdmissionConfig(windowTokens: 10_000, triggerFraction: 0.8))
        var run = ContextAdmissionRun(config: admission)
        #expect(try run.decide(messages: history, systemPrompt: "") == .proceed)
    }

    @Test func aReserveShrinksTheInputWindowSoCompactionStartsEarlier() throws {
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 10_000, triggerFraction: 0.8, outputReserveTokens: 2_500))
        #expect(admission.inputWindowTokens == 7_500)
        var run = ContextAdmissionRun(config: admission)
        guard case .compact = try run.decide(messages: history, systemPrompt: "") else {
            Issue.record("expected compact"); return
        }
    }

    @Test func theReserveIsCappedAtAQuarterOfTheWindow() throws {
        let admission = try #require(ContextAdmissionConfig(
            windowTokens: 10_000, triggerFraction: 0.8, outputReserveTokens: 32_000))
        #expect(admission.inputWindowTokens == 7_500)
    }
}
