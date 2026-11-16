//
//  SkillCatalogFileSnapshot.swift
//  MinisCore
//
//  Descriptor-anchored reads for the App/Hermes skill discovery callers.
//  Boundary checks alone are insufficient when a path can be replaced between
//  validation and read; this helper binds every accepted byte to its opened
//  regular-file identity and rejects an unstable path.
//

import Darwin
import Foundation

/// A bounded, UTF-8 decoded SKILL.md plus its optional sidecar manifest.
/// No source path is retained in the snapshot or in a read failure.
public struct SkillCatalogFileSnapshot: Equatable, Sendable {
    public let content: String
    public let manifestData: Data?
    public let contentByteCount: Int
    public let manifestByteCount: Int

    /// Read a skill directory through O_NOFOLLOW descriptors and bind the
    /// result to stable file identities before returning it to a catalog scan.
    /// The optional manifest is accepted only when absent or independently
    /// proven to be a bounded regular file below the same trusted directory.
    public static func read(
        skillDirectory: URL,
        within root: URL,
        maxSkillBytes: Int = SkillStore.maxSkillContentBytes,
        maxManifestBytes: Int = SkillFilesystemBoundary.maxManifestBytes,
        expectedRootIdentity: SkillFilesystemBoundary.RootIdentity? = nil,
        expectedSkillDirectoryIdentity: SkillFilesystemBoundary.EntryIdentity? = nil,
        expectedSkillFileIdentity: SkillFilesystemBoundary.EntryIdentity? = nil
    ) -> SkillCatalogFileSnapshot? {
        guard let rootIdentity = expectedRootIdentity ?? SkillFilesystemBoundary.approvedRootIdentity(root),
              SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity),
              maxSkillBytes >= 0,
              maxManifestBytes >= 0,
              let skillDirectoryIdentity = expectedSkillDirectoryIdentity
                  ?? SkillFilesystemBoundary.trustedDirectoryIdentity(skillDirectory, within: root),
              SkillFilesystemBoundary.isTrustedDirectory(
                  skillDirectory,
                  within: root,
                  matching: skillDirectoryIdentity
              ),
              SkillFilesystemBoundary.isTrustedSkillDirectory(skillDirectory, within: root)
        else { return nil }

        let skillURL = skillDirectory.appendingPathComponent("SKILL.md")
        guard let skillFileIdentity = expectedSkillFileIdentity
                ?? SkillFilesystemBoundary.trustedRegularFileIdentity(
                    skillURL,
                    within: root,
                    maximumBytes: maxSkillBytes
                ),
              SkillFilesystemBoundary.isTrustedDirectory(
                  skillDirectory,
                  within: root,
                  matching: skillDirectoryIdentity
              ),
              SkillFilesystemBoundary.isTrustedRegularFile(
                  skillURL,
                  within: root,
                  maximumBytes: maxSkillBytes,
                  matching: skillFileIdentity
              ),
              case .bytes(let contentData) = readData(
                  at: skillURL,
                  maximumBytes: maxSkillBytes,
                  required: true,
                  expectedIdentity: skillFileIdentity
              ),
        let content = String(data: contentData, encoding: .utf8)
        else { return nil }

        let manifestURL = skillDirectory.appendingPathComponent("manifest.json")
        let manifestPresent = FileManager.default.fileExists(atPath: manifestURL.path)
        let manifestIdentity: SkillFilesystemBoundary.EntryIdentity?
        if manifestPresent {
            guard let identity = SkillFilesystemBoundary.trustedRegularFileIdentity(
                manifestURL,
                within: root,
                maximumBytes: maxManifestBytes
            ) else { return nil }
            manifestIdentity = identity
        } else {
            manifestIdentity = nil
        }
        let manifestData: Data?
        switch readData(
            at: manifestURL,
            maximumBytes: maxManifestBytes,
            required: false,
            expectedIdentity: manifestIdentity,
            expectedMissing: !manifestPresent
        ) {
        case .missing:
            manifestData = nil
        case .bytes(let data):
            // A manifest is a UTF-8 JSON sidecar. Reject an in-budget byte
            // sequence that cannot be decoded before it reaches any catalog
            // identity or presentation consumer.
            guard String(data: data, encoding: .utf8) != nil else { return nil }
            manifestData = data
        case .rejected:
            return nil
        }

        // Revalidate the path boundary after descriptor reads. A path swap is
        // therefore rejected even when the replacement happens during the
        // manifest read; the caller receives one coherent safe snapshot.
        guard SkillFilesystemBoundary.isApprovedRoot(root, matching: rootIdentity),
              SkillFilesystemBoundary.isTrustedDirectory(
                  skillDirectory,
                  within: root,
                  matching: skillDirectoryIdentity
              ),
              SkillFilesystemBoundary.isTrustedSkillDirectory(skillDirectory, within: root),
              SkillFilesystemBoundary.isTrustedRegularFile(
                  skillURL,
                  within: root,
                  maximumBytes: maxSkillBytes,
                  matching: skillFileIdentity
              ),
              manifestIdentity == nil
                  || SkillFilesystemBoundary.isTrustedRegularFile(
                      manifestURL,
                      within: root,
                      maximumBytes: maxManifestBytes,
                      matching: manifestIdentity!
                  ),
              manifestData != nil || !FileManager.default.fileExists(atPath: manifestURL.path)
        else { return nil }

        return SkillCatalogFileSnapshot(
            content: content,
            manifestData: manifestData,
            contentByteCount: contentData.count,
            manifestByteCount: manifestData?.count ?? 0
        )
    }

    private enum ReadResult {
        case bytes(Data)
        case missing
        case rejected
    }

    private static func readData(
        at url: URL,
        maximumBytes: Int,
        required: Bool,
        expectedIdentity: SkillFilesystemBoundary.EntryIdentity? = nil,
        expectedMissing: Bool = false
    ) -> ReadResult {
        var initialInfo = stat()
        guard Darwin.lstat(url.path, &initialInfo) == 0 else {
            return required || expectedIdentity != nil || !expectedMissing ? .rejected : .missing
        }
        guard !expectedMissing,
              isStableRegularFile(initialInfo, maximumBytes: maximumBytes),
              expectedIdentity.map({ sameIdentity(initialInfo, $0) }) ?? true else { return .rejected }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .rejected }
        defer { _ = Darwin.close(descriptor) }

        var openedInfo = stat()
        guard Darwin.fstat(descriptor, &openedInfo) == 0,
              isStableRegularFile(openedInfo, maximumBytes: maximumBytes),
              sameIdentity(initialInfo, openedInfo),
              expectedIdentity.map({ sameIdentity(openedInfo, $0) }) ?? true else { return .rejected }

        let byteCount = Int(openedInfo.st_size)
        var data = Data(count: byteCount)
        let readAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        guard readAll else { return .rejected }

        var finalInfo = stat()
        var finalPathInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              Darwin.lstat(url.path, &finalPathInfo) == 0,
              isStableRegularFile(finalInfo, maximumBytes: maximumBytes),
              isStableRegularFile(finalPathInfo, maximumBytes: maximumBytes),
              sameIdentity(initialInfo, openedInfo),
              sameIdentity(openedInfo, finalInfo),
              sameIdentity(initialInfo, finalPathInfo),
              expectedIdentity.map({ sameIdentity(finalInfo, $0) }) ?? true,
              expectedIdentity.map({ sameIdentity(finalPathInfo, $0) }) ?? true,
              finalInfo.st_size == Int64(data.count),
              finalPathInfo.st_size == Int64(data.count)
        else { return .rejected }
        return .bytes(data)
    }

    private static func isStableRegularFile(_ info: stat, maximumBytes: Int) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_nlink == 1
            && info.st_size >= 0
            && info.st_size <= Int64(maximumBytes)
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameIdentity(
        _ info: stat,
        _ identity: SkillFilesystemBoundary.EntryIdentity
    ) -> Bool {
        UInt64(info.st_dev) == identity.device && UInt64(info.st_ino) == identity.inode
    }
}
