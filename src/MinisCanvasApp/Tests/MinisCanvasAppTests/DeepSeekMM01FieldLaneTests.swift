import Darwin
import Foundation
import CryptoKit
import MinisCore
import Testing
@testable import MinisCanvasApp

// Test oracle: only HTTPS's default port may differ; every other URL component stays exact.
private func mm01FieldEndpointEquivalent(_ actual: URL, to expected: String) -> Bool {
    guard var lhs = URLComponents(url: actual, resolvingAgainstBaseURL: false),
          var rhs = URLComponents(string: expected),
          lhs.scheme == "https", rhs.scheme == "https",
          lhs.host == "api.deepseek.com", rhs.host == "api.deepseek.com",
          (lhs.port ?? 443) == 443, (rhs.port ?? 443) == 443 else { return false }
    lhs.port = 443
    rhs.port = 443
    return lhs == rhs
}

private final class MM01FakeOfficialWire: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejectVisual = false
    nonisolated(unsafe) private static var forcedStatus: Int?
    nonisolated(unsafe) private static var forcedStatusDelay = 0
    nonisolated(unsafe) private static var onlyFlashDiscovery = false
    nonisolated(unsafe) private static var captures: [(URL, Data)] = []
    nonisolated(unsafe) private static var responseStatuses: [Int] = []
    nonisolated(unsafe) private static var ownedTransportURLs: Set<String> = []
    static var requests: [(URL, Data)] { lock.lock(); defer { lock.unlock() }; return captures }
    static var statusCodes: [Int] { lock.lock(); defer { lock.unlock() }; return responseStatuses }
    static func reset() { lock.lock(); defer { lock.unlock() }; captures = []; responseStatuses = []; rejectVisual = false; forcedStatus = nil; forcedStatusDelay = 0; onlyFlashDiscovery = false; ownedTransportURLs = [] }
    static func failVisual() { lock.lock(); defer { lock.unlock() }; rejectVisual = true }
    static func forceStatus(_ status: Int, afterNextRequests: Int = 0) {
        precondition(afterNextRequests >= 0)
        lock.lock(); defer { lock.unlock() }
        forcedStatus = status; forcedStatusDelay = afterNextRequests
    }
    static func discoverOnlyFlash() { lock.lock(); defer { lock.unlock() }; onlyFlashDiscovery = true }
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
            Self.lock.lock(); let onlyFlash = Self.onlyFlashDiscovery; Self.lock.unlock()
            content = onlyFlash ? #"{"data":[{"id":"deepseek-flash"}]}"# : #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#
        } else if streaming {
            content = "data: " + #"{"choices":[{"index":0,"delta":{"content":"MM01 controlled visual answer"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        } else {
            content = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"MM01 controlled visual answer"},"finish_reason":"stop"}]}"#
        }
        Self.lock.lock()
        let forced = Self.forcedStatusDelay == 0 ? Self.forcedStatus : nil
        if Self.forcedStatusDelay > 0 { Self.forcedStatusDelay -= 1 }
        let status = forced ?? (Self.rejectVisual && request.httpMethod == "POST" && payload?["max_tokens"] as? Int != 1 ? 503 : 200)
        Self.responseStatuses.append(status); Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


private struct MM01ReadinessTrace: SettingsProviderReadinessTransport {
    let wrapped: any SettingsProviderReadinessTransport
    var canProduceLiveEvidence: Bool { wrapped.canProduceLiveEvidence }
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        // No credential/body/header logging: this wraps and forwards the exact
        // production deferred sender; evidence classification is unchanged.
        print("MM01_READINESS_TRANSPORT_ENTER operation=\(request.operation) base=\(request.baseURL.absoluteString)")
        do {
            let response = try await wrapped.send(request)
            print("MM01_READINESS_TRANSPORT_RESPONSE status=\(response.statusCode)")
            return response
        } catch {
            if let refusal = error as? DeepSeekMM01FieldLane.Refusal {
                print("MM01_READINESS_TRANSPORT_REFUSAL=\(refusal)")
            } else {
                print("MM01_READINESS_TRANSPORT_ERROR_TYPE=\(String(reflecting: type(of: error)))")
            }
            throw error
        }
    }
}

@Suite("MM01 exact field permit, real Settings Apply and one SDK turn, fake I/O only", .serialized)
@MainActor
struct DeepSeekMM01FieldLaneTests {
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
    // MM_PARENT_RETAIN_BEGIN: explicit per-worker ownership; never infer case success.
    private func retainForSDKParent(_ root: URL, suite: String? = nil) -> Bool {
        guard let requested = ProcessInfo.processInfo.environment["MINISCANVAS_MM01_PARENT_RETAIN_ROOTS"] else { return false }
        do {
            guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess(),
                  requested == formal.runIdentity else {
                Issue.record("MM parent-retain worker contract mismatch; root retained without deletion")
                return true
            }
            var owned = stat()
            guard lstat(root.path, &owned) == 0,
                  (owned.st_mode & S_IFMT) == S_IFDIR,
                  owned.st_uid == geteuid(), owned.st_uid == formal.rootOwner,
                  (owned.st_mode & 0o777) == 0o700 else {
                Issue.record("MM parent-retain owned root identity unavailable; no deletion")
                return true
            }
            print("MM01_PARENT_RETAIN root=\(root.path) UID=\(owned.st_uid) DEV=\(owned.st_dev) INODE=\(owned.st_ino) MODE=700 SUITE=\(suite ?? "NONE") RUN=\(formal.runIdentity) cleanupAssertions=NOT_EXECUTED_PARENT_OWNS PHYSICAL_CLEANUP=NOT_RUN")
        } catch {
            Issue.record("MM parent-retain formal contract refused; no deletion")
        }
        return true
    }
    // MM_PARENT_RETAIN_END
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
        // MM_PARENT_RETAIN_EXACT_BEGIN
        if retainForSDKParent(lease.url) { return }
        // MM_PARENT_RETAIN_EXACT_END
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
        // MM_PARENT_RETAIN_PROFILE_BEGIN
        if ProcessInfo.processInfo.environment["MINISCANVAS_MM01_PARENT_RETAIN_ROOTS"] != nil {
            guard profile.isDisposable, profile.isDisposableRootIntact else {
                Issue.record("MM parent-retain profile refused; no deletion")
                return
            }
            if retainForSDKParent(profile.rootDirectory, suite: profile.userDefaultsSuiteName) { return }
        }
        // MM_PARENT_RETAIN_PROFILE_END
        do {
            try profile.cleanupDisposableRoots()
            let absent = !FileManager.default.fileExists(atPath: profile.rootDirectory.path)
            print("MM01_CLEANUP_ROOT=\(profile.rootDirectory.path) ABSENT=\(absent)")
            #expect(absent)
        } catch {
            Issue.record("Owned MM01 root cleanup refused: \(error)")
        }
    }
    private func fixture(includeIndependentBuiltin: Bool = false, retainRootOnFailure: Bool = false) async throws -> Fixture {
        MM01FakeOfficialWire.reset()
        let arguments = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            DeepSeekEnvironmentPackageFieldBootstrap.activationArgument, DeepSeekMM01FieldLane.activationArgument]
        let lease = try ownedFieldRoot("MM01-")
        var leaseTransferred = false
        defer {
            if !leaseTransferred && !retainRootOnFailure { cleanupExactOwnedRoot(lease) }
        }
        let root = lease.url
        let profile = try RuntimeIsolationProfile.makePackagedField(label: "MM01-fake",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: root.path],
            processArguments: arguments)
        if retainRootOnFailure {
            print("MM_LOCAL_CONTROL_OWNED_SUITE=\(profile.userDefaultsSuiteName ?? "MISSING") ROOT=\(profile.rootDirectory.path) ROOT_RETAINED_FOR_PARENT=true")
        }
        var fixtureCompleted = false
        defer {
            if !fixtureCompleted && !retainRootOnFailure { cleanupOwnedField(profile) }
        }
        print("MM01_NORMALIZED_PROFILE_ROOT=\(profile.rootDirectory.path) LAUNCH_IDENTITY=\(profile.launchIdentity)")
        let environment = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: profile.rootDirectory.path,
            RuntimeIsolationProfile.profileIdentityKey: profile.launchIdentity,
            "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL, "DEEPSEEK_API_KEY": "synthetic-MM01-never-real"]
        let composition = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: profile,
            bootstrapFailed: false, arguments: arguments, environment: environment))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MM01FakeOfficialWire.self]
        let fake = URLSession(configuration: configuration)
        try #require(try composition.prepareMM01ForRemoteContractTest(arguments: arguments, environment: environment, session: fake))
        fake.invalidateAndCancel()
        let defaults = profile.makeUserDefaults()
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let center = ProductionDomainAssembly.makeSettings(profile: profile, keychain: composition.keychain,
            sessionStore: sessions, sessionBadgeStore: SessionBadgeStore(directory: profile.minisCanvasDirectory),
            logManager: profile.makeLogManager(), store: ShortcutStore(defaults: defaults),
            readinessTransport: MM01ReadinessTrace(wrapped: composition.mm01ReadinessTransport),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory),
            fieldEnvironmentStore: composition.environmentStore)
        let bridge = BridgeStore(sessionStore: sessions, providerReadinessStore: center.providerReadinessStore)
        let chat = bridge.chat
        try #require(chat.attachPersistence(sessions))
        #expect(composition.install(settings: center, actualKeychain: composition.keychain, primaryCompositionSucceeded: true) == .configured)
        // Finish both real credential/metadata writes BEFORE the one-shot lane
        // is minted/bound: binding revisions include the global metadata token.
        if includeIndependentBuiltin {
            try #require(center.saveProvider(name: "DEEPSEEK", credential: .replace("synthetic-independent-builtin-never-real"),
                baseURL: DeepSeekProviderContract.baseURL, modelNames: [LLMModel.deepSeekV4Flash.id], protocolType: .openaiCompatible))
            print("MM01_DUAL_RECORD_FIXTURE bothRecordsSavedBeforeLaneActivation=true")
        }
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
        let canonicalBase = try CustomProviderURL.validate(DeepSeekProviderContract.baseURL)
        print("MM01_READINESS_BEFORE laneIntact=\(f.lane.intact) canonicalBase=\(canonicalBase.absoluteString) strictBareEqual=\(canonicalBase.absoluteString == DeepSeekProviderContract.baseURL)")
        // The field model belongs only to the actual custom record.
        let report = try #require(await f.center.checkProviderReadiness(forProviderName: DeepSeekProviderContract.apiKeyEnvironmentVariable))
        let stageFacts: [String: Any] = [
            "state": report.state.rawValue, "configuration": report.configuration.status.rawValue,
            "reachability": report.reachability.status.rawValue, "authentication": report.authentication.status.rawValue,
            "discovery": report.modelDiscovery.status.rawValue, "modelCount": report.discoveredModelIDs.count,
            "modelChecks": report.modelChecks.count, "fakeRequests": MM01FakeOfficialWire.requests.count,
            "laneIntactAfter": f.lane.intact, "redactedResult": report.redactedResult,
            "configurationDetail": report.configuration.detail, "reachabilityDetail": report.reachability.detail
        ]
        print("MM01_READINESS_REPORT=" + String(data: try JSONSerialization.data(withJSONObject: stageFacts, options: [.sortedKeys]), encoding: .utf8)!)
        #expect(report.state == .live)
        #expect(report.discoveredModelIDs == [DeepSeekMM01FieldLane.modelID])
        #expect(report.modelChecks.count == 1)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        #expect(MM01FakeOfficialWire.requests.prefix(3).allSatisfy { $0.0.absoluteString == "https://api.deepseek.com:443/models" && $0.1.isEmpty })
        try #require(MM01FakeOfficialWire.requests.count >= 4) // Preserve original expects, avoid secondary indexing SIGTRAP.
        let probe = try #require(try JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[3].1) as? [String: Any])
        #expect(probe["model"] as? String == "deepseek-flash")
        #expect(probe["max_tokens"] as? Int == 1)
        f.chat.newSession()
        let boundRecord = f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable }
        let adapter = ChatStore.ChatModelPickerAdapter(store: f.center.providerReadinessStore)
        let requestedItem = adapter.item(providerID: ProviderType.deepSeek.rawValue, modelID: DeepSeekMM01FieldLane.modelID)
        let actualRecordItem = adapter.item(providerID: DeepSeekProviderContract.apiKeyEnvironmentVariable, modelID: DeepSeekMM01FieldLane.modelID)
        let schedulerRevision = boundRecord.flatMap { f.chat.schedulerCredentialVersionSource?($0.name) }
        let settingsRevision = boundRecord.flatMap { f.center.providerCredentialBinding(recordID: $0.id)?.revision }
        let fingerprint = boundRecord.flatMap { record in
            schedulerRevision.map { ChatStore.BuiltinReadinessBinding.fingerprint(record: record, credentialRevision: $0) }
        }
        let applyFacts: [String: Bool] = [
            "laneIntact": f.lane.intact,
            "actualCustomRecordContainsFlash": boundRecord?.modelNames.contains(DeepSeekMM01FieldLane.modelID) == true,
            "boundActualCustomRecord": boundRecord != nil,
            "requestedItemExists": requestedItem != nil,
            "requestedItemSelectable": requestedItem?.isSelectable == true,
            "requestedItemApplyReceipt": requestedItem?.applyReceipt != nil,
            "actualRecordItemExists": actualRecordItem != nil,
            "actualRecordItemSelectable": actualRecordItem?.isSelectable == true,
            "actualRecordItemApplyReceipt": actualRecordItem?.applyReceipt != nil,
            "chatReceiptExists": f.chat.chatModelPickerReceipt(providerID: ProviderType.deepSeek.rawValue, modelID: DeepSeekMM01FieldLane.modelID) != nil,
            "providerRecordsSourceBound": f.chat.providerRecordsSource != nil,
            "schedulerRevisionSourceBound": f.chat.schedulerCredentialVersionSource != nil,
            "credentialMetadataSourceBound": f.chat.providerCredentialMetadataSource != nil,
            "runtimeRouteFactoryBound": f.chat.providerRuntimeRouteFactory != nil,
            "schedulerRevisionExists": schedulerRevision != nil,
            "sameActualCredentialRevision": schedulerRevision != nil && schedulerRevision == settingsRevision,
            "fingerprintMatchesStoredRecord": fingerprint != nil && f.center.providerReadinessStore.records.contains(where: { $0.configurationFingerprint == fingerprint }),
            "canSelectRequested": f.chat.canSelectChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: DeepSeekMM01FieldLane.modelID)
        ]
        print("MM01_APPLY_GUARDS=" + String(data: try JSONSerialization.data(withJSONObject: applyFacts, options: [.sortedKeys]), encoding: .utf8)!)
        let installed = try #require(boundRecord)
        let liveRecord = try #require(f.center.providerReadinessStore.records.first {
            $0.modelID == DeepSeekMM01FieldLane.modelID && $0.readinessState == .live
        })
        let producer = ConversationModelPickerConsumer(chat: f.chat)
        let rows = producer.rows.filter {
            $0.isSelectable && $0.modelID == DeepSeekMM01FieldLane.modelID
                && $0.providerID == ProviderReadinessRevision.canonicalProviderID(installed.name)
        }
        try #require(rows.count == 1)
        let row = rows[0]
        #expect(row.providerID == liveRecord.providerID)
        #expect(row.providerID == ProviderReadinessRevision.canonicalProviderID(installed.name))
        #expect(f.chat.canSelectChatModel(providerID: row.providerID, modelID: row.modelID))
        print("MM01_APPLY_PRODUCTION_ROW providerID=\(row.providerID) modelID=\(row.modelID) matchesLiveRecord=\(row.providerID == liveRecord.providerID)")
        #expect(f.chat.applyChatModel(providerID: row.providerID, modelID: row.modelID))
        try #require(f.chat.selectedReadinessProviderID.map(ProviderReadinessRevision.canonicalProviderID) == row.providerID && f.chat.selectedModelID == row.modelID)
        print("MM01_APPLY_ROUTE selectedBuiltin=\(f.chat.selectedProviderType == .deepSeek) selectedActualCustomRecord=\(f.chat.selectedCustomProvider?.id == installed.id) applyReceiptMatchesRow=\(f.chat.lastChatModelApplyReceipt?.providerID == row.providerID)")

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

    @Test("actual Settings probes and Apply resolve one field-only model into a bounded SDK image request")
    func actualSettingsApplyThenOneImageSDKRequest() async throws {
        // Positive and rejection controls for the narrow default-port equivalence.
        let expectedEndpoint = "https://api.deepseek.com:443/chat/completions"
        for text in [expectedEndpoint, "https://api.deepseek.com/chat/completions"] {
            let url = try #require(URL(string: text))
            #expect(mm01FieldEndpointEquivalent(url, to: expectedEndpoint))
        }
        for text in ["http://api.deepseek.com:443/chat/completions",
                     "https://api.deepseek.com.evil.invalid/chat/completions",
                     "https://api.deepseek.com:444/chat/completions",
                     "https://api.deepseek.com/v1/chat/completions",
                     "https://api.deepseek.com/chat/completions?extra=1",
                     "https://api.deepseek.com/chat/completions#extra",
                     "https://user@api.deepseek.com/chat/completions"] {
            let url = try #require(URL(string: text))
            #expect(!mm01FieldEndpointEquivalent(url, to: expectedEndpoint))
        }
        let f = try await fixture(); defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        #expect(!model().capabilities.supportedModalities.contains(.imageInput))
        #expect(!LLMModel.deepSeekV4Flash.capabilities.supportedModalities.contains(.imageInput))
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image, fileName: "标准几何图.png", fileType: .image,
            mimeType: "image/png", data: image))
        #expect(f.chat.composerMediaReadinessSnapshot.canSubmitAttachments)
        let provider = try f.chat.activeProvider()
        #expect(f.lane.admits(provider))
        #expect(provider.capabilities.contains(.vision))
        #expect(provider.model.capabilities.supportedModalities.contains(.imageInput))
        #expect(!MediaCapabilityGate.decide(mimeType: "application/pdf", capabilities: provider.model.capabilities).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "audio/wav", capabilities: provider.model.capabilities).isAllowed)
        #expect(!provider.model.capabilities.supportedModalities.contains(.pdfInput))
        #expect(!provider.model.capabilities.supportedModalities.contains(.audioInput))
        let sessionID = try #require(f.chat.activeSessionID)
        #expect(f.chat.streamingProviderOverride == nil)
        f.chat.turnFailureObserverForTests = { observation in
            print("MM01_ACTUAL_TURN_FAILURE stage=\(observation.stage.rawValue) errorType=\(observation.errorType) safeCase=\(observation.errorCaseName ?? "not-classified") attempt=\(observation.executionIdentity.attempt) actualSession=\(observation.sessionID?.uuidString == observation.executionIdentity.turn.sessionID)")
        }
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
        var completed = false
        for _ in 0..<500 {
            completed = !f.chat.isStreaming && f.chat.messages.contains {
                $0.role == .assistant && $0.content.contains("MM01 controlled visual answer")
            }
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let execution = f.chat.executionSnapshot(forSessionID: sessionID)
        let projectionFacts: [String: Any] = [
            "executionState": execution?.state.rawValue ?? "missing",
            "failureReasonPresent": execution?.failureReason != nil,
            "safeFailureKind": execution?.failureKind?.rawValue ?? "none",
            "executionIdentityPresent": execution?.executionIdentity != nil,
            "isStreaming": f.chat.isStreaming,
            "userCount": f.chat.messages.filter({ $0.role == .user }).count,
            "assistantCount": f.chat.messages.filter({ $0.role == .assistant }).count,
            "toolCount": f.chat.messages.filter({ $0.role == .tool }).count,
            "fakeRequestCount": MM01FakeOfficialWire.requests.count,
            "providerOverridePresent": f.chat.streamingProviderOverride != nil
        ]
        print("MM01_ACTUAL_TURN_PROJECTION=" + String(data: try JSONSerialization.data(withJSONObject: projectionFacts, options: [.sortedKeys]), encoding: .utf8)!)
        #expect(completed)
        #expect(!f.chat.isStreaming)
        #expect(f.chat.activeSessionID == sessionID)
        #expect(MM01FakeOfficialWire.requests.count == 5)
        try #require(MM01FakeOfficialWire.requests.count >= 5) // Prevent secondary SIGTRAP; original count expectation remains.
        let wire = try #require(try JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[4].1) as? [String: Any])
        #expect(mm01FieldEndpointEquivalent(MM01FakeOfficialWire.requests[4].0, to: DeepSeekMM01FieldLane.visualEndpoint))
        #expect(MM01FakeOfficialWire.requests.allSatisfy { $0.0.scheme == "https" && $0.0.host == "api.deepseek.com" && ($0.0.port ?? 443) == 443 })
        #expect(wire["model"] as? String == "deepseek-flash")
        #expect(wire["max_completion_tokens"] as? Int == 256 || wire["max_tokens"] as? Int == 256)
        let body = String(decoding: MM01FakeOfficialWire.requests[4].1, as: UTF8.self)
        // Historical literal assertion failed in cfg9f78 and remains sealed.
        // JSON escaping is not a byte-integrity oracle; decode the real URI.
        let literalContainsOwnedBase64 = body.contains(image.base64EncodedString())
        let imageRequestIndices = MM01FakeOfficialWire.requests.indices.filter { index in
            guard let json = try? JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[index].1) as? [String: Any],
                  let messages = json["messages"] as? [[String: Any]] else { return false }
            return messages.contains { message in
                (message["content"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == "image_url" || $0["image_url"] != nil
                } == true
            }
        }
        #expect(imageRequestIndices == [4])
        let semantic = try ownedPNGFromVisualJSON(wire)
        let bytesMatchOwnedPNG = semantic.data == image
        let decodedSHA = SHA256.hash(data: semantic.data).map { String(format: "%02x", $0) }.joined()
        let ownedSHA = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        #expect(semantic.imageCount == 1)
        #expect(bytesMatchOwnedPNG)
        #expect(decodedSHA == ownedSHA)
        #expect(decodedSHA == DeepSeekMM01FieldLane.imageSHA256)
        let oracleFacts: [String: Any] = [
            "visualImagePartCount": semantic.imageCount, "visualImageRequestCount": imageRequestIndices.count, "decodedByteCount": semantic.data.count,
            "ownedByteCount": image.count, "bytesMatchOwnedPNG": bytesMatchOwnedPNG,
            "decodedSHA256": decodedSHA, "ownedSHA256": ownedSHA,
            "rawLiteralContainsOwnedBase64": literalContainsOwnedBase64,
            "rawJSONHasEscapedSlash": body.contains("\\/"),
            "requestBodySHA256": SHA256.hash(data: MM01FakeOfficialWire.requests[4].1).map { String(format: "%02x", $0) }.joined()
        ]
        print("MM01_VISUAL_PNG_SEMANTIC_ORACLE=" + String(data: try JSONSerialization.data(withJSONObject: oracleFacts, options: [.sortedKeys]), encoding: .utf8)!)
        let secretAbsent = !body.contains("synthetic-MM01-never-real")
        #expect(secretAbsent)
        await #expect(throws: Error.self) { try await provider.sendMessage(messages: [message()], systemPrompt: nil, maxTokens: 256, temperature: nil) }
        #expect(MM01FakeOfficialWire.requests.count == 5)
    }

    @Test("admission and revalidation failures never create additional fake or real network requests", arguments: Negative.allCases)
    func negativeMatrix(_ failure: Negative) async throws {
        let f = try await fixture(); defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        if [.noFlag,.duplicateFlag,.duplicateC3Flag,.duplicateFieldFlag,.noField,.noIdentity,.wrongIdentity,.wrongRoot,.unsafeRoot].contains(failure) {
            var args = f.arguments; var env = f.environment
            switch failure {
            case .noFlag: args.removeAll { $0 == DeepSeekMM01FieldLane.activationArgument }
            case .duplicateFlag: args.append(DeepSeekMM01FieldLane.activationArgument)
            case .duplicateC3Flag: args.append(DeepSeekEnvironmentPackageFieldBootstrap.activationArgument)
            case .duplicateFieldFlag: args.append(RuntimeIsolationProfile.fieldActivationArgument)
            case .noField: args.removeAll { $0 == RuntimeIsolationProfile.fieldActivationArgument }
            case .noIdentity: env[RuntimeIsolationProfile.profileIdentityKey] = nil
            case .wrongIdentity: env[RuntimeIsolationProfile.profileIdentityKey] = "wrong"
            case .wrongRoot: env[RuntimeIsolationProfile.fieldActivationRootKey] = "/tmp/another-root"
            case .unsafeRoot:
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.profile.rootDirectory.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.profile.rootDirectory.path) }
                #expect(!DeepSeekMM01FieldLane.acceptsAdmission(profile: f.profile, keychain: f.composition.keychain,
                    arguments: args, environment: env))
                #expect(MM01FakeOfficialWire.requests.isEmpty); return
            default: break
            }
            #expect(!DeepSeekMM01FieldLane.acceptsAdmission(profile: f.profile, keychain: f.composition.keychain,
                    arguments: args, environment: env))
            #expect(MM01FakeOfficialWire.requests.isEmpty); return
        }
        if failure == .substitutedBacking {
            let other = f.profile.makeKeychainStore()
            let fresh = try #require(DeepSeekMM01FieldLane.makeAfterSuccessfulInstall(profile: f.profile,
                keychain: f.composition.keychain, environmentStore: f.composition.environmentStore,
                arguments: f.arguments, environment: f.environment, testConfiguration: nil))
            #expect(!fresh.bind(settings: f.center, actualKeychain: other, chat: f.chat))
            #expect(MM01FakeOfficialWire.requests.isEmpty); return
        }
        if failure == .missingReadiness {
            f.chat.newSession()
            #expect(!f.chat.applyChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: DeepSeekMM01FieldLane.modelID))
            #expect(MM01FakeOfficialWire.requests.isEmpty); return
        }
        try await ready(f)
        let baseline = MM01FakeOfficialWire.requests.count
        let (actualRecord, actualConfig, actualModel) = try actualCustomInputs(f)
        if failure == .wrongModel {
            let bad = LLMModel(id: "deepseek-v4-flash", displayName: "bad", provider: "DeepSeek")
            #expect(!f.chat.canSelectChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: bad.id))
        } else if failure == .wrongBackend {
            let bad = ProviderConfig(label: "wrong", providerType: .anthropic, runtimeProviderID: "Anthropic")
            // Same safety predicate: a wrong backend cannot construct a field provider.
            // The custom API fails by typed throw rather than the removed builtin API's nil.
            #expect(throws: Error.self) { _ = try f.lane.freezeCustom(record: actualRecord, config: bad, model: actualModel, for: f.chat) }
        } else if failure == .wrongHost {
            for host in ["http://api.deepseek.com", "https://api.deepseek.com.evil.invalid", "https://api.deepseek.com:444", "https://api.deepseek.com/v1"] {
                var bad = actualConfig; bad.customBaseURL = host
                #expect(throws: Error.self) { try f.lane.freezeCustom(record: actualRecord, config: bad, model: actualModel, for: f.chat) }
            }
        } else if failure == .wrongPort || failure == .wrongPath {
            let suffix = failure == .wrongPort ? ":444" : "/v1"
            var bad = actualConfig; bad.customBaseURL = DeepSeekProviderContract.baseURL + suffix
            #expect(throws: Error.self) { try f.lane.freezeCustom(record: actualRecord, config: bad, model: actualModel, for: f.chat) }
            var request = URLRequest(url: URL(string: DeepSeekProviderContract.baseURL + suffix + "/chat/completions")!)
            request.httpMethod = "POST"
            #expect(throws: Error.self) { try DeepSeekMM01FieldLane.normalizeOfficialRequest(request) }
        } else if failure == .transportPolicy {
            let construction = try #require(try f.lane.freezeCustom(record: actualRecord, config: actualConfig, model: actualModel, for: f.chat))
            let cfg = construction.session.configuration
            #expect(cfg.urlCache == nil && cfg.httpCookieStorage == nil)
            #expect(cfg.connectionProxyDictionary?["HTTPEnable"] as? Int == 0)
            #expect(cfg.connectionProxyDictionary?["HTTPSEnable"] as? Int == 0)
            #expect(cfg.connectionProxyDictionary?["SOCKSEnable"] as? Int == 0)
        } else if failure == .chatStoreFallback {
            let provider = try f.chat.activeProvider()
            #expect(!f.bridge.productionExternalNetworkAllowed)
            let factory = try #require(f.chat.providerRuntimeRouteFactory)
            let route = try #require(factory(provider))
            #expect(route.snapshot.fallbackProviderIDs.isEmpty)
            MM01FakeOfficialWire.failVisual()
            let actualFailure = try await actualNegative503ProducerTurn(f)
            #expect(actualFailure.failures.count == 1
                && actualFailure.failures.first?.stage == .streamConsumption
                && actualFailure.failures.first?.errorType == "MinisCore.LLMError"
                && actualFailure.failures.first?.executionIdentity.attempt == 1
                && actualFailure.failures.first?.executionIdentity.turn == actualFailure.snapshot.turn
                && actualFailure.requestCount == baseline + 1
                && actualFailure.statusCodes == [200, 200, 200, 200, 503]
                && actualFailure.pngBytesMatch
                && actualFailure.route.snapshot.fallbackProviderIDs.isEmpty)
            #expect(MM01FakeOfficialWire.requests.count == baseline + 1)
        } else if failure == .innerRetry {
            let provider = try f.chat.activeProvider()
            MM01FakeOfficialWire.failVisual()
            let actualFailure = try await actualNegative503ProducerTurn(f)
            #expect(actualFailure.failures.count == 1
                && actualFailure.failures.first?.stage == .streamConsumption
                && actualFailure.failures.first?.errorType == "MinisCore.LLMError"
                && actualFailure.failures.first?.executionIdentity.attempt == 1
                && actualFailure.failures.first?.executionIdentity.turn == actualFailure.snapshot.turn
                && actualFailure.requestCount == baseline + 1
                && actualFailure.statusCodes == [200, 200, 200, 200, 503]
                && actualFailure.pngBytesMatch
                && actualFailure.route.snapshot.fallbackProviderIDs.isEmpty)
            #expect(MM01FakeOfficialWire.requests.count == baseline + 1)
            await #expect(throws: Error.self) { try await provider.sendMessage(messages: [message()], systemPrompt: nil, maxTokens: 256, temperature: nil) }
        } else {
            let provider = try f.chat.activeProvider()
            var messages = [message()]
            switch failure {
            case .wrongPNG: messages = [LLMMessage(role: .user, content: DeepSeekMM01FieldLane.prompt, images: [.init(mimeType: "image/png", data: Data("other".utf8))])]
            case .audio: messages = [LLMMessage(role: .user, content: DeepSeekMM01FieldLane.prompt, audios: [.init(format: "wav", base64Data: image.base64EncodedString())])]
            case .extraUserHistory: messages.insert(LLMMessage(role: .user, content: "old"), at: 0)
            case .changedRevision:
                #expect(f.center.saveProvider(name: DeepSeekProviderContract.apiKeyEnvironmentVariable,
                    apiKey: "synthetic-changed", baseURL: DeepSeekProviderContract.baseURL,
                    modelNames: [DeepSeekMM01FieldLane.modelID], protocolType: .openaiCompatible))
            case .secondVisual:
                try await actualNegativeFirstSuccessfulTurn(f)
            default: break
            }
            await #expect(throws: Error.self) { try await provider.sendMessage(messages: messages, systemPrompt: nil, maxTokens: 256, temperature: nil) }
            if failure == .wrongPNG {
                for mime in ["image/svg+xml", "application/pdf", "video/mp4"] {
                    let denied = [LLMMessage(role: .user, content: DeepSeekMM01FieldLane.prompt, images: [.init(mimeType: mime, data: image)])]
                    await #expect(throws: Error.self) { try await provider.sendMessage(messages: denied, systemPrompt: nil, maxTokens: 256, temperature: nil) }
                }
            }
        }
        #expect(MM01FakeOfficialWire.requests.count == baseline + ([.secondVisual, .innerRetry, .chatStoreFallback].contains(failure) ? 1 : 0))
    }
}


private final class MM01Owned302Server: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var requests = 0
    private var stopped = false
    private let location: String?
    let port: UInt16
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    init(location: String? = nil) throws {
        self.location = location
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        listener = fd
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { Darwin.close(fd); throw URLError(.badURL) }
        let rc = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [weak self] in self?.serve() }
    }
    func stop() { lock.lock(); let first = !stopped; stopped = true; lock.unlock()
        if first { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener) } }
    func listenerIsClosed() -> Bool {
        errno = 0
        return fcntl(listener, F_GETFD) == -1 && errno == EBADF
    }
    deinit { stop() }
    private func serve() {
        let client = accept(listener, nil, nil); guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        guard recv(client, &buffer, buffer.count, 0) > 0 else { return }
        lock.lock(); requests += 1; lock.unlock()
        let header = location.map { "HTTP/1.1 302 Found\r\nLocation: \($0)\r\n" } ?? "HTTP/1.1 200 OK\r\n"
        let response = Data((header + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8)
        response.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }; var sent = 0
            while sent < bytes.count {
                let n = Darwin.send(client, start.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { return }; sent += n
            }
        }
    }
}

extension DeepSeekMM01FieldLaneTests {
    @Test("C3 failure cannot mint a permit or expose a readiness sender")
    func failedInstallHasNoPermitOrWire() async throws {
        MM01FakeOfficialWire.reset()
        let lease = try ownedFieldRoot("MM01-failed-")
        defer { cleanupExactOwnedRoot(lease) }
        let root = lease.url
        let args = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            DeepSeekEnvironmentPackageFieldBootstrap.activationArgument, DeepSeekMM01FieldLane.activationArgument]
        let p = try RuntimeIsolationProfile.makePackagedField(label: "MM01-failed",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: root.path], processArguments: args)
        print("MM01_NORMALIZED_PROFILE_ROOT=\(p.rootDirectory.path) LAUNCH_IDENTITY=\(p.launchIdentity)")
        let env = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: p.rootDirectory.path,
            RuntimeIsolationProfile.profileIdentityKey: p.launchIdentity, "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL,
            "DEEPSEEK_API_KEY": "synthetic-failed-install"]
        let composition = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: p, bootstrapFailed: false, arguments: args, environment: env))
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MM01FakeOfficialWire.self]
        let fake = URLSession(configuration: cfg); defer { fake.invalidateAndCancel() }
        #expect(try composition.prepareMM01ForRemoteContractTest(arguments: args, environment: env, session: fake))
        let sessions = SessionStore(directory: p.sessionDirectory)
        let center = ProductionDomainAssembly.makeSettings(profile: p, keychain: composition.keychain,
            sessionStore: sessions, sessionBadgeStore: SessionBadgeStore(directory: p.minisCanvasDirectory),
            logManager: p.makeLogManager(), store: ShortcutStore(defaults: p.makeUserDefaults()),
            readinessTransport: composition.mm01ReadinessTransport,
            providerReadinessStore: ProviderReadinessStore(directory: p.providerConfigurationDirectory),
            fieldEnvironmentStore: composition.environmentStore)
        let chat = ChatStore(providerReadinessStore: center.providerReadinessStore, preferencesDefaults: p.makeUserDefaults())
        #expect(composition.activateMM01(settings: center, actualKeychain: composition.keychain, chat: chat) == nil)
        #expect(composition.install(settings: center, actualKeychain: composition.keychain, primaryCompositionSucceeded: false) == .refused)
        #expect(composition.activateMM01(settings: center, actualKeychain: composition.keychain, chat: chat) == nil)
        #expect(center.mm01FieldLane == nil && chat.mm01FieldLane == nil && center.providerRecords.isEmpty)
        await #expect(throws: Error.self) { try await composition.mm01ReadinessTransport.send(
            .init(operation: .reachability, providerID: DeepSeekProviderContract.apiKeyEnvironmentVariable,
                baseURL: URL(string: DeepSeekProviderContract.baseURL)!, apiKey: "synthetic-failed-install", modelID: nil, protocolType: .openaiCompatible)) }
        #expect(MM01FakeOfficialWire.requests.isEmpty)
    }

    @Test("native URLSession receives owned HTTP302 but redirect target receives zero requests")
    func actualOwned302HasZeroRedirectTargetWire() async throws {
        let target = try MM01Owned302Server(); defer { target.stop() }
        let source = try MM01Owned302Server(location: "http://127.0.0.1:\(target.port)/must-not-be-requested")
        defer { source.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: MM01NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(source.port)/owned-302")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(source.requestCount == 1)
        #expect(target.requestCount == 0)
        print("MM01_OWNED_SOCKET pid=\(ProcessInfo.processInfo.processIdentifier) sourcePort=\(source.port) targetPort=\(target.port) sourceRequests=\(source.requestCount) targetRequests=\(target.requestCount)")
        source.stop(); target.stop()
        let sourceClosed = source.listenerIsClosed()
        let targetClosed = target.listenerIsClosed()
        #expect(sourceClosed && targetClosed)
        print("MM01_OWNED_SOCKET_STOP sourceListenerClosed=\(sourceClosed) targetListenerClosed=\(targetClosed)")
        // This is a real owned HTTP socket test of the production redirect
        // delegate, not a vendor request or an official HTTPS admission bypass.
    }

    @Test("same frozen lane session receives owned302: first leg1, redirect target0; official policy rejects loopback")
    func frozenLaneSessionOwned302RejectsRedirect() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease); MM01FakeOfficialWire.reset() }
        try await ready(f)
        let (actualRecord, actualConfig, actualModel) = try actualCustomInputs(f)
        let construction = try #require(try f.lane.freezeCustom(record: actualRecord, config: actualConfig, model: actualModel, for: f.chat))
        let again = try #require(try f.lane.freezeCustom(record: actualRecord, config: actualConfig, model: actualModel, for: f.chat))
        #expect(construction.session === again.session)
        #expect(construction.session.delegate is MM01NoRedirect)
        let cfg = construction.session.configuration
        #expect(cfg.urlCache == nil && cfg.httpCookieStorage == nil)
        #expect(cfg.connectionProxyDictionary?["HTTPEnable"] as? Int == 0)
        #expect(cfg.connectionProxyDictionary?["HTTPSEnable"] as? Int == 0)
        #expect(cfg.connectionProxyDictionary?["SOCKSEnable"] as? Int == 0)
        let target = try MM01Owned302Server(); defer { target.stop() }
        let targetURL = try #require(URL(string: "http://127.0.0.1:\(target.port)/must-not-be-requested"))
        let source = try MM01Owned302Server(location: targetURL.absoluteString); defer { source.stop() }
        let sourceURL = try #require(URL(string: "http://127.0.0.1:\(source.port)/owned-lane-302"))
        var denied = URLRequest(url: sourceURL); denied.httpMethod = "POST"
        #expect(throws: Error.self) { try DeepSeekMM01FieldLane.normalizeOfficialRequest(denied) }
        #expect(source.requestCount == 0 && target.requestCount == 0)
        MM01FakeOfficialWire.allowOwnedTransportOnly([sourceURL, targetURL])
        // Test-only direct access to the actual lane session proves transport
        // behavior. This intentionally does not assert loopback lane admission.
        let (_, response) = try await construction.session.data(from: sourceURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(source.requestCount == 1)
        #expect(target.requestCount == 0)
        print("MM01_OWNED_SOCKET pid=\(ProcessInfo.processInfo.processIdentifier) sourcePort=\(source.port) targetPort=\(target.port) sourceRequests=\(source.requestCount) targetRequests=\(target.requestCount)")
        source.stop(); target.stop()
        let sourceClosed = source.listenerIsClosed()
        let targetClosed = target.listenerIsClosed()
        #expect(sourceClosed && targetClosed)
        print("MM01_OWNED_SOCKET_STOP sourceListenerClosed=\(sourceClosed) targetListenerClosed=\(targetClosed)")
        #expect(MM01FakeOfficialWire.requests.count == 4) // readiness baseline only
    }

    @Test("actual ChatStore route rejects a nonstandard user prompt before an extra SDK request")
    func actualRouteRejectsNonstandardUserPrompt() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        let provider = try f.chat.activeProvider()
        let factory = try #require(f.chat.providerRuntimeRouteFactory)
        let route = try #require(factory(provider))
        let changed = LLMMessage(role: .user, content: "Agent-added nonstandard prefix\n" + DeepSeekMM01FieldLane.prompt,
            images: [.init(mimeType: "image/png", data: image)])
        await #expect(throws: Error.self) {
            try await route.sendMessage(messages: [changed], systemPrompt: nil, maxTokens: 256, temperature: nil)
        }
        #expect(MM01FakeOfficialWire.requests.count == 4) // extra wire0, baseline4
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)
        // Actual Agent engine prompt assembly and nonnil systemPrompt remain
        // NOT_COVERED by this controlled route-input negative.
    }


    @Test("actual ChatStore route must reject a nonnil unapproved system prompt before extra wire")
    func actualRouteRejectsUnapprovedSystemPrompt() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        let provider = try f.chat.activeProvider()
        let factory = try #require(f.chat.providerRuntimeRouteFactory)
        let route = try #require(factory(provider))
        await #expect(throws: Error.self) {
            try await route.sendMessage(messages: [message()], systemPrompt: "synthetic unapproved Agent system instruction",
                maxTokens: 256, temperature: nil)
        }
        #expect(MM01FakeOfficialWire.requests.count == 4) // baseline4, required extra0
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)
        // Regression candidate: current Source forwards this systemPrompt;
        // expected RED until a narrowly reviewed production refusal is installed.
    }


    private func actualRegisteredScenarioBaseline(_ f: Fixture) async throws -> (MM01ProviderConstruction, any LLMProvider) {
        try await ready(f)
        let record = try #require(f.chat.selectedCustomProvider)
        var cfg = ProviderConfig(label: record.name, providerType: .openAI, runtimeProviderID: record.name)
        cfg.customBaseURL = record.baseURL; cfg.appendV1Suffix = false
        try #require(f.composition.keychain.backingKind == .injected)
        let rawCredential: String? = f.composition.keychain.get(record.name) // Synthetic RAM only; one get call.
        let credential: String = try #require(rawCredential)
        try #require(!credential.isEmpty)
        cfg.apiKey = credential
        let runtimeModel = LLMModel(id: DeepSeekMM01FieldLane.modelID, displayName: "owned", provider: record.name)
        let construction = try #require(try f.lane.freezeCustom(record: record, config: cfg, model: runtimeModel, for: f.chat))
        let provider = construction.makeProvider()
        try #require(f.lane.admits(provider))
        try #require(f.chat.streamingProviderOverride == nil)
        f.chat.turnFailureObserverForTests = { observation in
            Issue.record("Legal actual baseline failed: stage=\(observation.stage.rawValue), type=\(observation.errorType)")
        }
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image, fileName: "标准几何图.png", fileType: .image,
            mimeType: "image/png", data: image))
        try #require(f.chat.composerMediaReadinessSnapshot.canSubmitAttachments)
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
        var completed = false
        for _ in 0..<500 {
            completed = !f.chat.isStreaming && f.chat.messages.contains {
                $0.role == .assistant && $0.content.contains("MM01 controlled visual answer")
            }
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(completed)
        try #require(f.chat.activeSessionID == construction.sessionID)
        try #require(f.chat.executionSnapshot(forSessionID: construction.sessionID)?.state == .idle)
        try #require(f.chat.messages.filter({ $0.role == .user }).count == 1)
        try #require(f.chat.messages.filter({ $0.role == .tool }).isEmpty)
        try #require(MM01FakeOfficialWire.requests.count == 5)
        let wire = try #require(try JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[4].1) as? [String: Any])
        let decoded = try ownedPNGFromVisualJSON(wire)
        let bytesMatch = decoded.data == image
        let sha = SHA256.hash(data: decoded.data).map { String(format: "%02x", $0) }.joined()
        try #require(bytesMatch && sha == DeepSeekMM01FieldLane.imageSHA256)
        try #require(mm01FieldEndpointEquivalent(MM01FakeOfficialWire.requests[4].0, to: DeepSeekMM01FieldLane.visualEndpoint))
        try #require(wire["model"] as? String == DeepSeekMM01FieldLane.modelID)
        try #require(wire["max_tokens"] as? Int == 256 || wire["max_completion_tokens"] as? Int == 256)
        print("MM01_LEGAL_REGISTERED_BASELINE fakeRequests=5 imageRequests=1 ownedPNGSHA=\(sha) completed=true idle=true toolCount=0")
        return (construction, provider)
    }

    @Test("legally registered actual Composer scenario consumes once then refuses an approved replay with extra wire0")
    func actualRegisteredScenarioAllowsOneThenRefusesReplay() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        let (_, provider) = try await actualRegisteredScenarioBaseline(f)
        let baseline = MM01FakeOfficialWire.requests.count
        try #require(f.lane.intact)
        await #expect(throws: Error.self) {
            try await provider.sendMessage(messages: [message()], systemPrompt: MM01AgentScenarioContract.approvedSystemPrompt,
                maxTokens: 256, temperature: 0.7)
        }
        #expect(MM01FakeOfficialWire.requests.count == baseline)
        #expect(baseline == 5)
        print("MM01_REPLAY baseline=5 extraURLProtocolRequests=\(MM01FakeOfficialWire.requests.count - baseline)")
    }

    @Test("same actual custom lane session after a legal registered scenario rejects owned302 redirect: first1 target0")
    func actualRegisteredLaneSessionRejectsOwned302Redirect() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease); MM01FakeOfficialWire.reset() }
        let (construction, _) = try await actualRegisteredScenarioBaseline(f)
        let baseline = MM01FakeOfficialWire.requests.count
        #expect(construction.session.delegate is MM01NoRedirect)
        let cfg = construction.session.configuration
        #expect(cfg.urlCache == nil && cfg.httpCookieStorage == nil)
        #expect(cfg.connectionProxyDictionary?["HTTPEnable"] as? Int == 0)
        #expect(cfg.connectionProxyDictionary?["HTTPSEnable"] as? Int == 0)
        #expect(cfg.connectionProxyDictionary?["SOCKSEnable"] as? Int == 0)
        let target = try MM01Owned302Server(); defer { target.stop() }
        let targetURL = try #require(URL(string: "http://127.0.0.1:\(target.port)/must-not-be-requested"))
        let source = try MM01Owned302Server(location: targetURL.absoluteString); defer { source.stop() }
        let sourceURL = try #require(URL(string: "http://127.0.0.1:\(source.port)/owned-registered-lane-302"))
        var denied = URLRequest(url: sourceURL); denied.httpMethod = "POST"
        #expect(throws: Error.self) { try DeepSeekMM01FieldLane.normalizeOfficialRequest(denied) }
        #expect(source.requestCount == 0 && target.requestCount == 0)
        MM01FakeOfficialWire.allowOwnedTransportOnly([sourceURL, targetURL])
        // Direct test access to the same actual session. Production official
        // admission still rejects loopback; only the transport layer is proved.
        let (_, response) = try await construction.session.data(from: sourceURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(source.requestCount == 1)
        #expect(target.requestCount == 0)
        #expect(MM01FakeOfficialWire.requests.count == baseline)
        #expect(baseline == 5)
        source.stop(); target.stop()
        let sourceClosed = source.listenerIsClosed()
        let targetClosed = target.listenerIsClosed()
        #expect(sourceClosed && targetClosed)
        print("MM01_REGISTERED_SOCKET_IDENTITY PID=\(getpid()) sourcePort=\(source.port) targetPort=\(target.port) sourceListenerClosed=\(sourceClosed) targetListenerClosed=\(targetClosed)")
        print("MM01_REGISTERED_OWNED302 baselineFake=5 firstOwnedLeg=\(source.requestCount) redirectTarget=\(target.requestCount) extraOfficialURLProtocol=\(MM01FakeOfficialWire.requests.count - baseline) vendorWire=0")
    }


    private func checkAdmissionPredicate(_ predicate: Negative) async throws {
        MM01FakeOfficialWire.reset()
        // Pristine profile: C3 prepare refuses pre-existing env metadata. Never
        // create/install a full fixture and then delete metadata to reach it.
        let lease = try ownedFieldRoot("MM01-admission-")
        defer { cleanupExactOwnedRoot(lease) }
        let argsControl = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument,
            DeepSeekEnvironmentPackageFieldBootstrap.activationArgument, DeepSeekMM01FieldLane.activationArgument]
        let profile = try RuntimeIsolationProfile.makePackagedField(label: "MM01-admission",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: lease.url.path],
            processArguments: argsControl)
        defer { cleanupOwnedField(profile) }
        let envControl = [RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
            RuntimeIsolationProfile.fieldActivationRootKey: profile.rootDirectory.path,
            RuntimeIsolationProfile.profileIdentityKey: profile.launchIdentity,
            "DEEPSEEK_BASE_URL": DeepSeekProviderContract.baseURL,
            "DEEPSEEK_API_KEY": "synthetic-admission-never-real"]
        let metadata = profile.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)
        try #require(!FileManager.default.fileExists(atPath: metadata.path))
        let positive = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: profile, bootstrapFailed: false, arguments: argsControl, environment: envControl))
        try #require(!FileManager.default.fileExists(atPath: metadata.path))
        let negative = try #require(DeepSeekEnvironmentPackageFieldBootstrap.prepare(profile: profile, bootstrapFailed: false, arguments: argsControl, environment: envControl))
        try #require(!FileManager.default.fileExists(atPath: metadata.path))
        let positiveAccepted = positive.prepareMM01(arguments: argsControl, environment: envControl)
        try #require(positiveAccepted)
        var args = argsControl; var env = envControl
        var changedMode = false
        defer { if changedMode { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.rootDirectory.path) } }
        switch predicate {
        case .noFlag: args.removeAll { $0 == DeepSeekMM01FieldLane.activationArgument }
        case .duplicateFlag: args.append(DeepSeekMM01FieldLane.activationArgument)
        case .noField: args.removeAll { $0 == RuntimeIsolationProfile.fieldActivationArgument }
        case .noIdentity: env[RuntimeIsolationProfile.profileIdentityKey] = nil
        case .wrongIdentity: env[RuntimeIsolationProfile.profileIdentityKey] = "synthetic-other-profile-identity"
        case .wrongRoot: env[RuntimeIsolationProfile.fieldActivationRootKey] = profile.rootDirectory.path + "-not-this-owned-root"
        case .unsafeRoot:
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile.rootDirectory.path)
            changedMode = true
        default: Issue.record("Unsupported admission predicate"); return
        }
        let negativeAccepted = negative.prepareMM01(arguments: args, environment: env)
        #expect(!negativeAccepted)
        #expect(MM01FakeOfficialWire.requests.isEmpty)
        print("MM01_ADMISSION predicate=\(String(describing: predicate)) positiveAccepted=\(positiveAccepted) negativeAccepted=\(negativeAccepted) extraURLProtocol=\(MM01FakeOfficialWire.requests.count)")
    }

    @Test("admissionNoMMFlag: lawful admission control versus one changed predicate")
    func admissionNoMMFlag() async throws { try await checkAdmissionPredicate(.noFlag) }

    @Test("admissionDuplicateMMFlag: lawful admission control versus one changed predicate")
    func admissionDuplicateMMFlag() async throws { try await checkAdmissionPredicate(.duplicateFlag) }

    @Test("admissionNoFieldFlag: lawful admission control versus one changed predicate")
    func admissionNoFieldFlag() async throws { try await checkAdmissionPredicate(.noField) }

    @Test("admissionNoProfileIdentity: lawful admission control versus one changed predicate")
    func admissionNoProfileIdentity() async throws { try await checkAdmissionPredicate(.noIdentity) }

    @Test("admissionWrongProfileIdentity: lawful admission control versus one changed predicate")
    func admissionWrongProfileIdentity() async throws { try await checkAdmissionPredicate(.wrongIdentity) }

    @Test("admissionWrongOwnedRoot: lawful admission control versus one changed predicate")
    func admissionWrongOwnedRoot() async throws { try await checkAdmissionPredicate(.wrongRoot) }

    @Test("admissionUnsafeOwnedRootMode: lawful admission control versus one changed predicate")
    func admissionUnsafeOwnedRootMode() async throws { try await checkAdmissionPredicate(.unsafeRoot) }


    @Test("same post-install owned backing binds, substituted injected backing refuses before wire")
    func admissionSubstitutedBackingRefuses() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        let good = try #require(DeepSeekMM01FieldLane.makeAfterSuccessfulInstall(profile: f.profile, keychain: f.composition.keychain,
            environmentStore: f.composition.environmentStore, arguments: f.arguments, environment: f.environment, testConfiguration: nil))
        let bad = try #require(DeepSeekMM01FieldLane.makeAfterSuccessfulInstall(profile: f.profile, keychain: f.composition.keychain,
            environmentStore: f.composition.environmentStore, arguments: f.arguments, environment: f.environment, testConfiguration: nil))
        let controlBound = good.bind(settings: f.center, actualKeychain: f.composition.keychain, chat: f.chat)
        try #require(controlBound)
        let substitute = f.profile.makeKeychainStore()
        try #require(substitute !== f.composition.keychain && substitute.backingKind == .injected)
        let substitutedBound = bad.bind(settings: f.center, actualKeychain: substitute, chat: f.chat)
        #expect(!substitutedBound)
        #expect(MM01FakeOfficialWire.requests.isEmpty)
        print("MM01_BACKING_CONTROL actualBound=true substituteBound=\(substitutedBound) extraURLProtocol=0")
    }

    private func actualCustomInputs(_ f: Fixture) throws -> (EnvVarEntry, ProviderConfig, LLMModel) {
        let record = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        var cfg = ProviderConfig(label: record.name, providerType: .openAI, runtimeProviderID: record.name)
        cfg.customBaseURL = record.baseURL; cfg.appendV1Suffix = false
        try #require(f.composition.keychain.backingKind == .injected)
        let ownedValue: String? = f.composition.keychain.get(record.name)
        let credential: String = try #require(ownedValue)
        let credentialNonempty = !credential.isEmpty
        try #require(credentialNonempty)
        cfg.apiKey = credential
        return (record, cfg, LLMModel(id: DeepSeekMM01FieldLane.modelID, displayName: "owned", provider: record.name))
    }

    @Test("actual custom row refuses before readiness and accepts after real four probes plus Apply")
    func freezeMissingReadinessRefusesThenRealApplyAccepts() async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        let (record, cfg, runtimeModel) = try actualCustomInputs(f)
        try #require(f.lane.intact)
        #expect(throws: Error.self) { _ = try f.lane.freezeCustom(record: record, config: cfg, model: runtimeModel, for: f.chat) }
        #expect(MM01FakeOfficialWire.requests.isEmpty)
        // Apply cannot legally precede readiness. The control advances that
        // real prerequisite, rather than forging a ready/apply receipt.
        try await ready(f)
        let current = try #require(f.chat.selectedCustomProvider)
        let accepted = try f.lane.freezeCustom(record: current, config: cfg, model: runtimeModel, for: f.chat)
        try #require(accepted != nil)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        print("MM01_READINESS_PREREQUISITE beforeWire=0 afterFourProbesApplyAccepted=true extraVisual=0")
    }

    private func checkFreezePredicate(_ predicate: Negative) async throws {
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        let (record, cfg, runtimeModel) = try actualCustomInputs(f)
        let control = try f.lane.freezeCustom(record: record, config: cfg, model: runtimeModel, for: f.chat)
        try #require(control != nil)
        let baseline = MM01FakeOfficialWire.requests.count
        var changed = cfg; var changedModel = runtimeModel
        switch predicate {
        case .wrongModel:
            changedModel = LLMModel(id: "deepseek-v4-pro", displayName: runtimeModel.displayName, provider: record.name)
        case .wrongBackend:
            changed = ProviderConfig(id: cfg.id, label: cfg.label, providerType: .anthropic,
                runtimeProviderID: cfg.runtimeProviderID, credentialType: cfg.credentialType,
                isEnabled: cfg.isEnabled, createdAt: cfg.createdAt, customBaseURL: cfg.customBaseURL,
                appendV1Suffix: cfg.appendV1Suffix, apiKeyEnvVar: cfg.apiKeyEnvVar, apiKey: cfg.apiKey,
                attemptCheckpointDirectory: cfg.attemptCheckpointDirectory)
        case .wrongHost: changed.customBaseURL = "https://sibling.deepseek.com"
        default: Issue.record("Unsupported freeze predicate"); return
        }
        #expect(throws: Error.self) { _ = try f.lane.freezeCustom(record: record, config: changed, model: changedModel, for: f.chat) }
        #expect(MM01FakeOfficialWire.requests.count == baseline)
        #expect(baseline == 4)
        print("MM01_CUSTOM_FREEZE predicate=\(String(describing: predicate)) validActualRowControl=true baseline=4 extraURLProtocol=\(MM01FakeOfficialWire.requests.count - baseline)")
    }

    @Test("freezeWrongModel: same actual custom row and credential only modelID changes")
    func freezeWrongModelRefuses() async throws { try await checkFreezePredicate(.wrongModel) }
    @Test("freezeWrongBackend: same actual custom row and credential only backend changes")
    func freezeWrongBackendRefuses() async throws { try await checkFreezePredicate(.wrongBackend) }
    @Test("freezeWrongHost: same actual custom row and credential only endpoint changes")
    func freezeWrongHostRefuses() async throws { try await checkFreezePredicate(.wrongHost) }

    private struct Negative503ProducerObservation {
        let failures: [ChatTurnFailureObservationForTests]
        let snapshot: ChatTurnRuntimeSnapshot
        let route: ProviderRuntimeRoute
        let requestCount: Int
        let statusCodes: [Int]
        let pngBytesMatch: Bool
    }
    private func actualNegative503ProducerTurn(_ f: Fixture) async throws -> Negative503ProducerObservation {
        // B1310: submitComposer is a Void producer. Return only its actual typed
        // failure observation; do not synthesize a thrown provider error.
        guard let sessionID = f.chat.activeSessionID,
              let runtimeFactory = f.chat.turnRuntimeSnapshotFactory else {
            throw NegativeActualSuccessError.producer
        }
        let observations = ExpectedFailureBox()
        f.chat.turnRuntimeSnapshotFactory = { turn, actualProvider in
            let snapshot = runtimeFactory(turn, actualProvider)
            observations.actualSnapshots.append(snapshot)
            return snapshot
        }
        defer {
            f.chat.turnRuntimeSnapshotFactory = runtimeFactory
            f.chat.turnFailureObserverForTests = nil
        }
        f.chat.turnFailureObserverForTests = { observation in observations.observations.append(observation) }
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image, fileName: "标准几何图.png", fileType: .image,
            mimeType: "image/png", data: image))
        guard f.chat.composerMediaReadinessSnapshot.canSubmitAttachments else {
            throw NegativeActualSuccessError.producer
        }
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
        var failed = false
        for _ in 0..<500 {
            failed = !f.chat.isStreaming && f.chat.executionSnapshot(forSessionID: sessionID)?.state == .failed
            if failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard failed, f.chat.activeSessionID == sessionID,
              observations.actualSnapshots.count == 1 else {
            throw NegativeActualSuccessError.producer
        }
        let snapshot = observations.actualSnapshots[0]
        guard snapshot.turn.sessionID == sessionID.uuidString else { throw NegativeActualSuccessError.producer }
        let route: ProviderRuntimeRoute
        if let actualRoute = snapshot.providerRuntimeRoute { route = actualRoute }
        else if let preparation = snapshot.providerRuntimeRoutePreparation {
            switch await preparation.value {
            case .success(let actualRoute): route = actualRoute
            case .failure: throw NegativeActualSuccessError.route
            }
        } else { throw NegativeActualSuccessError.route }
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)
        #expect(MM01FakeOfficialWire.requests.count == 5)
        #expect(MM01FakeOfficialWire.statusCodes == [200, 200, 200, 200, 503])
        guard MM01FakeOfficialWire.requests.count >= 5 else { throw NegativeActualSuccessError.wire }
        let wire = (try? JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[4].1)) as? [String: Any]
        #expect(wire != nil)
        guard let wire else { throw NegativeActualSuccessError.wire }
        let decoded = try ownedPNGFromVisualJSON(wire)
        let pngBytesMatch = decoded.data == image
        #expect(pngBytesMatch)
        let officialEndpointEquivalent = mm01FieldEndpointEquivalent(
            MM01FakeOfficialWire.requests[4].0, to: DeepSeekMM01FieldLane.visualEndpoint)
        #expect(officialEndpointEquivalent)
        print("MM01_NEGATIVE_ACTUAL_503 observations=\(observations.observations.count) stage=\(observations.observations.first?.stage.rawValue ?? "missing") type=\(observations.observations.first?.errorType ?? "missing") attempt=\(observations.observations.first?.executionIdentity.attempt ?? -1) fakeRequests=\(MM01FakeOfficialWire.requests.count) actualSnapshotRoute=true ownedPNGMatch=\(pngBytesMatch) fallbackCandidates=\(route.snapshot.fallbackProviderIDs.count) vendorWire=0")
        return Negative503ProducerObservation(failures: observations.observations, snapshot: snapshot, route: route,
            requestCount: MM01FakeOfficialWire.requests.count, statusCodes: MM01FakeOfficialWire.statusCodes,
            pngBytesMatch: pngBytesMatch)
    }

    private enum NegativeActualSuccessError: Error { case producer, route, wire }
    private func actualNegativeFirstSuccessfulTurn(_ f: Fixture) async throws {
        // Follow the already passing actualRegisteredScenarioBaseline and
        // actualVisual503 producer/observer path after this case's ready(f).
        // submitComposer alone creates the execution identity, scenario binding,
        // approved prompt, receipt and actual synthetic image attachment.
        guard let sessionID = f.chat.activeSessionID,
              let runtimeFactory = f.chat.turnRuntimeSnapshotFactory else {
            throw NegativeActualSuccessError.producer
        }
        let observations = ExpectedFailureBox()
        f.chat.turnRuntimeSnapshotFactory = { turn, actualProvider in
            let snapshot = runtimeFactory(turn, actualProvider)
            observations.actualSnapshots.append(snapshot)
            return snapshot
        }
        defer {
            f.chat.turnRuntimeSnapshotFactory = runtimeFactory
            f.chat.turnFailureObserverForTests = nil
        }
        f.chat.turnFailureObserverForTests = { observation in observations.observations.append(observation) }
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image, fileName: "标准几何图.png", fileType: .image,
            mimeType: "image/png", data: image))
        guard f.chat.composerMediaReadinessSnapshot.canSubmitAttachments else {
            throw NegativeActualSuccessError.producer
        }
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
        var completed = false
        for _ in 0..<500 {
            completed = !f.chat.isStreaming && f.chat.messages.contains {
                $0.role == .assistant && $0.content.contains("MM01 controlled visual answer")
            }
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard completed, observations.observations.isEmpty,
              f.chat.activeSessionID == sessionID,
              f.chat.executionSnapshot(forSessionID: sessionID)?.state == .idle,
              f.chat.messages.filter({ $0.role == .user }).count == 1,
              f.chat.messages.filter({ $0.role == .tool }).isEmpty,
              observations.actualSnapshots.count == 1 else {
            throw NegativeActualSuccessError.producer
        }
        let snapshot = observations.actualSnapshots[0]
        guard snapshot.turn.sessionID == sessionID.uuidString else { throw NegativeActualSuccessError.producer }
        let route: ProviderRuntimeRoute
        if let actualRoute = snapshot.providerRuntimeRoute { route = actualRoute }
        else if let preparation = snapshot.providerRuntimeRoutePreparation {
            switch await preparation.value {
            case .success(let actualRoute): route = actualRoute
            case .failure: throw NegativeActualSuccessError.route
            }
        } else { throw NegativeActualSuccessError.route }
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)
        #expect(MM01FakeOfficialWire.requests.count == 5)
        #expect(MM01FakeOfficialWire.statusCodes == [200, 200, 200, 200, 200])
        guard MM01FakeOfficialWire.requests.count >= 5 else { throw NegativeActualSuccessError.wire }
        let officialEndpointEquivalent = mm01FieldEndpointEquivalent(
            MM01FakeOfficialWire.requests[4].0, to: DeepSeekMM01FieldLane.visualEndpoint)
        #expect(officialEndpointEquivalent)
        let wire = (try? JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[4].1)) as? [String: Any]
        #expect(wire != nil)
        guard let wire else { throw NegativeActualSuccessError.wire }
        let decoded = try ownedPNGFromVisualJSON(wire)
        let pngBytesMatch = decoded.data == image
        #expect(pngBytesMatch)
        // Keep the original fail-closed success baseline after recording each predicate.
        guard route.snapshot.fallbackProviderIDs.isEmpty,
              MM01FakeOfficialWire.requests.count == 5,
              MM01FakeOfficialWire.statusCodes == [200, 200, 200, 200, 200],
              officialEndpointEquivalent, pngBytesMatch else { throw NegativeActualSuccessError.wire }
        print("MM01_NEGATIVE_SECOND_VISUAL firstActualTurn=idle firstVisual200=1 fakeRequests=5 preparedByActualAgent=true fallbackCandidates=0 vendorWire=0")
    }

    @MainActor private final class ExpectedFailureBox {
        var observations: [ChatTurnFailureObservationForTests] = []
        var actualSnapshots: [ChatTurnRuntimeSnapshot] = []
    }
    private enum Actual503ObservationError: Error { case snapshot, route }
    private func actualVisual503(_ check: String) async throws {
        // Independently establish the complete actual registered/scenario-bound
        // positive. The failing run gets a fresh permit and a fresh owned root.
        do {
            let positive = try await fixture()
            defer { positive.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(positive.profile); cleanupExactOwnedRoot(positive.rootLease) }
            _ = try await actualRegisteredScenarioBaseline(positive)
        }
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f)
        let sessionID = try #require(f.chat.activeSessionID)
        let provider = try f.chat.activeProvider()
        try #require(f.lane.admits(provider))
        let runtimeFactory = try #require(f.chat.turnRuntimeSnapshotFactory)
        let failures = ExpectedFailureBox()
        // Observe the exact producer-owned runtime snapshot without replacing
        // route/receipt/skill authority or copying an alternate provider.
        f.chat.turnRuntimeSnapshotFactory = { turn, actualProvider in
            let snapshot = runtimeFactory(turn, actualProvider)
            failures.actualSnapshots.append(snapshot)
            return snapshot
        }
        defer { f.chat.turnRuntimeSnapshotFactory = runtimeFactory }
        f.chat.turnFailureObserverForTests = { observation in failures.observations.append(observation) }
        f.chat.addComposerDraftAttachment(ChatAttachment(kind: .image, fileName: "标准几何图.png", fileType: .image,
            mimeType: "image/png", data: image))
        try #require(f.chat.composerMediaReadinessSnapshot.canSubmitAttachments)
        MM01FakeOfficialWire.failVisual() // Only visual response status changes; readiness already returned four200.
        f.chat.draftText = DeepSeekMM01FieldLane.prompt
        f.chat.submitComposer()
        var failed = false
        for _ in 0..<500 {
            failed = !f.chat.isStreaming && f.chat.executionSnapshot(forSessionID: sessionID)?.state == .failed
            if failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(failed)
        try #require(failures.observations.count == 1)
        let observation = failures.observations[0]
        let matchingSnapshots = failures.actualSnapshots.filter { $0.turn == observation.executionIdentity.turn }
        try #require(matchingSnapshots.count == 1)
        let actualSnapshot = matchingSnapshots[0]
        let actualRoute: ProviderRuntimeRoute
        if let route = actualSnapshot.providerRuntimeRoute { actualRoute = route }
        else if let preparation = actualSnapshot.providerRuntimeRoutePreparation {
            switch await preparation.value {
            case .success(let route): actualRoute = route
            case .failure: throw Actual503ObservationError.route
            }
        } else { throw Actual503ObservationError.snapshot }
        #expect(observation.executionIdentity.attempt == 1)
        #expect(observation.executionIdentity.turn.sessionID == sessionID.uuidString)
        #expect(f.chat.activeSessionID == sessionID)
        #expect(MM01FakeOfficialWire.statusCodes == [200, 200, 200, 200, 503])
        #expect(MM01FakeOfficialWire.requests.count == 5)
        try #require(MM01FakeOfficialWire.requests.count >= 5)
        let wire = try #require(try JSONSerialization.jsonObject(with: MM01FakeOfficialWire.requests[4].1) as? [String: Any])
        let decoded = try ownedPNGFromVisualJSON(wire)
        let bytesMatch = decoded.data == image
        #expect(bytesMatch)
        #expect(actualRoute.snapshot.fallbackProviderIDs.isEmpty)
        if check == "innerRetry" {
            await #expect(throws: Error.self) {
                _ = try await provider.sendMessage(messages: [message()], systemPrompt: MM01AgentScenarioContract.approvedSystemPrompt,
                    maxTokens: 256, temperature: 0.7)
            }
        }
        #expect(MM01FakeOfficialWire.requests.count == 5)
        print("MM01_ACTUAL_503 predicate=\(check) stage=\(observation.stage.rawValue) type=\(observation.errorType) attempt=\(observation.executionIdentity.attempt) readiness200=4 firstVisual503=1 extraRetryOrFallback=\(MM01FakeOfficialWire.requests.count - 5) fallbackCandidates=\(actualRoute.snapshot.fallbackProviderIDs.count) vendorWire=0")
    }
    @Test("actual visual503 has one admitted image attempt and zero inner or outer retry requests")
    func actualVisual503HasNoRetry() async throws { try await actualVisual503("innerRetry") }
    @Test("actual visual503 keeps the real route fallback-free with zero alternate requests")
    func actualVisual503HasNoFallback() async throws { try await actualVisual503("ChatStoreFallback") }


    private func namespaceReadiness(_ entry: EnvVarEntry, writeName: String? = nil,
                                    generation: String, checkedAt: Date) -> ProviderReadinessPersistenceRecord {
        ProviderReadinessPersistenceRecord(providerID: writeName ?? entry.name,
            modelID: entry.modelNames[0], configurationGeneration: generation,
            status: .passed, readinessState: .mock, checkedAt: checkedAt,
            evidenceID: "mock-namespace-record:" + entry.id, isApplied: true,
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: entry, credentialRevision: "F-SYNKEY-revision:" + entry.id),
            expiresAt: checkedAt.addingTimeInterval(120))
    }

    @Test("record case and trim aliases survive real persistence reload and actual picker lookup")
    func namespaceRecordCaseTrimRoundTripsActualAdapter() throws {
        let lease = try ownedFieldRoot("MM01-namespace-")
        defer { cleanupExactOwnedRoot(lease) }
        let generation = "namespace-case-trim"
        let modelID = LLMModel.deepSeekV4Flash.id // Pure metadata, no model request.
        let entry = EnvVarEntry(id: "00000000-0000-4000-8000-0000000000A1",
            name: EnvVarStore.canonicalName("  DeEpSeEk_ApI_KeY  "), value: "", isSecret: true,
            valueInKeychain: true, baseURL: DeepSeekProviderContract.baseURL, modelNames: [modelID])
        let written = namespaceReadiness(entry, writeName: "  dEePsEeK_ApI_KeY  ", generation: generation, checkedAt: Date())
        let store = ProviderReadinessStore(directory: lease.url, configurationGeneration: generation)
        try #require(store.upsert([written]))
        let reloaded = ProviderReadinessStore(directory: lease.url, configurationGeneration: generation)
        try #require(reloaded.records.count == 1)
        let persisted = reloaded.records[0]
        #expect(persisted.providerID == ProviderReadinessRevision.canonicalProviderID(entry.name))
        #expect(persisted.configurationFingerprint == written.configurationFingerprint)
        let adapter = ChatStore.ChatModelPickerAdapter(store: reloaded)
        for request in [entry.name, "deepseek_api_key", "  DeEpSeEk_ApI_KeY  "] {
            let item = try #require(adapter.item(providerID: request, modelID: modelID))
            #expect(item.providerID == persisted.providerID)
            #expect(item.evidenceID == persisted.evidenceID)
            #expect(item.applyReceiptID == persisted.applyReceiptID)
            #expect(item.isSelectable && !item.isLiveVerified)
        }
        // Backend type, configured record UUID/name, and builtin selection ID
        // are not interchangeable inputs even though a DTO knows the backend.
        #expect(ProviderConfig.canonicalProviderType(from: entry.name) == .deepSeek)
        #expect(adapter.item(providerID: ProviderType.deepSeek.rawValue, modelID: modelID) == nil)
        #expect(!adapter.isSelectable(providerID: "MISSING_UNKNOWN_PROVIDER", modelID: modelID))
        #expect(adapter.item(providerID: entry.name, modelID: modelID.uppercased()) == nil)
    }

    @Test("backend env aliases do not merge distinct configured record UUIDs or builtin picker identity")
    func namespaceBackendAliasesDoNotMergeActualPickerRecords() throws {
        let lease = try ownedFieldRoot("MM01-namespace-")
        defer { cleanupExactOwnedRoot(lease) }
        let generation = "namespace-distinct-records"
        let modelID = LLMModel.deepSeekV4Flash.id
        let names = [EnvVarStore.canonicalName(ProviderType.deepSeek.rawValue),
            "DEEPSEEK_API_KEY", "HERMES_CUSTOM_DEEPSEEK_API_KEY", "MYPROXY_KEY"]
        let entries = names.enumerated().map { index, name in
            EnvVarEntry(id: "00000000-0000-4000-8000-0000000000B\(index)", name: name,
                value: "", isSecret: true, valueInKeychain: true,
                baseURL: DeepSeekProviderContract.baseURL, modelNames: [modelID])
        }
        let records = entries.map { namespaceReadiness($0, generation: generation, checkedAt: Date()) }
        let store = ProviderReadinessStore(directory: lease.url, configurationGeneration: generation)
        try #require(store.upsert(records))
        let reloaded = ProviderReadinessStore(directory: lease.url, configurationGeneration: generation)
        let adapter = ChatStore.ChatModelPickerAdapter(store: reloaded)
        try #require(reloaded.records.count == entries.count)
        #expect(Set(entries.map(\.id)).count == 4)
        #expect(Set(reloaded.records.map(\.providerID)).count == 4)
        #expect(Set(reloaded.records.compactMap(\.configurationFingerprint)).count == 4)
        for (entry, record) in zip(entries, records) {
            let item = try #require(adapter.item(providerID: entry.name, modelID: modelID))
            #expect(item.evidenceID == record.evidenceID)
            #expect(item.applyReceiptID == record.applyReceiptID)
        }
        // Existing ProviderConfig legacy DTO aliases converge to a backend;
        // the persistence/adapter still retains each real record identity.
        #expect(ProviderConfig.canonicalProviderType(from: entries[1].name) == .deepSeek)
        #expect(ProviderConfig.canonicalProviderType(from: entries[2].name) == .deepSeek)
        let builtin = try #require(adapter.item(providerID: ProviderType.deepSeek.rawValue, modelID: modelID))
        let configured = try #require(adapter.item(providerID: entries[1].name, modelID: modelID))
        #expect(builtin.evidenceID == records[0].evidenceID)
        #expect(builtin.evidenceID != configured.evidenceID)
        #expect(builtin.providerID != configured.providerID)
        #expect(ProviderConfig.canonicalProviderType(from: entries[3].name) == .unsupported)
        #expect(adapter.isSelectable(providerID: entries[3].name, modelID: modelID)) // Its own explicit row only.
        #expect(adapter.item(providerID: "UNKNOWN_MISSING_RECORD", modelID: modelID) == nil)
    }

    @Test
    func fieldCustomApplyFreezePreservesIndependentBuiltinPickerProjection() async throws {
        let f = try await fixture(includeIndependentBuiltin: true)
        defer { f.chat.mm01FieldLane = f.lane; f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        try await ready(f) // Both records already saved before lane activation; real four stages and actual custom Apply.
        let custom = try #require(f.chat.selectedCustomProvider)
        let customRevision = try #require(f.center.providerCredentialBinding(recordID: custom.id)?.revision)
        let customPersisted = try #require(f.center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(custom.name) && $0.modelID == DeepSeekMM01FieldLane.modelID
        })
        // This independently saved second record already existed before lane binding.
        let builtin = try #require(f.center.providerRecords.first { $0.name == "DEEPSEEK" })
        let builtinRevision = try #require(f.center.providerCredentialBinding(recordID: builtin.id)?.revision)
        try #require(builtin.id != custom.id)
        let builtinRAM: String? = f.composition.keychain.get(builtin.name)
        let customRAM: String? = f.composition.keychain.get(custom.name)
        let builtinValue = try #require(builtinRAM)
        let customValue = try #require(customRAM)
        try #require(!builtinValue.isEmpty && !customValue.isEmpty && builtinValue != customValue)
        try #require(f.center.providerCredentialBinding(recordID: custom.id)?.revision == customRevision)
        let builtinFingerprint = ChatStore.BuiltinReadinessBinding.fingerprint(record: builtin, credentialRevision: builtinRevision)
        try #require(!builtinFingerprint.isEmpty)
        // Custom records use their ordinary persisted schema; the lane binds
        // exact UUID/current revision/RAM/live Apply instead of a builtin alias.
        #expect(customPersisted.configurationFingerprint == nil)
        try #require(builtinFingerprint != customPersisted.configurationFingerprint)
        let now = Date()
        // Explicit mock evidence: metadata projection control, never vendor/readiness network proof.
        let builtinReadiness = ProviderReadinessPersistenceRecord(providerID: builtin.name,
            modelID: LLMModel.deepSeekV4Flash.id, configurationGeneration: customPersisted.configurationGeneration,
            status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "mock-independent-builtin:" + builtin.id, isApplied: true,
            configurationFingerprint: builtinFingerprint, expiresAt: now.addingTimeInterval(120))
        try #require(f.center.providerReadinessStore.upsert([builtinReadiness]))
        let persistedBuiltin = try #require(f.center.providerReadinessStore.records.first {
            $0.providerID == ProviderReadinessRevision.canonicalProviderID(builtin.name)
                && $0.modelID == LLMModel.deepSeekV4Flash.id
        })
        try #require(persistedBuiltin.configurationFingerprint == builtinFingerprint)
        // Existing production route injection property, no new getter: turn only the lane OFF
        // while keeping both same records/store/revisions, to prove the ordinary builtin UI path.
        f.chat.mm01FieldLane = nil
        let baseline = f.chat.chatModelPickerModels(forProviderID: ProviderType.deepSeek.rawValue)
        try #require(baseline.map(\.id) == [LLMModel.deepSeekV4Flash.id])
        try #require(baseline.allSatisfy { $0.capabilities.supportedModalities == .textOnly })
        try #require(f.chat.canSelectChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: LLMModel.deepSeekV4Flash.id))
        try #require(f.chat.applyChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: LLMModel.deepSeekV4Flash.id))
        try #require(f.chat.selectedProviderType == .deepSeek && f.chat.selectedCustomProvider == nil)
        let builtinReceipt = try #require(f.chat.lastChatModelApplyReceipt)
        try #require(builtinReceipt.providerID == ProviderReadinessRevision.canonicalProviderID(builtin.name))
        // Restore the exact real custom row via the same production Apply API, then same lane.
        try #require(f.chat.applyChatModel(providerID: custom.name, modelID: DeepSeekMM01FieldLane.modelID))
        try #require(f.chat.selectedCustomProvider?.id == custom.id)
        let customReceipt = try #require(f.chat.lastChatModelApplyReceipt)
        try #require(customReceipt.providerID != builtinReceipt.providerID && customReceipt.evidenceID != builtinReceipt.evidenceID)
        f.chat.mm01FieldLane = f.lane
        try #require(f.lane.intact)
        let globalCatalog = ChatStore.ChatProvider.builtIn(.deepSeek).modelOptions
        let supported = DeepSeekProviderContract.supportedModelIDs
        func checkActualBuiltin(_ phase: String) {
            let projected = f.chat.chatModelPickerModels(forProviderID: ProviderType.deepSeek.rawValue)
            let canSelect = f.chat.canSelectChatModel(providerID: ProviderType.deepSeek.rawValue, modelID: LLMModel.deepSeekV4Flash.id)
            #expect(projected == baseline)
            #expect(canSelect)
            #expect(!projected.contains { $0.id == DeepSeekMM01FieldLane.modelID })
            #expect(projected.allSatisfy { $0.capabilities.supportedModalities == .textOnly })
            #expect(ChatStore.ChatProvider.builtIn(.deepSeek).modelOptions == globalCatalog)
            #expect(DeepSeekProviderContract.supportedModelIDs == supported)
            print("MM01_DUAL_RECORD_BUILTIN phase=\(phase) baselineCount=\(baseline.count) actualCount=\(projected.count) builtinSelectable=\(canSelect) flashInBuiltin=\(projected.contains { $0.id == DeepSeekMM01FieldLane.modelID }) distinctRecordUUID=true distinctRAM=true builtinFingerprintBound=true customFingerprintNil=true")
        }
        // On old Source0617 these semantic invariants are predicted RED: the
        // field builtin bridge substitutes flash and matches both record names.
        checkActualBuiltin("fieldActiveBeforeCustomFreeze")
        let (record, cfg, runtimeModel) = try actualCustomInputs(f)
        let value = try f.lane.freezeCustom(record: record, config: cfg, model: runtimeModel, for: f.chat)
        let construction = try #require(value)
        let provider = construction.makeProvider()
        try #require(f.lane.admits(provider))
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: provider.model.capabilities).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "application/pdf", capabilities: provider.model.capabilities).isAllowed)
        checkActualBuiltin("fieldActiveAfterCustomFreeze")
        #expect(MM01FakeOfficialWire.requests.count == 4)
        #expect(!f.bridge.productionExternalNetworkAllowed)
    }

    @Test
    func fieldCustomApplyFreezeLeavesBuiltinDeepSeekCatalogTextOnlyUnchanged() async throws {
        // Capture real production catalog before installing the field custom record.
        let catalogBefore = ChatStore.ChatProvider.builtIn(.deepSeek).modelOptions
        let supportedBefore = DeepSeekProviderContract.supportedModelIDs
        try #require(!catalogBefore.isEmpty)
        try #require(catalogBefore.filter { $0.id == DeepSeekMM01FieldLane.modelID }.count == 1)
        try #require(supportedBefore.contains(DeepSeekMM01FieldLane.modelID))
        try #require(catalogBefore.allSatisfy { $0.capabilities.supportedModalities == .textOnly })
        func checkBuiltin(_ phase: String) {
            let currentCatalog = ChatStore.ChatProvider.builtIn(.deepSeek).modelOptions
            #expect(currentCatalog == catalogBefore)
            #expect(DeepSeekProviderContract.supportedModelIDs == supportedBefore)
            #expect(currentCatalog.filter { $0.id == DeepSeekMM01FieldLane.modelID }.count == 1)
            #expect(currentCatalog.allSatisfy { $0.capabilities.supportedModalities == .textOnly })
            // A fresh production provider reads the actual default model/capability path.
            // Explicit synthetic credential prevents any environment/keychain resolution.
            let builtin = DeepSeekProvider(apiKey: "synthetic-MM01-catalog-only-never-real")
            #expect(builtin.model == .deepSeekV4Flash)
            #expect(builtin.model.capabilities.supportedModalities == .textOnly)
            #expect(!MediaCapabilityGate.decide(mimeType: "image/png", capabilities: builtin.model.capabilities).isAllowed)
            #expect(!MediaCapabilityGate.decide(mimeType: "application/pdf", capabilities: builtin.model.capabilities).isAllowed)
            print("MM01_BUILTIN_INVARIANCE phase=\(phase) catalogUnchanged=\(currentCatalog == catalogBefore) builtinTextOnly=\(builtin.model.capabilities.supportedModalities == .textOnly)")
        }
        checkBuiltin("beforeCustomInstall")
        let f = try await fixture()
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        let installed = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        #expect(installed.modelNames == [DeepSeekMM01FieldLane.modelID])
        checkBuiltin("afterCustomInstall")
        try await ready(f) // Actual Settings 4 fake probes and actual custom-row Apply.
        let selected = try #require(f.chat.selectedCustomProvider)
        try #require(selected.id == installed.id)
        let receipt = try #require(f.chat.lastChatModelApplyReceipt)
        #expect(receipt.providerID == ProviderReadinessRevision.canonicalProviderID(selected.name))
        checkBuiltin("afterRealApplyBeforeFreeze")
        let (record, cfg, runtimeModel) = try actualCustomInputs(f)
        try #require(record.id == selected.id)
        let constructionValue = try f.lane.freezeCustom(record: record, config: cfg, model: runtimeModel, for: f.chat)
        let construction = try #require(constructionValue)
        let fieldProvider = construction.makeProvider()
        try #require(f.lane.admits(fieldProvider))
        #expect(fieldProvider.model.id == DeepSeekMM01FieldLane.modelID)
        #expect(fieldProvider.name == selected.name)
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: fieldProvider.model.capabilities).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "application/pdf", capabilities: fieldProvider.model.capabilities).isAllowed)
        #expect(!fieldProvider.model.capabilities.supportedModalities.contains(.audioInput))
        checkBuiltin("afterFreezeCustom")
        #expect(!f.bridge.productionExternalNetworkAllowed)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        print("MM01_BUILTIN_INVARIANCE customActualApply=true customFreezeAdmitted=true readinessRequests=4 visualRequests=0")
    }


    @Test
    func fieldDiscoverySubsetKeepsForeignRecordsAndRejectsInvalidOwnedBinding() async throws {
        let f = try await fixture(includeIndependentBuiltin: true)
        defer { f.chat.stopAllStreamingForSafety(); EnvCredentials.supplementarySource = nil; cleanupOwnedField(f.profile); cleanupExactOwnedRoot(f.rootLease) }
        let owned = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        let builtin = try #require(f.center.providerRecords.first { $0.name == "DEEPSEEK" })
        let ordinary = EnvVarEntry(name: "INDEPENDENT_CUSTOM", value: "synthetic-subset-only",
            isSecret: true, baseURL: "https://custom.example.invalid", modelNames: ["ordinary-model"], protocolType: .openaiCompatible)
        let discovered = ["ordinary-model", LLMModel.deepSeekV4Flash.id, DeepSeekMM01FieldLane.modelID]
        try #require(f.lane.intact)
        try #require(builtin.id != owned.id && ordinary.id != owned.id)
        #expect(f.lane.discoverySubset(discovered, record: builtin) == discovered)
        #expect(f.lane.discoverySubset(discovered, record: ordinary) == discovered)
        #expect(f.lane.discoverySubset(discovered, record: owned) == [DeepSeekMM01FieldLane.modelID])
        #expect(f.lane.discoverySubset(["ordinary-model"], record: owned).isEmpty)
        var changedSameID = owned; changedSameID.name = "FORGED_NAME_SAME_UUID"
        #expect(f.lane.discoverySubset(discovered, record: changedSameID).isEmpty)
        // A real owned metadata write invalidates the captured revision; no test seam.
        try #require(f.center.saveProvider(name: owned.name, credential: .replace("synthetic-revised-field-key"),
            baseURL: owned.baseURL ?? "", modelNames: owned.modelNames, protocolType: owned.protocolType))
        try #require(!f.lane.intact)
        #expect(f.lane.discoverySubset(discovered, record: owned).isEmpty)
        #expect(f.lane.discoverySubset(discovered, record: builtin) == discovered)
        #expect(f.lane.discoverySubset(discovered, record: ordinary) == discovered)
        #expect(MM01FakeOfficialWire.requests.isEmpty)
        print("MM01_DISCOVERY_SCOPE nonownedBuiltinUnchanged=true nonownedCustomUnchanged=true ownedTypedSubset=true invalidOwnedFailClosed=true wire0=true")
    }


    // MM_LOCAL_CONTROL_REGRESSION_BEGIN
    // No test deletes these roots while hidden domain producers may still run.
    // The SDK parent must naturally wait/EOF/known0+5 before physical cleanup.
    private func retainLocalControlFixture(_ f: Fixture) {
        f.chat.stopAllStreamingForSafety()
        EnvCredentials.supplementarySource = nil
        print("MM_LOCAL_CONTROL_RETAINED_ROOT=\(f.profile.rootDirectory.path) LEASE=\(f.rootLease.url.path) UID=\(f.rootLease.owner) DEV=\(f.rootLease.device) INODE=\(f.rootLease.inode) PRODUCER_LOGICAL_JOIN=NOT_PROVEN_PARENT_PROCESS_BOUNDARY_REQUIRED")
    }

    @Test
    func completedReadinessLocalRefusalPreservesOriginalReceipt() async throws {
        let f = try await fixture(retainRootOnFailure: true)
        defer { retainLocalControlFixture(f) }
        try #require(await f.center.usageStore.waitForPersistence())
        let first = try #require(await f.center.checkProviderReadiness(forProviderName: DeepSeekProviderContract.apiKeyEnvironmentVariable))
        try #require(first.state == .live)
        let record = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        let original = f.center.providerReadinessStore.records
        try #require(original.contains { $0.status == .passed && $0.evidenceID != nil })
        #expect(MM01FakeOfficialWire.requests.count == 4)
        let repeated = try #require(await f.center.checkProviderReadiness(forProviderName: record.name))
        #expect(repeated == first)
        #expect(repeated.checkedAt == first.checkedAt)
        #expect(f.center.providerReadinessStore.records == original)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        #expect(f.center.providerReadinessLocalControlMessage(for: record) != nil)
        #expect(!f.center.isCheckingProviderReadiness)
        // An individual model recheck must not clear the same real receipt,
        // create a fake passed result, or leave a synthetic loading state.
        let previousModel = f.center.providerModelReadiness(for: record, modelID: DeepSeekMM01FieldLane.modelID)
        let model = await f.center.checkProviderModelReadiness(forProviderName: record.name, modelID: DeepSeekMM01FieldLane.modelID)
        #expect(model == previousModel)
        #expect(f.center.providerReadinessStore.records == original)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        try #require(await f.center.usageStore.waitForPersistence())
    }

    @Test
    func earlyModelControlRefusalCreatesNoFailureOrPassedReceipt() async throws {
        let f = try await fixture(retainRootOnFailure: true)
        defer { retainLocalControlFixture(f) }
        try #require(await f.center.usageStore.waitForPersistence())
        let record = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        let original = f.center.providerReadinessStore.records
        let model = await f.center.checkProviderModelReadiness(forProviderName: record.name, modelID: DeepSeekMM01FieldLane.modelID)
        #expect(model == nil)
        #expect(f.center.providerModelReadiness(for: record, modelID: DeepSeekMM01FieldLane.modelID) == nil)
        #expect(f.center.providerReadinessReport(for: record) == nil)
        #expect(f.center.providerReadinessStore.records == original)
        #expect(MM01FakeOfficialWire.requests.isEmpty)
        #expect(f.center.providerReadinessLocalControlMessage(for: record) != nil)
        let report = try #require(await f.center.checkProviderReadiness(forProviderName: record.name))
        #expect(report.state == .live)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        #expect(f.center.providerReadinessLocalControlMessage(for: record) == nil)
        try #require(await f.center.usageStore.waitForPersistence())
    }

    enum LocalControlBindingChange: String, CaseIterable, Sendable { case configuration, credential }
    @Test(arguments: LocalControlBindingChange.allCases)
    func changedBindingNeverReusesCompletedReadiness(_ change: LocalControlBindingChange) async throws {
        let f = try await fixture(retainRootOnFailure: true)
        defer { retainLocalControlFixture(f) }
        try #require(await f.center.usageStore.waitForPersistence())
        let first = try #require(await f.center.checkProviderReadiness(forProviderName: DeepSeekProviderContract.apiKeyEnvironmentVariable))
        try #require(first.state == .live)
        let record = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        let oldRevision = f.center.providerCredentialBinding(recordID: record.id)?.revision
        let credential: ProviderCredentialUpdate = change == .credential ? .replace("synthetic-replaced-never-real") : .keepExisting
        try #require(f.center.saveProvider(name: record.name, credential: credential,
            baseURL: change == .configuration ? "https://api.deepseek.com/v1" : DeepSeekProviderContract.baseURL,
            modelNames: [DeepSeekMM01FieldLane.modelID], protocolType: .openaiCompatible))
        let revisionChanged = f.center.providerCredentialBinding(recordID: record.id)?.revision != oldRevision
        #expect(revisionChanged)
        #expect(!f.lane.intact)
        let result = try #require(await f.center.checkProviderReadiness(forProviderName: record.name))
        #expect(result.state == .blocked)
        #expect(result != first)
        #expect(!f.center.providerReadinessStore.records.isEmpty)
        #expect(f.center.providerReadinessStore.records.allSatisfy { $0.status == .unavailable && $0.readinessState == .blocked })
        #expect(MM01FakeOfficialWire.requests.count == 4)
        let current = try #require(f.center.providerRecords.first { $0.id == record.id })
        #expect(f.center.providerReadinessLocalControlMessage(for: current) == nil)
        try #require(await f.center.usageStore.waitForPersistence())
    }

    @Test
    func actualHTTP403StillInvalidatesAndIsNotLocalControl() async throws {
        let f = try await fixture(retainRootOnFailure: true)
        defer { retainLocalControlFixture(f) }
        try #require(await f.center.usageStore.waitForPersistence())
        MM01FakeOfficialWire.forceStatus(403)
        let report = try #require(await f.center.checkProviderReadiness(forProviderName: DeepSeekProviderContract.apiKeyEnvironmentVariable))
        let record = try #require(f.center.providerRecords.first { $0.name == DeepSeekProviderContract.apiKeyEnvironmentVariable })
        #expect(report.state == .blocked)
        #expect(report.reachability.status == .failed)
        #expect(MM01FakeOfficialWire.statusCodes == [403])
        #expect(!f.center.providerReadinessStore.records.isEmpty)
        #expect(f.center.providerReadinessStore.records.allSatisfy { $0.status == .unavailable && $0.errorCategory == .permissionDenied })
        #expect(f.center.providerReadinessLocalControlMessage(for: record) == nil)
        let originalFailure = f.center.providerReadinessStore.records
        let repeated = try #require(await f.center.checkProviderReadiness(forProviderName: record.name))
        #expect(repeated == report)
        #expect(f.center.providerReadinessStore.records == originalFailure)
        #expect(MM01FakeOfficialWire.statusCodes == [403])
        #expect(f.center.providerReadinessLocalControlMessage(for: record) != nil)
        try #require(await f.center.usageStore.waitForPersistence())
    }

    @Test
    func ordinaryTransportStillRechecksAnd403InvalidatesPriorSuccess() async throws {
        MM01FakeOfficialWire.reset()
        MM01FakeOfficialWire.discoverOnlyFlash()
        let lease = try ownedFieldRoot("MM01-local-control-ordinary-")
        let args = ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument]
        let profile = try RuntimeIsolationProfile.makePackagedField(label: "MM01-local-control-ordinary",
            processEnvironment: [RuntimeIsolationProfile.fieldActivationMarkerKey: "1", RuntimeIsolationProfile.fieldActivationRootKey: lease.url.path],
            processArguments: args)
        print("MM_LOCAL_CONTROL_ORDINARY_OWNED_SUITE=\(profile.userDefaultsSuiteName ?? "MISSING")")
        print("MM_LOCAL_CONTROL_ORDINARY_RETAINED_ROOT=\(profile.rootDirectory.path) DEV=\(lease.device) INODE=\(lease.inode) PRODUCER_JOIN=NOT_PROVEN_PARENT_REQUIRED")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MM01FakeOfficialWire.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let keychain = profile.makeKeychainStore()
        let defaults = profile.makeUserDefaults()
        let center = ProductionDomainAssembly.makeSettings(profile: profile, keychain: keychain,
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.minisCanvasDirectory),
            logManager: profile.makeLogManager(), store: ShortcutStore(defaults: defaults),
            readinessTransport: URLSessionProviderReadinessTransport(remoteContractSession: session),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        try #require(await center.usageStore.waitForPersistence())
        try #require(center.saveProvider(name: "SYNTHETIC_ORDINARY_PROVIDER", credential: .replace("synthetic-ordinary-never-real"),
            baseURL: DeepSeekProviderContract.baseURL, modelNames: [DeepSeekMM01FieldLane.modelID], protocolType: .openaiCompatible))
        #expect(center.mm01FieldLane == nil)
        let success = try #require(await center.checkProviderReadiness(forProviderName: "SYNTHETIC_ORDINARY_PROVIDER"))
        try #require(success.state == .live)
        #expect(MM01FakeOfficialWire.requests.count == 4)
        try #require(center.providerReadinessStore.records.contains { $0.status == .passed && $0.evidenceID != nil })
        // Reachability must succeed before this case can exercise the ordinary
        // authentication failure. A 403 at reachability is correctly terminal.
        MM01FakeOfficialWire.forceStatus(403, afterNextRequests: 1)
        let failed = try #require(await center.checkProviderReadiness(forProviderName: "SYNTHETIC_ORDINARY_PROVIDER"))
        #expect(failed.state == .blocked)
        #expect(failed.authentication.status == .failed)
        #expect(MM01FakeOfficialWire.requests.count == 6)
        #expect(!center.providerReadinessStore.records.isEmpty)
        #expect(center.providerReadinessStore.records.allSatisfy { $0.status == .unavailable && $0.errorCategory == .permissionDenied })
        let record = try #require(center.providerRecords.first { $0.name == "SYNTHETIC_ORDINARY_PROVIDER" })
        #expect(center.providerReadinessLocalControlMessage(for: record) == nil)
        try #require(await center.usageStore.waitForPersistence())
    }
    // MM_LOCAL_CONTROL_REGRESSION_END

}
