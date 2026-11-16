import Foundation
import Testing
@testable import MinisCore

private func makeRecoveryConsumerDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-RecoveryConsumer-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private final class RecoveryConsumerKeychainBacking: KeychainBacking, @unchecked Sendable {
    func set(_ value: String, forKey key: String) -> Bool { true }
    func get(_ key: String) -> String? { nil }
    func delete(_ key: String) -> Bool { true }
}

private struct CleanupFailingRecoveryFileSystem: CredentialMetadataRecoveryFileSystem {
    let children: [URL]

    func contentsOfDirectory(at directory: URL) throws -> [URL] {
        children
    }

    func removeItem(at url: URL) throws {
        throw NSError(domain: "EnvVarStoreRecoveryConsumerTests", code: 1)
    }
}

private func writeFormalRecoveryMetadata(to directory: URL) throws -> URL {
    let metadataURL = directory.appendingPathComponent(EnvVarStore.fileName)
    let entry = EnvVarEntry(name: "STABLE_VALUE", value: "formal-metadata")
    try JSONEncoder().encode([entry]).write(to: metadataURL)
    return metadataURL
}

struct EnvVarStoreRecoveryConsumerTests {
    @Test func initRecoversOrphansBeforeLoadingFormalMetadata() throws {
        let directory = try makeRecoveryConsumerDirectory("live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = try writeFormalRecoveryMetadata(to: directory)
        let metadataBefore = try Data(contentsOf: metadataURL)
        let orphanURL = directory.appendingPathComponent(".envvars.json.pending-interrupted")
        let fixtureSecret = "synthetic-recovery-secret"
        try Data(fixtureSecret.utf8).write(to: orphanURL)

        let store = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: RecoveryConsumerKeychainBacking())
        )

        #expect(store.entry(name: "STABLE_VALUE")?.value == "formal-metadata")
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(store.lastMetadataRecoveryFailure == nil)
        #expect(!String(describing: store.lastMetadataRecoveryFailure).contains(fixtureSecret))
    }

    @Test func cleanupFailureIsRecordedAndFormalMetadataStillLoads() throws {
        let directory = try makeRecoveryConsumerDirectory("failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeFormalRecoveryMetadata(to: directory)
        let orphanURL = directory.appendingPathComponent(".envvars.json.pending-failed")
        try Data("synthetic-recovery-secret".utf8).write(to: orphanURL)
        let fileSystem = CleanupFailingRecoveryFileSystem(children: [
            directory.appendingPathComponent(EnvVarStore.fileName),
            orphanURL
        ])

        let store = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: RecoveryConsumerKeychainBacking()),
            metadataRecoveryFileSystem: fileSystem
        )

        #expect(store.lastMetadataRecoveryFailure == .cleanupFailed)
        #expect(store.entry(name: "STABLE_VALUE")?.value == "formal-metadata")
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
    }
}
