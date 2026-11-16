import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ordinary source capture worker ownership", .serialized)
@MainActor
struct AutomaticCompactionSourcePreprocessing3116Tests {
    @Test(arguments: [false, true])
    func actualCommittedCompactionFinalizationKeepsOriginalAdoptionBoundary3162(revise: Bool) async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        #expect(chat.applySwitchSession(id: f.sessionID))
        let history = try #require(chat.messages(forSession: f.sessionID)).filter { $0.role != .system }
        let original = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let revision = try #require(chat.transcriptRevision(forSession: f.sessionID))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let policy = chat.composerPolicyFacts
        let provider = Dialogue()
        let gate = ReadGate()
        let observations = WorkObservations()
        let operation = Task { @MainActor in
            try await chat.performCompaction(history: history, keepRecent: 3,
                sessionID: f.sessionID, expectedTranscriptRevision: original.transcriptRevision,
                providerBox: LLMProviderBox(value: provider), frozenEngine: engine,
                authorize: {
                    chat.composerPolicyFacts.revision == policy.revision
                        && chat.composerPolicyFacts.grantEpoch == policy.grantEpoch
                        && chat.composerPolicyFacts.expiresAt > Date()
                }, preflightWorkObserverForTests: { observations.record($0) },
                finalizationPauseForTests: { await gate.hold() })
        }
        let entered = await waitUntil { await gate.didEnter }
        #expect(entered, "actual committed legacy adoption never entered its production read worker")
        guard entered else { operation.cancel(); await gate.release(); _ = try? await operation.value; return }
        do {
            let checkpoint = try #require(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: original.id))
            let committed = try #require(f.settings.sessionStore.loadSession(id: original.id))
            #expect(committed.messages == original.messages)
            #expect(committed.transcriptRevision == checkpoint.resultTranscriptRevision)
            #expect(checkpoint.sourceTranscriptRevision == original.transcriptRevision)
            #expect(chat.transcriptRevision(forSession: f.sessionID) == revision)
            let beforeProviderCount = provider.requests.count
            var expectedCanonical = committed
            var expectedUI = try #require(chat.messages(forSession: f.sessionID))
            if revise {
                let userIndex = try #require(expectedUI.lastIndex { $0.role == .user })
                expectedUI[userIndex].content = "REVISED_AFTER_DURABLE_COMMIT_3162"
                #expect(chat.setMessages(expectedUI, forSession: f.sessionID))
                expectedCanonical = try #require(f.settings.sessionStore.loadSession(id: original.id))
            } else {
                // The original synchronous finalizer did not introduce a new
                // cancellation refusal after checkpoint commit. Adoption changes
                // only the revision; it must never write a new late message.
                operation.cancel()
            }
            await gate.release()
            if revise {
                do { _ = try await operation.value; Issue.record("old committed projection adopted over revised UI") }
                catch {}
                #expect(chat.messages(forSession: f.sessionID) == expectedUI)
                #expect(f.settings.sessionStore.loadSession(id: original.id) == expectedCanonical)
            } else {
                #expect(try await operation.value)
                #expect(chat.messages(forSession: f.sessionID) == expectedUI)
                #expect(chat.transcriptRevision(forSession: f.sessionID) == committed.transcriptRevision)
                #expect(f.settings.sessionStore.loadSession(id: original.id) == committed)
            }
            #expect(observations.reads > 0 && observations.mainThreadWork == 0)
            #expect(provider.requests.count == beforeProviderCount)
            #expect(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: original.id) == checkpoint)
            let reopened = SessionStore(directory: f.profile.sessionDirectory)
            #expect(reopened.loadSession(id: original.id) == expectedCanonical)
            #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: original.id) == checkpoint)
            #expect(engine.toolExecutionFactLedger.facts.isEmpty)
            withExtendedLifetime(f.settings) {}
        } catch {
            operation.cancel()
            await gate.release()
            _ = try? await operation.value
            throw error
        }
    }

    @Test(arguments: [0, 1, 2])
    func actualEngineCompactionPreflightRejectsCancellationOrLatePlaceholderIdentity3150(change: Int) async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        #expect(chat.applySwitchSession(id: f.sessionID))
        let history = try #require(chat.messages(forSession: f.sessionID)).filter { $0.role != .system }
        let bubble = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        #expect(chat.setMessages(history + [bubble], forSession: f.sessionID))
        let source = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let revision = try #require(chat.transcriptRevision(forSession: f.sessionID))
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let policy = chat.composerPolicyFacts
        let provider = Dialogue()
        let gate = ReadGate()
        let observations = WorkObservations()
        let operation = Task { @MainActor in
            try await chat.performCompaction(history: history, keepRecent: 3,
                sessionID: f.sessionID, expectedTranscriptRevision: source.transcriptRevision,
                providerBox: LLMProviderBox(value: provider),
                inFlightAssistantMessageID: bubble.id, expectedInMemoryRevision: revision,
                frozenEngine: engine, canonicalProjectionSource: source,
                authorize: {
                    chat.composerPolicyFacts.revision == policy.revision
                        && chat.composerPolicyFacts.grantEpoch == policy.grantEpoch
                        && chat.composerPolicyFacts.expiresAt > Date()
                }, preflightWorkObserverForTests: { observations.record($0) },
                preflightPauseForTests: { await gate.hold() })
        }
        let entered = await waitUntil { await gate.didEnter }
        #expect(entered, "actual performCompaction did not suspend at its production worker")
        guard entered else { operation.cancel(); await gate.release(); _ = try? await operation.value; return }
        #expect(provider.requests.isEmpty)
        if change == 1 { operation.cancel() }
        if change == 2 {
            var changed = history
            changed.append(ChatMessageUI(role: .assistant, content: "", isStreaming: true))
            #expect(changed.last?.id != bubble.id)
            #expect(chat.setMessages(changed, forSession: f.sessionID))
            #expect(chat.transcriptRevision(forSession: f.sessionID) != revision)
        }
        await gate.release()
        if change == 0 {
            #expect(try await operation.value)
            #expect(observations.projections > 0 && observations.reads >= 2)
            #expect(!provider.summaryRequests.isEmpty && provider.replyRequests.isEmpty)
            let checkpoint = try #require(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: source.id))
            #expect(checkpoint.sourceTranscriptRevision == source.transcriptRevision)
            #expect(checkpoint.replacementHistory.contains { $0.content.contains(Dialogue.summaryMarker) })
            let canonical = try #require(f.settings.sessionStore.loadSession(id: source.id))
            #expect(canonical.messages == source.messages)
            #expect(canonical.transcriptRevision == checkpoint.resultTranscriptRevision)
            #expect(chat.messages(forSession: f.sessionID)?.last?.id == bubble.id)
            #expect(chat.transcriptRevision(forSession: f.sessionID) == canonical.transcriptRevision)
            let reopened = SessionStore(directory: f.profile.sessionDirectory)
            #expect(reopened.loadSession(id: source.id) == canonical)
            #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
        } else {
            do { _ = try await operation.value; Issue.record("cancelled or replaced placeholder crossed preflight") }
            catch {}
            #expect(provider.requests.isEmpty)
            #expect(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
            #expect(observations.reads == 0)
            if change == 1 { #expect(f.settings.sessionStore.loadSession(id: source.id) == source) }
        }
        #expect(observations.mainThreadWork == 0)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        withExtendedLifetime(f.settings) {}
    }

    @Test func actualOrdinaryTurnProjectsAndReadsCanonicalSourceOffMain() async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        await f.configureAutomaticBudget(for: chat)
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(f.settings) {} }
        #expect(chat.applySwitchSession(id: f.sessionID))
        let provider = Dialogue()
        let observations = WorkObservations()
        let adoptionObservations = WorkObservations()
        chat.automaticCompactionSourceObserverForTests = { observations.record($0) }
        chat.automaticCompactionAdoptionObserverForTests = { adoptionObservations.record($0) }
        chat.streamingProviderOverride = provider
        chat.draftText = "NORMAL_SOURCE_CAPTURE_3116"
        chat.submitComposer()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && !provider.requests.isEmpty }
        #expect(ended)
        #expect(observations.projections > 0 && observations.reads > 0,
            "the actual ChatStore → AgentLoop boundary never called the production worker")
        #expect(observations.mainThreadWork == 0,
            "projection or canonical Store load ran on the main thread")
        #expect(adoptionObservations.reads >= 2 && adoptionObservations.projections > 0,
            "actual adoption must independently read canonical session and checkpoint before its projection")
        #expect(adoptionObservations.mainThreadWork == 0)
        #expect(!provider.summaryRequests.isEmpty)
        #expect(provider.replyRequests.count == 1)
        let sent = try #require(provider.replyRequests.first)
        #expect(provider.summaryRequests.allSatisfy {
            $0.count == 1 && $0[0].role == .user
                && !$0[0].content.contains("NORMAL_SOURCE_CAPTURE_3116")
        })
        #expect(provider.summaryRequests.contains {
            $0.contains { $0.content.contains("coefficient 31") }
        }, "the actual summary request must read the original historical assistant text")
        #expect(sent.filter { $0.content == "NORMAL_SOURCE_CAPTURE_3116" }.count == 1)
        #expect(sent.contains { $0.content.contains("coefficient 31") })
        #expect(!sent.contains { $0.role == .assistant && $0.content.isEmpty })
        let canonical = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let ui = try #require(chat.messages(forSession: f.sessionID)?.filter { $0.role != .system })
        #expect(canonical.messages == ui.map { $0.asLLMMessage() })
        #expect(canonical.messages.filter { $0.content == "CURRENT_REPLY_3116" }.count == 1)
        let checkpoint = try #require(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: canonical.id))
        #expect(checkpoint.replacementHistory.contains { $0.content.contains(Dialogue.summaryMarker) })
        let reopened = SessionStore(directory: f.profile.sessionDirectory)
        #expect(reopened.loadSession(id: canonical.id) == canonical)
        #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: canonical.id) == checkpoint)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test(arguments: [false, true])
    func heldActualSourceCannotResumeCancelledOrRevisedTurnAndNextSendSucceeds(revise: Bool) async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        await f.configureAutomaticBudget(for: chat)
        let gate = ReadGate()
        let observations = WorkObservations()
        let oldProvider = Dialogue()
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(f.settings) {} }
        #expect(chat.applySwitchSession(id: f.sessionID))
        chat.automaticCompactionSourceObserverForTests = { observations.record($0) }
        chat.automaticCompactionSourcePauseForTests = { await gate.hold() }
        chat.streamingProviderOverride = oldProvider
        chat.draftText = "OLD_FROZEN_SOURCE_3116"
        chat.submitComposer()
        let entered = await waitUntil { await gate.didEnter }
        #expect(entered, "the actual Store read boundary was not held")
        guard entered else { await gate.release(); return }
        #expect(oldProvider.requests.isEmpty)
        let identity = try #require(chat.lastComposerSubmissionSnapshot)
        let oldTask = try #require(chat.turnTaskForTests(sessionID: f.sessionID))
        let oldRevision = try #require(chat.transcriptRevision(forSession: f.sessionID))
        if revise {
            var changed = try #require(chat.messages(forSession: f.sessionID))
            let user = try #require(changed.lastIndex { $0.role == .user })
            changed[user].content = "REVISED_SOURCE_3116"
            #expect(chat.setMessages(changed, forSession: f.sessionID))
            #expect(chat.transcriptRevision(forSession: f.sessionID) != oldRevision)
        } else {
            chat.stopStreaming()
            #expect(!chat.isActiveSessionStreaming)
        }
        await gate.release()
        await oldTask.value
        let oldEnded = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(oldEnded)
        #expect(oldProvider.requests.isEmpty,
            "cancelled or revised source crossed the original Provider boundary")
        #expect(oldProvider.replyRequests.isEmpty)
        #expect(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString) == nil)
        #expect(observations.mainThreadWork == 0)
        if !revise { #expect(observations.reads == 0, "cancelled worker read canonical bytes after release") }
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        chat.automaticCompactionSourcePauseForTests = nil
        let requiresReopen = chat.isCanonicalWriteIsolated(f.sessionID)
        if revise {
            // A rejected pre-read snapshot has not committed a checkpoint.
            // It need not isolate the UI, but cannot revive its old identity.
            #expect(chat.lastComposerSubmissionSnapshot == identity)
            let revised = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
            #expect(revised.messages.contains { $0.role == .user && $0.content == "REVISED_SOURCE_3116" })
            #expect(!revised.messages.contains { $0.role == .user && $0.content == "OLD_FROZEN_SOURCE_3116" })
        }
        if requiresReopen {
            let rejectedProvider = Dialogue()
            chat.streamingProviderOverride = rejectedProvider
            let beforeUI = chat.messages(forSession: f.sessionID)
            let beforeCanonical = f.settings.sessionStore.loadSession(id: f.sessionID.uuidString)
            chat.draftText = "BLOCKED_WHILE_ISOLATED_3133"
            chat.submitComposer()
            #expect(chat.isCanonicalWriteIsolated(f.sessionID))
            #expect(chat.lastComposerSubmissionSnapshot == identity)
            #expect(!chat.hasStreamingTasksForSafety)
            #expect(rejectedProvider.requests.isEmpty && rejectedProvider.replyRequests.isEmpty)
            #expect(chat.messages(forSession: f.sessionID) == beforeUI)
            #expect(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString) == beforeCanonical)
        }
        // Re-entry is the ordinary new Store/Bridge assembly over the exact
        // owned canonical root. Never clear isolation on the retired instance.
        let reopenedFixture = (requiresReopen || revise) ? try Fixture(reopening: f) : nil
        if let reopenedFixture { await reopenedFixture.attach() }
        let nextChat = reopenedFixture?.bridge.chat ?? chat
        let nextSettings = reopenedFixture?.settings ?? f.settings
        defer { nextChat.stopAllStreamingForSafety(); withExtendedLifetime(reopenedFixture) {} }
        #expect(nextChat.applySwitchSession(id: f.sessionID))
        #expect(!nextChat.isCanonicalWriteIsolated(f.sessionID))
        if requiresReopen { #expect(chat.isCanonicalWriteIsolated(f.sessionID)) }
        await f.configureAutomaticBudget(for: nextChat)
        let nextProvider = Dialogue()
        nextChat.streamingProviderOverride = nextProvider
        nextChat.draftText = "NEXT_CURRENT_SOURCE_3116"
        nextChat.submitComposer()
        let next = try #require(nextChat.lastComposerSubmissionSnapshot)
        #expect(next.sessionID == identity.sessionID)
        // TurnController numbers are instance-local and restart from zero.
        // The new durable task/message identity must never reuse the old one.
        if reopenedFixture == nil { #expect(next.turnID != identity.turnID) }
        #expect(next.taskID != identity.taskID)
        #expect(next.messageID != identity.messageID)
        #expect(next != identity, "next send must capture its own original identity")
        let nextEnded = await waitUntil { !nextChat.hasStreamingTasksForSafety && !nextProvider.requests.isEmpty }
        let nextExecution = nextChat.executionSnapshot(forSessionID: f.sessionID)
        let nextTerminal = nextExecution?.executionIdentity.flatMap { nextChat.terminalReceipt(for: $0)?.outcome.rawValue }
        let nextBubble = nextChat.messages(forSession: f.sessionID)?.last
        let snapshotConflict = nextExecution?.failureReason == ChatStore.userErrorMessage(
            SessionStoreError.sessionSnapshotConflict(f.sessionID.uuidString))
        let invalidCheckpoint = nextExecution?.failureReason == ChatStore.userErrorMessage(
            SessionStoreError.invalidCompactionCheckpoint(f.sessionID.uuidString))
        #expect(nextEnded, Comment(rawValue:
            "next-state streaming=\(nextChat.hasStreamingTasksForSafety) active=\(nextChat.activeExecutionIdentity(for: f.sessionID) != nil) state=\(nextExecution?.state.rawValue ?? "none") kind=\(nextExecution?.failureKind?.rawValue ?? "none") terminal=\(nextTerminal ?? "none") snapshotConflict=\(snapshotConflict) invalidCheckpoint=\(invalidCheckpoint) isolated=\(nextChat.isCanonicalWriteIsolated(f.sessionID)) pause=\(nextChat.automaticCompactionSourcePauseForTests != nil) projections=\(observations.projections) reads=\(observations.reads) main=\(observations.mainThreadWork) bubbleStreaming=\(nextBubble?.isStreaming == true) bubbleInterrupted=\(nextBubble?.wasInterrupted == true) phases=\(nextBubble?.turnTiming?.phaseTimings.map { $0.phase.rawValue }.joined(separator: ",") ?? "none")"))
        #expect(!nextProvider.summaryRequests.isEmpty)
        #expect(nextProvider.replyRequests.count == 1)
        #expect(oldProvider.requests.isEmpty)
        #expect(oldProvider.replyRequests.isEmpty)
        let sent = try #require(nextProvider.replyRequests.first)
        #expect(sent.filter { $0.content == "NEXT_CURRENT_SOURCE_3116" }.count == 1)
        #expect(!sent.contains { $0.role == .assistant && $0.content.isEmpty })
        let canonical = try #require(nextSettings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let ui = try #require(nextChat.messages(forSession: f.sessionID)?.filter { $0.role != .system })
        #expect(canonical.messages == ui.map { $0.asLLMMessage() })
        #expect(canonical.messages.filter { $0.content == "CURRENT_REPLY_3116" }.count == 1)
        let checkpoint = try #require(try nextSettings.sessionStore.loadLatestCompactionCheckpoint(sessionID: canonical.id))
        #expect(checkpoint.replacementHistory.contains { $0.content.contains(Dialogue.summaryMarker) })
        #expect(nextProvider.summaryRequests.allSatisfy {
            !$0.contains { $0.content.contains("NEXT_CURRENT_SOURCE_3116") }
        }, "the assistant-only summarizer must not consume the current user instruction")
        if revise {
            #expect(sent.contains { $0.content.contains("REVISED_SOURCE_3116") })
            #expect(!sent.contains { $0.content.contains("OLD_FROZEN_SOURCE_3116") })
            #expect(checkpoint.replacementHistory.contains { $0.content.contains("REVISED_SOURCE_3116") })
            #expect(!checkpoint.replacementHistory.contains { $0.content.contains("OLD_FROZEN_SOURCE_3116") })
        }
        let reopened = SessionStore(directory: f.profile.sessionDirectory)
        #expect(reopened.loadSession(id: canonical.id) == canonical)
        #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: canonical.id) == checkpoint)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
        let nextEngine = try #require(nextChat.agentEngine as? AgentLoopChatEngine)
        #expect(nextEngine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test(arguments: [false, true])
    func actualHighBudgetReadbackRunsOffMainAndHeldCancellationCannotReachProvider(cancel: Bool) async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        let provider = Dialogue()
        let observations = WorkObservations()
        let gate = ReadGate()
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(f.settings) {} }
        #expect(chat.applySwitchSession(id: f.sessionID))
        // The default cumulative cap is 1,000,000 since C1: the 0.8 budget fraction is built on
        // an explicit 100_000 cap. The compaction trigger is the window occupancy (C1).
        var cappedAgent = f.settings.settings.agent
        cappedAgent.maxTokensPerSession = 100_000
        chat.configureBudget(from: cappedAgent)
        let tracker = chat.budgetTracker
        await tracker.record(requestTokens: 80_000)
        chat.requestBudget = await tracker.budget
        #expect(chat.requestBudget.usageFraction == 0.8)
        let sourceSession = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        chat.recordWindowOccupancy(sessionID: f.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: sourceSession.messages.count)
        chat.automaticCompactionHighBudgetObserverForTests = { observations.record($0) }
        if cancel { chat.automaticCompactionHighBudgetPauseForTests = { await gate.hold() } }
        chat.compactionProviderOverride = provider
        chat.streamingProviderOverride = provider
        chat.draftText = "HIGH_BUDGET_CURRENT_3134"
        chat.submitComposer()
        let submitted = try #require(chat.lastComposerSubmissionSnapshot)
        if cancel {
            let entered = await waitUntil { await gate.didEnter }
            #expect(entered, "the actual authoritative high-budget worker was not entered")
            guard entered else { await gate.release(); return }
            let task = try #require(chat.turnTaskForTests(sessionID: f.sessionID))
            #expect(provider.requests.isEmpty)
            chat.stopStreaming()
            await gate.release()
            await task.value
            #expect(!chat.hasStreamingTasksForSafety)
            #expect(chat.lastComposerSubmissionSnapshot == submitted)
            #expect(provider.requests.isEmpty && provider.replyRequests.isEmpty)
            #expect(observations.reads == 0 && observations.projections == 0)
            #expect(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString) == nil)
        } else {
            let ended = await waitUntil { !chat.hasStreamingTasksForSafety && !provider.replyRequests.isEmpty }
            #expect(ended)
            #expect(observations.reads >= 2 && observations.projections >= 2,
                "both the actual preflight and committed readback must use the worker")
            #expect(provider.replyRequests.count == 1)
            let sent = try #require(provider.replyRequests.first)
            #expect(sent.filter { $0.content == "HIGH_BUDGET_CURRENT_3134" }.count == 1)
            #expect(!sent.contains { $0.role == .assistant && $0.content.isEmpty })
            let checkpoint = try #require(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString))
            let reopened = SessionStore(directory: f.profile.sessionDirectory)
            #expect(try reopened.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString) == checkpoint)
        }
        #expect(observations.mainThreadWork == 0)
        let canonical = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        #expect(canonical.messages.filter { $0.content == "HIGH_BUDGET_CURRENT_3134" }.count == 1)
        #expect(canonical.messages.filter { $0.content == "CURRENT_REPLY_3116" }.count == (cancel ? 0 : 1))
        let reopened = SessionStore(directory: f.profile.sessionDirectory)
        #expect(reopened.loadSession(id: canonical.id) == canonical)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test(arguments: [false, true])
    func heldActualAdoptionRejectsCancellationOrRevisedUI(revise: Bool) async throws {
        let f = try Fixture()
        await f.attach()
        let chat = f.bridge.chat
        await f.configureAutomaticBudget(for: chat)
        let gate = ReadGate()
        let provider = Dialogue()
        let observations = WorkObservations()
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(f.settings) {} }
        #expect(chat.applySwitchSession(id: f.sessionID))
        chat.automaticCompactionAdoptionPauseForTests = { await gate.hold() }
        chat.automaticCompactionAdoptionObserverForTests = { observations.record($0) }
        chat.streamingProviderOverride = provider
        chat.draftText = "ADOPT_CURRENT_3134"
        chat.submitComposer()
        let originalAssistantID = try #require(chat.messages(forSession: f.sessionID)?.last?.id)
        let entered = await waitUntil { await gate.didEnter }
        #expect(entered, "actual Engine commit must reach the adoption worker")
        guard entered else { await gate.release(); return }
        let oldTask = try #require(chat.turnTaskForTests(sessionID: f.sessionID))
        let identity = try #require(chat.lastComposerSubmissionSnapshot)
        let checkpoint = try #require(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString))
        let committed = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        #expect(committed.transcriptRevision == checkpoint.resultTranscriptRevision)
        let beforeAdoption = try #require(chat.messages(forSession: f.sessionID))
        let beforeProjection = beforeAdoption.filter { $0.role != .system }
        #expect(committed.messages == beforeProjection.dropLast().map { $0.asLLMMessage() },
            "this fixture persists the closed prefix while the original UI placeholder remains live")
        #expect(committed.messages.count + 1 == beforeProjection.count)
        #expect(beforeProjection.last?.id == originalAssistantID)
        #expect(beforeProjection.last?.role == .assistant && beforeProjection.last?.isStreaming == true)
        #expect(observations.reads == 0 && observations.projections == 0,
            "the held adoption worker must not have read or projected the UI")
        #expect(!beforeAdoption.contains { $0.content == "CURRENT_REPLY_3116" })
        #expect(!provider.summaryRequests.isEmpty && provider.replyRequests.count == 1,
            "post-reply adoption follows the first completed ordinary request")
        let requestsBeforeRetirement = provider.requests.count
        let firstRequest = try #require(provider.replyRequests.first)
        #expect(firstRequest.filter { $0.role == .user && $0.content == "ADOPT_CURRENT_3134" }.count == 1)
        if revise {
            var changed = try #require(chat.messages(forSession: f.sessionID))
            let user = try #require(changed.lastIndex { $0.role == .user })
            changed[user].content = "ADOPT_REVISED_3134"
            #expect(chat.setMessages(changed, forSession: f.sessionID))
        } else {
            chat.stopStreaming()
            #expect(!chat.isActiveSessionStreaming)
        }
        let canonicalAtRetirement = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        let uiAtRetirement = chat.messages(forSession: f.sessionID)
        let revisionAtRetirement = chat.transcriptRevision(forSession: f.sessionID)
        await gate.release()
        await oldTask.value
        #expect(await waitUntil { !chat.hasStreamingTasksForSafety })
        #expect(chat.lastComposerSubmissionSnapshot == identity)
        #expect(provider.replyRequests.count == 1,
            "retirement must not enter another ordinary request")
        #expect(provider.requests.count == requestsBeforeRetirement,
            "cancellation or revision must not enter any additional Provider call")
        if revise { #expect(chat.isCanonicalWriteIsolated(f.sessionID)) }
        #expect(observations.mainThreadWork == 0)
        if !revise {
            #expect(observations.reads == 0)
            #expect(chat.messages(forSession: f.sessionID) == uiAtRetirement)
            #expect(chat.transcriptRevision(forSession: f.sessionID) == revisionAtRetirement)
            #expect(try f.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: f.sessionID.uuidString) == checkpoint)
        }
        let canonical = try #require(f.settings.sessionStore.loadSession(id: f.sessionID.uuidString))
        #expect(canonical == canonicalAtRetirement,
            "the late adoption cannot write over the actual retirement snapshot")
        #expect(!canonical.messages.contains { $0.content == "CURRENT_REPLY_3116" })
        #expect(!(chat.messages(forSession: f.sessionID) ?? []).contains { $0.content == "CURRENT_REPLY_3116" })
        if revise {
            #expect(canonical.messages.contains { $0.role == .user && $0.content == "ADOPT_REVISED_3134" })
            #expect((chat.messages(forSession: f.sessionID) ?? []).contains {
                $0.role == .user && $0.content == "ADOPT_REVISED_3134"
            })
        }
        #expect(SessionStore(directory: f.profile.sessionDirectory).loadSession(id: canonical.id) == canonical)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.toolExecutionFactLedger.facts.isEmpty)
    }

    private func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private actor ReadGate {
        private(set) var didEnter = false
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func hold() async {
            didEnter = true
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { waiter = continuation }
            }
        }
        func release() {
            released = true
            let pending = waiter
            waiter = nil
            pending?.resume()
        }
    }

    private final class WorkObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var projectionCount = 0
        private var readCount = 0
        private var mainCount = 0
        var projections: Int { lock.withLock { projectionCount } }
        var reads: Int { lock.withLock { readCount } }
        var mainThreadWork: Int { lock.withLock { mainCount } }
        func record(_ stage: AutomaticCompactionSourcePreprocessor.Stage) {
            lock.withLock {
                switch stage {
                case .projection: projectionCount += 1
                case .canonicalRead: readCount += 1
                }
                if Thread.isMainThread { mainCount += 1 }
            }
        }
    }

    @MainActor private final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let bridge: BridgeStore
        let sessionID: UUID

        init(reopening previous: Fixture? = nil) throws {
            sessionID = previous?.sessionID ?? UUID()
            if let previous { profile = previous.profile }
            else {
                profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Compaction3116",
                    processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
            }
            let defaults = profile.makeUserDefaults()
            let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            var history: [LLMMessage] = []
            for option in 0..<18 {
                history.append(LLMMessage(role: .user, content: "Compare distinct option \(option), dependency \(option + 7)."))
                history.append(LLMMessage(role: .assistant, content: (0..<24).map { detail in
                    "Option \(option), consideration \(detail): cost \(option + detail + 2), dependency \(option * 7 - detail), coefficient \(option * 31 + detail) and fallback \(detail % 5) have distinct tradeoffs."
                }.joined(separator: " ")))
            }
            if previous == nil {
                try sessions.updateSession(ChatSession(id: sessionID.uuidString, title: "owned compaction3116", messages: history))
            } else {
                _ = try #require(sessions.loadSession(id: sessionID.uuidString),
                    "the legal reopened assembly must consume the original canonical session")
            }
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            let accepted = readiness.upsert([ProviderReadinessPersistenceRecord(
                providerID: Dialogue.providerID, modelID: Dialogue.modelID, status: .passed, readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "readiness3116", isApplied: true,
                discoveryReceiptID: "discovery3116", discoveredAt: Date(timeIntervalSince1970: 1_000),
                applyReceiptID: "provider-readiness-apply:3116", appliedAt: Date(timeIntervalSince1970: 1_001))])
            guard accepted else { throw CocoaError(.fileWriteUnknown) }
            let shortcuts = ShortcutStore(defaults: defaults)
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: readiness)
            bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks3116.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest3116.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center3116.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        }
        /// The real AgentLoop budget branch is reached after a completed
        /// ordinary request. History size alone never enables that policy.
        func configureAutomaticBudget(for chat: ChatStore) async {
            let budget = RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: .autoCompact)
            chat.requestBudget = budget
            await chat.budgetTracker.replace(with: budget)
            #expect(await chat.budgetTracker.budget == budget)
        }
        func attach() async {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled, externalRunners: [:],
                externalNetworkAllowed: true, sessionReadSecretStore: settings.envStore).value
        }
    }

    private final class Dialogue: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
        static let providerID = "dialogue3116"
        static let modelID = "dialogue-model3116"
        static let summaryMarker = "HISTORICAL_ASSISTANT_SUMMARY_3133"
        private static let summaryRequestPrefix = "请把下面这段较早的对话压缩成一份摘要，供后续对话继续使用。"
        private struct CapturedRequest {
            let messages: [LLMMessage]
            let isSummary: Bool
        }
        let name = Dialogue.providerID
        var model = LLMModel(id: Dialogue.modelID, displayName: "Owned dialogue", provider: Dialogue.providerID)
        var runtimeConfigurationMaterial: String? = "owned-runtime3116"
        let capabilities: Set<ProviderCapability> = [.tools]
        private let lock = NSLock()
        private var captured: [CapturedRequest] = []
        var requests: [[LLMMessage]] { lock.withLock { captured.map(\.messages) } }
        var summaryRequests: [[LLMMessage]] { lock.withLock { captured.filter(\.isSummary).map(\.messages) } }
        var replyRequests: [[LLMMessage]] { lock.withLock { captured.filter { !$0.isSummary }.map(\.messages) } }
        private func respond(_ messages: [LLMMessage], maxTokens: Int, temperature: Double?) -> LLMResponse {
            let isSummary = messages.count == 1 && messages[0].role == .user
                && messages[0].content.hasPrefix(Self.summaryRequestPrefix)
                && messages[0].content.contains("===== 对话记录 =====")
                && messages[0].content.hasSuffix("===== 记录结束 =====")
                && maxTokens == 4_096 && temperature == 0.2
            lock.withLock { captured.append(CapturedRequest(messages: messages, isSummary: isSummary)) }
            let text = isSummary
                ? "\(Self.summaryMarker): historical coefficient 31, commitments and tradeoffs are background only."
                : "CURRENT_REPLY_3116"
            return LLMResponse(text: text, stopReason: "stop", usage: nil)
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            respond(messages, maxTokens: maxTokens, temperature: temperature)
        }
        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            respond(messages, maxTokens: maxTokens, temperature: temperature)
        }
        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            throw LLMError.unsupportedCapability(.streaming)
        }
    }
}
