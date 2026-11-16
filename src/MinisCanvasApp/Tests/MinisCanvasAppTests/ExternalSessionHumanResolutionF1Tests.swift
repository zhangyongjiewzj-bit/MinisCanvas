import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("EXTI F1 explicit local disposition and independent compensation preserve UNKNOWN")
@MainActor
struct ExternalSessionHumanResolutionF1Tests {
    @Test func localDispositionHasNoProviderEffectRetainsUnknownAndRequiresFreshHandshake() async throws {
        for operation in [ExternalSessionControlOperationV1.resume, .fork] {
            let fixture = try await F1OwnedFixture.make(originalOperation: operation)
            let adapter = try fixture.adapter()
            let original = try #require(adapter.runtimeSnapshot.unconfirmedControl)
            let preview = try await fixture.preview()
            let countBefore = try fixture.effects().count
            let decision = try await fixture.composition.submitHumanResolution(sourceID: fixture.sourceID,
                preview: preview, decision: .recordExternalHandlingAndAllowNewControls,
                note: "已在外部检查并人工处理", sourceReference: "owned://manual-observation",
                controlGrant: fixture.controlGrant)
            #expect(decision.original == preview.original)
            #expect(decision.original.requestIdentity == original.requestIdentity)
            #expect(decision.actor == .localUser)
            #expect(decision.decisionSource == .settingsControlConfirmation)
            #expect(decision.outcome == .localDispositionRecorded)
            #expect(decision.independentIdentity == nil)
            #expect(decision.independentPlan == nil)
            #expect(try fixture.effects().count == countBefore)
            #expect(adapter.runtimeSnapshot.state == .disconnected)
            #expect(adapter.runtimeSnapshot.ownerID == nil)
            #expect(adapter.runtimeSnapshot.unconfirmedControl == nil)
            #expect(adapter.runtimeSnapshot.independentCompensationReceipts == nil)
            #expect(adapter.runtimeSnapshot.humanResolutionHistory == [decision])
            await F1OwnedFixture.refuses {
                _ = try await adapter.control(request: fixture.originalRequest, controlGrant: fixture.controlGrant)
            }
            try await fixture.composition.activateSyntheticCodexControl(sourceID: fixture.sourceID,
                readGrant: fixture.readGrant, controlGrant: fixture.controlGrant)
            let fresh = try fixture.adapter()
            #expect(fresh.runtimeSnapshot.ownerID != preview.currentOwnerID)
            #expect(fresh.runtimeSnapshot.generation > preview.currentGeneration)
            #expect(fresh.runtimeSnapshot.humanResolutionHistory == [decision])
            #expect(try fixture.effects().count == 1)
            await F1OwnedFixture.refuses {
                _ = try await fresh.control(request: fixture.originalRequest, controlGrant: fixture.controlGrant)
            }
            let status = try await fresh.status(target: .init(sourceID: fixture.sourceID,
                threadID: fixture.threadID), readGrant: fixture.readGrant)
            let newRequest = ExternalSessionControlRequestV1(sourceID: fixture.sourceID,
                threadID: fixture.threadID, operation: operation, expectedCursor: status.observedCursor,
                idempotencyKey: "f1-new-after-local-" + UUID().uuidString,
                parentConversationID: fixture.controlGrant.parentConversationID,
                parentTurnID: fixture.controlGrant.parentTurnID)
            let newReceipt = try await fresh.control(request: newRequest, controlGrant: fixture.controlGrant)
            #expect(newReceipt.operation == operation)
            #expect(newReceipt.outcome == (operation == .fork ? .completed : .accepted))
            #expect(try fixture.effects().count == 2)
            #expect(fresh.runtimeSnapshot.humanResolutionHistory == [decision])
            let cold = try await fixture.coldReopen()
            #expect(try cold.adapter().runtimeSnapshot.humanResolutionHistory == [decision])
            #expect(try cold.effects().count == 2)
            await cold.stop()
        }
    }

    @Test func compensationPersistsFullNewIntentBeforeIOConsumesOnceAndKeepsOldUnknown() async throws {
        for operation in [ExternalSessionControlOperationV1.resume, .fork] {
            let fixture = try await F1OwnedFixture.make(originalOperation: operation)
            let preview = try await fixture.preview()
            let proposal = fixture.proposal(operation: operation)
            let decision = try await fixture.confirmCompensation(preview: preview, proposal: proposal)
            let independent = try #require(decision.independentIdentity)
            #expect(independent.idempotencyKey != preview.original.requestIdentity?.idempotencyKey)
            #expect(independent.localOperationID != preview.original.requestIdentity?.localOperationID)
            #expect(decision.independentPlan == proposal.plan)
            #expect(independent.expectedCursor == preview.inspectedCursor)
            #expect(independent.expectedSequence == nil)
            #expect(independent.parentConversationID == fixture.controlGrant.parentConversationID)
            #expect(independent.parentTurnID == fixture.controlGrant.parentTurnID)
            #expect(independent.parentConversationID != nil)
            #expect(independent.parentTurnID != nil)
            #expect(decision.original == preview.original)
            #expect(try fixture.effects().count == 1)
            let adapter = try fixture.adapter()
            #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(adapter.runtimeSnapshot.unconfirmedControl == preview.original)
            #expect(adapter.runtimeSnapshot.pendingIndependentCompensationDecisionID == decision.decisionID)
            await F1OwnedFixture.refuses {
                _ = try await adapter.control(request: fixture.originalRequest, controlGrant: fixture.controlGrant)
            }
            let result = try await fixture.perform(decision, proposal: proposal)
            #expect(result.decisionID == decision.decisionID)
            #expect(result.originalUnknownCaseID == decision.caseID)
            #expect(result.independentIdentity == independent)
            #expect(result.controlAuthorizationID == fixture.controlGrant.authorizationID)
            #expect(result.controlRevocationEpoch == fixture.controlGrant.revocationEpoch)
            #expect(result.connectionOwnerID == preview.currentOwnerID)
            #expect(result.connectionGeneration == preview.currentGeneration)
            #expect(result.providerReceipt.sourceID == fixture.sourceID)
            #expect(result.providerReceipt.threadID == fixture.threadID)
            #expect(result.providerReceipt.turnID == nil)
            #expect(result.providerReceipt.operation == operation)
            #expect(result.providerReceipt.outcome == (operation == .fork ? .completed : .accepted))
            #expect(result.auditPersistence == .recorded)
            #expect(try fixture.effects().count == 2)
            let atIO = try fixture.beforeEffect(number: 2)
            let persisted = try #require(atIO["pendingIndependentCompensation"] as? [String: Any])
            #expect(persisted["decisionID"] as? String == decision.decisionID)
            let atIdentity = try #require(persisted["identity"] as? [String: Any])
            #expect(atIdentity["idempotencyKey"] as? String == independent.idempotencyKey)
            #expect(atIdentity["localOperationID"] as? String == independent.localOperationID)
            let control = try #require(atIO["unconfirmedControl"] as? [String: Any])
            let controlIdentity = try #require(control["requestIdentity"] as? [String: Any])
            #expect(controlIdentity["idempotencyKey"] as? String == independent.idempotencyKey)
            #expect(control["connectionOwnerID"] as? String == preview.currentOwnerID)
            #expect((control["connectionGeneration"] as? NSNumber)?.uint64Value == preview.currentGeneration)
            #expect(adapter.runtimeSnapshot.humanResolutionHistory == [decision])
            #expect(adapter.runtimeSnapshot.independentCompensationReceipts == [result])
            #expect(adapter.runtimeSnapshot.unconfirmedControl == nil)
            await F1OwnedFixture.refuses { _ = try await fixture.perform(decision, proposal: proposal) }
            #expect(try fixture.effects().count == 2)
            let cold = try await fixture.coldReopen()
            #expect(try cold.adapter().runtimeSnapshot.humanResolutionHistory == [decision])
            #expect(try cold.adapter().runtimeSnapshot.independentCompensationReceipts == [result])
            #expect(try cold.effects().count == 2)
            await cold.stop()
        }
    }

    @Test func foreignIdentityStaleConfirmationRevocationAndChangedIntentRefuseWithoutEffects() async throws {
        let fixture = try await F1OwnedFixture.make()
        let preview = try await fixture.preview()
        let baseline = try Data(contentsOf: fixture.runtimeURL)
        for proposal in [
            ExternalSessionIndependentCompensationProposal(sourceID: .init(rawValue: "foreign-source"),
                profileID: fixture.profileID, threadID: fixture.threadID, turnID: nil, operation: .resume),
            ExternalSessionIndependentCompensationProposal(sourceID: fixture.sourceID,
                profileID: .init(rawValue: "foreign-profile"), threadID: fixture.threadID, turnID: nil, operation: .resume),
            ExternalSessionIndependentCompensationProposal(sourceID: fixture.sourceID,
                profileID: fixture.profileID, threadID: .init(rawValue: "foreign-thread"), turnID: nil, operation: .resume),
            ExternalSessionIndependentCompensationProposal(sourceID: fixture.sourceID,
                profileID: fixture.profileID, threadID: fixture.threadID, turnID: .init(rawValue: "foreign-turn"), operation: .fork)
        ] {
            await F1OwnedFixture.refuses { _ = try await fixture.confirmCompensation(preview: preview, proposal: proposal) }
            #expect(try Data(contentsOf: fixture.runtimeURL) == baseline)
            #expect(try fixture.effects().count == 1)
        }
        let expiredGrant = try await fixture.composition.issueControlGrant(
            authorizationID: .init(rawValue: "f1-expired"), sourceID: fixture.sourceID,
            profileID: fixture.profileID, target: .thread(fixture.threadID), operations: [.resume],
            issuedAt: Date().addingTimeInterval(-120), lifetime: 60)
        await F1OwnedFixture.refuses {
            _ = try await fixture.composition.previewHumanResolution(sourceID: fixture.sourceID,
                readGrant: fixture.readGrant, controlGrant: expiredGrant)
        }
        #expect(try Data(contentsOf: fixture.runtimeURL) == baseline)
        #expect(try fixture.effects().count == 1)
        let newerPreview = try await fixture.preview()
        await F1OwnedFixture.refuses {
            _ = try await fixture.confirmCompensation(preview: preview, proposal: fixture.proposal())
        }
        let decision = try await fixture.confirmCompensation(preview: newerPreview, proposal: fixture.proposal())
        let persistedIntent = try Data(contentsOf: fixture.runtimeURL)
        await F1OwnedFixture.refuses { _ = try await fixture.perform(decision, proposal: fixture.proposal(operation: .fork)) }
        await F1OwnedFixture.refuses { _ = try await fixture.perform(decision, proposal: fixture.proposal(input: "changed-input")) }
        #expect(try Data(contentsOf: fixture.runtimeURL) == persistedIntent)
        #expect(try fixture.effects().count == 1)
        let adapter = try fixture.adapter()
        _ = await fixture.composition.revoke(sourceID: fixture.sourceID, profileID: fixture.profileID)
        await F1OwnedFixture.refuses {
            _ = try await adapter.performIndependentCompensation(decisionReceiptID: decision.decisionID,
                proposal: fixture.proposal(), readGrant: fixture.readGrant, controlGrant: fixture.controlGrant)
        }
        #expect(try fixture.effects().count == 1)
        let cold = try await fixture.coldReopen(stopOriginal: false)
        #expect(cold.controlGrant.authorizationID != fixture.controlGrant.authorizationID)
        #expect(try cold.adapter().runtimeSnapshot.humanResolutionHistory == [decision])
        await F1OwnedFixture.refuses {
            _ = try await cold.composition.submitHumanResolution(sourceID: cold.sourceID, preview: newerPreview,
                decision: .recordExternalHandlingAndAllowNewControls, note: "old confirmation",
                sourceReference: "owned://old", controlGrant: cold.controlGrant)
        }
        #expect(try cold.effects().count == 1)
        await cold.stop()
    }

    @Test func lateAndForeignActualProviderCallbacksCannotClearUnknownOrReplayAnEffect() async throws {
        for mode in ["held", "foreign"] {
            let fixture = try await F1OwnedFixture.make(mode: mode)
            let preview = try await fixture.preview()
            let proposal = fixture.proposal(operation: .fork)
            let decision = try await fixture.confirmCompensation(preview: preview, proposal: proposal)
            if mode == "held" {
                let adapter = try fixture.adapter()
                let task = Task { try await fixture.perform(decision, proposal: proposal) }
                try await fixture.waitForFile("held")
                #expect(try fixture.effects().count == 2)
                let before = adapter.runtimeSnapshot
                adapter.disconnect()
                #expect(adapter.runtimeSnapshot.generation > before.generation)
                try Data("release".utf8).write(to: fixture.home.appendingPathComponent("release"))
                let receipt = try await task.value
                #expect(receipt.providerReceipt.outcome == .completed)
                #expect(receipt.auditPersistence == .recoveryRequired)
                #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
                #expect(adapter.runtimeSnapshot.unconfirmedControl?.requestIdentity == decision.independentIdentity)
                #expect(adapter.runtimeSnapshot.ownerID == nil)
                #expect(adapter.runtimeSnapshot.independentCompensationReceipts == nil)
            } else {
                await F1OwnedFixture.refuses { _ = try await fixture.perform(decision, proposal: proposal) }
                #expect(try fixture.adapter().runtimeSnapshot.requiresSideEffectReconciliation)
                #expect(try fixture.adapter().runtimeSnapshot.unconfirmedControl?.requestIdentity == decision.independentIdentity)
                #expect(try fixture.adapter().runtimeSnapshot.independentCompensationReceipts == nil)
            }
            #expect(try fixture.adapter().runtimeSnapshot.humanResolutionHistory == [decision])
            await F1OwnedFixture.refuses { _ = try await fixture.perform(decision, proposal: proposal) }
            #expect(try fixture.effects().count == 2)
            let cold = try await fixture.coldReopen()
            #expect(try cold.adapter().runtimeSnapshot.requiresSideEffectReconciliation)
            #expect(try cold.adapter().runtimeSnapshot.humanResolutionHistory == [decision])
            #expect(try cold.effects().count == 2)
            await cold.stop()
        }
    }

    @Test func writeFailureCapacityAndLegacyMissingIdentityNeverForgeOldReceipts() async throws {
        let fixture = try await F1OwnedFixture.make()
        let preview = try await fixture.preview()
        let bytes = try Data(contentsOf: fixture.runtimeURL)
        let savedDirectory = fixture.runtimeDirectory.appendingPathExtension("preserved-before-write-failure")
        try FileManager.default.moveItem(at: fixture.runtimeDirectory, to: savedDirectory)
        try Data("owned non-directory blocker".utf8).write(to: fixture.runtimeDirectory)
        await F1OwnedFixture.refuses {
            _ = try await fixture.composition.submitHumanResolution(sourceID: fixture.sourceID,
                preview: preview, decision: .recordExternalHandlingAndAllowNewControls,
                note: "must persist", sourceReference: "owned://write-failure", controlGrant: fixture.controlGrant)
        }
        #expect(try fixture.adapter().runtimeSnapshot.unconfirmedControl == preview.original)
        #expect(try fixture.adapter().runtimeSnapshot.humanResolutionHistory == nil)
        #expect(try fixture.effects().count == 1)
        #expect(try Data(contentsOf: savedDirectory.appendingPathComponent(fixture.runtimeURL.lastPathComponent)) == bytes)
        let blockerEvidence = fixture.runtimeDirectory.appendingPathExtension("blocker-evidence")
        try FileManager.default.moveItem(at: fixture.runtimeDirectory, to: blockerEvidence)
        try FileManager.default.moveItem(at: savedDirectory, to: fixture.runtimeDirectory)
        await fixture.stop()
        var legacy = try fixture.runtimeJSON()
        var oldControl = try #require(legacy["unconfirmedControl"] as? [String: Any])
        oldControl.removeValue(forKey: "requestIdentity")
        legacy["unconfirmedControl"] = oldControl
        try fixture.writeRuntimeJSON(legacy)
        let old = try await fixture.coldReopen(stopOriginal: false)
        #expect(try old.adapter().runtimeSnapshot.unconfirmedControl?.requestIdentity == nil)
        let legacyPreview = try await old.preview()
        let legacyDecision = try await old.composition.submitHumanResolution(sourceID: old.sourceID,
            preview: legacyPreview, decision: .recordExternalHandlingAndAllowNewControls,
            note: "legacy tuple inspected", sourceReference: "owned://legacy", controlGrant: old.controlGrant)
        #expect(legacyDecision.original.requestIdentity == nil)
        #expect(legacyDecision.independentIdentity == nil)
        #expect(try old.adapter().runtimeSnapshot.independentCompensationReceipts == nil)
        #expect(try old.effects().count == 1)
        await old.stop()

        let boolOnly = try await F1OwnedFixture.make()
        await boolOnly.stop()
        var boolRuntime = try boolOnly.runtimeJSON()
        boolRuntime.removeValue(forKey: "unconfirmedControl")
        boolRuntime["requiresSideEffectReconciliation"] = true
        try boolOnly.writeRuntimeJSON(boolRuntime)
        let noTarget = try await boolOnly.coldReopen(stopOriginal: false)
        #expect(try noTarget.adapter().runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(try noTarget.adapter().runtimeSnapshot.unconfirmedControl == nil)
        await F1OwnedFixture.refuses { _ = try await noTarget.preview() }
        #expect(try noTarget.adapter().runtimeSnapshot.humanResolutionHistory == nil)
        #expect(try noTarget.adapter().runtimeSnapshot.independentCompensationReceipts == nil)
        #expect(try noTarget.effects().count == 1)
        await noTarget.stop()

        let capacity = try await F1OwnedFixture.make()
        await capacity.stop()
        var full = try capacity.runtimeJSON()
        // Valid legacy runtime below the existing 64KiB maximum. Its immutable
        // old identity fits; another full audit transaction must refuse.
        full["lastSequenceByThread"] = [String(repeating: "x", count: 62_000): 1]
        try capacity.writeRuntimeJSON(full)
        #expect(try Data(contentsOf: capacity.runtimeURL).count < 64 * 1024)
        let reopened = try await capacity.coldReopen(stopOriginal: false)
        let fullPreview = try await reopened.preview()
        let fullBytes = try Data(contentsOf: reopened.runtimeURL)
        await F1OwnedFixture.refuses {
            _ = try await reopened.confirmCompensation(preview: fullPreview, proposal: reopened.proposal())
        }
        #expect(try reopened.adapter().runtimeSnapshot.humanResolutionHistory == nil)
        #expect(try reopened.adapter().runtimeSnapshot.unconfirmedControl == fullPreview.original)
        #expect(try Data(contentsOf: reopened.runtimeURL) == fullBytes)
        #expect(try reopened.effects().count == 1)
        await reopened.stop()
    }

    @Test func coldPendingIntentNeverAutoDispatchesAndRequiresNewExplicitCurrentDecision() async throws {
        let fixture = try await F1OwnedFixture.make()
        let preview = try await fixture.preview()
        let proposal = fixture.proposal()
        let decision = try await fixture.confirmCompensation(preview: preview, proposal: proposal)
        #expect(try fixture.effects().count == 1)
        let cold = try await fixture.coldReopen()
        let adapter = try cold.adapter()
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(adapter.runtimeSnapshot.pendingIndependentCompensationDecisionID == decision.decisionID)
        #expect(adapter.runtimeSnapshot.humanResolutionHistory == [decision])
        #expect(adapter.runtimeSnapshot.ownerID != preview.currentOwnerID)
        #expect(try cold.effects().count == 1)
        await F1OwnedFixture.refuses { _ = try await cold.perform(decision, proposal: proposal) }
        await F1OwnedFixture.refuses {
            _ = try await cold.composition.submitHumanResolution(sourceID: cold.sourceID,
                preview: preview, decision: .recordExternalHandlingAndAllowNewControls,
                note: "stale preview", sourceReference: "owned://stale", controlGrant: cold.controlGrant)
        }
        #expect(try cold.effects().count == 1)
        let currentPreview = try await cold.preview()
        let newDecision = try await cold.confirmCompensation(preview: currentPreview, proposal: cold.proposal())
        #expect(newDecision.decisionID != decision.decisionID)
        #expect(newDecision.independentIdentity != decision.independentIdentity)
        #expect(newDecision.admissionGeneration > decision.admissionGeneration)
        let newReceipt = try await cold.perform(newDecision, proposal: cold.proposal())
        #expect(newReceipt.auditPersistence == .recorded)
        #expect(adapter.runtimeSnapshot.humanResolutionHistory == [decision, newDecision])
        #expect(adapter.runtimeSnapshot.independentCompensationReceipts == [newReceipt])
        #expect(try cold.effects().count == 2)
        await cold.stop()
    }
}

@MainActor
private final class F1OwnedFixture {
    let root: URL
    let home: URL
    let runtimeDirectory: URL
    let server: URL
    let sessions: URL
    let threadID = ExternalSessionThreadID(rawValue: "12345678-1234-1234-1234-123456789abc")
    let composition: ExternalSessionAuthorizationComposition
    let sourceID: ExternalSessionSourceID
    let profileID: ExternalSessionProfileID
    let readGrant: ExternalSessionReadGrantV1
    let controlGrant: ExternalSessionControlGrantV1
    let originalRequest: ExternalSessionControlRequestV1
    var runtimeURL: URL { runtimeDirectory.appendingPathComponent(sourceID.rawValue + ".json") }

    private init(root: URL, originalOperation: ExternalSessionControlOperationV1,
                 existingRegistration: F1OwnedFixture? = nil) async throws {
        self.root = root
        home = root.appendingPathComponent("owned-codex-home", isDirectory: true)
        sessions = home.appendingPathComponent("sessions", isDirectory: true)
        runtimeDirectory = root.appendingPathComponent("runtime", isDirectory: true)
        server = root.appendingPathComponent("synthetic-codex-server.py")
        composition = existingRegistration?.composition
            ?? ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
        composition.configureExternalSourceRegistration(hostID: "synthetic-f1-host")
        if let existingRegistration {
            sourceID = existingRegistration.sourceID
            profileID = existingRegistration.profileID
        } else {
            sourceID = try composition.registerSelectedReadRoot(kind: .codex, rootURL: sessions)
            profileID = try #require(composition.supervisedProfileID(for: sourceID))
        }
        try composition.configureSyntheticCodexControl(sourceID: sourceID,
            executableURL: server, homeURL: home, runtimeDirectory: runtimeDirectory)
        readGrant = try await composition.issueReadGrant(authorizationID: .init(rawValue: "f1-read-" + UUID().uuidString),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID), scopes: [.metadata, .status], lifetime: 600)
        if existingRegistration == nil {
            _ = try await composition.activateSelectedReadRoot(sourceID: sourceID, readGrant: readGrant)
        }
        controlGrant = try await composition.issueControlGrant(authorizationID: .init(rawValue: "f1-control-" + UUID().uuidString),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.resume, .fork, .steer], lifetime: 600,
            parentConversationID: "owned-f1-parent-conversation", parentTurnID: "owned-f1-parent-turn")
        try await composition.activateSyntheticCodexControl(sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant)
        let adapter = try #require(composition.adapter(for: sourceID))
        let status = try await adapter.status(target: .init(sourceID: sourceID, threadID: threadID), readGrant: readGrant)
        originalRequest = .init(sourceID: sourceID, threadID: threadID, operation: originalOperation,
            expectedCursor: status.observedCursor, idempotencyKey: "f1-original-once",
            parentConversationID: controlGrant.parentConversationID, parentTurnID: controlGrant.parentTurnID)
    }

    static func make(originalOperation: ExternalSessionControlOperationV1 = .resume,
                     mode: String = "known") async throws -> F1OwnedFixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "EXTIF1-" + mode)
        let root = profile.rootDirectory
        let home = root.appendingPathComponent("owned-codex-home", isDirectory: true)
        let day = home.appendingPathComponent("sessions/2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "12345678-1234-1234-1234-123456789abc"
        try Data("""
        {"timestamp":"2026-10-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","cwd":"/synthetic/project","cli_version":"0.151.0"}}
        {"timestamp":"2026-10-01T00:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}
        """.utf8).write(to: day.appendingPathComponent("rollout-2026-10-01T00-00-00-\(thread).jsonl"))
        try Data(mode.utf8).write(to: home.appendingPathComponent("mode"))
        let server = root.appendingPathComponent("synthetic-codex-server.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys, glob, time
        home = os.environ['CODEX_HOME']
        path = os.path.join(home, 'effects.jsonl')
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            if method == 'initialize':
                print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method in ('thread/resume', 'thread/fork', 'turn/steer'):
                count = sum(1 for _ in open(path)) if os.path.exists(path) else 0
                runtime = glob.glob(os.path.join(os.path.dirname(home), 'runtime', '*.json'))
                if runtime:
                    with open(runtime[0]) as f: state = json.load(f)
                    with open(os.path.join(home,'before-effect-'+str(count+1)+'.json'),'w') as f:
                        json.dump(state,f);f.flush();os.fsync(f.fileno())
                with open(path,'a') as f:
                    f.write(json.dumps(req)+'\n');f.flush();os.fsync(f.fileno())
                if count == 0: sys.exit(0)
                mode = open(os.path.join(home,'mode')).read()
                if mode == 'held':
                    open(os.path.join(home,'held'),'w').write('held')
                    deadline = time.time()+10
                    while not os.path.exists(os.path.join(home,'release')) and time.time()<deadline: time.sleep(.01)
                thread = req['params']['threadId']
                if method == 'thread/fork':
                    result = {'thread':{'id':'foreign-child' if mode=='foreign' else '87654321-1234-1234-1234-123456789abc','forkedFromId':'foreign-parent' if mode=='foreign' else thread}}
                elif method == 'thread/resume':
                    result = {'thread':{'id':'foreign-thread' if mode=='foreign' else thread}}
                else: result = {'turnId':req['params']['expectedTurnId']}
                print(json.dumps({'id':req['id'],'result':result}),flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let fixture = try await F1OwnedFixture(root: root, originalOperation: originalOperation)
        let adapter = try fixture.adapter()
        let events = try await fixture.composition.issueReadGrant(authorizationID: .init(rawValue: "f1-events"),
            sourceID: fixture.sourceID, profileID: fixture.profileID, target: .thread(fixture.threadID), scopes: [.events], lifetime: 600)
        try await fixture.composition.subscribeSyntheticCodexEvents(sourceID: fixture.sourceID,
            threadID: fixture.threadID, readGrant: events)
        await refuses { _ = try await adapter.control(request: fixture.originalRequest, controlGrant: fixture.controlGrant) }
        #expect(adapter.runtimeSnapshot.unconfirmedControl?.requestIdentity?.idempotencyKey == fixture.originalRequest.idempotencyKey)
        #expect(try fixture.effects().count == 1)
        for _ in 0..<300 {
            if !fixture.composition.hasActiveCodexEventListener(for: fixture.sourceID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!fixture.composition.hasActiveCodexEventListener(for: fixture.sourceID))
        try await fixture.composition.activateSyntheticCodexControl(sourceID: fixture.sourceID,
            readGrant: fixture.readGrant, controlGrant: fixture.controlGrant)
        #expect(try fixture.adapter().runtimeSnapshot.requiresSideEffectReconciliation)
        return fixture
    }

    func adapter() throws -> ExternalSessionAppAdapter { try #require(composition.adapter(for: sourceID)) }
    func preview() async throws -> ExternalSessionHumanResolutionPreview {
        try await composition.previewHumanResolution(sourceID: sourceID, readGrant: readGrant, controlGrant: controlGrant)
    }
    func proposal(operation: ExternalSessionControlOperationV1 = .resume,
                  input: String? = nil) -> ExternalSessionIndependentCompensationProposal {
        .init(sourceID: sourceID, profileID: profileID, threadID: threadID, turnID: nil,
              operation: operation, boundedInput: input)
    }
    func confirmCompensation(preview: ExternalSessionHumanResolutionPreview,
                             proposal: ExternalSessionIndependentCompensationProposal) async throws -> ExternalSessionHumanResolutionReceipt {
        try await composition.submitHumanResolution(sourceID: sourceID, preview: preview,
            decision: .authorizeOneIndependentCompensation, note: "仅单独补偿；原操作未知",
            sourceReference: "owned://explicit-independent-intent", compensationProposal: proposal, controlGrant: controlGrant)
    }
    func perform(_ receipt: ExternalSessionHumanResolutionReceipt,
                 proposal: ExternalSessionIndependentCompensationProposal) async throws -> ExternalSessionIndependentCompensationReceipt {
        try await composition.performIndependentCompensation(sourceID: sourceID,
            decisionReceiptID: receipt.decisionID, proposal: proposal, readGrant: readGrant, controlGrant: controlGrant)
    }
    func effects() throws -> [String] {
        try String(contentsOf: home.appendingPathComponent("effects.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
    func beforeEffect(number: Int) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            home.appendingPathComponent("before-effect-\(number).json"))) as? [String: Any])
    }
    func runtimeJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: runtimeURL)) as? [String: Any])
    }
    func writeRuntimeJSON(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: runtimeURL, options: .atomic)
    }
    func stop() async { _ = await composition.revoke(sourceID: sourceID, profileID: profileID) }
    func coldReopen(stopOriginal: Bool = true) async throws -> F1OwnedFixture {
        if stopOriginal { await stop() }
        // Keep the original production-selected source/profile registration.
        // Explicit revoke + new grants precede production activation, which
        // constructs a fresh AppAdapter/runtime ledger from the same file.
        // This is storage/adapter cold reopen, not an OS-restart grant claim.
        let reopened = try await F1OwnedFixture(root: root,
            originalOperation: originalRequest.operation, existingRegistration: self)
        #expect(reopened.sourceID == sourceID)
        #expect(reopened.profileID == profileID)
        #expect(reopened.runtimeURL == runtimeURL)
        #expect(reopened.controlGrant.authorizationID != controlGrant.authorizationID)
        #expect(reopened.controlGrant.revocationEpoch > controlGrant.revocationEpoch)
        return reopened
    }
    func waitForFile(_ name: String) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("owned provider never reached held callback")
        throw ExternalSessionHumanResolutionError.confirmationStale
    }
    static func refuses(_ operation: @MainActor () async throws -> Void) async {
        do { try await operation(); Issue.record("expected typed production refusal; operation unexpectedly succeeded") }
        catch { #expect(error is ExternalSessionAppAdapterError || error is ExternalSessionHumanResolutionError
            || error is ExternalSessionAppServerTransportError || error is ExternalSessionCodexJSONRPCError) }
    }
}
