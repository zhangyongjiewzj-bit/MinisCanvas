import Foundation
import Testing
@testable import MinisCore

// MARK: - P3-MEDIA-01 media capability gate tests
//
// Covers the canonical row's acceptance elements that are code-decidable:
// capability gate (classification + modality decision), SVG isolation, and
// failure isolation at the OpenAI-compatible wire assembly and the agent
// inline-image choke point. Expected state at delivery: UNVERIFIED-RUNTIME
// (ordinary DEV lanes do not run swift test; PKG/L06 compile and execute).

private let visionCaps = ModelCapabilities(supportedModalities: .vision, supportedAuth: [.apiKey])
private let textOnlyCaps = ModelCapabilities(supportedModalities: .textOnly, supportedAuth: [.apiKey])
private let fullMultimodalCaps = ModelCapabilities(supportedModalities: .fullMultimodalInput, supportedAuth: [.apiKey])

@Suite("MediaCapabilityGate classification")
struct MediaPartClassificationTests {

    @Test func rasterMIMEsAreRasterImage() {
        for mime in ["image/png", "image/jpeg", "image/webp", "image/gif", "image/heic", "image/bmp", "image/tiff"] {
            #expect(MediaPartKind.classify(mimeType: mime) == .rasterImage, "misclassified \(mime)")
        }
    }

    @Test func svgIsVectorNotRaster() {
        // The LUNA defect class: SVG folded into the raster image channel.
        #expect(MediaPartKind.classify(mimeType: "image/svg+xml") == .vectorImage)
        #expect(MediaPartKind.classify(mimeType: "IMAGE/SVG+XML") == .vectorImage)
        #expect(MediaPartKind.classify(mimeType: "image/svg+xml; charset=utf-8") == .vectorImage)
    }

    @Test func documentAudioVideoAndUnknownClassify() {
        #expect(MediaPartKind.classify(mimeType: "application/pdf") == .pdf)
        #expect(MediaPartKind.classify(mimeType: "audio/wav") == .audio)
        #expect(MediaPartKind.classify(mimeType: "video/mp4") == .video)
        #expect(MediaPartKind.classify(mimeType: "application/octet-stream") == .unclassifiable)
        #expect(MediaPartKind.classify(mimeType: "") == .unclassifiable)
    }

    @Test func requiredModalityIsTotal() {
        #expect(MediaPartKind.rasterImage.requiredInputModality == .imageInput)
        #expect(MediaPartKind.pdf.requiredInputModality == .pdfInput)
        #expect(MediaPartKind.audio.requiredInputModality == .audioInput)
        #expect(MediaPartKind.video.requiredInputModality == .videoInput)
        #expect(MediaPartKind.vectorImage.requiredInputModality == nil)
        #expect(MediaPartKind.unclassifiable.requiredInputModality == nil)
    }
}

@Suite("MediaCapabilityGate decision")
struct MediaGateDecisionTests {

    @Test func visionModelAdmitsRasterAndPDFButNotAudioVideo() {
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: visionCaps).isAllowed)
        #expect(MediaCapabilityGate.decide(mimeType: "image/jpeg", capabilities: visionCaps).isAllowed)
        #expect(MediaCapabilityGate.decide(mimeType: "application/pdf", capabilities: visionCaps).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "audio/wav", capabilities: visionCaps).isAllowed)
        #expect(!MediaCapabilityGate.decide(mimeType: "video/mp4", capabilities: visionCaps).isAllowed)
    }

    @Test func svgRejectedForEveryCapabilityIncludingFullMultimodal() {
        // Capability-independent rejection: no chat provider accepts an SVG
        // data part, so even the most generous modality set must reject it.
        #expect(MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: fullMultimodalCaps).isAllowed == false)
        #expect(MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: visionCaps).isAllowed == false)
        if case .rejected(let kind, _) = MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: fullMultimodalCaps) {
            #expect(kind == .vectorImage)
        } else {
            Issue.record("SVG must be rejected")
        }
    }

    @Test func textOnlyModelRejectsAllMedia() {
        for mime in ["image/png", "application/pdf", "audio/wav", "video/mp4"] {
            #expect(MediaCapabilityGate.decide(mimeType: mime, capabilities: textOnlyCaps).isAllowed == false, "\(mime) must reject on textOnly")
        }
    }

    @Test func fullMultimodalAdmitsDeclaredInputModalities() {
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: fullMultimodalCaps).isAllowed)
        #expect(MediaCapabilityGate.decide(mimeType: "audio/wav", capabilities: fullMultimodalCaps).isAllowed)
        #expect(MediaCapabilityGate.decide(mimeType: "video/mp4", capabilities: fullMultimodalCaps).isAllowed)
    }

    @Test func unclassifiablePayloadFailsClosed() {
        #expect(MediaCapabilityGate.decide(mimeType: "application/octet-stream", capabilities: fullMultimodalCaps).isAllowed == false)
    }

    @Test func decisionIsPureAndDeterministic() {
        // Same inputs → same outputs (restart / compact / model-switch replay).
        let a = MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: visionCaps)
        let b = MediaCapabilityGate.decide(mimeType: "image/svg+xml", capabilities: visionCaps)
        #expect(a == b)
        let noteA = MediaCapabilityGate.rejectionNote(mimeType: "image/svg+xml", reason: "r")
        let noteB = MediaCapabilityGate.rejectionNote(mimeType: "image/svg+xml", reason: "r")
        #expect(noteA == noteB)
    }

    @Test func modelCapabilityLookupFeedsGate() {
        // The gate reads ModelCapabilities.supportedModalities via the model's
        // own lookup, honoring per-model overrides (the field's first read site).
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: LLMModel.deepSeekChat.capabilities).isAllowed == false)
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: LLMModel.qwen3VLPlus.capabilities).isAllowed)
        let forcedTextOnly = LLMModel.claudeSonnet5.withModalityOverride(.textOnly)
        #expect(MediaCapabilityGate.decide(mimeType: "image/png", capabilities: forcedTextOnly.capabilities).isAllowed == false)
    }
}

@Suite("OpenAI-compatible gated assembly (failure isolation)")
struct OpenAIGatedAssemblyTests {

    private func partType(_ part: [String: Any]) -> String { part["type"] as? String ?? "" }
    private func textOf(_ part: [String: Any]) -> String { part["text"] as? String ?? "" }
    /// Ordered `type` sequence of a content array — pins *position*, not just membership.
    private func partTypes(_ parts: [[String: Any]]?) -> [String] { (parts ?? []).map { $0["type"] as? String ?? "" } }
    /// Ordered text payload of a content array ("" for non-text parts).
    private func partTexts(_ parts: [[String: Any]]?) -> [String] { (parts ?? []).map { $0["text"] as? String ?? "" } }
    /// Ordered image payload of a content array ("" for non-image parts) — pins the
    /// admitted bytes themselves against replay drift, not just the part's type.
    private func partImageURLs(_ parts: [[String: Any]]?) -> [String] {
        (parts ?? []).map { ($0["image_url"] as? [String: Any])?["url"] as? String ?? "" }
    }

    @Test func svgRejectedRasterSurvivesInSameMessage() throws {
        let png = LLMMessage.ImageAttachment(mimeType: "image/png", data: try MediaPayloadFixtures589.png())
        let svg = LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: Data("<svg/>".utf8))
        let msg = LLMMessage(role: .user, content: "compare these", images: [svg, png])
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: visionCaps)
        let parts = dict["content"] as? [[String: Any]]
        #expect(parts?.count == 3)  // note + png + text — rejected part never drops siblings
        #expect(partType(parts?[1] ?? [:]) == "image_url")
        let pngURL = (parts?[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(pngURL?.hasPrefix("data:image/png;base64,") ?? false)
        #expect(partType(parts?[0] ?? [:]) == "text")
        // Bound to a local: `#expect` expands a receiver that itself contains
        // optional chaining into `Testing.__checkFunctionCall(_, calling: { $0?.contains($1) })`,
        // and optional chaining is illegal on the non-optional String textOf returns.
        // The asserted predicate (part 0's text carries the gate note) is unchanged.
        let gateNoteText = textOf(parts?[0] ?? [:])
        #expect(gateNoteText.contains("[media-gate]"))
        // The SVG bytes must never ride the wire — also on every later replay.
        #expect(!gateNoteText.contains("<svg/>"))
    }

    @Test func audioPartGatedByDeclaredAudioInput() {
        let audio = LLMMessage.AudioAttachment(format: "wav", base64Data: MediaPayloadFixtures589.wav.base64EncodedString())
        let msg = LLMMessage(role: .user, content: "transcribe", audios: [audio])
        let gatedOnVision = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: visionCaps)
        let parts = gatedOnVision["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(partType(parts?[0] ?? [:]) == "text")
        // Same hoisting reason as svgRejectedRasterSurvivesInSameMessage.
        let gateNoteText = textOf(parts?[0] ?? [:])
        #expect(gateNoteText.contains("[media-gate]"))
        let gatedOnMultimodal = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: fullMultimodalCaps)
        let allowedParts = gatedOnMultimodal["content"] as? [[String: Any]]
        #expect(partType(allowedParts?[0] ?? [:]) == "input_audio")
    }

    @Test func allMediaRejectedStillDeliversTextOnlyRequest() {
        let svg = LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: Data("<svg/>".utf8))
        let msg = LLMMessage(role: .user, content: "hello", images: [svg])
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: visionCaps)
        let parts = dict["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(textOf(parts?[1] ?? [:]) == "hello")  // body intact (failure isolation)
    }

    // PART-ORDER CONTRACT (proven from source, not from an observed index):
    // `OpenAICompatibleProvider.openAIMessageDict` builds the content array with ONE
    // sequential append loop over the declared attachments —
    //   OpenAICompatibleProvider.swift:426 `var parts: [[String: Any]] = []`
    //   OpenAICompatibleProvider.swift:427 `for img in msg.images` loop
    //   OpenAICompatibleProvider.swift:433 `parts.append(["type": "text", "text": note])` (rejected → note IN that attachment's slot)
    //   OpenAICompatibleProvider.swift:437-440 `parts.append(["type": "image_url", …])` (allowed → stays in its slot)
    //   OpenAICompatibleProvider.swift:442-456 same shape for `msg.audios`
    //   OpenAICompatibleProvider.swift:457-459 the message body text is appended LAST
    // and `LLMMessage.init` stores `images`/`audios` verbatim (LLMTypes.swift:528-536),
    // so attachment DECLARATION ORDER is preserved: a rejection note is never hoisted
    // to index 0. There is no dictionary/Set iteration in this path, hence nothing
    // incidental — the order is a deterministic function of declaration order, and the
    // agent-side gate agrees (AgentProvider.swift:653-686 appends per part).
    // This test therefore pins BOTH declaration orders and the note's text content.
    @Test func modelSwitchReplaysSameHistoryWithSameGateOutcome() throws {
        let png = LLMMessage.ImageAttachment(mimeType: "image/png", data: try MediaPayloadFixtures589.png())
        let svg = LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: Data("<svg/>".utf8))
        // Declaration order A: [png, svg] — the png is declared FIRST, so on a vision
        // model the image_url part occupies slot 0 and the svg note slot 1.
        let msg = LLMMessage(role: .user, content: "t", images: [png, svg])
        // Vision → textOnly switch: png gets gated out too, svg stays rejected;
        // both runs are pure re-derivations from the same stored message.
        let visionRun = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: visionCaps)
        let textRun = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: textOnlyCaps)
        let visionParts = visionRun["content"] as? [[String: Any]]
        let textParts = textRun["content"] as? [[String: Any]]
        // Failure isolation: neither attachment is dropped — 2 media slots + body.
        #expect(visionParts?.count == 3)
        #expect(textParts?.count == 3)
        #expect(partType(visionParts?[0] ?? [:]) == "image_url") // png kept in its declared slot
        #expect(partType(visionParts?[1] ?? [:]) == "text")      // svg note occupies the svg slot
        #expect(partType(visionParts?[2] ?? [:]) == "text")      // body text appended last
        #expect(partType(textParts?[0] ?? [:]) == "text")        // png now rejected, note in slot 0
        #expect(partType(textParts?[1] ?? [:]) == "text")         // svg note still in slot 1
        // Which slot holds WHICH note is pinned by MIME, not position alone.
        let visionSVGNote = textOf(visionParts?[1] ?? [:])
        #expect(visionSVGNote.contains("[media-gate]"))
        #expect(visionSVGNote.contains("image/svg+xml"))
        #expect(!visionSVGNote.contains("<svg/>"))  // rejected bytes never ride the wire
        let textPNGNote = textOf(textParts?[0] ?? [:])
        #expect(textPNGNote.contains("[media-gate]"))
        #expect(textPNGNote.contains("image/png"))
        let textSVGNote = textOf(textParts?[1] ?? [:])
        #expect(textSVGNote.contains("[media-gate]"))
        #expect(textSVGNote.contains("image/svg+xml"))
        // Body intact on both models (failure isolation, not truncation).
        #expect(textOf(visionParts?[2] ?? [:]) == "t")
        #expect(textOf(textParts?[2] ?? [:]) == "t")
        // The one part the vision model admits carries the real png bytes.
        // Bound to a non-optional local (same macro-hygiene reason as
        // svgRejectedRasterSurvivesInSameMessage above).
        let admittedPNG = ((visionParts?[0]["image_url"] as? [String: Any])?["url"] as? String) ?? ""
        #expect(admittedPNG.hasPrefix("data:image/png;base64,"))
        #expect(partImageURLs(textParts) == ["", "", ""])  // textOnly emits no image part at all

        // Declaration order B: [svg, png] — the mirror case. Same gate decisions,
        // each note in the slot of the attachment it replaces.
        let msgB = LLMMessage(role: .user, content: "t", images: [svg, png])
        let visionRunB = OpenAICompatibleProvider.openAIMessageDict(msgB, mediaCapabilities: visionCaps)
        let textRunB = OpenAICompatibleProvider.openAIMessageDict(msgB, mediaCapabilities: textOnlyCaps)
        let visionPartsB = visionRunB["content"] as? [[String: Any]]
        let textPartsB = textRunB["content"] as? [[String: Any]]
        #expect(visionPartsB?.count == 3)
        #expect(textPartsB?.count == 3)
        #expect(partTypes(visionPartsB) == ["text", "image_url", "text"])
        #expect(partTypes(textPartsB) == ["text", "text", "text"])
        #expect(partImageURLs(visionPartsB) == ["", admittedPNG, ""])  // same png, moved slot
        let visionSVGNoteB = textOf(visionPartsB?[0] ?? [:])
        #expect(visionSVGNoteB == visionSVGNote)  // note text is a pure function of (mime, caps)
        #expect(textOf(textPartsB?[0] ?? [:]) == textSVGNote)
        #expect(textOf(textPartsB?[1] ?? [:]) == textPNGNote)

        // Deterministic replay: same inputs, byte-equal gate outcome (this is the
        // restart / compact / model-switch matrix requirement). The original pinned
        // only the part count; the ordered type/text/image sequences are now pinned
        // too, and switching vision → textOnly → vision must reproduce the first
        // vision run exactly.
        let replay = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: textOnlyCaps)
        let replayParts = replay["content"] as? [[String: Any]]
        #expect(
            (replay["content"] as? [[String: Any]])?.count == textParts?.count
        )
        #expect(partTypes(replayParts) == partTypes(textParts))
        #expect(partTexts(replayParts) == partTexts(textParts))
        #expect(partImageURLs(replayParts) == partImageURLs(textParts))
        let switchedBack = OpenAICompatibleProvider.openAIMessageDict(msg, mediaCapabilities: visionCaps)
        let switchedBackParts = switchedBack["content"] as? [[String: Any]]
        #expect(partTypes(switchedBackParts) == partTypes(visionParts))
        #expect(partTexts(switchedBackParts) == partTexts(visionParts))
        #expect(partImageURLs(switchedBackParts) == partImageURLs(visionParts))
    }

    @Test func ungatedLegacyShapeIsPinnedForNilCapabilities() {
        // Pins that the defaulted parameter (nil) keeps the historical
        // serialization exactly — existing single-arg tests must not weaken.
        let png = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data([0x89]))
        let msg = LLMMessage(role: .user, content: "x", images: [png])
        let legacy = OpenAICompatibleProvider.openAIMessageDict(msg)
        let parts = legacy["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(partType(parts?[0] ?? [:]) == "image_url")
    }
}

@Suite("Agent inline-media gate (AgentProvider)")
struct AgentInlineMediaGateTests {

    @Test func imageDataSVGReplacedWithNoteRasterKept() throws {
        let pngPart = AgentContentPart.imageData(data: try MediaPayloadFixtures589.png(), mimeType: "image/png")
        let svgPart = AgentContentPart.imageData(data: Data("<svg/>".utf8), mimeType: "image/svg+xml")
        let message = AgentMessage(role: .user, parts: [.text("look"), svgPart, pngPart])
        let gated = message.gatingInlineMedia(for: visionCaps)
        #expect(gated.role == .user)
        #expect(gated.parts.count == 3)
        if case .text(let t) = gated.parts[1] {
            #expect(t.contains("[media-gate]"))
        } else {
            Issue.record("rejected SVG part must become a text note")
        }
        if case .imageData(_, let mime, _) = gated.parts[2] {
            #expect(mime == "image/png")
        } else {
            Issue.record("allowed png part must survive unchanged")
        }
    }

    @Test func toolResultRejectedImageDropsOnlyImagePayload() {
        let part = AgentContentPart.toolResult(
            id: "call-1", name: "browser_screenshot", content: "screenshot taken", isError: false,
            imageData: Data("<svg/>".utf8), imageMimeType: "image/svg+xml", pageURL: "https://example.com", imagePath: "/tmp/s.svg"
        )
        let message = AgentMessage(role: .user, parts: [part], isInterrupted: true, reasoningContent: "deep thought")
        let gated = message.gatingInlineMedia(for: visionCaps)
        if case .toolResult(let id, let name, let content, let isError, let imageData, let imageMimeType, let pageURL, let imagePath) = gated.parts.first {
            #expect(id == "call-1" && name == "browser_screenshot")
            #expect(content == "screenshot taken")   // tool text preserved
            #expect(isError == false)
            #expect(imageData == nil && imageMimeType == nil)  // rejected bytes stripped
            #expect(pageURL == "https://example.com" && imagePath == "/tmp/s.svg")
        } else {
            Issue.record("toolResult shape must be preserved")
        }
        // Metadata identity survives gating (interrupt/reasoning discipline).
        #expect(gated.isInterrupted == true)
        #expect(gated.reasoningContent == "deep thought")
    }

    @Test func gatingIsPureAcrossReplays() {
        let svgPart = AgentContentPart.imageData(data: Data("<svg/>".utf8), mimeType: "image/svg+xml")
        let message = AgentMessage(role: .user, parts: [svgPart])
        let first = message.gatingInlineMedia(for: visionCaps)
        let second = message.gatingInlineMedia(for: visionCaps)
        if case .text(let a) = first.parts.first, case .text(let b) = second.parts.first {
            #expect(a == b)
        } else {
            Issue.record("both replays must produce the text note")
        }
    }
}
