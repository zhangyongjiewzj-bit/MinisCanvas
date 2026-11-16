import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TASK-04 controlled field worker through production Task Center Stop")
@MainActor
struct Task04ControlledWorkerProductionConsumerTests {
    @Test("Goal-bound Stop cancels the live worker and fences its late success")
    func stopCancelsActualWorkerAndPreservesCancelledReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "task04-controlled-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let arguments = [
            "MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            SessionPackageFieldFixture.activationArgument,
            TaskPackageFieldFixture.activationArgument
        ]
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "task04-controlled",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: arguments
        )
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: sessions,
            arguments: [SessionPackageFieldFixture.activationArgument]
        )
        let tasks = try AgentTaskStore(
            persistenceURL: root.appendingPathComponent("task04-agent-tasks.json")
        )
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let environment = EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: sessions, canvasRuntimeState: .disabled,
            agentTaskStore: tasks,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            commandEnvStore: environment,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task04-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            enableOrchestration: true, externalNetworkAllowed: false,
            sessionReadSecretStore: environment
        ).value

        let completion = Task04FixtureCompletion()
        let readyOutput = try Task04FixtureReadyOutput()
        defer { readyOutput.stop() }
        let worker = Task {
            do {
                try await TaskPackageFieldFixture.run(
                    profile: profile, bridge: bridge, sessionStore: sessions
                )
                await completion.finish(error: nil)
            } catch {
                await completion.finish(error: String(describing: error))
            }
        }
        defer { worker.cancel() }

        var runningRow: TaskCenterReceiptRow?
        for _ in 0..<1_200 {
            let candidate = bridge.taskCenterControlConsumer.receiptRows().first {
                $0.taskID.hasPrefix("field-task-running-")
            }
            if readyOutput.isReady,
               candidate?.taskState == .running,
               candidate?.cancelAvailable == true,
               bridge.approvalCenter.pendingRequest != nil {
                runningRow = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let row = try #require(runningRow, "actual producer must expose a cancellable live worker")
        readyOutput.stop()
        let runID = try #require(row.runID)
        let fact = try #require(bridge.taskCenterGoalProjection().fact(
            taskID: row.taskID, parentID: row.parentID
        ))
        let scopeID = try #require(fact.scopeID)
        #expect(fact.isGoalBound)

        // The same canonical row has no control authority without its Goal.
        let unbound = TaskCenterControlConsumer(store: tasks)
        let stop = TaskCenterControlRequest(
            taskID: row.taskID, parentID: row.parentID,
            revision: fact.revision, scopeID: scopeID,
            actorID: "task04-production-test", idempotencyKey: "task04-stop",
            action: .stop, runID: runID
        )
        #expect(throws: TaskCenterControlConsumerError.unavailable) {
            _ = try unbound.execute(stop)
        }
        #expect(tasks.snapshot(taskID: row.taskID, parentID: row.parentID)?.status == .running)
        #expect(tasks.receipt(runID: runID) == nil)

        let control = try bridge.executeTaskCenterControl(stop)
        #expect(control.afterFact.status == .cancelled)
        #expect(control.cancelledTaskIDs.contains(row.taskID))
        #expect(tasks.snapshot(taskID: row.taskID, parentID: row.parentID)?.status == .cancelled)
        // Deny the unrelated synthetic approval so the producer can join all
        // of its children. No UI card was presented in this non-UI test, so
        // the presentation-bound action is intentionally unavailable here.
        if let approval = bridge.approvalCenter.pendingRequest {
            bridge.approvalCenter.resolve(
                approved: false, reason: "synthetic test denial",
                confirmed: false, requestID: approval.id
            )
        }
        for _ in 0..<400 {
            if await completion.finished { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finishedBeforeTimeout = await completion.finished
        if !finishedBeforeTimeout {
            let states = tasks.taskCenterSnapshots().map {
                "\($0.taskID):\($0.status)"
            }.sorted().joined(separator: ",")
            print("TASK04_DIAG after-stop rows=\(states) pending-approval=\(bridge.approvalCenter.pendingRequest != nil) running-receipt=\(String(describing: tasks.receipt(runID: runID)?.outcome))")
        }
        if !finishedBeforeTimeout { worker.cancel() }
        await worker.value
        #expect(finishedBeforeTimeout, "Stop must interrupt the 590-second provider wait")
        let fixtureError = await completion.error
        #expect(fixtureError == nil)
        #expect(tasks.receipt(runID: runID)?.outcome == .cancelled)
        #expect(tasks.receipt(runID: runID)?.childResultEnvelope == nil)
        #expect(bridge.taskCenterControlConsumer.receiptRows().first {
            $0.taskID == row.taskID && $0.parentID == row.parentID
        }?.taskState == .cancelled)
    }
}

/// Observe the fixture's own ready event before controlling its worker.
/// The production fixture has stricter readiness than a running row plus
/// pending approval; stopping sooner prevents its ready loop from finishing.
private final class Task04FixtureReadyOutput: @unchecked Sendable {
    private let marker = Data("TASK2387_FIELD_READY".utf8)
    private let pipe = Pipe()
    private let originalFD: Int32
    private let reader = DispatchGroup()
    private let lock = NSLock()
    private var ready = false
    private var stopped = false

    init() throws {
        let fd = dup(STDOUT_FILENO)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        originalFD = fd
        let readFD = pipe.fileHandleForReading.fileDescriptor
        reader.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { reader.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var tail = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(readFD, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }
                let chunk = Data(buffer.prefix(count))
                chunk.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var written = 0
                    while written < count {
                        let amount = Darwin.write(originalFD, base.advanced(by: written), count - written)
                        guard amount > 0 else { break }
                        written += amount
                    }
                }
                tail.append(chunk)
                if tail.range(of: marker) != nil { lock.withLock { ready = true } }
                if tail.count > marker.count {
                    tail = Data(tail.suffix(marker.count - 1))
                }
            }
        }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            pipe.fileHandleForWriting.closeFile()
            reader.wait()
            close(originalFD)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    var isReady: Bool { lock.withLock { ready } }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        fflush(stdout)
        _ = dup2(originalFD, STDOUT_FILENO)
        pipe.fileHandleForWriting.closeFile()
        reader.wait()
        close(originalFD)
        pipe.fileHandleForReading.closeFile()
    }
}

private actor Task04FixtureCompletion {
    private(set) var finished = false
    private(set) var error: String?

    func finish(error: String?) {
        self.error = error
        finished = true
    }
}
