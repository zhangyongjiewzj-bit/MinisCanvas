import Foundation
import Testing
@testable import MinisCore

struct DeepSeekReadinessCompatibilityTests {
    @Test("Responses accepts nullable error while preserving completed output requirements")
    func nullableError() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiResponses)
        let output = #"[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]"#
        try adapter.validateModelRequestResponse(from: Data("{\"status\":\"completed\",\"error\":null,\"output\":\(output)}".utf8))
        for body in [
            "{\"status\":\"completed\",\"error\":{\"message\":\"failed\"},\"output\":\(output)}",
            "{\"status\":\"incomplete\",\"error\":null,\"output\":\(output)}",
            #"{"status":"completed","error":null,"output":[]}"#
        ] {
            #expect(throws: ProviderReadinessWireAdapterError.malformedModelResponse) {
                try adapter.validateModelRequestResponse(from: Data(body.utf8))
            }
        }
    }

    @Test("Only canonical DeepSeek Responses probes disable thinking with bounded output")
    func responsesBudget() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiResponses)
        for (base, expectedTokens) in [
            ("https://api.deepseek.com", 32), ("https://api.deepseek.com/v1", 32),
            ("https://api.deepseek.com:443/v1", 32), ("https://api.deepseek.com:8443", 1),
            ("http://api.deepseek.com", 1), ("https://api.deepseek.com/proxy", 1),
            ("https://provider.example/v1", 1), ("https://api.deepseek.com?route=x", 1)
        ] {
            let request = try adapter.makeRequest(operation: .modelRequest(modelID: "test"), baseURL: #require(URL(string: base)), modelID: nil, apiKey: "synthetic")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["max_output_tokens"] as? Int == expectedTokens)
            #expect((body["reasoning"] as? [String: String])?["effort"] == (expectedTokens == 32 ? "none" : nil))
            #expect(request.timeoutInterval == 15)
        }
    }

    @Test("DeepSeek Anthropic uses same-origin Bearer catalog and versioned Messages")
    func anthropicRoutesAndCatalog() throws {
        let catalog = Data(#"{"object":"list","data":[{"id":"test","object":"model","owned_by":"deepseek"}]}"#.utf8)
        for raw in ["https://api.deepseek.com/anthropic", "https://api.deepseek.com/anthropic/v1/"] {
            let base = try #require(URL(string: raw))
            let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic, baseURL: base)
            for operation in [ProviderReadinessTransportCall.reachability, .authentication, .modelCatalog] {
                let request = try adapter.makeRequest(operation: operation, baseURL: base, modelID: nil, apiKey: "synthetic")
                #expect(request.url?.absoluteString == "https://api.deepseek.com/models")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            }
            let message = try adapter.makeRequest(operation: .modelRequest(modelID: "test"), baseURL: base, modelID: nil, apiKey: "synthetic")
            #expect(message.url?.path == "/anthropic/v1/messages")
            #expect(message.value(forHTTPHeaderField: "x-api-key") == "synthetic")
            #expect(message.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(try adapter.decodeModelCatalog(from: catalog).map(\.id) == ["test"])
            for malformed in [#"{"object":"list","data":[{"id":"test","type":"model"}]}"#, #"{"object":"other","data":[{"id":"test","object":"model"}]}"#] {
                #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
                    try adapter.decodeModelCatalog(from: Data(malformed.utf8))
                }
            }
        }
        for raw in ["https://provider.example/anthropic", "http://api.deepseek.com/anthropic", "https://api.deepseek.com:8443/anthropic", "https://api.deepseek.com/other"] {
            let base = try #require(URL(string: raw))
            let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic, baseURL: base)
            let request = try adapter.makeRequest(operation: .modelCatalog, baseURL: base, modelID: nil, apiKey: "synthetic")
            #expect(request.url == base.appendingPathComponent("models"))
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
                try adapter.decodeModelCatalog(from: catalog)
            }
        }
    }
}
