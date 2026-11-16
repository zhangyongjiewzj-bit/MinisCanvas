import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Task center -> residual-worktree panel (a sheet) -> the panel's own
/// approval sheet. The approval buttons must keep a real, pressable AX frame
/// that lies inside that approval sheet. Run only under the existing exclusive
/// native UI host/lease, like the other NSHostingController-based consumers.
///
/// Sheet chain mounted here (three attached sheets, as in the product):
///   host NSWindow
///     -> sheet 1: stand-in for the task-center sheet (empty 700x500 content)
///       -> sheet 2: the real P03CleanupAppView panel
///         -> sheet 3: the panel's own ApprovalPromptView sheet
/// If AppKit refuses a third attached sheet in this environment the chain wait
/// below fails with its own message; it is never silently reduced to two layers.
@Suite("P03 residual panel nested approval sheet layout", .serialized)
@MainActor
struct P03CleanupResidualApprovalSheetLayoutTests {
    /// Same value as `.frame(minHeight: 280)` on the approval sheet content in
    /// P03CleanupAppView. Keep the two in step.
    private let approvalSheetMinHeight: CGFloat = 280

    private func request() -> ApprovalRequest {
        // requiresSecondConfirmation: Allow must only open the confirmation
        // step, so `approval.confirm` appears after it.
        ApprovalRequest(
            id: "nested-call", requestID: "nested-request", callID: "nested-call",
            toolName: "file_read", inputSummary: "synthetic nested approval request",
            riskLevel: .high, requiresApproval: true, requiresSecondConfirmation: true,
            sessionID: "nested-session", turnID: 7, taskID: "nested-task",
            attemptID: "nested-attempt", approvalScope: "nested-scope",
            composerMode: "manual", messageID: "nested-message",
            identityDigest: "nested-digest", expiresAt: Date().addingTimeInterval(60)
        )
    }

    private func observe(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            // Same wait as ApprovalPromptCenterSemanticTests.observe: yield the
            // main actor; RunLoop.run is unavailable from async contexts.
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Attached sheets from the host down: [sheet1, sheet2, ...].
    private func sheetChain(from window: NSWindow) -> [NSWindow] {
        var chain: [NSWindow] = []
        var current = window
        while let next = current.attachedSheet { chain.append(next); current = next }
        return chain
    }

    private func appKitFrame(ofAX element: AnyObject) -> CGRect? {
        guard let frame = NativeConsumerOwnedAX.frame(element) else { return nil }
        return UF03AXScreenCoordinates.appKitFrame(
            position: frame.origin, size: frame.size, zeroScreenFrame: NSScreen.screens.first?.frame)
    }

    @Test("Allow and Confirm stay inside a tall-enough nested approval sheet, at least 20pt tall and pressable")
    func nestedApprovalButtonsKeepAXFrameAndPress() async throws {
        let center = ApprovalPromptCenter()
        let controller = P03CleanupAppController(platformTrash: { _ in
            throw GitChildWorktreeCleanupService.CleanupError.rejected("not used")
        })
        let lease = NativeTestHostLifecycle.begin("P03ResidualApprovalLayout")
        let hosting = NSHostingController(rootView: Color.clear.frame(width: 700, height: 500)
            .sheet(isPresented: .constant(true)) {
                Color.clear.frame(width: 700, height: 500)
                    .sheet(isPresented: .constant(true)) {
                        P03CleanupAppView(controller: controller, approvalCenter: center, shortcutStore: nil)
                    }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.setAccessibilityIdentifier("p03-residual-approval-layout-\(lease.uuidString)")
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.makeKeyAndOrderFront(nil)
        // End the sheets innermost first, so no window is left with an attached
        // sheet. Idempotent: the happy path calls it before its final expects.
        func endAllSheets() {
            for sheet in sheetChain(from: window).reversed() {
                (sheet.sheetParent ?? window).endSheet(sheet)
            }
        }
        defer {
            center.stopGeneration()
            endAllSheets()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }

        try #require(await observe { sheetChain(from: window).count == 2 },
                     "task-center stand-in and residual panel sheets must both attach")
        let pending = Task { await center.present(request()) }
        defer { pending.cancel() }
        try #require(await observe { center.pendingRequest != nil && center.isPromptPresented })
        try #require(await observe { sheetChain(from: window).count == 3 },
                     "the panel's approval sheet must attach as the third sheet")
        let approvalSheet = try #require(sheetChain(from: window).last)
        try #require(await observe { NativeAppWideAXLookup.find(identifier: "approval.allow") != nil },
                     "approval.allow must be findable in the nested approval sheet")
        #expect(approvalSheet.frame.height >= approvalSheetMinHeight,
                "approval sheet too short: \(approvalSheet.frame)")
        // Keep the 0.5s new-modal guard of the approval sheet intact.
        try await Task.sleep(for: .milliseconds(550))

        func check(_ element: AnyObject, name: String) throws {
            let frame = try #require(NativeConsumerOwnedAX.frame(element), "\(name) AX frame missing")
            #expect(frame.height >= 20, "\(name) frame too small: \(frame)")
            let inAppKit = try #require(appKitFrame(ofAX: element), "\(name) frame not convertible")
            let sheetFrame = approvalSheet.frame.insetBy(dx: -1, dy: -1)
            #expect(sheetFrame.contains(inAppKit),
                    "\(name) AX frame \(inAppKit) is not inside its approval sheet \(approvalSheet.frame)")
        }

        let allow = try #require(NativeAppWideAXLookup.find(identifier: "approval.allow"))
        try check(allow, name: "approval.allow")
        #expect(NativeConsumerOwnedAX.press(allow))
        try #require(await observe { center.awaitingConfirmation })

        try #require(await observe { NativeAppWideAXLookup.find(identifier: "approval.confirm") != nil },
                     "approval.confirm must be findable after Allow")
        // Allow resets the card's presentation time; confirm needs another 0.5s.
        try await Task.sleep(for: .milliseconds(550))
        let confirm = try #require(NativeAppWideAXLookup.find(identifier: "approval.confirm"))
        try check(confirm, name: "approval.confirm")
        #expect(NativeConsumerOwnedAX.press(confirm))
        try #require(await observe { center.pendingRequest == nil })
        _ = await pending.value

        endAllSheets()
        #expect(sheetChain(from: window).isEmpty, "all three layers must be detached at the end")
        #expect(window.attachedSheet == nil && window.sheets.isEmpty)
    }
}
