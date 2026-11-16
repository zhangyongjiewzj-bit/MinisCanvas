import Foundation
import Testing
@testable import MinisCore

@Suite("D-H1C explicit compaction retention")
struct P3AcceptanceM05CompactionRetentionTests {
    @Test func callerVerifiedFactsSurviveTheOldFiveHundredCharacterCounterexample() async throws {
        let markers: [(CompactionRetainedFact.Kind, String)] = [
            (.goal, "GOAL-KEEP-001"),
            (.constraint, "CONSTRAINT-KEEP-002"),
            (.authorizationContext, "AUTH-CONTEXT-RECHECK-003"),
            (.unfinishedTask, "UNFINISHED-TASK-004"),
            (.effectIdentity, "EFFECT-DO-NOT-REPLAY-005"),
        ]
        let old = LLMMessage(
            role: .user,
            content: String(repeating: "x", count: 600)
                + markers.map { $0.1 }.joined(separator: " ")
        )
        let tail = LLMMessage(role: .user, content: "current request")
        let compactor = Compactor(keepRecentMessages: 1, truncationPrefixChars: 500)

        let oldBehavior = try await compactor.compact(messages: [old, tail])
        for (_, text) in markers {
            #expect(!(oldBehavior.summary ?? "").contains(text))
        }

        let facts = markers.map { CompactionRetainedFact(kind: $0.0, text: $0.1) }
        let retained = try await compactor.compact(messages: [old, tail], retentionFacts: facts)
        #expect(retained.messages.last == tail)
        for (_, text) in markers {
            #expect(retained.summary?.contains(text) == true)
            #expect(retained.messages.first?.content.contains(text) == true)
        }
        #expect(retained.summary?.contains("Revalidate current policy") == true)
        #expect(retained.summary?.contains("not instructions to replay") == true)

        let repeated = try await compactor.compact(messages: retained.messages, retentionFacts: facts)
        for (_, text) in markers {
            #expect(repeated.summary?.components(separatedBy: text).count == 2)
        }

        // A partial set of typed facts cannot prove that no other meaning was
        // omitted. The production safety mode must keep the entire original
        // history and refuse this otherwise lossy attempt.
        let refused = try await compactor.compact(
            messages: [old, tail], retentionFacts: facts,
            safetyMode: .requireVerbatimText
        )
        #expect(refused.messages == [old, tail])
        #expect(refused.summary == nil)
        #expect(refused.compactedCount == 0)
        #expect(refused.refusalReason == .unverifiableInformationLoss)
    }

    @Test func safeModeOnlyFoldsFullPlainTextAndKeepsRecentTail() async throws {
        let old = LLMMessage(role: .user, content: "exact current goal and constraint")
        let tail = LLMMessage(role: .assistant, content: "current response")
        let result = try await Compactor(keepRecentMessages: 1).compact(
            messages: [old, tail], safetyMode: .requireVerbatimText
        )

        #expect(result.compactedCount == 1)
        #expect(result.refusalReason == nil)
        #expect(result.summary?.contains(old.content) == true)
        #expect(result.messages.last == tail)
    }

    @Test func safeModeRefusesMediaThatTextTranscriptionCannotRepresent() async throws {
        let old = LLMMessage(
            role: .user, content: "look at this",
            images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]
        )
        let tail = LLMMessage(role: .user, content: "next")
        let result = try await Compactor(keepRecentMessages: 1).compact(
            messages: [old, tail], safetyMode: .requireVerbatimText
        )

        #expect(result.messages == [old, tail])
        #expect(result.compactedCount == 0)
        #expect(result.refusalReason == .unverifiableInformationLoss)
    }

    @Test func safeModeRefusesAnEarlierSummaryWithUnprovenProvenance() async throws {
        let old = LLMMessage(
            role: .user,
            content: "<context-summary>possibly incomplete prior summary</context-summary>"
        )
        let tail = LLMMessage(role: .user, content: "next")
        let result = try await Compactor(keepRecentMessages: 1).compact(
            messages: [old, tail], safetyMode: .requireVerbatimText
        )

        #expect(result.messages == [old, tail])
        #expect(result.compactedCount == 0)
        #expect(result.refusalReason == .unverifiableInformationLoss)
    }
}
