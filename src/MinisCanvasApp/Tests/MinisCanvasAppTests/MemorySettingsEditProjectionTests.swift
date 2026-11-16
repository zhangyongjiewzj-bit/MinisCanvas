import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - W4-SETTINGS-MEMORY-UI-028
//
// D-MEMORY-05 编辑半区接线（SettingsCenter.editMemoryFact）与
// I2-MEMORY-PROJECTION（Memory tab 的快照必须是 activeFacts 投影）。
// 全部用临时目录注入，不触碰 Application Support 真实数据。

@Suite("W4-028 记忆编辑接线与 active 投影")
@MainActor
struct MemorySettingsEditProjectionTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("W4-028-Memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCenter(dir: URL) throws -> SettingsCenter {
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        )
        center.memoryScopeProvider = {
            MemoryScope(sessionID: "test-session", projectID: "test-project")
        }
        // Production provisions this built-in Settings source at composition.
        // The synthetic center must use the same narrow source before submit.
        _ = try center.provisionMemoryCandidateSubmission()
        return center
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    @Test("D-MEMORY-05：编辑经 editMemoryFact 追加修订，投影只呈现新文本")
    func editMemoryFactAppendsRevisionAndRefreshesProjection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)
        #expect(center.addMemoryFact("旧内容") == true)
        guard let original = center.memoryFacts.first else {
            Issue.record("新增后 active 投影缺少条目")
            return
        }
        let originalID = original.id
        let originalRevision = original.revision

        let edited = try center.editMemoryFact(id: originalID, newText: "  新内容  ")

        #expect(edited.id != originalID)
        #expect(edited.text == "新内容")
        #expect(edited.revision == originalRevision + 1)
        #expect(edited.lifecycleState == .active)
        #expect(edited.supersedesFactID == originalID)

        // 列表投影：同一条逻辑记忆只出现一个 active 修订。
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.first?.id == edited.id)
        #expect(center.memoryFacts.first?.text == "新内容")

        // 规范入口不旁路：磁盘上旧修订仍存在（superseded 历史，供审计）。
        let store = MemoryStore(directory: dir)
        let persisted = try store.facts()
        #expect(persisted.count == 2)
        #expect(persisted.first(where: { $0.id == originalID })?.lifecycleState == .superseded)
        // 总数与 active 投影分开记账。
        #expect(center.memoryFactTotalCount == 2)
    }

    @Test("D-MEMORY-05：空文本编辑失败关闭且不改动原条目")
    func editMemoryFactRejectsBlankText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)
        #expect(center.addMemoryFact("保留原样") == true)
        let factID = center.memoryFacts.first!.id

        #expect(throws: MemoryStoreError.emptyFact) {
            try center.editMemoryFact(id: factID, newText: "   \n ")
        }
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.first?.text == "保留原样")
        #expect(try MemoryStore(directory: dir).facts().count == 1)
    }

    @Test("D-MEMORY-05：编辑不存在或非 active 目标以 unknownFact 失败关闭")
    func editMemoryFactRejectsUnknownAndInactiveTargets() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)

        #expect(throws: MemoryStoreError.unknownFact) {
            try center.editMemoryFact(id: "missing-fact", newText: "任何内容")
        }

        #expect(center.addMemoryFact("将被编辑") == true)
        let factID = center.memoryFacts.first!.id
        _ = try center.editMemoryFact(id: factID, newText: "第一版修订")

        // 旧修订已 superseded：对它再编辑必须失败关闭，不得复活历史版本。
        #expect(throws: MemoryStoreError.unknownFact) {
            try center.editMemoryFact(id: factID, newText: "越权改写")
        }
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.first?.text == "第一版修订")
    }

    @Test("D-MEMORY-05：编辑提交核对读取的修订和指纹，旧快照不能重放")
    func editMemoryFactRejectsStaleSnapshotAndReplay() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)
        #expect(center.addMemoryFact("原始记忆") == true)
        let snapshot = try #require(center.memoryFacts.first)
        let store = MemoryStore(directory: dir)

        // 目标仍 active 且修订号相同，但内容指纹不对应磁盘前像。
        let stale = MemoryFact(
            id: snapshot.id,
            text: "过期的读取内容",
            sourceSessionID: snapshot.sourceSessionID,
            createdAt: snapshot.createdAt,
            category: snapshot.category,
            memoryScope: snapshot.memoryScope,
            ownerUserID: snapshot.ownerUserID,
            sourceProposalID: snapshot.sourceProposalID,
            sourceRef: snapshot.sourceRef,
            contentDigest: snapshot.contentDigest,
            revision: snapshot.revision,
            supersedesFactID: snapshot.supersedesFactID,
            lifecycleState: snapshot.lifecycleState,
            activatedAt: snapshot.activatedAt
        )
        #expect(throws: MemoryStoreError.concurrentMutation) {
            try center.commitMemoryFactEdit(id: snapshot.id, text: "不应写入", expected: stale)
        }
        #expect(try store.facts() == [snapshot])

        let edited = try center.commitMemoryFactEdit(id: snapshot.id, text: "更新后的记忆", expected: snapshot)
        let afterFirstCommit = try store.facts()
        #expect(edited.revision == snapshot.revision + 1)
        #expect(afterFirstCommit.count == 2)
        #expect(throws: MemoryStoreError.invalidRevision) {
            try center.commitMemoryFactEdit(id: snapshot.id, text: "重复提交", expected: snapshot)
        }
        #expect(try store.facts() == afterFirstCommit)
    }

    @Test("I2-MEMORY-PROJECTION：快照读取 active 投影，删除条目不得出现")
    func reloadStorageBindsActiveProjectionOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)
        #expect(center.addMemoryFact("保留") == true)
        #expect(center.addMemoryFact("删除") == true)
        let doomedID = center.memoryFacts.first(where: { $0.text == "删除" })!.id

        let preview = try center.previewMemoryFactDeletion(id: doomedID)
        _ = try center.removeMemoryFact(id: doomedID, intent: confirmed(preview))

        center.reloadStorage()
        #expect(center.memoryFacts.allSatisfy { $0.lifecycleState == .active })
        #expect(center.memoryFacts.contains { $0.id == doomedID } == false)
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFactTotalCount == 1)

        // 编辑产生的 superseded 历史同样不得回流到投影。
        let keptID = center.memoryFacts.first!.id
        _ = try center.editMemoryFact(id: keptID, newText: "更新后的保留")
        #expect(center.memoryFacts.count == 1)
        #expect(center.memoryFacts.first?.text == "更新后的保留")
        #expect(center.memoryFactTotalCount == 2)
    }

    @Test("编辑后重启等价：新 Store 读回的 active 投影与设置页一致")
    func editedProjectionSurvivesStoreReopen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = try makeCenter(dir: dir)
        #expect(center.addMemoryFact("重启前旧值", category: .userPref) == true)
        let factID = center.memoryFacts.first!.id
        _ = try center.editMemoryFact(id: factID, newText: "重启前新值")

        let reopened = try makeCenter(dir: dir)
        reopened.reloadStorage()
        #expect(reopened.memoryFacts.count == 1)
        #expect(reopened.memoryFacts.first?.text == "重启前新值")
        #expect(reopened.memoryFacts.first?.category == .userPref)
        #expect(reopened.memoryFactTotalCount == 2)
    }
}
