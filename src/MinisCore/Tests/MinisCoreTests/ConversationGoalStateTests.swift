import Foundation
import Testing
@testable import MinisCore

struct ConversationGoalStateTests {
    @Test(arguments: [ConversationGoalState.ReviewRecord.Outcome.invalidResponse, .unavailable, .timedOut, .cancelled, .rejected])
    func reviewFailureNeedsAttentionWhenContinuationIsOff(outcome: ConversationGoalState.ReviewRecord.Outcome) throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review draft"))
        let disabled = goal.setAutoContinue(false)
        try #require(disabled)
        let pending = goal.reportCompletion(evidence: ["Draft reviewed"])
        let id = try #require(pending)
        let settled = goal.recordReview(id: id, result: .init(outcome: outcome))
        try #require(settled)
        #expect(goal.reviewNeedsAttention)
    }

    @Test func rejectionWithContinuationEnabledNeedsNoAttention() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review draft"))
        try #require(goal.autoContinueEnabled)
        let pending = goal.reportCompletion(evidence: ["Draft reviewed"])
        let id = try #require(pending)
        let settled = goal.recordReview(id: id, result: .init(outcome: .rejected))
        try #require(settled)
        #expect(!goal.reviewNeedsAttention)
    }

    @Test func laterGoalTurnClearsReviewAttention() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review draft"))
        let pending = goal.reportCompletion(evidence: ["Draft reviewed"])
        let id = try #require(pending)
        let settled = goal.recordReview(id: id, result: .init(outcome: .unavailable))
        try #require(settled)
        try #require(goal.reviewNeedsAttention)
        let advanced = goal.recordTurn(durationSeconds: 1, reportedTokens: nil, outcome: .completed)
        try #require(advanced)
        #expect(!goal.reviewNeedsAttention)
    }

    @Test func rejectedGoalReviewPersistsItsVerdictReasonAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let sessionID = UUID()
        _ = try store.createSession(id: sessionID.uuidString)
        let goal = try store.startConversationGoal(sessionID: sessionID, objective: "Review the draft")
        let pending = try store.recordConversationGoalReport(
            sessionID: sessionID, goalID: goal.id, report: .completion(evidence: ["Draft reviewed"])
        )
        let reviewID = try #require(pending.reviewID)
        let verdictRecord = Data("""
        {"outcome":"rejected","reason":"The second section has no supporting evidence."}
        """.utf8)
        let result = try JSONDecoder().decode(ConversationGoalState.ReviewRecord.self, from: verdictRecord)
        let settled = try store.recordConversationGoalReview(
            expected: pending, reviewID: reviewID, result: result
        )
        let reopened = SessionStore(directory: directory)
        let review = try #require(reopened.loadSession(id: sessionID.uuidString)?.goal?.lastReview)
        #expect(review.outcome == .rejected)
        #expect(settled.evidence.isEmpty)
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as? [String: Any])
        #expect(fields["reason"] as? String == "The second section has no supporting evidence.")
    }

    @Test func goalReviewReasonDecodesAsOptionalBoundedRejectedText() throws {
        let legacy = try JSONDecoder().decode(ConversationGoalState.ReviewRecord.self,
            from: Data(#"{"outcome":"rejected","provider":"Synthetic"}"#.utf8))
        #expect(legacy.outcome == .rejected)
        #expect(legacy.provider == "Synthetic")
        #expect(legacy.reason == nil)
        let passed = try JSONDecoder().decode(ConversationGoalState.ReviewRecord.self,
            from: Data(#"{"outcome":"passed","reason":"Only rejected reviews carry reasons"}"#.utf8))
        #expect(passed.reason == nil)

        let reason = "See https://example.invalid/proof " + String(repeating: "x", count: 320)
        let rejected = ConversationGoalState.ReviewRecord(outcome: .rejected, reason: reason)
        let stored = try #require(rejected.reason)
        #expect(stored.count == 300)
        #expect(stored.hasPrefix("See <remote-url> "))
        #expect(!stored.contains("example.invalid"))
    }

    @Test func reportedReviewTokensSaturateWithoutAddingATurn() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let configured = goal.setBudgetLimits(turns: 30, tokens: 12, durationSeconds: nil)
        #expect(configured)
        let pending = goal.reportCompletion(evidence: ["Draft checked"])
        let id = try #require(pending)
        let settled = goal.recordReview(id: id, result: .init(outcome: .rejected),
                                        usage: .init(inputTokens: Int.max, outputTokens: 1))
        #expect(settled)
        #expect(goal.budget.usedTokens == Int.max)
        #expect(goal.budget.usedTurns == 0)
        #expect(goal.status == .paused)
    }

    @Test func onlyExactPendingGoalReviewCanCompleteCanonicalSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let sessionID = UUID()
        _ = try store.createSession(id: sessionID.uuidString)
        let goal = try store.startConversationGoal(sessionID: sessionID, objective: "Review the draft")
        let first = try store.recordConversationGoalReport(
            sessionID: sessionID, goalID: goal.id, report: .completion(evidence: ["First draft reviewed"])
        )
        let firstID = try #require(first.reviewID)
        let failure = ConversationGoalState.ReviewRecord(outcome: .timedOut, provider: "Synthetic",
                                                          modelID: "unsafe/path")
        let retriable = try store.recordConversationGoalReview(expected: first, reviewID: firstID, result: failure)
        #expect(retriable.status == .active)
        #expect(retriable.lastReview?.outcome == .timedOut)
        #expect(retriable.lastReview?.provider == "Synthetic")
        #expect(retriable.lastReview?.modelID == nil)
        #expect(retriable.consecutiveRetryableFailures == 1)
        #expect(retriable.budget.usedTurns == 0)
        #expect(retriable.budget.usedTokens == 0)
        #expect(throws: SessionStore.ConversationGoalError.invalidTransition) {
            try store.recordConversationGoalReview(expected: first, reviewID: firstID, result: failure)
        }
        #expect(SessionStore(directory: directory).loadSession(id: sessionID.uuidString)?.goal == retriable)
        let current = try store.recordConversationGoalReport(
            sessionID: sessionID, goalID: goal.id, report: .completion(evidence: ["Revised draft reviewed"])
        )
        let currentID = try #require(current.reviewID)
        #expect(throws: SessionStore.ConversationGoalError.invalidTransition) {
            try store.recordConversationGoalReview(expected: first, reviewID: firstID, accepted: true)
        }
        #expect(throws: SessionStore.ConversationGoalError.invalidTransition) {
            try store.recordConversationGoalReview(expected: current, reviewID: firstID, accepted: true)
        }
        let completed = try store.recordConversationGoalReview(expected: current, reviewID: currentID, accepted: true)
        #expect(completed.status == .completed)
        #expect(SessionStore(directory: directory).loadSession(id: sessionID.uuidString)?.goal == completed)
    }

    @Test func foreignGoalOnDiskDoesNotHideOwnedTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let owner = UUID()
        var session = try store.createSession(id: owner.uuidString)
        session.messages = [LLMMessage(role: .user, content: "Keep this transcript")]
        try store.updateSession(session)
        let file = store.sessionsDirectory.appendingPathComponent(owner.uuidString + ".json")
        try #require(FileManager.default.fileExists(atPath: file.path))
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let foreign = try #require(ConversationGoalState(sessionID: UUID(), objective: "Another draft"))
        try #require(foreign.sessionID != owner)
        document["goal"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreign))
        try JSONSerialization.data(withJSONObject: document).write(to: file)

        let reopened = SessionStore(directory: directory)
        let restored = try #require(reopened.loadSession(id: owner.uuidString), "Foreign goal must not hide its host session")
        #expect(restored.messages == session.messages)
        #expect(restored.goal == nil)
    }

    @Test func normalSessionStoreRetainsOwnedGoalAcrossReopenWithoutCopyingToAnotherSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let owner = UUID()
        let other = UUID()
        let original = try store.createSession(id: owner.uuidString)
        _ = try store.createSession(id: other.uuidString)
        let goal = try #require(ConversationGoalState(sessionID: owner, objective: "Review the draft"))
        let encoded = try JSONEncoder().encode(original)
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document["goal"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(goal))
        let withGoal = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: document))
        try store.updateSession(withGoal)
        let reopened = SessionStore(directory: directory)
        for id in [owner, other] {
            let session = try #require(reopened.loadSession(id: id.uuidString))
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
            if id == owner {
                let value = try #require(saved["goal"], "The normal session document must retain its owned goal")
                #expect(try ConversationGoalState.reopen(JSONSerialization.data(withJSONObject: value), for: id) == goal)
            } else {
                #expect(saved["goal"] == nil)
            }
        }
    }

    @Test func completionRequiresEvidenceAndMatchingReviewAfterReopen() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let result34 = goal.reportCompletion(evidence: [" "])
        #expect(result34 == nil)
        let reportedReview = goal.reportCompletion(evidence: ["Reviewed both sections"])
        let review = try #require(reportedReview)
        let saved = try JSONEncoder().encode(goal)
        var reopened = try ConversationGoalState.reopen(saved, for: goal.sessionID)
        #expect(reopened == goal)
        #expect(throws: ConversationGoalState.RestoreError.foreignSession) {
            try ConversationGoalState.reopen(saved, for: UUID())
        }
        var invalid = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        invalid.removeValue(forKey: "reviewID")
        let malformed = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: DecodingError.self) {
            try ConversationGoalState.reopen(malformed, for: goal.sessionID)
        }
        let result48 = reopened.recordReview(id: UUID(), accepted: true)
        #expect(!result48)
        #expect(reopened.status == .awaitingReview)
        let result50 = reopened.recordReview(id: review, accepted: false)
        #expect(result50)
        let reportedNewreview = reopened.reportCompletion(evidence: ["Reviewed corrected draft"])
        let newReview = try #require(reportedNewreview)
        let result52 = reopened.recordReview(id: review, accepted: true)
        #expect(!result52)
        let result53 = reopened.recordReview(id: newReview, accepted: true)
        #expect(result53)
        #expect(reopened.status == .completed)
    }

    @Test func blockedReportRequiresReasonAndDoesNotCompleteGoal() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Compare the two drafts"))
        let result59 = goal.reportBlocked(reason: " ")
        #expect(!result59)
        let result60 = goal.reportBlocked(reason: "Waiting for the second draft")
        #expect(result60)
        #expect(goal.status == .blocked)
        let result62 = goal.reportCompletion(evidence: ["First draft reviewed"])
        #expect(result62 == nil)
    }

    @Test(arguments: [
        ConversationGoalState.BudgetDimension.turns, .tokens, .duration
    ])
    func measuredTurnPausesAtEachBudgetCeiling(dimension: ConversationGoalState.BudgetDimension) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let owner = UUID()
        _ = try store.createSession(id: owner.uuidString)
        let active = try store.startConversationGoal(sessionID: owner, objective: "Review the draft")
        #expect(active.budget.turnLimit == 30)
        _ = try store.setConversationGoalBudget(sessionID: owner, goalID: active.id,
            turns: dimension == .turns ? 1 : 30, tokens: dimension == .tokens ? 20 : nil,
            durationSeconds: dimension == .duration ? 4 : nil)
        #expect(throws: SessionStore.ConversationGoalError.unavailable) {
            try store.recordConversationGoalTurn(sessionID: owner, goalID: UUID(), durationSeconds: 4,
                reportedTokens: 20, outcome: .completed)
        }

        let paused = try store.recordConversationGoalTurn(sessionID: owner, goalID: active.id,
            durationSeconds: 4, reportedTokens: 20, outcome: .completed)
        #expect(paused.status == .paused)
        #expect(paused.budgetPauseReason == dimension)
        #expect(paused.budget.usedTurns == 1)
        #expect(paused.budget.usedTokens == 20)
        #expect(paused.budget.usedDurationSeconds == 4)
        #expect(store.loadSession(id: owner.uuidString)?.goal == paused)
        #expect(throws: SessionStore.ConversationGoalError.invalidTransition) {
            try store.controlConversationGoal(sessionID: owner, goalID: active.id, action: .resume)
        }
        _ = try store.setConversationGoalBudget(sessionID: owner, goalID: active.id,
            turns: 30, tokens: 40, durationSeconds: 8)
        let resumed = try store.controlConversationGoal(sessionID: owner, goalID: active.id, action: .resume)
        #expect(resumed.status == .active)
        #expect(resumed.budget.usedTokens == 20)
    }

    @Test func retryableFailuresMustBeConsecutiveToBlock() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let firstFailure = goal.recordTurn(durationSeconds: 1, reportedTokens: nil, outcome: .retryableNetwork)
        #expect(firstFailure)
        #expect(goal.consecutiveRetryableFailures == 1)
        let success = goal.recordTurn(durationSeconds: 1, reportedTokens: 10, outcome: .completed)
        #expect(success)
        #expect(goal.consecutiveRetryableFailures == 0)
        for failure in [ConversationGoalState.TurnOutcome.retryableNetwork, .retryableRateLimit] {
            let recorded = goal.recordTurn(durationSeconds: 1, reportedTokens: nil, outcome: failure)
            #expect(recorded)
            #expect(goal.status == .active)
        }
        let thirdFailure = goal.recordTurn(durationSeconds: 1, reportedTokens: nil, outcome: .retryableRateLimit)
        #expect(thirdFailure)
        #expect(goal.status == .blocked)
        #expect(goal.consecutiveRetryableFailures == 3)
        #expect(goal.budget.usedTokens == 10)
        #expect(goal.blockedReason == "连续三次回合失败，最近一次为限流")
    }

    @Test func nonRetryableFailureBlocksImmediatelyAndLegacyBudgetDefaults() throws {
        let original = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let data = try JSONEncoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "budget")
        legacy.removeValue(forKey: "consecutiveRetryableFailures")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        var goal = try ConversationGoalState.reopen(legacyData, for: original.sessionID)
        #expect(goal == original)
        let invalid = goal.recordTurn(durationSeconds: .infinity, reportedTokens: 100, outcome: .nonRetryable)
        #expect(!invalid)
        #expect(goal == original)
        let recorded = goal.recordTurn(durationSeconds: 7, reportedTokens: nil, outcome: .nonRetryable)
        #expect(recorded)
        #expect(goal.status == .blocked)
        #expect(goal.blockedReason == "目标回合遇到不可重试错误")
        #expect(goal.budget.usedTokens == 0)
    }

    @Test func goalTracksLocalBlockersWithoutBlockingUntilAllRemainingWorkIsBlocked() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the drafts"))
        let blocker = try #require(ConversationGoalBlocker(summary: "Review the second draft",
            reason: "The second draft is missing", options: ["Upload": "Attach the second draft"],
            userAction: "Attach the second draft"))
        let premature = goal.reportBlocked(reason: "Waiting for drafts", allRemainingWorkBlocked: true)
        #expect(!premature)
        let recorded = goal.recordBlocker(blocker)
        let duplicate = goal.recordBlocker(blocker)
        #expect(recorded && duplicate)
        #expect(goal.blockers == [blocker])
        #expect(goal.status == .active)
        let blocked = goal.reportBlocked(reason: "Waiting for the second draft", allRemainingWorkBlocked: true)
        #expect(blocked)
        #expect(goal.allRemainingWorkBlocked)
        let serialized = try JSONEncoder().encode(goal)
        var restored = try ConversationGoalState.reopen(serialized, for: goal.sessionID)
        #expect(restored == goal)
        let resumed = restored.resume()
        #expect(resumed)
        #expect(!restored.allRemainingWorkBlocked)
        #expect(restored.blockers == [blocker])
        var malformed = try #require(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
        let encodedBlocker = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blocker))
        malformed["blockers"] = ["invalid", encodedBlocker]
        let data = try JSONSerialization.data(withJSONObject: malformed)
        let recovered = try ConversationGoalState.reopen(data, for: goal.sessionID)
        #expect(recovered == goal)
    }

    // B2-21：用户确认已处理后可清除待办与提醒；没有待办或已结束的目标不能清。
    @Test func clearingBlockersRemovesThemAndTheirReminder() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the drafts"))
        let firstClear = goal.clearBlockers()
        #expect(!firstClear)
        let blocker = try #require(ConversationGoalBlocker(summary: "Review the second draft",
            reason: "The second draft is missing", options: ["Upload": "Attach the second draft"],
            userAction: "Attach the second draft"))
        let recorded = goal.recordBlocker(blocker)
        #expect(recorded)
        #expect(goal.reminderDueAt != nil)
        let cleared = goal.clearBlockers()
        #expect(cleared)
        #expect(goal.blockers.isEmpty)
        #expect(goal.reminderDueAt == nil)
        #expect(goal.status == .active)
        let clearedAgain = goal.clearBlockers()
        #expect(!clearedAgain)
        let restored = try ConversationGoalState.reopen(JSONEncoder().encode(goal), for: goal.sessionID)
        #expect(restored.blockers.isEmpty)
    }

    @Test func goalReminderBackoffSurvivesRestartAndResetsOnlyForItsOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let owner = UUID()
        let other = UUID()
        _ = try store.createSession(id: owner.uuidString)
        _ = try store.createSession(id: other.uuidString)
        let goal = try store.startConversationGoal(sessionID: owner, objective: "Review the drafts")
        let unrelated = try store.startConversationGoal(sessionID: other, objective: "Review other drafts")
        let blocker = try #require(ConversationGoalBlocker(summary: "Review the second draft",
            reason: "The second draft is missing", options: ["Upload": "Attach the second draft"],
            userAction: "Attach the second draft"))
        let start = Date(timeIntervalSince1970: 100_000)
        let first = start.addingTimeInterval(30 * 60)
        let second = first.addingTimeInterval(60 * 60)
        let third = second.addingTimeInterval(2 * 60 * 60)
        let recorded = try store.recordConversationGoalReport(sessionID: owner, goalID: goal.id,
            report: .blocker(blocker), now: start)
        #expect(recorded.reminderDueAt == start)
        #expect(recorded.hasUnacknowledgedBlockerReminder)
        let reopened = SessionStore(directory: directory)
        #expect(reopened.loadSession(id: owner.uuidString)?.goal?.reminderDueAt == start)
        let immediate = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: goal.id,
            expectedDueAt: start, now: start)
        #expect(immediate.reminderDueAt == first)
        #expect(immediate.hasUnacknowledgedBlockerReminder)
        let duplicate = try reopened.recordConversationGoalReport(sessionID: owner, goalID: goal.id,
            report: .blocker(blocker), now: start.addingTimeInterval(1))
        #expect(duplicate == immediate)
        #expect(throws: SessionStore.ConversationGoalError.self) {
            _ = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: goal.id,
                expectedDueAt: first, now: first.addingTimeInterval(-1))
        }
        let afterFirst = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: goal.id,
            expectedDueAt: first, now: first)
        #expect(afterFirst.reminderDueAt == second)
        #expect(afterFirst.hasUnacknowledgedBlockerReminder)
        #expect(SessionStore(directory: directory).loadSession(id: owner.uuidString)?
            .goal?.hasUnacknowledgedBlockerReminder == true)
        let afterSecond = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: goal.id,
            expectedDueAt: second, now: second)
        #expect(afterSecond.reminderDueAt == third)
        #expect(throws: SessionStore.ConversationGoalError.self) {
            _ = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: unrelated.id,
                now: second)
        }
        #expect(reopened.loadSession(id: other.uuidString)?.goal?.reminderDueAt == nil)
        let reset = try reopened.updateConversationGoalReminder(sessionID: owner, goalID: goal.id,
            now: second)
        #expect(reset.reminderDueAt == second.addingTimeInterval(30 * 60))
        #expect(reset.blockers == [blocker])
        #expect(!reset.hasUnacknowledgedBlockerReminder)
        let nextBlocker = try #require(ConversationGoalBlocker(summary: "Review the final draft",
            reason: "The final draft is missing", options: ["Upload": "Attach the final draft"],
            userAction: "Attach the final draft"))
        let nextRecordedAt = second.addingTimeInterval(1)
        let next = try reopened.recordConversationGoalReport(sessionID: owner, goalID: goal.id,
            report: .blocker(nextBlocker), now: nextRecordedAt)
        #expect(next.reminderDueAt == nextRecordedAt)
        #expect(next.hasUnacknowledgedBlockerReminder)
        #expect(next.blockers == [blocker, nextBlocker])
    }

    @Test func malformedBudgetPausesAndRetainsGoal() throws {
        let goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(goal)) as? [String: Any])
        document["budget"] = ["turnLimit": 0]
        document["consecutiveRetryableFailures"] = 92
        document["budgetPauseReason"] = "duration"
        let data = try JSONSerialization.data(withJSONObject: document)
        let recovered = try ConversationGoalState.reopen(data, for: goal.sessionID)
        #expect(recovered.id == goal.id)
        #expect(recovered.objective == goal.objective)
        #expect(recovered.status == .paused)
        #expect(recovered.budget == goal.budget)
        #expect(recovered.consecutiveRetryableFailures == 3)
        #expect(recovered.budgetPauseReason == nil)
        #expect(recovered.budgetRecoveryReason == "预算记录异常，已重置")
    }

    @Test func ownedInterruptedTurnChargesUsageAndClearsItsPendingReview() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let limitsSet = goal.setBudgetLimits(turns: 2, tokens: 10, durationSeconds: nil)
        #expect(limitsSet)
        let requestedReview = goal.reportCompletion(evidence: ["Draft evidence"])
        let reviewID = try #require(requestedReview)
        let recorded = goal.recordInterruptedTurn(durationSeconds: 1.5, reportedTokens: 10, outcome: .retryableNetwork)
        #expect(recorded)
        #expect(goal.status == .paused)
        #expect(goal.budgetPauseReason == .tokens)
        #expect(goal.budget.usedTokens == 10)
        #expect(goal.budget.usedTurns == 1)
        #expect(goal.budget.usedDurationSeconds == 1.5)
        #expect(goal.reviewID == nil)
        #expect(goal.evidence.isEmpty)
        let staleReviewAccepted = goal.recordReview(id: reviewID, accepted: true)
        #expect(!staleReviewAccepted)
    }

    @Test func pendingReviewAcceptsSuccessfulUsageButRejectsFailureSettlement() throws {
        var goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        let limitsSet = goal.setBudgetLimits(turns: 1, tokens: nil, durationSeconds: nil)
        #expect(limitsSet)
        let requestedReview = goal.reportCompletion(evidence: ["Reviewed the draft"])
        let reviewID = try #require(requestedReview)
        let awaiting = goal
        for outcome in [ConversationGoalState.TurnOutcome.retryableNetwork, .retryableRateLimit, .nonRetryable] {
            let recorded = goal.recordTurn(durationSeconds: 1, reportedTokens: 10, outcome: outcome)
            #expect(!recorded)
            #expect(goal == awaiting)
        }
        let recorded = goal.recordTurn(durationSeconds: 1, reportedTokens: 10, outcome: .completed)
        #expect(recorded)
        #expect(goal.status == .awaitingReview)
        #expect(goal.reviewID == reviewID)
        #expect(goal.budget.usedTokens == 10)
        let reviewed = goal.recordReview(id: reviewID, accepted: false)
        #expect(reviewed)
        #expect(goal.status == .paused)
        #expect(goal.budgetPauseReason == .turns)
    }

    @Test func autoContinueDefaultsOnAndLegacyRecordsDecodeAsOn() throws {
        let goal = try #require(ConversationGoalState(sessionID: UUID(), objective: "Review the draft"))
        #expect(goal.autoContinueEnabled)
        #expect(goal.allowsAutoContinuation)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(goal)) as? [String: Any])
        legacy.removeValue(forKey: "autoContinueEnabled")
        let restored = try ConversationGoalState.reopen(JSONSerialization.data(withJSONObject: legacy), for: goal.sessionID)
        #expect(restored.autoContinueEnabled)
        #expect(restored == goal)
    }

    @Test func autoContinueSwitchPersistsAndOnlyActiveGoalWithBudgetMayContinue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let sessionID = UUID()
        _ = try store.createSession(id: sessionID.uuidString)
        let goal = try store.startConversationGoal(sessionID: sessionID, objective: "Review the draft")
        let off = try store.setConversationGoalAutoContinue(sessionID: sessionID, goalID: goal.id, enabled: false)
        #expect(!off.autoContinueEnabled && !off.allowsAutoContinuation && off.status == .active)
        let reopened = SessionStore(directory: directory)
        #expect(reopened.loadSession(id: sessionID.uuidString)?.goal?.autoContinueEnabled == false)
        #expect(throws: SessionStore.ConversationGoalError.self) {
            try store.setConversationGoalAutoContinue(sessionID: sessionID, goalID: goal.id, enabled: false)
        }
        let on = try store.setConversationGoalAutoContinue(sessionID: sessionID, goalID: goal.id, enabled: true)
        #expect(on.allowsAutoContinuation)

        var reviewing = on
        _ = reviewing.reportCompletion(evidence: ["Draft checked"])
        #expect(reviewing.status == .awaitingReview && !reviewing.allowsAutoContinuation)
        var paused = on
        _ = paused.pause()
        #expect(!paused.allowsAutoContinuation)
        var exhausted = on
        _ = exhausted.setBudgetLimits(turns: 1, tokens: nil, durationSeconds: nil)
        _ = exhausted.recordTurn(durationSeconds: 1, reportedTokens: nil, outcome: .completed)
        #expect(exhausted.budgetPauseReason == .turns && !exhausted.allowsAutoContinuation)
        let stopped = try store.controlConversationGoal(sessionID: sessionID, goalID: goal.id, action: .stop)
        #expect(!stopped.allowsAutoContinuation)
        #expect(throws: SessionStore.ConversationGoalError.self) {
            try store.setConversationGoalAutoContinue(sessionID: sessionID, goalID: goal.id, enabled: false)
        }
    }

    @Test func emptyTurnPauseReasonSurvivesReopenAndClearsOnResume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let sessionID = UUID()
        _ = try store.createSession(id: sessionID.uuidString)
        let goal = try store.startConversationGoal(sessionID: sessionID, objective: "Review the draft")
        let paused = try store.pauseConversationGoalForInterruptedTurn(expected: goal, reason: .emptyTurn)
        #expect(paused.status == .paused && paused.turnPauseReason == .emptyTurn)
        let saved = try #require(SessionStore(directory: directory).loadSession(id: sessionID.uuidString)?.goal)
        #expect(saved.turnPauseReason == .emptyTurn)
        let resumed = try store.controlConversationGoal(sessionID: sessionID, goalID: goal.id, action: .resume)
        #expect(resumed.turnPauseReason == nil && resumed.allowsAutoContinuation)
    }

    @Test func onlyPlanModeCannotDriveAGoal() {
        #expect(ComposerTaskMode.allCases.filter { !$0.supportsConversationGoal } == [.plan])
    }
}
