import Foundation
import Testing
@testable import MinisCore

@Suite("H05 B exact call identity (not authorization)")
struct WebFetchCallBindingTests {
    private func snapshot(session: String = "session", revision: String = "revision", epoch: String = "epoch") -> ComposerSubmissionSnapshot {
        .init(mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: session, turnID: 1, taskID: "task", attemptID: "attempt", messageID: "message",
            workspaceID: "project", createdAt: Date(timeIntervalSince1970: 1),
            policyRevision: revision, grantEpoch: epoch, autonomyCeiling: .l3)
    }
    private func facts(lease: String = "lease", revision: String = "revision", epoch: String = "epoch", revoked: Bool = false) -> ComposerPolicyFactSource {
        .init(knownCapabilities: ["web_fetch"], grantedCapabilities: ["web_fetch"],
            allowedWriteRoots: ["/synthetic-project"], workspaceID: "project", revision: revision,
            grantEpoch: epoch, leaseID: lease, expiresAt: Date(timeIntervalSince1970: 1000),
            revoked: revoked, autonomyCeiling: .l3)
    }
    @Test func changedSessionLeaseRevisionEpochOrURLCannotReuseBinding() throws {
        let input = try ComposerToolInput(["url": "https://example.com/a"])
        let binding = try WebFetchCallBinding(snapshot: snapshot(), facts: facts(), callID: "call",
            input: input, now: Date(timeIntervalSince1970: 2))
        let variants: [(ComposerSubmissionSnapshot, ComposerPolicyFactSource, ComposerToolInput)] = [
            (snapshot(session: "foreign"), facts(), input),
            (snapshot(), facts(lease: "other"), input),
            (snapshot(revision: "r2"), facts(revision: "r2"), input),
            (snapshot(epoch: "e2"), facts(epoch: "e2"), input),
            (snapshot(), facts(), try ComposerToolInput(["url": "https://example.com/b"]))
        ]
        for (snapshot, facts, input) in variants {
            #expect(throws: (any Error).self) {
                try binding.validate(snapshot: snapshot, facts: facts, callID: "call", input: input,
                    now: Date(timeIntervalSince1970: 2))
            }
        }
        #expect(throws: (any Error).self) {
            try binding.validate(snapshot: snapshot(), facts: facts(), callID: "wrong-call", input: input,
                now: Date(timeIntervalSince1970: 2))
        }
        #expect(throws: (any Error).self) {
            try binding.validate(snapshot: snapshot(), facts: facts(), callID: "call", input: input,
                now: Date(timeIntervalSince1970: 1001))
        }
        #expect(throws: (any Error).self) {
            try binding.validate(snapshot: snapshot(), facts: facts(revoked: true), callID: "call", input: input,
                now: Date(timeIntervalSince1970: 2))
        }
    }
}
