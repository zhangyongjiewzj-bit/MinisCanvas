import Foundation
import CryptoKit
import Darwin

/// A stale independent writer must reopen and retry from the committed pair.
/// This is intentionally distinct from IO failure and from same-owner LWW.
public enum MCPPersistenceConflict: Error, Equatable, Sendable {
    case staleSnapshot
    case needsReopen
    case incompleteSnapshot
    case writerBusy
    case scopeUnavailable(path: String, code: Int32)
    case documentUnavailable(path: String, code: Int32)
    case documentTooLarge(path: String)
}

/// Private to MCP persistence; does not extend the app's import fence.
/// Each target has its own lock, so either overlapping member of two pairs
/// conflicts. Parent dev/inode + basename survives document atomic rename and
/// unifies parent-directory aliases. A final-component symlink is rejected:
/// replacing that name and following it have different atomic-write semantics.
enum MCPPersistentWriteFence {
    enum Document { case config, authorization }
    struct TargetID: Hashable, Comparable, Sendable {
        let device: UInt64
        let inode: UInt64
        let basename: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.device != rhs.device { return lhs.device < rhs.device }
            if lhs.inode != rhs.inode { return lhs.inode < rhs.inode }
            return lhs.basename < rhs.basename
        }
    }

    struct DocumentToken: Equatable, Sendable {
        let target: TargetID
        let present: Bool
        let sha256: String?
        let revision: Int?
    }

    struct PairToken: Equatable, Sendable {
        let config: DocumentToken
        let authorization: DocumentToken
    }

    private final class Gate: @unchecked Sendable {
        let lock = NSLock()
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var gates: [TargetID: Gate] = [:]
        func gate(for id: TargetID) -> Gate {
            lock.lock()
            defer { lock.unlock() }
            if let existing = gates[id] { return existing }
            let gate = Gate()
            gates[id] = gate
            return gate
        }
    }
    private static let registry = Registry()

    private struct Target {
        let id: TargetID
        let url: URL
        let originalParent: URL
        let name: String
        let parent: Int32
        let gate: Gate
    }

    /// Created and released while the manager's instance lock is held. Never
    /// waits for another writer: both the process gate and flock are try-only.
    final class Lease {
        private let config: Target
        private let authorization: Target
        private let targets: [Target]
        private var acquired: [(Gate, Int32)] = []
        private var released = false

        fileprivate init(configURL: URL, authorizationURL: URL) throws {
            let config = try Self.target(for: configURL)
            let authorization: Target
            do { authorization = try Self.target(for: authorizationURL) }
            catch { Darwin.close(config.parent); throw error }
            guard config.id != authorization.id else {
                Darwin.close(config.parent)
                Darwin.close(authorization.parent)
                throw MCPPersistenceConflict.scopeUnavailable(path: configURL.path, code: EINVAL)
            }
            self.config = config
            self.authorization = authorization
            var unique: [TargetID: Target] = [config.id: config]
            if unique[authorization.id] == nil { unique[authorization.id] = authorization }
            self.targets = unique.values.sorted { $0.id < $1.id }
            do {
                for target in targets {
                    guard target.gate.lock.try() else { throw MCPPersistenceConflict.writerBusy }
                    let digest = SHA256.hash(data: Data(target.id.basename.utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    let name = ".mcp-write-fence-\(digest).lock"
                    let fd = name.withCString {
                        openat(target.parent, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    }
                    guard fd >= 0 else {
                        let code = errno
                        target.gate.lock.unlock()
                        throw MCPPersistenceConflict.scopeUnavailable(path: target.url.path, code: code)
                    }
                    var opened = stat()
                    var named = stat()
                    let namedResult = name.withCString {
                        fstatat(target.parent, $0, &named, AT_SYMLINK_NOFOLLOW)
                    }
                    guard fstat(fd, &opened) == 0, namedResult == 0,
                          opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
                          opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                        Darwin.close(fd)
                        target.gate.lock.unlock()
                        throw MCPPersistenceConflict.scopeUnavailable(path: target.url.path, code: EINVAL)
                    }
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                        let code = errno
                        Darwin.close(fd)
                        target.gate.lock.unlock()
                        if code == EWOULDBLOCK || code == EAGAIN {
                            throw MCPPersistenceConflict.writerBusy
                        }
                        throw MCPPersistenceConflict.scopeUnavailable(path: target.url.path, code: code)
                    }
                    acquired.append((target.gate, fd))
                }
            } catch {
                release()
                throw error
            }
        }

        private static func target(for url: URL) throws -> Target {
            let parentURL = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
            let parent = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parent >= 0 else {
                throw MCPPersistenceConflict.scopeUnavailable(path: parentURL.path, code: errno)
            }
            var metadata = stat()
            guard fstat(parent, &metadata) == 0 else {
                let code = errno
                Darwin.close(parent)
                throw MCPPersistenceConflict.scopeUnavailable(path: parentURL.path, code: code)
            }
            let caseSensitive: Bool
            do {
                guard let value = try parentURL.resourceValues(
                    forKeys: [.volumeSupportsCaseSensitiveNamesKey]
                ).volumeSupportsCaseSensitiveNames else {
                    throw MCPPersistenceConflict.scopeUnavailable(path: parentURL.path, code: ENOTSUP)
                }
                caseSensitive = value
            } catch {
                Darwin.close(parent)
                throw error
            }
            // Lock aliases must agree before either absent document is first
            // created. Use the owning volume's name-comparison behavior rather
            // than the spelling supplied by one caller. Keep the original name
            // for IO; only the stable lock identity is normalized/folded.
            let normalizedName = url.lastPathComponent.precomposedStringWithCanonicalMapping
            let lockName = caseSensitive ? normalizedName : normalizedName.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
            )
            let id = TargetID(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                              basename: lockName)
            return Target(id: id, url: parentURL.appendingPathComponent(url.lastPathComponent),
                          originalParent: url.deletingLastPathComponent(),
                          name: url.lastPathComponent, parent: parent, gate: registry.gate(for: id))
        }

        private func validateMappings() throws {
            precondition(!released)
            for target in targets {
                var original = stat()
                guard target.originalParent.path.withCString({
                    fstatat(AT_FDCWD, $0, &original, 0)
                }) == 0,
                      UInt64(original.st_dev) == target.id.device,
                      UInt64(original.st_ino) == target.id.inode else {
                    throw MCPPersistenceConflict.scopeUnavailable(
                        path: target.originalParent.path, code: ESTALE
                    )
                }
            }
        }

        /// Descriptor and basename are valid only for this synchronous body.
        /// Both pre/post mapping checks diagnose retargeting; actual IO remains
        /// pinned even when retargeting races either check.
        func withTarget<T>(
            _ kind: Document, _ body: (Int32, String, URL) throws -> T
        ) throws -> T {
            try validateMappings()
            let target = kind == .config ? config : authorization
            let result = try body(target.parent, target.name, target.url)
            try validateMappings()
            return result
        }

        /// Caller owns the duplicate and must close it. Used by cleanup so
        /// unlinkat is bound to the same already locked parent as config/auth.
        func duplicateParent(_ kind: Document) throws -> Int32 {
            try validateMappings()
            let target = kind == .config ? config : authorization
            let copy = fcntl(target.parent, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else {
                throw MCPPersistenceConflict.scopeUnavailable(path: target.url.path, code: errno)
            }
            do { try validateMappings() }
            catch { _ = Darwin.close(copy); throw error }
            return copy
        }

        func token(maxBytes: Int) throws -> PairToken {
            try validateMappings()
            let result = try PairToken(config: document(config, maxBytes: maxBytes).0,
                                       authorization: document(authorization, maxBytes: maxBytes).0)
            try validateMappings()
            return result
        }

        func read(_ kind: Document, maxBytes: Int) throws -> Data? {
            try validateMappings()
            let result = try document(kind == .config ? config : authorization, maxBytes: maxBytes).1
            try validateMappings()
            return result
        }

        enum RevocationError: Error, Equatable { case authorizationExpansion }

        /// An unreadable config cannot admit ordinary writes. This narrower
        /// operation retains the pair lock and only removes whole old grants.
        func replaceAuthorizationsRevokingOnly(
            _ replacement: Data, matching expected: DocumentToken, maxBytes: Int,
            write: (Int32, String, URL) throws -> Void
        ) throws {
            struct AuthorizationDocument: Decodable {
                let authorizations: [MCPToolAuthorization]
                let revision: Int?
            }
            try validateMappings()
            let before = try document(authorization, maxBytes: maxBytes)
            guard before.0 == expected, let original = before.1 else {
                throw MCPPersistenceConflict.staleSnapshot
            }
            let decoder = JSONDecoder()
            let old = try decoder.decode(AuthorizationDocument.self, from: original)
            let new = try decoder.decode(AuthorizationDocument.self, from: replacement)
            var retainedIDs: Set<String> = []
            guard replacement.count <= maxBytes,
                  (new.revision ?? 0) >= (old.revision ?? 0),
                  new.authorizations.count <= old.authorizations.count,
                  new.authorizations.allSatisfy({ grant in
                      guard let id = grant.serverID, retainedIDs.insert(id).inserted else { return false }
                      return old.authorizations.contains(grant)
                  }) else { throw RevocationError.authorizationExpansion }
            // Recheck the same single-document baseline immediately before IO.
            guard try document(authorization, maxBytes: maxBytes).0 == expected else {
                throw MCPPersistenceConflict.staleSnapshot
            }
            try withTarget(.authorization, write)
            let after = try document(authorization, maxBytes: maxBytes)
            guard after.0.target == expected.target, after.1 == replacement else {
                throw MCPPersistenceConflict.staleSnapshot
            }
            try validateMappings()
        }

        private func document(_ target: Target, maxBytes: Int) throws -> (DocumentToken, Data?) {
            // Fail if a cooperating caller's pathname no longer identifies the
            // locked physical parent. Never silently adopt a replacement scope.
            var parent = stat()
            let parentPath = target.url.deletingLastPathComponent().path
            guard parentPath.withCString({ fstatat(AT_FDCWD, $0, &parent, 0) }) == 0,
                  UInt64(parent.st_dev) == target.id.device,
                  UInt64(parent.st_ino) == target.id.inode else {
                throw MCPPersistenceConflict.scopeUnavailable(path: parentPath, code: ESTALE)
            }
            let fd = target.name.withCString {
                openat(target.parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard fd >= 0 else {
                let code = errno
                if code == ENOENT {
                    return (DocumentToken(target: target.id, present: false, sha256: nil, revision: nil), nil)
                }
                throw MCPPersistenceConflict.documentUnavailable(path: target.url.path, code: code)
            }
            defer { Darwin.close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw MCPPersistenceConflict.documentUnavailable(path: target.url.path, code: EINVAL)
            }
            guard maxBytes >= 0, maxBytes < Int.max else {
                throw MCPPersistenceConflict.documentTooLarge(path: target.url.path)
            }
            let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var hasher = SHA256()
            var bytes = Data()
            while bytes.count <= maxBytes {
                let chunk = try reader.read(upToCount: min(64 * 1024, maxBytes + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty {
                    var after = stat()
                    var current = stat()
                    let currentResult = target.name.withCString {
                        fstatat(target.parent, $0, &current, AT_SYMLINK_NOFOLLOW)
                    }
                    guard fstat(fd, &after) == 0, currentResult == 0,
                          current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino,
                          after.st_size == metadata.st_size,
                          after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
                          after.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
                          after.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec,
                          Int64(bytes.count) == Int64(after.st_size) else {
                        throw MCPPersistenceConflict.documentUnavailable(path: target.url.path, code: ESTALE)
                    }
                    let revision = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["revision"] as? Int
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    return (DocumentToken(target: target.id, present: true, sha256: digest, revision: revision), bytes)
                }
                hasher.update(data: chunk)
                bytes.append(chunk)
            }
            throw MCPPersistenceConflict.documentTooLarge(path: target.url.path)
        }

        func release() {
            guard !released else { return }
            released = true
            for (gate, fd) in acquired.reversed() {
                _ = flock(fd, LOCK_UN)
                _ = Darwin.close(fd)
                gate.lock.unlock()
            }
            acquired.removeAll()
            _ = Darwin.close(config.parent)
            _ = Darwin.close(authorization.parent)
        }
        deinit { release() }
    }

    static func acquire(configURL: URL, authorizationURL: URL) throws -> Lease {
        try Lease(configURL: configURL, authorizationURL: authorizationURL)
    }
}
