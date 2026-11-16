import Foundation
import Testing
@testable import MinisCore

@Suite("Settings catalog typed metadata through final tool projection")
struct SettingsCatalogSecretMetadataProjectionTests {
    @Test func builtinCatalogPreservesDescriptorFlagsTypedMarkersAndReadOnlySafety() throws {
        let raw = #"{"entries":[{"id":"shortcuts.createPipeline","kind":"object","agentMutable":true,"secret":false},{"id":"safety.safe-mode-enabled","kind":"toggle","agentMutable":false,"secret":false},{"id":"credential.provider-api-key","kind":"secret","agentMutable":false,"secret":true}],"values":{"safety.safe-mode-enabled":{"kind":"toggle","toggle":true},"credential.provider-api-key":{"kind":"redactedSecret","present":true},"provider.record.synthetic":{"kind":"object","object":{"credential":{"kind":"redactedSecret","present":false}}}}}"#
        let projected = MCPOutputLimiter.projectSettingsCatalog(raw)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        let entries = try #require(body["entries"] as? [[String: Any]])
        let shortcut = try #require(entries.first(where: { $0["id"] as? String == "shortcuts.createPipeline" }))
        #expect(shortcut["secret"] as? Bool == false)
        #expect(shortcut["agentMutable"] as? Bool == true)
        let safety = try #require(entries.first(where: { $0["id"] as? String == "safety.safe-mode-enabled" }))
        #expect(safety["secret"] as? Bool == false)
        #expect(safety["agentMutable"] as? Bool == false)
        let credential = try #require(entries.first(where: { $0["id"] as? String == "credential.provider-api-key" }))
        #expect(credential["secret"] as? Bool == true)
        #expect(credential["agentMutable"] as? Bool == false)
        let values = try #require(body["values"] as? [String: Any])
        func typed(_ id: String) throws -> BL6SettingValue {
            let data = try JSONSerialization.data(withJSONObject: try #require(values[id]))
            return try JSONDecoder().decode(BL6SettingValue.self, from: data)
        }
        #expect(try typed("safety.safe-mode-enabled") == .toggle(true))
        #expect(try typed("credential.provider-api-key") == .redactedSecret(present: true))
        #expect(try typed("provider.record.synthetic") == .object(["credential": .redactedSecret(present: false)]))
    }

    @Test func ordinaryProjectorKeepsItsSecretRedactionContract() throws {
        let raw = #"{"entries":[{"id":"shortcuts.createPipeline","kind":"object","agentMutable":true,"secret":false}],"credential.provider-api-key":{"kind":"redactedSecret","present":true},"secret":"synthetic-credential-value","secretValuesExposed":false}"#
        let projected = MCPOutputLimiter.project(raw)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        let entries = try #require(body["entries"] as? [[String: Any]])
        #expect(entries.first?["secret"] as? String == "[REDACTED]")
        #expect(body["credential.provider-api-key"] as? String == "[REDACTED]")
        #expect(body["secret"] as? String == "[REDACTED]")
        #expect(body["secretValuesExposed"] as? Bool == false)
        #expect(!projected.contains("synthetic-credential-value"))
    }

    @Test func catalogContextDoesNotExemptPayloadsOrMalformedMetadata() throws {
        let raw = #"{"entries":[{"id":"shortcuts.createPipeline","kind":"object","agentMutable":true,"secret":false,"credential":"synthetic-extra-value"}],"items":[{"secret":false},{"secret":true},{"secret":"synthetic-credential-value"}],"credential.numeric":{"kind":"redactedSecret","present":0},"credential.text":{"kind":"redactedSecret","present":"false"},"credential.extra":{"kind":"redactedSecret","present":false,"extra":"synthetic-extra-value"},"credential.plain":"synthetic-provider-value"}"#
        let projected = MCPOutputLimiter.projectSettingsCatalog(raw)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        let entries = try #require(body["entries"] as? [[String: Any]])
        #expect(entries.first?["secret"] as? String == "[REDACTED]")
        #expect(entries.first?["credential"] as? String == "[REDACTED]")
        let items = try #require(body["items"] as? [[String: Any]])
        #expect(items.count == 3)
        for item in items { #expect(item["secret"] as? String == "[REDACTED]") }
        for key in ["credential.numeric", "credential.text", "credential.extra", "credential.plain"] {
            #expect(body[key] as? String == "[REDACTED]")
        }
        #expect(!projected.contains("synthetic-credential-value"))
        #expect(!projected.contains("synthetic-provider-value"))
        #expect(!projected.contains("synthetic-extra-value"))
    }
}
