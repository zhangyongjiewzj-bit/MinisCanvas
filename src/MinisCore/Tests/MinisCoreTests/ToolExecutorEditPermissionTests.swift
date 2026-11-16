import Foundation
import Testing
@testable import MinisCore

// D-PRIVACY-05 / lane QODER-DEV-W13-TOOLEXEC-FLAT-172：runFileEdit 的写 seam
// （ToolExecutor.swift runFileEdit 的 catch-all，基线 d3fd00008 的 929-933）此前
// 把文件系统权限拒绝与一般 I/O 失败一起压平成未分型的 `writeFailed` 原始字符串
// —— 即 lane 169 回执中登记的 "residual_analog_outside_enumerated_delta"。
// 169（delta 167V-D1）只枚举并修复了 file_write 写 seam；本套件固定 file_edit
// 写 seam 修复后的边界：
//   1. 目录不可写（原子写临时文件 EACCES）→ 复用既有 typed case
//      `permissionDenied`，不再是 writeFailed 字符串，且失败无副作用；
//   2. 反弱化守卫：pre-write 校验失败（old_string 未命中）仍精确落在既有
//      `editFailed`，不得被新的分型抢先吞掉；
//   3. 成功路径的压平结果形状（单行 "Edited … replaced N occurrence(s) …"）
//      保持不变（169V-D1 为严格增强，不重定义成功形状）。
// 风格与前置判别镜像 ToolExecutorWritePermissionTests.swift（lane 169）与
// ToolExecutorPathNormalizationTests.swift:217-281 的读侧手法。
struct ToolExecutorEditPermissionTests {

    private struct Fixture {
        let base: URL
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorEditPermissionTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(base: base, root: root)
    }

    private func executor(for fixture: Fixture) -> BuiltinToolExecutor {
        BuiltinToolExecutor(allowedRoot: fixture.root)
    }

    /// 本机必须真的拒绝该目录内的原子写入（非 root、卷尊重 mode 位）。不成立
    /// 时显式失败，而不是让下面的断言假通过。
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

    /// 正例（file_edit 写 seam）：允许根内、位于 mode 555 目录的可读文件被编辑
    /// 时，`text.write(to:atomically:)` 的临时文件创建抛出 fileWriteNoPermission/
    /// EACCES 类拒绝 —— 必须浮现为既有 typed case `permissionDenied(path)`，
    /// 而不是未分型的 writeFailed 字符串；且失败无副作用（原内容不变）。
    @Test func fileEditIntoUnwritableDirectoryIsTypedPermissionDenied() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let fm = FileManager.default
        let subject = executor(for: fixture)
        let lockedDir = fixture.root.appendingPathComponent("locked-dir", isDirectory: true)
        try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let target = lockedDir.appendingPathComponent("payload.txt")
        try "alpha beta".data(using: .utf8)!.write(to: target)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)

        try requireRawWriteRejected(
            { try "probe".write(to: lockedDir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8) },
            path: lockedDir.path
        )

        await #expect(throws: ToolExecutorError.permissionDenied(target.path)) {
            _ = try await subject.execute(
                name: "file_edit",
                input: ["path": target.path, "old_string": "alpha", "new_string": "omega"]
            )
        }
        // 失败必须无副作用：恢复目录权限后原内容保持不变，且探针文件未残留。
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        let unchanged = try Data(contentsOf: target)
        #expect(String(data: unchanged, encoding: .utf8) == "alpha beta")
        #expect(!fm.fileExists(atPath: lockedDir.appendingPathComponent("probe.txt").path))
    }

    /// 反弱化守卫（无行为塌缩）：pre-write 校验失败（old_string 未命中）在不可
    /// 写目录内也必须仍精确落在既有 `editFailed("old_string not found in …")`，
    /// 证明新的权限分型只作用于真实写拒绝，没有抢先改变既有错误顺序。
    @Test func fileEditValidationFailureInUnwritableDirectoryStillThrowsEditFailedNotPermissionDenied() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let fm = FileManager.default
        let subject = executor(for: fixture)
        let lockedDir = fixture.root.appendingPathComponent("locked-dir2", isDirectory: true)
        try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        let target = lockedDir.appendingPathComponent("note.txt")
        try "hello".data(using: .utf8)!.write(to: target)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)

        do {
            _ = try await subject.execute(
                name: "file_edit",
                input: ["path": target.path, "old_string": "missing-token", "new_string": "x"]
            )
            Issue.record("expected ToolExecutorError.editFailed for an old_string miss")
        } catch let error as ToolExecutorError {
            guard case .editFailed(let detail) = error else {
                Issue.record("expected .editFailed, got \(error)")
                return
            }
            #expect(detail == "old_string not found in \(target.path)")
        }
    }

    /// 反弱化守卫（成功形状不变）：可写根内的正常编辑仍返回单行压平结果
    /// "Edited <path>: replaced 1 occurrence(s) (<n> bytes written)." 且文件
    /// 内容真实替换 —— 修复只收紧拒绝分型，不重定义成功形状。
    @Test func fileEditSuccessResultShapeIsUnchanged() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let subject = executor(for: fixture)
        let changes = FileChangeLedger(workspaceRoot: fixture.root.path)
        subject.fileChangeLedger = changes
        subject.fileChangeSessionID = "edit-shape-session"
        let target = fixture.root.appendingPathComponent("ok.txt")
        try "alpha beta".data(using: .utf8)!.write(to: target)

        let out = try await subject.execute(
            name: "file_edit",
            input: ["path": target.path, "old_string": "alpha", "new_string": "omega"]
        )
        #expect(changes.records(sessionID: "edit-shape-session").count == 1)
        let record = try #require(changes.records(sessionID: "edit-shape-session").first)
        #expect(out == "Edited \(target.path): replaced 1 occurrence(s) (\("omega".utf8.count) bytes written). [diffID:\(record.diffID)]")
        let content = try Data(contentsOf: target)
        #expect(String(data: content, encoding: .utf8) == "omega beta")
    }

    @Test func fileEditWithoutLedgerWarnsButStillWrites() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let subject = executor(for: fixture)
        let target = fixture.root.appendingPathComponent("warning.txt")
        try Data("alpha beta".utf8).write(to: target)

        let out = try await subject.execute(
            name: "file_edit",
            input: ["path": target.path, "old_string": "alpha", "new_string": "omega"]
        )
        #expect(out == "Edited \(target.path): replaced 1 occurrence(s) (5 bytes written). 文件已写入，但文件变更台账不可用。")
        #expect(try String(contentsOf: target, encoding: .utf8) == "omega beta")
    }
}
