import CryptoKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class SentPreviewProvider1025: LLMProvider, @unchecked Sendable {
    let name = "owned-sent-preview1025"
    var model = LLMModel(id: "owned-sent-preview1025", displayName: "Owned preview control",
                         provider: "owned-sent-preview1025", modalityOverride: .textOnly)
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var captured: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { captured } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { captured.append(messages) }
        return LLMResponse(text: "OWNED_SENT_REPLY1025", stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        lock.withLock { captured.append(messages) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("OWNED_SENT_REPLY1025"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

@Suite("COM05 actual ordinary send to sent-message FileTree preview", .serialized)
@MainActor
struct SentMessageAttachmentPreview1025Tests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "actual worker/ordinary request/preview did not settle")
    }

    @Test("sent Markdown retains its real preview target after draft preview expiry and ordinary send")
    func sentMarkdownFeedsOriginalFileTreeAfterOrdinarySend() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "SentPreview1025",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let inputRoot = profile.rootDirectory.appendingPathComponent("owned-input", isDirectory: true)
        let treeRoot = profile.rootDirectory.appendingPathComponent("owned-empty-tree", isDirectory: true)
        for root in [inputRoot, treeRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let text = "# OWNED1025 preview\nThis synthetic document belongs only to the sent attachment consumer.\n"
        let bytes = Data(text.utf8)
        let url = inputRoot.appendingPathComponent("OWNED1025_DOCUMENT.md")
        try bytes.write(to: url)
        let store = SessionStore(directory: profile.sessionDirectory)
        let chat = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(chat.attachPersistence(store))
        let aID = try #require(chat.activeSessionID)
        let provider = SentPreviewProvider1025()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: chat.composerWorkspaceID, revision: "owned-preview1025",
            grantEpoch: "owned-preview1025", leaseID: "owned-preview1025", expiresAt: .distantFuture,
            autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        let skills = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills"))
        chat.turnRuntimeSnapshotFactory = { turn, box in
            let snapshot = try! ProviderRuntimeSnapshot(providerID: box.model.provider, modelID: box.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:owned-preview1025")
            let route = try! ProviderRuntimeRoute(snapshot: snapshot, primary: box)
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, providerRuntimeRoute: route, requiresProviderRuntimeRoute: true)
        }
        chat.agentEngine = AgentLoopChatEngine(toolExecutor: BuiltinToolExecutor(allowedRoot: inputRoot),
            requestBudget: chat.budgetTracker, composerPolicyFacts: facts)
        chat.streamingProviderOverride = provider
        defer { chat.stopAllStreamingForSafety() }

        let added = try #require(chat.addAttachments(urls: [url]).first)
        try await waitUntil { chat.pendingAttachments.first?.status == .ready }
        let draft = try #require(chat.pendingAttachments.first)
        #expect(draft.id == added.id && draft.data == bytes && draft.fileType == .markdown)
        let draftTarget = try ChatAttachmentOpenTarget().resolve(draft)
        let draftSelection = ChatAttachmentPreviewSelection(sessionID: aID, attachment: draft, url: draftTarget)
        let files = FileTreeStore(rootURL: treeRoot)
        files.selectAttachment(draftSelection)
        try await waitUntil { files.preview != nil }
        #expect(files.preview?.text == text && files.preview?.error == nil)

        let bID = chat.applyNewSession(title: "owned B1025")
        #expect(draftSelection.visible(in: bID) == nil)
        files.clearChatAttachmentSelection()
        #expect(files.selectedURL == nil && files.preview == nil)
        #expect(chat.applySwitchSession(id: aID))
        #expect(chat.pendingAttachments.first?.id == added.id)
        chat.draftText = "OWNED_ORDINARY_BODY1025"
        chat.submitComposer()
        try await waitUntil { !chat.hasStreamingTasksForSafety && provider.requests.count == 1 }
        let sent = try #require(chat.messages.last { $0.role == .user })
        let attachment = try #require(sent.attachments.first)
        #expect(attachment == draft)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content == "OWNED_SENT_REPLY1025" })
        #expect(chat.pendingAttachments.isEmpty)
        #expect(provider.requests[0].last { $0.role == .user }?.content == sent.asLLMMessage().content)
        #expect(ChatAttachmentOpenTarget.sourceState(for: attachment) == .sourceAvailable)
        let target = try ChatAttachmentOpenTarget().resolve(attachment)
        #expect(target.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let originalFileID = try #require(originalAttributes[.systemFileNumber] as? NSNumber)
        let targetFileID = try #require(targetAttributes[.systemFileNumber] as? NSNumber)
        let originalDevice = try #require(originalAttributes[.systemNumber] as? NSNumber)
        let targetDevice = try #require(targetAttributes[.systemNumber] as? NSNumber)
        #expect(originalFileID == targetFileID)
        #expect(originalDevice == targetDevice)
        let targetBytes = try Data(contentsOf: target)
        #expect(targetBytes == bytes)
        let selection = ChatAttachmentPreviewSelection(sessionID: aID, attachment: attachment, url: target)
        #expect(selection.visible(in: chat.activeSessionID) == selection)
        let retiredDraftRequest = PendingAttachmentPreviewRequest(attachmentID: draft.id,
                                                                requestID: draftSelection.requestID)
        #expect(PendingAttachmentPreviewLifecycle.selectionAfterRemoval(selection,
            removedRequest: retiredDraftRequest) == selection)
        // This is the original selected-message target and detached preview
        // consumer. It does not claim to press a native SwiftUI button or prove
        // ContentView's mounted State/action dispatch in the observed UI failure.
        files.selectAttachment(selection)
        try await waitUntil { files.preview != nil }
        #expect(files.selectedURL == target && files.rootURL == treeRoot)
        #expect(files.preview?.text == text && files.preview?.error == nil)
        #expect(files.canShowPreview(for: selection))
        let canonical = try #require(store.loadSession(id: aID.uuidString))
        let persisted = try #require(try ChatAttachmentPersistence.load(forSessionID: aID.uuidString, from: store.directory))
        let userIndex = try #require(canonical.messages.firstIndex { $0.role == .user && $0.content == sent.asLLMMessage().content })
        let record = try #require(persisted.first { $0.messageIndex == userIndex })
        #expect(record.attachments.first?.id == attachment.id)
        let digest = SHA256.hash(data: Data(canonical.messages[userIndex].content.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(record.contentDigest == digest)
        #expect(chat.applySwitchSession(id: bID))
        #expect(selection.visible(in: chat.activeSessionID) == nil)
        files.clearChatAttachmentSelection()
        try await Task.sleep(for: .milliseconds(100))
        #expect(files.selectedURL == nil && files.preview == nil)
        #expect(chat.messages.allSatisfy { $0.attachments.isEmpty })
        #expect(store.loadSession(id: aID.uuidString) == canonical)

        // Exercise the same ordinary sent attachment after a cold read, then
        // both receipt-bound recovery actions. The old test stopped before any
        // reversible deletion, while the global ownership snapshot was pruned.
        let group = try #require(chat.createGroup(named: "Owned sent preview recovery"))
        chat.moveSession(aID, toGroup: group.id)
        let expectedCanonical = try #require(store.loadSession(id: aID.uuidString))
        let coldStore = SessionStore(directory: profile.sessionDirectory)
        let cold = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(cold.attachPersistence(coldStore))

        func checkRecovered(_ owner: ChatStore) async throws {
            let thread = try #require(owner.sessions.first { $0.id == aID })
            #expect(thread.groupID == group.id)
            let message = try #require(thread.messages.first {
                $0.role == .user && $0.attachments.contains { $0.id == attachment.id }
            })
            #expect(message.displayContent == "OWNED_ORDINARY_BODY1025")
            let restored = try #require(message.attachments.first { $0.id == attachment.id })
            #expect(restored.fileName == attachment.fileName && restored.size == attachment.size)
            #expect(restored.fileType == attachment.fileType && restored.status == attachment.status)
            #expect(ChatAttachmentOpenTarget.sourceState(for: restored) == .sourceAvailable)
            let restoredTarget = try ChatAttachmentOpenTarget().resolve(restored)
            #expect(try Data(contentsOf: restoredTarget) == bytes)
            let restoredFiles = FileTreeStore(rootURL: treeRoot)
            restoredFiles.selectAttachment(ChatAttachmentPreviewSelection(
                sessionID: aID, attachment: restored, url: restoredTarget))
            try await waitUntil { restoredFiles.preview != nil }
            #expect(restoredFiles.preview?.text == text && restoredFiles.preview?.error == nil)
        }
        try await checkRecovered(cold)
        let first = try cold.previewDeletion(id: aID)
        let firstReceipt = try cold.deleteSession(id: aID, intent: first
            .withFirstConfirmation("reviewed this owned sent attachment session")
            .withSecondConfirmation("move this owned session to recoverable trash"))
        #expect(cold.sessionTrashEntries.contains { $0.id == firstReceipt.operationID })
        #expect(try ChatAttachmentPersistence.load(forSessionID: aID.uuidString, from: store.directory) != nil)
        #expect(cold.undoLastSessionDeletion())
        try await checkRecovered(cold)
        #expect(coldStore.loadSession(id: aID.uuidString)?.messages == expectedCanonical.messages)

        let second = try cold.previewDeletion(id: aID)
        let secondReceipt = try cold.deleteSession(id: aID, intent: second
            .withFirstConfirmation("reviewed the same restored owned session")
            .withSecondConfirmation("move the same session to recoverable trash"))
        let reopenedStore = SessionStore(directory: profile.sessionDirectory)
        let reopened = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(reopened.attachPersistence(reopenedStore))
        #expect(!reopened.sessions.contains { $0.id == aID })
        #expect(reopened.sessionTrashEntries.contains { $0.id == secondReceipt.operationID })
        #expect(reopened.restoreTrashedSession(secondReceipt))
        try await checkRecovered(reopened)
        #expect(reopenedStore.loadSession(id: aID.uuidString)?.messages == expectedCanonical.messages)
        let finalRead = ChatStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager())
        #expect(finalRead.attachPersistence(SessionStore(directory: profile.sessionDirectory)))
        try await checkRecovered(finalRead)
        #expect(provider.requests.count == 1)
    }
}
