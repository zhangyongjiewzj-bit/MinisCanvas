import Foundation
import Testing
import CryptoKit
import Darwin
@testable import MinisCore
@testable import MinisCanvasApp

private struct Safe2295NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

@Suite("SAFE2 selected recovery with unavailable unselected recall2295", .serialized)
@MainActor
struct SafeSelectedRecoveryConsumer2295Tests {
    private let sessionID = "599CAF48-D21A-46CC-A05A-59E199522995"
    private var scope: MemoryScope { .init(sessionID: sessionID, projectID: "safe2295-owned") }
    private func root() throws -> URL {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal).appendingPathComponent("Safe2295-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
    private func center(_ root: URL) -> SettingsCenter {
        let core = root.appendingPathComponent("core"), chat = root.appendingPathComponent("chat")
        let keys = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(settingsStore: SettingsStore(directory: core),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keys),
            memoryStore: MemoryStore(directory: chat), memoryFileStore: MemoryFileStore(directory: chat),
            sessionStore: SessionStore(directory: chat),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keys),
            skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Safe2295NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        center.memoryScopeProvider = { scope }
        return center
    }
    private struct Fixture {
        let source: SettingsCenter
        let target: SettingsCenter
        let targetRoot: URL
        let snapshot: URL
        let memoryFile: URL
        let memoryBytes: Data
    }
    private func fixture(damaged: Bool, backupDomain: SyncScope = .sessions) throws -> Fixture {
        let root = try root()
        let source = center(root.appendingPathComponent("source"))
        var session = try source.sessionStore.createSession(id: sessionID, title: "safe2295 source")
        session.messages = [LLMMessage(role: .assistant, content: "SAFE2295 restored actual session")]
        try source.sessionStore.updateSession(session)
        _ = try source.memoryStore.addFact("safe2295 source memory", sourceSessionID: sessionID, memoryScope: scope)
        let bytes = try source.syncManager.exportSnapshot(scopes: [backupDomain])
        let snapshot = root.appendingPathComponent("owned.minissync")
        try bytes.write(to: snapshot)
        let targetRoot = root.appendingPathComponent("target")
        let target = center(targetRoot)
        _ = try target.sessionStore.createSession(id: sessionID, title: "safe2295 target")
        _ = try target.memoryStore.addFact("safe2295 target memory", sourceSessionID: sessionID, memoryScope: scope)
        target.enableSafeMode()
        target.engageKillSwitch()
        #expect(target.optionalModulesDisabled && target.chatBackupRecoveryRemainEnabled)
        // MemoryStore itself has no optional enable flag. The original restore
        // domain selection, not an invented toggle, excludes this failed recall.
        let memoryFile = target.memoryStore.directory.appendingPathComponent("memory/facts.json")
        if damaged { try Data("unreadable-as-memory-json-safe2295".utf8).write(to: memoryFile) }
        let memoryBytes = try Data(contentsOf: memoryFile)
        if damaged { #expect(throws: DecodingError.self) { try target.memoryStore.facts() } }
        else { #expect(try target.memoryStore.facts().count == 1) }
        return Fixture(source: source, target: target, targetRoot: targetRoot,
            snapshot: snapshot, memoryFile: memoryFile, memoryBytes: memoryBytes)
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private struct Reopen: Codable {
        let root: URL
        let layout: SyncAtomicImport.Layout
        let sessionID: String
        let parentPID: Int32
        let nonce: String
        let memoryHash: String
        let recallDamaged: Bool
        let journal: URL
        let journalHash: String
        let proof: URL
    }
    private struct Proof: Codable {
        let nonce: String
        let parentPID: Int32
        let childPID: Int32
        let recoveredBeforeSessionStore: Bool
    }
    private func freshReopen(_ f: Fixture, receipt: SyncAtomicImportReceipt, recallDamaged: Bool) throws {
        let args = CommandLine.arguments
        let executable = try #require(args.first)
        try #require(executable.hasSuffix("/MinisCanvasOriginalAppMain"))
        try #require(FileManager.default.isExecutableFile(atPath: executable))
        let evidence = f.targetRoot.appendingPathComponent("child-evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let request = Reopen(root: f.targetRoot, layout: try SyncAtomicImport(manager: f.target.syncManager).layout,
            sessionID: sessionID, parentPID: getpid(),
            nonce: UUID().uuidString, memoryHash: digest(f.memoryBytes), recallDamaged: recallDamaged, journal: receipt.journalURL,
            journalHash: digest(try Data(contentsOf: receipt.journalURL)), proof: evidence.appendingPathComponent("proof.json"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--testing-library", "swift-testing",
            "--filter", "selectedRecoveryChild2295\\(\\)"]
        var environment = ProcessInfo.processInfo.environment
        environment["SAFE2295_REOPEN"] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let log = evidence.appendingPathComponent("child.raw.log")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let timeout = done.wait(timeout: .now() + 20) != .success
        if timeout {
            process.terminate()
            if done.wait(timeout: .now() + 2) != .success { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try handle.synchronize()
        try Data("\(process.terminationStatus)\n".utf8).write(to: evidence.appendingPathComponent("child.REAL_EXIT"))
        let raw = try String(contentsOf: log, encoding: .utf8)
        try #require(!timeout && process.terminationStatus == 0)
        try #require(raw.contains("Test selectedRecoveryChild2295() passed after"))
        try #require(raw.contains("Test run with 1 test in 1 suite passed"))
        let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: request.proof))
        #expect(proof.nonce == request.nonce && proof.parentPID == getpid())
        #expect(proof.childPID == process.processIdentifier && proof.childPID != getpid())
        #expect(proof.recoveredBeforeSessionStore)
        print("SAFE2295_CHILD path=\(log.path) sha256=\(digest(Data(raw.utf8))) REAL_EXIT=\(process.terminationStatus)")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAFE2295_REOPEN"] != nil))
    func selectedRecoveryChild2295() throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["SAFE2295_REOPEN"])
        let request = try JSONDecoder().decode(Reopen.self, from: #require(Data(base64Encoded: encoded)))
        try #require(getpid() != request.parentPID)
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let canonical = request.root.resolvingSymlinksInPath().standardizedFileURL
        try #require(canonical.path.hasPrefix(URL(fileURLWithPath: formal).resolvingSymlinksInPath().path + "/"))
        try #require(canonical.lastPathComponent == "target")
        let ownerName = canonical.deletingLastPathComponent().lastPathComponent
        try #require(ownerName.hasPrefix("Safe2295-"))
        try #require(UUID(uuidString: String(ownerName.dropFirst("Safe2295-".count))) != nil)
        try #require(request.sessionID == sessionID && UUID(uuidString: request.nonce) != nil)
        // Carry the real producer layout into startup recovery, including any
        // optional metadata routes supplied by the ordinary SettingsCenter.
        let layout = request.layout
        try #require(layout.sessionDirectory.path == canonical.appendingPathComponent("chat").path)
        try #require(layout.memoryDirectory.path == canonical.appendingPathComponent("chat").path)
        try #require(layout.settingsDirectory.path == canonical.appendingPathComponent("core").path)
        try #require(layout.skillsRoot.path == canonical.appendingPathComponent("core/skills").path)
        try #require(request.journal.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/"))
        try #require(request.proof.resolvingSymlinksInPath().path.hasPrefix(canonical.path + "/"))
        try #require(digest(Data(contentsOf: request.journal)) == request.journalHash)
        try SyncAtomicImport.recoverBeforeStores(layout: layout)
        let session = try #require(SessionStore(directory: request.root.appendingPathComponent("chat")).loadSession(id: request.sessionID))
        #expect(session.title == "safe2295 source")
        #expect(session.messages.map(\.content) == ["SAFE2295 restored actual session"])
        #expect(digest(try Data(contentsOf: request.root.appendingPathComponent("chat/memory/facts.json"))) == request.memoryHash)
        let reopenedRecall = MemoryStore(directory: request.root.appendingPathComponent("chat"))
        if request.recallDamaged {
            #expect(throws: DecodingError.self) { try reopenedRecall.facts() }
        } else {
            #expect(try reopenedRecall.facts().map(\.text) == ["safe2295 target memory"])
        }
        try JSONEncoder().encode(Proof(nonce: request.nonce, parentPID: request.parentPID,
            childPID: getpid(), recoveredBeforeSessionStore: true)).write(to: request.proof)
    }
    private func restoreSessions(damaged: Bool) async throws {
        let f = try fixture(damaged: damaged)
        let draft = try f.target.readAtomicBackupDraft(from: f.snapshot)
        let preview = try f.target.previewAtomicBackup(draft, selecting: [.sessions], memoryScope: nil)
        #expect(preview.selected == [.sessions] && preview.domains.map(\.scope) == [.sessions])
        let receipt = try await f.target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        #expect(receipt.committed && receipt.reopenRequired && receipt.selected == [.sessions])
        #expect(try Data(contentsOf: f.memoryFile) == f.memoryBytes)
        // A committed atomic transaction deliberately retires the old store
        // generation. The fresh child above owns actual recall decoding.
        #expect(throws: PersistenceTransactionError.reopenRequired) { try f.target.memoryStore.facts() }
        try freshReopen(f, receipt: receipt, recallDamaged: damaged)
    }
    @Test func sessionsOnlyRecoveryWithHealthyUnselectedRecall() async throws {
        try await restoreSessions(damaged: false)
    }
    @Test func sessionsOnlyRecoveryWithFailedUnselectedRecall() async throws {
        try await restoreSessions(damaged: true)
    }
    @Test func selectingFailedRecallStillRejectsInsteadOfPretendingRestoreSucceeded() throws {
        let f = try fixture(damaged: true, backupDomain: .memories)
        let draft = try f.target.readAtomicBackupDraft(from: f.snapshot)
        #expect(throws: DecodingError.self) {
            try f.target.previewAtomicBackup(draft, selecting: [.memories], memoryScope: scope)
        }
        #expect(f.target.atomicBackupReceipt == nil)
        #expect(try Data(contentsOf: f.memoryFile) == f.memoryBytes)
        #expect(f.target.sessionStore.loadSession(id: sessionID)?.title == "safe2295 target")
    }
    @Test func unselectedNeighborDriftStillInvalidatesConfirmation() async throws {
        let f = try fixture(damaged: true)
        let draft = try f.target.readAtomicBackupDraft(from: f.snapshot)
        let preview = try f.target.previewAtomicBackup(draft, selecting: [.sessions], memoryScope: nil)
        let drift = Data("new unselected bytes safe2295".utf8)
        try drift.write(to: f.memoryFile)
        await #expect(throws: SyncAtomicImportError.stalePreview) {
            try await f.target.confirmAtomicBackup(draft, preview: preview, confirmation: .init(preview: preview))
        }
        #expect(f.target.atomicBackupReceipt == nil)
        #expect(try Data(contentsOf: f.memoryFile) == drift)
        #expect(f.target.sessionStore.loadSession(id: sessionID)?.title == "safe2295 target")
    }
}
