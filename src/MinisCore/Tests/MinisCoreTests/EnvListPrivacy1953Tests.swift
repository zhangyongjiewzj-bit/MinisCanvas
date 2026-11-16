import Foundation
import Testing
@testable import MinisCore

@Suite("TASK1953 env.list synthetic privacy boundary")
struct EnvListPrivacy1953Tests {
    @Test func listHidesUnapprovedValuesAndKeepsExplicitPublicValue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvListPrivacy1953-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "EnvListPrivacy1953.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let privacy = EnvVarPrivacyStore(defaults: defaults)
        let env = EnvVarStore(
            directory: directory,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            privacyStore: privacy
        )
        let protected = [
            "SECRET_TEST": "synthetic-secret-test-1953",
            "TOKEN": "synthetic-token-1953",
            "PASSWORD": "synthetic-password-1953",
            "SERVICE_CREDENTIAL_BLOB": "synthetic-credential-1953",
            "OPAQUE_SLOT": "synthetic-unclassified-1953",
        ]
        for (name, value) in protected {
            #expect(env.setEnvVar(name: name, value: value))
        }
        privacy.unmarkSecret(name: "USER_LABEL")
        #expect(env.setEnvVar(name: "USER_LABEL", value: "synthetic-public-1953"))

        let backends = LocalBackends(configs: Dictionary(uniqueKeysWithValues:
            LocalBackendKind.allCases.map {
                ($0, LocalBackendConfig(kind: $0, baseURL: $0.defaultBaseURL, enabled: false))
            }))
        let deps = CommandDependencies(
            env: env,
            log: LogManager(directory: directory),
            backends: backends,
            sessions: SessionStore(directory: directory),
            memory: MemoryStore(directory: directory),
            workflows: WorkflowStore(storeDirectory: directory.appendingPathComponent("Workflows"))
        )
        let result = try await CommandRegistry(commands: PresetCommands.all(dependencies: deps))
            .execute(id: "env.list")
        #expect(result.ok)
        for (name, value) in protected {
            #expect(result.text.contains(name))
            #expect(!result.text.contains(value))
        }
        #expect(result.text.contains("OPAQUE_SLOT = [hidden]"))
        #expect(result.text.contains("USER_LABEL = synthetic-public-1953"))

        // New name-classified credentials use the existing Keychain-backed
        // metadata projection; no process environment or real Keychain is read.
        let metadata = String(decoding: try Data(contentsOf:
            directory.appendingPathComponent(EnvVarStore.fileName)), as: UTF8.self)
        for name in ["SECRET_TEST", "TOKEN", "PASSWORD", "SERVICE_CREDENTIAL_BLOB"] {
            #expect(env.entry(name: name)?.isSecret == true)
            let value = try #require(protected[name])
            #expect(!metadata.contains(value))
        }
        #expect(env.entry(name: "USER_LABEL")?.isSecret == false)
    }
}
