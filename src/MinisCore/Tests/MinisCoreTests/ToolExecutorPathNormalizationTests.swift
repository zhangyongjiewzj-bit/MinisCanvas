import Foundation
import Testing
@testable import MinisCore

// D-PRIVACY-01 / D-PRIVACY-02（P3-PRIVACY-01 族，QODER-DEV-PRIVACY-FSROOT-016）：
// 文件工具（file_read/file_write/file_edit）的路径校验必须与
// PolicyRuntimePathBoundary 共用同一个规范化/解析 seam：
//   1. `.`/`..` 组件在任何文件系统访问前直接拒绝（不再先做词法 standardize，
//      消除词法 `..` 与物理 `..` 的语义分叉面）；
//   2. 符号链接解析覆盖「目标尚不存在的新文件写」——对最近的已存在祖先解析，
//      旧实现 resolvingSymlinksInPath 只在完整路径存在时做真实解析；
//   3. 拒绝表比较做大小写 + Unicode 规范化折叠（macOS 卷默认大小写/规范化
//      不敏感：`/Root/secret/new.txt` 与真实目录 `/Root/Secret` 指向同一目录，
//      精确前缀比较会让 deny 被大小写/normal-form 变体绕过）；
//   4. 允许侧比较保持精确（折叠只用于拒绝，绝不放宽 allow）。
struct ToolExecutorPathNormalizationTests {

    private struct Fixture {
        let base: URL
        let root: URL
        let deniedReal: URL
        let deniedKeyFile: URL
    }

    /// base/root = 允许根；base/root/Secret = 真实大小写的拒绝目录（内含 key.txt）。
    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ToolExecutorPathNormalizationTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let deniedReal = root.appendingPathComponent("Secret", isDirectory: true)
        try fm.createDirectory(at: deniedReal, withIntermediateDirectories: true)
        let deniedKeyFile = deniedReal.appendingPathComponent("key.txt")
        try "top-secret".data(using: .utf8)!.write(to: deniedKeyFile)
        return Fixture(base: base, root: root, deniedReal: deniedReal, deniedKeyFile: deniedKeyFile)
    }

    private func executor(for fixture: Fixture) -> BuiltinToolExecutor {
        BuiltinToolExecutor(allowedRoot: fixture.root, deniedRoots: [fixture.deniedReal])
    }

    /// 核心负例：deny 目录内「尚不存在的写目标」用不同大小写的路径变体写入。
    /// 旧实现只在完整路径存在时解析真实名字，缺失叶子路径保持小写原文，
    /// 精确前缀比较漏过拒绝表 → 写入真的落进 Secret/（D-PRIVACY-02 fail-open）。
    @Test func writeIntoDeniedDirViaCaseVariantMissingLeafIsRejected() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let lowercaseTarget = fixture.root
            .appendingPathComponent("secret/leak.json")
            .path

        await #expect(throws: ToolExecutorError.pathViolation(lowercaseTarget)) {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": lowercaseTarget, "content": "exfil"]
            )
        }
        // 失败必须无副作用：真实拒绝目录里不得出现 leak.json。
        #expect(!FileManager.default.fileExists(
            atPath: fixture.deniedReal.appendingPathComponent("leak.json").path
        ))
    }

    /// 核心负例：Unicode 规范化变体（NFD 请求 vs NFC 书写的真实目录名）。
    @Test func writeIntoDeniedDirViaUnicodeNormalFormVariantIsRejected() async throws {
        let fixture = try makeFixture()
        _ = executor(for: fixture)
        let nfcDenied = fixture.root.appendingPathComponent("Üsers", isDirectory: true)
        try FileManager.default.createDirectory(at: nfcDenied, withIntermediateDirectories: true)
        let executorWithUnicodeDeny = BuiltinToolExecutor(
            allowedRoot: fixture.root,
            deniedRoots: [fixture.deniedReal, nfcDenied]
        )
        let decomposedTarget = fixture.root
            .appendingPathComponent("\u{0055}\u{0308}sers/leak.json")
            .path

        await #expect(throws: ToolExecutorError.pathViolation(decomposedTarget)) {
            _ = try await executorWithUnicodeDeny.execute(
                name: "file_write",
                input: ["path": decomposedTarget, "content": "exfil"]
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: nfcDenied.appendingPathComponent("leak.json").path
        ))
    }

    /// 负例：`..` 组件即使在允许根内也被直接拒绝（与 PolicyRuntime 边界一致，
    /// 不再依赖「先词法 standardize 再校验」的顺序）。
    @Test func traversalComponentsRejectedEvenInsideAllowedRoot() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let note = fixture.root.appendingPathComponent("note.txt")
        try "plain".data(using: .utf8)!.write(to: note)
        let traversing = fixture.root
            .appendingPathComponent("sub/../note.txt")
            .path

        await #expect(throws: ToolExecutorError.pathViolation(traversing)) {
            _ = try await subject.execute(name: "file_read", input: ["path": traversing])
        }
    }

    /// 负例：符号链接逃逸到允许根之外（回归守卫）。
    @Test func symlinkEscapeOutsideRootIsRejected() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let fm = FileManager.default
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let treasure = outside.appendingPathComponent("treasure.txt")
        try "loot".data(using: .utf8)!.write(to: treasure)
        try fm.createSymbolicLink(
            at: fixture.root.appendingPathComponent("portal"),
            withDestinationURL: outside
        )
        let viaLink = fixture.root.appendingPathComponent("portal/treasure.txt").path

        await #expect(throws: ToolExecutorError.pathViolation(viaLink)) {
            _ = try await subject.execute(name: "file_read", input: ["path": viaLink])
        }
    }

    /// 负例：符号链接指向允许根内的拒绝目录。
    @Test func symlinkPointingIntoDeniedDirIsRejected() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("window"),
            withDestinationURL: fixture.deniedReal
        )
        let viaLink = fixture.root.appendingPathComponent("window/key.txt").path

        await #expect(throws: ToolExecutorError.pathViolation(viaLink)) {
            _ = try await subject.execute(name: "file_read", input: ["path": viaLink])
        }
    }

    /// 负例：通过符号链接父目录写「尚不存在」的新文件，必须被拒且无副作用。
    @Test func writeThroughSymlinkedParentOutsideRootIsRejectedWithoutEffect() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let fm = FileManager.default
        let outside = fixture.base.appendingPathComponent("outside-write", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: fixture.root.appendingPathComponent("dirlink"),
            withDestinationURL: outside
        )
        let viaLink = fixture.root.appendingPathComponent("dirlink/new-note.txt").path

        await #expect(throws: ToolExecutorError.pathViolation(viaLink)) {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": viaLink, "content": "escaped"]
            )
        }
        #expect(!fm.fileExists(atPath: outside.appendingPathComponent("new-note.txt").path))
    }

    /// 负例：挂载（additionalAllowedRoots）目录内的拒绝子目录同样被大小写
    /// 变体写路径拦截（deny 覆盖 allow+mount 双层）。
    @Test func mountedRootDeniedSubdirRejectsCaseVariantWrite() async throws {
        let fixture = try makeFixture()
        let fm = FileManager.default
        let mounted = fixture.base.appendingPathComponent("mounted", isDirectory: true)
        let mountedDenied = mounted.appendingPathComponent("Private", isDirectory: true)
        try fm.createDirectory(at: mountedDenied, withIntermediateDirectories: true)
        let subject = BuiltinToolExecutor(
            allowedRoot: fixture.root,
            deniedRoots: [fixture.deniedReal, mountedDenied],
            additionalAllowedRoots: [mounted]
        )
        let variantTarget = mounted
            .appendingPathComponent("private/plist.json")
            .path

        await #expect(throws: ToolExecutorError.pathViolation(variantTarget)) {
            _ = try await subject.execute(
                name: "file_write",
                input: ["path": variantTarget, "content": "x"]
            )
        }
        #expect(!fm.fileExists(atPath: mountedDenied.appendingPathComponent("plist.json").path))
    }

    /// 正例：允许根内的精确路径读写不受影响（折叠不得削弱合法访问）。
    @Test func exactCaseInsideRootStillReadsAndWrites() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let note = fixture.root.appendingPathComponent("notes/draft.md")

        _ = try await subject.execute(
            name: "file_write",
            input: ["path": note.path, "content": "hello", "create_dirs": true]
        )
        let out = try await subject.execute(name: "file_read", input: ["path": note.path])
        #expect(out.contains("hello"))
    }

    /// 正例：允许根内非 ASCII/带大小写的真实文件名照常可读，
    /// 且规范化变体输入也命中同一文件（volume 语义），allow 不被折叠误伤。
    @Test func unicodeFileNamesInsideRootRemainReadable() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let file = fixture.root.appendingPathComponent("Ünïcødé draft.txt")
        try "café".data(using: .utf8)!.write(to: file)

        let viaExact = try await subject.execute(
            name: "file_read",
            input: ["path": file.path]
        )
        #expect(viaExact.contains("café"))
    }

    /// 负例（PRIVACY-05 第三子句）：允许根内、因权限而无法读取的路径必须返回
    /// 显式的 `ToolExecutorError.permissionDenied` 结构化决定，而不是把
    /// Foundation/POSIX 原始错误串透出工具边界。
    @Test func fileReadOnPermissionDeniedPathIsExplicitlyDenied() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let fm = FileManager.default
        let guarded = fixture.root.appendingPathComponent("locked.txt")
        try "do-not-read".data(using: .utf8)!.write(to: guarded)
        // 无论断言结果如何都恢复权限，保证临时目录可清理。
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.path) }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: guarded.path)

        // 前置判别：本机必须真的拒绝该读取（非 root、卷尊重 mode 位）。
        // 若不成立则显式失败，而不是让下面的断言假通过。
        let rawReadRejected: Bool
        do {
            _ = try Data(contentsOf: guarded)
            rawReadRejected = false
        } catch {
            rawReadRejected = true
        }
        try #require(
            rawReadRejected,
            "test precondition not met: \(guarded.path) with mode 000 stayed readable (running as root, or a volume that ignores POSIX mode bits), so no real EACCES can be produced here"
        )

        await #expect(throws: ToolExecutorError.permissionDenied(guarded.path)) {
            _ = try await subject.execute(name: "file_read", input: ["path": guarded.path])
        }
    }

    /// 负例（PRIVACY-05 第三子句）：file_edit 的读取 seam 同样不得透出原始
    /// 权限错误，且拒绝必须无副作用（原内容保持不变）。
    @Test func fileEditOnPermissionDeniedPathIsExplicitlyDeniedWithoutEffect() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let fm = FileManager.default
        let guarded = fixture.root.appendingPathComponent("locked-edit.txt")
        try "do-not-read".data(using: .utf8)!.write(to: guarded)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.path) }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: guarded.path)

        let rawReadRejected: Bool
        do {
            _ = try Data(contentsOf: guarded)
            rawReadRejected = false
        } catch {
            rawReadRejected = true
        }
        try #require(
            rawReadRejected,
            "test precondition not met: \(guarded.path) with mode 000 stayed readable (running as root, or a volume that ignores POSIX mode bits), so no real EACCES can be produced here"
        )

        await #expect(throws: ToolExecutorError.permissionDenied(guarded.path)) {
            _ = try await subject.execute(
                name: "file_edit",
                input: ["path": guarded.path, "old_string": "do-not-read", "new_string": "x"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.path)
        let unchanged = try Data(contentsOf: guarded)
        #expect(String(data: unchanged, encoding: .utf8) == "do-not-read")
    }

    /// 反弱化守卫（PRIVACY-05）：非权限类读取失败不得被新的 permissionDenied
    /// 决定吞掉——非法 UTF-8 文本仍必须精确返回既有 `readFailed`。
    @Test func nonUTF8ReadStillReturnsReadFailedNotPermissionDenied() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let malformed = fixture.root.appendingPathComponent("not-utf8.txt")
        // 无 NUL 字节，避开 fileIsBinary；也不是合法 UTF-8；不以 UTF-16 BOM（FF FE / FE FF）开头。
        try Data([0xFF, 0xFF, 0x41]).write(to: malformed)

        await #expect(
            throws: ToolExecutorError.readFailed("File is not valid UTF-8 text: \(malformed.path)")
        ) {
            _ = try await subject.execute(name: "file_read", input: ["path": malformed.path])
        }
    }

    /// MC4-021：超过 8 MiB 的带 BOM UTF-16 文本（纯中文、没有 NUL 字节）按文本分页读取，
    /// 头读、尾读都不是乱码也不报二进制。
    @Test func largeBOMUTF16TextReadsAsTextHeadAndTail() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        var text = ""
        var count = 0
        var utf16Units = 0
        while utf16Units * 2 < 8 * 1024 * 1024 + 4096 {
            count += 1
            let line = "第\(count)行：你好世界\n"
            text += line
            utf16Units += line.utf16.count
        }
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let file = fixture.root.appendingPathComponent("big-utf16.txt")
        try data.write(to: file)

        let head = try await subject.execute(name: "file_read", input: ["path": file.path, "lines": 3])
        #expect(head.contains("第1行：你好世界") && head.contains("第3行：你好世界"))
        #expect(!head.contains("第4行："))
        let tail = try await subject.execute(
            name: "file_read", input: ["path": file.path, "direction": "tail", "lines": 2])
        #expect(tail.contains("第\(count)行：你好世界"))
        let middle = try await subject.execute(
            name: "file_read", input: ["path": file.path, "offset": 100_000, "lines": 2])
        #expect(middle.contains("第100000行：你好世界"))
    }

    /// MC4-021 剩余：无 BOM、几乎没有 NUL 的纯中文 UTF-16 大文件，过去按 UTF-8 解成乱码或报非 UTF-8。回退后头读会抛错。
    @Test func largeBOMlessChineseUTF16LittleEndianReadsAsText() async throws {
        let fixture = try makeFixture()
        let subject = executor(for: fixture)
        let line = "你好世界今天天气很好我们一起去看海\n"
        let text = String(repeating: line, count: 8 * 1024 * 1024 / (line.utf16.count * 2) + 4096)
        let file = fixture.root.appendingPathComponent("big-utf16-nobom.txt")
        try text.data(using: .utf16LittleEndian)!.write(to: file)
        #expect(BuiltinToolExecutor.largeFileUTF16Layout(head: Data(try Data(contentsOf: file).prefix(8192)))
            == BuiltinToolExecutor.LargeFileUTF16Layout(bigEndian: false, bomLength: 0))

        let head = try await subject.execute(name: "file_read", input: ["path": file.path, "lines": 2])
        #expect(head.contains("你好世界今天天气很好我们一起去看海"))
        let tail = try await subject.execute(
            name: "file_read", input: ["path": file.path, "direction": "tail", "lines": 2])
        #expect(tail.contains("你好世界今天天气很好我们一起去看海"))
    }

    @Test func utf16BlockConversionKeepsSurrogatePairsAcrossBlocks() throws {
        let bytes = "a😀b".data(using: .utf16LittleEndian)!   // 61 00 3D D8 00 DE 62 00
        var carry = Data()
        let first = try #require(BuiltinToolExecutor.utf16BlockToUTF8(Data(bytes.prefix(3)), bigEndian: false, carry: &carry))
        #expect(String(decoding: first, as: UTF8.self) == "a")
        let second = try #require(BuiltinToolExecutor.utf16BlockToUTF8(Data(bytes.dropFirst(3)), bigEndian: false, carry: &carry))
        #expect(String(decoding: second, as: UTF8.self) == "😀b")
        #expect(carry.isEmpty)
    }
}
