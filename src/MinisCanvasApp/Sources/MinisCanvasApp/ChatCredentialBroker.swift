import Foundation
import Observation
import MinisCore

/// App-local custody only. Neither entries nor stream buffers are Codable.
/// Public projections contain handles and outcomes, never captured values.
@MainActor @Observable
final class ChatCredentialBroker {
    struct Request: Identifiable, Equatable {
        let id: String
        let sessionID: UUID
        let expiresAt: Date
        var providerID: String?
    }

    enum Outcome: Equatable {
        case saved, savedProbeBlocked, savedProbeFailed, rejected, cancelled
    }

    private struct Entry {
        let value: String
        var request: Request
    }

    private(set) var pending: Request?
    private(set) var outcome: Outcome?
    private(set) var isConfirming = false
    private var entries: [String: Entry] = [:]
    /// 每条流式消息一份增量脱敏状态（原文 + 已提交前缀 + 尾部窗口）。
    private var streams: [UUID: IncrementalSecretRedactor] = [:]
    /// 托管撤销（cancel）时已脱敏、但尚未显示的尾部；下一次投影接在界面文本后面。
    private var withheldAfterCancel: [UUID: String] = [:]
    /// 思考通道（thinking）同样按消息增量脱敏，状态与正文分开。
    private var thinkingStreams: [UUID: IncrementalSecretRedactor] = [:]
    private var thinkingWithheldAfterCancel: [UUID: String] = [:]
    private var resolving: Request?
    private var activeRequest: Request?
    private var probeTask: Task<SettingsProviderReadinessReport?, Never>?
    private weak var center: SettingsCenter?
    private var externalNetworkAllowed = false
    var clock: () -> Date = Date.init
    var ttl: TimeInterval = 300

    func attach(center: SettingsCenter, externalNetworkAllowed: Bool) {
        self.center = center
        self.externalNetworkAllowed = externalNetworkAllowed
        center.bl6CredentialResolver = { [weak self] handle in
            self?.consume(handle)
        }
    }

    var providerIDs: [String] { center?.providerRecords.map(\.name) ?? [] }

    func providerProjection(_ id: String) -> ChatProviderSettingsReopenProjection? {
        center?.chatProviderSettingsProjection(providerID: id)
    }

    func beginSecureEntry(sessionID: UUID) {
        cancel()
        let request = Request(id: UUID().uuidString, sessionID: sessionID,
                              expiresAt: clock().addingTimeInterval(ttl))
        pending = request
        scheduleExpiry(request)
    }

    private func scheduleExpiry(_ request: Request) {
        Task { [weak self] in
            let delay = max(0, min(self?.ttl ?? 300, 300))
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.pending?.id == request.id else { return }
            self.cancel(sessionID: request.sessionID)
        }
    }

    // Immutable format grammar is shared by all edits; custody and matches
    // remain per-call/per-session. Never cache user text or matched values.
    private static let captureFormatProbe = try? NSRegularExpression(
        pattern: #"(?i)sk-|bearer|api[_-]?key|apikey|token|password|secret"#
    )
    private static let captureRegex = try? NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_\-]{8,}|(?i:Bearer\s+)([A-Za-z0-9_\-.=+/]{8,})|(?i:(?:api[_-]?key|apikey|token|password|secret)\s*[=:]\s*)[\"']?([^\s\"';&]{4,})"#)

    /// Known credential shapes are intercepted regardless of prose intent.
    /// Detection never constitutes authorization to mutate a provider.
    func capture(_ text: String, sessionID: UUID?, stageCredential: Bool = true) -> String {
        // A proven ASCII format-negative still passes through known-secret
        // masking. Candidate pairs and Unicode always use the original ICU
        // capture grammar, including matches completed by this edit.
        let checked = ContentSecretRedactor.FormatCheckedText(text)
        if !checked.mayContainFormatTrigger {
            return ContentSecretRedactor.redact(checked, knownSecrets: currentKnownSecrets())
        }
        if let probe = Self.captureFormatProbe,
           probe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
            return protect(text)
        }
        guard let regex = Self.captureRegex else { return protect(text) }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return protect(text) }
        if stageCredential { cancel() }
        var safe = text
        let now = clock()
        for match in matches.reversed() {
            let group = match.range(at: 2).location != NSNotFound ? 2
                : (match.range(at: 1).location != NSNotFound ? 1 : 0)
            guard let range = Range(match.range(at: group), in: safe) else { continue }
            let value = String(safe[range])
            let id = UUID().uuidString
            // Multiple credentials require a fresh explicit SecureField entry.
            // All detected values are removed, but none is silently selected.
            if stageCredential, matches.count == 1, let sessionID {
                let request = Request(id: id, sessionID: sessionID,
                                      expiresAt: now.addingTimeInterval(ttl))
                entries[id] = Entry(value: value, request: request)
                pending = request
                scheduleExpiry(request)
            }
            safe.replaceSubrange(range, with: "[本地凭据:" + id + "]")
        }
        return protect(safe)
    }

    @discardableResult
    func captureSecureField(_ value: String, sessionID: UUID) -> Request? {
        cancel()
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let request = Request(id: UUID().uuidString, sessionID: sessionID,
                              expiresAt: clock().addingTimeInterval(ttl))
        entries[request.id] = Entry(value: value, request: request)
        pending = request
        scheduleExpiry(request)
        return request
    }

    func protect(_ text: String) -> String {
        ContentSecretRedactor.redact(text, knownSecrets: currentKnownSecrets())
    }

    private func currentKnownSecrets() -> [String] {
        // A confirmed handle leaves local custody, but the saved provider
        // still owns its value. Use only values already in the injected
        // profile's in-memory snapshot; this projection must never trigger a
        // deferred Keychain read on the transcript/rendering path.
        let saved = center?.envStore.allEnvVars.compactMap { entry in
            entry.isSecret && !entry.value.isEmpty ? entry.value : nil
        } ?? []
        return entries.values.map(\.value) + saved
    }

    /// 流式片段投影：只重扫尾部窗口；尾部里可能是密钥前半段的末端先不显示，
    /// 到下一个边界或回合结束（`finalizeStream`）才显示。
    func projectStreamUpdate(messageID: UUID, current: String, append: String) -> IncrementalSecretRedactor.Update {
        let perf = PerformanceSignposts.begin(.streamRedaction); defer { perf.end() }
        var stream = streams.removeValue(forKey: messageID)
            ?? IncrementalSecretRedactor(
                surface: current, withheld: withheldAfterCancel.removeValue(forKey: messageID) ?? "")
        let update = stream.append(append, knownSecrets: currentKnownSecrets())
        streams[messageID] = stream
        return update
    }

    func projectStream(messageID: UUID, current: String, append: String) -> String {
        projectStreamUpdate(messageID: messageID, current: current, append: append).text
    }

    func replaceStream(messageID: UUID, with text: String) -> String {
        withheldAfterCancel.removeValue(forKey: messageID)
        var stream = IncrementalSecretRedactor()
        let shown = stream.replace(with: text, knownSecrets: currentKnownSecrets())
        streams[messageID] = stream
        return shown
    }

    /// 工具调用边界：把扣住的尾部放开并定稿，行内锚点才落在已显示文字之后。
    func settleStream(messageID: UUID) -> IncrementalSecretRedactor.Update? {
        guard var stream = streams.removeValue(forKey: messageID) else { return nil }
        let update = stream.settle(knownSecrets: currentKnownSecrets())
        streams[messageID] = stream
        return update
    }

    /// 回合终态（完成/出错/停止共用）：对整条原文做一次全量脱敏并以它为准，
    /// 同时释放这条消息的流状态。没有流状态、没有被扣住的尾部且无追加时返回 nil
    /// （界面文本保持不变）。
    func finalizeStream(messageID: UUID, current: String, append: String = "") -> IncrementalSecretRedactor.Update? {
        let stream = streams.removeValue(forKey: messageID)
        let withheld = withheldAfterCancel.removeValue(forKey: messageID)
        guard stream != nil || withheld != nil || !append.isEmpty else { return nil }
        let full: String
        if let stream {
            // 被扣住的尾部若可能是残缺密钥，并入正文前先遮蔽；追加的收尾文字单独脱敏。
            full = stream.terminalProjection(knownSecrets: currentKnownSecrets())
                + (append.isEmpty ? "" : protect(append))
        } else {
            full = protect(current + (withheld ?? "") + append)
        }
        return IncrementalSecretRedactor.Update(
            text: full, extendsPrevious: full.utf8.starts(with: current.utf8))
    }

    func finishStream(messageID: UUID) {
        streams.removeValue(forKey: messageID)
        withheldAfterCancel.removeValue(forKey: messageID)
        thinkingStreams.removeValue(forKey: messageID)
        thinkingWithheldAfterCancel.removeValue(forKey: messageID)
    }

    /// 思考文字的增量投影：与正文同一套扣留规则，返回应显示的文本。
    func projectThinking(messageID: UUID, current: String, append: String) -> String {
        var stream = thinkingStreams.removeValue(forKey: messageID)
            ?? IncrementalSecretRedactor(
                surface: current, withheld: thinkingWithheldAfterCancel.removeValue(forKey: messageID) ?? "")
        let update = stream.append(append, knownSecrets: currentKnownSecrets())
        thinkingStreams[messageID] = stream
        return update.text
    }

    /// 思考文字的终态：被扣住的尾部按与正文相同的规则放开或遮蔽。没有思考流状态时返回 nil。
    func finalizeThinking(messageID: UUID, current: String) -> String? {
        let stream = thinkingStreams.removeValue(forKey: messageID)
        let withheld = thinkingWithheldAfterCancel.removeValue(forKey: messageID)
        if let stream { return stream.terminalProjection(knownSecrets: currentKnownSecrets()) }
        guard let withheld else { return nil }
        return protect(current + withheld)
    }

    func cancel(sessionID: UUID? = nil) {
        // 先取走各流尚未显示的尾部（此刻托管仍有效，按当时的已知密钥脱敏），
        // 否则撤销后这段文字既不在界面上、也无法再被掩码。
        if !streams.isEmpty || !thinkingStreams.isEmpty {
            let known = currentKnownSecrets()
            for (id, stream) in streams {
                let withheld = stream.withheldRedacted(knownSecrets: known)
                if !withheld.isEmpty { withheldAfterCancel[id] = withheld }
            }
            for (id, stream) in thinkingStreams {
                let withheld = stream.withheldRedacted(knownSecrets: known)
                if !withheld.isEmpty { thinkingWithheldAfterCancel[id] = withheld }
            }
        }
        if sessionID == nil || activeRequest?.sessionID == sessionID {
            probeTask?.cancel()
        }
        if let sessionID {
            entries = entries.filter { $0.value.request.sessionID != sessionID }
            if pending?.sessionID == sessionID { pending = nil }
        } else {
            entries.removeAll()
            pending = nil
        }
        resolving = nil
        outcome = .cancelled
        // Generation-termination scrub: cancellation drops the captured
        // values from custody, and a raw stream accumulation can contain
        // echoes of exactly those values. If the raw copy survived, the next
        // projection would rebuild from it while `knownSecrets` no longer
        // lists the value, re-exposing it in clear on the visible transcript
        // and any later durable write. Removing the raw copies forces the
        // projection to rebuild from the already-redacted surface text,
        // which no masking pass can un-redact; each append is still rescanned
        // as (base + append), so credentials split across the removal
        // boundary stay covered by the pattern layer. This only ever withholds
        // more material; it never grants additional visibility.
        streams.removeAll(keepingCapacity: false)
        thinkingStreams.removeAll(keepingCapacity: false)
    }

    /// Resolution is possible only inside the synchronous approved CAS write.
    /// A caller holding a copied/replayed handle cannot open custody itself.
    private func consume(_ handle: BL6CredentialHandle) -> String? {
        guard let context = resolving, context.id == handle.id,
              let entry = entries[handle.id], entry.request == context,
              context.expiresAt > clock(), context.providerID != nil else { return nil }
        entries.removeValue(forKey: handle.id)
        return entry.value
    }

    func confirm(requestID: String, sessionID: UUID, providerID: String,
                 baseURL: String, modelIDs: [String], protocolType: ProviderWireProtocol,
                 riskConfirmed: Bool) async -> Outcome {
        guard !isConfirming, riskConfirmed, let center,
              var entry = entries[requestID], pending?.id == requestID,
              entry.request.sessionID == sessionID, entry.request.expiresAt > clock(),
              !providerID.isEmpty, protect(providerID) == providerID,
              protect(baseURL) == baseURL,
              modelIDs.allSatisfy({ protect($0) == $0 }),
              center.providerRecords.filter({ $0.name.caseInsensitiveCompare(providerID) == .orderedSame }).count <= 1
        else { outcome = .rejected; return .rejected }
        entry.request.providerID = providerID
        entries[requestID] = entry
        pending = entry.request
        guard case .success(let preview) = center.makeChatProviderSettingsPreview(
            requestID: requestID, providerID: providerID, baseURL: baseURL,
            modelIDs: modelIDs, protocolType: protocolType,
            credential: .opaqueHandle(BL6CredentialHandle(id: requestID)))
        else { outcome = .rejected; return .rejected }
        isConfirming = true
        activeRequest = entry.request
        resolving = entry.request
        let result = center.confirmChatProviderSettings(preview,
                                                        approvalReceiptID: "local-credential-" + requestID)
        resolving = nil
        entries.removeValue(forKey: requestID)
        pending = nil
        defer {
            isConfirming = false
            activeRequest = nil
            probeTask = nil
        }
        guard case .success = result else { outcome = .rejected; return .rejected }
        let host = URL(string: baseURL)?.host?.lowercased()
        guard externalNetworkAllowed || ["localhost", "127.0.0.1", "::1"].contains(host ?? "") else {
            outcome = .savedProbeBlocked
            return .savedProbeBlocked
        }
        guard !Task.isCancelled else { outcome = .savedProbeFailed; return .savedProbeFailed }
        let task = Task { await center.checkProviderReadiness(forProviderName: providerID) }
        probeTask = task
        let report = await task.value
        let answer: Outcome = !task.isCancelled && (report?.state == .live || report?.state == .local)
            ? .saved : .savedProbeFailed
        outcome = answer
        return answer
    }
}
