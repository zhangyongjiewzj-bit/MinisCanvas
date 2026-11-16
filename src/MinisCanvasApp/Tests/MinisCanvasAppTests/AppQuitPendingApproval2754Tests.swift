import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-APP-12 bound Quit dismisses the actual pending approval")
@MainActor
struct AppQuitPendingApproval2754Tests {
    @Test func boundWillTerminateRejectsAndClearsPendingApproval() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "app-quit-approval-2754", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults, logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.sessionDirectory),
            canvasFeatureLane: .phase3NonCanvas)
        let lifecycle = AppLifecycleGuard.beginAtLaunch(defaults: defaults)
        let delegate = MinisCanvasAppDelegate()
        lifecycle.bind(appDelegate: delegate, bridge: bridge)
        let request = ApprovalRequest(
            id: "synthetic-quit-2754", toolName: "file_write",
            inputSummary: "synthetic isolated request, no external effect",
            riskLevel: .high, requiresApproval: true)
        let waiter = Task { await bridge.approvalCenter.present(request) }
        defer { waiter.cancel() }
        for _ in 0..<200 where bridge.approvalCenter.pendingRequest == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(bridge.approvalCenter.pendingRequest == request,
                "the real approval must remain pending before Quit")
        delegate.applicationWillTerminate(Notification(name: Notification.Name("synthetic-will-terminate")))
        #expect(bridge.approvalCenter.pendingRequest == nil,
                "the production bound Quit callback must dismiss its approval")
        // Bound the baseline failure: settle its still-live waiter only after
        // the assertion above, so missing production cleanup cannot hang tests.
        if bridge.approvalCenter.pendingRequest != nil {
            bridge.approvalCenter.stopGeneration()
        }
        let decision = await waiter.value
        #expect(!decision.approved, "Quit must reject pending work, never authorize it")
        #expect(bridge.approvalCenter.lastDiagnostic?.code == .cancelled)
        #expect(defaults.bool(forKey: AppLifecycleGuard.cleanExitDefaultsKey))
        // The same system callback can be repeated without resuming twice.
        delegate.applicationWillTerminate(Notification(name: Notification.Name("synthetic-will-terminate")))
        #expect(bridge.approvalCenter.pendingRequest == nil)
    }
}
