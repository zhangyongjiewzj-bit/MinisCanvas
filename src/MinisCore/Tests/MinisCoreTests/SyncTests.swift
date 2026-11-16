import Foundation
import Testing
@testable import MinisCore

// D8 同步与后台能力测试：
// - 快照导出/导入往返（sessions+memories+settings 恢复一致）
// - skills 往返（id -> SKILL.md 原文）
// - manifest 校验（版本不匹配 / scope 不完整 / dirty 标记）
// - TaskScheduler 注册/启停/手动触发（短间隔 mock 验证真实触发）

/// 每个测试独立的临时目录（测试并行执行，绝不共享路径）。
private func makeTempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 线程安全计数器（@Sendable 闭包里用）。
private actor Counter {
    private var value = 0
    func increment() { value += 1 }
    func get() -> Int { value }
}

struct SyncTests {

    // MARK: - 快照导出/导入往返

    @Test func snapshotRoundTripSessionsMemoriesSettings() throws {
        let srcDir = try makeTempDir("SyncRoundTrip")
        let dstDir = try makeTempDir("SyncRoundTrip")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        // 源：造数据
        let srcSessions = SessionStore(directory: srcDir)
        let srcMemories = MemoryStore(directory: srcDir)
        let srcSettings = SettingsStore(directory: srcDir)
        let srcSkills = SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true))

        var session = try srcSessions.createSession(id: "s-1", title: "第一次对话")
        session.messages = [
            LLMMessage(role: .user, content: "你好，MinisCanvas"),
            LLMMessage(role: .assistant, content: "你好！我是你的 AI 助手。")
        ]
        try srcSessions.updateSession(session)
        try srcSessions.createSession(id: "s-2", title: "画布讨论")

        let memoryScope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        try srcMemories.addFact(
            "用户喜欢晴天",
            sourceSessionID: "s-1",
            memoryScope: memoryScope
        )
        try srcMemories.addFact(
            "项目叫 MinisCanvas",
            sourceSessionID: "s-1",
            category: .userPref,
            memoryScope: memoryScope
        )

        srcSettings.update(\.general.defaultProviderID, to: "gimage2")
        srcSettings.update(\.general.language, to: "en")
        srcSettings.update(\.storage.sessionRetentionDays, to: 60)
        #expect(srcSettings.settings.agent.browserWriteEnabled)

        let manager = SyncManager(
            sessionStore: srcSessions,
            memoryStore: srcMemories,
            skillStore: srcSkills,
            settingsStore: srcSettings,
            deviceName: "TestMac"
        )

        // 导出（sessions + memories + settings）
        let data = try manager.exportSnapshot(scopes: [.sessions, .memories, .settings])
        #expect(!data.isEmpty)

        // 目标：全新空 store，导入后应与源一致
        let dstSessions = SessionStore(directory: dstDir)
        let dstMemories = MemoryStore(directory: dstDir)
        let dstSettings = SettingsStore(directory: dstDir)
        let dstSkills = SkillStore(skillsRoot: dstDir.appendingPathComponent("skills", isDirectory: true))

        #expect(dstSessions.listSessions().isEmpty)
        #expect(try dstMemories.facts().isEmpty)

        let importer = SyncManager(
            sessionStore: dstSessions,
            memoryStore: dstMemories,
            skillStore: dstSkills,
            settingsStore: dstSettings,
            deviceName: "ImporterMac"
        )
        let result = try importer.importSnapshot(data, memoryScope: memoryScope)
        #expect(result.allSucceeded)
        #expect(result.failedScopes.isEmpty)
        let manifest = result.manifest
        #expect(manifest.version == SyncManifest.currentVersion)
        #expect(manifest.deviceName == "TestMac")
        #expect(Set(manifest.scopes) == ["sessions", "memories", "settings"])

        // 会话一致（按 id 比较）
        let restoredSessions = dstSessions.listSessions()
        #expect(restoredSessions.count == 2)
        for s in restoredSessions {
            let src = srcSessions.loadSession(id: s.id)
            #expect(src != nil)
            #expect(s == src)
        }
        // 消息内容完整
        let restoredS1 = dstSessions.loadSession(id: "s-1")
        #expect(restoredS1?.messages.count == 2)
        #expect(restoredS1?.messages.first?.content == "你好，MinisCanvas")

        // 记忆一致（含 id/createdAt 保真）
        let restoredFacts = try dstMemories.facts()
        let srcFacts = try srcMemories.facts()
        #expect(restoredFacts.count == 2)
        #expect(Set(restoredFacts) == Set(srcFacts))

        // 导入带入全部非权限设置；权限与安全字段保持本机现值（N1，此处本机为默认值）。
        let localBefore = AppSettings.defaults
        var expectedSettings = srcSettings.settings
        expectedSettings = SyncManager.preservingLocalPermissionSettings(imported: expectedSettings, local: localBefore)
        #expect(dstSettings.settings == expectedSettings)
        #expect(dstSettings.settings.agent.browserWriteEnabled == localBefore.agent.browserWriteEnabled)
        #expect(dstSettings.settings.general.defaultProviderID == "gimage2")
        #expect(dstSettings.settings.storage.sessionRetentionDays == 60)
    }

    @Test func importedBackupKeepsLocalChildDeletionAutoReviewSettings() throws {
        let srcDir = try makeTempDir("SyncDeleteAutoSrc")
        let dstDir = try makeTempDir("SyncDeleteAutoDst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }
        let whitelist = ["/usr/local/goal18-sync-a", "/usr/local/goal18-sync-b"]
        let srcSettings = SettingsStore(directory: srcDir)
        srcSettings.update(\.agent.childDeletionAutoReviewWhitelist, to: whitelist)
        srcSettings.update(\.agent.childDeletionAutoReviewEnabled, to: true)
        srcSettings.update(\.agent.toolTimeoutSeconds, to: 41)
        #expect(srcSettings.settings.agent.childDeletionAutoReviewEnabled)

        let exporter = SyncManager(
            sessionStore: SessionStore(directory: srcDir), memoryStore: MemoryStore(directory: srcDir),
            skillStore: SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: srcSettings, deviceName: "Src")
        let data = try exporter.exportSnapshot(scopes: [.settings])

        let dstSettings = SettingsStore(directory: dstDir)
        let importer = SyncManager(
            sessionStore: SessionStore(directory: dstDir), memoryStore: MemoryStore(directory: dstDir),
            skillStore: SkillStore(skillsRoot: dstDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: dstSettings, deviceName: "Dst")
        let result = try importer.importSnapshot(data)
        #expect(result.allSucceeded)
        // N1：包内的自动审核开关与白名单都不导入，保留本机现值（本机为默认）。
        #expect(!dstSettings.settings.agent.childDeletionAutoReviewEnabled)
        #expect(dstSettings.settings.agent.browserWriteEnabled == AgentSettings.default.browserWriteEnabled)
        #expect(dstSettings.settings.agent.childDeletionAutoReviewWhitelist == AgentSettings.default.childDeletionAutoReviewWhitelist)
        #expect(dstSettings.settings.agent.childDeletionAutoReviewWhitelist != whitelist)
        // Other settings keep their normal import semantics.
        #expect(dstSettings.settings.agent.toolTimeoutSeconds == 41)
    }

    @Test func snapshotRoundTripSkills() throws {
        let srcDir = try makeTempDir("SyncSkills")
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let srcSkills = SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true))
        let skillMD = """
        ---
        name: 测试技能
        description: 用于 D8 往返测试
        version: 1.0.0
        ---
        正文内容，保持原样。
        """
        let imported = try srcSkills.importSkill(content: skillMD, source: .file)
        #expect(!srcSkills.skills.isEmpty)

        let srcSessions = SessionStore(directory: srcDir)
        let srcMemories = MemoryStore(directory: srcDir)
        let srcSettings = SettingsStore(directory: srcDir)
        let manager = SyncManager(
            sessionStore: srcSessions,
            memoryStore: srcMemories,
            skillStore: srcSkills,
            settingsStore: srcSettings
        )

        let data = try manager.exportSnapshot(scopes: [.skills])

        // 恢复到同一 root 的全新 SkillStore
        let dstSkills = SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true))
        let dstSessions = SessionStore(directory: srcDir)
        let dstMemories = MemoryStore(directory: srcDir)
        let dstSettings = SettingsStore(directory: srcDir)
        let importer = SyncManager(
            sessionStore: dstSessions,
            memoryStore: dstMemories,
            skillStore: dstSkills,
            settingsStore: dstSettings
        )
        let skillResult = try importer.importSnapshot(data)
        #expect(skillResult.allSucceeded)

        let dstSkill = dstSkills.skills.first { $0.id == imported.id }
        #expect(dstSkill != nil)
        #expect(dstSkill?.body == imported.body)
        #expect(dstSkill?.name == imported.name)
    }

    @Test func protectedSnapshotFileKeepsLegacyApiExplicit() throws {
        let directory = try makeTempDir("SyncProtectedFile")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SyncManager(
            sessionStore: SessionStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: directory),
            deviceName: "ProtectionTestMac"
        )
        let password = "correct horse battery staple"
        let protected = directory.appendingPathComponent("protected.minissync")
        try manager.exportSnapshotFile(to: protected, protection: .password(password))
        #expect(try manager.snapshotProtectionKind(from: protected) == .passwordProtected)
        #expect(throws: SyncProtectionError.protectionRequired) {
            try manager.importSnapshotFile(from: protected)
        }

        let legacy = directory.appendingPathComponent("legacy.minissync")
        try manager.exportSnapshotFile(to: legacy)
        #expect(try manager.snapshotProtectionKind(from: legacy) == .legacyPlaintext)
    }

    // MARK: - Manifest 校验

    @Test func manifestVersionMismatchThrows() throws {
        let dir = try makeTempDir("SyncManifest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        // 手工构造版本不匹配的快照（999 = 未来版本）。编码器用默认
        // 日期策略，与 SyncManager 内部编解码一致。
        let envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(version: 999, deviceName: "Future", scopes: ["sessions"]),
            sessions: []
        )
        let data = try JSONEncoder().encode(envelope)

        #expect(throws: SyncManifestError.unsupportedVersion(expected: 1, found: 999)) {
            try manager.importSnapshot(data)
        }
    }

    @Test func manifestMissingPayloadThrows() throws {
        let dir = try makeTempDir("SyncManifest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        // 清单声明了 skills，但载荷缺 skills → scope 不完整
        let envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(deviceName: "Test", scopes: ["sessions", "skills"]),
            sessions: []
        )
        let data = try JSONEncoder().encode(envelope)

        #expect(throws: SyncManifestError.incompletePayload(["skills"])) {
            try manager.importSnapshot(data)
        }
    }

    @Test func manifestUnknownScopeThrowsWithoutRestore() throws {
        let dir = try makeTempDir("SyncManifest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        var session = try store.createSession(id: "keep", title: "保留")
        session.messages = [LLMMessage(role: .user, content: "hi")]
        try store.updateSession(session)

        let manager = SyncManager(
            sessionStore: store,
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        // 拼写错误的 scope 名（"session" 缺 s）→ 坏快照，必须抛错而非静默
        // 零恢复（静默成功会让用户误以为数据已导入）。
        let envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(deviceName: "Typo", scopes: ["session"]),
            sessions: []
        )
        let data = try JSONEncoder().encode(envelope)

        #expect(throws: SyncManifestError.invalidSnapshot("unknown scopes: [\"session\"]")) {
            try manager.importSnapshot(data)
        }
        // 混合：合法 + 非法 scope 同样整体拒绝，不部分恢复
        let mixed = SyncSnapshotEnvelope(
            manifest: SyncManifest(deviceName: "Typo", scopes: ["sessions", "bogus"]),
            sessions: []
        )
        #expect(throws: SyncManifestError.invalidSnapshot("unknown scopes: [\"bogus\"]")) {
            try manager.importSnapshot(try JSONEncoder().encode(mixed))
        }
        // 失败后未写入任何数据
        #expect(manager.sessionStore.listSessions().map(\.id) == ["keep"])
    }

    @Test func restoringUndeclaredScopeRejectsWithoutClearingExistingFacts() throws {
        let dir = try makeTempDir("SyncRestoreScope")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionStore = SessionStore(directory: dir)
        let memoryStore = MemoryStore(directory: dir)
        let skillStore = SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        let settingsStore = SettingsStore(directory: dir)
        try memoryStore.addFact(
            "现有记忆必须保留",
            sourceSessionID: "existing-session",
            memoryScope: MemoryScope(sessionID: "existing-session", projectID: "project-1")
        )
        let before = try Data(contentsOf: memoryStore.fileURL)

        let manager = SyncManager(
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            skillStore: skillStore,
            settingsStore: settingsStore,
            deviceName: "ImporterMac"
        )
        let snapshot = try makeSnapshotData(scopes: [.sessions])

        #expect(throws: SyncManifestError.missingScopes(["memories"])) {
            try manager.importSnapshot(
                snapshot,
                restoring: [.memories],
                memoryScope: MemoryScope(sessionID: "existing-session", projectID: "project-1")
            )
        }
        #expect(try Data(contentsOf: memoryStore.fileURL) == before)
        #expect(try memoryStore.facts().map(\.text) == ["现有记忆必须保留"])
    }

    @Test func restoringEmptyScopeRejectsWithoutWritingAnyDomain() throws {
        let dir = try makeTempDir("SyncRestoreEmptyScope")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionStore = SessionStore(directory: dir)
        let memoryStore = MemoryStore(directory: dir)
        let skillStore = SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        let settingsStore = SettingsStore(directory: dir)
        var existing = try sessionStore.createSession(id: "keep", title: "保留")
        existing.messages = [LLMMessage(role: .user, content: "不要被空恢复覆盖")]
        try sessionStore.updateSession(existing)
        let sessionURL = sessionStore.sessionsDirectory.appendingPathComponent("keep.json")
        let beforeSessionBytes = try Data(contentsOf: sessionURL)

        let manager = SyncManager(
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            skillStore: skillStore,
            settingsStore: settingsStore,
            deviceName: "ImporterMac"
        )
        let snapshot = try makeSnapshotData(scopes: [.sessions])

        #expect(throws: SyncManifestError.emptyScopes) {
            try manager.importSnapshot(snapshot, restoring: [])
        }
        #expect(try Data(contentsOf: sessionURL) == beforeSessionBytes)
        #expect(sessionStore.listSessions().map(\.id) == ["keep"])
        #expect(try memoryStore.facts().isEmpty)
    }

    @Test func memoryRestoreWithoutActiveScopeFailsClosed() throws {
        let dir = try makeTempDir("SyncMissingMemoryScope")
        defer { try? FileManager.default.removeItem(at: dir) }

        let memoryStore = MemoryStore(directory: dir)
        let scope = MemoryScope(sessionID: "existing-session", projectID: "project-1")
        try memoryStore.addFact(
            "不得被覆盖",
            sourceSessionID: scope.sessionID,
            memoryScope: scope
        )
        let before = try Data(contentsOf: memoryStore.fileURL)
        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: memoryStore,
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )
        let snapshot = try makeSnapshotData(scopes: [.memories])

        do {
            _ = try manager.importSnapshot(snapshot)
            Issue.record("缺少 active memory scope 时必须拒绝记忆恢复")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.memories])
            #expect(error.result.scopeResults.first?.failures.map(\.item) == ["memoryScope"])
        }
        #expect(try Data(contentsOf: memoryStore.fileURL) == before)
        #expect(try memoryStore.facts().map(\.text) == ["不得被覆盖"])
    }

    @Test func repeatedMemoryRestoreIsIdempotent() throws {
        let srcDir = try makeTempDir("SyncRestoreSource")
        let dstDir = try makeTempDir("SyncRestoreDestination")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        let scope = MemoryScope(sessionID: "restore-session", projectID: "project-1")
        let sourceStore = MemoryStore(directory: srcDir)
        try sourceStore.addFact(
            "恢复一次即可",
            sourceSessionID: scope.sessionID,
            memoryScope: scope
        )
        let source = SyncManager(
            sessionStore: SessionStore(directory: srcDir),
            memoryStore: sourceStore,
            skillStore: SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: srcDir)
        )
        let data = try source.exportSnapshot(scopes: [.memories])

        let destinationStore = MemoryStore(directory: dstDir)
        let destination = SyncManager(
            sessionStore: SessionStore(directory: dstDir),
            memoryStore: destinationStore,
            skillStore: SkillStore(skillsRoot: dstDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dstDir)
        )
        let first = try destination.importSnapshot(data, memoryScope: scope)
        let firstBytes = try Data(contentsOf: destinationStore.fileURL)
        let second = try destination.importSnapshot(data, memoryScope: scope)

        #expect(second.scopeResults.first?.succeeded == true)
        #expect(second.allSucceeded)
        #expect(first.manifest == second.manifest)
        #expect(try Data(contentsOf: destinationStore.fileURL) == firstBytes)
        #expect(try destinationStore.facts().count == 1)
        #expect(try destination.memoryProposalConsumer.restoreReceipts().count == 1)
    }

    @Test func dirtyScopesTravelWithExportAndClear() throws {
        let dir = try makeTempDir("SyncDirty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        #expect(manager.dirtyScopes.isEmpty)
        manager.markDirty(.sessions)
        manager.markDirty(.settings)
        #expect(manager.dirtyScopes == [.sessions, .settings])

        // 只导出 sessions：manifest 只带 sessions 的 dirty，且导出后清除
        let data = try manager.exportSnapshot(scopes: [.sessions])
        #expect(manager.dirtyScopes == [.settings])

        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data)
        #expect(envelope.manifest.dirtyScopes == ["sessions"])
    }

    // MARK: - TaskScheduler

    @Test func schedulerRunsTaskOnIntervalAndRecords() async throws {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        let counter = Counter()
        let task = BackgroundTask(id: "tick", title: "心跳", intervalSeconds: 0.05) {
            await counter.increment()
        }
        #expect(scheduler.register(task))

        try await Task.sleep(for: .milliseconds(450))
        let count = await counter.get()
        #expect(count >= 1, "短间隔任务应在等待窗口内至少触发一次")

        // 状态与执行记录
        let registered = scheduler.task(id: "tick")
        #expect(registered != nil)
        #expect(registered?.lastRunAt != nil)
        let records = scheduler.executionRecords()
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.taskID == "tick" })
        #expect(records.contains { $0.status == .success })
    }

    @Test func schedulerDisableStopsFiring() async throws {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        let counter = Counter()
        scheduler.register(BackgroundTask(id: "tick2", title: "心跳2", intervalSeconds: 0.05) {
            await counter.increment()
        })

        try await Task.sleep(for: .milliseconds(300))
        let before = await counter.get()
        #expect(before >= 1)

        #expect(scheduler.disable(id: "tick2"))
        try await Task.sleep(for: .milliseconds(400))
        let after = await counter.get()
        // 允许最多一次已在 disable 前入队/在途的执行完成；若仍周期性
        // 触发，after 会远超 before + 1。
        #expect(after <= before + 1, "禁用后不应再周期性触发")

        // 重新启用应恢复触发
        #expect(scheduler.enable(id: "tick2"))
        try await Task.sleep(for: .milliseconds(300))
        let resumed = await counter.get()
        #expect(resumed > after)
    }

    @Test func schedulerRunNowTriggersImmediately() async throws {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        let counter = Counter()
        scheduler.register(BackgroundTask(id: "manual", title: "手动", intervalSeconds: 3600) {
            await counter.increment()
        })

        scheduler.runNow(id: "manual")
        try await Task.sleep(for: .milliseconds(150))
        let count = await counter.get()
        #expect(count == 1)
        #expect(scheduler.task(id: "manual")?.lastRunAt != nil)

        // 未注册 / 禁用任务不执行
        scheduler.runNow(id: "nope")
        #expect(scheduler.disable(id: "manual"))
        scheduler.runNow(id: "manual")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await counter.get() == 1)
    }

    @Test func schedulerRecordsFailureStatus() async throws {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        scheduler.register(BackgroundTask(id: "boom", title: "会失败的任务", intervalSeconds: 0.05) {
            throw SyncManifestError.emptyScopes
        })
        try await Task.sleep(for: .milliseconds(300))

        let records = scheduler.executionRecords()
        #expect(records.contains { record in
            if case .failed = record.status { return true }
            return false
        })
    }

    // MARK: - 边界：空 scope / 坏 JSON 导入容错

    @Test func emptyScopeExportYieldsSnapshotImportRejects() async throws {
        // 边界：空 scope 导出不崩且产出合法 JSON；导入端因清单 scopes 为空抛 emptyScopes，不写任何数据
        let dir = try makeTempDir("SyncEmptyScope")
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        let data = try manager.exportSnapshot(scopes: [])
        #expect(!data.isEmpty)
        #expect(throws: SyncManifestError.emptyScopes) {
            try manager.importSnapshot(data)
        }
        // 导入失败未写入任何数据
        #expect(manager.sessionStore.listSessions().isEmpty)
    }

    @Test func badJSONImportThrowsWithoutCorruption() throws {
        let dir = try makeTempDir("SyncBadJSON")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(directory: dir)
        var session = try store.createSession(id: "keep", title: "保留")
        session.messages = [LLMMessage(role: .user, content: "hi")]
        try store.updateSession(session)

        let manager = SyncManager(
            sessionStore: store,
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir)
        )

        // 完全不是 JSON → 解码抛错
        #expect(throws: (any Error).self) {
            try manager.importSnapshot(Data("这不是 JSON".utf8))
        }
        // 合法 JSON 但不是快照形状（缺 manifest）→ 抛错
        #expect(throws: (any Error).self) {
            try manager.importSnapshot(Data(#"{"foo": 1}"#.utf8))
        }
        // 已有数据未被破坏
        #expect(manager.sessionStore.listSessions().map(\.id) == ["keep"])
        #expect(manager.sessionStore.listSessions().first?.messages.count == 1)
    }

    // MARK: - F14 P1-2：导入写盘错误不再吞（per-scope 聚合）

    /// 用「文件占位目录」让指定域的写盘必然失败：
    /// sessions → 在 sessions 目录位置放普通文件（createDirectory 失败）；
    /// memories → 在 memory 目录位置放普通文件（facts.json 父目录创建失败）。
    /// 返回装配好的 SyncManager（目标侧，全部空目录）。
    private func makeWriteFailureImporter(
        dir: URL,
        failScopes: Set<SyncScope>
    ) throws -> SyncManager {
        if failScopes.contains(.sessions) {
            let blocker = dir.appendingPathComponent("sessions")
            try Data("x".utf8).write(to: blocker)
        }
        if failScopes.contains(.memories) {
            // memory 目录位置放普通文件 → restoreMemories 的 createDirectory 失败
            let blocker = dir.appendingPathComponent("memory")
            try Data("x".utf8).write(to: blocker)
        }
        return SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dir),
            deviceName: "ImporterMac"
        )
    }

    /// 构造含指定域载荷的快照 Data（手工 envelope，避免依赖源 Store）。
    private func makeSnapshotData(
        scopes: Set<SyncScope>,
        sessions: [ChatSession] = [ChatSession(id: "imp-1", title: "导入会话")],
        memories: [MemoryFact] = [MemoryFact(text: "导入的记忆")],
        skills: [String: String] = [:],
        dirtyScopes: [String]? = nil
    ) throws -> Data {
        var envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(
                deviceName: "SrcMac",
                scopes: scopes.map(\.rawValue).sorted(),
                dirtyScopes: dirtyScopes
            )
        )
        if scopes.contains(.sessions) { envelope.sessions = sessions }
        if scopes.contains(.memories) { envelope.memories = memories }
        if scopes.contains(.skills) { envelope.skills = skills }
        if scopes.contains(.settings) { envelope.settings = AppSettings() }
        return try JSONEncoder().encode(envelope)
    }

    @Test func importMarksFailedScopeOthersStillRestore() throws {
        let dir = try makeTempDir("SyncImportFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        // sessions 写盘被阻断；memories + settings 正常
        let importer = try makeWriteFailureImporter(dir: dir, failScopes: [.sessions])

        let data = try makeSnapshotData(scopes: [.sessions, .memories, .settings])

        // 抛 SyncImportError 且携带逐域结果：sessions 失败、其余成功
        do {
            _ = try importer.importSnapshot(
                data,
                memoryScope: MemoryScope(sessionID: "imp-session", projectID: "project-1")
            )
            Issue.record("写失败不应静默返回成功")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.sessions])
            let results = error.result.scopeResults
            #expect(results.count == 3)
            let failed = results.first { $0.scope == .sessions }
            #expect(failed?.succeeded == false)
            #expect(failed?.failures.map(\.item) == ["imp-1"])
            let okMem = results.first { $0.scope == .memories }
            #expect(okMem?.succeeded == true)
            #expect(okMem?.failures.isEmpty == true)
            let okSettings = results.first { $0.scope == .settings }
            #expect(okSettings?.succeeded == true)
            // 中文错误提示点名失败域
            #expect(error.message.contains("会话"))
            #expect(error.result.summaryMessage.contains("记忆"))
            #expect(error.result.summaryMessage.contains("导入失败"))
        }

        // 成功域的数据真实落盘生效
        #expect(try importer.memoryStore.facts().map(\.text) == ["导入的记忆"])
        #expect(importer.sessionStore.listSessions().isEmpty)

        // 单域快照失败 → summaryMessage 为「导入失败：…」形态
        let onlySessions = try makeSnapshotData(scopes: [.sessions])
        do {
            _ = try importer.importSnapshot(onlySessions)
            Issue.record("写失败不应静默返回成功")
        } catch let error as SyncImportError {
            #expect(error.result.summaryMessage == "导入失败：会话")
        }
    }

    @Test func settingsImportReportsPersistenceFailureWithoutMutatingStore() throws {
        let dir = try makeTempDir("SyncSettingsImportFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsStore = SettingsStore(directory: dir)
        #expect(settingsStore.update(\.general.appearance, to: .dark) == .success(.persisted))
        let before = settingsStore.settings

        let settingsFile = dir.appendingPathComponent(SettingsStore.fileName)
        try FileManager.default.removeItem(at: settingsFile)
        try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: true)

        let manager = SyncManager(
            sessionStore: SessionStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: settingsStore
        )
        let data = try makeSnapshotData(scopes: [.settings])

        do {
            _ = try manager.importSnapshot(data)
            Issue.record("设置持久化失败不应返回成功")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.settings])
            #expect(error.result.scopeResults.count == 1)
            #expect(error.result.scopeResults.first?.failures.map(\.item) == [SettingsStore.fileName])
        }
        #expect(settingsStore.settings == before)
    }

    @Test func importFailureMessageIncludesItemDetail() throws {
        // skills 域：空内容 → importSkill 抛 invalidContent，
        // 条目级失败明细 item = 快照中的 skill id，message 含域名+条目+原因。
        let dir = try makeTempDir("SyncImportFailSkills")
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = try makeWriteFailureImporter(dir: dir, failScopes: [])

        let data = try makeSnapshotData(
            scopes: [.skills],
            skills: [
                "坏技能": "",   // 空内容 → importSkill 拒绝
                "好技能": "---\nname: 好技能\ndescription: 正常\nversion: 1.0.0\n---\n正文",
            ]
        )

        do {
            _ = try importer.importSnapshot(data)
            Issue.record("技能导入失败不应静默成功")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.skills])
            let skillResult = error.result.scopeResults.first { $0.scope == .skills }
            #expect(skillResult?.succeeded == false)
            #expect(skillResult?.failures.map(\.item) == ["坏技能"])
            #expect(skillResult?.failures.first?.reason.isEmpty == false)
            #expect(error.message.contains("技能"))
            #expect(error.message.contains("坏技能"))
        }
        // 合法技能不受影响（尽力恢复语义：失败条目不阻断成功条目）
        #expect(importer.skillStore.skills.contains { $0.id == "好技能" })
    }

    @Test func importFailurePreservesFailedScopeDirtyFlag() throws {
        // 快照声明 dirtyScopes=[sessions, memories]；sessions 写失败后，
        // 本地 sessions 的 dirty 标记不应被误清（只清恢复成功的域）。
        let dir = try makeTempDir("SyncImportDirtyFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let importer = try makeWriteFailureImporter(dir: dir, failScopes: [.sessions])
        importer.markDirty(.sessions)
        importer.markDirty(.memories)

        let data = try makeSnapshotData(
            scopes: [.sessions, .memories],
            dirtyScopes: ["sessions", "memories"]
        )
        do {
            _ = try importer.importSnapshot(
                data,
                memoryScope: MemoryScope(sessionID: "imp-session", projectID: "project-1")
            )
            Issue.record("写失败不应静默返回成功")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.sessions])
        }
        #expect(importer.dirtyScopes == [.sessions])
    }

    @Test func importSnapshotFileSurfacesWriteFailure() throws {
        // importSnapshotFile 同样不再吞写失败（P1-3 UI 层走的就是它）
        let srcDir = try makeTempDir("SyncImportFileSrc")
        let dstDir = try makeTempDir("SyncImportFileDst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        let srcSessions = SessionStore(directory: srcDir)
        try srcSessions.createSession(id: "f-1", title: "文件导入")
        let srcManager = SyncManager(
            sessionStore: srcSessions,
            memoryStore: MemoryStore(directory: srcDir),
            skillStore: SkillStore(skillsRoot: srcDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: srcDir)
        )
        let fileURL = dstDir.appendingPathComponent("snap.minissync")
        try srcManager.exportSnapshotFile(scopes: [.sessions], to: fileURL)

        // 目标侧 sessions 写盘被阻断
        let blocker = dstDir.appendingPathComponent("sessions")
        try Data("x".utf8).write(to: blocker)
        let importer = SyncManager(
            sessionStore: SessionStore(directory: dstDir),
            memoryStore: MemoryStore(directory: dstDir),
            skillStore: SkillStore(skillsRoot: dstDir.appendingPathComponent("skills", isDirectory: true)),
            settingsStore: SettingsStore(directory: dstDir)
        )

        do {
            _ = try importer.importSnapshotFile(from: fileURL)
            Issue.record("写失败不应静默返回成功")
        } catch let error as SyncImportError {
            #expect(error.failedScopes == [.sessions])
            #expect(error.result.summaryMessage.contains("会话"))
        }
        #expect(importer.sessionStore.listSessions().isEmpty)
    }

    @Test func syncImportResultSummaryMessageForms() {
        // summaryMessage 三种形态（纯逻辑，无 IO）
        let allOK = SyncImportResult(
            manifest: SyncManifest(deviceName: "T", scopes: ["sessions", "memories"]),
            scopeResults: [
                SyncScopeResult(scope: .sessions, succeeded: true, failures: []),
                SyncScopeResult(scope: .memories, succeeded: true, failures: []),
            ]
        )
        #expect(allOK.summaryMessage == "导入成功：会话、记忆")
        #expect(allOK.allSucceeded)

        let partial = SyncImportResult(
            manifest: SyncManifest(deviceName: "T", scopes: ["sessions", "memories"]),
            scopeResults: [
                SyncScopeResult(scope: .sessions, succeeded: true, failures: []),
                SyncScopeResult(
                    scope: .memories, succeeded: false,
                    failures: [SyncScopeFailure(item: "facts.json", reason: "disk full")]
                ),
            ]
        )
        #expect(!partial.allSucceeded)
        #expect(partial.summaryMessage == "会话 导入成功；记忆 导入失败")
        #expect(partial.failedScopes == [.memories])
        #expect(SyncImportError(result: partial).message.contains("记忆"))
        #expect(SyncImportError(result: partial).message.contains("facts.json"))
    }
}


extension SyncTests {
    @Test func atomicPreviewDoesNotReplaceExplicitLegacyPartialImportAPI() throws {
        let sourceRoot = try makeTempDir("F05-legacy-source").resolvingSymlinksInPath()
        let targetRoot = try makeTempDir("F05-legacy-target").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sourceRoot); try? FileManager.default.removeItem(at: targetRoot) }
        func manager(_ root: URL) -> SyncManager {
            SyncManager(sessionStore: SessionStore(directory: root), memoryStore: MemoryStore(directory: root),
                        skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true)), settingsStore: SettingsStore(directory: root))
        }
        let source = manager(sourceRoot); let target = manager(targetRoot)
        _ = source.settingsStore.update(\.storage.sessionRetentionDays, to: 67)
        let data = try source.exportSnapshot(scopes: [.settings])
        let before = target.settingsStore.settings
        _ = try target.previewAtomicImport(data, selecting: [.settings])
        #expect(target.settingsStore.settings == before)
        let result = try target.importSnapshot(data, restoring: [.settings])
        #expect(result.allSucceeded)
        #expect(target.settingsStore.settings.storage.sessionRetentionDays == 67)
        #expect(!PersistenceTransactionFence.requiresReopen(target.settingsStore.persistenceDomain))
    }
}
