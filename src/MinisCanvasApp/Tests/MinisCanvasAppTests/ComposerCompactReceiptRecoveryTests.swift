import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class CompactReceiptCountingProvider: LLMProvider, @unchecked Sendable {
    let name = "compact-receipt-test"
    var model = LLMModel(id: "compact-receipt-test", displayName: "Compact Receipt Test", provider: "test")
    private(set) var callCount = 0
    private(set) var requests: [[LLMMessage]] = []

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        requests.append(messages)
        return LLMResponse(text: "Preserve the title. Prior authorization was read-only.", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private let compactFixtureSessionID = "11111111-2222-3333-4444-555555555555"
private let compactFixtureMessages = [
    LLMMessage(role: .user, content: "fixture user 1"),
    LLMMessage(role: .assistant, content: "fixture assistant 1"),
    LLMMessage(role: .user, content: "fixture user 2"),
    LLMMessage(role: .assistant, content: "fixture assistant 2"),
    LLMMessage(role: .user, content: "fixture user 3"),
    LLMMessage(role: .assistant, content: "fixture assistant 3"),
]

private func seedCompactFixture(at directory: URL,
    messages: [LLMMessage] = compactFixtureMessages) throws -> [String] {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let session = ChatSession(
        id: compactFixtureSessionID,
        title: "Compact receipt fixture",
        createdAt: timestamp,
        updatedAt: timestamp,
        messages: messages,
        transcriptRevision: UInt64(messages.count)
    )
    try SessionStore(directory: directory).updateSession(session)
    return messages.map { "\($0.role.rawValue)|\($0.content)" }
}

private func semanticMessages(_ messages: [ChatMessageUI]) -> [String] {
    messages.map { "\($0.role.rawValue)|\($0.content)" }
}

@Suite("Composer compact receipt recovery")
@MainActor
struct ComposerCompactReceiptRecoveryTests {
    @Test func pendingCompactReceiptSurvivesRestartWithoutTranscriptOrProvider() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-receipt-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseline = try seedCompactFixture(at: directory)
        let provider = CompactReceiptCountingProvider()
        let first = ChatStore()
        #expect(first.attachPersistence(SessionStore(directory: directory)))
        #expect(semanticMessages(first.messages) == baseline)
        first.compactionProviderOverride = provider
        first.onComposerCommandPolicy = { _, _ in .pending }
        first.draftText = "/compact"
        let before = semanticMessages(first.messages)

        first.submitComposer()

        let receipt = try #require(first.lastComposerCommandReceipt)
        #expect(receipt.commandID == "compact")
        #expect(receipt.disposition == .pending)
        #expect(first.pendingComposerCommand?.commandID == "compact")
        #expect(semanticMessages(first.messages) == before)
        #expect(provider.callCount == 0)

        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.lastComposerCommandReceipt == receipt)
        #expect(restarted.pendingComposerCommand?.commandID == "compact")
        #expect(semanticMessages(restarted.messages) == baseline)
    }

    @Test func rejectedAndExecutedCompactReceiptsRecoverAtTheirExecutionBoundary() async throws {
        let rejectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-receipt-rejected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rejectedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rejectedDirectory) }

        let rejectedBaseline = try seedCompactFixture(at: rejectedDirectory)
        let rejected = ChatStore()
        #expect(rejected.attachPersistence(SessionStore(directory: rejectedDirectory)))
        #expect(semanticMessages(rejected.messages) == rejectedBaseline)
        rejected.onComposerCommandPolicy = { _, _ in .reject }
        rejected.draftText = "/compact"
        let rejectedBefore = semanticMessages(rejected.messages)
        rejected.submitComposer()
        #expect(semanticMessages(rejected.messages) == rejectedBefore)
        let rejectedReceipt = try #require(rejected.lastComposerCommandReceipt)
        #expect(rejectedReceipt.disposition == .reject)
        #expect(rejected.pendingComposerCommand == nil)

        let rejectedRestart = ChatStore()
        #expect(rejectedRestart.attachPersistence(SessionStore(directory: rejectedDirectory)))
        #expect(rejectedRestart.lastComposerCommandReceipt == rejectedReceipt)
        #expect(rejectedRestart.pendingComposerCommand == nil)
        #expect(semanticMessages(rejectedRestart.messages) == rejectedBaseline)

        let executedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-receipt-executed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: executedDirectory) }

        let longExplanation = (0..<40).map { index in
            "Observation \(index): the proposed repair has cost \(index * 11 + 3), dependency \(index % 7), verification step \(index + 2), and a distinct alternative to compare before deciding."
        }.joined(separator: " ")
        let naturalSource: [LLMMessage] = [
            .init(role: .user, content: "Goal: compare repairs. Preserve the title. Prior authorization was read-only."),
            .init(role: .assistant, content: longExplanation),
            .init(role: .user, content: "Retain the unfinished comparison of alternative B."),
            .init(role: .assistant, content: "The recent alternative adds a different inspection."),
            .init(role: .user, content: "Keep that inspection in the comparison."),
            .init(role: .assistant, content: "Ready to continue the same conversation."),
        ]
        let executedBaseline = try seedCompactFixture(at: executedDirectory, messages: naturalSource)
        let provider = CompactReceiptCountingProvider()
        let executed = ChatStore()
        #expect(executed.attachPersistence(SessionStore(directory: executedDirectory)))
        #expect(semanticMessages(executed.messages) == executedBaseline)
        executed.compactionProviderOverride = provider
        executed.onComposerCommandPolicy = { _, _ in .execute }
        executed.draftText = "/compact"
        let executedBefore = semanticMessages(executed.messages)
        executed.submitComposer()
        #expect(semanticMessages(executed.messages) == executedBefore)
        let executedReceipt = try #require(executed.lastComposerCommandReceipt)
        #expect(executedReceipt.disposition == .execute)
        #expect(executed.pendingComposerCommand == nil)
        #expect(provider.callCount == 0)

        let persisted = SessionStore(directory: executedDirectory)
        for _ in 0..<100 {
            if try persisted.loadLatestCompactionCheckpoint(sessionID: compactFixtureSessionID) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let checkpoint = try #require(try persisted.loadLatestCompactionCheckpoint(sessionID: compactFixtureSessionID))
        #expect(provider.callCount == 1)
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(semanticMessages(executed.messages) == executedBefore)
        #expect(persisted.loadSession(id: compactFixtureSessionID)?.messages == naturalSource)
        let modelView = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: persisted,
            sessionID: compactFixtureSessionID)
        #expect(modelView == checkpoint.replacementHistory)
        #expect(Compactor.hasMaterialRequestReduction(from: naturalSource, to: modelView))
        let summaryRequest = try #require(provider.requests.first)
        #expect(summaryRequest.count == 1)
        #expect(summaryRequest.first?.role == .user)
        #expect(summaryRequest.first?.content.contains("===== 对话记录 =====") == true)
        #expect(summaryRequest.first?.content.contains("Preserve the title") == true)
        #expect(modelView.first?.content.contains("Preserve the title. Prior authorization was read-only.") == true)
        #expect(checkpoint.projectionRecentCount == 3)
        #expect(Array(modelView.suffix(3)) == Array(naturalSource.suffix(3)))
        #expect(provider.requests.flatMap { $0 }.allSatisfy { !$0.content.contains("/compact") })
        #expect(naturalSource.allSatisfy { !$0.content.contains("/compact") })

        let executedRestart = ChatStore()
        #expect(executedRestart.attachPersistence(SessionStore(directory: executedDirectory)))
        #expect(executedRestart.lastComposerCommandReceipt == executedReceipt)
        #expect(executedRestart.pendingComposerCommand == nil)
        #expect(semanticMessages(executedRestart.messages) == executedBefore)
        #expect(try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: SessionStore(directory: executedDirectory), sessionID: compactFixtureSessionID) == modelView)
    }

    @Test func routedShortCompactNeverCreatesSuccessCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compact-receipt-short-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortSource = Array(compactFixtureMessages.prefix(3))
        let baseline = try seedCompactFixture(at: directory, messages: shortSource)
        let provider = CompactReceiptCountingProvider()
        let chat = ChatStore()
        let persisted = SessionStore(directory: directory)
        #expect(chat.attachPersistence(persisted))
        chat.compactionProviderOverride = provider
        chat.onComposerCommandPolicy = { _, _ in .execute }
        chat.draftText = "/compact"
        chat.submitComposer()
        let receipt = try #require(chat.lastComposerCommandReceipt)
        #expect(receipt.disposition == .execute) // routing, not a success attestation
        for _ in 0..<100 {
            if chat.messages.contains(where: { $0.role == .system && $0.content == "上下文较短，无需压缩。" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.messages.contains { $0.role == .system && $0.content == "上下文较短，无需压缩。" })
        #expect(provider.callCount == 0)
        #expect(try persisted.loadLatestCompactionCheckpoint(sessionID: compactFixtureSessionID) == nil)
        #expect(persisted.loadSession(id: compactFixtureSessionID)?.messages == shortSource)
        #expect(semanticMessages(chat.messages.filter { $0.role != .system }) == baseline)
        let restarted = ChatStore()
        #expect(restarted.attachPersistence(SessionStore(directory: directory)))
        #expect(restarted.lastComposerCommandReceipt == receipt)
        #expect(semanticMessages(restarted.messages) == baseline)
    }

}
