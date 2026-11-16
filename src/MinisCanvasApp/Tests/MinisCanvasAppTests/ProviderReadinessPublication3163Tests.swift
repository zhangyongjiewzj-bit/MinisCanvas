import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// D-PROVIDER-07/09/17: actual Settings publisher and the main picker consume
/// the same owned stores. The transport holds real entry-point awaits; it does
/// not publish readiness itself or claim a remote model understood a request.
@Suite("Provider readiness publication identity 3163", .serialized)
@MainActor
struct ProviderReadinessPublication3163Tests {
    @Test("deleted provider cannot be revived by a late directory result", arguments: [200, 503])
    func deletedProviderRejectsLateDiscovery(statusCode: Int) async throws {
        let transport = ControlledTransport(heldOperation: .modelDiscovery, heldCount: 1)
        let f = try Fixture(transport: transport)
        let task = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(1)
        let preview = try f.center.previewProviderDeletion(name: Fixture.providerName)
        let approved = preview.withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try f.center.deleteProvider(name: Fixture.providerName, intent: approved)
        let afterDelete = try f.readinessBytes()
        #expect(f.center.providerRecords.isEmpty)
        #expect(f.center.providerReadinessStore.records.isEmpty)
        await transport.release(1, statusCode: statusCode)
        let result = await task.value
        #expect(result == nil)
        #expect(f.center.providerReadinessStore.records.isEmpty)
        #expect(f.center.chatModelPickerProjection.items.isEmpty)
        #expect(f.center.chatModelPickerProjection.pending.isEmpty)
        #expect(f.center.providerReadinessReport(for: f.provider) == nil)
        #expect(f.chat.chatProviderOptions.allSatisfy { $0.id != "custom." + Fixture.providerName })
        #expect(ModelPickerPanel.readinessFilteredModels(for: .custom(f.provider), chat: f.chat).isEmpty)
        #expect(!f.chat.applyChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        #expect(try f.readinessBytes() == afterDelete)
        #expect(await transport.operations() == [.reachability, .authentication, .modelDiscovery])
    }

    @Test("older failure cannot overwrite the newer successful report and picker")
    func olderFailureCannotInvalidateNewerSuccess() async throws {
        let transport = ControlledTransport(heldOperation: .modelDiscovery, heldCount: 1)
        let f = try Fixture(transport: transport)
        let old = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(1)
        let fresh = await f.center.checkProviderReadiness(forProviderName: Fixture.providerName)
        #expect(fresh?.state == .mock)
        #expect(f.center.providerReadinessReport(for: f.provider)?.checkedAt == fresh?.checkedAt)
        #expect(ModelPickerPanel.readinessFilteredModels(for: .custom(f.provider), chat: f.chat).map(\.id) == [Fixture.modelID])
        #expect(f.chat.applyChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        let currentBytes = try f.readinessBytes()
        await transport.release(1, statusCode: 503)
        let obsolete = await old.value
        #expect(obsolete == nil)
        #expect(f.center.providerReadinessReport(for: f.provider)?.checkedAt == fresh?.checkedAt)
        #expect(try f.readinessBytes() == currentBytes)
        #expect(f.chat.canSelectChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        #expect(f.chat.chatProviderOptions.contains { $0.id == "custom." + Fixture.providerName })
        #expect(!f.center.isCheckingProviderReadiness)
        #expect(f.center.providerReadinessCheckingProviderID == nil)
    }

    @Test("older completion cannot clear the new probe's loading identity")
    func olderCompletionDoesNotClearNewProbe() async throws {
        let transport = ControlledTransport(heldOperation: .reachability, heldCount: 2)
        let f = try Fixture(transport: transport)
        let old = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(1)
        let fresh = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(2)
        await transport.release(1, statusCode: 503)
        let obsolete = await old.value
        #expect(obsolete == nil)
        #expect(f.center.isCheckingProviderReadiness)
        #expect(f.center.providerReadinessCheckingProviderID == f.provider.id)
        await transport.release(2, statusCode: 200)
        let result = await fresh.value
        #expect(result?.state == .mock)
        #expect(!f.center.isCheckingProviderReadiness)
        #expect(f.center.providerReadinessCheckingProviderID == nil)
        #expect(f.chat.canSelectChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
    }

    @Test("same current cancelled probe settles typed cancellation even when transport returns late success")
    func currentCancellationInvalidatesOldPass() async throws {
        let transport = ControlledTransport(heldOperation: .reachability, heldCount: 2)
        let f = try Fixture(transport: transport)
        let seed = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(1)
        await transport.release(1, statusCode: 200)
        let seedResult = await seed.value
        #expect(seedResult?.state == .mock)
        #expect(f.chat.canSelectChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        let current = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(2)
        current.cancel()
        await transport.release(2, statusCode: 200)
        let result = await current.value
        #expect(result?.reachability.status == .cancelled)
        #expect(f.center.providerReadinessStore.records.first?.status == .unavailable)
        #expect(!f.chat.canSelectChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        #expect(!f.center.isCheckingProviderReadiness)
        #expect(f.center.providerReadinessCheckingProviderID == nil)
        #expect(await transport.operations() == [.reachability, .authentication, .modelDiscovery,
            .minimalModelRequest(Fixture.modelID), .reachability])
    }

    @Test("cancelled obsolete probe cannot invalidate a newer success")
    func obsoleteCancellationCannotInvalidateNewerSuccess() async throws {
        let transport = ControlledTransport(heldOperation: .reachability, heldCount: 1)
        let f = try Fixture(transport: transport)
        let old = Task { await f.center.checkProviderReadiness(forProviderName: Fixture.providerName) }
        await transport.waitUntilHeld(1)
        let fresh = await f.center.checkProviderReadiness(forProviderName: Fixture.providerName)
        #expect(fresh?.state == .mock)
        let currentBytes = try f.readinessBytes()
        old.cancel()
        await transport.release(1, statusCode: 200)
        let obsolete = await old.value
        #expect(obsolete == nil)
        #expect(f.center.providerReadinessReport(for: f.provider)?.checkedAt == fresh?.checkedAt)
        #expect(try f.readinessBytes() == currentBytes)
        #expect(f.chat.canSelectChatModel(providerID: Fixture.providerName, modelID: Fixture.modelID))
        #expect(!f.center.isCheckingProviderReadiness)
        #expect(f.center.providerReadinessCheckingProviderID == nil)
    }

    @MainActor
    private struct Fixture {
        static let providerName = "OWNED_3163_PROVIDER"
        static let modelID = "owned-3163-model"
        let root: URL
        let center: SettingsCenter
        let chat: ChatStore
        let provider: EnvVarEntry

        init(transport: any SettingsProviderReadinessTransport) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider3163-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let keychain = KeychainStore(backing: InMemoryKeychainBacking())
            let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("provider"))
            let log = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20)
            let domain = "provider3163." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: domain))
            center = SettingsCenter(
                settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
                envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
                logManager: log,
                mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
                skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: .suite(domain)),
                providerReadinessTransport: transport,
                providerReadinessDeployment: .mock,
                providerReadinessStore: readiness
            )
            #expect(center.saveProvider(name: Self.providerName, apiKey: "synthetic-3163-input",
                baseURL: "https://fixture.invalid/v1", modelNames: [Self.modelID], protocolType: .openaiCompatible))
            provider = try #require(center.providerRecords.first)
            chat = ChatStore(providerReadinessStore: readiness, preferencesDefaults: defaults, logManager: log)
            let settings = center
            chat.providerRecordsSource = { settings.providerRecords }
        }

        func readinessBytes() throws -> Data {
            try Data(contentsOf: root.appendingPathComponent("provider")
                .appendingPathComponent(ProviderReadinessStore.fileName))
        }
    }

    private actor ControlledTransport: SettingsProviderReadinessTransport {
        let heldOperation: ProviderReadinessOperation
        let heldCount: Int
        private var ordinal = 0
        private var requests: [ProviderReadinessOperation] = []
        private var held: [Int: CheckedContinuation<ProviderReadinessTransportResponse, Never>] = [:]
        private var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]

        init(heldOperation: ProviderReadinessOperation, heldCount: Int) {
            self.heldOperation = heldOperation
            self.heldCount = heldCount
        }

        func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
            requests.append(request.operation)
            if request.operation == heldOperation {
                ordinal += 1
                let index = ordinal
                if index <= heldCount {
                    return await withCheckedContinuation { continuation in
                        held[index] = continuation
                        for observer in observers.removeValue(forKey: index) ?? [] { observer.resume() }
                    }
                }
            }
            return response(statusCode: 200)
        }

        func waitUntilHeld(_ index: Int) async {
            if held[index] != nil { return }
            await withCheckedContinuation { observers[index, default: []].append($0) }
        }

        func release(_ index: Int, statusCode: Int) {
            held.removeValue(forKey: index)?.resume(returning: response(statusCode: statusCode))
        }

        func operations() -> [ProviderReadinessOperation] { requests }

        private func response(statusCode: Int) -> ProviderReadinessTransportResponse {
            ProviderReadinessTransportResponse(statusCode: statusCode, modelIDs: ["owned-3163-model"])
        }
    }
}
