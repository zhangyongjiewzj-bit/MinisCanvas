import Foundation
import Testing
@testable import MinisCore

// D-PRIVACY-05 / delta 167V-D1（lane QODER-DEV-W13-169）：file_write 的写 seam
// （ToolExecutor.swift runFileWrite 的 catch-all）此前把文件系统权限拒绝与一般
// I/O 失败一起压平成未分型的 `writeFailed` 原始字符串。本套件固定修复后的三分
// 支边界：
//   1. 目录不可写（原子写临时文件 EACCES）→ 复用既有 typed case
//      `permissionDenied`，不再是 writeFailed 字符串；
//   2. append 分支打开不可写文件（FileHandle EACCES）→ 同样 typed 拒绝；
//   3. 反弱化守卫：非权限类 I/O 失败（目录不存在 ENOENT）仍必须精确落在既有
//      `writeFailed`，不得被新的分型吞掉。
struct ToolExecutorWritePermissionTests {

    private struct Fixture {
        let base: URL
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorWritePermissionTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(base: base, root: root)
    }

    private func executor(for fixture: Fixture) -> BuiltinToolExecutor {
        BuiltinToolExecutor(allowedRoot: fixture.root)
    }

    /// 本机必须真的拒绝该写入（非 root、卷尊重 mode 位）。不成立时显式失败，
    /// 而不是让下面的断言假通过 —— 与 ToolExecutorPathNormalizationTests 的
    /// 读侧前置判别同一手法，方向换成写。
    private func requireRawWriteRejected(_ attempt: () throws -> Void, path: String) throws {
        let rejected: Bool
        do {
            try attempt()
            rejected = false
        } catch {
            rejected = true
        }
        try #require(
            rejected,
            "test precondition not met: writing \(path) stayed permitted at the raw Foundation layer (running as root, or a volume that ignores POSIX mode bits), so no real EACCES can be produced here"
        )
    }

    /// 正例（167V-D1 主支）：向允许根内 mode 555 的目录做非原子替换写入时，
    /// Foundation 抛出 fileWriteNoPermission/EACCES 类拒绝 —— 必须浮现为既有
    /// typed case `permissionDenied(path)`，而不是未分型的 writeFailed 字符串。
    @Test func fileWriteIntoUnwritableDirectoryIsTypedPermissionDenied() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let fm = FileManager.default
        let subject = executor(for: fixture)
        let lockedDir = fixture.root.appendingPathComponent("locked-dir", isDirectory: true)
        try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        let target = lockedDir.appendingPathComponent("payload.txt")

        try requireRawWriteRejected(
            { try "exfil".write(to: target, atomically: true, encoding: .utf8) },
            path: target.path
        )

        await #expect(throws: ToolExecutorError.permissionDenied(target.path)) {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": target.path, "content": "exfil"]
            )
        }
        // 失败必须无副作用：目标不得被创建。
        #expect(!fm.fileExists(atPath: target.path))
    }

    /// 正例（167V-D1 append 支）：append=true 打开 mode 000 的已存在文件时，
    /// `FileHandle(forWritingTo:)` 的权限拒绝同样必须走 typed case。
    @Test func fileWriteAppendToPermissionDeniedFileIsTypedPermissionDenied() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let fm = FileManager.default
        let subject = executor(for: fixture)
        let guarded = fixture.root.appendingPathComponent("locked-append.txt")
        try "original".data(using: .utf8)!.write(to: guarded)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.path) }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: guarded.path)

        try requireRawWriteRejected(
            {
                let handle = try FileHandle(forWritingTo: guarded)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data("+tail".utf8))
            },
            path: guarded.path
        )

        await #expect(throws: ToolExecutorError.permissionDenied(guarded.path)) {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": guarded.path, "content": "+tail", "append": true]
            )
        }
        // 失败必须无副作用：恢复权限后原内容保持不变。
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.path)
        let unchanged = try Data(contentsOf: guarded)
        #expect(String(data: unchanged, encoding: .utf8) == "original")
    }

    /// 反弱化守卫（无行为塌缩）：非权限类写失败（父目录不存在，ENOENT 族）
    /// 仍必须精确返回既有 `writeFailed`，不得被新的 permissionDenied 分型吞掉。
    @Test func nonPermissionWriteFailureStillReturnsWriteFailed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let subject = executor(for: fixture)
        let missingDirTarget = fixture.root
            .appendingPathComponent("no-such-dir/payload.txt")
            .path

        // 前置判别：raw 层这一步必须真的失败（否则 writeFailed 断言无意义），
        // 且失败原因不是权限类。
        let rawError: NSError
        do {
            try "x".write(to: URL(fileURLWithPath: missingDirTarget), atomically: true, encoding: .utf8)
            Issue.record("test precondition not met: raw write into \(missingDirTarget) unexpectedly succeeded")
            return
        } catch let error as NSError {
            rawError = error
        }
        let rawIsPermissionShaped =
            (rawError.domain == NSPOSIXErrorDomain && (rawError.code == Int(EACCES) || rawError.code == Int(EPERM)))
            || (rawError.domain == NSCocoaErrorDomain
                && (rawError.code == CocoaError.Code.fileWriteNoPermission.rawValue
                      || rawError.code == CocoaError.Code.fileReadNoPermission.rawValue))
        try #require(
            !rawIsPermissionShaped,
            "test precondition not met: raw failure for \(missingDirTarget) is permission-shaped (\(rawError.domain) \(rawError.code)), so it cannot pin the writeFailed branch"
        )

        do {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": missingDirTarget, "content": "x"]
            )
            Issue.record("expected ToolExecutorError.writeFailed for a non-permission I/O failure")
        } catch let error as ToolExecutorError {
            guard case .writeFailed(let detail) = error else {
                Issue.record("expected .writeFailed, got \(error)")
                return
            }
            // 既有字符串形状保持：路径仍可见，未塌缩成通用失败。
            #expect(detail.contains(missingDirTarget))
        }
    }
}
