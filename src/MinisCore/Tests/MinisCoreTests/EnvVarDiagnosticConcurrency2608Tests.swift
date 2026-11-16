import Foundation
import Testing
@testable import MinisCore

@Suite("D-CONC2/4 environment diagnostic publication", .serialized)
struct EnvVarDiagnosticConcurrency2608Tests: Sendable {
    private func fixture() throws -> (EnvVarStore, EnvVarPrivacyStore) {
        let formalRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formalRoot, isDirectory: true)
            .appendingPathComponent("envvar-2608-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let defaults = try #require(UserDefaults(suiteName: "EnvVar2608.\(UUID().uuidString)"))
        let privacy = EnvVarPrivacyStore(defaults: defaults)
        return (EnvVarStore(directory: root,
                           keychain: KeychainStore(backing: InMemoryKeychainBacking()),
                           privacyStore: privacy), privacy)
    }

    @Test func rejectedWritesAndDiagnosticConsumerOverlap() async throws {
        let (store, _) = try fixture()
        // Both real mutation APIs reject before touching metadata or Keychain.
        // The public error projection is also read by SettingsCenter/BL6.
        let counts = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            group.addTask {
                var rejected = 0
                for index in 0..<20_000 {
                    if !store.setEnvVar(name: "NOT A VARIABLE", value: "synthetic-only", isSecret: false) {
                        rejected += 1
                    }
                    if index.isMultiple(of: 32) { await Task.yield() }
                }
                return rejected
            }
            group.addTask {
                var rejected = 0
                for index in 0..<20_000 {
                    if !store.saveProvider(name: "NOT A PROVIDER", credential: .missing,
                                           baseURL: nil, modelNames: [], protocolType: .openaiCompatible) {
                        rejected += 1
                    }
                    if index.isMultiple(of: 32) { await Task.yield() }
                }
                return rejected
            }
            group.addTask {
                var validProjections = 0
                for index in 0..<20_000 {
                    let error = store.lastPersistenceError
                    if error == nil || error == .invalidName { validProjections += 1 }
                    if index.isMultiple(of: 32) { await Task.yield() }
                }
                return validProjections
            }
            var results: [Int] = []
            for await count in group { results.append(count) }
            return results
        }
        #expect(counts.count == 3)
        #expect(counts.allSatisfy { $0 == 20_000 })
        #expect(store.lastPersistenceError == .invalidName)
        #expect(store.allEnvVars.isEmpty)
        #expect(store.lastMetadataRecoveryFailure == nil)
    }

    @Test func completedPrivacyMarkPrecedesActualPreviewConsumer() async throws {
        let (store, privacy) = try fixture()
        let visibleName = "VISIBLE_2608"
        privacy.unmarkSecret(name: visibleName)
        let names = (0..<24).map { "SLOT_2608_\($0)" }
        let allMasked = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for name in names {
                group.addTask {
                    privacy.markSecret(name: name)
                    // Marking has completed before this production preview begins.
                    let preview = store.processEnvironmentImportPreview(source: [name: "synthetic-secret-2608"])
                    return privacy.provenance(name: name) == .explicitSecret
                        && preview.count == 1 && preview[0].isSecretClassified
                        && preview[0].valueDisplay == EnvVarStore.EnvVarProcessImportPreviewItem.redactedValuePlaceholder
                }
            }
            var result = true
            for await masked in group { result = result && masked }
            return result
        }
        #expect(allMasked)
        let visible = store.processEnvironmentImportPreview(source: [visibleName: "synthetic-visible-2608"])
        #expect(visible.first?.valueDisplay == "synthetic-visible-2608")
        #expect(visible.first?.isSecretClassified == false)
        #expect(store.allEnvVars.isEmpty)
    }
}
