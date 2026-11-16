import Foundation

/// Observations only. These values cannot grant authority, resolve a provider,
/// or turn missing telemetry into usage. The child origin comes from Core's
/// existing immutable child identity when available, never from a tool argument.
/// Legacy children without that identity remain explicitly unverified children.
public struct ChildUsageOrigin: Sendable {
    public let taskID: String?
    public let childTranscriptLocator: ChildTranscriptLocator?
    public init(taskID: String?, childTranscriptLocator: ChildTranscriptLocator? = nil) {
        self.taskID = taskID
        self.childTranscriptLocator = childTranscriptLocator
    }
}

/// Observed route identity only; it neither selects nor authorizes a route.
public struct UsageServedRoute: Sendable {
    public let provider: String
    public let model: String
    public init(provider: String, model: String) { self.provider = provider; self.model = model }
}

/// Decorators forward this fact instead of presenting a fallback primary as served.
public protocol UsageRouteIdentityProviding {
    var usageRouteIdentity: UsageServedRoute? { get }
}

public actor UsageServedRouteCapture {
    private var route: UsageServedRoute?
    public init() {}
    public func record(_ route: UsageServedRoute) { self.route = route }
    public func value() -> UsageServedRoute? { route }
}

public enum UsageTelemetryObservation: Sendable {
    case childUsage(origin: ChildUsageOrigin, usage: LLMUsage, route: UsageServedRoute?)
    /// An actual MCP call attempt; MCP does not report model tokens here.
    case mcpCall(serverID: String, fullName: String, succeeded: Bool)
}

public enum UsageTelemetryContext {
    @TaskLocal public static var observer: (@Sendable (UsageTelemetryObservation) async -> Void)?
    @TaskLocal public static var childOrigin: ChildUsageOrigin?
    @TaskLocal public static var servedRouteCapture: UsageServedRouteCapture?

    public static func directRoute(of provider: any LLMProvider) -> UsageServedRoute? {
        if let reporting = provider as? any UsageRouteIdentityProviding { return reporting.usageRouteIdentity }
        // Only these concrete transports are known to send one configured route.
        // An unknown decorator's name/model may describe a fallback primary.
        guard provider is AnthropicProvider || provider is OpenAICompatibleProvider
                || provider is OpenAIResponsesProvider || provider is DeepSeekProvider
                || provider is DashScopeProvider || provider is LocalOpenAIProvider else { return nil }
        return UsageServedRoute(provider: provider.name, model: provider.model.id)
    }
}
