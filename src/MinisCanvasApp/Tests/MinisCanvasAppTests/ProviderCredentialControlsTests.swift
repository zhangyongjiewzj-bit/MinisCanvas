import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class F03KeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum Mode: Sendable {
        case found
        case missing
        case denied
        case failed
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private let mode: Mode

    init(mode: Mode = .found) {
        self.mode = mode
    }

    @discardableResult
    nonisolated func set(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        values[key] = value
        lock.unlock()
        return true
    }

    nonisolated func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    nonisolated func delete(_ key: String) -> Bool {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
        return true
    }

    nonisolated func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock()
        let value = values[key]
        lock.unlock()
        switch mode {
        case .found:
            return value.map(KeychainReadResult.found) ?? .missing
        case .missing:
            return .missing
        case .denied:
            return .denied
        case .failed:
            return .failed
        }
    }
}

/// Hold one synthetic Keychain read after its value is captured. The blocked
/// call runs inside KeychainStore's detached async reader, not on MainActor.
private final class F03DelayedKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [String: String] = [:]
    private var delayedKey: String?
    private var readStarted = false
    private var readReleased = false

    func delayNextRead(forKey key: String) {
        condition.lock(); defer { condition.unlock() }
        delayedKey = key
        readStarted = false
        readReleased = false
    }

    func waitUntilReadStarted() async throws {
        for _ in 0..<300 {
            if hasStarted() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        releaseRead()
        throw NSError(domain: "F03DelayedKeychainBacking.read-not-started", code: 1)
    }

    private func hasStarted() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return readStarted
    }

    func releaseRead() {
        condition.lock(); defer { condition.unlock() }
        readReleased = true
        condition.broadcast()
    }

    func set(_ value: String, forKey key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        condition.lock(); defer { condition.unlock() }
        return values[key]
    }

    func delete(_ key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        values.removeValue(forKey: key)
        return true
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        condition.lock(); defer { condition.unlock() }
        let captured = values[key].map(KeychainReadResult.found) ?? .missing
        if delayedKey == key {
            delayedKey = nil
            readStarted = true
            condition.broadcast()
            while !readReleased { condition.wait() }
        }
        return captured
    }
}

@MainActor
private final class F03Pasteboard: ProviderCredentialPasteboard {
    private(set) var changeCount = 0
    private(set) var copiedString: String?
    private(set) var clearCount = 0

    @discardableResult
    func write(_ value: String) -> Bool {
        copiedString = value
        changeCount += 1
        return true
    }

    @discardableResult
    func clearIfUnchanged(since count: Int) -> Bool {
        guard changeCount == count else { return false }
        copiedString = nil
        changeCount += 1
        clearCount += 1
        return true
    }

    func userReplacesClipboard(with value: String) {
        copiedString = value
        changeCount += 1
    }
}

private actor F03ReadGate {
    typealias Outcome = SettingsCenter.ProviderCredentialReadOutcome
    private var continuation: CheckedContinuation<Outcome, Never>?

    func read() async -> Outcome {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<300 {
            if continuation != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "F03ReadGate.read-not-started", code: 1)
    }

    func release(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

@Suite("F03 provider credential controls")
@MainActor
struct ProviderCredentialControlsTests {
    private let providerID = "F03_SYNTHETIC_PROVIDER"
    private let credentialName = "F03_SYNTHETIC_PROVIDER_API_KEY"
    private let secret = "f03-synthetic-secret-only"

    private func binding(revision: String = "revision-1") -> ProviderCredentialBinding {
        ProviderCredentialBinding(
            providerID: providerID,
            credentialName: credentialName,
            revision: revision
        )
    }

    private func makeCenter(
        backing: F03KeychainBacking,
        value: String = "f03-synthetic-secret-only"
    ) throws -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("F03-credential-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: backing)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"),
                keychain: keychain
            )
        )
        #expect(center.saveProvider(
            name: credentialName,
            apiKey: value,
            baseURL: "https://invalid.local/v1",
            modelNames: ["synthetic-model"],
            protocolType: .openaiCompatible
        ))
        return (center, root)
    }

    private func settle(_ model: ProviderCredentialControlsModel) async throws {
        for _ in 0..<300 {
            if model.state != .readingReveal && model.state != .readingCopy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "F03Controls.read-not-settled", code: 1)
    }

    @Test func twoProviderRenameReloadRejectsLateProductionCredentialRead1739() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("F03-generation-1739-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "F03-generation-1739-\(UUID().uuidString)"
        let privacyDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { privacyDefaults.removePersistentDomain(forName: suiteName) }
        let backing = F03DelayedKeychainBacking()
        let keychain = KeychainStore(backing: backing)
        func center() -> SettingsCenter {
            SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: privacyDefaults)),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills"))
            )
        }
        let original = center()
        let alpha = "F03_ALPHA_1739_API_KEY"
        let beta = "F03_BETA_1739_API_KEY"
        let renamed = "F03_ALPHA_RENAMED_1739_API_KEY"
        #expect(original.saveProvider(name: alpha, apiKey: "synthetic-alpha-before",
            baseURL: "https://alpha.invalid/v1", modelNames: ["alpha-model"], protocolType: .openaiCompatible))
        #expect(original.saveProvider(name: beta, apiKey: "synthetic-beta",
            baseURL: "https://beta.invalid/v1", modelNames: ["beta-model"], protocolType: .openaiCompatible))
        let alphaRecord = try #require(original.providerRecords.first { $0.name == alpha })
        let betaRecord = try #require(original.providerRecords.first { $0.name == beta })
        let alphaBinding = try #require(original.providerCredentialBinding(recordID: alphaRecord.id))
        let betaBinding = try #require(original.providerCredentialBinding(recordID: betaRecord.id))
        #expect(alphaBinding.providerID != betaBinding.providerID)
        let oldPasteboard = F03Pasteboard()
        let oldAlpha = try #require(original.makeProviderCredentialControlsModel(
            recordID: alphaRecord.id, pasteboard: oldPasteboard))
        let oldBeta = try #require(original.makeProviderCredentialControlsModel(
            recordID: betaRecord.id, pasteboard: F03Pasteboard()))

        backing.delayNextRead(forKey: alpha)
        oldAlpha.reveal()
        defer { backing.releaseRead() }
        try await backing.waitUntilReadStarted()
        oldBeta.reveal()
        try await settle(oldBeta)
        #expect(oldBeta.visibleValue == "synthetic-beta")
        #expect(oldAlpha.visibleValue == nil)

        let preview = try original.previewProviderRename(from: alpha, to: renamed)
        let confirmed = preview.withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try original.renameProvider(
            from: alpha, to: renamed, apiKey: "synthetic-alpha-after",
            baseURL: "https://alpha.invalid/v2", modelNames: ["alpha-model"],
            protocolType: .openaiCompatible, intent: confirmed)
        #expect(original.providerCredentialBinding(recordID: alphaRecord.id) == nil)
        #expect(original.providerCredentialBinding(recordID: betaRecord.id)?.providerID == betaBinding.providerID)
        backing.releaseRead()
        try await settle(oldAlpha)
        #expect(oldAlpha.visibleValue == nil)
        #expect(oldAlpha.state == .failed(.staleRequest))
        #expect(oldPasteboard.copiedString == nil)

        let restored = center() // Reload the same isolated metadata and synthetic Keychain domain.
        let newAlphaRecord = try #require(restored.providerRecords.first { $0.name == renamed })
        let newBetaRecord = try #require(restored.providerRecords.first { $0.name == beta })
        let newAlphaBinding = try #require(restored.providerCredentialBinding(recordID: newAlphaRecord.id))
        let newBetaBinding = try #require(restored.providerCredentialBinding(recordID: newBetaRecord.id))
        #expect(newAlphaBinding.providerID != alphaBinding.providerID)
        #expect(newBetaBinding.providerID == betaBinding.providerID)
        let newAlpha = try #require(restored.makeProviderCredentialControlsModel(
            recordID: newAlphaRecord.id, pasteboard: F03Pasteboard()))
        let newBeta = try #require(restored.makeProviderCredentialControlsModel(
            recordID: newBetaRecord.id, pasteboard: F03Pasteboard()))
        newAlpha.reveal()
        newBeta.reveal()
        try await settle(newAlpha)
        try await settle(newBeta)
        #expect(newAlpha.visibleValue == "synthetic-alpha-after")
        #expect(newBeta.visibleValue == "synthetic-beta")
        #expect(oldAlpha.visibleValue == nil)
    }

    @Test func actualParentFactoryBindsStoredRecordAndInvalidatesOnReplacement() async throws {
        let (center, root) = try makeCenter(backing: F03KeychainBacking())
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try #require(center.providerRecords.first)
        let before = try #require(center.providerCredentialBinding(recordID: record.id))
        #expect(before.providerID == record.id)
        #expect(before.credentialName == record.name)
        #expect(before.providerID != before.credentialName)
        let pasteboard = F03Pasteboard()
        let model = try #require(center.makeProviderCredentialControlsModel(recordID: record.id, pasteboard: pasteboard))
        model.reveal()
        for _ in 0..<200 {
            if model.state != .readingReveal { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.visibleValue == secret)
        #expect(center.saveProvider(name: credentialName, credential: .replace("f03-synthetic-replacement"),
            baseURL: "https://invalid.local/v1", modelNames: ["synthetic-model"], protocolType: .openaiCompatible))
        let after = try #require(center.providerCredentialBinding(recordID: record.id))
        #expect(after.providerID == before.providerID)
        #expect(after.revision != before.revision)
        #expect(model.visibleValue == nil)
        model.copy()
        #expect(pasteboard.copiedString == nil)
        model.refresh()
        #expect(model.isClosed)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/SettingsView.swift"), encoding: .utf8)
        #expect(source.contains("credentialSettings: center"))
        #expect(source.contains("credentialSettings?.makeProviderCredentialControlsModel(recordID: existing.id)"))
        #expect(source.contains("ProviderCredentialControls(model: credentialControlsModel)"))
    }

    @Test func explicitRevealUsesTypedSettingsReadAndMasksAfterFifteenSeconds() async throws {
        let backing = F03KeychainBacking()
        let (center, root) = try makeCenter(backing: backing)
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = F03Pasteboard()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let currentBinding = binding()
        let model = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: pasteboard,
            now: { currentDate }
        )

        #expect(model.state == .hidden)
        #expect(model.visibleValue == nil)
        model.reveal()
        try await settle(model)

        #expect(model.visibleValue == secret)
        if case .revealed(let until) = model.state {
            #expect(until == currentDate.addingTimeInterval(15))
        } else {
            Issue.record("explicit reveal did not enter revealed state")
        }
        #expect(model.accessibilitySnapshot.exposedValues.isEmpty)
        #expect(model.accessibilitySnapshot.controlLabels == ["显示 API Key", "复制 API Key"])
        #expect(pasteboard.copiedString == nil)

        currentDate = currentDate.addingTimeInterval(15)
        model.refresh()
        #expect(model.state == .hidden)
        #expect(model.visibleValue == nil)
    }

    @Test func focusLossBackgroundAndCloseMaskRevealWithoutImplicitCopy() async throws {
        let backing = F03KeychainBacking()
        let (center, root) = try makeCenter(backing: backing)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentBinding = binding()
        let model = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: F03Pasteboard(),
            now: Date.init
        )

        model.reveal()
        try await settle(model)
        #expect(model.visibleValue == secret)
        model.focusLost()
        #expect(model.visibleValue == nil)
        #expect(model.state == .hidden)
        #expect(model.accessibilitySnapshot.exposedValues.isEmpty)
        model.reveal()
        try await settle(model)
        model.appDidEnterBackground()
        #expect(model.visibleValue == nil)
        model.close()
        #expect(model.isClosed)
        #expect(model.state == .hidden)
    }

    @Test func copyOwnsAndClearsOnlyUnchangedPasteboardAfterSixtySeconds() async throws {
        let backing = F03KeychainBacking()
        let (center, root) = try makeCenter(backing: backing)
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = F03Pasteboard()
        var currentDate = Date(timeIntervalSince1970: 2_000)
        let currentBinding = binding()
        let model = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: pasteboard,
            now: { currentDate }
        )

        model.copy()
        try await settle(model)
        #expect(pasteboard.copiedString == secret)
        #expect(model.visibleValue == nil)
        currentDate = currentDate.addingTimeInterval(59)
        model.refresh()
        #expect(pasteboard.clearCount == 0)
        pasteboard.userReplacesClipboard(with: "user-owned-clipboard")
        currentDate = currentDate.addingTimeInterval(1)
        model.refresh()
        #expect(pasteboard.clearCount == 0)
        #expect(pasteboard.copiedString == "user-owned-clipboard")

        model.copy()
        try await settle(model)
        currentDate = currentDate.addingTimeInterval(60)
        model.refresh()
        #expect(pasteboard.clearCount == 1)
        #expect(pasteboard.copiedString == nil)
    }

    @Test func typedMissingDeniedAndFailedReadsRemainSecretFree() async throws {
        let cases: [(F03KeychainBacking.Mode, ProviderCredentialControlFailure)] = [
            (.missing, .missing),
            (.denied, .denied),
            (.failed, .failed)
        ]
        for (mode, expected) in cases {
            let backing = F03KeychainBacking(mode: mode)
            let (center, root) = try makeCenter(backing: backing)
            defer { try? FileManager.default.removeItem(at: root) }
            let currentBinding = binding()
            let model = ProviderCredentialControlsModel(
                settings: center,
                binding: currentBinding,
                currentBinding: { currentBinding },
                pasteboard: F03Pasteboard(),
                now: Date.init
            )
            model.reveal()
            try await settle(model)
            #expect(model.state == .failed(expected))
            #expect(model.visibleValue == nil)
            #expect(model.accessibilitySnapshot.exposedValues.isEmpty)
        }
    }

    @Test func nonActiveScenePhaseRemasksRevealWhileActiveKeepsIt() async throws {
        let backing = F03KeychainBacking()
        let (center, root) = try makeCenter(backing: backing)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentBinding = binding()
        let model = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: F03Pasteboard(),
            now: Date.init
        )

        model.reveal()
        try await settle(model)
        #expect(model.visibleValue == secret)

        // An active->active notification must not mask early.
        model.scenePhaseChanged(to: .active)
        #expect(model.visibleValue == secret)

        // macOS reports .inactive when the app resigns front or the window
        // stops being key: the revealed Keychain value must disappear now,
        // not only at the 15-second deadline or on .background.
        model.scenePhaseChanged(to: .inactive)
        #expect(model.visibleValue == nil)
        #expect(model.state == .hidden)
        model.reveal()
        try await settle(model)
        #expect(model.visibleValue == secret)
        model.scenePhaseChanged(to: .background)
        #expect(model.visibleValue == nil)
        #expect(model.state == .hidden)
    }

    @Test func closeScrubsOwnedClipboardCopyOnlyWhileItIsUnchanged() async throws {
        let backing = F03KeychainBacking()
        let (center, root) = try makeCenter(backing: backing)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentBinding = binding()

        // Unchanged owned copy is scrubbed when the row closes.
        let keptPasteboard = F03Pasteboard()
        let keptModel = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: keptPasteboard,
            now: Date.init
        )
        keptModel.copy()
        try await settle(keptModel)
        #expect(keptPasteboard.copiedString == secret)
        keptModel.close()
        #expect(keptPasteboard.clearCount == 1)
        #expect(keptPasteboard.copiedString == nil)

        // If the user replaced the clipboard first, closing must not clear
        // the user's content, and the secret is already gone from the
        // pasteboard regardless.
        let replacedPasteboard = F03Pasteboard()
        let replacedModel = ProviderCredentialControlsModel(
            settings: center,
            binding: currentBinding,
            currentBinding: { currentBinding },
            pasteboard: replacedPasteboard,
            now: Date.init
        )
        replacedModel.copy()
        try await settle(replacedModel)
        replacedPasteboard.userReplacesClipboard(with: "user-owned-clipboard")
        replacedModel.close()
        #expect(replacedPasteboard.clearCount == 0)
        #expect(replacedPasteboard.copiedString == "user-owned-clipboard")
    }

    @Test func revealViewRoutesEveryScenePhaseThroughTheMaskingPolicy() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/ProviderCredentialControls.swift"), encoding: .utf8)
        // The view must not reintroduce a background-only mask condition.
        #expect(source.contains("model.scenePhaseChanged(to: phase)"))
    }

    @Test func staleBindingAndCancelledReadCannotRevealOrCopy() async throws {
        let pasteboard = F03Pasteboard()
        let gate = F03ReadGate()
        let firstBinding = binding()
        let currentBinding = F03CurrentBinding(firstBinding)
        let model = ProviderCredentialControlsModel(
            binding: firstBinding,
            currentBinding: { currentBinding.value },
            pasteboard: pasteboard,
            now: Date.init,
            readCredential: { _ in await gate.read() }
        )

        model.reveal()
        try await gate.waitUntilStarted()
        currentBinding.value = binding(revision: "revision-2")
        await gate.release(.success(secret))
        try await settle(model)
        #expect(model.visibleValue == nil)
        #expect(model.state == .failed(.staleRequest))
        #expect(pasteboard.copiedString == nil)

        currentBinding.value = firstBinding
        model.reveal()
        try await gate.waitUntilStarted()
        model.focusLost()
        await gate.release(.success(secret))
        try await settle(model)
        #expect(model.visibleValue == nil)
        #expect(model.state == .hidden)
        #expect(pasteboard.copiedString == nil)
    }

    @Test func closeBeforeScheduledReadStartsPreventsCredentialAccess() async {
        var reads = 0
        let current = binding()
        let model = ProviderCredentialControlsModel(binding: current, currentBinding: { current },
            pasteboard: F03Pasteboard(), now: Date.init, readCredential: { _ in
                reads += 1
                return .success("must-not-be-read")
            })
        model.reveal()
        let cancelled = model.close()
        await cancelled?.value
        #expect(reads == 0)
        #expect(model.visibleValue == nil)
        #expect(model.state == .hidden)
    }

    @Test func invalidOrDeletedBindingFailsBeforeCredentialRead() {
        let pasteboard = F03Pasteboard()
        var readCount = 0
        let binding = self.binding()
        let model = ProviderCredentialControlsModel(
            binding: binding,
            currentBinding: { nil },
            pasteboard: pasteboard,
            now: Date.init,
            readCredential: { _ in
                readCount += 1
                return .success("must-not-be-read")
            }
        )

        model.reveal()
        #expect(model.state == .failed(.staleBinding))
        #expect(readCount == 0)
        #expect(model.visibleValue == nil)
    }
}

@MainActor
private final class F03CurrentBinding {
    var value: ProviderCredentialBinding?
    init(_ value: ProviderCredentialBinding?) { self.value = value }
}
