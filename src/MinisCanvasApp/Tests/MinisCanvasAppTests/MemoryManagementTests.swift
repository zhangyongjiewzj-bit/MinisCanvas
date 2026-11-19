import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private final class H4CProvider3033: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "h4c3033-local"
    var model = LLMModel(id: "h4c3033-model", displayName: "H4C synthetic", provider: "h4c3033-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "h4c3033-owned"
    private let lock = NSLock()
    private var capturedPrompts: [String] = []
    private var capturedRequests: [[LLMMessage]] = []

    var prompts: [String] { lock.withLock { capturedPrompts } }
    var requests: [[LLMMessage]] { lock.withLock { capturedRequests } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock {
            capturedPrompts.append(systemPrompt ?? "")
            capturedRequests.append(messages)
        }
        return LLMResponse(text: "synthetic ordinary reply", stopReason: "stop", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("H4C synthetic Provider unexpectedly used streaming transport")
        return AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - 波4 记忆管理（SettingsCenter → MemoryStore 接线）
//
// 验证「记忆」Tab 依赖的接线层：新增/列出/删除/清空 + 空白拒绝 + 持久化。
// 全部用临时目录注入，不触碰 Application Support 真实数据。

@Suite("波4 记忆管理")
@MainActor
struct MemoryManagementTests {

    @Test("内建候选默认授权只插入缺失来源，撤权后重启不复活，外部来源仍关闭")
    func builtInCandidateDefaultsPreserveRevocationAndApproval() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir, provisionSettings: false)
        let consumer = center.memoryProposalConsumer
        let scope = MemoryScope(sessionID: "test-session", projectID: "test-project")

        let genericSources: [SettingsCenter.BuiltInMemoryCandidateSource] = [
            .settingsCenter, .composerCommand, .presetCommand, .chatSessionRuntime
        ]
        let dedicatedSource = MemoryProposalConsumer.chatProjectSourceID
        let expectedSourceIDs = Set(genericSources.map(\.rawValue) + [dedicatedSource])
        let defaults = try center.provisionBuiltInMemoryCandidateSubmissions()
        #expect(Set(defaults.map(\.sourceID)) == expectedSourceIDs)
        for authorization in defaults {
            #expect(authorization.canSubmit)
        }
        let authorizations = try consumer.candidateSubmissionAuthorizations()
        #expect(authorizations.count == 5)
        #expect(Set(authorizations.map(\.sourceID)) == expectedSourceIDs)

        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try consumer.submit(text: "专用来源不可通过通用入口提交", within: scope, sourceID: dedicatedSource)
        }
        #expect(try consumer.envelopes().isEmpty)

        #expect(throws: MemoryProposalConsumerError.candidateSubmissionUnauthorized) {
            _ = try consumer.submit(
                text: "外部定时来源不得默认提交",
                within: scope,
                sourceID: "scheduled-task"
            )
        }

        var proposals: [String: String] = [:]
        for source in genericSources {
            let submitted = try consumer.submit(
                text: "内建来源 \(source.rawValue) 的候选",
                within: scope,
                sourceID: source.rawValue
            )
            proposals[source.rawValue] = submitted.proposal.proposalID
        }
        // A source grant admits candidates, never facts; each fact still needs
        // its own explicit approval.
        #expect(try center.memoryStore.facts().isEmpty)

        let composer = SettingsCenter.BuiltInMemoryCandidateSource.composerCommand
        _ = try consumer.approve(
            proposalID: try #require(proposals[composer.rawValue]),
            within: scope,
            reason: "用户批准撤权前的一条记忆"
        )
        let composerProposalID = try consumer.submit(
            text: "撤权前尚未批准的 Composer 候选",
            within: scope,
            sourceID: composer.rawValue
        ).proposal.proposalID
        let revoked = try center.setMemoryCandidateSubmission(for: composer, enabled: false)
        #expect(!revoked.canSubmit)
        #expect(revoked.epoch == 1)
        #expect(try consumer.envelopes().first(where: {
            $0.proposal.proposalID == composerProposalID
        })?.state == .revoked)
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try consumer.submit(
                text: "撤权后的新候选",
                within: scope,
                sourceID: composer.rawValue
            )
        }
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try consumer.approve(
                proposalID: composerProposalID,
                within: scope,
                reason: "撤权后不能批准"
            )
        }

        for source in genericSources where source != composer {
            _ = try consumer.approve(
                proposalID: try #require(proposals[source.rawValue]),
                within: scope,
                reason: "用户逐条批准"
            )
        }
        #expect(try center.memoryStore.activeFacts().count == 4)

        let reopened = makeCenter(dir: dir, provisionSettings: false)
        let replay = try reopened.provisionBuiltInMemoryCandidateSubmissions()
        #expect(replay.first(where: { $0.sourceID == composer.rawValue }) == revoked)
        #expect(try reopened.memoryCandidateSubmissionEnabled(for: composer) == false)
        #expect(try reopened.memoryStore.activeFacts().count == 4)

        let enabled = try reopened.setMemoryCandidateSubmission(for: composer, enabled: true)
        #expect(enabled.canSubmit)
        #expect(enabled.epoch == revoked.epoch)
        #expect(try reopened.memoryProposalConsumer.submit(
            text: "用户重新启用后的候选",
            within: scope,
            sourceID: composer.rawValue
        ).state == .proposed)
        #expect(try reopened.memoryStore.activeFacts().count == 4)
    }

    @Test("新增结果区分缺少范围、空输入、范围拒绝和保存失败")
    func addMemoryFactReportsActionableFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        center.memoryScopeProvider = nil
        #expect(center.addMemoryFactResult("   ") == .emptyInput)
        #expect(center.addMemoryFactResult("非空资料") == .missingScope)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))
        center.memoryScopeProvider = { MemoryScope(sessionID: "", projectID: "") }
        #expect(center.addMemoryFactResult("非空资料") == .scopeRejected)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))
        center.memoryScopeProvider = { MemoryScope(sessionID: "session", projectID: "project") }
        try FileManager.default.createDirectory(at: center.memoryStore.fileURL, withIntermediateDirectories: true)
        let sentinel = center.memoryStore.fileURL.appendingPathComponent("untouched")
        let bytes = Data("保留原始对象".utf8)
        try bytes.write(to: sentinel)
        #expect(center.addMemoryFactResult("非空资料") == .persistenceFailed)
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(center.memoryFacts.isEmpty)
        #expect(SettingsCenter.MemoryFactAddResult.missingScope.message != SettingsCenter.MemoryFactAddResult.emptyInput.message)
        #expect(SettingsCenter.MemoryFactAddResult.persistenceFailed.message != SettingsCenter.MemoryFactAddResult.emptyInput.message)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    private func makeCenter(dir: URL, provisionSettings: Bool = true,
                            keychain: KeychainStore = KeychainStore()) -> SettingsCenter {
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir, keychain: keychain),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        )
        center.memoryScopeProvider = {
            MemoryScope(sessionID: "test-session", projectID: "test-project")
        }
        if provisionSettings {
            do {
                _ = try center.provisionMemoryCandidateSubmission()
            } catch {
                preconditionFailure("记忆候选测试夹具授权失败：\(error)")
            }
        }
        return center
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMgmt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("新增记忆：addMemoryFact 写入 MemoryStore 并刷新快照")
    func addMemoryFactPersists() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)

        let ok = center.addMemoryFact("用户偏好暗色主题", category: .userPref)
        #expect(ok == true)
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.first?.text == "用户偏好暗色主题")
        #expect(center.memoryFacts.first?.category == .userPref)

        // 持久化：重载后仍在
        center.reloadStorage()
        #expect(center.memoryFacts.count == 1)
    }

    @Test("Explicit manual memory is eligible in other sessions of the same project")
    func manualMemoryRecallsAcrossSessionsOnlyWithinItsProject() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = makeCenter(dir: directory, keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        let origin = MemoryScope(sessionID: "session-a", projectID: "project-owned")
        center.memoryScopeProvider = { origin }
        let legacy = try center.memoryStore.addFact(
            id: UUID().uuidString,
            text: "旧偏好：回答使用简体中文", sourceSessionID: origin.sessionID,
            category: .userPref, memoryScope: origin
        )
        let unrelated = try center.memoryStore.addFact(
            id: UUID().uuidString, text: "导入偏好：回答使用中文",
            sourceSessionID: origin.sessionID, category: .userPref,
            memoryScope: origin, visibility: .project
        )
        let manualText = "测试偏好：回答使用中文"
        try #require(center.addMemoryFactResult(manualText, category: .userPref) == .added)
        let reopened = MemoryStore(directory: center.memoryStore.directory)
        let facts = try reopened.activeFacts()
        let manual = try #require(facts.first { $0.text == manualText })
        #expect(manual.visibility == .project)
        #expect(facts.first { $0.id == legacy.id }?.visibility == nil)
        let injector = MemoryInjector(store: reopened)
        let query = "我偏好用什么语言回答？"
        let sameProject = MemoryScope(sessionID: "session-b", projectID: origin.projectID)
        let otherProject = MemoryScope(sessionID: "session-c", projectID: "project-other")
        let source = try injector.injection(
            base: "", userMessage: query, context: MemoryInjectionContext(scope: origin))
        #expect(Set(source.injectedFactIDs) == Set([manual.id, legacy.id, unrelated.id]))
        let sibling = try injector.injection(
            base: "", userMessage: query, context: MemoryInjectionContext(scope: sameProject))
        #expect(Set(sibling.injectedFactIDs) == Set([manual.id, unrelated.id]))
        #expect(sibling.prompt.contains(manualText))
        let search = MemorySearchDisplayConsumer(search: MemorySearch(store: reopened))
        let siblingResults = try search.retrieve(keyword: "偏好", scope: .session(sameProject))
        #expect(Set(siblingResults.items.map(\.factID)) == Set([manual.id, unrelated.id]))
        let foreignResults = try search.retrieve(keyword: "偏好", scope: .session(otherProject))
        #expect(foreignResults.items.isEmpty)
        let foreign = try injector.injection(
            base: "", userMessage: query, context: MemoryInjectionContext(scope: otherProject))
        #expect(foreign.injectedFactIDs.isEmpty)
        #expect(!foreign.prompt.contains(manualText))
    }

    @Test("新增记忆：空白内容被拒绝")
    func addMemoryFactRejectsBlank() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)

        let ok = center.addMemoryFact("   ")
        #expect(ok == false)
        #expect(center.memoryFacts.isEmpty)
    }

    @Test("删除记忆：removeMemoryFact 按 id 删除并刷新快照")
    func removeMemoryFact() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        _ = center.addMemoryFact("经历一")
        _ = center.addMemoryFact("经历二")
        #expect(center.memoryFacts.count == 2)

        let firstID = center.memoryFacts.first!.id
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deletion = try center.previewMemoryFactDeletion(id: firstID, now: now)
        let presentation = SettingsDeletionPresentation(intent: deletion)
        #expect(presentation.warning == "本次操作不可恢复。")
        #expect(presentation.secondPhrase == "永久删除")
        try #require(!deletion.reversible)
        #expect(deletion.expiresAt == now.addingTimeInterval(300))

        let firstConfirmed = deletion.withFirstConfirmation("我已核对这份精确预览")
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            try center.removeMemoryFact(id: firstID, intent: deletion, now: now)
        }
        #expect(throws: DeletionGateError.secondConfirmationRequired) {
            try center.removeMemoryFact(id: firstID, intent: firstConfirmed, now: now)
        }
        #expect(throws: DeletionGateError.irreversibleRequiresPhrase) {
            try center.removeMemoryFact(
                id: firstID,
                intent: firstConfirmed.withSecondConfirmation("I CONFIRM MOVE TO TRASH"),
                now: now
            )
        }
        #expect(throws: DeletionGateError.expired) {
            try center.removeMemoryFact(id: firstID, intent: confirmed(deletion), now: now.addingTimeInterval(300))
        }
        #expect(center.memoryFacts.count == 2)
        _ = try center.removeMemoryFact(id: firstID, intent: confirmed(deletion), now: now.addingTimeInterval(299))
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.contains { $0.id == firstID } == false)
    }

    @Test("删除后下一真实聊天回合与重开均不向 Provider 送旧事实")
    func deletedFactStaysOutOfNextProviderPromptAfterReopen() async throws {
        let formal = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = formal.rootDirectory.appendingPathComponent("h4c3033-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "h4c3033-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let center = makeCenter(dir: root)
        let chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
        try #require(chat.attachPersistence(SessionStore(directory: root.appendingPathComponent("sessions"))))
        let sessionID = try #require(chat.activeSessionID)
        chat.setProject(
            .init(id: "h4c3033-project", name: "Owned project", workingDirectory: root.path),
            forSession: sessionID
        )
        let scope = try #require(chat.activeMemoryScope)
        center.memoryScopeProvider = { chat.activeMemoryScope }
        center.memoryEnabled = true
        #expect(center.addMemoryFact("orbit3033 old fact must be forgotten"))
        #expect(center.addMemoryFact("orbit3033 independent fact must remain"))
        let original = try #require(center.memoryFacts.first { $0.text.contains("old fact") })
        let independent = try #require(center.memoryFacts.first { $0.text.contains("independent fact") })
        #expect(original.memoryScope == scope)
        #expect(independent.memoryScope == scope)

        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "h4c3033-policy",
            grantEpoch: "h4c3033-epoch", leaseID: "h4c3033-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l1
        )
        chat.configureComposerPolicy(facts)
        chat.agentEngine = AgentLoopChatEngine(
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts
        )
        let injector = SkillInjector(store: SkillStore(
            skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil
            )
        }
        chat.memoryInjector = MemoryInjector(store: center.memoryStore)
        chat.memoryEnabledProvider = { center.memoryEnabled }
        let provider = H4CProvider3033()
        chat.streamingProviderOverride = provider

        func send(_ text: String, expectedCount: Int) async throws -> String {
            chat.draftText = text
            chat.submitComposer()
            for _ in 0..<300 {
                if !chat.isActiveSessionStreaming && provider.prompts.count >= expectedCount { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!chat.isActiveSessionStreaming)
            try #require(provider.prompts.count == expectedCount)
            #expect(provider.requests.count == expectedCount)
            let hasCurrentUserRequest = provider.requests.last?.contains {
                $0.role == .user && $0.content.contains(text)
            } ?? false
            #expect(hasCurrentUserRequest)
            return try #require(provider.prompts.last)
        }

        let before = try await send("请解释 orbit3033", expectedCount: 1)
        #expect(before.contains(original.text))
        #expect(before.contains(independent.text))

        let deletion = try center.previewMemoryFactDeletion(id: original.id)
        _ = try center.removeMemoryFact(id: original.id, intent: confirmed(deletion))
        #expect(center.memoryFacts.map(\.id) == [independent.id])
        let nextTurn = try await send("继续讨论 orbit3033", expectedCount: 2)
        #expect(!nextTurn.contains(original.text))
        #expect(nextTurn.contains(independent.text))

        let reopened = makeCenter(dir: root, provisionSettings: false)
        reopened.memoryScopeProvider = { chat.activeMemoryScope }
        #expect(reopened.memoryFacts.map(\.id) == [independent.id])
        chat.memoryInjector = MemoryInjector(store: reopened.memoryStore)
        chat.memoryEnabledProvider = { reopened.memoryEnabled }
        let afterReopen = try await send("重开后再问 orbit3033", expectedCount: 3)
        #expect(!afterReopen.contains(original.text))
        #expect(afterReopen.contains(independent.text))
        chat.stopAllStreamingForSafety()
    }

    @Test("清空记忆：clearAllMemory 返回删除数并清空快照")
    func clearAllMemory() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        _ = center.addMemoryFact("a")
        _ = center.addMemoryFact("b")
        _ = center.addMemoryFact("c")

        let deletion = try center.previewMemoryClear()
        // Successful clear has no recovery entry and requires the permanent phrase.
        let receipt = try center.clearAllMemory(intent: confirmed(deletion).withSecondConfirmation("永久删除"))
        #expect(receipt.affectedCount == 3)
        #expect(center.memoryFacts.isEmpty)
    }

    @Test("记忆持久化格式不变：磁盘 JSON 可直接被 MemoryStore 读回")
    func persistenceFormatUnchanged() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        _ = center.addMemoryFact("跨会话记忆", category: .lesson)

        // 独立 MemoryStore 直接读同一文件，验证格式未变
        let store = MemoryStore(directory: dir)
        let facts = try store.facts()
        #expect(facts.count == 1)
        #expect(facts.first?.text == "跨会话记忆")
        #expect(facts.first?.category == .lesson)
    }

    @Test("新增和导入：都经过同一 scope admission consumer")
    func addAndImportUseScopedConsumer() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)

        #expect(center.addMemoryFact("新增事实") == true)
        let imported = [
            MemoryFact(
                text: "导入事实",
                sourceSessionID: "foreign-session",
                memoryScope: nil
            )
        ]
        let result = center.importMemoryFacts(imported)

        #expect(result.added == 1)
        #expect(result.skipped == 0)
        #expect(center.memoryFacts.contains { $0.text == "导入事实" })
        #expect(center.memoryFacts.allSatisfy {
            $0.memoryScope == MemoryScope(sessionID: "test-session", projectID: "test-project")
        })
    }

    @Test("JSON 记忆导入走一次 scoped restore 并保持幂等 receipt")
    func jsonImportUsesScopedRestore() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        let incoming = [
            MemoryFact(text: "批量事实一", category: .lesson),
            MemoryFact(text: "批量事实二", category: .userPref)
        ]
        let data = try JSONEncoder().encode(incoming)

        let first = try center.importMemoryJSON(data)
        let second = try center.importMemoryJSON(data)

        #expect(first == MemoryImportResult(added: 2, skipped: 0))
        #expect(second == MemoryImportResult(added: 0, skipped: 2))
        #expect(try center.memoryProposalConsumer.restoreReceipts().count == 1)
        #expect(try center.memoryStore.facts().allSatisfy {
            $0.memoryScope == MemoryScope(sessionID: "test-session", projectID: "test-project")
        })
    }

    @Test("JSON 记忆导出在 facts 损坏时严格失败而不导出缓存")
    func jsonExportFailsClosedOnCorruptFacts() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        #expect(center.addMemoryFact("不可伪造的事实") == true)
        try Data("{not-json".utf8).write(to: center.memoryStore.fileURL, options: .atomic)

        #expect(throws: Error.self) {
            _ = try center.exportMemoryJSON()
        }
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == Data("{not-json".utf8))
    }

    @Test("缺少 active scope：新增记忆 fail-closed 且零写入")
    func addMemoryFactRequiresActiveScope() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        center.memoryScopeProvider = nil

        #expect(center.addMemoryFact("没有 scope 的事实") == false)
        #expect(center.memoryFacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))
    }

    @Test("文件式记忆只在保存/删除成功时报告成功并刷新列表")
    func memoryFileOperationResultsAreTruthful() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)

        #expect(center.saveMemoryDocumentResult(named: "GLOBAL.md", content: "global") == .saved)
        #expect(center.readMemoryDocument(named: "GLOBAL.md") == "global")
        #expect(center.memoryFiles.map(\.relativePath) == ["GLOBAL.md"])
        #expect(center.deleteMemoryDocumentResult(named: "GLOBAL.md") == .deleted)
        #expect(center.readMemoryDocument(named: "GLOBAL.md") == nil)
        #expect(center.memoryFiles.isEmpty)

        #expect(center.saveMemoryDocumentResult(named: "GLOBAL.md", content: "global") == .saved)

        let beforeInvalidTarget = center.memoryFiles.map(\.relativePath)
        #expect(
            center.saveMemoryDocumentResult(named: "../outside.md", content: "outside")
                == .saveInvalidTarget
        )
        #expect(center.memoryFiles.map(\.relativePath) == beforeInvalidTarget)
        #expect(center.readMemoryDocument(named: "../outside.md") == nil)

        let soulURL = center.memoryFileStore.soulURL
        try FileManager.default.createDirectory(at: soulURL, withIntermediateDirectories: false)
        let beforeWriteFailure = center.memoryFiles.map(\.relativePath)
        #expect(
            center.saveMemoryDocumentResult(named: "SOUL.md", content: "must remain editable")
                == .saveFailed
        )
        #expect(center.memoryFiles.map(\.relativePath) == beforeWriteFailure)
        #expect(FileManager.default.fileExists(atPath: soulURL.path))

        #expect(center.deleteMemoryDocumentResult(named: "missing.md") == .deleteInvalidTarget)
        #expect(center.memoryFiles.map(\.relativePath) == beforeWriteFailure)
    }

    @Test("文件式记忆删除写盘失败时保留文件和列表")
    func memoryFileDeleteFailurePreservesState() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        try center.memoryFileStore.writeSoul("soul")
        center.reloadMemoryFiles()
        let before = center.memoryFiles.map(\.relativePath)
        let soulURL = center.memoryFileStore.soulURL
        let memoryDirectory = center.memoryFileStore.memoryDirectory

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: memoryDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: memoryDirectory.path
            )
        }

        #expect(center.deleteMemoryDocumentResult(named: "SOUL.md") == .deleteFailed)
        #expect(FileManager.default.fileExists(atPath: soulURL.path))
        #expect(center.memoryFiles.map(\.relativePath) == before)
    }

    @Test("Markdown 先预览再确认：作用域选择绑定且取消不写入")
    func markdownPreviewBindsExplicitScope() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        let principal = try #require(ProcessUIDMemoryPrincipalSource.production.trustedPrincipal())
        center.memoryOwnerUserIDProvider = { principal.userID }
        let markdown = """
        # 可编辑记忆
        ## 用户偏好
        - 喜欢深色界面
        ## 安全
        - 不把密钥写入记忆
        """
        let preview = try center.previewMemoryMarkdown(Data(markdown.utf8))
        #expect(preview.factCount == 2)
        #expect(preview.selectedScope == nil)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))

        let selected = try center.selectMemoryMarkdownScope(.personal, for: preview)
        #expect(selected.selectedScope == .personal)
        #expect(selected.boundOwnerUserID == principal.userID)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))

        let result = try center.confirmMemoryMarkdownImport(selected)
        #expect(result.added == 2)
        #expect(center.memoryFacts.allSatisfy {
            $0.memoryScope == MemoryScope(sessionID: "test-session", projectID: "test-project")
        })
        #expect(center.memoryFacts.allSatisfy { $0.ownerUserID == principal.userID && $0.visibility == .personal })
    }

    @Test("Markdown 个人作用域缺少本地身份或当前 scope 时拒绝")
    func markdownScopeSelectionFailsClosed() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        let preview = try center.previewMemoryMarkdown(
            Data("## 一般事实\n- 需要明确范围\n".utf8)
        )
        center.memoryOwnerUserIDProvider = nil
        #expect(throws: MemoryMarkdownImportError.invalidScope) {
            try center.selectMemoryMarkdownScope(.personal, for: preview)
        }
        center.memoryScopeProvider = nil
        #expect(throws: MemoryMarkdownImportError.invalidScope) {
            try center.selectMemoryMarkdownScope(.project, for: preview)
        }
        #expect(center.memoryFacts.isEmpty)
    }

    @Test("Markdown 预览源文件变化或当前 scope 变化时拒绝确认且零写入")
    func markdownPreviewRejectsStaleSourceAndScope() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        let sourceURL = dir.appendingPathComponent("memory.md")
        let original = Data("## 一般事实\n- 原始内容\n".utf8)
        try original.write(to: sourceURL, options: .atomic)
        let preview = try center.previewMemoryMarkdown(original, sourceURL: sourceURL)
        let selected = try center.selectMemoryMarkdownScope(.project, for: preview)
        try Data("## 一般事实\n- 被替换内容\n".utf8).write(to: sourceURL, options: .atomic)
        #expect(throws: MemoryMarkdownImportError.sourceChanged) {
            try center.confirmMemoryMarkdownImport(selected)
        }
        #expect(center.memoryFacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))

        try original.write(to: sourceURL, options: .atomic)
        let fresh = try center.previewMemoryMarkdown(original, sourceURL: sourceURL)
        let freshSelected = try center.selectMemoryMarkdownScope(.project, for: fresh)
        center.memoryScopeProvider = {
            MemoryScope(sessionID: "changed-session", projectID: "test-project")
        }
        #expect(throws: MemoryMarkdownImportError.scopeChanged) {
            try center.confirmMemoryMarkdownImport(freshSelected)
        }
        #expect(center.memoryFacts.isEmpty)
    }

    @Test("Markdown 重复导入幂等，冲突和损坏不部分覆盖")
    func markdownImportIsIdempotentAndFailClosed() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        let data = Data("## 一般事实\n- 可重复事实\n".utf8)
        let first = try center.importMemoryMarkdown(data, selecting: .temporary)
        let second = try center.importMemoryMarkdown(data, selecting: .temporary)
        #expect(first == MemoryImportResult(added: 1, skipped: 0))
        #expect(second == MemoryImportResult(added: 0, skipped: 1))
        #expect(center.memoryFacts.count == 1)

        let before = try Data(contentsOf: center.memoryStore.fileURL)
        #expect(throws: MemoryMarkdownCodec.Error.invalidUTF8) {
            try center.importMemoryMarkdown(Data([0xff, 0xfe]), selecting: .project)
        }
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == before)
    }

    @Test("JSON 与 Markdown 都写入真实完成文件并可读回")
    func exportsVerifyCompletedFiles() throws {
        let dir = try makeTempDir()
        let center = makeCenter(dir: dir)
        #expect(center.addMemoryFact("可导出的事实", category: .lesson))
        let jsonURL = dir.appendingPathComponent("exports/memory.json")
        let markdownURL = dir.appendingPathComponent("exports/memory.md")
        let jsonReceipt = try center.exportMemoryJSON(to: jsonURL)
        let markdownReceipt = try center.exportMemoryMarkdown(to: markdownURL)
        #expect(jsonReceipt.format == .json)
        #expect(markdownReceipt.format == .markdown)
        #expect(jsonReceipt.byteCount == (try Data(contentsOf: jsonURL)).count)
        #expect(markdownReceipt.byteCount == (try Data(contentsOf: markdownURL)).count)
        #expect(try JSONDecoder().decode([MemoryFact].self, from: Data(contentsOf: jsonURL)).count == 1)
        #expect(try MemoryMarkdownCodec.decode(Data(contentsOf: markdownURL)).facts.count == 1)
    }

    private func personalPrincipal() -> MemoryTrustedPrincipal {
        MemoryTrustedPrincipal.validated(userID: "test-owner", by: { _ in true })!
    }

    @Test("普通会话的“请记住”存成个人事实，不改写 GLOBAL.md")
    func userTypedPersonalMemoryIsStoredAsPersonalFact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        let principal = personalPrincipal()
        center.memoryTrustedPrincipalProvider = { principal }

        #expect(center.addUserTypedMemory("回答请用简体中文", within: nil, sessionID: "s1") == .personal)
        #expect(center.addUserTypedMemory("回答请用简体中文", within: nil, sessionID: "s1") == .personal)

        let personal = try center.memoryStore.activeFacts().filter { $0.visibility == .personal }
        #expect(personal.count == 1)
        #expect(personal.first?.text == "回答请用简体中文")
        #expect(personal.first?.ownerUserID == "test-owner")
        #expect(center.memoryFileStore.readGlobal().isEmpty)
    }

    @Test("旧版写进 GLOBAL.md 的“我的记忆”段迁成个人事实，剩下默认内容时删回未自定义")
    func legacyPersonalSectionMigratesAndGlobalReturnsToDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        let principal = personalPrincipal()
        center.memoryTrustedPrincipalProvider = { principal }
        try center.memoryFileStore.writeGlobal(
            MemoryInjector.defaultGlobalInstructions + "\n\n【我的记忆】\n- 喜欢简短回答\n- 不要用表情")

        #expect(center.migratePersonalMemorySectionFromGlobal() == 2)

        let texts = Set(try center.memoryStore.activeFacts().filter { $0.visibility == .personal }.map(\.text))
        #expect(texts == ["喜欢简短回答", "不要用表情"])
        #expect(center.memoryFileStore.readGlobal().isEmpty)
        #expect(center.migratePersonalMemorySectionFromGlobal() == 0)
    }

    @Test("用户自己改过的 GLOBAL.md 迁移后保留自定义内容、只去掉“我的记忆”段")
    func customizedGlobalKeepsUserContentAfterMigration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        let principal = personalPrincipal()
        center.memoryTrustedPrincipalProvider = { principal }
        try center.memoryFileStore.writeGlobal("我自己的全局指令\n\n【我的记忆】\n- 偏好深色主题")

        #expect(center.migratePersonalMemorySectionFromGlobal() == 1)
        #expect(center.memoryFileStore.readGlobal() == "我自己的全局指令")
    }
}
