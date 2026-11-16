import Darwin
import Foundation
import CryptoKit
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class MM01ScenarioFakeWire: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejectVisual = false
    nonisolated(unsafe) private static var captures: [(URL, Data)] = []
    nonisolated(unsafe) private static var ownedTransportURLs: Set<String> = []
    static var requests: [(URL, Data)] { lock.lock(); defer { lock.unlock() }; return captures }
    static func reset() { lock.lock(); defer { lock.unlock() }; captures = []; rejectVisual = false; ownedTransportURLs = [] }
    static func failVisual() { lock.lock(); defer { lock.unlock() }; rejectVisual = true }
    static func allowOwnedTransportOnly(_ urls: [URL]) {
        precondition(urls.allSatisfy { $0.scheme == "http" && $0.host == "127.0.0.1" && $0.port != nil })
        lock.lock(); defer { lock.unlock() }
        ownedTransportURLs = Set(urls.map(\.absoluteString))
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Only two exact disposable socket URLs can bypass this fake. Official
        // and all other URLs stay intercepted; this never opens a vendor wire.
        return !ownedTransportURLs.contains(request.url?.absoluteString ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(buffer, count: count)
            }
        }
        guard let url = request.url else { return }
        Self.lock.lock(); Self.captures.append((url, body)); Self.lock.unlock()
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let streaming = payload?["stream"] as? Bool == true
        let content: String
        if request.httpMethod == "GET" {
            content = #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#
        } else if streaming {
            content = "data: " + #"{"choices":[{"index":0,"delta":{"content":"MM01 controlled visual answer"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        } else {
            content = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"MM01 controlled visual answer"},"finish_reason":"stop"}]}"#
        }
        Self.lock.lock(); let status = Self.rejectVisual && request.httpMethod == "POST" && payload?["max_tokens"] as? Int != 1 ? 503 : 200; Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("MM01 actual Composer Agent scenario, zero network, NOT_RUN candidate", .serialized)
@MainActor
struct MM01AgentScenarioTests {
    enum Negative: String, CaseIterable, Sendable {
        case noFlag, duplicateFlag, duplicateC3Flag, duplicateFieldFlag, noField, noIdentity, wrongIdentity, wrongRoot, unsafeRoot
        case substitutedBacking, missingReadiness, wrongModel, wrongBackend, wrongHost
        case wrongPNG, audio, extraUserHistory, changedRevision, secondVisual
        case wrongPort, wrongPath, innerRetry, chatStoreFallback, transportPolicy
    }
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let rootLease: OwnedRootLease
        let composition: DeepSeekEnvironmentPackageFieldBootstrap.Composition
        let lane: DeepSeekMM01FieldLane
        let center: SettingsCenter
        let chat: ChatStore
        let bridge: BridgeStore
        let arguments: [String]
        let environment: [String: String]
    }
    private var image: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAAErElEQVR4nO3T0a0cRRRFUQfBt3PhmzjJih8iGSw9ZCQL2a9mqvt2z15LFUBd6ewvDwj7Mv0BmCQA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBkCYA0gRAmgBIEwBpAiBNAKQJgDQBDPv6x9/TX0gTwHm+bf3zb/qzFRsC+Ovr1yu/1w980dLuCyX89ufv01/4jwAO9OL03zUDAbx/ABun/2YZfFv/x5v+yL8EsNlB03+bDATwzgGcsP5bN/B9/ddpQADbnLb++zYggPcM4OTp3zSDH9Z/kQYE8KrB9d+rAQEIoBvA/67/Cg0I4CXj679FAz9Z/3gDAnje+O7v0oAA3jCA8cXfpYFfrn+2AQE8aXzuAthCAM8Y3/pdGvjk+gcbEMAzxocugF0EsGx85XdpYGn9Uw0IYNn4xAWwkQDWjO/7Lg08sf6RBgSwZnzctwjg6fWf34AA1oyPWwB7CWDB+LJv0cCL6z+5AQEsGJ+1ALYTwILxWV8/gC3rP7MBASwYn7UAthPAgvFZXzyAjes/rQEBLBiftQC2E8CC8VlfOYDt6z+nAQF81vimr9zAQes/oQEBLBjf9DXX/xDAld/rB343PutrBnDo+o9uQAALxmctgO0EsGB81hcM4IT1H9qAABaMz1oA2wlgwfisrxbAaes/rgEBLBiftQC2E8Ca8WVn139QAwJYMz7uiwQwsv4jGhDAmvFxC2DvIQJYNr7v8vq3NyCAZeMTF8DGWwTwjPGVl9e/twEBPGN86ALYdY4AnjS+9fL6NzYggCeNz10AWy4SwPPGF19e/64GBPCS8d2X17+lAQG8qrD+hwB+YnziAjja+MqPa0AAG7z3+h8C+LnxiY8H8OEtp/+4/PpfbEAAO73f+h8C+KXxiV8ngMcpDZx5zviyj25AAId4g+l/GJ+1AG4ZwIdbT/9xq/U/3YAADnfH6T9uuP7nGtgQAJ90i93XCGCYrc8SAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmANAGQJgDSBECaAEgTAGkCIE0ApAmAtH8AiUkej9k1eI8AAAAASUVORK5CYII=")! }
    private struct OwnedRootLease {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
    }
    private func cleanupExactOwnedRoot(_ lease: OwnedRootLease) {
        var current = stat()
        if lstat(lease.url.path, &current) != 0 {
            #expect(errno == ENOENT)
            print("MM01_LEASE_CLEANUP_ROOT=\(lease.url.path) ALREADY_ABSENT=\(errno == ENOENT)")
            return
        }
        guard current.st_dev == lease.device, current.st_ino == lease.inode,
              current.st_uid == lease.owner, current.st_uid == geteuid(),
              (current.st_mode & S_IFMT) == S_IFDIR, (current.st_mode & 0o777) == 0o700 else {
            Issue.record("Owned root identity changed; refusing cleanup: \(lease.url.path)"); return
        }
        do {
            // Delete only this exact freshly owned UUID directory, never its T parent.
            try FileManager.default.removeItem(at: lease.url)
            let absent = !FileManager.default.fileExists(atPath: lease.url.path)
            print("MM01_LEASE_CLEANUP_ROOT=\(lease.url.path) ABSENT=\(absent)")
            #expect(absent)
        } catch { Issue.record("Exact owned root cleanup failed: \(error)") }
    }
    private func ownedFieldRoot(_ prefix: String) throws -> OwnedRootLease {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let temporary = FileManager.default.temporaryDirectory
        var parent = stat()
        try #require(lstat(temporary.path, &parent) == 0)
        try #require((parent.st_mode & S_IFMT) == S_IFDIR && (parent.st_mode & 0o777) == 0o700)
        try #require(parent.st_uid == geteuid() && parent.st_uid == formal.rootOwner)
        let root = temporary.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        print("MM01_CREATED_UUID_ROOT=\(root.path)")
        var owned = stat()
        try #require(lstat(root.path, &owned) == 0)
        let lease = OwnedRootLease(url: root, device: owned.st_dev, inode: owned.st_ino, owner: owned.st_uid)
        var transferred = false
        defer { if !transferred { cleanupExactOwnedRoot(lease) } }
        try #require((owned.st_mode & S_IFMT) == S_IFDIR && (owned.st_mode & 0o777) == 0o700)
        try #require(owned.st_uid == geteuid() && owned.st_uid == formal.rootOwner && owned.st_dev == parent.st_dev)
        try #require(owned.st_ino != parent.st_ino && UInt64(owned.st_ino) != formal.rootInode)
        let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        print("MM01_CREATED_ROOT=\(root.path) UID=\(owned.st_uid) DEV=\(owned.st_dev) INODE=\(owned.st_ino) MODE=700 PATH_SHA256=\(digest)")
        print("MM01_PARENT_ROOT=\(temporary.path) UID=\(parent.st_uid) DEV=\(parent.st_dev) INODE=\(parent.st_ino) MODE=\(String(parent.st_mode & 0o777, radix: 8))")
        transferred = true
        return lease // The unmodified production validator applies its stable alias mapping.
    }
    private func cleanupOwnedField(_ profile: RuntimeIsolationProfile) {
        do {
            try profile.cleanupDisposableRoots()
            let absent = !FileManager.default.fileExists(atPath: profile.rootDirectory.path)
            print("MM01_CLEANUP_ROOT=\(profile.rootDirectory.path) ABSENT=\(absent)")
            #expect(absent)
        } catch {
            Issue.record("Owned MM01 root cleanup refused: \(error)")
        }
    }
    private func fixture() async throws -> Fixture {
        MM01ScenarioFakeWire.reset()
        let arguments = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            DeepSeekEnvironmentPackageFieldBootstrap.activationArgument, DeepSeekMM01FieldLane.activationArgument]
        let lease = try ownedFieldRoot("MM01-")
        var leaseTransferred = false
        defer { if !leaseTransferred { cleanupExactOwnedRoot(lease) } }
        let root = lease.url
        let profile = try RuntimeIsolationProfile.makePackagedField(label: "MM01-fake",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: root.path],
            processArguments: arguments)
        var fixtureCompleted = false
        defer { if !fixtureCompleted { cleanupOwnedField(profile) } }
        print("MM01_NORMALIZED_PROFILE_ROOT=\(profile.rootDirectory.path) LAUNCH_IDENTITY=\(profile.launchIdentity)")
        let environment = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: profile.rootDirectory.path,
            RuntimeIsolationProfile.profileIdentityKey: profile.launchIdentity,
            "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL, "DEEPSEEK_API_KEY": "synthetic-MM01-never-real"]
        let composition = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: profile,
            bootstrapFailed: false, arguments: arguments, environment: environment))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MM01ScenarioFakeWire.self]
        let fake = URLSession(configuration: configuration)
        try #require(try composition.prepareMM01ForRemoteContractTest(arguments: arguments, environment: environment, session: fake))
        fake.invalidateAndCancel()
        let defaults = profile.makeUserDefaults()
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let center = ProductionDomainAssembly.makeSettings(profile: profile, keychain: composition.keychain,
            sessionStore: sessions, sessionBadgeStore: SessionBadgeStore(directory: profile.minisCanvasDirectory),
            logManager: profile.makeLogManager(), store: ShortcutStore(defaults: defaults),
            readinessTransport: composition.mm01ReadinessTransport,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory),
            fieldEnvironmentStore: composition.environmentStore)
        let bridge = BridgeStore(sessionStore: sessions, providerReadinessStore: center.providerReadinessStore)
        let chat = bridge.chat
        try #require(chat.attachPersistence(sessions))
        #expect(composition.install(settings: center, actualKeychain: composition.keychain, primaryCompositionSucceeded: true) == .configured)
        let installedRecord = try #require(center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        let activationFacts: [String: Bool] = [
            "admissionStillValid": DeepSeekMM01FieldLane.acceptsAdmission(profile: profile, keychain: composition.keychain, arguments: arguments, environment: environment),
            "sameEnvStore": center.envStore === composition.environmentStore,
            "settingsSessionDirectory": center.sessionStore.directory == profile.sessionDirectory,
            "chatSessionDirectory": chat.sessionStore?.directory == profile.sessionDirectory,
            "metadataDirectory": center.envStore.metadataDirectory == profile.providerConfigurationDirectory,
            "rootIntact": profile.isDisposableRootIntact,
            "recordBase": installedRecord.baseURL == DeepSeekProviderContract.baseURL,
            "recordProtocol": installedRecord.protocolType == .openaiCompatible,
            "recordModels": installedRecord.modelNames == [DeepSeekMM01FieldLane.modelID],
            "recordKeychain": installedRecord.valueInKeychain,
            "recordSecret": installedRecord.isSecret,
            "recordValueEmpty": installedRecord.value.isEmpty,
            "recordCacheMatchesOwnedRAM": installedRecord.value == composition.keychain.get(installedRecord.name),
            "actualBindingExists": center.providerCredentialBinding(recordID: installedRecord.id) != nil
        ]
        // Booleans only: never print the cached credential or a full environment.
        print("MM01_ACTIVATION_GUARDS=" + String(data: try JSONSerialization.data(withJSONObject: activationFacts, options: [.sortedKeys]), encoding: .utf8)!)
        let lane = try #require(composition.activateMM01(settings: center, actualKeychain: composition.keychain, chat: chat))
        chat.providerRecordsSource = { center.providerRecords }
        chat.providerCredentialMetadataSource = { recordID, name in
            guard let record = center.providerRecords.first(where: { $0.id == recordID && $0.name == name }) else { return nil }
            return await center.providerCredentialBindingAsync(recordID: record.id)?.revision
        }
        chat.providerCredentialPreflightSource = { recordID, name, revision in
            guard center.providerCredentialBinding(recordID: recordID)?.revision == revision,
                  case .success(let value) = await center.providerCredentialReadAsync(named: name), !value.isEmpty else { return false }
            center.reloadEnv()
            return center.providerCredentialBinding(recordID: recordID)?.revision == revision
        }
        chat.schedulerCredentialVersionSource = { name in
            center.providerRecords.first(where: { $0.name == name }).flatMap { center.providerCredentialBinding(recordID: $0.id)?.revision }
        }
        EnvCredentials.supplementarySource = { name in
            name == DeepSeekProviderContract.apiKeyEnvironmentVariable ? "synthetic-MM01-never-real" : nil
        }
        bridge.mm01FieldLane = lane
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: sessions.directory, mcpManager: center.mcpManager, skillStore: center.skillStore,
            externalNetworkAllowed: false, sessionReadSecretStore: center.envStore).value
        #expect(!bridge.productionExternalNetworkAllowed)
        fixtureCompleted = true
        leaseTransferred = true
        return Fixture(profile: profile, rootLease: lease, composition: composition, lane: lane, center: center, chat: chat, bridge: bridge,
            arguments: arguments, environment: environment)
    }
    private func ready(_ f: Fixture) async throws {
        let report = try #require(await f.center.checkProviderReadiness(forProviderName: DeepSeekProviderContract.apiKeyEnvironmentVariable))
        #expect(report.state == .live)
        #expect(report.discoveredModelIDs == [DeepSeekMM01FieldLane.modelID])
        #expect(report.modelChecks.count == 1)
        #expect(MM01ScenarioFakeWire.requests.count == 4)
        #expect(MM01ScenarioFakeWire.requests.prefix(3).allSatisfy { $0.0.absoluteString == "https://api.deepseek.com:443/models" && $0.1.isEmpty })
        let probe = try #require(try JSONSerialization.jsonObject(with: MM01ScenarioFakeWire.requests[3].1) as? [String: Any])
        #expect(probe["model"] as? String == "deepseek-flash")
        #expect(probe["max_tokens"] as? Int == 1)
        f.chat.newSession()
        let installed = try #require(f.center.providerRecords.first {
            $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable
        })
        let producer = ConversationModelPickerConsumer(chat: f.chat)
        let rows = producer.rows.filter {
            $0.isSelectable && $0.modelID == DeepSeekMM01FieldLane.modelID
                && $0.providerID == ProviderReadinessRevision.canonicalProviderID(installed.name)
        }
        let row = try #require(rows.count == 1 ? rows.first : nil)
        #expect(row.providerID == "deepseek_api_key")
        #expect(row.providerID == ProviderReadinessRevision.canonicalProviderID(installed.name))
        #expect(f.chat.applyChatModel(providerID: row.providerID, modelID: row.modelID))
        #expect(f.chat.selectedProviderType == nil)
        #expect(f.chat.selectedCustomProvider?.id == installed.id)
        #expect(f.chat.selectedCustomProvider?.name == installed.name)
        #expect(f.chat.lastChatModelApplyReceipt == f.chat.chatModelPickerReceipt(providerID: row.providerID, modelID: row.modelID))
    }
    private func config() -> ProviderConfig {
        var config = ProviderConfig(label: "DeepSeek", providerType: .deepSeek, runtimeProviderID: ProviderType.deepSeek.runtimeProviderID)
        config.customBaseURL = DeepSeekProviderContract.baseURL; config.apiKey = "synthetic-MM01-never-real"
        return config
    }
    private func model() -> LLMModel {
        LLMModel(id: DeepSeekMM01FieldLane.modelID, displayName: DeepSeekMM01FieldLane.modelID, provider: ProviderType.deepSeek.runtimeProviderID)
    }
    private func message() -> LLMMessage {
        LLMMessage(role: .user, content: DeepSeekMM01FieldLane.prompt,
            images: [.init(mimeType: "image/png", data: image)])
    }

    private enum PNGWireOracleError: Error { case messages, imagePart, imageCount, dataURI, base64 }
    private func ownedPNGFromVisualJSON(_ wire: [String: Any]) throws -> (data: Data, imageCount: Int) {
        guard let messages = wire["messages"] as? [[String: Any]],
              messages.filter({ $0["role"] as? String == "user" }).count == 1 else { throw PNGWireOracleError.messages }
        var images: [(role: String, uri: String)] = []
        for message in messages {
            guard let role = message["role"] as? String else { throw PNGWireOracleError.messages }
            guard let parts = message["content"] as? [[String: Any]] else { continue }
            for part in parts where part["type"] as? String == "image_url" || part["image_url"] != nil {
                guard part["type"] as? String == "image_url",
                      let payload = part["image_url"] as? [String: Any],
                      let uri = payload["url"] as? String else { throw PNGWireOracleError.imagePart }
                images.append((role, uri))
            }
        }
        guard images.count == 1, images[0].role == "user" else { throw PNGWireOracleError.imageCount }
        let prefix = "data:image/png;base64,"
        guard images[0].uri.hasPrefix(prefix) else { throw PNGWireOracleError.dataURI }
        let encoded = String(images[0].uri.dropFirst(prefix.count))
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded else { throw PNGWireOracleError.base64 }
        return (data, images.count)
    }

    private func submitImage(_ f: Fixture) {
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image,
            fileName: "标准几何图.png", fileType: .image, mimeType: "image/png", data: image))
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
    }

    private func settle(_ f: Fixture) async throws {
        for _ in 0..<500 {
            if !f.chat.isStreaming { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("actual Composer Agent did not reach terminal state")
    }

    private struct SafeSubmitStage {
        let stage: String
        let reason: String
    }

    private func safeSubmitStages(_ chat: ChatStore) -> [SafeSubmitStage] {
        chat.logManager.recentLogs().reversed().compactMap { entry in
            guard entry.category == "ComposerSubmission", entry.eventID == "composer.submit.stage" else { return nil }
            let fields = entry.message.split(separator: " ")
            guard let stageField = fields.first(where: { $0.hasPrefix("stage=") }),
                  let reasonField = fields.first(where: { $0.hasPrefix("reason=") }) else { return nil }
            let stage = String(stageField.dropFirst(6))
            let reason = String(reasonField.dropFirst(7))
            // Only fixed-vocabulary stage/reason fields; never dump log text.
            guard [stage, reason].allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0.allSatisfy(\.isLetter) }) else { return nil }
            return SafeSubmitStage(stage: stage, reason: reason)
        }
    }

    private func waitForFixedScenarioTerminal(_ f: Fixture, sessionID: UUID,
                                               probe: MM01FixedScenarioFailureProbe) async throws {
        var observedRegisteredIdentity: AgentExecutionIdentity?
        func receipt() -> ChatRunTerminalReceipt? {
            if let active = f.chat.activeExecutionIdentity(for: sessionID) {
                observedRegisteredIdentity = active
            }
            if let observedRegisteredIdentity {
                return f.chat.terminalReceipt(for: observedRegisteredIdentity)
            }
            guard let snapshot = f.chat.lastComposerSubmissionSnapshot,
                  snapshot.sessionID == sessionID.uuidString else { return nil }
            // Lookup only from the actual Composer snapshot. This does not
            // mint/register an identity or weaken the production entry guard.
            let turn = AgentTurnIdentity(sessionID: snapshot.sessionID,
                turnID: snapshot.turnID, messageID: snapshot.messageID)
            let lookup = AgentExecutionIdentity(turn: turn,
                operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1)
            return f.chat.terminalReceipt(for: lookup)
        }
        func pending() -> Bool {
            f.chat.isComposerAttachmentPreflightPending || f.chat.isComposerCredentialPreflightPending
                || f.chat.isComposerProviderPreparationPending || f.chat.isStreaming
                || f.chat.activeExecutionIdentity(for: sessionID) != nil
        }
        func report(_ status: String, terminal: ChatRunTerminalReceipt?) throws {
            let stages = safeSubmitStages(f.chat)
            let facts: [String: Any] = [
                "waitStatus": status, "requestCount": MM01ScenarioFakeWire.requests.count,
                "isStreaming": f.chat.isStreaming,
                "attachmentPreflightPending": f.chat.isComposerAttachmentPreflightPending,
                "credentialPreflightPending": f.chat.isComposerCredentialPreflightPending,
                "providerPreparationPending": f.chat.isComposerProviderPreparationPending,
                "registeredIdentityObserved": observedRegisteredIdentity != nil,
                "actualComposerSnapshotPresent": f.chat.lastComposerSubmissionSnapshot != nil,
                "actualUserCount": f.chat.messages.filter { $0.role == .user }.count,
                "actualAssistantCount": f.chat.messages.filter { $0.role == .assistant }.count,
                "laneIntact": f.lane.intact,
                "mediaCanSubmit": f.chat.composerMediaReadinessSnapshot.canSubmitAttachments,
                "invalidSettingsBlocked": f.chat.lastSubmissionBlockedByInvalidSettings,
                "activeExecutionPresent": f.chat.activeExecutionIdentity(for: sessionID) != nil,
                "terminalOutcome": terminal?.outcome.rawValue ?? "none",
                "failureStage": probe.failure?.stage.rawValue ?? "none",
                "failureErrorType": probe.failure?.errorType ?? "none",
                "failureCaseName": probe.failure?.errorCaseName ?? "none",
                "submissionStages": stages.map(\.stage), "submissionReasons": stages.map(\.reason),
                "expectedAssistantPresent": f.chat.messages.contains {
                    $0.role == .assistant && $0.content.contains("MM01 controlled visual answer")
                }
            ]
            print("MM01_FIXED_SCENARIO_TERMINAL=" + String(data: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), encoding: .utf8)!)
        }
        // Same 10-second bound as the previous helper; await real predicates,
        // not an initial idle window during async preflight preparation.
        for _ in 0..<500 {
            let terminal = receipt()
            let hasAnswer = f.chat.messages.contains {
                $0.role == .assistant && $0.content.contains("MM01 controlled visual answer")
            }
            if !pending(), terminal?.outcome == .succeeded, hasAnswer {
                try report("succeeded", terminal: terminal)
                return
            }
            if !pending(), terminal?.outcome == .failed || terminal?.outcome == .cancelled || probe.failure != nil {
                try report("failedOrCancelled", terminal: terminal)
                return
            }
            let stages = safeSubmitStages(f.chat)
            let rejected = stages.contains {
                ["submitRejected", "credentialPreflightRejected", "providerPreparationRejected", "userMessageAppendNotObserved"].contains($0.stage)
            }
            if !pending(), rejected {
                try report("submissionRejected", terminal: terminal)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try report("boundedTimeout", terminal: receipt())
        Issue.record("MM01 fixed scenario did not reach a production success or failure terminal within the existing bound")
    }

    @Test("zero-network Settings Apply Composer Bridge real Agent uses the fixed prompt and generates no tools")
    func actualComposerAgentFixedScenario() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        // These synthetic dynamic values must never enter this fixed field
        // scenario; the adjacent ordinary test retains the regular prompt.
        f.chat.restorePersona(Persona(name: "MM01 synthetic persona", summary: "MM01_SYNTHETIC_PERSONA_SENTINEL"), enabled: true)
        let sessionID = try #require(f.chat.activeSessionID)
        #expect(f.chat.agentEngine is AgentLoopChatEngine)
        #expect(f.chat.streamingProviderOverride == nil)
        let probe = MM01FixedScenarioFailureProbe()
        f.chat.turnFailureObserverForTests = { probe.failure = $0 }
        f.chat.composerSubmissionDiagnosticsEnabled = true
        submitImage(f)
        try await waitForFixedScenarioTerminal(f, sessionID: sessionID, probe: probe)
        #expect(f.chat.activeSessionID == sessionID)
        #expect(f.chat.messages.contains { $0.role == .assistant && $0.content.contains("MM01 controlled visual answer") })
        let requests = MM01ScenarioFakeWire.requests
        try #require(requests.count == 5)
        let body = try #require(try JSONSerialization.jsonObject(with: requests[4].1) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let system = try #require(messages.first)
        #expect(system["role"] as? String == "system")
        let actualPrompt = try #require(system["content"] as? String)
        #expect(Data(actualPrompt.utf8) == Data(MM01AgentScenarioContract.approvedSystemPrompt.utf8))
        #expect(actualPrompt.utf8.count == MM01AgentScenarioContract.approvedPromptUTF8Length)
        #expect(SHA256.hash(data: Data(actualPrompt.utf8)).map { String(format: "%02x", $0) }.joined() == MM01AgentScenarioContract.approvedPromptSHA256)
        #expect(body["tools"] == nil)
        #expect(body["max_tokens"] as? Int == 256)
        #expect(body["temperature"] as? Double == 0.7)
        #expect(messages.filter { $0["role"] as? String == "user" }.count == 1)
        let raw = String(decoding: requests[4].1, as: UTF8.self)
        // Preserve the historical raw-literal result only as a diagnostic.
        // The byte-integrity gate is the actual decoded JSON data URI.
        let imageRequestIndices = requests.indices.filter { index in
            guard let json = try? JSONSerialization.jsonObject(with: requests[index].1) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else { return false }
            return messages.contains { message in
                (message["content"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == "image_url" || $0["image_url"] != nil
                } == true
            }
        }
        #expect(imageRequestIndices == [4])
        let semantic = try ownedPNGFromVisualJSON(body)
        let decodedSHA = SHA256.hash(data: semantic.data).map { String(format: "%02x", $0) }.joined()
        let ownedSHA = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        #expect(semantic.imageCount == 1)
        #expect(semantic.data == image)
        #expect(decodedSHA == ownedSHA)
        #expect(decodedSHA == DeepSeekMM01FieldLane.imageSHA256)
        let facts: [String: Any] = [
            "visualImagePartCount": semantic.imageCount,
            "visualImageRequestCount": imageRequestIndices.count,
            "decodedByteCount": semantic.data.count, "ownedByteCount": image.count,
            "bytesMatchOwnedPNG": semantic.data == image,
            "decodedSHA256": decodedSHA, "ownedSHA256": ownedSHA,
            "rawLiteralContainsOwnedBase64": raw.contains(image.base64EncodedString()),
            "rawJSONHasEscapedSlash": raw.contains("\\/"),
            "requestBodySHA256": SHA256.hash(data: requests[4].1).map { String(format: "%02x", $0) }.joined()
        ]
        print("MM01_AGENT_VISUAL_PNG_SEMANTIC_ORACLE=" + String(data: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), encoding: .utf8)!)
        #expect(!raw.contains("MM01_SYNTHETIC_PERSONA_SENTINEL"))
        #expect(!raw.contains("synthetic-MM01-never-real"))
        #expect(!f.bridge.productionExternalNetworkAllowed)
    }

    @Test("non-nil unapproved prompt and the default real tool catalog are rejected before wire", arguments: [false, true])
    func unapprovedPromptOrDefaultTools(_ useTools: Bool) async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        let provider = try f.chat.activeProvider()
        let tools = useTools ? AgentToolCatalog.makeTools() : []
        if useTools { #expect(!tools.isEmpty) }
        await #expect(throws: Error.self) {
            _ = try await provider.sendMessage(messages: [message()],
                systemPrompt: useTools ? MM01AgentScenarioContract.approvedSystemPrompt : "UNAPPROVED_NONNIL_SYNTHETIC",
                tools: tools, maxTokens: 256, temperature: 0.7)
        }
        #expect(MM01ScenarioFakeWire.requests.count == 4)
    }

    @Test("existing synthetic user history prevents fresh-empty scenario mint before another user append")
    func existingHistoryCannotMintScenario() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        f.chat.appendUser("MM01_SYNTHETIC_OLD_HISTORY")
        let before = f.chat.messages.filter { $0.role == .user }.count
        submitImage(f)
        try await settle(f)
        #expect(f.chat.messages.filter { $0.role == .user }.count == before)
        #expect(MM01ScenarioFakeWire.requests.count == 4)
    }

    enum PrebindMutation: String, CaseIterable, Sendable {
        case unchangedControl, credentialRevision, withdrawApply, switchSession, extraHistory
    }

    private struct BoundRunSummary {
        let observation: ProviderRuntimeRouteObservation
        let model: LLMModel
        let configurationFingerprint: String
        let visualJSON: [String: Any]?
    }

    private func boundRun(_ mutation: MM01BoundWireMutation,
                          wrapped: Bool, expectSuccess: Bool,
                          beforeDelegate: (@MainActor @Sendable (Fixture) async throws -> Void)? = nil,
                          liveProbe: BoundLiveMutationProbe? = nil) async throws -> BoundRunSummary {
        let f = try await fixture()
        let gate = MM01BoundOwnedTurnGate()
        var ownedTask: Task<Void, Never>?
        var support: MM01BoundWireMutationTestSupport?
        defer {
            gate.release()
            support?.restore()
            f.chat.stopAllStreamingForSafety()
            EnvCredentials.supplementarySource = nil
            cleanupOwnedField(f.profile)
            cleanupExactOwnedRoot(f.rootLease)
        }
        do {
            try await ready(f)
            let session = try #require(f.chat.activeSessionID)
            let actual = try #require(try f.chat.activeProvider() as? MM01FieldProvider)
            let expectedModel = actual.model
            let expectedName = actual.name
            let expectedCapabilities = actual.capabilities
            let expectedFingerprint = ProviderRuntimeSnapshot.configurationFingerprint(
                providerID: expectedName, modelID: expectedModel.id,
                capabilities: expectedCapabilities,
                configurationMaterial: actual.runtimeConfigurationMaterial)
            let apply = try #require(f.chat.lastChatModelApplyReceipt)
            let before = f.bridge.providerRuntimeObservations.count
            let probe = MM01FixedScenarioFailureProbe()
            f.chat.turnFailureObserverForTests = { probe.failure = $0 }
            f.chat.composerSubmissionDiagnosticsEnabled = true
            // Use the existing preprocessor seam only to capture the actual
            // owned Task. The parameter mutation still happens after bind.
            f.chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
            if wrapped {
                let callback: (@Sendable () async throws -> Void)?
                if let beforeDelegate {
                    callback = { @MainActor in try await beforeDelegate(f) }
                } else { callback = nil }
                support = try MM01BoundWireMutationTestSupport(
                    chat: f.chat, lane: f.lane, mutation: mutation,
                    pauseBeforeDelegate: callback)
            }
            submitImage(f)
            for _ in 0..<500 {
                if gate.isPaused { break }
                if probe.failure != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(gate.isPaused)
            let task = try #require(f.chat.turnTaskForTests(sessionID: session))
            ownedTask = task
            let identity = try #require(f.chat.activeExecutionIdentity(for: session))
            try #require(identity.isValid && identity.attempt == 1)
            gate.release()
            await task.value // Actual production Task; no idle/preflight timing guess.
            if let liveProbe {
                let deliveredNow = Array(f.bridge.providerRuntimeObservations.dropFirst(before))
                var facts = liveProbe.safeFacts
                facts["entryCount"] = support?.interceptions ?? 0
                facts["delegateCount"] = support?.delegations ?? 0
                facts["adapterFailures"] = support?.adapterFailures ?? []
                facts["delegatedErrorTypes"] = support?.delegatedErrorTypes ?? []
                facts["originalSinkDeliveryCount"] = deliveredNow.count
                facts["originalSinkTerminalFailure"] = deliveredNow.first?.status == .terminalFailure
                facts["actualFailureStage"] = probe.failure?.stage.rawValue ?? "none"
                facts["actualFailureErrorType"] = probe.failure?.errorType ?? "none"
                facts["terminalOutcome"] = f.chat.terminalReceipt(for: identity)?.outcome.rawValue ?? "none"
                facts["requestCount"] = MM01ScenarioFakeWire.requests.count
                print("MM01_AFTER_BIND_LIVE_MUTATION=" + String(data: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), encoding: .utf8)!)
            }
            try #require(!f.chat.isStreaming)
            try #require(f.chat.activeExecutionIdentity(for: session) == nil)
            try #require(f.chat.activeSessionID == session)
            let terminal = try #require(f.chat.terminalReceipt(for: identity))
            let delivered = Array(f.bridge.providerRuntimeObservations.dropFirst(before))
            try #require(delivered.count == 1) // Original sink, no duplicate synthetic observation.
            let observation = delivered[0]
            try #require(observation.fallbackEvents.isEmpty)
            if let support {
                try #require(support.factoryCalls == 1)
                try #require(support.adapterFailures.isEmpty)
                try #require(support.interceptions == 1 && support.delegations == 1)
                let event = try #require(support.events.count == 1 ? support.events.first : nil)
                let snapshot = try #require(support.originalRouteSnapshots.count == 1 ? support.originalRouteSnapshots.first : nil)
                try #require(event.executionIdentity == identity)
                try #require(event.routeReceiptID == snapshot.routeReceiptID)
                try #require(observation.routeReceiptID == event.routeReceiptID)
                try #require(support.originalRouteReceiptIDs == [snapshot.routeReceiptID])
                try #require(snapshot.providerID == expectedName && snapshot.modelID == expectedModel.id)
                try #require(snapshot.capabilities == expectedCapabilities)
                try #require(snapshot.configurationFingerprint == expectedFingerprint)
                try #require(snapshot.applyReceiptID == apply.applyReceiptID)
                try #require(snapshot.readinessEvidenceID == apply.evidenceID)
                try #require(snapshot.fallbackProviderIDs.isEmpty && snapshot.fallbackProvenance.isEmpty)
                try #require(event.applyReceiptID == apply.applyReceiptID)
                try #require(event.requestPromptSHA256 == MM01AgentScenarioContract.approvedPromptSHA256)
                try #require(event.imageSHA256 == [DeepSeekMM01FieldLane.imageSHA256])
                try #require(event.audioCount == 0 && event.toolCount == 0 && event.maxTokens == 256)
                let facts: [String: Any] = [
                    "entryCount": support.interceptions, "delegateCount": support.delegations,
                    "adapterFailures": support.adapterFailures,
                    "delegatedErrorTypes": support.delegatedErrorTypes,
                    "originalSinkDeliveryCount": delivered.count,
                    "configurationFingerprintMatched": snapshot.configurationFingerprint == expectedFingerprint,
                    "snapshotReceiptMatched": observation.routeReceiptID == snapshot.routeReceiptID,
                    "actualIdentityMatched": event.executionIdentity == identity,
                    "requestCount": MM01ScenarioFakeWire.requests.count,
                    "terminalOutcome": terminal.outcome.rawValue,
                    "actualFailureStage": probe.failure?.stage.rawValue ?? "none",
                    "actualFailureErrorType": probe.failure?.errorType ?? "none"
                ]
                print("MM01_BOUND_ORIGINAL_ROUTE_FACTS=" + String(data: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), encoding: .utf8)!)
                if expectSuccess {
                    try #require(support.delegatedErrorTypes.isEmpty)
                } else {
                    try #require(!support.delegatedErrorTypes.isEmpty)
                    try #require(support.delegatedErrorTypes.allSatisfy {
                        !$0.contains("MM01BoundWireSupportError") && !$0.contains("ProviderRuntimeSnapshotError")
                    })
                    if let liveProbe {
                        // An outer/current-execution fence or callback refusal
                        // is not final Lane predicate coverage.
                        try #require(liveProbe.callbackCalls == 1 && liveProbe.baselineVerified)
                        try #require(liveProbe.mutationVerified && liveProbe.identityRemainedRegistered)
                        let laneType = String(reflecting: DeepSeekMM01FieldLane.Refusal.self)
                        try #require(support.delegatedErrorTypes == [laneType])
                        try #require(probe.failure?.errorType == laneType)
                    }
                }
            }
            let requests = MM01ScenarioFakeWire.requests
            if expectSuccess {
                try #require(probe.failure == nil)
                try #require(terminal.outcome == .succeeded)
                try #require(observation.status == .served)
                try #require(observation.servedProviderID == expectedName)
                try #require(observation.servedModelID == expectedModel.id)
                try #require(requests.count == 5)
                try #require(requests.allSatisfy {
                    $0.0.scheme == "https" && $0.0.host == "api.deepseek.com" && ($0.0.port ?? 443) == 443
                })
                try #require(f.chat.messages.contains { $0.role == .assistant && $0.content.contains("MM01 controlled visual answer") })
                guard let wire = try JSONSerialization.jsonObject(with: requests[4].1) as? [String: Any],
                      let messages = wire["messages"] as? [[String: Any]] else {
                    throw MM01BoundWireSupportError.baselineRequest
                }
                let prompt = try #require(messages.first?["content"] as? String)
                try #require(messages.first?["role"] as? String == "system")
                try #require(Data(prompt.utf8) == Data(MM01AgentScenarioContract.approvedSystemPrompt.utf8))
                try #require(prompt.utf8.count == MM01AgentScenarioContract.approvedPromptUTF8Length)
                try #require(SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined() == MM01AgentScenarioContract.approvedPromptSHA256)
                try #require(wire["tools"] == nil && wire["max_tokens"] as? Int == 256)
                try #require(wire["temperature"] as? Double == 0.7)
                try #require(wire["model"] as? String == DeepSeekMM01FieldLane.modelID)
                let png = try ownedPNGFromVisualJSON(wire)
                let bytesMatchOwnedPNG = png.data == image
                try #require(png.imageCount == 1 && bytesMatchOwnedPNG && png.data.count == 1253)
                try #require(SHA256.hash(data: png.data).map { String(format: "%02x", $0) }.joined() == DeepSeekMM01FieldLane.imageSHA256)
                return BoundRunSummary(observation: observation, model: expectedModel,
                    configurationFingerprint: expectedFingerprint, visualJSON: wire)
            }
            try #require(wrapped)
            try #require(terminal.outcome == .failed)
            try #require(observation.status == .terminalFailure)
            try #require(probe.failure != nil)
            try #require(requests.count == 4)
            return BoundRunSummary(observation: observation, model: expectedModel,
                configurationFingerprint: expectedFingerprint, visualJSON: nil)
        } catch {
            gate.release()
            f.chat.stopAllStreamingForSafety()
            ownedTask?.cancel()
            if let ownedTask { await ownedTask.value }
            throw error
        }
    }

    @Test("bound wire control preserves original route snapshot configuration observer and whole five requests")
    func boundWireControlEquivalentToOriginal() async throws {
        let original = try await boundRun(.control, wrapped: false, expectSuccess: true)
        let wrapped = try await boundRun(.control, wrapped: true, expectSuccess: true)
        #expect(wrapped.model == original.model)
        #expect(wrapped.configurationFingerprint == original.configurationFingerprint)
        #expect(wrapped.observation.status == original.observation.status)
        #expect(wrapped.observation.servedProviderID == original.observation.servedProviderID)
        #expect(wrapped.observation.servedModelID == original.observation.servedModelID)
        #expect(wrapped.observation.attemptedProviderIDs == original.observation.attemptedProviderIDs)
        #expect(wrapped.observation.attempts.map(\.attempt) == original.observation.attempts.map(\.attempt))
        #expect(wrapped.observation.attempts.map(\.succeeded) == original.observation.attempts.map(\.succeeded))
        #expect(wrapped.observation.fallbackEvents.isEmpty && original.observation.fallbackEvents.isEmpty)
        let lhs = try #require(wrapped.visualJSON)
        let rhs = try #require(original.visualJSON)
        let visualParametersEquivalent = NSDictionary(dictionary: lhs).isEqual(to: rhs)
        #expect(visualParametersEquivalent) // boolean only; never print a body/URI/base64 on failure
    }

    @Test("after real prepared bind changing only outgoing PNG delegates to original lane and sends zero visuals")
    func boundWireRejectsWrongPNG() async throws {
        let otherOwnedPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l2kAAAAASUVORK5CYII="))
        _ = try await boundRun(.wrongPNG(otherOwnedPNG), wrapped: true, expectSuccess: false)
    }

    @Test("after real prepared bind changing only outgoing audio delegates to original lane and sends zero visuals")
    func boundWireRejectsAudio() async throws {
        // Owned 48-byte RIFF/PCM synthetic sample; no microphone/file/real audio.
        let wav = try #require(Data(base64Encoded: "UklGRigAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQQAAAAAAAAA"))
        _ = try await boundRun(.audio(.init(format: "wav", base64Data: wav.base64EncodedString())),
            wrapped: true, expectSuccess: false)
    }

    @Test("after real prepared bind changing only final prompt delegates to original lane and sends zero visuals")
    func boundWireRejectsFinalPrompt() async throws {
        _ = try await boundRun(.finalPrompt("MM01_SYNTHETIC_FINAL_PROMPT_MUTATION"),
            wrapped: true, expectSuccess: false)
    }

    @Test("after real prepared bind changing only final budget to 257 delegates to original lane and sends zero visuals")
    func boundWireRejectsSendBudget() async throws {
        _ = try await boundRun(.sendBudget(257), wrapped: true, expectSuccess: false)
    }


    @Test(arguments: PrebindMutation.allCases)
    func admittedScenarioPrebindAuthorityChange(_ change: PrebindMutation) async throws {
        let f = try await fixture()
        let gate = MM01ScenarioPrebindPause()
        defer {
            gate.release()
            f.chat.stopAllStreamingForSafety()
            EnvCredentials.supplementarySource = nil
            cleanupOwnedField(f.profile)
            cleanupExactOwnedRoot(f.rootLease)
        }
        try await ready(f)
        let originalSession = try #require(f.chat.activeSessionID)
        let originalRecord = try #require(f.chat.selectedCustomProvider)
        let originalApply = try #require(f.chat.lastChatModelApplyReceipt)
        let originalRevision = try #require(f.center.providerCredentialBinding(recordID: originalRecord.id)?.revision)
        f.chat.turnPromptPreprocessPauseForTests = { await gate.wait() }
        submitImage(f)
        for _ in 0..<500 {
            if gate.isPaused { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(gate.isPaused)
        try #require(f.chat.isStreaming)
        let snapshot = try #require(f.chat.lastComposerSubmissionSnapshot)
        let identity = try #require(f.chat.activeExecutionIdentity(for: originalSession))
        try #require(identity.isValid && identity.attempt == 1)
        try #require(identity.turn.sessionID == originalSession.uuidString)
        try #require(identity.turn.messageID == snapshot.messageID)
        try #require(f.chat.messages.filter { $0.role == .user }.count == 1)
        try #require(f.chat.messages.first { $0.role == .user }?.id.uuidString == snapshot.messageID)
        try #require(f.chat.lastChatModelApplyReceipt == originalApply)
        try #require(f.lane.admits(try f.chat.activeProvider()))
        try #require(MM01ScenarioFakeWire.requests.count == 4)
        print("MM01_PREBIND_BASELINE mutation=\(change.rawValue) REGISTERED=true APPLY_MATCH=true REQUESTS=4 FINAL_BIND_NOT_YET_OBSERVED=true")
        switch change {
        case .unchangedControl:
            break
        case .credentialRevision:
            try #require(f.center.saveProvider(name: originalRecord.name,
                apiKey: "synthetic-MM01-revision-change", baseURL: DeepSeekProviderContract.baseURL,
                modelNames: [DeepSeekMM01FieldLane.modelID], protocolType: .openaiCompatible))
            try #require(f.center.providerCredentialBinding(recordID: originalRecord.id)?.revision != originalRevision)
        case .withdrawApply:
            f.chat.setCustomProvider(originalRecord) // same record/model; actual API retires Apply receipt
            try #require(f.chat.selectedCustomProvider?.id == originalRecord.id)
            try #require(f.chat.selectedModelID == DeepSeekMM01FieldLane.modelID)
            try #require(f.chat.lastChatModelApplyReceipt == nil)
        case .switchSession:
            f.chat.newSession()
            try #require(f.chat.activeSessionID != originalSession)
        case .extraHistory:
            f.chat.appendUser("MM01_SYNTHETIC_HISTORY_ADDED_AFTER_ADMISSION")
            try #require(f.chat.messages.filter { $0.role == .user }.count == 2)
        }
        gate.release()
        for _ in 0..<500 {
            if !f.chat.isStreaming && f.chat.activeExecutionIdentity(for: originalSession) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!f.chat.isStreaming)
        #expect(f.chat.activeExecutionIdentity(for: originalSession) == nil)
        let requests = MM01ScenarioFakeWire.requests
        if change == .unchangedControl {
            try #require(requests.count == 5)
            let wire = try #require(try JSONSerialization.jsonObject(with: requests[4].1) as? [String: Any])
            let png = try ownedPNGFromVisualJSON(wire)
            #expect(png.data == image)
            #expect(SHA256.hash(data: png.data).map { String(format: "%02x", $0) }.joined() == DeepSeekMM01FieldLane.imageSHA256)
            #expect(f.chat.messages.contains { $0.role == .assistant && $0.content.contains("MM01 controlled visual answer") })
        } else {
            #expect(requests.count == 4)
        }
        print("MM01_PREBIND_TERMINAL mutation=\(change.rawValue) REQUESTS=\(requests.count) FINAL_SEND_PREDICATE_NOT_CLAIMED=true")
    }

    private enum BoundLiveMutationKind: String {
        case extraUserHistory, changedRevision
    }

    @MainActor
    private final class BoundLiveMutationProbe {
        let kind: BoundLiveMutationKind
        var callbackCalls = 0
        var baselineVerified = false
        var mutationVerified = false
        var identityRemainedRegistered = false
        var sameLiveRecordUUID = false
        var sameOwnedStore = false
        var sameActualApply = false
        var liveRevisionChanged = false
        var ownedRAMMatchesLiveRecord = false
        var actualUIUserCount = 0
        var actualPersistedUserCount = 0
        init(_ kind: BoundLiveMutationKind) { self.kind = kind }
        var safeFacts: [String: Any] {
            ["predicate": kind.rawValue, "callbackCalls": callbackCalls,
             "baselineVerified": baselineVerified, "mutationVerified": mutationVerified,
             "identityRemainedRegistered": identityRemainedRegistered,
             "sameLiveRecordUUID": sameLiveRecordUUID, "sameOwnedStore": sameOwnedStore,
             "sameActualApply": sameActualApply, "liveRevisionChanged": liveRevisionChanged,
             "ownedRAMMatchesLiveRecord": ownedRAMMatchesLiveRecord,
             "actualUIUserCount": actualUIUserCount, "actualPersistedUserCount": actualPersistedUserCount]
        }
        func mutate(_ f: Fixture) throws {
            callbackCalls += 1
            try #require(callbackCalls == 1)
            let session = try #require(f.chat.activeSessionID)
            let identity = try #require(f.chat.activeExecutionIdentity(for: session))
            let apply = try #require(f.chat.lastChatModelApplyReceipt)
            let selected = try #require(f.chat.selectedCustomProvider)
            let live = try #require(f.center.providerRecords.first { $0.id == selected.id })
            let revision = try #require(f.center.providerCredentialBinding(recordID: live.id)?.revision)
            try #require(identity.isValid && identity.attempt == 1)
            try #require(live == selected && f.lane.intact)
            try #require(f.chat.messages.filter { $0.role == .user }.count == 1)
            try #require(f.chat.messages.first { $0.role == .user }?.id.uuidString == identity.turn.messageID)
            sameOwnedStore = f.chat.sessionStore?.directory == f.profile.sessionDirectory
                && f.center.sessionStore === f.chat.sessionStore
            try #require(sameOwnedStore)
            try #require(live.value == f.composition.keychain.get(live.name))
            try #require(MM01ScenarioFakeWire.requests.count == 4)
            baselineVerified = true
            switch kind {
            case .extraUserHistory:
                f.chat.appendUser("MM01_SYNTHETIC_EXTRA_HISTORY_AFTER_REAL_BIND")
            case .changedRevision:
                try #require(f.center.saveProvider(name: live.name,
                    apiKey: "synthetic-MM01-afterbind-revision", baseURL: live.baseURL,
                    modelNames: live.modelNames, protocolType: live.protocolType))
            }
            let current = try #require(f.center.providerRecords.first { $0.id == live.id })
            let currentRevision = f.center.providerCredentialBinding(recordID: live.id)?.revision
            sameLiveRecordUUID = current.id == live.id && current.name == live.name
                && f.chat.selectedCustomProvider?.id == live.id
            sameActualApply = f.chat.lastChatModelApplyReceipt == apply
            identityRemainedRegistered = f.chat.activeExecutionIdentity(for: session) == identity
            liveRevisionChanged = currentRevision != revision
            ownedRAMMatchesLiveRecord = current.value == f.composition.keychain.get(current.name)
            actualUIUserCount = f.chat.messages.filter { $0.role == .user }.count
            let persisted = f.center.sessionStore.loadSession(id: session.uuidString)
            actualPersistedUserCount = persisted?.messages.filter { $0.role == .user }.count ?? -1
            switch kind {
            case .extraUserHistory:
                mutationVerified = actualUIUserCount == 2 && actualPersistedUserCount == 2
                    && !liveRevisionChanged && current == live && sameLiveRecordUUID && sameActualApply
            case .changedRevision:
                mutationVerified = liveRevisionChanged && current.id == live.id
                    && current.baseURL == live.baseURL && current.protocolType == live.protocolType
                    && current.modelNames == live.modelNames && ownedRAMMatchesLiveRecord
                    && actualUIUserCount == 1 && sameLiveRecordUUID && sameActualApply
            }
            // Do not manufacture a throw or revoke an execution here. The
            // original checkCancellation/route/Lane report their actual layer.
        }
    }

    @Test("after real bind actual owned producer and persisted extra user history reaches original Lane refusal")
    func boundWireRejectsExtraUserHistoryAfterBind() async throws {
        let probe = BoundLiveMutationProbe(.extraUserHistory)
        _ = try await boundRun(.control, wrapped: true, expectSuccess: false,
            beforeDelegate: { try probe.mutate($0) }, liveProbe: probe)
    }

    @Test("after real bind actual same-UUID live credential revision and owned RAM change reaches original Lane refusal")
    func boundWireRejectsChangedRevisionAfterBind() async throws {
        let probe = BoundLiveMutationProbe(.changedRevision)
        _ = try await boundRun(.control, wrapped: true, expectSuccess: false,
            beforeDelegate: { try probe.mutate($0) }, liveProbe: probe)
    }

    @Test("ordinary Agent preserves its supplied context and generates the ordinary tool catalog")
    func ordinaryAgentContextAndCatalogRemain() async throws {
        let lease = try ownedFieldRoot("MM01-ordinary-")
        defer { cleanupExactOwnedRoot(lease) }
        let root = lease.url
        let suite = "MM01-ordinary-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let logManager = LogManager(directory: root.appendingPathComponent("logs"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("environment"),
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory,
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: sessions,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: logManager,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: .suite(suite)),
            shortcutStore: ShortcutStore(defaults: defaults),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        let chat = ChatStore(preferencesDefaults: defaults, logManager: logManager)
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime(center) {} }
        try #require(chat.attachPersistence(sessions))
        chat.newSession()
        let sessionID = try #require(chat.activeSessionID)
        let failureProbe = MM01FixedScenarioFailureProbe()
        let previousFailureObserver = chat.turnFailureObserverForTests
        defer { chat.turnFailureObserverForTests = previousFailureObserver }
        chat.turnFailureObserverForTests = { observation in
            previousFailureObserver?(observation)
            guard observation.sessionID == sessionID, failureProbe.failure == nil else { return }
            failureProbe.failure = observation
        }
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "MM01-ordinary-policy", grantEpoch: "MM01-ordinary-epoch",
            leaseID: "MM01-ordinary-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let engine = AgentLoopChatEngine(maxIterations: 1,
            chatRuntimeDependencies: .init(sessionStore: sessions,
                memoryStore: memory,
                skillStore: skills, soulStore: SoulStore(directory: root.appendingPathComponent("souls"))),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            composerPolicyFacts: facts)
        chat.agentEngine = engine.withRequestBudget(chat.budgetTracker)
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let provider = MM01OrdinaryCaptureProvider()
        chat.streamingProviderOverride = provider // zero-I/O ordinary capture; real Agent remains installed
        let persona = Persona(summary: "ORDINARY_SYNTHETIC_CONTEXT_SENTINEL")
        chat.restorePersona(persona, enabled: true)
        #expect(chat.mm01FieldLane == nil)
        #expect(chat.agentEngine is AgentLoopChatEngine)
        chat.draftText = "ordinary synthetic turn"
        chat.submitComposer() // owns real Composer snapshot, registration and writeback lifecycle
        let ownedExecution = chat.activeExecutionIdentity(for: sessionID)
        for _ in 0..<500 {
            if !chat.isStreaming && provider.snapshot().calls == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(snapshot.sessionID == sessionID.uuidString)
        #expect(snapshot.messageID == chat.messages.last(where: { $0.role == .user })?.id.uuidString)
        let captured = provider.snapshot()
        #expect(!chat.isStreaming)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains("synthetic ordinary answer") })
        let base = ChatStore.systemPrompt(for: .normal)
        let expected = ChatStore.systemPrompt(withPersona: base, persona: persona)
        let prompt = try #require(captured.prompt)
        #expect(prompt.hasPrefix(expected))
        let insertedPersona = "\n\n" + persona.systemPromptFragment
        let split = try #require(expected.range(of: insertedPersona))
        #expect(expected.hasPrefix("指令来源："))
        #expect(expected[..<split.lowerBound].contains(
            "用户当前的话 > 项目指令 > 全局指令 > 技能 > 记忆"))
        #expect(expected.components(separatedBy: insertedPersona).count == 2)
        var original = expected
        original.removeSubrange(split)
        #expect(Data(original.utf8) == Data(base.utf8))
        #expect(captured.prompt?.contains("ORDINARY_SYNTHETIC_CONTEXT_SENTINEL") == true)
        #expect(captured.prompt != MM01AgentScenarioContract.approvedSystemPrompt)
        #expect(captured.tools.contains("shell_execute"))
        #expect(captured.tools.contains("browser"))
        let failureContext: String
        if let ownedExecution, let failure = failureProbe.failure,
           failure.executionIdentity == ownedExecution {
            failureContext = "stage=\(failure.stage.rawValue) type=\(failure.errorType) case=\(failure.errorCaseName ?? "UNMAPPED")"
        } else {
            failureContext = "stage=UNOBSERVED type=UNOBSERVED case=UNOBSERVED"
        }
        #expect(captured.calls == 1, Comment(rawValue: String(failureContext.prefix(320))))
    }
}

private final class MM01OrdinaryCaptureProvider: LLMProvider, @unchecked Sendable {
    let name = "MM01 ordinary no-network neighbor"
    var model = LLMModel(id: "synthetic", displayName: "synthetic", provider: "synthetic")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var capture: (prompt: String?, tools: [String], calls: Int) = (nil, [], 0)
    func snapshot() -> (prompt: String?, tools: [String], calls: Int) {
        lock.lock(); defer { lock.unlock() }; return capture
    }
    private func record(_ prompt: String?, tools: [AgentToolDefinition]) {
        lock.lock(); defer { lock.unlock() }
        capture = (prompt, tools.map(\.name), capture.calls + 1)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        record(systemPrompt, tools: []); return LLMResponse(text: "synthetic ordinary answer", stopReason: "stop", usage: nil)
    }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        record(systemPrompt, tools: tools); return LLMResponse(text: "synthetic ordinary answer", stopReason: "stop", usage: nil)
    }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

@MainActor
private final class MM01ScenarioPrebindPause {
    private(set) var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class MM01FixedScenarioFailureProbe {
    var failure: ChatTurnFailureObservationForTests?
}

@MainActor
private final class MM01BoundOwnedTurnGate {
    private(set) var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
