import Foundation
import Testing
@testable import MinisCore

struct CompactionSourceSpanTests {
    private final class AssistantSummaryProvider: LLMProvider, @unchecked Sendable {
        let name = "assistant-summary-test"
        var model = LLMModel(id: "assistant-summary-test", displayName: "Test", provider: "tests")
        var requests: [[LLMMessage]] = []
        var tokenLimits: [Int] = []
        private let responseText: String
        init(responseText: String = "The assistant compared draft options.") {
            self.responseText = responseText
        }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            requests.append(messages)
            tokenLimits.append(maxTokens)
            return LLMResponse(text: responseText,
                stopReason: nil, usage: nil)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?,
                           maxTokens: Int, temperature: Double?) async throws
            -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test("source-anchored producer receives its actual retained-content budget", arguments: [0, 1, 2])
    func summaryRequestBudgetIsConsumedWithoutBypassingRetention(mode: Int) async throws {
        let explanation = String(repeating:
            "A blue windmill turns beside three willows and an eastward river. ", count: mode == 2 ? 24 : 7)
        let source: [LLMMessage] = [
            .init(role: .user, content: "Read-only authorization: keep the title and do not write."),
            .init(role: .assistant, content: explanation),
            .init(role: .user, content: "Continue this story."),
        ]
        let short = "A blue windmill turns beside three willows."
        let provider = AssistantSummaryProvider(responseText: mode == 1 ? explanation : short)
        var facts = [CompactionRetainedFact(kind: .authorizationContext,
            text: source[0].content)]
        let factDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-budget-facts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: factDirectory) }
        if mode == 2 {
            try FileManager.default.createDirectory(at: factDirectory, withIntermediateDirectories: true)
            let ledger = try ToolExecutionFactLedger(persistenceURL: factDirectory.appendingPathComponent("facts.json"))
            let identity = AgentExecutionIdentity(turn: .init(sessionID: "budget-source", turnID: 1,
                messageID: "original-message"), operationID: "original-operation", attempt: 1)
            let receipt = try ledger.mint(toolCallID: "original-call", toolName: "file_read",
                attemptID: "original-attempt", attemptNumber: 1, executionIdentity: identity)
            _ = try ledger.settle(receipt, status: .succeeded)
            facts += CompactionFactCapture.capture(sessionID: "budget-source", revision: 1,
                messages: source, taskStore: nil, effectLedger: ledger)
            #expect(facts.contains { $0.source != nil })
        }
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: source,
            summarizeUsing: provider, retentionFacts: facts, safetyMode: .sourceAnchoredNatural)
        #expect(provider.requests.count == 1 && provider.tokenLimits.count == 1)
        let request = try #require(provider.requests.first?.first?.content)
        let limitLine = try #require(request.split(separator: "\n").first {
            $0.hasPrefix("Maximum assistant summary length: ")
        })
        let budget = try #require(Int(limitLine.dropFirst("Maximum assistant summary length: ".count)
            .prefix { $0.isNumber }))
        #expect(budget >= short.count && budget < explanation.count)
        #expect(provider.tokenLimits[0] == 1024)
        if mode == 1 {
            // A producer ignoring the request is not silently truncated/retried.
            #expect(result.refusalReason == .unverifiableInformationLoss)
            #expect(result.messages == source && result.compactedCount == 0)
        } else {
            #expect(result.refusalReason == nil)
            #expect(result.messages.last == source.last && result.compactedCount == 2)
            #expect(result.messages.first?.content.contains(String(reflecting: source[0].content)) == true)
            #expect(result.messages.first?.content.contains(short) == true)
            #expect(result.retentionFacts == facts)
            if mode == 2 {
                let background = try #require(CompactionFactCapture.backgroundMessage(facts))
                #expect(result.messages.contains(background))
            }
        }
    }

    @Test func impossibleRetainedContentBudgetDoesNotCallSummaryProvider() async throws {
        let source: [LLMMessage] = [
            .init(role: .user, content: String(repeating: "Keep every exact user statement. ", count: 16)),
            .init(role: .assistant, content: "Agreed."),
            .init(role: .user, content: "Continue."),
        ]
        let provider = AssistantSummaryProvider()
        let result = try await Compactor(keepRecentMessages: 1).compact(messages: source,
            summarizeUsing: provider, safetyMode: .sourceAnchoredNatural)
        #expect(provider.requests.isEmpty)
        #expect(result.messages == source)
        #expect(result.refusalReason == .unverifiableInformationLoss)
    }

    @Test func ordinaryTurnsOnBothSidesOfToolExchangeStayEligible() {
        let call = LLMToolCall(id: "call-1", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let history: [LLMMessage] = [
            .init(role: .user, content: "Goal: finish the design within the approved scope."),
            .init(role: .assistant, content: "I will compare the options first."),
            .init(role: .assistant, content: "Reading source", toolCalls: [call]),
            .init(role: .assistant, content: "Waiting for the read to settle."),
            .init(role: .tool, content: "receipt: read completed", toolCallID: "call-1"),
            .init(role: .user, content: "Keep the existing constraint."),
            .init(role: .assistant, content: "Here is the revised explanation."),
            .init(role: .user, content: "Continue with the next step."),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<2),
            .init(kind: .exact, range: 2..<5),
            .init(kind: .naturalText, range: 5..<7),
        ])
    }

    @Test func mediaAndUnprovenSummaryStayExactWithoutFreezingFollowingText() {
        let history: [LLMMessage] = [
            .init(role: .user, content: "First ordinary question."),
            .init(role: .user, content: "Inspect image", images: [
                .init(mimeType: "image/png", data: Data([1, 2, 3]))
            ]),
            .init(role: .user, content: "<context-summary>old projection</context-summary>"),
            .init(role: .assistant, content: "Distinct later explanation."),
            .init(role: .user, content: "Current request."),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<1),
            .init(kind: .exact, range: 1..<3),
            .init(kind: .naturalText, range: 3..<4),
        ])
    }

    @Test func toolCallCrossingRecentTailRemainsExact() {
        let call = LLMToolCall(id: "late-call", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let history: [LLMMessage] = [
            .init(role: .user, content: "Earlier goal and constraints."),
            .init(role: .assistant, content: "Earlier ordinary explanation."),
            .init(role: .assistant, content: "Calling tool", toolCalls: [call]),
            .init(role: .assistant, content: "Intervening progress text."),
            .init(role: .tool, content: "Settled receipt", toolCallID: "late-call"),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<2),
            .init(kind: .exact, range: 2..<4),
        ])
    }

    @Test func legacyTextToolEnvelopeStaysExactAcrossInterveningProse() {
        let use = #"{"type":"tool_use","id":"legacy-1","name":"read_file","input":{}}"#
        let result = #"{"type":"tool_result","tool_use_id":"legacy-1","content":"settled"}"#
        let history: [LLMMessage] = [
            .init(role: .user, content: "Earlier ordinary goal."),
            .init(role: .assistant, content: "Earlier ordinary answer."),
            .init(role: .assistant, content: use),
            .init(role: .assistant, content: "Waiting for legacy result."),
            .init(role: .user, content: result),
            .init(role: .user, content: "Later ordinary request."),
            .init(role: .assistant, content: "Later ordinary answer."),
            .init(role: .user, content: "Current tail."),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<2),
            .init(kind: .exact, range: 2..<5),
            .init(kind: .naturalText, range: 5..<7),
        ])
    }

    @Test func legacyTextToolUseWithResultInRecentTailIsNotSummarized() {
        let use = #"{"type":"tool_use","id":"legacy-2","name":"read_file","input":{}}"#
        let result = #"{"type":"tool_result","tool_use_id":"legacy-2","content":"settled"}"#
        let history: [LLMMessage] = [
            .init(role: .user, content: "Earlier ordinary goal."),
            .init(role: .assistant, content: "Earlier ordinary answer."),
            .init(role: .assistant, content: use),
            .init(role: .assistant, content: "Waiting for legacy result."),
            .init(role: .user, content: result),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<2),
            .init(kind: .exact, range: 2..<4),
        ])
    }

    @Test func repeatedToolIdentityDoesNotLetLaterTextCrossAmbiguousEffect() {
        let first = LLMToolCall(id: "same-id", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let second = LLMToolCall(id: "same-id", name: "write_file",
            rawArguments: "{}", arguments: [:])
        let history: [LLMMessage] = [
            .init(role: .user, content: "Earlier natural goal."),
            .init(role: .assistant, content: "First call", toolCalls: [first]),
            .init(role: .tool, content: "First result", toolCallID: "same-id"),
            .init(role: .assistant, content: "Second call", toolCalls: [second]),
            .init(role: .tool, content: "Second result", toolCallID: "same-id"),
            .init(role: .user, content: "Later text after ambiguous identity."),
            .init(role: .user, content: "Current tail."),
        ]

        #expect(Compactor.sourceSpans(messages: history, keepRecentMessages: 1) == [
            .init(kind: .naturalText, range: 0..<1),
            .init(kind: .exact, range: 1..<6),
        ])
    }

    @Test func sourceAnchoredCandidatePreservesUserWordsAndExactToolReceipt() throws {
        let verboseOne = String(repeating: "The first explanation has distinct details about the draft. ", count: 12)
        let verboseTwo = String(repeating: "The later explanation weighs a different option. ", count: 12)
        let call = LLMToolCall(id: "read-7", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let source: [LLMMessage] = [
            .init(role: .user, content: "Goal: revise the draft. Constraint: keep the title."),
            .init(role: .assistant, content: verboseOne),
            .init(role: .assistant, content: "Read receipt", toolCalls: [call]),
            .init(role: .tool, content: "effect read-7 already settled", toolCallID: "read-7"),
            .init(role: .user, content: "Authorization was read-only. Unfinished: compare option B."),
            .init(role: .assistant, content: verboseTwo),
            .init(role: .user, content: "Please continue now."),
        ]
        let first = try #require(Compactor.sourceAnchoredSummary(
            from: source, range: 0..<2, assistantSummary: "Draft options were outlined."))
        let second = try #require(Compactor.sourceAnchoredSummary(
            from: source, range: 4..<6, assistantSummary: "Option B was compared."))
        let projection = [first, source[2], source[3], second, source[6]]
        let spans: [CompactionProjectionSpan] = [
            .init(source: .init(kind: .naturalText, range: 0..<2), projectedRange: 0..<1),
            .init(source: .init(kind: .exact, range: 2..<4), projectedRange: 1..<3),
            .init(source: .init(kind: .naturalText, range: 4..<6), projectedRange: 3..<4),
        ]
        let facts = [
            CompactionRetainedFact(kind: .goal, text: "Goal: revise the draft."),
            CompactionRetainedFact(kind: .constraint, text: "Constraint: keep the title."),
            CompactionRetainedFact(kind: .authorizationContext, text: "Authorization was read-only."),
            CompactionRetainedFact(kind: .unfinishedTask, text: "Unfinished: compare option B."),
        ]
        #expect(Compactor.isSourceAnchoredProjection(from: source, to: projection,
            spans: spans, keepRecentMessages: 1, requiredFacts: facts))
        var lostUserTurn = projection
        lostUserTurn[0] = .init(role: .user,
            content: first.content.replacingOccurrences(of: "keep the title", with: "change the title"))
        #expect(!Compactor.isSourceAnchoredProjection(from: source, to: lostUserTurn,
            spans: spans, keepRecentMessages: 1, requiredFacts: facts))
        var rewrittenReceipt = projection
        rewrittenReceipt[2] = .init(role: .tool, content: "replayed effect", toolCallID: "read-7")
        #expect(!Compactor.isSourceAnchoredProjection(from: source, to: rewrittenReceipt,
            spans: spans, keepRecentMessages: 1, requiredFacts: facts))
    }

    @Test func naturalDifferentTurnsProduceReducedSegmentedCandidate() async throws {
        let provider = AssistantSummaryProvider()
        let firstExplanation = String(repeating:
            "The draft introduction explains an independent design choice. ", count: 16)
        let secondExplanation = String(repeating:
            "The alternative outline has separate reasoning and examples. ", count: 16)
        let call = LLMToolCall(id: "read-8", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let source: [LLMMessage] = [
            .init(role: .user, content: "Goal: revise chapter one. Keep the approved ending."),
            .init(role: .assistant, content: firstExplanation),
            .init(role: .assistant, content: "Reading receipt", toolCalls: [call]),
            .init(role: .tool, content: "read-8 settled; no write performed", toolCallID: "read-8"),
            .init(role: .user, content: "Read-only authorization. Still need to compare option B."),
            .init(role: .assistant, content: secondExplanation),
            .init(role: .user, content: "Continue this same conversation."),
        ]
        let facts = [
            CompactionRetainedFact(kind: .goal, text: "Goal: revise chapter one."),
            CompactionRetainedFact(kind: .constraint, text: "Keep the approved ending."),
            CompactionRetainedFact(kind: .authorizationContext, text: "Read-only authorization."),
            CompactionRetainedFact(kind: .unfinishedTask, text: "Still need to compare option B."),
            CompactionRetainedFact(kind: .effectIdentity, text: "read-8 settled"),
        ]
        let result = try await Compactor(keepRecentMessages: 1).compact(
            messages: source, summarizeUsing: provider, retentionFacts: facts,
            safetyMode: .sourceAnchoredNatural)

        #expect(result.refusalReason == nil)
        #expect(result.compactedCount == 6)
        #expect(result.messages.count == 5)
        #expect(result.messages[1] == source[2])
        #expect(result.messages[2] == source[3])
        #expect(result.messages.last == source.last)
        #expect(result.projectionSpans?.count == 3)
        #expect(provider.requests.count == 2)
        #expect(Compactor.isSourceAnchoredProjection(from: source,
            to: result.messages, spans: result.projectionSpans ?? [],
            keepRecentMessages: 1, requiredFacts: facts))
    }

    @Test func segmentedCheckpointResumesExactToolGroupAndLaterTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmented-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let id = "segmented-session"
        _ = try store.createSession(id: id)
        let call = LLMToolCall(id: "read-9", name: "read_file",
            rawArguments: "{}", arguments: [:])
        let source: [LLMMessage] = [
            .init(role: .user, content: "Goal: write a concise answer."),
            .init(role: .assistant, content: String(repeating:
                "First answer explains a distinct part of the problem. ", count: 18)),
            .init(role: .assistant, content: "Reading", toolCalls: [call]),
            .init(role: .tool, content: "read-9 settled", toolCallID: "read-9"),
            .init(role: .user, content: "Constraint: keep the evidence. The next task is open."),
            .init(role: .assistant, content: String(repeating:
                "Second answer discusses a separate design choice. ", count: 18)),
            .init(role: .user, content: "Continue now."),
        ]
        for message in source { try store.saveMessage(message, sessionID: id) }
        let canonical = try #require(store.loadSession(id: id))
        let facts = [
            CompactionRetainedFact(kind: .goal, text: "Goal: write a concise answer."),
            CompactionRetainedFact(kind: .unfinishedTask, text: "The next task is open."),
            CompactionRetainedFact(kind: .effectIdentity, text: "read-9 settled")
        ]
        let candidate = try await Compactor(keepRecentMessages: 1).compact(
            messages: canonical.messages, summarizeUsing: AssistantSummaryProvider(),
            retentionFacts: facts, safetyMode: .sourceAnchoredNatural)
        #expect(candidate.refusalReason == nil)
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: id, sourceTranscriptRevision: canonical.transcriptRevision,
            sourceMessages: canonical.messages, result: candidate,
            lineage: canonical.lineageIdentity)
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion)
        #expect(candidate.retentionFacts == facts)
        #expect(checkpoint.retentionFacts == facts)
        let encoded = try JSONEncoder().encode(checkpoint)
        #expect(try JSONDecoder().decode(CompactionCheckpoint.self, from: encoded) == checkpoint)
        var altered = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        altered["retentionFacts"] = [["kind": "effectIdentity", "text": "nonexistent-effect"]]
        let tampered = try JSONDecoder().decode(CompactionCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: altered))
        #expect(!tampered.hasValidDigest)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(checkpoint.checkpointID)) {
            try store.saveCompactionCheckpoint(tampered.withDigest())
        }
        altered.removeValue(forKey: "retentionFacts")
        let missing = try JSONDecoder().decode(CompactionCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: altered))
        #expect(!missing.withDigest().hasValidDigest)
        try store.saveCompactionCheckpoint(checkpoint)
        #expect(store.loadSession(id: id)?.messages == source)
        let next = LLMMessage(role: .user, content: "Another current request.")
        try store.saveMessage(next, sessionID: id)
        let reopened = SessionStore(directory: root)
        #expect(try reopened.resumeMessages(sessionID: id) == candidate.messages + [next])
        #expect(reopened.loadSession(id: id)?.messages == source + [next])
    }
}
