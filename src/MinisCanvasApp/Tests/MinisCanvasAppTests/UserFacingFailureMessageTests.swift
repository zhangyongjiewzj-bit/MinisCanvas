import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("提示不清问题：失败文案映射")
@MainActor
struct UserFacingFailureMessageTests {
    // MARK: 备份

    @Test func wrongPasswordReturnsToPasswordSheet() {
        let failure = SettingsFailureMessage.backup(SyncProtectionError.wrongPasswordOrCorrupt, operation: .preview)
        #expect(failure.needsPasswordRetry)
        #expect(failure.message.contains("密码错误"))
        #expect(!failure.message.contains("SyncProtectionError"))
    }

    @Test func unsupportedFormatAndVersionAreNotPasswordErrors() {
        let scheme = SettingsFailureMessage.backup(SyncProtectionError.unsupportedVersion, operation: .preview)
        #expect(!scheme.needsPasswordRetry)
        #expect(scheme.message.contains("版本"))
        let manifest = SettingsFailureMessage.backup(
            SyncManifestError.unsupportedVersion(expected: 2, found: 1), operation: .preview)
        #expect(manifest.message.contains("v2") && manifest.message.contains("v1"))
        let invalid = SettingsFailureMessage.backup(SyncManifestError.invalidSnapshot("x"), operation: .preview)
        #expect(invalid.message.contains("格式不对"))
    }

    @Test func fileSystemErrorsSplitIntoPermissionSpaceAndMissing() {
        let denied = CocoaError(.fileReadNoPermission)
        let space = CocoaError(.fileWriteOutOfSpace)
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let wrapped = NSError(domain: "wrap", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(SettingsFailureMessage.fileCategory(denied) == .noPermission)
        #expect(SettingsFailureMessage.fileCategory(space) == .noSpace)
        #expect(SettingsFailureMessage.fileCategory(missing) == .notFound)
        #expect(SettingsFailureMessage.fileCategory(wrapped) == .noPermission)
        #expect(SettingsFailureMessage.backup(denied, operation: .preview).message.contains("读取"))
        #expect(SettingsFailureMessage.backup(CocoaError(.fileWriteNoPermission), operation: .export).message.contains("写入"))
        #expect(SettingsFailureMessage.backup(space, operation: .export).message.contains("磁盘空间不足"))
    }

    @Test func unrecognisedBackupErrorDoesNotLeakSwiftDescription() {
        struct Odd: Error {}
        let failure = SettingsFailureMessage.backup(Odd(), operation: .preview)
        #expect(failure.message.contains("原因未识别"))
        #expect(!failure.message.contains("Odd"))
        #expect(!failure.message.contains("BACKUP-PREVIEW-FAILED"))
    }

    // MARK: 删除 / 记忆

    @Test func deletionFailuresExplainCauseAndNextStep() {
        #expect(SettingsFailureMessage.deletion(DeletionGateError.targetChanged).contains("发生了变化"))
        #expect(SettingsFailureMessage.deletion(SettingsDeletionError.notFound("a")).contains("已不存在"))
        #expect(SettingsFailureMessage.deletion(SettingsDeletionError.rollbackFailed("x")).contains("回滚"))
        #expect(!SettingsFailureMessage.deletion(SettingsDeletionError.rollbackFailed("secret-detail")).contains("secret-detail"))
        #expect(SettingsFailureMessage.deletion(CocoaError(.fileWriteNoPermission)).contains("权限"))
    }

    @Test func memoryActionUsesTypedChineseDescriptions() {
        let text = SettingsFailureMessage.memoryAction(
            MemoryMarkdownCodec.Error.emptyDocument, action: "Markdown 导入预览",
            code: "X", hint: "h")
        #expect(text.contains("没有可导入的记忆条目"))
        let unknown = SettingsFailureMessage.memoryAction(
            NSError(domain: "x", code: 1), action: "记忆检索", code: "X", hint: "请检查检索词后重试。")
        #expect(unknown.contains("请检查检索词后重试。"))
        #expect(!unknown.contains("MEMORY-SEARCH-FAILED"))
    }

    // MARK: 项目会话

    @Test func projectSessionErrorsAllHaveChineseNextStep() {
        let all: [ProjectSessionAppError] = [
            .grantUnavailable, .grantChanged, .sourceUnavailable, .conflictingReplay,
            .persistenceUncertain, .targetUnavailable, .runUnavailable, .busy, .creationNotAuthorized,
        ]
        for error in all {
            #expect(error.userMessage.contains("请"), Comment(rawValue: "\(error)"))
            #expect(!error.userMessage.contains("ProjectSessionAppError"))
        }
    }

    // MARK: 定时任务 / 审批卡

    @Test func schedulerConfirmationSeparatesStorageFromStaleVersion() {
        let now = Date(timeIntervalSince1970: 1_756_650_000)
        let storage = SchedulerConfirmationFeedback.failureMessage(
            previewExpiresAt: now.addingTimeInterval(60), hasValidTarget: true, storageUnavailable: true, now: now)
        #expect(storage.contains("磁盘空间"))
        #expect(!storage.contains("版本"))
        let stale = SchedulerConfirmationFeedback.failureMessage(
            previewExpiresAt: now.addingTimeInterval(60), hasValidTarget: true, now: now)
        #expect(stale.contains("版本") && !stale.contains("存储"))
    }

    @Test func approvalCountdownText() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ApprovalCountdownText.text(deadline: now.addingTimeInterval(300), now: now) == "约 5 分钟后自动拒绝")
        #expect(ApprovalCountdownText.text(deadline: now.addingTimeInterval(61), now: now) == "约 2 分钟后自动拒绝")
        #expect(ApprovalCountdownText.text(deadline: now.addingTimeInterval(20), now: now) == "不到 1 分钟后自动拒绝")
        #expect(ApprovalCountdownText.text(deadline: now.addingTimeInterval(-1), now: now) == "即将自动拒绝")
    }

    @Test func mcpApprovalShowsServerToolRedactedArgumentsAndIrreversibleNotice() {
        let long = String(repeating: "a", count: 400)
        let card = ApprovalMCPPresentation(toolName: "mcp_github_create_issue", inputSummary: "title: " + long)
        #expect(card.identityLine.contains("github"))
        #expect(card.identityLine.contains("create_issue"))
        #expect(card.argumentsLine.contains("仅显示前 \(ApprovalMCPPresentation.argumentLimit) 字"))
        #expect(card.argumentsLine.count < 260)
        #expect(card.irreversibleNotice.contains("无法由本应用撤销"))
        #expect(ApprovalMCPPresentation(toolName: "mcp_a_b", inputSummary: "").argumentsLine == "参数：无")
    }

    // MARK: 浏览器与工具失败

    @Test func browserDenialsAreChineseAndKeepCodeSeparate() {
        for denial in [BrowserNavigationPolicy.Denial.invalidScope, .staleGeneration, .missingURL,
                       .unsupportedScheme, .missingHost, .invalidURL, .credentialsInURL,
                       .domainNotAuthorized, .crossOriginNotAuthorized, .insecureRedirect,
                       .newWindowNotAllowed, .downloadNotAuthorized, .formSubmissionNotAuthorized,
                       .requestMethodNotAuthorized, .resourceUnavailable] {
            let reason = "navigation_denied:" + denial.rawValue
            let result = ToolEventCard.browserDenialText(refusalReason: reason)
            #expect(result.code == reason)
            #expect(!result.text.contains(denial.rawValue), Comment(rawValue: reason))
            #expect(result.text.contains("请") || result.text.contains("设置"), Comment(rawValue: reason))
        }
        let domain = ToolEventCard.browserDenialText(refusalReason: "navigation_denied:domain_not_authorized")
        #expect(domain.text.contains("设置 → 智能体运行 → 运行安全上限"))
        #expect(ToolEventCard.browserDenialText(refusalReason: "write_authorization_required").text.contains("批准"))
        #expect(ToolEventCard.browserFailureText(failureCode: "cannot_go_back").text == "无法返回：没有上一页")
    }

    @Test func providerFailureSplitsByStatusCode() {
        #expect(ToolEventCard.providerFailureReason(statusCode: 401).contains("API Key"))
        #expect(ToolEventCard.providerFailureReason(statusCode: 429).contains("限流"))
        #expect(ToolEventCard.providerFailureReason(statusCode: 503).contains("服务端"))
        #expect(ToolEventCard.providerFailureReason(statusCode: 404).contains("模型名"))
        #expect(ToolEventCard.providerFailureReason(statusCode: nil).contains("检查"))
        #expect(ToolEventCard.statusCode(in: "请求失败 HTTP 429") == 429)
        #expect(ToolEventCard.statusCode(in: "状态码：401") == 401)
        #expect(ToolEventCard.statusCode(in: "读取了 500 字符") == nil)
    }

    @Test func toolFailureNamesToolAndStage() {
        #expect(ToolEventCard.toolFailureReason(toolName: "file_write", status: .failed).contains("「写入文件」执行中失败"))
        #expect(ToolEventCard.toolFailureReason(toolName: "file_write", status: .blocked).contains("没有执行"))
        #expect(ToolEventCard.toolFailureReason(toolName: nil, status: .failed).contains("该工具调用"))
    }
}
