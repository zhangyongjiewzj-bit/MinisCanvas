import Foundation
import CryptoKit
import MinisCore

/// One source identity with separate read and control implementations. The
/// existing AppAdapter and ledger remain the only app-facing authorization
/// gate; each underlying implementation also enforces its own grant type.
private struct ExternalSessionReadControlComposite: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    let reader: any ExistingAgentSessionAdapter
    let controller: any ExistingAgentSessionAdapter

    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        try await reader.listThreads(query: query, readGrant: readGrant)
    }

    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        try await reader.read(request: request, readGrant: readGrant)
    }

    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        try await reader.status(target: target, readGrant: readGrant)
    }

    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        try await controller.control(request: request, controlGrant: controlGrant)
    }
}

/// No target-path I/O occurs while only the source choice is registered.
/// The Task Center names this state as pending, and all operations refuse.
private struct ExternalSessionPendingReadSource: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        throw ExternalSessionAppAdapterError.sourceUnavailable
    }
    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        throw ExternalSessionAppAdapterError.sourceUnavailable
    }
    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        throw ExternalSessionAppAdapterError.sourceUnavailable
    }
    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        throw ExternalSessionAppAdapterError.sourceUnavailable
    }
}

private extension ExternalSessionControlTargetV1 {
    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}

private extension ExternalSessionReadTargetV1 {
    func isSource(_ sourceID: ExternalSessionSourceID) -> Bool {
        if case .source(let target) = self { return target == sourceID }
        return false
    }
}

enum ExternalSessionCodexRetirementPhase: Sendable {
    case closing, holding, incompleteReceipt, witnessFailed
}

struct ExternalSessionCodexRetirementStatus: Sendable {
    let leaseID: UUID
    let ownerID: UUID?
    let phase: ExternalSessionCodexRetirementPhase
    let receipt: ExternalSessionCodexStdioTerminationReceipt?
}

struct ExternalSessionCodexRetirementOverview: Sendable {
    let reservationCount: Int
    let connections: [ExternalSessionCodexRetirementStatus]
    var isComplete: Bool { reservationCount == 0 && connections.isEmpty }
}

/// One exact connection owns one retirement reservation. A caller's temporary
/// revoke reservation never substitutes for this retained Process/FD witness.
@MainActor
private final class ExternalSessionCodexRetirementBook {
    private struct Entry {
        let sourceID: ExternalSessionSourceID
        let leaseID: UUID
        let connection: ExternalSessionCodexStdioConnection
        var witness: ExternalSessionCodexStdioTermination?
        var receipt: ExternalSessionCodexStdioTerminationReceipt?
        var phase: ExternalSessionCodexRetirementPhase = .closing
        var waiter: Task<Void, Never>?
    }
    private var reservations: [ExternalSessionSourceID: Set<UUID>] = [:]
    private var entries: [ObjectIdentifier: Entry] = [:]

    func reserve(_ sourceID: ExternalSessionSourceID) -> UUID {
        let id = UUID(); reservations[sourceID, default: []].insert(id); return id
    }
    func release(_ sourceID: ExternalSessionSourceID, leaseID: UUID) {
        guard var leases = reservations[sourceID], leases.remove(leaseID) != nil else { return }
        reservations[sourceID] = leases.isEmpty ? nil : leases
    }
    func isRetiring(_ sourceID: ExternalSessionSourceID) -> Bool {
        !(reservations[sourceID]?.isEmpty ?? true)
    }
    func overview(_ sourceID: ExternalSessionSourceID) -> ExternalSessionCodexRetirementOverview {
        let statuses = entries.values.filter { $0.sourceID == sourceID }.map {
            ExternalSessionCodexRetirementStatus(leaseID: $0.leaseID, ownerID: $0.witness?.ownerID,
                phase: $0.phase, receipt: $0.receipt)
        }.sorted { $0.leaseID.uuidString < $1.leaseID.uuidString }
        return ExternalSessionCodexRetirementOverview(
            reservationCount: reservations[sourceID]?.count ?? 0, connections: statuses)
    }
    func soleWitness(_ sourceID: ExternalSessionSourceID) -> ExternalSessionCodexStdioTermination? {
        let matches = entries.values.filter { $0.sourceID == sourceID }
        return matches.count == 1 ? matches[0].witness : nil
    }

    func retire(_ connection: ExternalSessionCodexStdioConnection, sourceID: ExternalSessionSourceID) async {
        let key = ObjectIdentifier(connection)
        guard entries[key] == nil else { return }
        // Reserve and retain before the first actor suspension.
        let leaseID = reserve(sourceID)
        entries[key] = Entry(sourceID: sourceID, leaseID: leaseID, connection: connection)
        let witness = await connection.terminationCompletion()
        guard var entry = matching(key, sourceID: sourceID, leaseID: leaseID) else { return }
        entry.witness = witness; entries[key] = entry
        let receipt = await connection.close()
        guard var current = matching(key, sourceID: sourceID, leaseID: leaseID) else { return }
        current.receipt = receipt
        guard receipt.ownerID == witness.ownerID else {
            current.phase = .incompleteReceipt; entries[key] = current; return
        }
        if receipt.isComplete {
            entries[key] = nil; release(sourceID, leaseID: leaseID); return
        }
        current.phase = .holding; entries[key] = current
        // This same owner survives its caller. No timeout/cancel drops the
        // original connection, true completion token or admission reservation.
        let waiter = Task { @MainActor [self] in
            do {
                let terminal = try await witness.wait()
                acceptTerminal(terminal, key: key, sourceID: sourceID,
                    leaseID: leaseID, ownerID: witness.ownerID)
            } catch {
                guard var retained = matching(key, sourceID: sourceID, leaseID: leaseID) else { return }
                retained.phase = .witnessFailed; retained.waiter = nil; entries[key] = retained
            }
        }
        current.waiter = waiter; entries[key] = current
    }

    private func matching(_ key: ObjectIdentifier, sourceID: ExternalSessionSourceID, leaseID: UUID) -> Entry? {
        guard let entry = entries[key], entry.sourceID == sourceID, entry.leaseID == leaseID,
              ObjectIdentifier(entry.connection) == key else { return nil }
        return entry
    }
    private func acceptTerminal(_ receipt: ExternalSessionCodexStdioTerminationReceipt,
                                key: ObjectIdentifier, sourceID: ExternalSessionSourceID,
                                leaseID: UUID, ownerID: UUID) {
        guard var entry = matching(key, sourceID: sourceID, leaseID: leaseID) else { return }
        guard receipt.ownerID == ownerID, entry.witness?.ownerID == ownerID else { return }
        // Even an absent PID is not a complete retirement receipt. Preserve
        // this fence on every incomplete result; never infer exit/reap from
        // nil metadata, a returned callback, or a completed observer task.
        if receipt.isComplete {
            entries[key] = nil; release(sourceID, leaseID: leaseID)
        } else {
            entry.receipt = receipt; entry.phase = .incompleteReceipt
            entry.waiter = nil; entries[key] = entry
        }
    }
}

/// Composition-root owner of the external-session authorization ledger.
///
/// Before this type existed, `ExternalSessionAuthorizationLedgerV1` was
/// constructed only inside test targets, while the app-facing gate
/// (`ExternalSessionAppAdapter`) took its ledger as an optional parameter that
/// defaulted to `nil`. A `nil` ledger makes `enforceAuthorizationActive`
/// return early, so every revocation-epoch check is skipped: the production
/// authorization boundary was fail-open by default and permanently inert
/// because nothing at the composition root ever supplied a ledger.
///
/// This type closes exactly that gap and nothing more:
/// - it owns one `ExternalSessionAuthorizationLedgerV1` per app process, as a
///   single owner held by `MinisCanvasAppMain`. There is no shared global
///   instance and no second ledger anywhere in the app.
/// - it is the only app-side factory for `ExternalSessionAppAdapter`, and the
///   adapter it hands out always carries this ledger (never `nil`).
/// - grant issuance is pure delegation to that ledger. It adds no new
///   authorization semantics, does not widen a scope or operation set, and
///   refuses to mint a grant for a source this owner does not supervise.
/// - runtime publication goes to the already existing `TaskCenterControlConsumer`
///   seam, which stays read-only.
///
/// The local SessionStore source is registered at launch. External sources
/// enter only through the user's selected directory in Task Center. The
/// existing ledger and AppAdapter enforce separate read/control grants, and
/// registration never starts a transport or reads the selected directory.
/// No credential, token or session content is persisted here.
@MainActor
final class ExternalSessionAuthorizationComposition {
    /// The one ledger this app process authorizes external sessions against.
    let ledger: ExternalSessionAuthorizationLedgerV1

    /// UI-only suggestions. No source registration, grant, enumeration or I/O.
    private(set) var directorySelectionSuggestions: (codex: URL, claudeCode: URL)?

    static func directorySelectionSuggestions(
        mode: RuntimeIsolationProfile.Mode, profileRoot: URL, productionHome: () -> URL
    ) -> (codex: URL, claudeCode: URL) {
        guard mode == .production else { return (profileRoot, profileRoot) }
        let home = productionHome()
        return (home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".claude/projects", isDirectory: true))
    }

    func configureDirectorySelectionSuggestions(profile: RuntimeIsolationProfile) {
        directorySelectionSuggestions = Self.directorySelectionSuggestions(
            mode: profile.mode, profileRoot: profile.rootDirectory,
            productionHome: { FileManager.default.homeDirectoryForCurrentUser }
        )
    }

    /// Adapters already handed out, keyed by the source identity they enforce.
    private var adapters: [ExternalSessionSourceID: ExternalSessionAppAdapter] = [:]
    private var selectedReaders: [ExternalSessionSourceID: any ExistingAgentSessionAdapter] = [:]
    private var selectedCodexHomes: [ExternalSessionSourceID: URL] = [:]
    private var controlledMemoryRuntimeDirectory: URL?
    private struct PendingReadConfiguration {
        let kind: ExternalSessionSourceKindV1
        let rootURL: URL
        let profileID: ExternalSessionProfileID
        let hostID: String
    }
    private var pendingReadRoots: [ExternalSessionSourceID: PendingReadConfiguration] = [:]
    private var selectedSourceLabels: [ExternalSessionSourceID: String] = [:]
    private var memoryProposalConsumer: MemoryProposalConsumer?
    private var externalMemoryScopes: [ExternalSessionSourceID: MemoryScope] = [:]
    private var externalHostID: String?
    private struct SyntheticCodexControlConfiguration {
        let executableURL: URL
        let homeURL: URL
        let runtimeDirectory: URL
    }
    private var syntheticCodexControl: [ExternalSessionSourceID: SyntheticCodexControlConfiguration] = [:]
    private var activeCodexConnections: [ExternalSessionSourceID: ExternalSessionCodexStdioConnection] = [:]
    private var ownedDynamicConnections: [ExternalSessionSourceID: ExternalSessionCodexStdioConnection] = [:]
    private struct CodexConnectionAttempt {
        let id: UUID
        let task: Task<Void, any Error>
        var connection: ExternalSessionCodexStdioConnection?
    }
    private var pendingCodexConnections: [ExternalSessionSourceID: CodexConnectionAttempt] = [:]
    private let codexRetirements = ExternalSessionCodexRetirementBook()

    /// Reserve before the first suspension. Only this outer owner removes the
    /// slot, after the original worker Task.value really completed.
    private func withCodexConnectionAttempt(
        sourceID: ExternalSessionSourceID,
        unavailable: any Error,
        operation: @escaping @MainActor (UUID) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard activeCodexConnections[sourceID] == nil,
              pendingCodexConnections[sourceID] == nil,
              !codexRetirements.isRetiring(sourceID) else { throw unavailable }
        let id = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await operation(id)
        }
        pendingCodexConnections[sourceID] = CodexConnectionAttempt(id: id, task: task)
        defer {
            if pendingCodexConnections[sourceID]?.id == id { pendingCodexConnections[sourceID] = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func requireCodexConnectionAttempt(_ sourceID: ExternalSessionSourceID, id: UUID) throws {
        try Task.checkCancellation()
        guard pendingCodexConnections[sourceID]?.id == id else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
    }
    private struct ControlledMemoryTask {
        let connection: ExternalSessionCodexStdioConnection
        let threadID: ExternalSessionThreadID
        var turnID: ExternalSessionTurnID?
        let generation: UInt64
        let submissionEpoch: UInt64
    }
    private var controlledMemoryTasks: [ExternalSessionSourceID: ControlledMemoryTask] = [:]
    private struct ActiveCodexEventListener {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }
    private var activeCodexEventListeners: [ExternalSessionSourceID: ActiveCodexEventListener] = [:]
    // Reserve the subscription before any ledger actor suspension.
    private var pendingCodexEventSubscriptions: Set<ExternalSessionSourceID> = []
    /// A checkpoint identity is reusable only when the previous listener
    /// reached a clean EOF/disconnect.  This in-memory admission record keeps
    /// an honest UNKNOWN (or a bounded partial/RED stream) from being mistaken
    /// for a clean continuation after a later reconnect.  The runtime ledger
    /// remains the authority for event acceptance and late-result fencing.
    private var cleanCodexCheckpointIdentities: [ExternalSessionSourceID: ExternalAgentInvocationIdentity] = [:]

    enum ExternalSourceRegistrationError: Error {
        case appHostUnavailable
        case invalidDirectory
        case unsupportedSource
    }

    /// Existing production read-only projection consumer. Held weakly: BridgeStore
    /// owns the consumer, and this owner must not extend its lifetime.
    private weak var runtimeConsumer: TaskCenterControlConsumer?

    init(
        ledger: ExternalSessionAuthorizationLedgerV1 = ExternalSessionAuthorizationLedgerV1(),
        runtimeConsumer: TaskCenterControlConsumer? = nil
    ) {
        self.ledger = ledger
        self.runtimeConsumer = runtimeConsumer
    }

    /// Source identities this owner supervises, in a stable order.
    var supervisedSourceIDs: [ExternalSessionSourceID] {
        adapters.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func sourceLabel(for sourceID: ExternalSessionSourceID) -> String {
        selectedSourceLabels[sourceID] ?? sourceID.rawValue
    }

    struct ExternalMemoryCandidate: Identifiable {
        let sourceID: ExternalSessionSourceID
        let profileID: ExternalSessionProfileID
        let label: String
        let memorySourceID: String
        var id: String { memorySourceID }
    }

    /// Only an activated, registered external reader can be named in Settings.
    /// Its READ or CONTROL grant never supplies a memory submission grant.
    var externalMemoryCandidates: [ExternalMemoryCandidate] {
        selectedReaders.compactMap { sourceID, reader in
            guard reader.source.kind == .codex || reader.source.kind == .claudeCode,
                  adapters[sourceID]?.source.profileID == reader.source.profileID,
                  adapters[sourceID]?.source.kind == reader.source.kind,
                  adapters[sourceID]?.source.hostID == reader.source.hostID,
                  adapters[sourceID]?.source.capabilities.contains(.stream) == true else { return nil }
            return ExternalMemoryCandidate(
                sourceID: sourceID, profileID: reader.source.profileID,
                label: sourceLabel(for: sourceID),
                memorySourceID: Self.memorySourceID(sourceID, reader.source.profileID)
            )
        }.sorted { $0.memorySourceID < $1.memorySourceID }
    }

    func configureMemoryProposalConsumer(_ consumer: MemoryProposalConsumer) {
        memoryProposalConsumer = consumer
    }

    /// App-owned persistence only. Setting this path does not connect to or
    /// read an external source; a new task still requires a user action.
    func configureControlledMemoryRuntimeDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw ExternalSourceRegistrationError.invalidDirectory
        }
        controlledMemoryRuntimeDirectory = directory
    }

    var controlledMemorySourceIDs: [ExternalSessionSourceID] {
        selectedReaders.compactMap { sourceID, reader in
            reader.source.kind == .codex && selectedCodexHomes[sourceID] != nil ? sourceID : nil
        }.sorted { $0.rawValue < $1.rawValue }
    }

    func hasOwnedDynamicMemoryConnection(for sourceID: ExternalSessionSourceID) -> Bool {
        ownedDynamicConnections[sourceID] != nil
    }

    /// A caller retaining an owned runtime root can await this exact process
    /// generation's terminal receipt after revoke, before releasing that root.
    func ownedCodexTermination(sourceID: ExternalSessionSourceID) async -> ExternalSessionCodexStdioTermination? {
        if let connection = activeCodexConnections[sourceID] {
            return await connection.terminationCompletion()
        }
        return codexRetirements.soleWitness(sourceID)
    }

    func boundMemoryScope(for candidate: ExternalMemoryCandidate) -> MemoryScope? {
        externalMemoryScopes[candidate.sourceID]
    }

    func memoryCandidateSubmissionEnabled(for candidate: ExternalMemoryCandidate) throws -> Bool {
        try memoryCandidateSubmissionEpoch(for: candidate) != nil
    }

    private func memoryCandidateSubmissionEpoch(for candidate: ExternalMemoryCandidate) throws -> UInt64? {
        guard currentMemoryCandidate(candidate), let memoryProposalConsumer else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        return try memoryProposalConsumer.candidateSubmissionAuthorizations()
            .first { $0.sourceID == candidate.memorySourceID }
            .flatMap { $0.canSubmit ? $0.epoch : nil }
    }

    @discardableResult
    func setMemoryCandidateSubmission(
        for candidate: ExternalMemoryCandidate, within scope: MemoryScope?, enabled: Bool
    ) throws -> MemoryCandidateSubmissionAuthorization {
        guard currentMemoryCandidate(candidate), let memoryProposalConsumer else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        if enabled {
            guard let scope, scope.isValid else {
                throw ExternalMemoryProposalError.scopeMismatch
            }
            guard externalMemoryScopes[candidate.sourceID] == nil
                    || externalMemoryScopes[candidate.sourceID] == scope else {
                throw ExternalMemoryProposalError.scopeMismatch
            }
            // A grant can outlive this process, while the exact UI scope
            // binding is deliberately not guessed from a path or READ grant.
            // Rebinding an unbound old grant first invalidates its pending
            // epoch so an old scope cannot be approved under a new choice.
            if externalMemoryScopes[candidate.sourceID] == nil,
               try memoryProposalConsumer.candidateSubmissionAuthorizations()
                    .first(where: { $0.sourceID == candidate.memorySourceID })?.canSubmit == true {
                _ = try memoryProposalConsumer.revokeCandidateSubmission(
                    sourceID: candidate.memorySourceID,
                    reason: "Rebinding registered external source to explicit memory scope"
                )
            }
            // The user chose this exact internal scope in Settings. A source
            // cannot silently borrow a READ target or later selected scope.
            let authorization = try memoryProposalConsumer.grantCandidateSubmission(
                sourceID: candidate.memorySourceID,
                reason: "User enabled registered external source for exact memory scope"
            )
            externalMemoryScopes[candidate.sourceID] = scope
            return authorization
        }
        // Revocation targets the registered source's existing grant. A later
        // session selection (or no selected session) must not block it.
        let authorization = try memoryProposalConsumer.revokeCandidateSubmission(
            sourceID: candidate.memorySourceID,
            reason: "User revoked registered external memory source"
        )
        externalMemoryScopes[candidate.sourceID] = nil
        return authorization
    }

    private func currentMemoryCandidate(_ candidate: ExternalMemoryCandidate) -> Bool {
        externalMemoryCandidates.contains { $0.sourceID == candidate.sourceID
            && $0.profileID == candidate.profileID
            && $0.memorySourceID == candidate.memorySourceID }
    }

    private static func memorySourceID(
        _ sourceID: ExternalSessionSourceID, _ profileID: ExternalSessionProfileID
    ) -> String {
        let material = Data("\(sourceID.rawValue)|\(profileID.rawValue)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return "external-memory:\(digest)"
    }

    /// Production ingress for one explicit V2 tool frame delivered by the
    /// registered source. The existing adapter admits the event against its
    /// live read grant, attempt owner, connection generation and checkpoint.
    /// Only then may the independently granted memory source submit a pending
    /// candidate. No fact is activated here.
    func consumeMemoryProposalToolFrame(
        _ frame: Data,
        from candidate: ExternalMemoryCandidate,
        correlationID: String,
        attemptID: String,
        ownerID: String,
        connectionGeneration: UInt64,
        sequence: UInt64,
        sourceCursor: ExternalSessionCursorV1,
        readGrant: ExternalSessionReadGrantV1,
        expectedSubmissionEpoch: UInt64? = nil
    ) async throws -> MemoryProposalEnvelope {
        let event = try ExternalMemoryProposalToolEventV2.decode(frame)
        guard currentMemoryCandidate(candidate),
              let adapter = adapters[candidate.sourceID],
              let scope = externalMemoryScopes[candidate.sourceID], scope.isValid,
              let memoryProposalConsumer,
              connectionGeneration <= UInt64(Int.max),
              readGrant.sourceID == candidate.sourceID,
              readGrant.profileID == candidate.profileID else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        guard let submissionEpoch = try memoryCandidateSubmissionEpoch(for: candidate),
              expectedSubmissionEpoch.map({ $0 == submissionEpoch }) ?? true else {
            throw ExternalMemoryProposalError.sourceNotEnabled
        }
        let checkpoint = ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: event.sourceEventID),
            sourceID: candidate.sourceID,
            threadID: ExternalSessionThreadID(rawValue: event.threadID),
            turnID: ExternalSessionTurnID(rawValue: event.turnID),
            sequence: sequence,
            sourceCursor: sourceCursor,
            occurredAt: Date(), required: true, kind: .progress,
            payload: ExternalSessionRedactedPayloadV1(kind: "memoryProposal", summary: "显式记忆候选"),
            sourceRef: "memory-propose"
        )
        let acceptance = try await adapter.consumeExternalEvent(
            checkpoint,
            correlationID: correlationID, attemptID: attemptID,
            ownerID: ownerID, connectionGeneration: connectionGeneration,
            readGrant: readGrant
        )
        guard acceptance == .accepted else {
            throw ExternalMemoryProposalError.runtimeRejected(acceptance)
        }
        guard currentMemoryCandidate(candidate),
              externalMemoryScopes[candidate.sourceID] == scope,
              let currentEpoch = try memoryCandidateSubmissionEpoch(for: candidate),
              expectedSubmissionEpoch.map({ $0 == currentEpoch }) ?? true else {
            throw ExternalMemoryProposalError.sourceNotEnabled
        }
        let identity = "\(candidate.memorySourceID)|\(event.threadID)|\(event.turnID)|\(event.sourceEventID)"
        let proposalID = "external-\(MemoryStore.contentDigest(for: identity))"
        let sourceHash = MemoryStore.contentDigest(for: "\(identity)|\(event.factText)")
        let generation = Int(connectionGeneration)
        let provenance = MemoryWriteProvenanceInput(
            actorID: "registered:\(candidate.sourceID.rawValue)",
            runID: "\(correlationID):\(attemptID)",
            triggerID: event.sourceEventID,
            sourceID: candidate.memorySourceID
        )
        do {
            return try memoryProposalConsumer.submit(
                proposalID: proposalID, text: event.factText, within: scope,
                sourceRef: "memory://external/\(proposalID)",
                sourceHash: sourceHash, generation: generation,
                sourceID: candidate.memorySourceID,
                writeProvenance: provenance
            )
        } catch MemoryProposalConsumerError.duplicateProposal {
            // Only an identical current-epoch delivery is an idempotent retry.
            // A reused provider event ID with changed content stays a conflict.
            let currentAuthorization = try memoryProposalConsumer.candidateSubmissionAuthorizations()
                .first { $0.sourceID == candidate.memorySourceID }
            guard let existing = try memoryProposalConsumer.envelopes().first(where: {
                $0.proposal.proposalID == proposalID
            }), existing.text == event.factText,
                  existing.sourceHash == sourceHash,
                  existing.proposal.memoryScope == scope,
                  existing.sourceID == candidate.memorySourceID,
                  existing.submissionEpoch == currentAuthorization?.epoch,
                  existing.writeProvenance?.actorID == provenance.actorID,
                  existing.writeProvenance?.runID == provenance.runID,
                  existing.writeProvenance?.triggerID == provenance.triggerID,
                  existing.state != .revoked else {
                throw ExternalMemoryProposalError.duplicateConflict
            }
            return existing
        }
    }

    func hasConfiguredSyntheticCodexControl(for sourceID: ExternalSessionSourceID) -> Bool {
        syntheticCodexControl[sourceID] != nil
    }

    /// Admission occupies the same subscription slot before its listener Task exists.
    func hasActiveCodexEventListener(for sourceID: ExternalSessionSourceID) -> Bool {
        activeCodexEventListeners[sourceID] != nil || pendingCodexEventSubscriptions.contains(sourceID)
    }

    func configurableControlOperations(for sourceID: ExternalSessionSourceID) -> Set<ExternalSessionControlOperationV1> {
        if syntheticCodexControl[sourceID] != nil {
            return [.resume, .fork, .steer, .interrupt, .approve, .reject]
        }
        return supportedControlOperations(for: sourceID)
    }

    func configurableReadScopes(for sourceID: ExternalSessionSourceID) -> Set<ExternalSessionReadScopeV1> {
        if pendingReadRoots[sourceID] != nil { return [.metadata, .messages, .status] }
        return supportedReadScopes(for: sourceID)
    }

    func isReadRootPending(for sourceID: ExternalSessionSourceID) -> Bool {
        pendingReadRoots[sourceID] != nil
    }

    /// Field-profile injection only. This stores paths but neither launches a
    /// process nor touches either directory; activation requires a distinct
    /// live control grant and explicit user action in Task Center.
    func configureSyntheticCodexControl(
        sourceID: ExternalSessionSourceID,
        executableURL: URL,
        homeURL: URL,
        runtimeDirectory: URL
    ) throws {
        guard selectedReaders[sourceID]?.source.kind == .codex
                || pendingReadRoots[sourceID]?.kind == .codex,
              executableURL.isFileURL, homeURL.isFileURL, runtimeDirectory.isFileURL else {
            throw ExternalSourceRegistrationError.unsupportedSource
        }
        syntheticCodexControl[sourceID] = SyntheticCodexControlConfiguration(
            executableURL: executableURL,
            homeURL: homeURL,
            runtimeDirectory: runtimeDirectory
        )
    }

    func activateSyntheticCodexControl(
        sourceID: ExternalSessionSourceID,
        readGrant: ExternalSessionReadGrantV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws {
        try await withCodexConnectionAttempt(
            sourceID: sourceID, unavailable: ExternalSessionAppAdapterError.operationNotGranted(.resume)
        ) { id in
            try await self.activateSyntheticCodexControlAttempt(sourceID: sourceID,
                readGrant: readGrant, controlGrant: controlGrant, attemptID: id)
        }
    }

    private func activateSyntheticCodexControlAttempt(
        sourceID: ExternalSessionSourceID,
        readGrant: ExternalSessionReadGrantV1,
        controlGrant: ExternalSessionControlGrantV1,
        attemptID: UUID
    ) async throws {
        let issued = await ledger.authorizationSnapshot()
        guard let config = syntheticCodexControl[sourceID],
              let reader = selectedReaders[sourceID],
              issued.readGrants.contains(readGrant),
              issued.controlGrants.contains(controlGrant),
              readGrant.sourceID == sourceID,
              readGrant.profileID == reader.source.profileID,
              readGrant.scopes.contains(.status),
              readGrant.target.isSource(sourceID),
              readGrant.issuedAt <= Date(), Date() < readGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID,
                  profileID: readGrant.profileID,
                  revocationEpoch: readGrant.revocationEpoch
              ),
              controlGrant.sourceID == sourceID,
              controlGrant.profileID == reader.source.profileID,
              controlGrant.target.isThread,
              !controlGrant.operations.isEmpty,
              controlGrant.operations.isSubset(of: configurableControlOperations(for: sourceID)),
              activeCodexConnections[sourceID] == nil,
              controlGrant.issuedAt <= Date(), Date() < controlGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID,
                  profileID: controlGrant.profileID,
                  revocationEpoch: controlGrant.revocationEpoch
              ) else {
            throw ExternalSessionAppAdapterError.operationNotGranted(.resume)
        }
        try requireCodexConnectionAttempt(sourceID, id: attemptID)
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: config.executableURL,
            environment: ["CODEX_HOME": config.homeURL.path],
            workingDirectory: config.homeURL
        )
        pendingCodexConnections[sourceID]?.connection = connection
        var installedAdapter: ExternalSessionAppAdapter?
        do {
            try await connection.connect()
            guard await connection.isReady(),
                  let userAgent = await connection.handshakeUserAgent(),
                  userAgent.split(separator: " ").first == "miniscanvas/0.151.0" else {
                throw ExternalSourceRegistrationError.unsupportedSource
            }
            try requireCodexConnectionAttempt(sourceID, id: attemptID)
            let transport = ExternalSessionCodexJSONRPCControlTransport(
                connection: connection,
                sourceID: sourceID
            )
            let runtimeURL = config.runtimeDirectory
                .appendingPathComponent("\(sourceID.rawValue).json")
            let adapter = try registerConnectedCodexControl(
                sourceID: sourceID,
                transport: transport,
            verifiedCapabilities: [.resume, .fork, .steer, .interrupt, .stream, .approval],
                runtimePersistenceURL: runtimeURL
            )
            installedAdapter = adapter
            _ = try await adapter.connect(readGrant: readGrant)
            try requireCodexConnectionAttempt(sourceID, id: attemptID)
            guard adapters[sourceID]?.runtimeIdentity == adapter.runtimeIdentity else {
                throw ExternalSessionAppAdapterError.runtimeUnavailable
            }
            activeCodexConnections[sourceID] = connection
        } catch {
            await codexRetirements.retire(connection, sourceID: sourceID)
            if pendingCodexConnections[sourceID]?.id == attemptID,
               let installedAdapter,
               adapters[sourceID]?.runtimeIdentity == installedAdapter.runtimeIdentity {
                installedAdapter.retireRuntime()
                // Revocation/cancellation must not resurrect a writable reader.
                if !Task.isCancelled { _ = makeAdapter(implementation: reader) }
            }
            throw error
        }
    }

    /// The Task Center's explicit connect action is the only normal-mode
    /// factory for a dynamic-tool capable Codex process. A selected READ root
    /// or an old thread control grant never starts this process by itself.
    func connectOwnedCodexMemorySource(
        sourceID: ExternalSessionSourceID,
        executableURL: URL,
        statusReadGrant: ExternalSessionReadGrantV1
    ) async throws {
        try await withCodexConnectionAttempt(
            sourceID: sourceID, unavailable: ExternalMemoryProposalError.sourceUnavailable
        ) { id in
            try await self.connectOwnedCodexMemorySourceAttempt(sourceID: sourceID,
                executableURL: executableURL, statusReadGrant: statusReadGrant, attemptID: id)
        }
    }

    private func connectOwnedCodexMemorySourceAttempt(
        sourceID: ExternalSessionSourceID,
        executableURL: URL,
        statusReadGrant: ExternalSessionReadGrantV1,
        attemptID: UUID
    ) async throws {
        let issued = await ledger.authorizationSnapshot()
        guard let reader = selectedReaders[sourceID], reader.source.kind == .codex,
              let homeURL = selectedCodexHomes[sourceID],
              let runtimeDirectory = controlledMemoryRuntimeDirectory,
              memoryProposalConsumer != nil,
              activeCodexConnections[sourceID] == nil,
              executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path),
              issued.readGrants.contains(statusReadGrant),
              statusReadGrant.sourceID == sourceID,
              statusReadGrant.profileID == reader.source.profileID,
              statusReadGrant.scopes.contains(.status),
              statusReadGrant.target.isSource(sourceID),
              statusReadGrant.issuedAt <= Date(), Date() < statusReadGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID, profileID: reader.source.profileID,
                  revocationEpoch: statusReadGrant.revocationEpoch
              ) else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        try requireCodexConnectionAttempt(sourceID, id: attemptID)
        try FileManager.default.createDirectory(
            at: runtimeDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try requireCodexConnectionAttempt(sourceID, id: attemptID)
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: executableURL,
            environment: ["CODEX_HOME": homeURL.path], workingDirectory: homeURL,
            experimentalDynamicTools: true
        )
        pendingCodexConnections[sourceID]?.connection = connection
        var installedAdapter: ExternalSessionAppAdapter?
        do {
            try await connection.connect()
            guard await connection.isReady(),
                  let agent = await connection.handshakeUserAgent(),
                  agent.split(separator: " ").first == "miniscanvas/0.151.0" else {
                throw ExternalSourceRegistrationError.unsupportedSource
            }
            try requireCodexConnectionAttempt(sourceID, id: attemptID)
            let transport = ExternalSessionCodexJSONRPCControlTransport(
                connection: connection, sourceID: sourceID
            )
            let adapter = try registerConnectedCodexControl(
                sourceID: sourceID, transport: transport,
                verifiedCapabilities: [.stream],
                runtimePersistenceURL: runtimeDirectory.appendingPathComponent("\(sourceID.rawValue).json")
            )
            installedAdapter = adapter
            _ = try await adapter.connect(readGrant: statusReadGrant)
            try requireCodexConnectionAttempt(sourceID, id: attemptID)
            guard adapters[sourceID]?.runtimeIdentity == adapter.runtimeIdentity else {
                throw ExternalSessionAppAdapterError.runtimeUnavailable
            }
            activeCodexConnections[sourceID] = connection
            ownedDynamicConnections[sourceID] = connection
        } catch {
            await codexRetirements.retire(connection, sourceID: sourceID)
            if pendingCodexConnections[sourceID]?.id == attemptID,
               let installedAdapter,
               adapters[sourceID]?.runtimeIdentity == installedAdapter.runtimeIdentity {
                installedAdapter.retireRuntime()
                // Revocation/cancellation must not resurrect a writable reader.
                if !Task.isCancelled { _ = makeAdapter(implementation: reader) }
            }
            throw error
        }
    }

    struct ControlledMemoryTaskReceipt: Sendable {
        let sourceID: ExternalSessionSourceID
        let threadID: ExternalSessionThreadID
        let turnID: ExternalSessionTurnID
    }

    /// Starts one new thread with the pinned experimental function registered
    /// from birth. This method is invoked only by the user's confirmed Task
    /// Center action; resume and fork paths never call or inherit it.
    func startOwnedCodexMemoryTask(
        sourceID: ExternalSessionSourceID,
        workspaceURL: URL,
        prompt: String,
        eventsReadGrant: ExternalSessionReadGrantV1
    ) async throws -> ControlledMemoryTaskReceipt {
        let issued = await ledger.authorizationSnapshot()
        guard let connection = ownedDynamicConnections[sourceID],
              activeCodexConnections[sourceID] === connection,
              let adapter = adapters[sourceID],
              adapter.runtimeSnapshot.state == .connected,
              activeCodexEventListeners[sourceID] == nil,
              controlledMemoryTasks[sourceID] == nil,
              let candidate = externalMemoryCandidates.first(where: { $0.sourceID == sourceID }),
              externalMemoryScopes[sourceID]?.isValid == true,
              let submissionEpoch = try memoryCandidateSubmissionEpoch(for: candidate),
              issued.readGrants.contains(eventsReadGrant),
              eventsReadGrant.sourceID == sourceID,
              eventsReadGrant.profileID == candidate.profileID,
              eventsReadGrant.scopes.contains(.events),
              eventsReadGrant.target.isSource(sourceID),
              eventsReadGrant.issuedAt <= Date(), Date() < eventsReadGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID, profileID: candidate.profileID,
                  revocationEpoch: eventsReadGrant.revocationEpoch
              ),
              workspaceURL.isFileURL, workspaceURL.path.hasPrefix("/"),
              try workspaceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 8_192 else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        let tool: CodexJSONValue = .object([
            "type": .string("namespace"), "name": .string("miniscanvas"),
            "description": .string("MinisCanvas memory candidates requiring separate user approval"),
            "tools": .array([.object([
                "type": .string("function"), "name": .string("memory_propose"),
                "description": .string("Submit one factual memory candidate for later user review; this never activates memory"),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(["factText": .object([
                        "type": .string("string"), "maxLength": .integer(4096)
                    ])]),
                    "required": .array([.string("factText")]),
                    "additionalProperties": .bool(false)
                ])
            ])])
        ])
        // A timed-out request may already have created a remote thread.
        // Never retry this effect automatically on the same connection.
        let started = try await connection.request(method: "thread/start", params: [
            "cwd": .string(workspaceURL.path), "dynamicTools": .array([tool])
        ])
        guard let rawThreadID = started["thread"]?.objectValue?["id"]?.stringValue,
              !rawThreadID.isEmpty, rawThreadID.utf8.count <= 256 else {
            throw ExternalMemoryProposalError.sourceUnavailable
        }
        let threadID = ExternalSessionThreadID(rawValue: rawThreadID)
        controlledMemoryTasks[sourceID] = ControlledMemoryTask(
            connection: connection, threadID: threadID, turnID: nil,
            generation: adapter.runtimeSnapshot.generation,
            submissionEpoch: submissionEpoch
        )
        do {
            try await subscribeSyntheticCodexEvents(
                sourceID: sourceID, threadID: threadID, readGrant: eventsReadGrant,
                onToolCall: { [weak self] delivery in
                    await self?.consumeOwnedMemoryToolCall(
                        delivery, sourceID: sourceID, connection: connection
                    ) ?? false
                }
            )
            let turn = try await connection.request(method: "turn/start", params: [
                "threadId": .string(rawThreadID),
                "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])
            ])
            guard let rawTurnID = turn["turn"]?.objectValue?["id"]?.stringValue,
                  !rawTurnID.isEmpty, rawTurnID.utf8.count <= 256,
                  controlledMemoryTasks[sourceID]?.threadID == threadID else {
                throw ExternalMemoryProposalError.sourceUnavailable
            }
            let turnID = ExternalSessionTurnID(rawValue: rawTurnID)
            controlledMemoryTasks[sourceID]?.turnID = turnID
            return ControlledMemoryTaskReceipt(sourceID: sourceID, threadID: threadID, turnID: turnID)
        } catch {
            controlledMemoryTasks[sourceID] = nil
            if let listener = activeCodexEventListeners.removeValue(forKey: sourceID) {
                listener.task.cancel()
            }
            ownedDynamicConnections[sourceID] = nil
            activeCodexConnections[sourceID] = nil
            await codexRetirements.retire(connection, sourceID: sourceID)
            adapter.disconnect()
            throw error
        }
    }

    private func consumeOwnedMemoryToolCall(
        _ delivery: ExternalCodexToolCallDelivery,
        sourceID: ExternalSessionSourceID,
        connection: ExternalSessionCodexStdioConnection
    ) async -> Bool {
        guard let task = controlledMemoryTasks[sourceID],
              task.connection === connection,
              task.generation == delivery.connectionGeneration,
              let turnID = task.turnID,
              delivery.message.params["threadId"]?.stringValue == task.threadID.rawValue,
              delivery.message.params["turnId"]?.stringValue == turnID.rawValue,
              delivery.message.params["namespace"]?.stringValue == "miniscanvas",
              delivery.message.params["tool"]?.stringValue == "memory_propose",
              let callID = delivery.message.params["callId"]?.stringValue,
              let arguments = delivery.message.params["arguments"]?.objectValue,
              Set(arguments.keys) == Set(["factText"]),
              let factText = arguments["factText"]?.stringValue,
              let candidate = externalMemoryCandidates.first(where: { $0.sourceID == sourceID }) else {
            return false
        }
        let frame: [String: Any] = [
            "schemaVersion": 2, "type": "miniscanvas.memory.propose",
            "sourceEventID": callID, "threadID": task.threadID.rawValue,
            "turnID": turnID.rawValue, "factText": factText
        ]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: frame)
            _ = try await consumeMemoryProposalToolFrame(
                bytes, from: candidate,
                correlationID: delivery.correlationID, attemptID: delivery.attemptID,
                ownerID: delivery.ownerID,
                connectionGeneration: delivery.connectionGeneration,
                sequence: delivery.sequence, sourceCursor: delivery.sourceCursor,
                readGrant: delivery.readGrant,
                expectedSubmissionEpoch: task.submissionEpoch
            )
            return true
        } catch {
            return false
        }
    }

    /// One selected thread per runtime. The ready signal is emitted only
    /// after the Core notification subscriber exists; callers may then send
    /// control without losing the first event to a subscription race.
    func subscribeSyntheticCodexEvents(
        sourceID: ExternalSessionSourceID,
        threadID: ExternalSessionThreadID,
        readGrant: ExternalSessionReadGrantV1,
        onEvent: @escaping @Sendable (ExternalSessionEventV1) -> Void = { _ in },
        onToolCall: (@Sendable (ExternalCodexToolCallDelivery) async -> Bool)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard activeCodexEventListeners[sourceID] == nil,
              pendingCodexEventSubscriptions.insert(sourceID).inserted else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        defer { pendingCodexEventSubscriptions.remove(sourceID) }
        let issued = await ledger.authorizationSnapshot()
        guard activeCodexEventListeners[sourceID] == nil,
              let connection = activeCodexConnections[sourceID],
              let adapter = adapters[sourceID],
              adapter.source.capabilities.contains(.stream),
              let ownerID = adapter.runtimeSnapshot.ownerID,
              adapter.runtimeSnapshot.state == .connected,
              readGrant.sourceID == sourceID,
              issued.readGrants.contains(readGrant),
              readGrant.profileID == adapter.source.profileID,
              readGrant.scopes.contains(.events),
              readGrant.issuedAt <= Date(), Date() < readGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID,
                  profileID: readGrant.profileID,
                  revocationEpoch: readGrant.revocationEpoch
              ) else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        switch readGrant.target {
        case .source(let target) where target == sourceID: break
        case .project: break // App gate verifies thread membership on delivery.
        case .thread(let target) where target == threadID: break
        default: throw ExternalSessionAppAdapterError.targetMismatch
        }

        try Task.checkCancellation()
        let readiness = AsyncThrowingStream<Void, Error>.makeStream()
        let listenerID = UUID()
        let generation = adapter.runtimeSnapshot.generation
        let correlationID = "external-codex-\(sourceID.rawValue)"
        let checkpointIdentity = adapter.runtimeSnapshot.eventCheckpoint?.identity
        let reusableIdentity: ExternalAgentInvocationIdentity?
        if let checkpointIdentity,
           checkpointIdentity.isValid,
           checkpointIdentity.correlationID == correlationID,
           adapter.runtimeSnapshot.eventCheckpoint?.threadID == threadID,
           cleanCodexCheckpointIdentities[sourceID] == checkpointIdentity,
           !adapter.runtimeSnapshot.requiresSideEffectReconciliation {
            reusableIdentity = checkpointIdentity
        } else {
            reusableIdentity = nil
        }
        let attemptID = reusableIdentity?.attemptID ?? listenerID.uuidString
        let task = Task { [weak self] in
            do {
                try await adapter.streamCodexNotifications(
                    from: connection,
                    threadID: threadID,
                    correlationID: correlationID,
                    attemptID: attemptID,
                    ownerID: ownerID,
                    readGrant: readGrant,
                    onEvent: onEvent,
                    onSubscribed: { _ = readiness.continuation.yield(()) },
                    onToolCall: onToolCall
                )
                readiness.continuation.finish()
            } catch {
                readiness.continuation.finish(throwing: error)
            }
            if self?.activeCodexEventListeners[sourceID]?.id == listenerID,
               self?.activeCodexEventListeners[sourceID]?.generation == generation {
                let snapshot = adapter.runtimeSnapshot
                if !snapshot.requiresSideEffectReconciliation,
                   snapshot.state == .disconnected,
                   let checkpoint = snapshot.eventCheckpoint,
                   checkpoint.threadID == threadID,
                   checkpoint.identity == ExternalAgentInvocationIdentity(
                       correlationID: correlationID, attemptID: attemptID
                   ) {
                    // Only a clean stream EOF earns identity reuse.  UNKNOWN,
                    // partial and RED exits leave no reusable identity.
                    self?.cleanCodexCheckpointIdentities[sourceID] = checkpoint.identity
                } else {
                    self?.cleanCodexCheckpointIdentities[sourceID] = nil
                }
                // The stream already retires its runtime ledger on EOF/error.
                // Repeating disconnect here could downgrade an UNKNOWN state.
                // A subscriber may also stop while its process is healthy
                // (grant expiry or bounded-delta refusal); retain that lease.
                // Only a truly closed owned process releases the activation
                // slot. Recheck listener and connection after the actor await:
                // a late old listener cannot remove a new process lease.
                let connectionClosed = !(await connection.isReady())
                if connectionClosed,
                   self?.activeCodexEventListeners[sourceID]?.id == listenerID,
                   self?.activeCodexEventListeners[sourceID]?.generation == generation,
                   self?.activeCodexConnections[sourceID] === connection {
                    self?.activeCodexConnections[sourceID] = nil
                    await self?.codexRetirements.retire(connection, sourceID: sourceID)
                }
                if self?.activeCodexEventListeners[sourceID]?.id == listenerID,
                   self?.activeCodexEventListeners[sourceID]?.generation == generation {
                    self?.activeCodexEventListeners[sourceID] = nil
                }
            }
        }
        activeCodexEventListeners[sourceID] = ActiveCodexEventListener(
            id: listenerID, generation: generation, task: task
        )
        do {
            try await withTaskCancellationHandler {
                var iterator = readiness.stream.makeAsyncIterator()
                guard try await iterator.next() != nil,
                      activeCodexEventListeners[sourceID]?.id == listenerID else {
                    throw ExternalSessionAppAdapterError.runtimeUnavailable
                }
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
            }
        } catch {
            // A rejected admission never abandons the listener it created.
            task.cancel()
            await task.value
            if activeCodexEventListeners[sourceID]?.id == listenerID {
                activeCodexEventListeners[sourceID] = nil
            }
            throw error
        }
    }

    func respondToSyntheticCodexApproval(
        sourceID: ExternalSessionSourceID,
        decision: ExternalSessionControlOperationV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws {
        let issued = await ledger.authorizationSnapshot()
        guard decision == .approve || decision == .reject,
              issued.controlGrants.contains(controlGrant),
              activeCodexEventListeners[sourceID] != nil,
              let connection = activeCodexConnections[sourceID],
              let adapter = adapters[sourceID] else {
            throw ExternalSessionAppAdapterError.runtimeUnavailable
        }
        try await adapter.respondToCodexApproval(
            on: connection, decision: decision, controlGrant: controlGrant
        )
    }

    /// The real app supplies its host identity at launch. This does not inspect
    /// a Codex or Claude directory and does not register an external source.
    func configureExternalSourceRegistration(hostID: String) {
        externalHostID = hostID
    }

    /// Selecting a root registers an explicitly unavailable source and records
    /// its path without inspecting it. After a separately minted read grant,
    /// `activateSelectedReadRoot` builds the real implementation. Each choice
    /// receives a fresh source/profile pair so grants never cross directories.
    @discardableResult
    func registerSelectedReadRoot(
        kind: ExternalSessionSourceKindV1,
        rootURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> ExternalSessionSourceID {
        guard let hostID = externalHostID else {
            throw ExternalSourceRegistrationError.appHostUnavailable
        }
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw ExternalSourceRegistrationError.invalidDirectory
        }
        let requiredName: String
        switch kind {
        case .codex: requiredName = "sessions"
        case .claudeCode: requiredName = "projects"
        case .hermes, .other: throw ExternalSourceRegistrationError.unsupportedSource
        }
        guard rootURL.lastPathComponent == requiredName else {
            throw ExternalSourceRegistrationError.invalidDirectory
        }
        let sourceID = ExternalSessionSourceID(rawValue: "\(kind.rawValue)-\(UUID().uuidString)")
        let profileID = ExternalSessionProfileID(rawValue: UUID().uuidString)
        pendingReadRoots[sourceID] = PendingReadConfiguration(
            kind: kind, rootURL: rootURL, profileID: profileID, hostID: hostID
        )
        if kind == .codex { selectedCodexHomes[sourceID] = rootURL.deletingLastPathComponent() }
        selectedSourceLabels[sourceID] = "\(kind == .codex ? "Codex" : "Claude Code") · \(rootURL.path)"
        _ = makeAdapter(implementation: ExternalSessionPendingReadSource(source: ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: kind,
            adapterVersion: "pending-user-authorization",
            profileID: profileID,
            hostID: hostID,
            capabilities: [],
            authState: .unavailable
        )), clock: clock)
        return sourceID
    }

    @discardableResult
    func activateSelectedReadRoot(
        sourceID: ExternalSessionSourceID,
        readGrant: ExternalSessionReadGrantV1,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> ExternalSessionAppAdapter {
        let issued = await ledger.authorizationSnapshot()
        guard let configuration = pendingReadRoots[sourceID],
              issued.readGrants.contains(readGrant),
              readGrant.sourceID == sourceID,
              readGrant.profileID == configuration.profileID,
              readGrant.issuedAt <= clock(), clock() < readGrant.expiresAt,
              await ledger.isAuthorizationActive(
                  sourceID: sourceID,
                  profileID: configuration.profileID,
                  revocationEpoch: readGrant.revocationEpoch
              ) else {
            throw ExternalSessionAppAdapterError.grantRevoked
        }
        let implementation: any ExistingAgentSessionAdapter
        switch configuration.kind {
        case .codex:
            implementation = ExternalSessionCodexRolloutReadAdapter(
                sourceID: sourceID,
                profileID: configuration.profileID,
                hostID: configuration.hostID,
                rootURL: configuration.rootURL,
                authorizationLedger: ledger,
                clock: clock
            )
        case .claudeCode:
            implementation = ExternalSessionClaudeCodeReadAdapter(
                sourceID: sourceID,
                profileID: configuration.profileID,
                hostID: configuration.hostID,
                rootURL: configuration.rootURL,
                authorizationLedger: ledger,
                clock: clock
            )
        case .hermes, .other:
            throw ExternalSourceRegistrationError.unsupportedSource
        }
        guard implementation.source.authState == .authorized,
              !implementation.source.capabilities.isEmpty else {
            throw ExternalSessionAppAdapterError.sourceUnavailable
        }
        selectedReaders[sourceID] = implementation
        pendingReadRoots[sourceID] = nil
        return makeAdapter(implementation: implementation, clock: clock)
    }

    /// Called only after a separately configured Codex connection has
    /// completed its protocol/version handshake. The transport cannot be
    /// inferred from a read root or a read grant. The same source/profile and
    /// ledger are retained for both halves, so a read grant never becomes a
    /// control grant through registration.
    @discardableResult
    func registerConnectedCodexControl(
        sourceID: ExternalSessionSourceID,
        transport: any ExternalSessionControlTransportV1,
        verifiedCapabilities: Set<ExternalSessionCapabilityV1>,
        runtimePersistenceURL: URL?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> ExternalSessionAppAdapter {
        guard let reader = selectedReaders[sourceID], reader.source.kind == .codex else {
            throw ExternalSourceRegistrationError.unsupportedSource
        }
        let supported: Set<ExternalSessionCapabilityV1> = [.resume, .fork, .steer, .interrupt, .stream, .approval]
        guard !verifiedCapabilities.isEmpty,
              verifiedCapabilities.isSubset(of: supported) else {
            throw ExternalSourceRegistrationError.unsupportedSource
        }
        let original = reader.source
        let source = ExternalSessionSourceV1(
            sourceID: original.sourceID,
            kind: original.kind,
            adapterVersion: original.adapterVersion + "+codex-app-server-verified",
            profileID: original.profileID,
            hostID: original.hostID,
            capabilities: original.capabilities.union(verifiedCapabilities),
            authState: original.authState
        )
        let controller = ExternalSessionControlLedgerAdapter(
            source: source,
            ledger: ledger,
            clock: clock,
            transport: transport
        )
        return makeAdapter(
            implementation: ExternalSessionReadControlComposite(
                source: source,
                reader: reader,
                controller: controller
            ),
            clock: clock,
            runtimePersistenceURL: runtimePersistenceURL
        )
    }

    /// Read-only declaration from this composition's actual registrations.
    /// A one-shot CLI runner or a wire codec is not an existing-session adapter.
    struct SourceSupport: Identifiable {
        enum MissingPrerequisite: Equatable {
            case adapterNotRegistered
            case readAuthorizationRequired
            case sourceUnavailable
            case readOnlyAvailable
            case connectionHandshakeRequired
            case sideEffectReconciliationRequired
        }
        let kind: ExternalSessionSourceKindV1
        let registeredSourceIDs: [ExternalSessionSourceID]
        let declaredCapabilities: Set<ExternalSessionCapabilityV1>
        let missingPrerequisite: MissingPrerequisite?
        var id: String { kind.rawValue }
        var title: String {
            switch kind {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .hermes: "Hermes"
            case .other: "其他来源"
            }
        }
        var detail: String {
            switch missingPrerequisite {
            case .adapterNotRegistered:
                "尚未接入现有会话适配器；单次 CLI 执行不代表会话读取或控制支持"
            case .readAuthorizationRequired:
                "已选择会话目录，等待读取授权；尚未打开该目录中的会话"
            case .sourceUnavailable:
                "适配器来源不可用；请先恢复来源前置条件"
            case .readOnlyAvailable:
                "只读适配器已登记；读取范围由独立授权约束，控制尚未接入"
            case .sideEffectReconciliationRequired:
                "外部控制结果未知；请核对原操作，连接状态不代表副作用已确认"
            case .connectionHandshakeRequired:
                "已登记只读来源；读取需单独授权，尚未连接控制进程"
            case nil:
                "适配器状态握手已完成；操作仍需各自的有效授权"
            }
        }
    }

    func sourceSupport(for kind: ExternalSessionSourceKindV1) -> SourceSupport {
        let registered = adapters.values.filter { $0.source.kind == kind }
        let ready = registered.filter { $0.source.authState == .authorized }
        let missing: SourceSupport.MissingPrerequisite? = registered.isEmpty ? .adapterNotRegistered
            : ready.isEmpty ? (registered.allSatisfy { pendingReadRoots[$0.source.sourceID] != nil }
                ? .readAuthorizationRequired : .sourceUnavailable)
            : ready.allSatisfy { $0.runtimeSnapshot.requiresSideEffectReconciliation } ? .sideEffectReconciliationRequired
            : ready.allSatisfy { $0.source.capabilities.isDisjoint(with: [.resume, .fork, .steer, .interrupt, .approval]) } ? .readOnlyAvailable
            : ready.contains { $0.runtimeSnapshot.state == .connected } ? nil : .connectionHandshakeRequired
        return SourceSupport(kind: kind,
            registeredSourceIDs: registered.map { $0.source.sourceID }.sorted { $0.rawValue < $1.rawValue },
            declaredCapabilities: ready.reduce(into: []) { $0.formUnion($1.source.capabilities) },
            missingPrerequisite: missing)
    }

    var externalSourceSupport: [SourceSupport] {
        [.codex, .claudeCode, .hermes].map { sourceSupport(for: $0) }
    }

    // MARK: - Production adapter construction

    /// The only app-side construction of `ExternalSessionAppAdapter`.
    ///
    /// The ledger argument is non-optional on this path, so an adapter created
    /// here can never fall into the `nil`-ledger branch that skips revocation
    /// enforcement. When a runtime consumer is attached, the adapter's
    /// secret-free snapshot is published through it immediately, reusing the
    /// existing `bindExternalSessionRuntime` seam.
    func makeAdapter(
        implementation: any ExistingAgentSessionAdapter,
        clock: @escaping @Sendable () -> Date = { Date() },
        runtimePersistenceURL: URL? = nil
    ) -> ExternalSessionAppAdapter {
        adapters[implementation.source.sourceID]?.retireRuntime()
        let adapter = ExternalSessionAppAdapter.production(
            implementation: implementation,
            clock: clock,
            runtimePersistenceURL: runtimePersistenceURL,
            authorizationLedger: ledger
        )
        adapters[implementation.source.sourceID] = adapter
        runtimeConsumer?.bindExternalSessionRuntime(from: adapter)
        return adapter
    }

    func adapter(for sourceID: ExternalSessionSourceID) -> ExternalSessionAppAdapter? {
        adapters[sourceID]
    }

    func previewHumanResolution(sourceID: ExternalSessionSourceID,
        readGrant: ExternalSessionReadGrantV1, controlGrant: ExternalSessionControlGrantV1) async throws
        -> ExternalSessionHumanResolutionPreview {
        guard let adapter = adapters[sourceID] else { throw ExternalSessionAppAdapterError.sourceUnavailable }
        return try await adapter.previewHumanResolution(readGrant: readGrant, controlGrant: controlGrant)
    }

    func submitHumanResolution(sourceID: ExternalSessionSourceID,
        preview: ExternalSessionHumanResolutionPreview, decision: ExternalSessionHumanDecision,
        note: String, sourceReference: String,
        compensationProposal: ExternalSessionIndependentCompensationProposal? = nil,
        controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionHumanResolutionReceipt {
        guard let adapter = adapters[sourceID] else { throw ExternalSessionAppAdapterError.sourceUnavailable }
        let receipt = try await adapter.submitHumanResolution(preview: preview, decision: decision,
            note: note, sourceReference: sourceReference, compensationProposal: compensationProposal,
            controlGrant: controlGrant)
        // A human disposition follows an honest UNKNOWN.  Even when the
        // disposition permits new controls, the old checkpoint attempt must
        // not become a clean reconnect identity.
        cleanCodexCheckpointIdentities[sourceID] = nil
        if decision == .recordExternalHandlingAndAllowNewControls {
            let operationLease = codexRetirements.reserve(sourceID)
            defer { codexRetirements.release(sourceID, leaseID: operationLease) }
            // The durable local transaction already retired the old runtime
            // owner. Retire its transport lease without changing grants/epoch.
            let listener = activeCodexEventListeners.removeValue(forKey: sourceID)
            let connection = activeCodexConnections.removeValue(forKey: sourceID)
            ownedDynamicConnections[sourceID] = nil
            controlledMemoryTasks[sourceID] = nil
            listener?.task.cancel()
            if let listener { await listener.task.value }
            if let connection { await codexRetirements.retire(connection, sourceID: sourceID) }
        }
        return receipt
    }

    func performIndependentCompensation(sourceID: ExternalSessionSourceID,
        decisionReceiptID: String, proposal: ExternalSessionIndependentCompensationProposal,
        readGrant: ExternalSessionReadGrantV1, controlGrant: ExternalSessionControlGrantV1) async throws
        -> ExternalSessionIndependentCompensationReceipt {
        guard let adapter = adapters[sourceID] else { throw ExternalSessionAppAdapterError.sourceUnavailable }
        return try await adapter.performIndependentCompensation(decisionReceiptID: decisionReceiptID,
            proposal: proposal, readGrant: readGrant, controlGrant: controlGrant)
    }

    func supportedReadScopes(for sourceID: ExternalSessionSourceID) -> Set<ExternalSessionReadScopeV1> {
        guard let capabilities = adapters[sourceID]?.source.capabilities else { return [] }
        var scopes: Set<ExternalSessionReadScopeV1> = []
        if capabilities.contains(.readMetadata) { scopes.insert(.metadata) }
        if capabilities.contains(.readMessages) { scopes.insert(.messages) }
        if capabilities.contains(.status) { scopes.insert(.status) }
        if capabilities.contains(.stream) { scopes.insert(.events) }
        return scopes
    }

    func supportedControlOperations(for sourceID: ExternalSessionSourceID) -> Set<ExternalSessionControlOperationV1> {
        guard let capabilities = adapters[sourceID]?.source.capabilities else { return [] }
        var operations: Set<ExternalSessionControlOperationV1> = []
        if capabilities.contains(.resume) { operations.insert(.resume) }
        if capabilities.contains(.fork) { operations.insert(.fork) }
        if capabilities.contains(.steer) { operations.insert(.steer) }
        if capabilities.contains(.interrupt) { operations.insert(.interrupt) }
        if capabilities.contains(.approval) {
            operations.formUnion([.approve, .reject])
        }
        return operations
    }

    // MARK: - P3-EXT-01 read-side registration bridge

    /// Registration path for the read-side production consumer
    /// (`ExternalSessionLocalStoreAdapter`, already on head in MinisCore).
    ///
    /// This adds no semantics of its own: the identity labels and store are
    /// caller-supplied, the adapter is read-only by construction, and the
    /// ledger handed to it is this owner's single instance — so an
    /// implementation can never be registered against a private or absent
    /// ledger, and revocation stays wired into every read it serves.
    /// Registration itself mints no grant and performs no read.
    @discardableResult
    func registerLocalStoreReadSide(
        store: SessionStore,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        hostID: String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> ExternalSessionAppAdapter {
        makeAdapter(
            implementation: ExternalSessionLocalStoreAdapter(
                sourceID: sourceID,
                profileID: profileID,
                hostID: hostID,
                store: store,
                authorizationLedger: ledger,
                clock: clock
            ),
            clock: clock
        )
    }

    // MARK: - Grant issuance (delegation only)

    /// Mint a read grant for a source this owner supervises. The parameter list
    /// mirrors `ExternalSessionAuthorizationLedgerV1.issueReadGrant` verbatim:
    /// the caller still names the exact target and scope set, so nothing here
    /// broadens what a grant permits. An un-supervised `sourceID` is refused
    /// with the adapter's own `sourceMismatch` error rather than being minted
    /// and left for the adapter to reject later.
    func issueReadGrant(
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionReadTargetV1,
        scopes: Set<ExternalSessionReadScopeV1>,
        issuedAt: Date = Date(),
        lifetime: TimeInterval,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) async throws -> ExternalSessionReadGrantV1 {
        try requireSupervisedSource(sourceID)
        return try await ledger.issueReadGrant(
            authorizationID: authorizationID,
            sourceID: sourceID,
            profileID: profileID,
            target: target,
            scopes: scopes,
            issuedAt: issuedAt,
            lifetime: lifetime,
            parentConversationID: parentConversationID,
            parentTurnID: parentTurnID
        )
    }

    /// Mint a control grant. Same split as the contract enforces: read
    /// scopes and control operations are separate grants minted by separate
    /// calls, and this owner never combines or implies one from the other.
    func issueControlGrant(
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionControlTargetV1,
        operations: Set<ExternalSessionControlOperationV1>,
        issuedAt: Date = Date(),
        lifetime: TimeInterval,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) async throws -> ExternalSessionControlGrantV1 {
        try requireSupervisedSource(sourceID)
        return try await ledger.issueControlGrant(
            authorizationID: authorizationID,
            sourceID: sourceID,
            profileID: profileID,
            target: target,
            operations: operations,
            issuedAt: issuedAt,
            lifetime: lifetime,
            parentConversationID: parentConversationID,
            parentTurnID: parentTurnID
        )
    }

    /// Read the current epoch for one source/profile pair.
    func revocationEpoch(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) async -> UInt64 {
        await ledger.revocationEpoch(sourceID: sourceID, profileID: profileID)
    }

    /// Read-only ledger snapshot for the 077-A authorization-ledger display
    /// (authorized pairs, epochs, minted grants with target/scopes/expiry).
    /// Pure pass-through to `ExternalSessionAuthorizationLedgerV1
    /// .authorizationSnapshot()`: this owner adds no enumeration logic, and
    /// the snapshot decides nothing — `isAuthorizationActive` stays the only
    /// activity authority on every read and control path.
    func authorizationSnapshot() async -> ExternalSessionAuthorizationSnapshotV1 {
        await ledger.authorizationSnapshot()
    }

    /// Profile identity of a supervised source, when one is registered. The
    /// user-facing grant entry uses this so a mint names the exact
    /// `(source, profile)` pair the adapter enforces, never a hand-typed
    /// profile guess.
    func supervisedProfileID(for sourceID: ExternalSessionSourceID) -> ExternalSessionProfileID? {
        adapters[sourceID]?.source.profileID
    }

    /// Advance the revocation epoch for one exact `(sourceID, profileID)` pair.
    /// The Task Center revoke action calls this path; every older read and
    /// control grant for that pair then fails the ledger's equality check.
    @discardableResult
    func revoke(sourceID: ExternalSessionSourceID, profileID: ExternalSessionProfileID) async -> UInt64 {
        let operationLease = codexRetirements.reserve(sourceID)
        // Only this operation's reservation ends here. A HOLD connection has
        // its own retained lease, released solely by its exact true witness.
        defer { codexRetirements.release(sourceID, leaseID: operationLease) }
        let pending = pendingCodexConnections[sourceID]
        let retiringConnection = activeCodexConnections[sourceID]
        let retiringAdapter = adapters[sourceID]
        pending?.task.cancel()
        // Fence retained adapters before any await; old status callbacks and
        // even an explicit old connect cannot persist into a replacement.
        retiringAdapter?.retireRuntime()
        let epoch = await ledger.revoke(sourceID: sourceID, profileID: profileID)
        controlledMemoryTasks[sourceID] = nil
        ownedDynamicConnections[sourceID] = nil
        let retiringRuntime = retiringAdapter?.runtimeIdentity
        if let listener = activeCodexEventListeners.removeValue(forKey: sourceID) {
            listener.task.cancel()
            await listener.task.value
        }
        // A later legal activation can finish while the old listener joins.
        // A fresh adapter may exist before its connection is installed.
        if adapters[sourceID]?.runtimeIdentity == retiringRuntime,
           adapters[sourceID]?.runtimeSnapshot.ownerID != nil {
            // The listener may already have retired an active attempt as
            // UNKNOWN while joining. Do not downgrade that recovery barrier
            // to plain disconnected when the revoke cleanup runs afterward.
            adapters[sourceID]?.disconnect()
        }
        // Keep closing an unchanged old connection even if its adapter was
        // replaced; never remove or close a later connection's activation.
        if activeCodexConnections[sourceID] === retiringConnection,
           let connection = activeCodexConnections.removeValue(forKey: sourceID) {
            await codexRetirements.retire(connection, sourceID: sourceID)
        }
        // The revoke caller is outside the worker it joins. Holding the
        // retiring-source admission fence prevents a new generation until
        // child/reader/writer cleanup and this original worker really finish.
        if let connection = pending?.connection { await codexRetirements.retire(connection, sourceID: sourceID) }
        if let pending { _ = await pending.task.result }
        return epoch
    }

    /// Epoch revocation is not a claim that Process/FD custody ended.
    /// Callers can observe pending/HOLD without weakening admission gates.
    func codexRetirementStatus(sourceID: ExternalSessionSourceID) -> ExternalSessionCodexRetirementOverview {
        codexRetirements.overview(sourceID)
    }
    struct RevocationRetirementReport: Sendable {
        let epoch: UInt64
        let retirement: ExternalSessionCodexRetirementOverview
    }
    func revokeReportingRetirement(sourceID: ExternalSessionSourceID,
                                   profileID: ExternalSessionProfileID) async -> RevocationRetirementReport {
        let epoch = await revoke(sourceID: sourceID, profileID: profileID)
        return RevocationRetirementReport(epoch: epoch, retirement: codexRetirements.overview(sourceID))
    }

    private func requireSupervisedSource(_ sourceID: ExternalSessionSourceID) throws {
        guard adapters[sourceID] != nil else {
            throw ExternalSessionAppAdapterError.sourceMismatch
        }
    }
}
