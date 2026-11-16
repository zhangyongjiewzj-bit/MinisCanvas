import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Actual list producer -> the preparation used by SettingsView -> existing
/// save/delete consumers, with fresh stores. This is not a visible UI journey.
@Suite("D-MEMORY-09/10 selected file editor consumer", .serialized)
@MainActor
struct MemoryFileEditorConsumer411Tests {
    enum ReadFailure: CaseIterable, Sendable {
        case invalidUTF8, removedFile, invalidRelativePath
    }

    private func makeProfile() throws -> RuntimeIsolationProfile {
        try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Memory411", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
    }

    private func makeCenter(_ profile: RuntimeIsolationProfile, defaults: UserDefaults) -> SettingsCenter {
        let keychain = profile.makeKeychainStore()
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(
                directory: profile.minisCoreDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)
            ),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL,
                                         keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        )
    }

    private func cleanup(_ profile: RuntimeIsolationProfile, defaults: UserDefaults) {
        if let suite = profile.userDefaultsSuiteName {
            defaults.removePersistentDomain(forName: suite)
        }
        try? profile.cleanupDisposableRoots()
    }

    /// Diagnostic only: mirror the existing containment comparison before any
    /// document is created. All URLs belong to this fixture's disposable root;
    /// this neither creates the missing memory directory nor admits a target.
    private func traceInitialTarget(_ store: MemoryFileStore, candidate: URL) {
        let manager = FileManager.default
        let root = store.memoryDirectory.resolvingSymlinksInPath().standardizedFileURL
        var components: [String] = []
        var ancestor = candidate.deletingLastPathComponent()
        while !manager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard ancestor.path != parent.path, !ancestor.lastPathComponent.isEmpty else {
                print("MEMORY411_TARGET_PROBE ancestorUnavailable")
                return
            }
            components.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        let physicalAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        var reconstructed = physicalAncestor
        components.append(candidate.lastPathComponent)
        for component in components {
            reconstructed.appendPathComponent(component, isDirectory: false)
        }
        let resolved = reconstructed.resolvingSymlinksInPath().standardizedFileURL
        let prefixMatches = resolved.pathComponents.starts(with: root.pathComponents)
        let isDescendant = resolved.pathComponents.count > root.pathComponents.count
        print("MEMORY411_TARGET_PROBE rootRaw=\(store.memoryDirectory.absoluteString) rootExists=\(manager.fileExists(atPath: store.memoryDirectory.path)) rootResolved=\(root.absoluteString) rootComponents=\(root.pathComponents)")
        print("MEMORY411_TARGET_PROBE candidateRaw=\(candidate.absoluteString) ancestorRaw=\(ancestor.absoluteString) ancestorResolved=\(physicalAncestor.absoluteString) reconstructed=\(reconstructed.absoluteString) resolved=\(resolved.absoluteString) resolvedComponents=\(resolved.pathComponents) prefixMatches=\(prefixMatches) isDescendant=\(isDescendant) requiresReopen=\(PersistenceTransactionFence.requiresReopen(store.persistenceDomain))")
    }

    @Test(arguments: ["GLOBAL.md", "SOUL.md"])
    func selectedDailyRowKeepsItsTargetThroughSaveDeleteAndReopen(basename: String) throws {
        let profile = try makeProfile()
        let defaults = profile.makeUserDefaults()
        defer { cleanup(profile, defaults: defaults) }
        let center = makeCenter(profile, defaults: defaults)
        let rootText = "根文件保留🧠 " + basename
        let dailyText = "同名日志内容🌱 " + basename
        let dailyPath = "daily/" + basename
        traceInitialTarget(center.memoryFileStore, candidate: center.memoryFileStore.memoryDirectory.appendingPathComponent(basename))
        traceInitialTarget(center.memoryFileStore, candidate: center.memoryFileStore.dailyDirectory.appendingPathComponent(basename))
        #expect(center.saveMemoryDocumentResult(named: basename, content: rootText) == .saved)
        #expect(center.saveMemoryDocumentResult(named: dailyPath, content: dailyText) == .saved)
        let rootURL = center.memoryFileStore.memoryDirectory.appendingPathComponent(basename)
        let rootBytes = try Data(contentsOf: rootURL)
        #expect(Set(center.memoryFiles.map(\.id)) == [basename, dailyPath])
        let daily = try #require(center.memoryFiles.first { $0.relativePath == dailyPath })
        #expect(daily.name == basename)
        #expect(daily.kind == .daily)

        let preparation = center.prepareMemoryFileEditor(daily)
        #expect(preparation == .ready(relativePath: dailyPath, content: dailyText))
        guard case .ready(let selectedPath, let content) = preparation else {
            Issue.record("生产编辑器未能准备所选日志")
            return
        }
        let edited = content + "\n用户保存的修订"
        #expect(center.saveMemoryDocumentResult(named: selectedPath, content: edited) == .saved)
        #expect(try Data(contentsOf: rootURL) == rootBytes)

        // Reconstruct the production consumer; no cached list/content is reused.
        let reopened = makeCenter(profile, defaults: defaults)
        reopened.reloadMemoryFiles()
        let restored = try #require(reopened.memoryFiles.first { $0.relativePath == dailyPath })
        #expect(restored.id == dailyPath)
        #expect(restored.kind == .daily)
        #expect(restored.byteCount == Data(edited.utf8).count)
        let recovered = reopened.prepareMemoryFileEditor(restored)
        #expect(recovered == .ready(relativePath: dailyPath, content: edited))
        guard case .ready(let deletionPath, _) = recovered else {
            Issue.record("重载后未能准备原相对路径")
            return
        }
        #expect(reopened.deleteMemoryDocumentResult(named: deletionPath) == .deleted)
        #expect(try Data(contentsOf: rootURL) == rootBytes)
        let freshStore = MemoryFileStore(directory: profile.memoryDirectory)
        #expect(freshStore.readDocument(named: dailyPath) == nil)
        #expect(freshStore.readDocument(named: basename) == rootText)
        #expect(freshStore.listFiles().map(\.relativePath) == [basename])
    }

    @Test(arguments: ReadFailure.allCases)
    func unreadableRowsCannotBecomeEmptyEditorDrafts(failure: ReadFailure) throws {
        let profile = try makeProfile()
        let defaults = profile.makeUserDefaults()
        defer { cleanup(profile, defaults: defaults) }
        let center = makeCenter(profile, defaults: defaults)
        traceInitialTarget(center.memoryFileStore, candidate: center.memoryFileStore.globalURL)
        #expect(center.saveMemoryDocumentResult(named: "GLOBAL.md", content: "原始文件") == .saved)
        var selected = try #require(center.memoryFiles.first { $0.relativePath == "GLOBAL.md" })
        let url = center.memoryFileStore.globalURL
        switch failure {
        case .invalidUTF8:
            try Data([0xff, 0xc3, 0x28]).write(to: url, options: .atomic)
        case .removedFile:
            // Only the file created by this fixture is removed.
            try FileManager.default.removeItem(at: url)
        case .invalidRelativePath:
            selected = MemoryFileInfo(
                name: selected.name, kind: selected.kind, modifiedAt: selected.modifiedAt,
                preview: selected.preview, byteCount: selected.byteCount,
                relativePath: "daily/../GLOBAL.md"
            )
        }
        let bytesBefore = try? Data(contentsOf: url)
        let listBefore = center.memoryFiles.map(\.relativePath)
        #expect(center.prepareMemoryFileEditor(selected) == .unreadable)
        #expect((try? Data(contentsOf: url)) == bytesBefore)
        #expect(center.memoryFiles.map(\.relativePath) == listBefore)
        #expect(!FileManager.default.fileExists(atPath: center.memoryFileStore.dailyDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: center.memoryStore.fileURL.path))
    }

    @Test func anExistingEmptyFileStillPreparesAnEditor() throws {
        let profile = try makeProfile()
        let defaults = profile.makeUserDefaults()
        defer { cleanup(profile, defaults: defaults) }
        let center = makeCenter(profile, defaults: defaults)
        traceInitialTarget(center.memoryFileStore, candidate: center.memoryFileStore.soulURL)
        #expect(center.saveMemoryDocumentResult(named: "SOUL.md", content: "") == .saved)
        let file = try #require(center.memoryFiles.first { $0.relativePath == "SOUL.md" })
        #expect(center.prepareMemoryFileEditor(file) == .ready(relativePath: "SOUL.md", content: ""))
        #expect(try Data(contentsOf: center.memoryFileStore.soulURL).isEmpty)
    }
}
