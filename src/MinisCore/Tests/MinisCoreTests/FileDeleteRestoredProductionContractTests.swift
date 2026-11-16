import Foundation
import CryptoKit
import Darwin
import Testing
@testable import MinisCore

@Suite("OUTPUT02 restored physical deletion contract", .serialized)
struct FileDeleteRestoredProductionContractTests {
    @Test(arguments: [false, true])
    func successfulDeletePreservesOldDigestAndBoundedDiff(longText: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("output02-restored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: root)
            var status = stat()
            #expect(Darwin.lstat(root.path, &status) == -1 && errno == ENOENT)
        }
        let file = root.appendingPathComponent("synthetic.txt")
        let content = String(repeating: "controlled output02 line\n", count: longText ? 500 : 2)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let ledger = FileChangeLedger(workspaceRoot: root.path)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        executor.fileChangeLedger = ledger
        executor.fileChangeSessionID = "output02-restored-session"
        try #require(AgentToolCatalog.makeTools().contains { $0.name == "file_delete" })
        let output = try await executor.execute(name: "file_delete", input: ["path": file.path])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let record = try #require(ledger.records(sessionID: "output02-restored-session").first)
        #expect(ledger.count == 1)
        #expect(record.kind.rawValue == "deleted")
        #expect(output.contains(record.diffID))
        #expect(record.outputSHA256 == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let expected = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(encoded["deletedContentSHA256"] as? String == expected)
        let diff = try #require(ledger.diffPayload(diffID: record.diffID, sessionID: "output02-restored-session"))
        #expect(diff.path == file.lastPathComponent)
        #expect(diff.unifiedDiff.contains("controlled output02 line"))
        #expect(diff.insertions == 0)
        #expect(diff.deletions == (longText ? 501 : 3))
        #expect(diff.unifiedDiff.count <= 6_030)
        if longText { #expect(diff.unifiedDiff.contains("diff truncated")) }
        #expect(ledger.record(diffID: record.diffID, sessionID: "foreign-session") == nil)
    }
}
