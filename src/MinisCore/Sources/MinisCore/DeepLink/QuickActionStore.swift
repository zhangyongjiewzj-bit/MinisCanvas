import Foundation

// MARK: - QuickAction

/// A home-screen / menu quick action. Each action carries a `deepLinkURL`
/// that `DeepLinkRouter` understands, so performing an action is exactly the
/// same code path as handling a deep link.
public struct QuickAction: Identifiable, Codable, Equatable, Sendable {
    /// Stable identifier (also used to look the action up in `perform`).
    public let id: String
    /// User-facing title, e.g. "新会话".
    public var title: String
    /// SF Symbol name for the icon (rendered by the host app).
    public var icon: String
    /// `miniscanvas://` URL dispatched when the action is performed.
    public var deepLinkURL: String

    public init(id: String, title: String, icon: String, deepLinkURL: String) {
        self.id = id
        self.title = title
        self.icon = icon
        self.deepLinkURL = deepLinkURL
    }
}

// MARK: - QuickActionStore

/// Registry of the app's preset quick actions.
///
/// Unlike the OpenMinis `QuickActionRouter` (which owns UIKit shortcut-item
/// registration and a `newChatTrigger` wake-up counter), the macOS store is a
/// thin, platform-free list: `listActions()` for UI, `perform(actionID:)` to
/// run one by routing its `deepLinkURL` through `DeepLinkRouter`.
public final class QuickActionStore: @unchecked Sendable {

    public static let shared = QuickActionStore()

    /// Preset quick actions shipped with the app.
    public static let defaultActions: [QuickAction] = [
        QuickAction(
            id: "new-chat",
            title: "新会话",
            icon: "bubble.left.and.bubble.right",
            deepLinkURL: "miniscanvas://new-session"
        ),
        QuickAction(
            id: "quick-pipeline",
            title: "一键流水线",
            icon: "bolt.fill",
            deepLinkURL: "miniscanvas://pipeline"
        ),
        QuickAction(
            id: "open-settings",
            title: "打开设置",
            icon: "gearshape",
            deepLinkURL: "miniscanvas://settings"
        ),
    ]

    private let lock = NSLock()
    private var actions: [QuickAction]

    public init(actions: [QuickAction] = QuickActionStore.defaultActions) {
        self.actions = actions
    }

    /// All registered actions, in display order.
    public func listActions() -> [QuickAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    /// Look up an action by id. `nil` when no action has that id.
    public func action(id: String) -> QuickAction? {
        lock.lock()
        defer { lock.unlock() }
        return actions.first { $0.id == id }
    }

    /// Perform the action with `actionID` by routing its `deepLinkURL`
    /// through `router`. Returns `false` when the id is unknown or the URL
    /// is not a supported deep link.
    @discardableResult
    public func perform(actionID: String, using router: DeepLinkRouter = .shared) -> Bool {
        guard let action = action(id: actionID),
              let url = URL(string: action.deepLinkURL),
              // Resolve the persisted URL first. Unsupported links and links
              // that require Policy/Approval must not dispatch opaquely.
              DeepLinkRouter.parseResult(url: url).isDispatchable else { return false }
        return router.handle(url: url)
    }

    /// Resolve a persisted quick action while preserving an explicit
    /// unsupported/authorization-required outcome for the host UI.
    public func resolution(id: String) -> DeepLinkParseResult? {
        guard let action = action(id: id),
              let url = URL(string: action.deepLinkURL) else { return nil }
        return DeepLinkRouter.parseResult(url: url)
    }
}
