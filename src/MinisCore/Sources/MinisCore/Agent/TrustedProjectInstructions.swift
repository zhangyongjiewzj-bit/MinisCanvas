import Foundation
import Darwin
import CryptoKit

/// Only a root already admitted by the product project trust boundary may be
/// passed here. Session metadata and model-supplied paths are not authority.
///
/// 对齐 Claude Code：从项目根向上逐级（到家目录或文件系统根为止）收集
/// AGENTS.md / CLAUDE.md / .claude/CLAUDE.md / CLAUDE.local.md，再加用户级
/// ~/.claude/CLAUDE.md，按“用户级 → 上层 → 项目根”顺序合并，每段注明来源路径。
public enum TrustedProjectInstructions {
    /// 单个指令文件的读取上限；超出部分截断并在提示里说明。
    public static let maxBytes = 64 * 1024
    /// 所有指令文件合计上限。
    public static let maxTotalBytes = 200 * 1024
    public static let maxImportDepth = 4

    /// 一次读取的结果：`snapshot` 为空表示没有任何指令文件被加载；
    /// `skipped` 记录“文件存在但没能加载”的原因（中文，含来源路径）。
    public struct LoadReport: Sendable {
        public let snapshot: TrustedProjectInstructionSnapshot?
        public let skipped: [String]

        /// 只有“有文件但一个都没加载”才算不可用；项目本来没有指令文件不提示。
        public var unavailableReason: String? {
            guard snapshot == nil, !skipped.isEmpty else { return nil }
            return "项目指令文件没能加载：" + skipped.joined(separator: "；") + "。请修正文件后重试。"
        }
    }

    public static func load(atTrustedRoot root: URL) throws -> String? {
        try loadSnapshot(atTrustedRoot: root)?.systemPromptPrefix
    }

    public static func loadSnapshot(atTrustedRoot root: URL) throws -> TrustedProjectInstructionSnapshot? {
        try loadReport(atTrustedRoot: root).snapshot
    }

    public static func loadReport(atTrustedRoot root: URL, userHome: URL? = nil) throws -> LoadReport {
        // The admitted caller supplies the physical spelling. Foundation may
        // standardize /private/var back to the system /var symlink; preserve
        // that spelling for the descriptor walk instead of reintroducing it.
        let path = root.relativePath
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard root.isFileURL, path.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return LoadReport(snapshot: nil, skipped: [])
        }
        let rootPath = "/" + components.joined(separator: "/")
        let rootFD = try openDirectory(components.map(String.init))
        guard rootFD >= 0 else { throw posixError() }
        defer { Darwin.close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else { throw posixError() }
        let rootIdentity = "\(rootInfo.st_dev):\(rootInfo.st_ino)"

        let environment = ProcessInfo.processInfo.environment
        // 家目录以进程环境的 HOME 为准（正式测试配置会把 HOME 指向隔离目录），没有再退回系统家目录。
        let defaultHome = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
        let homePath = physicalPath((userHome ?? URL(fileURLWithPath: defaultHome, isDirectory: true)).path)
        // 正式测试配置下，向上查找不越出测试根目录，避免读到开发机上的真实指令文件。
        let testBoundary: String? = environment["MINISCANVAS_TEST_PROFILE"] == "1"
            ? environment["MINISCANVAS_TEST_DIRECTORY"].flatMap { $0.hasPrefix("/") ? physicalPath($0) : nil }
            : nil
        let state = Collector(rootPath: rootPath, homePath: homePath)

        // 优先级：项目根 > 近处上层 > 远处上层 > 用户级（总量不够时先保近处）。
        let rootNames = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"]
        let rootGroup = try state.loadGroup(base: rootPath, baseFD: rootFD, names: rootNames)

        var ancestorDirs: [String] = []
        var parts = components.map(String.init)
        var reachedHome = rootPath == homePath
        if let testBoundary, !(rootPath == testBoundary || rootPath.hasPrefix(testBoundary + "/")) {
            reachedHome = true // 测试配置下项目根不在测试根内：不向上查找。
        }
        while !parts.isEmpty, !reachedHome {
            parts.removeLast()
            let dir = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
            if let testBoundary, !(dir == testBoundary || dir.hasPrefix(testBoundary + "/")) { break }
            ancestorDirs.append(dir)
            if dir == homePath { reachedHome = true }
        }
        var ancestorGroups: [(dir: String, group: Group)] = []
        for dir in ancestorDirs {
            // 家目录下的 .claude/CLAUDE.md 就是用户级文件，由下面的用户级单独读取，这里不重复读。
            let names = dir == homePath ? rootNames.filter { $0 != ".claude/CLAUDE.md" } : rootNames
            ancestorGroups.append((dir, (try? state.loadOptionalGroup(base: dir, names: names)) ?? Group()))
        }
        let userDir = homePath + "/.claude"
        let userGroup = (try? state.loadOptionalGroup(base: userDir, names: ["CLAUDE.md"])) ?? Group()

        var ordered: [Group] = [userGroup]
        ordered.append(contentsOf: ancestorGroups.reversed().map(\.group))
        ordered.append(rootGroup)
        let paths = ordered.flatMap(\.paths)
        guard !paths.isEmpty else { return LoadReport(snapshot: nil, skipped: state.skipped) }
        var prefix = "Project instructions (from the user-trusted project root; current user instructions take precedence):\n"
            + ordered.map(\.text).joined()
        if !state.skipped.isEmpty {
            prefix += "[Note: some instruction files were not loaded: " + state.skipped.joined(separator: "; ") + "]\n"
        }
        let snapshot = TrustedProjectInstructionSnapshot(
            systemPromptPrefix: prefix, loadedRelativePaths: paths,
            sourceFileSHA256: state.sourceHashes, rootDirectoryIdentity: rootIdentity)
        return LoadReport(snapshot: snapshot, skipped: state.skipped)
    }

    // MARK: - Collection

    private struct Group {
        var text = ""
        var paths: [String] = []
    }

    private struct Loaded {
        let text: String
        let sha256: String
        let identity: String
        let truncatedAt: Int?
    }

    private enum ReadOutcome {
        case missing
        case skipped(String)
        case loaded(Loaded)
    }

    private enum OpenResult {
        case fd(Int32)
        case missing
        case symlink
        case denied
    }

    private final class Collector {
        let rootPath: String
        let homePath: String
        var remaining = TrustedProjectInstructions.maxTotalBytes
        var sourceHashes: [String: String] = [:]
        var sources: [String: Loaded] = [:]
        var topLevelKeys: Set<String> = []
        var seenFiles: Set<String> = []
        var active: Set<String> = []
        var skipped: [String] = []
        var loaded: [String] = []

        init(rootPath: String, homePath: String) {
            self.rootPath = rootPath
            self.homePath = homePath
        }

        func key(base: String, rel: String) -> String {
            base == rootPath ? rel : (base == "/" ? "" : base) + "/" + rel
        }

        /// 上层目录与用户级目录：读不到（不存在、无权限）都不影响项目本身。
        func loadOptionalGroup(base: String, names: [String]) throws -> Group {
            let parts = base.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let fd = parts.isEmpty
                ? Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                : ((try? TrustedProjectInstructions.openDirectory(parts)) ?? -1)
            guard fd >= 0 else { return Group() }
            defer { Darwin.close(fd) }
            return try loadGroup(base: base, baseFD: fd, names: names)
        }

        func loadGroup(base: String, baseFD: Int32, names: [String]) throws -> Group {
            var group = Group()
            for name in names {
                let before = loaded.count
                guard let text = try expand(base: base, baseFD: baseFD, rel: name, depth: 0, topLevel: true) else { continue }
                group.text += text
                group.paths.append(contentsOf: loaded[before...])
            }
            return group
        }

        func expand(base: String, baseFD: Int32, rel: String, depth: Int, topLevel: Bool) throws -> String? {
            let key = key(base: base, rel: rel)
            guard !active.contains(key) else { return nil }
            if !topLevel, topLevelKeys.contains(key) { return nil }
            let source: Loaded
            if let frozen = sources[key] {
                guard frozen.text.utf8.count <= remaining else { return nil }
                source = frozen
            } else {
                guard remaining > 0 else {
                    // 只有确实存在的文件才值得提示；这里没读过，先探测一下是否存在。
                    if case .missing = try TrustedProjectInstructions.readFile(
                        base: base, baseFD: baseFD, rel: rel, limit: 1,
                        rootPath: rootPath, homePath: homePath) { return nil }
                    skipped.append("\(key)（已超过总量上限 \(TrustedProjectInstructions.maxTotalBytes / 1024) KB）")
                    return nil
                }
                let limit = min(TrustedProjectInstructions.maxBytes, remaining)
                switch try TrustedProjectInstructions.readFile(
                    base: base, baseFD: baseFD, rel: rel, limit: limit,
                    rootPath: rootPath, homePath: homePath) {
                case .missing: return nil
                case .skipped(let reason):
                    skipped.append("\(key)（\(reason)）")
                    return nil
                case .loaded(let value):
                    // 同一个物理文件（例如 CLAUDE.md 是指向 AGENTS.md 的符号链接）只加载一次。
                    let fresh = seenFiles.insert(value.identity).inserted
                    if topLevel && !fresh { return nil }
                    sources[key] = value
                    source = value
                }
            }
            if topLevel { topLevelKeys.insert(key) }
            let text = source.text
            sourceHashes[key] = source.sha256
            remaining -= text.utf8.count
            active.insert(key)
            defer { active.remove(key) }
            loaded.append(key)
            var result = "[Project instruction file: \(key)]\n"
            let parent = (rel as NSString).deletingLastPathComponent
            // Imports are whitespace-delimited @path tokens, relative to the
            // importing file. Email addresses and ordinary prose stay text.
            for line in text.components(separatedBy: "\n") {
                for token in line.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix("@") {
                    guard depth < TrustedProjectInstructions.maxImportDepth,
                          let relative = TrustedProjectInstructions.importPath(String(token.dropFirst()), parent: parent),
                          let imported = try expand(base: base, baseFD: baseFD, rel: relative, depth: depth + 1, topLevel: false) else { continue }
                    result += imported + "\n"
                }
                result += line + "\n"
            }
            if let cut = source.truncatedAt {
                result += "[Note: \(key) 超过 \(cut / 1024) KB，仅加载了前 \(cut / 1024) KB]\n"
            }
            return result
        }
    }

    // MARK: - File access

    private static func importPath(_ path: String, parent: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
        var parts = parent.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    private static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func openDirectory(_ components: [String]) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        for component in components {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = posixError()
                Darwin.close(descriptor)
                throw error
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func within(_ path: String, _ prefix: String) -> Bool {
        prefix == "/" || path == prefix || path.hasPrefix(prefix + "/")
    }

    /// 符号链接解析后的目标必须仍在可读范围内：项目根内、~/.claude 内，
    /// 或家目录下非隐藏、非 Library 的普通位置。
    private static func symlinkTargetAllowed(_ resolved: String, rootPath: String, homePath: String) -> Bool {
        if within(resolved, rootPath) || within(resolved, homePath + "/.claude") { return true }
        guard within(resolved, homePath), resolved != homePath else { return false }
        let first = resolved.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return !first.hasPrefix(".") && first != "Library"
    }

    private static func openFile(dirFD: Int32, parts: [String]) throws -> OpenResult {
        guard let name = parts.last else { return .missing }
        var directory = dup(dirFD)
        guard directory >= 0 else { throw posixError() }
        defer { Darwin.close(directory) }
        func classify(_ failedName: String) throws -> OpenResult {
            let code = errno
            var info = stat()
            if fstatat(directory, failedName, &info, AT_SYMLINK_NOFOLLOW) == 0,
               (info.st_mode & S_IFMT) == S_IFLNK { return .symlink }
            if code == ENOENT || code == ENOTDIR || code == ELOOP { return .missing }
            if code == EACCES || code == EPERM { return .denied }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        for part in parts.dropLast() {
            let next = Darwin.openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return try classify(part) }
            Darwin.close(directory)
            directory = next
        }
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return try classify(name) }
        return .fd(fd)
    }

    private static func readFile(base: String, baseFD: Int32, rel: String, limit: Int,
                                 rootPath: String, homePath: String) throws -> ReadOutcome {
        let parts = rel.split(separator: "/").map(String.init)
        switch try openFile(dirFD: baseFD, parts: parts) {
        case .fd(let fd):
            defer { Darwin.close(fd) }
            return try consume(fd, limit: limit)
        case .missing:
            return .missing
        case .denied:
            return .skipped("没有读取权限")
        case .symlink:
            let full = (base == "/" ? "" : base) + "/" + rel
            guard let raw = realpath(full, nil) else { return .missing }
            let resolved = String(cString: raw)
            free(raw)
            guard symlinkTargetAllowed(resolved, rootPath: rootPath, homePath: homePath) else {
                return .skipped("符号链接指向了可读范围之外")
            }
            let top = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard top >= 0 else { throw posixError() }
            defer { Darwin.close(top) }
            switch try openFile(dirFD: top, parts: resolved.split(separator: "/").map(String.init)) {
            case .fd(let fd):
                defer { Darwin.close(fd) }
                return try consume(fd, limit: limit)
            case .denied: return .skipped("没有读取权限")
            default: return .missing
            }
        }
    }

    private static func consume(_ fd: Int32, limit: Int) throws -> ReadOutcome {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        // 空文件、目录、管道等没有可加载的内容，按“没有这个文件”处理。
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else { return .missing }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while bytes.count <= limit {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - bytes.count))
            if count == 0 { break }
            guard count > 0 else { throw posixError() }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        let truncated = bytes.count > limit
        if truncated { bytes = bytes.prefix(limit) }
        guard let text = decode(bytes, mayBeCut: truncated) else {
            return .skipped("文件编码无法识别，需要 UTF-8 或 GB18030")
        }
        return .loaded(Loaded(
            text: text, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            identity: "\(info.st_dev):\(info.st_ino)", truncatedAt: truncated ? limit : nil))
    }

    private static func decode(_ data: Data, mayBeCut: Bool) -> String? {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [String.Encoding.utf8, gb] {
            for drop in 0...(mayBeCut ? 3 : 0) where data.count > drop {
                if let text = String(data: data.prefix(data.count - drop), encoding: encoding) { return text }
            }
        }
        return nil
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
