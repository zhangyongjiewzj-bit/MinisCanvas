import Foundation
import Testing
@testable import MinisCore

private struct Terminal307SyntheticRunner: TerminalProcessRunner {
    let result: TerminalProcessResult
    let failure: TerminalBoundaryError?

    init(result: TerminalProcessResult, failure: TerminalBoundaryError? = nil) {
        self.result = result
        self.failure = failure
    }

    func run(command: String, workdir: URL, timeout: Duration) async throws -> TerminalProcessResult {
        if let failure { throw failure }
        return result
    }
}

/// Synthetic runner -> the actual Core receipt projection. No shell/process
/// execution; no claim about POSIX process-group cleanup.
@Suite("D-TERMINAL-07 production receipt projection")
struct TerminalReceiptProjection307Tests {
    private func receipt(
        stdout: String, stderr: String = "", exitCode: Int32 = 0,
        failure: TerminalBoundaryError? = nil
    ) async throws -> TerminalReceipt {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Terminal307-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = TerminalExecutionContext(
            sessionID: "receipt307-session", turnID: "receipt307-turn",
            taskID: "receipt307-task", projectID: "receipt307-project",
            workdir: root.path
        )
        let boundary = TerminalBoundary(
            policy: TerminalPolicy(scopeID: context.projectID, allowedRoot: root),
            runner: Terminal307SyntheticRunner(
                result: TerminalProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr),
                failure: failure
            )
        )
        return await boundary.execute(TerminalExecutionRequest(
            capabilityID: "shell_execute", command: "echo synthetic",
            context: context, timeout: .seconds(5)
        ))
    }

    @Test("stdout and stderr remain ordered, recognized secrets are masked, actual nonzero exit survives")
    func bothStreamsRedactAndKeepActualExit() async throws {
        let key = "Terminal307KeySyntheticInteriorABCDEFG"
        let bearer = "Terminal307BearerSyntheticInteriorABCDEFG"
        let sid = "Terminal307SidSyntheticInteriorABCDEFG"
        let csrf = "Terminal307CsrfSyntheticInteriorABCDEFG"
        let value = try await receipt(
            stdout: "普通 api_key=\(key) 正文\nBearer \(bearer)",
            stderr: "Cookie: sid=\(sid); csrf=\(csrf)\nordinary-error-tail",
            exitCode: 17
        )
        #expect(value.error == nil)
        #expect(value.exitCode == 17)
        #expect(value.output == "普通 api_key=\(ContentSecretRedactor.mask(key)) 正文\nBearer \(ContentSecretRedactor.mask(bearer))\nCookie: sid=\(ContentSecretRedactor.mask(sid)); csrf=\(ContentSecretRedactor.mask(csrf))\nordinary-error-tail")
        for secret in [key, bearer, sid, csrf] { #expect(!value.output.contains(secret)) }
        #expect(value.sessionID == "receipt307-session")
        #expect(value.turnID == "receipt307-turn")
        #expect(value.taskID == "receipt307-task")
        #expect(value.projectID == "receipt307-project")
        #expect(!value.requestFingerprint.isEmpty)
    }

    @Test("stderr-only output is retained without a fabricated leading separator")
    func stderrOnlyIsNotLost() async throws {
        let value = try await receipt(stdout: "", stderr: "ordinary stderr only", exitCode: 2)
        #expect(value.output == "ordinary stderr only")
        #expect(value.exitCode == 2)
        #expect(value.error == nil)
    }

    @Test("full-value redaction precedes the UI character limit")
    func redactionPrecedesTruncation() async throws {
        let secret = "HEAD" + String(repeating: "SyntheticInterior", count: 500) + "TAIL"
        let prefix = String(repeating: "界", count: 4_000)
        let raw = prefix + " Bearer " + secret + "\nordinary-tail"
        let value = try await receipt(stdout: raw)
        let expected = prefix + " Bearer " + ContentSecretRedactor.mask(secret) + "\nordinary-tail"
        let limit = TerminalReceipt.maximumOutputCharacters
        let marker = "\n[truncated]"
        // A full-value mask keeps this ASCII secret's character count. The
        // entire redacted source no longer fits, so the receipt must project
        // only the first 4,096 safe characters and mark that loss explicitly.
        #expect(raw.count == expected.count && expected.count > limit)
        let correctBoundedProjection = value.output == String(expected.prefix(limit)) + marker
        #expect(correctBoundedProjection)
        #expect(value.output.count == limit + marker.count)
        #expect(value.output.hasPrefix(prefix + " Bearer " + String(repeating: "*", count: 88)))
        #expect(!value.output.contains("SyntheticInterior"))
        #expect(!value.output.contains("HEAD") && !value.output.contains("TAIL"))
        #expect(value.output.hasSuffix(marker))
    }

    @Test("character limit is inclusive and never splits a grapheme", arguments: [4_096, 4_097])
    func unicodeTruncationIsExplicit(characterCount: Int) async throws {
        let raw = String(repeating: "👩🏽‍💻", count: characterCount)
        let value = try await receipt(stdout: raw)
        let prefix = String(raw.prefix(TerminalReceipt.maximumOutputCharacters))
        let expected = characterCount > TerminalReceipt.maximumOutputCharacters
            ? prefix + "\n[truncated]" : prefix
        #expect(value.output == expected)
        #expect(value.exitCode == 0)
        #expect(value.error == nil)
    }

    @Test("typed failure stays separate from an actual exit", arguments: [
        TerminalBoundaryError.spawnFailed, .executionFailed, .timeout, .cancelled
    ])
    func typedFailureNeverInventsZeroExit(failure: TerminalBoundaryError) async throws {
        let value = try await receipt(stdout: "must not be published", exitCode: 0, failure: failure)
        #expect(value.error == failure.rawValue)
        #expect(value.exitCode == nil)
        #expect(value.output.isEmpty)
    }
}
