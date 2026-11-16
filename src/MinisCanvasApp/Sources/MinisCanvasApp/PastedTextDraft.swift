import Foundation

struct PastedTextDraft: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var text: String
    var source: Source
    var kind: Kind

    enum Source: String, Codable, Equatable, Sendable {
        case pasteboard
        case typing
    }

    enum Kind: String, Codable, Equatable, Sendable {
        case reference
        case instruction
    }

    typealias Semantic = Kind
    typealias Role = Kind

    init(
        id: UUID,
        text: String,
        source: Source,
        kind: Kind = .reference
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.kind = kind
    }

    init(
        id: UUID,
        text: String,
        source: Source,
        semantic: Semantic
    ) {
        self.init(id: id, text: text, source: source, kind: semantic)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case source
        case kind
        case semantic
        case role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        source = try container.decode(Source.self, forKey: .source)
        // Pre-kind capsules remain references; aliases keep staged persisted
        // payloads readable while the semantic name converges.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? container.decodeIfPresent(Kind.self, forKey: .semantic)
            ?? container.decodeIfPresent(Kind.self, forKey: .role)
            ?? .reference
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
    }

    var semantic: Semantic {
        get { kind }
        set { kind = newValue }
    }

    var role: Role {
        get { kind }
        set { kind = newValue }
    }

    var isReference: Bool { kind == .reference }
    var isInstruction: Bool { kind == .instruction }

    var characterCount: Int {
        text.unicodeScalars.count
    }

    var lineCount: Int {
        PastedTextPolicy.lineCount(in: text)
    }
}

/// Session-owned transcript projection for a sent reference paste.
/// The model still receives the full material, while the transcript keeps it
/// bounded until the user explicitly expands the card.
struct PastedTextReferenceCard: Codable, Equatable, Sendable, Identifiable {
    static let previewScalarLimit = 240

    let id: UUID
    let sessionID: UUID
    let instruction: String
    let material: String
    let kind: PastedTextDraft.Kind
    let preview: String
    let characterCount: Int
    let lineCount: Int
    var isExpanded: Bool

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, instruction, material, kind, isExpanded
    }

    init(
        id: UUID,
        sessionID: UUID,
        instruction: String = "",
        material: String,
        kind: PastedTextDraft.Kind = .reference,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        self.material = material
        self.kind = kind
        self.preview = String(
            String.UnicodeScalarView(material.unicodeScalars.prefix(Self.previewScalarLimit))
        )
        self.characterCount = material.unicodeScalars.count
        self.lineCount = PastedTextPolicy.lineCount(in: material)
        self.isExpanded = isExpanded
    }

    /// Rebuild derived presentation fields from the persisted material so a
    /// stale preview/count payload cannot change a session-owned card.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            instruction: try container.decodeIfPresent(String.self, forKey: .instruction) ?? "",
            material: try container.decode(String.self, forKey: .material),
            kind: try container.decodeIfPresent(PastedTextDraft.Kind.self, forKey: .kind) ?? .reference,
            isExpanded: try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(material, forKey: .material)
        try container.encode(kind, forKey: .kind)
        try container.encode(isExpanded, forKey: .isExpanded)
    }

    var renderedMaterial: String { isExpanded ? material : preview }

    var stateLabel: String { isExpanded ? "资料已展开" : "资料已收起" }

    @discardableResult
    mutating func toggleExpanded(expectedSessionID: UUID) -> Bool {
        guard expectedSessionID == sessionID else { return false }
        isExpanded.toggle()
        return true
    }
}

struct PastedTextSubmissionSnapshot: Equatable, Sendable {
    let capsuleID: UUID
    let sessionID: UUID
    let text: String
    let kind: PastedTextDraft.Kind
    let referenceCard: PastedTextReferenceCard?

    init(
        capsuleID: UUID,
        sessionID: UUID,
        text: String,
        kind: PastedTextDraft.Kind = .reference,
        referenceCard: PastedTextReferenceCard? = nil
    ) {
        self.capsuleID = capsuleID
        self.sessionID = sessionID
        self.text = text
        self.kind = kind
        self.referenceCard = referenceCard
    }

    init(
        capsuleID: UUID,
        sessionID: UUID,
        body: String,
        pastedText: PastedTextDraft
    ) {
        self.init(
            capsuleID: capsuleID,
            sessionID: sessionID,
            text: ComposerPayload.merge(body: body, pastedText: pastedText),
            kind: pastedText.kind,
            referenceCard: !pastedText.text.isEmpty
                ? PastedTextReferenceCard(
                    id: capsuleID,
                    sessionID: sessionID,
                    instruction: body,
                    material: pastedText.text,
                    kind: pastedText.kind
                )
                : nil
        )
    }

    var fullText: String { text }
    var isReference: Bool { kind == .reference }
    var isInstruction: Bool { kind == .instruction }
}

struct PastedTextSummary: Equatable, Sendable {
    let characterCount: Int
    let lineCount: Int
    let preview: String
}

enum PastedTextPolicy {
    static let scalarThreshold = 2_000
    static let lineThreshold = 12
    static let lineScalarThreshold = 800
    static let previewScalarLimit = 40

    static func shouldCollapsePastedText(_ text: String) -> Bool {
        shouldCollapse(text, source: .pasteboard)
    }

    static func shouldCollapse(_ draft: PastedTextDraft) -> Bool {
        shouldCollapse(draft.text, source: draft.source)
    }

    static func shouldCollapse(_ text: String, source: PastedTextDraft.Source) -> Bool {
        guard source == .pasteboard else { return false }

        let scalarCount = text.unicodeScalars.count
        if scalarCount > scalarThreshold {
            return true
        }

        return newlineCount(in: text) >= lineThreshold && scalarCount > lineScalarThreshold
    }

    static func intentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        guard let pastedText, pastedText.kind == .instruction else {
            return body
        }
        return ComposerPayload.merge(body: body, pastedText: pastedText)
    }

    static func commandInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        intentInput(body: body, pastedText: pastedText)
    }

    static func sessionReadIntentInput(
        body: String,
        pastedText: PastedTextDraft?
    ) -> String {
        intentInput(body: body, pastedText: pastedText)
    }

    static func summary(
        for text: String,
        previewLimit: Int = previewScalarLimit
    ) -> PastedTextSummary {
        let limit = min(previewScalarLimit, max(0, previewLimit))
        let previewScalars = text.unicodeScalars.prefix(limit)
        return PastedTextSummary(
            characterCount: text.unicodeScalars.count,
            lineCount: lineCount(in: text),
            preview: String(String.UnicodeScalarView(previewScalars))
        )
    }

    fileprivate static func lineCount(in text: String) -> Int {
        newlineCount(in: text) + 1
    }

    private static func newlineCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 10 {
                count += 1
            }
        }
    }
}

enum ComposerPayload {
    static let pastedTextSeparator = "\n\n[Pasted text]\n"
    static let pastedInstructionSeparator = "\n\n[Pasted instruction]\n"

    static func merge(body: String, pastedText: String?) -> String {
        guard let pastedText, !pastedText.isEmpty else {
            return body
        }
        guard !body.isEmpty else {
            return pastedText
        }
        return body + pastedTextSeparator + pastedText
    }

    static func merge(body: String, pastedText: PastedTextDraft?) -> String {
        guard let pastedText, !pastedText.text.isEmpty else {
            return body
        }
        guard !body.isEmpty else {
            return pastedText.text
        }
        let separator = pastedText.kind == .instruction
            ? pastedInstructionSeparator
            : pastedTextSeparator
        return body + separator + pastedText.text
    }
}
