import Foundation
import Testing
@testable import MinisCore

/// P3-A4-CONTEXT-ORCHESTRATOR-R1: pure context manifest contract.
///
/// The public seam is ContextOrchestrator.makeManifest(_:budget:). It must not
/// invoke providers, mutate application state, or perform network I/O.
struct ContextOrchestratorContractTests {
    private func snapshot(
        sessionID: String = "session-a",
        providerID: String = "provider-a",
        modelID: String = "model-a",
        skills: [String] = ["browser", "file_read"]
    ) -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: "fingerprint-a",
            skillIdentifiers: skills,
            conversationID: "conversation-a"
        )
    }

    @Test func acceptsAllEntriesWithinBudgetAndRecordsBudgetReceipt() {
        let orchestrator = ContextOrchestrator()
        let result = orchestrator.makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [
                    .init(identifier: "system", content: "rules", tokenCost: 2),
                    .init(identifier: "memory", content: "summary", tokenCost: 3)
                ]
            ),
            budget: 5
        )

        #expect(result.manifest?.snapshotID == snapshot().snapshotID)
        #expect(result.manifest?.entries.map(\.identifier) == ["system", "memory"])
        #expect(result.receipt.requestedBudget == 5)
        #expect(result.receipt.usedBudget == 5)
        #expect(result.receipt.droppedEntryIDs == [])
        #expect(result.receipt.cacheDisposition == .miss)
    }

    @Test func cropsTrailingEntriesAtBudgetAndRecordsDroppedIDs() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [
                    .init(identifier: "system", content: "rules", tokenCost: 2),
                    .init(identifier: "memory", content: "summary", tokenCost: 3),
                    .init(identifier: "history", content: "old turn", tokenCost: 2)
                ]
            ),
            budget: 5
        )

        #expect(result.manifest?.entries.map(\.identifier) == ["system", "memory"])
        #expect(result.receipt.usedBudget == 5)
        #expect(result.receipt.droppedEntryIDs == ["history"])
        #expect(result.receipt.wasCropped)
    }

    @Test func requiredItemIsNeverCroppedWhenOptionalEntryConsumesBudget() {
        let input = ContextOrchestrator.Input(
            snapshot: snapshot(),
            contextItems: [
                .init(
                    identifier: "optional-history",
                    content: "old turn",
                    tokenCost: 1,
                    level: .l3,
                    scope: "conversation",
                    provenance: "test",
                    required: false
                ),
                .init(
                    identifier: "required-system",
                    content: "security rules",
                    tokenCost: 2,
                    level: .l0,
                    scope: "conversation",
                    provenance: "test",
                    required: true
                )
            ]
        )
        let orchestrator = ContextOrchestrator()
        let result = orchestrator.makeManifest(input, budget: 2)
        let cached = orchestrator.makeManifest(input, budget: 2)

        #expect(result.manifest?.entries.map(\.identifier) == ["required-system"])
        #expect(result.receipt.usedBudget == 2)
        #expect(result.receipt.droppedEntryIDs == ["optional-history"])
        #expect(cached.receipt.cacheDisposition == .hit)
        #expect(cached.receipt.droppedEntryIDs == ["optional-history"])
    }

    @Test func requiredItemMetadataSurvivesManifestConstruction() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                contextItems: [
                    .init(
                        identifier: "required-system",
                        content: "security rules",
                        tokenCost: 2,
                        level: .l0,
                        scope: "conversation",
                        provenance: "test",
                        required: true
                    )
                ]
            ),
            budget: 2
        )

        #expect(result.manifest?.entries.first?.required == true)
    }

    @Test func returnsCachedManifestForSameNormalizedInputAndBudget() {
        let orchestrator = ContextOrchestrator()
        let input = ContextOrchestrator.Input(
            snapshot: snapshot(),
            entries: [
                .init(identifier: "system", content: "rules", tokenCost: 2),
                .init(identifier: "memory", content: "summary", tokenCost: 3)
            ]
        )

        let first = orchestrator.makeManifest(input, budget: 5)
        let second = orchestrator.makeManifest(input, budget: 5)

        #expect(first.receipt.cacheDisposition == .miss)
        #expect(second.manifest == first.manifest)
        #expect(second.receipt.cacheDisposition == .hit)
        #expect(second.receipt.usedBudget == first.receipt.usedBudget)
    }

    @Test func rejectsNegativeBudgetWithoutCachingOrManifest() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [.init(identifier: "system", content: "rules", tokenCost: 2)]
            ),
            budget: -1
        )

        #expect(result.manifest == nil)
        #expect(result.receipt.rejection == .negativeBudget)
        #expect(result.receipt.cacheDisposition == .notApplicable)
    }

    @Test func rejectsOverflowingRequiredBudgetWithoutTrapping() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                contextItems: [
                    .init(identifier: "required-a", content: "a", tokenCost: Int.max, required: true),
                    .init(identifier: "required-b", content: "b", tokenCost: 1, required: true)
                ]
            ),
            budget: Int.max
        )

        #expect(result.manifest == nil)
        #expect(result.receipt.rejection == .budgetOverflow)
    }

    @Test func dropsOptionalOverflowWithoutTrappingOrInflatingReceipt() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [
                    .init(identifier: "optional-a", content: "a", tokenCost: Int.max),
                    .init(identifier: "optional-b", content: "b", tokenCost: Int.max)
                ]
            ),
            budget: Int.max
        )

        #expect(result.manifest?.entries.map(\.identifier) == ["optional-a"])
        #expect(result.receipt.usedBudget == Int.max)
        #expect(result.receipt.droppedEntryIDs == ["optional-b"])
        #expect(result.receipt.rejection == nil)
    }

    @Test func rejectsOverflowingConsumerManifestWithoutTrapping() {
        let result = ContextOrchestrator.Result(
            manifest: .init(
                snapshotID: snapshot().snapshotID,
                entries: [
                    .init(identifier: "manifest-a", content: "a", tokenCost: Int.max),
                    .init(identifier: "manifest-b", content: "b", tokenCost: 1)
                ]
            ),
            receipt: .init(
                requestedBudget: Int.max,
                usedBudget: Int.max,
                droppedEntryIDs: [],
                cacheDisposition: .miss,
                rejection: nil
            )
        )

        #expect(
            ContextOrchestrator.ConsumerSeam.validate(result, for: snapshot())
                == .rejected(.budgetOverflow)
        )
    }

    @Test func rejectsUnboundedAndUnsafeOrchestrationIdentities() {
        let tooMany = (0...1_024).map {
            ContextOrchestrator.Entry(identifier: "entry-\($0)", content: "value", tokenCost: 1)
        }
        let countResult = ContextOrchestrator().makeManifest(
            .init(snapshot: snapshot(), entries: tooMany),
            budget: 1_025
        )
        #expect(countResult.receipt.rejection == .invalidContextItem)

        let bidiResult = ContextOrchestrator().makeManifest(
            .init(
                snapshot: snapshot(),
                contextItems: [
                    .init(
                        identifier: "visible\u{202E}identifier",
                        content: "value",
                        tokenCost: 1,
                        scope: "conversation",
                        provenance: "test"
                    )
                ]
            ),
            budget: 1
        )
        #expect(bidiResult.receipt.rejection == .invalidContextItem)

        let unsafeReceipt = ContextOrchestrator.Receipt(
            requestedBudget: 0,
            usedBudget: 0,
            droppedEntryIDs: ["visible\u{202E}dropped"],
            cacheDisposition: .miss,
            rejection: nil
        )
        #expect(
            ContextOrchestrator.ReceiptAuditSeam.normalize(unsafeReceipt)
                == .rejected(.invalidDroppedEntryIdentifier)
        )
    }

    @Test func consumerSeamAcceptsValidManifestAndReceiptDeterministically() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [
                    .init(identifier: "system", content: "rules", tokenCost: 2),
                    .init(identifier: "memory", content: "summary", tokenCost: 3),
                    .init(identifier: "history", content: "old turn", tokenCost: 2)
                ]
            ),
            budget: 5
        )

        let first = ContextOrchestrator.ConsumerSeam.validate(result, for: snapshot())
        let second = ContextOrchestrator.ConsumerSeam.validate(result, for: snapshot())

        #expect(first == .accepted(manifest: result.manifest!, receipt: result.receipt))
        #expect(second == first)
    }

    @Test func consumerSeamRejectsMismatchedSnapshotAndInconsistentReceipt() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [.init(identifier: "system", content: "rules", tokenCost: 2)]
            ),
            budget: 2
        )
        let otherSnapshot = snapshot(sessionID: "session-b")
        let mismatched = ContextOrchestrator.ConsumerSeam.validate(result, for: otherSnapshot)
        let inconsistent = ContextOrchestrator.Result(
            manifest: result.manifest,
            receipt: .init(
                requestedBudget: 2,
                usedBudget: 1,
                droppedEntryIDs: [],
                cacheDisposition: .miss,
                rejection: nil
            )
        )

        #expect(mismatched == .rejected(.snapshotMismatch))
        #expect(ContextOrchestrator.ConsumerSeam.validate(inconsistent, for: snapshot()) == .rejected(.usedBudgetMismatch))
    }

    @Test func consumerSeamRejectsRejectedOrMalformedResultWithoutSideEffects() {
        let rejected = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(snapshot: snapshot(), entries: []),
            budget: -1
        )
        let malformed = ContextOrchestrator.Result(
            manifest: .init(snapshotID: snapshot().snapshotID, entries: []),
            receipt: .init(
                requestedBudget: 0,
                usedBudget: 0,
                droppedEntryIDs: [],
                cacheDisposition: .notApplicable,
                rejection: nil
            )
        )

        #expect(ContextOrchestrator.ConsumerSeam.validate(rejected, for: snapshot()) == .rejected(.orchestratorRejected(.negativeBudget)))
        #expect(ContextOrchestrator.ConsumerSeam.validate(malformed, for: snapshot()) == .rejected(.invalidCacheDisposition))
    }

    @Test func receiptAuditSeamNormalizesAcceptedReceiptDeterministically() {
        let receipt = ContextOrchestrator.Receipt(
            requestedBudget: 5,
            usedBudget: 3,
            droppedEntryIDs: ["history", "memory"],
            cacheDisposition: .miss,
            rejection: nil
        )

        let first = ContextOrchestrator.ReceiptAuditSeam.normalize(receipt)
        let second = ContextOrchestrator.ReceiptAuditSeam.normalize(receipt)

        #expect(first == .accepted(.init(
            requestedBudget: 5,
            usedBudget: 3,
            droppedEntryIDs: ["history", "memory"],
            cacheDisposition: .miss
        )))
        #expect(second == first)
    }

    @Test func receiptAuditSeamFailsClosedForRejectedAndMalformedReceipts() {
        let rejected = ContextOrchestrator.Receipt(
            requestedBudget: -1,
            usedBudget: 0,
            droppedEntryIDs: [],
            cacheDisposition: .notApplicable,
            rejection: .negativeBudget
        )
        let negativeUsedBudget = ContextOrchestrator.Receipt(
            requestedBudget: 1,
            usedBudget: -1,
            droppedEntryIDs: [],
            cacheDisposition: .miss,
            rejection: nil
        )
        let exceededBudget = ContextOrchestrator.Receipt(
            requestedBudget: 1,
            usedBudget: 2,
            droppedEntryIDs: [],
            cacheDisposition: .hit,
            rejection: nil
        )
        let notApplicable = ContextOrchestrator.Receipt(
            requestedBudget: 0,
            usedBudget: 0,
            droppedEntryIDs: [],
            cacheDisposition: .notApplicable,
            rejection: nil
        )

        #expect(ContextOrchestrator.ReceiptAuditSeam.normalize(rejected) == .rejected(.orchestratorRejected(.negativeBudget)))
        #expect(ContextOrchestrator.ReceiptAuditSeam.normalize(negativeUsedBudget) == .rejected(.negativeUsedBudget))
        #expect(ContextOrchestrator.ReceiptAuditSeam.normalize(exceededBudget) == .rejected(.budgetExceeded))
        #expect(ContextOrchestrator.ReceiptAuditSeam.normalize(notApplicable) == .rejected(.invalidCacheDisposition))
    }

    @Test func rejectsDuplicateContextIdentifiersBeforeReceiptCanLoseDroppedFacts() {
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot(),
                entries: [
                    .init(identifier: "duplicate", content: "first", tokenCost: 1),
                    .init(identifier: "duplicate", content: "second", tokenCost: 1)
                ]
            ),
            budget: 1
        )

        #expect(result.manifest == nil)
        #expect(result.receipt.rejection == .invalidContextItem)
        #expect(result.receipt.droppedEntryIDs.isEmpty)
    }

    @Test func cacheDoesNotAliasSnapshotsThatShareAnIDButHaveDifferentSkillOrder() {
        let orchestrator = ContextOrchestrator()
        let entries = [ContextOrchestrator.Entry(
            identifier: "system",
            content: "rules",
            tokenCost: 1
        )]

        let ordered = orchestrator.makeManifest(
            .init(snapshot: snapshot(skills: ["browser", "file_read"]), entries: entries),
            budget: 1
        )
        let reordered = orchestrator.makeManifest(
            .init(snapshot: snapshot(skills: ["file_read", "browser"]), entries: entries),
            budget: 1
        )

        #expect(ordered.manifest?.snapshotID == reordered.manifest?.snapshotID)
        #expect(ordered.receipt.cacheDisposition == .miss)
        #expect(reordered.receipt.cacheDisposition == .miss)
    }

    @Test func rejectsDriftedSnapshotBeforeManifestConstruction() {
        let drifted = snapshot()
        let forged = ConversationContextSnapshotV1(
            snapshotID: "context:forged",
            sessionID: drifted.sessionID,
            providerID: drifted.providerID,
            modelID: drifted.modelID,
            configurationFingerprint: drifted.configurationFingerprint,
            skillIdentifiers: drifted.skillIdentifiers,
            conversationID: drifted.conversationID
        )
        let result = ContextOrchestrator().makeManifest(
            .init(snapshot: forged, entries: [.init(identifier: "system", content: "rules", tokenCost: 1)]),
            budget: 1
        )

        #expect(result.manifest == nil)
        #expect(result.receipt.rejection == .invalidSnapshot)
    }

    @Test func preparesImmutableAgentLoopInputWithFrozenExecutionIdentity() throws {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 7, messageID: "message-a"),
            operationID: "operation-a",
            attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(
                snapshot: snapshot(),
                entries: [.init(identifier: "system", content: "rules", tokenCost: 1)]
            ),
            budget: 1,
            executionIdentity: identity
        )
        let handoff = try #require(prepared.input)

        #expect(prepared.rejection == nil)
        #expect(handoff.snapshot == snapshot())
        #expect(handoff.manifest.entries.map(\.identifier) == ["system"])
        #expect(handoff.executionIdentity == identity)

        let captured: @Sendable () -> ContextOrchestrator.AgentLoopInput = { handoff }
        #expect(captured() == handoff)
    }

    @Test func rejectsInvalidExecutionIdentityBeforeAgentLoopHandoff() {
        let invalid = AgentExecutionIdentity(
            turn: .init(sessionID: "", turnID: 0, messageID: ""),
            operationID: "",
            attempt: 0
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot(), entries: []),
            budget: 0,
            executionIdentity: invalid
        )

        #expect(prepared.input == nil)
        #expect(prepared.rejection == .invalidExecutionIdentity)
    }

    @Test func rejectsNegativeAttemptConstructedAtThePublicIdentitySeam() {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 13, messageID: "message-a"),
            operationID: "operation-negative-attempt",
            attempt: -1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot(), entries: []),
            budget: 0,
            executionIdentity: identity
        )

        #expect(identity.attempt == -1)
        #expect(identity.isValid == false)
        #expect(prepared.input == nil)
        #expect(prepared.rejection == .invalidExecutionIdentity)
    }

    @Test func rejectsLateWritebackAfterCurrentSnapshotChanges() throws {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 8, messageID: "message-a"),
            operationID: "operation-b",
            attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot(), entries: []),
            budget: 0,
            executionIdentity: identity
        )
        let handoff = try #require(prepared.input)
        let gate = ContextOrchestrator.AgentLoopWritebackGate()
        let writeback = ContextOrchestrator.AgentLoopWriteback(
            snapshot: handoff.snapshot,
            executionIdentity: identity
        )
        let nextSnapshot = snapshot(sessionID: "session-b")

        #expect(gate.begin(handoff))
        #expect(
            gate.validate(writeback, for: handoff, currentSnapshot: nextSnapshot)
                == .rejected(.snapshotMismatch)
        )
        #expect(gate.begin(handoff) == false)
        #expect(
            gate.validate(writeback, for: handoff, currentSnapshot: handoff.snapshot)
                == .rejected(.inactiveExecution)
        )
    }

    @Test func rejectsLateWritebackAfterFinishCancelOrAttemptDrift() throws {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 9, messageID: "message-a"),
            operationID: "operation-c",
            attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot(), entries: []),
            budget: 0,
            executionIdentity: identity
        )
        let handoff = try #require(prepared.input)
        let gate = ContextOrchestrator.AgentLoopWritebackGate()
        let late = ContextOrchestrator.AgentLoopWriteback(
            snapshot: handoff.snapshot,
            executionIdentity: .init(
                turn: identity.turn,
                operationID: identity.operationID,
                attempt: 2
            )
        )

        #expect(gate.begin(handoff))
        #expect(
            gate.validate(late, for: handoff, currentSnapshot: handoff.snapshot)
                == .rejected(.executionIdentityMismatch)
        )
        gate.finish(handoff)
        #expect(gate.begin(handoff) == false)
        #expect(
            gate.validate(
                .init(snapshot: handoff.snapshot, executionIdentity: identity),
                for: handoff,
                currentSnapshot: handoff.snapshot
            ) == .rejected(.inactiveExecution)
        )

        let resumedIdentity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 10, messageID: "message-b"),
            operationID: "operation-d",
            attempt: 1
        )
        let resumed = try #require(
            ContextOrchestrator().prepareAgentLoopInput(
                .init(snapshot: handoff.snapshot, entries: []),
                budget: 0,
                executionIdentity: resumedIdentity
            ).input
        )
        #expect(gate.begin(resumed))
        gate.cancel(resumed)
        #expect(gate.begin(resumed) == false)
        #expect(
            gate.validate(
                .init(snapshot: resumed.snapshot, executionIdentity: resumedIdentity),
                for: resumed,
                currentSnapshot: resumed.snapshot
            ) == .rejected(.inactiveExecution)
        )
    }

    @Test func acceptsOneWritebackOnlyAndRejectsDuplicateCompletion() throws {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 11, messageID: "message-a"),
            operationID: "operation-e",
            attempt: 1
        )
        let handoff = try #require(
            ContextOrchestrator().prepareAgentLoopInput(
                .init(snapshot: snapshot(), entries: []),
                budget: 0,
                executionIdentity: identity
            ).input
        )
        let gate = ContextOrchestrator.AgentLoopWritebackGate()
        let writeback = ContextOrchestrator.AgentLoopWriteback(
            snapshot: handoff.snapshot,
            executionIdentity: identity
        )

        #expect(gate.begin(handoff))
        #expect(
            gate.validate(writeback, for: handoff, currentSnapshot: handoff.snapshot)
                == .accepted
        )
        #expect(
            gate.validate(writeback, for: handoff, currentSnapshot: handoff.snapshot)
                == .rejected(.inactiveExecution)
        )
    }

    @Test func cancelledTurnCannotBeReactivatedAfterOrchestratorRestart() throws {
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "session-a", turnID: 12, messageID: "message-a"),
            operationID: "operation-restart",
            attempt: 1
        )
        let handoff = try #require(
            ContextOrchestrator().prepareAgentLoopInput(
                .init(snapshot: snapshot(), entries: []),
                budget: 0,
                executionIdentity: identity
            ).input
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscore-turn-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistenceURL = directory.appendingPathComponent("turns.json")
        let firstStore = try AgentTurnContextStore(persistenceURL: persistenceURL)
        let firstGate = ContextOrchestrator.AgentLoopWritebackGate(store: firstStore)
        let writeback = ContextOrchestrator.AgentLoopWriteback(
            snapshot: handoff.snapshot,
            executionIdentity: identity
        )

        #expect(firstGate.begin(handoff))
        firstGate.cancel(handoff)

        // A new gate represents a process restart. The cancelled identity must
        // remain tombstoned before any late callback can write it back.
        let restartedStore = try AgentTurnContextStore(persistenceURL: persistenceURL)
        let restartedGate = ContextOrchestrator.AgentLoopWritebackGate(store: restartedStore)
        #expect(restartedGate.begin(handoff) == false)
        #expect(
            restartedGate.validate(
                writeback,
                for: handoff,
                currentSnapshot: handoff.snapshot
            ) == .rejected(.inactiveExecution)
        )
    }

    private func executionScope(
        sessionID: String = "session-a",
        taskID: String = "task-a"
    ) -> AgentExecutionScopeIdentity {
        AgentExecutionScopeIdentity(
            sessionID: sessionID,
            workspaceID: "workspace-a",
            memoryScopeID: "memory-a",
            skillsScopeID: "skills-a",
            permissionsScopeID: "permissions-a",
            taskID: taskID,
            budgetScopeID: "budget-a"
        )
    }

    @Test func scopeIdentityHasOneCanonicalProjectionAndRejectsMissingComponents() {
        let scope = executionScope()
        #expect(scope.isValid)
        #expect(scope.matches(scope))
        #expect(scope.fingerprint == "scope:" + scope.canonicalRepresentation)
        #expect(
            AgentExecutionScopeIdentity(
                sessionID: "",
                workspaceID: "workspace-a",
                memoryScopeID: "memory-a",
                skillsScopeID: "skills-a",
                permissionsScopeID: "permissions-a",
                taskID: "task-a",
                budgetScopeID: "budget-a"
            ).isValid == false
        )
    }

    @Test func manifestProductionConsumerRequiresTheSameCompleteScope() throws {
        let scope = executionScope()
        let manifest = ContextManifest(
            snapshot: snapshot(),
            entries: [.init(identifier: "system", tokenCost: 1)],
            scopeIdentity: scope
        )
        let receipt = ContextManifestReceipt(
            runID: "run-a",
            requestedBudget: 1,
            usedBudget: 1,
            droppedEntryIDs: []
        )
        let store = ContextManifestStore()

        _ = try store.record(manifest: manifest, receipt: receipt, scopeIdentity: scope)
        #expect(try store.manifest(runID: receipt.runID, scopeIdentity: scope) == manifest)

        do {
            try store.validate(manifest: manifest, for: executionScope(taskID: "task-drift"))
            #expect(Bool(false))
        } catch ContextManifestStoreError.scopeMismatch {
            #expect(Bool(true))
        }
    }

    @Test func manifestProductionConsumerRejectsAnUnboundManifest() throws {
        let scope = executionScope()
        let manifest = ContextManifest(snapshot: snapshot(), entries: [])
        do {
            try ContextManifestStore().validate(manifest: manifest, for: scope)
            #expect(Bool(false))
        } catch ContextManifestStoreError.missingScopeIdentity {
            #expect(Bool(true))
        }
    }
}
