import Foundation
import Testing
@testable import MinisCore

private func makeTempDir() throws -> URL {
    let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let url = formal.rootDirectory
        .appendingPathComponent("MinisCore-MemoryManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct Memory07PriorManagerImportTests {
@Test func exportImportRoundTripsAcrossStores() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = MemoryStore(directory: dir.appendingPathComponent("src"))
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        let f1 = try source.addFact(
            "用户喜欢晴天",
            sourceSessionID: "s1",
            category: .userPref,
            memoryScope: scope
        )
        let f2 = try source.addFact(
            "密码要存钥匙串",
            sourceSessionID: "s2",
            category: .security,
            memoryScope: scope
        )

        let manager = MemoryManager(store: source)
        let data = try manager.export()

        let target = MemoryStore(directory: dir.appendingPathComponent("dst"))
        let targetManager = MemoryManager(store: target)
        let imported = try targetManager.importJSON(data, within: scope)

        #expect(imported == 2)
        let facts = try target.facts()
        #expect(facts.count == 2)
        // id / createdAt / category / sourceSessionID all preserved.
        #expect(facts.contains(f1))
        #expect(facts.contains(f2))
    }

@Test func importJSONDedupesById() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        let fact = try store.addFact(
            "已有的记忆",
            sourceSessionID: "s1",
            category: .lesson,
            memoryScope: scope
        )

        let manager = MemoryManager(store: store)
        let data = try manager.export()

        // Re-importing the same payload must not duplicate.
        #expect(try manager.importJSON(data, within: scope) == 0)
        #expect(try store.facts().count == 1)

        // Merging a payload with one new + one duplicate only adds the new one.
        let payload = try JSONEncoder().encode([fact, MemoryFact(text: "新记忆", sourceSessionID: "s2")])
        #expect(try manager.importJSON(payload, within: scope) == 1)
        #expect(try store.facts().count == 2)
    }

@Test func importJSONSkipsEmptyTextFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let manager = MemoryManager(store: store)
        let payload = try JSONEncoder().encode([MemoryFact(text: "   "), MemoryFact(text: "有效记忆")])
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        #expect(throws: MemoryProposalConsumerError.invalidText) {
            try manager.importJSON(payload, within: scope)
        }
        #expect(try store.facts().isEmpty)
    }

@Test func importJSONRejectsCorruptFactsWithoutOverwriting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{\"corrupt\":true}".utf8)
        try original.write(to: store.fileURL)

        let manager = MemoryManager(store: store)
        let payload = try JSONEncoder().encode([MemoryFact(text: "不得覆盖")])
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        #expect(throws: (any Error).self) {
            try manager.importJSON(payload, within: scope)
        }
        #expect(try Data(contentsOf: store.fileURL) == original)
    }
}
