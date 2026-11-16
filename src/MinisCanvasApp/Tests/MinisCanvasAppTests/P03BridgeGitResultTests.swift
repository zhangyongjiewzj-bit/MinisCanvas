import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("P03 consumes only a complete shell result envelope")
@MainActor struct P03BridgeGitResultTests {
    @Test func onlyFixedDarwinAliasesMatchDisposableChildWorktreePaths() throws {
        let name = "P03-owned-" + UUID().uuidString
        for prefix in ["/var/", "/tmp/"] {
            let short = prefix + name
            let long = "/private" + short
            #expect(BridgeStore.matchesChildWorktreePath(short, long, isDisposable: true))
            #expect(BridgeStore.matchesChildWorktreePath(long, short, isDisposable: true))
            #expect(!BridgeStore.matchesChildWorktreePath(short, long, isDisposable: false))
            #expect(!BridgeStore.matchesChildWorktreePath(short, long + "-other", isDisposable: true))
        }
        #expect(BridgeStore.matchesChildWorktreePath("/synthetic/owned", "/synthetic/owned",
                                                    isDisposable: false))
        #expect(!BridgeStore.matchesChildWorktreePath("/etc/" + name, "/private/etc/" + name,
                                                     isDisposable: true))
    }

    @Test func prospectiveDarwinAliasStillRejectsDeniedCredentialAndProtectedPaths() throws {
        let temporaryPath = try #require(ChildProcessEnvironment.values(ordinary: [:])["TMPDIR"])
        let privatePath = temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath
        try #require(privatePath.hasPrefix("/private/var/"))
        let name = "P03-owned-" + UUID().uuidString
        let rootPath = privatePath + (privatePath.hasSuffix("/") ? "" : "/") + name
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }

        let real = rootPath + "/checkout"
        let canonical = try #require(PolicyRuntimePathBoundary.canonicalPath(real))
        let standardized = URL(fileURLWithPath: real).standardizedFileURL.path
        try #require(canonical.hasPrefix("/var/") && standardized.hasPrefix("/private/var/"))
        try #require(canonical != standardized)
        #expect(BridgeStore.admitsProspectiveChildWorktreePath(real, deniedRoots: [], isDisposable: true))
        #expect(!BridgeStore.admitsProspectiveChildWorktreePath(real, deniedRoots: [], isDisposable: false))
        #expect(!BridgeStore.admitsProspectiveChildWorktreePath(real, deniedRoots: [root], isDisposable: true))

        let symlink = root.appendingPathComponent("owned-link", isDirectory: true)
        let physical = root.appendingPathComponent("owned-target", isDirectory: true)
        try files.createDirectory(at: physical, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: symlink, withDestinationURL: physical)
        let linkChild = symlink.path + "/checkout"
        let targetChild = physical.path + "/checkout"
        let canonicalTarget = try #require(PolicyRuntimePathBoundary.canonicalPath(targetChild))
        try #require(PolicyRuntimePathBoundary.canonicalPath(linkChild) == canonicalTarget)
        #expect(!BridgeStore.matchesChildWorktreePath(linkChild, targetChild, isDisposable: true))
        #expect(!BridgeStore.admitsProspectiveChildWorktreePath(linkChild, deniedRoots: [], isDisposable: true))

        let credential = rootPath + "/.env"
        let canonicalCredential = try #require(PolicyRuntimePathBoundary.canonicalPath(credential))
        try #require(SensitiveFilePolicy.isCredentialPath(canonicalCredential))
        #expect(!BridgeStore.admitsProspectiveChildWorktreePath(credential, deniedRoots: [], isDisposable: true))

        let protected = URL(fileURLWithPath: rootPath + "/owned-state")
        try #require(BridgeStore.admitsProspectiveChildWorktreePath(protected.path, deniedRoots: [],
                                                                   isDisposable: true))
        SensitiveFilePolicy.protectStatePath(protected)
        defer { SensitiveFilePolicy.unprotectStatePath(protected) }
        #expect(SensitiveFilePolicy.isProtectedStatePath(protected.path))
        #expect(!BridgeStore.admitsProspectiveChildWorktreePath(protected.path, deniedRoots: [],
                                                               isDisposable: true))
    }

    @Test func rawExitIsPreservedAndArtifactPreviewCannotProveCheckoutIdentity() throws {
        let result = try BridgeStore.worktreeGitCommandResult(#"{"exit_code":7,"stdout":"out","stderr":"failed"}"#)
        #expect(result.exitCode == 7)
        #expect(result.stdout == "out")
        #expect(result.stderr == "failed")
        for incomplete in [
            #"{"stdout":"out","stderr":""}"#,
            #"{"exit_code":0,"stdout":"preview","stderr":"","stdout_artifact":{"path":"/some/receipt"}}"#,
            #"{"exit_code":0,"stdout":"out","stderr":"preview","stderr_artifact":{"path":"/some/receipt"}}"#,
            "not a result envelope"
        ] {
            #expect(throws: (any Error).self) { try BridgeStore.worktreeGitCommandResult(incomplete) }
        }
    }

    @Test func readSetRequiresAnActualBooleanCompletenessReceipt() throws {
        for value in [false, 1, "true", NSNull()] as [Any] {
            let bytes = try JSONSerialization.data(withJSONObject: ["exit_code": 0,
                "stdout": "eight fields", "stderr": "", "output_complete": value])
            #expect(throws: (any Error).self) {
                try BridgeStore.cleanupReadSetResult(String(decoding: bytes, as: UTF8.self))
            }
        }
        #expect(throws: (any Error).self) {
            try BridgeStore.cleanupReadSetResult(#"{"exit_code":0,"stdout":"out","stderr":""}"#)
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["exit_code": 0,
            "stdout": "preview", "stderr": "", "output_complete": true,
            "stdout_artifact": ["path": "/synthetic/preview"]])
        #expect(throws: (any Error).self) {
            try BridgeStore.cleanupReadSetResult(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// Pure composition: no shell command, process, Git or filesystem write.
    /// Exercises the real foreground formatter and Bridge JSON consumer, not a
    /// made-up readset envelope. Capture truth itself is tested by Core's pipe suite.
    @Test func NULFramingSurvivesUTF8RedactionRealEnvelopeAndPostHook() throws {
        let fields = ["/synthetic/repository\n", "/synthetic/checkout\n",
            "/synthetic/repository/.git\n", "/synthetic/repository/.git\n",
            "refs/heads/minis/child-synthetic\n", "", "100644 index-entry\n",
            String(repeating: "a", count: 40) + "\n"]
        let original = fields.joined(separator: "\0")
        let decoded = try #require(String(data: Data(original.utf8), encoding: .utf8))
        let redacted = ContentSecretRedactor.redact(decoded)
        let owner = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory)
        let envelope = try owner.shellResult(command: "git status", exitCode: 0,
            stdout: redacted, stderr: "", outputComplete: true)
        let annotated = HookOutputAnnotation.annotate(output: envelope,
            context: "synthetic display context", toolName: "shell_execute")
        let result = try BridgeStore.cleanupReadSetResult(annotated)
        #expect(result.outputComplete)
        #expect(result.stdout.utf8.elementsEqual(original.utf8))
        #expect(result.stdout.components(separatedBy: "\0") == fields)
    }
}
