import Foundation
import Testing
import AppKit
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

/// Production-consumer fixture for the shared primary row. The native host
/// later exercises geometry/AX at the listed widths; this source test pins
/// the real ChatStore model and policy owners used by both composer views.
@Suite("UF03 Composer primary controls")
@MainActor
struct ComposerPrimaryControlsNativeTests {
    @Test("diagnostic only: original two policy menus at220 and310 execute every forward and restore")
    func diagnosticOriginalPolicyTransactionsAt220And310() async throws {
        var lease: UUID?
        let items = try await ComposerNativeFixtureContract.diagnosticOriginalPolicyTransactionsAt220And310(
            beforeHost: { lease = ComposerNativeHostReadiness.begin("UF03-original-three-policy-menus") },
            onCreated: { window in if let lease { ComposerNativeHostReadiness.bind(lease, to: window) } },
            onSampled: { ComposerNativeHostReadiness.observe($0, phase: "sampled") },
            onClosed: { window in NativeTestHostLifecycle.end(window); lease = nil })
        #expect(lease == nil)
        #expect(items.map(\.expected.id) == ["companionEvidence.policy:p0:w220", "companionEvidence.policy:p0:w310"])
        #expect(items.flatMap(\.transactions).count == 8)
        let kinds = ["mode_forward", "mode_restore", "effort_forward", "effort_restore"]
        for item in items {
            #expect(item.expected.fontSize == 13 && [220, 310].contains(Int(item.expected.width)))
            #expect(item.completed && item.windowClosed && item.fixtureResourcesClosed)
            #expect(item.nativeStatus == "PASS" && item.visualStatus != "RED" && item.visualRecordsConsistent)
            #expect(item.restorationStatus == "PASS")
            #expect(item.transactions.map(\.kind) == kinds)
            let setup = try #require(item.setup)
            var previous = setup
            for transaction in item.transactions {
                #expect(transaction.status == "PASS" && transaction.attempted && transaction.attemptCount == 1,
                        "real policy transaction=\(transaction.id) reason=\(transaction.reason ?? "none")")
                #expect(transaction.witness == "NATIVE_ACTION_AND_STATE_CHANGE_OBSERVED")
                #expect(transaction.budgetSeconds == 0.5 && transaction.maxPresses == 2)
                #expect(transaction.pressCount == 2 && transaction.pressResults == [0, 0])
                #expect(transaction.durationSeconds <= 0.5 && transaction.witnessSamples <= 5)
                let before = try #require(transaction.before), after = try #require(transaction.after)
                #expect(before == previous)
                var expected = before
                switch transaction.kind {
                case "mode_forward": expected.policy.mode = .autoEdit
                case "mode_restore": expected.policy.mode = .manual
                case "effort_forward": expected.policy.effort = .high
                case "effort_restore": expected.policy.effort = .low
                default: Issue.record("unexpected frozen policy transaction")
                }
                #expect(before.policy != expected.policy && after == expected)
                #expect(transaction.targetEvidence.count == 2)
                for target in transaction.targetEvidence {
                    #expect(target.nativeStatus == "PASS" && target.ownedWindowIdentifier == "uf03-owned-" + item.expected.id)
                    #expect(target.matchedCount == 1 && target.nativeMatchedCount == 1)
                    #expect(target.nativeFrame != nil && target.nativeFrame == target.snapshot.frame)
                }
                if let optionProof = transaction.targetEvidence.last?.externalNativeProof {
                    #expect(optionProof["revision"] == "R15_ORIGINAL_EXECUTOR_VALIDATED_TARGET_V1")
                    #expect(optionProof["owner"] == "uf03-owned-" + item.expected.id)
                    #expect(optionProof["request_sha"]?.count == 64)
                    #expect(optionProof["launch_sha"]?.count == 64)
                    #expect(optionProof["target_id"]?.contains(".option.") == true)
                }
                previous = after
            }
            #expect(previous == setup && item.after == setup)
            // Real restore is proven above, before fixture-only selection cleanup.
            for slot in ["model", "mode", "effort"] {
                let control = try #require(item.controls.first { $0.slot == slot })
                #expect(control.nativeStatus == "PASS" && control.matchedCount == 1 && control.nativeMatchedCount == 1)
                #expect(control.nativeFrame != nil && control.nativeFrame == control.snapshot.frame)
                #expect(control.ownedWindowIdentifier == "uf03-owned-" + item.expected.id)
            }
        }
    }

    @Test("visible geometry cannot admit an inactive or foreign native host", arguments: 0..<7)
    func ownedHostFocusRequiresActiveExactOwner(_ index: Int) {
        // The positive control and each independently missing prerequisite use
        // the same production admission as the actual mounted host.
        #expect(UF03OwnedHostFocusAdmission.accepts(applicationActive: index != 1,
            exactKeyWindow: index != 2, windowKey: index != 3, visible: index != 4,
            exactHost: index != 5, exactOwner: index != 6) == (index == 0))
    }

    @Test("tracking target evidence requires an authenticated fresh external action result", arguments: 0..<12)
    func trackingTargetEvidenceCannotUseLocalGeometryAlone(_ index: Int) {
        let owner = "uf03-owned-companionEvidence.policy:p0:w220"
        let target = "composer.policy.instance.test.g1.option.1"
        var proof: [String: String]? = ["revision": "R15_ORIGINAL_EXECUTOR_VALIDATED_TARGET_V1",
            "request_sha": String(repeating: "a", count: 64), "launch_sha": String(repeating: "b", count: 64),
            "actor": "test-actor", "host_pid": "123", "host_start": "1:2", "owner": owner, "target_id": target]
        var current = true, dispatched = true, late = false
        var error: Int32 = 0
        var now = 10.1
        switch index {
        case 1: proof = nil
        case 2: proof?["owner"] = "foreign-owner"
        case 3: proof?["target_id"] = "stale-generation-target"
        case 4: current = false
        case 5: error = -25204
        case 6: dispatched = false
        case 7: late = true
        case 8: now = 10.5
        case 9: proof?["request_sha"] = "not-a-request-digest"
        case 10: now = .nan
        case 11: proof?["revision"] = "unrecognized-proof"
        default: break
        }
        #expect(UF03TrackingMenuNativeProof.accepts(proof, owner: owner, targetID: target,
            current: current, error: error, dispatched: dispatched, late: late,
            now: now, deadline: 10.5) == (index == 0))
    }

    @Test("owned menu local frame request roundtrips through original screen coordinates")
    func trackingLocalGeometryRetainsOriginalAXFrameConstraint() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let local = CGRect(x: 30, y: 420, width: 150, height: 22)
        let wire = try #require(UF03AXScreenCoordinates.appKitFrame(position: local.origin,
            size: local.size, zeroScreenFrame: screen))
        let restored = UF03AXScreenCoordinates.appKitFrame(position: wire.origin,
            size: wire.size, zeroScreenFrame: screen)
        #expect(restored == local)
        #expect(UF03AXScreenCoordinates.appKitFrame(position: local.origin,
            size: .zero, zeroScreenFrame: screen) == nil)
        #expect(UF03AXScreenCoordinates.appKitFrame(position: local.origin,
            size: local.size, zeroScreenFrame: nil) == nil)
    }

    @Test("diagnostic only: original owned220 policy case with readable model control")
    func diagnosticOwnedPolicyCaseAt220() async throws {
        var lease: UUID?
        let item = try await ComposerNativeFixtureContract.diagnosticCompanionPolicyCaseAt220(
            beforeHost: { lease = ComposerNativeHostReadiness.begin("UF03-policy-diagnostic") },
            onCreated: { window in if let lease { ComposerNativeHostReadiness.bind(lease, to: window) } },
            onSampled: { ComposerNativeHostReadiness.observe($0, phase: "sampled") },
            onClosed: { window in NativeTestHostLifecycle.end(window); lease = nil })
        #expect(lease == nil)
        #expect(item.expected.id == "companionEvidence.widths:m0:f12:w220")
        #expect(item.expected.width == 220 && item.expected.fontSize == 12)
        #expect(item.completed && item.windowClosed && item.fixtureResourcesClosed)
        #expect(item.restorationStatus == "PASS")
        let model = try #require(item.controls.first { $0.slot == "model" })
        #expect(model.nativeStatus == "PASS")
        #expect(model.matchedCount == 1 && model.nativeMatchedCount == 1)
        #expect(model.snapshot.frame != nil && model.nativeFrame == model.snapshot.frame)
        for (slot, label) in [("mode", "Composer 任务模式"), ("effort", "Composer 工作量")] {
            let control = try #require(item.controls.first { $0.slot == slot })
            #expect(control.ownedWindowIdentifier == "uf03-owned-" + item.expected.id, "diagnostic target=\(slot)")
            #expect(control.query == label, "diagnostic target=\(slot)")
            #expect(control.actualLabel == label || control.actualTitle == label, "diagnostic target=\(slot)")
            #expect(control.matchedCount == 1 && control.nativeMatchedCount == 1, "diagnostic target=\(slot)")
            #expect(control.snapshot.frame != nil && control.nativeFrame == control.snapshot.frame, "diagnostic target=\(slot)")
            #expect(control.nativeStatus == "PASS", "diagnostic target=\(slot)")
        }
        print("UF03_DIAGNOSTIC_CASE case=\(item.expected.id) targetOnly=true fullCaseNative=\(item.nativeStatus) modelNative=\(model.nativeStatus)")
    }

    @Test("companion local labels preserve exact public attribute precedence", arguments: 0..<12)
    func companionLocalLabelAttributePrecedence(_ index: Int) {
        let query = "Composer 任务模式"
        let cases: [(direct: String?, legacy: Any?, title: String?, kind: String, source: String?, reads: Int)] = [
            (query, "different", nil, "labelOrTitle", "accessibilityLabel", 0),
            (nil, query, nil, "labelOrTitle", "AXDescription", 1),
            ("different", query, nil, "labelOrTitle", nil, 0),
            ("", query, nil, "labelOrTitle", nil, 0),
            (nil, nil, nil, "labelOrTitle", nil, 1),
            (nil, NSNumber(value: 7), nil, "labelOrTitle", nil, 1),
            (nil, "prefix " + query, nil, "labelOrTitle", nil, 1),
            (nil, "different", query, "labelOrTitle", "accessibilityTitle", 1),
            ("different", query, query, "labelOrTitle", "accessibilityTitle", 0),
            (nil, query, nil, "identifier", nil, 0),
            (nil, query, nil, "help", nil, 0),
            (nil, query, query, "title", "accessibilityTitle", 0),
        ]
        let value = cases[index]
        let object = UF03CompanionLabelProxy(direct: value.direct, legacy: value.legacy, title: value.title)
        #expect(UF03CompanionLocalLabelReader.matchSource(object, query: query, kind: value.kind) == value.source)
        #expect(object.descriptionReads == value.reads)
    }

    @Test("companion duplicate exact label nodes remain ineligible for unique native binding")
    func companionLocalLabelDuplicateTargetsRemainIneligible() {
        let query = "Composer 审批范围"
        let objects = [UF03CompanionLabelProxy(direct: query, legacy: nil, title: nil),
                       UF03CompanionLabelProxy(direct: nil, legacy: query, title: nil)]
        let sources = objects.compactMap {
            UF03CompanionLocalLabelReader.matchSource($0, query: query, kind: "labelOrTitle")
        }
        #expect(sources == ["accessibilityLabel", "AXDescription"])
        #expect(!UF03AXScreenCoordinates.nativeTargetIsEligible(
            localMatchCount: sources.count, nativeMatchCount: 1, traversalComplete: true, hasNativeRole: true))
        #expect(!UF03AXScreenCoordinates.nativeTargetIsEligible(
            localMatchCount: 1, nativeMatchCount: 0, traversalComplete: true, hasNativeRole: true))
        let placeholder = UF03CompanionInputRoleProxy(NSAccessibility.Role.staticText.rawValue)
        let input = UF03CompanionInputRoleProxy(NSAccessibility.Role.scrollArea.rawValue)
        let duplicateInput = UF03CompanionInputRoleProxy(NSAccessibility.Role.textArea.rawValue)
        let targets = UF03CompanionLocalLabelReader.inputTargets([placeholder, input])
        #expect(targets.count == 1 && targets.first === input)
        #expect(UF03CompanionLocalLabelReader.inputTargets([placeholder]).isEmpty)
        #expect(UF03CompanionLocalLabelReader.inputTargets([NSObject()]).isEmpty)
        let noAccessibility = NSObject()
        #expect(UF03CompanionLocalLabelReader.role(noAccessibility) == nil)
        #expect(UF03CompanionLocalLabelReader.matchSource(
            noAccessibility, query: query, kind: "labelOrTitle") == nil)
        let duplicated = UF03CompanionLocalLabelReader.inputTargets([placeholder, input, duplicateInput])
        #expect(duplicated.count == 2)
        #expect(!UF03AXScreenCoordinates.nativeTargetIsEligible(
            localMatchCount: duplicated.count, nativeMatchCount: 1, traversalComplete: true, hasNativeRole: true))
    }

    @Test("non-protocol proxy returns its exact CGRect through the verified getter ABI")
    func nonProtocolProxyFramePreservesExactGeometry() {
        let frame = CGRect(x: 17.25, y: -23.5, width: 137.75, height: 41.125)
        let proxy = UF03RectProxy(frame: frame)
        let result = UF03NativeFrameReader.read(proxy)
        #expect(!result.evidence.protocolCast)
        #expect(result.evidence.selectorResponds)
        #expect(result.evidence.path == "typed-selector")
        #expect(result.frame == frame)
        #expect(proxy.calls == 1)
    }

    @Test("absent frame getter remains missing")
    func nonProtocolProxyMissingFrameRemainsNil() {
        let result = UF03NativeFrameReader.read(NSObject())
        #expect(!result.evidence.protocolCast)
        #expect(!result.evidence.selectorResponds)
        #expect(result.frame == nil)
    }

    @Test("object and scalar frame getters are rejected before invocation")
    func nonProtocolProxyWrongReturnTypesAreNeverCalled() {
        let objectProxy = UF03ObjectFrameProxy()
        let scalarProxy = UF03ScalarFrameProxy()
        for proxy: NSObject in [objectProxy, scalarProxy] {
            let result = UF03NativeFrameReader.read(proxy)
            #expect(!result.evidence.protocolCast)
            #expect(result.evidence.selectorResponds)
            #expect(result.evidence.path == "rejected-signature")
            #expect(result.frame == nil)
        }
        #expect(objectProxy.calls == 0)
        #expect(scalarProxy.calls == 0)
    }

    @Test("non-protocol proxy rejects empty negative and nonfinite real frames", arguments: [
        CGRect.zero,
        CGRect(x: 1, y: 2, width: -3, height: 4),
        CGRect(x: 1, y: 2, width: 3, height: -4),
        CGRect(x: CGFloat.nan, y: 2, width: 3, height: 4),
        CGRect(x: 1, y: CGFloat.infinity, width: 3, height: 4),
        CGRect(x: 1, y: 2, width: CGFloat.infinity, height: 4),
        CGRect(x: 1, y: 2, width: 3, height: CGFloat.nan),
    ])
    func nonProtocolProxyInvalidFramesRemainNil(_ frame: CGRect) {
        let proxy = UF03RectProxy(frame: frame)
        let result = UF03NativeFrameReader.read(proxy)
        #expect(result.evidence.path == "rejected-invalid-frame")
        #expect(result.frame == nil)
        #expect(proxy.calls == 1)
    }

    @Test("model and policy changes share ChatStore and freeze into the next submit")
    func primaryControlsUseSharedStoreAndFrozenSnapshot() throws {
        let chat = ChatStore()
        chat.selectModel(.deepSeekReasoner)
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .autoEdit,
            approvalScope: .turn,
            effort: .high,
            bypassModeConfirmed: false
        )

        var captured: ComposerSubmissionSnapshot?
        chat.onSendCommand = { _, snapshot in
            captured = snapshot
            return true
        }
        chat.draftText = "UF03 primary row"
        chat.submitComposer()

        #expect(ModelMenuButton.composerLabel(
            modelID: chat.selectedModelID,
            providerType: chat.selectedProviderType,
            tier: chat.modelSpeedTier
        ) == "deepseek-reasoner")
        let snapshot = try #require(captured)
        #expect(snapshot.mode == .autoEdit)
        #expect(snapshot.approvalScope == .turn)
        #expect(snapshot.effort == .high)
    }

    @Test("policy values remain explicit when the model changes")
    func modelSelectionDoesNotRewritePolicySelection() {
        let chat = ChatStore()
        chat.composerPolicySelection = ComposerPolicySelection(
            mode: .plan,
            approvalScope: .workspace,
            effort: .low,
            bypassModeConfirmed: false
        )
        chat.selectModel(.qwen38MaxPreview)
        #expect(chat.composerPolicySelection.mode == .plan)
        #expect(chat.composerPolicySelection.approvalScope == .workspace)
        #expect(chat.composerPolicySelection.effort == .low)
    }

    @Test("shared generating fixture resolves its real TXT before a single offline submission without a native host")
    func generatingFixtureWaitsForRealAttachmentResolution() async throws {
        let fixture = try makeFixture(.generating)
        defer { fixture.close() }
        let pair = try #require(fixture.pairs.first)
        let prepared = try await fixture.prepare(pair)
        let chat = prepared.chat
        let user = try #require(chat.messages.first { $0.role == .user })
        let attachment = try #require(user.attachments.first)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(attachment.status == .ready)
        #expect(attachment.data == Data("fixture".utf8))
        #expect(chat.lastComposerSubmissionSnapshot?.messageID == user.id.uuidString)
        #expect(chat.lastComposerSubmissionSnapshot?.sessionID == chat.activeSessionID?.uuidString)
        #expect(chat.isActiveSessionStreaming)
        #expect(chat.draftText.isEmpty && chat.pendingAttachments.isEmpty)
    }

    @Test("shared prepared companion fixture waits for its real TXT without sending")
    func preparedCompanionWaitsForRealAttachmentResolution() async throws {
        let spec = try #require(ComposerNativeFixtureContract.companionCases.first { $0.state == "prepared" })
        let fixture = try makeFixture(spec.pair.group)
        defer { fixture.close() }
        let prepared = try await fixture.prepareCompanion(spec)
        let chat = prepared.chat
        let attachment = try #require(chat.pendingAttachments.first)
        #expect(attachment.status == .ready)
        #expect(attachment.data == Data("fixture".utf8))
        #expect(chat.canSubmitComposerAttachments)
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(!chat.isActiveSessionStreaming && chat.lastComposerSubmissionSnapshot == nil)
    }

    @Test("fixture readiness rejects a foreign owner, missing slot and unresolved deadline without sending")
    func attachmentReadinessFailsClosedWithDetails() async throws {
        let fixture = try makeFixture(.widthsAndFonts)
        defer { fixture.close() }
        let prepared = try await fixture.prepare(try #require(fixture.pairs.first))
        let chat = prepared.chat
        let owner = try #require(chat.activeSessionID)
        let pending = ChatAttachment(kind: .file, fileName: "uf03-pending.txt",
                                     fileType: .text, status: .pending)
        chat.addComposerDraftAttachment(pending)
        chat.draftText = "UF03 retained draft"
        let cases: [(UUID, [UUID], String)] = [
            (UUID(), [pending.id], "owner_changed"),
            (owner, [UUID()], "attachment_slots_changed"),
            (owner, [pending.id], "attachment_ready_timeout")
        ]
        for (expectedOwner, ids, reason) in cases {
            do {
                try await fixture.awaitAttachmentsReady(chat, sessionID: expectedOwner,
                                                         attachmentIDs: ids, timeout: .zero)
                Issue.record("readiness unexpectedly accepted \(reason)")
            } catch ComposerNativeFixtureContract.FixtureError.attachmentPreparation(let detail) {
                #expect(detail.contains(reason))
                #expect(detail.contains(pending.id.uuidString))
                #expect(detail.contains(":pending"))
            }
        }
        #expect(chat.draftText == "UF03 retained draft")
        #expect(chat.pendingAttachments.map(\.id) == [pending.id])
        #expect(chat.messages.allSatisfy { $0.role != .user })
        #expect(chat.lastComposerSubmissionSnapshot == nil && !chat.isActiveSessionStreaming)
    }

    @Test("hosted global and companion consumers keep primary row controls reachable")
    func hostedConsumersKeepPrimaryControlsReachableAcrossWidthsAndFonts() async throws {
        let fixture = try makeFixture(.widthsAndFonts)
        defer { fixture.close() }
        for pair in fixture.pairs {
            let prepared = try await fixture.prepare(pair)
            let width = pair.width
            let size = pair.fontSize
            let modelID = pair.modelID
            let globalProbe = hostAndProbe(prepared, consumer: .global)
            #expect(globalProbe.isUsable, "global width=\(width) font=\(size) model=\(modelID)")
            let companionProbe = hostAndProbe(prepared, consumer: .companion)
            #expect(companionProbe.isUsable, "companion width=\(width) font=\(size) model=\(modelID)")
        }
    }

    @Test("hosted consumers cover every existing policy mode, scope and effort")
    func hostedConsumersCoverPolicyMatrix() async throws {
        let fixture = try makeFixture(.policies)
        defer { fixture.close() }
        for pair in fixture.pairs {
            let prepared = try await fixture.prepare(pair)
            let policy = pair.policy
            let globalProbe = hostAndProbe(prepared, consumer: .global)
            let companionProbe = hostAndProbe(prepared, consumer: .companion)
            #expect(globalProbe.isUsable, "global policy=\(policy.mode.rawValue)/\(policy.approvalScope.rawValue)/\(policy.effort.rawValue)")
            #expect(companionProbe.isUsable, "companion policy=\(policy.mode.rawValue)/\(policy.approvalScope.rawValue)/\(policy.effort.rawValue)")
        }
    }

    @Test("hosted generating consumer keeps policy/model row while attachment and skill state are present")
    func hostedGeneratingStateKeepsPrimaryControlsReachable() async throws {
        let fixture = try makeFixture(.generating)
        defer { fixture.close() }
        for pair in fixture.pairs {
            let prepared = try await fixture.prepare(pair)
            let chat = prepared.chat
            #expect(chat.isActiveSessionStreaming)
            defer { chat.stopStreaming() }
            let globalProbe = hostAndProbe(prepared, consumer: .global)
            let companionProbe = hostAndProbe(prepared, consumer: .companion)
            #expect(globalProbe.isUsable)
            #expect(companionProbe.isUsable)
        }
    }

    @Test("shared companion evidence covers every frozen actual-width case and bounded transaction")
    func hostedCompanionAllControlsAtActualWidths() async {
        defer { nativeTestHostBoundary("companion-defer-leave") }
        var hostLease: UUID?
        let result = await ComposerNativeFixtureContract.collectCompanionEvidence(
            beforeHost: { hostLease = ComposerNativeHostReadiness.begin("UF03-companion-evidence") },
            onCreated: { window in
                #expect(hostLease != nil)
                if let hostLease { ComposerNativeHostReadiness.bind(hostLease, to: window) }
            },
            onSampled: { ComposerNativeHostReadiness.observe($0, phase: "sampled") },
            onClosed: { window in NativeTestHostLifecycle.end(window); hostLease = nil }
        )
        nativeTestHostBoundary("companion-collect-return", detail: "expected=\(result.expected.count) observations=\(result.observations.count) transactions=\(result.observations.flatMap(\.transactions).count) lastCase=\(String((result.observations.last?.expected.id ?? "none").prefix(96)))")
        #expect(hostLease == nil)
        #expect(result.expected.count == 57)
        #expect(result.observations.map(\.expected) == result.expected)
        #expect(result.observations.flatMap(\.transactions).count == 54)
        #expect(result.observations.compactMap(\.state2958Diagnostic).count == 57)
        for (ordinal, observation) in result.observations.enumerated() {
            #expect(observation.state2958Diagnostic?.schema == State2958DiagnosticRecord.schema)
            #expect(observation.state2958Diagnostic?.caseID == observation.expected.id)
            #expect(observation.state2958Diagnostic?.zeroBasedOrdinal == ordinal)
            #expect(observation.state2958Diagnostic?.dimensions.map(\.name)
                == State2958DiagnosticRecord.requiredDimensionNames)
            #expect(observation.state2958Diagnostic?.phases.map(\.phase)
                == State2958DiagnosticRecord.requiredPhaseNames)
            #expect(observation.state2958Diagnostic?.exactlyOneRecord == true)
            #expect(observation.state2958Diagnostic?.eligibilityDecisionUnchanged == true)
            #expect(observation.state2958Diagnostic?.extraAXActions == 0)
            if let diagnostic = observation.state2958Diagnostic {
                var previousEnd = -Double.infinity
                for phase in diagnostic.phases.dropLast() {
                    #expect(phase.startUptime >= previousEnd)
                    #expect(phase.endUptime >= phase.startUptime)
                    #expect(phase.durationSeconds >= 0)
                    previousEnd = phase.endUptime
                }
                if let total = diagnostic.phases.last {
                    #expect(total.startUptime <= total.endUptime)
                    #expect(total.durationSeconds >= 0)
                }
                #expect(diagnostic.dimensions.allSatisfy {
                    $0.boolean != nil || $0.observed != nil || $0.error != nil
                })
            }
        }
        #expect(result.completed)
        #expect(result.nativeStatus == "PASS")
        #expect(result.visualStatus != "RED")
        for observation in result.observations {
            #expect(observation.nativeStatus == "PASS", "\(observation.expected.id): \(observation.nativeErrors)")
            #expect(observation.visualStatus != "RED")
            #expect(observation.visualRecordsConsistent)
            #expect(observation.restorationStatus == "PASS")
        }
        nativeTestHostBoundary("companion-body-end", detail: "hostLeaseNil=\(hostLease == nil)")
    }

    @Test("diagnostic only: SwiftPM testing helper host focus capability")
    func diagnosticSwiftPMTestingHelperHostFocusCapability() {
        struct Snapshot: Encodable {
            let phase: String
            let host_executable_path: String
            let host_executable_sha256: String
            let bundle_identifier: String
            let bundle_package_type: String
            let activation_policy: Int
            let isRunning: Bool
            let isFinishedLaunching: Bool
            let applicationActive: Bool
            let key_window_number: Int
            let owned_window_number: Int
            let exactKeyWindow: Bool
            let windowKey: Bool
            let visible: Bool
            let exactHost: Bool
            let exactOwner: Bool
            let main_thread: Bool
            let run_loop_mode: String
            let monotonic_timestamp: Double
        }
        struct Record: Encodable {
            let schema: String
            let test_symbol: String
            let snapshots: [Snapshot]
            let decision: String
            let ax_action_count: Int
            let product_transaction_count: Int
            let diagnostic_only: Bool
        }
        var window: NSWindow?
        var host: NSHostingController<EmptyView>?
        var snapshots: [Snapshot] = []
        let ownerIdentifier = "state2984-swiftpm-host-focus-capability"
        func capture(_ phase: String) {
            let application = NSApplication.shared
            let path = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
            var exactHost = false
            var exactOwner = false
            if let window, let host {
                let hostView = host.view
                let contentView = window.contentViewController?.view
                let isAttachedToWindow = hostView.window === window
                let isInstalledAsContent = contentView === hostView
                exactHost = isAttachedToWindow && isInstalledAsContent
                exactOwner = !ownerIdentifier.isEmpty && window.accessibilityIdentifier() == ownerIdentifier
            }
            snapshots.append(Snapshot(phase: phase, host_executable_path: path,
                host_executable_sha256: ProcessInfo.processInfo.environment["MINISCANVAS_FIELD_BINARY_SHA256"] ?? "",
                bundle_identifier: Bundle.main.bundleIdentifier ?? "",
                bundle_package_type: Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String ?? "",
                activation_policy: application.activationPolicy().rawValue,
                isRunning: application.isRunning,
                isFinishedLaunching: NSRunningApplication.current.isFinishedLaunching,
                applicationActive: application.isActive,
                key_window_number: application.keyWindow?.windowNumber ?? 0,
                owned_window_number: window?.windowNumber ?? 0,
                exactKeyWindow: window.map { application.keyWindow === $0 } ?? false,
                windowKey: window?.isKeyWindow ?? false,
                visible: window?.isVisible ?? false, exactHost: exactHost, exactOwner: exactOwner,
                main_thread: Thread.isMainThread,
                run_loop_mode: RunLoop.current.currentMode?.rawValue ?? "",
                monotonic_timestamp: ProcessInfo.processInfo.systemUptime))
        }
        capture("before_begin")
        let lease = NativeTestHostLifecycle.begin("STATE2984-swiftpm-host-focus-capability")
        capture("after_begin")
        let controller = NSHostingController(rootView: EmptyView())
        let diagnosticWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless], backing: .buffered, defer: true)
        diagnosticWindow.isReleasedWhenClosed = false
        diagnosticWindow.setAccessibilityIdentifier(ownerIdentifier)
        diagnosticWindow.contentViewController = controller
        window = diagnosticWindow
        host = controller
        ComposerNativeHostReadiness.bind(lease, to: diagnosticWindow)
        capture("after_bind")
        capture("after_make_ready")
        ComposerNativeHostReadiness.observe(diagnosticWindow, phase: "sampled")
        capture("after_sample")
        diagnosticWindow.orderOut(nil)
        diagnosticWindow.contentViewController = nil
        diagnosticWindow.close()
        NativeTestHostLifecycle.end(diagnosticWindow)
        capture("after_cleanup")
        let postBind = snapshots.filter { ["after_bind", "after_make_ready", "after_sample"].contains($0.phase) }
        let capable = postBind.contains {
            $0.applicationActive && $0.exactKeyWindow && $0.windowKey && $0.visible && $0.exactHost && $0.exactOwner
        }
        let record = Record(schema: "R18_STATE2984_SWIFTPM_HOST_CAPABILITY_RECORD_V1",
            test_symbol: "diagnosticSwiftPMTestingHelperHostFocusCapability", snapshots: snapshots,
            decision: capable ? "CAPABLE" : "INCAPABLE_CURRENT_ROUTE", ax_action_count: 0,
            product_transaction_count: 0, diagnostic_only: true)
        if let data = try? JSONEncoder().encode(record), let text = String(data: data, encoding: .utf8) {
            print("STATE2984_CAPABILITY_INSTRUMENTATION \(text)")
        } else {
            print("STATE2984_CAPABILITY_INSTRUMENTATION_ENCODING_ERROR")
        }
    }

    private func makeFixture(_ group: ComposerNativeFixtureContract.Group) throws -> ComposerNativeFixtureContract.Fixture {
        try ComposerNativeFixtureContract.Fixture(group: group) { applied in
            // Same model-selection assertion, observed once when each real ChatStore is prepared.
            #expect(applied)
        }
    }

    private func hostAndProbe(
        _ prepared: ComposerNativeFixtureContract.Prepared,
        consumer: ComposerNativeFixtureContract.Consumer
    ) -> ComposerNativeFixtureContract.HostedProbe {
        let expected = prepared.pair.expected(consumer)
        let root = prepared.root(consumer)
        let hostLease = ComposerNativeHostReadiness.begin("UF03")
        return ComposerNativeFixtureContract.hostAndProbe(
            root, width: expected.width,
            rowIdentifier: expected.rowIdentifier, policyIdentifier: expected.policyIdentifier,
            modelIdentifier: expected.modelIdentifier,
            onCreated: { ComposerNativeHostReadiness.bind(hostLease, to: $0) },
            onSampled: { ComposerNativeHostReadiness.observe($0, phase: "sampled") },
            onClosed: { NativeTestHostLifecycle.end($0) }
        )
    }
}

@MainActor
private enum ComposerNativeHostReadiness {
    private static let launchRunLoopSlice = 0.01
    private static let maxReadinessAttempts = 8

    static func begin(_ label: String) -> UUID {
        let lease = NativeTestHostLifecycle.begin(label)
        activateApplication()
        return lease
    }

    static func bind(_ lease: UUID, to window: NSWindow) {
        NativeTestHostLifecycle.bind(lease, to: window)
        makeReady(window)
    }

    static func observe(_ window: NSWindow, phase: String) {
        makeReady(window)
        NativeTestHostLifecycle.observe(window, phase: phase)
    }

    private static func activateApplication() {
        let application = NSApplication.shared
        if !application.isRunning || !NSRunningApplication.current.isFinishedLaunching {
            application.finishLaunching()
        }
        application.unhide(nil)
        application.activate(ignoringOtherApps: true)
    }

    private static func makeReady(_ window: NSWindow) {
        for _ in 0..<maxReadinessAttempts {
            activateApplication()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if NSApplication.shared.isActive
                && NSApplication.shared.keyWindow === window
                && window.isKeyWindow {
                return
            }
            _ = RunLoop.main.run(mode: .default,
                before: Date(timeIntervalSinceNow: launchRunLoopSlice))
        }
    }
}

// These objects intentionally do not declare NSAccessibilityProtocol conformance.
// Their public selector signatures exercise the shared reader without a UI host.
@MainActor
private final class UF03CompanionInputRoleProxy: NSObject {
    private let role: String
    init(_ role: String) { self.role = role }
    @objc func accessibilityRole() -> String? { role }
}

private final class UF03RectProxy: NSObject {
    let frame: CGRect
    var calls = 0

    init(frame: CGRect) { self.frame = frame }

    @objc dynamic func accessibilityFrame() -> CGRect {
        calls += 1
        return frame
    }
}

@MainActor
private final class UF03ObjectFrameProxy: NSObject {
    var calls = 0

    @objc(accessibilityFrame) dynamic func boxedFrame() -> NSValue {
        calls += 1
        return NSValue(rect: CGRect(x: 1, y: 2, width: 3, height: 4))
    }
}

@MainActor
private final class UF03ScalarFrameProxy: NSObject {
    var calls = 0

    @objc(accessibilityFrame) dynamic func scalarFrame() -> Double {
        calls += 1
        return 42
    }
}


extension ComposerPrimaryControlsNativeTests {
    @Test("CF global point frames convert through the zero screen without clipping", arguments: 0..<7)
    func cfGlobalPointsConvertToAppKit(_ index: Int) {
        let cases: [(name: String, position: CGPoint, size: CGSize, expected: CGRect)] = [
            ("zero-screen", CGPoint(x: 100, y: 200), CGSize(width: 40, height: 30), CGRect(x: 100, y: 850, width: 40, height: 30)),
            ("left-screen", CGPoint(x: -400, y: 100), CGSize(width: 80, height: 40), CGRect(x: -400, y: 940, width: 80, height: 40)),
            ("right-screen", CGPoint(x: 2100, y: 900), CGSize(width: 50, height: 25), CGRect(x: 2100, y: 155, width: 50, height: 25)),
            ("above-screen", CGPoint(x: 100, y: -240), CGSize(width: 40, height: 30), CGRect(x: 100, y: 1290, width: 40, height: 30)),
            ("below-screen", CGPoint(x: 100, y: 1200), CGSize(width: 40, height: 30), CGRect(x: 100, y: -150, width: 40, height: 30)),
            ("cross-screen", CGPoint(x: 1900, y: -10), CGSize(width: 50, height: 30), CGRect(x: 1900, y: 1060, width: 50, height: 30)),
            ("fractional-retina-points", CGPoint(x: 100.25, y: 200.5), CGSize(width: 40.5, height: 30.25), CGRect(x: 100.25, y: 849.25, width: 40.5, height: 30.25))
        ]
        let value = cases[index]
        let actual = UF03AXScreenCoordinates.appKitFrame(
            position: value.position, size: value.size,
            zeroScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(actual == value.expected, "\(value.name): preserve point units and full global rectangle")
    }

    @Test("CF conversion rejects absent or invalid zero-screen references", arguments: 0..<9)
    func cfConversionRejectsInvalidZeroScreen(_ index: Int) {
        let references: [CGRect?] = [
            nil, .zero,
            CGRect(x: 0, y: 0, width: 0, height: 1080),
            CGRect(x: 0, y: 0, width: -1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: -1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1080),
            CGRect(x: CGFloat.nan, y: 0, width: 1920, height: 1080)
        ]
        let actual = UF03AXScreenCoordinates.appKitFrame(
            position: CGPoint(x: 100, y: 200), size: CGSize(width: 40, height: 30),
            zeroScreenFrame: references[index])
        #expect(actual == nil)
    }

    @Test("CF conversion fails closed for invalid AX values and arithmetic overflow", arguments: 0..<10)
    func cfConversionRejectsInvalidValues(_ index: Int) {
        let huge = CGFloat.greatestFiniteMagnitude
        let cases: [(position: CGPoint, size: CGSize, screenHeight: CGFloat)] = [
            (CGPoint(x: CGFloat.nan, y: 200), CGSize(width: 40, height: 30), 1080),
            (CGPoint(x: 100, y: CGFloat.infinity), CGSize(width: 40, height: 30), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: CGFloat.nan, height: 30), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: 40, height: CGFloat.infinity), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: 0, height: 30), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: 40, height: 0), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: -40, height: 30), 1080),
            (CGPoint(x: 100, y: 200), CGSize(width: 40, height: -30), 1080),
            (CGPoint(x: huge, y: 200), CGSize(width: huge, height: 30), 1080),
            (CGPoint(x: 100, y: -huge), CGSize(width: 40, height: 30), huge)
        ]
        let value = cases[index]
        #expect(UF03AXScreenCoordinates.appKitFrame(
            position: value.position, size: value.size,
            zeroScreenFrame: CGRect(x: 0, y: 0, width: 1920, height: value.screenHeight)) == nil)
    }

    @Test("Native target eligibility preserves uniqueness complete traversal and role", arguments: 0..<8)
    func cfNativeEligibilityRemainsFailClosed(_ index: Int) {
        let cases: [(local: Int, native: Int, complete: Bool, role: Bool, expected: Bool)] = [
            (1, 1, true, true, true),
            (0, 1, true, true, false),
            (2, 1, true, true, false),
            (1, 0, true, true, false),
            (1, 2, true, true, false),
            (1, 1, false, true, false),
            (1, 1, true, false, false),
            (2, 2, false, false, false)
        ]
        let value = cases[index]
        #expect(UF03AXScreenCoordinates.nativeTargetIsEligible(
            localMatchCount: value.local, nativeMatchCount: value.native,
            traversalComplete: value.complete, hasNativeRole: value.role) == value.expected)
    }

    @Test("Coordinate normalization retains strict subpoint equality and missing-reference rejection")
    func cfNormalizationDoesNotGrantAnApproximateOrMissingMatch() {
        let zero = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let snapshot = CGRect(x: 100, y: 850, width: 40, height: 30)
        let exact = UF03AXScreenCoordinates.appKitFrame(
            position: CGPoint(x: 100, y: 200), size: CGSize(width: 40, height: 30), zeroScreenFrame: zero)
        let displaced = UF03AXScreenCoordinates.appKitFrame(
            position: CGPoint(x: 100, y: 200.25), size: CGSize(width: 40, height: 30), zeroScreenFrame: zero)
        #expect(exact == snapshot)
        #expect(displaced == CGRect(x: 100, y: 849.75, width: 40, height: 30))
        #expect(displaced != snapshot)
        let missing = UF03AXScreenCoordinates.appKitFrame(
            position: CGPoint(x: 100, y: 200), size: CGSize(width: 40, height: 30), zeroScreenFrame: nil)
        #expect(missing == nil)
        #expect(!UF03AXScreenCoordinates.nativeTargetIsEligible(
            localMatchCount: 1, nativeMatchCount: missing == snapshot ? 1 : 0,
            traversalComplete: true, hasNativeRole: true))
    }
}

// Public NSObject/AppKit attribute shape, with no window or native acceptance claim.
private final class UF03CompanionLabelProxy: NSObject {
    let direct: String?
    let legacy: Any?
    let title: String?
    var descriptionReads = 0

    init(direct: String?, legacy: Any?, title: String?) {
        self.direct = direct
        self.legacy = legacy
        self.title = title
    }

    @objc dynamic func accessibilityLabel() -> String? { direct }
    @objc dynamic func accessibilityTitle() -> String? { title }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attribute == .description else { return nil }
        descriptionReads += 1
        return legacy
    }
}
