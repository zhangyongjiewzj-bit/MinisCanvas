import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("FRESH13 field workflow isolation")
@MainActor
struct FieldWorkflowIsolationV25Tests {
    private static func canonicalResolvedPath(_ url: URL) -> String {
        let resolved = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let privateVarPrefix = "/private/var"
        guard resolved == privateVarPrefix
            || resolved.hasPrefix(privateVarPrefix + "/") else {
            return resolved
        }
        return "/var" + String(resolved.dropFirst(privateVarPrefix.count))
    }

    @Test("packaged field workflow directory stays inside the synthetic field root")
    func packagedFieldWorkflowDirectoryIsRootedInFieldProfile() throws {
        let syntheticRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-field-v25-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: syntheticRoot.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument],
            processName: "MinisCanvasApp"
        )
        defer { try? profile.cleanupDisposableRoots() }
        let workflowDirectory = profile.minisCanvasDirectory
            .appendingPathComponent("Workflows", isDirectory: true)
        let rootPath = Self.canonicalResolvedPath(profile.rootDirectory)
        let workflowPath = Self.canonicalResolvedPath(workflowDirectory)

        #expect(workflowPath.hasPrefix(rootPath + "/"))
        #expect(Self.canonicalResolvedPath(profile.minisCanvasDirectory)
            == Self.canonicalResolvedPath(
                syntheticRoot.appendingPathComponent("Canvas", isDirectory: true)
            ))
        #expect(!workflowPath.contains("/Library/Application Support/"))

        // Recreate the App composition through the production assembly. This
        // keeps the assertion tied to the object consumed by BridgeStore,
        // rather than to source text or a duplicated path literal.
        let defaults = profile.makeUserDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let log = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let settings = ProductionDomainAssembly.makeSettings(
            profile: profile,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            sessionStore: sessions,
            sessionBadgeStore: badges,
            logManager: log,
            store: shortcuts,
            readinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: readiness
        )
        let skills = SkillsStore(
            appStore: settings.skillStore,
            stateFileURL: profile.skillStateURL,
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory
                .appendingPathComponent("scheduler-occurrences-v1.json")
        )
        let workflows = WorkflowStore(storeDirectory: workflowDirectory)
        let bridge = ProductionDomainAssembly.makeBridge(
            profile: profile,
            bootstrapFailure: nil,
            settings: settings,
            store: shortcuts,
            defaults: defaults,
            skillsStore: skills,
            schedulerStore: scheduler,
            logManager: log,
            workflowStore: workflows,
            sessionBadgeStore: badges,
            sessionStore: sessions
        )

        #expect(bridge.workflowChat.workflowStore === workflows)
        try workflows.saveTemplate(WorkflowTemplate.presets[0])
        #expect(FileManager.default.fileExists(
            atPath: workflowDirectory.appendingPathComponent(WorkflowStore.fileName).path
        ))
    }

    @Test("missing field profile contract fails before a workflow store can be composed")
    func missingFieldProfileContractIsRejected() {
        #expect(throws: RuntimeIsolationProfile.IsolationError.missingFieldActivationEnvironment) {
            try RuntimeIsolationProfile.resolveLaunchProfile(
                processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"],
                processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument],
                processName: "MinisCanvasApp"
            )
        }
    }
}
