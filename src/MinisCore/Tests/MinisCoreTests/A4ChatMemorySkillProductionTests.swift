import Foundation
import Testing
@testable import MinisCore

private final class A4CapturingProvider: LLMProvider, @unchecked Sendable {
    let name = "a4-provider"
    var model = LLMModel(id: "a4-model", displayName: "A4 Model", provider: "a4-provider")
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var calls = 0
    private(set) var prompts: [String?] = []

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        calls += 1
        prompts.append(systemPrompt)
        return LLMResponse(text: "ok", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct A4ChatMemorySkillProductionTests {
    @Test
    func skillInjectionReceiptCarriesStableRequestBudgetAndSkipFacts() {
        let receipt = SkillInjectionReceipt(
            request: "same request",
            skillID: "a4-skill",
            version: "1.0.0",
            contentHash: "skill-hash",
            matchedTerms: ["same"],
            injectedCharacters: 12,
            budget: 100,
            omittedReason: "total_character_budget",
            generation: 3,
            sessionID: "session-a"
        )

        #expect(receipt.request == SkillInjectionReceipt.stableRequestFingerprint(for: "same request"))
        #expect(receipt.skillHash == "skill-hash")
        #expect(receipt.budget == 100)
        #expect(receipt.skipReason == "total_character_budget")
        #expect(receipt.generation == 3)
    }

    private func makeFixture(
        id: String = UUID().uuidString,
        projectID: String? = "project-a"
    ) throws -> (
        root: URL,
        session: ChatSession,
        sessions: SessionStore,
        memory: MemoryStore,
        skills: SkillStore,
        souls: SoulStore,
        provider: A4CapturingProvider,
        runtime: ChatSessionRuntime
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A4ChatMemorySkillProduction-\(UUID().uuidString)")
        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: id, projectID: projectID)
        let memory = MemoryStore(directory: root)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let souls = SoulStore(directory: root)
        let provider = A4CapturingProvider()
        let runtime = ChatSessionRuntime(
            sessionStore: sessions,
            memoryStore: memory,
            skillStore: skills,
            soulStore: souls,
            provider: provider,
            toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            toolCatalog: AgentToolCatalog.makeTools(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        return (root, session, sessions, memory, skills, souls, provider, runtime)
    }

    private func productionRequest(
        text: String,
        context: ChatRuntimeContext,
        name: String,
        capsule: ChatInputCapsule? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            text: text,
            context: context,
            capsule: capsule,
            turnID: "turn:\(name)",
            taskID: "task:\(name)",
            attempt: 1,
            executionIdentity: minisCoreToolContractIdentity(
                name,
                sessionID: context.sessionID
            )
        )
    }

    @Test
    func planIsDryRunAndDoesNotPersistOrCallProvider() async throws {
        let fixture = try makeFixture()
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)

        let result = try await fixture.runtime.send(
            ChatTurnRequest(
                text: "plan this",
                context: context,
                operationMode: .plan
            )
        )

        #expect(result.isDryRun)
        #expect(fixture.provider.calls == 0)
        #expect(fixture.sessions.loadSession(id: fixture.session.id)?.messages.isEmpty == true)
        #expect(result.context.memoryScope == MemoryScope(sessionID: fixture.session.id, projectID: "project-a"))
    }

    @Test(arguments: ["corrupt-json", "facts-directory", "damaged-parent"])
    func localRecallFailureStillSendsBasePromptWithoutChangingMemory(failure: String) async throws {
        let fixture = try makeFixture()
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)
        let memoryDirectory = fixture.root.appendingPathComponent("memory", isDirectory: true)
        let factsURL = memoryDirectory.appendingPathComponent("facts.json")
        let badBytes = Data("not-json-586".utf8)
        if failure == "damaged-parent" {
            try badBytes.write(to: memoryDirectory)
        } else {
            try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
            if failure == "facts-directory" {
                try FileManager.default.createDirectory(at: factsURL, withIntermediateDirectories: true)
            } else {
                try badBytes.write(to: factsURL)
            }
        }
        #expect(throws: (any Error).self) { try fixture.memory.facts() }
        let result = try await fixture.runtime.send(productionRequest(
            text: "晴天 Swift", context: context, name: "a4-recall-586-\(failure)"
        ))
        #expect(!result.isDryRun)
        #expect(result.messages.last?.content == "ok")
        #expect(fixture.provider.calls == 1)
        #expect(fixture.provider.prompts == [SoulStore.defaultSoul.systemPrompt])
        let saved = try #require(fixture.sessions.loadSession(id: fixture.session.id))
        #expect(saved.messages.map(\.content) == ["晴天 Swift", "ok"])
        #expect(throws: (any Error).self) { try fixture.memory.facts() }
        if failure == "facts-directory" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: factsURL.path).isEmpty)
        } else {
            #expect(try Data(contentsOf: failure == "damaged-parent" ? memoryDirectory : factsURL) == badBytes)
        }

        // A local read fault cannot authorize a context replay. It still
        // rejects before a second provider call or a foreign transcript write.
        let other = try fixture.sessions.createSession(id: "foreign-586", projectID: "foreign-project")
        await #expect(throws: ChatSessionRuntimeError.contextMismatch) {
            try await fixture.runtime.send(ChatTurnRequest(
                text: "晴天 Swift", context: context, sessionID: other.id
            ))
        }
        #expect(fixture.provider.calls == 1)
        #expect(fixture.sessions.loadSession(id: other.id)?.messages.isEmpty == true)
    }

    @Test
    func productionTurnUsesPinnedMemoryScopeAndPersistsTranscript() async throws {
        let fixture = try makeFixture()
        let scope = MemoryScope(sessionID: fixture.session.id, projectID: "project-a")
        _ = try fixture.memory.addFact(
            "只有 A 会话可以看见",
            sourceSessionID: fixture.session.id,
            memoryScope: scope
        )
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)

        let result = try await fixture.runtime.send(
            productionRequest(
                text: "会话",
                context: context,
                name: "a4-memory-scope"
            )
        )

        #expect(!result.isDryRun)
        #expect(fixture.provider.calls == 1)
        #expect(fixture.provider.prompts.first??.contains("只有 A 会话可以看见") == true)
        #expect(fixture.sessions.loadSession(id: fixture.session.id)?.messages.count == 2)
    }

    @Test
    func reopenedProductionTurnsUseRecoveredFactSourceAndEffectiveState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = MemoryScope(sessionID: fixture.session.id, projectID: "project-a")
        let sourceID = "synthetic-scheduled-source"
        let consumer = MemoryProposalConsumer(store: fixture.memory)
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID, reason: "synthetic enable")
        let submitted = try consumer.submit(
            proposalID: "restart-source-fact", text: "orbital peach preference",
            within: scope, sourceRef: "synthetic://run/restart",
            sourceHash: "synthetic-effect", generation: 1, sourceID: sourceID,
            writeProvenance: MemoryWriteProvenanceInput(
                actorID: "synthetic-actor", runID: "synthetic-run",
                triggerID: "synthetic-trigger", sourceID: sourceID
            )
        )
        _ = try consumer.approve(
            proposalID: submitted.proposal.proposalID, within: scope,
            reason: "individual synthetic fact approval"
        )
        _ = try consumer.revokeCandidateSubmission(sourceID: sourceID, reason: "synthetic revoke")

        func reopenedRuntime(provider: A4CapturingProvider) throws -> ChatSessionRuntime {
            ChatSessionRuntime(
                sessionStore: SessionStore(directory: fixture.root),
                memoryStore: MemoryStore(directory: fixture.root),
                skillStore: SkillStore(skillsRoot: fixture.root.appendingPathComponent("skills")),
                soulStore: SoulStore(directory: fixture.root),
                provider: provider,
                toolExecutor: BuiltinToolExecutor(allowedRoot: fixture.root),
                toolCatalog: AgentToolCatalog.makeTools(),
                toolExecutionFactLedger: try minisCoreToolContractLedger(at: fixture.root)
            )
        }

        let firstProvider = A4CapturingProvider()
        let firstReopen = try reopenedRuntime(provider: firstProvider)
        let firstContext = try await firstReopen.makeContext(sessionID: fixture.session.id)
        _ = try await firstReopen.send(productionRequest(
            text: "orbital peach", context: firstContext, name: "a4-restart-active"
        ))
        #expect(firstProvider.calls == 1)
        #expect(firstProvider.prompts.first??.contains("orbital peach preference") == true)
        let reopenedMemory = MemoryStore(directory: fixture.root)
        let fact = try #require(reopenedMemory.activeFacts().first)
        #expect(fact.sourceRef == "synthetic://run/restart")
        #expect(fact.writeProvenance == submitted.writeProvenance)
        #expect(try MemoryProposalConsumer(store: reopenedMemory).proposalLineage(
            forFactID: fact.id, within: scope
        )?.writeProvenance == submitted.writeProvenance)
        #expect(try consumer.candidateSubmissionAuthorizations().first(where: {
            $0.sourceID == sourceID
        })?.canSubmit == false)

        _ = try reopenedMemory.tombstoneFact(id: fact.id, reason: "synthetic user deletion")
        let secondProvider = A4CapturingProvider()
        let secondReopen = try reopenedRuntime(provider: secondProvider)
        let secondContext = try await secondReopen.makeContext(sessionID: fixture.session.id)
        _ = try await secondReopen.send(productionRequest(
            text: "orbital peach", context: secondContext, name: "a4-restart-tombstoned"
        ))
        #expect(secondProvider.calls == 1)
        #expect(secondProvider.prompts.first??.contains("orbital peach preference") == false)
        #expect(try MemoryStore(directory: fixture.root).activeFacts().isEmpty)
    }

    @Test
    func productionTurnInjectsOnlyPinnedSkillWithinSessionScope() async throws {
        let fixture = try makeFixture()
        let scope = MemoryScope(sessionID: fixture.session.id, projectID: "project-a")
        let imported = try fixture.skills.importSkillThroughLifecycle(
            content: """
            ---
            name: a4-scoped-skill
            description: a4 trigger
            version: 1.0.0
            ---

            A4 scoped skill body.
            """,
            source: .file,
            reason: "A4 production test",
            scope: scope,
            approval: SkillApproval(approverID: "a4-test", scope: scope)
        )
        let context = try await fixture.runtime.makeContext(
            sessionID: fixture.session.id,
            skillIDs: [imported.skill.id]
        )

        let result = try await fixture.runtime.send(
            productionRequest(
                text: "a4-scoped-skill",
                context: context,
                name: "a4-skill-scope"
            )
        )

        #expect(imported.receipt.state == .active)
        #expect(imported.receipt.scope == scope)
        #expect(context.skillIDs == [imported.skill.id])
        #expect(result.matchedSkillIDs == [imported.skill.id])
        #expect(fixture.provider.prompts.first??.contains("A4 scoped skill body.") == true)
    }

    @Test
    func contextCannotBeReplayedAcrossSessionsOrProjects() async throws {
        let fixture = try makeFixture()
        let other = try fixture.sessions.createSession(id: "session-b", projectID: "project-b")
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)

        await #expect(throws: ChatSessionRuntimeError.contextMismatch) {
            try await fixture.runtime.send(
                ChatTurnRequest(text: "wrong session", context: context, sessionID: other.id)
            )
        }
    }

    @Test
    func memoryProposalExpiresAndApprovedFactCanRollback() async throws {
        let fixture = try makeFixture()
        _ = try MemoryProposalConsumer(store: fixture.memory).grantCandidateSubmission(
            sourceID: "chat-session-runtime",
            reason: "A4 explicit memory proposal fixture grant"
        )
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)
        let expired = try await fixture.runtime.proposeMemory(
            text: "expired",
            context: context,
            proposalID: "expired",
            expiresAt: Date(timeIntervalSince1970: 10)
        )
        await #expect(throws: ChatSessionRuntimeError.proposalExpired) {
            try await fixture.runtime.approveMemory(expired, reason: "late", now: Date(timeIntervalSince1970: 20))
        }

        let proposal = try await fixture.runtime.proposeMemory(
            text: "rollback me",
            context: context,
            proposalID: "rollback-me",
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        _ = try await fixture.runtime.approveMemory(
            proposal,
            reason: "explicit",
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(try fixture.memory.facts().contains { $0.id == "rollback-me" })
        try await fixture.runtime.rollbackMemory(proposalID: proposal.proposalID, reason: "user undo")
        #expect(try fixture.memory.facts().contains { $0.id == "rollback-me" } == false)
    }

    @Test
    func capsuleSendIsIdempotentlyRejectedAfterFirstSend() async throws {
        let fixture = try makeFixture()
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)
        let capsule = ChatInputCapsule(
            capsuleID: "capsule-1",
            sessionID: fixture.session.id,
            originalSnapshot: "long text",
            sendSnapshot: "long text"
        )
        let request = productionRequest(
            text: capsule.sendSnapshot,
            context: context,
            name: "a4-capsule",
            capsule: capsule
        )
        _ = try await fixture.runtime.send(request)

        await #expect(throws: ChatSessionRuntimeError.duplicateCapsuleSend) {
            try await fixture.runtime.send(request)
        }
        #expect(fixture.provider.calls == 1)
    }

    @Test
    func bypassModeIsRejectedBeforeAnyProviderOrSessionWrite() async throws {
        let fixture = try makeFixture()
        let context = try await fixture.runtime.makeContext(sessionID: fixture.session.id)

        await #expect(throws: ChatSessionRuntimeError.bypassNotAllowed) {
            try await fixture.runtime.send(
                ChatTurnRequest(text: "no bypass", context: context, operationMode: .bypass)
            )
        }
        #expect(fixture.provider.calls == 0)
        #expect(fixture.sessions.loadSession(id: fixture.session.id)?.messages.isEmpty == true)
    }
}
