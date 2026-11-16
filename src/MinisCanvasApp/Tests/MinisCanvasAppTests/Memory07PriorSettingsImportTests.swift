import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@MainActor
struct Memory07PriorSettingsImportTests {
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

    @Test("Temporary Markdown 的真实 JSON 导出同 scope 回导保留生命周期且幂等")
    func temporaryMarkdownJSONRoundTripPreservesAllMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        let imported = try center.importMemoryMarkdown(
            Data("## 一般事实\n- 合成临时回导事实\n".utf8), selecting: .temporary)
        #expect(imported == MemoryImportResult(added: 1, skipped: 0))
        let original = try center.memoryStore.facts()
        let fact = try #require(original.first)
        #expect(fact.visibility == .temporary)
        #expect(fact.temporaryLifetimeID == "session:test-session")
        let exported = try center.exportMemoryJSON()
        #expect(try JSONDecoder().decode([MemoryFact].self, from: exported) == original)
        let before = try Data(contentsOf: center.memoryStore.fileURL)

        let first = try center.importMemoryJSON(exported)
        let receiptCount = try center.memoryProposalConsumer.restoreReceipts().count
        let second = try center.importMemoryJSON(exported)
        #expect(first == MemoryImportResult(added: 0, skipped: 1))
        #expect(second == MemoryImportResult(added: 0, skipped: 1))
        #expect(try center.memoryStore.facts() == original)
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == before)
        #expect(try center.memoryProposalConsumer.restoreReceipts().count == receiptCount)
    }

    @Test("真实批准来源的 JSON 回导保真，跨 scope 不抹来源或重签")
    func approvedProvenanceJSONRoundTripRejectsForeignRebinding() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)
        let scope = MemoryScope(sessionID: "test-session", projectID: "test-project")
        let grant = try center.provisionMemoryCandidateSubmission()
        let origin = MemoryWriteProvenanceInput(actorID: "owned-memory-import-user",
            runID: "owned-memory-import-run", triggerID: "owned-memory-import-input",
            sourceID: grant.sourceID)
        let proposed = try center.memoryProposalConsumer.submit(
            text: "合成已批准来源事实", within: scope,
            sourceRef: "synthetic://memory-json-roundtrip", sourceID: grant.sourceID,
            writeProvenance: origin)
        try center.approveDisplayedMemoryProposal(proposed)
        let original = try center.memoryStore.facts()
        let fact = try #require(original.first)
        #expect(fact.writeProvenance != nil)
        let exported = try center.exportMemoryJSON()
        #expect(try JSONDecoder().decode([MemoryFact].self, from: exported) == original)
        let before = try Data(contentsOf: center.memoryStore.fileURL)
        let first = try center.importMemoryJSON(exported)
        let receiptCount = try center.memoryProposalConsumer.restoreReceipts().count
        let second = try center.importMemoryJSON(exported)
        #expect(first == MemoryImportResult(added: 0, skipped: 1))
        #expect(second == MemoryImportResult(added: 0, skipped: 1))
        #expect(try center.memoryStore.facts() == original)
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == before)
        #expect(try center.memoryProposalConsumer.restoreReceipts().count == receiptCount)

        let foreignDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignDir) }
        let foreign = makeCenter(dir: foreignDir)
        foreign.memoryScopeProvider = {
            MemoryScope(sessionID: "foreign-session", projectID: "foreign-project")
        }
        let priorReceipts = try foreign.memoryProposalConsumer.restoreReceipts()
        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            try foreign.importMemoryJSON(exported)
        }
        #expect(try foreign.memoryStore.facts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: foreign.memoryStore.fileURL.path))
        #expect(try foreign.memoryProposalConsumer.restoreReceipts() == priorReceipts)
    }

    private func makeCenter(dir: URL, provisionSettings: Bool = true) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let defaults = UserDefaults(suiteName: "memory07-prior-" + dir.lastPathComponent)!
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir, keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: dir),
            memoryFileStore: MemoryFileStore(directory: dir.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            usageStore: UsageStore(domain: .suite("memory07-prior-" + dir.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: dir.appendingPathComponent("readiness"))
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
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let url = formal.rootDirectory
            .appendingPathComponent("MemoryMgmt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
