import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 会话管理

@Suite("会话管理")
@MainActor
struct ChatSessionTests {
    @Test func duplicateSessionPreservesToolMetadataWithFreshSessionBoundary() {
        let chat = ChatStore()
        let sourceID = chat.activeSessionID!
        let call = LLMToolCall(
            id: "call-duplicate-1",
            name: "file_read",
            rawArguments: "{\"path\":\"notes.md\"}",
            arguments: ["path": "notes.md"]
        )
        chat.messages.append(ChatMessageUI(
            role: .assistant,
            content: "",
            toolCalls: [call]
        ))
        chat.messages.append(ChatMessageUI(
            role: .tool,
            content: "读取完成",
            toolCallID: call.id
        ))

        let copyID = chat.applyDuplicateSession(id: sourceID)
        let copy = chat.sessions.first { $0.id == copyID }
        let source = chat.sessions.first { $0.id == sourceID }

        #expect(copyID != nil)
        #expect(copyID != sourceID)
        #expect(copy?.transcriptRevision == 0)
        #expect(copy?.messages.map(\.role) == source?.messages.map(\.role))
        #expect(copy?.messages.last(where: { !$0.toolCalls.isEmpty })?.toolCalls == [call])
        #expect(copy?.messages.last?.toolCallID == call.id)
        #expect(source?.messages.last(where: { !$0.toolCalls.isEmpty })?.toolCalls == [call])
        #expect(source?.messages.last?.toolCallID == call.id)
    }

    @Test func toolRoleDecodesAndUnknownRoleFailsClosed() throws {
        let raw = """
        {"id":"00000000-0000-0000-0000-000000000001","role":"tool","content":"tool result","isStreaming":false,"timestamp":0,"toolCallID":"call-1","toolCalls":[]}
        """
        let decoded = try JSONDecoder().decode(ChatMessageUI.self, from: Data(raw.utf8))

        #expect(decoded.role == .tool)
        #expect(decoded.toolCallID == "call-1")
        #expect(decoded.toolCalls.isEmpty)

        let unknown = raw.replacingOccurrences(of: "\"tool\"", with: "\"future\"")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ChatMessageUI.self, from: Data(unknown.utf8))
        }
    }

    @Test func newSessionSwitchesAndKeepsMessages() {
        let chat = ChatStore()
        let firstID = chat.activeSessionID
        #expect(chat.sessions.count == 1)
        #expect(!chat.messages.isEmpty) // 欢迎语

        chat.appendUser("你好")
        #expect(chat.sessions[0].title == "你好")

        chat.newSession()
        #expect(chat.sessions.count == 2)
        #expect(chat.activeSessionID != firstID)
        #expect(chat.messages.isEmpty) // 新会话无消息

        chat.appendUser("新会话的第一条")
        #expect(chat.sessionsSorted.first?.title == "新会话的第一条")

        // 切回旧会话，旧消息仍在
        chat.switchSession(id: firstID!)
        #expect(chat.activeSessionID == firstID)
        #expect(chat.messages.contains { $0.content.contains("欢迎使用 MinisCanvas") })
        #expect(chat.messages.contains { $0.content == "你好" })
    }

    @Test func deleteSessionKeepsAtLeastOne() throws {
        let chat = ChatStore()
        let firstID = chat.activeSessionID
        chat.newSession()
        let secondID = chat.activeSessionID

        let intent = try chat.previewDeletion(id: secondID!)
            .withFirstConfirmation("I reviewed this exact conversation")
            .withSecondConfirmation("永久删除")
        try chat.deleteSession(id: secondID!, intent: intent)
        #expect(chat.sessions.count == 1)
        #expect(chat.activeSessionID == firstID)

        // 删除最后一个不允许
        #expect(throws: ChatStoreDeletionError.cannotDeleteLastSession(firstID!)) {
            let intent = try chat.previewDeletion(id: firstID!)
                .withFirstConfirmation("I reviewed this exact conversation")
                .withSecondConfirmation("永久删除")
            try chat.deleteSession(id: firstID!, intent: intent)
        }
        #expect(chat.sessions.count == 1)
        #expect(chat.activeSessionID == firstID)
    }

    @Test func titleFromFirstUserMessageTruncated() {
        let chat = ChatStore()
        let long = String(repeating: "很长的标题内容", count: 10)
        chat.appendUser(long)
        let title = chat.sessions[0].title
        #expect(title.hasSuffix("…"))
        #expect(title.count <= 21)
    }
}

// MARK: - AJ-30 会话归属项目 / 工作目录

@Suite("会话归属项目")
@MainActor
struct SessionProjectTests {
    @Test func newSessionWithProjectSetsFields() {
        let chat = ChatStore()
        chat.newSession(projectID: "proj-a", projectName: "Alpha", workingDirectory: "/Users/me/Alpha")
        let session = chat.sessions[1]
        #expect(session.projectID == "proj-a")
        #expect(session.projectName == "Alpha")
        #expect(session.workingDirectory == "/Users/me/Alpha")
    }

    @Test func setProjectAssignsAndClears() {
        let chat = ChatStore()
        let id = chat.activeSessionID!
        chat.setProject(ChatStore.SessionProject(id: "p1", name: "MyApp", workingDirectory: "/tmp/MyApp"), forSession: id)
        #expect(chat.sessions[0].projectID == "p1")
        #expect(chat.sessions[0].projectName == "MyApp")
        #expect(chat.sessions[0].workingDirectory == "/tmp/MyApp")

        chat.setProject(nil, forSession: id)
        #expect(chat.sessions[0].projectID == nil)
        #expect(chat.sessions[0].projectName == nil)
        #expect(chat.sessions[0].workingDirectory == nil)
    }

    @Test func sessionGroupsByProject() {
        let chat = ChatStore()
        // 未归属（默认）
        let unassignedID = chat.activeSessionID!
        // 归入项目 A
        chat.newSession(projectID: "proj-b", projectName: "Beta", workingDirectory: "/tmp/Beta")
        let betaID = chat.activeSessionID!
        chat.newSession(projectID: "proj-a", projectName: "Alpha", workingDirectory: "/tmp/Alpha")
        let alphaID = chat.activeSessionID!

        let groups = chat.sessionGroups
        // 有项目组按名称排序（Alpha 在 Beta 前），未归属组在最后
        #expect(groups.count == 3)
        #expect(groups[0].name == "Alpha")
        #expect(groups[0].items.map(\.session.id) == [alphaID])
        #expect(groups[1].name == "Beta")
        #expect(groups[1].items.map(\.session.id) == [betaID])
        #expect(groups[2].name == "未归属项目")
        #expect(groups[2].items.map(\.session.id) == [unassignedID])
    }

    @Test func sameProjectNameGroupsTogether() {
        let chat = ChatStore()
        chat.newSession(projectID: "proj-a", projectName: "Alpha", workingDirectory: "/tmp/A1")
        chat.newSession(projectID: "proj-a", projectName: "Alpha", workingDirectory: "/tmp/A2")
        let groups = chat.sessionGroups.filter {
            if case .project("proj-a") = $0.kind { return true }
            return false
        }
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
    }

    @Test func projectIDFromNameIsStableAndTrimmed() {
        #expect(ChatStore.projectID(for: "  MyApp  ") == "MyApp")
        #expect(ChatStore.projectID(for: "   ") == "project")
    }
}

// MARK: - 模型选择

@Suite("模型选择")
@MainActor
struct ModelSelectionTests {
    @Test func providerSwitchSelectsFirstBuiltInModel() {
        let chat = ChatStore()
        #expect(chat.selectedProviderType == nil) // 默认 Mock
        #expect(chat.providerLabel == "演示模式")

        chat.setProvider(.dashScope)
        #expect(chat.selectedProviderType == .dashScope)
        #expect(chat.selectedModelID == "qwen3.8-max-preview")
        #expect(chat.providerLabel.contains("qwen3.8-max-preview"))

        chat.setProvider(nil)
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == nil)
    }

    @Test func activeProviderCarriesSelectedModel() throws {
        let chat = ChatStore()
        chat.setProvider(.dashScope)
        let provider = try chat.activeProvider()
        #expect(provider.model.id == "qwen3.8-max-preview")

        // 自定义模型名（本地场景）
        chat.setProvider(.local)
        chat.selectedModelID = "qwen2.5-coder"
        let local = try chat.activeProvider()
        #expect(local.model.id == "qwen2.5-coder")
    }

    @Test func chatProviderTypesAreRegistered() {
        let types = ChatStore.chatProviderTypes
        #expect(types.contains(.openAI))
        #expect(types.contains(.anthropic))
        #expect(types.contains(.dashScope))
        #expect(types.contains(.local))
        // 生图/生视频专用不在聊天列表
        #expect(!types.contains(.gimage2))
        #expect(!types.contains(.kling))
        #expect(!types.contains(.jimeng))
    }
}

// MARK: - 流式打字机（Mock Provider）

@Suite("流式回复")
@MainActor
struct StreamingTests {
    @Test func mockStreamCompletesWithTypewriter() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "你好，介绍一下你自己"
        chat.sendDraft()

        #expect(chat.isStreaming)
        // 等待流式完成（Mock 打字机约 1~2s）
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        #expect(!chat.isStreaming)
        let last = chat.messages.last
        #expect(last?.role == .assistant)
        #expect(last?.isStreaming == false)
        #expect(last?.content.isEmpty == false)
        #expect(last?.content.contains("收到：你好，介绍一下你自己") == true)
    }

    @Test func stopStreamingInterrupts() async throws {
        let chat = ChatStore()
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "继续输出"
        chat.sendDraft()
        #expect(chat.isStreaming)
        chat.stopStreaming()
        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.isStreaming == false)
    }
}

// MARK: - Markdown 解析

@Suite("Markdown 解析")
struct MarkdownParserTests {
    @Test func codeFenceWithLanguage() {
        let blocks = MarkdownParser.blocks(from: "```swift\nlet a = 1\nprint(a)\n```")
        #expect(blocks.count == 1)
        guard case .code(let language, let code)? = blocks.first else {
            Issue.record("应为代码块"); return
        }
        #expect(language == "swift")
        #expect(code == "let a = 1\nprint(a)")
    }

    @Test func unclosedFenceStillExtractsCode() {
        let blocks = MarkdownParser.blocks(from: "```\ncode line 1\ncode line 2")
        guard case .code(_, let code)? = blocks.first else {
            Issue.record("应为代码块"); return
        }
        #expect(code == "code line 1\ncode line 2")
    }

    @Test func headingLevels() {
        let blocks = MarkdownParser.blocks(from: "# 大标题\n\n## 小标题")
        #expect(blocks.count == 2)
        guard case .heading(let l1, let t1) = blocks[0] else { Issue.record("应为标题"); return }
        #expect(l1 == 1 && t1 == "大标题")
        guard case .heading(let l2, let t2) = blocks[1] else { Issue.record("应为标题"); return }
        #expect(l2 == 2 && t2 == "小标题")
    }

    @Test func listAndParagraph() {
        let blocks = MarkdownParser.blocks(from: "- 甲\n- 乙\n\n普通段落")
        #expect(blocks.count == 2)
        guard case .list(let items) = blocks[0] else { Issue.record("应为列表"); return }
        #expect(items == ["甲", "乙"])
        guard case .paragraph(let p) = blocks[1] else { Issue.record("应为段落"); return }
        #expect(p == "普通段落")
    }

    @Test func inlineMarkdownStaysInParagraph() {
        let blocks = MarkdownParser.blocks(from: "这是 `行内代码` 和 **粗体** 与 [链接](https://example.com)")
        #expect(blocks.count == 1)
        guard case .paragraph(let p)? = blocks.first else { Issue.record("应为段落"); return }
        #expect(p.contains("`行内代码`"))
        #expect(p.contains("**粗体**"))
    }
}
