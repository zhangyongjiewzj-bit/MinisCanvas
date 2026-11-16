import Foundation
import Testing
@testable import MinisCore

/// Only explicit synthetic dictionaries, disposable preferences, and an
/// in-memory credential backend. No ProcessInfo environment or live Keychain.
@Suite("D-PRIVACY-07/08 stored-secret import projection")
struct PrivacyProcessPreview362Tests {
    private final class Backing: KeychainBacking, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var counts = [0, 0, 0]

        func set(_ value: String, forKey key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            counts[0] += 1
            values[key] = value
            return true
        }
        func get(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            counts[1] += 1
            return values[key]
        }
        func delete(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            counts[2] += 1
            values.removeValue(forKey: key)
            return true
        }
        var operations: [Int] {
            lock.lock(); defer { lock.unlock() }
            return counts
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Privacy362-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: [false, true])
    func storedExplicitSecretsAndProviderNamesStayHiddenEvenAfterReload(reload: Bool) throws {
        let root = try root()
        let suite = "Privacy362.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let privacy = EnvVarPrivacyStore(defaults: defaults)
        let backing = Backing()
        let keychain = KeychainStore(backing: backing)
        var store = EnvVarStore(directory: root, keychain: keychain, privacyStore: privacy)
        let existing = "violet-stored-explicit-362"
        #expect(store.setEnvVar(name: "PRIVATE362_VALUE", value: existing, isSecret: true))
        #expect(store.saveProvider(name: "PROVIDER362", apiKey: "amber-provider-362",
                                  baseURL: "https://synthetic.invalid", modelNames: ["synthetic-model"],
                                  protocolType: .openaiCompatible))
        #expect(store.setEnvVar(name: "PUBLIC362_VALUE", value: "original-public", isSecret: false))
        #expect(!privacy.isSecret(name: "PRIVATE362_VALUE"))
        #expect(!privacy.isSecret(name: "PROVIDER362"))
        if reload { store = EnvVarStore(directory: root, keychain: keychain, privacyStore: privacy) }
        let metadata = root.appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: metadata)
        let operations = backing.operations
        let raw = ["private362_value": "violet-process-explicit-362",
                   "PROVIDER362": "amber-process-provider-362",
                   "PUBLIC362_VALUE": "changed-public"]
        let rows = store.processEnvironmentImportPreview(source: raw)
        for name in ["PRIVATE362_VALUE", "PROVIDER362"] {
            let row = try #require(rows.first { $0.name == name })
            #expect(row.changeKind == .skip && row.skipReason == .alreadyStored)
            #expect(!row.isSelectableForImport)
            #expect(row.isSecretClassified)
            #expect(row.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
            #expect(!String(describing: row).contains("process-"))
        }
        let publicRow = try #require(rows.first { $0.name == "PUBLIC362_VALUE" })
        #expect(publicRow.changeKind == .update && !publicRow.isSecretClassified)
        #expect(publicRow.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(try Data(contentsOf: metadata) == before)
        #expect(backing.operations == operations)
        // Even a forged selection cannot overwrite either saved credential.
        let outcomes = store.applyProcessEnvironmentImport(selectedNames: Array(raw.keys), source: raw)
        #expect(outcomes.values.allSatisfy { $0 == .skippedAlreadyStored })
        #expect(try Data(contentsOf: metadata) == before)
        #expect(backing.operations == operations)
    }

    @Test func retainedKeychainOwnershipCannotBecomeAPlainPreview() throws {
        let root = try root()
        let suite = "Privacy362.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        // A legacy metadata flag combination still describes a deferred
        // credential; preview must not resolve it or expose the process value.
        let entry = EnvVarEntry(name: "LEGACY362", value: "", isSecret: false, valueInKeychain: true)
        let metadata = root.appendingPathComponent(EnvVarStore.fileName)
        try JSONEncoder().encode([entry]).write(to: metadata)
        let backing = Backing()
        let store = EnvVarStore(directory: root, keychain: KeychainStore(backing: backing),
                                privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let before = try Data(contentsOf: metadata)
        let row = try #require(store.processEnvironmentImportPreview(
            source: ["LEGACY362": "violet-deferred-process-362"]
        ).first)
        #expect(row.isSecretClassified && !row.isSelectableForImport)
        #expect(row.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder)
        #expect(!String(describing: row).contains("violet-deferred-process-362"))
        #expect(backing.operations == [0, 0, 0])
        #expect(try Data(contentsOf: metadata) == before)
    }

    @Test func explicitSelectionImportsOnlyChosenValuesAndProtectsBothLogSinks() throws {
        let root = try root()
        let suite = "Privacy362.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let backing = Backing()
        let store = EnvVarStore(directory: root.appendingPathComponent("env"),
                                keychain: KeychainStore(backing: backing),
                                privacyStore: EnvVarPrivacyStore(defaults: defaults))
        let logger = LogManager(directory: root.appendingPathComponent("logs"))
        store.attachLogRedaction(to: logger)
        let chosen = "violet-selected-private-362"
        let unselected = "amber-unselected-private-362"
        let source = ["CHOSEN362_TOKEN": chosen, "UNSELECTED362_TOKEN": unselected,
                      "PUBLIC362": "visible-public", "EMPTY362": ""]
        let rows = store.processEnvironmentImportPreview(source: source)
        #expect(rows.filter(\.isSecretClassified).allSatisfy {
            $0.valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder
        })
        #expect(store.count == 0 && backing.operations == [0, 0, 0])
        // Cancel/no selected names is zero mutation; there is no blanket grant.
        #expect(store.applyProcessEnvironmentImport(selectedNames: [], source: source).isEmpty)
        #expect(store.count == 0 && backing.operations == [0, 0, 0])
        let outcomes = store.applyProcessEnvironmentImport(
            selectedNames: ["CHOSEN362_TOKEN", "PUBLIC362"], source: source
        )
        #expect(outcomes == ["CHOSEN362_TOKEN": .imported, "PUBLIC362": .imported])
        #expect(store.entry(name: "UNSELECTED362_TOKEN") == nil)
        #expect(store.entry(name: "EMPTY362") == nil)
        #expect(store.getEnvVar(name: "CHOSEN362_TOKEN") == chosen)
        #expect(store.getEnvVar(name: "PUBLIC362") == "visible-public")
        let metadata = root.appendingPathComponent("env").appendingPathComponent(EnvVarStore.fileName)
        let disk = String(decoding: try Data(contentsOf: metadata), as: UTF8.self)
        #expect(!disk.contains(chosen) && !disk.contains(unselected))
        #expect(disk.contains("visible-public"))
        logger.info("visible-public \(chosen)", category: "Synthetic362")
        let logFile = try #require(logger.logFileURL())
        for text in [logger.recentLogsText(), String(decoding: try Data(contentsOf: logFile), as: UTF8.self)] {
            #expect(!text.contains(chosen) && text.contains("visible-public"))
        }
    }
}
