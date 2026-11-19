import Darwin
import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// A loopback HTTP peer for the real ProviderFactory URLSession transport.
/// It holds only synthetic response bodies and never records request headers.
private final class ProviderBridgeWire: @unchecked Sendable {
    enum Reply {
        case failure(Int)
        case completion(String)
        case readinessCatalog(String)

        var bytes: [UInt8] {
            let body: String
            let status: String
            let contentType: String
            switch self {
            case .failure(let code):
                status = "HTTP/1.1 \(code) Failure"
                contentType = "application/json"
                body = "remote-body-must-not-be-shown"
            case .completion(let text):
                status = "HTTP/1.1 200 OK"
                contentType = "text/event-stream"
                body = "data: "
                    + #"{"choices":[{"index":0,"delta":{"content":""#
                    + text
                    + #""},"finish_reason":"stop"}]}"#
                    + "\n\ndata: [DONE]\n\n"
            case .readinessCatalog(let modelID):
                status = "HTTP/1.1 200 OK"
                contentType = "application/json"
                body = #"{"data":[{"id":""# + modelID + #""}]}"#
            }
            return Array((status + "\r\nContent-Type: " + contentType
                + "\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                + body).utf8)
        }
    }

    private let listener: Int32
    private let lock = NSLock()
    private var requests = 0
    let port: UInt16

    var requestCount: Int { lock.withLock { requests } }

    init(replies: [Reply]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        listener = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd)
            throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, Int32(replies.count)) == 0 else {
            _ = Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else {
            _ = Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serve(replies)
        }
    }

    deinit {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        _ = Darwin.close(listener)
    }

    private func serve(_ replies: [Reply]) {
        for reply in replies {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE,
                &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var request = [UInt8](repeating: 0, count: 65536)
            guard recv(client, &request, request.count, 0) > 0 else {
                _ = Darwin.close(client)
                return
            }
            lock.withLock { requests += 1 }
            let response = reply.bytes
            response.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let result = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                    guard result > 0 else { break }
                    sent += result
                }
            }
            _ = Darwin.close(client)
        }
    }
}

@Suite("D-PROVIDER-11/13 production Bridge composition consumer", .serialized)
@MainActor
struct ProviderBridgeProductionCompositionTests {
    private struct Harness {
        let profile: RuntimeIsolationProfile
        let bridge: BridgeStore
        let sessions: SessionStore
        let primary: ProviderBridgeWire
        let backup: ProviderBridgeWire?
        let sessionID: UUID
        let primaryReadinessRequests: Int
        let backupReadinessRequests: Int

        @MainActor
        func finish() {
            bridge.chat.stopAllStreamingForSafety()
            try? FileManager.default.removeItem(at: profile.rootDirectory)
        }
    }

    private func makeHarness(
        primaryReplies: [ProviderBridgeWire.Reply],
        backupReplies: [ProviderBridgeWire.Reply]? = nil
    ) async throws -> Harness {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ProviderBridgeProductionComposition",
            processEnvironment: [:],
            processArguments: ["MinisCanvasAppTests.xctest"],
            canvasRuntimeState: .disabled
        )
        let modelID = "bridge-model"
        let readinessReplies = Array(
            repeating: ProviderBridgeWire.Reply.readinessCatalog(modelID), count: 4
        )
        let primary = try ProviderBridgeWire(replies: readinessReplies + primaryReplies)
        let backup = try backupReplies.map {
            try ProviderBridgeWire(replies: readinessReplies + $0)
        }
        let defaults = profile.makeUserDefaults()
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let logger = profile.makeLogManager()
        let settings = ProductionDomainAssembly.makeSettings(
            profile: profile,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: logger,
            store: shortcuts,
            readinessTransport: ControlledLoopbackProviderReadinessTransport(),
            providerReadinessStore: readiness
        )
        let skills = SkillsStore(
            appStore: settings.skillStore,
            stateFileURL: profile.skillStateURL,
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory
                .appendingPathComponent("scheduler-occurrences-v1.json")
        )
        let workflows = WorkflowStore.startForAppBootstrap(
            storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows")
        )
        let bridge = ProductionDomainAssembly.makeBridge(
            profile: profile, bootstrapFailure: nil, settings: settings,
            store: shortcuts, defaults: defaults, skillsStore: skills,
            schedulerStore: scheduler, logManager: logger, workflowStore: workflows,
            sessionBadgeStore: badges, sessionStore: sessions
        )
        #expect(bridge.chat.providerReadinessStore === settings.providerReadinessStore)
        await ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            agentSettings: AgentSettings(fallbackEnabled: backup != nil),
            fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [URL(fileURLWithPath: NSHomeDirectory())],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: settings.mcpManager,
            skillStore: settings.skillStore,
            canvasRuntimeState: .disabled,
            externalNetworkAllowed: backup != nil,
            controlledFieldLoopbackAllowed: backup == nil,
            sessionReadSecretStore: settings.envStore
        ).value
        #expect(bridge.productionExternalNetworkAllowed == (backup != nil))
        #expect(bridge.productionControlledFieldLoopbackAllowed == (backup == nil))
        bridge.chat.newSession(
            projectID: "synthetic-provider-bridge",
            projectName: "Synthetic provider bridge",
            workingDirectory: profile.rootDirectory.path
        )
        let sessionID = try #require(bridge.chat.activeSessionID)
        let primaryID = "BRIDGE_PRIMARY_API_KEY"
        let backupID = "BRIDGE_BACKUP_API_KEY"
        let endpoints = [(primaryID, primary.port, "synthetic-primary-key")]
            + (backup.map { [(backupID, $0.port, "synthetic-backup-key")] } ?? [])
        var probeReceipts: [[String: Any]] = []
        for (name, port, credential) in endpoints {
            #expect(settings.saveProvider(
                name: name, apiKey: credential,
                baseURL: "http://127.0.0.1:\(port)",
                modelNames: [modelID], protocolType: .openaiCompatible
            ))
            let report = try #require(await settings.checkProviderReadiness(
                forProviderName: name
            ))
            #expect(report.state == .live)
            #expect(report.modelChecks.map(\.modelID) == [modelID])
            let stored = try #require(readiness.records.first {
                $0.providerID == ProviderReadinessRevision.canonicalProviderID(name)
                    && $0.modelID == modelID
            })
            let canonical = [
                name, modelID, "200", String(report.checkedAt.timeIntervalSince1970)
            ].joined(separator: "\u{001F}")
            let digest = SHA256.hash(data: Data(canonical.utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(stored.evidenceID == "live-settings:" + digest)
            #expect(stored.applyReceiptID != nil)
            #expect(stored.isApplied)
            #expect(bridge.chat.chatModelPickerReceipt(
                providerID: name, modelID: modelID
            )?.evidenceID == stored.evidenceID)
            probeReceipts.append([
                "providerID": report.providerID,
                "modelID": modelID,
                "checkedAtUnix": report.checkedAt.timeIntervalSince1970,
                "state": String(describing: report.state),
                "configuration": report.configuration.status.rawValue,
                "reachability": report.reachability.status.rawValue,
                "authentication": report.authentication.status.rawValue,
                "modelDiscovery": report.modelDiscovery.status.rawValue,
                "modelCheck": report.modelChecks[0].status.rawValue,
                "reachabilityHTTP": report.reachability.statusCode ?? -1,
                "authenticationHTTP": report.authentication.statusCode ?? -1,
                "modelDiscoveryHTTP": report.modelDiscovery.statusCode ?? -1,
                "evidenceID": stored.evidenceID ?? "",
                "applyReceiptID": stored.applyReceiptID ?? "",
                "pickerEvidenceID": bridge.chat.chatModelPickerReceipt(
                    providerID: name, modelID: modelID
                )?.evidenceID ?? "",
                "sharedReadinessStore": bridge.chat.providerReadinessStore === settings.providerReadinessStore
            ])
        }
        #expect(primary.requestCount == 4)
        #expect(backup == nil || backup?.requestCount == 4)
        let formalPaths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let formalRoot = try #require(formalPaths).rootDirectory
        let probeFile = formalRoot.appendingPathComponent(
            backup == nil ? "provider-bridge-recovery-probe.json"
                : "provider-bridge-fallback-probe.json"
        )
        let probeData = try JSONSerialization.data(withJSONObject: [
            "source": "SettingsCenter.checkProviderReadiness",
            "composition": "ProductionDomainAssembly.makeSettings+makeBridge",
            "primaryReadinessRequests": primary.requestCount,
            "backupReadinessRequests": backup?.requestCount ?? 0,
            "probes": probeReceipts
        ], options: [.prettyPrinted, .sortedKeys])
        try probeData.write(to: probeFile, options: .atomic)
        bridge.chat.providerRecordsSource = { settings.providerRecords }
        bridge.chat.schedulerCredentialVersionSource = { name in
            guard let record = settings.providerRecords.first(where: { $0.name == name })
            else { return nil }
            return settings.providerCredentialBinding(recordID: record.id)?.revision
        }
        #expect(bridge.chat.applyChatModel(providerID: primaryID, modelID: modelID))
        #expect(bridge.chat.streamingProviderOverride == nil)
        #expect(bridge.chat.turnRuntimeSnapshotFactory != nil)
        #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
        if backup != nil {
            #expect(bridge.chat.providerRuntimeFallbackCandidates(
                excludingProviderID: primaryID).map(\.providerID) == [backupID])
        }
        return Harness(profile: profile, bridge: bridge, sessions: sessions,
            primary: primary, backup: backup, sessionID: sessionID,
            primaryReadinessRequests: primary.requestCount,
            backupReadinessRequests: backup?.requestCount ?? 0)
    }

    private func sendAndSettle(_ harness: Harness, text: String, timeoutPolls: Int = 1_000) async throws ->
        (newMessages: [ChatMessageUI], identity: AgentExecutionIdentity) {
        let chat = harness.bridge.chat
        let priorIDs = Set(chat.messages.map(\.id))
        chat.draftText = text
        chat.submitComposer()
        let identity = try #require(chat.activeExecutionIdentity(for: harness.sessionID))
        var terminal = false
        for _ in 0..<timeoutPolls {
            terminal = !chat.isStreaming
                && chat.terminalReceipt(for: identity) != nil
                && chat.messages.contains {
                    $0.role == .assistant && !priorIDs.contains($0.id)
                }
            if terminal { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminal, "production Bridge turn must reach a terminal state")
        for _ in 0..<100 where harness.bridge.providerRuntimeObservations.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (chat.messages.filter { !priorIDs.contains($0.id) }, identity)
    }

    @Test("production Bridge 429 failure then next request recovers without duplicate transcript")
    func typedFailureThenRecovery() async throws {
        // 主对话重试策略（V-7）：首次 + 最多 8 次重试，共 9 次 429 后这一轮才以失败结束。
        let harness = try await makeHarness(primaryReplies: Array(repeating: .failure(429), count: 9)
            + [.completion("recovered-once")])
        defer { harness.finish() }
        // Nine attempts with the main-conversation backoff (0.5 s doubling to 32 s, about 95 s in all).
        let first = try await sendAndSettle(harness, text: "first synthetic request", timeoutPolls: 15_000)
        #expect(first.newMessages.map(\.role) == [.user, .assistant])
        let failure = try #require(first.newMessages.last?.content)
        #expect(failure.contains("429"))
        #expect(!failure.contains("remote-body-must-not-be-shown"))
        #expect(harness.bridge.chat.terminalReceipt(for: first.identity)?.outcome == .failed)
        let firstObservation = try #require(harness.bridge.providerRuntimeObservations.last)
        #expect(firstObservation.attempts.first?.failureKind == .rateLimited)
        #expect(firstObservation.attempts.first?.statusCode == 429)
        #expect(harness.primary.requestCount - harness.primaryReadinessRequests == 9)

        let second = try await sendAndSettle(harness, text: "second synthetic request")
        #expect(second.newMessages.map(\.role) == [.user, .assistant])
        #expect(second.newMessages.last?.content.contains("recovered-once") == true)
        #expect(harness.bridge.chat.terminalReceipt(for: second.identity)?.outcome == .succeeded)
        #expect(harness.primary.requestCount - harness.primaryReadinessRequests == 10)
        let persisted = try #require(harness.sessions.loadSession(id: harness.sessionID.uuidString))
        #expect(persisted.messages.count == 4)
        #expect(persisted.messages.suffix(4).map { $0.role.rawValue }
            == ["user", "assistant", "user", "assistant"])
        #expect(persisted.messages.last?.content == second.newMessages.last?.content)
        #expect(harness.bridge.providerRuntimeObservationPersistenceError == nil)
    }

    @Test("production Bridge 404 fallback uses real route and inserts one completion")
    func productionFallbackInsertsOnce() async throws {
        let harness = try await makeHarness(
            primaryReplies: [.failure(404)],
            backupReplies: [.completion("backup-completed-once")]
        )
        defer { harness.finish() }
        let result = try await sendAndSettle(harness, text: "synthetic fallback request")
        #expect(result.newMessages.map(\.role) == [.user, .assistant])
        let assistant = try #require(result.newMessages.last)
        #expect(assistant.content.components(separatedBy: "backup-completed-once").count - 1 == 1)
        #expect(assistant.content.components(
            separatedBy: ChatStore.fallbackRouteProjectionPrefix).count - 1 == 1)
        #expect(assistant.content.contains("HTTP 404"))
        #expect(!assistant.content.contains("remote-body-must-not-be-shown"))
        #expect(ChatTranscriptAXContract.fallbackRouteStatus(
            in: harness.bridge.chat.messages) == "回退路由状态已显示")
        #expect(harness.bridge.chat.terminalReceipt(for: result.identity)?.outcome == .succeeded)
        #expect(harness.primary.requestCount - harness.primaryReadinessRequests == 1)
        #expect((harness.backup?.requestCount ?? 0) - harness.backupReadinessRequests == 1)
        let observation = try #require(harness.bridge.providerRuntimeObservations.last)
        #expect(observation.servedProviderID == "BRIDGE_BACKUP_API_KEY")
        #expect(observation.attempts.first?.failureKind == .notFound)
        #expect(harness.bridge.chat.ingestProviderRuntimeObservation(
            observation, executionIdentity: result.identity) == false)
        #expect(harness.bridge.chat.markExecutionSucceeded(
            sessionID: harness.sessionID, executionIdentity: result.identity) == false)
        let persisted = try #require(harness.sessions.loadSession(id: harness.sessionID.uuidString))
        #expect(persisted.messages.suffix(2).map { $0.role.rawValue } == ["user", "assistant"])
        #expect(persisted.messages.last?.content == assistant.content)
        #expect(harness.bridge.providerRuntimeObservationPersistenceError == nil)
    }
}
