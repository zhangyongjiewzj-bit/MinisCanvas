import Foundation

/// Canonical settings/readiness/picker contract for the DeepSeek V4 route.
///
/// The persisted provider name may still be an environment-variable alias,
/// but the UI and readiness identity must converge on `deepseek`. DeepSeek's
/// documented bare host is also intentionally distinct from generic OpenAI
/// compatible proxies: its readiness and chat paths are rooted directly at
/// `/models` and `/chat/completions`.
public enum DeepSeekProviderContract {
    public static let providerID = "deepseek"
    public static let apiKeyEnvironmentVariable = "DEEPSEEK_API_KEY"
    public static let apiKeyEnvironmentAliases = [
        "HERMES_CUSTOM_DEEPSEEK_API_KEY",
        apiKeyEnvironmentVariable,
    ]
    public static let baseURL = "https://api.deepseek.com"
    public static let preferredModelID = "deepseek-v4-flash"
    public static let supportedModelIDs = [
        preferredModelID,
        "deepseek-v4-pro",
        "deepseek-chat",
        "deepseek-reasoner",
        "deepseek-flash",
    ]
    public static let modelsPath = "/models"
    public static let chatCompletionsPath = "/chat/completions"

    public enum ReadinessRoute: String, Sendable {
        case models
        case chatCompletions = "chat/completions"

        public var path: String {
            "/" + rawValue
        }
    }

    /// Resolve an input provider identity to the one stable picker identity.
    /// Unknown names return nil rather than being guessed from substrings.
    public static func canonicalProviderID(for rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.caseInsensitiveCompare(providerID) == .orderedSame
            || normalized.caseInsensitiveCompare("DeepSeek") == .orderedSame
            || apiKeyEnvironmentAliases.contains(where: {
                $0.caseInsensitiveCompare(normalized) == .orderedSame
            }) {
            return providerID
        }
        return nil
    }

    /// A bare canonical host is the only DeepSeek URL that omits `/v1`.
    public static func isCanonicalBaseURL(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.deepseek.com",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }

    /// Build a canonical route without carrying query, credential, or body
    /// material into settings/readiness/picker receipts.
    public static func endpointURL(
        baseURL: String = DeepSeekProviderContract.baseURL,
        route: ReadinessRoute
    ) -> URL? {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.user == nil,
              base.password == nil,
              base.query == nil,
              base.fragment == nil else {
            return nil
        }
        if isCanonicalBaseURL(base.absoluteString) {
            return URL(string: Self.baseURL + route.path)
        }
        return base.appendingPathComponent(route.rawValue)
    }
}
