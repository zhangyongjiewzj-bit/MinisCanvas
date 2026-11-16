import Darwin
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Owned loopback only. Retains the JSON entity, never Authorization headers.
final class ComposerWire3090: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var failure: String?
    private var stopped = false
    let port: UInt16
    var requests: [Data] { lock.withLock { bodies } }
    var captureFailure: String? { lock.withLock { failure } }

    typealias ResponseScript = @Sendable (String, String, Data) throws -> (contentType: String, body: Data)

    init(reply: String, maxRequests: Int = 1, responseScript: ResponseScript? = nil) throws {
        precondition((1...8).contains(maxRequests))
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for _ in 0..<maxRequests {
                if self.lock.withLock({ self.stopped }) { return }
                self.serve(reply: reply, responseScript: responseScript)
            }
        }
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

    private func serve(reply: String, responseScript: ResponseScript?) {
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
            let requestLine = headers.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            let method = requestLine.first.map(String.init) ?? ""
            let path = requestLine.count > 1 ? String(requestLine[1]) : ""
            let boundedLength = entityLength ?? (responseScript != nil && method == "GET" ? 0 : nil)
            guard let entityLength = boundedLength,
                  entityLength > 0 || (responseScript != nil && method == "GET" && entityLength == 0) else {
                lock.withLock { failure = "missing bounded Content-Length" }; return
            }
            let offset = boundary.upperBound
            guard received.count >= offset + entityLength else { continue }
            let entity = received.subdata(in: offset..<(offset + entityLength))
            lock.withLock { bodies.append(entity) }
            let body: Data
            let contentType: String
            if let responseScript {
                do {
                    let scripted = try responseScript(method, path, entity)
                    body = scripted.body
                    contentType = scripted.contentType
                } catch {
                    lock.withLock { failure = "owned response script rejected request" }
                    return
                }
            } else {
                let escaped = try? JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
                    "delta": ["content": reply], "finish_reason": "stop"]]])
                guard let escaped else { return }
                body = Data(("data: " + String(decoding: escaped, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
                contentType = "text/event-stream"
            }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            response.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, address.advanced(by: sent), bytes.count - sent, 0)
                    if count <= 0 { break }
                    sent += count
                }
            }
            return
        }
        lock.withLock { failure = "HTTP entity exceeded owned fixture bound" }
    }
}

private actor ComposerPause3090 {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func pending() -> Bool { !waiting.isEmpty }
    func release() {
        released = true
        let continuations = waiting; waiting.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class ComposerSummary3090: LLMProvider, @unchecked Sendable {
    let name = "owned-summary3090"
    var model = LLMModel(id: "summary3090", displayName: "Owned summary", provider: "owned-summary3090")
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    let pause = ComposerPause3090()
    private let refusesSummary: Bool
    init(refusesSummary: Bool) { self.refusesSummary = refusesSummary }

    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        if refusesSummary {
            #expect(maxTokens == 4_096 && temperature == 0.2)
            return LLMResponse(text: "", stopReason: "stop", usage: nil)
        }
        await pause.wait()
        return LLMResponse(text: "The assistant compared distinct options and recorded their costs, dependencies and fallback tradeoffs.", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw LLMError.unsupportedCapability(.streaming)
    }
}

@Suite("D-COMPOSER-12 selected Provider actual wire snapshot", .serialized)
@MainActor
struct ComposerSelectedProviderSnapshot3090Tests {
    @Test("real selected Provider HTTP request retains A body PNG and model after immediate B send")
    func immediateSwitchReachesActualProviderRequest() async throws {
        let fixture = try Fixture()
        await fixture.attach()
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); fixture.stopWire(); withExtendedLifetime(fixture.settings) {} }
        let (sent, frozen, image) = try fixture.submitA()
        // No suspension between the accepted send and the switch.
        let bID = try fixture.sendB()
        #expect(await fixture.waitForEnd())
        try fixture.captureTerminalDiagnostics(frozen: frozen, image: image, bID: bID)
        try fixture.assertRequest(fixture.wireA, model: "gpt-4o", text: "ORIGIN_A_BODY_3090", png: fixture.png)
        try fixture.assertRequest(fixture.wireB, model: "gpt-4o-mini", text: "ONLY_B_BODY_3090", png: nil)
        try fixture.assertOrigin(sent: sent, frozen: frozen, image: image, bID: bID, success: true)
        #expect(fixture.summary.requests.isEmpty)
    }

    @Test("actual selected Provider preserves recent PNG through held compaction and rejects a changed credential revision", arguments: [false, true])
    func heldCompactionReachesOriginalProviderOrRejectsRevision(rebind: Bool) async throws {
        let fixture = try Fixture()
        await fixture.attach()
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); fixture.stopWire(); withExtendedLifetime(fixture.settings) {} }
        // The default cumulative cap is 1,000,000 since C1; the 0.8 budget fraction below
        // is built on an explicit 100_000 cap. The trigger is the window occupancy.
        var cappedAgent = fixture.settings.settings.agent
        cappedAgent.maxTokensPerSession = 100_000
        chat.configureBudget(from: cappedAgent)
        await chat.budgetTracker.record(requestTokens: 80_000)
        chat.requestBudget = await chat.budgetTracker.budget
        #expect(chat.requestBudget.usageFraction == 0.8)
        try fixture.recordOccupancyForA()
        let (sent, frozen, image) = try fixture.submitA()
        let entered = await waitUntil { fixture.summary.requests.count == 1 }
        #expect(entered, "actual original worker must enter compaction before the switch")
        guard entered else { await fixture.summary.pause.release(); return }
        #expect(fixture.wireA.requests.isEmpty)
        let bID = try fixture.sendB()
        if rebind { fixture.revisionA = "owned-revision-after-rebind" }
        await fixture.summary.pause.release()
        #expect(await fixture.waitForEnd())
        try fixture.captureTerminalDiagnostics(frozen: frozen, image: image, bID: bID)
        #expect(fixture.summary.requests.count == 1)
        #expect(fixture.summary.requests[0].allSatisfy { !$0.content.contains("ONLY_B_BODY_3090") })
        try fixture.assertRequest(fixture.wireB, model: "gpt-4o-mini", text: "ONLY_B_BODY_3090", png: nil)
        try fixture.assertOrigin(sent: sent, frozen: frozen, image: image, bID: bID, success: !rebind)
        let checkpoint = try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString)
        if rebind {
            #expect(fixture.wireA.requests.isEmpty)
            #expect(checkpoint == nil)
            let a = try #require(chat.sessions.first { $0.id == fixture.sessionID })
            #expect(a.messages.contains { $0.content.contains("自动压缩未完成") || $0.content.contains("已取消") || $0.content.contains("错误") })
        } else {
            try fixture.assertRequest(fixture.wireA, model: "gpt-4o", text: "ORIGIN_A_BODY_3090", png: fixture.png)
            #expect(checkpoint != nil)
        }
    }

    @Test("an earlier owned image refuses unsafe compaction below the hard block: A is still sent, whole and unchanged, and independent B completes")
    func unsafeEarlierAttachmentRefusesWithoutProviderRequest() async throws {
        let fixture = try Fixture(earlierImage: true)
        await fixture.attach()
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); fixture.stopWire(); withExtendedLifetime(fixture.settings) {} }
        try fixture.recordOccupancyForA()
        let (sent, frozen, image) = try fixture.submitA()
        let aFailureComment = { () -> String in
            let first = fixture.typedFailures3184.first {
                ($0["turnSessionID"] as? String) == frozen.sessionID
                    && ($0["turnID"] as? Int) == frozen.turnID
                    && ($0["attempt"] as? Int) == fixture.execution?.attempt
            }
            let text = first.map { "stage=\($0["stage"] as? String ?? "UNOBSERVED") type=\($0["errorType"] as? String ?? "UNOBSERVED") case=\($0["errorCaseName"] as? String ?? "UNOBSERVED")" } ?? "A_FAILURE_UNOBSERVED"
            let marker = " [TRUNCATED]"
            return text.count > 320 ? String(text.prefix(320 - marker.count)) + marker : text
        }
        let bID = try fixture.sendB()
        #expect(await fixture.waitForEnd())
        try fixture.captureTerminalDiagnostics(frozen: frozen, image: image, bID: bID)
        // An empty model summary exercises the refusal below 95%; the
        // request copy still replaces the earlier image with a placeholder.
        try fixture.assertRefusedSummaryRequest()
        try fixture.assertRequest(fixture.wireA, model: "gpt-4o", text: "ORIGIN_A_BODY_3090", png: fixture.png)
        try fixture.assertEarlierImagePlaceheld(fixture.wireA)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)
        try fixture.assertRequest(fixture.wireB, model: "gpt-4o-mini", text: "ONLY_B_BODY_3090", png: nil)
        try fixture.assertOrigin(sent: sent, frozen: frozen, image: image, bID: bID, success: true)
        let a = try #require(chat.sessions.first { $0.id == fixture.sessionID })
        #expect(!a.messages.contains { $0.content.contains("自动压缩未完成") || $0.content.contains("上下文含无法完整保留") }, Comment(rawValue: aFailureComment()))
        // 1101:10: the refused compaction is explained by one quiet line.
        #expect(a.messages.filter { $0.role == .system
            && $0.content == ChatStore.compactionNotExecutedNoticeText }.count == 1)
        #expect(a.messages.contains { $0.attachments.contains { $0.data == fixture.png } })
    }

    @Test("old image refusal below the hard block still sends, and independent B keeps its contract, in both real worker release orders", arguments: [true, false])
    func unsafeEarlierAttachmentWithHeldCanonicalSource3220(aFirst: Bool) async throws {
        let fixture = try Fixture(earlierImage: true)
        await fixture.attach()
        let chat = fixture.bridge.chat
        let aPause = ComposerPause3090(), bPause = ComposerPause3090()
        defer {
            chat.automaticCompactionHighBudgetPauseForTests = nil
            chat.automaticCompactionSourcePauseForTests = nil
            chat.stopAllStreamingForSafety(); fixture.stopWire()
            withExtendedLifetime(fixture.settings) {}
        }
        // These are the production workers' existing before-read seams. The
        // engine, authority checks and canonical reads remain unchanged.
        chat.automaticCompactionHighBudgetPauseForTests = { await aPause.wait() }
        chat.automaticCompactionSourcePauseForTests = { await bPause.wait() }
        do {
            try fixture.recordOccupancyForA()
            let (sent, frozen, image) = try fixture.submitA()
            let aFailureComment = { () -> String in
                let first = fixture.typedFailures3184.first {
                    ($0["turnSessionID"] as? String) == frozen.sessionID
                        && ($0["turnID"] as? Int) == frozen.turnID
                        && ($0["attempt"] as? Int) == fixture.execution?.attempt
                }
                let text = first.map { "stage=\($0["stage"] as? String ?? "UNOBSERVED") type=\($0["errorType"] as? String ?? "UNOBSERVED") case=\($0["errorCaseName"] as? String ?? "UNOBSERVED")" } ?? "A_FAILURE_UNOBSERVED"
                let marker = " [TRUNCATED]"
                return text.count > 254 ? String(text.prefix(254 - marker.count)) + marker : text
            }
            let bID = try fixture.sendB() // still no suspension after submitA
            let aHeld = await waitForWorker3220(aPause)
            let bHeld = await waitForWorker3220(bPause)
            #expect(aHeld && bHeld, "both original workers must reach their actual read seam")
            guard aHeld && bHeld else {
                await aPause.release(); await bPause.release()
                return
            }
            let frozenBHistory = try #require(chat.messages(forSession: bID))
            #expect(frozenBHistory.last?.isStreaming == true)
            try fixture.captureCanonicalPhase3220("both-held", bID: bID,
                frozenBHistory: frozenBHistory, aFirst: aFirst)
            if aFirst {
                // C3 (11/9 contract change): A's refusal no longer ends A. After it A goes on
                // to the engine, whose canonical source read is the same seam B holds, so A can
                // no longer finish "before B resumes". Old: wait for A's refusal card, then
                // release B. New: release A's compaction worker, record the phase, release the
                // shared source seam; both workers then complete (asserted below).
                await aPause.release()
                try fixture.captureCanonicalPhase3220("A-released-B-held", bID: bID,
                    frozenBHistory: frozenBHistory, aFirst: aFirst)
                await bPause.release()
            } else {
                await bPause.release()
                let bCompleted = await waitUntil {
                    chat.messages(forSession: bID)?.contains {
                        $0.role == .assistant && !$0.isStreaming
                            && $0.content.contains("ACTUAL_B_REPLY_3090")
                    } == true
                }
                #expect(bCompleted, "B must actually complete its own wire request before A resumes")
                try fixture.captureCanonicalPhase3220("B-completed-A-held", bID: bID,
                    frozenBHistory: frozenBHistory, aFirst: aFirst)
                await aPause.release()
            }
            #expect(await fixture.waitForEnd())
            try fixture.captureCanonicalPhase3220("both-terminal", bID: bID,
                frozenBHistory: frozenBHistory, aFirst: aFirst)
            try fixture.captureTerminalDiagnostics(frozen: frozen, image: image, bID: bID)
            try fixture.assertRefusedSummaryRequest()
            try fixture.assertRequest(fixture.wireA, model: "gpt-4o", text: "ORIGIN_A_BODY_3090", png: fixture.png)
            try fixture.assertEarlierImagePlaceheld(fixture.wireA)
            #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
                sessionID: fixture.sessionID.uuidString) == nil)
            try fixture.assertRequest(fixture.wireB, model: "gpt-4o-mini", text: "ONLY_B_BODY_3090", png: nil)
            try fixture.assertOrigin(sent: sent, frozen: frozen, image: image, bID: bID, success: true)
            let a = try #require(chat.sessions.first { $0.id == fixture.sessionID })
            #expect(!a.messages.contains { $0.content.contains("上下文含无法完整保留") }, Comment(rawValue: aFailureComment()))
            #expect(a.messages.filter { $0.role == .system
                && $0.content == ChatStore.compactionNotExecutedNoticeText }.count == 1)
            let retained = try #require(a.messages.first { $0.id == sent.id }?.attachments.first { $0.id == image.id })
            // Old: quarantined (the refused send never delivered the media). Now delivered.
            #expect(retained.data == fixture.png && retained.deliveryQuarantined == nil)
        } catch {
            // Failed diagnostics/oracles must also release both original workers.
            await aPause.release(); await bPause.release()
            throw error
        }
    }

    @Test("a real captured canonical source rejects a subsequent external edit and a new identity recovers")
    func capturedCanonicalExternalEditRejectsThenNewIdentityRecovers3244() async throws {
        let fixture = try Fixture()
        await fixture.attach()
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); fixture.stopWire(); withExtendedLifetime(fixture.settings) {} }
        let user = ChatMessageUI(role: .user, content: "CAPTURED_CANONICAL_BODY_3244")
        let assistant = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        #expect(chat.setMessages([user, assistant], forSession: fixture.sessionID))
        let local = try #require(chat.sessions.first { $0.id == fixture.sessionID })
        let history = try #require(chat.messages(forSession: fixture.sessionID))
        let revision = try #require(chat.transcriptRevision(forSession: fixture.sessionID))
        let store = fixture.settings.sessionStore
        let input = AutomaticCompactionSourcePreprocessor.Input(
            sourceID: fixture.sessionID.uuidString, assistantMessageID: assistant.id,
            initialHistory: history, currentHistory: history, localSession: local, uiRevision: revision)
        let worker = AutomaticCompactionSourcePreprocessor()
        let pause = ComposerPause3090()
        var captured: AgentLoopChatEngine.AutomaticCompactionSource?
        var base = try #require(chat.agentEngine as? AgentLoopChatEngine)
        base.updateComposerPolicy(chat.composerPolicyFacts)
        let engine = base.withAutomaticCompactionBoundary(capture: { sourceID in
            #expect(sourceID == input.sourceID)
            // Compose the real worker's result. Hold only after it has returned
            // the owned canonical value; never manufacture its source envelope.
            let source = try #require(try await worker.prepare(input, store: store))
            captured = source
            await pause.wait()
            return source
        }, adopt: { _, _ in
            Issue.record("A stale capture must not reach projection adoption")
            return false
        }, isolate: { _ in })
        var config = ProviderConfig(label: fixture.recordA.name, providerType: .openAI,
            runtimeProviderID: fixture.recordA.name, customBaseURL: fixture.recordA.baseURL,
            apiKey: "owned-synthetic-key")
        config.controlledFieldLoopbackOnly = true
        var provider = try ProviderFactory().makeProvider(for: config)
        provider.model = LLMModel(id: "gpt-4o", displayName: "Owned A", provider: fixture.recordA.name)
        let negative = Task { @MainActor () throws -> String? in
            do {
                try await fixture.consumeActualEngine3244(engine, provider: provider, turnNumber: 3244)
                Issue.record("A canonical edit after the real source capture must reject before Provider")
                return nil
            } catch SessionStoreError.sessionSnapshotConflict(let sessionID) {
                try fixture.captureExternalTypedFailure3244(sessionID: sessionID)
                return sessionID
            }
        }
        let held = await waitForWorker3220(pause)
        #expect(held, "the actual source worker must return before the external edit")
        guard held else { await pause.release(); _ = try await negative.value; return }
        do {
            let source = try #require(captured)
            #expect(source.session == store.loadSession(id: input.sourceID))
            try fixture.captureExternalCanonical3244("captured-before-edit", source: source)
            // A distinct owned Store owner makes a legitimate metadata update.
            // The original turn has no authority to overwrite this new value.
            let external = SessionStore(directory: fixture.profile.sessionDirectory)
            var changed = try #require(external.loadSession(id: input.sourceID))
            changed.title = "OWNED_EXTERNAL_METADATA_3244"
            changed.transcriptRevision += 1
            try external.updateSession(changed)
            let committed = try #require(external.loadSession(id: input.sourceID))
            #expect(committed.title == changed.title)
            #expect(committed.transcriptRevision > source.session.transcriptRevision)
            #expect(committed.messages == source.session.messages)
            try fixture.captureExternalCanonical3244("external-edit-before-engine-freeze", source: source)
            await pause.release()
            let rejectedID = try await negative.value
            #expect(rejectedID == input.sourceID)
            #expect(fixture.wireA.requests.isEmpty && fixture.wireB.requests.isEmpty)
            #expect(store.loadSession(id: input.sourceID) == committed)
            #expect(try store.loadLatestCompactionCheckpoint(sessionID: input.sourceID) == nil)
            try fixture.captureExternalCanonical3244("rejected-new-canonical-retained", source: source)
            let recovered = base.withAutomaticCompactionBoundary(capture: { sourceID in
                #expect(sourceID == input.sourceID)
                return try #require(try await worker.prepare(input, store: store))
            }, adopt: { _, _ in
                Issue.record("The ordinary recovery must not need automatic compaction")
                return false
            }, isolate: { _ in })
            // A distinct turn and operation obtain a fresh real canonical capture.
            try await fixture.consumeActualEngine3244(recovered, provider: provider, turnNumber: 3245)
            try fixture.assertRequest(fixture.wireA, model: "gpt-4o", text: user.content, png: nil)
            #expect(fixture.wireB.requests.isEmpty)
            #expect(store.loadSession(id: input.sourceID)?.title == committed.title)
            try fixture.captureExternalCanonical3244("new-identity-recovered", source: source)
        } catch {
            await pause.release()
            _ = try? await negative.value
            throw error
        }
    }

    private func waitForWorker3220(_ pause: ComposerPause3090) async -> Bool {
        for _ in 0..<400 {
            if await pause.pending() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await pause.pending()
    }

    @Test("actual authority revocation after independent B completes rejects held original A")
    func heldCompactionRejectsRealAuthorityRevocation() async throws {
        let fixture = try Fixture()
        await fixture.attach()
        let chat = fixture.bridge.chat
        defer { chat.stopAllStreamingForSafety(); fixture.stopWire(); withExtendedLifetime(fixture.settings) {} }
        try fixture.recordOccupancyForA()
        let (sent, frozen, image) = try fixture.submitA()
        let entered = await waitUntil { fixture.summary.requests.count == 1 }
        #expect(entered)
        guard entered else { await fixture.summary.pause.release(); return }
        let bID = try fixture.sendB()
        let bCompleted = await waitUntil {
            chat.sessions.first { $0.id == bID }?.messages.contains { $0.content.contains("ACTUAL_B_REPLY_3090") } == true
        }
        #expect(bCompleted)
        let current = chat.composerPolicyFacts
        // Keep the new task's epoch/revision/rights identical; only revoke authority.
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: current.knownCapabilities,
            grantedCapabilities: current.grantedCapabilities,
            capabilityGrantBindings: current.capabilityGrantBindings,
            allowedWriteRoots: current.allowedWriteRoots,
            workspaceID: current.workspaceID, revision: current.revision,
            grantEpoch: current.grantEpoch, leaseID: current.leaseID,
            expiresAt: current.expiresAt, revoked: true,
            autonomyCeiling: current.autonomyCeiling
        ))
        #expect(chat.composerPolicyFacts.revoked)
        #expect(chat.composerPolicyFacts.grantEpoch == current.grantEpoch)
        #expect(chat.composerPolicyFacts.revision == current.revision)
        await fixture.summary.pause.release()
        #expect(await fixture.waitForEnd())
        try fixture.captureTerminalDiagnostics(frozen: frozen, image: image, bID: bID)
        #expect(fixture.summary.requests.count == 1)
        #expect(fixture.wireA.requests.isEmpty)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(sessionID: fixture.sessionID.uuidString) == nil)
        try fixture.assertRequest(fixture.wireB, model: "gpt-4o-mini", text: "ONLY_B_BODY_3090", png: nil)
        try fixture.assertOrigin(sent: sent, frozen: frozen, image: image, bID: bID, success: false)
        let a = try #require(chat.sessions.first { $0.id == fixture.sessionID })
        #expect(a.messages.contains { $0.content.contains("已取消") || $0.content.contains("错误") })
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @MainActor private final class Fixture {
        let profile: RuntimeIsolationProfile
        let settings: SettingsCenter
        let bridge: BridgeStore
        let sessionID = UUID()
        let png: Data
        let wireA: ComposerWire3090
        let wireB: ComposerWire3090
        let summary: ComposerSummary3090
        var originalPolicyFacts: ComposerPolicyFactSource?
        var runtimeRouteCaptures: [[String: String]] = []
        var persistenceEvents3184: [[String: Any]] = []
        var typedFailures3184: [[String: Any]] = []
        var diagnosticBSessionID3184: UUID?
        var diagnosticBComposerSnapshot3184: ComposerSubmissionSnapshot?
        var diagnosticBExecution3184: AgentExecutionIdentity?
        let recordA: EnvVarEntry
        let recordB: EnvVarEntry
        var revisionA = "owned-revision-A"
        var expectedAContent = ""
        var assistantID: UUID?
        var execution: AgentExecutionIdentity?
        init(earlierImage: Bool = false) throws {
            summary = ComposerSummary3090(refusesSummary: earlierImage)
            profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "Composer3090",
                processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
            png = try ComposerMediaFixtures589.png()
            wireA = try ComposerWire3090(reply: "ACTUAL_A_REPLY_3090")
            wireB = try ComposerWire3090(reply: "ACTUAL_B_REPLY_3090")
            recordA = EnvVarEntry(name: "LUNA", value: "owned-synthetic-key", isSecret: true,
                baseURL: "http://127.0.0.1:\(wireA.port)", modelNames: ["gpt-4o"], protocolType: .openaiCompatible)
            recordB = EnvVarEntry(name: "OWNED_COMPOSER_B", value: "owned-synthetic-key", isSecret: true,
                baseURL: "http://127.0.0.1:\(wireB.port)", modelNames: ["gpt-4o-mini"], protocolType: .openaiCompatible)
            let defaults = profile.makeUserDefaults()
            let keychain = profile.makeKeychainStore()
            let sessions = SessionStore(directory: profile.sessionDirectory)
            var history: [LLMMessage] = []
            for option in 0..<18 {
                history.append(LLMMessage(role: .user, content: "Compare distinct option \(option), dependency \(option + 7).",
                    images: earlierImage && option == 0 ? [LLMMessage.ImageAttachment(mimeType: "image/png", data: png)] : []))
                history.append(LLMMessage(role: .assistant, content: (0..<24).map { detail in
                    "Option \(option), consideration \(detail): cost \(option + detail + 2), dependency \(option * 7 - detail), coefficient \(option * 31 + detail) and fallback \(detail % 5) have distinct tradeoffs."
                }.joined(separator: " ")))
            }
            try sessions.updateSession(ChatSession(id: sessionID.uuidString, title: "owned A3090", messages: history))
            let badges = SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges"))
            let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
            for (record, model) in [(recordA, "gpt-4o"), (recordB, "gpt-4o-mini")] {
                #expect(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: record.name, modelID: model,
                    status: .passed, readinessState: .live, checkedAt: Date(),
                    evidenceID: "live-settings:" + String(repeating: record.name == recordA.name ? "a" : "b", count: 64), isApplied: true)]))
            }
            let shortcuts = ShortcutStore(defaults: defaults)
            settings = SettingsCenter(settingsStore: SettingsStore(directory: profile.settingsDirectory),
                envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                    privacyStore: EnvVarPrivacyStore(defaults: defaults)),
                memoryStore: MemoryStore(directory: profile.memoryDirectory),
                memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
                sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
                mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
                skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
                usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain), shortcutStore: shortcuts,
                providerReadinessTransport: FailClosedProviderReadinessTransport(), providerReadinessDeployment: .mock,
                providerReadinessStore: readiness)
            bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults, logManager: settings.logManager,
                workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
                sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
                canvasRuntimeState: .disabled,
                agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks3090.json")),
                contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifest3090.json")),
                memoryStore: settings.memoryStore, memoryProposalConsumer: settings.memoryProposalConsumer,
                providerReadinessStore: readiness,
                taskCenterBindingPersistenceURL: profile.rootDirectory.appendingPathComponent("task-center3090.json"),
                canvasFeatureLane: .phase3NonCanvas,
                speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
            #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
            capturePersistenceEvent3184("owned-seed-and-attach-complete", sessionIDs: [sessionID])
        }
        func consumeActualEngine3244(_ engine: AgentLoopChatEngine,
            provider: any LLMProvider, turnNumber: Int) async throws {
            let canonical = try #require(settings.sessionStore.loadSession(id: sessionID.uuidString))
            let turn = AgentTurnIdentity(sessionID: canonical.id, turnID: turnNumber,
                messageID: "owned-canonical-message-\(turnNumber)")
            let facts = bridge.chat.composerPolicyFacts
            let composer = ComposerSubmissionSnapshot(mode: .plan, approvalScope: .request,
                effort: .standard, sessionID: turn.sessionID, turnID: turn.turnID,
                taskID: "owned-canonical3244", attemptID: "owned-attempt-\(turnNumber)",
                messageID: turn.messageID, inputDigest: "owned-input3244", workspaceID: facts.workspaceID,
                createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
                autonomyCeiling: facts.autonomyCeiling)
            let identity = AgentExecutionIdentity(turn: turn,
                operationID: "owned-canonical-operation-\(turnNumber)", attempt: 1)
            let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
            let runtime = try #require(await factory(turn, provider).preparedForExecution())
            let stream = try await engine.streamReply(provider: provider,
                history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "Owned canonical capture test",
                maxTokens: 4096, conversationID: canonical.id, authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil, turnID: turn.turnID, composerSnapshot: composer,
                executionIdentity: identity, turnRuntimeSnapshot: runtime)
            for try await _ in stream {}
        }
        func captureExternalTypedFailure3244(sessionID: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] else { return }
            let metadata: [String: Any] = ["errorType": "MinisCore.SessionStoreError",
                "errorCaseName": "sessionSnapshotConflict", "sessionID": sessionID,
                "observedAt": "exact enum catch of actual direct Engine preparation",
                "turnID": 3244, "operationID": "owned-canonical-operation-3244", "attempt": 1]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "typed3244-\(sessionID).json"), options: .atomic)
        }
        func captureExternalCanonical3244(_ phase: String,
            source: AgentLoopChatEngine.AutomaticCompactionSource) throws {
            guard let directory = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] else { return }
            let json: (any Encodable) throws -> Any = { value in
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            }
            let current = try #require(settings.sessionStore.loadSession(id: sessionID.uuidString))
            let payload: [String: Any] = ["phase": phase, "sessionID": sessionID.uuidString,
                "wallTime": Date().timeIntervalSince1970,
                "capturedSession": try json(source.session), "currentSession": try json(current),
                "closedPrefixCount": source.closedPrefixCount,
                "wireARequests": wireA.requests.count, "wireBRequests": wireB.requests.count,
                "boundary": "real source worker result held before Engine canonical freeze",
                "negativeIdentity": ["turnID": 3244, "operationID": "owned-canonical-operation-3244",
                    "sourceMessageID": "owned-canonical-message-3244", "attempt": 1],
                "positiveIdentity": ["turnID": 3245, "operationID": "owned-canonical-operation-3245",
                    "sourceMessageID": "owned-canonical-message-3245", "attempt": 1]]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(
                    "canonical3244-\(sessionID.uuidString)-\(phase).json"), options: .atomic)
        }
        /// C1: the compaction trigger is the window occupancy of A's next request
        /// (86% of the 128_000 window of `gpt-4o`: above the 80% trigger, below the
        /// 95% hard block). Replaces the cumulative-usage budget this fixture used.
        func recordOccupancyForA() throws {
            let canonical = try #require(settings.sessionStore.loadSession(id: sessionID.uuidString))
            bridge.chat.recordWindowOccupancy(
                sessionID: sessionID, providerID: recordA.name, modelID: "gpt-4o",
                sentMessageCount: canonical.messages.count)
        }
        func stopWire() { wireA.stop(); wireB.stop() }
        func attach() async {
            await bridge.attachProductionServices(agentSettings: settings.settings.agent,
                fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
                sessionDirectory: profile.sessionDirectory, mcpManager: settings.mcpManager,
                skillStore: settings.skillStore, canvasRuntimeState: .disabled, externalRunners: [:],
                externalNetworkAllowed: false, controlledFieldLoopbackAllowed: true,
                sessionReadSecretStore: settings.envStore).value
            #expect(bridge.chat.agentEngine is AgentLoopChatEngine)
            bridge.chat.turnFailureObserverForTests = { [weak self] observation in
                self?.captureOriginalFailure3184(observation)
            }
            #expect(bridge.chat.applySwitchSession(id: sessionID))
            let records = [recordA, recordB]
            bridge.chat.providerRecordsSource = { records }
            bridge.chat.schedulerCredentialVersionSource = { [weak self] name in
                guard let self else { return nil }
                return name == self.recordA.name ? self.revisionA : "owned-revision-B"
            }
            #expect(bridge.chat.applyChatModel(providerID: recordA.name, modelID: "gpt-4o"))
            bridge.chat.compactionProviderOverride = summary
            #expect(bridge.chat.streamingProviderOverride == nil)
            if let originalFactory = bridge.chat.turnRuntimeSnapshotFactory {
                bridge.chat.turnRuntimeSnapshotFactory = { [weak self] turn, provider in
                    self?.capturePersistenceEvent3184("production-runtime-factory-entry",
                        sessionIDs: UUID(uuidString: turn.sessionID).map { [$0] } ?? [])
                    let runtime = originalFactory(turn, provider)
                    self?.capturePersistenceEvent3184("production-runtime-factory-return",
                        sessionIDs: UUID(uuidString: turn.sessionID).map { [$0] } ?? [])
                    let snapshot = runtime.providerRuntimeRoute?.snapshot
                    self?.runtimeRouteCaptures.append([
                        "sessionID": turn.sessionID, "messageID": turn.messageID,
                        "turnID": String(turn.turnID), "primaryProviderID": provider.name,
                        "primaryModelID": provider.model.id,
                        "selectedUIReadinessID": self?.bridge.chat.selectedReadinessProviderID ?? "NONE",
                        "routeProviderID": snapshot?.providerID ?? "NONE",
                        "routeModelID": snapshot?.modelID ?? "NONE",
                        "readinessEvidenceID": snapshot?.readinessEvidenceID ?? "NONE",
                        "applyReceiptID": snapshot?.applyReceiptID ?? "NONE",
                        "routeError": String(describing: runtime.providerRuntimeRouteError)
                    ])
                    // Observe the production route; return that exact unmodified runtime.
                    if let snapshot, let self {
                        #expect(snapshot.providerID == provider.name)
                        #expect(snapshot.modelID == provider.model.id)
                        #expect(snapshot.readinessEvidenceID == self.bridge.chat.chatModelPickerReceipt(
                            providerID: provider.name, modelID: provider.model.id
                        )?.evidenceID)
                    }
                    return runtime
                }
            }
        }
        func submitA() throws -> (ChatMessageUI, ComposerSubmissionSnapshot, ChatAttachment) {
            let chat = bridge.chat
            let image = ChatAttachment(kind: .image, fileName: "owned.png", fileType: .image,
                mimeType: "image/png", size: Int64(png.count), data: png)
            chat.draftText = "ORIGIN_A_BODY_3090"
            chat.addComposerDraftAttachment(image)
            #expect(chat.composerMediaReadinessSnapshot.attachment(id: image.id)?.readiness == .supported)
            #expect(chat.composerAttachmentBlockReason == nil)
            chat.submitComposer()
            capturePersistenceEvent3184("A-submit-return", sessionIDs: [sessionID])
            let sent = try #require(chat.messages.last { $0.role == .user })
            let frozen = try #require(chat.lastComposerSubmissionSnapshot)
            originalPolicyFacts = chat.composerPolicyFacts
            #expect(originalPolicyFacts?.revision == frozen.policyRevision)
            #expect(originalPolicyFacts?.grantEpoch == frozen.grantEpoch)
            #expect(originalPolicyFacts?.revoked == false)
            #expect((originalPolicyFacts?.expiresAt ?? .distantPast) > Date())
            #expect(sent.content.contains("ORIGIN_A_BODY_3090"))
            expectedAContent = sent.asLLMMessage().content
            #expect(frozen.sessionID == sessionID.uuidString && frozen.messageID == sent.id.uuidString)
            #expect(chat.draftText.isEmpty && chat.pendingAttachments.isEmpty)
            let frozenAssistantID: UUID = try #require(chat.messages.last { $0.role == .assistant && $0.isStreaming }?.id)
            assistantID = frozenAssistantID
            let frozenExecution: AgentExecutionIdentity = try #require(chat.activeExecutionIdentity(for: sessionID))
            execution = frozenExecution
            #expect(execution?.turn.sessionID == frozen.sessionID)
            #expect(execution?.turn.turnID == frozen.turnID)
            #expect(execution?.turn.messageID == frozen.messageID)
            #expect(execution?.attempt == 1)
            return (sent, frozen, image)
        }
        func sendB() throws -> UUID {
            let chat = bridge.chat
            capturePersistenceEvent3184("before-B-create", sessionIDs: [sessionID])
            let bID = chat.applyNewSession(title: "owned B3090")
            diagnosticBSessionID3184 = bID
            #expect(bID != sessionID)
            capturePersistenceEvent3184("B-create-return", sessionIDs: [sessionID, bID])
            #expect(chat.applyChatModel(providerID: recordB.name, modelID: "gpt-4o-mini"))
            chat.draftText = "ONLY_B_BODY_3090"
            chat.submitComposer()
            diagnosticBComposerSnapshot3184 = chat.lastComposerSubmissionSnapshot
            diagnosticBExecution3184 = chat.activeExecutionIdentity(for: bID)
            capturePersistenceEvent3184("B-submit-return", sessionIDs: [sessionID, bID])
            let original = try #require(originalPolicyFacts)
            let current = chat.composerPolicyFacts
            #expect(current.grantEpoch != original.grantEpoch)
            #expect(current.leaseID != original.leaseID)
            #expect(current.revision == original.revision)
            #expect(current.workspaceID == original.workspaceID)
            #expect(current.knownCapabilities == original.knownCapabilities)
            #expect(current.grantedCapabilities == original.grantedCapabilities)
            #expect(current.capabilityGrantBindings == original.capabilityGrantBindings)
            #expect(current.allowedWriteRoots == original.allowedWriteRoots)
            #expect(current.autonomyCeiling == original.autonomyCeiling)
            #expect(!current.revoked && !original.revoked)
            return bID
        }
        func waitForEnd() async -> Bool {
            for _ in 0..<500 {
                if !bridge.chat.hasStreamingTasksForSafety { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return !bridge.chat.hasStreamingTasksForSafety
        }
        func captureOriginalFailure3184(_ observation: ChatTurnFailureObservationForTests) {
            // The real catch classifies the original error and retains its
            // captured execution identity. Do not guess a SessionStore case or
            // inspect arbitrary payloads; the callback only appends memory.
            let identity = observation.executionIdentity
            typedFailures3184.append([
                "sequence": typedFailures3184.count,
                "wallTime": Date().timeIntervalSince1970,
                "monotonicUptime": ProcessInfo.processInfo.systemUptime,
                "stage": observation.stage.rawValue,
                "errorType": observation.errorType,
                "errorCaseName": observation.errorCaseName ?? "NOT_A_SESSION_STORE_ERROR",
                "sessionID": observation.sessionID?.uuidString ?? "NONE",
                "assistantMessageID": observation.messageID.uuidString,
                "sourceMessageID": identity.turn.messageID,
                "turnSessionID": identity.turn.sessionID,
                "turnID": identity.turn.turnID,
                "attempt": identity.attempt,
                "operationID": identity.operationID
            ])
        }

        func captureCanonicalPhase3220(_ phase: String, bID: UUID,
                                      frozenBHistory: [ChatMessageUI], aFirst: Bool) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func object<T: Encodable>(_ value: T) throws -> Any {
                try JSONSerialization.jsonObject(with: encoder.encode(value))
            }
            let canonicalA = try #require(settings.sessionStore.loadSession(id: sessionID.uuidString))
            let canonicalB = try #require(settings.sessionStore.loadSession(id: bID.uuidString))
            let liveA = try #require(bridge.chat.messages(forSession: sessionID))
            let liveB = try #require(bridge.chat.messages(forSession: bID))
            // Full owned canonical values, closed prefix and retained suffix
            // are separate evidence. Metadata equality never substitutes for
            // the original B wire/A refusal assertions.
            let record: [String: Any] = ["phase": phase, "aFirst": aFirst,
                "wallTime": Date().timeIntervalSince1970,
                "monotonicUptime": ProcessInfo.processInfo.systemUptime,
                "A": sessionID.uuidString, "B": bID.uuidString,
                "canonicalA": try object(canonicalA), "canonicalB": try object(canonicalB),
                "liveUIA": try object(liveA), "liveUIB": try object(liveB),
                "frozenBClosedPrefix": try object(frozenBHistory.dropLast().map { $0.asLLMMessage() }),
                "frozenBRetainedSuffix": try object(frozenBHistory.suffix(1).map { $0.asLLMMessage() })]
            guard let path = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] else { return }
            let name = "canonical3220-\(sessionID)-\(aFirst ? "A-first" : "B-first")-\(phase).json"
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path).appendingPathComponent(name), options: .atomic)
        }

        // Passive owned-file metadata only. This observes the existing factory;
        // it does not replay SessionStore reads, replace the real engine, pause a
        // worker, or infer an enum case from NSError's localized error number.
        func capturePersistenceEvent3184(_ phase: String, sessionIDs: [UUID]) {
            let root = profile.rootDirectory.resolvingSymlinksInPath().standardizedFileURL
            let project = settings.sessionStore.directory.resolvingSymlinksInPath().standardizedFileURL
            let owned = root.lastPathComponent.hasPrefix("MinisCanvasAppTests-Composer3090-")
                && project.path.hasPrefix(root.path + "/")
                && project == profile.sessionDirectory.resolvingSymlinksInPath().standardizedFileURL
            #expect(owned, "diagnostics may inspect only this fixture's owned project")
            var event: [String: Any] = ["sequence": persistenceEvents3184.count,
                "phase": phase, "wallTime": Date().timeIntervalSince1970,
                "monotonicUptime": ProcessInfo.processInfo.systemUptime,
                "rootPath": root.path, "projectPath": project.path,
                "ownedProject": owned, "A": sessionID.uuidString,
                "B": diagnosticBSessionID3184?.uuidString ?? "NOT_CREATED",
                "productionEngineType": String(reflecting: type(of: bridge.chat.agentEngine)),
                "workersStillRunning": bridge.chat.hasStreamingTasksForSafety,
                "observationKind": "FileManager metadata; not a production I/O trace",
                "typedEngineError": "NOT_EXPOSED_BY_EXISTING_FACTORY"]
            guard owned else { persistenceEvents3184.append(event); return }
            var paths: [(String, URL)] = [("fixture-root", root), ("canonical-project", project)]
            for id in sessionIDs {
                let file = settings.sessionStore.sessionsDirectory
                    .appendingPathComponent(id.uuidString + ".json")
                paths.append((id == sessionID ? "A-canonical-session" : "B-canonical-session", file))
            }
            event["uiSessionIdentities"] = sessionIDs.compactMap { id -> [String: Any]? in
                guard let session = bridge.chat.sessions.first(where: { $0.id == id }) else { return nil }
                return ["sessionID": id.uuidString,
                    "projectID": session.projectID.map { String(describing: $0) } ?? "NONE",
                    "transcriptRevision": session.transcriptRevision,
                    "messageIDs": session.messages.map { $0.id.uuidString }]
            }
            event["paths"] = paths.map { role, url -> [String: Any] in
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                let inRoot = resolved == root || resolved.path.hasPrefix(root.path + "/")
                var value: [String: Any] = ["role": role, "path": url.path,
                    "canonicalPath": resolved.path, "withinOwnedRoot": inRoot]
                #expect(inRoot)
                guard inRoot else { return value }
                value["exists"] = FileManager.default.fileExists(atPath: url.path)
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    for key in [FileAttributeKey.systemNumber, .systemFileNumber, .ownerAccountID,
                                .groupOwnerAccountID, .posixPermissions, .size] {
                        if let number = attributes[key] as? NSNumber {
                            value[key.rawValue] = number
                        }
                    }
                    value["fileType"] = (attributes[.type] as? FileAttributeType)?.rawValue ?? "UNKNOWN"
                    value["mtime"] = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                } catch {
                    // Preserve the error's type; no source body, key, or error
                    // description is copied into this diagnostic journal.
                    value["metadataErrorType"] = String(reflecting: type(of: error))
                }
                return value
            }
            persistenceEvents3184.append(event)
        }

        func captureTerminalDiagnostics(frozen: ComposerSubmissionSnapshot, image: ChatAttachment, bID: UUID) throws {
            guard let path = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] else { return }
            let directory = URL(fileURLWithPath: path)
            capturePersistenceEvent3184("terminal-diagnostics-observation", sessionIDs: [sessionID, bID])
            try JSONSerialization.data(withJSONObject: typedFailures3184, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("typed-failures3184-\(sessionID).json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: persistenceEvents3184, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("persistence-events3184-\(sessionID).json"), options: .atomic)
            if let snapshot = diagnosticBComposerSnapshot3184 {
                try JSONEncoder().encode(snapshot).write(
                    to: directory.appendingPathComponent("B-snapshot3184-\(sessionID).json"), options: .atomic)
            }
            if let identity = diagnosticBExecution3184 {
                try JSONEncoder().encode(identity).write(
                    to: directory.appendingPathComponent("B-execution3184-\(sessionID).json"), options: .atomic)
            }
            try JSONEncoder().encode(frozen).write(to: directory.appendingPathComponent("snapshot-\(sessionID).json"), options: .atomic)
            if let execution {
                try JSONEncoder().encode(execution).write(to: directory.appendingPathComponent("execution-\(sessionID).json"), options: .atomic)
            }
            var sessions: [[String: Any]] = []
            for id in [sessionID, bID] {
                if let session = bridge.chat.sessions.first(where: { $0.id == id }) {
                    sessions.append(["sessionID": id.uuidString, "messages": session.messages.map {
                        ["id": $0.id.uuidString, "role": $0.role.rawValue, "content": $0.content,
                         "attachmentIDs": $0.attachments.map { $0.id.uuidString },
                         "modelID": $0.turnModelID ?? "NONE"] as [String: Any]
                    }])
                }
            }
            let effects: [String: Any] = ["A": sessionID.uuidString, "B": bID.uuidString,
                "sourceMessageID": frozen.messageID, "attachmentID": image.id.uuidString,
                "originalGrantEpoch": frozen.grantEpoch, "currentGrantEpoch": bridge.chat.composerPolicyFacts.grantEpoch,
                "currentPolicyRevision": bridge.chat.composerPolicyFacts.revision,
                "currentAuthorityRevoked": bridge.chat.composerPolicyFacts.revoked,
                "ARequestCount": wireA.requests.count, "BRequestCount": wireB.requests.count,
                "summaryCount": summary.requests.count, "routes": runtimeRouteCaptures, "sessions": sessions]
            try JSONSerialization.data(withJSONObject: effects, options: [.prettyPrinted, .sortedKeys]).write(
                to: directory.appendingPathComponent("effects-\(sessionID).json"), options: .atomic)
            for (label, wire) in [("A", wireA), ("B", wireB)] {
                for (index, bytes) in wire.requests.enumerated() {
                    try bytes.write(to: directory.appendingPathComponent("captured-wire-\(sessionID)-\(label)-\(index).json"), options: .atomic)
                }
            }
        }
        func assertRequest(_ wire: ComposerWire3090, model: String, text: String, png: Data?) throws {
            #expect(wire.captureFailure == nil)
            #expect(wire.requests.count == 1, wire === wireB ? Comment(rawValue: {
                guard let identity = diagnosticBExecution3184 else { return "B_FAILURE_UNOBSERVED" }
                let matches = typedFailures3184.filter {
                    ($0["turnSessionID"] as? String) == identity.turn.sessionID
                        && ($0["turnID"] as? Int) == identity.turn.turnID
                        && ($0["sourceMessageID"] as? String) == identity.turn.messageID
                        && ($0["attempt"] as? Int) == identity.attempt
                }
                guard !matches.isEmpty else { return "B_FAILURE_UNOBSERVED" }
                guard matches.count == 1, let failure = matches.first else { return "B_FAILURE_AMBIGUOUS" }
                let stage = failure["stage"] as? String ?? "UNOBSERVED"
                let errorCase = failure["errorCaseName"] as? String ?? "UNOBSERVED"
                return "B_FAILURE stage=\(stage) case=\(errorCase)"
            }()) : nil)
            let bytes = try #require(wire.requests.first)
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(json["model"] as? String == model)
            #expect(json["stream"] as? Bool == true)
            let messages = try #require(json["messages"] as? [[String: Any]])
            let users = messages.filter { $0["role"] as? String == "user" }
            let last = try #require(users.last)
            let encoded = String(decoding: bytes, as: UTF8.self)
            #expect(encoded.contains(text))
            #expect(!encoded.contains(text == "ORIGIN_A_BODY_3090" ? "ONLY_B_BODY_3090" : "ORIGIN_A_BODY_3090"))
            if let png {
                let content = try #require(last["content"] as? [[String: Any]])
                #expect(content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String } == [expectedAContent])
                let image = try #require(content.first { $0["type"] as? String == "image_url" })
                let url = try #require((image["image_url"] as? [String: Any])?["url"] as? String)
                #expect(url == "data:image/png;base64," + png.base64EncodedString())
            } else {
                #expect(!encoded.contains("image_url"))
                #expect(!encoded.contains("Compare distinct option"))
                #expect(last["content"] as? String == text)
            }
            // IDs live on Store/Agent turn identity, not OpenAI's HTTP schema.
            if let path = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] {
                let destination = URL(fileURLWithPath: path).appendingPathComponent("request-\(sessionID)-\(model).json")
                try bytes.write(to: destination, options: .atomic)
                print("TASK3090_PROVIDER_REQUEST_FILE=\(destination.path)")
            }
            print("TASK3090_PROVIDER_REQUEST model=\(model) bodyMatch=true pngMatch=\(png != nil) requestCount=\(wire.requests.count) stream=true")
        }
        /// C4 (user decision 2159 #4c): in the 80%-95% band the earlier image is sent as a
        /// text placeholder; only the current message still carries the image bytes.
        func assertRefusedSummaryRequest() throws {
            let requests = summary.requests
            try #require(requests.count == 1)
            let request = try #require(requests.first)
            try #require(request.count == 1)
            let message = try #require(request.first)
            #expect(message.role == .user)
            #expect(message.content.hasPrefix("请把下面这段较早的对话压缩成一份摘要，供后续对话继续使用。"))
            #expect(message.content.contains("===== 对话记录 ====="))
            #expect(message.content.hasSuffix("===== 记录结束 ====="))
            #expect(!message.content.contains("ONLY_B_BODY_3090"))
        }

        func assertEarlierImagePlaceheld(_ wire: ComposerWire3090) throws {
            let bytes = try #require(wire.requests.first)
            let marker = "data:image/png;base64," + png.base64EncodedString()
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            // The wire JSON escapes "/" as "\/", so count the payload in the parsed body
            // re-serialized without slash escaping, not in the raw bytes.
            let unescaped = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            let encoded = String(decoding: unescaped, as: UTF8.self)
            #expect(encoded.components(separatedBy: marker).count - 1 == 1,
                "exactly one image payload (the current message) may remain")
            let messages = try #require(json["messages"] as? [[String: Any]])
            let firstUser = try #require(messages.first { $0["role"] as? String == "user" })
            let text = try #require(firstUser["content"] as? String)
            #expect(text.contains("已省略"), "the earlier image must be replaced by its placeholder line")
        }
        func assertOrigin(sent: ChatMessageUI, frozen: ComposerSubmissionSnapshot, image: ChatAttachment,
                          bID: UUID, success: Bool) throws {
            let chat = bridge.chat
            let a = try #require(chat.sessions.first { $0.id == sessionID })
            let b = try #require(chat.sessions.first { $0.id == bID })
            #expect(a.messages.filter { $0.id == sent.id }.count == 1)
            let retained = try #require(a.messages.first { $0.id == sent.id })
            #expect(retained.content == sent.content)
            #expect(retained.attachments.first?.id == image.id)
            #expect(retained.attachments.first?.data == png)
            #expect(a.messages.allSatisfy { !$0.content.contains("ONLY_B_BODY_3090") })
            #expect(b.messages.allSatisfy { !$0.content.contains("ORIGIN_A_BODY_3090") && $0.attachments.isEmpty })
            let placeholder = try #require(a.messages.first { $0.id == assistantID && $0.role == .assistant })
            #expect(placeholder.turnModelID == "gpt-4o")
            #expect(placeholder.turnTiming != nil)
            #expect(placeholder.content.contains("ACTUAL_A_REPLY_3090") == success, Comment(rawValue: {
                let first = typedFailures3184.first {
                    ($0["turnSessionID"] as? String) == frozen.sessionID
                        && ($0["turnID"] as? Int) == frozen.turnID
                        && ($0["attempt"] as? Int) == execution?.attempt
                }
                let text = first.map { "stage=\($0["stage"] as? String ?? "UNOBSERVED") type=\($0["errorType"] as? String ?? "UNOBSERVED") case=\($0["errorCaseName"] as? String ?? "UNOBSERVED")" } ?? "A_FAILURE_UNOBSERVED"
                let marker = " [TRUNCATED]"
                return text.count > 320 ? String(text.prefix(320 - marker.count)) + marker : text
            }()))
            #expect(b.messages.contains { $0.content.contains("ACTUAL_B_REPLY_3090") && $0.turnModelID == "gpt-4o-mini" })
            #expect(chat.activeSessionID == bID)
            let canonical = try #require(settings.sessionStore.loadSession(id: sessionID.uuidString))
            #expect(canonical.messages.filter { $0.content.contains("ORIGIN_A_BODY_3090") }.count == 1)
            #expect(canonical.messages.contains { $0.images.contains { $0.data == png } })
            if let path = ProcessInfo.processInfo.environment["COMPOSER3090_EVIDENCE_DIRECTORY"] {
                let destination = URL(fileURLWithPath: path).appendingPathComponent("snapshot-\(sessionID).json")
                try JSONEncoder().encode(frozen).write(to: destination, options: .atomic)
                if let execution {
                    try JSONEncoder().encode(execution).write(to: URL(fileURLWithPath: path).appendingPathComponent("execution-\(sessionID).json"), options: .atomic)
                }
            }
            print("TASK3090_IDENTITY session=\(frozen.sessionID) message=\(frozen.messageID) turn=\(frozen.turnID) attachment=\(image.id) assistant=\(placeholder.id) attempt=\(execution?.attempt ?? -1) operation=\(execution?.operationID ?? "NONE") originSuccess=\(success) B=\(bID)")
        }
    }
}
