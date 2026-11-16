import Foundation
import Testing
@testable import MinisCore

// 2026-11-15 第六版：下载与上传的路径核对按真实路径比较，
// /private/var/... 与系统软链 /var/... 视为同一位置；用户自建的符号链接仍拒绝。
@Suite("Browser transfer physical path")
struct BrowserTransferPhysicalPathTests {
    private func makeRoot() throws -> URL {
        // 固定用系统的 /private/tmp，保证路径带 /private 前缀（测试进程的 TMPDIR 可能在 /Users 下）。
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("transfer-physical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func privatePrefixedAndSystemAliasPathsAreAccepted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = URL(fileURLWithPath: String(cString: realpath(root.path, nil)), isDirectory: true)
        #expect(physical.path.hasPrefix("/private/"))
        let target = physical.appendingPathComponent("download.txt")
        #expect(BrowserTransferFileIdentity.isPhysicalPath(target))
        let alias = URL(fileURLWithPath: String(physical.path.dropFirst("/private".count)), isDirectory: true)
            .appendingPathComponent("download.txt")
        #expect(BrowserTransferFileIdentity.isPhysicalPath(alias))
        // A download target that does not exist yet passes the on-disk capture.
        let captured = try BrowserTransferFileIdentity.captureOnDisk(url: target, upload: false)
        #expect(captured.path == target.path)
    }

    @Test func userSymlinksInThePathOrAtTheLeafAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = URL(fileURLWithPath: String(cString: realpath(root.path, nil)), isDirectory: true)
        let real = physical.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linkedDirectory = physical.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: real)
        #expect(!BrowserTransferFileIdentity.isPhysicalPath(linkedDirectory.appendingPathComponent("out.txt")))

        let file = real.appendingPathComponent("source.txt")
        try Data("x".utf8).write(to: file)
        let leafLink = real.appendingPathComponent("leaf-link.txt")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: file)
        #expect(!BrowserTransferFileIdentity.isPhysicalPath(leafLink))
        #expect(BrowserTransferFileIdentity.isPhysicalPath(file))
    }

    @Test func onlyTheSystemAliasesAreNormalized() {
        #expect(BrowserTransferFileIdentity.systemAliasNormalized("/var/folders/x") == "/private/var/folders/x")
        #expect(BrowserTransferFileIdentity.systemAliasNormalized("/tmp/x") == "/private/tmp/x")
        #expect(BrowserTransferFileIdentity.systemAliasNormalized("/Users/a/x") == "/Users/a/x")
        #expect(BrowserTransferFileIdentity.systemAliasNormalized("/variable/x") == "/variable/x")
    }
}
