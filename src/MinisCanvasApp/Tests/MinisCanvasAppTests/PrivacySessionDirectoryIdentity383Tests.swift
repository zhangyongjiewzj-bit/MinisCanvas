import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Exercise the actual assembly before/after directory creation and against
/// foreign roots, URL schemes and retargeted symlinks. The existing 297 and
/// 362 production callback/dispatch oracles remain unchanged.
@Suite("TASK383 production session directory identity", .serialized)
@MainActor
struct PrivacySessionDirectoryIdentity383Tests {
    enum DirectoryChange: CaseIterable, Equatable, Sendable {
        case createdDirectoryHint, differentDataRoot, nonFileScheme, foreignFileAuthority, changedSymlinkTarget
    }

    private func builtinOwner(of executor: any ToolExecutor) -> BuiltinToolExecutor? {
        if let concurrent = executor as? ConcurrentToolLimitingExecutor {
            return builtinOwner(of: concurrent.baseBox.value)
        }
        return (executor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    @Test(arguments: DirectoryChange.allCases)
    func directoryChangesRespectTheBoundConsumer(change: DirectoryChange) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Privacy383", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let firstRoot = profile.rootDirectory.appendingPathComponent("data-a", isDirectory: true)
        let secondRoot = profile.rootDirectory.appendingPathComponent("data-b", isDirectory: true)
        let workspace = profile.rootDirectory.appendingPathComponent("workspace", isDirectory: true)
        for directory in [secondRoot, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = profile.rootDirectory.appendingPathComponent("session-alias", isDirectory: true)
        let initialDirectory: URL
        if change != .createdDirectoryHint {
            try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        }
        if change == .changedSymlinkTarget {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstRoot)
            initialDirectory = alias
        } else if change == .createdDirectoryHint {
            initialDirectory = URL(fileURLWithPath: firstRoot.path, isDirectory: false)
        } else {
            initialDirectory = firstRoot
        }
        let keychain = profile.makeKeychainStore()
        let logger = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.minisCoreDirectory, keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: initialDirectory),
            logManager: logger,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock, providerReadinessStore: readiness
        )
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: logger,
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: initialDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: center.memoryStore, memoryProposalConsumer: center.memoryProposalConsumer,
            providerReadinessStore: readiness,
            taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in
                SpeechToolDirectObservations(voiceAvailable: false, audioOutputDevicePresent: false)
            }
        )
        @discardableResult
        func attach(_ directory: URL) -> Task<Void, Never> {
            return bridge.attachProductionServices(
                agentSettings: center.settings.agent,
                fileAccessAllowedRoot: workspace,
                fileAccessDeniedRoots: center.runtimeDeniedRoots.map { URL(fileURLWithPath: $0) },
                sessionDirectory: directory, mcpManager: center.mcpManager, skillStore: center.skillStore,
                canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false,
                sessionReadSecretStore: center.envStore
            )
        }
        // Diagnostic only: all inputs below are this fixture's own paths.
        // Keep the product and every positive/negative assertion unchanged.
        func traceDirectory(_ label: String, _ directory: URL) -> URL? {
            var components = URLComponents(url: directory, resolvingAgainstBaseURL: true)
            let resolved = directory.resolvingSymlinksInPath()
            let standardized = resolved.standardizedFileURL
            let canonical = URLComponents(url: standardized, resolvingAgainstBaseURL: true)
            print("PRIVACY383 stage=\(label) raw=\(directory.absoluteString) "
                  + "directoryHint=\(directory.hasDirectoryPath) base=\(directory.baseURL?.absoluteString ?? "nil") "
                  + "scheme=\(components?.scheme ?? "nil") host=\(components?.host ?? "nil") "
                  + "port=\(components?.port.map { String($0) } ?? "nil") "
                  + "percentEncodedPath=\(components?.percentEncodedPath ?? "nil") "
                  + "query=\(components?.percentEncodedQuery ?? "nil") fragment=\(components?.percentEncodedFragment ?? "nil") "
                  + "resolved=\(resolved.absoluteString) resolvedHint=\(resolved.hasDirectoryPath) "
                  + "standardized=\(standardized.absoluteString) standardizedHint=\(standardized.hasDirectoryPath)")
            if let canonical {
                components?.percentEncodedPath = canonical.percentEncodedPath
                if components?.percentEncodedPath.hasSuffix("/") == false {
                    components?.percentEncodedPath += "/"
                }
            }
            let identity = components?.url
            print("PRIVACY383 stage=\(label) canonical=\(identity?.absoluteString ?? "nil")")
            return identity
        }
        var firstCanonicalWitness: URL?
        if change == .createdDirectoryHint {
            #expect(!FileManager.default.fileExists(atPath: firstRoot.path))
            #expect(!initialDirectory.hasDirectoryPath)
            firstCanonicalWitness = traceDirectory("first-before-creation", initialDirectory)
        }
        attach(initialDirectory)
        let before = try #require(bridge.productionBuiltinToolExecutor)
        let beforeSessionStore = try #require(bridge.chat.sessionStore)
        let beforeEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(builtinOwner(of: beforeEngine.composedExecutor) === before)
        #expect(bridge.canvasIfAvailable == nil)
        let input: URL
        switch change {
        case .createdDirectoryHint:
            #expect(FileManager.default.fileExists(atPath: firstRoot.path))
            input = firstRoot
            #expect(input.hasDirectoryPath)
        case .differentDataRoot:
            input = secondRoot
        case .nonFileScheme:
            input = try #require(URL(string: "https://synthetic.invalid/sessions"))
        case .foreignFileAuthority:
            var foreign = try #require(URLComponents(url: firstRoot, resolvingAgainstBaseURL: true))
            foreign.host = "synthetic.invalid"
            input = try #require(foreign.url)
        case .changedSymlinkTarget:
            // Only the symlink created by this fixture is removed/replaced.
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: secondRoot)
            input = alias
        }
        if change == .createdDirectoryHint {
            let attachedCanonical = traceDirectory("attached-after-creation", beforeSessionStore.directory)
            let incomingCanonical = traceDirectory("incoming-after-creation", input)
            print("PRIVACY383 compare firstAttached=\(firstCanonicalWitness == attachedCanonical) "
                  + "firstIncoming=\(firstCanonicalWitness == incomingCanonical) "
                  + "attachedIncoming=\(attachedCanonical == incomingCanonical) "
                  + "beforeBuiltin=\(ObjectIdentifier(before))")
        }
        await attach(input).value
        if change == .createdDirectoryHint {
            print("PRIVACY383 afterBuiltin=\(bridge.productionBuiltinToolExecutor.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
                  + "builtinChanged=\(bridge.productionBuiltinToolExecutor !== before)")
        }
        #expect(bridge.chat.sessionStore === beforeSessionStore)
        let afterEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        if change == .createdDirectoryHint {
            let after = try #require(bridge.productionBuiltinToolExecutor)
            #expect(after !== before)
            #expect(builtinOwner(of: afterEngine.composedExecutor) === after)
        } else {
            #expect(bridge.productionBuiltinToolExecutor === before)
            #expect(builtinOwner(of: afterEngine.composedExecutor) === before)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: secondRoot.path).isEmpty)
    }
}
