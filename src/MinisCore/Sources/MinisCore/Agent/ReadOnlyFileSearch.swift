import Foundation
import Darwin

/// Read-only native product tools. Authority is always supplied by the existing
/// file_read boundary; this scanner neither grants roots nor spawns commands.
public enum ReadOnlyFileSearch {
    public static let toolNames: Set<String> = ["file_grep", "file_glob"]
    public static let maximumResults = 1_000
    public static let defaultResults = 250
    public static let maximumEntries = 200_000
    public static let maximumFileBytes = 2 * 1024 * 1024
    public static let maximumReadBytes = 64 * 1024 * 1024
    public static let maximumDepth = 64
    static let maximumLineCharacters = 1_024
    static let maximumMatchedLineCharacters = 16_384
    static let maximumGitignoreBytes = 64 * 1024

    /// Traversal budgets. Production always uses `.standard`; the type exists so
    /// budget exhaustion can be exercised without writing tens of megabytes.
    struct Budgets: Sendable {
        var entries = ReadOnlyFileSearch.maximumEntries
        var fileBytes = ReadOnlyFileSearch.maximumFileBytes
        var readBytes = ReadOnlyFileSearch.maximumReadBytes
        static let standard = Budgets()
    }

    /// Directories that are almost never what the user means to search.
    /// `include_ignored=true` searches them anyway.
    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", "dist", "build",
        "Pods", "__pycache__", ".venv", ".next", ".gradle", ".idea", ".cache"
    ]

    static let fileTypes: [String: [String]] = [
        "swift": ["swift"], "py": ["py", "pyi"], "js": ["js", "jsx", "mjs", "cjs"],
        "ts": ["ts", "tsx", "mts", "cts"], "json": ["json", "jsonc"], "md": ["md", "markdown"],
        "rust": ["rs"], "go": ["go"], "java": ["java"], "kotlin": ["kt", "kts"],
        "c": ["c", "h"], "cpp": ["cc", "cpp", "cxx", "hpp", "hh", "h"], "objc": ["m", "mm", "h"],
        "html": ["html", "htm"], "css": ["css", "scss", "sass", "less"], "yaml": ["yml", "yaml"],
        "toml": ["toml"], "sh": ["sh", "bash", "zsh"], "ruby": ["rb"], "php": ["php"],
        "sql": ["sql"], "xml": ["xml", "plist"], "txt": ["txt"], "csv": ["csv", "tsv"],
        "lua": ["lua"], "dart": ["dart"], "scala": ["scala"]
    ]

    // MARK: - Glob

    /// Translate a glob to an anchored regular expression. `*` and `?` never
    /// cross `/`; `**/` matches zero or more directories (so `**/*.swift` also
    /// matches a top-level file); `{a,b}` alternation and `[...]` classes work.
    static func globRegex(_ rawPattern: String) -> NSRegularExpression? {
        var pattern = rawPattern
        while pattern.hasPrefix("./") { pattern.removeFirst(2) }
        while pattern.hasPrefix("/") { pattern.removeFirst() }
        let chars = Array(pattern)
        var out = "^"
        var braceDepth = 0
        var index = 0
        while index < chars.count {
            let c = chars[index]
            switch c {
            case "*":
                var end = index
                while end < chars.count, chars[end] == "*" { end += 1 }
                if end - index >= 2 {
                    if end < chars.count, chars[end] == "/" {
                        out += "(?:.*/)?"
                        index = end + 1
                    } else {
                        out += ".*"
                        index = end
                    }
                } else {
                    out += "[^/]*"
                    index = end
                }
                continue
            case "?": out += "[^/]"
            case "{": braceDepth += 1; out += "(?:"
            case "}":
                if braceDepth > 0 { braceDepth -= 1; out += ")" } else { out += "\\}" }
            case ",":
                out += braceDepth > 0 ? "|" : ","
            case "[":
                if let close = chars[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(chars[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    out += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close
                } else {
                    out += "\\["
                }
            case "\\":
                if index + 1 < chars.count {
                    index += 1
                    out += NSRegularExpression.escapedPattern(for: String(chars[index]))
                } else {
                    out += "\\\\"
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            index += 1
        }
        guard braceDepth == 0 else { return nil }
        out += "$"
        return try? NSRegularExpression(pattern: out)
    }

    private struct GlobMatcher {
        let regex: NSRegularExpression
        let matchesFullPath: Bool

        init?(_ pattern: String) {
            guard let regex = ReadOnlyFileSearch.globRegex(pattern) else { return nil }
            self.regex = regex
            self.matchesFullPath = pattern.contains("/")
        }

        func matches(relative: String) -> Bool {
            let candidate = matchesFullPath ? relative : (relative as NSString).lastPathComponent
            return regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        }
    }

    // MARK: - .gitignore (simple rules only)

    private struct IgnoreRule {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool
    }

    private struct IgnoreRuleSet {
        let base: String // relative directory the .gitignore lives in; "" for root
        let rules: [IgnoreRule]

        init(base: String, text: String) {
            self.base = base
            var parsed: [IgnoreRule] = []
            for rawLine in text.split(whereSeparator: \.isNewline) {
                var line = String(rawLine)
                while line.hasSuffix(" ") { line.removeLast() }
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                var negated = false
                if line.hasPrefix("!") { negated = true; line.removeFirst() }
                var directoryOnly = false
                if line.hasSuffix("/") { directoryOnly = true; line.removeLast() }
                guard !line.isEmpty else { continue }
                let anchored = line.contains("/")
                if line.hasPrefix("/") { line.removeFirst() }
                guard let regex = ReadOnlyFileSearch.globRegex(line) else { continue }
                parsed.append(IgnoreRule(regex: regex, negated: negated,
                                         directoryOnly: directoryOnly, anchored: anchored))
            }
            self.rules = parsed
        }

        /// nil: no rule matched; true: ignored; false: re-included by a "!" rule.
        func verdict(relativeToRoot path: String, isDirectory: Bool) -> Bool? {
            let local: String
            if base.isEmpty {
                local = path
            } else if path.hasPrefix(base + "/") {
                local = String(path.dropFirst(base.count + 1))
            } else {
                return nil
            }
            var result: Bool?
            for rule in rules {
                if rule.directoryOnly && !isDirectory { continue }
                let candidate = rule.anchored ? local : (local as NSString).lastPathComponent
                if rule.regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                    result = !rule.negated
                }
            }
            return result
        }
    }

    // MARK: - Text decoding

    /// UTF-8 first; legacy Chinese files (GBK/GB2312/GB18030) are decoded as GB18030.
    static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }

    /// 带 BOM 的 UTF-16 文本（旧版 Xcode 的 .strings、Windows 导出文件、PowerShell 重定向日志）。
    /// 每个英文字符都带一个 0 字节，不能按"含 0 字节即二进制"判断，先看文件头再按 UTF-16 解码。
    /// 没有 BOM 或解码失败返回 nil（按原来的二进制/UTF-8/GB18030 流程处理）。
    static func decodeUTF16WithBOM(_ data: Data) -> String? {
        guard data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) else { return nil }
        return String(data: data, encoding: .utf16)
    }

    // MARK: - Execution

    private static func integer(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        // Approved Composer integers return as native Int64, not Int.
        if Swift.type(of: raw) == Int64.self, let integer = raw as? Int64 { return Int(exactly: integer) }
        return raw as? Int
    }

    private static func flag(_ input: [String: Any], _ key: String) -> Bool {
        (input[key] as? Bool) ?? false
    }

    public static func execute(
        name: String, input: [String: Any],
        validatePath: (String) throws -> URL,
        isSensitive: (URL) -> Bool
    ) throws -> String {
        try execute(name: name, input: input, budgets: .standard,
                    validatePath: validatePath, isSensitive: isSensitive)
    }

    static func execute(
        name: String, input: [String: Any], budgets: Budgets,
        validatePath: (String) throws -> URL,
        isSensitive: (URL) -> Bool
    ) throws -> String {
        guard toolNames.contains(name) else { throw ToolExecutorError.unknownTool(name) }
        guard let path = input["path"] as? String, !path.isEmpty else {
            throw ToolExecutorError.missingParameter("path")
        }
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty,
              pattern.utf8.count <= 512 else {
            throw ToolExecutorError.invalidParameter("pattern must contain 1...512 UTF-8 bytes")
        }
        try Task.checkCancellation()
        let root = try validatePath(path)
        guard !isSensitive(root) else { throw ToolExecutorError.permissionDenied(path) }
        // Reject symlink roots as well as descendants. Resolving a symlink into
        // an allowed location does not make traversal through it necessary.
        guard root.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path else {
            throw ToolExecutorError.pathViolation(path)
        }
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ToolExecutorError.pathViolation(path) }
        defer { _ = Darwin.close(rootFD) }
        var actualPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let pathResult = actualPath.withUnsafeMutableBufferPointer {
            fcntl(rootFD, F_GETPATH, $0.baseAddress!)
        }
        guard pathResult == 0 else { throw ToolExecutorError.pathViolation(path) }
        let anchoredPath = actualPath.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // F_GETPATH uses the physical /private/var spelling on macOS while
        // Foundation canonicalizes that same directory to /var. Reapply the
        // existing authority resolver instead of comparing those raw spellings.
        guard try validatePath(anchoredPath).path == root.path else {
            throw ToolExecutorError.pathViolation(path)
        }

        let isGrep = name == "file_grep"
        let resultLimit = min(maximumResults, max(1, integer(input["max_results"]) ?? defaultResults))
        let ignoreCase = flag(input, "ignore_case")
        let includeIgnored = flag(input, "include_ignored")
        let literal = flag(input, "literal")
        let contextBoth = max(0, min(20, integer(input["context"]) ?? 0))
        let linesBefore = max(0, min(20, integer(input["before"]) ?? contextBoth))
        let linesAfter = max(0, min(20, integer(input["after"]) ?? contextBoth))
        let outputMode = (input["output_mode"] as? String) ?? "content"
        guard ["content", "files_with_matches", "count"].contains(outputMode) else {
            throw ToolExecutorError.invalidParameter("output_mode must be content, files_with_matches or count")
        }

        // The glob tool uses `pattern` as the glob; grep may add an optional `glob` filter.
        var globMatcher: GlobMatcher?
        if isGrep {
            if let filter = input["glob"] as? String, !filter.isEmpty {
                guard let matcher = GlobMatcher(filter) else {
                    throw ToolExecutorError.invalidParameter("glob is not a valid glob pattern")
                }
                globMatcher = matcher
            }
        } else {
            guard let matcher = GlobMatcher(pattern) else {
                throw ToolExecutorError.invalidParameter("pattern is not a valid glob pattern")
            }
            globMatcher = matcher
        }
        var typeExtensions: Set<String>?
        if isGrep, let type = input["type"] as? String, !type.isEmpty {
            guard let extensions = fileTypes[type.lowercased()] else {
                throw ToolExecutorError.invalidParameter(
                    "type must be one of: " + fileTypes.keys.sorted().joined(separator: ", "))
            }
            typeExtensions = Set(extensions)
        }
        var contentRegex: NSRegularExpression?
        if isGrep, !literal {
            do {
                contentRegex = try NSRegularExpression(
                    pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
            } catch {
                throw ToolExecutorError.invalidParameter(
                    "pattern is not a valid regular expression; escape special characters or pass literal=true")
            }
        }

        struct FileHit { let relative: String; let modified: TimeInterval; let count: Int }
        var rows: [String] = []
        var hits: [FileHit] = []
        var globMatches: [(relative: String, modified: TimeInterval)] = []
        var matchCount = 0
        var visited = 0, readBytes = 0
        var limited = false
        final class OversizedCount { var value = 0 }
        var skipped = 0
        let oversized = OversizedCount()
        var overflow = 0 // matches found beyond the result limit for glob/files modes

        func lineMatches(_ line: String) -> Bool {
            let candidate = line.utf8.count > maximumMatchedLineCharacters * 4
                ? String(line.prefix(maximumMatchedLineCharacters)) : line
            if let contentRegex {
                return contentRegex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }
            return candidate.range(of: pattern, options: ignoreCase ? [.caseInsensitive, .literal] : [.literal]) != nil
        }

        func readBytesOfFile(parentFD: Int32, leaf: String, expected: stat, limit: Int,
                             countsAgainstBudget: Bool) throws -> Data? {
            guard expected.st_size >= 0, Int(expected.st_size) <= limit else {
                oversized.value += 1; skipped += 1
                return nil
            }
            if countsAgainstBudget, readBytes + Int(expected.st_size) > budgets.readBytes {
                skipped += 1; limited = true
                return nil
            }
            let fd = Darwin.openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { skipped += 1; return nil }
            defer { _ = Darwin.close(fd) }
            var opened = stat()
            guard Darwin.fstat(fd, &opened) == 0,
                  opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino,
                  (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), opened.st_nlink == 1 else {
                skipped += 1; return nil
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { skipped += 1; return nil }
                if countsAgainstBudget { readBytes += count }
                guard data.count + count <= limit else { oversized.value += 1; skipped += 1; return nil }
                if countsAgainstBudget, readBytes > budgets.readBytes { limited = true; return nil }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }

        func scanFile(relative: String, parentFD: Int32, leaf: String, info: stat) throws {
            guard let data = try readBytesOfFile(parentFD: parentFD, leaf: leaf, expected: info,
                limit: budgets.fileBytes, countsAgainstBudget: true) else { return }
            guard let text = decodeUTF16WithBOM(data) ?? (data.contains(0) ? nil : decodeText(data)) else {
                skipped += 1; return
            }
            // NSString splitting: "\r\n" is one Character in Swift, so a Character split would miss it.
            let lines = text.components(separatedBy: "\n")
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            var fileMatches = 0
            var lastEmitted = -1
            for (offset, line) in lines.enumerated() {
                if offset & 1023 == 0 { try Task.checkCancellation() }
                guard lineMatches(line) else { continue }
                fileMatches += 1
                if outputMode == "content" {
                    let from = max(lastEmitted + 1, offset - linesBefore)
                    if lastEmitted >= 0, from > lastEmitted + 1, linesBefore + linesAfter > 0 { rows.append("--") }
                    if from < offset {
                        for context in from..<offset {
                            rows.append("\(relative)-\(context + 1)-\(lines[context].prefix(maximumLineCharacters))")
                        }
                    }
                    rows.append("\(relative):\(offset + 1):\(line.prefix(maximumLineCharacters))")
                    lastEmitted = offset
                    matchCount += 1
                    if linesAfter > 0 {
                        let to = min(lines.count - 1, offset + linesAfter)
                        if to > offset {
                            // Later matches inside the window are emitted as matches, not context.
                            var next = offset + 1
                            while next <= to {
                                if lineMatches(lines[next]) { break }
                                rows.append("\(relative)-\(next + 1)-\(lines[next].prefix(maximumLineCharacters))")
                                lastEmitted = next
                                next += 1
                            }
                        }
                    }
                    if matchCount >= resultLimit { limited = true; return }
                } else if outputMode == "files_with_matches" {
                    break
                }
            }
            if fileMatches > 0, outputMode != "content" {
                var stamp = stat()
                _ = fstatat(parentFD, leaf, &stamp, AT_SYMLINK_NOFOLLOW)
                hits.append(FileHit(relative: relative,
                                    modified: TimeInterval(stamp.st_mtimespec.tv_sec),
                                    count: fileMatches))
            }
        }

        func walk(_ fd: Int32, directory: URL, prefix: String, depth: Int, inherited: [IgnoreRuleSet]) throws {
            try Task.checkCancellation()
            guard depth <= maximumDepth else { limited = true; return }
            let duplicate = Darwin.dup(fd)
            guard duplicate >= 0 else { throw ToolExecutorError.readFailed("Cannot enumerate directory") }
            guard let stream = fdopendir(duplicate) else {
                _ = Darwin.close(duplicate)
                throw ToolExecutorError.readFailed("Cannot enumerate directory")
            }
            var leaves: [String] = []
            while let entry = readdir(stream) {
                let leaf = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if leaf != "." && leaf != ".." { leaves.append(leaf) }
            }
            closedir(stream)
            leaves.sort()

            var rules = inherited
            if !includeIgnored, leaves.contains(".gitignore") {
                var info = stat()
                if fstatat(fd, ".gitignore", &info, AT_SYMLINK_NOFOLLOW) == 0,
                   (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
                   Int(info.st_size) <= maximumGitignoreBytes,
                   let data = try readBytesOfFile(parentFD: fd, leaf: ".gitignore", expected: info,
                       limit: maximumGitignoreBytes, countsAgainstBudget: false),
                   let text = String(data: data, encoding: .utf8) {
                    rules.append(IgnoreRuleSet(base: prefix, text: text))
                }
                // A rejected or oversized .gitignore is simply not applied; it must not
                // count as a skipped searchable entry.
            }
            func ignored(_ relative: String, isDirectory: Bool) -> Bool {
                var verdict = false
                for set in rules {
                    if let result = set.verdict(relativeToRoot: relative, isDirectory: isDirectory) { verdict = result }
                }
                return verdict
            }

            for leaf in leaves {
                try Task.checkCancellation()
                guard visited < budgets.entries, !limited else { limited = true; return }
                if isGrep && outputMode == "content" && matchCount >= resultLimit { limited = true; return }
                visited += 1
                let url = directory.appendingPathComponent(leaf)
                let relative = prefix.isEmpty ? leaf : prefix + "/" + leaf
                var info = stat()
                guard fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { skipped += 1; continue }
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR), !includeIgnored,
                   ignoredDirectoryNames.contains(leaf) || ignored(relative, isDirectory: true) {
                    continue
                }
                if kind == mode_t(S_IFREG), !includeIgnored, ignored(relative, isDirectory: false) { continue }
                // Validate every candidate through file_read's same roots and
                // deny list before listing it or opening its contents.
                guard let admitted = try? validatePath(url.path), admitted.path == url.path,
                      !isSensitive(admitted) else { skipped += 1; continue }
                if kind == mode_t(S_IFDIR) {
                    let child = Darwin.openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { skipped += 1; continue }
                    defer { _ = Darwin.close(child) }
                    var opened = stat()
                    if fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino {
                        try walk(child, directory: url, prefix: relative, depth: depth + 1, inherited: rules)
                    } else { skipped += 1 }
                } else if kind == mode_t(S_IFREG), info.st_nlink == 1 {
                    if !isGrep {
                        if globMatcher?.matches(relative: relative) == true {
                            globMatches.append((relative, TimeInterval(info.st_mtimespec.tv_sec)))
                        }
                        continue
                    }
                    if let globMatcher, !globMatcher.matches(relative: relative) { continue }
                    if let typeExtensions,
                       !typeExtensions.contains((leaf as NSString).pathExtension.lowercased()) { continue }
                    try scanFile(relative: relative, parentFD: fd, leaf: leaf, info: info)
                } else { skipped += 1 }
            }
        }
        try walk(rootFD, directory: root, prefix: "", depth: 0, inherited: [])
        try Task.checkCancellation()

        // Files modes are ordered newest-modified first, like Claude Code.
        var shownCount = matchCount
        if !isGrep {
            let sorted = globMatches.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.relative < $1.relative }
            rows = sorted.prefix(resultLimit).map(\.relative)
            overflow = max(0, sorted.count - resultLimit)
            shownCount = rows.count
        } else if outputMode != "content" {
            let sorted = hits.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.relative < $1.relative }
            let shown = sorted.prefix(resultLimit)
            rows = shown.map { outputMode == "count" ? "\($0.relative):\($0.count)" : $0.relative }
            overflow = max(0, sorted.count - resultLimit)
            shownCount = rows.count
        }
        var summary = "\n\(shownCount) result(s); skipped \(skipped) unreadable, sensitive, linked, binary or oversized entries"
        if oversized.value > 0 { summary += " (\(oversized.value) larger than \(budgets.fileBytes / (1024 * 1024)) MiB)" }
        summary += "."
        if limited || overflow > 0 {
            summary += " Search stopped at a safety budget; results are INCOMPLETE"
            if overflow > 0 { summary += " (\(overflow) more match(es) not shown)" }
            summary += ". Narrow path, pattern, glob or type, or raise max_results (up to \(maximumResults))."
        }
        return MCPOutputLimiter.project(rows.joined(separator: "\n") + summary)
    }

    public static func definitions() -> [AgentToolDefinition] {
        let grepDescription = "Search file contents under a directory with a regular expression (like ripgrep); use it instead of shell grep/rg or reading many files. Returns relative/path:line:text (text cut at 1024 characters) plus a summary of the result count and skipped entries. The pattern is a regular expression (NSRegularExpression syntax, matched per line, cannot span lines); pass literal=true to match text verbatim, ignore_case=true for case-insensitive. Narrow with glob (e.g. \"*.swift\", \"src/**/*.{ts,tsx}\") or type (swift, py, js, ts, json, md, ...). output_mode: content (default, matching lines), files_with_matches (paths, newest first) or count (path:count). context/before/after add surrounding lines (marked path-line-text). path must be a directory; for one file use file_read. Hidden files are searched; .git, node_modules, .build, DerivedData, dist, build and similar plus simple .gitignore rules are skipped unless include_ignored=true. Sensitive files, links, binary files and files over 2 MiB are skipped; it stops at max_results (default 250, max 1000), 200,000 entries, 64 MiB read or depth 64. If the summary says the results are INCOMPLETE, narrow the search before drawing a conclusion. No hit is not proof of absence: try another spelling or wider directory first."
        let globDescription = "List files by name pattern under a directory; use it instead of shell find or ls. Returns relative paths of regular files only (no directories), newest modified first. A pattern without '/' matches file names at any depth (*.swift). A pattern with '/' matches the whole relative path: * and ? do not cross '/', ** matches any number of directories including none (**/*.swift also matches a top-level file), {a,b} alternates (src/**/*.{ts,tsx}) and [abc] is a character class. Hidden files are listed; .git, node_modules, .build, DerivedData, dist, build and similar plus simple .gitignore rules are skipped unless include_ignored=true. Sensitive files and links are skipped; limits match file_grep, and the summary says when the list is INCOMPLETE."
        let grepParams: [(String, AgentToolParam)] = [
            ("path", AgentToolParam(type: .string, description: "Absolute directory inside authorized roots. A file path fails.")),
            ("pattern", AgentToolParam(type: .string, description: "Regular expression, 1 to 512 UTF-8 bytes (literal text when literal=true).")),
            ("glob", AgentToolParam(type: .string, description: "Only search files whose name or relative path matches this glob, e.g. \"*.swift\" or \"src/**/*.{ts,tsx}\".")),
            ("type", AgentToolParam(type: .string, description: "Only search this file type: " + fileTypes.keys.sorted().joined(separator: ", ") + ".")),
            ("output_mode", AgentToolParam(type: .string, description: "content (default), files_with_matches or count.",
                                           enumValues: ["content", "files_with_matches", "count"])),
            ("context", AgentToolParam(type: .integer, description: "Lines of context before and after each match, 0 to 20; default 0.")),
            ("before", AgentToolParam(type: .integer, description: "Lines of context before each match; overrides context.")),
            ("after", AgentToolParam(type: .integer, description: "Lines of context after each match; overrides context.")),
            ("max_results", AgentToolParam(type: .integer, description: "1 to 1000, default 250.")),
            ("ignore_case", AgentToolParam(type: .boolean, description: "true for case-insensitive matching; default false.")),
            ("literal", AgentToolParam(type: .boolean, description: "true to match the pattern as plain text instead of a regular expression; default false.")),
            ("include_ignored", AgentToolParam(type: .boolean, description: "true to also search ignored directories (node_modules, build, .gitignore matches); default false."))
        ]
        let globParams: [(String, AgentToolParam)] = [
            ("path", AgentToolParam(type: .string, description: "Absolute directory inside authorized roots.")),
            ("pattern", AgentToolParam(type: .string, description: "Glob, 1 to 512 UTF-8 bytes. Supports **, {a,b} and [abc].")),
            ("max_results", AgentToolParam(type: .integer, description: "1 to 1000, default 250.")),
            ("include_ignored", AgentToolParam(type: .boolean, description: "true to also list ignored directories (node_modules, build, .gitignore matches); default false."))
        ]
        return [
            AgentToolDefinition(name: "file_grep", description: grepDescription,
                parameters: Dictionary(uniqueKeysWithValues: grepParams), required: ["path", "pattern"]),
            AgentToolDefinition(name: "file_glob", description: globDescription,
                parameters: Dictionary(uniqueKeysWithValues: globParams), required: ["path", "pattern"])
        ]
    }
}
