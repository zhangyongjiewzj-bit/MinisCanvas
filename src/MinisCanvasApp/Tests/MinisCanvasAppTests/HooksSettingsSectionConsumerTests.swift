import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Hooks settings configuration reaches the real local runtime", .serialized)
@MainActor
struct HooksSettingsSectionConsumerTests {
    @Test func packagedFieldHookConfigurationAndTrustStayInTheOwnedSettingsDirectory() throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-packaged-field-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fieldRoot = root.appendingPathComponent("field-profile", isDirectory: true)
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "hooks-owned-store",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: fieldRoot.path],
            processArguments: ["/Applications/MinisCanvas.app/Contents/MacOS/MinisCanvas",
                RuntimeIsolationProfile.fieldActivationArgument])
        defer { try? profile.cleanupDisposableRoots() }
        let sibling = root.appendingPathComponent("other-owned-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let siblingConfig = sibling.appendingPathComponent(HookConfigStore.userFileName)
        let siblingTrust = sibling.appendingPathComponent(HookConfigStore.trustFileName)
        let configSentinel = Data("owned sibling configuration sentinel".utf8)
        let trustSentinel = Data("owned sibling trust sentinel".utf8)
        try configSentinel.write(to: siblingConfig)
        try trustSentinel.write(to: siblingTrust)
        let directory = profile.settingsDirectory.appendingPathComponent("hooks", isDirectory: true)
        #expect(profile.mode == .packagedField)
        #expect(directory.path.hasPrefix(profile.rootDirectory.path + "/"))
        #expect(directory != sibling)
        // This exercises the real profile/store/controller composition;
        // the App installation call itself is reviewed separately, not
        // relabelled as a field startup inside a formal native test.
        let store = HookConfigStore(directory: directory)
        let runtime = HookRuntime(store: store, environment: { [:] })
        let settings = HooksSettingsController(runtime: runtime)
        #expect(settings.add(event: .userPromptSubmit, matcher: "", command: "printf owned-field-hook",
            timeoutText: "2"))
        let reviewed = try #require(settings.userSnapshot)
        #expect(reviewed.needsTrustDecision)
        settings.trust(reviewed, userLevel: true)
        #expect(settings.userSnapshot?.trust == .trusted)
        let expectedHooks = store.loadUserHooks()
        #expect(expectedHooks.hooks.count == 1 && expectedHooks.error == nil)
        let cold = HookConfigStore(directory: directory)
        #expect(cold.loadUserHooks() == expectedHooks)
        #expect(cold.userHooksSnapshot().trust == .trusted)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(HookConfigStore.userFileName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(HookConfigStore.trustFileName).path))
        #expect(runtime.recentRuns().isEmpty, "configuration and trust checks must not execute a hook")
        #expect(try Data(contentsOf: siblingConfig) == configSentinel)
        #expect(try Data(contentsOf: siblingTrust) == trustSentinel)
    }

    @Test func userHookSettingsTrustEnableAndDeleteControlTheNextExecution() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("hooks-settings-user") { root async throws -> Void in
            let directory = root.appendingPathComponent("hook-settings")
            let store = HookConfigStore(directory: directory)
            let runtime = HookRuntime(store: store, environment: { [:] })
            let settings = HooksSettingsController(runtime: runtime)
            let command = "/usr/bin/printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"OWNED_USER_HOOK_CONTEXT\"}}'"
            #expect(settings.add(event: .userPromptSubmit, matcher: "", command: command, timeoutText: "2"))
            let row = try #require(settings.userRows.first)
            #expect(settings.userRows.count == 1 && row.definition.enabled)
            let untrusted = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(untrusted.additionalContext == nil && runtime.recentRuns().isEmpty)
            settings.trust(try #require(settings.userSnapshot), userLevel: true)
            #expect(settings.userSnapshot?.trust == .trusted)
            let trusted = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(trusted.additionalContext == "OWNED_USER_HOOK_CONTEXT")
            #expect(runtime.recentRuns().count == 1)
            #expect(runtime.recentRuns().first?.source == .user)
            #expect(runtime.recentRuns().first?.status == .completed)
            settings.revoke(try #require(settings.userSnapshot), userLevel: true)
            #expect(settings.userSnapshot?.needsTrustDecision == true)
            let revoked = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(revoked.additionalContext == nil && runtime.recentRuns().count == 1)
            #expect(HookConfigStore(directory: directory).userHooksSnapshot().needsTrustDecision)
            // Restore the same reviewed owned hook, then retain all original
            // enable/disable/delete execution checks and their exact counts.
            settings.trust(try #require(settings.userSnapshot), userLevel: true)
            #expect(settings.userSnapshot?.trust == .trusted)
            settings.setEnabled(id: row.id, enabled: false)
            #expect(settings.userRows.first?.definition.enabled == false)
            let disabled = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(disabled.additionalContext == nil && runtime.recentRuns().count == 1)
            settings.setEnabled(id: row.id, enabled: true)
            settings.trust(try #require(settings.userSnapshot), userLevel: true)
            let enabled = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(enabled.additionalContext == "OWNED_USER_HOOK_CONTEXT" && runtime.recentRuns().count == 2)
            settings.remove(id: row.id)
            #expect(settings.userRows.isEmpty)
            let removed = await runtime.beginTurn(sessionID: "owned-user", prompt: "owned prompt", projectRoot: nil)
            #expect(removed.additionalContext == nil && runtime.recentRuns().count == 2)
            #expect(HookConfigStore(directory: directory).loadUserHooks().hooks.isEmpty)
        }
    }

    @Test func projectTrustAndRevocationChangeTheSameSessionsNextExecution() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("hooks-settings-project") { root async throws -> Void in
            let project = root.appendingPathComponent("owned-project")
            let config = project.appendingPathComponent(HookConfigStore.projectRelativePath)
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hook = HookDefinition(id: "owned-project-hook", event: .userPromptSubmit,
                command: "/usr/bin/printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"OWNED_PROJECT_HOOK_CONTEXT\"}}'",
                timeoutSeconds: 2)
            try JSONEncoder().encode(HookConfigurationFile(hooks: [hook])).write(to: config)
            let store = HookConfigStore(directory: root.appendingPathComponent("hook-settings"))
            let runtime = HookRuntime(store: store, environment: { [:] })
            let settings = HooksSettingsController(runtime: runtime)
            let before = await runtime.beginTurn(sessionID: "owned-project", prompt: "owned prompt", projectRoot: project)
            #expect(before.additionalContext == nil && runtime.recentRuns().isEmpty)
            settings.refresh()
            let preview = try #require(settings.projectRows.first?.snapshot)
            #expect(preview.projectRoot == project.standardizedFileURL.resolvingSymlinksInPath().path)
            #expect(preview.needsTrustDecision && preview.outsideReferences.isEmpty)
            settings.trust(preview)
            #expect(settings.projectRows.first?.snapshot.trust == .trusted)
            let trusted = await runtime.beginTurn(sessionID: "owned-project", prompt: "owned prompt", projectRoot: project)
            #expect(trusted.additionalContext == "OWNED_PROJECT_HOOK_CONTEXT")
            #expect(runtime.recentRuns().count == 1 && runtime.recentRuns().first?.source == .project)
            settings.revoke(try #require(settings.projectRows.first?.snapshot))
            let revoked = await runtime.beginTurn(sessionID: "owned-project", prompt: "owned prompt", projectRoot: project)
            #expect(revoked.additionalContext == nil && runtime.recentRuns().count == 1)
            #expect(store.projectSnapshot(projectRoot: project).needsTrustDecision)
            #expect(HookConfigStore(directory: store.directory).projectSnapshot(projectRoot: project).needsTrustDecision)
        }
    }
}
