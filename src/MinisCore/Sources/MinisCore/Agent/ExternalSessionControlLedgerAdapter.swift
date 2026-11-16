import Foundation

// MARK: - Control-side grant enforcement for the existing-session adapter seam

/// Control-side `ExistingAgentSessionAdapter` implementation for P3-EXT-02:
/// it validates every control call against an `ExternalSessionControlGrantV1`
/// and the composition-root `ExternalSessionAuthorizationLedgerV1` before any
/// transport I/O, and constructs/forwards the typed control request to an
/// injected transport.
///
/// Satisfies the seam comment at `ExternalSessionContract.swift:663-664`:
/// "Implementations and production registration belong to later stages and
/// must enforce the read/control capability separation before transport I/O."
/// Canonical row P3-EXT-02
/// (`docs/plans/三期合拢后-全量优化开发Canonical需求总表-20260827.md:352`)
/// still records "没有 app-server resume/fork/steer/interrupt/approval/recovery
/// 产品闭环"; this type supplies the control-side enforcement step and is
/// available only under a user-granted control authorization ("经用户单独授权
/// 后控制已有外部智能体", same row).
///
/// What this type owns:
/// - The full admission check list mirrored from the already-merged app-facing
///   gate `ExternalSessionAppAdapter.control` (`ExternalSessionAppAdapter.swift:917-934`):
///   source/profile identity, auth state, grant lifetime, operation capability
///   mapping, granted-operation set, thread target, idempotency key and the
///   revocation-epoch ledger check. Semantics are copied, not invented; each
///   check cites its head source below.
/// - Fail-closed ledger admission: a grant for a `(sourceID, profileID)` pair
///   this ledger never issued is never active
///   (`ExternalSessionAuthorizationLedger.swift:21-26`), and epochs are
///   compared with strict equality so stale *and* forged future epochs fail
///   the same way (`ExternalSessionAuthorizationLedger.swift:14-18`, `:74-87`).
///   Unlike the app gate's optional ledger parameter — which is fail-open at
///   the revocation check and therefore requires the `production(...)`
///   construction path (`ExternalSessionAppAdapter.swift:624-634`, `:652-672`) —
///   this adapter cannot be constructed without a ledger.
///
/// What this type deliberately does NOT own:
/// - Transport I/O. No app-server/等价双向事件 control channel type exists at
///   this base head (zero `app-server`/JSON-RPC-to-session matches under
///   `src/MinisCore/Sources/`; the only external-agent transport is the
///   one-shot CLI `ExternalAgentRunner`, `ExternalAgentBridge.swift:6-21`, as
///   also noted by `ExternalSessionContract.swift:7-10`). The injected
///   `ExternalSessionControlTransportV1` performs the external side effect
///   after admission and produces the receipt; this adapter never
///   hand-assembles receipt outcome or field semantics
///   (`ExternalSessionControlReceiptV1`, `ExternalSessionContract.swift:478-510`).
/// - Read capability. `listThreads`/`read`/`status` are refused outright, even
///   for a freshly minted valid `ExternalSessionReadGrantV1`: the control path
///   must never serve or bypass the read/control separation
///   (Canonical P3-EXT-02: "读取权与控制权分离";
///   `ExternalSessionContract.swift:663-664`). The read side belongs to the
///   separate P3-EXT-01 adapter.
/// - A `recovery` control operation. The Canonical row names recovery, but no
///   corresponding case exists in `ExternalSessionControlOperationV1`
///   (`ExternalSessionContract.swift:374-382`) or
///   `ExternalSessionCapabilityV1` (`ExternalSessionContract.swift:102-112`);
///   no semantics are invented here.
/// - Production registration. Wiring this adapter into the app composition
///   root touches `src/MinisCanvasApp/**` (`ExternalSessionAuthorizationComposition.swift:72-86`
///   is the single app-side `makeAdapter` slot); that write set is out of this
///   lane and no conformance exists in production yet
///   (`ExternalSessionAuthorizationComposition.swift:27-32`,
///   `MinisCanvasApp.swift:235-238`).
public protocol ExternalSessionControlTransportV1: Sendable {
    /// Performs the externally visible control side effect for an already
    /// admitted request and returns the factual receipt. Implementations are
    /// provider-specific adapters (Codex/Claude Code/Hermes) supplied by later
    /// lanes; nothing here may be enforced or softened by this seam.
    func send(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1
}

public struct ExternalSessionControlLedgerAdapter: ExistingAgentSessionAdapter {
    /// Mirrors the app-facing gate error surface
    /// (`ExternalSessionAppAdapterError`, `ExternalSessionAppAdapter.swift:937-950`)
    /// with one addition (`readNotServedByControlAdapter`) for the refusal
    /// documented on the read methods below.
    public enum Failure: Error, Equatable, Sendable {
        case sourceUnavailable
        case sourceMismatch
        case profileMismatch
        case grantNotYetValid
        case grantExpired
        case grantRevoked
        case targetMismatch
        case capabilityUnavailable(ExternalSessionCapabilityV1)
        case operationNotGranted(ExternalSessionControlOperationV1)
        case invalidRequest
        case readNotServedByControlAdapter
    }

    public let source: ExternalSessionSourceV1
    private let ledger: ExternalSessionAuthorizationLedgerV1
    private let clock: @Sendable () -> Date
    private let transport: any ExternalSessionControlTransportV1

    public init(
        source: ExternalSessionSourceV1,
        ledger: ExternalSessionAuthorizationLedgerV1,
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: any ExternalSessionControlTransportV1
    ) {
        self.source = source
        self.ledger = ledger
        self.clock = clock
        self.transport = transport
    }

    // MARK: Control path

    /// Admits the call only under a control grant that passes every check
    /// below, then hands the request to the transport. Enforcement is at
    /// admission only, copying the app gate's deliberate rule that a
    /// mid-flight revocation "must not hide what already happened to the
    /// external session" (`ExternalSessionAppAdapter.swift:928-931`).
    public func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        guard request.schemaVersion == ExternalSessionContractV1.schemaVersion,
              controlGrant.schemaVersion == ExternalSessionContractV1.schemaVersion,
              controlGrant.parentConversationID == request.parentConversationID,
              controlGrant.parentTurnID == request.parentTurnID else {
            throw Failure.invalidRequest
        }
        try validateControlGrant(controlGrant, request: request)
        guard request.sourceID == source.sourceID else {
            throw Failure.sourceMismatch  // ExternalSessionAppAdapter.swift:922-924
        }
        guard !request.idempotencyKey
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Failure.invalidRequest  // ExternalSessionAppAdapter.swift:925-927
        }
        try await enforceAuthorizationActive(controlGrant)
        try Task.checkCancellation()
        return try await transport.send(request: request, controlGrant: controlGrant)
    }

    /// Constructs a control request addressed at this adapter's own source,
    /// mirroring how the app gate builds its interrupt request in `cancel`
    /// (`ExternalSessionAppAdapter.swift:816-824`). The value type is the
    /// head contract's `ExternalSessionControlRequestV1`
    /// (`ExternalSessionContract.swift:438-476`); this adds no fields.
    public func makeControlRequest(
        threadID: ExternalSessionThreadID,
        operation: ExternalSessionControlOperationV1,
        expectedCursor: ExternalSessionCursorV1,
        turnID: ExternalSessionTurnID? = nil,
        expectedSequence: UInt64? = nil,
        idempotencyKey: String,
        boundedInput: String? = nil,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) -> ExternalSessionControlRequestV1 {
        ExternalSessionControlRequestV1(
            sourceID: source.sourceID,
            threadID: threadID,
            turnID: turnID,
            operation: operation,
            expectedCursor: expectedCursor,
            expectedSequence: expectedSequence,
            idempotencyKey: idempotencyKey,
            boundedInput: boundedInput,
            parentConversationID: parentConversationID,
            parentTurnID: parentTurnID
        )
    }

    // MARK: Read path — refused by the control adapter

    /// Refused: the control adapter never serves list capability, even with a
    /// freshly minted valid read grant ("读取权与控制权分离", Canonical
    /// P3-EXT-02; read/control capability separation required before transport
    /// I/O, `ExternalSessionContract.swift:663-664`).
    public func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        throw Failure.readNotServedByControlAdapter
    }

    /// Refused: see `listThreads`. A control-path object must not become a
    /// route to transcript data.
    public func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        throw Failure.readNotServedByControlAdapter
    }

    /// Refused: see `listThreads`.
    public func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        throw Failure.readNotServedByControlAdapter
    }
}

private extension ExternalSessionControlLedgerAdapter {
    /// Checks copied from `validateControlGrant`
    /// (`ExternalSessionAppAdapter.swift:1039-1060`), including its helper
    /// order: identity/lifetime first, then capability, then granted
    /// operations, then thread target.
    func validateControlGrant(
        _ grant: ExternalSessionControlGrantV1,
        request: ExternalSessionControlRequestV1
    ) throws {
        try validateSourceAndLifetime(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            issuedAt: grant.issuedAt,
            expiresAt: grant.expiresAt
        )
        guard source.capabilities.contains(capability(for: request.operation)) else {
            throw Failure.capabilityUnavailable(
                capability(for: request.operation)
            )  // ExternalSessionAppAdapter.swift:1049-1053
        }
        guard grant.operations.contains(request.operation) else {
            throw Failure.operationNotGranted(request.operation)  // :1054-1056
        }
        guard grant.target == .thread(request.threadID) else {
            throw Failure.targetMismatch  // :1057-1059
        }
    }

    /// Checks copied from `validateSourceAndLifetime`
    /// (`ExternalSessionAppAdapter.swift:1062-1084`), same order.
    func validateSourceAndLifetime(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        guard source.authState == .authorized else {
            throw Failure.sourceUnavailable  // ExternalSessionAppAdapter.swift:1068-1070
        }
        guard sourceID == source.sourceID else {
            throw Failure.sourceMismatch  // :1071-1073
        }
        guard profileID == source.profileID else {
            throw Failure.profileMismatch  // :1074-1076
        }
        let now = clock()
        guard issuedAt <= now else {
            throw Failure.grantNotYetValid  // :1077-1080
        }
        guard now < expiresAt else {
            throw Failure.grantExpired  // :1081-1083
        }
    }

    /// Operation→capability mapping copied verbatim from the app gate
    /// (`ExternalSessionAppAdapter.swift:1118-1126`). approve/reject/
    /// provideInput all map to `.approval`
    /// (`ExternalSessionControlOperationV1`, `ExternalSessionContract.swift:374-382`).
    func capability(
        for operation: ExternalSessionControlOperationV1
    ) -> ExternalSessionCapabilityV1 {
        switch operation {
        case .resume: return .resume
        case .fork: return .fork
        case .steer: return .steer
        case .interrupt: return .interrupt
        case .approve, .reject, .provideInput: return .approval
        }
    }

    /// The single ledger authority: strict-equality epoch check against the
    /// exact `(sourceID, profileID)` pair, where a pair this ledger never
    /// issued is never active (`ExternalSessionAuthorizationLedger.swift:74-87`,
    /// fail-open prevention rationale at `:21-26`). Covers not-issued,
    /// revoked and forged-epoch grants alike. The app-gate overload for control
    /// grants is `enforceAuthorizationActive(_:)`
    /// (`ExternalSessionAppAdapter.swift:983-989`); here the ledger is a
    /// required dependency, so the fail-open `nil` branch
    /// (`ExternalSessionAppAdapter.swift:960-965`) cannot be reproduced.
    func enforceAuthorizationActive(_ grant: ExternalSessionControlGrantV1) async throws {
        guard await ledger.isAuthorizationActive(
            sourceID: grant.sourceID,
            profileID: grant.profileID,
            revocationEpoch: grant.revocationEpoch
        ) else {
            throw Failure.grantRevoked
        }
    }
}
