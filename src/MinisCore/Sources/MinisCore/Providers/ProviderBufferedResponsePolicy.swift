import Foundation

/// Fail-closed admission and size limits for buffered provider JSON replies.
///
/// `URLSession.data(for:)` returns the decoded response body on supported
/// Foundation transports. The limit is applied to that returned `Data` before
/// JSONSerialization, so a compressed Content-Length cannot bypass the
/// memory bound.
public enum ProviderBufferedResponsePolicyError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case missingHTTPResponse
    case missingContentType
    case unexpectedContentType
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .missingHTTPResponse:
            return "Provider response is unavailable"
        case .missingContentType:
            return "Provider response has no content type"
        case .unexpectedContentType:
            return "Provider response has an unsupported content type"
        case .responseTooLarge:
            return "Provider response is too large"
        }
    }

    public var description: String {
        errorDescription ?? "Provider response rejected"
    }
}

/// Shared buffered-response policy for OpenAI-compatible provider calls.
public enum ProviderBufferedResponsePolicy {
    /// Align the buffered body ceiling with the existing Responses API bound.
    public static let maximumDecodedResponseBytes = 16 * 1024 * 1024

    /// Validates the successful JSON response before JSONSerialization. MIME
    /// parameters and casing are ignored. RFC 6839 JSON suffix types are
    /// accepted for compatible gateways while HTML/text responses fail closed.
    public static func validateJSONResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderBufferedResponsePolicyError.missingHTTPResponse
        }
        guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") else {
            throw ProviderBufferedResponsePolicyError.missingContentType
        }
        guard let firstComponent = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first else {
            throw ProviderBufferedResponsePolicyError.unexpectedContentType
        }
        let mediaType = String(firstComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json"
                || (mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json")) else {
            throw ProviderBufferedResponsePolicyError.unexpectedContentType
        }
        guard data.count <= maximumDecodedResponseBytes else {
            throw ProviderBufferedResponsePolicyError.responseTooLarge
        }
    }
}
