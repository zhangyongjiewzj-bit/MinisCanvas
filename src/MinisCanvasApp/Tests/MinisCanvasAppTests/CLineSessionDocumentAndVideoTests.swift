import Foundation
import AppKit
import ApplicationServices
import SwiftUI
import CryptoKit
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - C 线测试先行
//
// 原用例验证会话内逻辑和视频任务持久化；阶段 Binding 回归复用正式原生宿主。
// 不接入画布。每个测试使用独立临时目录，避免读写真实 Application Support。

@Suite("C 线会话内文档 Tab")
struct CLineSessionDocumentTests {
    private func makeDirectory(_ prefix: String = "c-line-doc") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    @Test @MainActor
    func consecutiveNativeStagePromptEditsKeepTheAcceptedSnapshotAndRejectExternalWriters() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("document-native-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsSuite = "document-native-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        defaults.set(MainPane.chat.rawValue, forKey: "minisCanvas.mainPane")
        let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        let store = SessionDocumentStore(directory: sessionRoot)
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: store,
            sessionStore: SessionStore(directory: sessionRoot),
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.layoutMode = .split
        let chat = bridge.chat
        let session = chat.applyNewSession(title: "owned stage binding")
        try #require(bridge.sessionDocuments === store && chat.activeSessionID == session)
        let tab = try store.newTab(sessionID: session, title: "owned", content: "owned source")
        let pipeline = DocumentPipeline(stages: [DocumentStage(name: "owned stage", promptTemplate: "Before {{input}}")])
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: pipeline,
            expectedRevision: tab.documentRevision, expectedPipeline: nil)
        let documentBytes = try Data(contentsOf: store.sessionFileURL(for: session))
        let lease = NativeTestHostLifecycle.begin("DocumentStageBinding")
        let controller = NSHostingController(rootView: ContentView(bridge: bridge))
        controller.sizingOptions = []
        let contentSize = NSSize(width: 1_280, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("document-stage-binding-" + lease.uuidString)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.contentViewController = controller
        window.setContentSize(contentSize)
        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        controller.view.display()
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            NativeTestHostLifecycle.end(window)
        }
        for _ in 0..<12 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        let initialHostIsQualified = window.isVisible && window.isKeyWindow && (NSApp?.isActive ?? false)
        try #require(initialHostIsQualified)
        let documents = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "chat.sessionDocuments"))
        try #require(NativeConsumerOwnedAX.role(documents) == .button && NativeConsumerOwnedAX.enabled(documents) == true)
        try #require(NativeConsumerOwnedAX.press(documents))
        for _ in 0..<12 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        let documentHostIsQualified = window.isVisible && window.isKeyWindow && (NSApp?.isActive ?? false)
        try #require(documentHostIsQualified && chat.activeSessionID == session)
        let toggle = try #require(NativeConsumerOwnedAX.find(in: window, identifier: "document.stages.toggle"))
        try #require(NativeConsumerOwnedAX.role(toggle) == .button && NativeConsumerOwnedAX.enabled(toggle) == true)
        try #require(NativeConsumerOwnedAX.press(toggle))
        for _ in 0..<12 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        let field = try #require(NativeConsumerOwnedAX.find(in: window,
            identifier: "document.stage.prompt." + pipeline.stages[0].id.uuidString))
        let ax = try #require(NativeConsumerOwnedAX.element(field))
        let hostIsQualified = window.isVisible && window.isKeyWindow && (NSApp?.isActive ?? false)
        try #require(hostIsQualified)
        try #require(AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success)
        let editor = try #require(window.firstResponder as? NSTextView)
        let native = try #require(editor.delegate as? NSTextField)
        let nativeBelongsToWindow = native.window === window
        let originalEditorIsCurrent = native.currentEditor() === editor
        try #require(editor.isFieldEditor && nativeBelongsToWindow && originalEditorIsCurrent)
        // Keep the very same native editor/binding without pumping a SwiftUI
        // replacement between callbacks. Both edits must reach the real Store.
        editor.insertText("First {{input}}", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let first = try #require(try store.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(first.stages[0].promptTemplate == "First {{input}}")
        let sameEditorIsCurrent = native.currentEditor() === editor
        try #require(sameEditorIsCurrent)
        editor.insertText("Second {{input}}", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let second = try #require(try store.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(second.stages[0].promptTemplate == "Second {{input}}")
        #expect(second.stages[0].id == pipeline.stages[0].id)
        #expect(try Data(contentsOf: store.sessionFileURL(for: session)) == documentBytes)
        // The View's accepted snapshot must never blindly rebase an external writer.
        let external = SessionDocumentStore(directory: sessionRoot)
        let externalTab = try #require(try external.documentStageState(sessionID: session).tabs.first)
        var replacement = try #require(externalTab.documentPipeline)
        replacement.stages[0].promptTemplate = "External writer must remain"
        _ = try external.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: replacement,
            expectedRevision: externalTab.documentRevision, expectedPipeline: externalTab.documentPipeline)
        editor.insertText("Must not overwrite external", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let retained = try #require(try external.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(retained == replacement)
        #expect(try Data(contentsOf: store.sessionFileURL(for: session)) == documentBytes)
    }

    @Test func savingStageInputPreservesRevisionWhileRealEditsAndABARejectLateResults() throws {
        let root = try makeDirectory("document-save-stage-input")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionDocumentStore(directory: root)
        let session = UUID()
        let tab = try store.newTab(sessionID: session, title: "owned", content: "owned unchanged input")
        let file = root.appendingPathComponent("owned.txt")
        let savedAs = try store.saveAs(sessionID: session, tabID: tab.id, to: file)
        let originalBytes = try Data(contentsOf: file)
        var a = DocumentPipeline(stages: [DocumentStage(name: "first", providerID: "owned", modelID: "one")])
        a.stages[0].promptTemplate = "A {{input}}"
        let acceptedA = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: a,
            expectedRevision: savedAs.documentRevision, expectedPipeline: nil)
        let saved = try store.save(sessionID: session, tabID: tab.id)
        #expect(saved.documentRevision == acceptedA.documentRevision)
        #expect(saved.updatedAt == acceptedA.updatedAt && saved.text == acceptedA.text && !saved.isDirty)
        let afterSave = try #require(try store.documentStageState(sessionID: session).tabs.first)
        #expect(afterSave.documentPipeline == a)
        var b = a
        b.stages[0].promptTemplate = "B {{input}}"
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: b,
            expectedRevision: saved.documentRevision, expectedPipeline: afterSave.documentPipeline)
        let cold = SessionDocumentStore(directory: root)
        let restored = try #require(try cold.documentStageState(sessionID: session).tabs.first)
        #expect(restored.documentPipeline == b && restored.documentRevision == saved.documentRevision)
        #expect(try Data(contentsOf: file) == originalBytes)
        let (running, run, input) = try cold.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 0, expectedRevision: restored.documentRevision, expectedStage: b.stages[0])
        #expect(input == saved.text && running.stages[0].promptTemplate == "B {{input}}")
        let changed = try cold.updateText(sessionID: session, tabID: tab.id, text: "owned changed input")
        #expect(changed.documentRevision != restored.documentRevision)
        let aba = try cold.updateText(sessionID: session, tabID: tab.id, text: saved.text)
        #expect(aba.documentRevision != changed.documentRevision && aba.documentRevision != restored.documentRevision)
        let late = try cold.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: b.stages[0].id, run: run, output: "late must not replace input", failure: nil)
        #expect(!late)
        #expect(cold.tab(sessionID: session, tabID: tab.id)?.text == saved.text)
        #expect(try Data(contentsOf: file) == originalBytes)
    }

    @Test(arguments: ["ready", "network", "http", "parse", "auth", "unknown"])
    func documentStageTypedFailuresRemainReadableAfterColdRestore(kind: String) async throws {
        let root = try makeDirectory("document-stage-safe-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionDocumentStore(directory: root)
        let session = UUID()
        let tab = try store.newTab(sessionID: session, title: "owned", content: "owned source")
        let pipeline = DocumentPipeline(stages: [DocumentStage(name: "first", providerID: "owned", modelID: "one")])
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: pipeline,
            expectedRevision: tab.documentRevision, expectedPipeline: nil)
        let (running, run, input) = try store.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 0, expectedRevision: tab.documentRevision, expectedStage: pipeline.stages[0])
        let privateDetail = "SYNTH_PRIVATE_SERVER_DETAIL https://user:password@example.test token=owned-secret"
        let error: any Error
        let expected: String
        switch kind {
        case "ready": error = ChildModelBindingError.notReady(privateDetail); expected = "DOC:model-not-ready"
        case "network": error = LLMError.networkError(underlying: URLError(.timedOut)); expected = "networkError"
        case "http": error = LLMError.httpStatus(code: 429, detail: privateDetail); expected = "HTTP 429"
        case "parse": error = LLMError.decodingError(underlying: NSError(domain: privateDetail, code: 1)); expected = "decodingError"
        case "auth": error = LLMError.invalidAPIKey(detail: privateDetail); expected = "invalidAPIKey"
        default: error = NSError(domain: privateDetail, code: 1, userInfo: [NSLocalizedDescriptionKey: privateDetail]); expected = "DOC:unknown"
        }
        var displayed: String?
        do {
            _ = try await DocumentStageRunner.runSessionStage(pipeline: running, index: 0,
                documentContent: input, llm: { _ in throw error })
            Issue.record("The real runner must throw the controlled typed failure")
        } catch {
            displayed = DocumentStageRunner.userFailureMessage(error) + " 原结果保留。"
        }
        let failure = try #require(displayed)
        #expect(failure.contains(expected))
        #expect(!failure.contains(privateDetail) && !failure.contains("owned-secret") && !failure.contains("example.test"))
        let finished = try store.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: running.stages[0].id, run: run, output: nil, failure: failure)
        #expect(finished)
        let reader = SessionDocumentStore(directory: root)
        let restored = try #require(try reader.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(restored.stages[0].execution?.state == .failed)
        #expect(restored.stages[0].execution?.failureMessage == failure)
        #expect(restored.stages[0].status == .pending && restored.stages[0].output.isEmpty)
        #expect(reader.tab(sessionID: session, tabID: tab.id)?.text == "owned source")
        let duplicate = try reader.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: running.stages[0].id, run: run, output: "late", failure: nil)
        #expect(!duplicate)
    }

    @Test func documentStageRunnerPersistsReviewAndRetryWithoutRewritingCompletedOutput() async throws {
        let root = try makeDirectory("document-stages-production")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionDocumentStore(directory: root)
        let session = UUID()
        let tab = try store.newTab(sessionID: session, title: "owned", content: "owned source")
        let originalBytes = try Data(contentsOf: store.sessionFileURL(for: session))
        let pipeline = DocumentPipeline(stages: [DocumentStage(name: "first", providerID: "owned", modelID: "one"),
                                                 DocumentStage(name: "second", providerID: "owned", modelID: "one")])
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: pipeline,
            expectedRevision: tab.documentRevision, expectedPipeline: nil)
        let (first, run, input) = try store.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 0, expectedRevision: tab.documentRevision, expectedStage: pipeline.stages[0])
        let llm = MockStageLLM(outputs: ["first result"])
        let output = try await DocumentStageRunner.runSessionStage(pipeline: first, index: 0,
            documentContent: input, llm: llm.call)
        #expect(try store.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: first.stages[0].id, run: run, output: output, failure: nil))
        #expect(!(try store.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: first.stages[0].id, run: run, output: "duplicate", failure: nil)))
        #expect(try Data(contentsOf: store.sessionFileURL(for: session)) == originalBytes)
        let resultDocument = try store.newTab(sessionID: session, title: "first result", content: output)
        let destination = root.appendingPathComponent("stage-result.txt")
        _ = try store.saveAs(sessionID: session, tabID: resultDocument.id, to: destination)
        let documentBytesAfterExplicitExport = try Data(contentsOf: store.sessionFileURL(for: session))
        var reviewed = try #require(try store.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(reviewed.stages[0].execution?.state == .succeeded)
        #expect(reviewed.stages[0].status == .awaitingReview)
        DocumentStageRunner.confirmStage(pipeline: &reviewed, index: 0)
        let previous = try #require(try store.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: reviewed,
            expectedRevision: tab.documentRevision, expectedPipeline: previous)
        let (second, failedRun, secondInput) = try store.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 1, expectedRevision: tab.documentRevision, expectedStage: reviewed.stages[1])
        #expect(secondInput == tab.text)
        let failing = MockStageLLM(shouldThrow: true)
        await #expect(throws: DocumentStageError.self) {
            _ = try await DocumentStageRunner.runSessionStage(pipeline: second, index: 1,
                documentContent: secondInput, llm: failing.call)
        }
        #expect(try store.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: second.stages[1].id, run: failedRun, output: nil, failure: "owned failure"))
        let reader = SessionDocumentStore(directory: root)
        let restored = try #require(try reader.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(restored.stages[0].status == .done && restored.stages[0].output == "first result")
        #expect(restored.stages[1].execution?.state == .failed)
        let (retry, retryRun, retryInput) = try reader.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 1, expectedRevision: tab.documentRevision, expectedStage: restored.stages[1])
        let retryLLM = MockStageLLM(outputs: ["second result"])
        let retried = try await DocumentStageRunner.runSessionStage(pipeline: retry, index: 1,
            documentContent: retryInput, llm: retryLLM.call)
        #expect(try reader.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: retry.stages[1].id, run: retryRun, output: retried, failure: nil))
        #expect(llm.callCount == 1 && failing.callCount == 1 && retryLLM.callCount == 1)
        #expect(retryLLM.lastPrompt?.contains("first result") == true)
        #expect(try Data(contentsOf: store.sessionFileURL(for: session)) == documentBytesAfterExplicitExport)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first result")
        let final = try #require(try reader.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(throws: DocumentStageError.self) {
            _ = try reader.beginDocumentStage(sessionID: session, tabID: tab.id,
                index: 0, expectedRevision: tab.documentRevision, expectedStage: final.stages[0])
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "first result")
    }

    @Test func documentStageReopenFailsInterruptedRunAndRejectsLateEditedInput() throws {
        let root = try makeDirectory("document-stage-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionDocumentStore(directory: root)
        let session = UUID()
        let tab = try store.newTab(sessionID: session, title: "owned", content: "before")
        let pipeline = DocumentPipeline(stages: [DocumentStage(name: "first", providerID: "owned", modelID: "one")])
        _ = try store.setDocumentPipeline(sessionID: session, tabID: tab.id, pipeline: pipeline,
            expectedRevision: tab.documentRevision, expectedPipeline: nil)
        let (_, run, _) = try store.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 0, expectedRevision: tab.documentRevision, expectedStage: pipeline.stages[0])
        _ = try store.updateText(sessionID: session, tabID: tab.id, text: "after")
        #expect(!(try store.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: pipeline.stages[0].id, run: run, output: "late", failure: nil)))
        let current = try #require(try store.documentStageState(sessionID: session).tabs.first)
        #expect(current.text == "after" && current.documentPipeline?.stages[0].output.isEmpty == true)
        let currentPipeline = try #require(current.documentPipeline)
        let (_, interrupted, _) = try store.beginDocumentStage(sessionID: session, tabID: tab.id,
            index: 0, expectedRevision: current.documentRevision, expectedStage: currentPipeline.stages[0])
        let reopened = SessionDocumentStore(directory: root)
        try reopened.recoverInterruptedDocumentStages(sessionID: session)
        let recovered = try #require(try reopened.documentStageState(sessionID: session).tabs.first?.documentPipeline)
        #expect(recovered.stages[0].execution?.id == interrupted.id)
        #expect(recovered.stages[0].execution?.state == .failed)
        #expect(reopened.tab(sessionID: session, tabID: tab.id)?.text == "after")
        let checkpoint = root.appendingPathComponent("document-stages/" + session.uuidString + ".json")
        let link = root.appendingPathComponent("stage-hardlink.json")
        try FileManager.default.linkItem(at: checkpoint, to: link)
        #expect(throws: SessionDocumentStoreError.self) {
            _ = try reopened.documentStageState(sessionID: session)
        }
        try FileManager.default.removeItem(at: link)
        #expect(try reopened.closeTab(sessionID: session, tabID: tab.id, decision: .discard) == .closed)
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        #expect((raw["pipelines"] as? [String: Any])?.isEmpty == true)
        #expect(!(try reopened.finishDocumentStage(sessionID: session, tabID: tab.id,
            stageID: pipeline.stages[0].id, run: interrupted, output: "late after close", failure: nil)))
        let ordinary = try reopened.newTab(sessionID: session, title: "ordinary after stage failure", content: "keep original flow")
        let damagedStage = Data("{owned damaged stage checkpoint".utf8)
        try damagedStage.write(to: checkpoint, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.path)
        #expect(try reopened.closeTab(sessionID: session, tabID: ordinary.id, decision: .discard) == .closed)
        #expect(reopened.documentStageCloseWarning(sessionID: session) != nil)
        #expect(try Data(contentsOf: checkpoint) == damagedStage)
    }

    /// Keep the original encoder's byte ordering/escaping while changing one
    /// scalar. Recovery journals are intentionally canonical, so rebuilding
    /// them through JSONSerialization would test a different representation.
    private func replacingJSONStringValue(
        _ field: String,
        in data: Data,
        with newValue: String
    ) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        let marker = "\"\(field)\":\""
        guard let markerRange = text.range(of: marker),
              let end = text[markerRange.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        let replaced = String(text[..<markerRange.upperBound])
            + newValue
            + String(text[end...])
        return Data(replaced.utf8)
    }

    @Test func stableDarwinAliasAndResolvedRootShareRestartState() throws {
        let parent = try makeDirectory("c-line-document-darwin-alias")
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("state", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        guard case .resolved(let resolvedPath) = DarwinSystemPathResolver.resolveOutcome(directory) else {
            Issue.record("temporary directory did not resolve through the stable Darwin alias contract")
            return
        }
        let resolvedDirectory = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        let sessionID = UUID()
        let writer = SessionDocumentStore(directory: directory)
        let tab = try writer.newTab(
            sessionID: sessionID,
            title: "Darwin alias",
            content: "same filesystem identity"
        )

        let restarted = SessionDocumentStore(directory: resolvedDirectory)
        #expect(writer.directory.path == resolvedPath)
        #expect(restarted.directory.path == resolvedPath)
        #expect(writer.sessionFileURL(for: sessionID).path.hasPrefix(resolvedPath + "/"))
        #expect(restarted.tab(sessionID: sessionID, tabID: tab.id) == tab)
        var writerInfo = stat()
        var restartedInfo = stat()
        #expect(lstat(writer.documentsDirectory.path, &writerInfo) == 0)
        #expect(lstat(restarted.documentsDirectory.path, &restartedInfo) == 0)
        #expect(writerInfo.st_dev == restartedInfo.st_dev)
        #expect(writerInfo.st_ino == restartedInfo.st_ino)

        try FileManager.default.removeItem(at: resolvedDirectory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let recreatedSessionID = UUID()
        let recreated = SessionDocumentStore(directory: directory)
        let recreatedTab = try recreated.newTab(
            sessionID: recreatedSessionID,
            title: "Recreated Darwin alias",
            content: "stable mapped namespace"
        )
        #expect(recreated.directory.path == resolvedPath)
        #expect(recreated.tab(sessionID: recreatedSessionID, tabID: recreatedTab.id) == recreatedTab)
    }

    @Test func legitimateDirectoryMembershipChangesPersistAndQuarantine() throws {
        let directory = try makeDirectory("c-line-directory-membership")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        var beforeMembers = stat()
        #expect(lstat(store.documentsDirectory.path, &beforeMembers) == 0)

        let tab = try store.newTab(
            sessionID: sessionID,
            title: "Directory membership",
            content: "first"
        )
        _ = try store.updateText(
            sessionID: sessionID, tabID: tab.id, text: "second"
        )
        let saved = try store.save(sessionID: sessionID, tabID: tab.id)
        #expect(saved.text == "second")
        #expect(!saved.isDirty)

        var afterMembers = stat()
        #expect(lstat(store.documentsDirectory.path, &afterMembers) == 0)
        #expect(afterMembers.st_dev == beforeMembers.st_dev)
        #expect(afterMembers.st_ino == beforeMembers.st_ino)
        #expect(afterMembers.st_uid == beforeMembers.st_uid)
        #expect((afterMembers.st_mode & 0o777) == (beforeMembers.st_mode & 0o777))
        #expect(afterMembers.st_nlink != beforeMembers.st_nlink)

        let restarted = SessionDocumentStore(directory: directory)
        #expect(restarted.tab(sessionID: sessionID, tabID: tab.id)?.text == "second")

        let corruptSessionID = UUID()
        let corruptURL = restarted.sessionFileURL(for: corruptSessionID)
        let corruptData = Data("{invalid session state".utf8)
        try corruptData.write(to: corruptURL, options: .atomic)
        #expect(restarted.state(for: corruptSessionID).tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: restarted.quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        #expect(try Data(contentsOf: quarantined[0]) == corruptData)
        #expect(restarted.tab(sessionID: sessionID, tabID: tab.id)?.text == "second")
    }

    @Test func multipleTabsEditDirtySaveAndSnapshotAreSessionScoped() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)

        let first = try store.newTab(
            sessionID: sessionID, title: "大纲", content: "第一版"
        )
        let second = try store.newTab(
            sessionID: sessionID, title: "分镜", content: "镜头一"
        )
        _ = try store.newTab(
            sessionID: otherSessionID, title: "另一会话", content: "隔离内容"
        )

        #expect(store.state(for: sessionID).tabs.count == 2)
        #expect(store.state(for: otherSessionID).tabs.count == 1)
        #expect(store.state(for: sessionID).selectedTabID == second.id)

        let edited = try store.updateText(
            sessionID: sessionID, tabID: first.id, text: "第二版"
        )
        #expect(edited.isDirty)

        let snapshot = try store.sendToConversation(
            sessionID: sessionID, tabID: first.id
        )
        #expect(snapshot.text == "第二版")
        #expect(snapshot.sessionID == sessionID)
        #expect(snapshot.tabID == first.id)

        _ = try store.save(sessionID: sessionID, tabID: first.id)
        #expect(store.tab(sessionID: sessionID, tabID: first.id)?.isDirty == false)
        #expect(snapshot.text == "第二版", "发送快照必须是不可变值，不随后续编辑变化")
    }

    @Test func openEditSaveAsAndRestartRestoreDirtyState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sourceURL = directory.appendingPathComponent("原稿.md")
        let savedAsURL = directory.appendingPathComponent("另存稿.md")
        try Data("原稿内容".utf8).write(to: sourceURL, options: .atomic)

        let store = SessionDocumentStore(directory: directory)
        let tab = try store.openDocument(sessionID: sessionID, fileURL: sourceURL)
        #expect(tab.title == "原稿")
        #expect(!tab.isDirty)

        _ = try store.updateText(
            sessionID: sessionID, tabID: tab.id, text: "恢复中的修改"
        )
        #expect(store.tab(sessionID: sessionID, tabID: tab.id)?.isDirty == true)

        // 模拟崩溃：编辑已经以原子方式写入会话恢复文件，但用户 Save 尚未完成。
        let restarted = SessionDocumentStore(directory: directory)
        let recovered = try #require(
            restarted.tab(sessionID: sessionID, tabID: tab.id)
        )
        #expect(recovered.text == "恢复中的修改")
        #expect(recovered.isDirty)

        let saved = try restarted.saveAs(
            sessionID: sessionID, tabID: tab.id, to: savedAsURL
        )
        let mappedSavedAsPath = try #require(
            DarwinSystemPathResolver.resolveOutcome(savedAsURL).path
        )
        let mappedSavedAsURL = URL(fileURLWithPath: mappedSavedAsPath)
        #expect(saved.title == "另存稿")
        #expect(saved.fileURL == mappedSavedAsURL)
        #expect(!saved.isDirty)
        #expect(String(data: try Data(contentsOf: savedAsURL), encoding: .utf8) == "恢复中的修改")

        let reopened = SessionDocumentStore(directory: directory)
        let restored = try #require(reopened.tab(sessionID: sessionID, tabID: tab.id))
        #expect(restored.text == "恢复中的修改")
        #expect(restored.fileURL == mappedSavedAsURL)
        #expect(!restored.isDirty)
    }

    @Test func openDocumentRejectsOversizedExternalFileWithoutReadingUnbounded() throws {
        let directory = try makeDirectory("c-line-document-open-size")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let sourceURL = directory.appendingPathComponent("oversized.md")
        let oversizedData = Data(
            repeating: UInt8(ascii: "x"),
            count: 8 * 1024 * 1024 + 1
        )
        try oversizedData.write(to: sourceURL, options: .atomic)
        let mappedSourcePath = try #require(
            DarwinSystemPathResolver.resolveOutcome(sourceURL).path
        )
        let mappedSourceURL = URL(fileURLWithPath: mappedSourcePath)

        #expect(throws: SessionDocumentStoreError.cannotRead(mappedSourceURL)) {
            _ = try store.openDocument(sessionID: sessionID, fileURL: sourceURL)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try Data(contentsOf: sourceURL) == oversizedData)
        #expect(store.state(for: sessionID).tabs.isEmpty)
    }

    @Test func openDocumentRejectsSymlinkedParentWithoutReadingOutside() throws {
        let directory = try makeDirectory("c-line-document-open-parent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let outsideDirectory = directory.appendingPathComponent(
            "outside", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true
        )
        let outsideFile = outsideDirectory.appendingPathComponent("source.md")
        let outsideData = Data("outside document".utf8)
        try outsideData.write(to: outsideFile, options: .atomic)
        let redirectedParent = directory.appendingPathComponent(
            "redirected", isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: redirectedParent, withDestinationURL: outsideDirectory
        )
        let escapedSource = redirectedParent.appendingPathComponent("source.md")

        #expect(throws: SessionDocumentStoreError.cannotRead(escapedSource)) {
            _ = try store.openDocument(
                sessionID: sessionID, fileURL: escapedSource
            )
        }
        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(try Data(contentsOf: outsideFile) == outsideData)
    }

    @Test func saveAsRejectsSymlinkedParentWithoutWritingOutside() throws {
        let directory = try makeDirectory("c-line-document-save-parent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let tab = try store.newTab(
            sessionID: sessionID,
            title: "恢复文档",
            content: "不得写入目录外"
        )
        let outsideDirectory = directory.appendingPathComponent(
            "outside", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true
        )
        let redirectedParent = directory.appendingPathComponent(
            "redirected", isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: redirectedParent,
            withDestinationURL: outsideDirectory
        )
        let escapedTarget = redirectedParent.appendingPathComponent("saved.md")

        let mappedPath: String? = if case .resolved(let path) =
            DarwinSystemPathResolver.resolveOutcome(escapedTarget) { path } else { nil }
        let mappedTarget = URL(fileURLWithPath: try #require(mappedPath))
        #expect(throws: SessionDocumentStoreError.cannotWrite(mappedTarget)) {
            _ = try store.saveAs(
                sessionID: sessionID,
                tabID: tab.id,
                to: escapedTarget
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outsideDirectory.appendingPathComponent("saved.md").path
            )
        )
        #expect(store.tab(sessionID: sessionID, tabID: tab.id)?.fileURL == nil)
        #expect(store.tab(sessionID: sessionID, tabID: tab.id)?.isDirty == false)
    }

    @Test func openDocumentDeduplicatesCanonicalURLAcrossRestart() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sourceURL = directory.appendingPathComponent("原稿.md")
        let sourcePath = sourceURL.path
        let aliasPath: String
        if sourcePath.hasPrefix("/private/var/") {
            aliasPath = String(sourcePath.dropFirst("/private".count))
        } else {
            try #require(sourcePath.hasPrefix("/var/"))
            aliasPath = "/private" + sourcePath
        }
        let aliasURL = URL(fileURLWithPath: aliasPath)
        let traversalURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("原稿.md")
        let originalData = Data("原稿内容".utf8)
        try originalData.write(to: sourceURL, options: .atomic)

        let store = SessionDocumentStore(directory: directory)
        let first = try store.openDocument(sessionID: sessionID, fileURL: sourceURL)
        let duplicate = try store.openDocument(sessionID: sessionID, fileURL: aliasURL)
        #expect(duplicate.id == first.id)
        #expect(store.state(for: sessionID).tabs.count == 1)
        #expect(store.state(for: sessionID).selectedTabID == first.id)

        #expect(throws: SessionDocumentStoreError.cannotRead(traversalURL)) {
            _ = try store.openDocument(sessionID: sessionID, fileURL: traversalURL)
        }
        #expect(store.state(for: sessionID).tabs.map(\.id) == [first.id])
        #expect(try Data(contentsOf: sourceURL) == originalData)

        let restarted = SessionDocumentStore(directory: directory)
        let reopened = try restarted.openDocument(sessionID: sessionID, fileURL: aliasURL)
        #expect(reopened.id == first.id)
        #expect(restarted.state(for: sessionID).tabs.count == 1)
        #expect(restarted.state(for: sessionID).selectedTabID == first.id)
    }

    @Test func snapshotRevisionFencesEditedAndMovedDocuments() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let tab = try store.newTab(sessionID: sessionID, title: "文档", content: "初稿")

        let snapshot = try store.sendToConversation(sessionID: sessionID, tabID: tab.id)
        #expect(!snapshot.revision.isEmpty)
        #expect(store.isCurrent(snapshot))

        _ = try store.updateText(sessionID: sessionID, tabID: tab.id, text: "新稿")
        #expect(!store.isCurrent(snapshot), "旧快照不能接受后续阶段结果")
        _ = try store.updateText(sessionID: sessionID, tabID: tab.id, text: "初稿")
        #expect(!store.isCurrent(snapshot), "revision 回退到旧文本也不能复活旧快照")

        let restarted = SessionDocumentStore(directory: directory)
        let reopenedSnapshot = try restarted.sendToConversation(
            sessionID: sessionID, tabID: tab.id
        )
        #expect(reopenedSnapshot.revision != snapshot.revision)
        #expect(restarted.isCurrent(reopenedSnapshot))

        let foreignTab = try store.newTab(
            sessionID: otherSessionID, title: "外部", content: "不应显示"
        )
        let foreignState = SessionDocumentSessionState(
            sessionID: sessionID,
            tabs: [foreignTab],
            selectedTabID: foreignTab.id
        )
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(foreignState).write(
            to: store.sessionFileURL(for: sessionID), options: .atomic
        )

        let reopened = SessionDocumentStore(directory: directory)
        #expect(
            reopened.state(for: sessionID).tabs.isEmpty,
            "foreign document tab must be quarantined on session reopen"
        )
        #expect(!reopened.isCurrent(snapshot))
    }

    @Test func closeRequiresConfirmationAndSupportsCancelDiscardAndSave() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let tab = try store.newTab(sessionID: sessionID, title: "文档", content: "初稿")
        _ = try store.updateText(sessionID: sessionID, tabID: tab.id, text: "修改")

        #expect(
            try store.closeTab(sessionID: sessionID, tabID: tab.id) == .requiresConfirmation
        )
        #expect(
            try store.closeTab(
                sessionID: sessionID, tabID: tab.id, decision: .cancel
            ) == .canceled
        )
        #expect(store.tab(sessionID: sessionID, tabID: tab.id) != nil)
        #expect(
            try store.closeTab(
                sessionID: sessionID, tabID: tab.id, decision: .discard
            ) == .closed
        )
        #expect(store.tab(sessionID: sessionID, tabID: tab.id) == nil)

        let savedTab = try store.newTab(sessionID: sessionID, title: "保存后关闭", content: "v1")
        _ = try store.updateText(sessionID: sessionID, tabID: savedTab.id, text: "v2")
        #expect(
            try store.closeTab(
                sessionID: sessionID, tabID: savedTab.id, decision: .save
            ) == .closed
        )
        #expect(store.tab(sessionID: sessionID, tabID: savedTab.id) == nil)
        #expect(SessionDocumentStore(directory: directory).state(for: sessionID).tabs.isEmpty)
    }

    @Test func duplicateDocumentIDsAreQuarantinedOnSessionRestore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let first = SessionDocumentTab(
            id: UUID(), sessionID: sessionID, title: "第一份", text: "one"
        )
        let duplicate = SessionDocumentTab(
            id: first.id, sessionID: sessionID, title: "第二份", text: "two"
        )
        let state = SessionDocumentSessionState(
            sessionID: sessionID, tabs: [first, duplicate], selectedTabID: duplicate.id
        )
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(
            to: store.sessionFileURL(for: sessionID), options: .atomic
        )

        let reopened = SessionDocumentStore(directory: directory)
        #expect(reopened.state(for: sessionID).tabs.isEmpty)
        #expect(!reopened.isCurrent(
            SessionDocumentTextSnapshot(
                sessionID: sessionID, tabID: first.id, title: first.title, text: first.text
            )
        ))
    }

    @Test func replacedExternalDocumentIsQuarantinedOnSessionRestore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let sourceURL = directory.appendingPathComponent("原稿.md")
        try Data("原稿内容".utf8).write(to: sourceURL, options: .atomic)
        let store = SessionDocumentStore(directory: directory)
        let tab = try store.openDocument(sessionID: sessionID, fileURL: sourceURL)

        try FileManager.default.removeItem(at: sourceURL)
        try Data("原稿内容".utf8).write(to: sourceURL, options: .atomic)

        let reopened = SessionDocumentStore(directory: directory)
        #expect(reopened.state(for: sessionID).tabs.isEmpty)
        #expect(tab.fileIdentity != nil)
    }

    @Test func strictRecoveryDecodeRejectsOversizedDuplicateAndTrailingJSON() throws {
        let directory = try makeDirectory("c-line-strict-json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let state = SessionDocumentSessionState(sessionID: sessionID)
        let valid = try JSONEncoder().encode(state)
        let duplicate = Data(
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[],\"tabs\":[],\"selectedTabID\":null}".utf8
        )
        let escapedDuplicate = Data(
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[],\"\\u0074abs\":[],\"selectedTabID\":null}".utf8
        )
        let unknown = Data(
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[],\"selectedTabID\":null,\"futureField\":true}".utf8
        )
        var trailing = valid
        trailing.append(contentsOf: Data(" {}".utf8))
        let oversized = Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)
        let deeplyNested = Data(
            (String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8
        )
        let numericOverflow = Data(
            "{\"schemaVersion\":1e309,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[],\"selectedTabID\":null}".utf8
        )
        var invalidUTF8 = Data(
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[{\"id\":\"\(UUID().uuidString)\",\"sessionID\":\"\(sessionID.uuidString)\",\"title\":\"".utf8
        )
        invalidUTF8.append(contentsOf: [0xC3, 0x28])
        invalidUTF8.append(contentsOf: Data("\",\"text\":\"\",\"savedText\":\"\",\"createdAt\":0,\"updatedAt\":0}],\"selectedTabID\":null}".utf8))
        let invalidSurrogate = Data(
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[{\"id\":\"\(UUID().uuidString)\",\"sessionID\":\"\(sessionID.uuidString)\",\"title\":\"\\uD800\",\"text\":\"\",\"savedText\":\"\",\"createdAt\":0,\"updatedAt\":0}],\"selectedTabID\":null}".utf8
        )
        let escapedAmplification = Data((
            "{\"schemaVersion\":1,\"sessionID\":\"\(sessionID.uuidString)\",\"tabs\":[{\"id\":\"\(UUID().uuidString)\",\"sessionID\":\"\(sessionID.uuidString)\",\"title\":\""
            + String(repeating: "\\u0074", count: 200_000)
            + "\",\"text\":\"\",\"savedText\":\"\",\"createdAt\":0,\"updatedAt\":0}],\"selectedTabID\":null}"
        ).utf8)
        let aggregateStrings = try JSONEncoder().encode(
            SessionDocumentSessionState(
                sessionID: sessionID,
                tabs: (0..<4_000).map { _ in
                    SessionDocumentTab(
                        sessionID: sessionID,
                        title: String(repeating: "t", count: 1_200)
                    )
                }
            )
        )
        #expect(aggregateStrings.count > 4 * 1024 * 1024)
        #expect(aggregateStrings.count <= 8 * 1024 * 1024)

        for (index, fixture) in [
            duplicate, escapedDuplicate, trailing, oversized, unknown,
            deeplyNested, numericOverflow, invalidUTF8, invalidSurrogate,
            escapedAmplification, aggregateStrings
        ].enumerated() {
            try FileManager.default.createDirectory(
                at: store.documentsDirectory, withIntermediateDirectories: true
            )
            try fixture.write(
                to: store.sessionFileURL(for: sessionID), options: .atomic
            )
            let reopened = SessionDocumentStore(directory: directory)
            #expect(
                reopened.state(for: sessionID).tabs.isEmpty,
                "fixture \(index) must quarantine instead of partially decoding"
            )
            #expect(
                reopened.hasRecoveryFailure(for: sessionID),
                "fixture \(index) must be surfaced as a recovery failure, not a normal empty session"
            )
        }
    }

    @Test func unknownSchemaSelectedDeletionAndRevisionRegressionFailClosed() throws {
        let directory = try makeDirectory("c-line-strict-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let unknownSchema = SessionDocumentSessionState(schemaVersion: 2, sessionID: sessionID)
        let selectedDeleted = SessionDocumentSessionState(
            sessionID: sessionID, selectedTabID: UUID()
        )
        let regressed = SessionDocumentSessionState(
            sessionID: sessionID,
            tabs: [SessionDocumentTab(
                sessionID: sessionID,
                title: "回退",
                createdAt: Date(timeIntervalSinceReferenceDate: 10),
                updatedAt: Date(timeIntervalSinceReferenceDate: 9)
            )]
        )

        for state in [unknownSchema, selectedDeleted, regressed] {
            try FileManager.default.createDirectory(
                at: store.documentsDirectory, withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(
                to: store.sessionFileURL(for: sessionID), options: .atomic
            )
            #expect(SessionDocumentStore(directory: directory).state(for: sessionID).tabs.isEmpty)
        }
    }

    @Test func concurrentStoreStaleBaselineFailsClosedWithoutLostUpdate() throws {
        let directory = try makeDirectory("c-line-concurrent-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let firstStore = SessionDocumentStore(directory: directory)
        let staleStore = SessionDocumentStore(directory: directory)

        #expect(firstStore.state(for: sessionID).tabs.isEmpty)
        #expect(staleStore.state(for: sessionID).tabs.isEmpty)
        let firstTab = try firstStore.newTab(
            sessionID: sessionID, title: "先写入", content: "保留这次更新"
        )

        do {
            _ = try staleStore.newTab(
                sessionID: sessionID, title: "陈旧写入", content: "不能覆盖"
            )
            #expect(Bool(false), "stale baseline must not overwrite the durable state")
        } catch let error as SessionDocumentStoreError {
            #expect(error == .cannotWrite(staleStore.sessionFileURL(for: sessionID)))
        }

        #expect(firstStore.tab(sessionID: sessionID, tabID: firstTab.id) != nil)
        let recovered = SessionDocumentStore(directory: directory)
        #expect(recovered.state(for: sessionID).tabs.map(\.id) == [firstTab.id])
    }

    @Test func recoveryLockSymlinkAndHardLinkAreRejected() throws {
        let directory = try makeDirectory("c-line-lock-fence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        let lockURL = store.sessionFileURL(for: sessionID).appendingPathExtension("lock")
        let targetURL = directory.appendingPathComponent("unrelated-lock-target")
        try Data("unrelated".utf8).write(to: targetURL, options: .atomic)

        try FileManager.default.createSymbolicLink(
            at: lockURL, withDestinationURL: targetURL
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(lockURL)) {
            _ = try store.newTab(sessionID: sessionID, title: "拒绝符号链接")
        }

        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.linkItem(at: targetURL, to: lockURL)
        #expect(throws: SessionDocumentStoreError.cannotWrite(lockURL)) {
            _ = try store.newTab(sessionID: sessionID, title: "拒绝硬链接")
        }
    }

    @Test func corruptSessionFileIsQuarantinedWithoutCreatingWorkspaceState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        try Data("{bad document state".utf8).write(
            to: store.sessionFileURL(for: sessionID), options: .atomic
        )

        #expect(store.state(for: sessionID).tabs.isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: store.quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)
        #expect(!store.hasWorkspaceState, "会话文档不能引入独立 workspace 状态")
    }

    @Test func corruptSessionFileLeavesEvidenceWhenQuarantinePathIsReplaced() throws {
        let directory = try makeDirectory("c-line-recovery-quarantine-path")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        let corruptedURL = store.sessionFileURL(for: sessionID)
        let corruptedData = Data("{bad document state}".utf8)
        try corruptedData.write(to: corruptedURL, options: .atomic)
        let outsideDirectory = directory.appendingPathComponent(
            "outside-quarantine", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: store.quarantineDirectory,
            withDestinationURL: outsideDirectory
        )

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        #expect(FileManager.default.fileExists(atPath: corruptedURL.path))
        #expect(try Data(contentsOf: corruptedURL) == corruptedData)
        let outsideEntries = try FileManager.default.contentsOfDirectory(
            at: outsideDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(outsideEntries.isEmpty)
    }

    @Test func quarantinedRecoveryFailureSurvivesRestartUntilNewStateIsSaved() throws {
        let directory = try makeDirectory("c-line-recovery-visibility")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let firstStore = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: firstStore.documentsDirectory, withIntermediateDirectories: true
        )
        try Data("{broken recovery snapshot".utf8).write(
            to: firstStore.sessionFileURL(for: sessionID), options: .atomic
        )

        #expect(firstStore.state(for: sessionID).tabs.isEmpty)
        #expect(firstStore.hasRecoveryFailure(for: sessionID))

        let restarted = SessionDocumentStore(directory: directory)
        #expect(restarted.state(for: sessionID).tabs.isEmpty)
        #expect(
            restarted.hasRecoveryFailure(for: sessionID),
            "重启后隔离备份仍须让用户知道原会话恢复失败"
        )

        let replacement = try restarted.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "重新开始"
        )
        #expect(!restarted.hasRecoveryFailure(for: sessionID))

        let reopened = SessionDocumentStore(directory: directory)
        #expect(reopened.state(for: sessionID).tabs.map(\.id) == [replacement.id])
        #expect(!reopened.hasRecoveryFailure(for: sessionID))
    }

    @Test func recoveryCleanupIsSessionScopedAfterReplacementStateIsSaved() throws {
        let directory = try makeDirectory("c-line-recovery-cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        for sessionID in [firstSessionID, otherSessionID] {
            try Data("{broken \(sessionID.uuidString) recovery snapshot".utf8).write(
                to: store.sessionFileURL(for: sessionID), options: .atomic
            )
            #expect(store.state(for: sessionID).tabs.isEmpty)
            #expect(store.hasRecoveryFailure(for: sessionID))
        }

        let restarted = SessionDocumentStore(directory: directory)
        _ = restarted.state(for: firstSessionID)
        _ = restarted.state(for: otherSessionID)
        let replacement = try restarted.newTab(
            sessionID: firstSessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(replacement.sessionID == firstSessionID)
        #expect(!restarted.hasRecoveryFailure(for: firstSessionID))
        #expect(restarted.hasRecoveryFailure(for: otherSessionID))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: restarted.quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(
            quarantined.allSatisfy {
                !$0.lastPathComponent.hasPrefix("\(firstSessionID.uuidString)-")
            },
            "恢复当前文档不能清理其他 session 的隔离备份"
        )
        #expect(
            quarantined.contains {
                $0.lastPathComponent.hasPrefix("\(otherSessionID.uuidString)-")
            }
        )
    }

    @Test func recoveryCleanupLeavesOtherSessionReceiptSetUntouched() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-fence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let ownArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try Data("current session recovery artifact".utf8).write(
            to: ownArtifact, options: .atomic
        )
        let otherArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(otherSessionID.uuidString)-\(UUID().uuidString).json"
        )
        let otherData = Data("other writer recovery artifact".utf8)
        try otherData.write(to: otherArtifact, options: .atomic)

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(!store.hasRecoveryFailure(for: sessionID))
        #expect(!FileManager.default.fileExists(atPath: ownArtifact.path))
        #expect(FileManager.default.fileExists(atPath: otherArtifact.path))
        #expect(
            try Data(contentsOf: otherArtifact) == otherData,
            "receipt set fence 不能清理另一 session 的新内容"
        )
    }

    @Test func recoveryCleanupRejectsReplacedSymlinkEscapeAndKeepsOtherSessionWarning() throws {
        let directory = try makeDirectory("c-line-recovery-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let outsideTarget = directory.appendingPathComponent("outside-recovery.json")
        try Data("must remain outside quarantine".utf8).write(
            to: outsideTarget, options: .atomic
        )
        let escapedArtifactID = UUID()
        let escapedArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(firstSessionID.uuidString)-\(escapedArtifactID.uuidString).json"
        )
        try Data("original recovery artifact".utf8).write(
            to: escapedArtifact, options: .atomic
        )
        try FileManager.default.removeItem(at: escapedArtifact)
        try FileManager.default.createSymbolicLink(
            at: escapedArtifact, withDestinationURL: outsideTarget
        )
        let userArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(firstSessionID.uuidString)-user-file.json"
        )
        try Data("user file".utf8).write(to: userArtifact, options: .atomic)
        let otherArtifactID = UUID()
        let otherArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(otherSessionID.uuidString)-\(otherArtifactID.uuidString).json"
        )
        try Data("other session recovery".utf8).write(
            to: otherArtifact, options: .atomic
        )

        #expect(store.state(for: firstSessionID).tabs.isEmpty)
        #expect(store.state(for: otherSessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: firstSessionID))
        #expect(store.hasRecoveryFailure(for: otherSessionID))

        let stateURL = store.sessionFileURL(for: firstSessionID)
        let stateExisted = FileManager.default.fileExists(atPath: stateURL.path)
        let stateBytes = stateExisted ? try Data(contentsOf: stateURL) : nil
        let rejectionURL = store.documentsDirectory.appendingPathComponent(
            "\(firstSessionID.uuidString).cleanup-diagnostic.json"
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(rejectionURL)) {
            _ = try store.newTab(
                sessionID: firstSessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path) == stateExisted)
        if let stateBytes {
            #expect(try Data(contentsOf: stateURL) == stateBytes)
        }

        #expect(
            store.hasRecoveryFailure(for: firstSessionID),
            "隔离清理遇到符号链接时必须保留当前 session 告警"
        )
        #expect(store.hasRecoveryFailure(for: otherSessionID))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: escapedArtifact.path)
                == outsideTarget.path
        )
        #expect(
            try Data(contentsOf: outsideTarget) == Data("must remain outside quarantine".utf8),
            "清理不能跟随隔离文件符号链接删除目录外目标"
        )
        #expect(FileManager.default.fileExists(atPath: userArtifact.path))
        #expect(FileManager.default.fileExists(atPath: otherArtifact.path))
    }

    @Test func symlinkedQuarantineDirectoryKeepsRecoveryWarningWithoutFollowingOutside() throws {
        let directory = try makeDirectory("c-line-recovery-quarantine-directory-symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.documentsDirectory, withIntermediateDirectories: true
        )
        let outsideDirectory = directory.appendingPathComponent(
            "outside-quarantine", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory, withIntermediateDirectories: true
        )
        let outsideArtifact = outsideDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        let outsideData = Data("outside quarantine evidence".utf8)
        try outsideData.write(to: outsideArtifact, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: store.quarantineDirectory,
            withDestinationURL: outsideDirectory
        )

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "不安全的 quarantine 目录必须保留可见恢复告警"
        )
        #expect(
            throws: SessionDocumentStoreError.cannotWrite(store.quarantineDirectory)
        ) {
            _ = try store.newTab(
                sessionID: sessionID,
                title: "拒绝不安全隔离目录",
                content: "不得写入"
            )
        }
        #expect(
            try Data(contentsOf: outsideArtifact) == outsideData,
            "告警探测不能把目录外证据当作可清理 quarantine"
        )
    }

    @Test func restartedRecoveryCleanupRecognizesOwnedTombstoneOnly() throws {
        let directory = try makeDirectory("c-line-recovery-tombstone")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let ownedData = Data("owned tombstone after interrupted cleanup".utf8)
        let ownedSource = store.quarantineDirectory.appendingPathComponent("owned-source")
        try ownedData.write(to: ownedSource, options: .atomic)
        var ownedInfo = stat()
        #expect(lstat(ownedSource.path, &ownedInfo) == 0)
        let ownedDigest = SHA256.hash(data: ownedData)
            .map { String(format: "%02x", $0) }.joined()
        let ownedTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(firstSessionID.uuidString)_\(firstSessionID.uuidString)_\(ownedInfo.st_dev)_\(ownedInfo.st_ino)_\(ownedDigest)_\(UUID().uuidString).json"
        )
        try FileManager.default.moveItem(at: ownedSource, to: ownedTombstone)
        let userFile = store.quarantineDirectory.appendingPathComponent(
            "\(firstSessionID.uuidString)-user-file.json"
        )
        try Data("do not clean user file".utf8).write(to: userFile, options: .atomic)
        let forgedTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(firstSessionID.uuidString)_\(firstSessionID.uuidString)_1_1_\(String(repeating: "0", count: 64))_\(UUID().uuidString).json"
        )
        try Data("forged receipt payload".utf8).write(
            to: forgedTombstone, options: .atomic
        )
        let otherTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(otherSessionID.uuidString)_\(otherSessionID.uuidString)_1_1_\(String(repeating: "0", count: 64))_\(UUID().uuidString).json"
        )
        try Data("other session tombstone".utf8).write(
            to: otherTombstone, options: .atomic
        )

        #expect(store.state(for: firstSessionID).tabs.isEmpty)
        #expect(store.state(for: otherSessionID).tabs.isEmpty)
        let restarted = SessionDocumentStore(directory: directory)
        #expect(restarted.state(for: firstSessionID).tabs.isEmpty)
        #expect(restarted.hasRecoveryFailure(for: firstSessionID))
        #expect(restarted.hasRecoveryFailure(for: otherSessionID))

        _ = try restarted.newTab(
            sessionID: firstSessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(
            restarted.hasRecoveryFailure(for: firstSessionID),
            "伪造 receipt 必须保留当前 session 告警"
        )
        #expect(!FileManager.default.fileExists(atPath: ownedTombstone.path))
        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(FileManager.default.fileExists(atPath: forgedTombstone.path))
        #expect(FileManager.default.fileExists(atPath: otherTombstone.path))
        #expect(restarted.hasRecoveryFailure(for: otherSessionID))
    }

    @Test func recoveryCleanupRejectsSameLengthReceiptABATamper() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-aba")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("0123456789abcdef".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        let tamperedData = Data("fedcba9876543210".utf8)
        #expect(tamperedData.count == originalData.count)
        let descriptor = open(
            tombstone.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            defer { _ = close(descriptor) }
            let written = tamperedData.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return write(descriptor, baseAddress, rawBuffer.count)
            }
            #expect(written == tamperedData.count)
            #expect(fsync(descriptor) == 0)
        }

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "receipt 内容同长 ABA 替换必须保留告警并 fail-closed"
        )
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == tamperedData)

        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        let diagnosticData = try Data(contentsOf: diagnosticURL)
        let diagnosticMessage = store.recoveryDiagnostic(for: sessionID)
        #expect(diagnosticMessage != nil)
        let preparedObject = try #require(
            JSONSerialization.jsonObject(with: diagnosticData)
                as? [String: Any]
        )
        #expect(preparedObject["phase"] as? String == "prepared")
        #expect(preparedObject["checkpointEpoch"] as? String
            == preparedObject["generation"] as? String)
        #expect(preparedObject["receiptDigest"] as? String
            == preparedObject["canonicalPayload"] as? String)

        let restarted = SessionDocumentStore(directory: directory)
        #expect(restarted.recoveryDiagnostic(for: sessionID) == diagnosticMessage)
        #expect(try Data(contentsOf: diagnosticURL) == diagnosticData)
        let diagnosticNames = try FileManager.default.contentsOfDirectory(
            at: restarted.documentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".cleanup-diagnostic.json") }
        #expect(diagnosticNames.count == 1)
        _ = try restarted.newTab(
            sessionID: sessionID, title: "再次恢复", content: "仍保留告警"
        )
        let afterRestartNames = try FileManager.default.contentsOfDirectory(
            at: restarted.documentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".cleanup-diagnostic.json") }
        #expect(afterRestartNames.count == 1)
        #expect(try Data(contentsOf: diagnosticURL) == diagnosticData)

        // Simulate a crash after the prepared unlink but before the commit
        // marker: the target is gone, so restart may only finalize the journal.
        try FileManager.default.removeItem(at: tombstone)
        _ = try restarted.newTab(
            sessionID: sessionID, title: "完成恢复", content: "清理已提交"
        )
        #expect(!restarted.hasRecoveryFailure(for: sessionID))
        #expect(restarted.recoveryDiagnostic(for: sessionID) == nil)
        #expect(FileManager.default.fileExists(atPath: diagnosticURL.path))

        let committedDiagnostic = try Data(contentsOf: diagnosticURL)
        let stableStateURL = restarted.sessionFileURL(for: sessionID)
        let stableStateBytes = try Data(contentsOf: stableStateURL)
        let rolloverPayload = try #require(
            replacingJSONStringValue(
                "canonicalPayload",
                in: committedDiagnostic,
                with: String(repeating: "f", count: 64)
            )
        )
        let rolloverDiagnostic = try #require(
            replacingJSONStringValue(
                "receiptDigest",
                in: rolloverPayload,
                with: String(repeating: "f", count: 64)
            )
        )
        try rolloverDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try restarted.newTab(
                sessionID: sessionID,
                title: "拒绝 checkpoint rollover 替换",
                content: "证据不变"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        #expect(try Data(contentsOf: diagnosticURL) == rolloverDiagnostic)
        try committedDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        let committedObject = try #require(
            JSONSerialization.jsonObject(with: committedDiagnostic)
                as? [String: Any]
        )
        let committedGeneration = try #require(
            committedObject["generation"] as? String
        )
        #expect(committedObject["checkpointEpoch"] as? String == committedGeneration)
        let committedReceiptDigest = try #require(
            committedObject["receiptDigest"] as? String
        )
        #expect(committedReceiptDigest
            == committedObject["canonicalPayload"] as? String)
        let secondOriginalData = Data("second-receipt-original".utf8)
        let secondSource = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try secondOriginalData.write(to: secondSource, options: .atomic)
        var secondSourceInfo = stat()
        #expect(lstat(secondSource.path, &secondSourceInfo) == 0)
        let secondDigest = SHA256.hash(data: secondOriginalData)
            .map { String(format: "%02x", $0) }.joined()
        let secondTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(secondSourceInfo.st_dev)_\(secondSourceInfo.st_ino)_\(secondDigest)_\(UUID().uuidString).json"
        )
        try FileManager.default.moveItem(at: secondSource, to: secondTombstone)
        let secondTamperedData = Data("second-receipt-tampered".utf8)
        #expect(secondTamperedData.count == secondOriginalData.count)
        try secondTamperedData.write(to: secondTombstone, options: .atomic)

        // A canonical document with the same generation but a divergent
        // previousDigest is a replay/fork candidate, not a new cleanup turn.
        // Replace the bytes in place so mode and inode remain unchanged while
        // the durable state floor still points at the committed journal.
        let divergentDiagnostic = try #require(
            replacingJSONStringValue(
                "previousDigest",
                in: committedDiagnostic,
                with: String(repeating: "f", count: 64)
            )
        )
        #expect(divergentDiagnostic.count == committedDiagnostic.count)
        let divergentDescriptor = open(
            diagnosticURL.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(divergentDescriptor >= 0)
        if divergentDescriptor >= 0 {
            defer { _ = close(divergentDescriptor) }
            let written = divergentDiagnostic.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return write(divergentDescriptor, baseAddress, rawBuffer.count)
            }
            #expect(written == divergentDiagnostic.count)
            #expect(fsync(divergentDescriptor) == 0)
        }
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try restarted.newTab(
                sessionID: sessionID, title: "拒绝同代分叉", content: "证据不变"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        #expect(try Data(contentsOf: diagnosticURL) == divergentDiagnostic)
        let restoreDescriptor = open(
            diagnosticURL.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(restoreDescriptor >= 0)
        if restoreDescriptor >= 0 {
            defer { _ = close(restoreDescriptor) }
            let written = committedDiagnostic.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return write(restoreDescriptor, baseAddress, rawBuffer.count)
            }
            #expect(written == committedDiagnostic.count)
            #expect(fsync(restoreDescriptor) == 0)
        }

        _ = try restarted.newTab(
            sessionID: sessionID, title: "后续隔离", content: "继续保留证据"
        )
        #expect(restarted.hasRecoveryFailure(for: sessionID))
        let successorDiagnostic = try Data(contentsOf: diagnosticURL)
        let successorObject = try #require(
            JSONSerialization.jsonObject(with: successorDiagnostic)
                as? [String: Any]
        )
        let successorGeneration = try #require(
            successorObject["generation"] as? String
        )
        #expect(UInt64(successorGeneration)! > UInt64(committedGeneration)!)
        #expect(successorObject["checkpointEpoch"] as? String == successorGeneration)
        #expect(successorObject["receiptDigest"] as? String
            == successorObject["canonicalPayload"] as? String)
        let committedDigest = SHA256.hash(data: committedDiagnostic)
            .map { String(format: "%02x", $0) }.joined()
        #expect(successorObject["previousDigest"] as? String == committedDigest)

        _ = try restarted.newTab(
            sessionID: sessionID, title: "后续重试", content: "同一候选幂等"
        )
        #expect(try Data(contentsOf: diagnosticURL) == successorDiagnostic)
        try FileManager.default.removeItem(at: secondTombstone)
        _ = try restarted.newTab(
            sessionID: sessionID, title: "后续完成", content: "清理已提交"
        )
        _ = try restarted.newTab(
            sessionID: sessionID, title: "完成收尾", content: "receipt ledger 已清理"
        )
        #expect(!FileManager.default.fileExists(atPath: diagnosticURL.path))
    }

    @Test func recoveryCleanupDoesNotTreatNonCanonicalArtifactUUIDAsOwned() throws {
        let directory = try makeDirectory("c-line-recovery-noncanonical-artifact")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let ownedArtifactID = UUID()
        let userArtifactID = UUID()
        let numericArtifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let ownedArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(ownedArtifactID.uuidString).json"
        )
        let ownedData = Data("owned recovery evidence".utf8)
        try ownedData.write(to: ownedArtifact, options: .atomic)
        let userArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(userArtifactID.uuidString.lowercased()).json"
        )
        let userData = Data("user recovery evidence".utf8)
        try userData.write(to: userArtifact, options: .atomic)
        let tombstoneSource = store.quarantineDirectory.appendingPathComponent(
            "user-tombstone-source"
        )
        let tombstoneData = Data("user tombstone evidence".utf8)
        try tombstoneData.write(to: tombstoneSource, options: .atomic)
        var tombstoneInfo = stat()
        #expect(lstat(tombstoneSource.path, &tombstoneInfo) == 0)
        let tombstoneDigest = SHA256.hash(data: tombstoneData)
            .map { String(format: "%02x", $0) }.joined()
        let nonCanonicalTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(tombstoneInfo.st_dev)_\(tombstoneInfo.st_ino)_\(tombstoneDigest)_\(userArtifactID.uuidString.lowercased()).json"
        )
        try FileManager.default.moveItem(
            at: tombstoneSource, to: nonCanonicalTombstone
        )
        let digestSource = store.quarantineDirectory.appendingPathComponent(
            "uppercase-digest-source"
        )
        let digestData = Data("uppercase digest evidence".utf8)
        try digestData.write(to: digestSource, options: .atomic)
        var digestInfo = stat()
        #expect(lstat(digestSource.path, &digestInfo) == 0)
        let digest = SHA256.hash(data: digestData)
            .map { String(format: "%02x", $0) }.joined()
        let uppercaseDigestTombstone = store.quarantineDirectory
            .appendingPathComponent(
                "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(digestInfo.st_dev)_\(digestInfo.st_ino)_\(digest.uppercased())_\(UUID().uuidString).json"
            )
        try FileManager.default.moveItem(
            at: digestSource, to: uppercaseDigestTombstone
        )
        let numericSource = store.quarantineDirectory.appendingPathComponent(
            "numeric-source"
        )
        let numericData = Data("noncanonical identity evidence".utf8)
        try numericData.write(to: numericSource, options: .atomic)
        var numericInfo = stat()
        #expect(lstat(numericSource.path, &numericInfo) == 0)
        let numericDigest = SHA256.hash(data: numericData)
            .map { String(format: "%02x", $0) }.joined()
        let leadingZeroTombstone = store.quarantineDirectory
            .appendingPathComponent(
                "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_0\(numericInfo.st_dev)_0\(numericInfo.st_ino)_\(numericDigest)_\(numericArtifactID.uuidString).json"
            )
        try FileManager.default.moveItem(
            at: numericSource, to: leadingZeroTombstone
        )

        #expect(store.state(for: sessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复文档", content: "清理合法证据"
        )

        #expect(!FileManager.default.fileExists(atPath: ownedArtifact.path))
        #expect(FileManager.default.fileExists(atPath: userArtifact.path))
        #expect(try Data(contentsOf: userArtifact) == userData)
        #expect(FileManager.default.fileExists(atPath: nonCanonicalTombstone.path))
        #expect(try Data(contentsOf: nonCanonicalTombstone) == tombstoneData)
        #expect(
            FileManager.default.fileExists(atPath: uppercaseDigestTombstone.path)
        )
        #expect(try Data(contentsOf: uppercaseDigestTombstone) == digestData)
        #expect(FileManager.default.fileExists(atPath: leadingZeroTombstone.path))
        #expect(try Data(contentsOf: leadingZeroTombstone) == numericData)
    }

    @Test func recoveryCleanupRejectsDuplicateReceiptArtifactUUID() throws {
        let directory = try makeDirectory("c-line-recovery-duplicate-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let payloads = [Data("first duplicate receipt".utf8), Data("second duplicate receipt".utf8)]
        var tombstones: [URL] = []
        for payload in payloads {
            let source = store.quarantineDirectory.appendingPathComponent(
                "\(sessionID.uuidString)-\(UUID().uuidString).json"
            )
            try payload.write(to: source, options: .atomic)
            var sourceInfo = stat()
            #expect(lstat(source.path, &sourceInfo) == 0)
            let digest = SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }.joined()
            let tombstone = store.quarantineDirectory.appendingPathComponent(
                "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
            )
            try FileManager.default.moveItem(at: source, to: tombstone)
            tombstones.append(tombstone)
        }

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        #expect(throws: SessionDocumentStoreError.cannotWrite(store.quarantineDirectory)) {
            _ = try store.newTab(
                sessionID: sessionID,
                title: "拒绝重复 receipt UUID",
                content: "稳定 bytes 不变"
            )
        }
        #expect(tombstones.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try Data(contentsOf: tombstones[0]) == payloads[0])
        #expect(try Data(contentsOf: tombstones[1]) == payloads[1])
    }

    @Test func recoveryCleanupRejectsPostCleanupTombstoneResurrection() throws {
        let directory = try makeDirectory("c-line-recovery-tombstone-resurrection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("receipt cleaned once".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        #expect(store.state(for: sessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: sessionID, title: "首次清理", content: "旧证据已提交"
        )
        _ = try store.newTab(
            sessionID: sessionID, title: "清理收尾", content: "旧 receipt ledger 已清理"
        )
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))

        let stableStateURL = store.sessionFileURL(for: sessionID)
        let stableStateBytes = try Data(contentsOf: stableStateURL)
        let resurrectedData = Data("resurrected receipt".utf8)
        let resurrectedSource = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-new-source.json"
        )
        try resurrectedData.write(to: resurrectedSource, options: .atomic)
        var resurrectedInfo = stat()
        #expect(lstat(resurrectedSource.path, &resurrectedInfo) == 0)
        let resurrectedDigest = SHA256.hash(data: resurrectedData)
            .map { String(format: "%02x", $0) }.joined()
        let resurrectedTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(resurrectedInfo.st_dev)_\(resurrectedInfo.st_ino)_\(resurrectedDigest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: resurrectedSource, to: resurrectedTombstone)
        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )

        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID,
                title: "拒绝清理重生 receipt",
                content: "稳定 state 不变"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        #expect(FileManager.default.fileExists(atPath: resurrectedTombstone.path))
        #expect(try Data(contentsOf: resurrectedTombstone) == resurrectedData)

        let restarted = SessionDocumentStore(directory: directory)
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try restarted.newTab(
                sessionID: sessionID,
                title: "重启后仍拒绝重生 receipt",
                content: "不 replay 旧 artifact ID"
            )
        }
        #expect(FileManager.default.fileExists(atPath: resurrectedTombstone.path))
        #expect(try Data(contentsOf: resurrectedTombstone) == resurrectedData)
    }

    @Test func recoveryCleanupRejectsOldCheckpointTombstoneSubstitution() throws {
        let directory = try makeDirectory("c-line-recovery-checkpoint-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let firstArtifactID = UUID()
        let secondArtifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        func addTombstone(artifactID: UUID, payload: Data) throws -> URL {
            let source = store.quarantineDirectory.appendingPathComponent(
                "\(sessionID.uuidString)-\(UUID().uuidString).json"
            )
            try payload.write(to: source, options: .atomic)
            var sourceInfo = stat()
            #expect(lstat(source.path, &sourceInfo) == 0)
            let digest = SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }.joined()
            let tombstone = store.quarantineDirectory.appendingPathComponent(
                "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
            )
            try FileManager.default.moveItem(at: source, to: tombstone)
            return tombstone
        }

        let firstTombstone = try addTombstone(
            artifactID: firstArtifactID, payload: Data("first epoch".utf8)
        )
        #expect(store.state(for: sessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: sessionID, title: "第一代清理", content: "epoch one"
        )
        _ = try store.newTab(
            sessionID: sessionID, title: "第一代收尾", content: "epoch one done"
        )
        #expect(!FileManager.default.fileExists(atPath: firstTombstone.path))

        let secondTombstone = try addTombstone(
            artifactID: secondArtifactID, payload: Data("second epoch".utf8)
        )
        _ = try store.newTab(
            sessionID: sessionID, title: "第二代清理", content: "epoch two"
        )
        _ = try store.newTab(
            sessionID: sessionID, title: "第二代收尾", content: "epoch two done"
        )
        #expect(!FileManager.default.fileExists(atPath: secondTombstone.path))
        let checkpointState = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: store.sessionFileURL(for: sessionID))
            ) as? [String: Any]
        )
        let checkpointHistory = try #require(
            checkpointState["recoveryCheckpointHistory"] as? [[String: Any]]
        )
        #expect(checkpointHistory.count == 2)
        #expect(
            checkpointHistory.compactMap { ($0["epoch"] as? NSNumber)?.intValue }
                == [1, 2]
        )
        #expect(checkpointHistory.allSatisfy {
            ($0["artifactIDs"] as? [String])?.count == 1
        })
        let firstCheckpoint = try #require(checkpointHistory.first)
        let secondCheckpoint = try #require(checkpointHistory.last)
        #expect(
            firstCheckpoint["previousManifestRoot"] as? String
                == String(repeating: "0", count: 64)
        )
        #expect(
            firstCheckpoint["previousReceiptDigest"] as? String
                == String(repeating: "0", count: 64)
        )
        #expect(
            secondCheckpoint["previousManifestRoot"] as? String
                == firstCheckpoint["manifestRoot"] as? String
        )
        #expect(
            secondCheckpoint["previousReceiptDigest"] as? String
                == firstCheckpoint["receiptDigest"] as? String
        )
        let canonicalHistoryBytes = try JSONSerialization.data(
            withJSONObject: checkpointHistory, options: [.sortedKeys]
        )
        let historyDigest = SHA256.hash(data: canonicalHistoryBytes)
            .map { String(format: "%02x", $0) }.joined()
        #expect(
            checkpointState["recoveryCheckpointHistoryDigest"] as? String
                == historyDigest
        )

        let stableStateURL = store.sessionFileURL(for: sessionID)
        let stableStateBytes = try Data(contentsOf: stableStateURL)
        let resurrectedData = Data("old epoch resurrection".utf8)
        let resurrectedSource = store.quarantineDirectory.appendingPathComponent(
            "resurrected-source.json"
        )
        try resurrectedData.write(to: resurrectedSource, options: .atomic)
        var resurrectedInfo = stat()
        #expect(lstat(resurrectedSource.path, &resurrectedInfo) == 0)
        let resurrectedDigest = SHA256.hash(data: resurrectedData)
            .map { String(format: "%02x", $0) }.joined()
        let resurrectedTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(resurrectedInfo.st_dev)_\(resurrectedInfo.st_ino)_\(resurrectedDigest)_\(firstArtifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: resurrectedSource, to: resurrectedTombstone)
        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )

        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID,
                title: "拒绝旧 epoch receipt",
                content: "history CAS"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        #expect(FileManager.default.fileExists(atPath: resurrectedTombstone.path))
        #expect(try Data(contentsOf: resurrectedTombstone) == resurrectedData)

        let restarted = SessionDocumentStore(directory: directory)
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try restarted.newTab(
                sessionID: sessionID,
                title: "重启后拒绝旧 epoch receipt",
                content: "history persists"
            )
        }
        #expect(FileManager.default.fileExists(atPath: resurrectedTombstone.path))
        #expect(try Data(contentsOf: resurrectedTombstone) == resurrectedData)
    }

    @Test func recoveryCommittedDiagnosticCompletesDurableCheckpointAfterRestart() throws {
        let directory = try makeDirectory("c-line-recovery-committed-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("receipt-cleaned-once".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        let tamperedData = Data("receipt-altered-once".utf8)
        #expect(tamperedData.count == originalData.count)
        try tamperedData.write(to: tombstone, options: .atomic)
        _ = try store.newTab(
            sessionID: sessionID,
            title: "准备恢复",
            content: "保留 prepared marker"
        )

        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        let preparedData = try Data(contentsOf: diagnosticURL)
        #expect(String(decoding: preparedData, as: UTF8.self).contains(
            "\"phase\":\"prepared\""
        ))
        try FileManager.default.removeItem(at: tombstone)
        let committedData = try #require(
            replacingJSONStringValue("phase", in: preparedData, with: "committed")
        )
        try committedData.write(to: diagnosticURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: diagnosticURL.path
        )

        let restarted = SessionDocumentStore(directory: directory)
        _ = try restarted.newTab(
            sessionID: sessionID,
            title: "完成恢复",
            content: "checkpoint durable"
        )

        #expect(!FileManager.default.fileExists(atPath: diagnosticURL.path))
        let persistedState = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: restarted.sessionFileURL(for: sessionID))
            ) as? [String: Any]
        )
        #expect((persistedState["recoveryGeneration"] as? NSNumber)?.uint64Value == 1)
        #expect((persistedState["recoveryCheckpointEpoch"] as? NSNumber)?.uint64Value == 1)
        let history = try #require(
            persistedState["recoveryCheckpointHistory"] as? [[String: Any]]
        )
        #expect(history.count == 1)
        #expect((history.first?["epoch"] as? NSNumber)?.uint64Value == 1)
        #expect(persistedState["recoveryDiagnosticDigest"] as? String != nil)
        #expect(persistedState["recoveryCheckpointHistoryDigest"] as? String != nil)
    }

    @Test func recoveryFailureDiscoveredDuringMutationRemainsVisible() throws {
        let directory = try makeDirectory("c-line-recovery-mutation-warning")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        _ = store.state(for: sessionID)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("mutation-recovery-original".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)
        let tamperedData = Data("mutation-recovery-tampered".utf8)
        #expect(tamperedData.count == originalData.count)
        try tamperedData.write(to: tombstone, options: .atomic)

        _ = try store.newTab(
            sessionID: sessionID,
            title: "操作中发现恢复异常",
            content: "用户仍需看到告警"
        )

        #expect(store.hasRecoveryFailure(for: sessionID))
        #expect(store.recoveryDiagnostic(for: sessionID) != nil)
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == tamperedData)
    }

    @Test func malformedCleanupDiagnosticRemainsVisibleAndBlocksWrites() throws {
        let directory = try makeDirectory("c-line-recovery-malformed-diagnostic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        _ = try store.newTab(
            sessionID: sessionID,
            title: "稳定文档",
            content: "原有状态必须保持"
        )
        let stableStateURL = store.sessionFileURL(for: sessionID)
        let stableStateBytes = try Data(contentsOf: stableStateURL)
        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        let malformedDiagnostic = Data("{\"phase\":\"committed\"}".utf8)
        try malformedDiagnostic.write(to: diagnosticURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: diagnosticURL.path
        )

        let restarted = SessionDocumentStore(directory: directory)
        #expect(!restarted.state(for: sessionID).tabs.isEmpty)
        #expect(restarted.hasRecoveryFailure(for: sessionID))
        #expect(restarted.recoveryDiagnostic(for: sessionID) != nil)
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try restarted.newTab(
                sessionID: sessionID,
                title: "拒绝损坏诊断",
                content: "稳定状态不变"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        #expect(try Data(contentsOf: diagnosticURL) == malformedDiagnostic)
    }

    @Test func recoveryDiagnosticWriteFailureBlocksCleanup() throws {
        let directory = try makeDirectory("c-line-recovery-diagnostic-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let artifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        let artifactData = Data("quarantined-document".utf8)
        try artifactData.write(to: artifact, options: .atomic)

        let outside = directory.appendingPathComponent("diagnostic-target")
        let outsideData = Data("user-owned-diagnostic-target".utf8)
        try outsideData.write(to: outside, options: .atomic)
        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        try FileManager.default.createSymbolicLink(
            at: diagnosticURL, withDestinationURL: outside
        )

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }

        #expect(FileManager.default.fileExists(atPath: artifact.path))
        #expect(try Data(contentsOf: artifact) == artifactData)
        #expect(try Data(contentsOf: outside) == outsideData)
        #expect(FileManager.default.fileExists(atPath: diagnosticURL.path))
    }

    @Test func recoveryDiagnosticRejectsStaleGenerationBeforeCleanup() throws {
        let directory = try makeDirectory("c-line-recovery-diagnostic-generation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("generation-bound-receipt".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        let tamperedData = Data("generation-bound-receipt!".utf8)
        #expect(tamperedData.count == originalData.count + 1)
        try tamperedData.write(to: tombstone, options: .atomic)
        #expect(store.state(for: sessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "新状态"
        )
        #expect(store.hasRecoveryFailure(for: sessionID))

        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        let canonicalDiagnostic = try Data(contentsOf: diagnosticURL)
        let stableStateURL = store.sessionFileURL(for: sessionID)
        let stableStateBytes = try Data(contentsOf: stableStateURL)
        let canonicalObject = try #require(
            JSONSerialization.jsonObject(with: canonicalDiagnostic)
                as? [String: Any]
        )
        let canonicalSegments = try #require(
            canonicalObject["segmentPayloadIdentities"] as? [String: Any]
        )
        let firstSegmentName = try #require(canonicalSegments.keys.first)
        var missingSegmentObject = canonicalObject
        var missingSegments = canonicalSegments
        missingSegments.removeValue(forKey: firstSegmentName)
        missingSegmentObject["segmentPayloadIdentities"] = missingSegments
        let missingSegmentDiagnostic = try JSONSerialization.data(
            withJSONObject: missingSegmentObject, options: [.sortedKeys]
        )
        try missingSegmentDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "缺失 segment", content: "不得清理"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        var extraSegmentObject = canonicalObject
        var extraSegments = canonicalSegments
        extraSegments["unexpected-segment"] = canonicalSegments[firstSegmentName]
        extraSegmentObject["segmentPayloadIdentities"] = extraSegments
        let extraSegmentDiagnostic = try JSONSerialization.data(
            withJSONObject: extraSegmentObject, options: [.sortedKeys]
        )
        try extraSegmentDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "额外 segment", content: "不得清理"
            )
        }
        #expect(try Data(contentsOf: stableStateURL) == stableStateBytes)
        try canonicalDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        let staleData = try #require(
            replacingJSONStringValue(
                "generation",
                in: canonicalDiagnostic,
                with: String(repeating: "f", count: 64)
            )
        )
        try staleData.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )

        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "再次恢复", content: "不得清理"
            )
        }

        let canonicalText = String(decoding: canonicalDiagnostic, as: UTF8.self)
        let unknownData = Data(
            canonicalText.replacingOccurrences(
                of: "\"message\":",
                with: "\"unknownKey\":true,\"message\":"
            ).utf8
        )
        try unknownData.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "未知字段", content: "不得清理"
            )
        }

        let duplicateData = Data(
            canonicalText.replacingOccurrences(
                of: "\"phase\":\"prepared\"",
                with: "\"phase\":\"prepared\",\"phase\":\"prepared\""
            ).utf8
        )
        try duplicateData.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "重复字段", content: "不得清理"
            )
        }

        var oversizedDiagnostic = canonicalDiagnostic
        oversizedDiagnostic.append(
            Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        )
        try oversizedDiagnostic.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "超大诊断", content: "不得清理"
            )
        }
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == tamperedData)
        #expect(try Data(contentsOf: diagnosticURL) == oversizedDiagnostic)
    }

    @Test func recoveryDiagnosticRejectsCrossSessionReplayBeforeCleanup() throws {
        let directory = try makeDirectory("c-line-recovery-diagnostic-cross-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerSessionID = UUID()
        let targetSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let ownerTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(ownerSessionID.uuidString)_\(ownerSessionID.uuidString)_1_1_\(String(repeating: "0", count: 64))_\(UUID().uuidString).json"
        )
        let targetTombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(targetSessionID.uuidString)_\(targetSessionID.uuidString)_1_1_\(String(repeating: "0", count: 64))_\(UUID().uuidString).json"
        )
        try Data("owner receipt".utf8).write(to: ownerTombstone, options: .atomic)
        try Data("target receipt".utf8).write(to: targetTombstone, options: .atomic)

        #expect(store.state(for: ownerSessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: ownerSessionID, title: "拥有者", content: "保留证据"
        )
        let ownerDiagnostic = store.documentsDirectory.appendingPathComponent(
            "\(ownerSessionID.uuidString).cleanup-diagnostic.json"
        )
        let targetDiagnostic = store.documentsDirectory.appendingPathComponent(
            "\(targetSessionID.uuidString).cleanup-diagnostic.json"
        )
        try Data(contentsOf: ownerDiagnostic).write(to: targetDiagnostic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: targetDiagnostic.path
        )

        #expect(store.state(for: targetSessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: targetSessionID))
        #expect(throws: SessionDocumentStoreError.cannotWrite(targetDiagnostic)) {
            _ = try store.newTab(
                sessionID: targetSessionID, title: "被复用", content: "不得清理"
            )
        }
        #expect(FileManager.default.fileExists(atPath: ownerTombstone.path))
        #expect(FileManager.default.fileExists(atPath: targetTombstone.path))
        #expect(FileManager.default.fileExists(atPath: targetDiagnostic.path))
    }

    @Test func committedRecoveryDiagnosticRejectsReplacementAfterUnlink() throws {
        let directory = try makeDirectory("c-line-recovery-diagnostic-committed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("committed-receipt".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)
        try Data("committed-receipt!".utf8).write(to: tombstone, options: .atomic)
        #expect(store.state(for: sessionID).tabs.isEmpty)
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "准备清理"
        )

        let diagnosticURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        let canonicalDiagnostic = try Data(contentsOf: diagnosticURL)
        try FileManager.default.removeItem(at: tombstone)
        let replacementData = Data("new-user-file".utf8)
        try replacementData.write(to: tombstone, options: .atomic)
        let committedData = try #require(
            replacingJSONStringValue(
                "phase", in: canonicalDiagnostic, with: "committed"
            )
        )
        try committedData.write(to: diagnosticURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path
        )

        #expect(throws: SessionDocumentStoreError.cannotWrite(diagnosticURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "再次恢复", content: "不得删除替换文件"
            )
        }
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == replacementData)
        #expect(FileManager.default.fileExists(atPath: diagnosticURL.path))
    }

    @Test func recoveryCleanupRejectsReceiptReplacementBeforeUnlinking() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-replaced")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalData = Data("receipt-original".utf8)
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try originalData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        let replacementData = Data("receipt-mutated!".utf8)
        #expect(replacementData.count == originalData.count)
        try replacementData.write(to: tombstone, options: .atomic)

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        _ = try store.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "receipt 同名替换必须在容量 digest fence 处保留告警"
        )
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == replacementData)
    }

    @Test func recoveryCleanupDoesNotPartiallyUnlinkOnReceiptEntryDrift() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-entry-drift")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        let stableTab = try store.newTab(sessionID: sessionID, title: "原文档", content: "原始内容")
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )
        let validArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        let validData = Data("valid evidence".utf8)
        try validData.write(to: validArtifact, options: .atomic)
        let outside = directory.appendingPathComponent("outside-entry-drift.json")
        let outsideData = Data("outside evidence".utf8)
        try outsideData.write(to: outside, options: .atomic)
        let escapedArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try FileManager.default.createSymbolicLink(
            at: escapedArtifact, withDestinationURL: outside
        )

        #expect(store.state(for: sessionID).tabs.map(\.id) == [stableTab.id])
        #expect(store.hasRecoveryFailure(for: sessionID))
        let stateURL = store.sessionFileURL(for: sessionID)
        let stateExisted = FileManager.default.fileExists(atPath: stateURL.path)
        let stateBytes = stateExisted ? try Data(contentsOf: stateURL) : nil
        let rejectionURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(rejectionURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path) == stateExisted)
        if let stateBytes {
            #expect(try Data(contentsOf: stateURL) == stateBytes)
        }

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "receipt entry 漂移必须在任何 partial unlink 前 fail-closed"
        )
        #expect(store.state(for: sessionID).tabs.map(\.id) == [stableTab.id])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: escapedArtifact.path) == outside.path)
        #expect(FileManager.default.fileExists(atPath: validArtifact.path))
        #expect(try Data(contentsOf: validArtifact) == validData)
        #expect(
            try Data(contentsOf: outside) == outsideData,
            "entry drift 不能触碰目录外证据"
        )
    }

    @Test func recoveryCleanupRejectsOversizedReceiptWithoutUnlinking() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-size")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let oversizedData = Data(
            repeating: UInt8(ascii: "x"),
            count: 8 * 1024 * 1024 + 1
        )
        let source = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try oversizedData.write(to: source, options: .atomic)
        var sourceInfo = stat()
        #expect(lstat(source.path, &sourceInfo) == 0)
        let digest = SHA256.hash(data: oversizedData)
            .map { String(format: "%02x", $0) }.joined()
        let tombstone = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(sourceInfo.st_dev)_\(sourceInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        try FileManager.default.moveItem(at: source, to: tombstone)

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        let stateURL = store.sessionFileURL(for: sessionID)
        let stateExisted = FileManager.default.fileExists(atPath: stateURL.path)
        let stateBytes = stateExisted ? try Data(contentsOf: stateURL) : nil
        let rejectionURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(rejectionURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path) == stateExisted)
        if let stateBytes {
            #expect(try Data(contentsOf: stateURL) == stateBytes)
        }

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "超大 receipt 必须在流式读取上限处 fail-closed"
        )
        #expect(FileManager.default.fileExists(atPath: tombstone.path))
        #expect(try Data(contentsOf: tombstone) == oversizedData)
        let attributes = try FileManager.default.attributesOfItem(atPath: tombstone.path)
        #expect(
            (attributes[.size] as? NSNumber)?.intValue == oversizedData.count
        )
    }

    @Test func recoveryCleanupRejectsReceiptCountOverflowWithoutUnlinking() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-count")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )
        let ownArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try Data("keep this recovery evidence".utf8).write(
            to: ownArtifact, options: .atomic
        )
        for index in 0...4_096 {
            let filler = store.quarantineDirectory.appendingPathComponent(
                "unowned-receipt-\(index).json"
            )
            try Data("filler".utf8).write(to: filler, options: .atomic)
        }

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        let stateURL = store.sessionFileURL(for: sessionID)
        let stateExisted = FileManager.default.fileExists(atPath: stateURL.path)
        let stateBytes = stateExisted ? try Data(contentsOf: stateURL) : nil
        let rejectionURL = store.quarantineDirectory
        #expect(throws: SessionDocumentStoreError.cannotWrite(rejectionURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path) == stateExisted)
        if let stateBytes {
            #expect(try Data(contentsOf: stateURL) == stateBytes)
        }

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "receipt 数量超限必须保留全部隔离证据"
        )
        #expect(FileManager.default.fileExists(atPath: ownArtifact.path))
        #expect(
            FileManager.default.fileExists(
                atPath: store.quarantineDirectory
                    .appendingPathComponent("unowned-receipt-4096.json").path
            )
        )
    }

    @Test func recoveryCleanupRejectsReceiptByteOverflowWithoutUnlinking() throws {
        let directory = try makeDirectory("c-line-recovery-receipt-total")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )
        let ownArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try Data("keep this recovery evidence".utf8).write(
            to: ownArtifact, options: .atomic
        )
        let filler = Data(repeating: 0x78, count: 8 * 1024 * 1024)
        for index in 0..<4 {
            let fillerURL = store.quarantineDirectory.appendingPathComponent(
                "large-unowned-receipt-\(index).json"
            )
            try filler.write(to: fillerURL, options: .atomic)
        }

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        let stateURL = store.sessionFileURL(for: sessionID)
        let stateExisted = FileManager.default.fileExists(atPath: stateURL.path)
        let stateBytes = stateExisted ? try Data(contentsOf: stateURL) : nil
        let rejectionURL = store.documentsDirectory.appendingPathComponent(
            "\(sessionID.uuidString).cleanup-diagnostic.json"
        )
        #expect(throws: SessionDocumentStoreError.cannotWrite(rejectionURL)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(FileManager.default.fileExists(atPath: stateURL.path) == stateExisted)
        if let stateBytes {
            #expect(try Data(contentsOf: stateURL) == stateBytes)
        }

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "receipt 总 bytes 超限必须停止 hash 并保留证据"
        )
        #expect(FileManager.default.fileExists(atPath: ownArtifact.path))
        #expect(
            try Data(contentsOf: store.quarantineDirectory
                .appendingPathComponent("large-unowned-receipt-3.json")) == filler
        )
    }

    @Test func interruptedTombstoneWithoutReceiptStaysQuarantinedAfterRestart() throws {
        let directory = try makeDirectory("c-line-recovery-missing-receipt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let otherSessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let originalName = "\(sessionID.uuidString)-\(UUID().uuidString).json"
        let missingReceiptTombstone = store.quarantineDirectory.appendingPathComponent(
            "\(originalName)-cleanup-\(UUID().uuidString).json"
        )
        try Data("rename committed before receipt".utf8).write(
            to: missingReceiptTombstone, options: .atomic
        )
        let otherTombstone = store.quarantineDirectory.appendingPathComponent(
            "\(otherSessionID.uuidString)-\(UUID().uuidString).json-cleanup-\(UUID().uuidString).json"
        )
        let otherTombstoneData = Data("other session pending receipt".utf8)
        try otherTombstoneData.write(
            to: otherTombstone, options: .atomic
        )
        let userFile = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-user-file.json"
        )
        try Data("user-owned quarantine file".utf8).write(to: userFile, options: .atomic)

        let restarted = SessionDocumentStore(directory: directory)
        #expect(restarted.state(for: sessionID).tabs.isEmpty)
        #expect(restarted.hasRecoveryFailure(for: sessionID))
        #expect(restarted.hasRecoveryFailure(for: otherSessionID))

        _ = try restarted.newTab(
            sessionID: sessionID, title: "恢复后的文档", content: "新状态"
        )

        #expect(restarted.hasRecoveryFailure(for: otherSessionID))
        #expect(
            restarted.hasRecoveryFailure(for: sessionID),
            "缺失 receipt 的 rename 结果必须 fail-closed 并保留告警"
        )
        #expect(FileManager.default.fileExists(atPath: missingReceiptTombstone.path))
        #expect(FileManager.default.fileExists(atPath: otherTombstone.path))
        #expect(try Data(contentsOf: otherTombstone) == otherTombstoneData)
        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test func recoveryCleanupLeavesOccupiedTombstoneDestinationUntouched() throws {
        let directory = try makeDirectory("c-line-recovery-destination-conflict")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let artifactID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let artifactData = Data("original quarantined payload".utf8)
        let artifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(artifactID.uuidString).json"
        )
        try artifactData.write(to: artifact, options: .atomic)
        var artifactInfo = stat()
        #expect(lstat(artifact.path, &artifactInfo) == 0)
        let digest = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }.joined()
        let destination = store.quarantineDirectory.appendingPathComponent(
            "miniscanvas-recovery-tombstone-\(sessionID.uuidString)_\(sessionID.uuidString)_\(artifactInfo.st_dev)_\(artifactInfo.st_ino)_\(digest)_\(artifactID.uuidString).json"
        )
        let userData = Data("new user file must win".utf8)
        try userData.write(to: destination, options: .atomic)

        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))
        let stateURL = store.sessionFileURL(for: sessionID)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(throws: SessionDocumentStoreError.cannotWrite(store.quarantineDirectory)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(store.state(for: sessionID).tabs.isEmpty)

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "tombstone destination 冲突必须保留当前 session 告警"
        )
        #expect(try Data(contentsOf: artifact) == artifactData)
        #expect(
            try Data(contentsOf: destination) == userData,
            "清理不能覆盖或删除已占用的用户文件"
        )
    }

    @Test func recoveryCleanupRejectsReplacedQuarantineDirectory() throws {
        let directory = try makeDirectory("c-line-recovery-directory-replaced")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )

        let oldArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try Data("old quarantine artifact".utf8).write(
            to: oldArtifact, options: .atomic
        )
        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))

        let oldQuarantineDirectory = store.quarantineDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("quarantine-old", isDirectory: true)
        try FileManager.default.moveItem(
            at: store.quarantineDirectory, to: oldQuarantineDirectory
        )
        let replacementDirectory = directory
            .appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementDirectory, withIntermediateDirectories: true
        )
        let replacementArtifact = replacementDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        let replacementData = Data("new directory content".utf8)
        try replacementData.write(to: replacementArtifact, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: store.quarantineDirectory, withDestinationURL: replacementDirectory
        )

        let stateURL = store.sessionFileURL(for: sessionID)
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(throws: SessionDocumentStoreError.cannotWrite(store.quarantineDirectory)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: stateURL.path))
        #expect(store.state(for: sessionID).tabs.isEmpty)

        #expect(
            store.hasRecoveryFailure(for: sessionID),
            "quarantine 目录边界漂移必须 fail-closed 并保留告警"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: oldQuarantineDirectory
                    .appendingPathComponent(oldArtifact.lastPathComponent).path
            )
        )
        #expect(try Data(contentsOf: oldQuarantineDirectory.appendingPathComponent(oldArtifact.lastPathComponent)) == Data("old quarantine artifact".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.quarantineDirectory.path) == replacementDirectory.path)
        #expect(
            try Data(contentsOf: replacementArtifact) == replacementData,
            "清理不能处理被替换目录中的新内容"
        )
    }

    @Test func recoveryCleanupRejectsReplacedDocumentsParent() throws {
        let directory = try makeDirectory("c-line-recovery-parent-replaced")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let store = SessionDocumentStore(directory: directory)
        try FileManager.default.createDirectory(
            at: store.quarantineDirectory, withIntermediateDirectories: true
        )
        let oldArtifact = store.quarantineDirectory.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        try Data("old parent artifact".utf8).write(to: oldArtifact, options: .atomic)
        #expect(store.state(for: sessionID).tabs.isEmpty)
        #expect(store.hasRecoveryFailure(for: sessionID))

        let oldDocumentsDirectory = directory.appendingPathComponent(
            "sessionDocuments-old", isDirectory: true
        )
        try FileManager.default.moveItem(
            at: store.documentsDirectory, to: oldDocumentsDirectory
        )
        let replacementDocumentsDirectory = directory.appendingPathComponent(
            "sessionDocuments-replacement", isDirectory: true
        )
        let replacementQuarantine = replacementDocumentsDirectory
            .appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacementQuarantine, withIntermediateDirectories: true
        )
        let replacementArtifact = replacementQuarantine.appendingPathComponent(
            "\(sessionID.uuidString)-\(UUID().uuidString).json"
        )
        let replacementData = Data("replacement parent content".utf8)
        try replacementData.write(to: replacementArtifact, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: store.documentsDirectory, withDestinationURL: replacementDocumentsDirectory
        )

        #expect(throws: SessionDocumentStoreError.cannotWrite(store.documentsDirectory)) {
            _ = try store.newTab(
                sessionID: sessionID, title: "恢复后的文档", content: "新状态"
            )
        }
        #expect(
            FileManager.default.fileExists(
                atPath: oldDocumentsDirectory
                    .appendingPathComponent("quarantine", isDirectory: true)
                    .appendingPathComponent(oldArtifact.lastPathComponent).path
            )
        )
        #expect(
            try Data(contentsOf: replacementArtifact) == replacementData,
            "父目录边界漂移不能处理新目录内容"
        )
    }

    @Test @MainActor func bridgeCompositionKeepsDocumentsInsideActiveSession() throws {
        let directory = try makeDirectory("c-line-composition")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = BridgeStore(
            sessionDocumentStore: SessionDocumentStore(directory: directory)
        )
        let firstSessionID = try #require(bridge.chat.activeSessionID)
        let tab = try bridge.sessionDocuments.newTab(
            sessionID: firstSessionID,
            title: "会话草稿",
            content: "只属于第一个会话"
        )

        #expect(!bridge.sessionDocuments.hasWorkspaceState)
        #expect(
            bridge.sessionDocuments.tab(
                sessionID: firstSessionID,
                tabID: tab.id
            )?.content == "只属于第一个会话"
        )

        bridge.chat.newSession()
        let secondSessionID = try #require(bridge.chat.activeSessionID)
        #expect(secondSessionID != firstSessionID)
        #expect(bridge.sessionDocuments.state(for: secondSessionID).tabs.isEmpty)
    }
}

@Suite("C 线视频任务状态机")
struct CLineVideoTaskStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c-line-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    @Test func allStatusesTransitionPersistAndRecoverRemoteTaskAndAsset() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)
        let queued = store.enqueue(
            nodeID: nodeID, providerID: "kling", promptFingerprint: "fp-1"
        )
        #expect(queued.status == .queued)
        #expect(queued.taskID.isEmpty)

        #expect(store.markSubmitted(id: queued.id, taskID: "remote-1"))
        #expect(store.markPolling(id: queued.id))
        #expect(store.markSucceeded(
            id: queued.id,
            videoURL: "https://cdn.example/video.mp4",
            assetPath: "/tmp/video.mp4"
        ))
        let restored = try #require(
            VideoTaskStore(directory: directory).record(id: queued.id)
        )
        #expect(restored.status == .succeeded)
        #expect(restored.taskID == "remote-1")
        #expect(restored.assetPath == "/tmp/video.mp4")
        #expect(VideoTaskRecord.Status.allCases == [
            .queued, .submitted, .polling, .succeeded, .failed, .canceled, .expired
        ])
    }

    @Test func submitIsIdempotentByNodeAndPromptAndDoesNotDuplicateActiveTask() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)
        let first = store.enqueue(
            nodeID: nodeID, providerID: "jimeng", promptFingerprint: "fp-2"
        )
        let second = store.enqueue(
            nodeID: nodeID, providerID: "jimeng", promptFingerprint: "fp-2"
        )
        #expect(first.id == second.id)
        #expect(store.allRecords().count == 1)
        #expect(store.pendingTask(nodeID: nodeID, promptFingerprint: "fp-2") == nil)
        #expect(store.activeTask(nodeID: nodeID, promptFingerprint: "fp-2")?.id == first.id)

        #expect(store.markSubmitted(id: first.id, taskID: "remote-2"))
        let resumed = store.resumeOrCreate(
            nodeID: nodeID,
            providerID: "jimeng",
            promptFingerprint: "fp-2"
        )
        #expect(resumed.id == first.id)
        #expect(resumed.taskID == "remote-2")
        #expect(resumed.status == .submitted)
        #expect(store.allRecords().count == 1)
    }

    @Test func restartPreservesQueuedIntentAndRequestSnapshotWithoutDuplicate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let snapshot = VideoTaskRequestSnapshot(
            CloudVideoRequest(
                prompt: "重启后继续提交",
                imageURL: "https://cdn.example/reference.png",
                aspectRatio: "16:9",
                duration: "5",
                modelOverride: "video-v1",
                extraParams: ["seed": "42"]
            )
        )
        let store = VideoTaskStore(directory: directory)
        let queued = store.enqueue(
            nodeID: nodeID,
            providerID: "test-video",
            promptFingerprint: "restart-request",
            requestSnapshot: snapshot
        )

        // A new package instance must reuse the durable intent and its exact
        // request, while queued work remains ineligible for remote polling.
        let restarted = VideoTaskStore(directory: directory)
        let resumed = restarted.resumeOrCreate(
            nodeID: nodeID,
            providerID: "test-video",
            promptFingerprint: "restart-request",
            requestSnapshot: snapshot
        )

        #expect(resumed.id == queued.id)
        #expect(resumed.idempotencyKey == queued.idempotencyKey)
        #expect(resumed.status == .queued)
        #expect(resumed.requestSnapshot == snapshot)
        #expect(restarted.recoverableTasks().isEmpty)
        #expect(restarted.allRecords().count == 1)
    }

    @Test func cancelExpireAndExplicitRetryHaveBoundedTransitions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)

        let canceled = store.enqueue(
            nodeID: nodeID, providerID: "kling", promptFingerprint: "cancel"
        )
        #expect(store.markCanceled(id: canceled.id, message: "用户停止"))
        #expect(store.record(id: canceled.id)?.status == .canceled)
        #expect(!store.markPolling(id: canceled.id), "终态不能回到轮询")

        let expired = store.enqueue(
            nodeID: nodeID, providerID: "kling", promptFingerprint: "expire"
        )
        #expect(store.markSubmitted(id: expired.id, taskID: "remote-expire"))
        #expect(store.markExpired(id: expired.id, message: "超过恢复期限"))
        #expect(store.record(id: expired.id)?.status == .expired)

        let retried = try #require(store.retry(id: expired.id))
        #expect(retried.id == expired.id, "重试复用本地幂等键")
        #expect(retried.status == .queued)
        #expect(retried.taskID.isEmpty)
        #expect(retried.errorMessage == nil)
        #expect(store.retry(id: canceled.id)?.status == .queued)
        #expect(store.retry(id: retried.id) == nil, "排队中的任务不能重复重试")
    }

    @Test func legacySubmitEntryCannotRegressPollingOrOverwriteTerminalOutcome() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nodeID = UUID()
        let store = VideoTaskStore(directory: directory)
        let record = store.enqueue(
            nodeID: nodeID, providerID: "kling", promptFingerprint: "legacy-boundary"
        )
        #expect(store.markSubmitted(id: record.id, taskID: "remote-boundary"))
        #expect(store.markPolling(id: record.id))

        // 旧画布入口仍可调用，但不能把新状态机从 polling 回退成 submitted。
        store.recordSubmitted(
            id: record.id,
            nodeID: nodeID,
            providerID: "kling",
            taskID: "remote-boundary",
            promptFingerprint: "legacy-boundary"
        )
        #expect(store.record(id: record.id)?.status == .polling)

        #expect(store.markSucceeded(id: record.id, videoURL: "https://cdn.example/boundary.mp4"))
        store.recordSubmitted(
            id: record.id,
            nodeID: nodeID,
            providerID: "kling",
            taskID: "new-remote-must-not-overwrite",
            promptFingerprint: "legacy-boundary"
        )
        #expect(store.record(id: record.id)?.status == .succeeded)
        #expect(store.record(id: record.id)?.taskID == "remote-boundary")
    }

    @Test func corruptRecordsAreQuarantinedAndLegacyRecordsRemainReadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent(VideoTaskStore.fileName), options: .atomic
        )
        let corruptStore = VideoTaskStore(directory: directory)
        #expect(corruptStore.allRecords().isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: corruptStore.quarantineDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(quarantined.count == 1)

        // 旧版记录没有新增的 assetPath/idempotencyKey 字段，仍应可读。
        let nodeID = UUID()
        let legacy = """
        [{"id":"legacy","nodeID":"\(nodeID.uuidString)","providerID":"kling","taskID":"remote-legacy","promptFingerprint":"fp-legacy","status":"submitted","videoURL":null,"errorMessage":null,"createdAt":"2026-08-07T00:00:00Z","updatedAt":"2026-08-07T00:00:00Z"}]
        """
        try Data(legacy.utf8).write(
            to: directory.appendingPathComponent(VideoTaskStore.fileName), options: .atomic
        )
        let reopened = VideoTaskStore(directory: directory)
        #expect(reopened.record(id: "legacy")?.status == .submitted)
        #expect(reopened.record(id: "legacy")?.taskID == "remote-legacy")
    }
}
