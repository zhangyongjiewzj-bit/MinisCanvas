import Foundation
import Testing
@testable import MinisCore

// QODER-DEV-W13-EXTKEY-REJECTION-170 (lane 166 escalation, C0 ruling 600 /
// F-LANE-166-SPEC-BLOCKED): model-controlled external input must NOT be able
// to inflate the global child-concurrency ceiling. These tests lock the
// REJECTION CONTRACT for the `enabled_session_count` key carried by an
// OrchestrateRequestV1 (the only production decoder is
// OrchestrationToolExecutor.execute -> OrchestrateRequestV1.decode).
//
// They deliberately assert NOTHING about the intended product semantics of
// `enabledSessionCount` beyond the rejection half. (Update 166-B, user ruling
// 2026-09-25T06:51Z: D-CHILDA取数口径已裁「设置里显式选 N」— the user-side
// Settings key now feeds the projection.) The contract pinned here is unchanged:
//   1. out-of-range model-supplied values are rejected at the decode boundary
//      before any Policy or governor can observe them, and
//   2. in-range values that the decoder still carries are inert: the effective
//      global ceiling is derived ONLY from the user-side selection the
//      composition root injected (SettingsCenter childConcurrencySelection ->
//      BridgeStore -> ChildConcurrencyGovernor.Policy.derived(from:)), whose
//      enabledSessionCount comes from the persisted user key
//      (AppSettings.agent.childConcurrencyEnabledSessionCount, default 1) and
//      never from the request.

@Suite("External enabled_session_count cannot reach the global child ceiling")
struct EnabledSessionCountCeilingRejectionTests {

    /// Nested `child_concurrency` object with a model-supplied count.
    private static func nestedInput(_ count: Any) -> [String: Any] {
        [
            "input_version": 1,
            "tasks": [[String: Any]](),
            "child_concurrency": [
                "selected": 8,
                "recommended": 8,
                "effective": 8,
                "enabled_session_count": count,
            ],
        ]
    }

    /// Flat top-level key form accepted by `flatChildConcurrencySelection`
    /// (OrchestrateRequestV1.swift:163-177).
    private static func flatInput(_ keysAndValues: [(String, Any)]) -> [String: Any] {
        var input: [String: Any] = ["input_version": 1, "tasks": [[String: Any]]()]
        for (key, value) in keysAndValues { input[key] = value }
        return input
    }

    @Test("out-of-range model-supplied enabled_session_count is rejected at decode, never reaches the policy")
    func hostileCountsRejectedAtDecodeBoundary() {
        // -1 fails `enabledSessionCount >= 0` and Int.max / Int.max/20 exceed
        // the overflow guard `Int.max / hardMaximum`
        // (ChildConcurrencySelection.swift:42-45); the decoder maps every
        // validation failure to invalidParameter("child_concurrency")
        // (OrchestrateRequestV1.swift:151-160), so no OrchestrateRequestV1 —
        // and therefore no selection — is ever materialised for the policy.
        let hostile: [Any] = [-1, Int.min, Int.max, Int.max / 20, -1_000_000]
        for count in hostile {
            #expect(throws: ToolExecutorError.invalidParameter("child_concurrency")) {
                try OrchestrateRequestV1.decode(
                    input: Self.nestedInput(count),
                    maxTasks: OrchestrationToolExecutor.maxTasks
                )
            }
            #expect(throws: ToolExecutorError.invalidParameter("child_concurrency")) {
                try OrchestrateRequestV1.decode(
                    input: Self.flatInput([
                        ("selected_child_concurrency", 8),
                        ("recommended_child_concurrency", 8),
                        ("effective_child_concurrency", 8),
                        ("enabled_session_count", count),
                    ]),
                    maxTasks: OrchestrationToolExecutor.maxTasks
                )
            }
        }
    }

    @Test("a flat enabled_session_count key without a complete selection is a whole-request rejection")
    func loneExternalKeyFailsToolCall() {
        // Injecting ONLY `enabled_session_count` (the speculative aggregate
        // child key) does not silently ride along at its 1x default: the
        // decoder demands the full user-selected trio and otherwise rejects
        // the entire tool call (OrchestrateRequestV1.swift:145-148).
        #expect(throws: ToolExecutorError.invalidParameter("child_concurrency")) {
            try OrchestrateRequestV1.decode(
                input: Self.flatInput([("enabled_session_count", 1000)]),
                maxTasks: OrchestrationToolExecutor.maxTasks
            )
        }
    }

    @Test("in-range inflated enabled_session_count claims decode but cannot change the effective global ceiling")
    func acceptedCountsStayInertForTheCeiling() throws {
        // 166-B (user ruling 2026-09-25T06:51Z「B：设置里显式选 N」): the
        // app-side projection now passes the PERSISTED USER KEY
        // (AppSettings.agent.childConcurrencyEnabledSessionCount, default 1)
        // into ChildConcurrencySelection (SettingsCenter.childConcurrencySelection).
        // The ceiling is therefore N-times the per-session user choice with N
        // chosen ONLY by the user; model-supplied enabled_session_count claims
        // remain inert. The persisted-default half of this contract (key
        // absent/1 ⇒ 1x) keeps the pre-166-B behaviour byte-identical.
        let userChosenSessionCount = 3
        var agentSettings = AgentSettings()
        agentSettings.childConcurrencyEnabledSessionCount = userChosenSessionCount
        let userSelection = try ChildConcurrencySelection(
            userSelected: 8,
            recommended: 8,
            effective: 8,
            enabledSessionCount: agentSettings.childConcurrencyEnabledSessionCount
        )
        #expect(userSelection.enabledSessionCount == userChosenSessionCount)
        let baselineCeiling = ChildConcurrencyGovernor
            .Policy.derived(from: userSelection)
            .globalHardCeiling
        #expect(baselineCeiling == userChosenSessionCount * 8)

        // 0 / 40 / 1000 / the maximal accepted boundary all pass selection
        // validation (ChildConcurrencySelection.swift:42-45) and decode
        // successfully — yet NOTHING recomputes the ceiling from them: the
        // only production Policy.derived call site
        // (BridgeStore.swift:1622) consumes the injected user-side selection,
        // never the request's.
        let accepted: [Any] = [0, 40, 1000, Int.max / ChildConcurrencySelection.hardMaximum]
        for count in accepted {
            let request = try OrchestrateRequestV1.decode(
                input: Self.nestedInput(count),
                maxTasks: OrchestrationToolExecutor.maxTasks
            )
            #expect(request.childConcurrencySelection.userSelected == 8)
            let ceilingAfterExternalClaim = ChildConcurrencyGovernor
                .Policy.derived(from: userSelection)
                .globalHardCeiling
            #expect(
                ceilingAfterExternalClaim == baselineCeiling,
                "model-supplied enabled_session_count=\(count) must not move the user-derived ceiling"
            )
        }
    }

    @Test("orchestrate tool execution carrying inflated external claims leaves the orchestrator's user-derived limits untouched")
    func executorPathNeverAppliesExternalCeilingClaim() async throws {
        let userSelection = try ChildConcurrencySelection(
            userSelected: 8,
            recommended: 8,
            effective: 8
        )
        let orchestrator = AgentOrchestrator(childConcurrencySelection: userSelection)
        let executor = OrchestrationToolExecutor(orchestrator: orchestrator)

        // Hostile-but-decodable flat input: the model claims 40-wide per
        // session AND 1000 enabled sessions. OrchestrationToolExecutor.execute
        // reads `request.tasks` only; the decoded selection is carried on the
        // request value and discarded (OrchestrationToolExecutor.swift:111-122).
        _ = try await executor.execute(
            name: "orchestrate",
            input: Self.flatInput([
                ("selected_child_concurrency", 40),
                ("recommended_child_concurrency", 40),
                ("effective_child_concurrency", 40),
                ("enabled_session_count", 1000),
            ])
        )

        #expect(orchestrator.childConcurrencySelection == userSelection)
        #expect(orchestrator.defaultMaxConcurrent == 8)
        #expect(
            ChildConcurrencyGovernor
                .Policy.derived(from: orchestrator.childConcurrencySelection)
                .globalHardCeiling == 8
        )
    }
}
