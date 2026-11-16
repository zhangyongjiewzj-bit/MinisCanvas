import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
private final class ScheduledMemory1747Fixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let sessions: SessionStore
    let chat: ChatStore
    let scheduler: SchedulerTaskStore
    let settings: SettingsCenter
    let targetID = UUID()
    let projectID = "scheduled-memory-1747"
    let command = "/memory.propose synthetic scheduled memory"
    var now = Date(timeIntervalSince1970: 1_756_650_000)
    var taskID: UUID!
    var runtime: SchedulerTaskRuntime!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-memory-1747-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        suite = "scheduled-memory-1747-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory-root"))
        settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: memory, sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        )
        chat = ChatStore(preferencesDefaults: defaults,
                         logManager: LogManager(directory: root.appendingPathComponent("chat-logs")))
        scheduler = SchedulerTaskStore(defaults: defaults,
                                       occurrenceLedgerURL: root.appendingPathComponent("occurrences.json"))
        let memoryScope = MemoryScope(sessionID: targetID.uuidString, projectID: projectID)
        settings.memoryScopeProvider = { memoryScope }
        _ = try sessions.createSession(id: targetID.uuidString, title: "synthetic target", projectID: projectID)
        try sessions.saveMessage(LLMMessage(role: .user, content: "synthetic source"),
                                 sessionID: targetID.uuidString)
        #expect(chat.attachPersistence(sessions))
        let policy = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "scheduled-memory-policy",
            grantEpoch: "scheduled-memory-epoch", leaseID: "scheduled-memory-lease",
            expiresAt: now.addingTimeInterval(3600), autonomyCeiling: .l1
        )
        chat.configureComposerPolicy(policy)
        #expect(scheduler.add(name: "synthetic memory task", cronExpression: "* * * * *",
                              command: command, targetSessionID: targetID,
                              targetProjectID: projectID, targetTurnID: 1) == nil)
        taskID = try #require(scheduler.allTasks().first?.id)
        var preview = try #require(scheduler.preview(taskID: taskID, now: now))
        let anchor = try #require(chat.schedulerSourceAnchorDigest(
            sessionID: targetID, projectID: projectID, ordinal: 1
        ))
        preview.observedSourceAnchorDigest = anchor
        preview.observedPolicyRevision = policy.revision
        #expect(scheduler.confirmPreview(preview, actorID: "synthetic-authorizing-user",
                                         scopeID: projectID, policyRevision: policy.revision,
                                         now: now, sourceAnchorConfirmed: true,
                                         currentSourceAnchorDigest: anchor,
                                         currentPolicyRevision: policy.revision))
        runtime = makeRuntime()
    }

    func makeRuntime(
        beforeSubmit: (@MainActor (SchedulerExecutionContext) -> Void)? = nil
    ) -> SchedulerTaskRuntime {
        SchedulerTaskRuntime(
            store: scheduler, now: { [weak self] in self?.now ?? Date() },
            sourceAnchorResolver: { [weak self] session, project, ordinal in
                self?.chat.schedulerSourceAnchorDigest(
                    sessionID: session, projectID: project, ordinal: ordinal
                )
            },
            policyRevisionResolver: { [weak self] in self?.chat.schedulerPolicyRevision() },
            submitEffect: { [weak self] context in
                guard let self else { throw CancellationError() }
                beforeSubmit?(context)
                return try await self.chat.submitScheduledRequest(
                    context, memoryProposalConsumer: self.settings.memoryProposalConsumer
                )
            }
        )
    }

    @discardableResult
    func pollNext() -> UUID? {
        let previous = scheduler.latestOccurrence(for: taskID)?.id
        runtime.pollNow(at: now)
        now = now.addingTimeInterval(60)
        return previous
    }

    func waitForTerminal(after previous: UUID? = nil) async throws -> SchedulerOccurrence {
        for _ in 0..<300 {
            if let occurrence = scheduler.latestOccurrence(for: taskID),
               occurrence.id != previous, occurrence.state.isTerminal {
                return occurrence
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ScheduledMemory1747", code: 1)
    }

    func cleanup() {
        runtime.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("D-MEMA scheduled producer uses the real occurrence and review consumer")
@MainActor
struct ScheduledMemoryProducer1747Tests {
    @Test func actualScheduledProposalKeepsSourceInActiveRendererAfterReopenAndRevoke() async throws {
        let f = try ScheduledMemory1747Fixture()
        defer { f.cleanup() }
        let sourceID = ScheduledMemoryCandidateSource.sourceID(taskID: f.taskID)
        _ = try f.settings.setScheduledMemoryCandidateSubmission(
            taskID: f.taskID, in: f.scheduler, enabled: true
        )
        let previous = f.pollNext()
        let delivered = try await f.waitForTerminal(after: previous)
        #expect(delivered.state == .succeeded)
        let pending = try #require(f.settings.pendingMemoryProposals().first)
        let origin = try #require(pending.writeProvenance)
        let beforeDisplay = MemoryProposalReviewSourcePresentation(envelope: pending)
        #expect(origin.sourceID == sourceID)
        #expect(origin.actorID == "synthetic-authorizing-user")
        #expect(origin.runID == delivered.effectID)
        #expect(origin.triggerID == delivered.id.uuidString)
        #expect(try f.settings.memoryStore.activeFacts().isEmpty)

        // Actual Settings activation consumes the proposal from the real
        // scheduler -> ChatStore producer, not a directly constructed fact.
        try f.settings.approveDisplayedMemoryProposal(pending)
        let active = try #require(f.settings.memoryFacts.first)
        #expect(active.writeProvenance == origin)
        #expect(active.sourceProposalID == pending.proposal.proposalID)
        let clear = ChatTranscriptRedactor(secretValues: [])
        let consumer = f.settings.memoryProposalConsumer
        let renderer = MemoryActiveFactSourceView(fact: active,
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: consumer), redactor: clear)
        // This is the exact AttributedString fed to production Text and the
        // same native accessibility label, not a second expected UI model.
        let rendered = String(renderer.renderedText.characters)
        #expect(renderer.accessibilityText == rendered)
        #expect(rendered.contains(beforeDisplay.sourceLine))
        #expect(rendered.contains("来源引用（候选声明）：" + clear.redact(pending.sourceRef ?? "未提供")))
        #expect(rendered.contains("actor \(origin.actorID) · run \(origin.runID) · trigger \(origin.triggerID)"))
        #expect(rendered.contains("记忆状态：已激活"))
        #expect(rendered.contains("来源提交授权：已开启"))
        let factsBeforeProjection = try f.settings.memoryStore.facts()
        let proposalsBeforeProjection = try consumer.envelopes()
        let grantsBeforeProjection = try consumer.candidateSubmissionAuthorizations()

        let reopenedStore = MemoryStore(directory: f.settings.memoryStore.directory)
        let reopenedConsumer = MemoryProposalConsumer(store: reopenedStore)
        let reopenedFact = try #require(reopenedStore.activeFacts().first)
        #expect(reopenedFact == active)
        let reopenedRenderer = MemoryActiveFactSourceView(fact: reopenedFact,
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: reopenedConsumer), redactor: clear)
        #expect(String(reopenedRenderer.renderedText.characters) == rendered)
        #expect(reopenedRenderer.accessibilityText == rendered)
        #expect(try reopenedStore.facts() == factsBeforeProjection)
        #expect(try reopenedConsumer.envelopes() == proposalsBeforeProjection)
        #expect(try reopenedConsumer.candidateSubmissionAuthorizations() == grantsBeforeProjection)
        let unavailableRenderer = MemoryActiveFactSourceView(fact: reopenedFact,
            snapshot: .unavailable, redactor: clear)
        let unavailableText = String(unavailableRenderer.renderedText.characters)
        #expect(unavailableText.contains(beforeDisplay.sourceLine))
        #expect(unavailableText.contains("来源提交授权：状态未提供"))
        #expect(!unavailableText.contains("来源提交授权：已开启"))

        // Reuse the existing App redactor on actual captured synthetic origin.
        // No secret is loaded from an environment or Keychain.
        let protectedRenderer = MemoryActiveFactSourceView(fact: reopenedFact,
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: reopenedConsumer),
            redactor: ChatTranscriptRedactor(secretValues: [origin.actorID, origin.runID, origin.triggerID]))
        let protectedText = String(protectedRenderer.renderedText.characters)
        #expect(protectedRenderer.accessibilityText == protectedText)
        for syntheticSecret in [origin.actorID, origin.runID, origin.triggerID] {
            #expect(!protectedText.contains(syntheticSecret))
        }
        #expect(protectedText.contains(sourceID))

        _ = try f.settings.setScheduledMemoryCandidateSubmission(
            taskID: f.taskID, in: f.scheduler, enabled: false
        )
        let revokedRenderer = MemoryActiveFactSourceView(fact: reopenedFact,
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: reopenedConsumer), redactor: clear)
        let revokedText = String(revokedRenderer.renderedText.characters)
        #expect(revokedRenderer.accessibilityText == revokedText)
        #expect(revokedText.contains(beforeDisplay.sourceLine))
        #expect(revokedText.contains("记忆状态：已激活"))
        #expect(revokedText.contains("来源提交授权：已撤回；已批准记忆仍保留。"))
        let beforeDenied = f.pollNext()
        let later = try await f.waitForTerminal(after: beforeDenied)
        #expect(later.state == .failed)
        #expect(try reopenedStore.activeFacts() == [active])
        let afterRevokeStore = MemoryStore(directory: reopenedStore.directory)
        let afterRevoke = MemoryActiveFactSourceView(fact: try #require(afterRevokeStore.activeFacts().first),
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: MemoryProposalConsumer(store: afterRevokeStore)),
            redactor: clear)
        #expect(String(afterRevoke.renderedText.characters) == revokedText)
        #expect(afterRevoke.accessibilityText == revokedText)
        print("H4A2961_RENDERER source=\(sourceID) firstOccurrence=\(delivered.state) laterOccurrence=\(later.state) factState=\(active.lifecycleState) freshReopenMatches=\(reopenedFact == active) renderTextAXSame=\(renderer.accessibilityText == rendered) revokePersistenceMatches=\(String(afterRevoke.renderedText.characters) == revokedText) activeFacts=\(try afterRevokeStore.activeFacts().count)")
    }

    @Test func oldFactsDoNotInventSourceAndUnavailableAuthorityDoesNotClaimEnabled() async throws {
        let f = try ScheduledMemory1747Fixture()
        defer { f.cleanup() }
        // Existing durable legacy decode: absent origin is not inferred from
        // a session name, fact text, or the current UI source selection.
        _ = try f.settings.memoryStore.addFact("合成旧事实", sourceSessionID: "legacy-session")
        let reopened = MemoryStore(directory: f.settings.memoryStore.directory)
        let old = try #require(reopened.activeFacts().first)
        #expect(old.sourceProposalID == nil && old.writeProvenance == nil)
        let renderer = MemoryActiveFactSourceView(fact: old, snapshot: .unavailable,
            redactor: ChatTranscriptRedactor(secretValues: []))
        let text = String(renderer.renderedText.characters)
        #expect(renderer.accessibilityText == text)
        #expect(text.contains("候选来源 ID：旧记录未提供 · 提交授权纪元：旧记录未提供"))
        #expect(text.contains("来源提交授权：状态未提供"))
        #expect(!text.contains("来源提交授权：已开启"))
        #expect(!text.contains("actor ") && !text.contains("legacy-session"))

        // Built-in proposals have no typed actor tuple. Resolve only their
        // actual approved durable lineage, keeping missing actor fields absent.
        let consumer = f.settings.memoryProposalConsumer
        let grant = try consumer.grantCandidateSubmission(sourceID: "2961-plain-source")
        let proposal = try consumer.submit(proposalID: "2961-plain-proposal", text: "合成内建候选",
            within: MemoryScope(sessionID: f.targetID.uuidString, projectID: f.projectID), sourceID: grant.sourceID)
        #expect(proposal.writeProvenance == nil)
        try f.settings.approveDisplayedMemoryProposal(try #require(f.settings.pendingMemoryProposals().first))
        let freshStore = MemoryStore(directory: reopened.directory)
        let plain = try #require(freshStore.activeFacts().first(where: { $0.sourceProposalID == proposal.proposal.proposalID }))
        let plainRenderer = MemoryActiveFactSourceView(fact: plain,
            snapshot: try MemoryActiveFactSourceSnapshot(consumer: MemoryProposalConsumer(store: freshStore)),
            redactor: ChatTranscriptRedactor(secretValues: []))
        let plainText = String(plainRenderer.renderedText.characters)
        #expect(plainRenderer.accessibilityText == plainText)
        #expect(plainText.contains("候选来源 ID：\(grant.sourceID) · 提交授权纪元：\(grant.epoch)"))
        #expect(plainText.contains("记忆状态：已激活"))
        #expect(!plainText.contains("actor "))
    }

    @Test func explicitTaskNeedsSeparateSourceGrantAndPerFactApproval() async throws {
        let f = try ScheduledMemory1747Fixture()
        defer { f.cleanup() }
        let sourceID = ScheduledMemoryCandidateSource.sourceID(taskID: f.taskID)
        #expect(try !f.settings.scheduledMemoryCandidateSubmissionEnabled(
            taskID: f.taskID, in: f.scheduler
        ))
        _ = try f.settings.memoryProposalConsumer.grantCandidateSubmission(
            sourceID: ScheduledMemoryCandidateSource.sourceID(taskID: UUID()),
            reason: "synthetic unrelated source must not grant this task"
        )
        let beforeDenied = f.pollNext()
        #expect(try await f.waitForTerminal(after: beforeDenied).state == .failed)
        #expect(try f.settings.memoryProposalConsumer.envelopes().isEmpty)
        #expect(try f.settings.memoryStore.facts().isEmpty)

        let enabled = try f.settings.setScheduledMemoryCandidateSubmission(
            taskID: f.taskID, in: f.scheduler, enabled: true
        )
        #expect(enabled.sourceID == sourceID && enabled.canSubmit)
        let beforeDelivered = f.pollNext()
        let delivered = try await f.waitForTerminal(after: beforeDelivered)
        #expect(delivered.state == .succeeded)
        let pending = try #require(f.settings.memoryProposalConsumer.envelopes().first(where: {
            $0.proposal.proposalID == delivered.id.uuidString
        }))
        let origin = try #require(pending.writeProvenance)
        #expect(pending.state == .proposed)
        #expect(origin.sourceID == sourceID)
        #expect(origin.actorID == "synthetic-authorizing-user")
        #expect(origin.runID == delivered.effectID)
        #expect(origin.triggerID == delivered.id.uuidString)
        #expect(origin.submissionEpoch == enabled.epoch)
        #expect(try f.settings.memoryStore.facts().isEmpty)

        try f.settings.approveDisplayedMemoryProposal(pending)
        let active = try #require(f.settings.memoryStore.activeFacts().first)
        #expect(active.writeProvenance == origin)
        #expect(active.text == "synthetic scheduled memory")

        let beforeSecond = f.pollNext()
        let second = try await f.waitForTerminal(after: beforeSecond)
        #expect(second.state == .succeeded)
        let pendingSecond = try #require(f.settings.memoryProposalConsumer.envelopes().first(where: {
            $0.proposal.proposalID == second.id.uuidString
        }))
        let revoked = try f.settings.setScheduledMemoryCandidateSubmission(
            taskID: f.taskID, in: f.scheduler, enabled: false
        )
        #expect(!revoked.canSubmit)
        #expect(try f.settings.memoryProposalConsumer.envelopes().first(where: {
            $0.proposal.proposalID == pendingSecond.proposal.proposalID
        })?.state == .revoked)
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try f.settings.approveDisplayedMemoryProposal(pendingSecond)
        }
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try f.settings.memoryProposalConsumer.approve(
                proposalID: pendingSecond.proposal.proposalID,
                within: MemoryScope(sessionID: f.targetID.uuidString, projectID: f.projectID),
                reason: "revoked source cannot approve pending proposal"
            )
        }
        let beforeRevoked = f.pollNext()
        #expect(try await f.waitForTerminal(after: beforeRevoked).state == .failed)
        #expect(try f.settings.memoryStore.activeFacts().count == 1)
    }

    @Test func expiredOrChangedOccurrenceCannotSubmitCandidate() async throws {
        for invalidate in ["expired", "changed"] {
            let f = try ScheduledMemory1747Fixture()
            defer { f.cleanup() }
            _ = try f.settings.setScheduledMemoryCandidateSubmission(
                taskID: f.taskID, in: f.scheduler, enabled: true
            )
            f.runtime = f.makeRuntime { context in
                if invalidate == "expired" {
                    f.now = f.now.addingTimeInterval(600)
                } else {
                    _ = context.store.cancelOccurrence(
                        id: context.request.occurrenceID,
                        owner: context.owner, token: context.token,
                        expectedTaskVersion: context.request.taskVersion,
                        expectedControlRevision: context.request.taskVersion,
                        now: f.now
                    )
                }
            }
            let beforeInvalidated = f.pollNext()
            _ = try await f.waitForTerminal(after: beforeInvalidated)
            #expect(try f.settings.memoryProposalConsumer.envelopes().isEmpty)
            #expect(try f.settings.memoryStore.facts().isEmpty)
        }
    }
}
