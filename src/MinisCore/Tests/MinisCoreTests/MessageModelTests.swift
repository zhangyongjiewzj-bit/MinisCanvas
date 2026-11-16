import Foundation
import Testing
@testable import MinisCore

// NOTE: This suite runs on the CLT-only toolchain (no Xcode). XCTest.framework
// does not exist there (`import XCTest` fails with "no such module 'XCTest'");
// Swift Testing (`import Testing`) ships with the CLT and is the only runnable
// test framework. Run with the documented flags:
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
// See threads/B1-fix.log for the evidence chain.

struct MessageModelTests {

    @Test func llmModelCodableRoundTrip() throws {
        let model = LLMModel(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            provider: "Anthropic",
            contextWindow: 1_000_000,
            maxOutputTokens: 64_000,
            supportsReasoning: true
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(LLMModel.self, from: data)
        #expect(decoded == model)
        #expect(decoded.contextWindowTokens == 1_000_000)
    }

    @Test func modelOverridesCodableRoundTrip() throws {
        let overrides = ModelOverrides(
            displayName: "My Claude",
            maxOutputTokens: 1234,
            contextWindow: 200_000,
            supportsReasoning: true,
            maxThinkingLevel: .high
        )
        let data = try JSONEncoder().encode(overrides)
        let decoded = try JSONDecoder().decode(ModelOverrides.self, from: data)
        #expect(decoded == overrides)
        #expect(!decoded.isEmpty)
        #expect(ModelOverrides().isEmpty)
    }

    @Test func modelEntryCodableRoundTrip() throws {
        let entry = ModelEntry(
            uuid: "uuid-1",
            providerInstanceId: "inst-1",
            model: .claudeSonnet46,
            overrides: ModelOverrides(displayName: "Sonnet 4.6 (fast)"),
            isCustom: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ModelEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.compositeKey == "inst-1/claude-sonnet-4-6")
        #expect(decoded.id == "inst-1/claude-sonnet-4-6")
        #expect(decoded.model.displayName == "Sonnet 4.6 (fast)")
        #expect(decoded.isUserModified)
    }

    @Test func modelEntryDecodesLegacyJSONWithoutUuid() throws {
        let json = """
        {"providerInstanceId":"inst-9","model":{"id":"gpt-4o","displayName":"GPT-4o","provider":"OpenAI"},"isCustom":false,"isHidden":false}
        """
        let entry = try JSONDecoder().decode(ModelEntry.self, from: json.data(using: .utf8)!)
        #expect(entry.providerInstanceId == "inst-9")
        #expect(entry.baseModel.id == "gpt-4o")
        #expect(entry.overrides.isEmpty)
        #expect(!entry.uuid.isEmpty)
    }

    @Test func modelGroupCodableRoundTrip() throws {
        let group = ModelGroup(
            id: "grp-1",
            name: "Fast fallback",
            memberEntryIds: ["inst-1/gpt-4o-mini", "inst-2/claude-haiku-4-5"],
            strategy: .fallback,
            fallbackStrategy: .limited,
            defaultThinkingLevel: .medium,
            contextLimitTokens: 100_000
        )
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(ModelGroup.self, from: data)
        #expect(decoded == group)
        #expect(decoded.memberEntryIds.count == 2)
        #expect(decoded.strategy == .fallback)
        #expect(decoded.defaultThinkingLevel == .medium)
    }

    @Test func modelGroupDecodesLegacyJSON() throws {
        let json = """
        {"id":"g1","name":"G","memberEntryIds":["a/x"],"strategy":"fallback"}
        """
        let group = try JSONDecoder().decode(ModelGroup.self, from: json.data(using: .utf8)!)
        #expect(group.fallbackStrategy == .limited)
        #expect(group.defaultThinkingLevel == nil)
    }

    @Test func providerConfigCodableRoundTrip() throws {
        let config = ProviderConfig(
            id: "cfg-1",
            label: "Ollama",
            providerType: .local,
            customBaseURL: "http://127.0.0.1:11434",
            appendV1Suffix: false,
            apiKeyEnvVar: "OLLAMA_API_KEY"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.effectiveCustomBaseURL == "http://127.0.0.1:11434")
    }

    @Test func providerConfigDecodesLegacyJSON() throws {
        let json = """
        {"id":"cfg-2","label":"OpenAI","providerType":"openAI","credentialType":"apiKey","isEnabled":true,"createdAt":0,"customBaseURL":null,"appendV1Suffix":true}
        """
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json.data(using: .utf8)!)
        #expect(config.providerType == .openAI)
        #expect(config.appendV1Suffix)
        #expect(config.apiKeyEnvVar == nil)
        #expect(config.apiKey == nil)
    }

    @Test func providerConfigResolvedBaseURL() {
        let noCustom = ProviderConfig(label: "A", providerType: .openAI)
        let (url1, v11) = noCustom.resolvedBaseURL(default: "https://api.openai.com")
        #expect(url1 == "https://api.openai.com")
        #expect(v11)

        let withV1 = ProviderConfig(label: "B", providerType: .openAI, customBaseURL: "https://api.deepseek.com/v1/")
        let (url2, v12) = withV1.resolvedBaseURL(default: "https://x")
        #expect(url2 == "https://api.deepseek.com")
        #expect(v12)

        let verbatim = ProviderConfig(label: "C", providerType: .local, customBaseURL: "http://127.0.0.1:11434", appendV1Suffix: false)
        let (url3, v13) = verbatim.resolvedBaseURL(default: "https://x")
        #expect(url3 == "http://127.0.0.1:11434")
        #expect(!v13)
    }

    @Test func agentMessageParts() {
        let parts: [AgentContentPart] = [
            .text("Let me check"),
            .toolUse(id: "call_1", name: "shell_execute", input: ["command": "ls"]),
        ]
        let msg = AgentMessage(role: .assistant, parts: parts)
        #expect(msg.role == .assistant)
        #expect(msg.parts.count == 2)
        guard case .toolUse(let id, let name, let input) = msg.parts[1] else {
            Issue.record("expected toolUse")
            return
        }
        #expect(id == "call_1")
        #expect(name == "shell_execute")
        #expect(input["command"] as? String == "ls")
    }

    @Test func agentToolDefinitionSerialization() {
        let tool = AgentToolDefinition(
            name: "shell_execute",
            description: "Run a command",
            parameters: [
                "command": AgentToolParam(type: .string, description: "The command"),
                "timeout": AgentToolParam(type: .integer, description: "Seconds"),
                "mode": AgentToolParam(type: .string, description: "Mode", enumValues: ["fast", "safe"]),
            ],
            required: ["command"],
            propertyOrdering: ["command", "timeout", "mode"]
        )

        let openAI = tool.openAIFunctionDict
        #expect(openAI["type"] as? String == "function")
        let fn = openAI["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "shell_execute")
        let params = fn?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let hasCommand = properties?["command"] != nil
        #expect(hasCommand)
        let mode = properties?["mode"] as? [String: Any]
        let modeEnum = mode?["enum"] as? [String]
        #expect(modeEnum == ["fast", "safe"])
        let requiredParams = params?["required"] as? [String]
        #expect(requiredParams == ["command"])

        let anthropic = tool.anthropicToolDict
        #expect(anthropic["name"] as? String == "shell_execute")
        let schema = anthropic["input_schema"] as? [String: Any]
        let schemaType = schema?["type"] as? String
        #expect(schemaType == "object")
        let schemaRequired = schema?["required"] as? [String]
        #expect(schemaRequired == ["command"])
    }

    @Test func agentToolCatalog() {
        let tools = AgentToolCatalog.makeTools()
        // B1j: browser_use placeholder replaced by BrowserTool ("browser"),
        // Speech needs an explicit supported turn snapshot; unknown defaults
        // stay out of the model catalog. MCP tools are dynamic (async discovery).
        // Approved N-02 adds the session-local todo_write tool to the default catalog.
        #expect(tools.map(\.name) == ["file_grep", "file_glob", "todo_write", "shell_execute", "shell_output", "shell_stop", "file_read", "file_write", "file_edit", "file_delete", "session_read", "external_session_read", "external_session_send", "context_compact", "browser"])
        #expect(tools.allSatisfy { !$0.description.isEmpty })
        for tool in tools {
            for req in tool.required {
                #expect(tool.parameters[req] != nil, "\(tool.name) requires unknown param \(req)")
            }
        }
    }
}

// URLBuilding tests moved to URLBuildingTests.swift (QC4: /v1 dedup suite).

struct ProviderFactoryTests {

    @Test func builtInRegistrations() {
        let factory = ProviderFactory()
        for type in [ProviderType.openAI, .anthropic, .openRouter, .openAIResponses, .local] {
            #expect(factory.hasBuilder(for: type), "missing builder for \(type.rawValue)")
        }
        #expect(!factory.hasBuilder(for: .gemini))
    }

    @Test func makeOpenAIProvider() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "OpenAI", providerType: .openAI, apiKey: "test-key")
        let provider = try factory.makeProvider(for: config)
        #expect(provider is OpenAICompatibleProvider)
        #expect(provider.name == "OpenAI")
        #expect(provider.model.id == "gpt-4o-mini")
    }

    @Test func makeAnthropicProvider() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "Anthropic", providerType: .anthropic, apiKey: "test-key")
        let provider = try factory.makeProvider(for: config)
        #expect(provider.name == config.providerType.runtimeProviderID)
        #expect(provider.model.provider == provider.name)
        #expect(provider.model.id == LLMModel.claudeSonnet46.id)
        #expect(provider.capabilities == [.streaming, .tools, .vision])
    }

    @Test func makeLocalProvider() throws {
        let factory = ProviderFactory()
        let config = ProviderConfig(
            label: "Ollama",
            providerType: .local,
            customBaseURL: "http://127.0.0.1:11434",
            appendV1Suffix: false
        )
        let provider = try factory.makeProvider(for: config, requireCredentials: false)
        #expect(provider is LocalProvider, "local provider must conform to LocalProvider")
        #expect((provider as! LocalProvider).baseURL.absoluteString == "http://127.0.0.1:11434")
    }

    @Test func envVarKeyResolution() throws {
        setenv("MINISCORE_TEST_KEY", "env-key-value", 1)
        defer { unsetenv("MINISCORE_TEST_KEY") }

        let factory = ProviderFactory()
        let config = ProviderConfig(label: "Env", providerType: .openAI, apiKeyEnvVar: "MINISCORE_TEST_KEY")
        #expect(config.effectiveAPIKey() == "env-key-value")
        let provider = try factory.makeProvider(for: config)
        #expect(provider is OpenAICompatibleProvider)
    }

    @Test func directKeyWinsOverEnvVar() {
        setenv("MINISCORE_TEST_KEY2", "env-value", 1)
        defer { unsetenv("MINISCORE_TEST_KEY2") }

        let config = ProviderConfig(label: "Both", providerType: .openAI, apiKeyEnvVar: "MINISCORE_TEST_KEY2", apiKey: "direct-value")
        #expect(config.effectiveAPIKey() == "direct-value")
    }

    // `#expect(throws:)` with an enum case carrying associated values does not
    // compile on this toolchain (the macro mis-reads the case as a closure), so
    // these three tests use an explicit do/catch + `if case` pattern match.

    @Test func missingCredentialsThrows() {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "NoKey", providerType: .openAI)
        do {
            _ = try factory.makeProvider(for: config)
            Issue.record("expected noCredentials error")
        } catch let error as ProviderFactory.FactoryError {
            if case .noCredentials = error {} else {
                Issue.record("wrong error: \(error)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func disabledProviderThrows() {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "Off", providerType: .openAI, isEnabled: false, apiKey: "test-key")
        do {
            _ = try factory.makeProvider(for: config)
            Issue.record("expected providerDisabled error")
        } catch let error as ProviderFactory.FactoryError {
            if case .providerDisabled = error {} else {
                Issue.record("wrong error: \(error)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func unregisteredTypeThrows() {
        let factory = ProviderFactory()
        let config = ProviderConfig(label: "Gemini", providerType: .gemini, apiKey: "test-key")
        do {
            _ = try factory.makeProvider(for: config)
            Issue.record("expected noBuilder error")
        } catch let error as ProviderFactory.FactoryError {
            if case .noBuilder = error {} else {
                Issue.record("wrong error: \(error)")
            }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func customRegistrationOverride() throws {
        let factory = ProviderFactory()
        let marker = "custom-flag"
        factory.register(.openAI) { _ in
            CustomTestProvider(marker: marker)
        }
        let config = ProviderConfig(label: "Custom", providerType: .openAI, apiKey: "test-key")
        let provider = try factory.makeProvider(for: config)
        let custom = provider as? CustomTestProvider
        #expect(custom?.marker == marker)
    }

    @Test func unregister() {
        let factory = ProviderFactory()
        #expect(factory.hasBuilder(for: .openAI))
        factory.unregister(.openAI)
        #expect(!factory.hasBuilder(for: .openAI))
    }

    @Test func registeredTypesSorted() {
        let factory = ProviderFactory()
        let types = factory.registeredTypes
        #expect(types == types.sorted { $0.rawValue < $1.rawValue })
        #expect(types.contains(.anthropic))
    }
}

/// Minimal LLMProvider used to verify factory custom-registration.
private final class CustomTestProvider: LLMProvider {
    let name = "Custom"
    var model: LLMModel = .gpt4oMini
    let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        LLMResponse(text: marker, stopReason: nil, usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(marker))
            continuation.finish()
        }
    }
}
