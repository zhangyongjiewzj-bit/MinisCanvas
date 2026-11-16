import Foundation
import Testing
@testable import MinisCore

struct A5BoundaryNegativeTests {
    @Test
    func importWithMismatchedFactScopeRejectsAtomically() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MemoryStore(directory: directory)
        let activeScope = MemoryScope(sessionID: "chat-a", projectID: "project-a")
        let foreignScope = MemoryScope(sessionID: "chat-b", projectID: "project-a")
        try store.addFact("必须保留", sourceSessionID: activeScope.sessionID, memoryScope: activeScope)
        let before = try Data(contentsOf: store.fileURL)
        let payload = try JSONEncoder().encode([
            MemoryFact(
                id: "foreign",
                text: "越界事实",
                sourceSessionID: foreignScope.sessionID,
                memoryScope: foreignScope
            )
        ])

        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            try MemoryManager(store: store).importJSON(payload, within: activeScope)
        }
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try store.facts().map(\.text) == ["必须保留"])
    }

    @Test
    func restoreAgainstCorruptFactsFailsClosedAndKeepsBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let memoryStore = MemoryStore(directory: directory)
        try FileManager.default.createDirectory(
            at: memoryStore.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("{\"facts\":\"not-an-array\"}".utf8)
        try corrupt.write(to: memoryStore.fileURL, options: .atomic)

        let manager = SyncManager(
            sessionStore: SessionStore(directory: directory),
            memoryStore: memoryStore,
            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills")),
            settingsStore: SettingsStore(directory: directory)
        )
        let scope = MemoryScope(sessionID: "chat-a", projectID: "project-a")
        let envelope = SyncSnapshotEnvelope(
            manifest: SyncManifest(deviceName: "boundary-test", scopes: ["memories"]),
            memories: [MemoryFact(text: "不得覆盖")]
        )

        #expect(throws: SyncImportError.self) {
            try manager.importSnapshot(
                JSONEncoder().encode(envelope),
                memoryScope: scope
            )
        }
        #expect(try Data(contentsOf: memoryStore.fileURL) == corrupt)
    }

    @Test
    func replaceRestoresOnlyTargetScopeAndReceiptIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MemoryStore(directory: directory)
        let target = MemoryScope(sessionID: "chat-a", projectID: "project-a")
        let other = MemoryScope(sessionID: "chat-b", projectID: "project-a")
        try store.addFact("目标旧事实", sourceSessionID: target.sessionID, memoryScope: target)
        try store.addFact("其他范围事实", sourceSessionID: other.sessionID, memoryScope: other)

        let payload = try JSONEncoder().encode([
            MemoryFact(id: "target-new", text: "目标新事实", sourceSessionID: target.sessionID)
        ])
        let facts = try JSONDecoder().decode([MemoryFact].self, from: payload)
        let consumer = MemoryProposalConsumer(store: store)
        #expect(
            try consumer.restoreFacts(
                facts,
                within: target,
                mode: .replace,
                reason: "boundary test"
            ).receipt.added == 1
        )
        #expect(
            try consumer.restoreFacts(
                facts,
                within: target,
                mode: .replace,
                reason: "boundary test retry"
            ).receipt.added == 1
        )
        #expect(try store.facts().map(\.text).sorted() == ["其他范围事实", "目标新事实"])
        #expect(try consumer.restoreReceipts().count == 1)
        #expect(try consumer.envelopes().isEmpty)
    }

    @Test
    func defaultChatToolCatalogDoesNotOptIntoCanvasOrchestration() {
        let names = Set(AgentToolCatalog.makeTools().map(\.name))
        #expect(!names.contains("canvas_mutation"))
        #expect(!names.contains("canvas_read"))
        #expect(!names.contains(OrchestrationToolExecutor.toolName))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-A5Boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
