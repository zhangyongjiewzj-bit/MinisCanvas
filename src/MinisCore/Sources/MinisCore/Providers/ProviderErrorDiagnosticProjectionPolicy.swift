import Foundation

/// Shared payload-free projection for provider errors crossing product
/// diagnostics, workflow failures and fallback observations.
///
/// Known provider errors expose only their stable, typed descriptions. Unknown
/// errors are intentionally reduced to a fixed category; neither
/// `localizedDescription` nor synthesized `String(describing:)` output is
/// trusted because either may contain a URL, path, header or response body.
public enum ProviderErrorDiagnosticProjectionPolicy {
    /// Project an arbitrary provider/transport error without retaining its raw
    /// description. ApprovalError is handled by its caller first so its
    /// dedicated localized denial contract remains the single owner of that
    /// surface.
    public static func project(_ error: Error) -> String {
        if let replayBlocked = error as? ProviderRequestReplayBlockedError {
            return replayBlocked.errorDescription ?? "Provider request was not replayed"
        }
        if let fallbackError = error as? FallbackRouterError {
            switch fallbackError {
            case .emptyChain:
                return "Provider chain is empty"
            case .allProvidersFailed(let events):
                let attempts = min(max(events.count, 1), 1_024)
                return "All providers failed (attempts=\(attempts))"
            }
        }
        if let llmError = error as? LLMError {
            return llmError.description
        }
        if error is CancellationError {
            return LLMError.cancelled.errorDescription ?? "Request was cancelled"
        }
        let nsError = error as NSError
        if error is URLError || nsError.domain == NSURLErrorDomain {
            let classification = ProviderHTTPErrorAdapter.classify(transport: error)
            return classification.llmError.errorDescription ?? "Network error"
        }
        if let error = error as? ProviderResponseStreamPolicyError {
            return error.errorDescription ?? "Provider stream response rejected"
        }
        if let error = error as? ProviderBufferedResponsePolicyError {
            return error.errorDescription ?? "Provider response rejected"
        }
        if let error = error as? ProviderChatResponseShapePolicyError {
            return error.errorDescription ?? "Provider response shape rejected"
        }
        if let error = error as? ProviderAnthropicResponseShapePolicyError {
            return error.errorDescription ?? "Anthropic stream event rejected"
        }
        if error is ProviderEndpointPolicyError || error is CustomProviderURL.Failure {
            return "Provider endpoint rejected"
        }
        return "Provider error"
    }
}
