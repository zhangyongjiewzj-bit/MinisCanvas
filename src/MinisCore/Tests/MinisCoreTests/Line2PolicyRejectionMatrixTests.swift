import Foundation
import Testing
@testable import MinisCore

struct Line2PolicyRejectionMatrixTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func goal(
        level: AutonomyLevel = .l3,
        roots: [String] = ["/tmp/line2-work"],
        domains: Set<String> = ["example.com"],
        budget: Int = 10,
        deadline: Date? = nil,
        concurrency: Int = 2
    ) -> GoalEnvelope {
        GoalEnvelope(
            scopeID: "task:line2",
            allowedCapabilities: ["file_read", "browser", "shell_execute"],
            fileRoots: roots,
            networkDomains: domains,
            budget: budget,
            deadline: deadline ?? now.addingTimeInterval(60),
            concurrencyLimit: concurrency,
            autonomyLevel: level,
            creatorID: "user:test",
            createdAt: now.addingTimeInterval(-1)
        )
    }

    private func lease(for goal: GoalEnvelope, scopeID: String? = "task:line2") -> AutonomyLease {
        AutonomyLease(
            goalID: goal.goalID,
            scopeID: scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30)
        )
    }

    private func violation(
        goal: GoalEnvelope,
        lease: AutonomyLease? = nil,
        request: PolicyRequest,
        spent: Int = 0,
        at date: Date? = nil
    ) -> PolicyViolation? {
        let result = validatePolicy(
            goal: goal,
            lease: lease ?? self.lease(for: goal),
            request: request,
            now: date ?? now,
            spentBudget: spent
        )
        guard case .failure(let error) = result else { return nil }
        return error
    }

    @Test func l0ThroughL3AreOrderedAndEnvelopeIsBounded() throws {
        #expect(AutonomyLevel.l0 < .l1)
        #expect(AutonomyLevel.l2 < .l3)
        let envelope = goal(level: .l2)
        #expect(envelope.level == .l2)
        #expect(violation(goal: envelope, request: PolicyRequest(capabilityID: "shell_execute", autonomyLevel: .l3)) == .autonomyLevelExceeded)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(GoalEnvelope.self, from: data)
        #expect(decoded == envelope)
    }

    @Test(arguments: [
        ("/tmp/line2-work-other/file.txt", PolicyViolation.fileRootNotAllowed),
        ("/tmp/line2-work/../outside.txt", PolicyViolation.fileRootNotAllowed),
        ("relative.txt", PolicyViolation.fileRootNotAllowed),
    ])
    func fileRootBoundariesRejectTraversalAndPrefixConfusion(input: (String, PolicyViolation)) {
        let g = goal()
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read", filePath: input.0)) == input.1)
    }

    @Test func domainMatchingUsesHostBoundaries() {
        let g = goal()
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "browser", networkDomain: "API.Example.com")) == nil)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "browser", networkDomain: "example.com.evil")) == .networkDomainNotAllowed)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "browser", networkDomain: "https://example.com")) == .invalidNetworkDomain)
    }

    @Test func scopeBudgetDeadlineConcurrencyAndUnknownCapabilityReject() {
        let g = goal()
        let emptyScope = GoalEnvelope(
            scopeID: "   ",
            allowedCapabilities: ["file_read"],
            budget: 1,
            deadline: now.addingTimeInterval(60)
        )
        #expect(violation(goal: emptyScope, request: PolicyRequest(capabilityID: "file_read")) == .emptyScope)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read", scopeID: "task:other")) == .scopeMismatch)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "unknown")) == .capabilityNotAllowed)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read", estimatedCost: 11)) == .budgetExceeded)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read", activeTasks: 2)) == .concurrencyExceeded)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read", requestedUntil: now.addingTimeInterval(120))) == .requestDeadlineExceeded)
        #expect(violation(goal: g, request: PolicyRequest(capabilityID: "file_read"), spent: -1) == .invalidBudget)
        #expect(violation(goal: goal(deadline: now), request: PolicyRequest(capabilityID: "file_read")) == .deadlineExceeded)
        #expect(violation(goal: goal(roots: ["relative-root"]), request: PolicyRequest(capabilityID: "file_read")) == .invalidFileRoot)
        #expect(violation(goal: goal(domains: ["bad/domain"]), request: PolicyRequest(capabilityID: "file_read")) == .invalidNetworkDomain)
    }

    @Test func leaseIsBoundToGoalScopeAndRevocation() {
        let g = goal()
        let otherGoal = goal()
        #expect(violation(goal: g, lease: AutonomyLease(goalID: g.goalID, issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(30)), request: PolicyRequest(capabilityID: "file_read")) == .scopeMismatch)
        #expect(violation(goal: g, lease: lease(for: g, scopeID: "task:other"), request: PolicyRequest(capabilityID: "file_read")) == .scopeMismatch)
        #expect(violation(goal: g, lease: lease(for: otherGoal), request: PolicyRequest(capabilityID: "file_read")) == .leaseGoalMismatch)

        var revoked = lease(for: g)
        revoked.revoke()
        #expect(violation(goal: g, lease: revoked, request: PolicyRequest(capabilityID: "file_read")) == .leaseRevoked)
        #expect(violation(goal: g, lease: AutonomyLease(goalID: g.goalID, scopeID: g.scopeID, issuedAt: now.addingTimeInterval(-20), expiresAt: now.addingTimeInterval(-1)), request: PolicyRequest(capabilityID: "file_read")) == .leaseExpired)
    }

    @Test func approvalMatrixUsesInputAndFailsClosedForUnknownTools() async {
        let gate = ApprovalGate()
        #expect(gate.shouldAsk(tool: "file_read", input: ["path": "/tmp/line2-work/.env"]))
        #expect(gate.makeRequest(tool: "file_read", input: ["path": "/tmp/line2-work/.env"]).inputRiskLevel == .high)
        #expect(gate.makeRequest(tool: "file_write", input: ["path": "/tmp/line2-work/a.txt"]).requiresSecondConfirmation)

        await #expect(throws: ApprovalError.denied(reason: "Input requires approval for tool 'file_read'")) {
            try await gate.gate(tool: "file_read", input: ["path": "/tmp/line2-work/.env"])
        }
        await #expect(throws: ApprovalError.denied(reason: "L3 requires second confirmation")) {
            try await ApprovalGate(delegate: ApprovalDecisionDelegate(decision: ApprovalDecision(approved: true)))
                .gate(tool: "file_write", input: ["path": "/tmp/line2-work/a.txt"])
        }
        await #expect(throws: ApprovalError.denied(reason: "Unknown capability 'mcp_unregistered' is blocked")) {
            try await gate.gate(tool: "mcp_unregistered", input: [:])
        }
        await #expect(throws: ApprovalError.denied(reason: "Unknown capability 'mcp_unregistered' is blocked")) {
            try await gate.gate(tool: "mcp_unregistered", input: [:], delegate: ApprovalDecisionDelegate())
        }
    }

    @Test func summariesDoNotBecomePromptInjectionOrSecretChannels() {
        let summary = ApprovalGate.makeInputSummary([
            "authorization": "Bearer should-not-appear",
            "nested": ["token": "nested-secret"],
            "note": "line one\nline two",
        ])
        #expect(!summary.contains("should-not-appear"))
        #expect(!summary.contains("nested-secret"))
        #expect(!summary.contains("\n"))
    }

    @Test func invalidBudgetConfigurationFailsBeforeReservation() async {
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: -1))
        await #expect(throws: BudgetTrackerError.invalidConfiguration) {
            _ = try await tracker.beginRequest()
        }
    }

    @Test func turnHandlesCancelAndRevokeOnlyTheirOwnCapabilities() async {
        let controller = TurnController()
        let first = await controller.beginTurn()
        let second = await controller.beginTurn()
        let authorization = await first.issueSessionReadAuthorization(
            currentConversationID: "conversation",
            authorizedSessionID: "session",
            issuedAt: now,
            lifetime: 30
        )

        await first.interrupt()
        #expect(await first.isCancelled())
        #expect(await second.isCancelled() == false)
        #expect(authorization.isActive == false)
        await second.revoke()
        #expect(await second.isCancelled())
        await first.finish()
        await second.finish()
        #expect(await controller.isRunning == false)
    }
}

private struct ApprovalDecisionDelegate: ApprovalDelegate {
    let decision: ApprovalDecision

    init(decision: ApprovalDecision = .approve) {
        self.decision = decision
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision { decision }
}
