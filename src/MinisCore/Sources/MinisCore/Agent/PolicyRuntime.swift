import Foundation

/// Maximum autonomy granted to an automatic task.
///
/// The level is a ceiling: a request may use a lower level, but never a
/// higher one. The executor still has to apply the capability-specific gate.
public enum AutonomyLevel: Int, Codable, Equatable, Hashable, Sendable, Comparable {
    case l0 = 0
    case l1 = 1
    case l2 = 2
    case l3 = 3

    public static func < (lhs: AutonomyLevel, rhs: AutonomyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable boundary for one automatic task.
public struct GoalEnvelope: Codable, Equatable, Sendable, Hashable {
    public let goalID: UUID
    public let scopeID: String
    public let allowedCapabilities: Set<String>
    public let fileRoots: [String]
    public let networkDomains: Set<String>
    public let budget: Int
    public let deadline: Date
    public let concurrencyLimit: Int
    public let autonomyLevel: AutonomyLevel
    public let creatorID: String?
    public let createdAt: Date

    /// `level` is an intentionally small compatibility alias for callers that
    /// use the runbook's L0-L3 terminology directly.
    public var level: AutonomyLevel { autonomyLevel }

    public init(
        goalID: UUID = UUID(),
        scopeID: String,
        allowedCapabilities: Set<String>,
        fileRoots: [String] = [],
        networkDomains: Set<String> = [],
        budget: Int,
        deadline: Date,
        concurrencyLimit: Int = 1,
        autonomyLevel: AutonomyLevel = .l0,
        creatorID: String? = nil,
        createdAt: Date = Date(),
        level: AutonomyLevel? = nil
    ) {
        self.goalID = goalID
        self.scopeID = scopeID
        self.allowedCapabilities = allowedCapabilities
        self.fileRoots = fileRoots
        self.networkDomains = networkDomains
        self.budget = budget
        self.deadline = deadline
        self.concurrencyLimit = concurrencyLimit
        self.autonomyLevel = level ?? autonomyLevel
        self.creatorID = creatorID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case goalID, scopeID, allowedCapabilities, fileRoots, networkDomains
        case budget, deadline, concurrencyLimit, autonomyLevel, creatorID, createdAt
    }

    // Older envelopes did not carry level/creator metadata. Decoding them as
    // L0 is the conservative compatibility behavior.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goalID = try container.decode(UUID.self, forKey: .goalID)
        scopeID = try container.decode(String.self, forKey: .scopeID)
        allowedCapabilities = try container.decode(Set<String>.self, forKey: .allowedCapabilities)
        fileRoots = try container.decode([String].self, forKey: .fileRoots)
        networkDomains = try container.decode(Set<String>.self, forKey: .networkDomains)
        budget = try container.decode(Int.self, forKey: .budget)
        deadline = try container.decode(Date.self, forKey: .deadline)
        concurrencyLimit = try container.decode(Int.self, forKey: .concurrencyLimit)
        autonomyLevel = try container.decodeIfPresent(AutonomyLevel.self, forKey: .autonomyLevel) ?? .l0
        creatorID = try container.decodeIfPresent(String.self, forKey: .creatorID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? deadline
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goalID, forKey: .goalID)
        try container.encode(scopeID, forKey: .scopeID)
        try container.encode(allowedCapabilities, forKey: .allowedCapabilities)
        try container.encode(fileRoots, forKey: .fileRoots)
        try container.encode(networkDomains, forKey: .networkDomains)
        try container.encode(budget, forKey: .budget)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(concurrencyLimit, forKey: .concurrencyLimit)
        try container.encode(autonomyLevel, forKey: .autonomyLevel)
        try container.encodeIfPresent(creatorID, forKey: .creatorID)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public enum PolicyRenewalError: Error, Equatable, Sendable {
    case notRenewable
    case beyondAbsoluteCap
}

public struct AutonomyLease: Codable, Equatable, Sendable, Hashable {
    public let leaseID: UUID
    public let goalID: UUID
    public let scopeID: String?
    public let issuedAt: Date
    public let expiresAt: Date
    public private(set) var revoked: Bool

    public init(
        leaseID: UUID = UUID(),
        goalID: UUID,
        scopeID: String? = nil,
        issuedAt: Date,
        expiresAt: Date,
        revoked: Bool = false
    ) {
        self.leaseID = leaseID
        self.goalID = goalID
        self.scopeID = scopeID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revoked = revoked
    }

    /// Explicitly extend a live lease, bounded by a caller-owned absolute cap.
    /// This never revives an expired/revoked lease and never changes its identity.
    public func renewed(until: Date, now: Date, maxUntil: Date) throws -> AutonomyLease {
        guard !revoked, now < expiresAt, expiresAt > issuedAt, now >= issuedAt else {
            throw PolicyRenewalError.notRenewable
        }
        guard until.timeIntervalSinceReferenceDate.isFinite,
              maxUntil.timeIntervalSinceReferenceDate.isFinite,
              until > expiresAt,
              until <= maxUntil else {
            throw until > maxUntil ? PolicyRenewalError.beyondAbsoluteCap : PolicyRenewalError.notRenewable
        }
        return AutonomyLease(
            leaseID: leaseID,
            goalID: goalID,
            scopeID: scopeID,
            issuedAt: issuedAt,
            expiresAt: until,
            revoked: false
        )
    }

    public mutating func revoke() {
        revoked = true
    }

    public func isValid(at date: Date, for goalID: UUID) -> Bool {
        isValid(at: date, for: goalID, scopeID: nil)
    }

    public func isValid(at date: Date, for goalID: UUID, scopeID: String?) -> Bool {
        !revoked
            && self.goalID == goalID
            && (self.scopeID == nil || self.scopeID == scopeID)
            && date >= issuedAt
            && date < expiresAt
            && issuedAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt > issuedAt
    }
}

public enum PolicyViolation: String, Error, Codable, Equatable, Sendable {
    case emptyScope
    case scopeMismatch
    case capabilityNotAllowed
    case invalidCapability
    case fileRootNotAllowed
    case invalidFileRoot
    case networkDomainNotAllowed
    case invalidNetworkDomain
    case budgetExceeded
    case invalidBudget
    case deadlineExceeded
    case requestDeadlineExceeded
    case leaseExpired
    case leaseRevoked
    case leaseGoalMismatch
    case invalidLease
    case autonomyLevelExceeded
    case concurrencyExceeded
    case invalidConcurrency
    case invalidRequestCost
    case invalidActiveTasks
}

/// Immutable policy facts injected by a production composition root.
///
/// The binding is deliberately separate from `AgentLoop`: a loop may be
/// reused as a value, while the concrete executor and its policy lease belong
/// to one execution boundary. `SecureAgentLoopFactory` installs this binding
/// before provider/tool work begins and `AgentLoop` carries the resulting
/// wrapper through every per-tool dispatch.
public struct PolicyRuntimeBinding: @unchecked Sendable {
    public let goal: GoalEnvelope
    public let lease: AutonomyLease?
    public let capabilityResolver: (any PolicyCapabilityResolving)?
    public let requestBuilder: (@Sendable (String, [String: Any]) -> PolicyRequest)?
    public let clock: @Sendable () -> Date

    public init(
        goal: GoalEnvelope,
        lease: AutonomyLease?,
        capabilityResolver: (any PolicyCapabilityResolving)? = nil,
        requestBuilder: (@Sendable (String, [String: Any]) -> PolicyRequest)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.goal = goal
        self.lease = lease
        self.capabilityResolver = capabilityResolver
        self.requestBuilder = requestBuilder
        self.clock = clock
    }

    /// Compose the existing policy-enforced executor without exposing a
    /// second policy implementation or allowing a caller to skip the gate.
    public func wrap(_ base: any ToolExecutor) -> PolicyEnforcedToolExecutor {
        PolicyEnforcedToolExecutor(
            base: base,
            goal: goal,
            lease: lease,
            capabilityResolver: capabilityResolver,
            requestBuilder: requestBuilder,
            clock: clock
        )
    }
}

public struct PolicyRequest: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let scopeID: String?
    public let filePath: String?
    public let networkDomain: String?
    public let estimatedCost: Int
    public let activeTasks: Int
    public let autonomyLevel: AutonomyLevel
    public let requestedUntil: Date?

    public init(
        capabilityID: String,
        scopeID: String? = nil,
        filePath: String? = nil,
        networkDomain: String? = nil,
        estimatedCost: Int = 0,
        activeTasks: Int = 0,
        autonomyLevel: AutonomyLevel = .l0,
        requestedUntil: Date? = nil
    ) {
        self.capabilityID = capabilityID
        self.scopeID = scopeID
        self.filePath = filePath
        self.networkDomain = networkDomain
        self.estimatedCost = estimatedCost
        self.activeTasks = activeTasks
        self.autonomyLevel = autonomyLevel
        self.requestedUntil = requestedUntil
    }
}

public func validatePolicy(
    goal: GoalEnvelope,
    lease: AutonomyLease,
    request: PolicyRequest,
    now: Date,
    spentBudget: Int
) -> Result<Void, PolicyViolation> {
    guard isNonEmpty(goal.scopeID) else { return .failure(.emptyScope) }
    if let requestScope = request.scopeID {
        guard isNonEmpty(requestScope) else { return .failure(.emptyScope) }
        guard requestScope == goal.scopeID else { return .failure(.scopeMismatch) }
    }
    guard goal.budget >= 0, spentBudget >= 0 else { return .failure(.invalidBudget) }
    guard goal.concurrencyLimit > 0 else { return .failure(.invalidConcurrency) }
    guard goal.deadline.timeIntervalSinceReferenceDate.isFinite,
          goal.createdAt.timeIntervalSinceReferenceDate.isFinite else {
        return .failure(.deadlineExceeded)
    }
    guard now < goal.deadline else { return .failure(.deadlineExceeded) }

    guard !lease.revoked else { return .failure(.leaseRevoked) }
    guard lease.goalID == goal.goalID else { return .failure(.leaseGoalMismatch) }
    guard let leaseScope = lease.scopeID, isNonEmpty(leaseScope) else {
        return .failure(.scopeMismatch)
    }
    guard leaseScope == goal.scopeID else { return .failure(.scopeMismatch) }
    guard lease.issuedAt.timeIntervalSinceReferenceDate.isFinite,
          lease.expiresAt.timeIntervalSinceReferenceDate.isFinite,
          lease.expiresAt > lease.issuedAt else {
        return .failure(.invalidLease)
    }
    guard lease.isValid(at: now, for: goal.goalID, scopeID: goal.scopeID) else {
        return .failure(.leaseExpired)
    }

    let capability = request.capabilityID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !capability.isEmpty else { return .failure(.invalidCapability) }
    guard goal.allowedCapabilities.contains(capability) else {
        // No registry is consulted here: absence from the immutable allowlist
        // is deliberately indistinguishable from an unknown capability.
        return .failure(.capabilityNotAllowed)
    }
    guard request.autonomyLevel <= goal.autonomyLevel else {
        return .failure(.autonomyLevelExceeded)
    }
    guard request.estimatedCost >= 0 else { return .failure(.invalidRequestCost) }
    guard request.activeTasks >= 0 else { return .failure(.invalidActiveTasks) }
    guard spentBudget <= goal.budget,
          request.estimatedCost <= goal.budget - spentBudget else {
        return .failure(.budgetExceeded)
    }
    guard request.activeTasks < goal.concurrencyLimit else {
        return .failure(.concurrencyExceeded)
    }
    if let requestedUntil = request.requestedUntil {
        guard requestedUntil.timeIntervalSinceReferenceDate.isFinite,
              now < requestedUntil,
              requestedUntil <= goal.deadline,
              requestedUntil <= lease.expiresAt else {
            return .failure(.requestDeadlineExceeded)
        }
    }

    if let path = request.filePath {
        guard PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: goal.fileRoots) else {
            return .failure(.fileRootNotAllowed)
        }
    }
    if let domain = request.networkDomain {
        guard validDomain(domain) else { return .failure(.invalidNetworkDomain) }
        guard goal.permitsNetworkDomain(domain) else {
            return .failure(.networkDomainNotAllowed)
        }
    }
    guard goal.fileRoots.allSatisfy(validRoot) else { return .failure(.invalidFileRoot) }
    guard goal.networkDomains.allSatisfy(validDomain) else { return .failure(.invalidNetworkDomain) }
    return .success(())
}

private func isNonEmpty(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func validRoot(_ root: String) -> Bool {
    guard let canonical = PolicyRuntimePathBoundary.canonicalPath(root) else { return false }
    return canonical != "/"
}

/// Shared filesystem boundary for PolicyRuntime and Composer authorization.
/// It resolves existing symlinks for both candidate and roots, rejects
/// traversal syntax, and never treats `/` as an allowed project root.
public enum PolicyRuntimePathBoundary {
    public static func isWithinRoots(path: String, roots: [String]) -> Bool {
        guard let canonicalPath = canonicalPath(path), !roots.isEmpty else { return false }
        return roots.compactMap(canonicalPath(_:)).contains { root in
            root != "/" && (canonicalPath == root || canonicalPath.hasPrefix(root + "/"))
        }
    }

    public static func canonicalPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), !trimmed.contains("\0") else {
            return nil
        }
        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = resolveRealPathPreservingMissingLeaf(
            URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL
        )
        let result = url.path
        guard result.hasPrefix("/"), !result.contains("\0") else { return nil }
        return result
    }

    /// Normalization- and case-folded form of a path, used ONLY to widen
    /// deny-list comparisons. macOS volumes are case-insensitive and
    /// Unicode-normalization-insensitive by default (APFS/HFS+), so two
    /// strings that differ only in letter case or NFC/NFD normal form name
    /// the SAME directory. A deny entry written as `/Root/Secret` must also
    /// block a request for `/root/secret/x` or `root/Ü…` in the other
    /// normal form, otherwise the deny table is trivially bypassable.
    /// Allow-side comparisons intentionally stay exact (unfolded) so this
    /// folding can never grant access; it can only deny more.
    public static func foldedForPathComparison(_ path: String) -> String {
        let precomposed = (path as NSString).precomposedStringWithCanonicalMapping
        return precomposed.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Deny-side containment check on already-canonical paths: true when
    /// `candidate` is `denied` itself or lives under it, comparing folded
    /// forms so case/normalization variants cannot slip past the deny table.
    public static func foldedCandidate(_ candidate: String, isWithin denied: String) -> Bool {
        let foldedCandidate = foldedForPathComparison(candidate)
        let foldedDenied = foldedForPathComparison(denied)
        guard !foldedDenied.isEmpty else { return false }
        if foldedCandidate == foldedDenied { return true }
        let prefix = foldedDenied.hasSuffix("/") ? foldedDenied : foldedDenied + "/"
        return foldedCandidate.hasPrefix(prefix)
    }

    /// Foundation resolves a symlink reliably when the complete path exists,
    /// but a write target commonly does not exist yet. Resolve the nearest
    /// existing ancestor first, then append the missing suffix so a symlinked
    /// directory cannot escape the policy root on a new-file write.
    private static func resolveRealPathPreservingMissingLeaf(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var cursor = url
        var missingSuffix: [String] = []
        while !fileManager.fileExists(atPath: cursor.path), cursor.path != "/" {
            missingSuffix.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath()
        for component in missingSuffix.reversed() {
            resolved.appendPathComponent(component, isDirectory: false)
        }
        return resolved.standardizedFileURL
    }
}

private func validDomain(_ value: String) -> Bool {
    let domain = normalizeDomain(value)
    guard !domain.isEmpty, domain.count <= 253 else { return false }
    guard !domain.contains("/"), !domain.contains(":"), !domain.contains("@"), !domain.contains(" ") else {
        return false
    }
    return domain.split(separator: ".").allSatisfy { label in
        !label.isEmpty && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

extension ProductionPolicyDefaults {
    /// Settings may persist a user ceiling only when the existing runtime
    /// can enforce every field. This check does not grant any capability.
    public var isValidUserConfiguration: Bool {
        budget >= 0
            && deadlineHorizon.isFinite
            && deadlineHorizon >= 0
            && deadline().timeIntervalSinceReferenceDate.isFinite
            && networkDomains.allSatisfy(validDomain)
    }
}

private func normalizeDomain(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
}

private func domainAllowed(_ candidate: String, by allowed: String) -> Bool {
    let candidate = normalizeDomain(candidate)
    let allowed = normalizeDomain(allowed)
    guard validDomain(candidate), validDomain(allowed) else { return false }
    return candidate == allowed || candidate.hasSuffix("." + allowed)
}


extension GoalEnvelope {
    func permitsNetworkDomain(_ domain: String) -> Bool {
        networkDomains.contains { domainAllowed(domain, by: $0) }
            || BrowserDomainApproval.shared.permits(host: domain)
    }
}
