import Foundation
import Testing
import Darwin
@testable import MinisCanvasApp

/// R10: direct contract of the pure mount filter (depends on the new function).
@MainActor
struct DisposableExternalSessionMounts_R10_Tests_Unit {
    private func fixtureRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("R10unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: realPath(raw.path), isDirectory: true)
    }

    private func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func filter(_ paths: [String], container: URL, denied: [URL] = []) -> [String] {
        ProductionOrchestrationDefaults.disposableExternalSessionMountedRoots(
            mountedFolderPaths: paths, container: container, deniedRoots: denied
        ).map(\.path)
    }

    @Test func journeyLimitsMountsToWorkspace() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let inside = workspace.appendingPathComponent("h/.codex/sessions")
        let beside = root.appendingPathComponent("h/.codex/sessions")
        try makeDir(inside)
        try makeDir(beside)
        #expect(filter([inside.path, beside.path], container: workspace) == [inside.path])
        #expect(Set(filter([inside.path, beside.path], container: root)) == [inside.path, beside.path])
    }

    @Test func deniedRootCoveringMountIsDropped() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("deniedhome", isDirectory: true)
        let covered = denied.appendingPathComponent(".claude/projects")
        let freeDir = root.appendingPathComponent("ok/.claude/projects")
        try makeDir(covered)
        try makeDir(freeDir)
        #expect(filter([covered.path, freeDir.path], container: root, denied: [denied]) == [freeDir.path])
    }

    @Test func outOfRootSymlinkedAndNonQualifyingAreDropped() throws {
        let root = try fixtureRoot()
        let outside = try fixtureRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try makeDir(outside.appendingPathComponent(".codex/sessions"))
        try makeDir(root.appendingPathComponent("p/.codex/sessions"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let paths = [
            outside.appendingPathComponent(".codex/sessions").path,
            link.appendingPathComponent(".codex/sessions").path,
            root.path,
            root.appendingPathComponent("p/.codex").path,
            "relative/.codex/sessions"
        ]
        #expect(filter(paths, container: root).isEmpty)
    }
}
