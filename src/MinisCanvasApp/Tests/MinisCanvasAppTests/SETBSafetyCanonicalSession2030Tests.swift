import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-SETB safety canonical and session boundary", .serialized)
@MainActor
struct SETBSafetyCanonicalSession2030Tests {
    private func makeCenter(root: URL, defaults: UserDefaults) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("setb2030-" + root.lastPathComponent)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(
                directory: root.appendingPathComponent("readiness")))
    }

    @Test("failed safety relaxation cannot create a live shadow; reopen and reset use canonical state")
    func failedRelaxationStaysBlockedAcrossLiveAndReopenedConsumer() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "setb2030", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        let center = makeCenter(root: root, defaults: defaults)
        let snapshot = TerminalContextSnapshot(
            sessionID: "synthetic-session", turnID: "synthetic-turn",
            taskID: "synthetic-task", projectID: "synthetic-project", workdir: root.path)
        func request(_ center: SettingsCenter) -> TerminalExecutionRequest {
            TerminalContextPanelAdapter(snapshot: snapshot, settings: center)
                .makeRequest(command: "pwd", cwd: root.path, approved: false)
        }

        #expect(request(center).capabilityID == "shell_execute")
        center.enableSafeMode()
        #expect(center.lastPersistenceError == nil)
        let frozenBlockedRequest = request(center)
        #expect(frozenBlockedRequest.capabilityID.isEmpty)

        let settingsURL = center.settingsStore.fileURL
        let canonicalBytes = try Data(contentsOf: settingsURL)
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        center.disableSafeMode()
        #expect(center.lastPersistenceError == .writeFailed)
        #expect(center.safeModeEnabled)
        #expect(request(center).capabilityID.isEmpty)

        try FileManager.default.removeItem(at: settingsURL)
        try canonicalBytes.write(to: settingsURL, options: .atomic)
        let reopened = makeCenter(root: root, defaults: defaults)
        #expect(reopened.safeModeEnabled)
        #expect(request(reopened).capabilityID.isEmpty)
        reopened.restoreSafetyControlDefaults()
        #expect(reopened.lastPersistenceError == nil)
        #expect(request(reopened).capabilityID == "shell_execute")
        #expect(frozenBlockedRequest.capabilityID.isEmpty)
        #expect(!makeCenter(root: root, defaults: defaults).safeModeEnabled)

        // D-SAFE3 still requires an offline, synchronous emergency stop. A
        // failed write must report the lost durability without delaying the
        // stronger live session effect or making it a hidden success.
        let defaultBytes = try Data(contentsOf: settingsURL)
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        reopened.engageKillSwitch()
        #expect(reopened.lastPersistenceError == .writeFailed)
        #expect(reopened.killSwitchEnabled)
        #expect(request(reopened).capabilityID.isEmpty)
        reopened.restoreSafetyControlDefaults()
        #expect(reopened.lastPersistenceError == .writeFailed)
        #expect(reopened.killSwitchEnabled)
        #expect(request(reopened).capabilityID.isEmpty)
        try FileManager.default.removeItem(at: settingsURL)
        try defaultBytes.write(to: settingsURL, options: .atomic)
        #expect(!makeCenter(root: root, defaults: defaults).killSwitchEnabled)
        reopened.engageKillSwitch() // Same effective value, but retry the failed canonical save.
        #expect(reopened.lastPersistenceError == nil)
        #expect(reopened.killSwitchEnabled)
        #expect(makeCenter(root: root, defaults: defaults).killSwitchEnabled)
        reopened.restoreSafetyControlDefaults()
        #expect(reopened.lastPersistenceError == nil)
        #expect(!reopened.killSwitchEnabled)
        #expect(!makeCenter(root: root, defaults: defaults).killSwitchEnabled)
    }
}
