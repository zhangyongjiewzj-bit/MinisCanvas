import Foundation
import Testing
@testable import MinisCore

/// W-b: the Settings first-mount notice uses the same qualification as the
/// read tool. Status: 未运行 (not compiled when written).
@Suite("External session mount disclosure")
struct ExternalSessionMountDisclosureTests {
    @Test func qualifyingRootsRequireDisclosure() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        #expect(ExternalSessionMountQualification.requiresDisclosure(forMountedPath: home.codexRoot.path))
        #expect(ExternalSessionMountQualification.requiresDisclosure(forMountedPath: home.claudeRoot.path))
    }

    @Test func parentDirectoriesDoNotRequireDisclosure() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        for path in [home.url.path, home.url.appendingPathComponent(".codex").path,
                     home.url.appendingPathComponent(".claude").path] {
            #expect(!ExternalSessionMountQualification.requiresDisclosure(forMountedPath: path), "\(path)")
        }
    }

    @Test func disclosureAgreesWithReadToolQualificationForSymlinks() throws {
        let home = try ExtFixture.Home()
        defer { home.remove() }
        // (1) A link with an arbitrary name pointing at the real root: not a
        // qualifying mount for the tools (suffix is the link name), so no notice.
        let namedLink = home.url.appendingPathComponent("my-sessions")
        try FileManager.default.createSymbolicLink(at: namedLink, withDestinationURL: home.codexRoot)
        // (2) A ".codex/sessions"-named symlink to another directory: rejected (lstat not a directory).
        let target = home.url.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let aliasHome = home.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let aliasRoot = aliasHome.appendingPathComponent(".codex/sessions")
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: target)
        // (3) The real root reached through a symlinked parent: qualifies for the tools, so notice required.
        let viaParentLink = home.url.appendingPathComponent("linkedhome")
        try FileManager.default.createSymbolicLink(at: viaParentLink, withDestinationURL: home.url)
        let viaParent = viaParentLink.appendingPathComponent(".codex/sessions")

        for path in [namedLink.path, aliasRoot.path, viaParent.path, home.codexRoot.path, home.url.path] {
            #expect(ExternalSessionMountQualification.requiresDisclosure(forMountedPath: path)
                == ExternalSessionMountQualification.isQualifyingMount(path), "\(path)")
        }
        #expect(!ExternalSessionMountQualification.requiresDisclosure(forMountedPath: namedLink.path))
        #expect(!ExternalSessionMountQualification.requiresDisclosure(forMountedPath: aliasRoot.path))
        #expect(ExternalSessionMountQualification.requiresDisclosure(forMountedPath: viaParent.path))
    }
}
