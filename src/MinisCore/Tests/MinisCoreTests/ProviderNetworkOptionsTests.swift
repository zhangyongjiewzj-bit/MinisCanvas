import Foundation
import Testing
@testable import MinisCore

/// E3：服务商自定义请求头与代理。
@Suite("Provider network options")
struct ProviderNetworkOptionsTests {
    private func openAIConfig(_ options: ProviderNetworkOptions) -> ProviderConfig {
        var config = ProviderConfig(label: "Custom", providerType: .openAI, customBaseURL: "https://example.com")
        config.apiKey = "test-key-not-real"
        config.networkOptions = options
        return config
    }

    @Test func reservedAndInvalidHeadersAreNeverSent() {
        let headers = [
            ProviderCustomHeader(name: "Authorization", value: "Bearer evil"),
            ProviderCustomHeader(name: "x-API-key", value: "evil"),
            ProviderCustomHeader(name: "Content-Type", value: "text/plain"),
            ProviderCustomHeader(name: "Bad Name", value: "x"),
            ProviderCustomHeader(name: "X-Org-Id", value: "line1\nline2"),
            ProviderCustomHeader(name: "X-Org-Id", value: "org-42"),
        ]
        let resolved = ProviderNetworkOptionsPolicy.resolvedHeaders(headers)
        #expect(resolved == ["X-Org-Id": "org-42"])
        #expect(ProviderNetworkOptionsPolicy.issue(for: headers[0]) == .reservedName)
        #expect(ProviderNetworkOptionsPolicy.issue(for: headers[1]) == .reservedName)
        #expect(ProviderNetworkOptionsPolicy.issue(for: headers[3]) == .invalidName)
    }

    @Test func envVarHeaderValuesResolveAtRuntimeAndSkipWhenUnset() {
        let headers = [
            ProviderCustomHeader(name: "X-Team-Token", value: "TEAM_TOKEN", valueIsEnvVar: true),
            ProviderCustomHeader(name: "X-Missing", value: "MISSING_TOKEN", valueIsEnvVar: true),
        ]
        let resolved = ProviderNetworkOptionsPolicy.resolvedHeaders(headers) { name in
            name == "TEAM_TOKEN" ? "secret-from-env" : nil
        }
        #expect(resolved == ["X-Team-Token": "secret-from-env"])
    }

    @Test func factoryInjectsCustomHeadersWithoutTouchingAuthHeaders() throws {
        let options = ProviderNetworkOptions(headers: [
            ProviderCustomHeader(name: "X-Org-Id", value: "org-42"),
            ProviderCustomHeader(name: "Authorization", value: "Bearer evil"),
        ])
        let provider = try ProviderFactory().makeProvider(for: openAIConfig(options))
        let openAI = try #require(provider as? OpenAICompatibleProvider)
        #expect(openAI.extraHeaders == ["X-Org-Id": "org-42"])
    }

    @Test func factoryInjectsCustomHeadersForAnthropic() throws {
        var config = ProviderConfig(label: "Claude", providerType: .anthropic)
        config.apiKey = "test-key-not-real"
        config.networkOptions = ProviderNetworkOptions(headers: [
            ProviderCustomHeader(name: "X-Org-Id", value: "org-42"),
            ProviderCustomHeader(name: "anthropic-version", value: "1999-01-01"),
        ])
        let provider = try ProviderFactory().makeProvider(for: config)
        // Anthropic 被工厂身份包装；这里只确认构造成功且不因被拒绝的头失败。
        #expect(provider.name == config.providerType.runtimeProviderID)
    }

    @Test func proxyDictionaryMatchesMode() throws {
        #expect(try ProviderNetworkOptionsPolicy.proxyDictionary(for: .system) == nil)
        let direct = try #require(try ProviderNetworkOptionsPolicy.proxyDictionary(for: ProviderProxySetting(mode: .direct)))
        #expect(direct.isEmpty)
        let custom = try #require(try ProviderNetworkOptionsPolicy.proxyDictionary(
            for: ProviderProxySetting(mode: .custom, url: "http://127.0.0.1:7890")))
        #expect(custom["HTTPProxy"] as? String == "127.0.0.1")
        #expect(custom["HTTPPort"] as? Int == 7890)
        #expect(custom["HTTPSProxy"] as? String == "127.0.0.1")
        #expect(custom["HTTPSPort"] as? Int == 7890)
    }

    @Test func invalidCustomProxyFailsInsteadOfFallingBack() {
        for bad in ["", "socks5://127.0.0.1:1080", "http://user:pw@127.0.0.1:7890", "not a url", "http://"] {
            #expect(throws: ProviderNetworkOptionsPolicy.ProxyFailure.self) {
                _ = try ProviderNetworkOptionsPolicy.proxyDictionary(for: ProviderProxySetting(mode: .custom, url: bad))
            }
        }
        let config = openAIConfig(ProviderNetworkOptions(proxy: ProviderProxySetting(mode: .custom, url: "ftp://x")))
        #expect(throws: ProviderFactory.FactoryError.invalidProxy("Custom")) {
            _ = try ProviderFactory().makeProvider(for: config)
        }
    }

    @Test func proxyEntersURLSessionConfiguration() throws {
        let session = try #require(try ProviderNetworkOptionsPolicy.makeSession(
            for: ProviderProxySetting(mode: .custom, url: "https://proxy.example.com:8443")))
        let dictionary = try #require(session.configuration.connectionProxyDictionary)
        #expect(dictionary["HTTPSProxy"] as? String == "proxy.example.com")
        #expect(dictionary["HTTPSPort"] as? Int == 8443)
        #expect(try ProviderNetworkOptionsPolicy.makeSession(for: .system) == nil)
    }

    @Test func legacyConfigAndRecordJSONStillDecode() throws {
        // 默认配置不写 networkOptions，其编码结果就是旧配置的字节形态。
        let legacyConfig = try JSONEncoder().encode(ProviderConfig(label: "L", providerType: .openAI))
        let config = try JSONDecoder().decode(ProviderConfig.self, from: legacyConfig)
        #expect(config.networkOptions == .default)

        let legacyEntry = #"{"id":"a","name":"X_API_KEY","value":"","isSecret":true,"createdAt":0}"#
        let entry = try JSONDecoder().decode(EnvVarEntry.self, from: Data(legacyEntry.utf8))
        #expect(entry.networkOptions == nil)
    }

    @Test func defaultOptionsAreNotEncodedAndCustomOptionsRoundTrip() throws {
        var config = ProviderConfig(label: "L", providerType: .openAI)
        let plain = try JSONEncoder().encode(config)
        #expect(!String(decoding: plain, as: UTF8.self).contains("networkOptions"))

        config.networkOptions = ProviderNetworkOptions(
            headers: [ProviderCustomHeader(name: "X-Org-Id", value: "ORG_TOKEN", valueIsEnvVar: true)],
            proxy: ProviderProxySetting(mode: .custom, url: "http://127.0.0.1:7890"))
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.networkOptions == config.networkOptions)
    }
}
