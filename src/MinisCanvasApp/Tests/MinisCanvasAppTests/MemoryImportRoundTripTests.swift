import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - P3-MEM-01 记忆导入业务闭环（DEV-217）
//
// 覆盖 JSON 无损回导 round-trip、损坏文件负例与 scope 隔离。全部用临时目录
// 注入，不触碰 Application Support 真实数据；fixture 只使用明显的假值。

@Suite("P3-MEM-01 记忆导入闭环")
@MainActor
struct MemoryImportRoundTripTests {

    private static let exportSession = "session-export-0001"
    private static let importSession = "session-import-0002"
    private static let projectID = "project-alpha"
    private static let otherProject = "project-beta"
    private static let ownerID = "local-owner-fake"

    private func makeCenter(dir: URL, sessionID: String) -> SettingsCenter {
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
            MemoryScope(sessionID: sessionID, projectID: Self.projectID)
        }
        return center
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 一条字段完整的记忆事实（含 provenance/修订/激活时间），用于逐字段比对。
    private func populatedFact(id: String, text: String, supersedes: String?) -> MemoryFact {
        MemoryFact(
            id: id,
            text: text,
            sourceSessionID: "origin-session-fake",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-\(id)",
            sourceRef: "settings://memory/\(id)",
            contentDigest: MemoryStore.contentDigest(for: text),
            revision: supersedes == nil ? 1 : 2,
            supersedesFactID: supersedes,
            lifecycleState: .active,
            activatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    private var fixtureFacts: [MemoryFact] {
        [
            populatedFact(id: "fact-base-0001", text: "导出前写入的第一条记忆", supersedes: nil),
            // 批次内 supersedes 链必须满足持久化不变量：active 事实不得被另一条
            // active 事实取代（MemoryStore.validatePersistedFacts 写/读双侧 fail-closed）。
            // 见 DEV-270-MEMRESTORE raw.log。
            populatedFact(id: "fact-later-0002", text: "导出前写入的第二条记忆", supersedes: nil)
        ]
    }

    /// 无损断言：除 memoryScope（按设计重绑到导入时的 active scope）外，
    /// 每个字段都必须与导出前逐字段一致。
    private func expectLossless(
        _ imported: [MemoryFact],
        matching original: [MemoryFact],
        reboundTo scope: MemoryScope?
    ) {
        let sortedImported = imported.sorted { $0.id < $1.id }
        let sortedOriginal = original.sorted { $0.id < $1.id }
        #expect(sortedImported.count == sortedOriginal.count)
        for (result, source) in zip(sortedImported, sortedOriginal) {
            #expect(result.id == source.id)
            #expect(result.text == source.text)
            #expect(result.sourceSessionID == source.sourceSessionID)
            #expect(result.createdAt == source.createdAt)
            #expect(result.category == source.category)
            #expect(result.ownerUserID == source.ownerUserID)
            #expect(result.sourceProposalID == source.sourceProposalID)
            #expect(result.sourceRef == source.sourceRef)
            #expect(result.contentDigest == source.contentDigest)
            #expect(result.revision == source.revision)
            #expect(result.supersedesFactID == source.supersedesFactID)
            #expect(result.lifecycleState == source.lifecycleState)
            #expect(result.activatedAt == source.activatedAt)
            #expect(result.memoryScope == scope)
        }
    }

    @Test("JSON 导出→回导（同一 scope）：字段逐项一致且不产生重复")
    func jsonExportReimportsLosslesslyWithinSameScope() throws {
        let exportDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let importDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }

        let exporter = makeCenter(dir: exportDir, sessionID: Self.exportSession)
        let payload = try JSONEncoder().encode(fixtureFacts)
        #expect(try exporter.importMemoryJSON(payload) == MemoryImportResult(added: 2, skipped: 0))
        let snapshot = try exporter.exportMemoryJSON()

        // 目标库的 active scope 与导出时完全相同：允许原样重绑，字段不变。
        let importer = makeCenter(dir: importDir, sessionID: Self.exportSession)
        #expect(try importer.importMemoryJSON(snapshot) == MemoryImportResult(added: 2, skipped: 0))
        expectLossless(
            importer.memoryFacts,
            matching: fixtureFacts,
            reboundTo: MemoryScope(sessionID: Self.exportSession, projectID: Self.projectID)
        )

        // 再导出可与原导出逐字节一致（同一 encoder/同一集合）。
        let reexport = try importer.exportMemoryJSON()
        let reexportedFacts = try JSONDecoder().decode([MemoryFact].self, from: reexport).sorted { $0.id < $1.id }
        let snapshotFacts = try JSONDecoder().decode([MemoryFact].self, from: snapshot).sorted { $0.id < $1.id }
        #expect(reexportedFacts == snapshotFacts)

        // 同一文件重复导入走幂等 receipt，不新增条目。
        #expect(try importer.importMemoryJSON(snapshot) == MemoryImportResult(added: 0, skipped: 2))
        #expect(try importer.memoryProposalConsumer.restoreReceipts().count == 1)
        #expect(try importer.memoryStore.facts().count == 2)
    }

    @Test("JSON 无损回导跨会话：新会话导入旧导出文件成功且仅重绑 scope")
    func jsonExportReimportsIntoNewerSession() throws {
        let exportDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let importDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }

        let exporter = makeCenter(dir: exportDir, sessionID: Self.exportSession)
        let payload = try JSONEncoder().encode(fixtureFacts)
        #expect(try exporter.importMemoryJSON(payload).added == 2)
        // 导出文件里的 memoryScope 固定携带导出时的会话 UUID。
        let exported = try exporter.exportMemoryJSON()
        let exportedFacts = try JSONDecoder().decode([MemoryFact].self, from: exported)
        #expect(exportedFacts.allSatisfy {
            $0.memoryScope == MemoryScope(sessionID: Self.exportSession, projectID: Self.projectID)
        })

        // 回归：切换会话后回导同一文件，此前整批 scopeMismatch 失败。
        let importer = makeCenter(dir: importDir, sessionID: Self.importSession)
        #expect(try importer.importMemoryJSON(exported) == MemoryImportResult(added: 2, skipped: 0))
        expectLossless(
            importer.memoryFacts,
            matching: fixtureFacts,
            reboundTo: MemoryScope(sessionID: Self.importSession, projectID: Self.projectID)
        )
        // 内容级等价：owner 与 provenance 不因重绑而丢失。
        #expect(importer.memoryFacts.allSatisfy { $0.ownerUserID == Self.ownerID })
        #expect(importer.memoryFacts.allSatisfy {
            MemoryStore.contentDigest(for: $0.text) == $0.contentDigest
        })
    }

    @Test("损坏 JSON 文件 fail-closed：抛错、零写入、原文件不变")
    func corruptJSONImportsFailClosed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir, sessionID: Self.exportSession)

        // 语法损坏的 JSON。
        #expect(throws: (any Error).self) {
            try center.importMemoryJSON(Data("{ not-json".utf8))
        }
        // 顶层不是数组。
        #expect(throws: (any Error).self) {
            try center.importMemoryJSON(Data(#"{"facts":[]}"#.utf8))
        }
        // 空文本条目。
        let blankText = try JSONEncoder().encode([MemoryFact(text: "   ")])
        #expect(throws: MemoryProposalConsumerError.invalidText) {
            try center.importMemoryJSON(blankText)
        }
        // 空 ID 条目。
        let blankID = try JSONEncoder().encode([
            MemoryFact(id: "  ", text: "有效文本但缺 ID")
        ])
        #expect(throws: MemoryProposalConsumerError.invalidProposalID) {
            try center.importMemoryJSON(blankID)
        }
        // 全部失败路径：事实文件从未被创建，列表保持真空。
        #expect(center.memoryFacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))

        // 成功导入一次后，损坏输入不得触碰已持久化字节。
        let payload = try JSONEncoder().encode(fixtureFacts)
        #expect(try center.importMemoryJSON(payload).added == 2)
        let before = try Data(contentsOf: center.memoryStore.fileURL)
        #expect(throws: (any Error).self) {
            try center.importMemoryJSON(Data("[truncated".utf8))
        }
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == before)
        #expect(center.memoryFacts.count == 2)
    }

    @Test("scope 隔离：回导不改写他 scope 事实，稳定 ID 跨 scope 冲突 fail-closed")
    func reimportPreservesScopeIsolation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir, sessionID: Self.exportSession)

        let payload = try JSONEncoder().encode(fixtureFacts)
        #expect(try center.importMemoryJSON(payload).added == 2)
        let scopeA = MemoryScope(sessionID: Self.exportSession, projectID: Self.projectID)
        #expect(try center.memoryStore.facts().allSatisfy { $0.memoryScope == scopeA })
        let before = try Data(contentsOf: center.memoryStore.fileURL)

        // 同一存储、不同 active scope 下重放同一文件：稳定 ID 命中他 scope 事实，
        // 必须报冲突并零写入，而不是静默覆盖或串用别的项目/会话记忆。
        center.memoryScopeProvider = {
            MemoryScope(sessionID: Self.importSession, projectID: Self.otherProject)
        }
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            try center.importMemoryJSON(payload)
        }
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == before)
        let persisted = try center.memoryStore.facts()
        #expect(persisted.count == 2)
        #expect(persisted.allSatisfy { $0.memoryScope == scopeA })

        // 切回原 scope 的幂等重放仍然成功（不受失败尝试污染）。
        center.memoryScopeProvider = { scopeA }
        #expect(try center.importMemoryJSON(payload) == MemoryImportResult(added: 0, skipped: 2))
        #expect(try center.memoryStore.facts() == persisted)
    }

    @Test("JSON 文件晚到时切换会话或项目不得重定向导入")
    func delayedJSONFileReadKeepsSelectedScope() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir, sessionID: Self.exportSession)
        let selected = MemoryScope(sessionID: Self.exportSession, projectID: Self.projectID)
        var current = selected
        center.memoryScopeProvider = { current }
        let file = dir.appendingPathComponent("selected-import.json")
        try JSONEncoder().encode([
            MemoryFact(id: "delayed-import-fact", text: "合成迟到文件")
        ]).write(to: file)

        // The save/open panel selected this exact scope before the background
        // read. A new session in the same project is still a different target.
        current = MemoryScope(sessionID: Self.importSession, projectID: Self.projectID)
        let decoded = try JSONDecoder().decode([MemoryFact].self, from: Data(contentsOf: file))
        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            try center.importMemoryFactsThrowing(decoded, expectedScope: selected)
        }
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))
        #expect(try center.memoryProposalConsumer.restoreReceipts().isEmpty)

        // A different project ID also cannot substitute the selected scope.
        current = MemoryScope(sessionID: Self.importSession, projectID: Self.otherProject)
        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            try center.importMemoryFactsThrowing(decoded, expectedScope: selected)
        }
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))

        // Returning to the selected scope retains the legitimate positive path.
        current = selected
        #expect(try center.importMemoryFactsThrowing(decoded, expectedScope: selected)
            == MemoryImportResult(added: 1, skipped: 0))
        #expect(try center.memoryStore.facts().count == 1)
        #expect(try center.memoryStore.facts().first?.memoryScope == selected)
    }
}
