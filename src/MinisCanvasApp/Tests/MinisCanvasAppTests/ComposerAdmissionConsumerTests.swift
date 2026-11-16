import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Composer admission consumers", .serialized)
@MainActor
struct ComposerAdmissionConsumerTests {
    @Test func rejectedDesktopActionRestoresTheExactOriginalCommandDraft() async throws {
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID, revision: "desktop-reject", leaseID: "desktop-reject",
            expiresAt: Date().addingTimeInterval(60), autonomyCeiling: .l2)
        chat.configureComposerPolicy(facts)
        let center = ComposerCommandAdjudicationCenter()
        center.desktopCommandAction = { request, _ in
            throw CommandExecutionError.disabled(commandID: request.commandID, reason: "真实适配层拒绝")
        }
        chat.onComposerCommandPolicy = { request, snapshot in
            center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
        }
        defer { chat.onComposerCommandPolicy = nil }
        let welcomeBaseline = chat.messages
        #expect(welcomeBaseline.contains { $0.role == .assistant && $0.content.contains("欢迎使用 MinisCanvas！连接模型后即可开始对话。") })
        #expect(!welcomeBaseline.contains { $0.role == .user })
        let original = "/plan " + String(repeating: "保留这份规划描述。", count: 60)
        chat.draftText = original
        #expect(await chat.submitComposerAwaitingAdmission() == false)
        #expect(chat.draftText == original)
        #expect(chat.lastComposerCommandReceipt?.disposition == .reject)
        #expect(chat.messages == welcomeBaseline)
        #expect(!chat.isActiveSessionGenerating)
    }

    @Test(arguments: [false, true])
    func reviewCommentWaitsForRealPreflightAndStaysUnsentWhenRejected(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatStore(providerReadinessStore: ProviderReadinessStore(directory: root))
        defer { chat.stopAllStreamingForSafety() }
        let welcomeBaseline = chat.messages
        #expect(welcomeBaseline.contains { $0.role == .assistant && $0.content.contains("欢迎使用 MinisCanvas！连接模型后即可开始对话。") })
        #expect(!welcomeBaseline.contains { $0.role == .user })
        let session = try #require(chat.activeSessionID)
        let model = try #require(ProviderType.openAI.builtInModels.first?.id)
        let route = try #require(ChatStore.BuiltinReadinessBinding.route(for: .openAI))
        let record = EnvVarEntry(name: ProviderType.openAI.rawValue, value: "", isSecret: true,
            baseURL: route.baseURL, modelNames: [model], protocolType: route.wire)
        chat.providerRecordsSource = { [record] }
        chat.selectedProviderType = .openAI
        chat.selectedModelID = model
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        chat.providerCredentialMetadataSource = { _, _ in
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return "synthetic-revision"
        }
        var checks = 0
        chat.providerReadinessPreflight = { _, _ in checks += 1 } // No applied receipt is published.
        let comment = "针对 src/Foo.swift 第2行：请解释此改动。"
        var resolved = false
        let send = Task {
            let accepted = await chat.submitChangeComment(comment, expectedSessionID: session)
            resolved = true
            return accepted
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(chat.isComposerCredentialPreflightPending)
        #expect(!resolved)
        #expect(chat.messages == welcomeBaseline)
        if cancel { chat.cancelComposerCredentialPreflight() }
        release.continuation.finish()
        #expect(await send.value == false)
        #expect(chat.draftText == comment)
        #expect(chat.messages == welcomeBaseline)
        #expect(!chat.isActiveSessionGenerating)
        #expect(checks == (cancel ? 0 : 1))
    }
}
