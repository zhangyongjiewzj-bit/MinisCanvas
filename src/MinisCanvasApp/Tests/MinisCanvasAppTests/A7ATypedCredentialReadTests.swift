import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class A7AKeychainReadModeBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    enum Mode: Sendable {
        case missing
        case denied
        case failed
    }

    private let lock = NSLock()
    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func set(_ value: String, forKey key: String) -> Bool { true }

    func get(_ key: String) -> String? { nil }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .missing: return .missing
        case .denied: return .denied
        case .failed: return .failed
        }
    }

    func delete(_ key: String) -> Bool { true }
}

private final class A7ACountingKeychainBacking: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private let readMode: KeychainReadResult?
    private var readCounts: [String: Int] = [:]

    init(values: [String: String] = [:], readMode: KeychainReadResult? = nil) {
        self.values = values
        self.readMode = readMode
    }

    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        return true
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        readCounts[key, default: 0] += 1
        return values[key]
    }

    func readResult(forKey key: String) -> KeychainReadResult {
        lock.lock(); defer { lock.unlock() }
        readCounts[key, default: 0] += 1
        if let readMode {
            switch readMode {
            case .found:
                return values[key].map(KeychainReadResult.found) ?? readMode
            default:
                return readMode
            }
        }
        return values[key].map(KeychainReadResult.found) ?? .missing
    }

    func delete(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        return true
    }

    func readCount(forKey key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readCounts[key, default: 0]
    }
}

private func a7aTypedReadDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "MinisCanvas-A7A-" + label + "-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeA7AProviderMetadata(
    to directory: URL,
    name: String = "A7A_TYPED_READ_API_KEY"
) throws {
    let entry = EnvVarEntry(
        name: name,
        value: "",
        isSecret: true,
        valueInKeychain: true,
        baseURL: "https://example.invalid/v1",
        modelNames: ["fixture-model"]
    )
    let data = try JSONEncoder().encode([entry])
    try data.write(to: directory.appendingPathComponent(EnvVarStore.fileName), options: .atomic)
}

@MainActor
private func makeA7ASettingsCenter(directory: URL, backing: KeychainBacking) -> SettingsCenter {
    SettingsCenter(
        settingsStore: SettingsStore(directory: directory),
        envStore: EnvVarStore(directory: directory, keychain: KeychainStore(backing: backing)),
        memoryStore: MemoryStore(directory: directory),
        sessionStore: SessionStore(directory: directory),
        logManager: LogManager(directory: directory, ringCapacity: 10),
        mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json")),
        skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills"))
    )
}

@Suite("A7-A typed Settings credential-read seam")
struct A7ATypedCredentialReadTests {
    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    @Test("missing, denied, and failed Keychain reads stay typed and fail closed")
    @MainActor
    func typedProviderReadPreservesFailureCategory() async throws {
        let cases: [(A7AKeychainReadModeBacking.Mode, SettingsCenter.ProviderCredentialReadFailure)] = [
            (.missing, .missing),
            (.denied, .denied),
            (.failed, .failed),
        ]

        for (mode, expected) in cases {
            let directory = try a7aTypedReadDirectory(String(describing: mode))
            defer { try? FileManager.default.removeItem(at: directory) }
            try writeA7AProviderMetadata(to: directory)
            let center = makeA7ASettingsCenter(
                directory: directory,
                backing: A7AKeychainReadModeBacking(mode: mode)
            )

            let outcome = await center.providerCredentialReadAsync(named: "A7A_TYPED_READ_API_KEY")
            #expect(outcome == .failure(expected))
            #expect(center.providerCredential(named: "A7A_TYPED_READ_API_KEY") == nil)
        }
    }

    @Test("typed failure messages are user-visible but contain no credential payload")
    func typedFailureMessagesAreSecretSafe() {
        let failures: [SettingsCenter.ProviderCredentialReadFailure] = [.missing, .denied, .failed]

        for failure in failures {
            let message = failure.message
            #expect(!message.isEmpty)
            #expect(message.contains("API Key"))
            #expect(message.contains("钥匙串"))
            #expect(!message.contains("localizedDescription"))
            #expect(!message.contains("sk-"))
        }
    }

    @Test("explicit replacement never reads a denied old credential and migrates")
    @MainActor
    func explicitReplacementDoesNotReadDeniedOldCredential() throws {
        let directory = try a7aTypedReadDirectory("explicit-replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldName = "A7A_EXPLICIT_OLD_PROVIDER"
        let newName = "A7A_EXPLICIT_NEW_PROVIDER"
        try writeA7AProviderMetadata(to: directory, name: oldName)
        let backing = A7ACountingKeychainBacking(readMode: .denied)
        let center = makeA7ASettingsCenter(directory: directory, backing: backing)

        let preview = try center.previewProviderRename(from: oldName, to: newName)
        let receipt = try center.renameProvider(
            from: oldName,
            to: newName,
            apiKey: "sk-explicit-replacement",
            baseURL: "https://example.invalid/v2",
            modelNames: ["replacement-model"],
            protocolType: .openaiCompatible,
            intent: confirmed(preview)
        )

        #expect(receipt.outcome == "deleted")
        #expect(backing.readCount(forKey: oldName) == 0)
        #expect(center.providerRecords.map(\.name) == [newName])
    }

    @Test("blank retention reads once and executes the metadata fingerprint")
    @MainActor
    func blankRetentionReadsOnceAndKeepsFingerprint() async throws {
        let directory = try a7aTypedReadDirectory("blank-retention")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldName = "A7A_BLANK_OLD_PROVIDER"
        let newName = "A7A_BLANK_NEW_PROVIDER"
        try writeA7AProviderMetadata(to: directory, name: oldName)
        let backing = A7ACountingKeychainBacking(
            values: [oldName: "sk-retained-credential"]
        )
        let center = makeA7ASettingsCenter(directory: directory, backing: backing)

        let preview = try center.previewProviderRename(from: oldName, to: newName)
        let receipt = try await center.renameProviderAsync(
            from: oldName,
            to: newName,
            apiKey: "",
            baseURL: "https://example.invalid/v2",
            modelNames: ["retained-model"],
            protocolType: .openaiCompatible,
            intent: confirmed(preview)
        )

        #expect(receipt.outcome == "deleted")
        #expect(backing.readCount(forKey: oldName) == 1)
        #expect(center.providerRecords.map(\.name) == [newName])
    }

    @Test("blank retention keeps denied and missing reads typed and creates no provider")
    @MainActor
    func blankRetentionFailureDoesNotCreateProvider() async throws {
        let cases: [(String, KeychainReadResult, String)] = [
            ("denied", .denied, "钥匙串拒绝读取旧 API Key；请检查钥匙串权限，或直接输入新 Key 替换"),
            ("missing", .missing, "旧 API Key 不在钥匙串中；请返回并直接输入新 Key 后重试"),
        ]

        for (label, mode, message) in cases {
            let directory = try a7aTypedReadDirectory("blank-retention-" + label)
            defer { try? FileManager.default.removeItem(at: directory) }
            let oldName = "A7A_BLANK_" + label.uppercased() + "_OLD_PROVIDER"
            let newName = "A7A_BLANK_" + label.uppercased() + "_NEW_PROVIDER"
            try writeA7AProviderMetadata(to: directory, name: oldName)
            let backing = A7ACountingKeychainBacking(readMode: mode)
            let center = makeA7ASettingsCenter(directory: directory, backing: backing)
            let preview = try center.previewProviderRename(from: oldName, to: newName)

            await #expect(throws: SettingsDeletionError.operationFailed(message)) {
                _ = try await center.renameProviderAsync(
                    from: oldName,
                    to: newName,
                    apiKey: "",
                    baseURL: "https://example.invalid/v2",
                    modelNames: ["blocked-model"],
                    protocolType: .openaiCompatible,
                    intent: confirmed(preview)
                )
            }
            #expect(backing.readCount(forKey: oldName) == 1)
            #expect(center.providerRecords.map(\.name) == [oldName])
            #expect(!center.providerRecords.contains { $0.name == newName })
        }
    }
}
