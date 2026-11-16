import Foundation
import CryptoKit
import Testing
@testable import MinisCore

@Suite("D-CONC2 owned shell reader lifetime", .serialized)
struct LateShellPipeConsumer2438Tests {
    @Test("completed pipe chunks precede a legitimate delayed final output")
    func completeChunksProveCollectorStartedBeforeLateEmission() async throws {
        // Owned artifact reads reject symlinked ancestor components. Use the
        // admitted formal root rather than Foundation's /var temporary alias.
        guard let paths = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw FormalTestIsolationPaths.IsolationError.missingContract
        }
        let root = paths.rootDirectory.appendingPathComponent(
            "late-shell-2438-full-chunks-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let builtin = BuiltinToolExecutor(
            allowedRoot: root, deniedRoots: [root.appendingPathComponent("denied")]
        )
        // Each prefix is exactly 32 whole 64KiB collector chunks. Two MiB
        // is within the four-MiB per-stream product limit and forces actual
        // collection while the producer writes, before its later sleep.
        let prefixBytes = 2 * 1024 * 1024
        let stdoutMarker = "SYNTHETIC_2438_STDOUT_READY\n"
        let stderrMarker = "SYNTHETIC_2438_STDERR_READY\n"
        let expectedOut = stdoutMarker + String(repeating: "o", count: prefixBytes - stdoutMarker.utf8.count)
            + "\nSYNTHETIC_2438_STDOUT_FINAL\n"
        let expectedErr = stderrMarker + String(repeating: "e", count: prefixBytes - stderrMarker.utf8.count)
            + "\nSYNTHETIC_2438_STDERR_FINAL\n"
        let script = "import time,sys;a='SYNTHETIC_2438_STDOUT_READY\\n';b='SYNTHETIC_2438_STDERR_READY\\n';sys.stdout.write(a+'o'*(\(prefixBytes)-len(a)));sys.stdout.flush();sys.stderr.write(b+'e'*(\(prefixBytes)-len(b)));sys.stderr.flush();time.sleep(2);print('\\nSYNTHETIC_2438_STDOUT_FINAL',flush=True);print('\\nSYNTHETIC_2438_STDERR_FINAL',file=sys.stderr,flush=True)"
        let session = ToolOutputArtifactSessionScope(
            sessionStorageRoot: root.appendingPathComponent("session-storage", isDirectory: true),
            sessionID: UUID()
        )
        let artifactDirectory = try ToolOutputArtifactStore(
            sessionStorageRoot: session.sessionStorageRoot, sessionID: session.sessionID
        ).validatedDirectory()
        try await ToolOutputArtifactSessionScope.$current.withValue(session) {
            let result = try await builtin.execute(name: "shell_execute", input: [
                "command": "python3 -c \"\(script)\"", "timeout": 6
            ])
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            #expect(envelope["exit_code"] as? Int == 0)
            #expect(envelope["output_complete"] as? Bool == true)
            let stdoutPreview = try #require(envelope["stdout"] as? String)
            let stderrPreview = try #require(envelope["stderr"] as? String)
            let stdoutArtifact = try #require(envelope["stdout_artifact"] as? [String: Any])
            let stderrArtifact = try #require(envelope["stderr_artifact"] as? [String: Any])
            let stdoutPath = try #require(stdoutArtifact["path"] as? String)
            let stderrPath = try #require(stderrArtifact["path"] as? String)
            #expect(stdoutArtifact["capture_scope"] as? String == "retained_shell_output")
            #expect(stderrArtifact["capture_scope"] as? String == "retained_shell_output")
            #expect(stdoutPath.hasPrefix(artifactDirectory.path + "/"))
            #expect(stderrPath.hasPrefix(artifactDirectory.path + "/"))
            // The envelope carries previews. Read the producer-registered artifacts
            // in the same session scope to verify the entire retained streams.
            let stdoutData = try #require(try ToolOutputArtifactStore.readOwnedArtifact(path: stdoutPath))
            let stderrData = try #require(try ToolOutputArtifactStore.readOwnedArtifact(path: stderrPath))
            let stdout = try #require(String(data: stdoutData, encoding: .utf8))
            let stderr = try #require(String(data: stderrData, encoding: .utf8))
            #expect(stdoutArtifact["utf8_bytes"] as? Int == stdoutData.count)
            #expect(stderrArtifact["utf8_bytes"] as? Int == stderrData.count)
            #expect(stdoutPreview.utf8.count < stdoutData.count)
            #expect(stderrPreview.utf8.count < stderrData.count)
            #expect(stdoutPreview.hasPrefix(stdoutMarker))
            #expect(stderrPreview.hasPrefix(stderrMarker))
            #expect(stdoutPreview.hasSuffix("\nSYNTHETIC_2438_STDOUT_FINAL\n"))
            #expect(stderrPreview.hasSuffix("\nSYNTHETIC_2438_STDERR_FINAL\n"))
            #expect(stdout.hasSuffix("\nSYNTHETIC_2438_STDOUT_FINAL\n"))
            #expect(stderr.hasSuffix("\nSYNTHETIC_2438_STDERR_FINAL\n"))
            let stdoutReady = stdout.hasPrefix(stdoutMarker)
            let stderrReady = stderr.hasPrefix(stderrMarker)
            #expect(stdoutReady)
            #expect(stderrReady)
            let actualOutBytes = stdout.utf8.count
            let actualErrBytes = stderr.utf8.count
            #expect(actualOutBytes == expectedOut.utf8.count)
            #expect(actualErrBytes == expectedErr.utf8.count)
            // Compare the entire content without dumping a multi-MiB fixture.
            let actualOutHash = SHA256.hash(data: Data(stdout.utf8)).description
            let actualErrHash = SHA256.hash(data: Data(stderr.utf8)).description
            let expectedOutHash = SHA256.hash(data: Data(expectedOut.utf8)).description
            let expectedErrHash = SHA256.hash(data: Data(expectedErr.utf8)).description
            #expect(actualOutHash == expectedOutHash)
            #expect(actualErrHash == expectedErrHash)
        }
    }

    @Test("legitimate shell output remains owned until the process ends", arguments: [0, 2])
    func outputAfterReaderStartIsNotLost(delaySeconds: Int) async throws {
        let root = try minisCoreToolContractRoot("late-shell-2438-\(delaySeconds)")
        let builtin = BuiltinToolExecutor(
            allowedRoot: root,
            deniedRoots: [root.appendingPathComponent("denied")]
        )
        // The prefixes prove the real collector saw this owned process. Both
        // streams then emit again within the legitimate request deadline.
        // The zero-delay case is the normal-output positive control.
        let script = "import time,sys;print('SYNTHETIC_2438_STDOUT_PREFIX',flush=True);print('SYNTHETIC_2438_STDERR_PREFIX',file=sys.stderr,flush=True);time.sleep(\(delaySeconds));print('SYNTHETIC_2438_STDOUT_FINAL',flush=True);print('SYNTHETIC_2438_STDERR_FINAL',file=sys.stderr,flush=True)"
        let result = try await builtin.execute(name: "shell_execute", input: [
            "command": "python3 -c \"\(script)\"", "timeout": 6
        ])
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        )
        #expect(envelope["exit_code"] as? Int == 0)
        let stdout = try #require(envelope["stdout"] as? String)
        let stderr = try #require(envelope["stderr"] as? String)
        #expect(stdout.contains("SYNTHETIC_2438_STDOUT_PREFIX"))
        #expect(stderr.contains("SYNTHETIC_2438_STDERR_PREFIX"))
        #expect(stdout == "SYNTHETIC_2438_STDOUT_PREFIX\nSYNTHETIC_2438_STDOUT_FINAL\n")
        #expect(stderr == "SYNTHETIC_2438_STDERR_PREFIX\nSYNTHETIC_2438_STDERR_FINAL\n")
    }
}
