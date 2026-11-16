import Foundation
import Darwin
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("Task01 pending approval presentation navigation")
@MainActor
struct Task01PendingApprovalPresentationTests {
    private struct FixtureFailure: Error {
        let stage: String
        let code: Int32
    }
    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: [Error]
    }

    /// Pins the actual FileManager temporary parent and an immediately fresh
    /// UUID child. The formal contract supplies the expected uid/device; no
    /// environment string is accepted as the child's observed identity.
    private struct OwnedRoot {
        let url: URL
        let parentURL: URL
        let name: String
        let parentFD: Int32
        let rootFD: Int32
        let parentIdentity: stat
        let identity: stat
        let formal: FormalTestIsolationPaths

        static func make() throws -> OwnedRoot {
            guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess() else {
                throw FixtureFailure(stage: "formal profile missing", code: EINVAL)
            }
            let parentURL = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
            let parentFD = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentFD >= 0 else { throw FixtureFailure(stage: "open actualFM", code: errno) }
            var parentIdentity = stat()
            guard fstat(parentFD, &parentIdentity) == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "stat actualFM", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "stat actualFM", code: code)
            }
            guard parentIdentity.st_mode & S_IFMT == S_IFDIR,
                  parentIdentity.st_mode & 0o7777 == 0o700,
                  parentIdentity.st_uid == geteuid(), parentIdentity.st_uid == formal.rootOwner,
                  UInt64(parentIdentity.st_dev) == formal.rootDevice else {
                let error = FixtureFailure(stage: "actualFM parent uid/device/700", code: ESTALE)
                guard Darwin.close(parentFD) == 0 else {
                    throw FixtureFailures(business: error,
                        cleanup: [FixtureFailure(stage: "close invalid actualFM parent", code: errno)])
                }
                throw error
            }
            let name = "task01-pending-\(UUID().uuidString)"
            let created = name.withCString { mkdirat(parentFD, $0, 0o700) }
            guard created == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "mkdir fresh UUID", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "mkdir fresh UUID", code: code)
            }
            let rootFD = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            var identity = stat()
            guard rootFD >= 0, fstat(rootFD, &identity) == 0 else {
                let code = errno
                var errors: [Error] = []
                // mkdirat just created this still-empty child; unlinkat removes
                // only that directory entry, never follows a replacement link.
                if name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) != 0 {
                    errors.append(FixtureFailure(stage: "remove uninitialized fresh child", code: errno))
                }
                if rootFD >= 0, Darwin.close(rootFD) != 0 {
                    errors.append(FixtureFailure(stage: "close fresh child", code: errno))
                }
                if Darwin.close(parentFD) != 0 {
                    errors.append(FixtureFailure(stage: "close actualFM", code: errno))
                }
                throw FixtureFailures(business: FixtureFailure(stage: "open/stat fresh child", code: code),
                                      cleanup: errors)
            }
            // All later validation is business work under a cleanup owner.
            return OwnedRoot(url: parentURL.appendingPathComponent(name, isDirectory: true),
                             parentURL: parentURL, name: name, parentFD: parentFD, rootFD: rootFD,
                             parentIdentity: parentIdentity, identity: identity, formal: formal)
        }

        func validate() throws {
            var parentNow = stat()
            var childNow = stat()
            var rootNow = stat()
            guard parentURL.path.withCString({ fstatat(AT_FDCWD, $0, &parentNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  parentNow.st_mode & S_IFMT == S_IFDIR,
                  parentNow.st_mode & 0o7777 == 0o700,
                  parentNow.st_dev == parentIdentity.st_dev,
                  parentNow.st_ino == parentIdentity.st_ino,
                  parentNow.st_uid == geteuid(), parentNow.st_uid == formal.rootOwner,
                  UInt64(parentNow.st_dev) == formal.rootDevice,
                  name.withCString({ fstatat(parentFD, $0, &childNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  fstat(rootFD, &rootNow) == 0,
                  childNow.st_mode & S_IFMT == S_IFDIR,
                  childNow.st_uid == geteuid(), childNow.st_uid == formal.rootOwner,
                  childNow.st_mode & 0o7777 == 0o700,
                  childNow.st_dev == parentNow.st_dev,
                  childNow.st_dev == identity.st_dev, childNow.st_ino == identity.st_ino,
                  rootNow.st_dev == identity.st_dev, rootNow.st_ino == identity.st_ino,
                  childNow.st_ino != parentNow.st_ino,
                  UInt64(childNow.st_ino) != formal.rootInode,
                  url.deletingLastPathComponent().path == parentURL.path,
                  url.standardizedFileURL.resolvingSymlinksInPath().path == url.path else {
                throw FixtureFailure(stage: "freshFM uid/dev/inode/700/nosymlink", code: ESTALE)
            }
        }

        func finish<T>(_ business: Result<T, Error>) throws -> T {
            var errors: [Error] = []
            do {
                try validate()
                try FileManager.default.removeItem(at: url)
                var absent = stat()
                let result = name.withCString {
                    fstatat(parentFD, $0, &absent, AT_SYMLINK_NOFOLLOW)
                }
                guard result == -1, errno == ENOENT else {
                    throw FixtureFailure(stage: "cleanup verify ENOENT", code: errno)
                }
            } catch { errors.append(error) }
            if Darwin.close(rootFD) != 0 {
                errors.append(FixtureFailure(stage: "close fresh child", code: errno))
            }
            if Darwin.close(parentFD) != 0 {
                errors.append(FixtureFailure(stage: "close actualFM", code: errno))
            }
            if !errors.isEmpty {
                switch business {
                case .failure(let error): throw FixtureFailures(business: error, cleanup: errors)
                case .success: throw FixtureFailures(business: nil, cleanup: errors)
                }
            }
            print("TASK01_PENDING_FIXTURE_CLEANUP root=\(url.path) uid=\(identity.st_uid) dev=\(identity.st_dev) inode=\(identity.st_ino) ENOENT=true")
            return try business.get()
        }
    }

    private func withRootAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
        let owned = try OwnedRoot.make()
        let result: Result<T, Error>
        do {
            try owned.validate()
            print("TASK01_PENDING_FIXTURE root=\(owned.url.path) parent=\(owned.parentURL.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700 nosymlink=true")
            result = .success(try await body(owned.url))
        }
        catch { result = .failure(error) }
        return try owned.finish(result)
    }
    private struct Fixture {
        let root: URL
        let tasks: AgentTaskStore
        let consumer: TaskCenterControlConsumer
        let row: TaskCenterReceiptRow
        let mapping: AgentTaskApprovalNavigationBinding
        let request: ApprovalRequest
        let taskRunID: String
        let childSessionID: String
        let generationID: String
        let now: Date
        let expiresAt: Date
    }

    private func makeFixture(root: URL, secondConfirmation: Bool = false) async throws -> Fixture {
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let parent = try sessions.createSession(id: "synthetic-parent-session")
        let child = try sessions.forkSession(
            from: parent.id, id: "synthetic-child-session", title: "Synthetic child",
            throughMessageIndex: 0,
            createdByTaskID: "synthetic-child-task", createdByRunID: "synthetic-task-run"
        )
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(
            taskID: "synthetic-child-task", parentID: "synthetic-parent-task",
            providerID: "offline", modelID: "synthetic"
        )
        let run = try tasks.startRun(
            taskID: task.taskID, parentID: task.parentID, runID: "synthetic-task-run"
        )
        let attempt = try #require(tasks.attempts(runID: run.runID).last)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: parent.id, conversationID: parent.id,
            turnID: "turn-handle:\(handle.turnID)", taskID: task.parentID,
            actorID: "synthetic-actor"
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parentIdentity, childSessionID: child.id,
            childTaskID: task.taskID, scopeID: "synthetic-scope",
            requestedCapabilities: [.tools], parentCapabilities: [.tools],
            policyCapabilities: [.tools],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "offline", modelID: "synthetic",
                configurationFingerprint: "synthetic", conversationID: child.id
            ),
            memoryScopeID: "synthetic-memory", workingDirectory: root.path,
            cancelGeneration: handle.turnID, evidenceRoot: "synthetic-evidence",
            parentTurnHandle: handle, childExecutionID: "synthetic-execution"
        )
        let generationID = try #require(identity.generationID)
        let locator = ChildTranscriptLocator(
            childSessionID: child.id, parentSessionID: parent.id,
            taskID: task.taskID, parentID: task.parentID,
            runID: run.runID, attemptID: attempt.attemptID,
            childExecutionID: "synthetic-execution",
            parentContextSnapshotID: task.parentContextSnapshotID,
            lineageVersion: child.lineageVersion
        )
        _ = try tasks.bindChildTranscript(locator)
        let now = Date()
        let expiresAt = now.addingTimeInterval(600)
        let binding = ApprovalAuthorizationContext(
            actorID: "child:\(child.id)", sessionID: child.id,
            turnID: handle.turnID, taskID: task.taskID,
            runID: generationID, attemptID: generationID,
            effectID: "request-A", scope: identity.scopeID,
            payloadDigest: "synthetic-digest", expiresAt: expiresAt,
            policyRevision: "synthetic-policy", grantEpoch: generationID,
            toolName: "shell_execute"
        )
        let request = request(from: binding, requestID: "request-A", secondConfirmation: secondConfirmation)
        let mapping = try tasks.beginPendingChildApproval(
            taskRunID: run.runID, taskAttemptID: attempt.attemptID,
            childIdentity: identity, request: request, now: now
        )
        let consumer = TaskCenterControlConsumer(
            store: tasks, childTranscriptSessionStore: sessions
        )
        let row = try #require(consumer.receiptRows(now: now).first)
        #expect(row.childSessionID == child.id)
        return Fixture(
            root: root, tasks: tasks, consumer: consumer, row: row,
            mapping: mapping, request: request, taskRunID: run.runID,
            childSessionID: child.id, generationID: generationID,
            now: now, expiresAt: expiresAt
        )
    }

    private func request(
        from binding: ApprovalAuthorizationContext, requestID: String, secondConfirmation: Bool = false
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: requestID, requestID: requestID, callID: requestID,
            toolName: binding.toolName, inputSummary: "redacted",
            riskLevel: .medium, requiresApproval: true, requiresSecondConfirmation: secondConfirmation,
            sessionID: binding.sessionID, turnID: binding.turnID,
            taskID: binding.taskID, attemptID: binding.attemptID,
            approvalScope: binding.scope,
            policyRevision: binding.policyRevision,
            grantEpoch: binding.grantEpoch,
            inputDigest: binding.payloadDigest,
            identityDigest: binding.identityDigest,
            actorID: binding.actorID, runID: binding.runID,
            effectID: binding.effectID, expiresAt: binding.expiresAt
        )
    }

    private func withPresented<T>(
        _ center: ApprovalPromptCenter, request: ApprovalRequest,
        _ body: @MainActor (Task<ApprovalDecision, Never>) async throws -> T
    ) async throws -> T {
        let waiter = Task { await center.present(request) }
        let result: Result<T, Error>
        do {
            for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
            _ = try #require(center.pendingRequest)
            result = .success(try await body(waiter))
        } catch { result = .failure(error) }
        if center.pendingRequest != nil { waiter.cancel() }
        _ = await waiter.value
        return try result.get()
    }

    @Test func canonicalTaskSuspendsAndResumesTheSamePendingRequestWithoutDecision() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let center = ApprovalPromptCenter()
            try await withPresented(center, request: f.request) { waiter in
                let row = try #require(f.consumer.receiptRows().first)
                let nav = try #require(f.consumer.approvalNavigation(for: row, pendingRequest: center.pendingRequest))
                #expect(f.request.runID != row.runID)
                #expect(f.request.attemptID != row.attemptID)
                let beforeEvents = f.tasks.events(runID: f.taskRunID)
                let beforeRequest = center.pendingRequest
                let actions = center.actionsForPresentedRequest()
                #expect(actions.viewTaskCenter(nav, f.consumer))
                #expect(center.isPresentationSuspended)
                #expect(!center.isPromptPresented)
                #expect(center.pendingRequest == beforeRequest)
                #expect(f.consumer.receiptRows().first?.lifecycleState == .approvalRequired)
                #expect(f.tasks.events(runID: f.taskRunID) == beforeEvents)
                // Framework binding false/onDisappear from the old card cannot settle it.
                actions.dismiss()
                #expect(center.pendingRequest == beforeRequest)
                #expect(center.requestTaskCenterResume(nav, consumer: f.consumer))
                let intent = try #require(center.taskCenterResumeIntent)
                #expect(center.resumeFromTaskCenter(intent, consumer: f.consumer))
                #expect(center.isPromptPresented)
                #expect(center.pendingRequest == beforeRequest)
                #expect(f.tasks.events(runID: f.taskRunID) == beforeEvents)
                center.actionsForPresentedRequest().deny()
                let decision = await waiter.value
                #expect(!decision.approved)
                #expect(decision.requestID == f.request.requestID)
                #expect(decision.bindingDigest == f.request.identityDigest)
            }
        }
    }

    @Test func oldRenderedActionsCannotSettleResumedL3AndSecondStepIsPreserved() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root, secondConfirmation: true)
            let center = ApprovalPromptCenter()
            try await withPresented(center, request: f.request) { waiter in
                let nav = try #require(f.consumer.approvalNavigation(for: f.row, pendingRequest: center.pendingRequest))
                try await Task.sleep(for: .milliseconds(500))
                try #require(center.pendingRequest == f.request && !center.awaitingConfirmation)
                let firstCard = center.actionsForPresentedRequest()
                firstCard.approve()
                #expect(center.awaitingConfirmation)
                let confirmationCard = center.actionsForPresentedRequest()
                #expect(confirmationCard.viewTaskCenter(nav, f.consumer))
                confirmationCard.approve(); confirmationCard.deny(); confirmationCard.dismiss()
                #expect(center.pendingRequest == f.request)
                #expect(center.awaitingConfirmation)
                #expect(center.requestTaskCenterResume(nav, consumer: f.consumer))
                let intent = try #require(center.taskCenterResumeIntent)
                #expect(center.resumeFromTaskCenter(intent, consumer: f.consumer))
                confirmationCard.approve(); confirmationCard.deny(); confirmationCard.dismiss()
                firstCard.approve()
                #expect(center.pendingRequest == f.request)
                #expect(center.awaitingConfirmation)
                try await Task.sleep(for: .milliseconds(500))
                try #require(center.pendingRequest == f.request && center.awaitingConfirmation)
                center.actionsForPresentedRequest().approve()
                let decision = await waiter.value
                #expect(decision.approved && decision.confirmed)
            }
        }
    }

    @Test func legacyAndForeignCanonicalDestinationsCannotSuspendPresentation() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let nav = try #require(f.consumer.approvalNavigation(for: f.row, pendingRequest: f.request))
            let center = ApprovalPromptCenter()
            let legacy = ApprovalRequest(id: "legacy", toolName: "file_write", inputSummary: "redacted",
                                         riskLevel: .medium, requiresApproval: true)
            try await withPresented(center, request: legacy) { waiter in
                #expect(!center.actionsForPresentedRequest().viewTaskCenter(nav, f.consumer))
                #expect(center.isPromptPresented)
                center.actionsForPresentedRequest().dismiss()
                let denied = await waiter.value
                #expect(!denied.approved)
            }
            try await withPresented(center, request: f.request) { waiter in
                let foreign = TaskCenterApprovalNavigation(
                    taskID: "foreign", parentID: nav.parentID, sessionID: nav.sessionID,
                    runID: nav.runID, attemptID: nav.attemptID,
                    requestID: nav.requestID, identityDigest: nav.identityDigest
                )
                #expect(!center.actionsForPresentedRequest().viewTaskCenter(foreign, f.consumer))
                #expect(center.isPromptPresented)
                center.actionsForPresentedRequest().deny()
                let denied = await waiter.value
                #expect(!denied.approved)
            }
        }
    }

    @Test func suspendedExpirySettlesWaiterAndOldReturnCannotResumeReusedPublicRequest() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let center = ApprovalPromptCenter()
            let nav = try #require(f.consumer.approvalNavigation(for: f.row, pendingRequest: f.request))
            var oldIntent: ApprovalPromptCenter.TaskCenterPresentationReturn?
            try await withPresented(center, request: f.request) { waiter in
                #expect(center.actionsForPresentedRequest().viewTaskCenter(nav, f.consumer))
                #expect(center.requestTaskCenterResume(nav, consumer: f.consumer))
                let resumeCandidate: ApprovalPromptCenter.TaskCenterPresentationReturn? = center.taskCenterResumeIntent
                let resumeIntent: ApprovalPromptCenter.TaskCenterPresentationReturn = try #require(resumeCandidate as ApprovalPromptCenter.TaskCenterPresentationReturn?)
                oldIntent = resumeIntent
                center.expirePending()
                let decision = await waiter.value
                #expect(!decision.approved && decision.status == .expired)
                #expect(!center.isPresentationSuspended)
            }
            let retained = try #require(oldIntent)
            try await withPresented(center, request: f.request) { waiter in
                #expect(!center.resumeFromTaskCenter(retained, consumer: f.consumer))
                #expect(center.isPromptPresented)
                center.actionsForPresentedRequest().deny()
                let denied = await waiter.value
                #expect(!denied.approved)
            }
        }
    }

    @Test func suspendedCallerCancellationAndStopStillSettleOriginalWaiter() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let nav = try #require(f.consumer.approvalNavigation(for: f.row, pendingRequest: f.request))
            for cancelCaller in [true, false] {
                let center = ApprovalPromptCenter()
                try await withPresented(center, request: f.request) { waiter in
                    #expect(center.actionsForPresentedRequest().viewTaskCenter(nav, f.consumer))
                    if cancelCaller { waiter.cancel() } else { center.stopGeneration() }
                    let decision = await waiter.value
                    #expect(!decision.approved && decision.status == .cancelled)
                    #expect(center.pendingRequest == nil)
                    #expect(!center.isPresentationSuspended)
                    #expect(!center.requestTaskCenterResume(nav, consumer: f.consumer))
                }
            }
        }
    }

    @Test func canonicalRetryInvalidatesRequestedReturnBeforePresentationResumes() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let center = ApprovalPromptCenter()
            try await withPresented(center, request: f.request) { waiter in
                let nav = try #require(f.consumer.approvalNavigation(for: f.row, pendingRequest: center.pendingRequest))
                #expect(center.actionsForPresentedRequest().viewTaskCenter(nav, f.consumer))
                #expect(center.requestTaskCenterResume(nav, consumer: f.consumer))
                let intent = try #require(center.taskCenterResumeIntent)
                _ = try f.tasks.finish(runID: f.taskRunID, outcome: .cancelled)
                _ = try f.tasks.startRun(taskID: f.row.taskID, parentID: f.row.parentID, runID: "retry-run")
                #expect(f.consumer.pendingApproval(navigation: nav, pendingRequest: center.pendingRequest) == nil)
                #expect(!center.resumeFromTaskCenter(intent, consumer: f.consumer))
                #expect(center.isPresentationSuspended)
                center.stopGeneration()
                let denied = await waiter.value
                #expect(!denied.approved)
            }
        }
    }

    /// One real positive-delay production timer spans suspension and resumption.
    /// An 8s original timeout and resume at 4s leave disjoint outcomes:
    /// original expiry is at 8s (observed by 10s); restarting at resume expires
    /// no earlier than 12s and must fail this bounded observation.
    @Test func automaticDeadlineSurvivesTaskCenterSuspendAndResumeWithoutExtension() async throws {
        try await withRootAsync { root in
            let f = try await makeFixture(root: root)
            let center = ApprovalPromptCenter(expirationInterval: 8)
            let clock = ContinuousClock()
            let beforePresent = clock.now
            try await withPresented(center, request: f.request) { waiter in
                var observedDecision: ApprovalDecision?
                var observedAt: ContinuousClock.Instant?
                let observer = Task { @MainActor in
                    observedDecision = await waiter.value
                    observedAt = clock.now
                }
                let business: Result<Void, Error>
                do {
                    try #require(clock.now < beforePresent.advanced(by: .seconds(1)),
                                 "fixture must enter the accepted positive-delay timer window")
                    let row = try #require(f.consumer.receiptRows().first)
                    let nav = try #require(f.consumer.approvalNavigation(
                        for: row, pendingRequest: center.pendingRequest
                    ))
                    let originalRequest = center.pendingRequest
                    let originalEvents = f.tasks.events(runID: f.taskRunID)
                    let originalExpiresAt = f.request.expiresAt
                    let actions = center.actionsForPresentedRequest()
                    try #require(actions.viewTaskCenter(nav, f.consumer))
                    #expect(center.isPresentationSuspended)
                    #expect(!center.isPromptPresented)
                    #expect(center.pendingRequest == originalRequest)
                    print("TASK01_AUTO_TIMER phase=suspended originalTimeoutSeconds=8 requestID=\(f.request.requestID)")

                    // Yield the actor while the real timer is armed; do not
                    // block it with Thread.sleep or trigger any expiry API.
                    try await clock.sleep(until: beforePresent.advanced(by: .seconds(4)))
                    try #require(clock.now < beforePresent.advanced(by: .seconds(6)),
                                 "fixture must resume before the original deadline; no blind retry")
                    try #require(observedDecision == nil,
                                 "same waiter must still be pending before the original timeout")
                    try #require(center.requestTaskCenterResume(nav, consumer: f.consumer))
                    let intent = try #require(center.taskCenterResumeIntent)
                    try #require(center.resumeFromTaskCenter(intent, consumer: f.consumer))
                    #expect(center.isPromptPresented)
                    #expect(!center.isPresentationSuspended)
                    #expect(center.pendingRequest == originalRequest)
                    #expect(center.pendingRequest?.expiresAt == originalExpiresAt)
                    #expect(f.tasks.events(runID: f.taskRunID) == originalEvents)
                    print("TASK01_AUTO_TIMER phase=resumed elapsed=\(beforePresent.duration(to: clock.now)) requestID=\(f.request.requestID)")

                    let latestOriginalExpiry = beforePresent.advanced(by: .seconds(10))
                    while observedDecision == nil, clock.now < latestOriginalExpiry {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let decision = try #require(observedDecision,
                        "original automatic timer must finish by 10s; restarting at resume would finish at >=12s")
                    let completion = try #require(observedAt)
                    #expect(completion >= beforePresent.advanced(by: .seconds(8)),
                            "resumption must not synthesize an early expired result")
                    #expect(completion <= latestOriginalExpiry)
                    #expect(!decision.approved && !decision.confirmed && decision.status == .expired)
                    #expect(decision.requestID == f.request.requestID)
                    #expect(decision.bindingDigest == f.request.identityDigest)
                    #expect(center.lastDiagnostic?.code == .expired)
                    #expect(center.pendingRequest == nil)
                    #expect(!center.isPromptPresented && !center.isPresentationSuspended)
                    #expect(center.taskCenterResumeIntent == nil)
                    #expect(!center.requestTaskCenterResume(nav, consumer: f.consumer))
                    #expect(!center.resumeFromTaskCenter(intent, consumer: f.consumer))
                    #expect(f.tasks.events(runID: f.taskRunID) == originalEvents)
                    print("TASK01_AUTO_TIMER phase=expired status=\(decision.status.rawValue) elapsed=\(beforePresent.duration(to: completion)) requestID=\(decision.requestID ?? "nil")")
                    business = .success(())
                } catch {
                    business = .failure(error)
                }
                // Failure cleanup only: never convert a cancelled cleanup
                // decision into a successful typed-expiry assertion.
                if observedDecision == nil { waiter.cancel() }
                await observer.value
                try business.get()
            }
        }
    }

}
