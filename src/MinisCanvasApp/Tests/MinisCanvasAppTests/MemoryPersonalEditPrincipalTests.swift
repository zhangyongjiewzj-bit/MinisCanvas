import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Settings' real Markdown import and edit consumers; synthetic storage only.
@Suite("D-MEMORY-05 personal edit principal", .serialized)
@MainActor
struct MemoryPersonalEditPrincipalTests {
    private func fixture() throws -> (RuntimeIsolationProfile, SettingsCenter, MemoryTrustedPrincipal) {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "MemoryPersonalEdit", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let defaults = profile.makeUserDefaults()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(
                directory: profile.minisCoreDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        let verified = MemoryTrustedPrincipal.validated(
            userID: "synthetic-memory-owner", by: { $0 == "synthetic-memory-owner" })
        let principal = try #require(verified)
        center.memoryScopeProvider = { MemoryScope(sessionID: "session-a", projectID: "project-a") }
        center.memoryOwnerUserIDProvider = { principal.userID }
        center.memoryTrustedPrincipalProvider = { principal }
        return (profile, center, principal)
    }

    private func importPersonalFact(_ center: SettingsCenter) throws -> MemoryFact {
        let data = Data("## 用户偏好\n- 喜欢晴天\n".utf8)
        let preview = try center.previewMemoryMarkdown(data)
        #expect(preview.factCount == 1)
        #expect(try center.memoryStore.facts().isEmpty)
        let imported = try center.confirmMemoryMarkdownImport(preview, selecting: .personal)
        #expect(imported.added == 1)
        return try #require(center.memoryStore.activeFacts().first)
    }

    @Test func verifiedOwnerCanEditPersonalMarkdownImport() throws {
        let (profile, center, principal) = try fixture()
        defer { try? profile.cleanupDisposableRoots() }
        let original = try importPersonalFact(center)
        #expect(original.visibility == .personal)
        #expect(original.ownerUserID == principal.userID)
        let revised = try center.editMemoryFact(id: original.id, newText: "更喜欢晴天")
        #expect(revised.text == "更喜欢晴天")
        #expect(revised.revision == original.revision + 1)
        #expect(revised.supersedesFactID == original.id)
        #expect(revised.visibility == .personal)
        #expect(revised.ownerUserID == original.ownerUserID)
        #expect(revised.memoryScope == original.memoryScope)
        #expect(revised.writeProvenance == nil)
        let persisted = try MemoryStore(directory: profile.memoryDirectory).facts()
        #expect(persisted.count == 2)
        #expect(persisted.first(where: { $0.id == original.id })?.lifecycleState == .superseded)
        #expect(persisted.first(where: { $0.id == revised.id }) == revised)
        #expect(center.memoryFacts == [revised])
    }

    @Test(arguments: [false, true])
    func absentOrWrongPrincipalCannotEditPersonalFact(useWrongPrincipal: Bool) throws {
        let (profile, center, _) = try fixture()
        defer { try? profile.cleanupDisposableRoots() }
        let original = try importPersonalFact(center)
        let bytes = try Data(contentsOf: center.memoryStore.fileURL)
        let projection = center.memoryFacts
        let wrong = MemoryTrustedPrincipal.validated(userID: "other-owner", by: { $0 == "other-owner" })
        center.memoryTrustedPrincipalProvider = { useWrongPrincipal ? wrong : nil }
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try center.editMemoryFact(id: original.id, newText: "不应写入")
        }
        #expect(try Data(contentsOf: center.memoryStore.fileURL) == bytes)
        #expect(try MemoryStore(directory: profile.memoryDirectory).facts() == [original])
        #expect(center.memoryFacts == projection)
    }
}
