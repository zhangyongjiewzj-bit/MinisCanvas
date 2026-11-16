import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class PasteProbeBacking0900: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writes = 0
    private var deletes = 0
    var operationCounts: (writes: Int, deletes: Int) { lock.withLock { (writes, deletes) } }
    func matches(_ value: String, name: String) -> Bool { lock.withLock { values[name] == value } }
    func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock { values[key] = value; writes += 1; return true }
    }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func readResult(forKey key: String) -> KeychainReadResult {
        lock.withLock { values[key].map(KeychainReadResult.found) ?? .missing }
    }
    func delete(_ key: String) -> Bool {
        lock.withLock { values.removeValue(forKey: key); deletes += 1; return true }
    }
}

private struct PasteProbeWireFact0900: Equatable, Sendable {
    let method: String
    let path: String
    let credentialMatched: Bool
    let approvedWriteSeen: Bool
    let modelMatched: Bool
}

/// Real production URLSession/adapter requests terminate only at this owned
/// loopback socket. Headers and bodies never become stored test observations.
private final class PasteProbeWire0900: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let expected: String
    private let backing: PasteProbeBacking0900
    private var stopped = false
    private var captured: [PasteProbeWireFact0900] = []
    private var failed = false
    let port: UInt16
    var facts: [PasteProbeWireFact0900] { lock.withLock { captured } }
    var transportFailed: Bool { lock.withLock { failed } }

    init(expected: String, backing: PasteProbeBacking0900) throws {
        self.expected = expected
        self.backing = backing
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            _ = Darwin.close(fd); throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else { _ = Darwin.close(fd); throw URLError(.cannotConnectToHost) }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }
    deinit { stop() }
    func stop() {
        let close = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true; return true
        }
        if close { _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor) }
    }
    private func serve() {
        for _ in 0..<4 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            serveClient(client)
        }
    }
    private func serveClient(_ client: Int32) {
        defer { _ = Darwin.close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 131_072 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failed = true }; return }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            let lines = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            let length = lines.compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            guard length >= 0, length < 65_536 else { lock.withLock { failed = true }; return }
            let offset = boundary.upperBound
            guard received.count >= offset + length else { continue }
            let route = lines.first?.split(separator: " ") ?? []
            guard route.count >= 2 else { lock.withLock { failed = true }; return }
            let method = String(route[0]), path = String(route[1])
            let authorized = lines.contains {
                $0.lowercased().hasPrefix("authorization:")
                    && $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
                        == "Bearer " + expected
            }
            let body = received.subdata(in: offset..<(offset + length))
            let entity = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let modelMatched = method == "GET" || entity?["model"] as? String == "gpt-4o-mini"
            let fact = PasteProbeWireFact0900(method: method, path: path,
                credentialMatched: authorized, approvedWriteSeen: backing.operationCounts.writes == 1,
                modelMatched: modelMatched)
            lock.withLock { captured.append(fact) }
            let json = method == "GET"
                ? #"{"data":[{"id":"gpt-4o-mini"}]}"#
                : #"{"choices":[{"index":0,"message":{"role":"assistant","content":"owned probe"},"finish_reason":"stop"}]}"#
            let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json).utf8)
            response.withUnsafeBytes { bytes in
                guard let pointer = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, pointer.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { return }; sent += count
                }
            }
            return
        }
        lock.withLock { failed = true }
    }
}

@Suite("D-CREDF actual pasted credential approval and owned HTTP probe", .serialized)
@MainActor
struct ChatCredentialPasteProbe0900Tests {
    private func assertNoPlaintext(_ value: String, under root: URL) throws {
        let files = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var checked = 0
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let absent = !String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(value)
            #expect(absent)
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("one pasted handle is blocked before approval, saved only for its session, and consumed by the real readiness HTTP adapter")
    func pastedHandleApprovedWriteThenRealSyntheticProbe() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "CREDF0900-paste-probe",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled)
        let backing = PasteProbeBacking0900()
        let value = "sk-" + UUID().uuidString + UUID().uuidString
        let wire = try PasteProbeWire0900(expected: value, backing: backing)
        defer { wire.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // This uses the real transport and adapters but cannot mint live
        // vendor evidence from a synthetic server.
        let transport = URLSessionProviderReadinessTransport(session: session)
        #expect(!transport.canProduceLiveEvidence)
        let keychain = KeychainStore(backing: backing)
        let env = EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain)
        let center = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: env, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory), logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            providerReadinessTransport: transport, providerReadinessDeployment: .remote)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: center.logManager)
        let store = SessionStore(directory: profile.rootDirectory.appendingPathComponent("chat"))
        #expect(chat.attachPersistence(store,
            badgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))))
        let drafts = DraftStore(directory: profile.rootDirectory.appendingPathComponent("drafts"))
        chat.attachDraftStore(drafts)
        chat.credentialBroker.attach(center: center, externalNetworkAllowed: false)
        let sessionID = try #require(chat.activeSessionID)
        // An initial UI welcome row is not a model turn. Establish the real
        // disk session and compare its complete baseline, rather than assuming
        // that either surface starts as an empty array.
        chat.touchSession(sessionID)
        let originalMessages = chat.messages
        let originalCanonical = try #require(SessionStore(directory: store.directory)
            .loadSession(id: sessionID.uuidString))
        chat.draftText = "请在本地保存这个凭据。"
        let intercepted = chat.interceptCredentialPaste(ComposerPasteEvent(text: "\nAPI Key=" + value,
                                                                            bodyBefore: chat.draftText))
        #expect(intercepted)
        let draftHasNoValue = !chat.draftText.contains(value)
        #expect(draftHasNoValue)
        let request = try #require(chat.credentialBroker.pending)
        #expect(request.sessionID == sessionID)
        #expect(center.providerRecords.isEmpty && backing.operationCounts.writes == 0)
        chat.submitComposer()
        let blockedTurnUnchanged = !chat.isStreaming && chat.messages == originalMessages
        #expect(blockedTurnUnchanged)
        #expect(chat.credentialBroker.pending?.id == request.id)
        drafts.flushAll()
        try assertNoPlaintext(value, under: profile.rootDirectory)
        #expect(wire.facts.isEmpty)
        let providerID = "CREDF_0900_SYNTHETIC_PROVIDER"
        let endpoint = "http://127.0.0.1:\(wire.port)/v1"
        let unapproved = await chat.credentialBroker.confirm(requestID: request.id, sessionID: sessionID,
            providerID: providerID, baseURL: endpoint, modelIDs: ["gpt-4o-mini"],
            protocolType: .openaiCompatible, riskConfirmed: false)
        #expect(unapproved == .rejected)
        let wrongSession = await chat.credentialBroker.confirm(requestID: request.id, sessionID: UUID(),
            providerID: providerID, baseURL: endpoint, modelIDs: ["gpt-4o-mini"],
            protocolType: .openaiCompatible, riskConfirmed: true)
        #expect(wrongSession == .rejected)
        #expect(backing.operationCounts.writes == 0 && wire.facts.isEmpty)
        #expect(chat.credentialBroker.pending?.id == request.id)
        let approved = await chat.credentialBroker.confirm(requestID: request.id, sessionID: sessionID,
            providerID: providerID, baseURL: endpoint, modelIDs: ["gpt-4o-mini"],
            protocolType: .openaiCompatible, riskConfirmed: true)
        #expect(approved == .savedProbeFailed)
        #expect(backing.operationCounts.writes == 1 && backing.operationCounts.deletes == 0)
        let storedMatches = backing.matches(value, name: providerID)
        #expect(storedMatches)
        #expect(chat.credentialBroker.pending == nil && !chat.credentialBroker.isConfirming)
        let record = try #require(center.providerRecords.first { $0.name == providerID })
        let report = try #require(center.providerReadinessReports[record.id])
        #expect(report.configuration.status == .passed && report.reachability.status == .passed)
        #expect(report.authentication.status == .passed && report.modelDiscovery.status == .passed)
        #expect(report.discoveredModelIDs == ["gpt-4o-mini"] && report.modelChecks.count == 1)
        #expect(report.state == .unverified)
        #expect(wire.facts.map { $0.method + " " + $0.path } == [
            "GET /v1", "GET /v1/models", "GET /v1/models", "POST /v1/chat/completions"])
        #expect(wire.facts.allSatisfy { $0.credentialMatched && $0.approvedWriteSeen && $0.modelMatched })
        #expect(!wire.transportFailed)
        let replayed = await chat.credentialBroker.confirm(requestID: request.id, sessionID: sessionID,
            providerID: providerID, baseURL: endpoint, modelIDs: ["gpt-4o-mini"],
            protocolType: .openaiCompatible, riskConfirmed: true)
        #expect(replayed == .rejected && wire.facts.count == 4 && backing.operationCounts.writes == 1)
        let replayCannotResolveValue = center.bl6CredentialResolver?(BL6CredentialHandle(id: request.id)) == nil
        #expect(replayCannotResolveValue)
        let reopened = EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain)
        let persisted = try #require(reopened.entry(name: providerID))
        let persistedOpaqueReference = persisted.id == record.id && persisted.valueInKeychain && persisted.value.isEmpty
        #expect(persistedOpaqueReference)
        #expect(persisted.baseURL == endpoint && persisted.modelNames == ["gpt-4o-mini"])
        let canonical = try #require(SessionStore(directory: store.directory).loadSession(id: sessionID.uuidString))
        let canonicalAndUIUnchanged = canonical == originalCanonical && chat.messages == originalMessages
        #expect(canonicalAndUIUnchanged)
        let modelProjectionSafe = !ChatTranscriptFormatter.plainText(chat.messages).contains(value)
        #expect(modelProjectionSafe)
        try assertNoPlaintext(value, under: profile.rootDirectory)
        print("CREDF0900 interception=true unapprovedWrites=0 wrongSessionWrites=0 approvedWrites=1 readinessHTTP=4 replayWrites=0 liveEvidence=false")
    }
}
