import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("H05 Engine advertises only its assembled registered fetch owner")
@MainActor struct WebFetchEngineAvailabilityTests {
    @Test func availabilitySurvivesTheActualRecordingAndConcurrencyWrappers() {
        let root = URL(fileURLWithPath: "/synthetic/project")
        let absent = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        #expect(!AgentLoopChatEngine.webFetchAvailable(in: absent))
        // The default native catalog now already registers web_fetch. This
        // phase deliberately exercises a configured but unregistered owner.
        let configured = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [], registeredToolNames: [],
            webFetch: WebFetchTransport(allowedDomains: ["allowed.example"]))
        #expect(!AgentLoopChatEngine.webFetchAvailable(in: configured))
        configured.registerToolNames([WebFetchToolContract.toolName])
        let now = Date()
        let goal = GoalEnvelope(scopeID: "web-fetch", allowedCapabilities: [WebFetchToolContract.toolName],
            networkDomains: ["allowed.example"], budget: 10, deadline: now.addingTimeInterval(60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let policy = PolicyEnforcedToolExecutor(base: configured, goal: goal, lease: lease)
        let recording = RecordingToolExecutor(base: policy, onRecorded: { _ in })
        let concurrent = ConcurrentToolLimitingExecutor(base: recording, maxConcurrent: 2)
        #expect(AgentLoopChatEngine.webFetchAvailable(in: recording))
        #expect(AgentLoopChatEngine.webFetchAvailable(in: concurrent))
    }
}
