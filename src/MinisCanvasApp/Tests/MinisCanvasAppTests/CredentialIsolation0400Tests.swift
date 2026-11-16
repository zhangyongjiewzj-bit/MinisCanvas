import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Holds only an injected synthetic physical read. No OS Keychain access.
private final class Credential0400Backing: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [String: String] = [:]
    private var heldKey: String?
    private var started = false
    private var released = false
    private var counts = (reads: 0, writes: 0, deletes: 0)
    var operations: (reads: Int, writes: Int, deletes: Int) {
        condition.lock(); defer { condition.unlock() }; return counts
    }
    func resetCounts() { condition.lock(); defer { condition.unlock() }; counts = (0, 0, 0) }
    func holdNextRead(_ key: String) {
        condition.lock(); defer { condition.unlock() }
        heldKey = key; started = false; released = false
    }
    private var readStarted: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func awaitPhysicalRead() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !readStarted && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard readStarted else { releaseRead(); throw NSError(domain: "Credential0400.read-not-started", code: 1) }
    }
    func releaseRead() { condition.lock(); defer { condition.unlock() }; released = true; condition.broadcast() }
    func set(_ value: String, forKey key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }; counts.writes += 1; values[key] = value; return true
    }
    func get(_ key: String) -> String? {
        condition.lock(); defer { condition.unlock() }; counts.reads += 1; return values[key]
    }
    func delete(_ key: String) -> Bool {
        condition.lock(); defer { condition.unlock() }; counts.deletes += 1; values.removeValue(forKey: key); return true
    }
    func readResult(forKey key: String) -> KeychainReadResult {
        condition.lock(); defer { condition.unlock() }
        counts.reads += 1
        let result = values[key].map(KeychainReadResult.found) ?? .missing
        if heldKey == key {
            heldKey = nil; started = true; condition.broadcast()
            while !released { condition.wait() }
        }
        return result
    }
}

@MainActor
private final class Credential0400Pasteboard: ProviderCredentialPasteboard {
    private(set) var changeCount = 0
    private(set) var writes = 0
    func write(_ value: String) -> Bool { writes += 1; changeCount += 1; return true }
    func clearIfUnchanged(since count: Int) -> Bool {
        guard changeCount == count else { return false }; changeCount += 1; return true
    }
}

@Suite("0400 same-ID credential edit and rejected-save late-read isolation", .serialized)
@MainActor
struct CredentialIsolation0400Tests {
    enum Edit: String, CaseIterable, Sendable { case keepExisting, rejectedBlank, replaceValue }
    private func settle(_ model: ProviderCredentialControlsModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.state == .readingReveal && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state != .readingReveal)
    }

    @Test(arguments: Edit.allCases)
    func sameIDMetadataCommitRejectedBlankOrReplacementControlsLateReadAndFreshCustody(_ edit: Edit) async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("Credential0400-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let backing = Credential0400Backing()
        let keychain = KeychainStore(backing: backing)
        func makeCenter() -> SettingsCenter {
            SettingsCenter(settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
                logManager: LogManager(directory: root.appendingPathComponent("logs")),
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: .suite(root.lastPathComponent)))
        }
        let center = makeCenter()
        let alpha = "SYNTHETIC0400_ALPHA_API_KEY", beta = "SYNTHETIC0400_BETA_API_KEY"
        let alphaValue = "synthetic-canary0400-alpha-" + UUID().uuidString
        let betaValue = "synthetic-canary0400-beta-" + UUID().uuidString
        let replacement = "synthetic-canary0400-replacement-" + UUID().uuidString
        let bindingChanges = edit != .rejectedBlank
        let expectedAlpha = edit == .replaceValue ? replacement : alphaValue
        try #require(center.saveProvider(name: alpha, credential: .replace(alphaValue),
            baseURL: "https://alpha0400.invalid/v1", modelNames: ["alpha-before"], protocolType: .openaiCompatible))
        try #require(center.saveProvider(name: beta, credential: .replace(betaValue),
            baseURL: "https://beta0400.invalid/v1", modelNames: ["beta-model"], protocolType: .openaiCompatible))
        let alphaRecord = try #require(center.providerRecords.first { $0.name == alpha })
        let betaRecord = try #require(center.providerRecords.first { $0.name == beta })
        let originalBinding = try #require(center.providerCredentialBinding(recordID: alphaRecord.id))
        let betaBinding = try #require(center.providerCredentialBinding(recordID: betaRecord.id))
        let custodyToken = try #require(keychain.consistencyToken(forKey: alpha))
        let betaCustodyToken = try #require(keychain.consistencyToken(forKey: beta))
        let alphaPasteboard = Credential0400Pasteboard(), betaPasteboard = Credential0400Pasteboard()
        let oldAlpha = try #require(center.makeProviderCredentialControlsModel(
            recordID: alphaRecord.id, pasteboard: alphaPasteboard))
        let betaControl = try #require(center.makeProviderCredentialControlsModel(
            recordID: betaRecord.id, pasteboard: betaPasteboard))
        defer { backing.releaseRead(); oldAlpha.close(); betaControl.close() }
        backing.holdNextRead(alpha)
        oldAlpha.reveal()
        try await backing.awaitPhysicalRead()
        betaControl.reveal()
        try await settle(betaControl)
        let betaStillOwn = betaControl.visibleValue == betaValue
        #expect(betaStillOwn)
        #expect(oldAlpha.visibleValue == nil)
        // Saving happens while the actual old read is blocked off MainActor.
        // The save-only phase never reads or deletes. Only an explicit valid
        // replacement writes; keeping or rejecting an edit preserves custody.
        backing.resetCounts()
        let metadata = root.appendingPathComponent("env").appendingPathComponent(EnvVarStore.fileName)
        let bytesBefore = try Data(contentsOf: metadata)
        let update: ProviderCredentialUpdate
        switch edit {
        case .keepExisting: update = .keepExisting
        case .rejectedBlank: update = .replace(" \n\t ")
        case .replaceValue: update = .replace(replacement)
        }
        let saved = center.saveProvider(name: alpha,
            credential: update,
            baseURL: "https://alpha0400.invalid/v2", modelNames: ["alpha-after"], protocolType: .anthropic)
        #expect(saved == bindingChanges)
        #expect(backing.operations.reads == 0)
        #expect(backing.operations.writes == (edit == .replaceValue ? 1 : 0))
        #expect(backing.operations.deletes == 0)
        if edit == .replaceValue {
            #expect(keychain.consistencyToken(forKey: alpha) != custodyToken)
        } else {
            #expect(keychain.consistencyToken(forKey: alpha) == custodyToken)
        }
        let currentBinding = try #require(center.providerCredentialBinding(recordID: alphaRecord.id))
        #expect(currentBinding.providerID == originalBinding.providerID)
        #expect(currentBinding.credentialName == originalBinding.credentialName)
        if bindingChanges {
            #expect(currentBinding.revision != originalBinding.revision)
        } else {
            #expect(center.providerSaveFailure == .missingCredential)
            #expect(currentBinding == originalBinding)
            #expect(try Data(contentsOf: metadata) == bytesBefore)
        }
        let currentBetaBinding = try #require(center.providerCredentialBinding(recordID: betaRecord.id))
        #expect(currentBetaBinding.providerID == betaBinding.providerID)
        #expect(currentBetaBinding.credentialName == betaBinding.credentialName)
        #expect(center.providerRecords.first { $0.id == betaRecord.id } == betaRecord)
        #expect(keychain.consistencyToken(forKey: beta) == betaCustodyToken)
        if bindingChanges {
            // The canonical binding includes the shared metadata-file token.
            // A successful A commit invalidates old UI requests for B too;
            // this is masking, not a change of B identity or credential.
            #expect(currentBetaBinding.revision != betaBinding.revision)
        } else {
            #expect(currentBetaBinding == betaBinding)
        }
        backing.releaseRead()
        try await settle(oldAlpha)
        if bindingChanges {
            #expect(oldAlpha.visibleValue == nil)
            #expect(oldAlpha.state == .failed(.staleRequest))
        } else {
            let rejectedSavePreservesRead = oldAlpha.visibleValue == alphaValue
            #expect(rejectedSavePreservesRead)
        }
        if bindingChanges {
            #expect(betaControl.visibleValue == nil)
        } else {
            let betaRemainsLegitimatelyVisible = betaControl.visibleValue == betaValue
            #expect(betaRemainsLegitimatelyVisible)
        }
        #expect(alphaPasteboard.writes == 0 && betaPasteboard.writes == 0)
        // Fresh stores preserve both actual stable IDs and the original values;
        // success of a metadata edit is distinct from credential replacement.
        let reopened = makeCenter()
        #expect(reopened.providerRecords.first { $0.name == alpha }?.id == alphaRecord.id)
        #expect(reopened.providerRecords.first { $0.name == beta }?.id == betaRecord.id)
        let freshAlpha = try #require(reopened.makeProviderCredentialControlsModel(
            recordID: alphaRecord.id, pasteboard: Credential0400Pasteboard()))
        let freshBeta = try #require(reopened.makeProviderCredentialControlsModel(
            recordID: betaRecord.id, pasteboard: Credential0400Pasteboard()))
        defer { freshAlpha.close(); freshBeta.close() }
        freshAlpha.reveal(); freshBeta.reveal()
        try await settle(freshAlpha); try await settle(freshBeta)
        let freshAlphaOwn = freshAlpha.visibleValue == expectedAlpha
        let freshBetaOwn = freshBeta.visibleValue == betaValue
        #expect(freshAlphaOwn && freshBetaOwn)
        let freshAlphaBinding = try #require(reopened.providerCredentialBinding(recordID: alphaRecord.id))
        let freshBetaBinding = try #require(reopened.providerCredentialBinding(recordID: betaRecord.id))
        #expect(freshAlphaBinding.providerID != freshBetaBinding.providerID)
        for control in [oldAlpha, betaControl, freshAlpha, freshBeta] {
            let snapshot = String(describing: control.accessibilitySnapshot)
            let noCanary = !snapshot.contains(alphaValue) && !snapshot.contains(betaValue) && !snapshot.contains(replacement)
            #expect(noCanary) // Production AX projection only, not native AX.
        }
        let metadataText = String(decoding: try Data(contentsOf: metadata), as: UTF8.self)
        let metadataSecretFree = !metadataText.contains(alphaValue) && !metadataText.contains(betaValue) && !metadataText.contains(replacement)
        #expect(metadataSecretFree)
    }
}
