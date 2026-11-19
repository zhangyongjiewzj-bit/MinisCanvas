import Foundation
import AppKit
import ApplicationServices
import SwiftUI
import os
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ApprovalPromptCenter approval/confirmation semantics")
@MainActor
struct ApprovalPromptCenterSemanticTests {
    private func makeRequest(id: String = "call_semantics") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            toolName: "file_write",
            inputSummary: "path: /tmp/example.txt",
            riskLevel: .high,
            requiresApproval: true
        )
    }

    private func makeL3Request(id: String = "call_l3") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            toolName: "shell_execute",
            inputSummary: "command: rm -rf /tmp/example",
            riskLevel: .high,
            requiresApproval: true,
            requiresSecondConfirmation: true
        )
    }

    private func startPresenting(
        _ center: ApprovalPromptCenter,
        request: ApprovalRequest
    ) async -> Task<ApprovalDecision, Never> {
        let task = Task { await center.present(request) }
        for _ in 0..<100 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return task
    }

    @Test func missingConfirmedSignalFailsClosed() async {
        let center = ApprovalPromptCenter()
        let decisionTask = Task { await center.present(makeRequest()) }

        while center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        center.resolve(approved: true, reason: "用户允许")
        let decision = await decisionTask.value

        #expect(decision.approved == false)
        #expect(decision.confirmed == false)
        #expect(decision.reason?.contains("confirmed") == true)
        #expect(center.lastDiagnostic?.code == .missingConfirmation)
    }

    @Test func explicitFalseConfirmationStaysSeparateFromApproval() async {
        let center = ApprovalPromptCenter()
        let decisionTask = await startPresenting(center, request: makeRequest())

        center.resolve(approved: true, reason: "已批准但未二次确认", confirmed: false)
        let decision = await decisionTask.value

        #expect(decision.approved == true)
        #expect(decision.confirmed == false)
    }

    @Test func l3ApprovalWaitsForExplicitSecondStep() async {
        let center = ApprovalPromptCenter()
        let decisionTask = await startPresenting(center, request: makeL3Request())

        center.approvePending()
        #expect(center.pendingRequest != nil)
        #expect(center.awaitingConfirmation)

        center.confirmPending()
        let decision = await decisionTask.value
        #expect(decision.approved == true)
        #expect(decision.confirmed == true)
    }

    @Test func rapidApprovalShortcutCannotCompleteBothHighRiskSteps() async throws {
        let center = ApprovalPromptCenter()
        let task = await startPresenting(center, request: makeL3Request(id: "rapid-shortcut"))
        defer { center.dismissPending(); task.cancel() }
        // This is the actual action bound to the visible button and Cmd-Y.
        center.actionsForPresentedRequest().approve()
        #expect(!center.awaitingConfirmation)
        try await Task.sleep(for: .milliseconds(550))
        center.actionsForPresentedRequest().approve()
        #expect(center.awaitingConfirmation)
        center.actionsForPresentedRequest().approve()
        #expect(center.pendingRequest?.id == "rapid-shortcut")
        #expect(center.awaitingConfirmation)
        try await Task.sleep(for: .milliseconds(550))
        center.actionsForPresentedRequest().approve()
        let decision = await task.value
        #expect(decision.approved && decision.confirmed)
    }

    @Test func dismissFailsClosedAndRecordsCancellation() async {
        let center = ApprovalPromptCenter()
        let decisionTask = await startPresenting(center, request: makeRequest())

        center.dismissPending()
        let decision = await decisionTask.value

        #expect(decision.approved == false)
        #expect(decision.confirmed == false)
        #expect(center.lastDiagnostic?.code == .cancelled)
        #expect(decision.status == .cancelled)
        #expect(center.pendingRequest == nil)
    }

    @Test func configuredInlineExpiryAutomaticallyRejectsPendingApproval() async {
        let center = ApprovalPromptCenter()
        center.inlineApprovalEnabled = true
        center.inlineHostAvailable = true
        center.expirationInterval = 0.05
        let probe = CompletionProbe()
        let task = Task { probe.decision = await center.present(makeRequest(id: "configured-inline-expiry")) }
        #expect(await observe { probe.decision != nil })
        #expect(probe.decision?.status == .expired)
        #expect(probe.decision?.approved == false)
        #expect(center.pendingRequest == nil)
        await cleanUp(task, center: center, probe: probe)
    }

    @Test func expiryFailsClosedAndRecordsExpiry() async {
        let center = ApprovalPromptCenter(expirationInterval: 60)
        let decisionTask = await startPresenting(center, request: makeRequest())

        center.expirePending()
        let decision = await decisionTask.value

        #expect(decision.approved == false)
        #expect(decision.confirmed == false)
        #expect(center.lastDiagnostic?.code == .expired)
    }

    @Test func duplicateResolveCannotResolveAnotherRequest() async {
        let center = ApprovalPromptCenter()
        let first = await startPresenting(center, request: makeRequest(id: "first"))

        center.resolve(approved: true, reason: "允许", confirmed: true, requestID: "first")
        let firstDecision = await first.value
        #expect(firstDecision.approved)
        #expect(firstDecision.confirmed)

        center.resolve(approved: true, reason: "迟到裁决", confirmed: true, requestID: "first")
        #expect(center.lastDiagnostic?.code == .duplicateResolution)

        let second = await startPresenting(center, request: makeRequest(id: "second"))
        center.resolve(approved: true, reason: "允许第二个", confirmed: true, requestID: "first")
        #expect(center.pendingRequest?.id == "second")
        #expect(center.lastDiagnostic?.code == .requestMismatch)
        center.resolve(approved: true, reason: "允许第二个", confirmed: true, requestID: "second")
        #expect((await second.value).confirmed)
    }

    @MainActor private final class CompletionProbe {
        var decision: ApprovalDecision?
    }

    private func observe(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // Failure cleanup also has a deadline. Never await an unobserved Task.value.
    private func cleanUp(
        _ task: Task<Void, Never>, center: ApprovalPromptCenter, probe: CompletionProbe
    ) async {
        center.dismissPending()
        task.cancel()
        #expect(await observe { probe.decision != nil }, "fixture must reach terminal after dismissal")
    }

    private func boundRequest(expiresAt: Date = Date().addingTimeInterval(60)) -> ApprovalRequest {
        ApprovalRequest(
            id: "lifecycle-call", requestID: "lifecycle-request", callID: "lifecycle-call",
            toolName: "file_read", inputSummary: "synthetic lifecycle request",
            riskLevel: .high, requiresApproval: true,
            sessionID: "lifecycle-session", turnID: 7, taskID: "lifecycle-task",
            attemptID: "lifecycle-attempt", approvalScope: "lifecycle-scope",
            composerMode: "manual", messageID: "lifecycle-message",
            identityDigest: "lifecycle-digest", expiresAt: expiresAt
        )
    }

    private func presentationContext(
        eventSink: @escaping @Sendable (ApprovalLifecycleFact) -> Void
    ) -> ApprovalPresentationContext {
        let turn = AgentTurnIdentity(
            sessionID: "lifecycle-session", turnID: 7, messageID: "lifecycle-message"
        )
        return ApprovalPresentationContext(
            compositeKey: ToolExecutionCompositeKey(
                sessionID: "lifecycle-session", turnID: 7, messageID: "lifecycle-message",
                operationID: "lifecycle-operation", attemptID: "lifecycle-attempt",
                attemptNumber: 1, toolCallID: "lifecycle-call"
            ),
            executionIdentity: AgentExecutionIdentity(
                turn: turn, operationID: "lifecycle-operation", attempt: 1
            ),
            toolName: "file_read", eventSink: eventSink
        )
    }

    @Test func lifecycleAlreadyCancelledCallerNeverPresents() async {
        let center = ApprovalPromptCenter()
        let delegate = ApprovalPromptDelegate(center: center)
        let probe = CompletionProbe()
        let request = boundRequest()
        // The new task cannot enter this actor until this slice yields.
        let task = Task { probe.decision = await delegate.requestApproval(request) }
        task.cancel()
        let finished = await observe { probe.decision != nil }
        #expect(finished, "pre-cancelled caller must return without a UI stop callback")
        #expect(center.pendingRequest == nil)
        #expect(probe.decision?.status == .cancelled)
        #expect(probe.decision?.approved == false)
        #expect(probe.decision?.confirmed == false)
        #expect(probe.decision?.requestID == request.requestID)
        #expect(probe.decision?.bindingDigest == request.identityDigest)
        await cleanUp(task, center: center, probe: probe)
    }

    @Test(arguments: [false, true])
    func lifecycleCallerTaskCancellationReturnsWithoutStopCallback(secondStep: Bool) async {
        let center = ApprovalPromptCenter()
        let delegate = ApprovalPromptDelegate(center: center)
        let probe = CompletionProbe()
        let request = secondStep ? makeL3Request() : boundRequest()
        let task = Task { probe.decision = await delegate.requestApproval(request) }
        guard await observe({ center.pendingRequest != nil }) else {
            Issue.record("request did not become pending")
            await cleanUp(task, center: center, probe: probe)
            return
        }
        if secondStep {
            center.approvePending()
            #expect(center.awaitingConfirmation)
            #expect(probe.decision == nil)
        }
        // Same primitive as nonactive deleteSession and stream.onTermination.
        // No stopGeneration/dismiss/resolve is called before the assertion.
        task.cancel()
        #expect(await observe { probe.decision != nil }, "Task.cancel must finish pending approval")
        #expect(probe.decision?.status == .cancelled)
        #expect(probe.decision?.approved == false)
        #expect(probe.decision?.confirmed == false)
        #expect(center.pendingRequest == nil)
        #expect(!center.awaitingConfirmation)
        await cleanUp(task, center: center, probe: probe)
    }

    @Test func lifecycleExpiryDuringPresentedEventReturnsWithoutManualExpiry() async {
        let center = ApprovalPromptCenter(expirationInterval: 60)
        let delegate = ApprovalPromptDelegate(center: center)
        let probe = CompletionProbe()
        let presentedCount = OSAllocatedUnfairLock(initialState: 0)
        // Entry guards see a fresh request. The real synchronous eventSink crosses
        // its deadline before scheduling expiration, with no injected clock.
        let expiresAt = Date().addingTimeInterval(0.2)
        let request = boundRequest(expiresAt: expiresAt)
        let context = presentationContext { _ in
            presentedCount.withLock { $0 += 1 }
            Thread.sleep(until: expiresAt.addingTimeInterval(0.01))
        }
        let task = Task {
            probe.decision = await ApprovalPresentationContext.$current.withValue(context) {
                await delegate.requestApproval(request)
            }
        }
        #expect(await observe { probe.decision != nil }, "deadline crossing must resume registered waiter")
        #expect(presentedCount.withLock { $0 } == 1, "exercise accepted event path, not entry expiry guard")
        #expect(probe.decision?.status == .expired)
        #expect(probe.decision?.approved == false)
        #expect(probe.decision?.confirmed == false)
        #expect(probe.decision?.bindingDigest == request.identityDigest)
        #expect(center.pendingRequest == nil)
        #expect(center.lastDiagnostic?.code == .expired)
        await cleanUp(task, center: center, probe: probe)
    }

    @Test func lifecycleOldCancellationCannotRejectFreshSameCall() async {
        let center = ApprovalPromptCenter()
        let delegate = ApprovalPromptDelegate(center: center)
        for _ in 0..<10 {
            let old = CompletionProbe()
            let oldTask = Task { old.decision = await delegate.requestApproval(makeRequest(id: "same-call")) }
            guard await observe({ center.pendingRequest != nil }) else {
                Issue.record("old request did not become pending")
                await cleanUp(oldTask, center: center, probe: old)
                return
            }
            // Queue cancellation delivery, then finish the old request in this
            // actor slice. A fresh presentation reuses the public call ID.
            oldTask.cancel()
            center.dismissPending()
            // Retire the real queue slot before admitting fresh work. This
            // does not join the independently scheduled cancellation tasks.
            #expect(await observe { old.decision != nil })
            let fresh = CompletionProbe()
            let freshTask = Task { fresh.decision = await delegate.requestApproval(makeL3Request(id: "same-call")) }
            guard await observe({ center.pendingRequest != nil }) else {
                Issue.record("fresh request did not become pending")
                await cleanUp(oldTask, center: center, probe: old)
                await cleanUp(freshTask, center: center, probe: fresh)
                return
            }
            // Also cancel the now-terminal old handle while fresh is pending.
            oldTask.cancel()
            for _ in 0..<5 { await Task.yield() }
            #expect(fresh.decision == nil)
            #expect(center.pendingRequest?.id == "same-call")
            center.approvePending()
            #expect(center.awaitingConfirmation)
            #expect(fresh.decision == nil)
            center.confirmPending()
            #expect(await observe { fresh.decision != nil })
            #expect(fresh.decision?.approved == true)
            #expect(fresh.decision?.confirmed == true)
            await cleanUp(oldTask, center: center, probe: old)
            await cleanUp(freshTask, center: center, probe: fresh)
        }
    }

}


/// The same retained action bundle is consumed by ApprovalPromptView. Real
/// ApprovalGate receipts and the built-in writer distinguish a rejected old
/// card from a replacement that was silently approved by that old action.
@Suite("D-TOOL-06/09/10 retained presentation actions", .serialized)
@MainActor
struct ApprovalPresentationAction682Tests {
    @Test func multiParameterFileReadAndGrepShowTheirRequestPaths() {
        let gate = ApprovalGate()
        let read = gate.makeRequest(tool: "file_read", input: [
            "path": "/owned/a/report.md", "offset": 1, "lines": 20
        ])
        let readSummary = ApprovalSummaryPresentation(request: read)
        #expect(readSummary.target == "report.md")
        #expect(readSummary.directory == "/owned/a")

        let grep = gate.makeRequest(tool: "file_grep", input: [
            "path": "/owned/a/report.md", "pattern": "synthetic heading"
        ])
        let grepSummary = ApprovalSummaryPresentation(request: grep)
        #expect(grepSummary.target == "report.md")
        #expect(grepSummary.directory == "/owned/a")
        #expect(grepSummary.searchDetails == grep.inputSummary)
    }

    enum OldAction: String, CaseIterable, Sendable {
        case allow, confirmation, deny, dismiss, expiredAllow, stoppedAllow
    }

    @MainActor private final class EffectProbe {
        var finished = false
        var succeeded = false
        var effects = 0
        var receipts: [ApprovalReceipt] = []
    }

    private func observe(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private func begin(
        center: ApprovalPromptCenter, root: URL, target: String, probe: EffectProbe
    ) -> Task<Void, Never> {
        let task = Task {
            do {
                try await Self.authorizeAndWrite(center: center, root: root, target: target, probe: probe)
                probe.effects += 1
                probe.succeeded = true
            } catch { probe.succeeded = false }
            probe.finished = true
        }
        B1TaskOriginalFixtureSupport.register(root: root, task: task,
            cancel: { center.stopGeneration() }, finished: { probe.finished })
        return task
    }

    // Neither the JSON input nor the concrete built-in executor is Sendable.
    // Confine both to one background worker, as in the production tool path;
    // the real approval delegate alone crosses back to the presentation actor.
    private nonisolated static func authorizeAndWrite(
        center: ApprovalPromptCenter, root: URL, target: String, probe: EffectProbe
    ) async throws {
        let input: [String: Any] = ["path": root.appendingPathComponent(target).path,
                                   "content": target]
        let context = ApprovalAuthorizationContext(
            actorID: "fixture-682", sessionID: "session-682", turnID: 1,
            taskID: "task-682", runID: "run-682", attemptID: "attempt-682",
            effectID: "reused-public-call-682", scope: "request",
            payloadDigest: try #require(ApprovalAuthorizationContext.payloadDigest(for: input)),
            expiresAt: Date().addingTimeInterval(60), policyRevision: "policy-682",
            grantEpoch: "epoch-682", toolName: "file_delete"
        )
        let gate = ApprovalGate(delegate: ApprovalPromptDelegate(center: center),
            onApprovalReceipt: { receipt in await MainActor.run { probe.receipts.append(receipt) } })
        // 2026-11-16 起只有不可逆操作才需要第二次确认；普通 file_write 已是一次点击。
        // 这个夹具要验证的是“两步确认”的绑定，所以用不可逆的 file_delete 作为门控名称，
        // 确认前后是否出现写入副作用仍由下面的 BuiltinToolExecutor 证明。
        _ = try await gate.gate(tool: "file_delete", input: input, context: context)
        let executor = BuiltinToolExecutor(allowedRoot: root)
        _ = try await executor.execute(name: "file_write", input: input)
    }

    @Test(arguments: OldAction.allCases)
    func retainedOldCardCannotActOnReusedPublicIDAndChangedTarget(action: OldAction) async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("tool682") { root in
        let center = ApprovalPromptCenter()
        let old = EffectProbe()
        let oldTask = begin(center: center, root: root, target: "old.txt", probe: old)
        let originalObservation1 = await observe { center.pendingRequest != nil }
        #expect(originalObservation1)
        let oldDigest = try #require(center.pendingRequest?.identityDigest)
        var retained = center.actionsForPresentedRequest()
        if action == .confirmation {
            try await Task.sleep(for: .milliseconds(550))
            retained.approve()
            #expect(center.awaitingConfirmation)
            retained = center.actionsForPresentedRequest()
        }
        if action == .expiredAllow { center.expirePending() }
        else if action == .stoppedAllow { center.stopGeneration() }
        else { center.dismissPending() }
        let originalObservation2 = await observe { old.finished }
        #expect(originalObservation2)
        guard old.finished else { oldTask.cancel(); return }
        await oldTask.value
        #expect(!old.succeeded && old.effects == 0 && old.receipts.isEmpty)

        let fresh = EffectProbe()
        let freshTask = begin(center: center, root: root, target: "fresh.txt", probe: fresh)
        let originalObservation3 = await observe { center.pendingRequest != nil }
        #expect(originalObservation3)
        let freshDigest = try #require(center.pendingRequest?.identityDigest)
        #expect(freshDigest != oldDigest)
        #expect(center.pendingRequest?.requestID == "reused-public-call-682")
        // The new target has its own first consent. An old first-step action
        // must not become the new target's second confirmation.
        try await Task.sleep(for: .milliseconds(550))
        center.actionsForPresentedRequest().approve()
        #expect(center.awaitingConfirmation)
        switch action {
        case .deny: retained.deny()
        case .dismiss: retained.dismiss()
        default: retained.approve()
        }
        let actedOnReplacement = await observe { fresh.finished }
        #expect(!actedOnReplacement)
        #expect(center.pendingRequest?.identityDigest == freshDigest)
        #expect(center.awaitingConfirmation)
        #expect(fresh.effects == 0 && fresh.receipts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fresh.txt").path))

        center.actionsForPresentedRequest().approve()
        let originalObservation4 = await observe { fresh.finished }
        #expect(originalObservation4)
        if !fresh.finished { center.stopGeneration(); freshTask.cancel() }
        let originalObservation5 = await observe { fresh.finished }
        #expect(originalObservation5)
        guard fresh.finished else { return }
        await freshTask.value
        #expect(fresh.succeeded && fresh.effects == 1)
        #expect(fresh.receipts.count == 1)
        #expect(fresh.receipts.first?.identityDigest == freshDigest)
        #expect(try String(contentsOf: root.appendingPathComponent("fresh.txt"), encoding: .utf8) == "fresh.txt")
        retained.approve(); retained.deny(); retained.dismiss()
        #expect(fresh.effects == 1 && fresh.receipts.count == 1)
        #expect(center.pendingRequest == nil)
            }
    }

    @Test("P04 nine public identity fields use one exact nine-line copy projection")
    func identityRowsAndCopyKeepExactlyNineOriginalValues() {
        let request = ApprovalRequest(id: "owned-id", callID: "owned-call", toolName: "file_write",
            inputSummary: "<redacted>", riskLevel: .high, requiresApproval: true,
            sessionID: "owned-session", taskID: "owned-task", approvalScope: "request",
            composerMode: "manual", messageID: "owned-message", policyRevision: "owned-policy",
            grantEpoch: "owned-epoch", inputDigest: "input-owned-sha", identityDigest: "identity-owned-sha")
        let presentation = ApprovalIdentityPresentation(request: request)
        let expected = ["Call owned-call", "Session owned-session", "Task owned-task",
            "Message owned-message", "模式 / 范围 manual / request", "Policy owned-policy",
            "Lease owned-epoch", "Input SHA-256 input-owned-sha", "Identity SHA-256 identity-owned-sha"]
        #expect(presentation.rows.map(\.text) == expected)
        #expect(presentation.copyText == expected.joined(separator: "\n"))
        #expect(presentation.copyText.components(separatedBy: "\n").count == 9)
        #expect(Set(presentation.rows.map(\.id)).count == 9)
        #expect(presentation.rows.map(\.id) == ["approval.identity.call", "approval.identity.session",
            "approval.identity.task", "approval.identity.message", "approval.identity.mode-scope",
            "approval.identity.policy", "approval.identity.lease", "approval.identity.input-sha256",
            "approval.identity.identity-sha256"])
    }

    @Test("P04 missing and untrusted identity text cannot inject a tenth copied line or a credential")
    func identityCopyPreservesMissingValuesAndRedaction() {
        let request = ApprovalRequest(id: "owned", toolName: "file_write", inputSummary: "<redacted>",
            riskLevel: .high, requiresApproval: true,
            sessionID: "Authorization: Bearer OWNED_SYNTHETIC_P04_SECRET",
            taskID: "owned-task\nsecond-line")
        let presentation = ApprovalIdentityPresentation(request: request)
        #expect(presentation.rows.count == 9)
        #expect(presentation.copyText.components(separatedBy: "\n").count == 9)
        #expect(!presentation.copyText.contains("OWNED_SYNTHETIC_P04_SECRET"))
        #expect(presentation.rows[1].text == "Session Authorization: Bearer **************************")
        #expect(presentation.rows[2].value == "owned-task␊second-line")
        #expect(presentation.rows[3].value == "missing")
        #expect(presentation.rows[4].value == "missing")
    }

    @Test("P04 summary uses the approved file target without exposing the input body")
    func summaryUsesFileNameDirectoryScopeAndChineseAction() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("p04-summary") { root async throws -> Void in
            let reports = root.appendingPathComponent("reports", isDirectory: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let path = reports.appendingPathComponent("output-report.md").path
            let preview = try #require(ApprovalFilePreview.capture(tool: "file_write",
                input: ["path": path, "content": "owned preview body"]))
            let request = ApprovalRequest(id: "summary-owned", toolName: "file_write", inputSummary: "<redacted>",
                riskLevel: .high, requiresApproval: true, approvalScope: "request", filePreview: preview)
            let summary = ApprovalSummaryPresentation(request: request)
            #expect(summary.action == "写入文件")
            #expect(summary.target == "output-report.md")
            // 0717 修复②：超过 120 字的目录在中间省略，保留开头 40 字与结尾 79 字。
            let expectedDirectory = reports.path.count > 120
                ? String(reports.path.prefix(40)) + "…" + String(reports.path.suffix(79)) : reports.path
            #expect(summary.directory == expectedDirectory)
            #expect(summary.reason == "可能覆盖目标文件的已有内容。")
            #expect(summary.scope == "范围：仅这一次")
            #expect(![summary.action, summary.target, summary.directory, summary.reason, summary.scope]
                .contains(where: { $0.contains("owned preview body") }))
            #expect(request.inputSummary == "<redacted>" && request.filePreview == preview)
        }
    }

    @Test("子智能体审批卡：目标行显示子任务标题（前 3 个，超出写等 N 个任务），原因说明会派出子智能体")
    func orchestrateCardShowsTaskTitles() {
        var request = ApprovalRequest(id: "orch-card", toolName: "orchestrate", inputSummary: "<redacted>",
            riskLevel: .medium, requiresApproval: true, approvalScope: "request")
        request.displayTaskTitles = ["整理报告", "核对数据"]
        let two = ApprovalSummaryPresentation(request: request)
        #expect(two.target == "子任务：整理报告、核对数据")
        #expect(two.reason.contains("派出子智能体"))
        request.displayTaskTitles = ["甲", "乙", "丙", "丁", "戊"]
        #expect(ApprovalSummaryPresentation(request: request).target == "子任务：甲、乙、丙 等 5 个任务")
        // 没有标题时回退到原来的通用写法。
        request.displayTaskTitles = []
        #expect(ApprovalSummaryPresentation(request: request).target == "工具：orchestrate")
    }

    @Test("第七版：删除审批卡自己写明普通档是永久删除，不依赖模型预告")
    func deleteCardStatesPermanentDeletion() {
        let request = ApprovalRequest(id: "v7-delete", toolName: "file_delete", inputSummary: "<redacted>",
            riskLevel: .high, requiresApproval: true, approvalScope: "request")
        let summary = ApprovalSummaryPresentation(request: request)
        #expect(summary.reason.contains("永久删除"))
        #expect(summary.reason.contains("不进废纸篓"))
    }

    @Test func nonPreviewApprovalSummariesUseOnlyUnambiguousTargets() {
        func summary(_ tool: String, _ input: String) -> ApprovalSummaryPresentation {
            ApprovalSummaryPresentation(request: ApprovalRequest(
                id: "owned-summary", toolName: tool, inputSummary: input,
                riskLevel: .medium, requiresApproval: true
            ))
        }

        let fileRead = summary("file_read", "path: /owned/report.md")
        #expect(fileRead.action == "读取文件")
        #expect(fileRead.target == "/owned/report.md")
        #expect(fileRead.directory == "工具：file_read")

        let mcp = summary("mcp_example", "tool_title: path: /owned/misleading.md")
        #expect(mcp.action == "工具调用：mcp_example")
        #expect(mcp.target == "工具：mcp_example")
        let input = ApprovalGate.makeInputSummary([
            "path": "/owned/" + String(repeating: "a", count: 90),
            "pattern": "*.md"
        ])
        #expect(input.contains("…"))
        let grep = summary("file_grep", input)
        #expect(grep.action == "搜索文件内容")
        #expect(grep.target == "工具：file_grep")
        #expect(grep.searchDetails == input)
        let glob = summary("file_glob", input)
        #expect(glob.action == "查找文件")
        #expect(glob.target == "工具：file_glob")
        #expect(glob.searchDetails == input)
    }

    @Test("V1-04 sensitive file summary uses Chinese placeholders and hides the path")
    func sensitiveFileSummaryUsesChinesePlaceholdersWithoutExposingPath() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("v1-04-summary") { root async throws -> Void in
            let directory = root.appendingPathComponent("fixture-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(".env")
            try "fixture text".write(to: file, atomically: true, encoding: .utf8)
            let preview = try #require(ApprovalFilePreview.capture(tool: "file_write",
                input: ["path": file.path, "content": "proposed fixture text"]))
            try #require(preview.isSensitive)
            try #require(preview.available)
            let request = ApprovalRequest(id: "v1-04-summary", toolName: "file_write", inputSummary: "<redacted>",
                riskLevel: .high, requiresApproval: true, approvalScope: "request", filePreview: preview)
            let summary = ApprovalSummaryPresentation(request: request)
            #expect(summary.target == "目标已隐藏")
            #expect(summary.directory == "目录已隐藏")
            #expect(![summary.action, summary.target, summary.directory, summary.reason, summary.scope]
                .contains(where: { $0.contains(file.lastPathComponent) || $0.contains(directory.lastPathComponent) }))
        }
    }

    @Test("V1-01 external send shows the recipient and full redacted message on the unopened approval card")
    func externalSendShowsRecipientAndFullMessageBeforeExpandingDetails() async throws {
        try #require(NSApplication.shared.isRunning, "requires the existing native App test entry")
        let recipient = "168DD30F-E2F7-4699-A521-54B5452055FD"
        let message = "第一行：请检查本地夹具。\n" + String(repeating: "验证 ", count: 160) + "\n末行：确认校验和。"
        let secret = "OWNED_SYNTHETIC_V1_01_SECRET"
        let request = ApprovalRequest(
            id: "owned-external-send", toolName: "external_session_send",
            inputSummary: """
            向外部智能体会话发送纠偏消息
            来源：codex
            会话 ID：\(recipient)
            会话标题（来自外部会话，仅供辨认）：“本地夹具”
            命令（消息经 stdin 传入，不在命令行中）：codex exec resume \(recipient) -
            工作目录：/tmp
            消息全文（与实际发送的字符串完全相同）：
            \(message)
            Authorization: Bearer \(secret)
            已发出的消息不可撤回。
            """,
            riskLevel: .high, requiresApproval: true, approvalScope: "request", composerMode: "manual")
        let center = ApprovalPromptCenter()
        let lease = NativeTestHostLifecycle.begin("ApprovalExternalSendV1-01")
        let controller = NSHostingController(rootView: Color.clear.frame(width: 600, height: 200)
            .sheet(isPresented: Binding(get: { center.pendingRequest != nil },
                set: { if !$0 { center.dismissPending() } })) {
                ApprovalPromptView(center: center)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("approval-external-send-\(lease.uuidString)")
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        let pending = Task { await center.present(request) }
        defer {
            center.dismissPending(); pending.cancel()
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        try #require(await observe { center.pendingRequest != nil && window.attachedSheet != nil })
        let sheet = try #require(window.attachedSheet)
        if sheet.accessibilityIdentifier().isEmpty {
            sheet.setAccessibilityIdentifier("native-consumer-sheet-" + UUID().uuidString)
        }
        try #require(await observe {
            NativeConsumerOwnedAX.find(in: window, identifier: "approval.summary.action") != nil
        })
        let summary = try #require(NativeConsumerOwnedAX.textSnapshot(in: window, identifier: "approval.summary"))
        #expect(summary.texts.contains { $0.contains("来源：codex") && $0.contains("会话 ID：" + recipient) })
        #expect(summary.texts.contains { $0.contains(message) })
        #expect(summary.texts.contains { $0.contains("Authorization: Bearer ***") })
        #expect(!summary.texts.contains { $0.contains(secret) })
    }

    @Test("P04 collapsed and expanded production approval retain nine AX rows and copy through the real button")
    func nativeIdentityRowsSurviveCollapseAndCopyExactlyNineLines() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("p04-native-identity") { _ async throws -> Void in
            try #require(NSApplication.shared.isRunning, "requires the existing native App test entry")
            let request = ApprovalRequest(id: "owned-id", callID: "owned-call", toolName: "file_write",
                inputSummary: "<redacted>", riskLevel: .high, requiresApproval: true,
                sessionID: "owned-session", taskID: "owned-task", approvalScope: "request",
                composerMode: "manual", messageID: "owned-message", policyRevision: "owned-policy",
                grantEpoch: "owned-epoch", inputDigest: "input-owned-sha", identityDigest: "identity-owned-sha")
            let expected = ["Call owned-call", "Session owned-session", "Task owned-task",
                "Message owned-message", "模式 / 范围 manual / request", "Policy owned-policy",
                "Lease owned-epoch", "Input SHA-256 input-owned-sha", "Identity SHA-256 identity-owned-sha"]
            let fields = ["call", "session", "task", "message", "mode-scope", "policy", "lease", "input-sha256", "identity-sha256"]
            let board = NSPasteboard(name: .init("P04-owned-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let center = ApprovalPromptCenter()
            let lease = NativeTestHostLifecycle.begin("ApprovalIdentityP04")
            let controller = NSHostingController(rootView: Color.clear.frame(width: 600, height: 200)
                .sheet(isPresented: Binding(get: { center.pendingRequest != nil },
                    set: { if !$0 { center.dismissPending() } })) {
                    ApprovalPromptView(center: center, identityPasteboard: board)
                })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.setAccessibilityIdentifier("approval-identity-p04-\(lease.uuidString)")
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            let pending = Task { await center.present(request) }
            defer {
                center.dismissPending(); pending.cancel()
                window.orderOut(nil); window.contentViewController = nil; window.close()
                NativeTestHostLifecycle.end(window)
            }
            let presented = await observe { center.pendingRequest != nil && window.attachedSheet != nil }
            try #require(presented)
            let sheet = try #require(window.attachedSheet)
            try #require(window.sheets.count == 1 && sheet.sheetParent === window)
            // Preserve the original attached-sheet query's unique ownership ID.
            if sheet.accessibilityIdentifier().isEmpty {
                sheet.setAccessibilityIdentifier("native-consumer-sheet-" + UUID().uuidString)
            }
            // This host exposes the owned sheet through AXChildren, not AXSheets.
            // The existing parent-owned query still requires a complete, unique hit.
            let mounted = await observe {
                NativeConsumerOwnedAX.find(in: window,
                    identifier: "approval.identity.copy-all") != nil
            }
            try #require(mounted)
            let legacy = try #require(NativeConsumerOwnedAX.find(in: window,
                identifier: "approval.technical-identity"))
            // Public AX projection diagnostics only; never read or print any clipboard.
            // Emit statuses and matches against this case's synthetic expected text.
            if let element = NativeConsumerOwnedAX.element(legacy) {
                for attribute in [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    print("P04_LEGACY_AX_PROJECTION attribute=\(attribute) status=\(status.rawValue) stringValue=\(value is String) exactSyntheticMatch=\((value as? String) == expected.joined(separator: "; "))")
                }
            }
            #expect(NativeConsumerOwnedAX.attribute(legacy, kAXValueAttribute as CFString) as? String
                == expected.joined(separator: "; "))
            for expanded in [false, true, false] {
                let toggle = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifier: "approval.identity.toggle"))
                if let element = NativeConsumerOwnedAX.element(toggle) {
                    for attribute in [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
                        var value: CFTypeRef?
                        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                        print("P04_TOGGLE_AX_PROJECTION expectedExpanded=\(expanded) attribute=\(attribute) status=\(status.rawValue) stringValue=\(value is String) exactSyntheticMatch=\((value as? String) == (expanded ? "已展开" : "已折叠"))")
                    }
                }
                #expect(NativeConsumerOwnedAX.attribute(toggle, kAXValueAttribute as CFString) as? String
                    == (expanded ? "已展开" : "已折叠"))
                for (field, text) in zip(fields, expected) {
                    let row = try #require(NativeConsumerOwnedAX.find(in: window,
                        identifier: "approval.identity." + field))
                    #expect(NativeConsumerOwnedAX.attribute(row, kAXValueAttribute as CFString) as? String == text)
                }
                let copy = try #require(NativeConsumerOwnedAX.find(in: window,
                    identifier: "approval.identity.copy-all"))
                try #require(NativeConsumerOwnedAX.press(copy))
                #expect(board.string(forType: .string) == expected.joined(separator: "\n"))
                try #require(NativeConsumerOwnedAX.press(toggle))
                // The fixed selector list contains only this case's public IDs.
                // Snapshot strings stay local; logs contain presence Booleans only.
                let afterPress = NativeConsumerOwnedAX.textSnapshot(in: window,
                    identifier: "approval.technical-identity")
                print("P04_POST_TOGGLE_AX_PROJECTION expectedExpanded=\(!expanded) ownedIdentityReadable=\(afterPress != nil)")
                for selector in ["approval.identity.toggle", "approval.identity.copy-all"]
                    + fields.map({ "approval.identity." + $0 }) {
                    print("P04_POST_TOGGLE_SELECTOR selector=\(selector) present=\(afterPress?.labelsByIdentifier[selector] != nil)")
                }
                let changed = await observe {
                    guard let current = NativeConsumerOwnedAX.find(in: window,
                        identifier: "approval.identity.toggle") else { return false }
                    return NativeConsumerOwnedAX.attribute(current, kAXValueAttribute as CFString) as? String
                        == (expanded ? "已折叠" : "已展开")
                }
                try #require(changed)
            }
            #expect(center.pendingRequest == request && !center.awaitingConfirmation)
            center.dismissPending()
            #expect(!(await pending.value).approved)
        }
    }

    @Test func nativeSkillApprovalIdentifiesScopeBroadeningInItsDiff() async throws {
        try #require(NSApplication.shared.isRunning)
        let center = ApprovalPromptCenter()
        let lease = NativeTestHostLifecycle.begin("SkillScopeApproval")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.setAccessibilityIdentifier("skill-scope-approval-\(lease.uuidString)")
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: ApprovalPromptView(center: center))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 620))
        window.makeKeyAndOrderFront(nil)
        defer {
            center.dismissPending()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }

        var request = ApprovalRequest(id: "owned-skill-scope-card", toolName: "skill_update",
            inputSummary: "synthetic", riskLevel: .high, requiresApproval: true,
            requiresSecondConfirmation: true)
        request.skillDiff = FileChangeDiffPayload(diffID: "owned-scope-diff", path: "skills/owned/SKILL.md",
            unifiedDiff: "@@ -1 +1,3 @@\n-原有说明\n+新增工具：文件读取\n+新增目录：样例目录\n+扩大写入范围：样例输出",
            insertions: 3, deletions: 1)
        let pending = request
        let waiting = Task { await center.present(pending) }
        defer { waiting.cancel() }
        try #require(await observe { center.pendingRequest?.requestID == pending.requestID },
            "The exact owned skill request must be pending")
        try #require(window.isVisible && window.contentViewController === controller,
            "The test's original native window must present the card")
        try #require(await observe {
            NativeConsumerOwnedAX.find(in: window, identifier: "approval.summary.action") != nil
        }, "The actual approval card must be visible")
        try #require(await observe {
            NativeConsumerOwnedAX.findDisplayedText(in: window, exactText: "变更预览（已脱敏）") != nil
        }, "The skill change preview must be visible before checking its warning")
        let warning = NativeConsumerOwnedAX.find(in: window, identifier: "approval.skill-scope-expansion")
        #expect(warning != nil)
        if let warning {
            let text = NativeConsumerOwnedAX.label(warning) ?? ""
            for marker in ["新增工具", "新增目录", "扩大写入范围"] { #expect(text.contains(marker)) }
        }
        center.dismissPending()
        #expect(!(await waiting.value).approved)
    }

    @Test("web fetch approval explains the two routing modes before the decision")
    func nativeWebFetchApprovalExplainsProxyAndPinning() async throws {
        try #require(NSApplication.shared.isRunning, "requires the existing native App test entry")
        let center = ApprovalPromptCenter()
        let lease = NativeTestHostLifecycle.begin("WebFetchRoutingApproval")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("web-fetch-routing-approval-\(lease.uuidString)")
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ApprovalPromptView(center: center))
        window.makeKeyAndOrderFront(nil)
        defer {
            center.dismissPending()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }

        let request = ApprovalRequest(id: "web-fetch-routing-card",
            toolName: WebFetchToolContract.toolName, inputSummary: "synthetic",
            riskLevel: .medium, requiresApproval: true, webFetchAuthority: "routing.example:443")
        let waiting = Task { await center.present(request) }
        defer { waiting.cancel() }
        try #require(await observe {
            center.pendingRequest?.requestID == request.requestID
                && NativeConsumerOwnedAX.find(in: window, identifier: "approval.web-fetch-authority") != nil
        }, "the genuine approval card must be visible before inspecting routing text")
        try #require(await observe {
            NativeConsumerOwnedAX.find(in: window, identifier: "approval.web-fetch-routing") != nil
        })
        let routing = try #require(NativeConsumerOwnedAX.find(in: window,
            identifier: "approval.web-fetch-routing"))
        let text = try #require(NativeConsumerOwnedAX.label(routing))
        let authority = try #require(NativeConsumerOwnedAX.textSnapshot(in: window,
            identifier: "approval.web-fetch-authority"))
        #expect(authority.labelsByIdentifier["approval.web-fetch-routing"] == Optional([text]))
        #expect(text.contains("经代理无法固定 IP"))
        #expect(text.contains("无法确认直连"))
        #expect(text.contains("已允许的网站"))
        #expect(text.contains("系统网络路径"))
        #expect(text.contains("不固定 IP"))
        #expect(center.pendingRequest?.requestID == request.requestID)
        center.dismissPending()
        #expect(!(await waiting.value).approved)
    }

    @Test("mounted high-risk sheet rejects native Return while Allow only opens confirmation")
    func nativeHighRiskReturnRejectsAndAllowWaitsForConfirmation() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("tool03-native-return") { root async throws -> Void in
            try #require(NSApplication.shared.isRunning, "requires the existing native App test entry")
            let center = ApprovalPromptCenter()
            let lease = NativeTestHostLifecycle.begin("ApprovalHighRiskReturn")
            let controller = NSHostingController(rootView: Color.clear.frame(width: 600, height: 200)
                .sheet(isPresented: Binding(
                    get: { center.pendingRequest != nil },
                    set: { if !$0 { center.dismissPending() } }
                )) {
                    ApprovalPromptView(center: center)
                })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.setAccessibilityIdentifier("approval-high-risk-return-\(lease.uuidString)")
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.makeKeyAndOrderFront(nil)
            defer {
                center.stopGeneration()
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
                NativeTestHostLifecycle.end(window)
            }

            let rejected = EffectProbe()
            let rejectedTask = begin(center: center, root: root, target: "return-rejected.txt", probe: rejected)
            let firstPresented = await observe { center.pendingRequest != nil && window.attachedSheet != nil }
            try #require(firstPresented)
            #expect(center.pendingRequest?.riskLevel == .high)
            #expect(center.pendingRequest?.requiresSecondConfirmation == true)
            let sheet = try #require(window.attachedSheet)
            try #require(window.sheets.count == 1 && sheet.sheetParent === window)
            // Preserve the original attached-sheet query's unique ownership ID.
            if sheet.accessibilityIdentifier().isEmpty {
                sheet.setAccessibilityIdentifier("native-consumer-sheet-" + UUID().uuidString)
            }
            // Keep the original 0.5s new-modal guard intact before input.
            try await Task.sleep(for: .milliseconds(550))
            try #require(sheet.isKeyWindow && sheet.firstResponder != nil)
            try #require(NativeConsumerOwnedAX.find(in: window, identifier: "approval.deny") != nil)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.sendEvent(event)
            let rejectedFinished = await observe { rejected.finished }
            #expect(rejectedFinished, "native default Return must settle the high-risk request as denied")
            #expect(!center.awaitingConfirmation)
            #expect(!rejected.succeeded && rejected.effects == 0 && rejected.receipts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("return-rejected.txt").path))
            try #require(rejectedFinished)
            await rejectedTask.value
            #expect(center.pendingRequest == nil)
            let firstDismissed = await observe { window.attachedSheet == nil }
            try #require(firstDismissed)

            let allowed = EffectProbe()
            let allowedTask = begin(center: center, root: root, target: "allow-unconfirmed.txt", probe: allowed)
            let secondPresented = await observe { center.pendingRequest != nil && window.attachedSheet != nil }
            try #require(secondPresented)
            #expect(center.pendingRequest?.riskLevel == .high)
            #expect(center.pendingRequest?.requiresSecondConfirmation == true)
            let secondSheet = try #require(window.attachedSheet)
            try #require(window.sheets.count == 1 && secondSheet.sheetParent === window)
            // Preserve the original attached-sheet query's unique ownership ID.
            if secondSheet.accessibilityIdentifier().isEmpty {
                secondSheet.setAccessibilityIdentifier("native-consumer-sheet-" + UUID().uuidString)
            }
            try await Task.sleep(for: .milliseconds(550))
            let allowButton = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "approval.allow"))
            #expect(NativeConsumerOwnedAX.press(allowButton))
            let confirming = await observe { center.awaitingConfirmation }
            #expect(confirming)
            #expect(center.pendingRequest != nil)
            #expect(!allowed.finished && !allowed.succeeded && allowed.effects == 0 && allowed.receipts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-unconfirmed.txt").path))
            try #require(confirming)
            try #require(NativeConsumerOwnedAX.find(in: window, identifier: "approval.confirm") != nil)
            let denyButton = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "approval.deny"))
            #expect(NativeConsumerOwnedAX.press(denyButton))
            let cancelled = await observe { allowed.finished }
            try #require(cancelled)
            await allowedTask.value
            #expect(!allowed.succeeded && allowed.effects == 0 && allowed.receipts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-unconfirmed.txt").path))
        }
    }

    @Test func repeatedRenderedFirstConsentCannotSupplySecondConfirmation() async throws {
        try await B1TaskOriginalFixtureSupport.withRoot("tool682-first") { root async throws -> Void in
        let center = ApprovalPromptCenter()
        let probe = EffectProbe()
        let task = begin(center: center, root: root, target: "confirmed.txt", probe: probe)
        let originalObservation6 = await observe { center.pendingRequest != nil }
        #expect(originalObservation6)
        let firstRendered = center.actionsForPresentedRequest()
        try await Task.sleep(for: .milliseconds(550))
        firstRendered.approve()
        firstRendered.approve()
        let prematurelyFinished = await observe { probe.finished }
        #expect(!prematurelyFinished)
        #expect(center.pendingRequest != nil && center.awaitingConfirmation)
        #expect(probe.effects == 0 && probe.receipts.isEmpty)
        center.actionsForPresentedRequest().approve()
        let originalObservation7 = await observe { probe.finished }
        #expect(originalObservation7)
        if !probe.finished { center.stopGeneration(); task.cancel() }
        let originalObservation8 = await observe { probe.finished }
        #expect(originalObservation8)
        guard probe.finished else { return }
        await task.value
        #expect(probe.succeeded && probe.effects == 1 && probe.receipts.count == 1)
        #expect(try String(contentsOf: root.appendingPathComponent("confirmed.txt"), encoding: .utf8) == "confirmed.txt")
        firstRendered.approve()
        #expect(probe.effects == 1 && probe.receipts.count == 1)
            }
    }
}


@Suite("Goal18 approval presentation safeguards")
@MainActor
struct Goal18ApprovalPresentationTests {
    @Test(arguments: ["explicit-fallback", "feature-disabled", "host-removed"])
    func dialogReplacementStartsAFreshInputGuard(_ transition: String) async throws {
        let center = ApprovalPromptCenter()
        center.inlineApprovalEnabled = true
        center.inlineHostAvailable = true
        let waiter = Task { await center.present(ApprovalRequest(id: "dialog-reset-" + transition,
            toolName: "file_write", inputSummary: "synthetic", riskLevel: .high,
            requiresApproval: true, requiresSecondConfirmation: true)) }
        defer { center.dismissPending(); waiter.cancel() }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.usesInlinePresentation)
        try await Task.sleep(for: .milliseconds(550))
        switch transition {
        case "explicit-fallback": center.fallBackToDialog()
        case "feature-disabled": center.inlineApprovalEnabled = false
        default: center.inlineHostAvailable = false
        }
        #expect(!center.usesInlinePresentation)
        center.handleReturn()
        center.actionsForPresentedRequest().approve()
        #expect(center.pendingRequest?.id == "dialog-reset-" + transition)
        #expect(!center.awaitingConfirmation)
        try await Task.sleep(for: .milliseconds(550))
        center.actionsForPresentedRequest().approve()
        #expect(center.awaitingConfirmation)
        center.actionsForPresentedRequest().approve()
        #expect(center.pendingRequest != nil && center.awaitingConfirmation)
        center.actionsForPresentedRequest().deny()
        #expect(!(await waiter.value).approved)
    }

    /// A-1（2026-11-17 审查）：必须点击批准的卡片，⌘回车不批准；普通卡片 ⌘回车照常批准。
    @Test func commandReturnNeverApprovesExplicitClickCards() async throws {
        let center = ApprovalPromptCenter()
        var sensitive = ApprovalRequest(id: "cmd-return-sensitive", toolName: "file_read",
            inputSummary: "synthetic .env", riskLevel: .medium, requiresApproval: true)
        sensitive.requiresExplicitClick = true
        let blocked = Task { await center.present(sensitive) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        #expect(center.keyboardApprovalBlocked)
        center.handleCommandReturn()
        #expect(center.pendingRequest?.id == "cmd-return-sensitive")
        center.actionsForPresentedRequest().deny()
        #expect(!(await blocked.value).approved)

        let ordinary = Task { await center.present(ApprovalRequest(id: "cmd-return-ordinary", toolName: "file_read",
            inputSummary: "synthetic", riskLevel: .low, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        #expect(!center.keyboardApprovalBlocked)
        center.handleCommandReturn()
        #expect((await ordinary.value).approved)
    }

    /// R3-P-03：回车作用于当前焦点项。表格覆盖用户已定规则：普通卡回车批准（由 handleReturn 决定）、
    /// 拒绝理由框聚焦时回车 = 带理由拒绝、等待时长输入框聚焦时回车交还系统、⌘回车在时长框里被吞掉。
    @Test func returnKeyOutcomeTable() {
        typealias Outcome = ApprovalPromptCenter.ReturnKeyOutcome
        func outcome(command: Bool = false, duration: Bool = false, note: Bool = false) -> Outcome {
            ApprovalPromptCenter.returnKeyOutcome(isCommand: command, durationOwnsKeyboard: duration, denialNoteFocused: note)
        }
        #expect(outcome() == .plainReturn)
        #expect(outcome(command: true) == .commandReturn)
        #expect(outcome(note: true) == .denyWithReason)
        // 理由框里 ⌘回车也只会拒绝，绝不批准。
        #expect(outcome(command: true, note: true) == .denyWithReason)
        #expect(outcome(duration: true) == .ignored)
        #expect(outcome(command: true, duration: true) == .consumed)
        #expect(outcome(duration: true, note: true) == .ignored)
    }

    /// P3：回车作用于有焦点的按钮；没有按钮焦点（或焦点在“允许”）才按卡片默认。
    @Test func returnKeyOutcomeFollowsTheFocusedButton() {
        typealias Outcome = ApprovalPromptCenter.ReturnKeyOutcome
        func outcome(_ focus: ApprovalPromptCenter.ReturnFocus?, command: Bool = false,
                     duration: Bool = false, note: Bool = false) -> Outcome {
            ApprovalPromptCenter.returnKeyOutcome(
                isCommand: command, durationOwnsKeyboard: duration, denialNoteFocused: note, focus: focus)
        }
        #expect(outcome(nil) == .plainReturn)
        #expect(outcome(.allow) == .plainReturn)
        #expect(outcome(.deny) == .denyFocused)
        #expect(outcome(.denyWithNote) == .openDenialNote)
        #expect(outcome(.viewTaskCenter) == .viewTaskCenter)
        // ⌘回车、理由框、等待时长输入框的优先级不受按钮焦点影响。
        #expect(outcome(.denyWithNote, command: true) == .commandReturn)
        #expect(outcome(.viewTaskCenter, note: true) == .denyWithReason)
        #expect(outcome(.denyWithNote, duration: true) == .ignored)
    }

    /// P3 接线：回车键到动作的完整分发（视图 onKeyPress 只做一次调用）。
    @Test func returnKeyDispatchRunsTheFocusedButtonAndNeverApprovesOnWrongFocus() async throws {
        let center = ApprovalPromptCenter()
        let first = Task { await center.present(ApprovalRequest(id: "return-dispatch-1", toolName: "file_read",
            inputSummary: "synthetic", riskLevel: .low, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        var openedNote = 0
        var viewedTaskCenter = 0
        func press(_ focus: ApprovalPromptCenter.ReturnFocus?, duration: Bool = false) -> Bool {
            center.handleReturnKey(
                isCommand: false, durationOwnsKeyboard: duration, denialNoteFocused: false, focus: focus,
                openDenialNote: { openedNote += 1 }, viewTaskCenter: { viewedTaskCenter += 1 })
        }
        // “拒绝并说明…”：打开理由框，请求仍在等用户。
        #expect(press(.denyWithNote))
        #expect(openedNote == 1 && viewedTaskCenter == 0)
        #expect(center.pendingRequest?.id == "return-dispatch-1")
        // “在任务中心查看”：执行该按钮，请求仍在等用户，没有批准。
        #expect(press(.viewTaskCenter))
        #expect(openedNote == 1 && viewedTaskCenter == 1)
        #expect(center.pendingRequest?.id == "return-dispatch-1")
        // 等待时长输入框里的回车交还系统，什么都不做。
        #expect(!press(.denyWithNote, duration: true))
        #expect(openedNote == 1)
        // “拒绝”：拒绝。
        #expect(press(.deny))
        #expect(!(await first.value).approved)

        // 没有按钮焦点：普通卡按默认批准。
        let second = Task { await center.present(ApprovalRequest(id: "return-dispatch-2", toolName: "file_read",
            inputSummary: "synthetic", riskLevel: .low, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        #expect(press(nil))
        #expect((await second.value).approved)
    }

    /// P3 视图接线（纯函数已测、焦点绑定无法在这里挂载时用源码核对）：两个按钮必须登记各自的焦点，
    /// 回车必须经 `handleReturnKey` 带上当前焦点，回退成只看“拒绝”时这里会变红。
    @Test func approvalViewBindsFocusForEveryButtonAndRoutesReturnThroughTheDispatcher() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/ApprovalPromptCenter.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains(".focused($focusedAction, equals: .deny)"))
        #expect(source.contains(".focused($focusedAction, equals: .allow)"))
        #expect(source.contains(".focused($focusedAction, equals: .denyWithNote)"))
        #expect(source.contains(".focused($focusedAction, equals: .viewTaskCenter)"))
        #expect(source.contains("center.handleReturnKey("))
        #expect(source.contains("focus: focusedAction"))
        #expect(source.contains("viewTaskCenter: onViewTaskCenter"))
        #expect(!source.contains("handleReturn(focusOnDeny: focusedAction == .deny)"))
    }

    @Test func returnOnFocusedDenyButtonDeniesAndOtherwiseApproves() async throws {
        let center = ApprovalPromptCenter()
        let focusedDeny = Task { await center.present(ApprovalRequest(id: "return-focus-deny", toolName: "file_read",
            inputSummary: "synthetic", riskLevel: .low, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        #expect(!center.keyboardApprovalBlocked)
        center.handleReturn(focusOnDeny: true)
        let denied = await focusedDeny.value
        #expect(!denied.approved)

        let focusedAllow = Task { await center.present(ApprovalRequest(id: "return-focus-allow", toolName: "file_read",
            inputSummary: "synthetic", riskLevel: .low, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(550))
        center.handleReturn(focusOnDeny: false)
        #expect((await focusedAllow.value).approved)
    }

    /// R3-P-02：请求不属于当前会话时，卡片首行写来源会话，范围不再写"当前会话"。
    @Test func approvalSummaryNamesTheOriginSessionWhenItIsNotTheCurrentOne() {
        let request = ApprovalRequest(id: "origin-summary", toolName: "file_write", inputSummary: "synthetic",
            riskLevel: .high, requiresApproval: true, approvalScope: "session")
        let own = ApprovalSummaryPresentation(request: request)
        #expect(own.originNotice == nil)
        #expect(own.scope == "范围：当前会话")
        let other = ApprovalSummaryPresentation(request: request, originSessionTitle: "整理发票")
        #expect(other.originNotice == "来自会话：《整理发票》")
        #expect(other.scope == "范围：该会话")
        #expect(!other.scope.contains("当前会话"))
        #expect(ApprovalSummaryPresentation(request: request, originSessionTitle: "  ").originNotice == "来自另一个会话")
    }

    /// R3-P-02 接线：来源会话标题由会话库按当前会话给出，三处卡片入口（弹窗、任务中心上的弹窗、行内卡）
    /// 都必须把它传给卡片，少传一处，那一处的卡片就又不写来源了。
    @Test func originSessionTitleComesFromTheStoreAndAllThreeCardEntriesPassIt() throws {
        let chat = ChatStore()
        let first = try #require(chat.activeSessionID)
        chat.newSession()
        let second = try #require(chat.activeSessionID)
        let firstTitle = try #require(chat.sessions.first { $0.id == first }?.title)
        #expect(chat.approvalOriginSessionTitle(requestSessionID: second.uuidString) == nil)
        #expect(chat.approvalOriginSessionTitle(requestSessionID: first.uuidString) == firstTitle)
        #expect(chat.approvalOriginSessionTitle(requestSessionID: UUID().uuidString) == "")
        #expect(chat.approvalOriginSessionTitle(requestSessionID: nil) == nil)
        #expect(chat.approvalOriginSessionTitle(requestSessionID: "not-a-session-id") == nil)

        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/ContentView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let entries = source.components(separatedBy: "ApprovalPromptView(").count - 1
        let passed = source.components(
            separatedBy: "bridge.chat.approvalOriginSessionTitle(requestSessionID: request.sessionID)").count - 1
        #expect(entries == 3, "弹窗、任务中心上的弹窗、行内卡片三处入口")
        #expect(passed == entries)
        // 行内卡片再把标题交给真正的卡片。
        let center = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/ApprovalPromptCenter.swift")
        #expect(try String(contentsOf: center, encoding: .utf8).contains(
            "originSessionTitle: originSessionTitle, dismissesOnDisappear: false)"))
    }

    @Test func inlineDefaultsOffAndFreshReturnCannotApprove() async {
        let center = ApprovalPromptCenter()
        #expect(!center.inlineApprovalEnabled)
        #expect(!center.usesInlinePresentation)
        let waiter = Task { await center.present(ApprovalRequest(id: "return-guard", toolName: "file_write",
            inputSummary: "synthetic", riskLevel: .high, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.pendingRequest != nil)
        center.handleReturn()
        #expect(center.pendingRequest != nil)
        center.actionsForPresentedRequest().deny()
        #expect(!(await waiter.value).approved)
    }

    @Test func interactiveTimeoutDeniesWithVisibleReason() async {
        let center = ApprovalPromptCenter()
        center.applyPersistedPresentation(inline: true, expiration: 300)
        #expect(center.expirationInterval == 300)
        let waiter = Task { await center.present(ApprovalRequest(id: "timeout-reason", toolName: "file_write",
            inputSummary: "synthetic", riskLevel: .high, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.pendingRequest != nil)
        #expect(center.pendingExpirationDisplayDeadline != nil)
        center.expirePending()
        let decision = await waiter.value
        #expect(!decision.approved && decision.status == .expired)
        #expect(decision.reason == "超时未处理，已拒绝")
    }

    @Test func denyWithNoteSendsTheNoteToTheModelAndDefaultNeverAutoDenies() async {
        let center = ApprovalPromptCenter()
        // 对齐 Claude Code：默认不自动拒绝，审批卡一直等用户。
        #expect(center.expirationInterval == 0)
        let waiter = Task { await center.present(ApprovalRequest(id: "deny-note", toolName: "file_write",
            inputSummary: "synthetic", riskLevel: .high, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.pendingRequest != nil)
        #expect(center.pendingExpirationDisplayDeadline == nil)
        center.denialNote = "  请改写 src 目录下的文件  "
        center.actionsForPresentedRequest().deny()
        let decision = await waiter.value
        #expect(!decision.approved)
        #expect(decision.reason == ApprovalPromptCenter.userDenialReason + "：请改写 src 目录下的文件")
        #expect(center.denialNote.isEmpty)
        #expect(ApprovalDecisionStatusLedger.Observation(status: decision.status, reason: decision.reason).isUserDenial)
    }

        @Test func fallbackRetainsWaiterAndOldInlineCallbacksAreStale() async {
        let center = ApprovalPromptCenter()
        center.inlineApprovalEnabled = true
        center.inlineHostAvailable = true
        let waiter = Task { await center.present(ApprovalRequest(id: "fallback", toolName: "file_write",
            inputSummary: "synthetic", riskLevel: .high, requiresApproval: true)) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.usesInlinePresentation)
        let inlineActions = center.actionsForPresentedRequest()
        center.fallBackToDialog()
        inlineActions.dismiss()
        inlineActions.approve()
        #expect(center.pendingRequest?.id == "fallback")
        #expect(!center.usesInlinePresentation)
        center.actionsForPresentedRequest().deny()
        #expect(!(await waiter.value).approved)
    }

    @Test func unattendedFileApprovalCannotCreateSessionPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unattended-permission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let center = ApprovalPromptCenter()
        center.inlineApprovalEnabled = true
        center.inlineHostAvailable = true
        let request = ApprovalRequest(
            id: "unattended-write", toolName: "file_write", inputSummary: "synthetic",
            riskLevel: .high, requiresApproval: true, sessionID: "unattended-session",
            policyRevision: "revision", grantEpoch: "epoch",
            filePreview: ApprovalFilePreview.capture(tool: "file_write", input: ["path": file.path, "content": "next"])
        )
        let pending = Task {
            await ApprovalExecutionOriginContext.$current.withValue(.scheduledTask) {
                await center.present(request)
            }
        }
        defer { center.dismissPending(); pending.cancel() }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        try #require(center.pendingExecutionOrigin == .scheduledTask)
        center.rememberSameKindInSession = true
        center.resolve(approved: true, confirmed: true)
        #expect((await pending.value).approved)
        #expect(center.temporaryPermissionRows(sessionID: "unattended-session").isEmpty)
    }

    @Test func sameSessionPermissionNeverCrossesConversationOrFileChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal18-approval-ui-" + UUID().uuidString)
        #expect(root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let center = ApprovalPromptCenter()
        center.inlineApprovalEnabled = true
        center.inlineHostAvailable = true
        func request(_ id: String, session: String, revision: String = "r1", epoch: String = "e1") -> ApprovalRequest {
            ApprovalRequest(id: id, toolName: "file_write", inputSummary: "synthetic", riskLevel: .high,
                requiresApproval: true, sessionID: session, policyRevision: revision, grantEpoch: epoch,
                filePreview: ApprovalFilePreview.capture(tool: "file_write", input: ["path": file.path, "content": "next"]))
        }
        let first = Task { await center.present(request("first", session: "one")) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        center.rememberSameKindInSession = true
        center.resolve(approved: true, confirmed: true)
        #expect((await first.value).approved)
        // Same file, same preview, same session: explicit remembered consent.
        #expect((await center.present(request("same", session: "one"))).approved)
        for (id, revision, epoch) in [("revision", "r2", "e1"), ("epoch", "r1", "e2"), ("missing", "", "")] {
            let revised = Task { await center.present(request(id, session: "one", revision: revision, epoch: epoch)) }
            for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
            #expect(center.pendingRequest?.id == id)
            center.actionsForPresentedRequest().deny()
            #expect(!(await revised.value).approved)
        }
        let other = Task { await center.present(request("other", session: "two")) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.pendingRequest?.sessionID == "two")
        center.actionsForPresentedRequest().deny()
        #expect(!(await other.value).approved)
        try Data("different".utf8).write(to: file)
        let changed = Task { await center.present(request("changed", session: "one")) }
        for _ in 0..<100 where center.pendingRequest == nil { await Task.yield() }
        #expect(center.pendingRequest?.id == "changed")
        center.actionsForPresentedRequest().deny()
        #expect(!(await changed.value).approved)
    }
}
