import Foundation

/// Fail-closed admission and decoded-size limits for provider SSE responses.
///
/// `URLSession.AsyncBytes` exposes the response sequence after Foundation has
/// applied supported content decoding. The byte budget is therefore charged
/// against the decoded UTF-8 lines observed by the provider parser, which is
/// the memory and parser surface that this policy protects.
public enum ProviderResponseStreamPolicyError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case missingHTTPResponse
    case missingContentType
    case unexpectedContentType
    case lineTooLarge
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .missingHTTPResponse:
            return "Provider stream response is unavailable"
        case .missingContentType:
            return "Provider stream response has no content type"
        case .unexpectedContentType:
            return "Provider stream response has an unsupported content type"
        case .lineTooLarge:
            return "Provider stream response line is too large"
        case .responseTooLarge:
            return "Provider stream response is too large"
        }
    }

    public var description: String {
        errorDescription ?? "Provider stream response rejected"
    }
}

/// Shared bounded-response policy for the OpenAI-compatible streaming
/// transport. This type has no network or decompression side effects.
public enum ProviderResponseStreamPolicy {
    /// Keep this aligned with the existing Responses API SSE guard.
    public static let maximumDecodedLineBytes = 256 * 1024
    public static let maximumDecodedResponseBytes = 16 * 1024 * 1024

    /// Validates the successful response MIME boundary before any stream
    /// parsing or continuation is created. Parameters and MIME casing are
    /// intentionally ignored, while a missing or non-SSE media type fails
    /// closed.
    public static func validateSSEResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderResponseStreamPolicyError.missingHTTPResponse
        }
        guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") else {
            throw ProviderResponseStreamPolicyError.missingContentType
        }

        guard let firstComponent = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first else {
            throw ProviderResponseStreamPolicyError.unexpectedContentType
        }
        let mediaType = String(firstComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "text/event-stream" else {
            throw ProviderResponseStreamPolicyError.unexpectedContentType
        }
    }

    /// Tracks the decoded UTF-8 bytes delivered by `AsyncBytes.lines`.
    /// `lines` removes the line separator, so one separator byte is charged
    /// per delivered line. Charging it conservatively keeps the total bound
    /// valid for both LF and CRLF transports without retaining payload data.
    public struct DecodedByteBudget: Sendable, Equatable {
        public private(set) var decodedBytes: Int = 0

        public init() {}

        public mutating func consume(line: String) throws {
            let lineBytes = line.utf8.count
            guard lineBytes <= ProviderResponseStreamPolicy.maximumDecodedLineBytes else {
                throw ProviderResponseStreamPolicyError.lineTooLarge
            }

            let chargedBytes = lineBytes.addingReportingOverflow(1)
            guard !chargedBytes.overflow else {
                throw ProviderResponseStreamPolicyError.responseTooLarge
            }
            let projected = decodedBytes.addingReportingOverflow(chargedBytes.partialValue)
            guard !projected.overflow,
                  projected.partialValue <= ProviderResponseStreamPolicy.maximumDecodedResponseBytes else {
                throw ProviderResponseStreamPolicyError.responseTooLarge
            }
            decodedBytes = projected.partialValue
        }
    }
}
