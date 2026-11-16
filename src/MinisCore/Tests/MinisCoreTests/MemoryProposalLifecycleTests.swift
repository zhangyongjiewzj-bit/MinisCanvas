import Foundation
import Testing
@testable import MinisCore

struct MemoryProposalLifecycleTests {
    @Test func lifecycleReceiptRoundTripsDeterministically() throws {
        let receipt = MemoryProposalLifecycleReceipt(
            proposalID: "proposal-001",
            scope: .project,
            subjectID: "memory-001",
            action: .propose,
            state: .proposed,
            reason: "candidate memory",
            sequence: 1
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let decoded = try JSONDecoder().decode(MemoryProposalLifecycleReceipt.self, from: data)

        #expect(decoded == receipt)
        #expect(String(data: data, encoding: .utf8) == "{\"action\":\"propose\",\"proposalID\":\"proposal-001\",\"reason\":\"candidate memory\",\"scope\":\"project\",\"sequence\":1,\"state\":\"proposed\",\"subjectID\":\"memory-001\"}")
    }

    @Test(arguments: [
        (MemoryProposalLifecycleAction.propose, MemoryProposalLifecycleState.proposed),
        (.approve, .approved),
        (.reject, .rejected),
        (.activate, .active),
        (.rollback, .rolledBack)
    ])
    func actionHasStableTerminalState(
        _ action: MemoryProposalLifecycleAction,
        _ state: MemoryProposalLifecycleState
    ) {
        let receipt = MemoryProposalLifecycleReceipt(
            proposalID: "p",
            scope: .session,
            subjectID: "m",
            action: action,
            state: state,
            reason: "",
            sequence: 1
        )
        #expect(receipt.action.rawValue == action.rawValue)
        #expect(receipt.state.rawValue == state.rawValue)
    }
}
