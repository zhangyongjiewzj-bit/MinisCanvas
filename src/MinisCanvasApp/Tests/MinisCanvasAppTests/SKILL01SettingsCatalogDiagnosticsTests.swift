import Darwin
import Dispatch
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SKILL-01 Settings catalog diagnostics")
struct SKILL01SettingsCatalogDiagnosticsTests {
    @Test @MainActor func settingsReloadWaitsForBriefWriterThenKeepsCommittedAppSkillVisible() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK01-shared-read-\(UUID().uuidString)", isDirectory: true)
        let appRoot = fixture.appendingPathComponent("app-skills", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
        let seeded = SkillStore(skillsRoot: appRoot)
        let skill = try seeded.importSkill(
            content: "---\nname: Committed Reader\nversion: 1.0.0\n---\nsynthetic body",
            source: .file
        )
        let lockURL = seeded.skillDirectoryURL(for: skill.id)
            .appendingPathComponent(".skill-import.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            Issue.record("合成技能的导入锁文件无法打开")
            return
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            Issue.record("合成技能的排他写入锁无法持有")
            return
        }
        let released = DispatchGroup()
        released.enter()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            released.leave()
        }

        let settingsStore = SkillsStore(
            appStore: SkillStore(skillsRoot: appRoot),
            stateFileURL: fixture.appendingPathComponent("skills-enabled.json")
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            released.notify(queue: .global(qos: .userInitiated)) { @Sendable in continuation.resume() }
        }
        #expect(settingsStore.entries.map(\.id) == ["app:\(skill.id)"])
        #expect(settingsStore.entries.first?.isEnabled == true)

        // The Settings refresh button uses this existing detached scan. A
        // competing short writer must not make the MainActor button wait for
        // the import lock, while the eventual projection still includes the
        // committed skill.
        let refreshDescriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard refreshDescriptor >= 0 else {
            Issue.record("合成技能的刷新锁文件无法打开")
            return
        }
        guard flock(refreshDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(refreshDescriptor)
            Issue.record("合成技能的刷新排他锁无法持有")
            return
        }
        let refreshReleased = DispatchGroup()
        refreshReleased.enter()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            _ = flock(refreshDescriptor, LOCK_UN)
            _ = Darwin.close(refreshDescriptor)
            refreshReleased.leave()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let refresh = settingsStore.reloadInBackground()
        let schedulingElapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(schedulingElapsed < 0.5)
        await refresh.value
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshReleased.notify(queue: .global(qos: .userInitiated)) { @Sendable in continuation.resume() }
        }
        #expect(settingsStore.entries.map(\.id) == ["app:\(skill.id)"])
        #expect(settingsStore.entries.first?.isEnabled == true)
    }

    @Test @MainActor func settingsReportExplainsMissingAndDamagedHermesSkillsWithoutListingThem() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK01-settings-\(UUID().uuidString)", isDirectory: true)
        let hermesRoot = fixture.appendingPathComponent("hermes-skills", isDirectory: true)
        let appRoot = fixture.appendingPathComponent("app-skills", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: hermesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)

        let good = hermesRoot.appendingPathComponent("valid", isDirectory: true)
        let missing = hermesRoot.appendingPathComponent("missing", isDirectory: true)
        let damaged = hermesRoot.appendingPathComponent("damaged", isDirectory: true)
        for directory in [good, missing, damaged] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "---\nname: Valid\nversion: 1.0.0\n---\nbody".write(
            to: good.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "fixture only".write(
            to: missing.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try "---\nname: Damaged\nNAME: duplicate\nversion: 1.0.0\n---\nSECRET_BODY".write(
            to: damaged.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let settingsStore = SkillsStore(
            appStore: SkillStore(skillsRoot: appRoot),
            stateFileURL: fixture.appendingPathComponent("skills-enabled.json")
        )
        _ = settingsStore.addSkillDirectory(hermesRoot)
        settingsStore.reload()

        #expect(settingsStore.entries.map(\.name) == ["Valid"])
        #expect(settingsStore.catalogRefreshStatus == .degraded)
        #expect(settingsStore.catalogDiagnostics.rejectedCount == 2)
        #expect(settingsStore.catalogDiagnostics.counts[.missingDocument] == 1)
        #expect(settingsStore.catalogDiagnostics.counts[.documentRejected] == 1)
        #expect(settingsStore.catalogDiagnostics.userMessages.contains(
            "本地技能库 · missing：缺少 SKILL.md，未加入技能列表"
        ))
        #expect(settingsStore.catalogDiagnostics.userMessages.contains(
            "本地技能库 · damaged：SKILL.md 内容损坏或格式无效，未加入技能列表"
        ))
        #expect(settingsStore.catalogDiagnostics.userMessages.allSatisfy {
            !$0.contains(fixture.path) && !$0.contains("SECRET_BODY")
        })
    }

    @Test func categoryAndAssetFoldersAreNotMistakenForMissingSkills() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK01-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("creative/valid", isDirectory: true)
        let assets = skill.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "---\nname: Valid\nversion: 1.0.0\n---\nbody".write(
            to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "asset".write(
            to: assets.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )

        let result = SkillsScanner.scanLocalDirectoryWithDiagnostics(root: root)
        #expect(result.entries.map(\.name) == ["Valid"])
        #expect(result.diagnostics.rejectedCount == 0)
    }

    @Test func absentOptionalHermesRootIsEmptyWithoutAnErrorBanner() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SK01-absent-\(UUID().uuidString)", isDirectory: true)
        let result = SkillsScanner.scanLocalDirectoryWithDiagnostics(root: missingRoot)
        #expect(result.entries.isEmpty)
        #expect(result.diagnostics.rejectedCount == 0)
    }
}
