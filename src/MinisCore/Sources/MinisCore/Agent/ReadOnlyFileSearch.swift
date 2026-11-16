import Foundation
import Darwin

/// Read-only native product tools. Authority is always supplied by the existing
/// file_read boundary; this scanner neither grants roots nor spawns commands.
public enum ReadOnlyFileSearch {
    public static let toolNames: Set<String> = ["file_grep", "file_glob"]
    public static let maximumResults = 200
    public static let maximumEntries = 10_000
    public static let maximumFileBytes = 256 * 1024
    public static let maximumReadBytes = 4 * 1024 * 1024

    public static func execute(
        name: String, input: [String: Any],
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
        // Approved Composer integers return as native Int64, not Int.
        let requestedLimit: Int?
        if let raw = input["max_results"], Swift.type(of: raw) == Int64.self, let integer = raw as? Int64 {
            requestedLimit = Int(exactly: integer)
        } else {
            requestedLimit = input["max_results"] as? Int
        }
        let resultLimit = min(maximumResults, max(1, requestedLimit ?? 100))
        let ignoreCase = (input["ignore_case"] as? Bool) ?? false
        var rows: [String] = []
        var visited = 0, readBytes = 0
        var limited = false
        var skipped = 0
        // Literal grep avoids pathological regex execution. Glob uses POSIX
        // pathname semantics: * never crosses /, ** is not a recursive alias.
        func matchesGlob(_ relative: String) -> Bool {
            let candidate = pattern.contains("/") ? relative : (relative as NSString).lastPathComponent
            return pattern.withCString { p in candidate.withCString { fnmatch(p, $0, FNM_PATHNAME) == 0 } }
        }
        func readText(parentFD: Int32, leaf: String, expected: stat) throws -> String? {
            guard expected.st_size >= 0, expected.st_size <= maximumFileBytes,
                  readBytes + Int(expected.st_size) <= maximumReadBytes else {
                skipped += 1
                if readBytes + Int(max(0, expected.st_size)) > maximumReadBytes { limited = true }
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
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { skipped += 1; return nil }
                readBytes += count
                guard data.count + count <= maximumFileBytes, readBytes <= maximumReadBytes else {
                    limited = true; return nil
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard !data.contains(0) else { skipped += 1; return nil }
            return String(data: data, encoding: .utf8)
        }
        func walk(_ fd: Int32, directory: URL, prefix: String, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32 else { limited = true; return }
            let duplicate = Darwin.dup(fd)
            guard duplicate >= 0 else { throw ToolExecutorError.readFailed("Cannot enumerate directory") }
            guard let stream = fdopendir(duplicate) else {
                _ = Darwin.close(duplicate)
                throw ToolExecutorError.readFailed("Cannot enumerate directory")
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                try Task.checkCancellation()
                guard visited < maximumEntries, rows.count < resultLimit, !limited else {
                    limited = true; return
                }
                let leaf = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if leaf == "." || leaf == ".." { continue }
                visited += 1
                let url = directory.appendingPathComponent(leaf)
                let relative = prefix.isEmpty ? leaf : prefix + "/" + leaf
                // Validate every candidate through file_read's same roots and
                // deny list before listing it or opening its contents.
                guard let admitted = try? validatePath(url.path), admitted.path == url.path,
                      !isSensitive(admitted) else { skipped += 1; continue }
                var info = stat()
                guard fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 else { skipped += 1; continue }
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR) {
                    let child = Darwin.openat(fd, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { skipped += 1; continue }
                    defer { _ = Darwin.close(child) }
                    var opened = stat()
                    if fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino {
                        try walk(child, directory: url, prefix: relative, depth: depth + 1)
                    } else { skipped += 1 }
                } else if kind == mode_t(S_IFREG), info.st_nlink == 1 {
                    if name == "file_glob" {
                        if matchesGlob(relative) { rows.append(relative) }
                    } else if let text = try readText(parentFD: fd, leaf: leaf, expected: info) {
                        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                            try Task.checkCancellation()
                            if line.range(of: pattern, options: ignoreCase ? [.caseInsensitive, .literal] : [.literal]) != nil {
                                // Per-line bounds prevent one huge line filling the result accumulator.
                                rows.append("\(relative):\(offset + 1):\(line.prefix(1024))")
                                if rows.count >= resultLimit { limited = true; break }
                            }
                        }
                    }
                } else { skipped += 1 }
            }
        }
        try walk(rootFD, directory: root, prefix: "", depth: 0)
        try Task.checkCancellation()
        let summary = "\n\(rows.count) result(s); skipped \(skipped) unreadable, sensitive, linked, binary or oversized entries.\(limited ? " Search stopped at a safety budget; narrow path or pattern." : "")"
        return MCPOutputLimiter.project(rows.joined(separator: "\n") + summary)
    }

    public static func definitions() -> [AgentToolDefinition] {
        ["file_grep", "file_glob"].map { name in
            AgentToolDefinition(name: name,
                description: name == "file_grep"
                    ? "Search file contents under a directory for literal text; use it instead of shell grep/rg or reading many files. Returns relative/path:line:text (text cut at 1024 characters) plus a summary of the result count and skipped entries. The pattern is literal, not a regex, cannot span lines, and is case-sensitive unless ignore_case=true. path must be a directory; for one file use file_read. .gitignore is not honored and order is not ranked. Sensitive files, links, binary files and files over 256 KiB are skipped; it stops at 200 results, 10,000 entries, 4 MiB read or depth 32, and the summary then says so, so narrow path or pattern. No hit is not proof of absence: try another spelling or wider directory first."
                    : "List files by name pattern under a directory; use it instead of shell find or ls. Returns relative paths of regular files only (no directories), in directory order. A pattern without '/' matches file names at any depth (*.swift). A pattern with '/' matches the whole relative path, where * does not cross '/' and ** is not recursive (Sources/*/*.swift). Sensitive files and links are skipped; limits match file_grep.",
                parameters: [
                    "path": AgentToolParam(type: .string, description: name == "file_grep" ? "Absolute directory inside authorized roots. A file path fails." : "Absolute directory inside authorized roots."),
                    "pattern": AgentToolParam(type: .string, description: name == "file_grep" ? "Literal text, 1 to 512 UTF-8 bytes. Regex syntax is matched literally." : "POSIX glob, 1 to 512 UTF-8 bytes. No brace expansion."),
                    "max_results": AgentToolParam(type: .integer, description: name == "file_grep" ? "1 to 200, default 100." : "1 to 200, default 100."),
                    "ignore_case": AgentToolParam(type: .boolean, description: name == "file_grep" ? "true for case-insensitive matching; default false." : "No effect for file_glob.")
                ], required: ["path", "pattern"])
        }
    }
}
