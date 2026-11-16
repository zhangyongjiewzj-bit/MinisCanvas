import AppKit

/// The settings presentation keeps its existing SwiftUI layout. This binding
/// supplies the native resize policy only after its own window is an actual
/// sheet; it neither replaces a delegate nor changes any parent window.
@MainActor
final class SettingsSheetWindowSizing: NSObject {
    static let minimumContentSize = NSSize(width: SettingsLayoutPolicy.minimumSupportedWidth, height: 520)
    static let maximumContentSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private weak var window: NSWindow?
    private weak var parentWindow: NSWindow?
    private var correctingContentSize = false

    func bind(to newWindow: NSWindow?) {
        if window === newWindow {
            applyToBoundSheet()
            return
        }
        if let window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.willStartLiveResizeNotification, object: window
            )
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: window
            )
        }
        if let parentWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: parentWindow
            )
        }
        window = newWindow
        parentWindow = nil
        guard let newWindow else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: newWindow
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundWindowResized(_:)),
            name: NSWindow.willStartLiveResizeNotification, object: newWindow
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundWindowResized(_:)),
            name: NSWindow.didResizeNotification, object: newWindow
        )
        applyToBoundSheet()
        // SwiftUI can attach the content view before AppKit assigns sheetParent.
        // Retry once after attachment, without looking up another/global window.
        Task { @MainActor [weak self, weak newWindow] in
            guard let self, let newWindow, self.window === newWindow else { return }
            self.applyToBoundSheet()
        }
    }

    @objc private func boundWindowBecameKey(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow,
              notificationWindow === window else { return }
        applyToBoundSheet()
    }

    @objc private func boundWindowResized(_ notification: Notification) {
        guard !correctingContentSize,
              let resizedWindow = notification.object as? NSWindow,
              resizedWindow === window else { return }
        // The SwiftUI-hosted sheet may be attached after the one deferred bind
        // or may reset its native bounds while a drag is in progress.
        applyToBoundSheet()
    }

    @objc private func parentWindowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === parentWindow else { return }
        applyToBoundSheet()
    }

    private func applyToBoundSheet() {
        guard let window, let parent = window.sheetParent else { return }
        if parentWindow !== parent {
            if let parentWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResizeNotification, object: parentWindow
                )
            }
            parentWindow = parent
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentWindowDidResize(_:)),
                name: NSWindow.didResizeNotification, object: parent
            )
        }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        if window.contentMinSize != Self.minimumContentSize {
            window.contentMinSize = Self.minimumContentSize
        }
        // The 720pt ideal remains for a roomy parent. A 600–719pt parent
        // caps this sheet to its own content width, including after a resize.
        let parentWidth = parent.contentLayoutRect.width
        let compactMaximum = max(Self.minimumContentSize.width, parentWidth)
        let maximum = parentWidth < 720
            ? NSSize(width: compactMaximum, height: Self.maximumContentSize.height)
            : Self.maximumContentSize
        if window.contentMaxSize != maximum {
            window.contentMaxSize = maximum
        }
        let current = window.contentRect(forFrameRect: window.frame).size
        let bounded = NSSize(
            width: min(max(current.width, Self.minimumContentSize.width), maximum.width),
            height: max(current.height, Self.minimumContentSize.height)
        )
        if current != bounded {
            correctingContentSize = true
            defer { correctingContentSize = false }
            window.setContentSize(bounded)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
