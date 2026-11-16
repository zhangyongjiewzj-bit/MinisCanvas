import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

// Observation only. The lock does not marshal execution to any executor.
private final class C0102FactoryObservation: @unchecked Sendable {
    struct Entry: Sendable {
        let mainThread: Bool
        let threadID: UInt64
        let lexicalMainActor: Bool
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func record(mainThread: Bool, lexicalMainActor: Bool) {
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let entry = Entry(mainThread: mainThread, threadID: threadID, lexicalMainActor: lexicalMainActor)
        lock.withLock { entries.append(entry) }
        // Emit before the real actor-isolated ChatStore call. A compiler-inserted
        // closure-entry isolation failure may still occur before this body.
        let line = "C0102_FACTORY_ENTER mainThread=\(mainThread) threadID=\(threadID) lexicalMainActor=\(lexicalMainActor) lexicalIsNotDynamicExecutorProof=true\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    func snapshot() -> [Entry] { lock.withLock { entries } }
}

@Suite("D-CONC2 C0102 production-shaped Optimize factory isolation", .serialized)
@MainActor
struct CONC2OptimizePromptFactoryC0102Tests {
    // SDK 26.5 exposes this real thread predicate only to synchronous callers.
    // This helper does not schedule, suspend, dispatch or change executors.
    private func currentThreadIsMain() -> Bool { Thread.isMainThread }

    @Test func mainActorCreatedFactoryStaysOnMainWhenAwaitingRealOptimize() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("C0102-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var identity = stat()
        let rootStatus = lstat(root.path, &identity)
        try #require(rootStatus == 0)
        try #require((identity.st_mode & S_IFMT) == S_IFDIR && identity.st_uid == geteuid()
                     && (identity.st_mode & 0o777) == 0o700)
        let suite = "C0102-owned-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let chat = ChatStore(preferencesDefaults: defaults,
                             logManager: LogManager(directory: root.appendingPathComponent("logs")))
        // Fresh ChatStore has no configured provider/record source; its actual
        // activeProvider() branch returns the existing Release MockProvider.
        // Do not select a real provider, initialize an EnvVarStore or read keys.
        let observation = C0102FactoryObservation()
        let callerMain = currentThreadIsMain()
        let callerLexicalMain = (#isolation as? MainActor) != nil
        FileHandle.standardOutput.write(Data(
            "C0102_BEGIN root=\(root.path) dev=\(identity.st_dev) ino=\(identity.st_ino) uid=\(identity.st_uid) suite=\(suite) mainThread=\(callerMain) lexicalMainActor=\(callerLexicalMain)\n".utf8))
        #expect(callerMain)
        #expect(callerLexicalMain)

        // Same creation/invocation shape as NodeTextInspectorView.optimize:
        // MainActor creates the closure capturing ChatStore, then awaits the
        // actual unmodified service. No assumeIsolated/run/detached/actor shim.
        let service = OptimizePromptService(providerFactory: {
            let lexicalMain = (#isolation as? MainActor) != nil
            observation.record(mainThread: Thread.isMainThread, lexicalMainActor: lexicalMain)
            return try chat.activeProvider()
        })
        let optimized = try await service.optimize("C0102 synthetic prompt draft")
        let entries = observation.snapshot()
        let entryCount = entries.count
        #expect(entryCount == 1)
        let entry = try #require(entries.first)
        #expect(entry.mainThread, "The production-shaped factory must execute on the main thread")
        #expect(entry.lexicalMainActor, "This is a MainActor-created closure, not a nonisolated stub")
        #expect(optimized.contains("收到：C0102 synthetic prompt draft"))
        let resumedOnMain = currentThreadIsMain()
        #expect(resumedOnMain)
        FileHandle.standardOutput.write(Data(
            "C0102_END factoryCalls=\(entryCount) factoryMainThread=\(entry.mainThread) resumedMain=\(resumedOnMain) mockReplyMatched=\(optimized.contains("收到：C0102 synthetic prompt draft")) rootRetained=true suiteRetained=true tasksCreatedByFixture=0\n".utf8))
        // There are no fixture-created Tasks, server, UsageStore or stream to
        // cancel/join. Root and private suite remain for crash/RED diagnostics.
    }
}
