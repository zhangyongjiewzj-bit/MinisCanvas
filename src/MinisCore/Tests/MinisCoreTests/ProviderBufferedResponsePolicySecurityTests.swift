import Foundation
import Testing
@testable import MinisCore

@Suite("Provider buffered response policy security")
struct ProviderBufferedResponsePolicySecurityTests {
    private static func response(contentType: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return HTTPURLResponse(
            url: URL(string: "https://provider.example/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test("JSON MIME accepts case parameters and structured suffixes")
    func jsonMIMEBoundary() throws {
        try ProviderBufferedResponsePolicy.validateJSONResponse(
            Self.response(contentType: " Application/JSON ; charset=utf-8"),
            data: Data("{}".utf8)
        )
        try ProviderBufferedResponsePolicy.validateJSONResponse(
            Self.response(contentType: "application/vnd.provider+json"),
            data: Data("{}".utf8)
        )
        #expect(throws: ProviderBufferedResponsePolicyError.missingContentType) {
            try ProviderBufferedResponsePolicy.validateJSONResponse(
                Self.response(),
                data: Data("{}".utf8)
            )
        }
        #expect(throws: ProviderBufferedResponsePolicyError.unexpectedContentType) {
            try ProviderBufferedResponsePolicy.validateJSONResponse(
                Self.response(contentType: "text/html"),
                data: Data("{}".utf8)
            )
        }
    }

    @Test("decoded body is bounded before JSON parsing")
    func decodedBodyBudget() throws {
        let valid = Data(repeating: 0x20, count: ProviderBufferedResponsePolicy.maximumDecodedResponseBytes)
        try ProviderBufferedResponsePolicy.validateJSONResponse(
            Self.response(contentType: "application/json"),
            data: valid
        )
        let oversized = Data(repeating: 0x20, count: ProviderBufferedResponsePolicy.maximumDecodedResponseBytes + 1)
        #expect(throws: ProviderBufferedResponsePolicyError.responseTooLarge) {
            try ProviderBufferedResponsePolicy.validateJSONResponse(
                Self.response(contentType: "application/json"),
                data: oversized
            )
        }
    }

    @Test("policy errors are fixed and do not echo fixture data")
    func errorsAreRedacted() {
        let error = ProviderBufferedResponsePolicyError.unexpectedContentType
        #expect(error.localizedDescription == "Provider response has an unsupported content type")
        #expect(!error.localizedDescription.contains("provider.example"))
        #expect(!error.localizedDescription.contains("fixture-secret"))
    }
}
