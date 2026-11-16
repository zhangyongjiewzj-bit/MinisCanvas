import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("OUTPUT packaged-field producer uses the production Composer and ledger")
@MainActor
struct OutputPackageFieldFixtureProductionTests {
    @Test("synthetic read page, failure, approved write and edit reach ordinary consumers")
    func realProducerReachesToolPageAndFileDiff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "output-field-consumer-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let arguments = [
            "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            SessionPackageFieldFixture.activationArgument,
            OutputPackageFieldFixture.activationArgument
        ]
        let environment = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: root.path
        ]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "output-field-consumer", processEnvironment: environment,
            processArguments: arguments
        )
        defer { try? profile.cleanupDisposableRoots() }
        #expect(PackageFieldFixtureArguments.areValid(arguments, environment: environment))
        #expect(OutputPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true,
            arguments: arguments, environment: environment
        ))
        // Keep the production consumer on this disposable field profile. A
        // default BridgeStore in a full test process otherwise borrows the
        // process-wide formal profile and shared workflow/badge stores.
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        let shortcutStore = ShortcutStore(defaults: defaults)
        let logManager = profile.makeLogManager()
        let sessionStore = SessionStore(directory: profile.sessionDirectory)
        let sessionBadgeStore = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let memoryStore = MemoryStore(directory: profile.memoryDirectory)
        let readinessStore = ProviderReadinessStore(
            directory: profile.providerConfigurationDirectory
        )
        let bridge = BridgeStore(
            shortcutStore: shortcutStore,
            preferencesDefaults: defaults,
            logManager: logManager,
            workflowStore: WorkflowStore(
                storeDirectory: profile.minisCanvasDirectory.appendingPathComponent(
                    "Workflows", isDirectory: true
                )
            ),
            sessionBadgeStore: sessionBadgeStore,
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: sessionStore,
            memoryStore: memoryStore,
            providerReadinessStore: readinessStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        // Match the App's strongly owned SettingsCenter with this field
        // profile. Every dependency remains synthetic; no ambient profile is
        // consulted by SettingsCenter's default-construction path.
        let settingsCenter = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(
                directory: profile.providerConfigurationDirectory,
                keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)
            ),
            memoryStore: memoryStore,
            memoryFileStore: MemoryFileStore(
                directory: profile.rootDirectory.appendingPathComponent(
                    "memory-files", isDirectory: true
                )
            ),
            sessionStore: sessionStore,
            sessionBadgeStore: sessionBadgeStore,
            logManager: logManager,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            shortcutStore: shortcutStore,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: readinessStore
        )
        defer { withExtendedLifetime(settingsCenter) {} }
        let ownerID = try #require(BridgeStore.canonicalSessionDirectoryIdentity(
            settingsCenter.sessionStore.directory
        ))
        let expectedID = try #require(BridgeStore.canonicalSessionDirectoryIdentity(
            profile.sessionDirectory
        ))
        let sameOwner = ownerID == expectedID
        print("OUTPUT_SETTINGS_OWNER sameOwner=\(sameOwner)")
        #expect(sameOwner)
        #expect(SettingsCenter.active === settingsCenter)
        bridge.chat.applyNewSession()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        )
        let sessionID = try #require(bridge.chat.activeSessionID).uuidString
        let ledger = try #require(bridge.productionFileChangeLedger)
        #expect(!ledger.artifactPersistenceUnavailable)
        let runner = Task {
            try await OutputPackageFieldFixture.run(
                profile: profile, bridge: bridge, sessionFieldJourney: true,
                arguments: arguments, environment: environment
            )
        }
        var approved: [String] = []
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let request = bridge.approvalCenter.pendingRequest,
               !approved.contains(request.id) {
                #expect(["file_write", "file_edit"].contains(request.toolName))
                #expect(request.requiresApproval)
                // Holding the real card cannot produce a write or a ledger
                // record. For edit the approved create is the only prior fact.
                let lifecycleID = try #require(bridge.approvalCenter.pendingRequestLifecycleID)
                let confirming = bridge.approvalCenter.awaitingConfirmation
                // Each rendered step has its own 500 ms anti-repeat guard.
                try await Task.sleep(for: .milliseconds(550))
                guard bridge.approvalCenter.pendingRequestLifecycleID == lifecycleID,
                      bridge.approvalCenter.pendingRequest?.id == request.id,
                      bridge.approvalCenter.awaitingConfirmation == confirming,
                      bridge.approvalCenter.isPromptPresented else { continue }
                let toolRoots = try FileManager.default.contentsOfDirectory(
                    at: profile.rootDirectory, includingPropertiesForKeys: nil
                ).filter {
                    $0.lastPathComponent.hasPrefix("output-field-")
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                #expect(toolRoots.count == 1)
                let changedFiles = try toolRoots.flatMap { toolRoot in
                    try FileManager.default.contentsOfDirectory(
                        at: toolRoot, includingPropertiesForKeys: nil
                    ).filter { $0.lastPathComponent.hasPrefix("change-") }
                }
                if request.toolName == "file_write" {
                    #expect(changedFiles.isEmpty)
                    #expect(ledger.records(sessionID: sessionID).isEmpty)
                } else {
                    #expect(changedFiles.count == 1)
                    if let changedFile = changedFiles.first {
                        #expect(try String(contentsOf: changedFile, encoding: .utf8)
                                == "OUTPUT_FIELD original synthetic content\n")
                    }
                    #expect(ledger.records(sessionID: sessionID).count == 1)
                }
                bridge.approvalCenter.actionsForPresentedRequest().approve()
                // Count approval only when the live waiter actually resolves.
                // A first-step transition remains pending for the next loop.
                if bridge.approvalCenter.pendingRequestLifecycleID != lifecycleID {
                    approved.append(request.id)
                }
            }
            if !bridge.chat.isStreaming && approved.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if bridge.chat.isStreaming { bridge.chat.stopStreaming() }
        if approved.count != 2 { runner.cancel() }
        print(
            "OUTPUT_TEST_PROGRESS approvals=\(approved.count) "
                + "streaming=\(bridge.chat.isStreaming) "
                + "pending=\(bridge.approvalCenter.pendingRequest?.toolName ?? "none") "
                + "ledger=\(ledger.records(sessionID: sessionID).count) "
                + "events=\(bridge.chat.conversationEventProjection.events.count)"
        )
        try await runner.value
        #expect(approved.count == 2)
        let events = bridge.chat.conversationEventProjection.events.filter {
            $0.identity.sessionID == sessionID && $0.kind == .tool
        }
        #expect(events.count > ChatInspectorSnapshot.maxToolRows)
        #expect(events.contains { $0.toolName == "file_read" && $0.status == .failed })
        #expect(events.contains { $0.toolName == "file_write" && $0.status == .succeeded })
        #expect(events.contains { $0.toolName == "file_edit" && $0.status == .succeeded })
        let records = ledger.records(sessionID: sessionID)
        #expect(records.count == 2)
        #expect(records.contains { $0.kind == .created })
        #expect(records.contains { $0.kind == .modified })
        for record in records {
            #expect(ledger.diffPayload(diffID: record.diffID, sessionID: sessionID) != nil)
        }
        // The marker means a restart cannot repeat the same write/edit turn.
        let before = records.count
        try await OutputPackageFieldFixture.run(
            profile: profile, bridge: bridge, sessionFieldJourney: true,
            arguments: arguments, environment: environment
        )
        #expect(ledger.records(sessionID: sessionID).count == before)
    }

    @Test("missing field, session, marker or 0700 owned root cannot install the producer")
    func hardEntryNegatives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "output-field-deny-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let field = RuntimeIsolationProfile.fieldActivationArgument
        let session = SessionPackageFieldFixture.activationArgument
        let output = OutputPackageFieldFixture.activationArgument
        let marker = [
            RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: root.path
        ]
        let valid = ["MinisCanvas", field, session, output]
        #expect(!PackageFieldFixtureArguments.areValid(
            ["MinisCanvas", session, output], environment: marker
        ))
        #expect(!PackageFieldFixtureArguments.areValid(
            ["MinisCanvas", field, output], environment: marker
        ))
        #expect(!PackageFieldFixtureArguments.areValid(
            valid, environment: [RuntimeIsolationProfile.fieldActivationRootKey: root.path]
        ))
        #expect(!PackageFieldFixtureArguments.areValid(
            valid, environment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "0",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ]
        ))
        #expect(throws: RuntimeIsolationProfile.IsolationError.self) {
            _ = try RuntimeIsolationProfile.makePackagedField(
                label: "output-field-no-root",
                processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"],
                processArguments: valid
            )
        }
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "output-field-deny", processEnvironment: marker,
            processArguments: valid
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: profile.rootDirectory.path
            )
            try? profile.cleanupDisposableRoots()
        }
        #expect(!OutputPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true,
            arguments: ["MinisCanvas", field, session], environment: marker
        ))
        let bridge = BridgeStore()
        for deniedArguments in [
            ["MinisCanvas", session, output],
            ["MinisCanvas", field, output],
            ["MinisCanvas", field, session]
        ] {
            await #expect(throws: OutputPackageFieldFixture.FixtureError.self) {
                try await OutputPackageFieldFixture.run(
                    profile: profile, bridge: bridge, sessionFieldJourney: true,
                    arguments: deniedArguments, environment: marker
                )
            }
        }
        await #expect(throws: OutputPackageFieldFixture.FixtureError.self) {
            try await OutputPackageFieldFixture.run(
                profile: profile, bridge: bridge, sessionFieldJourney: true,
                arguments: valid, environment: [RuntimeIsolationProfile.fieldActivationRootKey: root.path]
            )
        }
        #expect(bridge.chat.streamingProviderOverride == nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: profile.rootDirectory.path
        )
        await #expect(throws: OutputPackageFieldFixture.FixtureError.self) {
            try await OutputPackageFieldFixture.run(
                profile: profile, bridge: bridge, sessionFieldJourney: true,
                arguments: valid, environment: marker
            )
        }
        #expect(bridge.chat.streamingProviderOverride == nil)
        let entries = try FileManager.default.contentsOfDirectory(
            at: profile.rootDirectory, includingPropertiesForKeys: nil
        )
        #expect(!entries.contains { $0.lastPathComponent.hasPrefix("output-field-") })
    }

    @Test("a scripted field binding never forwards an unrelated ordinary Mock turn")
    func ordinaryMockTurnDoesNotUseFieldScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "output-field-mock-isolation-\(UUID().uuidString)", isDirectory: true
        )
        let controlled = OutputFieldControlledProvider(
            readFile: root.appendingPathComponent("read.txt"),
            changedFile: root.appendingPathComponent("change.txt"),
            missingFile: root.appendingPathComponent("missing.txt")
        )
        let token = "OUTPUT_FIELD_TURN_\(UUID().uuidString)"
        #expect(MockProvider.shared.installOutputFieldScript(token: token, provider: controlled))
        defer { MockProvider.shared.removeOutputFieldScript(token: token) }
        let ordinary = try await MockProvider.shared.sendMessage(
            messages: [LLMMessage(role: .user, content: "ordinary mock turn")],
            systemPrompt: nil, tools: [], maxTokens: 128, temperature: nil
        )
        #expect(ordinary.text.contains("收到：ordinary mock turn"))
        #expect(await controlled.responseCount == 0)
    }
}
