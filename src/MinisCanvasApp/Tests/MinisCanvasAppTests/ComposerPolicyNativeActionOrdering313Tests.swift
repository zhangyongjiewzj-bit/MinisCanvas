import AppKit
import CoreFoundation
import Testing
@testable import MinisCanvasApp

/// D-POLICY-01/06/07, UF03: lifecycle controls, not a substitute for the
/// existing real AppKit mouse/keyboard/accessibility tracking regression.
@Suite("UF03 native item action ordering")
@MainActor
struct ComposerPolicyNativeActionOrdering313Tests {
    @Test("An item action after tracking ends commits before the closing turn")
    func itemActionBeforeClosingTurnCommitsOnce() throws {
        let fixture = NativeActionOrderingFixture()
        defer { fixture.close() }
        #expect(fixture.button.performNativeOwnedChoice { _ in false })
        fixture.beginTracking()
        fixture.button.selectItem(at: 2) // Post-selection precondition, not an action witness.
        fixture.endTracking()
        // NSMenu dispatches its actual will/didSendAction notifications and
        // concrete item's selector; no fake captureNativeChoice authorizes it.
        fixture.menu.performActionForItem(at: 2)
        #expect(fixture.itemActions == 1)
        #expect(fixture.forwardedActions == 1)
        #expect(fixture.capturedIndex == 2)
        #expect(fixture.button.committedSelectionIndex == nil)
        #expect(fixture.menu.chosenItem == nil)
        fixture.menu.performActionForItem(at: 2)
        #expect(fixture.itemActions == 2)
        #expect(fixture.forwardedActions == 1)
    }

    @Test("Late tracking and a real item action cannot revive a closed opening")
    func itemActionAfterClosingTurnIsRejected() throws {
        let fixture = NativeActionOrderingFixture()
        defer { fixture.close() }
        #expect(fixture.button.performNativeOwnedChoice { _ in false })
        // Drive the same default-mode boundary used by production. No tracking
        // began, so its action lease must close rather than wait indefinitely.
        _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
        fixture.beginTracking()
        fixture.button.selectItem(at: 2)
        fixture.endTracking()
        fixture.menu.performActionForItem(at: 2)
        // Distinguishes a native menu action from a binding-owner forward:
        // this is the action=1 / forwarding=0 counterexample seen in c4a raw.
        #expect(fixture.itemActions == 1)
        #expect(fixture.forwardedActions == 0)
        #expect(fixture.capturedIndex == nil)
        #expect(fixture.button.committedSelectionIndex == nil)
        #expect(fixture.menu.chosenItem == nil)
    }
}

@MainActor
private final class NativeActionOrderingFixture: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    let button = ComposerPolicyIdentityButton(frame: NSRect(x: 20, y: 20, width: 160, height: 30),
        pullsDown: false)
    let menu = ComposerPolicyChoiceMenu(title: "Composer 工作量")
    private(set) var itemActions = 0
    private(set) var forwardedActions = 0
    private(set) var capturedIndex: Int?

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        button.menu = menu
        button.addItems(withTitles: ["低", "标准", "高"])
        button.bindIdentity(titles: button.itemTitles)
        button.selectItem(at: 1)
        button.target = self
        button.action = #selector(capture(_:))
        window.contentView?.addSubview(button)
        window.orderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemAction(_:)),
            name: NSMenu.didSendActionNotification, object: menu)
    }

    func beginTracking() {
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    }

    func endTracking() {
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    }

    @objc private func itemAction(_ notification: Notification) { itemActions += 1 }

    @objc private func capture(_ sender: NSPopUpButton) {
        forwardedActions += 1
        guard button.captureNativeSelectionAction() else { return }
        capturedIndex = button.committedSelectionIndex
        button.completeNativeSelectionAction()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        menu.cancelTracking()
        window.close()
    }
}
