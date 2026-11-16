import Foundation

/// Immutable audit fact for one skill candidate considered by injection.
public struct SkillInjectionReceipt: Codable, Equatable, Sendable {
    public let receiptID: UUID
    /// A stable, credential-free identity for the request that led to this
    /// candidate being considered. The raw request is never retained.
    public let requestFingerprint: String
    public let skillID: String
    public let version: String
    public let contentHash: String
    /// Stable source revision identity carried into the injection audit
    /// record. It contains no path or executable source data.
    public let sourceIdentity: String
    /// Explicit lifecycle projection for this candidate.
    public let state: SkillEnablementState
    public let matchedTerms: [String]
    public let injectedCharacters: Int
    /// The character budget that applied to this candidate.
    public let budget: Int
    public let omittedReason: String?
    /// Generation and session bind a receipt to the current chat projection.
    public let generation: Int
    public let sessionID: String?

    public var request: String { requestFingerprint }
    public var requestID: String { requestFingerprint }
    public var skillHash: String { contentHash }
    public var characterBudget: Int { budget }
    public var skipReason: String? { omittedReason }

    public init(
        receiptID: UUID = UUID(),
        skillID: String,
        version: String,
        contentHash: String,
        sourceIdentity: String? = nil,
        matchedTerms: [String],
        injectedCharacters: Int,
        omittedReason: String? = nil,
        requestFingerprint: String? = nil,
        budget: Int? = nil,
        state: SkillEnablementState? = nil,
        generation: Int = 0,
        sessionID: String? = nil
    ) {
        self.receiptID = receiptID
        self.requestFingerprint = requestFingerprint.flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.stableRequestFingerprint(forMatchedTerms: matchedTerms)
        self.skillID = skillID
        self.version = version
        self.contentHash = contentHash
        self.sourceIdentity = sourceIdentity ?? Self.expectedSourceIdentity(skillID: skillID, contentHash: contentHash)
        self.state = state ?? Self.defaultState(omittedReason: omittedReason, injectedCharacters: injectedCharacters)
        self.matchedTerms = matchedTerms
        self.injectedCharacters = injectedCharacters
        self.budget = max(budget ?? injectedCharacters, injectedCharacters)
        self.omittedReason = omittedReason
        self.generation = generation
        self.sessionID = sessionID
    }

    /// Creates a receipt whose request identity is derived without retaining
    /// the user's raw message.
    public init(
        receiptID: UUID = UUID(),
        request: String,
        skillID: String,
        version: String,
        contentHash: String,
        matchedTerms: [String],
        injectedCharacters: Int,
        budget: Int,
        omittedReason: String? = nil,
        sourceIdentity: String? = nil,
        state: SkillEnablementState? = nil,
        generation: Int = 0,
        sessionID: String? = nil
    ) {
        self.init(
            receiptID: receiptID,
            skillID: skillID,
            version: version,
            contentHash: contentHash,
            sourceIdentity: sourceIdentity,
            matchedTerms: matchedTerms,
            injectedCharacters: injectedCharacters,
            omittedReason: omittedReason,
            requestFingerprint: Self.stableRequestFingerprint(for: request),
            budget: budget,
            state: state,
            generation: generation,
            sessionID: sessionID
        )
    }

    public static func stableRequestFingerprint(for request: String) -> String {
        SkillManifest.hash(request)
    }

    public static func expectedSourceIdentity(skillID: String, contentHash: String) -> String {
        "skill:\(skillID)@\(contentHash)"
    }

    private static func defaultState(
        omittedReason: String?,
        injectedCharacters: Int
    ) -> SkillEnablementState {
        if omittedReason != nil { return .rejected }
        return injectedCharacters > 0 ? .active : .pending
    }

    /// True when the value-only receipt still points at its declared source.
    public var hasValidProvenance: Bool {
        sourceIdentity == Self.expectedSourceIdentity(skillID: skillID, contentHash: contentHash)
            && (contentHash.isEmpty || Self.isValidContentHash(contentHash))
    }

    public func matchesSource(skillID: String, contentHash: String) -> Bool {
        self.skillID == skillID
            && self.contentHash == contentHash
            && (contentHash.isEmpty || Self.isValidContentHash(contentHash))
            && sourceIdentity == Self.expectedSourceIdentity(skillID: skillID, contentHash: contentHash)
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func stableRequestFingerprint(forMatchedTerms terms: [String]) -> String {
        stableRequestFingerprint(for: terms.sorted().joined(separator: "\u{1F}"))
    }

    /// Rebinds a legacy injector receipt to the immutable session projection.
    /// Only the non-sensitive request hash and projection identity are added.
    public func bound(
        requestFingerprint: String,
        budget: Int,
        sessionID: String,
        generation: Int
    ) -> SkillInjectionReceipt {
        SkillInjectionReceipt(
            receiptID: receiptID,
            skillID: skillID,
            version: version,
            contentHash: contentHash,
            sourceIdentity: sourceIdentity,
            matchedTerms: matchedTerms,
            injectedCharacters: injectedCharacters,
            omittedReason: omittedReason,
            requestFingerprint: requestFingerprint,
            budget: budget,
            state: state,
            generation: generation,
            sessionID: sessionID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID, requestFingerprint, skillID, version, contentHash, sourceIdentity, state
        case matchedTerms, injectedCharacters, budget, omittedReason
        case generation, sessionID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let skillID = try values.decode(String.self, forKey: .skillID)
        let version = try values.decode(String.self, forKey: .version)
        let contentHash = try values.decode(String.self, forKey: .contentHash)
        let matchedTerms = try values.decode([String].self, forKey: .matchedTerms)
        let injectedCharacters = try values.decode(Int.self, forKey: .injectedCharacters)
        self.init(
            receiptID: try values.decodeIfPresent(UUID.self, forKey: .receiptID) ?? UUID(),
            skillID: skillID,
            version: version,
            contentHash: contentHash,
            sourceIdentity: try values.decodeIfPresent(String.self, forKey: .sourceIdentity),
            matchedTerms: matchedTerms,
            injectedCharacters: injectedCharacters,
            omittedReason: try values.decodeIfPresent(String.self, forKey: .omittedReason),
            requestFingerprint: try values.decodeIfPresent(String.self, forKey: .requestFingerprint),
            budget: try values.decodeIfPresent(Int.self, forKey: .budget) ?? injectedCharacters,
            state: try values.decodeIfPresent(SkillEnablementState.self, forKey: .state),
            generation: try values.decodeIfPresent(Int.self, forKey: .generation) ?? 0,
            sessionID: try values.decodeIfPresent(String.self, forKey: .sessionID)
        )
    }
}

/// The prompt fragment and its per-candidate audit facts.
public struct SkillInjectionResult: Equatable, Sendable {
    public let fragment: String?
    public let receipts: [SkillInjectionReceipt]

    public init(fragment: String?, receipts: [SkillInjectionReceipt]) {
        self.fragment = fragment
        self.receipts = receipts
    }
}
