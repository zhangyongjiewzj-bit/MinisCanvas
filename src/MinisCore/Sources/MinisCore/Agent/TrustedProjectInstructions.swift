import Foundation
import Darwin
import CryptoKit

/// Only a root already admitted by the product project trust boundary may be
/// passed here. Session metadata and model-supplied paths are not authority.
public enum TrustedProjectInstructions {
    public static let maxBytes = 64 * 1024
    public static let maxImportDepth = 4

    public static func load(atTrustedRoot root: URL) throws -> String? {
        try loadSnapshot(atTrustedRoot: root)?.systemPromptPrefix
    }

    public static func loadSnapshot(atTrustedRoot root: URL) throws -> TrustedProjectInstructionSnapshot? {
        // The admitted caller supplies the physical spelling. Foundation may
        // standardize /private/var back to the system /var symlink; preserve
        // that spelling for the descriptor walk instead of reintroducing it.
        let path = root.relativePath
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard root.isFileURL, path.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let rootFD = try openRoot(components)
        guard rootFD >= 0 else { throw posixError() }
        defer { Darwin.close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else { throw posixError() }
        let rootIdentity = "\(rootInfo.st_dev):\(rootInfo.st_ino)"
        var sourceHashes: [String: String] = [:]
        var sources: [String: (text: String, sha256: String)] = [:]
        var remaining = maxBytes
        var loaded: [String] = []
        var active: Set<String> = []

        func expand(_ path: String, depth: Int) throws -> String? {
            guard !active.contains(path) else { return nil }
            let source: (text: String, sha256: String)
            if let frozen = sources[path] {
                guard frozen.text.utf8.count <= remaining else { return nil }
                source = frozen
            } else {
                guard let loaded = try read(path, rootFD: rootFD, limit: remaining) else { return nil }
                sources[path] = loaded
                source = loaded
            }
            let text = source.text
            sourceHashes[path] = source.sha256
            remaining -= text.utf8.count
            active.insert(path)
            defer { active.remove(path) }
            loaded.append(path)
            var result = "[Project instruction file: \(path)]\n"
            let parent = (path as NSString).deletingLastPathComponent
            // Imports are whitespace-delimited @path tokens, relative to the
            // importing file. Email addresses and ordinary prose stay text.
            for line in text.components(separatedBy: "\n") {
                for token in line.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix("@") {
                    guard depth < maxImportDepth,
                          let relative = importPath(String(token.dropFirst()), parent: parent),
                          let imported = try expand(relative, depth: depth + 1) else { continue }
                    result += imported + "\n"
                }
                result += line + "\n"
            }
            return result
        }
        for candidate in ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"] {
            if let text = try expand(candidate, depth: 0) {
                return TrustedProjectInstructionSnapshot(
                    systemPromptPrefix: "Project instructions (from the user-trusted project root; current user instructions take precedence):\n" + text,
                    loadedRelativePaths: loaded, sourceFileSHA256: sourceHashes,
                    rootDirectoryIdentity: rootIdentity)
            }
        }
        return nil
    }

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

    private static func openRoot(_ components: [Substring]) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        for component in components {
            let next = Darwin.openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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

    private static func read(_ path: String, rootFD: Int32, limit: Int) throws -> (text: String, sha256: String)? {
        let parts = path.split(separator: "/").map(String.init)
        var directory = dup(rootFD)
        guard directory >= 0 else { throw posixError() }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = Darwin.openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return nil }
                throw posixError()
            }
            Darwin.close(directory)
            directory = next
        }
        guard let name = parts.last else { return nil }
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return nil }
            throw posixError()
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
              info.st_size <= limit else { return nil }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit + 1, 8192))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw posixError() }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= limit else { return nil }
        }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        return (text, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
