import Foundation
import Testing
@testable import MinisCore

@Suite("D-PRIVACY-07 configured secret log sinks")
struct ConfiguredSecretLogRedactionTests {
    private final class MemoryBacking: KeychainBacking, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var reads = 0

        var readCount: Int {
            lock.lock(); defer { lock.unlock() }
            return reads
        }

        func set(_ value: String, forKey key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
            return true
        }

        func get(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return values[key]
        }

        func delete(_ key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: key)
            return true
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfiguredSecretLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func verifySinks(_ logger: LogManager, exclude values: [String]) throws {
        let memory = logger.recentLogsText(limit: 200)
        let file = try #require(logger.logFileURL())
        let disk = try String(contentsOf: file, encoding: .utf8)
        for value in values {
            #expect(!memory.contains(value))
            #expect(!disk.contains(value))
        }
        #expect(memory.contains("visible-context"))
        #expect(disk.contains("visible-context"))
    }

    @Test("configured secret logs leave no four-character secret fragment")
    func shortSecretFragmentsAreAbsentFromMemoryAndDisk() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnvVarStore(directory: directory.appendingPathComponent("env"),
                                keychain: KeychainStore(backing: MemoryBacking()))
        let logger = LogManager(directory: directory.appendingPathComponent("logs"))
        store.attachLogRedaction(to: logger)
        let alphabet = Array("q7B4c9D2e5F8g1H6")
        for length in [8, 9, 11, 12, 16] {
            let secret = String(alphabet.prefix(length))
            #expect(store.setEnvVar(name: "PRIVATE_VALUE", value: secret, isSecret: true))
            logger.info("visible-context \(secret)", category: "synthetic")
            let memory = logger.recentLogsText(limit: 200)
            let file = try #require(logger.logFileURL())
            let disk = try String(contentsOf: file, encoding: .utf8)
            let characters = Array(secret)
            for start in 0...(characters.count - 4) {
                let fragment = String(characters[start..<(start + 4)])
                #expect(!memory.contains(fragment))
                #expect(!disk.contains(fragment))
            }
        }
    }

    @Test("rotation and deletion do not expose delayed values in either sink")
    func rotatedAndDeletedValuesRemainProtected() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = MemoryBacking()
        let store = EnvVarStore(directory: directory.appendingPathComponent("env"),
                                keychain: KeychainStore(backing: backing))
        let logger = LogManager(directory: directory.appendingPathComponent("logs"))
        store.attachLogRedaction(to: logger)
        let first = "violet-marker-\(UUID().uuidString)"
        let second = "amber-marker-\(UUID().uuidString)"
        #expect(store.setEnvVar(name: "PRIVATE_VALUE", value: first, isSecret: true))
        #expect(store.setEnvVar(name: "PRIVATE_VALUE", value: second, isSecret: true))
        #expect(store.deleteEnvVar(name: "PRIVATE_VALUE"))
        logger.info("visible-context \(first) \(second)", category: first, eventID: second)
        try verifySinks(logger, exclude: [first, second])
        #expect(backing.readCount == 0)
    }

    @Test("attaching sinks uses in-memory values and leaves ordinary text visible")
    func existingValuesReachEveryAttachedSink() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = MemoryBacking()
        let store = EnvVarStore(directory: directory.appendingPathComponent("env"),
                                keychain: KeychainStore(backing: backing))
        let value = "violet-marker-\(UUID().uuidString)"
        #expect(store.setEnvVar(name: "PRIVATE_VALUE", value: value, isSecret: true))
        #expect(store.setEnvVar(name: "PUBLIC_VALUE", value: "visible-context", isSecret: false))
        let first = LogManager(directory: directory.appendingPathComponent("first"))
        let second = LogManager(directory: directory.appendingPathComponent("second"))
        store.attachLogRedaction(to: first)
        store.attachLogRedaction(to: first)
        store.attachLogRedaction(to: second)
        for logger in [first, second] {
            logger.info("visible-context \(value)")
            try verifySinks(logger, exclude: [value])
        }
        #expect(backing.readCount == 0)
    }

    @Test("attachment does not resolve a deferred credential; its authorized read registers it")
    func deferredReadRegistersBeforeReturning() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = MemoryBacking()
        let keychain = KeychainStore(backing: backing)
        let envDirectory = directory.appendingPathComponent("env")
        let original = EnvVarStore(directory: envDirectory, keychain: keychain)
        let value = "violet-marker-\(UUID().uuidString)"
        #expect(original.setEnvVar(name: "PRIVATE_VALUE", value: value, isSecret: true))
        let reloaded = EnvVarStore(directory: envDirectory, keychain: keychain)
        let logger = LogManager(directory: directory.appendingPathComponent("logs"))
        let readsBefore = backing.readCount
        reloaded.attachLogRedaction(to: logger)
        #expect(backing.readCount == readsBefore)
        #expect(reloaded.allEnvVars.first?.value.isEmpty == true)
        let resolved = await reloaded.getEnvVarAsync(name: "PRIVATE_VALUE")
        #expect(resolved == value)
        logger.info("visible-context \(try #require(resolved))")
        try verifySinks(logger, exclude: [value])
    }

    @Test("concurrent registration and append preserve complete redacted records")
    func concurrentLogSinks() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = LogManager(directory: directory, maxFileSize: 1_000_000, ringCapacity: 128)
        let values = (0..<64).map { "violet-marker-\($0)-\(UUID().uuidString)" }
        await withTaskGroup(of: Void.self) { group in
            for (index, value) in values.enumerated() {
                group.addTask {
                    logger.registerKnownSecrets([value])
                    logger.info("visible-context \(value)", eventID: "event-\(index)")
                }
            }
        }
        let entries = logger.recentLogs()
        #expect(entries.count == values.count)
        #expect(Set(entries.map(\.eventID)).count == values.count)
        let file = try #require(logger.logFileURL())
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == values.count)
        try verifySinks(logger, exclude: values)
    }
}
