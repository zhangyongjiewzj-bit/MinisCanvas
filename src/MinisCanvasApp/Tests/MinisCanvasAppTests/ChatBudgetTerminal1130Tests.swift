import AppKit
import ApplicationServices
import Darwin
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

private final class BudgetWire1130: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var failure: String?
    private var stopped = false
    let port: UInt16
    var requests: [Data] { lock.withLock { bodies } }
    var captureFailure: String? { lock.withLock { failure } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = Darwin.close(fd); throw URLError(.badURL)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
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
        let shouldClose = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldClose { _ = Darwin.shutdown(descriptor, SHUT_RDWR); _ = Darwin.close(descriptor) }
    }

    private func serve() {
        for _ in 0..<4 {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { _ = Darwin.close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let delimiter = Data("\r\n\r\n".utf8)
        while received.count < 2_000_000 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { lock.withLock { failure = "incomplete HTTP entity" }; return }
            received.append(contentsOf: buffer.prefix(count))
            guard let boundary = received.range(of: delimiter) else { continue }
            // Parse only Content-Length; discard the entire header afterwards.
            let headers = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
            let entityLength = headers.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }.first
            guard let entityLength, entityLength > 0 else {
                lock.withLock { failure = "missing bounded Content-Length" }; return
            }
            let offset = boundary.upperBound
            guard received.count >= offset + entityLength else { continue }
            lock.withLock { bodies.append(received.subdata(in: offset..<(offset + entityLength))) }
            let entity = received.subdata(in: offset..<(offset + entityLength))
            let request = (try? JSONSerialization.jsonObject(with: entity)) as? [String: Any]
            let user = (request?["messages"] as? [[String: Any]])?.last(where: { $0["role"] as? String == "user" })?["content"] as? String
            let over = user?.contains("OVER1130") == true
            let providerReject = user?.contains("ERROR1130") == true
            let reply = over ? "OWNED_OVER_REPLY1130" : "OWNED_LEGAL_REPLY1130"
            let tokens = over ? 110_000 : 1_000
            let escaped = try? JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
                "delta": ["content": reply], "finish_reason": "stop"]], "usage": ["prompt_tokens": tokens - 1, "completion_tokens": 1, "total_tokens": tokens]])
            guard let escaped else { return }
            let body = "data: " + String(decoding: escaped, as: UTF8.self) + "\n\ndata: [DONE]\n\n"
            let rejectedBody = "{\"error\":{\"message\":\"owned provider refused input\",\"type\":\"invalid_request_error\"}}"
            let status = providerReject ? "400 Bad Request" : "200 OK"
            let entityBody = providerReject ? rejectedBody : body
            let contentType = providerReject ? "application/json" : "text/event-stream"
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(entityBody.utf8.count)\r\nConnection: close\r\n\r\n\(entityBody)".utf8)
            response.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, address.advanced(by: sent), bytes.count - sent, 0)
                    if count <= 0 { break }
                    sent += count
                }
            }
            break
        }
        }
        lock.withLock { if bodies.count != 4 && !stopped { failure = "HTTP entity did not settle all legal requests" } }
    }
}


@Suite("CHAT16 typed budget pause retains actual refused turn", .serialized)
@MainActor
struct ChatBudgetTerminal1130Tests {
    private func settle(_ chat: ChatStore) async throws {
        for _ in 0..<500 {
            if !chat.hasStreamingTasksForSafety { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Owned actual stream did not settle within the original bounded deadline")
    }
    @Test("actual SDK usage settles current refusal, blocks next request, then reset permits a new identity")
    func usagePausePreservesTruthAndNamesTheBudgetBoundary() async throws {
        try await verifyBudgetPause()
    }

    fileprivate func verifyBudgetPause(checkInspector: Bool = false) async throws {
        try #require(KeychainStore.isTesting)
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolved)
        let root = paths.rootDirectory.appendingPathComponent("budget1130-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let wire = try BudgetWire1130()
        defer { wire.stop() }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let canonical = try sessions.createSession(id: UUID().uuidString, title: "Owned budget1130")
        let defaults = try #require(UserDefaults(suiteName: "budget1130-\(UUID().uuidString)"))
        let logger = LogManager(directory: root.appendingPathComponent("logs"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let inspectorBridge: BridgeStore? = checkInspector ? BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: logger,
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, canvasRuntimeState: .disabled, canvasFeatureLane: .phase3NonCanvas
        ) : nil
        let chat = inspectorBridge?.chat ?? ChatStore(preferencesDefaults: defaults, logManager: logger)
        #expect(chat.attachPersistence(sessions, badgeStore: badges))
        let sessionID = try #require(chat.activeSessionID)
        #expect(sessionID.uuidString == canonical.id)
        var settings = AgentSettings.default
        settings.autoCompactThreshold = 0
        // 本用例测超限/恢复，不是默认值：显式钉 10 万（默认值已改为 100 万）。
        settings.maxTokensPerSession = 100_000
        chat.configureBudget(from: settings)
        #expect(chat.budgetCapTokens == 100_000)
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID,
            revision: "owned1130-revision", grantEpoch: "owned1130-epoch", leaseID: "owned1130-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let injector = SkillInjector(store: SkillStore(skillsRoot: root.appendingPathComponent("skills")))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider,
                modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned1130")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        let lifecycleURL = root.appendingPathComponent("actual-turn-context.json")
        let engine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: root),
            requestBudget: chat.budgetTracker, contextWritebackStorePersistenceURL: lifecycleURL,
            composerPolicyFacts: facts)
        chat.agentEngine = engine
        var config = ProviderConfig(label: "owned-budget1130", providerType: .openAI,
            runtimeProviderID: "owned-budget1130", customBaseURL: "http://127.0.0.1:\(wire.port)/v1",
            apiKey: "owned-synthetic-nonsecret")
        config.controlledFieldLoopbackOnly = true
        var provider = try ProviderFactory().makeProvider(for: config)
        provider.model = LLMModel(id: "gpt-4o-mini", displayName: "Owned usage", provider: "owned-budget1130")
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety() }
        chat.draftText = "LOW1130 ordinary request"
        chat.sendDraft()
        try await settle(chat)
        #expect(wire.requests.count == 1)
        #expect(chat.budgetRequestCount == 1)
        #expect(chat.budgetUsedTokens == 1_000)
        #expect(chat.executionSnapshot(forSessionID: sessionID)?.state == .idle)
        #expect(chat.messages.last?.content == "OWNED_LEGAL_REPLY1130")
        chat.draftText = "OVER1130 ordinary request"
        chat.sendDraft()
        try await settle(chat)
        let refused = try #require(chat.executionSnapshot(forSessionID: sessionID))
        let refusedID = try #require(refused.executionIdentity)
        let record = try #require(engine.contextWritebackGate.lifecycleStore?.record(for: refusedID))
        #expect(wire.requests.count == 2)
        #expect(wire.captureFailure == nil)
        #expect(chat.budgetRequestCount == 2)
        #expect(chat.budgetUsedTokens == 111_000)
        #expect(chat.budgetIsOverLimit)
        #expect(refused.state == .failed)
        #expect(record.identity == refusedID)
        #expect(record.status == .policyRefused)
        #expect(record.terminalTruth?.outcome == .policyRefused)
        #expect(record.terminalTruth?.reason == AgentLoopError.budgetExhausted.errorDescription)
        #expect(chat.messages.last?.content.contains("OWNED_OVER_REPLY1130") == true)
        #expect(chat.messages.last?.isStreaming == false)
        #expect(refused.failureKind == .budgetPause)
        let indicator = ChatStore.ConversationListIndicator.derive(execution: refused, unread: false)
        #expect(indicator.accessibilityLabel == "预算已暂停")
        #expect(!indicator.helpText.contains("生成失败"))
        #expect(indicator.helpText.contains("重置或提高预算"))
        let thread = try #require(chat.sessions.first(where: { $0.id == sessionID }))
        let item = ChatStore.SessionListItem(session: thread, execution: refused)
        let projection = ChatStore.projectSessionBadge(for: item, source: indicator, store: badges)
        #expect(projection.presentation.status == .failed)
        #expect(projection.presentation.identity.sessionID == sessionID.uuidString)
        #expect(projection.accessibilityLabel == "预算已暂停")
        #expect(projection.helpText == indicator.helpText)
        #expect(projection.systemImageName == "pause.circle")
        #expect(projection.isRetryable)
        let encodedRefused = try JSONEncoder().encode(refused)
        let legacyDecoded = try JSONSerialization.jsonObject(with: encodedRefused)
        var legacyObject = try #require(legacyDecoded as? [String: Any])
        legacyObject.removeValue(forKey: "failureKind")
        let legacy = try JSONDecoder().decode(ChatStore.ExecutionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        #expect(legacy.state == .failed)
        #expect(legacy.failureKind == nil)
        #expect(legacy.executionIdentity == refusedID)
        #expect(ChatStore.ConversationListIndicator.derive(execution: legacy, unread: false).accessibilityLabel == "会话失败")
        let legacyProjection = ChatStore.projectSessionBadge(
            for: .init(session: thread, execution: legacy),
            source: .budgetPaused(reason: legacy.failureReason), store: badges)
        #expect(legacyProjection.budgetPauseReason == nil)
        #expect(legacyProjection.accessibilityLabel == "会话失败")
        let wrongSession = ChatStore.ExecutionSnapshot(sessionID: UUID(), turnID: refused.turnID,
            taskID: refused.taskID, state: .failed, failureReason: refused.failureReason,
            failureKind: .budgetPause, executionIdentity: refusedID)
        #expect(ChatStore.ConversationListIndicator.derive(execution: wrongSession, unread: false).accessibilityLabel == "会话失败")
        let disk = SessionStore(directory: sessions.directory)
        let persisted = try #require(disk.loadSession(id: canonical.id))
        #expect(persisted.messages.last?.content.contains("OWNED_OVER_REPLY1130") == true)
        let reopened = ChatStore(preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("reopen-logs")))
        #expect(reopened.attachPersistence(disk, badgeStore: badges))
        #expect(reopened.executionSnapshot(forSessionID: sessionID) == refused)
        let reopenedContext = try AgentTurnContextStore(persistenceURL: lifecycleURL)
        #expect(reopenedContext.record(for: refusedID) == record)
        chat.draftText = "BLOCKED1130 must never enter Provider"
        chat.sendDraft()
        try await settle(chat)
        let blocked = try #require(chat.executionSnapshot(forSessionID: sessionID))
        let blockedID = try #require(blocked.executionIdentity)
        #expect(blockedID != refusedID)
        #expect(blocked.state == .failed)
        #expect(wire.requests.count == 2)
        #expect(chat.budgetRequestCount == 2)
        #expect(chat.budgetUsedTokens == 111_000)
        #expect(engine.contextWritebackGate.lifecycleStore?.record(for: blockedID)?.status == .policyRefused)
        #expect(engine.contextWritebackGate.lifecycleStore?.record(for: refusedID) == record)
        #expect(await chat.budgetTracker.pendingRequestCount == 0)

        if checkInspector {
            let bridge = try #require(inspectorBridge)
            try #require(chat.activeSessionID == sessionID)
            try #require(chat.budgetIsOverLimit)
            let retainedTracker = chat.budgetTracker
            let cap = chat.budgetCapTokens
            try #require(NSApplication.shared.isRunning, "requires the existing native App test host")
            let lease = NativeTestHostLifecycle.begin("DIAG03BudgetReset")
            let controller = NSHostingController(rootView: ContentView(bridge: bridge))
            controller.sizingOptions = []
            let contentSize = NSSize(width: 1_180, height: 700)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            NativeTestHostLifecycle.bind(lease, to: window)
            window.isReleasedWhenClosed = false
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
                NativeTestHostLifecycle.end(window)
            }
            window.contentViewController = controller
            window.setContentSize(contentSize)
            controller.view.frame = NSRect(origin: .zero, size: contentSize)
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            window.makeKeyAndOrderFront(nil)
            controller.view.display()
            pumpAXRunLoop()
            NativeTestHostLifecycle.observe(window, phase: "sampled")
            try #require(NSApplication.shared.isActive && window.isKeyWindow && window.isVisible,
                "requires the already active native host and its visible key window")
            // SwiftUI repeats the section identifier across its descendants.
            // This exact visible status belongs only to the exhausted overview.
            let overviewStatus = try #require(NativeConsumerOwnedAX.findDisplayedText(
                in: window, exactText: "预算已超限"))
            try #require(NativeConsumerOwnedAX.role(overviewStatus) == .staticText)
            let resetByIdentifier = NativeConsumerOwnedAX.find(in: window, identifier: "chat-inspector.budget-reset")
            _ = resetByIdentifier
            // 输入区上限提示条的按钮叫"重置预算"，与检查器的"重置本会话预算"不同名，按标签唯一定位。
            let reset = try #require(NativeConsumerOwnedAX.find(
                in: window, label: "重置本会话预算", pressable: true))
            try #require(NativeConsumerOwnedAX.role(reset) == .button
                && NativeConsumerOwnedAX.label(reset) == "重置本会话预算")
            let projectedResetID = NativeConsumerOwnedAX.attribute(reset, kAXIdentifierAttribute as CFString) as? String
            print("DIAG03_RESET_AX identifierPresent=\(projectedResetID?.isEmpty == false)"
                + " identifierMatches=\(projectedResetID == "chat-inspector.budget-reset")")
            if let resetByIdentifier {
                let idElement = try #require(NativeConsumerOwnedAX.element(resetByIdentifier))
                let labelElement = try #require(NativeConsumerOwnedAX.element(reset))
                try #require(CFEqual(idElement, labelElement))
            }
            #expect(axRole(reset) == .button && axLabel(reset) == "重置本会话预算")
            try #require(NativeConsumerOwnedAX.enabled(reset) == true)
            try #require(NativeConsumerOwnedAX.press(reset))
            pumpAXRunLoop()
            let confirm = try #require(NativeConsumerOwnedAX.find(in: window,
                identifier: "chat-inspector.budget-reset.confirm"))
            try #require(NativeConsumerOwnedAX.role(confirm) == .button
                && NativeConsumerOwnedAX.label(confirm) == "确认重置预算")
            #expect(chat.budgetIsOverLimit && chat.budgetUsedTokens == 111_000)
            #expect(wire.requests.count == 2)
            try #require(NativeConsumerOwnedAX.press(confirm))
            for _ in 0..<500 {
                if !chat.isActiveSessionBudgetResetting && !chat.budgetIsOverLimit && chat.budgetRequestCount == 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!chat.isActiveSessionBudgetResetting && !chat.budgetIsOverLimit)
            #expect(chat.activeSessionID == sessionID && chat.budgetTracker === retainedTracker)
            #expect(chat.budgetCapTokens == cap && chat.budgetUsedTokens == 0 && chat.budgetRequestCount == 0)
            #expect(wire.requests.count == 2)
        } else {
            chat.configureBudget(from: settings)
        }

        chat.draftText = "RECOVERED1130 new ordinary request"
        chat.sendDraft()
        try await settle(chat)
        let recovered = try #require(chat.executionSnapshot(forSessionID: sessionID))
        let recoveredID = try #require(recovered.executionIdentity)
        #expect(recoveredID != blockedID && recoveredID != refusedID)
        #expect(recovered.state == .idle)
        #expect(wire.requests.count == 3)
        #expect(chat.budgetRequestCount == 1)
        #expect(chat.budgetUsedTokens == 1_000)
        #expect(!chat.budgetIsOverLimit)
        #expect(engine.contextWritebackGate.lifecycleStore?.record(for: refusedID) == record)
        #expect(chat.messages.last?.content == "OWNED_LEGAL_REPLY1130")
        #expect(wire.captureFailure == nil)
        #expect(wire.requests.allSatisfy { String(decoding: $0, as: UTF8.self).contains("gpt-4o-mini") })
        let lastUsers = try wire.requests.map { data -> String in
            let decoded = try JSONSerialization.jsonObject(with: data)
            let request = try #require(decoded as? [String: Any])
            let messages = try #require(request["messages"] as? [[String: Any]])
            let user = try #require(messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String)
            return user
        }
        #expect(lastUsers.count == 3)
        #expect(lastUsers[0].contains("LOW1130"))
        #expect(lastUsers[1].contains("OVER1130"))
        #expect(lastUsers[2].contains("RECOVERED1130"))
        #expect(lastUsers.allSatisfy { !$0.contains("BLOCKED1130") })
        chat.draftText = "ERROR1130 ordinary provider rejection"
        chat.sendDraft()
        try await settle(chat)
        let rejectedProvider = try #require(chat.executionSnapshot(forSessionID: sessionID))
        let rejectedID = try #require(rejectedProvider.executionIdentity)
        #expect(rejectedID != recoveredID)
        #expect(rejectedProvider.state == .failed)
        #expect(rejectedProvider.failureKind == nil)
        #expect(wire.requests.count == 4)
        #expect(chat.budgetRequestCount == 1)
        #expect(chat.budgetUsedTokens == 1_000)
        let providerIndicator = ChatStore.ConversationListIndicator.derive(execution: rejectedProvider, unread: false)
        #expect(providerIndicator.accessibilityLabel == "会话失败")
        #expect(providerIndicator.helpText.contains("生成失败"))
        let failedThread = try #require(chat.sessions.first(where: { $0.id == sessionID }))
        let failedProjection = ChatStore.projectSessionBadge(
            for: .init(session: failedThread, execution: rejectedProvider),
            source: providerIndicator, store: badges)
        #expect(failedProjection.budgetPauseReason == nil)
        #expect(failedProjection.accessibilityLabel == "会话失败")
        #expect(failedProjection.presentation.status == .failed)
        #expect(engine.contextWritebackGate.lifecycleStore?.record(for: refusedID) == record)
        #expect(wire.captureFailure == nil)
        #expect(await chat.budgetTracker.pendingRequestCount == 0)
    }
}


extension ChatBudgetAndRole541NativeConsumerTests {
    @Test func exhaustedSessionExposesPublicBudgetResetInInspector() async throws {
        try await ChatBudgetTerminal1130Tests().verifyBudgetPause(checkInspector: true)
    }
}
