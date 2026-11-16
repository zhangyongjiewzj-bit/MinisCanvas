import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-CREDI: an explicitly resolved credential is authoritative even below
/// the generic environment-value matching limit. Drive the real Settings
/// producers; no UI, URLSession, process environment, or platform Keychain.
@Suite("575 configured secrets stay outside readiness display state", .serialized)
@MainActor
struct SecretReadinessConsumer575Tests {
    private let providerID = "SYNTHETIC575_API_KEY"
    private let modelID = "synthetic-model575"
    private let ordinary = "public-visible575"

    private func makeCenter(root: URL, domain: String,
                            transport: any SettingsProviderReadinessTransport) throws -> SettingsCenter {
        let defaults = try #require(UserDefaults(suiteName: domain))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                                 privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(domain)),
            providerReadinessTransport: transport,
            providerReadinessDeployment: .remote,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SecretReadiness575-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: ["q8!", "u7%z", "v6!q?", "violet-private575-key"])
    func responseEchoIsMaskedInActualProviderAndSavedModelReports(secret: String) async throws {
        let root = try root()
        let domain = "SecretReadiness575." + UUID().uuidString
        let transport = SyntheticReadiness575Transport(body: ordinary + " " + secret,
                                                       modelID: modelID)
        let center = try makeCenter(root: root, domain: domain, transport: transport)
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        #expect(center.envStore.setEnvVar(name: "PUBLIC575", value: ordinary, isSecret: false))
        try #require(center.saveProvider(name: providerID, apiKey: secret,
                                        baseURL: "https://fixture575.invalid/v1", modelNames: [modelID],
                                        protocolType: .openaiCompatible))
        #expect(await center.envStore.getEnvVarAsync(name: providerID) == secret)
        let record = try #require(center.providerRecords.first { $0.name == providerID })

        let report = try #require(await center.checkProviderReadiness(forProviderName: providerID))
        #expect(center.providerReadinessReport(for: record) == report)
        #expect(!report.redactedResult.contains(secret))
        #expect(report.redactedResult.contains(ContentSecretRedactor.mask(secret)))
        #expect(report.redactedResult.contains(ordinary))
        #expect(!ProviderStatusTextProjection.project(report.redactedResult).contains(secret))
        #expect(report.state == .unverified)
        #expect(report.modelChecks.allSatisfy { $0.readiness?.evidenceID == nil })

        let model = try #require(await center.checkProviderModelReadiness(forProviderName: providerID,
                                                                          modelID: modelID))
        #expect(center.providerModelReadiness(for: record, modelID: modelID) == model)
        #expect(model.status == .passed && model.readiness?.state == .unverified)
        #expect(model.readiness?.evidenceID == nil)
        #expect(model.redactedResult == ordinary + " " + ContentSecretRedactor.mask(secret))
        #expect(!model.redactedResult.contains(secret))
        #expect(!ProviderStatusTextProjection.project(model.redactedResult).contains(secret))
        #expect(center.envStore.entry(name: "PUBLIC575")?.value == ordinary)
        #expect(center.envStore.entry(name: "PUBLIC575")?.isSecret == false)
        let readinessBytes = try Data(contentsOf: root.appendingPathComponent("readiness")
            .appendingPathComponent(ProviderReadinessStore.fileName))
        #expect(!String(decoding: readinessBytes, as: UTF8.self).contains(secret))
        let reopened = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        #expect(reopened.records == center.providerReadinessStore.records)
        #expect(reopened.records.allSatisfy { $0.evidenceID == nil && $0.readinessState == .unverified })
        let requests = await transport.requests()
        #expect(requests.map(\.operation) == [.reachability, .authentication, .modelDiscovery,
                                             .minimalModelRequest(modelID), .minimalModelRequest(modelID)])
        #expect(requests.allSatisfy { $0.apiKey == secret && $0.providerID == providerID })
        let envBytes = try Data(contentsOf: root.appendingPathComponent("env").appendingPathComponent(EnvVarStore.fileName))
        #expect(!String(decoding: envBytes, as: UTF8.self).contains(secret))
        #expect(String(decoding: envBytes, as: UTF8.self).contains(ordinary))
    }

    @Test(arguments: ["q8!", "u7%z", "v6!q?", "violet-private575-key"])
    func failedDraftProbeDoesNotExposeKnownCredentialOrMutateStores(secret: String) async throws {
        let root = try root()
        let domain = "SecretReadiness575." + UUID().uuidString
        let transport = SyntheticReadiness575Transport(body: ordinary + " " + secret,
                                                       modelID: modelID, throwsEcho: true)
        let center = try makeCenter(root: root, domain: domain, transport: transport)
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        #expect(center.envStore.setEnvVar(name: "PUBLIC575", value: ordinary, isSecret: false))
        let metadata = root.appendingPathComponent("env").appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: metadata)
        let settingsBefore = center.settingsStore.settings
        let readinessBefore = center.providerReadinessStore.records
        let result = await center.probeProviderDraft(providerID: providerID, apiKey: secret,
                                                     baseURL: "https://fixture575.invalid/v1",
                                                     protocolType: .openaiCompatible)
        guard case .failed(let displayedMessage) = result else {
            Issue.record("Synthetic failed transport must produce the real failed draft state")
            return
        }
        #expect(center.providerDraftProbeState == result)
        #expect(!displayedMessage.contains(secret))
        #expect(!ProviderStatusTextProjection.project(displayedMessage).contains(secret))
        #expect(displayedMessage.contains(ordinary))
        #expect(displayedMessage.contains(ContentSecretRedactor.mask(secret)))
        #expect(try Data(contentsOf: metadata) == before)
        #expect(center.settingsStore.settings == settingsBefore)
        #expect(center.providerReadinessStore.records == readinessBefore)
        #expect(center.envStore.entry(name: providerID) == nil)
        let requests = await transport.requests()
        #expect(requests.count == 1 && requests.first?.operation == .modelDiscovery)
        #expect(requests.first?.apiKey == secret)
    }
}

private struct SyntheticReadiness575Error: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private actor SyntheticReadiness575Transport: SettingsProviderReadinessTransport {
    private let body: String
    private let modelID: String
    private let throwsEcho: Bool
    private var captured: [ProviderReadinessTransportRequest] = []

    init(body: String, modelID: String, throwsEcho: Bool = false) {
        self.body = body
        self.modelID = modelID
        self.throwsEcho = throwsEcho
    }

    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        captured.append(request)
        if throwsEcho { throw SyntheticReadiness575Error(text: body) }
        return ProviderReadinessTransportResponse(statusCode: 200, body: body, modelIDs: [modelID])
    }

    func requests() -> [ProviderReadinessTransportRequest] { captured }
}
