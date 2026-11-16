import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("PastedTextPolicy Batch 1")
struct PastedTextPolicyTests {
    @Test func scalarThresholdUsesStrictGreaterThan() {
        let boundary = String(repeating: "x", count: PastedTextPolicy.scalarThreshold)
        let overBoundary = boundary + "y"

        #expect(PastedTextPolicy.shouldCollapsePastedText(boundary) == false)
        #expect(PastedTextPolicy.shouldCollapsePastedText(overBoundary) == true)
    }

    @Test func lineThresholdRequiresTwelveNewlinesAndMoreThanEightHundredScalars() {
        let twelveNewlinesUnderScalarThreshold =
            String(
                repeating: "x",
                count: PastedTextPolicy.lineScalarThreshold - PastedTextPolicy.lineThreshold
            ) +
            String(repeating: "\n", count: PastedTextPolicy.lineThreshold)
        let twelveNewlinesOverScalarThreshold =
            String(
                repeating: "x",
                count: PastedTextPolicy.lineScalarThreshold - PastedTextPolicy.lineThreshold + 1
            ) +
            String(repeating: "\n", count: PastedTextPolicy.lineThreshold)
        let elevenNewlinesOverScalarThreshold =
            String(repeating: "x", count: PastedTextPolicy.lineScalarThreshold + 1) +
            String(repeating: "\n", count: PastedTextPolicy.lineThreshold - 1)

        #expect(PastedTextPolicy.shouldCollapsePastedText(twelveNewlinesUnderScalarThreshold) == false)
        #expect(PastedTextPolicy.shouldCollapsePastedText(twelveNewlinesOverScalarThreshold) == true)
        #expect(PastedTextPolicy.shouldCollapsePastedText(elevenNewlinesOverScalarThreshold) == false)
    }

    @Test func typingSourceNeverCollapsesEvenWhenTextIsLong() {
        let draft = PastedTextDraft(
            id: UUID(),
            text: String(repeating: "typed", count: 501),
            source: .typing
        )

        #expect(PastedTextPolicy.shouldCollapse(draft) == false)
        #expect(PastedTextPolicy.shouldCollapse(draft.text, source: .typing) == false)
    }

    @Test func pasteboardDraftUsesTheSameThresholdPolicy() {
        let draft = PastedTextDraft(
            id: UUID(),
            text: String(repeating: "p", count: PastedTextPolicy.scalarThreshold + 1),
            source: .pasteboard
        )

        #expect(PastedTextPolicy.shouldCollapse(draft) == true)
        #expect(PastedTextPolicy.shouldCollapse(draft.text, source: .pasteboard) == true)
    }

    @Test func shortPasteDoesNotCollapse() {
        let draft = PastedTextDraft(id: UUID(), text: "short", source: .pasteboard)

        #expect(PastedTextPolicy.shouldCollapse(draft) == false)
        #expect(draft.characterCount == 5)
        #expect(draft.lineCount == 1)
    }

    @Test func unicodeScalarCountingCoversEmojiAndCombiningCharacters() {
        let text = "👩‍🚀e\u{301}"
        let draft = PastedTextDraft(id: UUID(), text: text, source: .pasteboard)
        let summary = PastedTextPolicy.summary(for: text)

        #expect(draft.characterCount == text.unicodeScalars.count)
        #expect(draft.characterCount == 5)
        #expect(text.count == 2)
        #expect(summary.characterCount == 5)
        #expect(summary.lineCount == 1)
    }

    @Test func summaryIsBoundedAndDoesNotReturnTheFullText() {
        let text = String(repeating: "z", count: 41)
        let summary = PastedTextPolicy.summary(for: text)

        #expect(summary.characterCount == 41)
        #expect(summary.lineCount == 1)
        #expect(summary.preview.unicodeScalars.count == 40)
        #expect(summary.preview == String(repeating: "z", count: 40))
        #expect(summary.preview != text)
    }

    @Test func summaryNeverExceedsFortyScalarsWhenCallerRequestsMore() {
        let text = String(repeating: "z", count: 80)
        let summary = PastedTextPolicy.summary(for: text, previewLimit: 80)

        #expect(summary.preview.unicodeScalars.count == PastedTextPolicy.previewScalarLimit)
        #expect(summary.preview == String(repeating: "z", count: PastedTextPolicy.previewScalarLimit))
    }

    @Test func summaryCountsLinesIncludingTrailingNewline() {
        let summary = PastedTextPolicy.summary(for: "first\nsecond\n")

        #expect(summary.characterCount == 13)
        #expect(summary.lineCount == 3)
        #expect(summary.preview == "first\nsecond\n")
    }

    @Test func draftRoundTripsThroughCodable() throws {
        let draft = PastedTextDraft(id: UUID(), text: "payload", source: .pasteboard)
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PastedTextDraft.self, from: data)

        #expect(decoded == draft)
    }

    @Test func mergeOmitsSeparatorForEmptyValues() {
        #expect(ComposerPayload.merge(body: "", pastedText: (nil as String?)) == "")
        #expect(ComposerPayload.merge(body: "body", pastedText: (nil as String?)) == "body")
        #expect(ComposerPayload.merge(body: "", pastedText: "") == "")
        #expect(ComposerPayload.merge(body: "body", pastedText: "") == "body")
        #expect(ComposerPayload.merge(body: "", pastedText: "pasted") == "pasted")
    }

    @Test func mergeKeepsBodySeparatorAndPastedTextOrder() {
        let body = "request"
        let pastedText = "long pasted content"
        let expected = body + ComposerPayload.pastedTextSeparator + pastedText

        #expect(ComposerPayload.merge(body: body, pastedText: pastedText) == expected)
    }

    @Test func onlyRealPasteSourceCanCollapseLongText() {
        let longText = String(repeating: "x", count: PastedTextPolicy.scalarThreshold + 1)
        let pasted = PastedTextDraft(id: UUID(), text: longText, source: .pasteboard)
        let typed = PastedTextDraft(id: UUID(), text: longText, source: .typing)

        #expect(PastedTextPolicy.shouldCollapse(pasted))
        #expect(!PastedTextPolicy.shouldCollapse(typed))
        #expect(!PastedTextPolicy.shouldCollapse(longText, source: .typing))
    }

    @Test func referenceAndInstructionRemainExplicitlyDistinct() throws {
        let reference = PastedTextDraft(
            id: UUID(),
            text: "参考中的 session_read 文字",
            source: .pasteboard
        )
        let instruction = PastedTextDraft(
            id: UUID(),
            text: "session_read target messages",
            source: .pasteboard,
            kind: .instruction
        )

        #expect(reference.kind == .reference)
        #expect(reference.isReference)
        #expect(instruction.kind == .instruction)
        #expect(instruction.isInstruction)
        #expect(PastedTextPolicy.intentInput(body: "总结", pastedText: reference) == "总结")
        #expect(
            PastedTextPolicy.intentInput(body: "执行", pastedText: instruction)
                == "执行\n\n[Pasted instruction]\nsession_read target messages"
        )

        let legacyJSON = """
        {"id":"\(reference.id.uuidString)","text":"legacy","source":"pasteboard"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PastedTextDraft.self, from: legacyJSON)
        #expect(decoded.kind == .reference)
        #expect(decoded.text == "legacy")
    }
}
