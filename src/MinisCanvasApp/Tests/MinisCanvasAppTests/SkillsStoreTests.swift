import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 波4 技能（skill）管理测试
//
// 覆盖：
//   · SkillsScanner：Hermes 库递归扫描（分类/名称/描述）、App 库扫描、去重
//   · SkillsStateStore：启用状态读写（独立 JSON，不写技能文件）
//   · SkillsStore：扫描合并且应用持久化状态、setEnabled 持久化 + 内存更新

// MARK: 工具

private func skTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSkillMD(at dir: URL, content: String) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private let skSampleMD = """
---
name: image-prompt-writer
description: 图片和视频的提示词怎么写，文生图 / 图生图 / 镜头分镜。
version: 1.2.0
---

# 正文
"""

// MARK: - SkillsScanner

@Suite("波4 SkillsScanner：技能扫描")
struct SkillsScannerTests {

    @Test func hermesScanRecursesAndAssignsCategory() throws {
        let root = try skTempDir("hermes")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkillMD(at: root.appendingPathComponent("creative/manju-core"), content: """
        ---
        name: manju-core
        description: 漫剧铁律层。
        ---
        正文。
        """)
        try writeSkillMD(at: root.appendingPathComponent("github/pr-workflow"), content: """
        ---
        name: pr-workflow
        description: GitHub PR lifecycle.
        ---
        body
        """)
        // 干扰项：无 SKILL.md 的目录
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty-category"), withIntermediateDirectories: true)

        let entries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.name)) == ["manju-core", "pr-workflow"])
        #expect(entries.allSatisfy { $0.source == .localDirectory })
        #expect(entries.allSatisfy { $0.isEnabled })
        // 分类 = SKILL.md 上一级目录名
        let manju = try #require(entries.first { $0.name == "manju-core" })
        #expect(manju.category == "creative")
        #expect(manju.id == "local:manju-core")
        let pr = try #require(entries.first { $0.name == "pr-workflow" })
        #expect(pr.category == "github")
        // 按名称排序
        #expect(entries.map(\.name) == entries.sorted { $0.name < $1.name }.map(\.name))
    }

    @Test func hermesScanRootMissingReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK4-missing-\(UUID().uuidString)")
        #expect(SkillsScanner.scanLocalDirectory(root: missing).isEmpty)
    }

    @Test func hermesScanRootLevelSkillMarkedUncategorized() throws {
        let root = try skTempDir("uncat")
        defer { try? FileManager.default.removeItem(at: root) }
        // 根目录直接放 SKILL.md（无分类子目录）
        try writeSkillMD(at: root.appendingPathComponent("top-skill"), content: skSampleMD)
        let entries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(entries.count == 1)
        #expect(entries[0].category == "未分类")
    }

    @Test func hermesScanFallsBackToDirectoryName() throws {
        let root = try skTempDir("noname")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkillMD(at: root.appendingPathComponent("cat/my-skill"), content: "# 无 frontmatter 正文")
        let entries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(entries.count == 1)
        #expect(entries[0].name == "my-skill")
        #expect(entries[0].id == "local:my-skill")
    }

    @Test func appScanListsStoreSkills() throws {
        let dir = try skTempDir("appstore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(skillsRoot: dir)
        try store.importSkill(content: skSampleMD, source: .file)

        let entries = SkillsScanner.scanApp(store: store)
        #expect(entries.count == 1)
        #expect(entries[0].source == .app)
        #expect(entries[0].category == "内置")
        #expect(entries[0].name == "image-prompt-writer")
        #expect(entries[0].id == "app:image-prompt-writer")
        #expect(entries[0].description.hasPrefix("图片和视频的提示词怎么写"))
    }
}

// MARK: - SkillsStateStore

@Suite("波4 SkillsStateStore：启用状态持久化")
struct SkillsStateStoreTests {

    @Test func loadSaveRoundTrip() throws {
        let dir = try skTempDir("state")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("skills-enabled.json")

        // 初始为空
        #expect(SkillsStateStore.load(from: url).isEmpty)

        // 保存后读回
        SkillsStateStore.save(["local:manju-core": false, "app:x": true], to: url)
        let loaded = SkillsStateStore.load(from: url)
        #expect(loaded["local:manju-core"] == false)
        #expect(loaded["app:x"] == true)
    }

    @Test func loadMissingFileReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK4-nostate-\(UUID().uuidString).json")
        #expect(SkillsStateStore.load(from: missing).isEmpty)
    }

    @Test func loadCorruptFileReturnsEmpty() throws {
        let dir = try skTempDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("skills-enabled.json")
        try "not-json".write(to: url, atomically: true, encoding: .utf8)
        #expect(SkillsStateStore.load(from: url).isEmpty)
    }
}

// MARK: - SkillsStore

private struct RollbackFixture {
    let appDirectory: URL
    let stateDirectory: URL
    let hermesDirectory: URL
    let frozenAppStore: SkillStore
    let stateURL: URL
    let settingsID: String
    let skillID: String
    let currentContent: String
}

private func makeRollbackFixture(
    label: String,
    originalEnabled: Bool
) throws -> RollbackFixture {
    let appDirectory = try skTempDir("rollback-\(label)-app")
    let appStore = SkillStore(skillsRoot: appDirectory)
    let skillName = "rollback-\(label)"
    let previousContent = """
    ---
    name: \(skillName)
    description: safe rollback fixture
    version: 1.0.0
    ---
    previous body
    """
    let currentContent = """
    ---
    name: \(skillName)
    description: safe rollback fixture
    version: 2.0.0
    ---
    current body
    """
    let previous = try appStore.importSkillThroughLifecycle(
        content: previousContent,
        source: .bundled,
        reason: "previous",
        approval: SkillApproval(approverID: "previous-reviewer")
    )
    _ = try appStore.importSkillThroughLifecycle(
        content: currentContent,
        source: .bundled,
        reason: "current",
        approval: SkillApproval(approverID: "current-reviewer")
    )

    let stateDirectory = try skTempDir("rollback-\(label)-state")
    let hermesDirectory = try skTempDir("rollback-\(label)-hermes")
    let stateURL = stateDirectory.appendingPathComponent("skills-enabled.json")
    let settingsID = "app:\(previous.skill.id)"
    if !originalEnabled {
        _ = SkillsStateStore.save([settingsID: false], to: stateURL)
    }

    return RollbackFixture(
        appDirectory: appDirectory,
        stateDirectory: stateDirectory,
        hermesDirectory: hermesDirectory,
        frozenAppStore: appStore.makeSnapshotStore(),
        stateURL: stateURL,
        settingsID: settingsID,
        skillID: previous.skill.id,
        currentContent: currentContent
    )
}

private func scriptedRollbackStateSaver(
    _ outcomes: [Result<Void, SkillsStateStore.SaveError>]
) -> ([String: Bool], URL) -> Result<Void, SkillsStateStore.SaveError> {
    var remaining = outcomes
    return { states, url in
        guard !remaining.isEmpty else { return .failure(.writeFailed) }
        switch remaining.removeFirst() {
        case .success:
            return SkillsStateStore.save(states, to: url)
        case .failure(let error):
            return .failure(error)
        }
    }
}

@Suite("波4 SkillsStore：扫描合并 + 启用/禁用")
@MainActor
struct SkillsStoreTests {

    @Test func mergesAppAndHermesApplyingPersistedState() throws {
        let appDir = try skTempDir("app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        try appStore.importSkill(content: skSampleMD, source: .file)

        let hermesRoot = try skTempDir("hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        try writeSkillMD(at: hermesRoot.appendingPathComponent("creative/manju-core"), content: """
        ---
        name: manju-core
        description: 漫剧铁律层。
        ---
        body
        """)

        let stateURL = try skTempDir("state").appendingPathComponent("skills-enabled.json")
        // 预置：manju-core 禁用
        SkillsStateStore.save(["local:" + SkillManifest.hash(hermesRoot.appendingPathComponent("creative/manju-core/SKILL.md").standardizedFileURL.path): false], to: stateURL)

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )
        _ = store.addSkillDirectory(hermesRoot)
        store.reload()
        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.id == "app:image-prompt-writer" })
        #expect(store.entries.contains { $0.id == "local:" + SkillManifest.hash(hermesRoot.appendingPathComponent("creative/manju-core/SKILL.md").standardizedFileURL.path) })
        // 持久化状态生效
        #expect(store.isEnabled("local:" + SkillManifest.hash(hermesRoot.appendingPathComponent("creative/manju-core/SKILL.md").standardizedFileURL.path)) == false)
        #expect(store.isEnabled("app:image-prompt-writer") == true)
    }

    @Test func coldStartCanDeferScanToBackground() async throws {
        let appDir = try skTempDir("deferred-app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        try appStore.importSkill(content: skSampleMD, source: .file)

        let hermesRoot = try skTempDir("deferred-hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        try writeSkillMD(at: hermesRoot.appendingPathComponent("creative/manju-core"), content: """
        ---
        name: manju-core
        description: 漫剧铁律层。
        ---
        body
        """)
        let stateURL = try skTempDir("deferred-state").appendingPathComponent("skills-enabled.json")

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL,
            loadImmediately: false
        )
        _ = store.addSkillDirectory(hermesRoot)
        #expect(store.entries.isEmpty, "延迟初始化不应在构造阶段同步扫描")

        let task = store.reloadInBackground()
        await task.value

        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.id == "app:image-prompt-writer" })
        #expect(store.entries.contains { $0.id == "local:" + SkillManifest.hash(hermesRoot.appendingPathComponent("creative/manju-core/SKILL.md").standardizedFileURL.path) })
    }

    @Test func setEnabledPersistsAndUpdatesMemory() throws {
        let appDir = try skTempDir("app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        try appStore.importSkill(content: skSampleMD, source: .file)
        let hermesRoot = try skTempDir("hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        let stateURL = try skTempDir("state").appendingPathComponent("skills-enabled.json")

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )
        let id = "app:image-prompt-writer"
        #expect(store.entries.first { $0.id == id }?.isEnabled == true)

        store.setEnabled(id, enabled: false)
        #expect(store.entries.first { $0.id == id }?.isEnabled == false)

        // 重新实例化（模拟重启）→ 状态仍持久化
        let store2 = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )
        #expect(store2.isEnabled(id) == false)
    }

    @Test func appToggleUpdatesTheLiveMinisCoreStore() throws {
        let appDir = try skTempDir("runtime-bridge-app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        try appStore.importSkill(content: skSampleMD, source: .file)

        let stateURL = try skTempDir("runtime-bridge-state")
            .appendingPathComponent("skills-enabled.json")
        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        store.setEnabled("app:image-prompt-writer", enabled: false)
        #expect(appStore.allSkills().first?.isEnabled == false)
        #expect(SkillInjector(store: appStore).matchingSkills(for: "image-prompt-writer").isEmpty)

        store.setEnabled("app:image-prompt-writer", enabled: true)
        #expect(appStore.allSkills().first?.isEnabled == true)
        #expect(SkillInjector(store: appStore).matchingSkills(for: "image-prompt-writer").count == 1)
    }

    @Test func settingsCanReenableSkillAfterIdempotentApprovedRedeploy() throws {
        let appDir = try skTempDir("runtime-redeploy-app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        let approved = try appStore.importSkillThroughLifecycle(
            content: skSampleMD,
            source: .bundled,
            reason: "initial bundled deployment",
            approval: SkillApproval(approverID: "settings-test")
        )

        let stateURL = try skTempDir("runtime-redeploy-state")
            .appendingPathComponent("skills-enabled.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )

        let settingsID = "app:" + approved.skill.id
        switch store.setEnabled(settingsID, enabled: false) {
        case .success: break
        case .failure(let error): Issue.record("approved skill could not be disabled: \(error)")
        }
        _ = try appStore.importSkillThroughLifecycle(
            content: skSampleMD,
            source: .bundled,
            reason: "repeat bundled deployment"
        )
        #expect(appStore.lifecycleReceipt(for: approved.skill.id)?.state == .active)
        switch store.setEnabled(settingsID, enabled: true) {
        case .success: break
        case .failure(let error): Issue.record("approved skill could not be re-enabled: \(error)")
        }
        #expect(appStore.allSkills().first?.isEnabled == true)
        #expect(SkillInjector(store: appStore).matchingSkills(for: "image-prompt-writer").count == 1)
    }

    @Test func settingsCanRollbackApprovedRevisionAndKeepItDisabled() throws {
        let appDir = try skTempDir("rollback-app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        let previousContent = """
        ---
        name: settings-rollback
        description: safe rollback fixture
        version: 1.0.0
        ---
        previous body
        """
        let currentContent = """
        ---
        name: settings-rollback
        description: safe rollback fixture
        version: 2.0.0
        ---
        current body
        """
        let previous = try appStore.importSkillThroughLifecycle(
            content: previousContent,
            source: .bundled,
            reason: "previous",
            approval: SkillApproval(approverID: "previous-reviewer")
        )
        _ = try appStore.importSkillThroughLifecycle(
            content: currentContent,
            source: .bundled,
            reason: "current",
            approval: SkillApproval(approverID: "current-reviewer")
        )

        let stateURL = try skTempDir("rollback-state")
            .appendingPathComponent("skills-enabled.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateURL
        )
        let settingsID = "app:\(previous.skill.id)"
        #expect(store.canRollback(settingsID))

        switch store.rollback(settingsID, reason: "settings rollback") {
        case .success(let receipt):
            #expect(receipt.contentHash == SkillManifest.hash(previousContent))
        case .failure(let error):
            Issue.record("settings rollback unexpectedly failed: \(error)")
        }
        #expect(store.isEnabled(settingsID) == false)
        #expect(appStore.rawContent(previous.skill.id) == previousContent)
        #expect(appStore.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
        #expect(!store.canRollback(settingsID))
        #expect(SkillInjector(store: appStore, minimumScore: 1)
            .matchingSkills(for: "settings rollback").isEmpty)
        #expect(SkillsStateStore.load(from: stateURL)[settingsID] == false)

        let restartedAppStore = SkillStore(skillsRoot: appDir)
        let restarted = SkillsStore(
            appStore: restartedAppStore,
            stateFileURL: stateURL
        )
        #expect(restarted.isEnabled(settingsID) == false)
        #expect(restartedAppStore.lifecycleReceipt(for: previous.skill.id)?.contentHash
            == SkillManifest.hash(previousContent))
    }

    @Test func rollbackInitialPersistenceFailureKeepsOriginalState() throws {
        for originalEnabled in [true, false] {
            let fixture = try makeRollbackFixture(
                label: "initial-\(originalEnabled)",
                originalEnabled: originalEnabled
            )
            defer {
                try? FileManager.default.removeItem(at: fixture.appDirectory)
                try? FileManager.default.removeItem(at: fixture.stateDirectory)
                try? FileManager.default.removeItem(at: fixture.hermesDirectory)
            }
            let store = SkillsStore(
                appStore: fixture.frozenAppStore,
                stateFileURL: fixture.stateURL,
                rollbackStateSaver: scriptedRollbackStateSaver([.failure(.writeFailed)])
            )
            #expect(store.isEnabled(fixture.settingsID) == originalEnabled)

            switch store.rollback(fixture.settingsID, reason: "initial persistence failure") {
            case .success:
                Issue.record("initial rollback persistence failure must not report success")
            case .failure(let error):
                #expect(error == .rollbackPersistenceFailed(.writeFailed))
            }
            #expect(store.lastErrorMessage
                == "技能回滚状态保存失败，当前状态未改变；请检查磁盘权限后重试。")
            #expect(store.isEnabled(fixture.settingsID) == originalEnabled)
            let persisted = SkillsStateStore.load(from: fixture.stateURL)[fixture.settingsID]
            if originalEnabled {
                #expect(persisted == nil)
            } else {
                #expect(persisted == false)
            }
            #expect(fixture.frozenAppStore.rawContent(fixture.skillID)
                == fixture.currentContent)
        }
    }

    @Test func rollbackRuntimeFailureWithSuccessfulCompensationRestoresOriginalState() throws {
        for originalEnabled in [true, false] {
            let fixture = try makeRollbackFixture(
                label: "compensation-success-\(originalEnabled)",
                originalEnabled: originalEnabled
            )
            defer {
                try? FileManager.default.removeItem(at: fixture.appDirectory)
                try? FileManager.default.removeItem(at: fixture.stateDirectory)
                try? FileManager.default.removeItem(at: fixture.hermesDirectory)
            }
            let store = SkillsStore(
                appStore: fixture.frozenAppStore,
                stateFileURL: fixture.stateURL,
                rollbackStateSaver: scriptedRollbackStateSaver([.success(()), .success(())])
            )
            #expect(store.isEnabled(fixture.settingsID) == originalEnabled)

            switch store.rollback(fixture.settingsID, reason: "runtime failure") {
            case .success:
                Issue.record("frozen runtime rollback must not report success")
            case .failure(let error):
                #expect(error == .rollbackRejected)
            }
            #expect(store.lastErrorMessage == "技能版本未能安全回滚，当前状态未改变。")
            #expect(store.isEnabled(fixture.settingsID) == originalEnabled)
            let persisted = SkillsStateStore.load(from: fixture.stateURL)[fixture.settingsID]
            if originalEnabled {
                #expect(persisted == nil)
            } else {
                #expect(persisted == false)
            }
            #expect(fixture.frozenAppStore.rawContent(fixture.skillID)
                == fixture.currentContent)
        }
    }

    @Test func rollbackCompensationFailureKeepsSkillDisabledAndReportsUnrestoredState() throws {
        for originalEnabled in [true, false] {
            let fixture = try makeRollbackFixture(
                label: "compensation-failure-\(originalEnabled)",
                originalEnabled: originalEnabled
            )
            defer {
                try? FileManager.default.removeItem(at: fixture.appDirectory)
                try? FileManager.default.removeItem(at: fixture.stateDirectory)
                try? FileManager.default.removeItem(at: fixture.hermesDirectory)
            }
            let store = SkillsStore(
                appStore: fixture.frozenAppStore,
                stateFileURL: fixture.stateURL,
                rollbackStateSaver: scriptedRollbackStateSaver([.success(()), .failure(.writeFailed)])
            )
            #expect(store.isEnabled(fixture.settingsID) == originalEnabled)

            switch store.rollback(fixture.settingsID, reason: "compensation persistence failure") {
            case .success:
                Issue.record("failed compensation persistence must not report success")
            case .failure(let error):
                #expect(error == .rollbackCompensationPersistenceFailed(.writeFailed))
            }
            #expect(store.lastErrorMessage
                == "技能回滚失败，技能保持禁用，原状态未恢复；请检查磁盘权限后重试。")
            #expect(store.isEnabled(fixture.settingsID) == false)
            #expect(SkillsStateStore.load(from: fixture.stateURL)[fixture.settingsID] == false)
            #expect(fixture.frozenAppStore.rawContent(fixture.skillID)
                == fixture.currentContent)
        }
    }

    @Test func failedPersistenceDoesNotProjectEnabledState() throws {
        let hermesRoot = try skTempDir("persistence-failure-hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        let appStore = SkillStore(skillsRoot: hermesRoot)
        _ = try appStore.importSkill(content: skSampleMD, source: .file)
        let stateDirectory = try skTempDir("persistence-failure-state")
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateDirectory
        )
        let id = "app:image-prompt-writer"
        let result = store.setEnabled(id, enabled: false)

        switch result {
        case .failure(let error):
            #expect(error == .persistenceFailed(.writeFailed))
        case .success:
            Issue.record("persistence failure must not report success")
        }
        #expect(store.isEnabled(id))
        #expect(store.entries.first { $0.id == id }?.isEnabled == true)
    }

    @Test func failedPersistenceExposesSafeUserMessageWithoutInternalErrorName() throws {
        let hermesRoot = try skTempDir("persistence-message-hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        let appStore = SkillStore(skillsRoot: hermesRoot)
        _ = try appStore.importSkill(content: skSampleMD, source: .file)
        let stateDirectory = try skTempDir("persistence-message-state")
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateDirectory
        )
        let result = store.setEnabled("app:image-prompt-writer", enabled: false)

        switch result {
        case .failure(let error):
            #expect(error == .persistenceFailed(.writeFailed))
        case .success:
            Issue.record("persistence failure must not report success")
        }
        #expect(store.lastErrorMessage == "技能状态保存失败，当前状态未改变；请检查磁盘权限后重试。")
        #expect(store.lastErrorMessage?.contains("persistenceFailed") == false)
        #expect(store.lastErrorMessage?.contains("writeFailed") == false)
        #expect(store.lastErrorMessage?.contains(stateDirectory.path) == false)
    }

    @Test func failedRuntimeExposesSafeUserMessageWithoutInternalErrorName() throws {
        let appDir = try skTempDir("runtime-message-app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let liveAppStore = SkillStore(skillsRoot: appDir)
        try liveAppStore.importSkill(content: skSampleMD, source: .file)
        let frozenAppStore = liveAppStore.makeSnapshotStore()
        let stateURL = try skTempDir("runtime-message-state")
            .appendingPathComponent("skills-enabled.json")

        let store = SkillsStore(
            appStore: frozenAppStore,
            stateFileURL: stateURL
        )
        let result = store.setEnabled("app:image-prompt-writer", enabled: false)

        switch result {
        case .failure(let error):
            #expect(error == .runtimeRejected(.rejected))
        case .success:
            Issue.record("runtime rejection must not report success")
        }
        #expect(store.lastErrorMessage == "运行时拒绝了这项更改，技能状态未改变。")
        #expect(store.lastErrorMessage?.contains("runtimeRejected") == false)
        #expect(store.lastErrorMessage?.contains("rejected") == false)
    }

    @Test func unknownSkillToggleReturnsFailureWithoutProjection() throws {
        let hermesRoot = try skTempDir("unknown-toggle-hermes")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        try writeSkillMD(
            at: hermesRoot.appendingPathComponent("creative/known"),
            content: skSampleMD
        )
        let appRoot = try skTempDir("unknown-toggle-app")
        defer { try? FileManager.default.removeItem(at: appRoot) }
        let stateURL = try skTempDir("unknown-toggle-state")
            .appendingPathComponent("skills-enabled.json")
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let store = SkillsStore(
            appStore: SkillStore(skillsRoot: appRoot),
            stateFileURL: stateURL
        )
        _ = store.addSkillDirectory(hermesRoot)
        store.reload()
        let unknownID = "app:missing"
        let before = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0.isEnabled) })
        let result = store.setEnabled(unknownID, enabled: true)

        switch result {
        case .failure(let error):
            #expect(error == .unknownSkill)
        case .success:
            Issue.record("unknown skill toggle must not report success")
        }
        let after = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0.isEnabled) })
        #expect(!after.keys.contains(unknownID))
        #expect(after == before)
    }

    @Test func groupedByCategorySections() throws {
        let hermesRoot = try skTempDir("cat")
        defer { try? FileManager.default.removeItem(at: hermesRoot) }
        try writeSkillMD(at: hermesRoot.appendingPathComponent("creative/a"), content: skSampleMD)
        try writeSkillMD(at: hermesRoot.appendingPathComponent("github/b"), content: skSampleMD)
        let appDir = try skTempDir("app")
        defer { try? FileManager.default.removeItem(at: appDir) }
        let appStore = SkillStore(skillsRoot: appDir)
        try appStore.importSkill(content: skSampleMD, source: .file)

        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: try skTempDir("state").appendingPathComponent("skills-enabled.json")
        )
        _ = store.addSkillDirectory(hermesRoot)
        store.reload()
        let groups = store.groupedByCategory
        #expect(groups.count == 3)
        #expect(Set(groups.map(\.category)) == ["creative", "github", "内置"])
    }
}

@Suite("O16c configured skill directories")
@MainActor
struct O16SkillDirectoriesTests {
    @Test func defaultGlobalAndChosenProjectDirectoriesSurviveReload() async throws {
        let root = try skTempDir("o16-directories")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = SkillStore(skillsRoot: root.appendingPathComponent("app"))
        let state = root.appendingPathComponent("settings/skills-enabled.json")
        let store = SkillsStore(appStore: app, stateFileURL: state, loadImmediately: false)
        _ = store.addSkillDirectory(root.appendingPathComponent(".claude/skills"))
        _ = store.addSkillDirectory(root.appendingPathComponent(".agents/skills"))
        #expect(store.localSkillRoots.map(\.path) == [root.appendingPathComponent(".claude/skills").path,
            root.appendingPathComponent(".agents/skills").path])
        let project = root.appendingPathComponent("project")
        #expect(store.addSkillDirectory(project, isProject: true))
        await store.reloadInBackground().value
        let reopened = SkillsStore(appStore: app, stateFileURL: state, loadImmediately: false)
        #expect(reopened.localSkillRoots.last?.path == project.appendingPathComponent(".claude/skills").path)
        #expect(reopened.removeSkillDirectory(project.appendingPathComponent(".claude/skills")))
        await reopened.reloadInBackground().value
        #expect(reopened.localSkillRoots.count == 2)
    }

    @Test func threeRootsDiscoverAndEachRequiresExplicitReviewBeforePickerUse() async throws {
        let root = try skTempDir("o16-review")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = SkillStore(skillsRoot: root.appendingPathComponent("app"))
        let roots = [root.appendingPathComponent(".claude/skills"), root.appendingPathComponent(".agents/skills"),
                     root.appendingPathComponent("project/.claude/skills")]
        for (index, directory) in roots.enumerated() {
            try writeSkillMD(at: directory.appendingPathComponent("skill-\(index)"), content: """
            ---
            name: skill-\(index)
            description: A skill from directory \(index).
            ---
            Perform only the requested fixture task.
            """)
        }
        let store = SkillsStore(appStore: app,
            stateFileURL: root.appendingPathComponent("settings/skills-enabled.json"))
        for directory in roots.prefix(2) { _ = store.addSkillDirectory(directory) }
        #expect(store.addSkillDirectory(root.appendingPathComponent("project"), isProject: true))
        await store.reloadInBackground().value
        let discovered = store.entries.filter(\.requiresImport)
        #expect(discovered.count == 3)
        #expect(discovered.allSatisfy { !store.isEnabled($0.id) })
        for entry in discovered {
            guard case .success(let draft) = store.proposeDiscoveredSkill(entry) else {
                Issue.record("discovered skill proposal failed"); return
            }
            #expect(app.lifecycleReceipt(for: draft.skillID)?.state == .proposed)
            #expect(!SkillCatalogLoader.loadCatalog(appStore: app, servers: []).contains { $0.id == "skill:" + draft.skillID })
            guard case .success = store.approveLocalSkill(draft) else {
                Issue.record("explicit skill review failed"); return
            }
            let skill = try #require(app.allSkills().first { $0.id == draft.skillID })
            #expect(app.isInjectable(skill))
        }
        let catalog = SkillCatalogLoader.loadCatalog(appStore: app, servers: [])
        #expect(Set(catalog.map(\.name)) == Set(discovered.map(\.name)))
        #expect(store.entries.filter(\.requiresImport).count == 3, "original source rows remain distinct from approved copies")
    }

    @Test func removedDirectoryCannotBeImportedThroughAStaleRow() async throws {
        let root = try skTempDir("o16-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("extra")
        try writeSkillMD(at: directory.appendingPathComponent("sample"), content: skSampleMD)
        let store = SkillsStore(
            appStore: SkillStore(skillsRoot: root.appendingPathComponent("app")),
            stateFileURL: root.appendingPathComponent("settings/skills-enabled.json"))
        #expect(store.addSkillDirectory(directory))
        await store.reloadInBackground().value
        let importableEntry = store.entries.first(where: \.requiresImport)
        let entry = try #require(importableEntry)
        #expect(store.removeSkillDirectory(directory))
        await store.reloadInBackground().value
        #expect(store.entries.isEmpty)
        guard case .failure(.invalidSource) = store.proposeDiscoveredSkill(entry) else {
            Issue.record("a removed source must not remain importable"); return
        }
    }
}
