import Foundation
import Testing
@testable import MinisCore

/// Direct consumer coverage for the P3 security closure.  Fixtures are
/// synthetic and assert only redacted identity/state; no credential value is
/// ever loaded or persisted by these tests.
struct P3SecurityClosureConsumerTests {
    @Test func denyWinsBeforeApprovalAndHighRiskNeedsConfirmation() async {
        let delegate = P3SecurityApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(policyByTool: ["shell_execute": .deny], delegate: delegate)

        await #expect(throws: ApprovalError.denied(reason: "Tool 'shell_execute' is blocked by policy")) {
            try await gate.gate(tool: "shell_execute", input: ["command": "synthetic no-op"])
        }
        #expect(delegate.requests.isEmpty)

        let asking = ApprovalGate(delegate: P3SecurityApprovalDelegate(decision: .approve))
        // 只有不可逆操作（删除）才要求第二次确认；普通 shell 命令一次批准即可。
        await #expect(throws: ApprovalError.denied(reason: "L3 requires second confirmation")) {
            try await asking.gate(
                tool: "shell_execute",
                input: ["command": "rm -rf /tmp/synthetic-irreversible-target"],
                delegate: P3SecurityApprovalDelegate(decision: ApprovalDecision(approved: true))
            )
        }
    }

    @Test func boundApprovalRejectsPayloadMutationAndAcceptsExactIdentity() async throws {
        let input: [String: Any] = ["path": "/tmp/synthetic", "content": "fixture"]
        let context = ApprovalAuthorizationContext(
            actorID: "actor", sessionID: "session", turnID: 1, taskID: "task",
            runID: "run", attemptID: "attempt", effectID: "effect",
            scope: "scope", payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
            expiresAt: Date().addingTimeInterval(60), policyRevision: "policy-v1", grantEpoch: "epoch-1"
        )
        let delegate = P3SecurityApprovalDelegate(decision: nil, bindToRequest: true)
        let gate = ApprovalGate(delegate: delegate)
        let decision = try await gate.gate(tool: "file_write", input: input, context: context)
        #expect(decision.approved)
        #expect(delegate.requests.count == 1)

        await #expect(throws: ApprovalError.bindingMismatch(requestID: context.effectID)) {
            try await gate.gate(
                tool: "file_write",
                input: ["path": "/tmp/synthetic", "content": "mutated"],
                context: context,
                delegate: delegate
            )
        }
    }

    @Test func credentialRecoveryReportsMissingAuthorityWithoutPromotion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent(".envvars.json.pending-fixture")
        try Data("synthetic-fixture".utf8).write(to: pending)

        let result = CredentialMetadataRecovery.recover(in: root)
        let receipt = try result.get()
        #expect(receipt.metadataRecoveryRequired)
        #expect(receipt.orphanCount == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("envvars.json").path))
    }

    @Test func deletionSnapshotBindsTargetScopeAndRevision() throws {
        let intent = DeletionGate.preview(
            targetID: "fixture-target", targetType: "session", targetName: "Fixture",
            affectedCount: 1, impactSummary: "fixture", scopeID: "fixture-scope",
            revision: 4, fingerprint: DeletionGate.fingerprint("fixture"),
            now: Date(timeIntervalSince1970: 1_000), ttl: 60
        ).withFirstConfirmation("reviewed").withSecondConfirmation("confirmed")
        let state = DeletionStateSnapshot(
            targetID: "fixture-target", scopeID: "fixture-scope", revision: 4,
            fingerprint: DeletionGate.fingerprint("fixture")
        )
        #expect(try DeletionGate.prepare(intent, currentState: state).get() == intent)
        #expect(DeletionGate.prepare(intent, currentState: DeletionStateSnapshot(
            targetID: "other", scopeID: state.scopeID, revision: state.revision,
            fingerprint: state.fingerprint
        )) == .failure(.targetChanged))
    }

    @Test func secretSafeRedactionAndPrivacyNamesAreCanonical() {
        let text = "TOKEN=abcd url=https://u:p@example.test/?api_key='tiny'"
        let redacted = ContentSecretRedactor.redact(text, knownSecrets: ["abcd"])
        #expect(!redacted.contains("abcd"))
        #expect(!redacted.contains("tiny"))
        #expect(!redacted.contains("u:p"))

        let suiteName = "p3-security-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let privacy = EnvVarPrivacyStore(defaults: suite)
        privacy.markSecret(name: " fixture_token ")
        #expect(privacy.isSecret(name: "FIXTURE_TOKEN"))
        #expect(!privacy.isSecret(name: "\u{0}"))
    }
}

private final class P3SecurityApprovalDelegate: ApprovalDelegate, @unchecked Sendable {
    let decision: ApprovalDecision?
    let bindToRequest: Bool
    private(set) var requests: [ApprovalRequest] = []

    init(decision: ApprovalDecision?, bindToRequest: Bool = false) {
        self.decision = decision
        self.bindToRequest = bindToRequest
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        if bindToRequest, let binding = request.binding {
            return ApprovalDecision(
                approved: true, reason: "fixture approval", confirmed: true,
                requestID: request.requestID, bindingDigest: binding.identityDigest
            )
        }
        return decision ?? .deny
    }
}
