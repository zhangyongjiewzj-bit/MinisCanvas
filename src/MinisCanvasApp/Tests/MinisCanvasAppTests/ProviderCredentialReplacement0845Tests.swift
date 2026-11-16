import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private enum CredentialCase0845: String, CaseIterable, Sendable {
    case emptyReplacement, typedReadFailure, validReplacement
}

/// Values stay in memory. Diagnostics expose only operation counts and matches.
private final class CredentialBacking0845: KeychainBacking, KeychainReadReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failRead = false
    private var reads = 0
    private var writes = 0
    private var deletes = 0
    func setReadFailure(_ value: Bool) { lock.withLock { failRead = value } }
    func resetCounts() { lock.withLock { reads = 0; writes = 0; deletes = 0 } }
    var counts: (reads: Int, writes: Int, deletes: Int) {
        lock.withLock { (reads, writes, deletes) }
    }
    func matches(_ expected: String, named name: String) -> Bool {
        lock.withLock { values[name] == expected }
    }
    func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock { writes += 1; values[key] = value; return true }
    }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func readResult(forKey key: String) -> KeychainReadResult {
        lock.withLock {
            reads += 1
            if failRead { return .failed }
            return values[key].map(KeychainReadResult.found) ?? .missing
        }
    }
    func delete(_ key: String) -> Bool {
        lock.withLock { deletes += 1; values.removeValue(forKey: key); return true }
    }
}

@MainActor
private final class CredentialPasteboard0845: ProviderCredentialPasteboard {
    private(set) var changeCount = 0
    private(set) var writes = 0
    func write(_ value: String) -> Bool { writes += 1; changeCount += 1; return true }
    func clearIfUnchanged(since count: Int) -> Bool { count == changeCount }
}

/// Real SDK loopback request. Never retains headers, credentials or raw requests.
private final class CredentialWire0845: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let expectedCredential: String
    private var stopped = false
    private var requests = 0
    private var authorized = false
    private var expectedPayload = false
    private var failure = false
    let port: UInt16
    var observation: (requests: Int, authorized: Bool, expectedPayload: Bool, failure: Bool) {
        lock.withLock { (requests, authorized, expectedPayload, failure) }
    }
    init(expectedCredential: String) throws {
        self.expectedCredential = expectedCredential
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
        guard bound == 0, listen(fd, 2) == 0 else {
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
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { _ = Darwin.close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 131_072 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failure = true }; return }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
            let lines = headers.components(separatedBy: "\r\n")
            guard let length = lines.compactMap({ line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }).first, length > 0, length < 65_536 else { lock.withLock { failure = true }; return }
            let offset = boundary.upperBound
            guard received.count >= offset + length else { continue }
            let credentialMatched = lines.contains {
                $0.lowercased().hasPrefix("authorization:")
                    && $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
                        == "Bearer " + expectedCredential
            }
            let body = received.subdata(in: offset..<(offset + length))
            let entity = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = entity?["messages"] as? [[String: Any]]
            let payloadMatched = entity?["model"] as? String == "gpt-4o-mini"
                && messages?.contains { $0["role"] as? String == "user"
                    && $0["content"] as? String == "CREDD_LEGITIMATE_NEXT_REQUEST" } == true
            lock.withLock { requests += 1; authorized = credentialMatched; expectedPayload = payloadMatched }
            let json = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"CREDD_NEXT_REQUEST_ACCEPTED"},"finish_reason":"stop"}]}"#
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
        lock.withLock { failure = true }
    }
}

@Suite("D-CREDD actual controls and replacement next-request consumer", .serialized)
@MainActor
struct ProviderCredentialReplacement0845Tests {
    private func center(profile: RuntimeIsolationProfile, backing: CredentialBacking0845) -> SettingsCenter {
        let keychain = KeychainStore(backing: backing)
        return SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory), logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock)
    }
    private func settle(_ model: ProviderCredentialControlsModel) async throws {
        for _ in 0..<200 {
            switch model.state {
            case .readingReveal, .readingCopy: try await Task.sleep(for: .milliseconds(5))
            default: return
            }
        }
        Issue.record("actual credential control did not complete within the original bounded fixture window")
    }
    @Test("empty input and typed read failure preserve old binding; only explicit nonempty replacement reaches the real next SDK request",
          arguments: CredentialCase0845.allCases)
    private func replacementJourney(scenario: CredentialCase0845) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "CREDD0845-" + scenario.rawValue,
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let backing = CredentialBacking0845()
        let oldValue = UUID().uuidString + UUID().uuidString
        let newValue = UUID().uuidString + UUID().uuidString
        let wire = try CredentialWire0845(expectedCredential: newValue)
        defer { wire.stop() }
        let name = "CREDD_0845_SYNTHETIC_PROVIDER"
        let endpoint = "http://127.0.0.1:\(wire.port)"
        let initial = center(profile: profile, backing: backing)
        let seeded = initial.saveProvider(name: name, credential: .replace(oldValue),
            baseURL: endpoint + "/old", modelNames: ["gpt-4o"], protocolType: .openaiCompatible)
        #expect(seeded)
        let settings = center(profile: profile, backing: backing)
        let record = try #require(settings.providerRecords.first { $0.name == name })
        #expect(record.valueInKeychain && record.value.isEmpty)
        let binding = try #require(settings.providerCredentialBinding(recordID: record.id))
        #expect(binding.isValid && binding.providerID == record.id && binding.credentialName == name)
        let pasteboard = CredentialPasteboard0845()
        let oldControls = try #require(settings.makeProviderCredentialControlsModel(recordID: record.id,
                                                                                   pasteboard: pasteboard))
        let metadataURL = profile.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)
        let originalMetadata = try Data(contentsOf: metadataURL)
        backing.resetCounts()
        switch scenario {
        case .emptyReplacement:
            #expect(!settings.saveProvider(name: name, credential: .replace(" \n\t "),
                baseURL: endpoint + "/rejected", modelNames: ["rejected-model"], protocolType: .anthropic))
            #expect(settings.providerSaveFailure == .missingCredential)
            #expect(settings.providerSaveFailure?.message == "保存失败：API Key 不能为空。")
            #expect(backing.counts.reads == 0)
        case .typedReadFailure:
            backing.setReadFailure(true)
            oldControls.reveal()
            try await settle(oldControls)
            #expect(oldControls.state == .failed(.failed))
            let failedControlHasNoValue = oldControls.visibleValue == nil
            #expect(failedControlHasNoValue)
            #expect(ProviderCredentialControlFailure.failed.message.contains("读取失败"))
            #expect(backing.counts.reads == 1)
            #expect(pasteboard.writes == 0)
        case .validReplacement:
            #expect(oldControls.state == .hidden)
            #expect(settings.providerSaveFailure == nil)
        }
        let oldValuePreserved = backing.matches(oldValue, named: name)
        #expect(oldValuePreserved)
        #expect(backing.counts.writes == 0 && backing.counts.deletes == 0)
        #expect(settings.providerCredentialBinding(recordID: record.id) == binding)
        #expect(settings.providerRecords.first { $0.id == record.id } == record)
        let rejectedMetadataUnchanged = try Data(contentsOf: metadataURL) == originalMetadata
        #expect(rejectedMetadataUnchanged)
        #expect(wire.observation.requests == 0)
        // A valid replacement does not read a denied/failed old value.
        backing.resetCounts()
        let replaced = settings.saveProvider(name: name, credential: .replace(newValue),
            baseURL: endpoint, modelNames: ["gpt-4o-mini"], protocolType: .openaiCompatible)
        #expect(replaced)
        #expect(settings.providerSaveFailure == nil)
        let newValueStored = backing.matches(newValue, named: name)
        #expect(newValueStored)
        #expect(backing.counts.reads == 0 && backing.counts.writes == 1 && backing.counts.deletes == 0)
        let successorBinding = try #require(settings.providerCredentialBinding(recordID: record.id))
        #expect(successorBinding.providerID == binding.providerID)
        #expect(successorBinding.revision != binding.revision)
        oldControls.copy()
        #expect(oldControls.state == .failed(.staleBinding))
        #expect(pasteboard.writes == 0)
        oldControls.refresh()
        let invalidatedControlMasked = oldControls.isClosed && oldControls.visibleValue == nil
        #expect(invalidatedControlMasked)
        let savedMetadata = try Data(contentsOf: metadataURL)
        let metadataSecretFree = !String(decoding: savedMetadata, as: UTF8.self).contains(oldValue)
            && !String(decoding: savedMetadata, as: UTF8.self).contains(newValue)
        #expect(metadataSecretFree)
        let reopened = center(profile: profile, backing: backing)
        let persisted = try #require(reopened.providerRecords.first { $0.id == record.id })
        #expect(persisted.baseURL == endpoint && persisted.modelNames == ["gpt-4o-mini"])
        #expect(persisted.protocolType == .openaiCompatible && persisted.valueInKeychain && persisted.value.isEmpty)
        backing.setReadFailure(false)
        let newControls = try #require(settings.makeProviderCredentialControlsModel(recordID: record.id,
                                                                   pasteboard: CredentialPasteboard0845()))
        newControls.reveal()
        try await settle(newControls)
        let controlHasNewValue = newControls.visibleValue == newValue
        #expect(controlHasNewValue)
        #expect(newControls.accessibilitySnapshot.exposedValues.isEmpty)
        let typedRead = await reopened.providerCredentialReadAsync(named: name)
        guard case .success(let actualValue) = typedRead else {
            Issue.record("valid persisted replacement did not resolve for the next request"); return
        }
        let resolvesNewValue = actualValue == newValue
        #expect(resolvesNewValue)
        var config = ProviderConfig(label: persisted.name, providerType: .openAI,
            runtimeProviderID: persisted.name, customBaseURL: persisted.baseURL, apiKey: actualValue)
        config.controlledFieldLoopbackOnly = true
        var provider = try ProviderFactory().makeProvider(for: config)
        provider.model = LLMModel(id: "gpt-4o-mini", displayName: "Owned CREDD next request", provider: name)
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: "CREDD_LEGITIMATE_NEXT_REQUEST")],
            systemPrompt: nil, maxTokens: 64, temperature: nil)
        #expect(response.text == "CREDD_NEXT_REQUEST_ACCEPTED")
        #expect(wire.observation.requests == 1 && wire.observation.authorized)
        #expect(wire.observation.expectedPayload && !wire.observation.failure)
        #expect(backing.counts.deletes == 0)
        _ = newControls.close()
        print("CREDD0845 case=\(scenario.rawValue) rejectedStatePreserved=true replacementRevisionChanged=true sdkRequests=\(wire.observation.requests) matchedNewCredential=\(wire.observation.authorized)")
    }
}
