//
//  SkillFilesystemBoundary.swift
//  MinisCore
//
//  Shared admission checks for local skill discovery.  Discovery is a
//  fail-closed projection: an item is either a regular file below the exact
//  approved root or it is omitted without exposing its filesystem path.
//

import Darwin
import Foundation

/// Filesystem trust boundary used by the App skill catalog and the Core store.
///
/// The methods intentionally return predicates instead of path-bearing errors.
/// A rejected local entry therefore cannot turn an absolute path into a user
/// diagnostic or a picker item.
public enum SkillFilesystemBoundary {
    /// The filesystem identity of an approved root. A path alone is not a
    /// scope: replacing the directory at that path must invalidate the scan.
    public struct RootIdentity: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        fileprivate init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// The device/inode identity of one admitted catalog entry path. It is
    /// checked again after the descriptor read so a renamed directory or file
    /// cannot silently become a different skill entry.
    public struct EntryIdentity: Equatable, Sendable {
        public let device: UInt64
        public let inode: UInt64

        fileprivate init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    /// Manifests are metadata, not arbitrary archives. Keep the limit small
    /// enough that discovery cannot ingest an unbounded JSON document.
    public static let maxManifestBytes = 64 * 1024

    /// C0, DEL, and C1 controls are not valid names for a discovered skill.
    public static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    /// Validate a single filesystem name before it becomes a path component.
    public static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !containsControlCharacters(value)
        else { return false }
        return true
    }

    /// Validate a display name without imposing the path-component rules used
    /// for directory names.
    public static func isSafeDisplayName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !containsControlCharacters(value)
    }

    /// The root itself must be an existing, ordinary directory with no
    /// symlink at its leaf. System aliases above the root (for example
    /// macOS's `/var`) are part of the resolved trust anchor and are not
    /// treated as skill-owned symlink chains.
    public static func isApprovedRoot(_ root: URL) -> Bool {
        guard root.isFileURL,
              !containsParentTraversal(root),
              let values = try? URL(fileURLWithPath: root.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        var metadata = stat()
        guard Darwin.lstat(root.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_ino != 0 else { return false }
        return true
    }

    /// Capture the root's inode after admission. Callers should retain this
    /// value for the complete scan and compare it before every entry read.
    public static func approvedRootIdentity(_ root: URL) -> RootIdentity? {
        guard isApprovedRoot(root) else { return nil }
        var metadata = stat()
        guard Darwin.lstat(root.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_ino != 0 else { return nil }
        return RootIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    /// Validate that the path still names the exact root captured before the
    /// scan. A replacement ordinary directory therefore fails closed even if
    /// its textual path and canonical descendants look in scope.
    public static func isApprovedRoot(_ root: URL, matching identity: RootIdentity) -> Bool {
        guard let current = approvedRootIdentity(root) else { return false }
        return current == identity
    }

    /// Admit a directory only when its canonical path remains below the
    /// approved root and neither path uses a symlink chain.
    public static func isTrustedDirectory(_ directory: URL, within root: URL) -> Bool {
        guard isApprovedRoot(root),
              directory.isFileURL,
              !containsParentTraversal(directory),
              !containsSymlinkBelowRoot(directory, root: root),
              let values = try? URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        return isCanonicallyContained(directory, in: root)
    }

    /// Capture an admitted skill directory identity before reading its files.
    public static func trustedDirectoryIdentity(
        _ directory: URL,
        within root: URL
    ) -> EntryIdentity? {
        guard isTrustedDirectory(directory, within: root) else { return nil }
        return entryIdentity(directory, expectedType: mode_t(S_IFDIR))
    }

    /// Revalidate the exact directory captured before a catalog read.
    public static func isTrustedDirectory(
        _ directory: URL,
        within root: URL,
        matching identity: EntryIdentity
    ) -> Bool {
        guard let current = trustedDirectoryIdentity(directory, within: root) else { return false }
        return current == identity
    }

    /// Admit a regular file below the approved root, optionally enforcing a
    /// byte budget before the caller reads it.
    public static func isTrustedRegularFile(
        _ file: URL,
        within root: URL,
        maximumBytes: Int? = nil
    ) -> Bool {
        guard isApprovedRoot(root),
              file.isFileURL,
              !containsParentTraversal(file),
              !containsSymlinkBelowRoot(file, root: root),
              let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              isCanonicallyContained(file, in: root)
        else { return false }
        if let maximumBytes {
            guard let size = values.fileSize, size <= maximumBytes else { return false }
        }
        return true
    }

    /// Capture an admitted regular-file identity before opening its bytes.
    public static func trustedRegularFileIdentity(
        _ file: URL,
        within root: URL,
        maximumBytes: Int? = nil
    ) -> EntryIdentity? {
        guard isTrustedRegularFile(file, within: root, maximumBytes: maximumBytes) else { return nil }
        return entryIdentity(file, expectedType: mode_t(S_IFREG))
    }

    /// Revalidate the exact regular file captured before a catalog read.
    public static func isTrustedRegularFile(
        _ file: URL,
        within root: URL,
        maximumBytes: Int? = nil,
        matching identity: EntryIdentity
    ) -> Bool {
        guard let current = trustedRegularFileIdentity(
            file,
            within: root,
            maximumBytes: maximumBytes
        ) else { return false }
        return current == identity
    }

    /// Admit a skill directory and, when present, its optional manifest.
    /// A symlink, non-regular manifest, or oversized manifest invalidates the
    /// whole entry so discovery cannot consume a partial projection.
    public static func isTrustedSkillDirectory(_ directory: URL, within root: URL) -> Bool {
        guard isTrustedDirectory(directory, within: root) else { return false }
        let manifest = directory.appendingPathComponent("manifest.json")
        guard !containsSymlinkBelowRoot(manifest, root: root) else { return false }
        guard FileManager.default.fileExists(atPath: manifest.path) else { return true }
        return isTrustedRegularFile(
            manifest,
            within: root,
            maximumBytes: maxManifestBytes
        )
    }

    /// Canonical containment uses a path-boundary separator, so `/skills2`
    /// cannot be mistaken for a child of `/skills`.
    public static func isCanonicallyContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func containsParentTraversal(_ url: URL) -> Bool {
        url.pathComponents.contains("..")
    }

    private static func entryIdentity(_ url: URL, expectedType: mode_t) -> EntryIdentity? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == expectedType,
              metadata.st_ino != 0 else { return nil }
        return EntryIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    /// `URLResourceValues.isSymbolicLink` on the leaf alone misses a symlinked
    /// child directory. Walk every component below the approved root so a
    /// chain that points back inside the root is rejected as well as one that
    /// escapes it.
    private static func containsSymlinkBelowRoot(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return true }
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        guard candidateComponents.starts(with: rootComponents) else { return false }
        var current = root.standardizedFileURL
        for component in candidateComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            if (try? URL(fileURLWithPath: current.path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
        }
        return false
    }
}
