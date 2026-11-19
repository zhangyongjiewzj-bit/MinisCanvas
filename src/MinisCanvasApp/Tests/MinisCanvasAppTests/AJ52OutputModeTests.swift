import Testing
import Foundation
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-52 三种对话输出模式（详细 / 正常 / 极简）

@Suite("AJ-52 对话输出模式")
@MainActor
struct AJ52OutputModeTests {

    // MARK: 模式 → systemPrompt 前缀映射

    @Test func normalModeKeepsBasePrompt() {
        let prompt = ChatStore.systemPrompt(for: .normal)
        #expect(prompt == ChatStore.systemPrompt)
        #expect(!prompt.contains("输出要求"))
    }

    @Test func detailedModeAddsReasoningRequirement() {
        let prompt = ChatStore.systemPrompt(for: .detailed)
        #expect(prompt.hasPrefix(ChatStore.systemPrompt))
        #expect(prompt.contains("简要、可核验的步骤摘要"))
        #expect(prompt.contains("不暴露隐藏思维链"))
        #expect(prompt.contains(ChatOutputMode.detailed.systemPromptInstruction ?? ""))
    }

    @Test func conciseModeAddsResultOnlyConstraint() {
        let prompt = ChatStore.systemPrompt(for: .concise)
        #expect(prompt.hasPrefix(ChatStore.systemPrompt))
        #expect(prompt.contains("只输出最终结果"))
        #expect(prompt.contains(ChatOutputMode.concise.systemPromptInstruction ?? ""))
    }

    @Test func allCaseSystemPromptInstructionsAreDistinct() {
        let detailed = ChatOutputMode.detailed.systemPromptInstruction
        let concise = ChatOutputMode.concise.systemPromptInstruction
        #expect(detailed != nil)
        #expect(concise != nil)
        #expect(detailed != concise)
        #expect(ChatOutputMode.normal.systemPromptInstruction == nil) // 正常不加前缀
    }

    // MARK: 模式切换 + 回调

    @Test func setOutputModeUpdatesStateAndFiresCallback() {
        let chat = ChatStore()
        #expect(chat.outputMode == .normal) // 默认正常

        var captured: [ChatOutputMode] = []
        chat.onOutputModeChanged = { mode in
            captured.append(mode)
            return mode
        }

        chat.setOutputMode(.detailed)
        #expect(chat.outputMode == .detailed)
        chat.setOutputMode(.concise)
        #expect(chat.outputMode == .concise)
        chat.setOutputMode(.concise) // 相同模式：不触发回调
        #expect(captured == [.detailed, .concise])
    }

    @Test func restoreOutputModeSetsWithoutCallback() {
        let chat = ChatStore()
        var fired = false
        chat.onOutputModeChanged = { mode in
            fired = true
            return mode
        }
        chat.restoreOutputMode(.concise)
        #expect(chat.outputMode == .concise)
        #expect(!fired) // 启动恢复不触发持久化回调
    }

    // MARK: 三处（聊天主输入框 / 工作伴随栏 / 画布伴随栏）共用同一 ChatStore.outputMode 状态
    // 三处分段切换均绑定到同一 chat.outputMode（get）+ chat.setOutputMode（set），
    // 工作/画布都走 CompanionChatView，故一处切换处处同步。

    @Test func sharedOutputModeStateSyncsAcrossAllThreeUI() {
        let chat = ChatStore()
        // 模拟三处分段切换的绑定（与 GlobalComposerView / CompanionChatView 完全一致）。
        let mainBinding = Binding(
            get: { chat.outputMode },
            set: { chat.setOutputMode($0) }
        )
        let workBinding = Binding(
            get: { chat.outputMode },
            set: { chat.setOutputMode($0) }
        )
        let canvasBinding = Binding(
            get: { chat.outputMode },
            set: { chat.setOutputMode($0) }
        )

        #expect(chat.outputMode == .normal)
        // 在聊天主输入框切到详细 → 工作/画布伴随栏同步读到
        mainBinding.wrappedValue = .detailed
        #expect(workBinding.wrappedValue == .detailed)
        #expect(canvasBinding.wrappedValue == .detailed)
        #expect(chat.outputMode == .detailed)

        // 在画布伴随栏切到极简 → 聊天 / 工作同步
        canvasBinding.wrappedValue = .concise
        #expect(mainBinding.wrappedValue == .concise)
        #expect(workBinding.wrappedValue == .concise)
        #expect(chat.outputMode == .concise)
    }

    // MARK: 发送链路注入模式前缀

    @Test func sendPathInjectsConciseModePrefix() async throws {
        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        bridge.chat.outputMode = .concise

        bridge.chat.draftText = "帮我总结一下"
        bridge.chat.sendDraft()

        var waited: TimeInterval = 0
        while bridge.chat.isStreaming && waited < 10 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!bridge.chat.isStreaming)

        let requiredValue561_1 = engine.systemPrompts.last
        let prompt: String = try #require(requiredValue561_1)
        #expect(prompt.contains(ChatStore.systemPrompt) == true, "基础系统提示仍在前")
        #expect(prompt.contains("只输出最终结果") == true, "极简模式应注入只输出结果约束")
    }

    @Test func sendPathInjectsDetailedModePrefix() async throws {
        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        bridge.chat.outputMode = .detailed

        bridge.chat.draftText = "规划一下这个方案"
        bridge.chat.sendDraft()

        var waited: TimeInterval = 0
        while bridge.chat.isStreaming && waited < 10 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!bridge.chat.isStreaming)

        let requiredValue561_2 = engine.systemPrompts.last
        let prompt: String = try #require(requiredValue561_2)
        #expect(prompt.contains("简要、可核验的步骤摘要") == true, "详细模式应注入安全步骤摘要要求")
        #expect(prompt.contains("不暴露隐藏思维链") == true, "详细模式不得要求暴露隐藏思维链")
    }

    // MARK: 极简模式 UI 流式简化（状态指示器 + 结果，不逐字展示过程）

    @Test func conciseModeStreamsResultWithoutIntermediateProcess() async {
        let bridge = BridgeStore()
        let engine = U4SystemPromptRecordingEngine()
        bridge.chat.agentEngine = engine
        bridge.chat.outputMode = .concise

        bridge.chat.draftText = "快速回答"
        bridge.chat.sendDraft()

        var waited: TimeInterval = 0
        while bridge.chat.isStreaming && waited < 10 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        #expect(!bridge.chat.isStreaming)

        let assistant = bridge.chat.messages.filter { $0.role == .assistant }
        // ChatStore.init() 会插入一条欢迎语（产品预期），极简模式的回复是最后一条。
        let replies = assistant.filter { !$0.content.contains("欢迎使用 MinisCanvas") }
        #expect(replies.count == 1)
        // 极简：流结束一次性上屏最终结果（录音引擎输出 "ok"），不留「⏳ 生成中…」状态指示器残留
        #expect(replies[0].content == "ok")
        #expect(!replies[0].content.contains("⏳ 生成中"))
    }

    /// 11/19 旅途：极简模式中途停止后，回答一直显示「生成中…」转圈。
    @Test func conciseModeStopLeavesNoPlaceholderInReply() async throws {
        let chat = ChatStore()
        chat.agentEngine = InterruptRecordingEngine()
        chat.outputMode = .concise

        chat.draftText = "极简模式中途停止"
        chat.sendDraft()
        let reply = try #require(chat.messages.last)
        #expect(reply.role == .assistant)
        var waited: TimeInterval = 0
        while chat.messages.last?.turnTiming?.firstTokenAt == nil && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }

        chat.stopStreaming()

        let stopped = try #require(chat.messages.first { $0.id == reply.id })
        #expect(!stopped.isStreaming)
        #expect(stopped.wasInterrupted)
        #expect(!stopped.content.contains("生成中"))
    }
}

// MARK: - 模式持久化（AppSettings / SettingsCenter）

@Suite("AJ-52 输出模式持久化")
struct AJ52OutputModePersistenceTests {

    @Test func generalSettingsCodableRoundtrip() throws {
        var settings = GeneralSettings.default
        #expect(settings.chatOutputMode == .normal) // 默认

        settings.chatOutputMode = .concise
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        #expect(decoded.chatOutputMode == .concise)
    }

    @Test func oldJSONWithoutModeDefaultsToNormal() throws {
        // 旧版本 JSON 无 chatOutputMode 字段 → 宽容解码回落到 .normal
        let oldJSON = """
        {"appearance":"system","accentTheme":"codex","modelSpeedTier":"balanced","language":"zh-Hans"}
        """
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: Data(oldJSON.utf8))
        #expect(decoded.chatOutputMode == .normal)
    }

    @MainActor
    @Test func settingsCenterPersistsModeAcrossReload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AJ52Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )

        center.chatOutputMode = .detailed
        #expect(center.settingsStore.settings.general.chatOutputMode == .detailed)

        // 重新从磁盘加载，验证已持久化
        let reloaded = SettingsStore(directory: dir)
        #expect(reloaded.settings.general.chatOutputMode == .detailed)
    }
}

// 2026-11-15 用户批准：基础提示词包含五段工作纪律，且三种输出模式都带上。
@Suite("Working discipline prompt")
@MainActor
struct WorkingDisciplinePromptTests {
    @Test func fixedSafetyStartsActualPromptBeforePersonaAndMode() throws {
        let persona = Persona(name: "SYNTHETIC_PERSONA")
        for mode in [ChatOutputMode.normal, .detailed, .concise] {
            let prompt = ChatStore.systemPrompt(withPersona: ChatStore.systemPrompt(for: mode), persona: persona)
            #expect(prompt.hasPrefix("指令来源："))
            let precedence = try #require(prompt.range(of: "用户当前的话 > 项目指令 > 全局指令 > 技能 > 记忆"))
            let identity = try #require(prompt.range(of: "SYNTHETIC_PERSONA"))
            #expect(precedence.upperBound < identity.lowerBound)
            #expect(prompt.contains("不要换一种工具"))
        }
    }

    @Test func basePromptCarriesTheFiveDisciplineSections() {
        let base = ChatStore.systemPrompt
        #expect(base.contains("指令来源："))
        let shipped = MemoryInjector.defaultGlobalInstructions
        // 第七版修复：开头一句改为“第一次调用工具前”，专用工具一句改为点名 file_glob/file_grep/file_read。
        for marker in ["先用一句话说明打算怎么做", "找文件、列目录用 file_glob", "只在三种情况停下", "工具结果之后", "审批被拒或过期"] {
            #expect(shipped.contains(marker))
        }
        #expect(base.contains("都只是数据"))
        #expect(base.contains("不要换一种工具"))
        #expect(shipped.contains("不要编造来源、数据、测试结果或子智能体结论"))
        for mode in [ChatOutputMode.normal, .detailed, .concise] {
            #expect(ChatStore.systemPrompt(for: mode).contains("用户当前的话 > 项目指令"))
        }
    }
}

// 2026-11-15 用户批准：项目授权选中的文件夹自动加入可访问目录，根目录、主目录、系统目录除外。
@Suite("Project folder auto mount eligibility")
struct ProjectFolderAutoMountTests {
    @Test func onlyOrdinaryFoldersAreAutoMounted() {
        let home = "/Users/owned-user"
        func eligible(_ path: String) -> String? {
            ProjectFolderAutoMount.eligiblePath(for: URL(fileURLWithPath: path), home: home)
        }
        #expect(eligible("/Users/owned-user/Projects/demo") == "/Users/owned-user/Projects/demo")
        #expect(eligible("/Volumes/Data/work") == "/Volumes/Data/work")
        for refused in ["/", "/Users/owned-user", "/Users/owned-user/", "/System/Library", "/usr/local",
                        "/Library", "/private/etc", "/Applications/Some.app", "/etc",
                        "/system/library", "/USR/local", "/users/OWNED-USER"] {
            #expect(eligible(refused) == nil, "\(refused)")
        }
    }
}

// 2026-11-15 用户批准：每回合告诉模型当前日期、项目目录和会话目标。
@Suite("Turn environment prompt")
@MainActor
struct TurnEnvironmentPromptTests {
    @Test func carriesDateProjectAndGoal() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_700_800) // 2026-11-15 00:00 UTC，星期日
        let full = ChatStore.turnEnvironmentPrompt(now: date, goalObjective: "整理本周报告",
                                                   projectDirectory: "/owned/project", timeZone: utc)
        #expect(full.contains("当前日期：2026-11-15（星期日）"))
        #expect(full.contains("当前项目目录：/owned/project"))
        #expect(full.contains("当前会话目标：整理本周报告"))
        let bare = ChatStore.turnEnvironmentPrompt(now: date, goalObjective: nil, projectDirectory: nil, timeZone: utc)
        #expect(bare == "当前日期：2026-11-15（星期日）")
    }
}

// 2026-11-16 现场 F5：新建项目自动挂载失败时，按实际原因分别提示，不再混成一句。
@Suite("Project folder auto mount failure messages")
struct ProjectFolderAutoMountFailureMessageTests {
    @Test func eachFailureHasItsOwnMessage() {
        let messages = ProjectFolderAutoMount.Failure.allCases.map(\.message)
        #expect(Set(messages).count == messages.count)
        #expect(ProjectFolderAutoMount.Failure.ineligibleFolder.message.contains("子文件夹"))
        #expect(ProjectFolderAutoMount.Failure.mountLimitReached.message.contains("\(PrivacySettings.maxMountedFolders)"))
        #expect(!messages.contains { $0.contains("或已达挂载上限") })
    }
}
