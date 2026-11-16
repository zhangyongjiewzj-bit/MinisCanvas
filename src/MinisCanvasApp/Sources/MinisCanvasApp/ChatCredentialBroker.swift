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
    private var streamBuffers: [UUID: String] = [:]
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

    func projectStream(messageID: UUID, current: String, append: String) -> String {
        let raw = (streamBuffers[messageID] ?? current) + append
        streamBuffers[messageID] = raw
        return protect(raw)
    }

    func replaceStream(messageID: UUID, with text: String) -> String {
        streamBuffers[messageID] = text
        return protect(text)
    }

    func finishStream(messageID: UUID) { streamBuffers.removeValue(forKey: messageID) }

    func cancel(sessionID: UUID? = nil) {
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
        streamBuffers.removeAll(keepingCapacity: false)
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
