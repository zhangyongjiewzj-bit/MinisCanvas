import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("Foreground shell capture completeness from actual reader outcomes")
struct ShellOutputCompletenessTests {
    private func closedWriterPipe(_ payload: Data) throws -> Pipe {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
        return pipe
    }

    @Test func onlyBothActualEOFsCanProduceCompleteForegroundEnvelope() async throws {
        let lifetime = ShellPipeReaderLifetime()
        #expect(await lifetime.outputComplete() == false)
        let stdout = try closedWriterPipe(Data("exactly8".utf8))
        let stderr = try closedWriterPipe(Data())
        let first = await readPipeData(stdout.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        #expect(first == Data("exactly8".utf8))
        #expect(await lifetime.outputComplete() == false)
        let second = await readPipeData(stderr.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        #expect(second.isEmpty)
        let complete = await lifetime.outputComplete()
        #expect(complete)
        let executor = BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic-project"))
        let raw = try executor.shellResult(command: "synthetic-command", exitCode: 0,
            stdout: String(decoding: first, as: UTF8.self), stderr: "", outputComplete: complete)
        let result = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(result["output_complete"] as? Bool == true)
        #expect(result["stdout"] as? String == "exactly8")
    }

    @Test func realCapOverflowRetainsOriginalPrefixButCannotClaimComplete() async throws {
        let lifetime = ShellPipeReaderLifetime()
        let stdout = try closedWriterPipe(Data("0123456789".utf8))
        let stderr = try closedWriterPipe(Data())
        let first = await readPipeData(stdout.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        _ = await readPipeData(stderr.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        #expect(first == Data("01234567".utf8))
        #expect(await lifetime.outputComplete() == false)
    }

    @Test func invalidDescriptorReadCannotBecomeEmptySuccessfulCapture() async throws {
        let lifetime = ShellPipeReaderLifetime()
        let pipe = Pipe()
        // Closing the read end makes poll report the write endpoint's error.
        // Keep that write-only descriptor owned and open across the await so its
        // number cannot be reused; the ensuing read deterministically fails.
        try pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        try #require(descriptor >= 0)
        try #require(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_WRONLY)
        let captured = await readPipeData(pipe.fileHandleForWriting, maxBytes: 8, lifetime: lifetime)
        let stderr = try closedWriterPipe(Data())
        _ = await readPipeData(stderr.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        #expect(captured.isEmpty)
        #expect(await lifetime.outputComplete() == false)
    }

    @Test func drainWithoutEOFAndFormatterWithoutProofStayIncomplete() async throws {
        let lifetime = ShellPipeReaderLifetime()
        let openWriter = Pipe()
        await lifetime.beginFinalDrain(gracePeriod: 0)
        let captured = await readPipeData(openWriter.fileHandleForReading, maxBytes: 8, lifetime: lifetime)
        #expect(captured.isEmpty)
        #expect(await lifetime.outputComplete() == false)
        let executor = BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic-project"))
        let raw = try executor.shellResult(command: "synthetic-command", exitCode: 0, stdout: "", stderr: "")
        let result = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(result["output_complete"] as? Bool == false)
    }
}
