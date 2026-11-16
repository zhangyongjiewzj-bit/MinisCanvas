import Foundation
import Testing
@testable import MinisCore

@Suite("Provider response stream policy security")
struct ProviderResponseStreamPolicySecurityTests {
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

    @Test("SSE MIME accepts case and parameters but rejects missing or JSON")
    func sseMIMEBoundary() {
        #expect(throws: Never.self) {
            try ProviderResponseStreamPolicy.validateSSEResponse(
                Self.response(contentType: " Text/Event-Stream ; charset=utf-8")
            )
        }
        #expect(throws: ProviderResponseStreamPolicyError.missingContentType) {
            try ProviderResponseStreamPolicy.validateSSEResponse(Self.response())
        }
        #expect(throws: ProviderResponseStreamPolicyError.unexpectedContentType) {
            try ProviderResponseStreamPolicy.validateSSEResponse(
                Self.response(contentType: "application/json")
            )
        }
    }

    @Test("decoded UTF-8 bytes are bounded before a line reaches the parser")
    func decodedLineBudget() throws {
        var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
        let multibyteLine = String(repeating: "中", count: 100)
        try budget.consume(line: multibyteLine)
        #expect(budget.decodedBytes == multibyteLine.utf8.count + 1)

        #expect(throws: ProviderResponseStreamPolicyError.lineTooLarge) {
            try budget.consume(
                line: String(repeating: "x", count: ProviderResponseStreamPolicy.maximumDecodedLineBytes + 1)
            )
        }
    }

    @Test("total decoded stream budget is independent of line size")
    func decodedTotalBudget() throws {
        var budget = ProviderResponseStreamPolicy.DecodedByteBudget()
        let line = String(repeating: "x", count: 64 * 1024)
        let iterations = ProviderResponseStreamPolicy.maximumDecodedResponseBytes / (line.utf8.count + 1)
        for _ in 0..<iterations {
            try budget.consume(line: line)
        }
        #expect(budget.decodedBytes <= ProviderResponseStreamPolicy.maximumDecodedResponseBytes)
        #expect(throws: ProviderResponseStreamPolicyError.responseTooLarge) {
            try budget.consume(line: line)
        }
    }

    @Test("policy errors never include fixture URL or payload text")
    func errorsAreFixedAndRedacted() {
        let error = ProviderResponseStreamPolicyError.unexpectedContentType
        #expect(error.localizedDescription == "Provider stream response has an unsupported content type")
        #expect(!error.localizedDescription.contains("provider.example"))
        #expect(!error.localizedDescription.contains("secret"))
    }
}
