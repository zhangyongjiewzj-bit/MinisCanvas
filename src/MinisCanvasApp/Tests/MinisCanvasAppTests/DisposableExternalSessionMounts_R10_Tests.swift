import Foundation
import Testing
import MinisCore
import Darwin
@testable import MinisCanvasApp

/// R10: a disposable (isolatedTest / packagedField) profile must carry its own
/// settings' qualifying external-session mounts that lie inside its own root.
/// These tests observe the real assembly path (attachCurrentProductionConfiguration)
/// through the builtin executor's additionalAllowedRoots and the tool result.
@Suite(.serialized)
struct DisposableExternalSessionMounts_R10_Tests {
    private func findBuiltin(in executor: any ToolExecutor) -> BuiltinToolExecutor? {
        if let builtin = executor as? BuiltinToolExecutor { return builtin }
        if let concurrent = executor as? ConcurrentToolLimitingExecutor {
            return findBuiltin(in: concurrent.baseBox.value)
        }
        if let recording = executor as? RecordingToolExecutor {
            return findBuiltin(in: recording.base)
        }
        for child in Mirror(reflecting: executor).children where child.label == "base" {
            if let nested = child.value as? any ToolExecutor, let found = findBuiltin(in: nested) {
                return found
            }
        }
        return nil
    }

    private func real(_ url: URL) -> String {
        guard let r = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(r) }
        return String(cString: r)
    }

    @MainActor
    private func assemble(
        label: String,
        mounts: (RuntimeIsolationProfile) throws -> [String],
        arguments: [String] = []
    ) async throws -> (roots: [String], read: String, profile: RuntimeIsolationProfile) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: label, processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
        }
        let keychain = profile.makeKeychainStore()
        let logManager = profile.makeLogManager()
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: logManager,
            mcpManager: MCPServerManager(
                fileURL: profile.mcpDirectory.appendingPathComponent("mcps.json"),
                keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(
                directory: profile.providerConfigurationDirectory
            )
        )
        center.mountedFolderPaths = try mounts(profile)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: logManager,
            workflowStore: WorkflowStore(
                storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")
            ),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            memoryStore: center.memoryStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        ProductionOrchestrationDefaults.attachCurrentProductionConfiguration(
            to: bridge, settings: center, profile: profile,
            childConcurrencySelection: center.childConcurrencySelection,
            arguments: arguments
        )
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let builtin = try #require(findBuiltin(in: engine.composedExecutor))
        var text = ""
        do {
            text = try await builtin.execute(name: "external_session_read", input: [:])
        } catch {
            text = "\(error) \(error.localizedDescription)"
        }
        return (builtin.additionalAllowedRoots.map { real($0) }, text, profile)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Case 1 (RED on baseline: mounts are forced empty for disposable profiles).
    @Test @MainActor func qualifyingInRootMountIsAuthorizedEndToEnd() async throws {
        var fixture: URL?
        let result = try await assemble(label: "R10in") { profile in
            let dir = profile.rootDirectory.appendingPathComponent("extfix/home/.codex/sessions")
            try makeDir(dir)
            fixture = dir
            return [dir.path]
        }
        defer { try? result.profile.cleanupDisposableRoots() }
        let dir = try #require(fixture)
        #expect(result.roots.contains(real(dir)))
        #expect(!result.read.contains("no_authorized_root"))
    }

    /// Case 2: a qualifying directory outside the profile root stays unauthorized.
    @Test @MainActor func qualifyingOutOfRootMountIsNotAuthorized() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("R10out-\(UUID().uuidString)/home/.codex/sessions")
        try makeDir(outside)
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let result = try await assemble(label: "R10out") { _ in [outside.path] }
        defer { try? result.profile.cleanupDisposableRoots() }
        #expect(!result.roots.contains(real(outside)))
        #expect(result.read.contains("no_authorized_root"))
    }

    /// Case 3: in-root but non-qualifying folders are not authorized.
    @Test @MainActor func inRootNonQualifyingMountsAreNotAuthorized() async throws {
        let result = try await assemble(label: "R10nq") { profile in
            let parent = profile.rootDirectory.appendingPathComponent("extfix/home/.codex")
            let plain = profile.rootDirectory.appendingPathComponent("extfix/plain")
            try makeDir(parent.appendingPathComponent("sessions"))
            try makeDir(plain)
            return [profile.rootDirectory.path, parent.path, plain.path]
        }
        defer { try? result.profile.cleanupDisposableRoots() }
        let base = real(result.profile.rootDirectory)
        #expect(!result.roots.contains(where: { $0 == base || $0.hasPrefix(base + "/extfix") }))
        #expect(result.read.contains("no_authorized_root"))
    }

    /// Case 4: an in-root symlinked parent that leads to a qualifying folder outside the root.
    @Test @MainActor func symlinkToOutOfRootQualifyingFolderIsNotAuthorized() async throws {
        let outsideHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("R10link-\(UUID().uuidString)", isDirectory: true)
        try makeDir(outsideHome.appendingPathComponent(".codex/sessions"))
        defer { try? FileManager.default.removeItem(at: outsideHome) }
        let result = try await assemble(label: "R10ln") { profile in
            let link = profile.rootDirectory.appendingPathComponent("linkhome")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideHome)
            return [link.appendingPathComponent(".codex/sessions").path]
        }
        defer { try? result.profile.cleanupDisposableRoots() }
        #expect(!result.roots.contains(real(outsideHome.appendingPathComponent(".codex/sessions"))))
        #expect(!result.roots.contains(real(outsideHome)))
        #expect(result.read.contains("no_authorized_root"))
    }
}
