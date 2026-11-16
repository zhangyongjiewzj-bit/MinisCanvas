import Foundation

/// File operations needed by the credential metadata startup recovery seam.
///
/// Keeping the operations injectable lets callers handle cleanup failures as a
/// typed, non-fatal startup result without reading the contents of a pending
/// file.  The live implementation is deliberately limited to the directory
/// listing and removal operations required by recovery.
public protocol CredentialMetadataRecoveryFileSystem: Sendable {
    func contentsOfDirectory(at directory: URL) throws -> [URL]
    func removeItem(at url: URL) throws
}

public struct LiveCredentialMetadataRecoveryFileSystem: CredentialMetadataRecoveryFileSystem, Sendable {
    public init() {}

    public func contentsOfDirectory(at directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Startup-only recovery for metadata temp files left by an interrupted
/// credential publish.
///
/// The final metadata file is authoritative: recovery never parses, replaces,
/// or promotes a pending file.  Pending file contents are never opened, so a
/// crashed write cannot expose a credential through this path.  Cleanup errors
/// are returned as `Result.failure` and must be surfaced by the caller as a
/// controlled diagnostic rather than a process-fatal error.
public enum CredentialMetadataRecovery {
    /// Metadata-only presence state. It deliberately does not imply that a
    /// Keychain credential is readable; missing, locked, and invalid
    /// credential outcomes remain typed at the credential-read boundary.
    public enum MetadataState: String, Codable, Equatable, Sendable {
        case present
        case missing
    }

    public enum Status: Equatable, Sendable {
        case clean
        case removedOrphans
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidMetadataFileName
        case directoryUnreadable
        case cleanupFailed
    }

    /// Redacted recovery receipt.  It intentionally carries no path, file
    /// name, metadata value, or credential bytes.
    public struct Receipt: Equatable, Sendable {
        public let formalMetadataPresent: Bool
        public let orphanCount: Int
        public let cleanedOrphanCount: Int
        public let status: Status

        /// Stable metadata-only state for callers that must distinguish an
        /// absent formal file from a present one without opening its contents.
        public var metadataState: MetadataState {
            formalMetadataPresent ? .present : .missing
        }

        /// True when startup found no authoritative metadata file.  Pending
        /// files are never promoted to clear this condition.
        public var metadataRecoveryRequired: Bool { !formalMetadataPresent }

        public init(
            formalMetadataPresent: Bool,
            orphanCount: Int,
            cleanedOrphanCount: Int,
            status: Status
        ) {
            self.formalMetadataPresent = formalMetadataPresent
            self.orphanCount = orphanCount
            self.cleanedOrphanCount = cleanedOrphanCount
            self.status = status
        }
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else { return false }
        return URL(fileURLWithPath: fileName).lastPathComponent == fileName
    }

    private static func isDirectChild(_ child: URL, of directory: URL) -> Bool {
        child.absoluteURL.standardizedFileURL.deletingLastPathComponent().path == directory.path
    }

    /// Removes only direct-child pending files matching the exact metadata
    /// prefix.  A missing formal metadata file does not authorize promotion:
    /// it remains missing after this method returns.
    public static func recover(
        in directory: URL,
        metadataFileName: String = "envvars.json",
        fileSystem: any CredentialMetadataRecoveryFileSystem = LiveCredentialMetadataRecoveryFileSystem()
    ) -> Result<Receipt, Failure> {
        guard isSafeFileName(metadataFileName) else {
            return .failure(.invalidMetadataFileName)
        }

        let directory = directory.standardizedFileURL
        let children: [URL]
        do {
            children = try fileSystem.contentsOfDirectory(at: directory)
        } catch {
            return .failure(.directoryUnreadable)
        }

        let formalMetadataPresent = children.contains {
            $0.lastPathComponent == metadataFileName && isDirectChild($0, of: directory)
        }
        let pendingPrefix = ".\(metadataFileName).pending-"
        let orphanURLs = children.filter { child in
            isDirectChild(child, of: directory) &&
            child.lastPathComponent.hasPrefix(pendingPrefix) &&
            child.lastPathComponent.count > pendingPrefix.count
        }

        var cleanedOrphanCount = 0
        var cleanupFailed = false
        var seenOrphans = Set<String>()
        for orphanURL in orphanURLs {
            let canonicalPath = orphanURL.standardizedFileURL.path
            guard seenOrphans.insert(canonicalPath).inserted else { continue }
            do {
                try fileSystem.removeItem(at: orphanURL)
                cleanedOrphanCount += 1
            } catch {
                cleanupFailed = true
            }
        }

        guard !cleanupFailed else {
            return .failure(.cleanupFailed)
        }
        return .success(
            Receipt(
                formalMetadataPresent: formalMetadataPresent,
                orphanCount: orphanURLs.count,
                cleanedOrphanCount: cleanedOrphanCount,
                status: orphanURLs.isEmpty ? .clean : .removedOrphans
            )
        )
    }
}
