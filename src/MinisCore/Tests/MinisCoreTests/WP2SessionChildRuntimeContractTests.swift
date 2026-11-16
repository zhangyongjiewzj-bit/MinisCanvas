import Foundation
import Testing
@testable import MinisCore

@Suite("WP-2 session and child runtime contract")
struct WP2SessionChildRuntimeContractTests {
    private let parent = ParentRuntimeIdentity(
        sessionID: "session-parent",
        conversationID: "conversation-parent",
        turnID: "turn-7",
        taskID: "task-parent",
        actorID: "user"
    )

    private let provider = ParentContextSnapshotV1(
        providerID: "custom",
        modelID: "gpt-5.6-luna",
        configurationFingerprint: "fingerprint",
        profileID: "implicit-default",
        baseHost: "hemasir.online",
        wireAPI: "responses",
        reasoningConfiguration: "max",
        conversationID: "conversation-parent"
    )

    @Test
    func sessionActionFreezesAllWritebackIdentity() throws {
        let action = SessionAction.new(
            title: "测试 2",
            projectID: "project-a",
            workingDirectory: "/tmp/project-a",
            switchAfterCreate: true,
            source: parent
        )

        let receipt = try action.validateAndReceipt(
            createdSessionID: "session-new",
            switched: true
        )

        #expect(receipt.action == .new)
        #expect(receipt.sessionID == "session-new")
        #expect(receipt.source == parent)
        #expect(receipt.projectID == "project-a")
        #expect(receipt.workingDirectory == "/tmp/project-a")
        #expect(receipt.didSwitch)
    }

    @Test
    func renameAndSwitchReceiptsCannotRebindToAnotherSession() {
        let rename = SessionAction.rename(
            sessionID: "session-target",
            title: "重命名",
            source: parent
        )
        #expect(throws: SessionActionError.invalidTarget) {
            try rename.validateAndReceipt(
                createdSessionID: "session-other",
                switched: false
            )
        }

        let switchAction = SessionAction.switch(
            sessionID: "session-target",
            source: parent
        )
        #expect(throws: SessionActionError.invalidTarget) {
            try switchAction.validateAndReceipt(
                createdSessionID: "session-other",
                switched: true
            )
        }
    }

    @Test
    func forkReceiptRetainsTheSourceTargetAndRejectsSelfFork() throws {
        let sourceTarget = "session-source"
        let fork = SessionAction.fork(sessionID: sourceTarget, source: parent)

        let receipt = try fork.validateAndReceipt(
            createdSessionID: "session-child",
            switched: true
        )

        #expect(receipt.targetSessionID == sourceTarget)
        #expect(throws: SessionActionError.invalidTarget) {
            try fork.validateAndReceipt(
                createdSessionID: sourceTarget,
                switched: true
            )
        }
    }

    @Test
    func malformedNewActionWithTargetFailsClosedAfterDecoding() throws {
        let action = SessionAction.new(title: "新会话", source: parent)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(action))
                as? [String: Any]
        )
        object["targetSessionID"] = "stale-target"
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let malformed = try JSONDecoder().decode(SessionAction.self, from: encoded)

        #expect(throws: SessionActionError.invalidTarget) {
            try malformed.validate(against: parent)
        }
    }

    @Test
    func whitespaceTargetFailsClosedAfterDecoding() throws {
        let action = SessionAction.switch(sessionID: "target", source: parent)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(action))
                as? [String: Any]
        )
        object["targetSessionID"] = " \n "
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let malformed = try JSONDecoder().decode(SessionAction.self, from: encoded)

        #expect(throws: SessionActionError.invalidTarget) {
            try malformed.validate(against: parent)
        }
    }

    @Test
    func invalidOrStaleSessionActionFailsClosed() {
        let action = SessionAction.switch(
            sessionID: "session-other",
            source: parent
        )

        #expect(throws: SessionActionError.sourceTurnMismatch) {
            try action.validate(
                against: ParentRuntimeIdentity(
                    sessionID: parent.sessionID,
                    conversationID: parent.conversationID,
                    turnID: "turn-8",
                    taskID: parent.taskID,
                    actorID: parent.actorID
                )
            )
        }
    }

    @Test
    func childIdentityIntersectsCapabilitiesAndBlocksRecursiveOrchestration() throws {
        let child = try ChildRuntimeIdentity.derive(
            parent: parent,
            childSessionID: "session-child",
            childTaskID: "task-child",
            scopeID: "scope-child",
            requestedCapabilities: [.tools, .vision],
            parentCapabilities: [.tools, .audio],
            policyCapabilities: [.tools],
            providerSnapshot: provider,
            memoryScopeID: "memory-session-child",
            workingDirectory: "/tmp/project-a",
            cancelGeneration: 3,
            evidenceRoot: "/tmp/evidence/task-child"
        )

        #expect(child.grantedCapabilities == [.tools])
        #expect(child.parentSessionID == "session-parent")
        #expect(child.parentTurnID == "turn-7")
        #expect(child.cancelGeneration == 3)
        #expect(child.allowsOrchestration == false)
        #expect(throws: ChildRuntimeIdentityError.recursiveOrchestrationDenied) {
            try child.validating(required: [.tools], requestsOrchestration: true)
        }
    }

    @Test
    func orchestrationPlanBoundsParallelismAndPreservesFailureIsolation() throws {
        let plan = try OrchestrationPlan(
            parent: parent,
            childIdentities: [
                try makeChild(id: "a"),
                try makeChild(id: "b"),
                try makeChild(id: "c")
            ],
            requestedParallelism: 99,
            maxParallelism: 4,
            deadline: Date(timeIntervalSince1970: 100)
        )

        #expect(plan.effectiveParallelism == 4)
        #expect(plan.failureIsolation == .perChild)
        #expect(plan.childIdentities.map(\.childTaskID) == ["a", "b", "c"])
    }

    @Test
    func resultGuardRejectsCancelTimeoutAndLateGenerationButAllowsRecovery() async throws {
        let child = try makeChild(id: "recoverable", generation: 4)
        let guardrail = ChildResultGuard(identity: child)

        #expect(await guardrail.accept(.success, generation: 4))
        #expect(await guardrail.accept(.cancelled, generation: 4) == false)
        #expect(await guardrail.accept(.success, generation: 3) == false)
        let timedOut = ChildResultGuard(identity: child)
        #expect(await timedOut.accept(.timedOut, generation: 4))
        #expect(await timedOut.recover())
        #expect(await timedOut.accept(.success, generation: 5))
    }

    @Test
    func registryRebindFencesStaleChildAndProviderFacts() {
        let registry = LLMSessionRegistry()
        let first = registry.register(
            providerID: "custom",
            sessionID: "session-child",
            sessionToken: "token-1"
        )
        #expect(first.generation == 1)
        #expect(first.stableID.count == 64)
        #expect(!first.stableID.contains("custom"))
        #expect(!first.stableID.contains("session-child"))
        #expect(registry.accepts(first))
        #expect(registry.currentEntry(
            providerID: "custom",
            sessionID: "session-child"
        ) == first)

        let rebound = registry.register(
            providerID: "custom",
            sessionID: "session-child",
            sessionToken: "token-2"
        )
        #expect(rebound.generation == 2)
        #expect(!registry.accepts(first))
        #expect(registry.accepts(rebound))
        #expect(registry.sessionToken(for: "custom") == nil)
        #expect(registry.currentEntry(
            providerID: "custom",
            sessionID: "session-child"
        )?.sessionToken == "token-2")

        registry.invalidate(providerID: "custom", sessionID: "session-child")
        #expect(!registry.accepts(rebound))
        let rebuilt = registry.register(
            providerID: "custom",
            sessionID: "session-child",
            sessionToken: "token-3"
        )
        #expect(rebuilt.generation == 3)
        #expect(registry.accepts(rebuilt))
    }

    @Test
    func registryRejectsAmbiguousProviderLookupAndRestartedEntries() {
        let registry = LLMSessionRegistry()
        let childA = registry.register(
            providerID: "custom",
            sessionID: "child-a",
            sessionToken: "token-a"
        )
        let childB = registry.register(
            providerID: "custom",
            sessionID: "child-b",
            sessionToken: "token-b"
        )
        #expect(registry.sessionToken(for: "custom") == nil)
        #expect(registry.currentEntry(providerID: "custom", sessionID: "child-a") == childA)
        #expect(registry.currentEntry(providerID: "custom", sessionID: "child-b") == childB)

        let providerOnly = registry.register(providerID: "custom", sessionToken: "provider-token")
        #expect(registry.sessionToken(for: "custom") == "provider-token")
        #expect(registry.accepts(providerOnly))

        let restarted = LLMSessionRegistry()
        #expect(!restarted.accepts(childA))
        #expect(!restarted.accepts(childB))
    }

    @Test
    func registryRejectsUnaddressableIdentityInputs() throws {
        let registry = LLMSessionRegistry()
        #expect(throws: LLMSessionRegistryError.invalidProviderID(" \n")) {
            try registry.registerValidated(
                providerID: " \n",
                sessionID: "child",
                sessionToken: "token"
            )
        }
        #expect(throws: LLMSessionRegistryError.invalidSessionID("")) {
            try registry.registerValidated(
                providerID: "provider",
                sessionID: "",
                sessionToken: "token"
            )
        }
        #expect(throws: LLMSessionRegistryError.invalidSessionToken) {
            try registry.registerValidated(
                providerID: "provider",
                sessionID: "child",
                sessionToken: "\t"
            )
        }

        let invalid = registry.register(
            providerID: "",
            sessionID: "child",
            sessionToken: "token"
        )
        #expect(registry.count() == 0)
        #expect(!registry.accepts(invalid))
    }

    private func makeChild(id: String, generation: Int = 1) throws -> ChildRuntimeIdentity {
        try ChildRuntimeIdentity.derive(
            parent: parent,
            childSessionID: "session-\(id)",
            childTaskID: id,
            scopeID: "scope-\(id)",
            requestedCapabilities: [.tools],
            parentCapabilities: [.tools],
            policyCapabilities: [.tools],
            providerSnapshot: provider,
            memoryScopeID: "memory-\(id)",
            workingDirectory: "/tmp/project-a",
            cancelGeneration: generation,
            evidenceRoot: "/tmp/evidence/\(id)"
        )
    }
}
