import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class RollbackFailureKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var setCount = 0
    private var failSetCall: Int?
    private var onSetFailure: (() -> Void)?

    func armRollbackFailure(onSetFailure: (() -> Void)? = nil) {
        lock.lock()
        // The first set establishes the old provider.  Fail the next set,
        // which is the replacement Keychain mutation, rather than a later
        // call that the production transaction never reaches.
        failSetCall = setCount + 1
        self.onSetFailure = onSetFailure
        lock.unlock()
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        setCount += 1
        let shouldFail = setCount == failSetCall
        let failureHook = shouldFail ? onSetFailure : nil
        if !shouldFail {
            values[key] = value
        }
        lock.unlock()
        if shouldFail {
            // Install the metadata rollback fault at the same injection point
            // as the failed Keychain write, after forward metadata committed.
            failureHook?()
            return false
        }
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }
}

@Suite("P0 typed settings production consumers")
@MainActor
struct BL6TypedConversationSettingsProductionTests {
    private func makeCenter() throws -> (SettingsCenter, URL) {
        try makeCenter(using: InMemoryKeychainBacking())
    }

    private func makeCenter<B: KeychainBacking>(using backing: B) throws -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BL6-production-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (makeCenter(at: root, using: backing), root)
    }

    private func makeCenter<B: KeychainBacking>(at root: URL, using backing: B) -> SettingsCenter {
        let keychain = KeychainStore(backing: backing)
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: keychain
            ),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"),
                keychain: keychain
            ),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
    }

    private func assertSecretAbsent(_ secret: String, under root: URL) throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: url)
            #expect(
                !String(decoding: bytes, as: UTF8.self).contains(secret),
                "secret leaked into reachable file \(url.path)"
            )
        }
    }

    private func approved(
        requestID: String,
        operation: BL6SettingsOperation = .apply,
        changes: [String: BL6SettingValue] = [:],
        revision: String,
        provider: BL6ProviderConfigurationPlan? = nil
    ) -> BL6SettingsIntent {
        BL6SettingsIntent(
            requestID: requestID,
            operation: operation,
            changes: changes,
            expectedRevision: revision,
            approval: .approved(receiptID: "approval-\(requestID)"),
            providerConfiguration: provider
        )
    }

    private func requireSuccess(
        _ result: Result<BL6SettingsReceipt, BL6SettingsDispatchError>
    ) throws -> BL6SettingsReceipt {
        guard case let .success(receipt) = result else {
            Issue.record("expected production receipt, got \(result)")
            throw ProductionSettingsTestError.dispatchFailed
        }
        return receipt
    }

    private func terminalValue(
        allowed: [String],
        confirmation: [String],
        denied: [String]
    ) -> BL6SettingValue {
        .object([
            "automaticAllowCommands": .list(allowed),
            "confirmationCommands": .list(confirmation),
            "userDeniedCommands": .list(denied)
        ])
    }

    @Test("real SettingsCenter dispatch applies and persists an approved typed change")
    func productionApplyAndEffectiveReceipt() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let result = center.dispatchBL6Settings(
            approved(
                requestID: "apply",
                changes: ["general.language": .text("en")],
                revision: before.catalogRevision
            )
        )
        let receipt = try requireSuccess(result)
        #expect(receipt.visibleOnNextTurn)
        #expect(receipt.previousRevision == before.catalogRevision)
        #expect(receipt.secretValuesExposed == false)
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "general.language") == .text("en"))
        let reloaded = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(
                directory: root.appendingPathComponent("env"),
                keychain: KeychainStore(backing: InMemoryKeychainBacking())
            ),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        #expect(reloaded.bl6EffectiveSettingsSnapshot?.value(for: "general.language") == .text("en"))
    }

    @Test("approved terminal policy uses the canonical store and next execution boundary")
    func terminalPolicyApplyPersistRollbackReset() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let initial = try #require(center.bl6EffectiveSettingsSnapshot)
        let value = terminalValue(
            allowed: ["echo", "printf"],
            confirmation: ["git"],
            denied: ["rm"]
        )
        var observedBoundary: TerminalPolicySnapshot?
        center.onTerminalPolicyChanged = { observedBoundary = $0 }

        let chat = ChatStore()
        chat.bl6SettingsDispatchHandler = { intent in center.dispatchBL6Settings(intent) }
        let applied = try requireSuccess(chat.dispatchBL6Settings(approved(
            requestID: "terminal-apply",
            changes: ["agent.terminal-policy": value],
            revision: initial.catalogRevision
        )))
        #expect(applied.changedKeys == ["agent.terminal-policy"])
        #expect(applied.visibleOnNextTurn)
        // A legacy three-field input is projected canonically with unknown provenance.
        let canonicalValue = center.bl6EffectiveSettingsSnapshot?.value(for: "agent.terminal-policy")
        if case let .object(fields) = canonicalValue {
            #expect(fields["confirmationProvenanceVersion"] == .integer(0))
            #expect(fields["explicitConfirmationCommands"] == .list([]))
        } else { Issue.record("missing terminal projection") }
        #expect(center.settingsStore.settings.agent.terminalPolicy == TerminalPolicySettings(
            automaticAllowCommands: ["echo", "printf"],
            confirmationCommands: ["git"],
            userDeniedCommands: ["rm"]
        ))
        #expect(observedBoundary?.classify(command: "printf ok") == .allowed)
        #expect(observedBoundary?.classify(command: "rm -rf fixture") == .denied)
        #expect(observedBoundary?.classify(command: "sudo echo fixture") == .denied)

        let reloaded = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(reloaded.bl6EffectiveSettingsSnapshot?.value(for: "agent.terminal-policy") == canonicalValue)
        #expect(reloaded.terminalPolicySnapshot.classify(command: "printf ok") == .allowed)

        let afterApply = try #require(center.bl6EffectiveSettingsSnapshot)
        _ = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "terminal-rollback",
            operation: .rollback,
            changes: applied.rollbackValues,
            revision: afterApply.catalogRevision
        )))
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "agent.terminal-policy") == initial.value(for: "agent.terminal-policy"))
        #expect(center.terminalPolicySettings == .default)

        let beforeReapply = try #require(center.bl6EffectiveSettingsSnapshot)
        _ = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "terminal-reapply",
            changes: ["agent.terminal-policy": value],
            revision: beforeReapply.catalogRevision
        )))
        let beforeReset = try #require(center.bl6EffectiveSettingsSnapshot)
        _ = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "terminal-reset",
            operation: .reset,
            revision: beforeReset.catalogRevision
        )))
        #expect(center.terminalPolicySettings == .default)
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "agent.terminal-policy") == initial.value(for: "agent.terminal-policy"))
    }

    @Test("terminal policy rejects malformed and hard denied entries without persistence")
    func terminalPolicyRejectsUnsafeValuesAndFences() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let initial = try #require(center.bl6EffectiveSettingsSnapshot)
        let invalidValues: [BL6SettingValue] = [
            .object(["automaticAllowCommands": .list(["echo"])]),
            .object([
                "automaticAllowCommands": .text("echo"),
                "confirmationCommands": .list([]),
                "userDeniedCommands": .list([])
            ]),
            .object([
                "automaticAllowCommands": .list(["echo"]),
                "confirmationCommands": .list([]),
                "userDeniedCommands": .list([]),
                "productHardDeniedCommands": .list([])
            ]),
            terminalValue(allowed: ["sudo"], confirmation: [], denied: []),
            terminalValue(allowed: [], confirmation: [], denied: ["sudo"]),
            terminalValue(allowed: ["echo -n"], confirmation: [], denied: []),
            terminalValue(allowed: ["echo", "echo"], confirmation: [], denied: []),
            terminalValue(allowed: ["echo"], confirmation: ["echo"], denied: [])
        ]
        for (index, value) in invalidValues.enumerated() {
            #expect(center.dispatchBL6Settings(approved(
                requestID: "terminal-invalid-\(index)",
                changes: ["agent.terminal-policy": value],
                revision: initial.catalogRevision
            )) == .failure(.invalidIntent("agent.terminal-policy")))
            #expect(center.bl6EffectiveSettingsSnapshot?.values == initial.values)
        }
        #expect(center.settingsStore.settings.agent.terminalPolicy == .default)
        #expect(center.dispatchBL6Settings(BL6SettingsIntent(
            requestID: "terminal-pending",
            changes: ["agent.terminal-policy": terminalValue(
                allowed: ["echo", "printf"], confirmation: [], denied: []
            )],
            expectedRevision: initial.catalogRevision,
            approval: .pending
        )) == .failure(.approvalRequired))
        #expect(center.bl6EffectiveSettingsSnapshot?.values == initial.values)

        _ = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "terminal-first",
            changes: ["agent.terminal-policy": terminalValue(
                allowed: ["echo", "printf"], confirmation: [], denied: []
            )],
            revision: initial.catalogRevision
        )))
        guard case .failure(.staleRevision(_, _)) = center.dispatchBL6Settings(approved(
            requestID: "terminal-stale",
            changes: ["agent.terminal-policy": terminalValue(
                allowed: ["cat"], confirmation: [], denied: []
            )],
            revision: initial.catalogRevision
        )) else {
            Issue.record("stale terminal policy revision was accepted")
            return
        }
        #expect(center.terminalPolicySettings.automaticAllowCommands.contains("printf"))
        #expect(!center.terminalPolicySettings.automaticAllowCommands.contains("cat"))
    }

    @Test("real dispatch reset and rollback update the effective next-turn snapshot")
    func productionResetRollback() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let initial = try #require(center.bl6EffectiveSettingsSnapshot)
        let applied = try requireSuccess(center.dispatchBL6Settings(
            approved(
                requestID: "apply-before-rollback",
                changes: ["general.language": .text("en")],
                revision: initial.catalogRevision
            )
        ))
        let afterApply = try #require(center.bl6EffectiveSettingsSnapshot)
        let restored = try requireSuccess(center.dispatchBL6Settings(
            approved(
                requestID: "rollback",
                operation: .rollback,
                changes: applied.rollbackValues,
                revision: afterApply.catalogRevision
            )
        ))
        #expect(restored.operation == .rollback)
        #expect(center.bl6EffectiveSettingsSnapshot?.values == initial.values)

        let beforeReset = try #require(center.bl6EffectiveSettingsSnapshot)
        _ = try requireSuccess(center.dispatchBL6Settings(
            approved(requestID: "reset", operation: .reset, revision: beforeReset.catalogRevision)
        ))
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "general.language") == .text(AppSettings.defaults.general.language))
    }

    @Test("real ChatStore forwarding enforces the SettingsCenter CAS revision")
    func productionChatDispatchAndCAS() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let chat = ChatStore()
        chat.bl6SettingsDispatchHandler = { intent in center.dispatchBL6Settings(intent) }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let intent = approved(
            requestID: "chat-cas",
            changes: ["agent.fallback-enabled": .toggle(false)],
            revision: before.catalogRevision
        )
        let applied = try requireSuccess(chat.dispatchBL6Settings(intent))
        #expect(applied.operation == .apply)
        let stale = chat.dispatchBL6Settings(intent)
        guard case let .failure(error) = stale else {
            Issue.record("stale ChatStore dispatch unexpectedly succeeded")
            return
        }
        guard case let .staleRevision(expected, actual) = error else {
            Issue.record("wrong stale dispatch error: \(error)")
            return
        }
        #expect(expected == before.catalogRevision)
        #expect(actual == applied.effectiveRevision)
    }

    @Test("rejected production plans never resolve or mutate provider credentials")
    func rejectedPlanHasNoProviderSideEffect() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        var resolverCalled = false
        center.bl6CredentialResolver = { _ in
            resolverCalled = true
            return "provider-secret-for-test"
        }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = BL6ProviderConfigurationPlan(
            providerID: "BL6_TEST_PROVIDER_API_KEY",
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["typed-model"],
            protocolType: ProviderWireProtocol.openaiCompatible.rawValue,
            credential: .opaqueHandle(BL6CredentialHandle(id: "rejected-handle"))
        )
        let result = center.dispatchBL6Settings(
            BL6SettingsIntent(
                requestID: "rejected",
                operation: .configureProvider,
                changes: ["general.language": .text("en")],
                expectedRevision: before.catalogRevision,
                approval: .pending,
                providerConfiguration: provider
            )
        )
        guard case .failure(.approvalRequired) = result else {
            Issue.record("rejected plan returned unexpected result: \(result)")
            return
        }
        #expect(resolverCalled == false)
        #expect(center.envStore.providerRecords.isEmpty)
        #expect(center.bl6EffectiveSettingsSnapshot?.values == before.values)
    }

    @Test("real provider configure consumes an opaque handle and returns a safe receipt")
    func productionProviderConfigure() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let chat = ChatStore()
        chat.bl6SettingsDispatchHandler = { intent in center.dispatchBL6Settings(intent) }
        center.bl6CredentialResolver = { handle in
            handle.id == "provider-handle" ? "provider-secret-for-test" : nil
        }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = BL6ProviderConfigurationPlan(
            providerID: "BL6_TEST_PROVIDER_API_KEY",
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["typed-model"],
            protocolType: ProviderWireProtocol.openaiCompatible.rawValue,
            credential: .opaqueHandle(BL6CredentialHandle(id: "provider-handle"))
        )
        let receipt = try requireSuccess(chat.dispatchBL6Settings(
            approved(
                requestID: "provider",
                operation: .configureProvider,
                revision: before.catalogRevision,
                provider: provider
            )
        ))
        #expect(receipt.secretValuesExposed == false)
        #expect(center.envStore.entry(name: provider.providerID)?.isProviderRecord == true)
        #expect(center.envStore.getEnvVar(name: provider.providerID) == "provider-secret-for-test")
    }

    @Test("provider failure compensates settings and emits no receipt")
    func providerFailureCompensatesSettings() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = BL6ProviderConfigurationPlan(
            providerID: "invalid provider name",
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["typed-model"],
            protocolType: ProviderWireProtocol.openaiCompatible.rawValue
        )
        let result = center.dispatchBL6Settings(
            approved(
                requestID: "provider-failure",
                operation: .configureProvider,
                changes: ["general.language": .text("en")],
                revision: before.catalogRevision,
                provider: provider
            )
        )
        #expect(result == .failure(.providerMutationFailed))
        #expect(center.bl6SettingsTransactionState == .ready)
        #expect(center.bl6EffectiveSettingsSnapshot?.values == before.values)
        #expect(center.envStore.providerRecords.isEmpty)
    }

    @Test("failed compensation marks the SettingsCenter unknown and blocks later turns")
    func failedCompensationIsFailClosed() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = BL6ProviderConfigurationPlan(
            providerID: "invalid provider name",
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["typed-model"],
            protocolType: ProviderWireProtocol.openaiCompatible.rawValue,
            credential: .opaqueHandle(BL6CredentialHandle(id: "handle"))
        )
        center.bl6CredentialResolver = { _ in
            let fileURL = center.settingsStore.fileURL
            do {
                try FileManager.default.removeItem(at: fileURL)
                try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
                return "provider-secret-for-test"
            } catch {
                Issue.record("failed to install deterministic compensation failure: \(error)")
                return nil
            }
        }
        let result = center.dispatchBL6Settings(
            approved(
                requestID: "unknown",
                operation: .configureProvider,
                changes: ["general.language": .text("en")],
                revision: before.catalogRevision,
                provider: provider
            )
        )
        #expect(result == .failure(.transactionUnknown))
        #expect(center.bl6SettingsTransactionState == .unknown)
        #expect(center.dispatchBL6Settings(
            approved(requestID: "blocked", changes: [:], revision: before.catalogRevision)
        ) == .failure(.transactionUnknown))

        let chat = ChatStore()
        let baselineMessages = chat.messages
        chat.effectiveSettingsSnapshotSource = { center.bl6EffectiveSettingsSnapshot }
        chat.draftText = "must not reach the provider"
        chat.submitComposer()
        #expect(chat.lastSubmissionBlockedByInvalidSettings)
        // ChatStore intentionally seeds a welcome message.  The recovery
        // invariant is that the blocked submission adds no user/provider
        // transcript mutation, not that the initial welcome is absent.
        #expect(chat.messages == baselineMessages)
        do {
            _ = try chat.activeProvider()
            Issue.record("unknown transaction reached provider runtime")
        } catch let error as ChatStoreProviderError {
            #expect(error == .unavailable(
                providerID: "settings-transaction-unknown",
                protocolType: .other
            ))
        }

        let markerURL = center.settingsStore.directory.appendingPathComponent(
            SettingsCenter.bl6SettingsTransactionMarkerFileName
        )
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        let restarted = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(restarted.bl6SettingsTransactionState == .unknown)
        #expect(restarted.bl6EffectiveSettingsSnapshot == nil)
        let restartedChat = ChatStore()
        restartedChat.effectiveSettingsSnapshotSource = { restarted.bl6EffectiveSettingsSnapshot }
        restartedChat.draftText = "must remain blocked after restart"
        restartedChat.submitComposer()
        #expect(restartedChat.lastSubmissionBlockedByInvalidSettings)
        do {
            _ = try restartedChat.activeProvider()
            Issue.record("restart unknown transaction reached provider runtime")
        } catch let error as ChatStoreProviderError {
            #expect(error == .unavailable(
                providerID: "settings-transaction-unknown",
                protocolType: .other
            ))
        }
    }

    @Test("Keychain rollback uncertainty is sticky and never leaks the replacement secret")
    func keychainRollbackFailureIsFailClosed() throws {
        let backing = RollbackFailureKeychainBacking()
        let (center, root) = try makeCenter(using: backing)
        defer { removeFixture(root) }

        let providerID = "BL6_ROLLBACK_PROVIDER"
        let oldCredential = "provider-old-secret"
        let newCredential = "provider-replacement-secret"
        #expect(center.saveProvider(
            name: providerID,
            apiKey: oldCredential,
            baseURL: "https://provider.invalid/v1",
            modelNames: ["old-model"],
            protocolType: .openaiCompatible
        ))
        let previousEntry = try #require(center.envStore.entry(name: providerID))
        let metadataURL = root
            .appendingPathComponent("env", isDirectory: true)
            .appendingPathComponent(EnvVarStore.fileName)
        let metadataBeforeFailure = try Data(contentsOf: metadataURL)
        #expect(!String(decoding: metadataBeforeFailure, as: UTF8.self).contains(oldCredential))
        #expect(!String(decoding: metadataBeforeFailure, as: UTF8.self).contains(newCredential))
        var metadataFixtureInstalled = false
        backing.armRollbackFailure {
            do {
                try FileManager.default.removeItem(at: metadataURL)
                try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
                metadataFixtureInstalled = true
            } catch {
                Issue.record("failed to install metadata failure fixture: \(error)")
            }
        }
        center.bl6CredentialResolver = { handle in
            guard handle.id == "rollback-failure-handle" else { return nil }
            return newCredential
        }

        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let provider = BL6ProviderConfigurationPlan(
            providerID: providerID,
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["new-model"],
            protocolType: ProviderWireProtocol.openaiCompatible.rawValue,
            credential: .opaqueHandle(BL6CredentialHandle(id: "rollback-failure-handle"))
        )
        let result = center.dispatchBL6Settings(
            approved(
                requestID: "keychain-rollback-unknown",
                operation: .configureProvider,
                changes: ["general.language": .text("en")],
                revision: before.catalogRevision,
                provider: provider
            )
        )

        #expect(metadataFixtureInstalled)
        #expect(center.envStore.lastPersistenceError == .keychainRollbackFailed)
        #expect(center.providerSaveFailure == .keychainRollbackFailed)
        #expect(result == .failure(.transactionUnknown))
        #expect(center.bl6SettingsTransactionState == .unknown)
        #expect(center.envStore.entry(name: providerID) == previousEntry)
        // An unknown transaction is a durable fence: no effective snapshot
        // may be exposed until an explicit reconciliation rebuilds the center.
        #expect(center.bl6EffectiveSettingsSnapshot == nil)
        #expect(String(describing: result).range(of: newCredential) == nil)
        #expect(!center.logManager.recentLogsText().contains(oldCredential))
        #expect(!center.logManager.recentLogsText().contains(newCredential))
        if let logURL = center.logManager.logFileURL() {
            #expect(!String(decoding: try Data(contentsOf: logURL), as: UTF8.self).contains(oldCredential))
            #expect(!String(decoding: try Data(contentsOf: logURL), as: UTF8.self).contains(newCredential))
        }

        // ProviderConfig is the runtime construction boundary.  Its Codable
        // payload must remain metadata-only; activeProvider is separately
        // exercised below to prove no runtime instance is built after the
        // transaction fence is raised.
        let runtimeConfig = ProviderConfig(
            label: providerID,
            providerType: .openAI,
            runtimeProviderID: providerID,
            customBaseURL: "https://provider.invalid/v1",
            apiKey: newCredential
        )
        let providerPayload = try JSONEncoder().encode(runtimeConfig)
        #expect(!String(decoding: providerPayload, as: UTF8.self).contains(newCredential))
        let exportData = try center.syncManager.exportSnapshot(scopes: Set([.settings]))
        #expect(!String(decoding: exportData, as: UTF8.self).contains(oldCredential))
        #expect(!String(decoding: exportData, as: UTF8.self).contains(newCredential))
        let packageURL = root.appendingPathComponent("rollback-failure.minissync")
        try exportData.write(to: packageURL, options: .atomic)
        #expect(!String(decoding: try Data(contentsOf: packageURL), as: UTF8.self).contains(newCredential))
        try assertSecretAbsent(oldCredential, under: root)
        try assertSecretAbsent(newCredential, under: root)
        #expect(center.dispatchBL6Settings(
            approved(requestID: "blocked-after-keychain-rollback", revision: before.catalogRevision)
        ) == .failure(.transactionUnknown))
    }

    @Test("production catalog exposes exactly all editable keys and only two exclusions")
    func productionCatalogScope() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let snapshot = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(snapshot.values.count == 43)
        #expect(Set(BL6SettingsCatalog.production.entries.map(\.id)) == Set(snapshot.values.keys))
        #expect(BL6SettingsCatalog.excludedConversationKeys == ["context_length", "history_rounds"])
        #expect(!snapshot.values.keys.contains("context_length"))
        #expect(!snapshot.values.keys.contains("history_rounds"))
    }

    @Test("the editable enabled-session count reaches the typed catalog and production dispatch")
    func enabledSessionCountTypedProductionConsumer() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let key = "agent.child-concurrency-enabled-session-count"

        // The ordinary Settings UI setter is the producer, including its
        // persisted user choice. The typed snapshot must read that same value.
        center.childConcurrencyEnabledSessionCount = 3
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(before.value(for: key) == .integer(3))
        #expect(center.settingsStore.settings.agent.childConcurrencyEnabledSessionCount == 3)
        try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: [key])
        for excluded in BL6SettingsCatalog.excludedConversationKeys {
            do {
                try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: [excluded])
                Issue.record("excluded setting was admitted: \(excluded)")
            } catch let error as BL6SettingsDispatchError {
                #expect(error == .invalidIntent("setting is read-only: \(excluded)"))
            }
        }

        // An acknowledged higher resource choice is never carried across a
        // later typed edit. The existing runtime projection must be notified
        // after the single committed settings transaction.
        center.childConcurrencyRiskAcknowledged = true
        #expect(center.childConcurrencyRiskAcknowledged)
        var published: [ChildConcurrencySelection] = []
        center.onChildConcurrencySelectionChanged = { published.append($0) }
        let receipt = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "enabled-sessions-apply",
            changes: [key: .integer(2)],
            revision: before.catalogRevision
        )))
        let after = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(receipt.changedKeys == [key])
        #expect(receipt.effectiveRevision == after.catalogRevision)
        #expect(after.value(for: key) == .integer(2))
        #expect(center.childConcurrencyEnabledSessionCount == 2)
        #expect(center.childConcurrencySelection.enabledSessionCount == 2)
        #expect(!center.childConcurrencyRiskAcknowledged)
        #expect(published.count == 1)
        #expect(published.first?.enabledSessionCount == 2)

        let reopened = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(reopened.childConcurrencyEnabledSessionCount == 2)
        #expect(reopened.bl6EffectiveSettingsSnapshot?.value(for: key) == .integer(2))

        // Invalid values and a call without approval leave store, revision,
        // runtime callback and the two explicit catalog exclusions intact.
        for invalid in [0, ChildConcurrencySelection.hardMaximum + 1] {
            #expect(center.dispatchBL6Settings(approved(
                requestID: "enabled-sessions-invalid-\(invalid)",
                changes: [key: .integer(invalid)],
                revision: after.catalogRevision
            )) == .failure(.invalidIntent(key)))
        }
        #expect(center.dispatchBL6Settings(BL6SettingsIntent(
            requestID: "enabled-sessions-pending",
            changes: [key: .integer(4)],
            expectedRevision: after.catalogRevision,
            approval: .pending
        )) == .failure(.approvalRequired))
        #expect(center.bl6EffectiveSettingsSnapshot?.catalogRevision == after.catalogRevision)
        #expect(center.childConcurrencyEnabledSessionCount == 2)
        #expect(published.count == 1)
        #expect(BL6SettingsCatalog.excludedConversationKeys == ["context_length", "history_rounds"])
    }
    // Goal17 SETA: only the fourteen remaining ordinary writable keys.
    // Literal expectations below are reviewed independently of the SUT catalog.
    // Fresh owners prove disk reopen, not an OS/App cold restart or a browser request.
    @Test("remaining ordinary settings apply, read back, reopen and reset", arguments: [
        "general.chat-output-mode",
        "agent.max-loop-iterations",
        "agent.tool-timeout-seconds",
        "agent.concurrent-tool-limit",
        "agent.auto-compact-threshold",
        "agent.persona-preset",
        "agent.new-message-interrupts-generation",
        "browser.user-agent-preset",
        "browser.custom-user-agent",
        "browser.viewport-mode",
        "browser.custom-viewport-width",
        "browser.custom-viewport-height",
        "browser.idle-tab-timeout-minutes",
        "typography.ui-base-font-size",
    ])
    func remainingOrdinaryWritableKeysApplyReadbackReopenReset(key: String) throws {
        let expected: BL6SettingValue
        let expectedDefault: BL6SettingValue
        let liveValue: @MainActor (SettingsCenter) -> BL6SettingValue
        let storedValue: (AppSettings) -> BL6SettingValue
        switch key {
        case "general.chat-output-mode":
            expected = .text("concise")
            expectedDefault = .text("normal")
            liveValue = { .text($0.chatOutputMode.rawValue) }
            storedValue = { .text($0.general.chatOutputMode.rawValue) }
        case "agent.max-loop-iterations":
            expected = .integer(25)
            // e66e240 / I-20261025T0841: reset follows the current default contract.
            #expect(AppSettings.defaults.agent.maxLoopIterations != 25)
            expectedDefault = .integer(AppSettings.defaults.agent.maxLoopIterations)
            liveValue = { .integer($0.maxLoopIterations) }
            storedValue = { .integer($0.agent.maxLoopIterations) }
        case "agent.tool-timeout-seconds":
            expected = .integer(120)
            expectedDefault = .integer(300)
            liveValue = { .integer($0.toolTimeoutSeconds) }
            storedValue = { .integer($0.agent.toolTimeoutSeconds) }
        case "agent.concurrent-tool-limit":
            expected = .integer(8)
            expectedDefault = .integer(4)
            liveValue = { .integer($0.concurrentToolLimit) }
            storedValue = { .integer($0.agent.concurrentToolLimit) }
        case "agent.auto-compact-threshold":
            expected = .decimal(0.9)
            expectedDefault = .decimal(0.8)
            liveValue = { .decimal($0.autoCompactThreshold) }
            storedValue = { .decimal($0.agent.autoCompactThreshold) }
        case "agent.persona-preset":
            expected = .text("creative")
            expectedDefault = .text("professional")
            liveValue = { .text($0.personaPreset.rawValue) }
            storedValue = { .text($0.agent.personaPreset.rawValue) }
        case "agent.new-message-interrupts-generation":
            expected = .toggle(true)
            expectedDefault = .toggle(false)
            liveValue = { .toggle($0.newMessageInterruptsGeneration) }
            storedValue = { .toggle($0.agent.newMessageInterruptsGeneration) }
        case "browser.user-agent-preset":
            expected = .text("mobileChrome")
            expectedDefault = .text("desktopChrome")
            liveValue = { .text($0.userAgentPreset.rawValue) }
            storedValue = { .text($0.browser.userAgentPreset.rawValue) }
        case "browser.custom-user-agent":
            expected = .text("Goal17-SETA-Synthetic/1.0")
            expectedDefault = .text("")
            liveValue = { .text($0.customUserAgent) }
            storedValue = { .text($0.browser.customUserAgent) }
        case "browser.viewport-mode":
            expected = .text("custom")
            expectedDefault = .text("autoByUA")
            liveValue = { .text($0.browserViewportMode.rawValue) }
            storedValue = { .text($0.browser.viewportMode.rawValue) }
        case "browser.custom-viewport-width":
            expected = .integer(900)
            expectedDefault = .integer(1280)
            liveValue = { .integer($0.customViewportWidth) }
            storedValue = { .integer($0.browser.customViewportWidth) }
        case "browser.custom-viewport-height":
            expected = .integer(700)
            expectedDefault = .integer(800)
            liveValue = { .integer($0.customViewportHeight) }
            storedValue = { .integer($0.browser.customViewportHeight) }
        case "browser.idle-tab-timeout-minutes":
            expected = .integer(5)
            expectedDefault = .integer(15)
            liveValue = { .integer($0.idleTabTimeoutMinutes) }
            storedValue = { .integer($0.browser.idleTabTimeoutMinutes) }
        case "typography.ui-base-font-size":
            expected = .integer(16)
            expectedDefault = .integer(14)
            liveValue = { .integer($0.uiBaseFontSize) }
            storedValue = { .integer($0.typography.uiBaseFontSize) }
        default:
            Issue.record("unreviewed SETA parameter key: \(key)")
            throw ProductionSettingsTestError.dispatchFailed
        }

        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let directory = root.appendingPathComponent("settings")
        let initial = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(liveValue(center) == expectedDefault)
        #expect(storedValue(center.settingsMirror) == expectedDefault)
        #expect(initial.value(for: key) == expectedDefault)
        #expect(storedValue(SettingsStore(directory: directory).settings) == expectedDefault)
        #expect(expected != expectedDefault)

        let applied = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "seta14-apply-\(key)",
            changes: [key: expected],
            revision: initial.catalogRevision
        )))
        #expect(applied.changedKeys == [key])
        #expect(applied.previousRevision == initial.catalogRevision)
        #expect(applied.visibleOnNextTurn)
        #expect(applied.secretValuesExposed == false)
        let effective = try #require(center.bl6EffectiveSettingsSnapshot)
        #expect(applied.effectiveRevision == effective.catalogRevision)
        #expect(effective.value(for: key) == expected)
        #expect(liveValue(center) == expected)
        #expect(storedValue(center.settingsMirror) == expected)
        #expect(storedValue(center.settingsStore.settings) == expected)
        #expect(storedValue(SettingsStore(directory: directory).settings) == expected)

        let reopened = makeCenter(at: root, using: InMemoryKeychainBacking())
        let reopenedSnapshot = try #require(reopened.bl6EffectiveSettingsSnapshot)
        #expect(reopenedSnapshot.value(for: key) == expected)
        #expect(liveValue(reopened) == expected)
        #expect(storedValue(reopened.settingsMirror) == expected)
        #expect(storedValue(reopened.settingsStore.settings) == expected)
        // Reset while this row is still nondefault, not after a rollback to defaults.
        let reset = try requireSuccess(reopened.dispatchBL6Settings(approved(
            requestID: "seta14-reset-\(key)",
            operation: .reset,
            revision: reopenedSnapshot.catalogRevision
        )))
        #expect(reset.operation == .reset)
        #expect(reset.changedKeys.contains(key))
        #expect(reset.previousRevision == reopenedSnapshot.catalogRevision)
        #expect(reset.visibleOnNextTurn)
        #expect(reset.secretValuesExposed == false)
        let resetSnapshot = try #require(reopened.bl6EffectiveSettingsSnapshot)
        #expect(reset.effectiveRevision == resetSnapshot.catalogRevision)
        #expect(resetSnapshot.value(for: key) == expectedDefault)
        #expect(liveValue(reopened) == expectedDefault)
        #expect(storedValue(reopened.settingsMirror) == expectedDefault)
        #expect(storedValue(SettingsStore(directory: directory).settings) == expectedDefault)

        let reopenedAfterReset = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(reopenedAfterReset.bl6EffectiveSettingsSnapshot?.value(for: key) == expectedDefault)
        #expect(liveValue(reopenedAfterReset) == expectedDefault)
        #expect(storedValue(reopenedAfterReset.settingsMirror) == expectedDefault)
        #expect(storedValue(reopenedAfterReset.settingsStore.settings) == expectedDefault)
        print("SETA14_CASE_COMPLETED key=\(key) applyReadbackDiskReopenReset=true OSRestart=false")
    }

}

private enum ProductionSettingsTestError: Error {
    case dispatchFailed
}

private func removeFixture(_ root: URL) {
    do {
        try FileManager.default.removeItem(at: root)
    } catch {
        Issue.record("failed to remove temporary BL6 fixture: \(error)")
    }
}

@Suite("P0 typed settings reducer")
struct BL6TypedConversationSettingsTests {
    private func snapshot(language: String = "zh-Hans") throws -> BL6EffectiveSettingsSnapshot {
        let catalog = BL6SettingsCatalog.production
        let values = catalog.completeValues(overriding: ["general.language": .text(language)])
        return try catalog.effectiveSnapshot(
            revision: try catalog.revision(for: values),
            values: values
        )
    }

    @Test("catalog scope")
    func catalogScope() throws {
        let catalog = BL6SettingsCatalog.production
        #expect(catalog.entries.count == 43)
        #expect(BL6SettingsCatalog.excludedConversationKeys == ["context_length", "history_rounds"])
        _ = try snapshot()
    }

    @Test("plan policy and revision")
    func planPolicyAndRevision() throws {
        let current = try snapshot()
        let executor = BL6SettingsExecutor()
        let intent = BL6SettingsIntent(
            requestID: "policy",
            changes: ["general.language": .text("en")],
            expectedRevision: current.catalogRevision,
            approval: .approved(receiptID: "approved-policy")
        )
        let plan = try executor.plan(intent, against: current)
        #expect(plan.baseRevision == current.catalogRevision)
        #expect(plan.changedKeys == ["general.language"])
    }

    @Test("apply rollback and CAS")
    func applyRollbackAndCAS() throws {
        let current = try snapshot()
        let executor = BL6SettingsExecutor()
        let plan = try executor.plan(
            BL6SettingsIntent(
                requestID: "apply",
                changes: ["general.language": .text("en")],
                expectedRevision: current.catalogRevision,
                approval: .approved(receiptID: "approved-apply")
            ),
            against: current
        )
        let applied = try executor.execute(plan, against: current)
        #expect(applied.receipt.rollbackValues == current.values)
        #expect(applied.snapshot.value(for: "general.language") == .text("en"))
        let stale = BL6SettingsIntent(
            requestID: "stale",
            changes: ["general.language": .text("fr")],
            expectedRevision: current.catalogRevision,
            approval: .approved(receiptID: "approved-stale")
        )
        #expect(throws: BL6SettingsDispatchError.self) {
            _ = try executor.plan(stale, against: applied.snapshot)
        }
    }

    @Test("reset and provider plan")
    func resetAndProviderPlan() throws {
        let current = try snapshot()
        let executor = BL6SettingsExecutor()
        let provider = BL6ProviderConfigurationPlan(
            providerID: "BL6_TEST_PROVIDER_API_KEY",
            baseURL: "https://provider.invalid/v1",
            modelIDs: ["typed-model"],
            protocolType: "openai-compatible",
            credential: .keepExisting
        )
        let plan = try executor.plan(
            BL6SettingsIntent(
                requestID: "provider",
                operation: .configureProvider,
                expectedRevision: current.catalogRevision,
                approval: .approved(receiptID: "approved-provider"),
                providerConfiguration: provider
            ),
            against: current
        )
        #expect(plan.providerConfiguration == provider)
        let reset = try executor.plan(
            BL6SettingsIntent(
                requestID: "reset",
                operation: .reset,
                expectedRevision: current.catalogRevision,
                approval: .approved(receiptID: "approved-reset")
            ),
            against: current,
            defaults: BL6SettingsCatalog.production.completeValues(overriding: [:])
        )
        #expect(reset.operation == .reset)
    }

    @Test("restart round trip")
    func restartRoundTrip() throws {
        let current = try snapshot()
        let bytes = try JSONEncoder().encode(current)
        let restored = try JSONDecoder().decode(BL6EffectiveSettingsSnapshot.self, from: bytes)
        #expect(restored == current)
    }

    @Test("old and new turn snapshots")
    func oldAndNewTurnSnapshots() throws {
        let old = try snapshot(language: "zh-Hans")
        let new = try snapshot(language: "en")
        let oldTurn = BL6InFlightSettingsSnapshot(snapshot: old, capturedForTurnID: "old-turn")
        let newTurn = BL6InFlightSettingsSnapshot(snapshot: new, capturedForTurnID: "new-turn")
        #expect(oldTurn.snapshot != newTurn.snapshot)
        #expect(oldTurn.capturedForTurnID == "old-turn")
        #expect(newTurn.capturedForTurnID == "new-turn")
    }
}


extension BL6TypedConversationSettingsProductionTests {
    @Test("named editor provenance persists through real SettingsCenter and unrelated BL6 changes")
    func explicitGitEditorPersistenceAndBL6RoundTrips() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let original = center.terminalPolicySettings
        center.terminalPolicySettings = original.editingConfirmationCommands(original.confirmationCommands.filter { $0 != "git" })
        center.terminalPolicySettings = center.terminalPolicySettings.editingConfirmationCommands(original.confirmationCommands)
        #expect(center.terminalPolicySettings.explicitConfirmationCommands == ["git"])
        #expect(center.terminalPolicySnapshot.classify(command: "git status") == .confirmation)
        let reloaded = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(reloaded.terminalPolicySettings == center.terminalPolicySettings)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let source = before.value(for: "agent.terminal-policy")
        let applied = try requireSuccess(center.dispatchBL6Settings(approved(
            requestID: "provenance-unrelated", changes: ["general.language": .text("en")], revision: before.catalogRevision)))
        #expect(center.bl6EffectiveSettingsSnapshot?.value(for: "agent.terminal-policy") == source)
        _ = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "provenance-new-rollback", operation: .rollback,
            changes: applied.rollbackValues, revision: try #require(center.bl6EffectiveSettingsSnapshot).catalogRevision)))
        #expect(center.terminalPolicySettings.explicitConfirmationCommands == ["git"])
        center.resetTerminalPolicyToDefaults()
        _ = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "provenance-new-import",
            changes: ["agent.terminal-policy": try #require(source)],
            revision: try #require(center.bl6EffectiveSettingsSnapshot).catalogRevision)))
        #expect(center.terminalPolicySettings.explicitConfirmationCommands == ["git"])
        #expect(center.terminalPolicySettings.confirmationProvenanceVersion == 1)
        #expect(BL6SettingsCatalog.deniedApprovedMutationKeys.contains("agent.terminal-policy"))
        #expect(throws: BL6SettingsDispatchError.self) {
            try BL6SettingsCatalog.production.validateApprovedMutation(changedKeys: ["agent.terminal-policy"])
        }
        center.resetTerminalPolicyToDefaults()
        #expect(center.terminalPolicySettings == .default)
        #expect(center.terminalPolicySnapshot.classify(command: "git status") == .allowed)
    }

    @Test("BL6 rejects malformed provenance and retains legacy unknown on unrelated edits")
    func explicitGitBL6ShapeAndLegacyRoundTrips() throws {
        let (center, root) = try makeCenter()
        defer { removeFixture(root) }
        let legacy = terminalValue(allowed: ["echo"], confirmation: ["git"], denied: [])
        _ = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "provenance-legacy",
            changes: ["agent.terminal-policy": legacy], revision: try #require(center.bl6EffectiveSettingsSnapshot).catalogRevision)))
        #expect(center.terminalPolicySettings.confirmationProvenanceVersion == nil)
        let reloaded = makeCenter(at: root, using: InMemoryKeychainBacking())
        #expect(reloaded.terminalPolicySettings.confirmationProvenanceVersion == nil)
        let before = try #require(center.bl6EffectiveSettingsSnapshot)
        let applied = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "legacy-unrelated",
            changes: ["general.language": .text("en")], revision: before.catalogRevision)))
        _ = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "legacy-rollback", operation: .rollback,
            changes: applied.rollbackValues, revision: try #require(center.bl6EffectiveSettingsSnapshot).catalogRevision)))
        var oldReceiptValues = try #require(center.bl6EffectiveSettingsSnapshot).values
        oldReceiptValues["agent.terminal-policy"] = legacy
        _ = try requireSuccess(center.dispatchBL6Settings(approved(requestID: "legacy-three-field-rollback", operation: .rollback,
            changes: oldReceiptValues, revision: try #require(center.bl6EffectiveSettingsSnapshot).catalogRevision)))
        #expect(center.terminalPolicySettings.confirmationProvenanceVersion == nil)
        let good = try #require(center.bl6EffectiveSettingsSnapshot)
        guard case let .object(base) = good.value(for: "agent.terminal-policy") else {
            Issue.record("missing terminal projection"); return
        }
        var future = base; future["confirmationProvenanceVersion"] = .integer(2)
        var subset = base; subset["explicitConfirmationCommands"] = .list(["echo"])
        var partial = base; partial.removeValue(forKey: "explicitConfirmationCommands")
        var wrongKind = base; wrongKind["confirmationProvenanceVersion"] = .text("1")
        for (index, invalid) in [future, subset, partial, wrongKind].enumerated() {
            let result = center.dispatchBL6Settings(approved(requestID: "invalid-provenance-\(index)",
                changes: ["agent.terminal-policy": .object(invalid)], revision: good.catalogRevision))
            if case .success = result { Issue.record("invalid provenance accepted") }
            #expect(center.bl6EffectiveSettingsSnapshot?.values == good.values)
        }
        // Changing provenance only must survive normalized equality and save.
        let old = center.terminalPolicySettings
        center.terminalPolicySettings = old.editingConfirmationCommands([]).editingConfirmationCommands(["git"])
        #expect(center.terminalPolicySettings.confirmationCommands == old.confirmationCommands)
        #expect(center.terminalPolicySettings != old)
        #expect(makeCenter(at: root, using: InMemoryKeychainBacking()).terminalPolicySettings == center.terminalPolicySettings)
    }
}


extension BL6TypedConversationSettingsProductionTests {
    @Test("future provenance opens in the existing visible read-only recovery state")
    func futureTerminalProvenanceRecoveryIsVisible() throws {
        let (_, root) = try makeCenter()
        defer { removeFixture(root) }
        let url = root.appendingPathComponent("settings/settings.json")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        var agent = try #require(object["agent"] as? [String: Any])
        var terminal = try #require(agent["terminalPolicy"] as? [String: Any])
        terminal["confirmationProvenanceVersion"] = 2
        agent["terminalPolicy"] = terminal; object["agent"] = agent
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: url)
        let reopened = makeCenter(at: root, using: InMemoryKeychainBacking())
        // SettingsView's existing error banner now also projects this store
        // recovery error on initial open, before a user attempts a write.
        #expect(reopened.settingsStore.lastPersistenceError == .transactionRecoveryRequired)
        #expect(reopened.bl6SettingsTransactionState == .unknown)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
