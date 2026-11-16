import Foundation
import Testing
import CryptoKit
@testable import MinisCore

@Suite("Trusted project instruction files")
struct TrustedProjectInstructionLoadingTests {
    private func root() throws -> URL {
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw FormalTestIsolationPaths.IsolationError.missingContract
        }
        let root = paths.rootDirectory.appendingPathComponent("M01-synthetic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ text: String, _ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func priorityAndFallbacks() throws {
        for preferred in ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md"] {
            let root = try root()
            try write("nested", ".claude/CLAUDE.md", root: root)
            if preferred != ".claude/CLAUDE.md" { try write("claude", "CLAUDE.md", root: root) }
            if preferred == "AGENTS.md" { try write("agents", "AGENTS.md", root: root) }
            let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
            #expect(loaded.loadedRelativePaths == [preferred])
            let originalBytes = try Data(contentsOf: root.appendingPathComponent(preferred))
            let expectedHash = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
            #expect(loaded.sourceFileSHA256 == [preferred: expectedHash])
            #expect(loaded.rootDirectoryIdentity != nil)
            #expect(loaded.redactingText { _ in "redacted" }.sourceFileSHA256 == loaded.sourceFileSHA256)
            try write("changed after snapshot", preferred, root: root)
            let changed = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
            #expect(changed.sourceFileSHA256 != loaded.sourceFileSHA256)
            #expect(!loaded.systemPromptPrefix.contains("changed after snapshot"))
        }
        let repeatedRoot = try root()
        try write("@rules.md\n@rules.md", "AGENTS.md", root: repeatedRoot)
        try write("repeated frozen source", "rules.md", root: repeatedRoot)
        let repeated = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: repeatedRoot))
        #expect(repeated.loadedRelativePaths == ["AGENTS.md", "rules.md", "rules.md"])
        #expect(repeated.sourceFileSHA256.count == 2)
        #expect(repeated.systemPromptPrefix.components(separatedBy: "repeated frozen source").count == 3)
    }

    @Test func importsStopAtFourLevelsAndStayInsideRoot() throws {
        let root = try root()
        try write("@rules/one.md\n@../outside.md", "CLAUDE.md", root: root)
        try write("@two.md\none", "rules/one.md", root: root)
        try write("@three.md\ntwo", "rules/two.md", root: root)
        try write("@four.md\nthree", "rules/three.md", root: root)
        try write("@five.md\n@../CLAUDE.md\nfour", "rules/four.md", root: root)
        try write("fifth level", "rules/five.md", root: root)
        let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(loaded.loadedRelativePaths == ["CLAUDE.md", "rules/one.md", "rules/two.md", "rules/three.md", "rules/four.md"])
        #expect(!loaded.systemPromptPrefix.contains("fifth level"))
        #expect(Set(loaded.sourceFileSHA256.keys) == Set(loaded.loadedRelativePaths))
    }

    @Test func symlinkComponentsAndAggregateSizeAreBoundaries() throws {
        let root = try root()
        let outside = try self.root()
        try write("outside", "external.md", root: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("direct.md"), withDestinationURL: outside.appendingPathComponent("external.md"))
        try write("@linked/external.md\n@direct.md\n@large.md\nroot", "AGENTS.md", root: root)
        try write(String(repeating: "x", count: TrustedProjectInstructions.maxBytes), "large.md", root: root)
        let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(loaded.loadedRelativePaths == ["AGENTS.md"])
        #expect(loaded.systemPromptPrefix.contains("root"))
        // A physical root remains required: the descriptor walk must not
        // follow a caller-created root alias, just as it rejects imports above.
        let linkedRoot = root.appendingPathComponent("root-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        #expect((try? TrustedProjectInstructions.loadSnapshot(atTrustedRoot: linkedRoot))?.systemPromptPrefix == nil)
        let relative = URL(fileURLWithPath: root.lastPathComponent, isDirectory: true, relativeTo: root.deletingLastPathComponent())
        #expect((try? TrustedProjectInstructions.loadSnapshot(atTrustedRoot: relative))?.systemPromptPrefix == nil)
        let dotted = try #require(URL(string: root.absoluteString + "./"))
        let parentTraversal = try #require(URL(string: root.absoluteString + "../" + root.lastPathComponent + "/"))
        #expect((try? TrustedProjectInstructions.loadSnapshot(atTrustedRoot: dotted))?.systemPromptPrefix == nil)
        #expect((try? TrustedProjectInstructions.loadSnapshot(atTrustedRoot: parentTraversal))?.systemPromptPrefix == nil)
    }
}
