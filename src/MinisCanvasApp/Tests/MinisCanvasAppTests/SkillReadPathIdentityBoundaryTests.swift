import Darwin
import Foundation
import Testing
@testable import MinisCore

private final class SkillReadOneShotMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () throws -> Void)?
    private var ran = false
    private var failure: String?

    func arm(_ action: @escaping @Sendable () throws -> Void) {
        lock.withLock { self.action = action }
    }

    func observe(_ access: SkillStoreFilesystemAccess) {
        guard case .fileRead = access else { return }
        let next = lock.withLock { () -> (@Sendable () throws -> Void)? in
            guard let action else { return nil }
            self.action = nil
            ran = true
            return action
        }
        do { try next?() }
        catch { lock.withLock { failure = String(describing: error) } }
    }

    var didRun: Bool { lock.withLock { ran } }
    var failed: Bool { lock.withLock { failure != nil } }
}

@Suite("skill read path identity boundary", .serialized)
struct SkillReadPathIdentityBoundaryTests {
    private struct Fixture {
        let parent: URL
        let root: URL
        let store: SkillStore
        let skillID: String
        let directory: URL
        let file: URL
        let content = "---\nname: Read Boundary\nversion: 1.0.0\n---\nSYNTHETIC_READ_BOUNDARY_BODY"

        init(observer: SkillStoreFilesystemAccessObserver? = nil) throws {
            let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
            let parent = paths.rootDirectory.appendingPathComponent("skill-read-\(UUID().uuidString)", isDirectory: true)
            let root = parent.appendingPathComponent("skills", isDirectory: true)
            let payload = "---\nname: Read Boundary\nversion: 1.0.0\n---\nSYNTHETIC_READ_BOUNDARY_BODY"
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let store = SkillStore(skillsRoot: root, filesystemAccessObserver: observer)
            let skill = try store.importSkill(content: payload, source: .file)
            self.parent = parent
            self.root = root
            self.store = store
            self.skillID = skill.id
            self.directory = store.skillDirectoryURL(for: skill.id)
            self.file = self.directory.appendingPathComponent("SKILL.md")
        }
    }

    @Test("canonical data-volume alias reads the same inode and keeps captured skill content")
    func canonicalAliasReadAndSnapshot() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        // R4 may supply the public spelling. Build the physical Data-volume
        // alias explicitly instead of requiring the runner to supply that alias.
        let dataPrefix = "/System/Volumes/Data"
        let physicalRoot = fixture.root.resolvingSymlinksInPath().path
        let publicPath = physicalRoot.hasPrefix(dataPrefix + "/")
            ? String(physicalRoot.dropFirst(dataPrefix.count)) : physicalRoot
        let publicRoot = URL(fileURLWithPath: publicPath, isDirectory: true)
        let aliasRoot = URL(fileURLWithPath: dataPrefix + publicRoot.path, isDirectory: true)
        let aliasStore = SkillStore(skillsRoot: aliasRoot)
        let aliasFile = aliasRoot.appendingPathComponent(fixture.skillID).appendingPathComponent("SKILL.md")
        let resolved = publicRoot.appendingPathComponent(fixture.skillID).appendingPathComponent("SKILL.md")
        var originalInfo = stat()
        var resolvedInfo = stat()
        #expect(lstat(aliasFile.path, &originalInfo) == 0)
        #expect(lstat(resolved.path, &resolvedInfo) == 0)
        #expect(originalInfo.st_dev == resolvedInfo.st_dev && originalInfo.st_ino == resolvedInfo.st_ino)
        #expect(aliasFile.path != resolved.path)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == fixture.content)
        #expect(aliasStore.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == fixture.content)
        let snapshot = aliasStore.snapshot()
        #expect(snapshot.rawContents[fixture.skillID] == fixture.content)
        #expect(snapshot.fileContents[fixture.skillID]?["SKILL.md"] == fixture.content)
    }

    @Test("absolute traversal and same-prefix sibling paths remain rejected")
    func outsideAndSiblingPathsRejected() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let sibling = fixture.root.appendingPathComponent(fixture.skillID + "-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outside = sibling.appendingPathComponent("SKILL.md")
        try "SYNTHETIC_OUTSIDE_BODY".write(to: outside, atomically: true, encoding: .utf8)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: outside.path) == nil)
        #expect(fixture.store.readSkillFile(fixture.skillID,
            relativePath: "../" + fixture.skillID + "-sibling/SKILL.md") == nil)
        let link = fixture.directory.appendingPathComponent("same-prefix.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "same-prefix.md") == nil)
    }

    @Test("owned file directory and root symlinks are rejected including links back inside")
    func symlinkComponentsRejected() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let references = fixture.directory.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let reference = references.appendingPathComponent("api.md")
        try "SYNTHETIC_REFERENCE".write(to: reference, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("inside.md"),
                                                 withDestinationURL: reference)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("linked-references"),
                                                 withDestinationURL: references)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "inside.md") == nil)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "linked-references/api.md") == nil)
        let saved = fixture.parent.appendingPathComponent("saved-skills", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: saved)
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == nil)
    }

    @Test("hardlinked skill files cannot provide a root-bound read")
    func hardlinkedFileRejected() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.linkItem(at: fixture.file, to: fixture.parent.appendingPathComponent("other-link.md"))
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == nil)
    }

    @Test("root replacement between admission and descriptor read fails closed")
    func rootReplacementDuringReadRejected() throws {
        let mutation = SkillReadOneShotMutation()
        let fixture = try Fixture(observer: { mutation.observe($0) })
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let root = fixture.root
        let saved = fixture.parent.appendingPathComponent("previous-skills", isDirectory: true)
        let replacementDirectory = root.appendingPathComponent(fixture.skillID, isDirectory: true)
        let content = fixture.content
        mutation.arm {
            try FileManager.default.moveItem(at: root, to: saved)
            try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
            try content.write(to: replacementDirectory.appendingPathComponent("SKILL.md"),
                              atomically: true, encoding: .utf8)
        }
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == nil)
        #expect(mutation.didRun && !mutation.failed)
    }

    @Test("file replacement after admission cannot change the returned bytes")
    func fileReplacementDuringReadRejected() throws {
        let mutation = SkillReadOneShotMutation()
        let fixture = try Fixture(observer: { mutation.observe($0) })
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let file = fixture.file
        let saved = fixture.parent.appendingPathComponent("previous-file.md")
        mutation.arm {
            try FileManager.default.moveItem(at: file, to: saved)
            try "SYNTHETIC_REPLACEMENT_BODY".write(to: file, atomically: true, encoding: .utf8)
        }
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "SKILL.md") == nil)
        #expect(mutation.didRun && !mutation.failed)
    }

    @Test("an intermediate-directory swap to an outside symlink cannot be read")
    func directorySwapDuringReadRejected() throws {
        let mutation = SkillReadOneShotMutation()
        let fixture = try Fixture(observer: { mutation.observe($0) })
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let references = fixture.directory.appendingPathComponent("references", isDirectory: true)
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        let saved = fixture.parent.appendingPathComponent("previous-references", isDirectory: true)
        for directory in [references, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "SYNTHETIC_REFERENCE".write(to: directory.appendingPathComponent("api.md"),
                                          atomically: true, encoding: .utf8)
        }
        mutation.arm {
            try FileManager.default.moveItem(at: references, to: saved)
            try FileManager.default.createSymbolicLink(at: references, withDestinationURL: outside)
        }
        #expect(fixture.store.readSkillFile(fixture.skillID, relativePath: "references/api.md") == nil)
        #expect(mutation.didRun && !mutation.failed)
    }
}
