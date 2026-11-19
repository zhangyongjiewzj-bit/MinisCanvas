import AppKit
import ApplicationServices
import Darwin
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

// New selectors for B0002 condition2. NOT_RUN; not an adaptation of original255.
// The real TaskCenterObservationView consumes the real Bridge consumer. This
// fixture never attaches production services, starts a provider, or submits work.
@MainActor
@Suite
struct BB7TaskCenterRuntimePresentationTests {
    @Test
    func childSessionLabelsAreHumanAndIdentifiersDistinguishRealRows() throws {
        try withFixture { fixture in
            var childIDs: [String] = []
            for index in 1...2 {
                let parent = UUID().uuidString
                let task = try fixture.tasks.enqueue(taskID: "F-SYNKEY-child-\(index)",
                    parentID: parent, providerID: "offline", modelID: "synthetic",
                    parentContextSnapshotID: "F-SYNKEY-context")
                _ = try fixture.sessions.createSession(id: parent)
                let run = try fixture.tasks.startRun(taskID: task.taskID,
                    parentID: parent, runID: "F-SYNKEY-child-run-\(index)")
                let child = parent + ":child:F-SYNKEY-exec-\(index)"
                _ = try fixture.sessions.forkSession(from: parent, id: child,
                    throughMessageIndex: 0, createdByTaskID: task.taskID, createdByRunID: run.runID)
                try fixture.sessions.saveMessage(.init(role: .assistant, content: "合成子会话正文"), sessionID: child)
                let attempt = try #require(fixture.tasks.canonicalAttemptID(runID: run.runID))
                let locator = ChildTranscriptLocator(childSessionID: child, parentSessionID: parent,
                    taskID: task.taskID, parentID: parent, runID: run.runID, attemptID: attempt,
                    childExecutionID: "F-SYNKEY-exec-\(index)", parentContextSnapshotID: task.parentContextSnapshotID)
                _ = try fixture.tasks.bindChildTranscript(locator)
                _ = try fixture.tasks.settleChildResult(ChildResultEnvelope(taskID: task.taskID,
                    runID: run.runID, attemptID: attempt, parentContextSnapshotID: task.parentContextSnapshotID,
                    childExecutionID: "F-SYNKEY-exec-\(index)", outcome: .succeeded,
                    outputDigest: "F-SYNKEY-digest-\(index)", idempotencyKey: "F-SYNKEY-idempotency-\(index)",
                    agentType: "codex", childTranscriptLocator: locator))
                let row = try #require(fixture.bridge.taskCenterControlConsumer.receiptRows()
                    .first { $0.taskID == task.taskID })
                #expect(row.childNavigation?.childSessionID == child)
                childIDs.append(child)
            }
            let before = fixture.tasks.taskCenterSnapshots()
            try fixture.withHost { window in
                let history = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "tasks-history-toggle"))
                #expect(NativeConsumerOwnedAX.press(history))
                fixture.pump(window)
                try fixture.requireHealthyWindow(window, phase: "child-after-history")
                var frames: [CGRect] = []
                for child in childIDs {
                    let initialResult = fixture.captureInitialChildQueryAndObserve(window, toggle: history,
                        identifier: "task-center-child-session-" + child)
                    let button = try #require(initialResult)
                    #expect(NativeConsumerOwnedAX.role(button) == .button)
                    #expect(NativeConsumerOwnedAX.enabled(button) == true)
                    let initialChildLabel = NativeConsumerOwnedAX.label(button)
                    fixture.observeGoalAttributes(button, initialLabel: initialChildLabel, context: "child")
                    #expect(initialChildLabel == "打开子会话并保留父任务位置")
                    let frame = try #require(NativeConsumerOwnedAX.frame(button))
                    #expect(frame.width > 0 && frame.height > 0)
                    frames.append(frame)
                }
                #expect(childIDs[0] != childIDs[1])
                #expect(frames[0] != frames[1])
            }
            #expect(fixture.tasks.taskCenterSnapshots() == before)
        }
    }

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func unmountedChildSessionProjectionUsesTheSameBridgeReleaseEndpoint(
        mountHost: Bool, locateSummary: Bool
    ) throws {
        // Preserve unmounted and mounted health-check controls. The third case
        // adds only summary lookup/role observation to distinguish its release
        // behavior; mounting already performs the existing healthy-window AX reads.
        try withFixture { fixture in
            var childIDs: [String] = []
            for index in 1...2 {
                let parent = UUID().uuidString
                let task = try fixture.tasks.enqueue(taskID: "F-SYNKEY-child-\(index)",
                    parentID: parent, providerID: "offline", modelID: "synthetic",
                    parentContextSnapshotID: "F-SYNKEY-context")
                _ = try fixture.sessions.createSession(id: parent)
                let run = try fixture.tasks.startRun(taskID: task.taskID,
                    parentID: parent, runID: "F-SYNKEY-child-run-\(index)")
                let child = parent + ":child:F-SYNKEY-exec-\(index)"
                _ = try fixture.sessions.forkSession(from: parent, id: child,
                    throughMessageIndex: 0, createdByTaskID: task.taskID, createdByRunID: run.runID)
                try fixture.sessions.saveMessage(.init(role: .assistant, content: "合成子会话正文"), sessionID: child)
                let attempt = try #require(fixture.tasks.canonicalAttemptID(runID: run.runID))
                let locator = ChildTranscriptLocator(childSessionID: child, parentSessionID: parent,
                    taskID: task.taskID, parentID: parent, runID: run.runID, attemptID: attempt,
                    childExecutionID: "F-SYNKEY-exec-\(index)", parentContextSnapshotID: task.parentContextSnapshotID)
                _ = try fixture.tasks.bindChildTranscript(locator)
                _ = try fixture.tasks.settleChildResult(ChildResultEnvelope(taskID: task.taskID,
                    runID: run.runID, attemptID: attempt, parentContextSnapshotID: task.parentContextSnapshotID,
                    childExecutionID: "F-SYNKEY-exec-\(index)", outcome: .succeeded,
                    outputDigest: "F-SYNKEY-digest-\(index)", idempotencyKey: "F-SYNKEY-idempotency-\(index)",
                    agentType: "codex", childTranscriptLocator: locator))
                let row = try #require(fixture.bridge.taskCenterControlConsumer.receiptRows()
                    .first { $0.taskID == task.taskID })
                #expect(row.childNavigation?.childSessionID == child)
                childIDs.append(child)
            }
            let before = fixture.tasks.taskCenterSnapshots()
            #expect(childIDs.count == 2 && childIDs[0] != childIDs[1])
            #expect(fixture.bridge.taskCenterControlConsumer.receiptRows().count == 2)
            if mountHost {
                try fixture.withHost { window in
                    if locateSummary {
                        let (foundSummary, isGroup) = autoreleasepool {
                            let found = NativeConsumerOwnedAX.find(
                                in: window, identifier: "task-center-summary")
                            let role = found.flatMap { NativeConsumerOwnedAX.role($0) }
                            return (found != nil, role == .group)
                        }
                        try #require(foundSummary)
                        #expect(isGroup)
                    }
                }
            }
            #expect(fixture.tasks.taskCenterSnapshots() == before)
        }
    }

    @Test
    func goalSummaryRendersHumanAuthorizationWithoutCanonicalScope() throws {
        try withFixture { fixture in
            let task = try fixture.tasks.enqueue(taskID: "F-SYNKEY-goal", parentID: UUID().uuidString,
                providerID: "offline", modelID: "synthetic")
            _ = try fixture.tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "F-SYNKEY-goal-run")
            let now = Date()
            let goalID = UUID()
            let scope = "F-SYNKEY-scope:" + UUID().uuidString
            fixture.bridge.taskCenterControlConsumer.installProductionGoal(
                goal: GoalEnvelope(goalID: goalID, scopeID: scope, allowedCapabilities: ["task.control"],
                    budget: 10, deadline: now.addingTimeInterval(3600), createdAt: now.addingTimeInterval(-60)),
                lease: AutonomyLease(leaseID: UUID(), goalID: goalID, scopeID: scope,
                    issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3600)))
            let facts = fixture.bridge.taskCenterControlConsumer.project(now: now)
            // The native assertion below is against the actual rendered row;
            // it is not a source-literal assertion or an unbound hand-made fact.
            let bound = try #require(facts.tasks.first { $0.taskID == task.taskID && $0.parentID == task.parentID })
            #expect(bound.isGoalBound && bound.scopeID == scope && bound.goalID == goalID)
            #expect(bound.leaseState == .active)
            let before = fixture.tasks.taskCenterSnapshots()
            try fixture.withHost { window in
                let expand = try #require(NativeConsumerOwnedAX.find(in: window, label: "展开详情"))
                #expect(NativeConsumerOwnedAX.press(expand))
                fixture.pump(window)
                let summary = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifier: "task-center-lease-state-" + goalID.uuidString))
                let initialLabel = NativeConsumerOwnedAX.label(summary)
                fixture.observeGoalAttributes(summary, initialLabel: initialLabel)
                let label = try #require(initialLabel)
                #expect(label == "任务授权有效")
                #expect(!label.contains(scope))
                #expect(!label.contains(goalID.uuidString))
                let frame = try #require(NativeConsumerOwnedAX.frame(summary))
                #expect(frame.width > 0 && frame.height > 0)
            }
            #expect(fixture.tasks.taskCenterSnapshots() == before)
        }
    }

    @Test
    func goalSummaryKeepsReadableLeaseAndCanonicalScopeInDetails() throws {
        try withFixture { fixture in
            let task = try fixture.tasks.enqueue(taskID: "F-SYNKEY-goal", parentID: UUID().uuidString,
                providerID: "offline", modelID: "synthetic", dispatchHumanTitle: "核对合成授权任务")
            _ = try fixture.tasks.startRun(taskID: task.taskID, parentID: task.parentID, runID: "F-SYNKEY-goal-run")
            let now = Date()
            let goalID = UUID()
            let scope = "F-SYNKEY-scope:" + UUID().uuidString
            fixture.bridge.taskCenterControlConsumer.installProductionGoal(
                goal: GoalEnvelope(goalID: goalID, scopeID: scope, allowedCapabilities: ["task.control"],
                    budget: 10, deadline: now.addingTimeInterval(3600), createdAt: now.addingTimeInterval(-60)),
                lease: AutonomyLease(leaseID: UUID(), goalID: goalID, scopeID: scope,
                    issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3600)))
            let facts = fixture.bridge.taskCenterControlConsumer.project(now: now)
            // The native assertion below is against the actual rendered row;
            // it is not a source-literal assertion or an unbound hand-made fact.
            let bound = try #require(facts.tasks.first { $0.taskID == task.taskID && $0.parentID == task.parentID })
            #expect(bound.isGoalBound && bound.scopeID == scope && bound.goalID == goalID)
            #expect(bound.leaseState == .active)
            #expect(bound.childGrantedCapabilities == nil)
            #expect(bound.childCapabilityIntersection == nil)
            #expect(bound.childWorkingDirectory == nil)
            let before = fixture.tasks.taskCenterSnapshots()
            try fixture.withHost { window in
                // 20261030T2016: migrate the original source-position oracle to
                // the rendered task row; the independent Goal group is observed separately.
                // This fixture has one task. The existing owned AX query
                // rejects absent/ambiguous row prefixes; the readable title
                // below binds that actual row without a private ID algorithm.
                let collapsedRow = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifierPrefix: "task-center-row-", excludingPrefix: "task-center-row-title-"))
                let rowID = try #require(NativeConsumerOwnedAX.attribute(collapsedRow,
                    kAXIdentifierAttribute as CFString) as? String)
                let collapsed = try #require(NativeConsumerOwnedAX.textSnapshot(in: window, identifier: rowID))
                #expect(collapsed.texts.contains("核对合成授权任务"))
                let internalTokens = [scope, String(scope.dropFirst("F-SYNKEY-scope:".count)),
                    goalID.uuidString, task.parentID]
                #expect(!collapsed.texts.contains { text in
                    internalTokens.contains { text.contains($0) } || text.localizedCaseInsensitiveContains("scope")
                })
                let expand = try #require(NativeConsumerOwnedAX.find(in: window, label: "展开详情"))
                #expect(NativeConsumerOwnedAX.press(expand))
                fixture.pump(window)
                let expanded = try #require(NativeConsumerOwnedAX.textSnapshot(in: window, identifier: rowID))
                #expect(expanded.texts.contains("任务授权有效"))
                #expect(expanded.texts.contains("授权范围：" + scope))
                #expect(expanded.texts.contains("子能力摘要（具体操作仍受审批/安全策略约束）"))
                #expect(expanded.texts.contains("子能力：未知（未记录子能力边界）"))
                #expect(expanded.texts.contains("父任务授权仅表示父级目标与上限，不等于子任务全部有效权限"))
                let summaryLabels = try #require(expanded.labelsByIdentifier[
                    "task-center-lease-state-" + goalID.uuidString])
                try #require(summaryLabels.count == 1)
                let summaryLabel = try #require(summaryLabels.first)
                #expect(summaryLabel == "任务授权有效")
                #expect(!summaryLabel.localizedCaseInsensitiveContains("scope"))
                #expect(!summaryLabel.contains(goalID.uuidString))
                let row = try #require(NativeConsumerOwnedAX.find(in: window, identifier: rowID))
                let frame = try #require(NativeConsumerOwnedAX.frame(row))
                #expect(frame.width > 0 && frame.height > 0)
                print("BB7_2016_TASK_ROW_ASSERTIONS_RETURNED goalGroupStillIndependent=true")

                // P-14/P-15 and §4.7: the default human summary must not expose
                // technical scope; explicit advanced content must keep it readable.
                // Recursive AX descendants are not a visual-visibility oracle.
                let advancedID = "tasks-advanced-authorization"
                _ = try #require(NativeConsumerOwnedAX.textSnapshot(in: window,
                    identifier: advancedID))
                let advanced = try #require(NativeConsumerOwnedAX.find(in: window, identifier: advancedID))
                let defaultSummary = try #require(NativeConsumerOwnedAX.label(advanced))
                #expect(defaultSummary.contains("高级与授权"))
                #expect(!defaultSummary.contains(scope))
                #expect(!defaultSummary.contains(String(scope.dropFirst("F-SYNKEY-scope:".count))))
                #expect(NativeConsumerOwnedAX.press(advanced))
                fixture.pump(window)
                // The exact owned group being readable proves advanced content
                // opened. Its combined children need not expose a separate ID.
                let group = try #require(NativeConsumerOwnedAX.textSnapshot(in: window,
                    identifier: "task-center-goal-" + goalID.uuidString))
                #expect(group.texts.contains { $0.contains("任务授权有效") })
                #expect(group.texts.contains { $0.contains(scope) })
                // The contract does not require a Goal UUID text in advanced content.

            }
            #expect(fixture.tasks.taskCenterSnapshots() == before)
            print("BB7_2016_NATIVE_BUSINESS_ASSERTIONS_RETURNED cleanupQualificationStillIndependent=true")
        }
    }

    @Test
    func failedReceiptRendersHumanReasonAndRetainsSafeCodeInDetails() throws {
        try withFixture { fixture in
            let task = try fixture.tasks.enqueue(taskID: "F-SYNKEY-failed", parentID: UUID().uuidString,
                providerID: "offline", modelID: "synthetic", dispatchHumanTitle: "核对合成任务结果")
            let run = try fixture.tasks.startRun(taskID: task.taskID, parentID: task.parentID,
                runID: "F-SYNKEY-failed-run")
            _ = try fixture.tasks.finish(runID: run.runID, outcome: .failed(reason: "F-SYNKEY-private-detail"))
            let row = try #require(fixture.bridge.taskCenterControlConsumer.receiptRows()
                .first { $0.taskID == task.taskID })
            #expect(row.failureReason == "execution-failed")
            #expect(row.failureReasonDisplayTitle == "执行未完成，请查看任务详情")
            let before = fixture.tasks.taskCenterSnapshots()
            try fixture.withHost { window in
                let reason = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifier: "task-center-failure-" + task.taskID))
                let initialFailureLabel = NativeConsumerOwnedAX.label(reason)
                fixture.observeGoalAttributes(reason, initialLabel: initialFailureLabel, context: "failure")
                let label = try #require(initialFailureLabel)
                #expect(label == "失败原因：执行未完成，请查看任务详情")
                #expect(!label.contains("execution-failed"))
                #expect(!label.contains("F-SYNKEY-private-detail"))
                let expand = try #require(NativeConsumerOwnedAX.find(in: window, label: "展开详情"))
                #expect(NativeConsumerOwnedAX.press(expand))
                fixture.pump(window)
                try fixture.requireHealthyWindow(window, phase: "failure-after-expand")
                let safeCode = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifier: "task-center-failure-code-" + task.taskID))
                #expect(NativeConsumerOwnedAX.label(safeCode) == "失败原因：执行失败")
            }
            #expect(fixture.tasks.taskCenterSnapshots() == before)
        }
    }

    private func withFixture(_ body: (BB7RuntimeFixture) throws -> Void) throws {
        try bb7RuntimeOwnedDirectory { directory in
            let domain = "MinisCanvasTests.F-SYNKEY.BB7Runtime." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            let business: Result<Void, any Error> = Result {
                let weakObservation = BB7RuntimeWeakObservation()
                weak var weakBridge: BridgeStore?
                // User-approved C decision: drain the fixture's autoreleases before the original weak assertion.
                try autoreleasepool {
                    var fixture: BB7RuntimeFixture? = BB7RuntimeFixture(root: directory, defaults: defaults)
                    weakBridge = fixture?.bridge
                    weakObservation.fixture = fixture
                    weakObservation.bridge = fixture?.bridge
                    fixture?.weakObservation = weakObservation
                    weakObservation.record("fixture-created")
                    try body(try #require(fixture))
                    weakObservation.record("body-returned-before-fixture-nil")
                    fixture = nil
                    weakObservation.record("fixture-nil-before-original-weak-assertion")
                }
                weakObservation.recordPostPool()
                weakObservation.recordToolbarPostPool()
                try #require(weakBridge == nil, "UI must release the actual Bridge before owned-root cleanup")
            }
            if case .failure(let error) = business {
                print("BB7_RUNTIME_SUITE_RETAINED domain=\(domain)")
                throw error
            }
            defaults.removePersistentDomain(forName: domain)
            let cleanup: Result<Void, any Error> = Result {
                try #require(defaults.persistentDomain(forName: domain) == nil)
            }
            switch (business, cleanup) {
            case (.success, .success): return
            case (.failure(let e), .success): throw e
            case (.success, .failure(let e)): throw e
            case (.failure(let a), .failure(let b)):
                throw NSError(domain: "BB7RuntimeBusinessAndSuiteCleanup", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "business=\(a); cleanup=\(b)"])
            }
        }
    }
}

@MainActor
private final class BB7RuntimeFixture {
    let tasks = AgentTaskStore()
    let sessions: SessionStore
    let bridge: BridgeStore
    var weakObservation: BB7RuntimeWeakObservation?
    private var didObserveOriginalChildQuery = false
    init(root: URL, defaults: UserDefaults) {
        sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let log = LogManager(directory: root.appendingPathComponent("logs"))
        bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: log, workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory), sessionStore: sessions,
            canvasRuntimeState: .disabled, agentTaskStore: tasks, contextManifestStore: ContextManifestStore(),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        bridge.taskCenterControlConsumer.bindChildTranscriptSessionStore(sessions)
    }
    func pump(_ window: NSWindow) {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }
    // Diagnostic-only: original unpinned host and original immediate result.
    // Later results are logged, NEVER substituted for the original assertion.
    func captureInitialChildQueryAndObserve(_ window: NSWindow, toggle: AnyObject, identifier: String) -> AnyObject? {
        let queryStart = ProcessInfo.processInfo.systemUptime
        let initial = NativeConsumerOwnedAX.find(in: window, identifier: identifier)
        let queryEnd = ProcessInfo.processInfo.systemUptime
        print("BB7_ORIGINAL_IMMEDIATE_QUERY epoch=\(Date().timeIntervalSince1970) start=\(queryStart) end=\(queryEnd) found=\(initial != nil) identifier=\(identifier)")
        guard !didObserveOriginalChildQuery else { return initial }
        didObserveOriginalChildQuery = true
        let end = queryEnd + 2.0
        var index = 0
        while index < 20 && ProcessInfo.processInfo.systemUptime < end {
            let target = queryEnd + Double(index + 1) * 0.1
            while ProcessInfo.processInfo.systemUptime < min(target, end) {
                _ = RunLoop.main.run(mode: .default,
                    before: Date(timeIntervalSinceNow: min(0.01, max(0, target - ProcessInfo.processInfo.systemUptime))))
            }
            guard ProcessInfo.processInfo.systemUptime < end else { break }
            let sampleDeadline = min(end, ProcessInfo.processInfo.systemUptime + 0.045)
            let subtree = diagnosticHistorySubtree(toggle, deadline: sampleDeadline)
            let record: [String: Any] = [
                "phase": "BB7_ORIGINAL_FIXTURE_AFTER_TOGGLE_OBSERVATION",
                "sample": index + 1, "uptime": ProcessInfo.processInfo.systemUptime,
                "initial_query_start": queryStart, "initial_query_end": queryEnd,
                "initial_result_found": initial != nil,
                "window_frame": NSStringFromRect(window.frame),
                "content_frame": window.contentView.map { NSStringFromRect($0.frame) } ?? "nil",
                "isKey": window.isKeyWindow, "isActive": NSApplication.shared.isActive,
                "frontmostPIDRecordedOnly": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "target_identifier": identifier,
                "actual_owned_subtree": subtree
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { print(line) }
            else { print("BB7_DIAGNOSTIC_JSON_UNAVAILABLE original_assertion_still_uses_initial_result=true") }
            index += 1
        }
        print("BB7_ORIGINAL_FIXTURE_OBSERVATION_END elapsed=\(ProcessInfo.processInfo.systemUptime - queryEnd) samples=\(index) originalResultRetained=true")
        return initial
    }

    private func diagnosticHistorySubtree(_ toggle: AnyObject, deadline: TimeInterval) -> [[String: String]] {
        // Start at the already owner-bound history control; avoid a fresh
        // multi-second whole-window search in the two-second observation.
        var root: AnyObject = toggle
        var ancestryStatus = "ANCESTRY_BOUND_REACHED"
        for _ in 0..<8 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let element = NativeConsumerOwnedAX.element(root) else { break }
            _ = AXUIElementSetMessagingTimeout(element, 0.003)
            let role = NativeConsumerOwnedAX.role(root)
            if role == .scrollArea || role == .window { ancestryStatus = "OWNED_SCROLL_OR_WINDOW_ANCESTOR"; break }
            guard let parent = NativeConsumerOwnedAX.attribute(root, kAXParentAttribute as CFString) else { break }
            // Stop before leaving the own window for an application root.
            guard let parentElement = NativeConsumerOwnedAX.element(parent) else { break }
            _ = AXUIElementSetMessagingTimeout(parentElement, 0.003)
            if NativeConsumerOwnedAX.role(parent) == .application { break }
            root = parent
        }
        var pending: [(AnyObject, Int)] = [(root, 0)]
        var result: [[String: String]] = [["observation": ancestryStatus]]
        var seen = Set<CFHashCode>()
        while let (node, depth) = pending.popLast() {
            guard result.count < 128, depth <= 12, ProcessInfo.processInfo.systemUptime < deadline else {
                result.append(["observation": "BOUNDED_SUBTREE_TRUNCATED_OR_SAMPLE_DEADLINE"])
                break
            }
            guard let element = NativeConsumerOwnedAX.element(node) else { continue }
            guard seen.insert(CFHash(element)).inserted else { continue }
            let remaining = max(0.001, min(0.003, deadline - ProcessInfo.processInfo.systemUptime))
            guard AXUIElementSetMessagingTimeout(element, Float(remaining)) == .success else {
                result.append(["observation": "AX_TIMEOUT_CONFIGURATION_FAILED"]); continue
            }
            let id = NativeConsumerOwnedAX.attribute(node, kAXIdentifierAttribute as CFString) as? String
            let label = NativeConsumerOwnedAX.label(node)
            let role = NativeConsumerOwnedAX.role(node)?.rawValue
            let frame = NativeConsumerOwnedAX.frame(node)
            result.append(["role": role ?? "UNAVAILABLE", "identifier": id ?? "UNAVAILABLE",
                "label": label.map { String($0.prefix(1024)) } ?? "UNAVAILABLE",
                "frame": frame.map { NSStringFromRect($0) } ?? "UNAVAILABLE", "depth": String(depth)])
            if let children = NativeConsumerOwnedAX.attribute(node, kAXChildrenAttribute as CFString) as? [AnyObject] {
                for child in children.reversed() { pending.append((child, depth + 1)) }
            }
        }
        return result
    }

    func requireHealthyWindow(_ window: NSWindow, phase: String) throws {
        // This is a fixture gate, not a product text assertion. In particular,
        // manually fixed NSView.bounds cannot satisfy an unhealthy NSWindow.
        let ownID = window.accessibilityIdentifier()
        let app = AXUIElementCreateApplication(getpid())
        try #require(AXUIElementSetMessagingTimeout(app, 0.05) == .success)
        var rawWindows: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows)
        try #require(windowsError == .success)
        let windows = try #require(rawWindows as? [AXUIElement])
        try #require(windows.count <= 16)
        let matches = windows.filter { candidate in
            _ = AXUIElementSetMessagingTimeout(candidate, 0.05)
            return (NativeConsumerOwnedAX.attribute(candidate, kAXIdentifierAttribute as CFString) as? String) == ownID
        }
        try #require(matches.count == 1, "fixture own AXWindow must be unique")
        let axWindow = try #require(matches.first)
        var ownerPID: pid_t = 0
        try #require(AXUIElementGetPid(axWindow, &ownerPID) == .success && ownerPID == getpid())
        try #require(NativeConsumerOwnedAX.role(axWindow) == .window)
        var rawSize: CFTypeRef?
        let sizeError = AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &rawSize)
        var size = CGSize.zero
        var sizeReadable = false
        if sizeError == .success, let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() {
            sizeReadable = AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size)
        }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let layout = window.contentLayoutRect
        let visible = window.screen?.visibleFrame
        print("BB7_HEALTHY_WINDOW phase=\(phase) frame=\(window.frame) contentRect=\(contentRect) contentFrame=\(String(describing: window.contentView?.frame)) contentLayoutRect=\(layout) AXSizeError=\(sizeError.rawValue) AXSizeReadable=\(sizeReadable) AXSize=\(size) key=\(window.isKeyWindow) active=\(NSApplication.shared.isActive) frontmostPIDRecordedOnly=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) visible=\(window.isVisible) screenVisible=\(String(describing: visible)) initialActivationAttempts=1")
        try #require(window.frame.width >= 1000 && window.frame.height >= 1000,
            "FIXTURE_UNHEALTHY_ACTUAL_NSWINDOW_FRAME")
        try #require(sizeReadable && size.width >= 1000 && size.height >= 1000,
            "FIXTURE_UNHEALTHY_ACTUAL_AXWINDOW_SIZE")
        try #require(contentRect.width >= 999 && contentRect.height >= 999
            && layout.width >= 999 && layout.height >= 999,
            "FIXTURE_UNHEALTHY_ACTUAL_CONTENT_LAYOUT_RECT")
        let screenVisible = try #require(visible)
        try #require(screenVisible.insetBy(dx: -1, dy: -1).contains(window.frame),
            "FIXTURE_WINDOW_DOES_NOT_FIT_VISIBLE_SCREEN; never shrink below Main minimum")
        // Main B0515: this in-process native presentation scope records
        // key/active/frontmost; field foreground guards remain unchanged.
        try #require(window.isVisible, "FIXTURE_WINDOW_NOT_VISIBLE")
    }

    func observeGoalAttributes(_ summary: AnyObject, initialLabel: String?, context: String = "goal") {
        // Diagnostic only. Neither AXValue nor a child can replace the saved
        // initialLabel in the existing human/scope assertions.
        var queue: [(AnyObject, Int)] = [(summary, 0)]
        var output: [[String: Any]] = []
        while !queue.isEmpty && output.count < 16 {
            let (object, depth) = queue.removeFirst()
            guard let element = NativeConsumerOwnedAX.element(object) else { continue }
            _ = AXUIElementSetMessagingTimeout(element, 0.02)
            var row: [String: Any] = ["depth": depth]
            for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
                         kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute] {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                let key = name as String
                row[key + "Error"] = error.rawValue
                row[key] = (value as? String).map { String($0.prefix(1024)) } ?? "NO_STRING_VALUE"
            }
            var children: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            row["AXChildrenError"] = error.rawValue
            let actualChildren = children as? [AnyObject]
            row["AXChildrenCount"] = actualChildren?.count ?? -1
            output.append(row)
            if depth < 2, let actualChildren {
                queue.append(contentsOf: actualChildren.prefix(16).map { ($0, depth + 1) })
            }
        }
        let record: [String: Any] = ["phase": context == "goal" ? "BB7_GOAL_ATTRIBUTE_OBSERVATION" : "BB7_" + context.uppercased() + "_LABEL_ATTRIBUTE_OBSERVATION",
            "context": context,
            "initialLabelWasNil": initialLabel == nil, "initialLabel": initialLabel ?? "NIL",
            "keyWindowPresentRecordedOnly": NSApplication.shared.keyWindow != nil,
            "isActiveRecordedOnly": NSApplication.shared.isActive,
            "frontmostPIDRecordedOnly": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "nodes": output, "truncated": !queue.isEmpty]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
        else { print("BB7_GOAL_ATTRIBUTE_OBSERVATION_UNAVAILABLE initialLabelStillAuthoritative=true") }
    }

    func withHost(_ body: (NSWindow) throws -> Void) throws {
        let contentSize = NSSize(width: 1000, height: 1000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = contentSize
        let controller = NSHostingController(rootView:
            TaskCenterObservationView(bridge: bridge).frame(width: 1000, height: 1000))
        controller.sizingOptions = []
        window.contentViewController = controller
        weakObservation?.window = window
        weakObservation?.controller = controller
        weakObservation?.rootView = controller.view
        weakObservation?.record("host-created-local-owners-alive")
        // NSWindow.h says contentMinSize is ignored by Auto Layout. Required
        // owned-root constraints therefore express the same minimum there.
        NSLayoutConstraint.activate([
            controller.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 1000),
            controller.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 1000)
        ])
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        window.setContentSize(contentSize)
        var actualFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            actualFrame.origin = NSPoint(x: visible.minX, y: visible.maxY - actualFrame.height)
        }
        window.setFrame(actualFrame, display: true)
        window.setAccessibilityIdentifier("F-SYNKEY-BB7Condition2-" + UUID().uuidString)
        // Make the owned window exist before the ONE existing lifecycle
        // activation. No extra application.activate calls, retries or input.
        window.orderFrontRegardless()
        let lease = NativeTestHostLifecycle.begin("BB7Condition2HealthyWindow")
        NativeTestHostLifecycle.bind(lease, to: window)
        print("BB7_HEALTHY_HOST_INITIAL_ACTIVATION attempts=1 source=NativeTestHostLifecycle.begin only=true")
        window.makeKeyAndOrderFront(nil)
        pump(window)
        weakObservation?.captureToolbarWeakIdentities()
        let business = Result {
            try requireHealthyWindow(window, phase: "before-business")
            try body(window)
        }
        window.orderOut(nil)
        window.contentViewController = nil
        // SwiftUI toolbar hosts are independent of contentViewController. The
        // real post-pool trace showed this owned window still attached to both.
        window.toolbar = nil
        window.close()
        weakObservation?.closeWasCalled = true
        NativeTestHostLifecycle.end(window)
        weakObservation?.record("host-closed-local-owners-still-in-scope")
        let cleanup: Result<Void, any Error> = Result {
            try #require(!window.isVisible && window.contentViewController == nil)
        }
        switch (business, cleanup) {
        case (.success, .success): return
        case (.failure(let e), .success): throw e
        case (.success, .failure(let e)): throw e
        case (.failure(let a), .failure(let b)):
            throw NSError(domain: "BB7RuntimeBusinessAndWindowCleanup", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "business=\(a); cleanup=\(b)"])
        }
    }
}

// Weak probes only: no object descriptions, Mirror, extra strong owner or wait.
// A retained probe does not retain any of the five observed objects.
@MainActor
private struct BB7ToolbarWeakIdentity {
    weak var item: NSToolbarItem?
    weak var view: NSView?
    let originalItemID: ObjectIdentifier
    let originalViewID: ObjectIdentifier?
    let itemIdentifier: String
    init(item: NSToolbarItem) {
        self.item = item
        self.view = item.view
        self.originalItemID = ObjectIdentifier(item)
        self.originalViewID = item.view.map { ObjectIdentifier($0) }
        self.itemIdentifier = item.itemIdentifier.rawValue
    }
}

@MainActor
private final class BB7RuntimeWeakObservation {
    weak var fixture: BB7RuntimeFixture?
    weak var bridge: BridgeStore?
    weak var window: NSWindow?
    weak var controller: NSViewController?
    weak var rootView: NSView?
    weak var toolbar: NSToolbar?
    private var originalToolbarID: ObjectIdentifier?
    private var originalToolbarItemCount: Int?
    private var toolbarWeakIdentities: [BB7ToolbarWeakIdentity] = []
    var closeWasCalled = false

    func captureToolbarWeakIdentities() {
        toolbar = window?.toolbar
        originalToolbarID = toolbar.map { ObjectIdentifier($0) }
        originalToolbarItemCount = toolbar?.items.count
        toolbarWeakIdentities = toolbar?.items.prefix(3).map { BB7ToolbarWeakIdentity(item: $0) } ?? []
    }

    @inline(never)
    private func ownedHostIdentity() -> (listed: Bool, content: Bool, attached: Bool, contentController: Bool, loadedView: Bool) {
        return autoreleasepool {
            let ownedWindow = window
            let ownedRoot = rootView
            let ownedController = controller
            return (
                ownedWindow.map { owned in NSApp.windows.contains { $0 === owned } } ?? false,
                ownedWindow != nil && ownedRoot != nil && ownedWindow?.contentView === ownedRoot,
                ownedWindow != nil && ownedRoot != nil && ownedRoot?.window === ownedWindow,
                ownedWindow != nil && ownedController != nil && ownedWindow?.contentViewController === ownedController,
                ownedController != nil && ownedRoot != nil && ownedController?.viewIfLoaded === ownedRoot
            )
        }
    }

    func recordPostPool() {
        // Weak loads produce only value metadata; no object is stored or described.
        // Do not reuse ownedHostIdentity: its separate autoreleasepool is not part of this trace.
        let fixtureID = fixture.map { ObjectIdentifier($0) }
        let bridgeID = bridge.map { ObjectIdentifier($0) }
        let windowID = window.map { ObjectIdentifier($0) }
        let controllerID = controller.map { ObjectIdentifier($0) }
        let rootViewID = rootView.map { ObjectIdentifier($0) }
        let bridgeType = bridge.map { String(reflecting: type(of: $0)) } ?? "nil"
        let windowType = window.map { String(reflecting: type(of: $0)) } ?? "nil"
        let controllerType = controller.map { String(reflecting: type(of: $0)) } ?? "nil"
        let rootViewType = rootView.map { String(reflecting: type(of: $0)) } ?? "nil"
        print("BB7_POST_POOL_WEAK_TRACE fixtureNil=\(fixtureID == nil) bridgeNil=\(bridgeID == nil) windowNil=\(windowID == nil) controllerNil=\(controllerID == nil) rootViewNil=\(rootViewID == nil) fixtureID=\(String(describing: fixtureID)) bridgeID=\(String(describing: bridgeID)) windowID=\(String(describing: windowID)) controllerID=\(String(describing: controllerID)) rootViewID=\(String(describing: rootViewID)) bridgeType=\(bridgeType) windowType=\(windowType) controllerType=\(controllerType) rootViewType=\(rootViewType) externalStrongRoot=UNKNOWN traceOnly=true")
    }

    func recordToolbarPostPool() {
        let currentToolbarID = (window?.toolbar).map { ObjectIdentifier($0) }
        let sameToolbar = originalToolbarID != nil && originalToolbarID == currentToolbarID
        let releasedWhenClosed = window.map { $0.isReleasedWhenClosed }
        let listedInApp = window.map { owned in NSApp.windows.contains { $0 === owned } }
        let currentItemCount = window?.toolbar?.items.count
        print("BB7_POST_POOL_TOOLBAR closeWasCalled=\(closeWasCalled) isReleasedWhenClosed=\(String(describing: releasedWhenClosed)) originalWindowInNSAppWindows=\(String(describing: listedInApp)) originalToolbarID=\(String(describing: originalToolbarID)) currentToolbarID=\(String(describing: currentToolbarID)) windowStillConnectsOriginalToolbar=\(sameToolbar) originalItemCount=\(String(describing: originalToolbarItemCount)) currentItemCount=\(String(describing: currentItemCount)) capturedItemCount=\(toolbarWeakIdentities.count) itemLimit=3")
        for (index, identity) in toolbarWeakIdentities.enumerated() {
            let itemID = identity.item.map { ObjectIdentifier($0) }
            let viewID = identity.view.map { ObjectIdentifier($0) }
            let itemType = identity.item.map { String(reflecting: type(of: $0)) } ?? "nil"
            let viewType = identity.view.map { String(reflecting: type(of: $0)) } ?? "nil"
            let connectedItem = identity.item != nil && window?.toolbar?.items.contains {
                $0 === identity.item
            } == true
            let sameView = identity.view != nil && identity.item?.view === identity.view
            print("BB7_POST_POOL_TOOLBAR_ITEM index=\(index) itemIdentifier=\(identity.itemIdentifier) originalItemID=\(identity.originalItemID) currentItemID=\(String(describing: itemID)) itemType=\(itemType) itemNil=\(itemID == nil) windowToolbarContainsOriginalItem=\(connectedItem) originalViewID=\(String(describing: identity.originalViewID)) currentViewID=\(String(describing: viewID)) viewType=\(viewType) viewNil=\(viewID == nil) originalItemStillConnectsOriginalView=\(sameView) bridgeCausality=UNKNOWN")
        }
    }

    func record(_ phase: String) {
        let owned = ownedHostIdentity()
        print("BB7_WEAK_OBSERVATION phase=\(phase) fixtureNil=\(fixture == nil) bridgeNil=\(bridge == nil) windowNil=\(window == nil) controllerNil=\(controller == nil) rootViewNil=\(rootView == nil) ownedWindowInNSAppWindows=\(owned.listed) ownedWindowContentIsRoot=\(owned.content) ownedRootWindowIsOwned=\(owned.attached) ownedWindowControllerIsOriginal=\(owned.contentController) ownedControllerLoadedViewIsRoot=\(owned.loadedView)")
    }
}

// On a throwing admission/business/closure check, preserve the root and suite
// for the independent worker owner. Never delete a possibly-live host's files.
private func bb7RuntimeOwnedDirectory(_ body: (URL) throws -> Void) throws {
    let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
    let parent = formal.rootDirectory
    var parentStat = stat()
    try #require(lstat(parent.path, &parentStat) == 0)
    try #require((parentStat.st_mode & S_IFMT) == S_IFDIR && (parentStat.st_mode & 0o777) == 0o700)
    try #require(parentStat.st_uid == geteuid() && parentStat.st_uid == formal.rootOwner)
    try #require(UInt64(parentStat.st_dev) == formal.rootDevice && UInt64(parentStat.st_ino) == formal.rootInode)
    let root = parent.appendingPathComponent("F-SYNKEY-BB7Runtime-" + UUID().uuidString, isDirectory: true)
    try #require(mkdir(root.path, 0o700) == 0)
    var initial = stat()
    try #require(lstat(root.path, &initial) == 0)
    try #require((initial.st_mode & S_IFMT) == S_IFDIR && (initial.st_mode & 0o777) == 0o700)
    try #require(initial.st_uid == parentStat.st_uid && initial.st_dev == parentStat.st_dev && initial.st_ino != parentStat.st_ino)
    print("BB7_RUNTIME_OWNED_BEGIN path=\(root.path) dev=\(initial.st_dev) ino=\(initial.st_ino) uid=\(initial.st_uid) mode=700")
    do { try body(root) }
    catch {
        print("BB7_RUNTIME_ROOT_RETAINED businessOrQualificationError=true")
        throw error
    }
    var current = stat()
    try #require(lstat(root.path, &current) == 0)
    try #require(current.st_dev == initial.st_dev && current.st_ino == initial.st_ino && current.st_uid == initial.st_uid)
    try #require((current.st_mode & S_IFMT) == S_IFDIR && (current.st_mode & 0o777) == 0o700)
    try FileManager().removeItem(at: root)
    errno = 0
    try #require(lstat(root.path, &current) == -1 && errno == ENOENT)
    print("BB7_RUNTIME_OWNED_END weakBridgeNil=true hostClosed=true cleanup_ENOENT=true")
}
