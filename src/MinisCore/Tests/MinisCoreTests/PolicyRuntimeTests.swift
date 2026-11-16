import Testing
import Foundation
@testable import MinisCore

struct PolicyRuntimeTests {
    private func goal() -> GoalEnvelope {
        GoalEnvelope(scopeID: "session:test", allowedCapabilities: ["file_read"], fileRoots: ["/tmp/work"], networkDomains: ["example.invalid"], budget: 10, deadline: Date().addingTimeInterval(60), concurrencyLimit: 1)
    }

    private func lease(for goal: GoalEnvelope, revoked: Bool = false) -> AutonomyLease {
        AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID, issuedAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(60), revoked: revoked)
    }

    private func failure(_ result: Result<Void, PolicyViolation>) -> PolicyViolation? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    @Test func allowedRequestPasses() {
        let g = goal()
        let result = validatePolicy(goal: g, lease: lease(for: g), request: PolicyRequest(capabilityID: "file_read", filePath: "/tmp/work/a.txt", estimatedCost: 2), now: Date(), spentBudget: 3)
        #expect(failure(result) == nil)
    }

    @Test(arguments: [PolicyViolation.capabilityNotAllowed, .fileRootNotAllowed, .networkDomainNotAllowed, .budgetExceeded, .concurrencyExceeded])
    func boundaryRequestFails(_ expected: PolicyViolation) {
        let g = goal()
        let request: PolicyRequest
        switch expected {
        case .capabilityNotAllowed: request = PolicyRequest(capabilityID: "shell_execute")
        case .fileRootNotAllowed: request = PolicyRequest(capabilityID: "file_read", filePath: "/Users/other/a")
        case .networkDomainNotAllowed: request = PolicyRequest(capabilityID: "file_read", networkDomain: "evil.invalid")
        case .budgetExceeded: request = PolicyRequest(capabilityID: "file_read", estimatedCost: 8)
        case .concurrencyExceeded: request = PolicyRequest(capabilityID: "file_read", activeTasks: 1)
        case .emptyScope, .scopeMismatch, .invalidCapability, .invalidFileRoot,
             .invalidNetworkDomain, .invalidBudget, .deadlineExceeded,
             .requestDeadlineExceeded, .leaseExpired, .leaseRevoked,
             .leaseGoalMismatch, .invalidLease, .autonomyLevelExceeded,
             .invalidConcurrency, .invalidRequestCost, .invalidActiveTasks:
            request = PolicyRequest(capabilityID: "file_read")
        }
        let spent = expected == .budgetExceeded ? 3 : 0
        let result = validatePolicy(goal: g, lease: lease(for: g), request: request, now: Date(), spentBudget: spent)
        #expect(failure(result) == expected)
    }

    @Test func explicitRenewalRequiresValidLeaseAndAbsoluteCap() throws {
        let g = goal()
        let now = Date()
        let original = AutonomyLease(goalID: g.goalID, scopeID: g.scopeID, issuedAt: now.addingTimeInterval(-10), expiresAt: now.addingTimeInterval(10))
        let renewed = try original.renewed(until: now.addingTimeInterval(20), now: now, maxUntil: now.addingTimeInterval(30))
        #expect(renewed.issuedAt == original.issuedAt)
        #expect(renewed.expiresAt == now.addingTimeInterval(20))
        #expect(throws: PolicyRenewalError.beyondAbsoluteCap) {
            try original.renewed(until: now.addingTimeInterval(31), now: now, maxUntil: now.addingTimeInterval(30))
        }
        #expect(throws: PolicyRenewalError.notRenewable) {
            try original.renewed(until: now.addingTimeInterval(5), now: now, maxUntil: now.addingTimeInterval(30))
        }
    }

    @Test func revokedAndExpiredLeasesFailClosed() {
        let g = goal()
        #expect(failure(validatePolicy(goal: g, lease: lease(for: g, revoked: true), request: PolicyRequest(capabilityID: "file_read"), now: Date(), spentBudget: 0)) == .leaseRevoked)
        let expired = AutonomyLease(goalID: g.goalID, scopeID: g.scopeID, issuedAt: Date().addingTimeInterval(-10), expiresAt: Date().addingTimeInterval(-1))
        #expect(failure(validatePolicy(goal: g, lease: expired, request: PolicyRequest(capabilityID: "file_read"), now: Date(), spentBudget: 0)) == .leaseExpired)
    }
}
