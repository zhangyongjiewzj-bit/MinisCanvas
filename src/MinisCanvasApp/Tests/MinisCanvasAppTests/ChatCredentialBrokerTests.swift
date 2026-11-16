import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// The stock test backing deliberately shares keys across instances. These
/// transaction tests need separate physical namespaces, so inject per-fixture
/// custody without resetting or altering the process-wide backing.
final class CredentialIsolatedBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock { values[key] = value }
        return true
    }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    @discardableResult
    func delete(_ key: String) -> Bool {
        _ = lock.withLock { values.removeValue(forKey: key) }
        return true
    }
}

@MainActor
enum CredentialTestSupport {
    static func makeCenter(transport: (any SettingsProviderReadinessTransport)? = nil) throws -> (SettingsCenter, CredentialIsolatedBacking, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("credential-broker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backing = CredentialIsolatedBacking()
        let keychain = KeychainStore(backing: backing)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            providerReadinessTransport: transport)
        return (center, backing, root)
    }

    static func assertAbsent(_ secret: String, under root: URL) throws {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(secret))
        }
    }

    static func confirm(_ broker: ChatCredentialBroker, request: ChatCredentialBroker.Request,
                        session: UUID? = nil, approved: Bool = true) async -> ChatCredentialBroker.Outcome {
        await broker.confirm(requestID: request.id, sessionID: session ?? request.sessionID,
                             providerID: "SYNTHETIC_BROKER_API_KEY", baseURL: "https://invalid.local/v1",
                             modelIDs: ["synthetic-model"], protocolType: .openaiCompatible,
                             riskConfirmed: approved)
    }
}

private actor CredentialProbeRecorder: SettingsProviderReadinessTransport {
    nonisolated let canProduceLiveEvidence = false
    private(set) var operations: [ProviderReadinessOperation] = []
    let fails: Bool
    init(fails: Bool) { self.fails = fails }
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        operations.append(request.operation)
        if fails { throw SettingsProviderReadinessTransportError.timeout }
        return ProviderReadinessTransportResponse(statusCode: 200, modelIDs: ["synthetic-model"], latency: 1)
    }
}

private actor CancellableCredentialProbe: SettingsProviderReadinessTransport {
    nonisolated let canProduceLiveEvidence = false
    private(set) var entered = false
    private(set) var cancelled = false
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        entered = true
        do {
            try await Task.sleep(for: .seconds(10))
            return ProviderReadinessTransportResponse(statusCode: 200)
        } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}

@Suite("Local credential broker custody") @MainActor
struct ChatCredentialBrokerTests {
    @Test func sessionCancellationReapsProbeWithoutPretendingToUndoApprovedWrite() async throws {
        let transport = CancellableCredentialProbe()
        let (center, backing, root) = try CredentialTestSupport.makeCenter(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: true)
        let value = "sk-synthetic-cancel-probe-" + UUID().uuidString
        let request = try #require(broker.captureSecureField(value, sessionID: UUID()))
        let task = Task { await CredentialTestSupport.confirm(broker, request: request) }
        for _ in 0..<100 {
            if await transport.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.entered)
        broker.cancel(sessionID: request.sessionID)
        #expect(await task.value == .savedProbeFailed)
        #expect(await transport.cancelled)
        #expect(!broker.isConfirming)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == value)
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .rejected)
        try CredentialTestSupport.assertAbsent(value, under: root)
    }
    @Test func staleSettingsPreviewCannotConsumePendingCredential() throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let value = "sk-synthetic-stale-" + UUID().uuidString
        let request = try #require(broker.captureSecureField(value, sessionID: UUID()))
        #expect(center.saveProvider(name: "SYNTHETIC_BROKER_API_KEY", apiKey: "old-synthetic",
                                    baseURL: "https://invalid.local/v1", modelNames: ["old"],
                                    protocolType: .openaiCompatible))
        let previewResult = center.makeChatProviderSettingsPreview(
            requestID: request.id, providerID: "SYNTHETIC_BROKER_API_KEY",
            baseURL: "https://invalid.local/v1", modelIDs: ["old"], protocolType: .openaiCompatible,
            credential: .opaqueHandle(BL6CredentialHandle(id: request.id)))
        guard case .success(let preview) = previewResult else { Issue.record("preview unavailable"); return }
        #expect(center.saveProvider(name: "SYNTHETIC_BROKER_API_KEY", apiKey: "old-synthetic",
                                    baseURL: "https://invalid.local/v1", modelNames: ["new"],
                                    protocolType: .openaiCompatible))
        // The old preview cannot resolve an entry outside broker's approved
        // synchronous context, regardless of which revision fence rejects it.
        let result = center.confirmChatProviderSettings(preview, approvalReceiptID: "stale-test")
        guard case .failure = result else { Issue.record("stale preview accepted"); return }
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == "old-synthetic")
        #expect(broker.pending?.id == request.id)
        try CredentialTestSupport.assertAbsent(value, under: root)
    }
    @Test func existingProbeRunsAfterApprovedWriteAndTimeoutCannotReplayHandle() async throws {
        for fails in [false, true] {
            let transport = CredentialProbeRecorder(fails: fails)
            let (center, backing, root) = try CredentialTestSupport.makeCenter(transport: transport)
            defer { try? FileManager.default.removeItem(at: root) }
            let broker = ChatCredentialBroker()
            broker.attach(center: center, externalNetworkAllowed: true)
            let value = "sk-synthetic-probe-" + UUID().uuidString
            let request = try #require(broker.captureSecureField(value, sessionID: UUID()))
            _ = await CredentialTestSupport.confirm(broker, request: request)
            #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == value)
            #expect(!(await transport.operations).isEmpty)
            // A mock transport cannot certify production live readiness.
            #expect(broker.outcome != .saved)
            #expect(await CredentialTestSupport.confirm(broker, request: request) == .rejected)
            try CredentialTestSupport.assertAbsent(value, under: root)
        }
    }

    @Test func credentialsInMetadataAndMissingProviderAreRejectedBeforeWriter() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let value = "sk-synthetic-metadata-" + UUID().uuidString
        let request = try #require(broker.captureSecureField(value, sessionID: UUID()))
        for provider in ["", value] {
            #expect(await broker.confirm(requestID: request.id, sessionID: request.sessionID,
                                         providerID: provider, baseURL: "https://invalid.local", modelIDs: ["model"],
                                         protocolType: .openaiCompatible, riskConfirmed: true) == .rejected)
        }
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == nil)
        #expect(center.providerRecords.isEmpty)
        try CredentialTestSupport.assertAbsent(value, under: root)
    }
    @Test func explicitConfirmationUsesExistingWriterWithoutDurableRawValue() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let secret = "sk-synthetic-only-" + UUID().uuidString
        let safe = broker.capture("保存这个测试凭据：" + secret, sessionID: UUID())
        #expect(!safe.contains(secret))
        let request = try #require(broker.pending)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == nil)
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .savedProbeBlocked)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == secret)
        #expect(broker.pending == nil)
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .rejected)
        #expect(center.bl6CredentialResolver?(BL6CredentialHandle(id: request.id)) == nil)
        try CredentialTestSupport.assertAbsent(secret, under: root)
    }

    @Test func unapprovedWrongSessionExpiredAndCancelledHandlesCannotWrite() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let session = UUID()
        let request = try #require(broker.captureSecureField("synthetic opaque value", sessionID: session))
        #expect(await CredentialTestSupport.confirm(broker, request: request, approved: false) == .rejected)
        #expect(await CredentialTestSupport.confirm(broker, request: request, session: UUID()) == .rejected)
        #expect(center.bl6CredentialResolver?(BL6CredentialHandle(id: request.id)) == nil)
        broker.clock = { request.expiresAt.addingTimeInterval(1) }
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .rejected)
        broker.cancel(sessionID: session)
        #expect(broker.pending == nil)
        #expect(await CredentialTestSupport.confirm(broker, request: request) == .rejected)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == nil)
    }

    @Test func multipleCredentialsAndProseNeverSelectAProviderOrWrite() async throws {
        let (center, backing, root) = try CredentialTestSupport.makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        let broker = ChatCredentialBroker()
        broker.attach(center: center, externalNetworkAllowed: false)
        let a = "sk-synthetic-one-" + UUID().uuidString
        let b = "sk-synthetic-two-" + UUID().uuidString
        let safe = broker.capture("示例引用而非授权：\(a) \(b)", sessionID: UUID())
        #expect(!safe.contains(a) && !safe.contains(b))
        #expect(broker.pending == nil)
        #expect(backing.get("SYNTHETIC_BROKER_API_KEY") == nil)
        let ordinary = "讨论 API Key 的保存方式，不包含任何值。"
        #expect(broker.capture(ordinary, sessionID: UUID()) == ordinary)
    }

    @Test func streamingProjectionCatchesSplitCredentialAndReplacement() {
        let broker = ChatCredentialBroker()
        let id = UUID()
        let secret = "sk-synthetic-split-only-value"
        var projected = ""
        for character in secret {
            projected = broker.projectStream(messageID: id, current: projected, append: String(character))
            #expect(!projected.contains(secret))
        }
        #expect(!broker.replaceStream(messageID: id, with: "reply " + secret).contains(secret))
        broker.finishStream(messageID: id)
        #expect(broker.projectStream(messageID: UUID(), current: "normal", append: " reply") == "normal reply")
    }
}
