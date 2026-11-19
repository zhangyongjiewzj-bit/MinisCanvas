import Foundation
import Testing
@testable import MinisCore

@Suite("Provider readiness wire adapter contract")
struct ProviderReadinessAdapterTests {
    private let baseURL = URL(string: "https://provider.example/v1")!
    private let fakeCredential = "sk-test-provider-secret-1234"

    @Test("OpenAI-compatible adapter defines catalog and chat-completions schemas")
    func openAICompatibleSchema() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiCompatible)

        let catalog = try adapter.makeRequest(
            operation: .modelCatalog,
            baseURL: baseURL,
            modelID: nil,
            apiKey: fakeCredential
        )
        #expect(catalog.httpMethod == "GET")
        #expect(catalog.url?.path == "/v1/models")
        #expect(catalog.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeCredential)")

        let minimum = try adapter.makeRequest(
            operation: .modelRequest(modelID: "gpt-test"),
            baseURL: baseURL,
            modelID: "gpt-test",
            apiKey: fakeCredential
        )
        #expect(minimum.httpMethod == "POST")
        #expect(minimum.url?.path == "/v1/chat/completions")
        #expect(minimum.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeCredential)")
        // 与对话请求一致（MC4-012）：自定义兼容端点 + 非推理模型用 max_tokens。
        let minimumBody = try jsonObject(from: minimum)
        #expect(minimumBody["max_tokens"] as? Int == 16)
        #expect(minimumBody["max_completion_tokens"] == nil)
        // 推理模型（gpt-5 / o 系列）与 OpenAI 官方端点仍用 max_completion_tokens。
        let reasoning = try adapter.makeRequest(
            operation: .modelRequest(modelID: "gpt-5"), baseURL: baseURL, modelID: "gpt-5", apiKey: fakeCredential)
        #expect(try jsonObject(from: reasoning)["max_completion_tokens"] as? Int == 16)
        #expect(try jsonObject(from: reasoning)["max_tokens"] == nil)
        let official = try adapter.makeRequest(
            operation: .modelRequest(modelID: "gpt-test"), baseURL: URL(string: "https://api.openai.com/v1")!,
            modelID: "gpt-test", apiKey: fakeCredential)
        #expect(try jsonObject(from: official)["max_completion_tokens"] as? Int == 16)
        #expect(try jsonObject(from: minimum)["stream"] as? Bool == false)
        #expect(try jsonObject(from: minimum)["model"] as? String == "gpt-test")
    }

    @Test("Responses wire value is distinct and unknown future values fail closed")
    func responsesProtocolDecoding() throws {
        #expect(try JSONDecoder().decode(
            ProviderWireProtocol.self,
            from: Data(#""openai_responses""#.utf8)
        ) == .openaiResponses)
        #expect(try JSONDecoder().decode(
            ProviderWireProtocol.self,
            from: Data(#""future_wire""#.utf8)
        ) == .other)
    }

    @Test("Responses adapter follows production /v1/responses wire and required catalog")
    func responsesSchemaAndPaths() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiResponses)
        for (rawBase, expectedPrefix) in [
            ("https://provider.example", "/v1"),
            ("https://provider.example/v1", "/v1"),
            ("https://provider.example/v1/", "/v1"),
            ("https://provider.example/proxy", "/proxy/v1")
        ] {
            let base = try #require(URL(string: rawBase))
            let catalog = try adapter.makeRequest(
                operation: .modelCatalog,
                baseURL: base,
                modelID: nil,
                apiKey: fakeCredential
            )
            #expect(catalog.httpMethod == "GET")
            #expect(catalog.url?.path == "\(expectedPrefix)/models")
            #expect(catalog.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeCredential)")

            let minimum = try adapter.makeRequest(
                operation: .modelRequest(modelID: "gpt-test"),
                baseURL: base,
                modelID: "gpt-test",
                apiKey: fakeCredential
            )
            #expect(minimum.httpMethod == "POST")
            #expect(minimum.url?.path == "\(expectedPrefix)/responses")
            #expect(minimum.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeCredential)")
            let body = try jsonObject(from: minimum)
            #expect(body["model"] as? String == "gpt-test")
            #expect(body["stream"] as? Bool == false)
            #expect(body["max_output_tokens"] as? Int == 16)
            #expect(body["messages"] == nil)
            #expect(body["max_tokens"] == nil)
            let input = try #require(body["input"] as? [[String: Any]])
            #expect(input.count == 1)
            #expect(input.first?["role"] as? String == "user")
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.first?["type"] as? String == "input_text")
            #expect(content.first?["text"] as? String == "ping")
        }
        let catalog = Data(#"{"data":[{"id":"gpt-test"}]}"#.utf8)
        #expect(try adapter.decodeModelCatalog(from: catalog).map(\.id) == ["gpt-test"])
        #expect(throws: ProviderReadinessWireAdapterError.missingModelID) {
            try adapter.makeRequest(
                operation: .modelRequest(modelID: "  "),
                baseURL: baseURL,
                modelID: nil,
                apiKey: fakeCredential
            )
        }
    }

    @Test("Responses 2xx requires a bounded completed Responses body")
    func responsesSuccessBodyValidation() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiResponses)
        try adapter.validateModelRequestResponse(from: Data(
            #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8
        ))
        let invalidBodies: [Data] = [
            Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
            Data(#"{"status":"failed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8),
            Data(#"{"status":"completed","output":[]}"#.utf8),
            Data(#"{"status":"completed","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8),
            Data([0xFF, 0xFE]),
            Data(repeating: 0x20, count: 16 * 1_048_576 + 1)
        ]
        for body in invalidBodies {
            #expect(throws: ProviderReadinessWireAdapterError.malformedModelResponse) {
                try adapter.validateModelRequestResponse(from: body)
            }
        }
    }

    @Test("Anthropic adapter uses Messages headers, endpoint, and schema")
    func anthropicSchema() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic)

        let catalog = try adapter.makeRequest(
            operation: .modelCatalog,
            baseURL: baseURL,
            modelID: nil,
            apiKey: fakeCredential
        )
        #expect(catalog.httpMethod == "GET")
        #expect(catalog.url?.path == "/v1/models")
        #expect(catalog.value(forHTTPHeaderField: "x-api-key") == fakeCredential)
        #expect(catalog.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(catalog.value(forHTTPHeaderField: "Authorization") == nil)

        let minimum = try adapter.makeRequest(
            operation: .modelRequest(modelID: "claude-test"),
            baseURL: baseURL,
            modelID: "claude-test",
            apiKey: fakeCredential
        )
        #expect(minimum.url?.path == "/v1/messages")
        #expect(minimum.value(forHTTPHeaderField: "x-api-key") == fakeCredential)
        #expect(minimum.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(try jsonObject(from: minimum)["max_tokens"] as? Int == 16)
        #expect(try jsonObject(from: minimum)["model"] as? String == "claude-test")
    }

    @Test("Anthropic 网关地址不带 /v1：连接检查与对话同样补 /v1")
    func anthropicGatewayWithoutV1GetsV1() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic)
        let gateway = URL(string: "https://gateway.example.com/anthropic/")!
        let catalog = try adapter.makeRequest(
            operation: .modelCatalog, baseURL: gateway, modelID: nil, apiKey: fakeCredential
        )
        #expect(catalog.url?.path == "/anthropic/v1/models")
        let auth = try adapter.makeRequest(
            operation: .authentication, baseURL: gateway, modelID: nil, apiKey: fakeCredential
        )
        #expect(auth.url?.path == "/anthropic/v1/models")
        let minimum = try adapter.makeRequest(
            operation: .modelRequest(modelID: "m"), baseURL: gateway, modelID: "m", apiKey: fakeCredential
        )
        #expect(minimum.url?.path == "/anthropic/v1/messages")
        let paged = try adapter.makeCatalogPageRequest(baseURL: gateway, apiKey: fakeCredential, afterID: "x")
        #expect(paged.url?.path == "/anthropic/v1/models")
    }

    @Test("Anthropic catalog uses its own schema and does not accept OpenAI-shaped data")
    func anthropicCatalogParserIsProtocolSpecific() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic)
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "claude-sonnet-test", "type": "model", "display_name": "Claude Test"]
            ]
        ])
        let models = try adapter.decodeModelCatalog(from: body)
        #expect(models.map(\.id) == ["claude-sonnet-test"])

        let openAIOnlyShape = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "wrong-protocol-model"]
            ]
        ])
        #expect(throws: ProviderReadinessWireAdapterError.self) {
            try adapter.decodeModelCatalog(from: openAIOnlyShape)
        }
    }

    @Test("Catalog decoding dedupes repeated IDs and rejects a catalog with no usable ID")
    func catalogIdentityIsDedupedAndNonEmpty() throws {
        let openAI = ProviderReadinessWireAdapterFactory.make(for: .openaiCompatible)
        let duplicateOpenAI = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "gpt-test"],
                ["id": " gpt-test " ],
                ["id": "gpt-other"]
            ]
        ])
        #expect(try openAI.decodeModelCatalog(from: duplicateOpenAI).map(\.id) == ["gpt-test", "gpt-other"])

        let anthropic = ProviderReadinessWireAdapterFactory.make(for: .anthropic)
        let emptyAnthropic = try JSONSerialization.data(withJSONObject: [
            "data": [
                ["id": "   ", "type": "model"]
            ]
        ])
        #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
            try anthropic.decodeModelCatalog(from: emptyAnthropic)
        }
    }

    @Test("Catalog accepts large relay catalogs and unknown root keys but still rejects broken JSON")
    func catalogEnvelopeIsTolerantAndBounded() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiCompatible)

        #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
            try adapter.decodeModelCatalog(from: Data(#"{"data":[{"id":"first","id":"second"}]}"#.utf8))
        }
        let withExtraRootKey = try JSONSerialization.data(withJSONObject: [
            "data": [["id": "gpt-test"]],
            "success": true
        ])
        #expect(try adapter.decodeModelCatalog(from: withExtraRootKey).map(\.id) == ["gpt-test"])

        let large = try JSONSerialization.data(withJSONObject: [
            "data": (0..<3_000).map { ["id": "gpt-\($0)"] }
        ])
        #expect(try adapter.decodeModelCatalog(from: large).count == 3_000)
        #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
            let entries = (0..<5_001).map { ["id": "gpt-\($0)"] }
            let body = try JSONSerialization.data(withJSONObject: ["data": entries])
            _ = try adapter.decodeModelCatalog(from: body)
        }
        #expect(throws: ProviderReadinessWireAdapterError.malformedModelCatalog) {
            try adapter.decodeModelCatalog(from: Data([0xFF, 0xFE, 0x00]))
        }
    }

    @Test("Anthropic catalog requests limit=1000 and follows has_more with last_id")
    func anthropicCatalogPaginates() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .anthropic)
        let first = try adapter.makeCatalogPageRequest(baseURL: baseURL, apiKey: fakeCredential, afterID: nil)
        #expect(first.url?.query == "limit=1000")
        let next = try adapter.makeCatalogPageRequest(baseURL: baseURL, apiKey: fakeCredential, afterID: "claude-a")
        #expect(next.url?.query?.contains("after_id=claude-a") == true)

        let page = Data(#"{"data":[{"id":"claude-a","type":"model"}],"has_more":true,"last_id":"claude-a"}"#.utf8)
        #expect(adapter.nextCatalogPageCursor(from: page) == "claude-a")
        let lastPage = Data(#"{"data":[{"id":"claude-b","type":"model"}],"has_more":false,"last_id":"claude-b"}"#.utf8)
        #expect(adapter.nextCatalogPageCursor(from: lastPage) == nil)
    }

    @Test("Opaque model IDs retain case and Unicode distinctions")
    func catalogIdentityDoesNotAliasOpaqueIDs() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .openaiCompatible)
        let composed = "model-\u{00E9}"
        let decomposed = "model-e\u{301}"
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [["id": composed], ["id": decomposed], ["id": "MODEL-TEST"]]
        ])

        let models = try adapter.decodeModelCatalog(from: body)
        #expect(models.map(\.id) == [composed, decomposed, "MODEL-TEST"])
    }

    @Test("Other is an explicit unsupported adapter and sends no request")
    func otherFailsClosed() throws {
        let adapter = ProviderReadinessWireAdapterFactory.make(for: .other)
        #expect(throws: ProviderReadinessWireAdapterError.unsupportedProtocol(.other)) {
            try adapter.makeRequest(
                operation: .reachability,
                baseURL: baseURL,
                modelID: nil,
                apiKey: fakeCredential
            )
        }
        #expect(throws: ProviderReadinessWireAdapterError.unsupportedProtocol(.other)) {
            try adapter.decodeModelCatalog(from: Data("{}".utf8))
        }
    }

    @Test("HTTP failures preserve status classification and redact credentials")
    func httpFailureClassificationAndRedaction() {
        let cases: [(Int, ProviderReadinessFailureCategory)] = [
            (401, .unauthorized),
            (403, .permissionDenied),
            (404, .notFound),
            (429, .rateLimited),
            (500, .server),
            (502, .server),
            (503, .server),
            (504, .server)
        ]

        for (statusCode, category) in cases {
            let failure = ProviderReadinessHTTPFailure.make(
                statusCode: statusCode,
                headers: statusCode == 429 ? ["Retry-After": "7"] : [:],
                body: "Authorization: Bearer \(fakeCredential), key=\(fakeCredential)",
                secrets: [fakeCredential]
            )
            #expect(failure?.failureCategory == category)
            #expect(failure?.redactedDetail.contains(fakeCredential) == false)
            if statusCode == 429 {
                #expect(failure?.retryAfterSeconds == 7)
            }
        }

        #expect(ProviderReadinessHTTPFailure.make(
            statusCode: 200,
            headers: [:],
            body: "ok",
            secrets: [fakeCredential]
        ) == nil)
    }

    @Test("URL timeout maps to the timeout readiness category")
    func timeoutClassification() {
        #expect(ProviderReadinessTransportError.timeout.category == .timeout)
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
