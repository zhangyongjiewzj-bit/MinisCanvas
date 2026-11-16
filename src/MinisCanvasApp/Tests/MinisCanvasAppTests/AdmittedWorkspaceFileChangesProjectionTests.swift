import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Recorded workspace roots in file change consumers")
struct AdmittedWorkspaceFileChangesProjectionTests {
    @Test func inspectorAndTaskCenterUseRecordRootAfterProjectSelectionChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("record-root-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = FileChangeLedger(workspaceRoot: "/synthetic/project-a", rootsProvider: {
            [URL(fileURLWithPath: "/synthetic/project-a"), URL(fileURLWithPath: "/synthetic/project-b")]
        })
        let facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        for (index, directory) in ["/synthetic/project-a", "/synthetic/project-b"].enumerated() {
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: "synthetic-session", turnID: index + 1, messageID: "m\(index)"),
                operationID: "op\(index)", attempt: 1)
            let receipt = try facts.mint(toolCallID: "call\(index)", toolName: "file_write",
                attemptID: "attempt\(index)", attemptNumber: 1, executionIdentity: identity)
            let record = try ledger.register(sessionID: "synthetic-session", path: directory + "/note.txt",
                kind: .created, oldContent: nil, newContent: "same content", producerReceipt: receipt)
            _ = try facts.settle(receipt, status: .succeeded)
            let access = TaskCenterFileArtifactAccess(record: record, workspaceRoot: ledger.workspaceRoot)
            #expect(access.workspaceRoot == directory)
        }
        let changes = TurnFileChangesProjection.capture(sessionID: "synthetic-session", ledger: ledger,
            facts: facts.facts, redact: { $0 })
        #expect(changes.map(\.absolutePath) == ["/synthetic/project-a/note.txt", "/synthetic/project-b/note.txt"])
        #expect(Set(changes.map(\.id)).count == 2)
    }
}
