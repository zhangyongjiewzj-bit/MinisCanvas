import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

/// A real exec boundary supplements the existing same-process 546/342 consumers.
/// This does not claim a full App launch or a physical external side effect.
@Suite("TaskCenter real process restart identity 0545")
@MainActor
struct TaskCenterColdRestartIdentity0545Tests {
    @Test func seedExitThenFreshProcessPreservesLeaseRuntimeAndTranscriptFences() async throws {
        guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw ColdRestart0545Error.missingFormalRoot
        }
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["CONC30545_CHILD_PHASE"] {
            let shared = URL(fileURLWithPath: try #require(environment["CONC30545_SHARED_ROOT"]), isDirectory: true)
            try #require(shared.standardizedFileURL.path.hasPrefix(formal.rootDirectory.standardizedFileURL.path + "/"))
            try await ColdRestartOwnedChild0545.run(phase: phase, root: shared)
            return
        }
        let shared = formal.rootDirectory.appendingPathComponent("coldrestart0545-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        // No automatic data deletion: both child journals and actual durable files remain evidence.
        let seed = try await launch(phase: "seed", shared: shared)
        #expect(seed.status == 0)
        let seedFact = try JSONDecoder().decode(ColdRestartSeed0545.self,
            from: Data(contentsOf: shared.appendingPathComponent("seed.json")))
        #expect(seedFact.pid == seed.pid)
        #expect(seedFact.pid != getpid())
        let reopened = try await launch(phase: "reopen", shared: shared)
        #expect(reopened.status == 0)
        let result = try JSONDecoder().decode(ColdRestartResult0545.self,
            from: Data(contentsOf: shared.appendingPathComponent("reopen.json")))
        #expect(result.pid == reopened.pid)
        #expect(result.seedPID == seed.pid)
        #expect(result.pid != seed.pid)
        #expect(result.pid != getpid())
        #expect(result.newRun != seedFact.oldEnvelope.runID)
        #expect(result.newAttempt != seedFact.oldEnvelope.attemptID)
        #expect(result.sourceContents == ["来源0545真实持久正文"])
        #expect(result.currentOutcome == .succeeded)
        #expect(result.unknownRecovery == .needsUserReview)
        #expect(result.unknownReceiptAbsent)
        #expect(result.runtimeCheckpointAttempt == "old-runtime0545")
        #expect(result.runtimeStillRequiresReconciliation)
        print("COLD_RESTART0545 parent=\(getpid()) seed=\(seed.pid) seed_EXIT=\(seed.status) reopen=\(reopened.pid) reopen_EXIT=\(reopened.status) shared=\(shared.path)")
    }

    private func launch(phase: String, shared: URL) async throws -> (pid: Int32, status: Int32) {
        let process = Process()
        let inherited = CommandLine.arguments
        let executable = URL(fileURLWithPath: inherited[0]).standardizedFileURL
        let bundle: URL
        if let flag = inherited.firstIndex(of: "--test-bundle-path") {
            // Normal macOS SwiftPM runs this method inside its testing helper.
            // Re-exec that same helper with the actual loaded test bundle.
            try #require(flag + 1 < inherited.count)
            try #require(executable.path.hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
            bundle = URL(fileURLWithPath: inherited[flag + 1]).standardizedFileURL
            process.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing",
                                 "--filter", "TaskCenterColdRestartIdentity0545Tests"]
        } else {
            // A directly executed official runner keeps the same real exec boundary.
            bundle = executable
            process.arguments = ["--testing-library", "swift-testing",
                                 "--filter", "TaskCenterColdRestartIdentity0545Tests"]
        }
        let officialTestBundle = bundle.path.contains(".xctest/Contents/MacOS/")
        // The existing direct-exec branch also runs in the original R13 App
        // entry. Admit only this exact loaded App/executable, not arbitrary apps.
        let currentOriginalApp = Bundle.main.bundleIdentifier == "com.miniscanvas.r13.original-app-main"
            && Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.executableURL?.standardizedFileURL == executable
            && bundle == executable
        #expect(officialTestBundle || currentOriginalApp)
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory))
        try #require(!isDirectory.boolValue)
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["CONC30545_CHILD_PHASE"] = phase
        environment["CONC30545_SHARED_ROOT"] = shared.path
        process.environment = environment
        let raw = shared.appendingPathComponent(phase + ".framework.raw.log")
        #expect(FileManager.default.createFile(atPath: raw.path, contents: nil))
        let output = try FileHandle(forWritingTo: raw)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let pid = process.processIdentifier
        let start = ["pid": String(pid), "argv": ([executable.path] + (process.arguments ?? [])).joined(separator: " "), "phase": phase]
        try JSONEncoder().encode(start).write(to: shared.appendingPathComponent(phase + ".started.json"), options: .atomic)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let timedOut = process.isRunning
        // Only this declared harmless fixture is eligible for bounded cleanup.
        if timedOut { process.terminate() }
        process.waitUntilExit()
        try JSONEncoder().encode(["pid": String(pid), "REAL_EXIT": String(process.terminationStatus), "timedOut": String(timedOut)])
            .write(to: shared.appendingPathComponent(phase + ".terminal.json"), options: .atomic)
        #expect(!timedOut)
        #expect(process.terminationReason == .exit)
        let framework = try String(contentsOf: raw, encoding: .utf8)
        #expect(framework.contains("Test run with 1 test in 1 suite passed"))
        return (pid, process.terminationStatus)
    }
}
