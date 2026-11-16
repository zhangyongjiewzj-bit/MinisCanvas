import AppKit
import Carbon

/// The process delegate owns this registration from launch through termination.
@MainActor
final class AppQuitAppleEventRouter: NSObject {
    private let onUserQuit: @MainActor () -> Void
    private let onSystemQuit: @MainActor () -> Void
    private var installed = false

    init(onUserQuit: @escaping @MainActor () -> Void,
         onSystemQuit: @escaping @MainActor () -> Void) {
        self.onUserQuit = onUserQuit
        self.onSystemQuit = onSystemQuit
        super.init()
    }

    func install() {
        guard !installed else { return }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
        installed = true
    }

    func uninstall() {
        guard installed else { return }
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
        installed = false
    }

    static func isSystemTerminationReason(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return [OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart),
                OSType(kAEReallyLogOut), OSType(kAELogOut)].contains(reason)
    }

    func route(reason: OSType?) {
        if Self.isSystemTerminationReason(reason) { onSystemQuit() }
        else { onUserQuit() }
    }

    static func quitReason(in event: NSAppleEventDescriptor) -> OSType? {
        let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        return reason?.enumCodeValue
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor,
                                  withReplyEvent reply: NSAppleEventDescriptor) {
        // AERegistry declares kAEQuitReason as an event parameter. Accept its
        // attribute spelling too, without changing or retaining the raw event.
        route(reason: Self.quitReason(in: event))
    }
}
