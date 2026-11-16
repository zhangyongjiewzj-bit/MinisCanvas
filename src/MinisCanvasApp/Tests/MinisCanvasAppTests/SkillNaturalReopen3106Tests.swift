import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("SKILL04 canonical catalog writer and natural reopen", .serialized)
struct SkillNaturalReopen3106Tests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-reopen3106-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func content(_ id: String) -> String {
        "---\nname: \(id)\nversion: 1.0.0\ndescription: controlled reopen3106\n---\nSynthetic constraint \(id)."
    }

    /// An actual file writer owns the production flock. Its uncommitted sidecar
    /// is deliberately unreadable as UTF-8, so ignoring the lock deterministically
    /// drops this skill. The original descriptor rejection must remain intact.
    private func whileWriterCommits(
        store: SkillStore, id: String, scan: () -> Void
    ) async throws {
        let directory = store.skillDirectoryURL(for: id)
        let manifest = directory.appendingPathComponent("manifest.json")
        let committed = try Data(contentsOf: manifest)
        let skillHash = SkillManifest.hash(try String(
            contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8))
        let descriptor = Darwin.open(directory.appendingPathComponent(".skill-import.lock").path,
                                     O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        do { try Data([0xC3, 0x28]).write(to: manifest, options: .atomic) }
        catch {
            _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor)
            throw error
        }
        #expect(SkillCatalogFileSnapshot.read(skillDirectory: directory,
                                              within: store.skillsRoot) == nil)
        let writer = Task.detached {
            defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
            try await Task.sleep(for: .milliseconds(150))
            try committed.write(to: manifest, options: .atomic)
        }
        scan()
        try await writer.value
        #expect(try Data(contentsOf: manifest) == committed)
        #expect(SkillManifest.hash(try String(
            contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)) == skillHash)
    }

    @Test func bothOriginalAppConsumersWaitForCommittedWriterWithoutLosingSkill() async throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = SkillStore(skillsRoot: fixture.appendingPathComponent("skills"))
        let skill = try store.importSkill(content: content("manju-aesthetic"))
        try await whileWriterCommits(store: store, id: skill.id) {
            let result = SkillsScanner.scanAppWithDiagnostics(store: store)
            #expect(result.entries.map(\.id) == ["app:\(skill.id)"])
            #expect(result.diagnostics.rejectedCount == 0)
        }
        try await whileWriterCommits(store: store, id: skill.id) {
            let result = SkillCatalogLoader.storeSkillItemsWithDiagnostics(from: store)
            #expect(result.items.map(\.id) == ["skill:\(skill.id)"])
            #expect(result.diagnostics.rejectedCount == 0)
        }
    }

    @Test func persistentUnsafeSidecarAndReplacedRootStillFailClosed() throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = SkillStore(skillsRoot: fixture.appendingPathComponent("skills"))
        let skill = try store.importSkill(content: content("manju-aesthetic"))
        let directory = store.skillDirectoryURL(for: skill.id)
        let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(store.skillsRoot))
        let directoryIdentity = try #require(SkillFilesystemBoundary.trustedDirectoryIdentity(
            directory, within: store.skillsRoot))
        try Data([0xC3, 0x28]).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        #expect(SkillsScanner.scanAppWithDiagnostics(store: store).entries.isEmpty)
        #expect(SkillCatalogLoader.storeSkillItemsWithDiagnostics(from: store).items.isEmpty)
        #expect(SkillCatalogFileSnapshot.read(skillDirectory: directory, within: store.skillsRoot) == nil)
        let preserved = fixture.appendingPathComponent("preserved-old-root")
        try FileManager.default.moveItem(at: store.skillsRoot, to: preserved)
        try FileManager.default.createDirectory(at: store.skillsRoot, withIntermediateDirectories: true)
        let replacement = SkillStore(skillsRoot: store.skillsRoot)
        _ = try replacement.importSkill(content: content("manju-aesthetic"))
        #expect(store.catalogFileSnapshot(for: skill.id, expectedRootIdentity: rootIdentity,
            expectedSkillDirectoryIdentity: directoryIdentity,
            waitUntil: ProcessInfo.processInfo.systemUptime + 2.0) == nil)
    }

    @Test func threeFreshCanonicalStoresAndOriginalDeploymentsKeepEightSkillsAndApproval() async throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("owned-source")
        let skills = fixture.appendingPathComponent("skills")
        let names = ["manju-aesthetic", "manju-asset", "manju-core", "manju-learn",
                     "manju-storyboard", "manju-video", "manju-weixian-lock", "synthetic3106"]
        let seeded = SkillStore(skillsRoot: skills)
        var receipts: [String: SkillLifecycleReceipt] = [:]
        for id in names {
            let leaf = source.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
            try content(id).write(to: leaf.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            let result = try seeded.importSkillThroughLifecycle(content: content(id), source: .bundled,
                reason: "controlled3106 approval", approval: SkillApproval(approverID: "controlled3106"))
            receipts[id] = result.receipt
        }
        try #require(seeded.setEnabled("manju-aesthetic", enabled: false))
        let hashes = try Dictionary(uniqueKeysWithValues: names.map { id in
            (id, SkillManifest.hash(try #require(seeded.rawContent(id))))
        })
        for _ in 0..<3 {
            let reopened = SkillStore(skillsRoot: skills)
            let deployment = SkillStoreReadiness.Deployment(store: reopened)
            let terminal = await deployment.task.value
            guard case .ready = terminal.status else {
                Issue.record("canonical store readiness failed after unchanged reopen")
                return
            }
            let settings = SkillsScanner.scanAppWithDiagnostics(store: reopened)
            let composer = SkillCatalogLoader.storeSkillItemsWithDiagnostics(from: reopened)
            #expect(Set(settings.entries.map(\.id)) == Set(names.map { "app:\($0)" }))
            #expect(Set(composer.items.map(\.id)) == Set(names.map { "skill:\($0)" }))
            #expect(settings.diagnostics.rejectedCount == 0 && composer.diagnostics.rejectedCount == 0)
            #expect(settings.entries.first { $0.id == "app:manju-aesthetic" }?.isEnabled == false)
            let available = SkillCatalogLoader.loadCatalog(appStore: reopened,
                 servers: [])
            #expect(Set(available.map(\.id)) == Set(names.filter { $0 != "manju-aesthetic" }.map { "skill:\($0)" }))
            for id in names {
                #expect(reopened.lifecycleReceipt(for: id) == receipts[id])
                #expect(SkillManifest.hash(try #require(reopened.rawContent(id))) == hashes[id])
            }
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func failedBootstrapRefreshDoesNotPublishAnEmptyReadyCatalog(background: Bool) async throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let blockedRoot = fixture.appendingPathComponent("skills")
        try Data("owned blocking file".utf8).write(to: blockedRoot)
        let appStore = SkillStore.startForAppBootstrap(skillsRoot: blockedRoot)
        await appStore.waitForInitialLoad()
        try #require(!appStore.isInitialLoadComplete)
        let settings = SkillsStore(appStore: appStore,
            stateFileURL: fixture.appendingPathComponent("enabled.json"), loadImmediately: false)
        let before = settings.entries
        if background {
            await settings.reloadInBackground().value
        } else {
            settings.reload()
        }
        #expect(settings.entries == before)
        #expect(settings.catalogRefreshStatus != .ready)
        #expect(settings.catalogRefreshStatus != .refreshing)
        #expect(settings.catalogRefreshStatus == .invalidated)
        #expect(!appStore.isInitialLoadComplete)
    }

    @MainActor
    @Test func successfulBootstrapRefreshListsTheApprovedSkill() async throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let appStore = SkillStore.startForAppBootstrap(
            skillsRoot: fixture.appendingPathComponent("skills"))
        await appStore.waitForInitialLoad()
        try #require(appStore.isInitialLoadComplete)
        let approved = try appStore.importSkillThroughLifecycle(
            content: content("ready-refresh"), source: .file,
            reason: "owned ready refresh approval",
            approval: SkillApproval(approverID: "ready-refresh"))
        let settings = SkillsStore(appStore: appStore,
            stateFileURL: fixture.appendingPathComponent("enabled.json"), loadImmediately: false)
        settings.reload()
        #expect(settings.entries.map(\.id) == ["app:\(approved.skill.id)"])
        #expect(settings.catalogRefreshStatus == .ready)
        await settings.reloadInBackground().value
        #expect(settings.entries.map(\.id) == ["app:\(approved.skill.id)"])
        #expect(settings.catalogRefreshStatus == .ready)
    }

    @Test func failedBootstrapDeploymentDoesNotPublishReadyOrAnExecutableCapture() async throws {
        let fixture = try root()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let blockedRoot = fixture.appendingPathComponent("skills")
        try Data("owned blocking file".utf8).write(to: blockedRoot)
        let appStore = SkillStore.startForAppBootstrap(skillsRoot: blockedRoot)
        let deployment = SkillStoreReadiness.Deployment(store: appStore)
        let prepared = await deployment.task.value
        #expect(!appStore.isInitialLoadComplete)
        #expect(prepared.status == .failed(failures: 1))
        #expect(prepared.injector == nil)
        #expect(prepared.terminalCapture == nil)
        #expect(deployment.hasFailed)
        #expect(await deployment.preparationForTurn().capture() == nil)
    }

}
