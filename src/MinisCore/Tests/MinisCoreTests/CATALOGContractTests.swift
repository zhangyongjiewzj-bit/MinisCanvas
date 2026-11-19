import Foundation
import Testing
import MinisCore

@Suite("Catalog public value and persistence contracts", .serialized)
struct CATALOGContractTests {
    @Test("Reasoning levels expose the declared order and labels")
    func thinkingLevels() {
        #expect(ThinkingLevel.allCases == [.off, .low, .medium, .high, .xhigh, .max, .ultra])
        #expect(ThinkingLevel.medium.displayName == "Med")
        #expect(!ThinkingLevel.off.isEnabled)
        #expect(ThinkingLevel.low < .ultra)
        #expect(!(ThinkingLevel.high < .high))
    }

    @Test("Fallback parsing is distinct from strict Codable")
    func strictThinkingDecode() throws {
        #expect(ThinkingLevel.decoded(" high ") == .xhigh)
        #expect(ThinkingLevel(rawValue: " high ") == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ThinkingLevel.self, from: Data("\" high \"".utf8))
        }
        let encoded = try JSONEncoder().encode(ThinkingLevel.ultra)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"ultra\"")
    }

    @Test("Provider identity preserves raw values and explicit runtime mapping")
    func providerTypes() throws {
        #expect(ProviderType.decoded("openAI") == .openAI)
        #expect(ProviderType.decoded("OpenAI") == .unsupported)
        #expect(ProviderType.openAIResponses.runtimeProviderID == "OpenAIResponses")
        #expect(ProviderType.gemini.defaultModality == .fullMultimodal)
        #expect(ProviderType.local.builtInModels.isEmpty)
        let encoded = try JSONEncoder().encode(ProviderCredential.oauth)
        #expect(try JSONDecoder().decode(ProviderCredential.self, from: encoded) == .oauth)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderType.self, from: Data("\"unknown\"".utf8))
        }
    }

    @Test("Config serialization excludes runtime secrets and capabilities")
    func configTransientPersistence() throws {
        var config = ProviderConfig(id: "synthetic", label: "  label  ", providerType: .deepSeek,
            apiKeyEnvVar: "  SYNTHETIC_REFERENCE_API_KEY  ", apiKey: "  SYNTHETIC_DIRECT_VALUE  ",
            attemptCheckpointDirectory: URL(fileURLWithPath: "/synthetic/checkpoint"))
        config.controlledFieldLoopbackOnly = true
        #expect(config.effectiveAPIKey() == "SYNTHETIC_DIRECT_VALUE")
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["apiKey"] == nil)
        #expect(object["attemptCheckpointDirectory"] == nil)
        #expect(object["controlledFieldLoopbackOnly"] == nil)
        let restored = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(restored.apiKey == nil)
        #expect(restored.attemptCheckpointDirectory == nil)
        #expect(!restored.controlledFieldLoopbackOnly)
        #expect(restored.label == "  label  ")
        #expect(restored.apiKeyEnvVar == "SYNTHETIC_REFERENCE_API_KEY")
        #expect(restored != config)
    }

    @Test("Legacy aliases recover references without reviving injected fields")
    func legacyConfigDecode() throws {
        let data = Data("""
        {"id":"legacy","label":"legacy","providerType":"HERMES_CUSTOM_DEEPSEEK_API_KEY",
         "apiKeyEnvVar":"  ","apiKey":"SYNTHETIC_UNTRUSTED_VALUE",
         "controlledFieldLoopbackOnly":true,"attemptCheckpointDirectory":"file:///synthetic"}
        """.utf8)
        let restored = try JSONDecoder().decode(ProviderConfig.self, from: data)
        #expect(restored.providerType == .deepSeek)
        #expect(restored.apiKeyEnvVar == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(restored.apiKey == nil)
        #expect(restored.attemptCheckpointDirectory == nil)
        #expect(!restored.controlledFieldLoopbackOnly)
        #expect(restored.isEnabled && restored.appendV1Suffix)
        #expect(restored.credentialType == .apiKey)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderConfig.self,
                from: Data("{\"id\":\"bad\",\"label\":\"bad\",\"providerType\":\"deepSeek\",\"isEnabled\":\"yes\"}".utf8))
        }
    }

    @Test("Canonical merge preserves the first record and legacy reference")
    func canonicalMerge() {
        let first = ProviderConfig(id: "first", label: " ", providerType: .deepSeek,
            isEnabled: false, customBaseURL: "", apiKeyEnvVar: "DEEPSEEK_API_KEY")
        let unrelated = ProviderConfig(id: "other", label: "other", providerType: .openAI)
        let second = ProviderConfig(id: "second", label: "adopted", providerType: .deepSeek,
            customBaseURL: "https://example.invalid", apiKeyEnvVar: "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        let merged = ProviderConfig.mergeCanonical([first, unrelated, second])
        #expect(merged.map(\.id) == ["first", "other"])
        #expect(merged[0].label == "adopted")
        #expect(merged[0].customBaseURL == "")
        #expect(merged[0].apiKeyEnvVar == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(merged[0].isEnabled)
        #expect(first.merged(with: unrelated) == first)
    }

    @Test("Endpoint normalization removes one trailing slash without recursion")
    func endpointSelection() {
        var config = ProviderConfig(label: "synthetic", providerType: .openRouter,
            customBaseURL: " https://example.invalid/api/v1// ")
        #expect(config.resolvedBaseURL(default: "unused").url == "https://example.invalid/api/v1/")
        #expect(config.runtimeConfigurationMaterial == "https://example.invalid/api/v1//|append-v1=false")
        config.appendV1Suffix = false
        let unchanged = config.resolvedBaseURL(default: "unused")
        #expect(unchanged.url == "https://example.invalid/api/v1//" && !unchanged.appendV1)
        config.customBaseURL = nil
        let fallback = config.resolvedBaseURL(default: "https://example.invalid/api/v1/")
        #expect(fallback.url == "https://example.invalid/api" && fallback.appendV1)
    }

    @Test("Credential names distinguish syntax, admission and noncredential scopes")
    func environmentIdentity() throws {
        #expect(EnvCredentials.canonicalName("  paper_api_key\n") == "PAPER_API_KEY")
        #expect(EnvCredentials.canonicalName("_PAPER_API_KEY") == nil)
        #expect(EnvCredentials.canonicalName("纸_API_KEY") == nil)
        #expect(throws: EnvCredentialsError.disallowedName) { try EnvCredentials.identity(for: "PATH") }
        #expect(try EnvCredentials.identity(for: "F6_TEST_API_KEY").scope == .testFixture)
        #expect(EnvCredentials.apiKey(envVar: "F6_TEST_API_KEY") == nil)
        let identity = try EnvCredentials.identity(for: "paper_accesskey")
        #expect(identity.scope == .accessKey)
        #expect(try JSONDecoder().decode(EnvCredentialIdentity.self,
            from: JSONEncoder().encode(identity)) == identity)
    }

    @Test("Configured record lookup requires exact current authority and skips process values")
    func configuredCredential() {
        let record = EnvVarEntry(id: "synthetic-authorized", name: "PAPER_CUSTOM", value: " ",
            isSecret: true, baseURL: "https://example.invalid")
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: record) == " ")
        var stale = record
        stale.modelNames = ["different"]
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: stale) == nil)
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: nil) == nil)
        var endpoint = record
        endpoint.name = "PAPER_BASE_URL"
        #expect(EnvCredentials.configuredProviderCredential(for: endpoint, current: endpoint) == nil)
    }

    @Test("MCP conversion preserves binding identity and schema ordering")
    func mcpConversion() throws {
        let tool = MCPTool(name: "native_name", inputSchema: .object([
            "properties": .object([
                "z": .object(["type": .string("number")]),
                "a": .object(["enum": .array([.string("second"), .string("first")])])
            ]),
            "required": .array([.string("z"), .string("a")])
        ]))
        let definitions = try AgentToolCatalog.makeMCPToolDefinitions([
            MCPBoundTool(fullName: " exact_binding ", serverID: "synthetic-server", tool: tool)
        ])
        let definition = try #require(definitions.first)
        #expect(definition.name == " exact_binding ")
        #expect(definition.propertyOrdering == ["a", "z"])
        #expect(definition.required == ["z", "a"])
        #expect(definition.parameters["z"]?.type == .number)
        #expect(definition.parameters["a"]?.enumValues == ["second", "first"])
        #expect(definition.description.contains("synthetic-server"))
    }

    @Test("One malformed MCP schema only skips that tool")
    func invalidMCPBatch() throws {
        let good = MCPBoundTool(fullName: "good", serverID: "synthetic", tool: MCPTool(name: "good"))
        // 11/16：单个工具的 schema 损坏（properties 不是对象）只跳过该工具，其余照常可用。
        let invalid = MCPBoundTool(fullName: "bad", serverID: "synthetic", tool: MCPTool(name: "bad",
            inputSchema: .object(["properties": .string("not-an-object")])))
        let result = try AgentToolCatalog.makeMCPToolDefinitionsReportingSkipped([good, invalid])
        #expect(result.definitions.map(\.name) == ["good"])
        #expect(result.skippedToolNames == ["bad"])
    }

    @Test("Local catalog has baseline prefix and does not expose unavailable speech")
    func localCatalog() {
        let tools = AgentToolCatalog.makeTools(browserGrant: .readOnly, speechAvailability: nil)
        #expect(Array(tools.prefix(2).map(\.name)) == ["file_grep", "file_glob"])
        #expect(!tools.contains(where: { $0.name == "speech" }))
        #expect(AgentToolCatalog.implementedNativeToolNames == Set([
            "file_grep", "file_glob", "todo_write", "shell_execute", "shell_output", "shell_stop",
            "file_read", "file_write", "web_fetch",
            "file_edit", "file_delete", "session_read", "external_session_read", "external_session_send", "session_send", "task_board", "context_compact", "browser", "speech",
            "skill_create", "skill_update", "skill_delete"
        ]))
        #expect(Array(tools.prefix(3).map(\.name)) == ["file_grep", "file_glob", "todo_write"])
        #expect(tools.filter { $0.name == SessionTodoProgress.toolName } == [SessionTodoProgress.definition()])
        let settings = AgentToolCatalog.makeTools(orchestration: nil, settingsAvailable: true)
        #expect(Array(settings.suffix(2).map(\.name)) == ["settings_catalog", "conversation_settings"])
    }

    @Test("Canonical todo survives synchronous variants without deduplicating extra definitions")
    func todoSynchronousVariants() {
        let canonical = SessionTodoProgress.definition()
        let extra = AgentToolDefinition(name: SessionTodoProgress.toolName,
            description: "Synthetic caller definition", parameters: [:], required: [])
        let variants = [
            AgentToolCatalog.makeTools(),
            AgentToolCatalog.makeTools(orchestration: nil, settingsAvailable: true),
            AgentToolCatalog.makeTools(orchestration: nil,
                browserGrant: BrowserCapabilityGrant(capability: "browser.write", approvalReceipt: "synthetic-receipt"),
                speechAvailability: nil)
        ]
        for tools in variants {
            #expect(tools.filter { $0.name == canonical.name } == [canonical])
            #expect(Array(tools.prefix(3)) == ReadOnlyFileSearch.definitions() + [canonical])
        }
        let withExtra = AgentToolCatalog.makeTools(orchestration: extra)
        #expect(withExtra.filter { $0.name == canonical.name } == [canonical, extra])
        #expect(withExtra.last == extra)
    }

    @Test("Async discovery keeps canonical todo on local fallback and still throws cancellation")
    func todoDiscoveryVariants() async throws {
        let canonical = SessionTodoProgress.definition()
        let variants = [
            try await AgentToolCatalog.makeTools(includingMCPFrom: nil),
            try await AgentToolCatalog.makeTools(includingMCPFrom: nil, orchestration: nil, settingsAvailable: true),
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .empty)),
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .failure), orchestration: nil)
        ]
        for tools in variants {
            #expect(tools.filter { $0.name == canonical.name } == [canonical])
            #expect(Array(tools.prefix(3)) == ReadOnlyFileSearch.definitions() + [canonical])
        }
        await #expect(throws: CancellationError.self) {
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .cancelled))
        }
    }

    @Test("Skill maintenance is hidden by default and appends canonical definitions before browser")
    func skillMaintenanceVisibility() throws {
        let hidden = AgentToolCatalog.makeTools()
        #expect(hidden.allSatisfy { !SkillMaintenanceTool.names.contains($0.name) && $0.name != SkillMaintenanceTool.readName })
        let definitions = SkillMaintenanceTool.definitions()
        // 第七版：只读的 skill_read 排在三个修改类工具之前，一起出现在目录里。
        #expect(definitions.first?.name == SkillMaintenanceTool.readName)
        let enabled = AgentToolCatalog.makeTools(skillMaintenanceAvailable: true)
        let browserIndex = try #require(hidden.firstIndex { $0.name == "browser" })
        let expected = Array(hidden[..<browserIndex]) + definitions + Array(hidden[browserIndex...])
        #expect(enabled == expected)
        #expect(enabled.filter { SkillMaintenanceTool.names.contains($0.name) || $0.name == SkillMaintenanceTool.readName } == definitions)
        #expect(enabled.filter { $0.name == SessionTodoProgress.toolName } == [SessionTodoProgress.definition()])
        let extra = AgentToolDefinition(name: "skill_create", description: "Synthetic extra definition",
                                       parameters: [:], required: [])
        let extended = AgentToolCatalog.makeTools(orchestration: extra, settingsAvailable: true,
                                                 skillMaintenanceAvailable: true)
        #expect(Array(extended.prefix(enabled.count)) == enabled)
        #expect(extended[enabled.count] == extra)
        #expect(Array(extended.suffix(2).map(\.name)) == ["settings_catalog", "conversation_settings"])
    }

    @Test("MCP local fallback preserves maintenance selection and cancellation remains an error")
    func skillMaintenanceDiscovery() async throws {
        let expected = AgentToolCatalog.makeTools(orchestration: nil, settingsAvailable: true,
                                                  skillMaintenanceAvailable: true)
        let variants = [
            try await AgentToolCatalog.makeTools(includingMCPFrom: nil, orchestration: nil,
                settingsAvailable: true, skillMaintenanceAvailable: true),
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .empty),
                orchestration: nil, settingsAvailable: true, skillMaintenanceAvailable: true),
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .failure),
                orchestration: nil, settingsAvailable: true, skillMaintenanceAvailable: true)
        ]
        for tools in variants { #expect(tools == expected) }
        let hiddenFallback = try await AgentToolCatalog.makeTools(
            includingMCPFrom: TodoDiscoveryBridge(outcome: .failure), orchestration: nil)
        #expect(hiddenFallback == AgentToolCatalog.makeTools())
        await #expect(throws: CancellationError.self) {
            try await AgentToolCatalog.makeTools(includingMCPFrom: TodoDiscoveryBridge(outcome: .cancelled),
                orchestration: nil, skillMaintenanceAvailable: true)
        }
    }

    private struct TodoDiscoveryBridge: MCPToolBridge {
        enum Outcome: Sendable { case empty, failure, cancelled }
        let outcome: Outcome

        func mcpBoundTools() async throws -> [MCPBoundTool] {
            switch outcome {
            case .empty: return []
            case .failure: throw MCPClientError.timeout("synthetic discovery failure")
            case .cancelled: throw CancellationError()
            }
        }

        func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
            throw MCPClientError.toolNotFound(fullName)
        }
    }

}
