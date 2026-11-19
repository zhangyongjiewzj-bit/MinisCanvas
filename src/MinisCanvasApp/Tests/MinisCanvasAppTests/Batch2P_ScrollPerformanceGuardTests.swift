import Foundation
import Testing
import MinisCore

@testable import MinisCanvasApp

/// Batch2P 对话滚动卡顿护栏：复制菜单不在行渲染时脱敏、脱敏结果不变、任务摘要按数据版本复用。
@Suite("Batch2P 滚动卡顿护栏")
@MainActor
struct Batch2PScrollPerformanceGuardTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("transcriptCopyMenu 构建期不调用脱敏，脱敏只在复制动作的 copyMessage 里")
    func copyMenuBuildDoesNotRedact() throws {
        let text = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")
        let start = try #require(text.range(of: "private func transcriptCopyMenu("))
        let end = try #require(text.range(of: "private func codeBlockMenuTitles(", range: start.upperBound..<text.endIndex))
        let menuBody = String(text[start.lowerBound..<end.lowerBound])
        #expect(!menuBody.contains("redactedCopyBody"))
        #expect(!menuBody.contains("transcriptRedactor"))
        #expect(!menuBody.contains("redact("))
        #expect(!menuBody.contains("redactVisibleConversationBody"))
        #expect(menuBody.contains("copyMessage(message.id)"))

        // 代码块菜单标题只对首行预览（24 字内）脱敏，防止标题泄露密钥；整条消息正文不在构建期脱敏。
        let titlesEnd = try #require(text.range(of: "private func scrollToMessage(", range: end.upperBound..<text.endIndex))
        let titlesBody = String(text[end.lowerBound..<titlesEnd.lowerBound])
        #expect(titlesBody.contains("redactVisibleConversationBody(preview)"))
        #expect(!titlesBody.contains("redactVisibleConversationBody(body)"))
        #expect(!titlesBody.contains("redactedCopyBody"))

        let copyStart = try #require(text.range(of: "func copyMessage("))
        let copyEnd = try #require(text.range(of: "private func redactedCopyBody(", range: copyStart.upperBound..<text.endIndex))
        #expect(String(text[copyStart.lowerBound..<copyEnd.lowerBound]).contains("redactedCopyBody(message, redactor: redactor)"))
    }

    @Test("菜单标题用的代码块数量不经过脱敏，且与围栏解析一致")
    func codeBlockCountFromUnredactedBody() {
        #expect(ChatTranscriptCopyProjection.codeBlockCount(unredactedBody: "plain text") == 0)
        let body = "a\n```swift\nlet x = 1\n```\nb\n~~~\nraw\n~~~\n"
        #expect(ChatTranscriptCopyProjection.codeBlockCount(unredactedBody: body) == 2)
        #expect(ChatTranscriptCopyProjection(redactedBody: body).codeBlocks.count == 2)
    }

    @Test("脱敏结果保持不变：密钥、路径、链接样例")
    func redactionOutputsAreStable() {
        let secret = "zz-super-secret-value-9876"
        let redactor = ChatTranscriptRedactor(secretValues: [secret])

        // 已知密钥被遮蔽；本地路径在对话正文里保留、在通用脱敏里被替换。
        let withSecretAndPath = "key \(secret) at /Users/someone/project/file.txt"
        let conversation = redactor.redactVisibleConversationBody(withSecretAndPath)
        #expect(!conversation.contains(secret))
        #expect(conversation.contains("/Users/someone/project/file.txt"))
        let general = redactor.redact(withSecretAndPath)
        #expect(!general.contains(secret))
        #expect(general.contains("<path>"))
        #expect(!general.contains("/Users/someone"))

        // 普通公开链接在对话正文里保留，凭据链接被替换；通用脱敏一律替换链接。
        let plain = "see https://example.com/docs/page?id=1 ok"
        #expect(redactor.redactVisibleConversationBody(plain) == plain)
        #expect(redactor.redact(plain).contains("<remote-url>"))
        let credentialLink = "go https://example.com/cb?access_token=abcdef123456 now"
        let redactedLink = redactor.redactVisibleConversationBody(credentialLink)
        #expect(!redactedLink.contains("abcdef123456"))

        // 重复调用（命中缓存的正则）结果一致。
        #expect(redactor.redactVisibleConversationBody(withSecretAndPath) == conversation)
        #expect(redactor.redact(withSecretAndPath) == general)

        // 与 ProductRedactionPolicy 直接调用一致，长度上限仍生效。
        #expect(ProductRedactionPolicy.redact("a /tmp/x https://h.io/p", maxLength: 8) == "a <path>")
    }

    @Test("任务摘要在账本版本不变时复用缓存行，版本前进后重算")
    func receiptRowsReuseUntilVersionAdvances() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2p-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let consumer = TaskCenterControlConsumer(store: store)
        _ = try store.enqueue(taskID: "p-one", parentID: "parent-p",
                              providerID: "synthetic-p", modelID: "synthetic-model-p")

        let first = consumer.receiptRowsReusingVersion()
        let versionAfterFirst = store.taskCenterReadVersion()
        let second = consumer.receiptRowsReusingVersion()
        #expect(first.map(\.stableID) == second.map(\.stableID))
        #expect(store.taskCenterReadVersion() == versionAfterFirst)
        #expect(first.map(\.stableID) == consumer.receiptRows().map(\.stableID))

        _ = try store.enqueue(taskID: "p-two", parentID: "parent-p",
                              providerID: "synthetic-p", modelID: "synthetic-model-p")
        let third = consumer.receiptRowsReusingVersion()
        #expect(third.count == first.count + 1)
    }

    @Test("MC4-032 任务中心签名带粗粒度时间段：账本不变时同一时间段内不变，跨时间段才变")
    func taskCenterSignatureAdvancesOnlyAcrossTimeBuckets() throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("batch2p-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let consumer = TaskCenterControlConsumer(store: store)
        let base = Date(timeIntervalSince1970: 1_000_000)
        let within = consumer.observationSignature(now: base.addingTimeInterval(1))
        #expect(consumer.observationSignature(now: base.addingTimeInterval(2)) == within)
        #expect(consumer.observationSignature(now: base.addingTimeInterval(TaskCenterControlConsumer.timeRefreshSeconds + 1)) != within)
    }

    @Test("回合计时页脚：每秒时钟只在 overlay 内，隐藏占位行决定尺寸，时钟不直接作为布局子视图")
    func turnTimingClockLivesInOverlayOnly() throws {
        let text = try source("src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift")
        let start = try #require(text.range(of: "private struct ChatTranscriptTurnTimingStrip: View"))
        let end = try #require(text.range(of: "private struct ChatTranscriptEditAffordance", range: start.upperBound..<text.endIndex))
        let strip = String(text[start.lowerBound..<end.lowerBound])
        let bodyStart = try #require(strip.range(of: "var body: some View {"))
        let body = String(strip[bodyStart.lowerBound...])
        let clock = try #require(body.range(of: "TimelineView(.periodic(from: .now, by: 1))"))
        let overlay = try #require(body.range(of: ".overlay {"))
        // 时钟出现在 overlay 之后（在 overlay 闭包里），且占位行先隐藏。
        #expect(overlay.lowerBound < clock.lowerBound)
        let hidden = try #require(body.range(of: ".hidden()"))
        #expect(hidden.lowerBound < overlay.lowerBound)
        // 只有一处时钟，不得再出现直接放在布局树里的第二个。
        #expect(body.components(separatedBy: "TimelineView(").count == 2)
    }

    private static let appSources = "src/MinisCanvasApp/Sources/MinisCanvasApp/"

    @Test("MC4-032 任务中心不再用 0.5 秒计时器包住整个界面；后台命令区自带时钟")
    func taskCenterBodyIsNotWrappedInPeriodicTimeline() throws {
        let view = try source(Self.appSources + "TaskCenterObservationView.swift")
        let start = try #require(view.range(of: "struct TaskCenterObservationView: View"))
        let end = try #require(view.range(of: "private struct TaskCenterMetric", range: start.upperBound..<view.endIndex))
        let main = String(view[start.lowerBound..<end.lowerBound])
        #expect(!main.contains("TimelineView(.periodic"))
        #expect(main.contains("observationSignature"))
        #expect(main.contains("receiptRowsReusingVersion(includeArchived: true)"))
        #expect(!main.contains("receiptRows(now: .now, includeArchived: true)"))
        let background = try source(Self.appSources + "BackgroundCommandsSection.swift")
        #expect(background.contains("TimelineView(.periodic(from: .now, by: 0.5))"))
    }

    @Test("MC4-031 流式中的对话代码块长行换行（与完成后的原生文本一致），其余场景仍横向滚动")
    func streamingCodeBlocksWrapLikeTheCompletedNativeText() throws {
        let markdown = try source(Self.appSources + "MarkdownView.swift")
        let start = try #require(markdown.range(of: "struct CodeBlockView: View"))
        let end = try #require(markdown.range(of: "// MARK: - 引用块", range: start.upperBound..<markdown.endIndex))
        let code = String(markdown[start.lowerBound..<end.lowerBound])
        #expect(code.contains("if wrapsLongLines"))
        #expect(code.contains("ScrollView(.horizontal, showsIndicators: false)"))
        let chat = try source(Self.appSources + "ChatSidebarView.swift")
        // 三处流式正文（用户气泡、工具结果、助手）都要打开换行。
        #expect(chat.components(separatedBy: "wrapsCodeLines: true").count == 4)
        // 完成态仍是字符级换行、无横向滚动条，流式换行才与之一致。
        let native = try source(Self.appSources + "ReadOnlyAttributedText.swift")
        #expect(native.contains("transcriptLineBreakMode: NSLineBreakMode = .byCharWrapping"))
        #expect(native.contains("scrollView.hasHorizontalScroller = false"))
    }

    @Test("MC4-017 后台命令区显示会话标题而不是原始编号")
    func backgroundCommandsShowSessionTitles() throws {
        let background = try source(Self.appSources + "BackgroundCommandsSection.swift")
        #expect(background.contains("TaskCenterRowLabelFormatter.sourceLabels("))
        #expect(!background.contains("会话：\\(row.sessionID)"))
        let view = try source(Self.appSources + "TaskCenterObservationView.swift")
        #expect(view.contains("BackgroundCommandsSection(registry: .shared, sessionTitles:"))
    }

    @Test("MC4-042 回合进行中切换模式时输入区提示新模式下一轮生效")
    func composerShowsDeferredModeHint() throws {
        let controls = try source(Self.appSources + "ComposerPolicyControls.swift")
        #expect(controls.contains("ComposerPolicyPresentation.modeChangeDeferredHint("))
        let state = try source(Self.appSources + "ComposerPolicyState.swift")
        #expect(state.contains("新模式从下一轮开始生效；要立即收紧可先停止当前回合"))
    }

    @Test("MC4-041 项目指令信任/拒绝记录写盘失败时提示用户，不再静默")
    func instructionRecordWriteFailureIsReported() throws {
        let handler = try source(Self.appSources + "ProjectSessionAppHandler.swift")
        #expect(!handler.contains("try? grants.refuseInstructions"))
        #expect(handler.contains("showInstructionRecordWriteFailure("))
        let start = try #require(handler.range(of: "try grants.trustInstructions(snapshot"))
        let tail = String(handler[start.lowerBound...].prefix(500))
        #expect(tail.contains("showInstructionRecordWriteFailure("))
    }

    @Test("MC4-047 右侧检查面板不用嵌套懒加载列表（有界列表直接用 VStack）")
    func chatInspectorHasNoNestedLazyStacks() throws {
        let view = try source(Self.appSources + "Inspector/ChatInspectorView.swift")
        #expect(!view.contains("LazyVStack"))
    }
}
