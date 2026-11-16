import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - F14 P1-3 备份导入/导出接入测试（SettingsCenter UI 接线层）
//
// 验证目标：
// 1. 导出 → 导入往返：exportBackup 落盘文件，importBackup 恢复后数据一致；
// 2. 部分域写盘失败时错误传播到 UI 层（isError=true + 中文摘要点名失败域，
//    不再静默吞错），成功域数据照常生效；
// 3. 中文摘要内容（summaryMessage 三种形态 + 条目级明细）。
//
// 全部用临时目录注入，不触碰 Application Support 真实数据。

@Suite("F14 P1-3 备份导入/导出")
@MainActor
struct F14BackupTests {

    /// 临时目录注入的 SettingsCenter（含独立 skillStore 根）。
    private func makeCenter(dir: URL) -> SettingsCenter {
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
        return center
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("F14Backup-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 导出 → 导入往返

    @Test func exportImportRoundTrip() throws {
        let srcDir = try makeTempDir("RT-src")
        let dstDir = try makeTempDir("RT-dst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        // 源：造会话 + 记忆 + 设置改动
        let src = makeCenter(dir: srcDir)
        try src.sessionStore.createSession(id: "rt-1", title: "往返会话")
        try src.memoryStore.addFact("往返记忆", sourceSessionID: "rt-1")
        src.settingsStore.update(\.storage.sessionRetentionDays, to: 90)
        src.reloadStorage()

        // 导出备份到文件
        let fileURL = srcDir.appendingPathComponent("backup.minissync")
        let exportResult = src.exportBackup(to: fileURL)
        #expect(!exportResult.isError)
        #expect(exportResult.message.contains("backup.minissync"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        // 目标：全新空 center，导入后数据一致
        let dst = makeCenter(dir: dstDir)
        #expect(dst.sessions.isEmpty)
        #expect(dst.memoryFacts.isEmpty)

        let importResult = dst.importBackup(from: fileURL)
        #expect(!importResult.isError, "往返导入不应失败：\(importResult.message)")
        // 成功摘要 = summaryMessage 中文形态
        #expect(importResult.message == "导入成功：会话、记忆、技能、设置")
        // UI 快照已刷新（导入后会话/记忆计数即时更新）
        #expect(dst.sessions.map(\.id) == ["rt-1"])
        #expect(dst.memoryFacts.map(\.text) == ["往返记忆"])
        #expect(dst.settingsStore.settings.storage.sessionRetentionDays == 90)
    }

    @Test func protectedExportDraftAndAtomicImportRoundTrip() async throws {
        let srcDir = try makeTempDir("Protected-src")
        let dstDir = try makeTempDir("Protected-dst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        let src = makeCenter(dir: srcDir)
        try src.sessionStore.createSession(id: "protected-1", title: "受保护会话")
        src.reloadStorage()
        let fileURL = srcDir.appendingPathComponent("protected.minissync")
        let password = "correct horse battery staple"
        let exportResult = await src.exportBackupAsync(
            to: fileURL,
            protection: .password(password)
        )
        #expect(!exportResult.isError, "受保护导出不应失败：\(exportResult.message)")

        let dst = makeCenter(dir: dstDir)
        let draft = try await dst.readAtomicBackupDraftAsync(
            from: fileURL,
            protection: .password(password)
        )
        let preview = try dst.previewAtomicBackup(
            draft,
            selecting: [.sessions, .settings],
            memoryScope: nil
        )
        let receipt = try await dst.confirmAtomicBackup(
            draft,
            preview: preview,
            confirmation: SyncAtomicImportConfirmation(preview: preview)
        )
        #expect(receipt.committed)
        #expect(receipt.reopenRequired)
        // 候选的原子导入合同：提交后本进程持久层进入 reopenRequired，UI 保持
        // 导入前视图并要求重启。因此断言磁盘真实状态而不是同进程读取。
        #expect(dst.atomicBackupReopenRequired)
        let importedSession = dstDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("protected-1.json")
        let importedData = try Data(contentsOf: importedSession)
        let importedObject = try #require(
            JSONSerialization.jsonObject(with: importedData) as? [String: Any]
        )
        #expect(importedObject["title"] as? String == "受保护会话")
    }

    @Test func protectedDraftWrongPasswordDoesNotPublishOrWrite() async throws {
        let srcDir = try makeTempDir("Protected-failure-src")
        let dstDir = try makeTempDir("Protected-failure-dst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        let src = makeCenter(dir: srcDir)
        try src.sessionStore.createSession(id: "protected-failure", title: "不会写入")
        let fileURL = srcDir.appendingPathComponent("protected.minissync")
        let exportResult = await src.exportBackupAsync(
            to: fileURL,
            protection: .password("correct horse battery staple")
        )
        #expect(!exportResult.isError)

        let dst = makeCenter(dir: dstDir)
        await #expect(throws: SyncProtectionError.wrongPasswordOrCorrupt) {
            try await dst.readAtomicBackupDraftAsync(
                from: fileURL,
                protection: .password("wrong password value")
            )
        }
        #expect(dst.sessions.isEmpty)
    }

    // MARK: - 部分域失败：错误传播到 UI 层（不静默吞）

    @Test func importPartialFailureSurfacesErrorToUI() throws {
        let srcDir = try makeTempDir("PF-src")
        let dstDir = try makeTempDir("PF-dst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        // 源：导出含会话 + 记忆的快照
        let src = makeCenter(dir: srcDir)
        try src.sessionStore.createSession(id: "pf-1", title: "失败演练")
        try src.memoryStore.addFact("能恢复的记忆", sourceSessionID: "pf-1")
        let fileURL = srcDir.appendingPathComponent("backup.minissync")
        #expect(!src.exportBackup(to: fileURL).isError)

        // 目标：sessions 目录位置放普通文件 → 会话域写盘必然失败
        try Data("x".utf8).write(to: dstDir.appendingPathComponent("sessions"))
        let dst = makeCenter(dir: dstDir)

        let result = dst.importBackup(from: fileURL)
        // 错误传播到 UI 层：isError=true（不再静默返回成功）
        #expect(result.isError)
        // 中文摘要点名失败域与成功域（summaryMessage 部分失败形态）
        #expect(result.message.contains("会话"), "消息应点名失败域：\(result.message)")
        #expect(result.message.contains("导入失败"), "消息应含「导入失败」：\(result.message)")
        #expect(result.message.contains("记忆"), "消息应点名成功域：\(result.message)")
        // 条目级明细：失败会话 id + 原因
        #expect(result.message.contains("pf-1"), "消息应含失败条目 id：\(result.message)")
        // 成功域数据真实生效（尽力恢复语义）
        #expect(dst.memoryFacts.map(\.text) == ["能恢复的记忆"])
        #expect(dst.sessions.isEmpty)
    }

    @Test func importBadFileSurfacesValidationMessage() throws {
        let dir = try makeTempDir("BadFile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = makeCenter(dir: dir)

        // 完全不是快照的文件 → 中文校验说明，isError=true，不崩溃不吞错
        let badURL = dir.appendingPathComponent("bad.minissync")
        try Data("这不是快照".utf8).write(to: badURL)
        let result = center.importBackup(from: badURL)
        #expect(result.isError)
        #expect(result.message.hasPrefix("导入失败"), "消息应为中文失败说明：\(result.message)")
        // 不存在的文件 → 同样报错（底层读文件失败）
        let missing = dir.appendingPathComponent("missing.minissync")
        #expect(center.importBackup(from: missing).isError)
    }

    // MARK: - 中文摘要内容（summaryMessage 形态，UI 层直读）

    @Test func summaryMessageChineseForms() {
        // 全部成功
        let allOK = SyncImportResult(
            manifest: SyncManifest(deviceName: "T", scopes: ["sessions", "memories", "skills", "settings"]),
            scopeResults: [
                SyncScopeResult(scope: .sessions, succeeded: true, failures: []),
                SyncScopeResult(scope: .memories, succeeded: true, failures: []),
                SyncScopeResult(scope: .skills, succeeded: true, failures: []),
                SyncScopeResult(scope: .settings, succeeded: true, failures: []),
            ]
        )
        #expect(allOK.summaryMessage == "导入成功：会话、记忆、技能、设置")

        // 部分失败（会话/技能成功，记忆失败）
        let partial = SyncImportResult(
            manifest: SyncManifest(deviceName: "T", scopes: ["sessions", "memories", "skills"]),
            scopeResults: [
                SyncScopeResult(scope: .sessions, succeeded: true, failures: []),
                SyncScopeResult(
                    scope: .memories, succeeded: false,
                    failures: [SyncScopeFailure(item: "facts.json", reason: "磁盘已满")]
                ),
                SyncScopeResult(scope: .skills, succeeded: true, failures: []),
            ]
        )
        #expect(partial.summaryMessage == "会话、技能 导入成功；记忆 导入失败")
        #expect(partial.failedScopes == [.memories])

        // 全部失败
        let allBad = SyncImportResult(
            manifest: SyncManifest(deviceName: "T", scopes: ["sessions"]),
            scopeResults: [
                SyncScopeResult(
                    scope: .sessions, succeeded: false,
                    failures: [SyncScopeFailure(item: "s-1", reason: "无法写入")]
                ),
            ]
        )
        #expect(allBad.summaryMessage == "导入失败：会话")

        // SyncImportError.message 含条目级原因（UI 层 importFailureDetail 的原料）
        let errorMessage = SyncImportError(result: partial).message
        #expect(errorMessage.contains("记忆"))
        #expect(errorMessage.contains("facts.json"))
        #expect(errorMessage.contains("磁盘已满"))
    }
}


extension F14BackupTests {
    /// Observe the actual injected stores and isolate registration from public
    /// Layout validation. These diagnostics never change admission or assertions.
    private func observeAtomicPrerequisites(_ center: SettingsCenter, label: String) throws {
        let registration = Mirror(reflecting: center.syncManager).children
            .first(where: { $0.label == "atomicProfileRegistered" })?.value as? Bool
        let inputs: [(String, URL)] = [
            ("session", center.sessionStore.directory), ("memory", center.memoryStore.directory),
            ("settings", center.settingsStore.directory), ("skills", center.skillStore.skillsRoot)
        ]
        for (name, url) in inputs {
            print("F05_ATOMIC_PREREQUISITE label=\(label) stage=input domain=\(name) fileURL=\(url.isFileURL) path=\(url.path) standardized=\(url.standardizedFileURL.path) resolved=\(url.resolvingSymlinksInPath().path)")
        }
        print("F05_ATOMIC_PREREQUISITE label=\(label) stage=profile observedRegistration=\(String(describing: registration))")
        let layout: SyncAtomicImport.Layout
        do {
            layout = try SyncAtomicImport.Layout(sessionDirectory: center.sessionStore.directory,
                                                  memoryDirectory: center.memoryStore.directory,
                                                  settingsDirectory: center.settingsStore.directory,
                                                  skillsRoot: center.skillStore.skillsRoot)
            print("F05_ATOMIC_PREREQUISITE label=\(label) stage=layout result=PASS domains=\(layout.domains)")
        } catch {
            print("F05_ATOMIC_PREREQUISITE label=\(label) stage=layout result=REJECT error=\(error)")
            throw error
        }
        do {
            _ = try SyncAtomicImport(manager: center.syncManager)
            print("F05_ATOMIC_PREREQUISITE label=\(label) stage=importer result=PASS")
        } catch {
            print("F05_ATOMIC_PREREQUISITE label=\(label) stage=importer result=REJECT layoutAlreadyAccepted=true error=\(error)")
            throw error
        }
    }
    @Test func atomicPreviewConsumesRealManifestCountsAndConflictsWithoutWrites() throws {
        let sourceRoot = try makeTempDir("preview-source"); let targetRoot = try makeTempDir("preview-target")
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }
        let source = makeCenter(dir: sourceRoot); let target = makeCenter(dir: targetRoot)
        try observeAtomicPrerequisites(target, label: "full-preview-target")
        let scope = MemoryScope(sessionID: "test-session", projectID: "test-project")
        for id in ["shared", "source-only"] { _ = try source.sessionStore.createSession(id: id, title: "backup " + id) }
        for id in ["shared", "keep-only"] { _ = try target.sessionStore.createSession(id: id, title: "existing " + id) }
        _ = try source.memoryStore.addFact("backup fact", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try target.memoryStore.addFact("old fact", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try target.memoryStore.addFact("other scope", sourceSessionID: "other", memoryScope: .init(sessionID: "other", projectID: "other-project"))
        for name in ["Shared Skill", "Source Only"] { _ = try source.skillStore.importSkill(content: "---\nname: \(name)\ndescription: preview\n---\nbackup") }
        for name in ["Shared Skill", "Keep Only"] { _ = try target.skillStore.importSkill(content: "---\nname: \(name)\ndescription: preview\n---\nexisting") }
        let raw = try source.syncManager.exportSnapshot()
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var manifest = try #require(object["manifest"] as? [String: Any])
        let exportedAt = Date(timeIntervalSinceReferenceDate: 123_456)
        manifest["deviceName"] = "工作室 Mac"; manifest["exportedAt"] = exportedAt.timeIntervalSinceReferenceDate; object["manifest"] = manifest
        let file = sourceRoot.appendingPathComponent("preview.minissync"); try JSONSerialization.data(withJSONObject: object).write(to: file)
        func bytes(_ root: URL) throws -> [String: Data] {
            var result: [String: Data] = [:]
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in files where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { result[url.path] = try Data(contentsOf: url) }
            return result
        }
        let before = try bytes(targetRoot); target.syncManager.markDirty(.settings)
        let draft = try target.readAtomicBackupDraft(from: file)
        #expect(draft.manifest.deviceName == "工作室 Mac" && draft.manifest.exportedAt == exportedAt)
        #expect(draft.sourceCounts == [.sessions: 2, .memories: 1, .skills: 2, .settings: 1])
        let sheet = AtomicBackupImportSheet(center: target, draft: draft)
        #expect(sheet.displayedMetadata.contains("版本：v1"))
        #expect(sheet.displayedMetadata.contains("来源设备：工作室 Mac"))
        #expect(sheet.displayedMetadata.contains("导出时间：" + exportedAt.formatted(date: .abbreviated, time: .standard)))
        #expect(sheet.sourceSummary(for: .sessions) == "会话：2项")
        #expect(sheet.sourceSummary(for: .settings) == "设置：1组")
        let preview = try target.previewAtomicBackup(draft, selecting: Set(SyncScope.allCases), memoryScope: scope)
        #expect(preview.domains.map(\.scope) == SyncScope.allCases)
        for domain in preview.domains {
            #expect(domain.incomingCount == draft.sourceCounts[domain.scope])
            #expect(domain.overlappingCount == 1)
            #expect(!AtomicBackupImportSheet.overwriteSemantics(for: domain.scope).isEmpty)
            #expect(!AtomicBackupImportSheet.conflictSummary(domain).isEmpty)
            if domain.scope != .settings { #expect(domain.retainedCount == 1) }
        }
        #expect(AtomicBackupImportSheet.overwriteSemantics(for: .memories).contains("其他范围保留"))
        let selected = try target.previewAtomicBackup(draft, selecting: [.settings], memoryScope: nil)
        #expect(selected.selected == [.settings] && selected.domains.map(\.scope) == [.settings])
        #expect(try bytes(targetRoot) == before)
        #expect(target.syncManager.dirtyScopes == [.settings])
        #expect(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent(".minis-sync-import-v1").path))
        // Discarding both previews is cancellation; it has no confirm side effect.
        #expect(!target.atomicBackupInProgress && !target.atomicBackupReopenRequired)
    }

    @Test func atomicPreviewMissingMetadataIsExplicitAndNeverFabricated() throws {
        let root = try makeTempDir("missing-metadata"); defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(dir: root)
        let data = try center.syncManager.exportSnapshot(scopes: [.settings])
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var manifest = try #require(object["manifest"] as? [String: Any])
        manifest.removeValue(forKey: "deviceName"); manifest.removeValue(forKey: "exportedAt"); object["manifest"] = manifest
        let file = root.appendingPathComponent("old.minissync"); try JSONSerialization.data(withJSONObject: object).write(to: file)
        let before = try Data(contentsOf: center.settingsStore.fileURL)
        #expect(throws: SettingsCenter.AtomicBackupMetadataError.missingFields(["来源设备", "导出时间"])) { try center.readAtomicBackupDraft(from: file) }
        #expect(try Data(contentsOf: center.settingsStore.fileURL) == before)
        try data.write(to: file)
        let valid = try center.readAtomicBackupDraft(from: file)
        #expect(AtomicBackupImportSheet(center: center, draft: valid).sourceSummary(for: .memories) == "记忆：未包含")
        #expect(valid.sourceCounts == [.settings: 1])
    }

    @Test func atomicProductionPreviewCommitPublishesReopenStateAndPreservesOldFacade() async throws {
        let sourceRoot = try makeTempDir("atomic-source").resolvingSymlinksInPath()
        let targetRoot = try makeTempDir("atomic-target").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }
        let source = makeCenter(dir: sourceRoot); let target = makeCenter(dir: targetRoot)
        try observeAtomicPrerequisites(target, label: "commit-target")
        let before = target.settingsStore.settings.storage.sessionRetentionDays
        _ = source.settingsStore.update(\.storage.sessionRetentionDays, to: 79)
        let data = try source.syncManager.exportSnapshot(scopes: [.settings])
        let file = sourceRoot.appendingPathComponent("atomic.minissync")
        try data.write(to: file)
        let draft = try target.readAtomicBackupDraft(from: file)
        target.syncManager.markDirty(.settings)
        let preview = try target.previewAtomicBackup(draft, selecting: [.settings], memoryScope: nil)
        #expect(target.settingsStore.settings.storage.sessionRetentionDays == before)
        #expect(target.syncManager.dirtyScopes == [.settings])
        let receipt = try await target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        #expect(receipt.committed && receipt.reopenRequired)
        #expect(target.atomicBackupReopenRequired && !target.atomicBackupInProgress)
        #expect(!target.atomicBackupRecoveryRequired)
        #expect(target.settingsStore.settings.storage.sessionRetentionDays == before)
        let persisted = try SettingsMigration.migrate(data: Data(contentsOf: target.settingsStore.fileURL)).settings
        #expect(persisted.storage.sessionRetentionDays == 79)
        let fresh = SettingsStore(directory: targetRoot)
        #expect(fresh.settings.storage.sessionRetentionDays == before)
        if case .success = fresh.replace(with: .defaults) { Issue.record("new old-process settings object escaped F05 latch") }
    }

    @Test func atomicMissingMemoryScopeRetainsExactDraftAndZeroWrites() throws {
        let sourceRoot = try makeTempDir("atomic-missing-source").resolvingSymlinksInPath()
        let targetRoot = try makeTempDir("atomic-missing-target").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }
        let source = makeCenter(dir: sourceRoot); let target = makeCenter(dir: targetRoot)
        try observeAtomicPrerequisites(target, label: "missing-scope-target")
        let scope = MemoryScope(sessionID: "test-session", projectID: "test-project")
        _ = try source.memoryStore.addFact("explicit scope", sourceSessionID: scope.sessionID, memoryScope: scope)
        let bytes = try source.syncManager.exportSnapshot(scopes: [.memories])
        let file = sourceRoot.appendingPathComponent("memory.minissync"); try bytes.write(to: file)
        let before = try Data(contentsOf: target.settingsStore.fileURL)
        let draft = try target.readAtomicBackupDraft(from: file)
        #expect(throws: SyncAtomicImportError.missingMemoryScope) { try target.previewAtomicBackup(draft, selecting: [.memories], memoryScope: nil) }
        #expect(draft.data == bytes && draft.sourceURL == file)
        #expect(draft.sourceMemoryScopes == [scope])
        #expect(try Data(contentsOf: target.settingsStore.fileURL) == before)
        #expect(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent(".minis-sync-import-v1").path))
        _ = try target.previewAtomicBackup(draft, selecting: [.memories], memoryScope: scope)
    }
}
