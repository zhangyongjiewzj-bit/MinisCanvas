import Foundation
import Testing
@testable import MinisCore

private let unsafeApprovalTool =
    "mcp://Bearer fixture-tool-secret/path?token=fixture-query-secret"
private let unsafeApprovalScope =
    "scope:/private/tmp/credential-secret?api_key=fixture"

@Suite("Approval receipt metadata security", .serialized)
struct ApprovalReceiptMetadataSecurityTests {
    @Test func webFetchAuthorityIsDisplayOnlyAndDefaultsToNil() throws {
        let input: [String: Any] = ["url": "https://example.com:8443/path"]
        let context = ApprovalAuthorizationContext(actorID: "synthetic-actor", sessionID: "session",
            turnID: 1, taskID: "task", runID: "run", attemptID: "attempt", effectID: "effect",
            scope: "request", payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
            expiresAt: Date().addingTimeInterval(60), policyRevision: "v1", grantEpoch: "epoch", toolName: "web_fetch")
        func makeRequest(authority: String?) -> ApprovalRequest {
            let base = ApprovalGate().makeBoundRequest(id: "same-call", tool: "web_fetch", input: input, context: context)
            return ApprovalRequest(id: base.id, requestID: base.requestID, callID: base.callID,
                toolName: base.toolName, inputSummary: base.inputSummary, riskLevel: base.riskLevel,
                requiresApproval: base.requiresApproval, inputRiskLevel: base.inputRiskLevel,
                requiresSecondConfirmation: base.requiresSecondConfirmation,
                sessionID: base.sessionID, turnID: base.turnID, taskID: base.taskID,
                attemptID: base.attemptID, approvalScope: base.approvalScope,
                composerMode: base.composerMode, messageID: base.messageID,
                policyRevision: base.policyRevision, grantEpoch: base.grantEpoch,
                inputDigest: base.inputDigest, identityDigest: base.identityDigest,
                actorID: base.actorID, runID: base.runID, effectID: base.effectID,
                expiresAt: base.expiresAt, filePreview: base.filePreview, webFetchAuthority: authority)
        }
        // Construct independently through the identical Gate + constructor path;
        // never copy a finished request and mutate its display field afterward.
        let original = makeRequest(authority: nil)
        let request = makeRequest(authority: "example.com:8443")
        #expect(original.webFetchAuthority == nil)
        #expect(original.terminalPolicyDisposition == nil)
        #expect(request.webFetchAuthority == "example.com:8443")
        #expect(request.binding != nil)
        #expect(request.id == original.id)
        #expect(request.requestID == original.requestID)
        #expect(request.callID == original.callID)
        #expect(request.binding == original.binding)
        #expect(request.inputDigest == original.inputDigest)
        #expect(request.identityDigest == original.identityDigest)
        #expect(request.inputSummary == original.inputSummary)
        #expect(request.requiresApproval == original.requiresApproval)
        #expect(request.requiresSecondConfirmation == original.requiresSecondConfirmation)
    }

    @Test func filePreviewRefreshRetainsWebAuthorityWithoutRewritingInputIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("approval-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.txt")
        try Data("before".utf8).write(to: file)
        let preview = try #require(ApprovalFilePreview.capture(tool: "file_write", input: ["path": file.path]))
        let request = ApprovalRequest(id: "old-card", callID: "same-call", toolName: "web_fetch",
            inputSummary: "unchanged summary", riskLevel: .medium, requiresApproval: true,
            inputDigest: "same-input", identityDigest: "same-identity", webFetchAuthority: "example.com:8443")
        let refreshed = request.refreshingFilePreview(preview)
        #expect(refreshed.webFetchAuthority == "example.com:8443")
        #expect(refreshed.callID == request.callID)
        #expect(refreshed.inputDigest == request.inputDigest)
        #expect(refreshed.identityDigest == request.identityDigest)
        #expect(refreshed.inputSummary == request.inputSummary)
        #expect(refreshed.id != request.id) // existing stale-card rejection contract
    }

    @Test("real approval caller projects tool and scope but preserves identity digest")
    func approvalCallerProjectsReceiptMetadata() async throws {
        let payloadDigest = try #require(
            ApprovalAuthorizationContext.payloadDigest(for: [:])
        )
        let context = ApprovalAuthorizationContext(
            actorID: "actor",
            sessionID: "session",
            turnID: 1,
            taskID: "task",
            runID: "run",
            attemptID: "attempt",
            effectID: "effect",
            scope: unsafeApprovalScope,
            payloadDigest: payloadDigest,
            expiresAt: Date(timeIntervalSinceNow: 60),
            policyRevision: "policy",
            grantEpoch: "grant",
            toolName: unsafeApprovalTool
        )
        let probe = ApprovalReceiptProbe()
        let gate = ApprovalGate(
            policyByTool: [unsafeApprovalTool: .autoApprove],
            onApprovalReceipt: { probe.record($0) }
        )

        let decision = try await gate.gate(
            tool: unsafeApprovalTool,
            input: [:],
            context: context
        )
        let receipt = try #require(probe.value)

        #expect(decision.approved)
        #expect(receipt.toolName == "tool")
        #expect(receipt.approvalScope == "scope")
        #expect(receipt.identityDigest == context.identityDigest)
        #expect(context.toolName == unsafeApprovalTool)
        #expect(context.scope == unsafeApprovalScope)
    }

    @Test("direct receipt construction bounds malformed labels")
    func directReceiptLabelsAreBounded() {
        let receipt = ApprovalReceipt(
            requestID: "request",
            toolName: String(repeating: "x", count: 129),
            policy: .deny,
            riskLevel: .high,
            inputSummary: "safe",
            approvalScope: "scope\u{0000}fixture"
        )

        #expect(receipt.toolName == "tool")
        #expect(receipt.approvalScope == "scope")
    }

    @Test("Codable receipt decode applies the same redaction")
    func decodedReceiptLabelsAreBounded() throws {
        let payload = """
        {
          "requestID": "request",
          "toolName": "mcp://Bearer fixture-tool-secret/path?token=secret",
          "policy": "deny",
          "riskLevel": "high",
          "inputSummary": "safe",
          "approvedAt": 0,
          "status": "denied",
          "actorID": null,
          "sessionID": null,
          "turnID": null,
          "taskID": null,
          "runID": null,
          "attemptID": null,
          "effectID": null,
          "approvalScope": "scope:/private/tmp/secret?api_key=fixture",
          "inputDigest": null,
          "identityDigest": null,
          "expiresAt": null,
          "policyRevision": null,
          "grantEpoch": null
        }
        """.data(using: .utf8)!

        let receipt = try JSONDecoder().decode(
            ApprovalReceipt.self,
            from: payload
        )

        #expect(receipt.toolName == "tool")
        #expect(receipt.approvalScope == "scope")
        #expect(receipt.status == .denied)
    }

    @Test("direct receipt arguments are redacted and bounded")
    func directReceiptArgumentsAreRedactedAndBounded() {
        let raw = "resource https://example.test/data?token=fixture-secret /Users/alice/private.txt "
            + String(repeating: "x", count: 240) + "\u{0000}"
        let receipt = ApprovalReceipt(
            requestID: "receipt-arguments",
            toolName: "file_read",
            policy: .alwaysAsk,
            riskLevel: .high,
            inputSummary: raw
        )

        #expect(receipt.inputSummary.contains("[remote resource]"))
        #expect(receipt.inputSummary.contains("[local path]"))
        #expect(!receipt.inputSummary.contains("fixture-secret"))
        #expect(!receipt.inputSummary.contains("/Users/alice/private.txt"))
        #expect(receipt.inputSummary.count <= 160)
        #expect(receipt.inputSummary.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
    }

    @Test("Codable receipt arguments remain redacted")
    func decodedReceiptArgumentsRemainRedactedAndBounded() throws {
        let payload = """
        {
          "requestID": "decoded-arguments",
          "toolName": "file_read",
          "policy": "alwaysAsk",
          "riskLevel": "high",
          "inputSummary": "open https://example.test/file?api_key=fixture-secret /private/fixture.txt",
          "approvedAt": 0,
          "status": "approved"
        }
        """.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(
            ApprovalReceipt.self,
            from: payload
        )

        #expect(receipt.inputSummary.contains("[remote resource]"))
        #expect(receipt.inputSummary.contains("[local path]"))
        #expect(!receipt.inputSummary.contains("fixture-secret"))
        #expect(!receipt.inputSummary.contains("/private/fixture.txt"))
        #expect(receipt.inputSummary.count <= 160)
    }

    @Test("denial rationale is safe at localized error surface")
    func denialReasonIsRedactedAndBounded() {
        let raw = "reason https://example.test/deny?token=fixture-secret /Users/alice/private.txt "
            + String(repeating: "r", count: 240) + "\u{0000}"
        let error = ApprovalError.denied(reason: raw)
        let description = error.errorDescription ?? ""

        #expect(description.hasPrefix("审批被拒绝: "))
        #expect(description.contains("[remote resource]"))
        #expect(description.contains("[local path]"))
        #expect(!description.contains("fixture-secret"))
        #expect(!description.contains("/Users/alice/private.txt"))
        #expect(description.count <= 170)
        #expect(description.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
        #expect(error == .denied(reason: raw))
    }

    @Test("real bound approval caller retains frozen terminal display classification")
    func boundCallerRetainsTerminalDispositionThroughPreviewRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-terminal-display-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.txt")
        try Data("owned preview".utf8).write(to: file)
        let preview = try #require(ApprovalFilePreview.capture(tool: "file_write", input: ["path": file.path]))
        let cases: [(tool: String, input: [String: Any], expected: TerminalCommandDisposition?)] = [
            ("shell_execute", ["command": "halt Synthetic.app"], .denied),
            ("file_read", ["path": file.path], nil)
        ]
        for item in cases {
            let reason = "synthetic terminal display refusal"
            let context = ApprovalAuthorizationContext(actorID: "display-actor", sessionID: "display-session",
                turnID: 1, taskID: "display-task", runID: "display-run", attemptID: "display-attempt",
                effectID: UUID().uuidString, scope: "request",
                payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: item.input)),
                expiresAt: Date().addingTimeInterval(60), policyRevision: "display-policy", grantEpoch: "display-epoch",
                toolName: item.tool)
            let expected = item.expected
            let delegate = ApprovalReasonDelegate(reason: reason, onRequest: { request in
                #expect(request.terminalPolicyDisposition == expected)
                #expect(request.binding == context.binding(to: request.toolName))
                let refreshed = request.refreshingFilePreview(preview)
                #expect(refreshed.terminalPolicyDisposition == expected)
                #expect(refreshed.binding == request.binding)
                #expect(refreshed.callID == request.callID)
                #expect(refreshed.inputDigest == request.inputDigest)
                #expect(refreshed.identityDigest == request.identityDigest)
                #expect(refreshed.id != request.id)
            })
            let gate = ApprovalGate(policyByTool: [item.tool: .alwaysAsk], delegate: delegate)
            await #expect(throws: ApprovalError.denied(reason: reason)) {
                _ = try await gate.gate(tool: item.tool, input: item.input, context: context)
            }
        }
    }

    @Test("ApprovalGate denial caller uses the bounded rationale surface")
    func approvalGateDenialReasonIsRedacted() async {
        let raw = "delegate https://example.test/deny?api_key=fixture-secret /private/fixture.txt "
            + String(repeating: "d", count: 240) + "\u{0000}"
        let gate = ApprovalGate(delegate: ApprovalReasonDelegate(reason: raw))

        do {
            _ = try await gate.gate(
                tool: "file_write",
                input: ["path": "/tmp/fixture.txt", "content": "fixture"]
            )
            Issue.record("expected the approval gate to deny the fixture")
        } catch let error as ApprovalError {
            let description = error.errorDescription ?? ""
            #expect(description.hasPrefix("审批被拒绝: "))
            #expect(description.contains("[remote resource]"))
            #expect(description.contains("[local path]"))
            #expect(!description.contains("fixture-secret"))
            #expect(!description.contains("/private/fixture.txt"))
            #expect(description.count <= 170)
            #expect(error == .denied(reason: raw))
        } catch {
            Issue.record("unexpected approval error: \(error)")
        }
    }
}

private final class ApprovalReceiptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ApprovalReceipt?

    var value: ApprovalReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ receipt: ApprovalReceipt) {
        lock.lock()
        storedValue = receipt
        lock.unlock()
    }
}

private struct ApprovalReasonDelegate: ApprovalDelegate {
    let reason: String
    var onRequest: (@Sendable (ApprovalRequest) -> Void)? = nil

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        onRequest?(request)
        return ApprovalDecision(approved: false, reason: reason)
    }
}
