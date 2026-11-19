import Foundation

// MARK: - DeepLinkAction

/// A parsed `miniscanvas://` deep link, normalized into a typed action.
///
/// Concept reference: OpenMinis `DeepLinkRouter` (URL scheme → navigation
/// action), adapted for the macOS MinisCanvas app. Actions are dispatched by
/// `DeepLinkRouter` to the registered handler; the host app decides what each
/// action means (open a window, create a session, etc.).
public enum DeepLinkAction: Equatable, Sendable {
    /// `miniscanvas://session/<id>` — open an existing session.
    case openSession(id: String)
    /// `miniscanvas://new-session` — create a fresh session.
    case newSession
    /// `miniscanvas://pipeline` — start the one-click pipeline.
    case createPipeline
    /// `miniscanvas://settings[/<id>]` — open Settings, optionally at a pane.
    /// F22（P1-2）：`?pane=<id>` query 等价于路径段（路径优先）。
    case openSettings(id: String?)
    /// `miniscanvas://run/<name>` — run a named workflow (id or 模板名;
    /// resolved via `WorkflowStore`, see `resolveWorkflow`).
    /// F22（P1-2）：`input` 携带 `?input=<text>` query —— 工作流首个必需输入，
    /// 消费方见 DeepLinkHandler.runWorkflow（旧 2 参构造已迁移为 input: nil）。
    case runWorkflow(name: String, input: String?)
    /// `miniscanvas://prompt/<text>` — prefill and send a prompt.
    /// F22（P1-2）：`session` 携带 `?session=<id>` query —— 先切换到该会话再发送；
    /// 空路径时 text 回落 `?text=<text>` query。
    case sendPrompt(text: String, session: String?)

    /// Actions that can execute work or mutate user state must be surfaced to
    /// the host's Policy/Approval seam before dispatch.
    public var requiresAuthorization: Bool {
        switch self {
        case .createPipeline, .runWorkflow, .sendPrompt:
            return true
        case .openSession, .newSession, .openSettings:
            return false
        }
    }
}

/// Result of parsing a deep link. The typed action is retained for callers
/// that need to explain or request approval; only `.supported` is dispatchable.
public enum DeepLinkParseDisposition: String, Sendable, Equatable {
    case supported
    case unsupported
    case authorizationRequired
}

public struct DeepLinkParseResult: Sendable, Equatable {
    public let disposition: DeepLinkParseDisposition
    public let action: DeepLinkAction?
    public let reason: String?

    public init(
        disposition: DeepLinkParseDisposition,
        action: DeepLinkAction? = nil,
        reason: String? = nil
    ) {
        self.disposition = disposition
        self.action = action
        self.reason = reason
    }

    public var isDispatchable: Bool {
        disposition == .supported && action != nil
    }
}

// MARK: - DeepLinkRouter

/// Parses `miniscanvas://` URLs into `DeepLinkAction`s and forwards them to
/// the registered handler.
///
/// On macOS the URL arrives from the app's launch arguments
/// (`--open-url <url>`) or an `openURL` event; the host app registers one
/// handler at startup:
///
///     DeepLinkRouter.shared.register { action in
///         switch action { ... }
///     }
///
/// Supported URLs (host-based, aliases accepted):
///   miniscanvas://session/<id>            (alias: sessions/<id>)
///   miniscanvas://new-session             (aliases: newSession, new)
///   miniscanvas://pipeline                (aliases: create-pipeline, createPipeline)
///   miniscanvas://settings[/<id>]
///   miniscanvas://run/<name>              (aliases: workflow, run-workflow)
///   miniscanvas://prompt/<text>           (alias: send-prompt)
///
/// A path-only fallback (`miniscanvas:///session/<id>`) is accepted too.
///
/// D1-fix 兼容：旧链接使用 `minis://` 前缀（如 `minis://run/manju-full`），
/// 解析时同样接受（见 `legacySchemes`），保证历史深链/旧数据不失效。
public final class DeepLinkRouter: @unchecked Sendable {

    public static let shared = DeepLinkRouter()

    /// The canonical URL scheme this router accepts (lowercased).
    public static let scheme = "miniscanvas"

    /// Legacy scheme also accepted (D1-fix): pre-统一 构建里 QuickAction /
    /// 模板 / 测试曾发出 `minis://` 深链（如 `minis://run/manju-full`），
    /// 且 macOS 已为该 scheme 弹过「未设定应用程序」——注册 + 解析兜底，
    /// 让旧链接在新包上照常可用，不再弹窗。
    public static let legacySchemes: Set<String> = ["minis"]

    /// URL and component bounds keep a pasted document or malformed external
    /// event from becoming an unbounded command/deep-link payload.
    public static let maxURLLength = 16_384
    private static let maxSegmentCount = 32
    private static let maxComponentLength = 256
    /// 提示词文本（prompt 路径或 ?text=）可以比一般组件更长。
    private static let maxPromptComponentLength = 4_096
    private static let maxPayloadLength = 4_096

    private let lock = NSLock()
    private var handler: ((DeepLinkAction) -> Void)?

    public init() {}

    /// Register the single handler that receives every successfully parsed
    /// action. Replaces any previously registered handler.
    public func register(handler: @escaping (DeepLinkAction) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// Parse `url` and, if recognized, forward it to the registered handler.
    /// Returns `false` when the URL is not a supported deep link (nothing is
    /// dispatched in that case).
    @discardableResult
    public func handle(url: URL) -> Bool {
        let result = Self.parseResult(url: url)
        guard result.isDispatchable, let action = result.action else { return false }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(action)
        return true
    }

    // MARK: - Workflow resolution (D2 接线)

    /// Resolve a `runWorkflow(name:)` action against `WorkflowStore`
    /// (match by template id or 模板名). Returns `nil` when the action is not
    /// `runWorkflow` or no template matches. Host app wiring example:
    ///
    ///     DeepLinkRouter.shared.register { action in
    ///         if let template = DeepLinkRouter.shared.resolveWorkflow(action) {
    ///             Task { try? await WorkflowRunner().run(template: template, inputs: [:], provider: llmProvider) }
    ///         }
    ///     }
    public func resolveWorkflow(_ action: DeepLinkAction, store: WorkflowStore = .shared) -> WorkflowTemplate? {
        guard case let .runWorkflow(name, _) = action else { return nil }
        return store.template(id: name)
    }

    // MARK: - Parsing (pure, testable)

    /// Parse a URL into a `DeepLinkAction`. Returns `nil` for non-miniscanvas
    /// schemes or unrecognized routes. Pure function — no side effects.
    /// The legacy `minis://` prefix (D1-fix 前旧数据/旧链接）也接受。
    public static func parse(url: URL) -> DeepLinkAction? {
        parseResult(url: url).action
    }

    /// Parse a deep link into an exact typed action and an explicit gate state.
    /// Unknown routes, duplicate/unknown query keys, overlong components, and
    /// invalid route shapes are unsupported rather than silently normalized.
    public static func parseResult(url: URL) -> DeepLinkParseResult {
        guard url.absoluteString.utf8.count <= Self.maxURLLength else {
            return DeepLinkParseResult(
                disposition: .unsupported,
                reason: "deep link exceeds the \(Self.maxURLLength)-byte limit"
            )
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == Self.scheme || Self.legacySchemes.contains(scheme) else {
            return DeepLinkParseResult(disposition: .unsupported, reason: "unsupported scheme")
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
        let firstRoute = (url.host?.isEmpty == false ? url.host : segments.first)?.lowercased()
        let segmentLimit = firstRoute.map(Self.promptRoutes.contains) == true
            ? Self.maxPromptComponentLength : Self.maxComponentLength
        guard segments.count <= Self.maxSegmentCount,
              segments.allSatisfy({ Self.isUsableBoundedComponent($0, limit: segmentLimit) }) else {
            return DeepLinkParseResult(disposition: .unsupported, reason: "invalid path components")
        }
        let host = url.host?.lowercased()

        // F22（P1-2）：解析 query —— 之前只读 host/path，?session=/?input=/?pane= 全丢。
        // URLComponents 按 percent-decoding 提取，重复键取最后一个。
        var query: [String: String] = [:]
        if let items = components?.queryItems {
            for item in items {
                guard Self.isUsableComponent(item.name),
                      let value = item.value,
                      value.utf8.count <= Self.maxPayloadLength,
                      query[item.name] == nil else {
                    return DeepLinkParseResult(
                        disposition: .unsupported,
                        reason: "duplicate or invalid query item"
                    )
                }
                query[item.name] = value
            }
        }

        let routeHost: String
        let routeSegments: [String]
        if let host, !host.isEmpty {
            routeHost = host
            routeSegments = segments
        } else {
            // Path-only fallback: miniscanvas:///session/<id> → first segment
            // acts as the route name.
            guard let head = segments.first else {
                return DeepLinkParseResult(disposition: .unsupported, reason: "missing route")
            }
            routeHost = head.lowercased()
            routeSegments = Array(segments.dropFirst())
        }

        guard Self.allowedQueryKeys(for: routeHost).isSuperset(of: query.keys) else {
            return DeepLinkParseResult(disposition: .unsupported, reason: "unsupported query item")
        }
        guard let action = parse(host: routeHost, segments: routeSegments, query: query) else {
            return DeepLinkParseResult(disposition: .unsupported, reason: "unsupported route shape")
        }
        return DeepLinkParseResult(
            disposition: action.requiresAuthorization ? .authorizationRequired : .supported,
            action: action,
            reason: action.requiresAuthorization ? "authorization is required before dispatch" : nil
        )
    }

    private static func parse(host: String, segments: [String], query: [String: String]) -> DeepLinkAction? {
        switch host {
        case "session", "sessions":
            guard segments.count == 1, let id = segments.first, Self.isUsableComponent(id) else { return nil }
            return .openSession(id: id)

        case "new-session", "newsession", "new":
            guard segments.isEmpty else { return nil }
            return .newSession

        case "pipeline", "create-pipeline", "createpipeline":
            guard segments.isEmpty else { return nil }
            return .createPipeline

        case "settings":
            // F22（P1-2）：路径段优先，回落 ?pane=<id>
            guard segments.count <= 1 else { return nil }
            let pane = segments.first ?? query["pane"]
            guard pane == nil || Self.isUsableComponent(pane!) else { return nil }
            return .openSettings(id: pane)

        case "run", "workflow", "run-workflow", "runworkflow":
            let name = segments.joined(separator: "/")
            guard !name.isEmpty, name.utf8.count <= Self.maxPayloadLength,
                  Self.isUsableComponent(name) else { return nil }
            // F22（P1-2）：透传 ?input=<text>（工作流首个必需输入）
            return .runWorkflow(name: name, input: query["input"])

        case "prompt", "send-prompt", "sendprompt":
            // F22（P1-2）：text 路径段优先，空则回落 ?text=；?session= 指定目标会话
            let text = segments.joined(separator: "/")
            let promptText = text.isEmpty ? (query["text"] ?? "") : text
            guard !promptText.isEmpty, promptText.utf8.count <= Self.maxPayloadLength,
                  Self.isUsableBoundedComponent(promptText, limit: Self.maxPromptComponentLength),
                  query["session"].map(Self.isUsableComponent) ?? true else { return nil }
            return .sendPrompt(text: promptText, session: query["session"])

        default:
            return nil
        }
    }

    private static func allowedQueryKeys(for host: String) -> Set<String> {
        switch host {
        case "settings": return ["pane"]
        case "run", "workflow", "run-workflow", "runworkflow": return ["input"]
        case "prompt", "send-prompt", "sendprompt": return ["text", "session"]
        default: return []
        }
    }

    /// Reject blank/control components while preserving URL-decoded Unicode
    /// IDs used by existing session and workflow links.
    private static let promptRoutes: Set<String> = ["prompt", "send-prompt", "sendprompt"]

    private static func isUsableComponent(_ value: String) -> Bool {
        isUsableBoundedComponent(value, limit: maxComponentLength)
    }

    private static func isUsableBoundedComponent(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= limit
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
