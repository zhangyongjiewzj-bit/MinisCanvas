import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Production sheet initialization and file consumers, without mounting a GUI.
/// The separate owned UI cold-reopen failure remains evidence for field retest.
@Suite("D-MEMORY-10 cold file editor content", .serialized)
@MainActor
struct MemoryFileEditorColdReopen0845Tests {
    private func makeProfile() throws -> RuntimeIsolationProfile {
        try RuntimeIsolationProfile.makeIsolatedTest(
            label: "MemoryEditor0845", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
    }

    private func makeCenter(_ profile: RuntimeIsolationProfile, defaults: UserDefaults) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
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


    private func open(_ center: SettingsCenter, path: String) throws -> MemoryFileEditorSheet {
        center.reloadMemoryFiles()
        let file = try #require(center.memoryFiles.first { $0.relativePath == path })
        let preparation = center.prepareMemoryFileEditor(file)
        guard case .ready(let relativePath, let content) = preparation else {
            throw EditorPreparationFailure.unreadable
        }
        let presentation = MemoryFileEditorPresentation(fileName: relativePath, content: content)
        return MemoryFileEditorSheet(
            presentation: presentation,
            onSave: { center.saveMemoryDocumentResult(named: $0, content: $1) },
            onDelete: { center.deleteMemoryDocumentResult(named: $0) }
        )
    }

    private enum EditorPreparationFailure: Error { case unreadable }

    @Test(arguments: ["GLOBAL.md", "daily/GLOBAL.md", "SOUL.md"])
    func freshEditorStartsWithSavedBytesBeforeAppearance(path: String) throws {
        let profile = try makeProfile()
        let defaults = profile.makeUserDefaults()
        let center = makeCenter(profile, defaults: defaults)
        let original = path == "SOUL.md" ? "" : "# owned memory\n冷读文本🧠\n" + path
        let sibling = path == "GLOBAL.md" ? "SOUL.md" : "GLOBAL.md"
        #expect(center.saveMemoryDocumentResult(named: sibling, content: "另一个文件保留") == .saved)
        #expect(center.saveMemoryDocumentResult(named: path, content: original) == .saved)
        let url = center.memoryFileStore.memoryDirectory.appendingPathComponent(path)
        let siblingURL = center.memoryFileStore.memoryDirectory.appendingPathComponent(sibling)
        let siblingBytes = try Data(contentsOf: siblingURL)
        #expect(try Data(contentsOf: url) == Data(original.utf8))

        // A new SettingsCenter is the cold consumer; no producer's cached draft is reused.
        let reopened = makeCenter(profile, defaults: defaults)
        let sheet = try open(reopened, path: path)
        #expect(sheet.fileName == path)
        #expect(sheet.editedContent == original)
        #expect(Data(sheet.editedContent.utf8) == (try Data(contentsOf: url)))
        let revised = sheet.editedContent + "\n正常保存的修订"
        #expect(sheet.onSave(sheet.fileName, revised) == .saved)
        #expect(try Data(contentsOf: url) == Data(revised.utf8))
        #expect(try Data(contentsOf: siblingURL) == siblingBytes)

        let coldAgain = makeCenter(profile, defaults: defaults)
        let secondSheet = try open(coldAgain, path: path)
        #expect(secondSheet.fileName == path)
        #expect(secondSheet.editedContent == revised)
        #expect(try Data(contentsOf: siblingURL) == siblingBytes)
        #expect(secondSheet.onDelete(secondSheet.fileName) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: siblingURL) == siblingBytes)
        let final = makeCenter(profile, defaults: defaults)
        final.reloadMemoryFiles()
        #expect(final.memoryFiles.map(\.relativePath) == [sibling])
        #expect(final.readMemoryDocument(named: sibling) == "另一个文件保留")
        #expect(final.readMemoryDocument(named: path) == nil)

        let firstPresentation = MemoryFileEditorPresentation(fileName: path, content: revised)
        let nextPresentation = MemoryFileEditorPresentation(fileName: sibling, content: "另一个文件保留")
        #expect(firstPresentation.id != nextPresentation.id)
        #expect(firstPresentation.fileName == path)
        #expect(nextPresentation.content == "另一个文件保留")
        print("MEMORY0845_COLD_EDITOR case=\(path) originalBytes=\(original.utf8.count) revisedBytes=\(revised.utf8.count) root=\(profile.rootDirectory.path)")
    }

    @Test func failedSaveAndDeleteKeepOriginalFileAndEditorContent() throws {
        let profile = try makeProfile()
        let defaults = profile.makeUserDefaults()
        let center = makeCenter(profile, defaults: defaults)
        let original = "不能被失败保存清空的记忆🧠"
        #expect(center.saveMemoryDocumentResult(named: "GLOBAL.md", content: original) == .saved)
        #expect(center.saveMemoryDocumentResult(named: "SOUL.md", content: "邻文件") == .saved)
        let fresh = makeCenter(profile, defaults: defaults)
        let sheet = try open(fresh, path: "GLOBAL.md")
        let bytes = try Data(contentsOf: fresh.memoryFileStore.globalURL)
        let siblingBytes = try Data(contentsOf: fresh.memoryFileStore.soulURL)
        let rows = fresh.memoryFiles.map(\.relativePath)
        let directory = fresh.memoryFileStore.memoryDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let save = sheet.onSave(sheet.fileName, "失败的新内容")
        #expect(save == .saveFailed)
        #expect(!save.succeeded)
        #expect(save.message(for: sheet.fileName).contains("保存失败"))
        let deletion = sheet.onDelete(sheet.fileName)
        #expect(deletion == .deleteFailed)
        #expect(!deletion.succeeded)
        #expect(deletion.message(for: sheet.fileName).contains("删除失败"))
        #expect(sheet.editedContent == original)
        #expect(try Data(contentsOf: fresh.memoryFileStore.globalURL) == bytes)
        #expect(try Data(contentsOf: fresh.memoryFileStore.soulURL) == siblingBytes)
        #expect(fresh.memoryFiles.map(\.relativePath) == rows)
        let reopened = makeCenter(profile, defaults: defaults)
        let recovered = try open(reopened, path: "GLOBAL.md")
        #expect(recovered.editedContent == original)
        #expect(reopened.memoryFiles.map(\.relativePath) == rows)
        print("MEMORY0845_FAILED_OPERATIONS root=\(profile.rootDirectory.path) originalBytes=\(bytes.count)")
    }
}
