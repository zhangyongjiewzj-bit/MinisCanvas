import AppKit
import ApplicationServices
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// D-AX-03: the complete production three-column tree, rather than a detached
/// Composer delegate, owns the actual key-view loop and AX focus projection.
/// This suite is native-host-only and must use the existing exclusive UI lease.
@Suite("Three-column native keyboard focus 2442", .serialized)
@MainActor
struct ThreeColumnKeyboardFocusNative2442Tests {
    @Test("Tab and Shift-Tab traverse sidebar, Composer, panel and toolbar without trapping focus",
          .enabled("Requires the host's keyboard navigation setting; this test does not change system settings") {
              await MainActor.run { NSApp?.isFullKeyboardAccessEnabled == true }
          })
    func mountedThreeColumnFocusLoopIsReversible() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        let window = fixture.window
        try #require(window.isKeyWindow, "native UI host did not own the key window")

        let controlIdentifiers: Set<String> = [
            "toolbar.sidebar.session.toggle",
            "toolbar.sidebar.context.toggle",
            "chat.sidebar.archived.toggle",
            "context.panel.tab.node",
            "context.panel.close",
            "composer.model",
            "composer.send"
        ]
        var landmarks = Set<String>()
        for identifier in controlIdentifiers {
            let control = try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier),
                                       "production control absent: \(identifier)")
            #expect(NativeConsumerOwnedAX.role(control) == .button,
                    "production control is not an AX button: \(identifier)")
            let isEnabled: Bool = try #require(
                NativeConsumerOwnedAX.enabled(control) as Bool?,
                "production control enabled state unreadable: \(identifier)"
            )
            if isEnabled {
                landmarks.insert(identifier)
            }
        }
        try #require(landmarks.contains("chat.sidebar.archived.toggle")
                     && landmarks.contains("context.panel.tab.node")
                     && landmarks.contains("toolbar.sidebar.session.toggle"),
                     "three-column landmarks were not enabled")

        let editor = try #require(nativeEditor(in: fixture.controller.view),
                                  "production Composer NSTextView was not mounted")
        #expect(window.makeFirstResponder(editor))
        #expect(window.firstResponder === editor)
        #expect(fixture.bridge.chat.draftText == "焦点检查")

        let forward = try traverse(window: window, editor: editor,
                                   landmarks: landmarks, reverse: false)
        let backward = try traverse(window: window, editor: editor,
                                    landmarks: landmarks, reverse: true)
        #expect(forward.returnedToEditor, "Tab did not return to Composer within its bounded native loop")
        #expect(backward.returnedToEditor, "Shift-Tab did not return to Composer within its bounded native loop")
        #expect(landmarks.isSubset(of: forward.visited),
                "Tab skipped one or more sidebar/panel/toolbar controls: \(landmarks.subtracting(forward.visited))")
        #expect(landmarks.isSubset(of: backward.visited),
                "Shift-Tab skipped one or more sidebar/panel/toolbar controls: \(landmarks.subtracting(backward.visited))")
        #expect(forward.orderedLandmarks == Array(backward.orderedLandmarks.reversed()),
                "Tab and Shift-Tab did not reverse the observed control order")
        #expect(fixture.bridge.chat.draftText == "焦点检查",
                "focus traversal must not mutate or send the Composer draft")
        print("THREE_COLUMN_FOCUS_NATIVE forward=\(forward.steps) backward=\(backward.steps) landmarks=\(landmarks.count) reverseVisited=\(backward.visited.count)")
    }

    @Test("one continuous pinned sidebar region is not interleaved with search or toolbar in either Tab direction",
          .enabled("Requires the host's keyboard navigation setting; this test does not change system settings") {
              await MainActor.run { NSApp?.isFullKeyboardAccessEnabled == true }
          })
    func pinnedSidebarRowsRemainOneReversibleTabRegion() throws {
        let fixture = try makeFixture()
        defer { close(fixture) }
        var pinned = Set<String>()
        // Use the real session actions after the production tree is mounted,
        // as when existing sessions become pinned in the ordinary sidebar.
        for number in 1...4 {
            let session = fixture.bridge.chat.applyNewSession(title: "AX03 owned pinned \(number)")
            fixture.bridge.chat.setPinned(true, sessionID: session)
            pinned.insert("chat.session.row.\(session.uuidString)")
        }
        fixture.bridge.chat.draftText = "焦点检查"
        for _ in 0..<30 {
            fixture.window.layoutIfNeeded()
            fixture.controller.view.layoutSubtreeIfNeeded()
            fixture.controller.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        try #require(fixture.window.isKeyWindow)
        let outside: Set<String> = [
            "open-task-center", "session.search.input",
            "toolbar.sidebar.session.toggle", "toolbar.sidebar.context.toggle",
            "chat.sidebar.archived.toggle", "context.panel.tab.node", "context.panel.close",
            "composer.model", "composer.send"
        ]
        let landmarks = pinned.union(outside)
        for identifier in pinned.union(["open-task-center", "session.search.input"]) {
            _ = try #require(NativeConsumerOwnedAX.find(in: fixture.window, identifier: identifier),
                             "owned production focus target absent: \(identifier)")
        }
        let editor = try #require(nativeEditor(in: fixture.controller.view))
        try #require(fixture.window.makeFirstResponder(editor))
        try #require(fixture.window.firstResponder === editor)
        let forward = try traverse(window: fixture.window, editor: editor,
            landmarks: landmarks, reverse: false)
        let backward = try traverse(window: fixture.window, editor: editor,
            landmarks: landmarks, reverse: true)
        #expect(forward.returnedToEditor && backward.returnedToEditor,
                "both native directions must close through the Composer")
        #expect(pinned.isSubset(of: forward.visited) && pinned.isSubset(of: backward.visited),
                "a missing pinned row cannot stand in for a contiguous focus region")
        func classify(_ steps: [Set<String>]) -> [String] {
            var order: [String] = []
            for identifiers in steps {
                let inside = identifiers.intersection(pinned)
                if inside.count == 1, let session = inside.first {
                    // Adjacent controls belonging to the same pinned row are
                    // one region. Never collapse or discard an outside step.
                    if order.last != session { order.append(session) }
                } else {
                    order.append("outside") // Includes unlabelled/unknown focus.
                }
            }
            return order
        }
        let forwardRegions = classify(forward.focusSteps)
        let backwardRegions = classify(backward.focusSteps)
        for order in [forwardRegions, backwardRegions] {
            let positions = order.indices.filter { pinned.contains(order[$0]) }
            try #require(positions.count == 4, "all four owned rows must be traversed exactly once")
            let first = try #require(positions.first)
            let last = try #require(positions.last)
            #expect(last - first + 1 == 4,
                    "a continuous pinned sidebar region was interrupted by another focus region: \(order)")
        }
        #expect(forward.orderedLandmarks == Array(backward.orderedLandmarks.reversed()),
                "Shift-Tab must reverse the same native control sequence")
        // The final observed step in each successful loop is the Composer;
        // compare the intervening actual steps in opposite directions.
        #expect(Array(forwardRegions.dropLast()) == Array(backwardRegions.dropLast().reversed()),
                "Shift-Tab must reverse all observed regions, including unknown outside controls")
        #expect(fixture.bridge.chat.draftText == "焦点检查")
        #expect(!fixture.bridge.chat.hasStreamingTasksForSafety)
    }

    private struct Traversal {
        let returnedToEditor: Bool
        let steps: Int
        let visited: Set<String>
        let orderedLandmarks: [String]
        let focusSteps: [Set<String>]
    }

    private func traverse(
        window: NSWindow, editor: ComposerPasteAwareTextView,
        landmarks: Set<String>, reverse: Bool
    ) throws -> Traversal {
        var visited = Set<String>()
        var orderedLandmarks: [String] = []
        var focusSteps: [Set<String>] = []
        for step in 1...96 {
            try sendTab(to: window, reverse: reverse)
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            if window.firstResponder === editor {
                focusSteps.append([]) // The real Composer is an outside region.
                #expect(step > 1, "first Tab direction did not leave the Composer")
                return Traversal(returnedToEditor: step > 1, steps: step,
                                 visited: visited, orderedLandmarks: orderedLandmarks, focusSteps: focusSteps)
            }
            let identifiers = try focusedIdentifiers(in: window)
            focusSteps.append(identifiers)
            visited.formUnion(identifiers)
            let matches = identifiers.intersection(landmarks)
            try #require(matches.count <= 1, "focused AX node maps to multiple landmarks")
            if let landmark = matches.first, orderedLandmarks.last != landmark {
                orderedLandmarks.append(landmark)
            }
        }
        return Traversal(returnedToEditor: false, steps: 96,
                         visited: visited, orderedLandmarks: orderedLandmarks, focusSteps: focusSteps)
    }

    private func sendTab(to window: NSWindow, reverse: Bool) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: reverse ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: reverse ? "\u{19}" : "\t",
            charactersIgnoringModifiers: reverse ? "\u{19}" : "\t",
            isARepeat: false,
            keyCode: 48
        ))
        window.sendEvent(event)
    }

    /// Walk only the focused element's parent chain in this PID and require
    /// the exact owned window. An AX timeout or foreign window is unobservable,
    /// never a successful traversal sample.
    private func focusedIdentifiers(in window: NSWindow) throws -> Set<String> {
        let application = AXUIElementCreateApplication(getpid())
        let focused = try #require(axElement(NativeConsumerOwnedAX.attribute(
            application, kAXFocusedUIElementAttribute as CFString
        )), "focused AX element unreadable")
        var identifiers = Set<String>()
        var current: AXUIElement? = focused
        var reachedOwner = false
        for _ in 0..<32 {
            guard let node = current else { break }
            if let identifier = NativeConsumerOwnedAX.attribute(
                node, kAXIdentifierAttribute as CFString
            ) as? String {
                identifiers.insert(identifier)
                if identifier == window.accessibilityIdentifier() {
                    reachedOwner = true
                    break
                }
            }
            current = axElement(NativeConsumerOwnedAX.attribute(
                node, kAXParentAttribute as CFString
            ))
        }
        if !reachedOwner,
           let owner = axElement(NativeConsumerOwnedAX.attribute(
               focused, kAXWindowAttribute as CFString
           )),
           let identifier = NativeConsumerOwnedAX.attribute(
               owner, kAXIdentifierAttribute as CFString
           ) as? String {
            reachedOwner = identifier == window.accessibilityIdentifier()
        }
        try #require(reachedOwner, "AX focus left the exact native host window")
        return identifiers
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private struct Fixture {
        let root: URL
        let defaultsSuite: String
        let defaults: UserDefaults
        let bridge: BridgeStore
        let controller: NSHostingController<AnyView>
        let window: NSWindow
    }

    private func makeFixture() throws -> Fixture {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.minisCoreDirectory.appendingPathComponent(
            "ax03-native-2442-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsSuite = "ax03-native-2442-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.set(MainPane.chat.rawValue, forKey: "minisCanvas.mainPane")
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions,
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.layoutMode = .split
        // Keep the real send button enabled so the traversal observes an
        // actionable Composer control without dispatching a message.
        bridge.chat.draftText = "焦点检查"
        let controller = NSHostingController(rootView: AnyView(ContentView(bridge: bridge)))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("AX03-ThreeColumn-2442")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        NativeTestHostLifecycle.bind(lease, to: window)
        window.setAccessibilityIdentifier("ax03-three-column-2442-\(UUID().uuidString)")
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_280, height: 760))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<30 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            let deadline = Date(timeIntervalSinceNow: 0.01)
            if let event = NSApp.nextEvent(matching: .any, until: deadline,
                inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        NativeTestHostLifecycle.observe(window, phase: "sampled")
        print("THREE_COLUMN_FOCUS_HOST keyboardAccessEnabled=\(NSApp.isFullKeyboardAccessEnabled) isActive=\(NSApp.isActive) isKey=\(window.isKeyWindow)")
        return Fixture(root: root, defaultsSuite: defaultsSuite, defaults: defaults,
                       bridge: bridge, controller: controller, window: window)
    }

    private func close(_ fixture: Fixture) {
        fixture.window.orderOut(nil)
        fixture.window.contentViewController = nil
        fixture.window.close()
        NativeTestHostLifecycle.end(fixture.window)
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuite)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func nativeEditor(in view: NSView) -> ComposerPasteAwareTextView? {
        for child in view.subviews {
            if let editor = child as? ComposerPasteAwareTextView { return editor }
            if let editor = nativeEditor(in: child) { return editor }
        }
        return nil
    }
}
