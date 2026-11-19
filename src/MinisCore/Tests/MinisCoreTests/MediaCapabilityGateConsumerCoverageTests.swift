import Foundation
import Testing
@testable import MinisCore

// MARK: - P3-MEDIA-01 media capability gate CONSUMER coverage tests (lane 138)
//
// Lane 128 shipped `MediaCapabilityGate` and wired it into the
// OpenAI-compatible chat-completions wire and the agent inline-image path.
// This suite pins the two remaining provider wire edges that had ZERO gate
// read sites at base 3f834054:
//   - `AnthropicProvider.anthropicMessageDict` (sole message-assembly edge,
//     reached from `buildRequest`, which every send/stream caller uses),
//   - `OpenAIResponsesProvider.responsesInputItem` (sole media-part edge,
//     reached from `requestBody`, which every send/stream caller uses).
// Both production call sites pass `model.capabilities` — exactly the values
// these tests build through the same public API (`LLMModel.capabilities` /
// `withModalityOverride`), so every row asserts the real production
// boundary: which provider path, which ModelCapabilities, which media kind
// yields allow (byte-identical serialization) / deny (deterministic
// `[media-gate]` text note) / degrade (capability admitted the medium but
// this wire's content block cannot carry it → same note, never a silent
// drop, never a malformed block).
//
// Rows marked (RED-ON-BASE) fail against base 3f834054 by construction: the
// ungated code emitted the media block/part verbatim (or, for Anthropic
// audio, dropped the attachment without any trace), so the asserted note or
// base64-absence cannot hold there. Rows marked (BASE-PASS) pin the
// allow-side and the legacy `mediaCapabilities: nil` behavior the pinned
// AnthropicStreamDecoderTests already rely on, proving the defaulted
// parameter is not a behavior break.
//
// Expected state at delivery: NOT_RUN / UNVERIFIED-RUNTIME — ordinary DEV
// lanes do not run swift test; PKG_MAIN compiles and executes.

// MARK: - Fixtures (pure, deterministic — same lookup production uses)

/// `LLMModel(provider: "Anthropic").capabilities` → knownCapabilities
/// entry = .vision (imageInput + pdfInput, no audio/video).
private let claudeVisionModel = LLMModel(
    id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", provider: "Anthropic")

/// Unknown provider id → `defaultCapabilities` = .textOnly (fail-closed) —
/// the same value the wire sites read through `model.capabilities`.
private let unknownTextOnlyModel = LLMModel(
    id: "mystery-1", displayName: "Mystery One", provider: "MysteryProvider")

/// Override incl. .audioInput + .videoInput — the most generous set the gate
/// can ever be told about (SVG still rejects).
private let fullMultimodalClaudeModel = LLMModel(
    id: "claude-opus-5", displayName: "Claude Opus 5", provider: "Anthropic"
).withModalityOverride(.fullMultimodalInput)

/// A Responses-path model whose provider string is NOT in knownCapabilities:
/// `model.capabilities` resolves to the fail-closed textOnly default — the
/// real configuration of `OpenAIResponsesProvider` unless the user set a
/// modality override.
private let responsesDefaultModel = LLMModel(
    id: "gpt-responses-mystery", displayName: "Responses Mystery", provider: "OpenAI Responses")

private let responsesVisionModel = LLMModel(
    id: "gpt-responses-vision", displayName: "Responses Vision", provider: "OpenAI Responses"
).withModalityOverride(.vision)

private let responsesFullMultimodalModel = LLMModel(
    id: "gpt-responses-full", displayName: "Responses Full Multimodal", provider: "OpenAI Responses"
).withModalityOverride(.fullMultimodalInput)

private let tinyPNGBytes = try! MediaPayloadFixtures589.png() // Existing allow-side fixture now has real dimensions.
private let tinyPNGBase64 = tinyPNGBytes.base64EncodedString()
private let svgBytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
private let svgBase64 = svgBytes.base64EncodedString()
private let pdfBytes = Data("%PDF-1.4 consumer coverage fixture".utf8)
private let pdfBase64 = pdfBytes.base64EncodedString()
private let audioBase64String = MediaPayloadFixtures589.wav.base64EncodedString()

private func pngMsg(
    content: String = "look at this",
    extraImages: [LLMMessage.ImageAttachment] = [],
    audios: [LLMMessage.AudioAttachment] = []
) -> LLMMessage {
    LLMMessage(
        role: .user,
        content: content,
        images: [LLMMessage.ImageAttachment(mimeType: "image/png", data: tinyPNGBytes)] + extraImages,
        audios: audios
    )
}

private func svgMsg(content: String = "vector check") -> LLMMessage {
    LLMMessage(
        role: .user,
        content: content,
        images: [LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: svgBytes)]
    )
}

private func pdfMsg(content: String = "contract") -> LLMMessage {
    LLMMessage(
        role: .user,
        content: content,
        images: [LLMMessage.ImageAttachment(mimeType: "application/pdf", data: pdfBytes)]
    )
}

/// Extract the Anthropic content blocks array; nil when the message took
/// the plain-string content fast path.
private func anthropicBlocks(_ dict: [String: Any]) -> [[String: Any]]? {
    dict["content"] as? [[String: Any]]
}

private func anthropicTexts(_ dict: [String: Any]) -> [String] {
    (anthropicBlocks(dict) ?? [])
        .filter { ($0["type"] as? String) == "text" }
        .compactMap { $0["text"] as? String }
}

private func jsonSerialized(_ dict: [String: Any]) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    } catch {
        Issue.record("gated Anthropic dict must stay JSON-serializable: \(error)")
        return "<serialization-failed>"
    }
}

private func jsonDataSerialized(_ item: ResponsesAPIRequestBody.InputMessage) -> String {
    do {
        // Compare canonical input-item bytes: JSONEncoder's default dictionary
        // key order may vary even when replay produces the same media parts.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(item)
        return String(decoding: data, as: UTF8.self)
    } catch {
        Issue.record("gated Responses input item must stay encodable: \(error)")
        return "<serialization-failed>"
    }
}

// MARK: - Anthropic wire (AnthropicProvider.anthropicMessageDict)

@Suite("P3-MEDIA-01 consumer coverage — Anthropic wire gate")
struct AnthropicMediaGateConsumerTests {

    @Test func allowedRasterSerializesByteIdenticallyToLegacyPath() {
        // (BASE-PASS control) A vision model's raster image rides exactly as
        // before: same block shape, same base64 payload.
        let gated = AnthropicProvider.anthropicMessageDict(
            pngMsg(), mediaCapabilities: claudeVisionModel.capabilities)
        let legacy = AnthropicProvider.anthropicMessageDict(pngMsg())
        #expect(jsonSerialized(gated) == jsonSerialized(legacy))
        let blocks = anthropicBlocks(gated) ?? []
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "image")
        #expect((blocks[0]["source"] as? [String: Any])?["data"] as? String == tinyPNGBase64)
    }

    @Test func svgRejectedOnVisionAndEvenOnFullMultimodal() {
        // (RED-ON-BASE) Base emitted an image block carrying the SVG bytes —
        // the recorded LUNA pollution mechanism.
        for caps in [claudeVisionModel.capabilities, fullMultimodalClaudeModel.capabilities] {
            let dict = AnthropicProvider.anthropicMessageDict(svgMsg(), mediaCapabilities: caps)
            #expect(!jsonSerialized(dict).contains(svgBase64), "SVG bytes must never ride the wire")
            #expect(!(anthropicBlocks(dict) ?? []).contains { ($0["type"] as? String) == "image" })
            let texts = anthropicTexts(dict)
            #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("image/svg+xml") })
            #expect(texts.contains { $0.contains("vector check") },
                    "message body must survive (failure isolation)")
        }
    }

    @Test func rasterRejectedOnTextOnlyModel() {
        // (RED-ON-BASE) Base attached the PNG unconditionally regardless of
        // declared modalities.
        let dict = AnthropicProvider.anthropicMessageDict(
            pngMsg(), mediaCapabilities: unknownTextOnlyModel.capabilities)
        #expect(!jsonSerialized(dict).contains(tinyPNGBase64))
        let texts = anthropicTexts(dict)
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("image/png") })
        #expect(texts.contains { $0.contains("look at this") })
    }

    @Test func audioNeverSilentlyDroppedAgain() {
        // (RED-ON-BASE) Base ignored msg.audios on this path entirely — the
        // turn lost the attachment without any trace for the model. The
        // gated edge replaces it with a deterministic note (Anthropic .vision
        // has no audioInput bit; even a capability allow would degrade to a
        // wire-incompat note because no audio content block exists here).
        let msg = LLMMessage(
            role: .user, content: "listen",
            audios: [LLMMessage.AudioAttachment(format: "wav", base64Data: audioBase64String)])
        let gated = AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: claudeVisionModel.capabilities)
        #expect(anthropicBlocks(gated) != nil, "audio-only message must take the block path once gated")
        let texts = anthropicTexts(gated)
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("audio/wav") })
        #expect(texts.contains { $0.contains("listen") })
        #expect(!jsonSerialized(gated).contains(audioBase64String))
        // Legacy pinned behavior stays untouched when no capabilities supplied.
        let legacy = AnthropicProvider.anthropicMessageDict(msg)
        #expect(legacy["content"] as? String == "listen")
    }

    @Test func capabilityAllowedButWireIncompatiblePdfDegradesToNote() {
        // (RED-ON-BASE) `.vision` includes .pdfInput, so the gate ADMITS the
        // medium — but this wire's `image` content block carries raster
        // images only (a document block is not assembled on this path).
        // Honest outcome: the shared `[media-gate]` note, never a malformed
        // image block, never silence.
        let dict = AnthropicProvider.anthropicMessageDict(
            pdfMsg(), mediaCapabilities: claudeVisionModel.capabilities)
        #expect(!jsonSerialized(dict).contains(pdfBase64))
        let texts = anthropicTexts(dict)
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("application/pdf") })
        #expect(texts.contains { $0.contains("raster images only") })
        #expect(texts.contains { $0.contains("contract") })
    }

    @Test func oneRejectedPartNeverDropsSiblingParts() {
        // (RED-ON-BASE) Failure isolation across three images + body text:
        // png allowed, svg rejected, octet-stream rejected fail-closed, text
        // intact — base sent all three binaries.
        let msg = pngMsg(extraImages: [
            LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: svgBytes),
            LLMMessage.ImageAttachment(mimeType: "application/octet-stream", data: Data([0x00, 0x01])),
        ])
        let dict = AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: claudeVisionModel.capabilities)
        let blocks = anthropicBlocks(dict) ?? []
        let imageBlocks = blocks.filter { ($0["type"] as? String) == "image" }
        #expect(imageBlocks.count == 1)
        #expect((imageBlocks[0]["source"] as? [String: Any])?["media_type"] as? String == "image/png")
        let texts = anthropicTexts(dict)
        #expect(texts.filter { $0.contains("[media-gate]") }.count == 2)
        #expect(texts.contains("look at this"))
    }

    @Test func toolRoleEnvelopeUnchangedUnderGating() {
        // 第八版起工具结果可以带图片（对齐 Claude Code：读图片、MCP 截图交给模型）。
        // 能力闸门照样生效：SVG 不作为图片块发送，tool_result 里保留正文并说明被拒原因。
        var msg = LLMMessage(role: .tool, content: "result text")
        msg.toolCallID = "call_42"
        msg.images = [LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: svgBytes)]
        let gated = AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: claudeVisionModel.capabilities)
        let json = jsonSerialized(gated)
        #expect(json.contains("\"tool_use_id\":\"call_42\""))
        #expect(json.contains("result text"))
        #expect(json.contains("[media-gate]"))
        #expect(!json.contains("\"type\":\"image\""))
    }

    @Test func decisionIsStatelessAcrossModelSwitch() {
        // Model-switch / compact replay property: the SAME stored message
        // re-derived against vision → textOnly → vision reproduces
        // byte-identical serializations; enforcement never mutates history.
        let msg = svgMsg()
        let vision = jsonSerialized(AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: claudeVisionModel.capabilities))
        let textOnly = jsonSerialized(AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: unknownTextOnlyModel.capabilities))
        let visionAgain = jsonSerialized(AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: claudeVisionModel.capabilities))
        #expect(vision == visionAgain)
        // SVG rejection is capability-independent (same deterministic note),
        // so the vision and textOnly replays of this reject coincide — while
        // neither ever coincides with the payload:
        #expect(textOnly == vision)
        #expect(!vision.contains(svgBase64))
    }
}

// MARK: - Responses wire (OpenAIResponsesProvider.responsesInputItem)

@Suite("P3-MEDIA-01 consumer coverage — Responses wire gate")
struct ResponsesMediaGateConsumerTests {

    @Test func unknownResponsesProviderFailsClosedOnAllMedia() {
        // (RED-ON-BASE) `model.capabilities` for an unlisted provider id is
        // the textOnly default → every media part must degrade to a note;
        // base attached image/audio verbatim.
        let msg = pngMsg(extraImages: [
            LLMMessage.ImageAttachment(mimeType: "image/svg+xml", data: svgBytes),
        ], audios: [LLMMessage.AudioAttachment(format: "wav", base64Data: audioBase64String)])
        let item = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: responsesDefaultModel.capabilities)
        #expect(!item.content.contains { $0.type == "input_image" })
        #expect(!item.content.contains { $0.type == "input_audio" })
        let texts = item.content.compactMap { $0.text }
        #expect(texts.filter { $0.contains("[media-gate]") }.count == 3)
        #expect(texts.contains("look at this"))
    }

    @Test func visionModelAdmitsRasterRejectsAudio() {
        // Mixed row: (BASE-PASS for the png part — identical data URL;
        // RED-ON-BASE for the audio part — base emitted input_audio
        // regardless of the declared modality).
        let msg = pngMsg(audios: [LLMMessage.AudioAttachment(format: "wav", base64Data: audioBase64String)])
        let item = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: responsesVisionModel.capabilities)
        let imageParts = item.content.filter { $0.type == "input_image" }
        #expect(imageParts.count == 1)
        #expect(imageParts[0].imageURL?.url == "data:image/png;base64,\(tinyPNGBase64)")
        #expect(!item.content.contains { $0.type == "input_audio" })
        let texts = item.content.compactMap { $0.text }
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("audio/wav") })
        #expect(texts.contains("look at this"))
    }

    @Test func fullMultimodalAdmitsAudioVerbatimButStillNotSVG() {
        // Allow-side control (audio part byte-identical to base) + the
        // capability-independent SVG rejection (RED-ON-BASE).
        let audioMsg = LLMMessage(
            role: .user, content: "transcribe",
            audios: [LLMMessage.AudioAttachment(format: "wav", base64Data: audioBase64String)])
        let allowed = OpenAIResponsesProvider.responsesInputItem(
            audioMsg, mediaCapabilities: responsesFullMultimodalModel.capabilities)
        let audioParts = allowed.content.filter { $0.type == "input_audio" }
        #expect(audioParts.count == 1)
        #expect(audioParts[0].inputAudio?.data == audioBase64String)
        #expect(audioParts[0].inputAudio?.format == "wav")

        let svg = OpenAIResponsesProvider.responsesInputItem(
            svgMsg(), mediaCapabilities: responsesFullMultimodalModel.capabilities)
        #expect(!svg.content.contains { $0.type == "input_image" })
        #expect(!jsonDataSerialized(svg).contains(svgBase64))
        #expect(svg.content.compactMap { $0.text }.contains { $0.contains("[media-gate]") })
    }

    @Test func capabilityAllowedNonRasterDegradesToNote() {
        // (RED-ON-BASE) vision includes .pdfInput so the gate admits the
        // medium, but `input_image` carries raster images only → the note,
        // never a malformed data URL.
        let item = OpenAIResponsesProvider.responsesInputItem(
            pdfMsg(), mediaCapabilities: responsesVisionModel.capabilities)
        #expect(!item.content.contains { $0.type == "input_image" })
        #expect(!jsonDataSerialized(item).contains(pdfBase64))
        let texts = item.content.compactMap { $0.text }
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("raster images only") })
        #expect(texts.contains("contract"))
    }

    @Test func legacyNilCapabilitiesKeepsUngatedBehavior() {
        // Pin the default-parameter non-regression (mirrors the pinned
        // AnthropicStreamDecoderTests row): nil = pre-lane-138 serialization.
        let item = OpenAIResponsesProvider.responsesInputItem(svgMsg())
        #expect(item.content.first?.type == "input_image")
        #expect(item.content.first?.imageURL?.url == "data:image/svg+xml;base64,\(svgBase64)")
    }

    @Test func gatedReplayIsByteIdenticalForSameStoredHistory() {
        // Restart/compact-replay determinism: same message + same caps
        // produce identical canonical input-item JSON, including media bytes.
        let msg = pngMsg(audios: [LLMMessage.AudioAttachment(format: "mp3", base64Data: audioBase64String)])
        let firstItem = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: responsesVisionModel.capabilities)
        let secondItem = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: responsesVisionModel.capabilities)
        let imageURL = firstItem.content.first { $0.type == "input_image" }?.imageURL?.url
        let texts = firstItem.content.compactMap { $0.text }
        #expect(imageURL == "data:image/png;base64,\(tinyPNGBase64)")
        #expect(!firstItem.content.contains { $0.type == "input_audio" })
        #expect(texts.contains { $0.contains("[media-gate]") && $0.contains("audio/mp3") })
        let first = jsonDataSerialized(firstItem)
        let second = jsonDataSerialized(secondItem)
        #expect(first != "<serialization-failed>")
        #expect(first == second)
    }
}

// MARK: - Intake edge (FileImporter → shared gate), no second classifier

@Suite("P3-MEDIA-01 consumer coverage — FileImporter intake chain")
struct FileImporterIntakeChainTests {
    // FileImporter intake is model-agnostic (the selected model can change
    // AFTER attachment), so enforcement stays at the wire edge — the lane-128
    // architecture note. These rows pin the intake→wire chain closed with the
    // SHARED classifier: whatever MIME FileImporter hands the send pipeline
    // (mimeType(of:) → ChatAttachment.mimeType → LLMMessage part) is exactly
    // what the gated wires decide on. No gate semantics are re-implemented.

    @Test func everyImportedMediumClassifiesIntoTheSharedGate() {
        let cases: [(String, MediaPartKind)] = [
            ("png", .rasterImage),
            ("jpg", .rasterImage),
            ("svg", .vectorImage),  // the pollution vector: intake folds it into FileType.image
            ("pdf", .pdf),          // lane-138: extension map now resolves PDF (was nil → disk-sniff only)
            ("wav", .audio),
            ("mp3", .audio),
            ("mp4", .video),
        ]
        for (ext, expectedKind) in cases {
            let mime = FileImporter.mimeType(forExtension: ext)
            #expect(mime != nil, "FileImporter must keep emitting a MIME for \(ext)")
            if let mime {
                #expect(MediaPartKind.classify(mimeType: mime) == expectedKind,
                        "intake MIME \(mime) must reach the shared classifier as \(expectedKind)")
            }
        }
    }

    @Test func pdfOnDiskResolvesToPDFKindWithoutFullRead() {
        // The row names PDF explicitly. An unreadable/security-scoped PDF
        // must still resolve its kind from the extension map (this is what
        // ChatStore stores on ChatAttachment.mimeType before any gating);
        // the on-disk magic-byte path must agree.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let pdfURL = dir.appendingPathComponent("minis-138-fixture.pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        do {
            try pdfBytes.write(to: pdfURL, options: .atomic)
        } catch {
            Issue.record("fixture PDF must be writable: \(error)")
            return
        }
        #expect(FileImporter.mimeType(forExtension: "pdf") == "application/pdf")
        if let mime = FileImporter.mimeType(of: pdfURL) {
            #expect(MediaPartKind.classify(mimeType: mime) == .pdf)
        } else {
            Issue.record("on-disk PDF must resolve a MIME")
        }
    }

    @Test func svgIntakeFoldIsNeutralizedOnEveryGatedWire() {
        // FileImporter.classify folds .svg into FileType.image (unchanged —
        // the FileType enum split is OUT_OF_SET), ChatStore therefore builds
        // an image-channel LLMMessage part with mimeType "image/svg+xml",
        // and EVERY wire edge must neutralize it — including the most
        // generous capability set (the OpenAI-compatible wire's identical
        // behavior is pinned by lane 128's MediaCapabilityGateTests).
        let mime = FileImporter.mimeType(forExtension: "svg") ?? ""
        #expect(MediaCapabilityGate.decide(mimeType: mime, capabilities: claudeVisionModel.capabilities).isAllowed == false)
        #expect(MediaCapabilityGate.decide(mimeType: mime, capabilities: fullMultimodalClaudeModel.capabilities).isAllowed == false)

        let msg = svgMsg()
        let anthropicDict = AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: fullMultimodalClaudeModel.capabilities)
        #expect(jsonSerialized(anthropicDict).contains("[media-gate]"))
        #expect(!jsonSerialized(anthropicDict).contains(svgBase64))
        let responsesItem = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: fullMultimodalClaudeModel.capabilities)
        #expect(!responsesItem.content.contains { $0.type == "input_image" })
    }

    @Test func textOnlyModelTurnSurvivesRejectedMedia() {
        // Row-level failure isolation across BOTH wires: a user sends text +
        // PNG + WAV to a text-only model. Neither path may drop the turn —
        // the text arrives and each media part becomes an explicit note.
        let msg = LLMMessage(
            role: .user, content: "hello without eyes",
            images: [LLMMessage.ImageAttachment(mimeType: "image/png", data: tinyPNGBytes)],
            audios: [LLMMessage.AudioAttachment(format: "wav", base64Data: audioBase64String)])

        let anthropic = AnthropicProvider.anthropicMessageDict(
            msg, mediaCapabilities: unknownTextOnlyModel.capabilities)
        let anthropicTexts = anthropicTexts(anthropic)
        #expect(anthropicTexts.contains("hello without eyes"))
        #expect(anthropicTexts.filter { $0.contains("[media-gate]") }.count == 2)

        let responses = OpenAIResponsesProvider.responsesInputItem(
            msg, mediaCapabilities: unknownTextOnlyModel.capabilities)
        let responsesTexts = responses.content.compactMap { $0.text }
        #expect(responsesTexts.contains("hello without eyes"))
        #expect(responsesTexts.filter { $0.contains("[media-gate]") }.count == 2)
        #expect(!jsonDataSerialized(responses).contains(tinyPNGBase64))
        #expect(!jsonSerialized(anthropic).contains(tinyPNGBase64))
    }
}
