import Foundation
import Testing
@testable import MinisCore

private func makeCredentialRecoveryDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-CredentialRecovery-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct FailingCredentialRecoveryFileSystem: CredentialMetadataRecoveryFileSystem {
    let children: [URL]

    func contentsOfDirectory(at directory: URL) throws -> [URL] {
        children
    }

    func removeItem(at url: URL) throws {
        throw NSError(domain: "CredentialMetadataRecoveryTests", code: 1)
    }
}

struct CredentialMetadataRecoveryTests {
    @Test func formalMetadataWinsAndOrphanSecretIsNeverRead() throws {
        let directory = try makeCredentialRecoveryDirectory("formal-wins")
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("envvars.json")
        let metadata = Data("{\"formal\":true}".utf8)
        try metadata.write(to: metadataURL)
        let orphanURL = directory.appendingPathComponent(".envvars.json.pending-secret")
        let fixtureSecret = "synthetic-credential-never-read"
        try Data(fixtureSecret.utf8).write(to: orphanURL)
        let unrelatedURL = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelatedURL)

        let result = EnvVarStore.recoverCredentialMetadataAtStartup(in: directory)
        if case .success(let receipt) = result {
            #expect(receipt.formalMetadataPresent)
            #expect(receipt.orphanCount == 1)
            #expect(receipt.cleanedOrphanCount == 1)
            #expect(receipt.status == .removedOrphans)
        } else {
            #expect(Bool(false), "formal metadata recovery unexpectedly failed")
        }
        #expect(try Data(contentsOf: metadataURL) == metadata)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
        #expect(!String(describing: result).contains(fixtureSecret))
    }

    @Test func missingFormalMetadataNeverPromotesOrphan() throws {
        let directory = try makeCredentialRecoveryDirectory("no-promotion")
        defer { try? FileManager.default.removeItem(at: directory) }

        let orphanURL = directory.appendingPathComponent(".envvars.json.pending-interrupted")
        try Data("synthetic-secret".utf8).write(to: orphanURL)

        let result = EnvVarStore.recoverCredentialMetadataAtStartup(in: directory)
        if case .success(let receipt) = result {
            #expect(!receipt.formalMetadataPresent)
            #expect(receipt.orphanCount == 1)
            #expect(receipt.cleanedOrphanCount == 1)
            #expect(receipt.status == .removedOrphans)
        } else {
            #expect(Bool(false), "orphan cleanup unexpectedly failed")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("envvars.json").path))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func cleanupFailureIsTypedAndDoesNotCrashStartup() {
        let directory = URL(fileURLWithPath: "/synthetic/credential-recovery")
        let orphanURL = directory.appendingPathComponent(".envvars.json.pending-failure")
        let fileSystem = FailingCredentialRecoveryFileSystem(children: [
            directory.appendingPathComponent("envvars.json"),
            orphanURL
        ])

        let result = CredentialMetadataRecovery.recover(in: directory, fileSystem: fileSystem)
        #expect(result == .failure(.cleanupFailed))
        #expect(!String(describing: result).contains("pending-failure"))
    }

    @Test func invalidMetadataNameFailsClosedWithoutFilesystemAccess() {
        let fileSystem = FailingCredentialRecoveryFileSystem(children: [])
        let result = CredentialMetadataRecovery.recover(
            in: URL(fileURLWithPath: "/synthetic/credential-recovery"),
            metadataFileName: "../envvars.json",
            fileSystem: fileSystem
        )
        #expect(result == .failure(.invalidMetadataFileName))
    }
}
