import Foundation
import Testing
@testable import MinisCore

@Suite("External session command templates")
struct ExternalSessionCommandTemplatesTests {
    private let id = "0197c2a4-1b2c-7d3e-8f40-5a6b7c8d9e0f"

    @Test
    func argvIsExactlyTheDeclaredTemplateAndNeverCarriesTheMessage() {
        let codex = ExternalSessionCommandTemplate.template(for: "codex")
        let claude = ExternalSessionCommandTemplate.template(for: "claude_code")
        #expect(codex?.argv(id) == ["exec", "resume", "--all", id, "-"])
        #expect(claude?.argv(id) == ["-p", "--resume", id])
        #expect(codex?.messageViaStdin == true)
        #expect(claude?.messageViaStdin == true)
    }

    @Test
    func noTemplateProducesPermissionWideningArguments() {
        for template in ExternalSessionCommandTemplate.all {
            let argv = template.argv(id)
            #expect(!ExternalSessionCommandTemplate.containsForbiddenArgument(argv),
                    "\(template.source) argv must not widen the peer's permissions")
        }
        // The guard itself must recognise the dangerous spellings.
        for bad in ["--dangerously-bypass-approvals-and-sandbox", "--yolo",
                    "bypassPermissions", "--permission-mode", "--dangerously-skip-permissions"] {
            #expect(ExternalSessionCommandTemplate.containsForbiddenArgument(["x", bad]))
        }
    }

    @Test
    func onlyTheTableKeysAreValidSources() {
        #expect(Set(ExternalSessionCommandTemplate.all.map(\.source)) == ["codex", "claude_code"])
        #expect(ExternalSessionCommandTemplate.template(for: "hermes") == nil)
        #expect(ExternalSessionCommandTemplate.template(for: "codex exec") == nil)
        #expect(ExternalSessionCommandTemplate.template(for: "") == nil)
    }

    @Test
    func binaryResolutionPicksFirstExecutableCandidateAndExpandsHome() {
        let home = "/Users/fixture"
        let codex = ExternalSessionCommandTemplate.codex
        // Second candidate ($HOME) beats the third when the first is absent.
        let both: Set<String> = ["/Users/fixture/.local/bin/codex", "/usr/local/bin/codex"]
        #expect(codex.resolveBinary(home: home, isExecutable: { both.contains($0) })
                == "/Users/fixture/.local/bin/codex")
        // The first candidate wins when everything exists.
        let all: Set<String> = ["/opt/homebrew/bin/codex", "/Users/fixture/.local/bin/codex",
                                "/usr/local/bin/codex"]
        #expect(codex.resolveBinary(home: home, isExecutable: { all.contains($0) })
                == "/opt/homebrew/bin/codex")
        // Nothing executable: not found, no PATH fallback.
        #expect(codex.resolveBinary(home: home, isExecutable: { _ in false }) == nil)
    }

    @Test
    func homeLocalBinIsResolvedAgainstARealExecutableFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("send-home-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        #expect(ExternalSessionCommandTemplate.claudeCode.resolveBinary(home: home.path) == claude.path)
        // A non-executable file of the same name is not a candidate.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: claude.path)
        #expect(ExternalSessionCommandTemplate.claudeCode.resolveBinary(home: home.path)
                .map { $0 != claude.path } ?? true)
    }
}
