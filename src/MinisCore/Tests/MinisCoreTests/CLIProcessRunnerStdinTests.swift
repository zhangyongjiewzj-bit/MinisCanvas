import Foundation
import Testing
@testable import MinisCore

@Suite("CLIProcessRunner standard input", .serialized)
struct CLIProcessRunnerStdinTests {
    @Test
    func stdinBytesReachTheChildVerbatim() async throws {
        let text = "- leading dash\n\"quoted\" $(not run) `not run`\n多字节 ✓\n"
        let output = try await CLIProcessRunner.run(
            binary: "/bin/cat", arguments: [], workingDirectory: nil,
            timeoutSeconds: 10, standardInput: Data(text.utf8))
        #expect(output == text)
    }

    @Test
    func inputLargerThanThePipeBufferDoesNotDeadlock() async throws {
        let text = String(repeating: "0123456789abcdef", count: 20_000) // 320 KB
        let output = try await CLIProcessRunner.run(
            binary: "/bin/cat", arguments: [], workingDirectory: nil,
            timeoutSeconds: 20, standardInput: Data(text.utf8))
        #expect(output.utf8.count == text.utf8.count)
        #expect(output == text)
    }

    @Test
    func emptyStdinGivesTheChildImmediateEOF() async throws {
        let output = try await CLIProcessRunner.run(
            binary: "/bin/cat", arguments: [], workingDirectory: nil,
            timeoutSeconds: 10, standardInput: Data())
        #expect(output == "")
    }

    @Test
    func childThatNeverReadsStdinDoesNotCrashTheCaller() async throws {
        // /usr/bin/true exits without reading 300 KB of input: the writer sees
        // EPIPE. A SIGPIPE would terminate the test process itself.
        let big = Data(String(repeating: "x", count: 300_000).utf8)
        let output = try await CLIProcessRunner.run(
            binary: "/usr/bin/true", arguments: [], workingDirectory: nil,
            timeoutSeconds: 10, standardInput: big)
        #expect(output == "")
    }

    @Test
    func stdinParameterNilKeepsExistingRunnerBehaviour() async throws {
        let direct = try await CLIProcessRunner.run(
            binary: "/bin/echo", arguments: ["hi"], workingDirectory: nil, timeoutSeconds: 10)
        #expect(direct == "hi\n")
        let task = SubAgentTask(
            id: "stdin-nil-\(UUID().uuidString)", title: "t", instructions: "proof",
            executionID: "stdin-nil-\(UUID().uuidString)")
        let viaRunner = try await CodexAgentRunner(binaryPath: "/bin/echo", timeoutSeconds: 5)
            .run(task: task)
        #expect(viaRunner == "exec proof\n")
    }
}
