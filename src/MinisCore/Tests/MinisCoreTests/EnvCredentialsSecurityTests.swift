import Foundation
import Testing
@testable import MinisCore

@Suite("EnvCredentials security", .serialized)
struct EnvCredentialsSecurityTests {
    private let processName = "ENV_CRED_TEST_API_KEY"
    private let processMarker = ["fixture", "process"].joined(separator: "-")
    private let supplementaryMarker = ["fixture", "supplementary"].joined(separator: "-")

    @Test func canonicalIdentityTrimsAndUppercasesWithoutReadingAValue() throws {
        let identity = try EnvCredentials.identity(for: "  openai_api_key  ")

        #expect(identity.canonicalName == "OPENAI_API_KEY")
        #expect(identity.scope == .apiKey)
        #expect(EnvCredentials.canonicalName("  openai_api_key  ") == "OPENAI_API_KEY")
    }

    @Test func scopeAllowlistSeparatesCredentialsFromEndpointNames() throws {
        let access = try EnvCredentials.identity(for: "volc_accesskey")
        let endpoint = try EnvCredentials.identity(for: "hermes_custom_image2_base_url")

        #expect(access.scope == .accessKey)
        #expect(endpoint.scope == .endpointURL)
        #expect(EnvCredentials.apiKey(envVar: "hermes_custom_image2_base_url") == nil)
        #expect(throws: EnvCredentialsError.disallowedName) {
            try EnvCredentials.identity(for: "arbitrary_runtime_setting")
        }
    }

    @Test func malformedNamesFailClosedBeforeSourceInvocation() {
        let malformed = [
            "../OPENAI_API_KEY",
            "OPENAI/API_KEY",
            "OPENAI\n_API_KEY",
            "ＯＰＥＮＡＩ_API_KEY",
            "",
        ]

        for name in malformed {
            #expect(EnvCredentials.canonicalName(name) == nil)
            #expect(EnvCredentials.resolution(for: name).status == .invalidName)
            #expect(EnvCredentials.value(for: name) == nil)
        }
    }

    @Test func processSourceWinsAndMetadataNeverCarriesTheValue() {
        let original = EnvCredentials.supplementarySource
        defer {
            EnvCredentials.supplementarySource = original
            unsetenv(processName)
        }
        setenv(processName, processMarker, 1)
        EnvCredentials.supplementarySource = { name in
            name == "ENV_CRED_TEST_API_KEY" ? "supplementary-shadow" : nil
        }

        #expect(EnvCredentials.value(for: " env_cred_test_api_key ") == processMarker)
        let metadata = EnvCredentials.resolution(for: " env_cred_test_api_key ")
        #expect(metadata.status == .configured)
        #expect(metadata.source == .process)
        #expect(metadata.identity?.canonicalName == processName)
        #expect(metadata.identity?.scope == .apiKey)
    }

    @Test func supplementaryResolutionUsesOnlyCanonicalNameAndIsDeterministic() {
        let original = EnvCredentials.supplementarySource
        defer {
            EnvCredentials.supplementarySource = original
            unsetenv(processName)
        }
        unsetenv(processName)
        EnvCredentials.supplementarySource = { name in
            name == "ENV_CRED_TEST_API_KEY" ? ["fixture", "supplementary"].joined(separator: "-") : nil
        }

        #expect(EnvCredentials.value(for: " env_cred_test_api_key ") == supplementaryMarker)
        let metadata = EnvCredentials.resolution(for: "env_cred_test_api_key")
        #expect(metadata.status == .configured)
        #expect(metadata.source == .supplementary)
        #expect(metadata.identity?.canonicalName == processName)
    }

    @Test func emptySourcesRemainUnsetAndDoNotProduceAFalsePositive() {
        let original = EnvCredentials.supplementarySource
        defer {
            EnvCredentials.supplementarySource = original
            unsetenv(processName)
        }
        unsetenv(processName)
        EnvCredentials.supplementarySource = { _ in "" }

        #expect(EnvCredentials.value(for: processName) == nil)
        #expect(EnvCredentials.resolution(for: processName).status == .unset)
    }

    @Test func exactGimageModelSettingIsReadableButNeverAnAPIKey() throws {
        let name = "GIMAGE2_MODEL_G2"
        let original = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = original }
        EnvCredentials.supplementarySource = { queried in
            queried == name ? "fixture-model" : nil
        }

        #expect(try EnvCredentials.identity(for: name).scope == .modelConfiguration)
        #expect(EnvCredentials.value(for: name) == "fixture-model")
        #expect(EnvCredentials.apiKey(envVar: name) == nil)
        #expect(EnvCredentials.value(for: "GIMAGE2_MODEL_G3") == nil)
        #expect(EnvCredentials.value(for: "OTHER_MODEL_G2") == nil)
        let configuredAsProvider = EnvVarEntry(
            name: name,
            value: "fixture-model",
            isSecret: true,
            baseURL: "https://provider.example.test/v1",
            modelNames: ["test-model"]
        )
        #expect(EnvCredentials.configuredProviderCredential(
            for: configuredAsProvider,
            current: configuredAsProvider
        ) == nil)
    }

    @Test func customProviderResolutionRequiresMatchingSecretRecordAndControlledSource() {
        let name = "ENV_CRED_TEST_PROVIDER"
        let original = EnvCredentials.supplementarySource
        defer {
            EnvCredentials.supplementarySource = original
            unsetenv(name)
        }
        setenv(name, "process-value-must-not-be-used", 1)
        EnvCredentials.supplementarySource = { queried in
            queried == name ? "fixture-provider-secret" : nil
        }
        let record = EnvVarEntry(
            id: "configured-provider",
            name: name,
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example.test/v1",
            modelNames: ["test-model"]
        )
        #expect(EnvCredentials.value(for: name) == nil)
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: record)
                == "fixture-provider-secret")
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: nil) == nil)

        var changed = record
        changed.name = "OTHER_PROVIDER"
        #expect(EnvCredentials.configuredProviderCredential(for: record, current: changed) == nil)
        changed = record
        changed.isSecret = false
        #expect(EnvCredentials.configuredProviderCredential(for: changed, current: changed) == nil)
        changed = record
        changed.modelNames = []
        changed.baseURL = nil
        #expect(EnvCredentials.configuredProviderCredential(for: changed, current: changed) == nil)
        changed = record
        changed.valueInKeychain = false
        #expect(EnvCredentials.configuredProviderCredential(for: changed, current: changed) == nil)
    }
}
