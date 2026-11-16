import Foundation
import Testing
@testable import MinisCore

@Suite("AgentProvider current durable schema preservation")
struct AgentProviderCurrentSchemaPreservation2757Tests {
    @Test("Unknown current-schema input cannot be silently erased by writer takeover",
          arguments: ["root", "pending", "fact", "file-write"])
    func unknownFieldFailsClosedBeforeTakeover(_ location: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-provider-schema2757-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("facts.json")
        let first = try ToolExecutionFactLedger(persistenceURL: url)
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "synthetic-session", turnID: 1,
                                    messageID: "synthetic-message"),
            operationID: "synthetic-operation", attempt: 1)
        let completed = try first.mint(toolCallID: "completed", toolName: "web_search",
                                       attemptID: "synthetic-attempt", attemptNumber: 1,
                                       executionIdentity: identity)
        _ = try #require(try first.settle(completed, status: .succeeded))
        _ = try first.mint(toolCallID: "queued", toolName: "web_search",
                           attemptID: "synthetic-attempt", attemptNumber: 1,
                           executionIdentity: identity)
        let write = try first.mint(toolCallID: "write", toolName: "file_write",
                                   attemptID: "synthetic-attempt", attemptNumber: 1,
                                   executionIdentity: identity)
        try first.beginFileWrite(write, targetPath: root.appendingPathComponent("target.txt").path,
                                 expectedSHA256: "synthetic-digest", beforeSHA256: nil)

        var disk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any])
        #expect(disk["schemaVersion"] as? Int == 6)
        switch location {
        case "root":
            disk["unrecognizedTransaction"] = "synthetic-future-field"
        case "pending", "fact":
            let collection = location == "pending" ? "pending" : "facts"
            var records = try #require(disk[collection] as? [String: Any])
            let key = try #require(records.keys.first)
            var record = try #require(records[key] as? [String: Any])
            record["unrecognizedTransaction"] = "synthetic-future-field"
            records[key] = record
            disk[collection] = records
        case "file-write":
            var records = try #require(disk["fileWrites"] as? [String: Any])
            let key = try #require(records.keys.first)
            var evidence = try #require(records[key] as? [String: Any])
            evidence["unrecognizedTransaction"] = "synthetic-future-field"
            records[key] = evidence
            disk["fileWrites"] = records
        default:
            Issue.record("Unexpected test input")
            return
        }
        let injected = try JSONSerialization.data(withJSONObject: disk, options: [.sortedKeys])
        try injected.write(to: url)

        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == injected)
        #expect(first.facts.count == 1 && first.pendingReceipts.count == 2)
    }
}
