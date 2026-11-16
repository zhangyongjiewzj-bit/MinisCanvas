import Foundation
import Testing
@testable import MinisCore

private actor NestedComposerApprovalProbe: ApprovalDelegate {
    let approves: Bool
    private var requests: [ApprovalRequest] = []
    init(approves: Bool) { self.approves = approves }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return .init(approved: approves, reason: "synthetic decision", confirmed: approves,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
    func count() -> Int { requests.count }
}

private actor NestedComposerEffectProbe: ToolExecutor {
    private var receipts: [ToolExecutionReceipt] = []
    nonisolated func execute(name: String, input: [String: Any]) async throws -> String {
        guard let receipt = ToolExecutionReceiptContext.current, receipt.toolName == name else {
            throw ToolExecutionFactLedgerError.receiptIdentityMismatch
        }
        await record(receipt)
        return #"{"exit_code":0,"stdout":"synthetic result","stderr":""}"#
    }
    private func record(_ receipt: ToolExecutionReceipt) { receipts.append(receipt) }
    func observedReceipts() -> [ToolExecutionReceipt] { receipts }
}

@Suite("P03 real Composer nested command authorization")
struct NestedComposerShellConsumerTests {
    private struct Fixture: Sendable {
        let directory: URL
        let snapshot: ComposerSubmissionSnapshot
        let ledger: ToolExecutionFactLedger
        let parent: ToolExecutionReceipt
        let effect: NestedComposerEffectProbe
        let approval: NestedComposerApprovalProbe
        let composer: ComposerPolicyEnforcedToolExecutor
        init(mode: ComposerTaskMode = .bypassPermission, approves: Bool = false,
             denied: Bool = false, revoked: Bool = false, expired: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("nested-composer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            snapshot = .init(mode: mode, approvalScope: .session, effort: .standard,
                sessionID: "session", turnID: 1, taskID: "task", messageID: "message",
                workspaceID: "workspace", createdAt: now, policyRevision: "revision",
                grantEpoch: "epoch", bypassModeConfirmed: mode == .bypassPermission, autonomyCeiling: .l3)
            let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"],
                grantedCapabilities: ["shell_execute"], allowedWriteRoots: [directory.path],
                workspaceID: "workspace", revision: "revision", grantEpoch: "epoch", leaseID: "lease",
                expiresAt: now.addingTimeInterval(expired ? -1 : 300), revoked: revoked, autonomyCeiling: .l3)
            ledger = try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json"))
            let identity = AgentExecutionIdentity(turn: .init(sessionID: snapshot.sessionID,
                turnID: snapshot.turnID, messageID: snapshot.messageID), operationID: "operation", attempt: 1)
            parent = try ledger.mint(toolCallID: "parent", toolName: OrchestrationToolExecutor.toolName,
                attemptID: try #require(AgentToolExecutionAttemptID.canonical(executionIdentity: identity,
                    composerSnapshot: snapshot, childBoundary: nil)), attemptNumber: 1, executionIdentity: identity)
            effect = NestedComposerEffectProbe()
            approval = NestedComposerApprovalProbe(approves: approves)
            composer = ComposerPolicyEnforcedToolExecutor(base: effect,
                controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
                approvalGate: ApprovalGate(policyByTool: denied ? ["shell_execute": .deny] : [:], delegate: approval))
        }
    }

    @Test func confirmedNestedCallsHaveSeparateReceiptsWithoutPrompt() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let input: [String: Any] = ["command": "git status --short", "cwd": f.directory.path]
        try await ToolExecutionReceiptContext.$current.withValue(f.parent) {
        try await ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            _ = try await f.composer.executeNestedShell(callID: "first", input: input)
            _ = try await f.composer.executeNestedShell(callID: "second", input: input)
            #expect(ToolExecutionReceiptContext.current == f.parent)
        }
        }
        #expect(await f.approval.count() == 0)
        let receipts = await f.effect.observedReceipts()
        #expect(receipts.map(\.toolCallID) == ["first", "second"])
        #expect(receipts.allSatisfy { $0.toolName == "shell_execute" && $0.executionIdentity == f.parent.executionIdentity })
        #expect(f.ledger.pendingReceipts == [f.parent])
        #expect(f.ledger.facts.filter { $0.status == .succeeded }.count == 2)
    }

    @Test(arguments: [true, false])
    func manualNestedCallsRequireFreshHumanApproval(approves: Bool) async throws {
        let f = try Fixture(mode: .manual, approves: approves)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let input: [String: Any] = ["command": "git status --short", "cwd": f.directory.path]
        try await ToolExecutionReceiptContext.$current.withValue(f.parent) {
            try await ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
                for callID in ["first", "second"] {
                    if approves {
                        _ = try await f.composer.executeNestedShell(callID: callID, input: input)
                    } else {
                        await #expect(throws: (any Error).self) {
                            _ = try await f.composer.executeNestedShell(callID: callID, input: input)
                        }
                    }
                }
            }
        }
        #expect(await f.approval.count() == 2)
        #expect(await f.effect.observedReceipts().map(\.toolCallID) == (approves ? ["first", "second"] : []))
        #expect(f.ledger.pendingReceipts == [f.parent])
        #expect(f.ledger.facts.filter { $0.status == .succeeded }.count == (approves ? 2 : 0))
    }

    enum DenialCondition: String, CaseIterable {
        case policyDenied, revoked, expired
    }

    @Test(arguments: DenialCondition.allCases)
    func denyRevokedOrExpiredAuthorityCannotReachTheEffect(condition: DenialCondition) async throws {
        let f = try Fixture(denied: condition == .policyDenied, revoked: condition == .revoked,
                            expired: condition == .expired)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        await ToolExecutionReceiptContext.$current.withValue(f.parent) {
        await ToolExecutionReceiptContext.$ledger.withValue(f.ledger) {
            await #expect(throws: (any Error).self) {
                _ = try await f.composer.executeNestedShell(callID: "blocked",
                    input: ["command": "git status --short", "cwd": f.directory.path])
            }
        }
        }
        #expect(await f.approval.count() == 0)
        #expect((await f.effect.observedReceipts()).isEmpty)
        #expect(f.ledger.pendingReceipts == [f.parent])
        #expect(f.ledger.facts.isEmpty)
    }
}
