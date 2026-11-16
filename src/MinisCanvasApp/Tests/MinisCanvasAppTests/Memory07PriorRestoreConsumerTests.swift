import Foundation
import Testing
@testable import MinisCore

struct Memory07PriorRestoreConsumerTests {
@Test func restoreImportIsIdempotentAndKeepsReceiptAcrossRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "restore-session", projectID: "project-1")
        let fact = MemoryFact(
            id: "restore-1",
            text: "可重复恢复",
            sourceSessionID: "source-session",
            category: .lesson
        )
        let firstConsumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let first = try firstConsumer.restoreFacts(
            [fact],
            within: scope,
            mode: .merge,
            reason: "测试导入"
        )
        let bytesAfterFirst = try Data(contentsOf: firstConsumer.store.fileURL)

        let restarted = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let second = try restarted.restoreFacts(
            [fact],
            within: scope,
            mode: .merge,
            reason: "重复导入"
        )

        #expect(second == first)
        #expect(try Data(contentsOf: restarted.store.fileURL) == bytesAfterFirst)
        #expect(try restarted.restoreReceipts().count == 1)
        #expect(try restarted.store.facts().count == 1)
    }

@Test func restoreRejectsConflictingDuplicateWithoutChangingFacts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "restore-session", projectID: "project-1")
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        _ = try consumer.restoreFacts(
            [MemoryFact(id: "same-id", text: "原始内容")],
            within: scope,
            reason: "首次导入"
        )
        let before = try Data(contentsOf: consumer.store.fileURL)

        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            _ = try consumer.restoreFacts(
                [MemoryFact(id: "same-id", text: "冲突内容")],
                within: scope,
                reason: "冲突导入"
            )
        }
        #expect(try Data(contentsOf: consumer.store.fileURL) == before)
        #expect(try consumer.store.facts().map(\.text) == ["原始内容"])
    }

@Test func restoreAcrossStoreInstancesDoesNotLoseFactsOrReceipts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "parallel-restore", projectID: "project-1")
        let consumers = [
            MemoryProposalConsumer(store: MemoryStore(directory: directory)),
            MemoryProposalConsumer(store: MemoryStore(directory: directory))
        ]
        let failures = ConcurrentRestoreFailures()
        let iterations = 96

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let fact = MemoryFact(
                id: "parallel-\(index)",
                text: "并发恢复 \(index)",
                sourceSessionID: scope.sessionID,
                createdAt: Date(timeIntervalSince1970: Double(index + 1))
            )
            do {
                _ = try consumers[index % consumers.count].restoreFacts(
                    [fact],
                    within: scope,
                    mode: .merge,
                    reason: "并发恢复合同"
                )
            } catch {
                failures.append(error)
            }
        }

        #expect(failures.isEmpty)
        let reopenedStore = MemoryStore(directory: directory)
        #expect(try reopenedStore.facts().count == iterations)
        let reopenedConsumer = MemoryProposalConsumer(store: reopenedStore)
        #expect(try reopenedConsumer.restoreReceipts().count == iterations)
    }

    private func temporaryDirectory() throws -> URL {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let url = formal.rootDirectory
            .appendingPathComponent("MemoryProposalConsumerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ConcurrentRestoreFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any Error] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty
    }

    func append(_ error: any Error) {
        lock.lock()
        values.append(error)
        lock.unlock()
    }
}
