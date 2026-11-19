import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("PastedText capsule slice")
struct PastedTextComposerSliceTests {
    @Test("paste collapses only over the scalar or multiline threshold")
    func collapseRules() {
        let long = String(repeating: "字", count: 2_001)
        let multiline = Array(repeating: "line", count: 13).joined(separator: "\n") + String(repeating: "x", count: 801)
        let typed = PastedTextDraft(id: UUID(), text: long, source: .typing)

        #expect(PastedTextPolicy.shouldCollapsePastedText(long))
        #expect(PastedTextPolicy.shouldCollapse(multiline, source: .pasteboard))
        #expect(!PastedTextPolicy.shouldCollapse(typed))
    }

    @Test("summary is bounded and payload merge is deterministic")
    func boundedSummaryAndSnapshotPayload() {
        let text = String(repeating: "a", count: 2_100)
        let summary = PastedTextPolicy.summary(for: text, previewLimit: 400)
        #expect(summary.characterCount == 2_100)
        #expect(summary.preview.unicodeScalars.count == PastedTextPolicy.previewScalarLimit)
        #expect(ComposerPayload.merge(body: "正文", pastedText: "附文") == "正文\n\n[Pasted text]\n附文")
    }

    @Test("capsule source contains bounded preview and stable accessibility actions")
    func capsuleContract() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/PastedTextCapsuleView.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        #expect(source.contains("composer.pasted-text.preview"))
        #expect(source.contains("composer.pasted-text.remove"))
        #expect(source.contains("accessibilityValue"))
        #expect(source.contains("lineLimit(1)"))
    }

    @Test("capsule exposes its own AX element identifier without replacing action IDs")
    func capsuleExposesIndependentAccessibilityElement() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/PastedTextCapsuleView.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let globalComposer = try String(
            contentsOf: path.deletingLastPathComponent().appendingPathComponent("GlobalComposerView.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: path.deletingLastPathComponent().appendingPathComponent("ChatSidebarView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("static let accessibilityIdentifier = \"composer.pasted-text.capsule\""))
        #expect(source.contains(".accessibilityElement(children: .contain)"))
        #expect(source.contains(".accessibilityIdentifier(Self.accessibilityIdentifier)"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.preview\")"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.remove\")"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.editor\")"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.cancel\")"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.delete\")"))
        #expect(source.contains(".accessibilityIdentifier(\"composer.pasted-text.save\")"))
        #expect(globalComposer.contains(".accessibilityElement(children: .contain)"))
        #expect(sidebar.contains(".accessibilityElement(children: .contain)"))
        #expect(!globalComposer.contains(".accessibilityIdentifier(\"composer.pasted-text.capsule\")"))
        #expect(!sidebar.contains(".accessibilityIdentifier(\"composer.pasted-text.capsule\")"))

        let elementMarker = try #require(source.range(of: ".accessibilityElement(children: .contain)"))
        let identifierMarker = try #require(source.range(of: ".accessibilityIdentifier(Self.accessibilityIdentifier)"))
        #expect(elementMarker.lowerBound < identifierMarker.lowerBound)
    }

    @Test("sent instruction and reference cards keep kind-aware session identities")
    func sentCardViewUsesKindAwareSessionIdentity() throws {
        let source = try source(named: "PastedTextCapsuleView.swift")

        #expect(source.contains("private var cardKindLabel"))
        #expect(source.contains("private var cardIdentity"))
        #expect(source.contains("card.sessionID.uuidString"))
        #expect(source.contains("card.id.uuidString"))
        #expect(source.contains("accessibilityLabel(card.isExpanded ?"))
        #expect(source.contains("chat.pasted-reference-card.toggle.\\(cardIdentity)"))
        #expect(source.contains("chat.pasted-reference-card.\\(cardIdentity)"))
    }

    @Test("reference card reconstruction derives its projection from material")
    func referenceCardReconstructionIsMaterialBacked() throws {
        let source = try source(named: "PastedTextDraft.swift")

        #expect(source.contains("init(from decoder: Decoder) throws"))
        #expect(source.contains("material: try container.decode(String.self, forKey: .material)"))
        #expect(source.contains("self.init("))
        #expect(source.contains("func encode(to encoder: Encoder) throws"))
        #expect(!source.contains("try container.decode(Int.self, forKey: .characterCount)"))
    }

    @Test("both Composer views read the same session capsule and send path")
    func composersUseOneFactSource() throws {
        let global = try source(named: "GlobalComposerView.swift")
        let sidebar = try source(named: "ChatSidebarView.swift")

        #expect(global.contains("chat.activePastedTextDraft"))
        #expect(sidebar.contains("chat.activePastedTextDraft"))
        #expect(global.contains("chat.submitComposer()"))
        // 侧栏起始提示按钮改为只预填（2026-11-16），侧栏只剩键盘提交入口。
        #expect(sidebar.contains("chat.submitComposerFromKeyboard()"))
        #expect(global.contains("PastedTextComposerConsumer.accept"))
        #expect(sidebar.contains("PastedTextComposerConsumer.accept"))
    }

    @Test("reference content is excluded from intent while instruction content remains explicit")
    func semanticIntentBoundary() {
        let reference = PastedTextDraft(
            id: UUID(),
            text: "说明 session_read 只是参考资料",
            source: .pasteboard
        )
        let instruction = PastedTextDraft(
            id: UUID(),
            text: "session_read target metadata",
            source: .pasteboard,
            semantic: .instruction
        )

        #expect(PastedTextPolicy.sessionReadIntentInput(body: "继续", pastedText: reference) == "继续")
        #expect(
            PastedTextPolicy.sessionReadIntentInput(body: "请执行", pastedText: instruction)
                .contains(ComposerPayload.pastedInstructionSeparator)
        )
        #expect(
            PastedTextPolicy.sessionReadIntentInput(body: "请执行", pastedText: instruction)
                .contains("session_read")
        )
    }

    @Test("submission snapshot factory retains the complete reference")
    func submissionSnapshotRetainsFullReference() {
        let referenceText = String(repeating: "reference ", count: 250)
        let reference = PastedTextDraft(
            id: UUID(),
            text: referenceText,
            source: .pasteboard
        )
        let snapshot = PastedTextSubmissionSnapshot(
            capsuleID: reference.id,
            sessionID: UUID(),
            body: "正文",
            pastedText: reference
        )

        #expect(snapshot.fullText == "正文" + ComposerPayload.pastedTextSeparator + referenceText)
        #expect(snapshot.fullText.hasSuffix(referenceText))
        #expect(snapshot.fullText.count > PastedTextPolicy.previewScalarLimit)
    }

    private func source(named name: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot
                .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
