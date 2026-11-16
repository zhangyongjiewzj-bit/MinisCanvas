import Foundation
import Testing
import CryptoKit
import Darwin
import AppKit
@testable import MinisCore
@testable import MinisCanvasApp

private struct Backup587NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Same App confirmation path as AtomicBackupImportSheet. A real new process
/// calls the existing startup recovery before constructing its SettingsCenter.
/// All content, directories, preference domains and credentials are synthetic.
@Suite("D-STORAGE 四域生产导入与重开587", .serialized)
@MainActor
struct BackupRestoreConsumer587Tests {
    // A UUID keeps this persisted session addressable by the real ChatStore.
    private let scope = MemoryScope(sessionID: "69353E6A-3138-4B46-A3D8-3E117E08B587",
                                    projectID: "storage587-project")

    private func root() throws -> URL {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("Backup587-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private func center(_ root: URL, shortcuts injectedShortcuts: ShortcutStore? = nil) -> SettingsCenter {
        let core = root.appendingPathComponent("core", isDirectory: true)
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        guard let defaults = UserDefaults(suiteName: root.lastPathComponent) else {
            preconditionFailure("Owned backup fixture preferences required")
        }
        let shortcuts = injectedShortcuts ?? shortcutStore(root)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: core.appendingPathComponent("providers"), keychain: keys,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: chat),
            memoryFileStore: MemoryFileStore(directory: chat),
            sessionStore: SessionStore(directory: chat),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            shortcutStore: shortcuts,
            providerReadinessTransport: Backup587NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        center.memoryScopeProvider = { scope }
        return center
    }

    private func shortcutStore(_ root: URL) -> ShortcutStore {
        let suite = root.lastPathComponent
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Owned backup shortcut preferences required")
        }
        return ShortcutStore(defaults: defaults, recoverySuiteName: suite)
    }

    private func populate(_ center: SettingsCenter, label: String) throws {
        var session = try center.sessionStore.createSession(
            id: scope.sessionID, title: label + " private session")
        session.messages = [
            LLMMessage(role: .user, content: label + " full synthetic user message"),
            LLMMessage(role: .assistant, content: label + " full synthetic assistant message"),
        ]
        try center.sessionStore.updateSession(session)
        _ = try center.memoryStore.addFact(label + " private fact", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try center.skillStore.importSkill(content: "---\nname: Storage 587 Skill\ndescription: synthetic\n---\n" + label + " skill")
        _ = center.settingsStore.update(\.storage.sessionRetentionDays, to: label == "source" ? 83 : 41)
        _ = center.settingsStore.update(\.browser.idleTabTimeoutMinutes, to: label == "source" ? 31 : 23)
        #expect(center.envStore.saveProvider(
            name: label == "source" ? "SOURCE587" : "TARGET587",
            credential: .replace("synthetic provider credential 587"),
            baseURL: "https://example.invalid/v1",
            modelNames: [label + "-model"], protocolType: .openaiCompatible
        ))
        center.defaultProviderID = "custom.\(label == "source" ? "SOURCE587" : "TARGET587")"
        center.defaultModelID = label + "-model"
        center.themePreset = label == "source" ? .light : .system
        #expect(center.lastPersistenceError == nil)
        center.reloadStorage()
    }

    /// Reuse the canonical Store's already-approved-effect fixture boundary.
    /// This creates synthetic prior completion evidence, never recovery grants.
    private func completedShortcut(_ store: ShortcutStore, root: URL,
                                   key: String) throws -> BL6SettingsReplayRecord {
        let profile = root.path
        let snapshot = try store.bl6Snapshot(profileID: profile).get()
        let value = BL6SettingValue.object(["key": .text(key), "modifiers": .object([
            "command": .toggle(true), "control": .toggle(false),
            "option": .toggle(true), "shift": .toggle(false)
        ])])
        let input = BL6SettingsApprovedInput(operation: .apply,
            changes: ["shortcuts.openSettings": value], expectedRevision: snapshot.revision)
        let proposal = try store.prepareBL6Replay(input, profileID: profile).get()
        let raw = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(input)) as? [String: Any])
        let requestID = "backup2912-" + UUID().uuidString
        let receipt = BL6SettingsReceipt(requestID: requestID, operation: .apply,
            previousRevision: snapshot.revision, effectiveRevision: UUID().uuidString,
            changedKeys: proposal.changedKeys, rollbackValues: [:])
        let record = BL6SettingsReplayRecord(requestID: requestID,
            payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: raw)),
            frozenInput: input, approvalBindingDigest: "synthetic-consumed-" + requestID,
            profileID: profile, scope: "request", sessionID: "synthetic-backup2912",
            policyRevision: "synthetic-policy2912", grantEpoch: "synthetic-grant2912",
            approvalExpiresAt: Date().addingTimeInterval(600), operation: .apply,
            receipt: receipt, rollbackValues: proposal.rollbackValues)
        #expect(try store.commitBL6Replay(record, profileID: profile).get() == receipt)
        #expect(try store.bl6ReplayRecord(for: requestID, profileID: profile).get() == record)
        return record
    }

    private func files(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        let canonicalRoot = PersistenceTransactionFence.stablePath(root)
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let canonicalPath = PersistenceTransactionFence.stablePath(url)
                try #require(canonicalPath.hasPrefix(canonicalRoot + "/"))
                result[String(canonicalPath.dropFirst(canonicalRoot.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ReopenRequest: Codable {
        let root: URL
        let selected: Set<SyncScope>
        let parentPID: Int32
        let nonce: String
        let journal: URL
        let journalHash: String
        let backupHash: String
        let proof: URL
        let expectedModule: String
        let expectedComponents: [String]
        let expectLockedCoreJourney: Bool
        let expectedSessionMessages: [LLMMessage]
        let expectedSettings: AppSettings
        let shortcutHistory: [BL6SettingsReplayRecord]
    }
    private struct ReopenProof: Codable {
        let nonce: String
        let parentPID: Int32
        let childPID: Int32
        let module: String
        let components: [String]
        let selected: Set<SyncScope>
        let recoveredBeforeConstruction: Bool
        let checkedDomains: Int
        let checkedSettingClasses: Int
        let rejectedHistoryEntries: Int
    }

    /// Re-exec the current supported test carrier without inventing a bundle argument.
    private func childArguments(filter: String) throws -> [String] {
        let inherited = CommandLine.arguments
        if let flag = inherited.firstIndex(of: "--test-bundle-path") {
            try #require(flag + 1 < inherited.count)
            let payload = inherited[flag + 1]
            try #require(inherited[0].hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            try #require(payload.hasSuffix("/MinisCanvasAppPackageTests.xctest/Contents/MacOS/MinisCanvasAppPackageTests"))
            return ["--test-bundle-path", payload, "--testing-library", "swift-testing",
                    "--filter", filter]
        }
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let scratch = formal.rootDirectory.deletingLastPathComponent()
        let host = scratch.appendingPathComponent("R13OriginalAppMain.app/Contents/MacOS/MinisCanvasOriginalAppMain")
        try #require(formal.packageName == "MinisCanvasApp" && inherited[0] == host.path)
        try #require(FileManager.default.isExecutableFile(atPath: host.path))
        // Foundation preferences and temporary files must stay in the runner's
        // existing synthetic home/tmp, including in the newly executed child.
        let environment = ProcessInfo.processInfo.environment
        let home = scratch.appendingPathComponent("home", isDirectory: true).standardizedFileURL
        let temporary = scratch.appendingPathComponent("tmp", isDirectory: true).standardizedFileURL
        for key in ["HOME", "CFFIXED_USER_HOME"] {
            let path = try #require(environment[key])
            try #require(URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath() == home)
        }
        let temporaryPath = try #require(environment["TMPDIR"])
        try #require(URL(fileURLWithPath: temporaryPath, isDirectory: true).resolvingSymlinksInPath() == temporary)
        return ["--testing-library", "swift-testing", "--no-parallel", "--filter", filter]
    }

    private func reopenInNewProcess(_ targetRoot: URL, receipt: SyncAtomicImportReceipt,
                                    expectedSessionMessages: [LLMMessage],
                                    expectedSettings: AppSettings,
                                    shortcutHistory: [BL6SettingsReplayRecord] = [],
                                    expectLockedCoreJourney: Bool = false) throws {
        let inherited = CommandLine.arguments
        let arguments = try childArguments(filter: "reopenConsumerChild\\(\\)")
        let current = try #require(Test.current?.id)
        let components = Array(current.nameComponents.dropLast()) + ["reopenConsumerChild()"]
        let evidence = targetRoot.appendingPathComponent("child-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let request = ReopenRequest(root: targetRoot, selected: Set(receipt.selected),
            parentPID: getpid(), nonce: UUID().uuidString, journal: receipt.journalURL,
            journalHash: digest(try Data(contentsOf: receipt.journalURL)),
            backupHash: digest(try Data(contentsOf: receipt.backupURL)),
            proof: evidence.appendingPathComponent("proof.json"),
            expectedModule: current.moduleName, expectedComponents: components,
            expectLockedCoreJourney: expectLockedCoreJourney,
            expectedSessionMessages: expectedSessionMessages,
            expectedSettings: expectedSettings, shortcutHistory: shortcutHistory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: inherited[0])
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BACKUP587_REOPEN_REQUEST"] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let log = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        defer { try? handle.close() }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let timeout = done.wait(timeout: .now() + 20) != .success
        if timeout {
            // Only this owned child, never a command-line pattern or another owner.
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try handle.synchronize()
        let raw = try String(contentsOf: log, encoding: .utf8)
        print("BACKUP587_CHILD_RAW path=\(log.path) sha256=\(digest(Data(raw.utf8))) exit=\(process.terminationStatus)")
        try #require(!timeout && process.terminationStatus == 0)
        try #require(raw.contains("Test reopenConsumerChild() started."))
        try #require(raw.contains("Test reopenConsumerChild() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
        let proof = try JSONDecoder().decode(ReopenProof.self, from: Data(contentsOf: request.proof))
        #expect(proof.nonce == request.nonce && proof.parentPID == getpid())
        #expect(proof.childPID == process.processIdentifier && proof.childPID != getpid())
        #expect(proof.module == request.expectedModule && proof.components == components)
        #expect(proof.selected == Set(receipt.selected) && proof.checkedDomains == 4)
        #expect(proof.recoveredBeforeConstruction)
        #expect(proof.checkedSettingClasses == 4)
        #expect(proof.rejectedHistoryEntries == shortcutHistory.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKUP587_REOPEN_REQUEST"] != nil))
    func reopenConsumerChild() throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["BACKUP587_REOPEN_REQUEST"])
        let request = try JSONDecoder().decode(ReopenRequest.self, from: #require(Data(base64Encoded: encoded)))
        let id = try #require(Test.current?.id)
        try #require(id.moduleName == request.expectedModule && id.nameComponents == request.expectedComponents)
        try #require(getpid() != request.parentPID)
        try #require(request.root.lastPathComponent.hasPrefix("Backup587-"))
        try #require(UUID(uuidString: String(request.root.lastPathComponent.dropFirst("Backup587-".count))) != nil)
        try #require(digest(Data(contentsOf: request.journal)) == request.journalHash)
        try #require(digest(Data(contentsOf: request.journal.deletingLastPathComponent().appendingPathComponent("backup.json"))) == request.backupHash)
        let layout = try SyncAtomicImport.Layout(sessionDirectory: request.root.appendingPathComponent("chat"),
            memoryDirectory: request.root.appendingPathComponent("chat"),
            settingsDirectory: request.root.appendingPathComponent("core"),
            skillsRoot: request.root.appendingPathComponent("core/skills"),
            providerConfigurationDirectory: request.root.appendingPathComponent("core/providers"),
            shortcutSuiteName: request.root.lastPathComponent)
        try SyncAtomicImport.recoverBeforeStores(layout: layout)
        let defaults = try #require(UserDefaults(suiteName: request.root.lastPathComponent))
        let restoredShortcuts = ShortcutStore(defaults: defaults,
            recoverySuiteName: request.root.lastPathComponent)
        let reopened = center(request.root, shortcuts: restoredShortcuts)
        if request.expectLockedCoreJourney {
            #expect(reopened.optionalModulesDisabled)
            #expect(reopened.chatBackupRecoveryRemainEnabled)
            let recoveredChat = try #require(reopened.sessionStore.loadSession(id: scope.sessionID))
            #expect(recoveredChat.messages.contains {
                $0.role == .assistant && $0.content.contains("SAFE2 synthetic chat")
            })
        }
        let sessionLabel = request.selected.contains(.sessions) ? "source" : "target"
        let memoryLabel = request.selected.contains(.memories) ? "source" : "target"
        let skillLabel = request.selected.contains(.skills) ? "source" : "target"
        let restoredSession = try #require(reopened.sessionStore.loadSession(id: scope.sessionID))
        #expect(restoredSession.title == sessionLabel + " private session")
        #expect(restoredSession.messages == request.expectedSessionMessages)
        let facts = try reopened.memoryStore.facts()
        #expect(facts.filter { $0.memoryScope == scope }.map(\.text) == [memoryLabel + " private fact"])
        #expect(facts.contains { $0.text == "other project retained" })
        #expect(reopened.skillStore.rawContent("storage-587-skill")?.contains(skillLabel + " skill") == true)
        #expect(reopened.settingsStore.settings.storage.sessionRetentionDays == (request.selected.contains(.settings) ? 83 : 41))
        #expect(reopened.settingsStore.settings == request.expectedSettings)
        if request.selected.contains(.settings) {
            #expect(!reopened.settingsStore.settings.agent.browserWriteEnabled)
        }
        let settingLabel = request.selected.contains(.settings) ? "source" : "target"
        #expect(reopened.defaultProviderID == "custom.\(settingLabel == "source" ? "SOURCE587" : "TARGET587")")
        #expect(reopened.defaultModelID == settingLabel + "-model")
        #expect(reopened.themePreset == (request.selected.contains(.settings) ? .light : .system))
        let theme = ThemeTokenProvider(center: reopened)
        #expect(theme.mode == (request.selected.contains(.settings)
            ? .light : ThemeTokenProvider.systemMode(for: NSApp?.effectiveAppearance)))
        if request.selected.contains(.settings) {
            #expect(theme.tokens.background
                == ThemePreset.light.semanticTokens(systemIsDark: false)?.background)
        }
        #expect(reopened.envStore.providerRecords.map(\.name) == [settingLabel == "source" ? "SOURCE587" : "TARGET587"])
        let providerRecord = reopened.envStore.providerRecords[0]
        #expect(providerRecord.value.isEmpty)
        // Importing settings installs cold metadata and cannot resurrect a
        // credential. Importing another scope must leave the target's own
        // provider metadata, including its existing Keychain flag, intact.
        #expect(providerRecord.valueInKeychain == !request.selected.contains(.settings))
        if request.selected.contains(.settings) {
            #expect(reopened.envStore.credentialBinding(name: providerRecord.name) == nil)
        }
        #expect(providerRecord.modelNames == [settingLabel + "-model"])
        #expect(providerRecord.baseURL == "https://example.invalid/v1")
        #expect(restoredShortcuts.binding(for: .openSettings)
            == ShortcutBinding(key: settingLabel == "source" ? "7" : "8", modifiers: .optionCommand))
        let bridge = BridgeStore(
            shortcutStore: restoredShortcuts, preferencesDefaults: defaults,
            logManager: reopened.logManager,
            workflowStore: WorkflowStore(storeDirectory: request.root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: request.root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: request.root.appendingPathComponent("documents")),
            sessionStore: reopened.sessionStore,
            agentTaskStore: try AgentTaskStore(persistenceURL: request.root.appendingPathComponent("agent-tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: request.root.appendingPathComponent("context-manifests.json")),
            memoryStore: reopened.memoryStore,
            providerReadinessStore: reopened.providerReadinessStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.paletteDisplay["settings.open"]?.shortcut
            == (settingLabel == "source" ? "⌥⌘7" : "⌥⌘8"))
        bridge.chat.providerRecordsSource = { reopened.providerRecords }
        #expect(!bridge.chat.applyDefaultProviderModel(general: reopened.settings.general))
        #expect(bridge.chat.selectedCustomProvider == nil)
        #expect(bridge.chat.selectedModelID == nil)
        #expect(bridge.chat.providerRecordsSource?().first?.modelNames == [settingLabel + "-model"])
        let restoredValue = defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey)
        for historical in request.shortcutHistory {
            #expect(try restoredShortcuts.bl6ReplayRecord(
                for: historical.requestID, profileID: request.root.path).get() == nil)
            let expectedFailure: BL6SettingsReplayCommitError = historical.profileID == request.root.path
                ? .staleRevision : .conflict
            #expect(restoredShortcuts.commitBL6Replay(historical, profileID: request.root.path)
                == .failure(expectedFailure))
            #expect(defaults.data(forKey: SettingsRecoveryAttachment.shortcutDefaultsKey) == restoredValue)
            #expect(restoredShortcuts.binding(for: .openSettings)
                == ShortcutBinding(key: settingLabel == "source" ? "7" : "8", modifiers: .optionCommand))
        }
        #expect(reopened.sessionStore.loadSession(id: "neighbor-session")?.title == "retained session")
        #expect(reopened.sessionStore.loadSession(id: "neighbor-session")?.messages
            == [LLMMessage(role: .user, content: "neighbor synthetic message")])
        #expect(try Data(contentsOf: request.root.appendingPathComponent("core/provider-neighbor.json")) == Data("synthetic retained provider".utf8))
        reopened.reloadStorage()
        #expect(reopened.sessions.contains { $0.id == scope.sessionID && $0.title == sessionLabel + " private session" })
        #expect(reopened.memoryFacts.contains { $0.text == memoryLabel + " private fact" })
        _ = try reopened.sessionStore.createSession(id: "post-reopen-writer", title: "legitimate fresh writer")
        try JSONEncoder().encode(ReopenProof(nonce: request.nonce, parentPID: request.parentPID,
            childPID: getpid(), module: id.moduleName, components: id.nameComponents,
            selected: request.selected, recoveredBeforeConstruction: true, checkedDomains: 4,
            checkedSettingClasses: 4, rejectedHistoryEntries: request.shortcutHistory.count)).write(to: request.proof)
    }

    /// Settings -> Bridge -> production AgentLoop -> ChatStore, with the same
    /// persisted session that the Settings backup exporter subsequently reads.
    private func completeChatWithOptionalModulesLocked(_ source: SettingsCenter,
                                                       root: URL) async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        #expect(profile.isDisposable)
        let suite = "safe2-backup587-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chatRoot = root.appendingPathComponent("chat", isDirectory: true)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: source.logManager,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            agentTaskStore: try AgentTaskStore(persistenceURL: root.appendingPathComponent("agent-tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: root.appendingPathComponent("context-manifests.json")),
            memoryStore: source.memoryStore,
            providerReadinessStore: source.providerReadinessStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        source.onSafetyRuntimeSnapshotChanged = { snapshot in
            _ = bridge.updateSafetyRuntimeSnapshot(snapshot)
        }
        source.enableSafeMode()
        source.engageKillSwitch()
        #expect(source.optionalModulesDisabled && source.chatBackupRecoveryRemainEnabled)
        #expect(bridge.safetyRuntimeSnapshot.allOptionalModulesDisabled)
        #expect(bridge.isSafetyFeatureEnabled(.chat))
        #expect(bridge.isSafetyFeatureEnabled(.backup))
        #expect(bridge.isSafetyFeatureEnabled(.recovery))
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: chatRoot,
            mcpManager: source.mcpManager,
            skillStore: source.skillStore,
            enableOrchestration: true,
            externalRunners: [:],
            externalNetworkAllowed: false
        ).value
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        #expect(!bridge.orchestrationEnabled)
        #expect(bridge.productionExternalRunnerNames.isEmpty)
        #expect(bridge.chat.sessionStore?.directory == source.sessionStore.directory)
        let activeSessionID = try #require(bridge.chat.activeSessionID)
        #expect(activeSessionID.uuidString == scope.sessionID)
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.draftText = "SAFE2 synthetic chat"
        bridge.chat.sendDraft()
        for _ in 0..<200 {
            if !bridge.chat.isStreaming,
               source.sessionStore.loadSession(id: scope.sessionID)?.messages.contains(where: {
                   $0.role == .assistant && $0.content.contains("SAFE2 synthetic chat")
               }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!bridge.chat.isStreaming)
        let saved = try #require(source.sessionStore.loadSession(id: scope.sessionID))
        #expect(saved.messages.contains { $0.role == .user && $0.content == "SAFE2 synthetic chat" })
        #expect(saved.messages.contains {
            $0.role == .assistant && $0.content.contains("SAFE2 synthetic chat")
        })
        let execution = try #require(bridge.chat.executionSnapshot(forSessionID: activeSessionID))
        #expect(execution.state != .failed && execution.failureReason == nil)
    }

    private func roundTrip(selected: Set<SyncScope>, protected: Bool,
                           lockedCoreJourney: Bool = false,
                           editCanonicalAfterExport: Bool = false) async throws {
        let sourceRoot = try root(), targetRoot = try root()
        let source = center(sourceRoot)
        try populate(source, label: "source")
        let sourceShortcuts = shortcutStore(sourceRoot)
        var shortcutHistory: [BL6SettingsReplayRecord] = []
        if editCanonicalAfterExport {
            shortcutHistory.append(try completedShortcut(sourceShortcuts, root: sourceRoot, key: "7"))
        } else {
            #expect(sourceShortcuts.setBinding(
                ShortcutBinding(key: "7", modifiers: .optionCommand), for: .openSettings) == nil)
        }
        // The App has one active SettingsCenter. Keep its session scope on the
        // source root until the production chat turn has finished.
        if lockedCoreJourney {
            try #require(SettingsCenter.active === source)
            try await completeChatWithOptionalModulesLocked(source, root: sourceRoot)
        }
        let target = center(targetRoot)
        try populate(target, label: "target")
        let targetShortcuts = shortcutStore(targetRoot)
        if editCanonicalAfterExport {
            shortcutHistory.append(try completedShortcut(targetShortcuts, root: targetRoot, key: "8"))
        } else {
            #expect(targetShortcuts.setBinding(
                ShortcutBinding(key: "8", modifiers: .optionCommand), for: .openSettings) == nil)
        }
        if lockedCoreJourney {
            try #require(SettingsCenter.active === target)
            target.enableSafeMode()
            target.engageKillSwitch()
            #expect(target.optionalModulesDisabled && target.chatBackupRecoveryRemainEnabled)
        }
        var neighbor = try target.sessionStore.createSession(id: "neighbor-session", title: "retained session")
        neighbor.messages = [LLMMessage(role: .user, content: "neighbor synthetic message")]
        try target.sessionStore.updateSession(neighbor)
        _ = try target.memoryStore.addFact("other project retained", sourceSessionID: "other-session",
            memoryScope: MemoryScope(sessionID: "other-session", projectID: "other-project"))
        try Data("synthetic retained provider".utf8).write(to: targetRoot.appendingPathComponent("core/provider-neighbor.json"))
        target.reloadStorage()
        let expectedSessionMessages = try #require(
            (selected.contains(.sessions) ? source : target)
                .sessionStore.loadSession(id: scope.sessionID)).messages
        // N1: permission settings keep the local value on import. Target is
        // explicitly closed and the exported source explicitly open, so the
        // two differ and the result proves the imported open value is ignored.
        #expect(target.settingsStore.update(\.agent.browserWriteEnabled, to: false) == .success(.persisted))
        #expect(!target.settingsStore.settings.agent.browserWriteEnabled)
        #expect(source.settingsStore.update(\.agent.browserWriteEnabled, to: true) == .success(.persisted))
        #expect(source.settingsStore.settings.agent.browserWriteEnabled)
        var expectedSettings = (selected.contains(.settings) ? source : target)
            .settingsStore.settings
        if selected.contains(.settings) {
            // N1: browser writes keep the local (closed) value; the source's open value is not imported.
            expectedSettings.agent.browserWriteEnabled = target.settingsStore.settings.agent.browserWriteEnabled
        }
        let file = sourceRoot.appendingPathComponent("owned.minissync")
        let protection: SyncSnapshotProtection = protected ? .password("synthetic backup password 587") : .legacy
        let export = await source.exportBackupAsync(to: file, protection: protection)
        try #require(!export.isError)
        if lockedCoreJourney {
            #expect(source.optionalModulesDisabled && target.optionalModulesDisabled)
        }
        if editCanonicalAfterExport {
            try #require(selected == Set(SyncScope.allCases))
            for (current, label, shortcuts) in [(source, "source", sourceShortcuts),
                                               (target, "target", targetShortcuts)] {
                #expect(current.settingsStore.update(\.storage.sessionRetentionDays, to: 99) == .success(.persisted))
                #expect(current.envStore.saveProvider(
                    name: label == "source" ? "SOURCE587" : "TARGET587", credential: .keepExisting,
                    baseURL: "https://changed.example.invalid/v1", modelNames: [label + "-edited-model"],
                    protocolType: .openaiCompatible))
                current.defaultProviderID = nil
                current.defaultModelID = label + "-edited-model"
                current.themePreset = label == "source" ? .system : .light
                #expect(shortcuts.setBinding(ShortcutBinding(key: "9", modifiers: .optionCommand),
                    for: .openSettings) == nil)
                current.reloadStorage()
                #expect(current.settingsStore.settings.storage.sessionRetentionDays == 99)
                #expect(current.defaultProviderID == nil)
                #expect(current.defaultModelID == label + "-edited-model")
                #expect(current.envStore.providerRecords.first?.modelNames == [label + "-edited-model"])
                #expect(current.themePreset == (label == "source" ? .system : .light))
                #expect(shortcuts.binding(for: .openSettings) == ShortcutBinding(key: "9", modifiers: .optionCommand))
            }
            #expect(source.settingsStore.settings != expectedSettings)
        }
        let targetBeforeImport = target.settingsStore.settings
        let kind = try await target.backupProtectionKindAsync(from: file)
        #expect(kind == (protected ? .passwordProtected : .legacyPlaintext))
        let bytes = try Data(contentsOf: file)
        for historical in shortcutHistory {
            #expect(bytes.range(of: Data(historical.requestID.utf8)) == nil)
            #expect(bytes.range(of: Data(historical.receipt.receiptID.utf8)) == nil)
        }
        if protected { #expect(bytes.range(of: Data("source private fact".utf8)) == nil) }
        else { #expect(bytes.range(of: Data("source private session".utf8)) != nil) }
        let draft = try await target.readAtomicBackupDraftAsync(from: file, protection: protection)
        #expect(draft.settingsRecovery?.providers.map(\.name) == ["SOURCE587"])
        #expect(draft.settingsRecovery?.providers.first?.modelNames == ["source-model"])
        #expect(draft.settingsRecovery?.shortcutOverrides.map(\.actionID) == ["openSettings"])
        #expect(draft.sourceCounts == [.sessions: 1, .memories: 1, .skills: 1, .settings: 1])
        let sheet = AtomicBackupImportSheet(center: target, draft: draft)
        #expect(sheet.displayedMetadata.count == 3)
        for domain in SyncScope.allCases { #expect(sheet.sourceSummary(for: domain).contains("1")) }
        let before = try files(targetRoot)
        let preview = try target.previewAtomicBackup(draft, selecting: selected,
            memoryScope: selected.contains(.memories) ? scope : nil)
        #expect(preview.selected == selected)
        #expect(try files(targetRoot) == before)
        let receipt = try await target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        try #require(receipt.committed && receipt.reopenRequired && Set(receipt.selected) == selected && receipt.selected.count == selected.count)
        if lockedCoreJourney { #expect(target.optionalModulesDisabled) }
        #expect(target.atomicBackupReopenRequired && !target.atomicBackupInProgress && !target.atomicBackupRecoveryRequired)
        #expect(target.settingsStore.settings == targetBeforeImport)
        #expect(target.sessions.contains { $0.id == scope.sessionID && $0.title == "target private session" })
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.sessionStore.createSession(id: "old-writer", title: "must not publish") }
        #expect(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        let backup = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt.backupURL)) as? [[String: Any]])
        #expect(!backup.isEmpty)
        let permission = try FileManager.default.attributesOfItem(atPath: receipt.backupURL.path)[.posixPermissions] as? NSNumber
        #expect(permission?.intValue == 0o600)
        let after = try files(targetRoot)
        for (path, oldBytes) in before {
            let domain: SyncScope? = path.hasPrefix("chat/sessions/") ? .sessions
                : path.hasPrefix("chat/memory/") ? .memories
                : path.hasPrefix("core/skills/") || path == "core/skills-enabled.json" ? .skills
                : path == "core/settings.json" || path == "core/providers/envvars.json" ? .settings : nil
            if domain.map({ !selected.contains($0) }) ?? true { #expect(after[path] == oldBytes, "unchanged scope/neighbor: \(path)") }
        }
        try reopenInNewProcess(targetRoot, receipt: receipt,
                              expectedSessionMessages: expectedSessionMessages,
                              expectedSettings: expectedSettings,
                              shortcutHistory: shortcutHistory,
                              expectLockedCoreJourney: lockedCoreJourney)
        print("BACKUP587_ROUNDTRIP selected=\(selected.map(\.rawValue).sorted()) protected=\(protected) root=\(targetRoot.path) result=CHILD_REOPEN_VERIFIED")
    }

    @Test func fourDomainPlaintextCommitReopensThroughAppConsumer() async throws {
        try await roundTrip(selected: Set(SyncScope.allCases), protected: false)
    }

    @Test func fourSettingBackupSnapshotSurvivesCanonicalEditsAndRejectsOldShortcutHistory() async throws {
        try await roundTrip(selected: Set(SyncScope.allCases), protected: false,
                            editCanonicalAfterExport: true)
    }

    private func runLockedCoreJourneyInIsolatedProcess() throws {
        let inherited = CommandLine.arguments
        let arguments = try childArguments(filter: "fourDomainPlaintextWithAllOptionalModulesDisabled")
        let evidence = try root().appendingPathComponent("locked-core-child")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let log = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: inherited[0])
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BACKUP587_LOCKED_CORE_CHILD_PARENT_PID"] = String(getpid())
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        let done = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in done.signal() }
        try child.run()
        let timeout = done.wait(timeout: .now() + 30) != .success
        if timeout {
            child.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        try handle.synchronize()
        let raw = try String(contentsOf: log, encoding: .utf8)
        print("BACKUP587_LOCKED_CHILD_RAW path=\(log.path) sha256=\(digest(Data(raw.utf8))) exit=\(child.terminationStatus)")
        try #require(!timeout && child.terminationStatus == 0)
        try #require(raw.contains("Test fourDomainPlaintextWithAllOptionalModulesDisabled() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed after"))
    }

    @Test func fourDomainPlaintextWithAllOptionalModulesDisabled() async throws {
        if let parentPID = ProcessInfo.processInfo.environment["BACKUP587_LOCKED_CORE_CHILD_PARENT_PID"] {
            let parent = try #require(Int32(parentPID))
            #expect(parent != getpid())
        } else {
            try runLockedCoreJourneyInIsolatedProcess()
            return
        }
        try await roundTrip(selected: Set(SyncScope.allCases), protected: false,
                            lockedCoreJourney: true)
    }
    @Test func fourDomainProtectedCommitReopensThroughAppConsumer() async throws {
        try await roundTrip(selected: Set(SyncScope.allCases), protected: true)
    }
    @Test(arguments: SyncScope.allCases)
    func eachSelectedDomainLeavesUnselectedDomainsAndNeighborsUnchanged(_ domain: SyncScope) async throws {
        try await roundTrip(selected: [domain], protected: false)
    }

    @Test func cancelledPreviewStaleTargetAndDifferentConfirmationWriteNothing() async throws {
        let sourceRoot = try root(), targetRoot = try root()
        let source = center(sourceRoot), target = center(targetRoot)
        try populate(source, label: "source"); try populate(target, label: "target")
        let file = sourceRoot.appendingPathComponent("owned.minissync")
        try #require(!(await source.exportBackupAsync(to: file, protection: .legacy)).isError)
        let draft = try target.readAtomicBackupDraft(from: file)
        let before = try files(targetRoot)
        let preview = try target.previewAtomicBackup(draft, selecting: [.settings], memoryScope: nil)
        #expect(try files(targetRoot) == before)
        let other = try target.previewAtomicBackup(draft, selecting: [.sessions], memoryScope: nil)
        await #expect(throws: SyncAtomicImportError.confirmationRequired) {
            try await target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: other))
        }
        #expect(try files(targetRoot) == before)
        _ = target.settingsStore.update(\.storage.sessionRetentionDays, to: 52)
        let mutated = try files(targetRoot)
        await #expect(throws: SyncAtomicImportError.stalePreview) {
            try await target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        }
        #expect(try files(targetRoot) == mutated)
        #expect(!target.atomicBackupReopenRequired && !target.atomicBackupRecoveryRequired && !target.atomicBackupInProgress)
    }

    @Test func passwordRejectionAndTamperingNeverPublishOrWritePrivatePayload() async throws {
        let sourceRoot = try root(), targetRoot = try root()
        let source = center(sourceRoot), target = center(targetRoot)
        try populate(source, label: "source"); try populate(target, label: "target")
        let file = sourceRoot.appendingPathComponent("protected.minissync")
        try #require(!(await source.exportBackupAsync(to: file, protection: .password("synthetic backup password 587"))).isError)
        let before = try files(targetRoot)
        await #expect(throws: SyncProtectionError.wrongPasswordOrCorrupt) {
            try await target.readAtomicBackupDraftAsync(from: file, protection: .password("different synthetic password"))
        }
        #expect(try files(targetRoot) == before)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: file)
        await #expect(throws: (any Error).self) {
            try await target.readAtomicBackupDraftAsync(from: file, protection: .password("synthetic backup password 587"))
        }
        #expect(try files(targetRoot) == before)
        #expect(!target.atomicBackupInProgress && !target.atomicBackupReopenRequired)
    }
}
