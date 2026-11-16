import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-APP-12 real owned child plus pending approval field producer")
@MainActor
struct ExitSafetyPackageFieldFixture2444Tests {
    @Test("explicit field admission requires the existing Session and Task producers")
    func requiresBothProductionJourneys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "exit-field-2444-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "exit-field-2444",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument,
                TaskPackageFieldFixture.activationArgument,
                ExitSafetyPackageFieldFixture.activationArgument]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let arguments = [RuntimeIsolationProfile.fieldActivationArgument,
            SessionPackageFieldFixture.activationArgument,
            TaskPackageFieldFixture.activationArgument,
            ExitSafetyPackageFieldFixture.activationArgument]
        let marker = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1"]
        #expect(PackageFieldFixtureArguments.areValid(arguments, environment: marker))
        #expect(!PackageFieldFixtureArguments.areValid(
            arguments.filter { $0 != TaskPackageFieldFixture.activationArgument },
            environment: marker
        ))
        #expect(!PackageFieldFixtureArguments.areValid(
            arguments + [SessionPackageFieldFixture.performanceArgument],
            environment: marker
        ))
        #expect(!PackageFieldFixtureArguments.areValid(
            arguments + [ExitSafetyPackageFieldFixture.activationArgument],
            environment: marker
        ))
        #expect(ExitSafetyPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true, taskFieldJourney: true,
            arguments: arguments, environment: marker
        ))
        #expect(!ExitSafetyPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: false, taskFieldJourney: true,
            arguments: arguments, environment: marker
        ))
        #expect(!ExitSafetyPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true, taskFieldJourney: true,
            arguments: arguments + [ExitSafetyPackageFieldFixture.activationArgument],
            environment: marker
        ))
        #expect(!ExitSafetyPackageFieldFixture.isRequested(
            profile: profile, sessionFieldJourney: true, taskFieldJourney: true,
            arguments: arguments, environment: [:]
        ))
    }

    @Test("cancelling the structured field worker retires the real stdio PID and pending Task approval")
    func cancellationRetiresOwnedProcessAndApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "exit-field-2444-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let profile = try RuntimeIsolationProfile.makePackagedField(
            label: "exit-field-2444",
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
                SessionPackageFieldFixture.activationArgument,
                TaskPackageFieldFixture.activationArgument,
                ExitSafetyPackageFieldFixture.activationArgument]
        )
        defer { try? profile.cleanupDisposableRoots() }
        let store = SessionStore(directory: profile.sessionDirectory)
        try SessionPackageFieldFixture.prepare(
            profile: profile, store: store,
            arguments: [SessionPackageFieldFixture.activationArgument]
        )
        let defaults = profile.makeUserDefaults()
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let environment = EnvVarStore(
            directory: profile.providerConfigurationDirectory, keychain: keychain)
        let tasks = try AgentTaskStore(
            persistenceURL: root.appendingPathComponent("exit-field-agent-tasks.json"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(
                storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: store, canvasRuntimeState: .disabled,
            agentTaskStore: tasks,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            commandEnvStore: environment,
            taskCenterBindingPersistenceURL: root.appendingPathComponent("exit-field-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(store))
        await ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [URL(fileURLWithPath: NSHomeDirectory())],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            canvasRuntimeState: .disabled,
            externalNetworkAllowed: false,
            sessionReadSecretStore: environment
        ).value
        try #require(bridge.taskCenterControlConsumer.isAvailable,
                     "production Goal binding must be installed before the field worker starts")
        let fixtureReady = try ExitSafetyFixtureReadyOutput()
        defer { fixtureReady.stop() }
        let completion = ExitSafetyWorkerCompletion()
        let worker = Task {
            defer { completion.finished = true }
            try await ExitSafetyPackageFieldFixture.run(
                profile: profile, bridge: bridge, sessionStore: store
            )
        }
        defer { worker.cancel() }
        let pidFile = root.appendingPathComponent("exit-safety-field/owned-pid")
        var ownedPID: pid_t?
        var sawPendingApproval = false
        var sawRunningGoalReady = false
        for _ in 0..<1_200 {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8) {
                ownedPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            sawPendingApproval = bridge.approvalCenter.pendingRequest != nil
            let runningRow = bridge.taskCenterControlConsumer.receiptRows().first {
                $0.taskID.hasPrefix("field-task-running-")
            }
            let runningFact = runningRow.flatMap {
                bridge.taskCenterControlConsumer.project().fact(
                    taskID: $0.taskID, parentID: $0.parentID
                )
            }
            sawRunningGoalReady = runningRow?.lifecycleState == .running &&
                runningRow?.cancelAvailable == true &&
                runningFact?.leaseState == .active &&
                runningFact?.isGoalBound == true
            if ownedPID != nil && sawPendingApproval && sawRunningGoalReady &&
                fixtureReady.isReady { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let fixtureReadyBeforeCancellation = fixtureReady.isReady
        fixtureReady.stop()
        let liveBeforeCancellation = ownedPID.map {
            Darwin.kill($0, 0) == 0 || errno == EPERM
        } ?? false
        let finishedBeforeCancellation = completion.finished
        worker.cancel()
        switch await worker.result {
        case .success:
            if finishedBeforeCancellation {
                Issue.record("field worker finished before the cancellation request")
            }
        case .failure(let error):
            print("EXIT_SAFETY_FIELD_WORKER_RESULT failure=\(Self.workerFailureClass(error))")
        }
        if let ownedPID {
            for _ in 0..<100 where Darwin.kill(ownedPID, 0) == 0 || errno == EPERM {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let retired = ownedPID.map { Darwin.kill($0, 0) != 0 && errno == ESRCH } ?? false
        #expect(liveBeforeCancellation)
        #expect(sawPendingApproval, "approval must come from the real Task fixture, not a fabricated row")
        #expect(sawRunningGoalReady, "the production running Task must retain its active Goal-bound control lease")
        #expect(fixtureReadyBeforeCancellation, "the Task fixture must emit its real READY event before cancellation")
        #expect(retired, "production MCPClient.disconnect must retire its owned stdio process")
        #expect(bridge.approvalCenter.pendingRequest == nil,
                "cancelling the owning Task must dismiss its pending approval")
        #expect(bridge.agentTaskStore.taskCenterSnapshots().count >= 4)
        let running = bridge.agentTaskStore.taskCenterSnapshots().first {
            $0.taskID.hasPrefix("field-task-running-")
        }
        #expect(running?.status == .cancelled,
                "the real running Task ledger must settle cancelled, never succeeded")
    }

    private static func workerFailureClass(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? ExitSafetyPackageFieldFixture.FixtureError {
            switch failure {
            case .unsafeRoot: return "exit.unsafeRoot"
            case .invalidMarker: return "exit.invalidMarker"
            case .occupiedTaskField: return "exit.occupiedTaskField"
            case .storeMismatch: return "exit.storeMismatch"
            case .unavailableInterpreter: return "exit.unavailableInterpreter"
            case .missingOwnedProcess: return "exit.missingOwnedProcess"
            }
        }
        if let failure = error as? TaskPackageFieldFixture.FixtureError {
            switch failure {
            case .unsafeRoot: return "task.unsafeRoot"
            case .occupiedLedger: return "task.occupiedLedger"
            case .invalidMarker: return "task.invalidMarker"
            case .missingParentSession: return "task.missingParentSession"
            case .invalidTerminal: return "task.invalidTerminal"
            case .missingLiveApproval: return "task.missingLiveApproval"
            case .missingGoalBinding: return "task.missingGoalBinding"
            }
        }
        return "other"
    }
}

@MainActor
private final class ExitSafetyWorkerCompletion {
    var finished = false
}

/// Capture the production fixture's own READY event before cancelling its worker.
/// A running row and pending approval can precede validated Goal-bound control.
private final class ExitSafetyFixtureReadyOutput: @unchecked Sendable {
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
