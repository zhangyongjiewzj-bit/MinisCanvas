import Foundation

// MARK: - P3-MEDIA-01 media capability gate
//
// Single source of truth for per-model media capability enforcement. Before this
// module, `ModelCapabilities.supportedModalities` was declared (LLMTypes.swift)
// but read by zero product site: SVG folded into the raster image channel in the
// UI, and provider message assembly attached every media part unconditionally —
// the recorded LUNA defect (standard PNG passed, then the SVG part polluted the
// following turns) is exactly that mismatch.
//
// Contract (acceptance element 「capability gate + 失败隔离」):
// 1. PURE FUNCTION. `decide(mimeType:capabilities:)` depends only on its inputs —
//    no I/O, no clock, no global state — so restart / compact / model-switch
//    replays of the same stored message produce byte-identical gate outcomes.
// 2. FAIL-CLOSED. Unclassifiable payloads and vector images are rejected for
//    every model, no matter how generous the declared modality set.
// 3. FAILURE ISOLATION. A rejected part is replaced by a deterministic text
//    note at assembly time; the remaining parts and the message body still
//    reach the model unchanged, and no rejected binary is ever (re-)emitted on
//    a later turn, which is what stops the historical one-bad-part-poisons-
//    the-conversation defect.
// This module never mutates stored history — ChatStore/session persistence keep
// the original bytes for the UI; enforcement lives on the wire-assembly edge.

/// Classification of a media payload by its wire MIME type. The gate's decision
/// is a function of `(kind, capabilities)`, and kind is a pure function of the
/// MIME type — so the whole decision is a pure function.
public enum MediaPartKind: String, Sendable, Hashable {
    /// Raster image formats the chat wire formats actually accept
    /// (`image/png`, `image/jpeg`, `image/webp`, …).
    case rasterImage
    /// Vector image (`image/svg+xml`). No chat provider accepts SVG as a native
    /// image data part; sending it is the recorded pollution defect. Always
    /// rejected — capability-independent.
    case vectorImage
    /// `application/pdf` document part (requires `.pdfInput`).
    case pdf
    /// Audio payload (requires `.audioInput`).
    case audio
    /// Video payload (requires `.videoInput`).
    case video
    /// Anything not classifiable as a model-input medium. Rejected fail-closed.
    case unclassifiable

    /// Total, deterministic MIME classification for gate purposes.
    public static func classify(mimeType: String) -> MediaPartKind {
        // Normalize: drop parameters ("; charset=…"), trim, lowercase.
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch normalized {
        case "image/svg+xml", "image/svg-xml", "text/svg+xml":
            return .vectorImage
        case "application/pdf", "application/x-pdf":
            return .pdf
        default:
            break
        }
        if normalized.hasPrefix("image/") { return .rasterImage }
        if normalized.hasPrefix("audio/") { return .audio }
        if normalized.hasPrefix("video/") { return .video }
        return .unclassifiable
    }

    /// The input modality bit a model must declare to receive this kind.
    /// `nil` means no declared capability admits it (vector images and
    /// unclassifiable payloads reject in the first stage).
    public var requiredInputModality: ModelModality? {
        switch self {
        case .rasterImage: return .imageInput
        case .pdf: return .pdfInput
        case .audio: return .audioInput
        case .video: return .videoInput
        case .vectorImage, .unclassifiable: return nil
        }
    }

    /// Human/model-visible label of the medium, used in rejection notes.
    public var inputLabel: String {
        switch self {
        case .rasterImage: return "image"
        case .vectorImage: return "SVG image"
        case .pdf: return "PDF"
        case .audio: return "audio"
        case .video: return "video"
        case .unclassifiable: return "attachment"
        }
    }
}

/// Gate verdict for one media part.
public enum MediaGateDecision: Sendable, Hashable {
    case allowed(kind: MediaPartKind)
    case rejected(kind: MediaPartKind, reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// The capability gate. Every entry point is a pure function; wiring sites in
/// `OpenAICompatibleProvider` (chat-completions wire assembly) and
/// `AgentProvider` (agent inline-image assembly) call it per part.
public enum MediaCapabilityGate {

    /// Decide whether a media part may be attached, given the model's declared
    /// capabilities (`ModelCapabilities.supportedModalities` — the first
    /// product read site of that field).
    ///
    /// Rules, in order:
    /// 1. Vector image (`image/svg+xml`) → rejected for every model.
    /// 2. Unclassifiable MIME → rejected fail-closed.
    /// 3. Otherwise, the part's `requiredInputModality` must be contained in
    ///    the capability set, else rejected.
    public static func decide(mimeType: String, capabilities: ModelCapabilities) -> MediaGateDecision {
        let kind = MediaPartKind.classify(mimeType: mimeType)
        guard let required = kind.requiredInputModality else {
            let reason: String
            switch kind {
            case .vectorImage:
                reason = "SVG is vector media — no chat provider accepts it as a native image part; convert it to PNG or JPEG before sending."
            default:
                reason = "payload could not be classified as a model input medium."
            }
            return .rejected(kind: kind, reason: reason)
        }
        guard capabilities.supportedModalities.contains(required) else {
            return .rejected(kind: kind, reason: "the selected model does not declare \(kind.inputLabel) input capability.")
        }
        return .allowed(kind: kind)
    }

    /// Deterministic text replacement for a rejected part. Assembly sites inject
    /// this as a plain text part in place of the rejected binary part so the
    /// model knows why an announced attachment is missing — while the rest of
    /// the message goes through untouched (failure isolation).
    public static func rejectionNote(mimeType: String, reason: String) -> String {
        "[media-gate] An attachment (\(mimeType)) was rejected by the model capability gate and was NOT sent: \(reason) The rest of this message was delivered unchanged; earlier turns are unaffected."
    }

    /// One-shot helper used by every assembly site: note for a rejected decision.
    public static func rejectionNote(for decision: MediaGateDecision, mimeType: String) -> String? {
        guard case .rejected(_, let reason) = decision else { return nil }
        return rejectionNote(mimeType: mimeType, reason: reason)
    }
}
