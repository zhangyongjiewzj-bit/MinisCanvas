import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-OUTPUT-03/04 ordinary Agent file output actions")
@MainActor
struct P3AcceptanceM03_AgentFileOutputActionConsumerTests {
    private func withSyntheticRoot(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.txt")
        try Data("synthetic output".utf8).write(to: file)
        try body(root, file)
    }

    private func change(_ path: String) -> AgentFileChangeRecord {
        AgentFileChangeRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            path: path,
            kind: .created,
            timestamp: Date(timeIntervalSince1970: 1),
            toolName: "file_write",
            diffText: "+synthetic output",
            additions: 1,
            deletions: 0,
            diffIsPartial: false
        )
    }

    private func record(_ change: AgentFileChangeRecord, sessionID: String? = "session-A") -> ActionRecord {
        ActionRecord(
            toolName: "file_write",
            argsSummary: "{}",
            resultSummary: "ok",
            succeeded: true,
            fileChange: change,
            sourceSessionID: sessionID
        )
    }

    @Test("the production action consumer rechecks a verified result and dispatches only the chosen user action")
    func readyFileOpensRevealsAndCopiesOnlyAfterValidation() throws {
        try withSyntheticRoot { root, file in
            let output = change(file.path)
            var actions: [String] = []
            let open: (URL) -> Bool = { url in actions.append("open:\(url.path)"); return true }
            let reveal: (URL) -> Bool = { url in actions.append("reveal:\(url.path)"); return true }
            let copy: (String) -> Bool = { path in actions.append("copy:\(path)"); return true }
            for intent in [AgentFileOutputIntent.systemOpen, .finderReveal, .copySafePath] {
                let result = AgentFileOutputActionConsumer.perform(
                    change: output, viewerSessionID: "session-A", records: [record(output)],
                    workspaceRoot: root.path, intent: intent,
                    probe: AgentFileOutputActionConsumer.fileSystemProbe,
                    open: open, reveal: reveal, copy: copy
                )
                #expect(result == .completed)
            }
            let physicalFile = file.resolvingSymlinksInPath().standardizedFileURL.path
            #expect(actions == ["open:\(physicalFile)", "reveal:\(physicalFile)", "copy:\(physicalFile)"])
        }
    }

    @Test("another session, a failed fact, and a replaced result cannot operate on the displayed path")
    func identityIsRevalidatedAtClickTime() throws {
        try withSyntheticRoot { root, file in
            let output = change(file.path)
            let failed = ActionRecord(
                toolName: "file_write", argsSummary: "{}", resultSummary: "failed",
                succeeded: false, fileChange: output, sourceSessionID: "session-A"
            )
            var calls = 0
            for records in [[record(output, sessionID: "session-B")], [failed], [record(change("/other.txt"))]] {
                let result = AgentFileOutputActionConsumer.perform(
                    change: output, viewerSessionID: "session-A", records: records,
                    workspaceRoot: root.path, intent: .systemOpen,
                    probe: { _ in calls += 1; return .readableFile },
                    open: { _ in calls += 1; return true },
                    reveal: { _ in calls += 1; return true },
                    copy: { _ in calls += 1; return true }
                )
                #expect(result == .failed(.unbound))
            }
            #expect(calls == 0)
        }
    }

    @Test("missing, out-of-root symlink, and permission denial have distinct visible failures and no OS action")
    func missingBoundaryAndPermissionFailClosed() throws {
        try withSyntheticRoot { root, file in
            let output = change(file.path)
            var actionCount = 0
            let open: (URL) -> Bool = { _ in actionCount += 1; return true }
            let reveal: (URL) -> Bool = { _ in actionCount += 1; return true }
            let copy: (String) -> Bool = { _ in actionCount += 1; return true }
            let denied = AgentFileOutputActionConsumer.perform(
                change: output, viewerSessionID: "session-A", records: [record(output)],
                workspaceRoot: root.path, intent: .systemOpen,
                probe: { _ in .permissionDenied }, open: open, reveal: reveal, copy: copy
            )
            #expect(denied == .failed(.permissionDenied))
            let noProductionRoot = AgentFileOutputActionConsumer.perform(
                change: output, viewerSessionID: "session-A", records: [record(output)],
                workspaceRoot: nil, intent: .systemOpen,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: open, reveal: reveal, copy: copy
            )
            #expect(noProductionRoot == .failed(.unavailable))

            try FileManager.default.removeItem(at: file)
            let missing = AgentFileOutputActionConsumer.perform(
                change: output, viewerSessionID: "session-A", records: [record(output)],
                workspaceRoot: root.path, intent: .systemOpen,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: open, reveal: reveal, copy: copy
            )
            #expect(missing == .failed(.missing))

            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("outside-\(UUID().uuidString)")
            try Data("synthetic outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let link = root.appendingPathComponent("outside-link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let escaped = change(link.path)
            let outOfBounds = AgentFileOutputActionConsumer.perform(
                change: escaped, viewerSessionID: "session-A", records: [record(escaped)],
                workspaceRoot: root.path, intent: .copySafePath,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: open, reveal: reveal, copy: copy
            )
            #expect(outOfBounds == .failed(.outOfBounds))
            let lexicalEscape = change(outside.path)
            let lexicalOutOfBounds = AgentFileOutputActionConsumer.perform(
                change: lexicalEscape, viewerSessionID: "session-A", records: [record(lexicalEscape)],
                workspaceRoot: root.path, intent: .systemOpen,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: open, reveal: reveal, copy: copy
            )
            #expect(lexicalOutOfBounds == .failed(.outOfBounds))
            #expect(actionCount == 0)
            #expect(!denied.message.contains(root.path))
            #expect(!missing.message.contains(root.path))
            #expect(!outOfBounds.message.contains(outside.path))
        }
    }

    @Test("a failed system action remains a failure rather than reporting an opened file")
    func systemOpenFailureIsVisible() throws {
        try withSyntheticRoot { root, file in
            let output = change(file.path)
            let result = AgentFileOutputActionConsumer.perform(
                change: output, viewerSessionID: "session-A", records: [record(output)],
                workspaceRoot: root.path, intent: .systemOpen,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: { _ in false }, reveal: { _ in true }, copy: { _ in true }
            )
            #expect(result == .failed(.actionFailed))
        }
    }

    @Test("verified text and image results route to the existing right-side preview; PDF has no claimed preview")
    func previewUsesOnlySupportedExistingKinds() throws {
        try withSyntheticRoot { root, textFile in
            let output = change(textFile.path)
            var previewURLs: [URL] = []
            let preview: (URL) -> Bool = { url in previewURLs.append(url); return true }
            let textResult = AgentFileOutputActionConsumer.perform(
                change: output, viewerSessionID: "session-A", records: [record(output)],
                workspaceRoot: root.path, intent: .preview,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: { _ in false }, reveal: { _ in false }, copy: { _ in false },
                preview: preview
            )
            #expect(textResult == .completed)

            let image = root.appendingPathComponent("image.png")
            let png = try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
            try png.write(to: image)
            let imageOutput = change(image.path)
            let imageResult = AgentFileOutputActionConsumer.perform(
                change: imageOutput, viewerSessionID: "session-A", records: [record(imageOutput)],
                workspaceRoot: root.path, intent: .preview,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: { _ in false }, reveal: { _ in false }, copy: { _ in false },
                preview: preview
            )
            #expect(imageResult == .completed)

            let pdf = root.appendingPathComponent("report.pdf")
            try Data("synthetic report".utf8).write(to: pdf)
            let pdfOutput = change(pdf.path)
            let pdfResult = AgentFileOutputActionConsumer.perform(
                change: pdfOutput, viewerSessionID: "session-A", records: [record(pdfOutput)],
                workspaceRoot: root.path, intent: .preview,
                probe: AgentFileOutputActionConsumer.fileSystemProbe,
                open: { _ in false }, reveal: { _ in false }, copy: { _ in false },
                preview: preview
            )
            #expect(pdfResult == .failed(.previewUnsupported))
            #expect(previewURLs.map(\.lastPathComponent) == ["report.txt", "image.png"])
            let imagePreview = FilePreview.loadAgentOutput(url: image, workspaceRoot: root)
            #expect(imagePreview.imageData == png)
            #expect(FileTreePreviewCache.image(from: png, key: "") != nil)
        }
    }

    @Test("Agent preview reads a synthetic Markdown report within budget and blocks oversized or escaped files")
    func boundedPreviewRechecksRootBeforeReading() throws {
        try withSyntheticRoot { root, _ in
            let report = root.appendingPathComponent("report.md")
            try Data("# Synthetic report\nOnly test content".utf8).write(to: report)
            let preview = FilePreview.loadAgentOutput(url: report, workspaceRoot: root)
            #expect(preview.kind == .text)
            #expect(preview.text == "# Synthetic report\nOnly test content")
            #expect(preview.error == nil)

            let large = root.appendingPathComponent("large.txt")
            try Data(repeating: 65, count: FilePreview.agentTextByteLimit + 1).write(to: large)
            let oversized = FilePreview.loadAgentOutput(url: large, workspaceRoot: root)
            #expect(oversized.text == nil)
            #expect(oversized.error?.contains("大小上限") == true)

            let outside = root.deletingLastPathComponent().appendingPathComponent("preview-outside-\(UUID().uuidString).txt")
            try Data("outside-canary".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let link = root.appendingPathComponent("escape.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let escaped = FilePreview.loadAgentOutput(url: link, workspaceRoot: root)
            #expect(escaped.text == nil)
            #expect(escaped.error == AgentFileOutputFailure.outOfBounds.message)
            #expect(!(escaped.error ?? "").contains("outside-canary"))
        }
    }

    @Test("Agent preview selection is tied to its original session and clears on switch")
    func previewSelectionDoesNotFollowNewSession() throws {
        try withSyntheticRoot { root, file in
            let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            let selection = ChatAttachmentPreviewSelection(
                sessionID: a, url: file, agentWorkspaceRoot: root
            )
            #expect(selection.visible(in: a) == selection)
            #expect(selection.visible(in: b) == nil)
            let store = FileTreeStore(rootURL: root)
            store.selectAttachment(selection)
            #expect(store.agentPreviewOnly)
            #expect(store.canShowPreview(for: selection))
            #expect(!store.canShowPreview(for: nil))
            #expect(!store.canShowPreview(for: ChatAttachmentPreviewSelection(
                sessionID: b, url: file, agentWorkspaceRoot: root
            )))
            store.clearChatAttachmentSelection()
            #expect(store.selectedURL == nil)
            #expect(store.preview == nil)
            #expect(!store.agentPreviewOnly)
        }
    }
}
