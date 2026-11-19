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

    /// 只看项目根内的相对路径；测试目录之上的真实文件（例如开发机的仓库 CLAUDE.md）不参与断言。
    private func inRoot(_ snapshot: TrustedProjectInstructionSnapshot) -> [String] {
        snapshot.loadedRelativePaths.filter { !$0.hasPrefix("/") }
    }

    @Test func rootFilesAreAllLoadedInOrder() throws {
        let root = try root()
        try write("nested", ".claude/CLAUDE.md", root: root)
        try write("claude", "CLAUDE.md", root: root)
        try write("agents", "AGENTS.md", root: root)
        try write("local", "CLAUDE.local.md", root: root)
        let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(inRoot(loaded) == ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"])
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("AGENTS.md"))
        let expectedHash = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        #expect(loaded.sourceFileSHA256["AGENTS.md"] == expectedHash)
        #expect(loaded.rootDirectoryIdentity != nil)
        #expect(loaded.redactingText { _ in "redacted" }.sourceFileSHA256 == loaded.sourceFileSHA256)
        try write("changed after snapshot", "AGENTS.md", root: root)
        let changed = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(changed.sourceFileSHA256 != loaded.sourceFileSHA256)
        #expect(!loaded.systemPromptPrefix.contains("changed after snapshot"))
        let repeatedRoot = try self.root()
        try write("@rules.md\n@rules.md", "AGENTS.md", root: repeatedRoot)
        try write("repeated frozen source", "rules.md", root: repeatedRoot)
        let repeated = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: repeatedRoot))
        #expect(inRoot(repeated) == ["AGENTS.md", "rules.md", "rules.md"])
        #expect(repeated.sourceFileSHA256.keys.filter { !$0.hasPrefix("/") }.count == 2)
        #expect(repeated.systemPromptPrefix.components(separatedBy: "repeated frozen source").count == 3)
    }

    @Test func parentDirectoriesAndUserFileMergeUserFirstProjectLast() throws {
        let outer = try root()
        let project = outer.appendingPathComponent("child/project", isDirectory: true)
        let home = try self.root()
        try write("outer rule", "CLAUDE.md", root: outer)
        try write("middle rule", "child/AGENTS.md", root: outer)
        try write("project rule", "child/project/CLAUDE.md", root: outer)
        try write("user rule", ".claude/CLAUDE.md", root: home)
        let report = try TrustedProjectInstructions.loadReport(atTrustedRoot: project, userHome: home)
        let snapshot = try #require(report.snapshot)
        let text = snapshot.systemPromptPrefix
        let user = try #require(text.range(of: "user rule"))
        let outerRange = try #require(text.range(of: "outer rule"))
        let middle = try #require(text.range(of: "middle rule"))
        let own = try #require(text.range(of: "project rule"))
        #expect(user.lowerBound < outerRange.lowerBound)
        #expect(outerRange.lowerBound < middle.lowerBound)
        #expect(middle.lowerBound < own.lowerBound)
        #expect(text.contains("[Project instruction file: \(outer.path)/CLAUDE.md]"))
        #expect(snapshot.loadedRelativePaths.last == "CLAUDE.md")
    }

    @Test func linksOversizeAndLegacyEncodingStillLoadWithExplanation() throws {
        let root = try root()
        try write("real instructions", "docs/real.md", root: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("CLAUDE.md"), withDestinationURL: root.appendingPathComponent("docs/real.md"))
        try write("TAIL" + String(repeating: "x", count: TrustedProjectInstructions.maxBytes), "AGENTS.md", root: root)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let legacy = try #require("项目规则：中文说明".data(using: gb))
        try legacy.write(to: root.appendingPathComponent("CLAUDE.local.md"))
        let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(inRoot(loaded) == ["AGENTS.md", "CLAUDE.md", "CLAUDE.local.md"])
        #expect(loaded.systemPromptPrefix.contains("real instructions"))
        #expect(loaded.systemPromptPrefix.contains("项目规则：中文说明"))
        #expect(loaded.systemPromptPrefix.contains("仅加载了前 64 KB"))
    }

    @Test func projectWithoutInstructionFilesReportsNothingSkipped() throws {
        let root = try root()
        let report = try TrustedProjectInstructions.loadReport(atTrustedRoot: root, userHome: try self.root())
        #expect(report.skipped.isEmpty)
        #expect(report.snapshot == nil || report.snapshot?.loadedRelativePaths.allSatisfy { $0.hasPrefix("/") } == true)
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
        #expect(inRoot(loaded) == ["CLAUDE.md", "rules/one.md", "rules/two.md", "rules/three.md", "rules/four.md"])
        #expect(!loaded.systemPromptPrefix.contains("fifth level"))
        #expect(Set(loaded.sourceFileSHA256.keys) == Set(loaded.loadedRelativePaths))
    }

    @Test func symlinkOutsideReadableRangeAndRootAliasAreBoundaries() throws {
        let root = try root()
        let outside = try self.root()
        try write("outside", "external.md", root: outside)
        // /etc 不在项目根、~/.claude 或家目录的普通位置内：符号链接不会被跟随。
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("direct.md"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        try write("@linked/hosts\n@direct.md\nroot", "AGENTS.md", root: root)
        let loaded = try #require(try TrustedProjectInstructions.loadSnapshot(atTrustedRoot: root))
        #expect(inRoot(loaded) == ["AGENTS.md"])
        #expect(loaded.systemPromptPrefix.contains("root"))
        #expect(!loaded.systemPromptPrefix.contains("localhost"))
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
