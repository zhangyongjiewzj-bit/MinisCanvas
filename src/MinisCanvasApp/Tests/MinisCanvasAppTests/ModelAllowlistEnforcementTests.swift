import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("P3 model allowlist enforcement")
struct ModelAllowlistEnforcementTests {
    @Test("empty whitelist preserves unrestricted model execution")
    func emptyWhitelistAllowsAnyModel() {
        #expect(ChatStore.isModelAllowed(modelID: "provider-model", whitelist: []))
        #expect(ChatStore.isModelAllowed(modelID: "provider-model", whitelist: [" ", "\n"]))
    }

    @Test("non-empty whitelist matches canonical exact IDs")
    func allowlistMatchesCanonicalIDsOnly() {
        #expect(
            ChatStore.isModelAllowed(
                modelID: "GPT-5.6-luna",
                whitelist: [" gpt-5.6-luna "]
            )
        )
        #expect(
            !ChatStore.isModelAllowed(
                modelID: "gpt-5.6-Luna",
                whitelist: ["gpt-5.6-luna"]
            )
        )
        #expect(
            !ChatStore.isModelAllowed(
                modelID: "other-model",
                whitelist: ["gpt-5.6-luna"]
            )
        )
    }

    @Test("request gate is before provider box and engine invocation")
    func requestBoundaryOwnsTheGate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatStore.swift"
            ),
            encoding: .utf8
        )
        // ChatStore contains an independent scheduled-submission path before
        // the interactive streamReply path. Scope this source-order contract
        // to the request boundary it names so a provider box in that separate
        // path cannot make the interactive gate appear to run late.
        let requestBoundary = try #require(
            source.range(of: "    private func streamReply(")
        )
        let requestSource = source[requestBoundary.lowerBound...]
        let whitelistRead = try #require(
            requestSource.range(of: "let configuredModelWhitelist = modelAllowlistProvider?() ?? []")
        )
        let providerBox = try #require(
            requestSource.range(of: "let providerBox = LLMProviderBox(value: provider)")
        )
        #expect(whitelistRead.lowerBound < providerBox.lowerBound)
        #expect(requestSource.contains("guard Self.isModelAllowed("))
        #expect(source.contains("当前请求未执行"))
    }

    @Test("composition injects the live SettingsCenter projection")
    func compositionWiresSettingsProjection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("bridge.chat.modelAllowlistProvider ="))
        #expect(source.contains("settings?.availableModelWhitelist ?? []"))
    }
}
