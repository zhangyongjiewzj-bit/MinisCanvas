import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore
import os

/// The actual confirmation sheet's warning and required phrase are derived
/// from the producer's recovery contract, without requiring a UI launch.
struct SettingsDeletionPresentation {
    let warning: String
    let secondPhrase: String

    init(intent: OperationIntent) {
        warning = intent.reversible ? "本次操作会移入回收站，可恢复。" : "本次操作不可恢复。"
        secondPhrase = intent.reversible && intent.operationType == .delete
            ? "I CONFIRM MOVE TO TRASH"
            : "永久删除"
    }
}

private struct SettingsDeletionRequest: Identifiable {
    let intent: OperationIntent
    let execute: ((OperationIntent) throws -> DeletionReceipt)?
    let executeAsync: (@MainActor (OperationIntent) async throws -> DeletionReceipt)?
    let preview: (() throws -> OperationIntent)?

    init(intent: OperationIntent, execute: @escaping (OperationIntent) throws -> DeletionReceipt) {
        self.intent = intent
        self.execute = execute
        self.executeAsync = nil
        self.preview = nil
    }

    init(
        preview: @escaping () throws -> OperationIntent,
        execute: @escaping (OperationIntent) throws -> DeletionReceipt,
        restarting expired: OperationIntent?
    ) throws {
        let fresh = try preview()
        if let expired {
            // The producer's fingerprint binds the reviewed record or batch.
            // A new operation ID and expiry are expected after a fresh preview.
            guard fresh.operationType == expired.operationType,
                  fresh.targetType == expired.targetType,
                  fresh.targetID == expired.targetID,
                  fresh.scopeID == expired.scopeID,
                  fresh.reversible == expired.reversible,
                  fresh.affectedCount == expired.affectedCount,
                  fresh.revision == expired.revision,
                  fresh.fingerprint == expired.fingerprint else {
                throw DeletionGateError.targetChanged
            }
        }
        self.intent = fresh
        self.execute = execute
        self.executeAsync = nil
        self.preview = preview
    }

    init(intent: OperationIntent, executeAsync: @escaping @MainActor (OperationIntent) async throws -> DeletionReceipt) {
        self.intent = intent
        self.execute = nil
        self.executeAsync = executeAsync
        self.preview = nil
    }

    var id: UUID { intent.operationID }
}

private struct SettingsDeletionExpiredNotice: View {
    let accessibilityPrefix: String
    let restart: () -> Void
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("确认已超过 300 秒失效，请重新发起。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).status")
            Button("重新发起确认", action: restart)
                .accessibilityIdentifier("\(accessibilityPrefix).restart-deletion")
        }
    }
}

private struct SettingsDeletionPrompt: View {
    @Environment(\.themeTokens) private var theme
    let request: SettingsDeletionRequest
    let onCancel: () -> Void
    let onConfirm: (OperationIntent) -> Void

    private enum Step {
        case first
        case second
    }

    @State private var step: Step = .first
    @State private var firstConfirmation = ""
    @State private var secondConfirmation = ""
    @Environment(\.typographyTokens) private var typography

    private var secondPhrase: String {
        SettingsDeletionPresentation(intent: request.intent).secondPhrase
    }

    var body: some View {
        if request.intent.reversible && request.intent.operationType == .delete {
            recoverableConfirmation
        } else {
            typedConfirmation
        }
    }

    private var recoverableConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认删除")
                .font((typography?.headline ?? .title3).weight(.semibold))
            Text(request.intent.targetName)
            Text(request.intent.impactSummary)
            Text(SettingsDeletionPresentation(intent: request.intent).warning)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    onConfirm(request.intent
                        .withFirstConfirmation("settings-recoverable-delete")
                        .withSecondConfirmation(secondPhrase))
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private var requiresExactTargetName: Bool {
        ["provider", "environment.variable"].contains(request.intent.targetType)
    }

    private var firstConfirmationAccepted: Bool {
        requiresExactTargetName
            ? firstConfirmation == request.intent.targetName
            : !firstConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var typedConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                MinisIconView(.delete, size: 12)
                    .foregroundPalette(theme?.statusDanger ?? AppStatusColor.danger)
                Text("确认删除")
                    .font((typography?.headline ?? .title3).weight(.semibold))
                Spacer()
            }

            Text(request.intent.targetName)
                .font(typography?.headline ?? .headline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(request.intent.impactSummary)
                .foregroundStyle(.secondary)
            Text(SettingsDeletionPresentation(intent: request.intent).warning)
                .foregroundStyle(request.intent.reversible ? Color.secondary : (theme?.statusDangerText ?? AppStatusColor.danger))

            switch step {
            case .first:
                Text(requiresExactTargetName
                     ? "第一步：核对目标和影响范围，然后请输入「\(request.intent.targetName)」。"
                     : "第一步：核对目标和影响范围，然后输入确认文字。")
                    .foregroundStyle(.secondary)
                TextField(requiresExactTargetName ? "输入「\(request.intent.targetName)」" : "输入第一确认文字",
                          text: $firstConfirmation)
                    .textFieldStyle(.roundedBorder)
            case .second:
                Text("第二步：输入 \(secondPhrase) 才会执行。")
                    .foregroundStyle(.secondary)
                TextField(secondPhrase, text: $secondConfirmation)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                switch step {
                case .first:
                    Button("下一步") {
                        step = .second
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!firstConfirmationAccepted)
                case .second:
                    Button(request.intent.reversible ? "执行" : "永久删除", role: .destructive) {
                        onConfirm(
                            request.intent
                                .withFirstConfirmation(requiresExactTargetName ? firstConfirmation
                                    : firstConfirmation.trimmingCharacters(in: .whitespacesAndNewlines))
                                .withSecondConfirmation(secondConfirmation.trimmingCharacters(in: .whitespacesAndNewlines))
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((requiresExactTargetName && !firstConfirmationAccepted)
                        || secondConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) != secondPhrase)
                }
            }
        }
        .modifier(TypedDeletionDialogLayout())
    }
}

struct TypedDeletionDialogLayout: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(24).frame(width: 460).interactiveDismissDisabled()
    }
}

private enum BackupProtectionAction: Identifiable {
    case export(URL)
    case importFile(URL)

    var id: String {
        switch self {
        case .export(let url): return "export:\(url.path)"
        case .importFile(let url): return "import:\(url.path)"
        }
    }

    var url: URL {
        switch self {
        case .export(let url), .importFile(let url): return url
        }
    }

    var isExport: Bool {
        if case .export = self { return true }
        return false
    }
}

// MARK: - 设置页失败文案（按错误类型给中文原因与做法）

/// 文件读写类错误的归类。
enum SettingsFailureCategory: Equatable {
    case noPermission, noSpace, notFound, fileFormat, other
}

/// 备份失败：文案 + 是否应回到密码框。
struct SettingsBackupFailure: Equatable {
    let message: String
    let needsPasswordRetry: Bool
}

enum SettingsBackupOperation { case preview, export }

/// 设置页 catch 分支用的纯函数映射。主句只放中文原因与下一步；内部代码写日志，不进主句。
enum SettingsFailureMessage {
    private static let logger = Logger(subsystem: "MinisCanvas", category: "settings-failure")

    /// 内部代码只记日志（错误类型名与代码，不记描述，避免路径外泄）。
    static func log(code: String, error: Error) {
        logger.error("\(code, privacy: .public) \(String(reflecting: type(of: error)), privacy: .public)")
    }

    static func fileCategory(_ error: Error, depth: Int = 0) -> SettingsFailureCategory {
        if error is DecodingError { return .fileFormat }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case CocoaError.Code.fileReadNoPermission.rawValue,
                 CocoaError.Code.fileWriteNoPermission.rawValue,
                 CocoaError.Code.fileWriteVolumeReadOnly.rawValue:
                return .noPermission
            case CocoaError.Code.fileWriteOutOfSpace.rawValue:
                return .noSpace
            case CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue:
                return .notFound
            case CocoaError.Code.fileReadCorruptFile.rawValue,
                 CocoaError.Code.fileReadInapplicableStringEncoding.rawValue,
                 CocoaError.Code.propertyListReadCorrupt.rawValue:
                return .fileFormat
            default: break
            }
        } else if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EACCES, EPERM, EROFS: return .noPermission
            case ENOSPC, EDQUOT: return .noSpace
            case ENOENT: return .notFound
            default: break
            }
        }
        if depth < 3, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return fileCategory(underlying, depth: depth + 1)
        }
        return .other
    }

    private static func categoryReason(_ category: SettingsFailureCategory, writing: Bool) -> String? {
        switch category {
        case .noPermission:
            return writing
                ? "没有写入该位置的权限。请换一个可写的文件夹，或在“系统设置 → 隐私与安全性”中授权后重试"
                : "没有读取该文件的权限。请把文件放到可访问的位置，或在“系统设置 → 隐私与安全性”中授权后重试"
        case .noSpace:
            return "磁盘空间不足。请清理磁盘后重试"
        case .notFound:
            return "找不到目标文件，可能已被移动或删除。请重新选择"
        case .fileFormat:
            return "文件格式不对，无法解析。请确认选择的是本应用导出的文件"
        case .other:
            return nil
        }
    }

    /// 备份预览 / 导出失败。
    static func backup(_ error: Error, operation: SettingsBackupOperation) -> SettingsBackupFailure {
        let writing = operation == .export
        let prefix = writing ? "备份导出未完成：" : "备份预览未完成："
        if let protection = error as? SyncProtectionError {
            switch protection {
            case .wrongPasswordOrCorrupt:
                return SettingsBackupFailure(
                    message: "密码错误，或备份文件已损坏。请重新输入密码；若确认密码无误，请换一份备份文件",
                    needsPasswordRetry: true)
            case .protectionRequired:
                return SettingsBackupFailure(message: "此备份受密码保护，请输入密码后重试", needsPasswordRetry: true)
            case .unsupportedEnvelope, .unsupportedScheme, .unsupportedVersion:
                return SettingsBackupFailure(
                    message: prefix + "备份的保护格式或版本不受支持，可能来自更新版本的应用。请升级应用，或换一份备份",
                    needsPasswordRetry: false)
            case .invalidParameters, .resourceLimit:
                return SettingsBackupFailure(
                    message: prefix + "文件过大或参数异常。请确认选择的是本应用导出的 .minissync 文件",
                    needsPasswordRetry: false)
            case .randomSourceFailed, .keyDerivationFailed:
                return SettingsBackupFailure(
                    message: prefix + "系统暂时无法完成加解密准备（可能内存不足）。请稍后重试",
                    needsPasswordRetry: false)
            case .cancelled:
                return SettingsBackupFailure(message: "备份操作已取消", needsPasswordRetry: false)
            }
        }
        if let manifest = error as? SyncManifestError {
            switch manifest {
            case .unsupportedVersion(let expected, let found):
                return SettingsBackupFailure(
                    message: prefix + "备份版本不匹配（需要 v\(expected)，文件是 v\(found)）。请用对应版本的应用导出，或换一份备份",
                    needsPasswordRetry: false)
            case .wrongSourceApplication:
                return SettingsBackupFailure(message: prefix + "该备份来自其他应用，无法导入", needsPasswordRetry: false)
            case .emptyScopes, .missingScopes, .incompletePayload, .invalidSnapshot:
                return SettingsBackupFailure(
                    message: prefix + "文件格式不对或内容不完整。请确认选择的是本应用导出的 .minissync 文件",
                    needsPasswordRetry: false)
            }
        }
        if let metadata = error as? SettingsCenter.AtomicBackupMetadataError,
           let text = metadata.errorDescription {
            return SettingsBackupFailure(message: prefix + text, needsPasswordRetry: false)
        }
        if error is SyncSnapshotExportError {
            return SettingsBackupFailure(
                message: prefix + "有记忆条目与审批来源绑定，无法改写后导出（推断）。请先在“设置 → 记忆”中处理这类条目",
                needsPasswordRetry: false)
        }
        if let reason = categoryReason(fileCategory(error), writing: writing) {
            return SettingsBackupFailure(message: prefix + reason, needsPasswordRetry: false)
        }
        log(code: writing ? "BACKUP-EXPORT-FAILED" : "BACKUP-PREVIEW-FAILED", error: error)
        return SettingsBackupFailure(
            message: prefix + "原因未识别。请检查文件格式与访问权限后重试；详情已写入日志",
            needsPasswordRetry: false)
    }

    /// 删除失败（三处设置页共用）。`.expired` 由调用方单独处理。
    static func deletion(_ error: Error) -> String {
        if let gate = error as? DeletionGateError {
            switch gate {
            case .targetChanged:
                return "删除未完成：待删除的内容在确认后发生了变化。请刷新列表，重新选择并确认"
            case .alreadyExecuting:
                return "删除未完成：同一删除正在执行。请稍候，完成后再刷新列表"
            case .alreadyConsumed:
                return "删除未完成：这次确认已经使用过。请刷新列表后重新发起删除"
            case .cancelled:
                return "删除已取消，没有改动任何数据"
            case .expired:
                return "删除未完成：确认已过期。请重新发起删除"
            case .firstConfirmationRequired, .secondConfirmationRequired, .irreversibleRequiresPhrase,
                 .invalidScope, .invalidIntent:
                return "删除未完成：确认步骤不完整。请重新发起删除并完成全部确认"
            }
        }
        if let failure = error as? SettingsDeletionError {
            switch failure {
            case .notFound:
                return "删除未完成：要删除的项目已不存在。请刷新列表"
            case .operationFailed(let reason):
                return "删除未生效：\(reason)。请刷新列表后重试"
            case .rollbackFailed:
                return "删除中途失败，且自动回滚没有完全成功。请先不要继续操作，重新打开应用后检查数据"
            }
        }
        if let reason = categoryReason(fileCategory(error), writing: true) {
            return "删除未完成：" + reason
        }
        log(code: "DELETE-FAILED", error: error)
        return "删除未完成：原因未识别。请刷新列表，必要时重新打开应用后再检查；详情已写入日志"
    }

    /// 记忆检索 / 导出 / 导入等通用动作。`hint` 是原因未识别时的下一步。
    static func memoryAction(_ error: Error, action: String, code: String, hint: String,
                             writing: Bool = false) -> String {
        if let known = error as? MemoryMarkdownImportError, let text = known.errorDescription {
            return "\(action)未完成：" + text
        }
        if let known = error as? MemoryFileExportError, let text = known.errorDescription {
            return "\(action)未完成：" + text
        }
        if let known = error as? MemoryProposalConsumerError, let text = known.errorDescription {
            return "\(action)未完成：" + text
        }
        if let known = error as? MemoryMarkdownCodec.Error, let text = known.errorDescription {
            return "\(action)未完成：\(text)请对照导出的文件修正后重试"
        }
        if let reason = categoryReason(fileCategory(error), writing: writing) {
            return "\(action)未完成：" + reason
        }
        log(code: code, error: error)
        return "\(action)未完成：原因未识别。\(hint)详情已写入日志"
    }
}

private struct BackupProtectionSheet: View {
    let action: BackupProtectionAction
    var errorMessage: String? = nil
    let onCancel: @MainActor () -> Void
    let onSubmit: @MainActor (SyncSnapshotProtection) -> Void

    @State private var usePassword = true
    @State private var password = ""
    @State private var confirmation = ""

    private var passwordIsValid: Bool {
        password.unicodeScalars.count >= 12 && password.utf8.count <= 1024
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.isExport ? "保护备份" : "解锁备份")
                .font(.title2.weight(.semibold))
            if action.isExport {
                Text("密码只在本次操作期间使用，不会保存到设置、备份清单、日志或 Keychain。")
                    .foregroundStyle(.secondary)
                Toggle("使用密码保护导出", isOn: $usePassword)
                if usePassword {
                    SecureField("密码（至少 12 个字符）", text: $password)
                        .textFieldStyle(.roundedBorder)
                    SecureField("再次输入密码", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                    Text("密码区分大小写，首尾空格也会作为密码内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("明文导出仅用于兼容旧调用方；文件可能包含私人会话和长期记忆。")
                        .modifier(ReadableStatusForeground(status: .danger))
                }
            } else {
                Text("此备份文件受密码保护。认证完成前不会读取私有载荷或写入目标数据。")
                    .foregroundStyle(.secondary)
                SecureField("输入备份密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage)
                        .modifier(ReadableStatusForeground(status: .danger))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.backup.password-error")
                }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button(action.isExport ? (usePassword ? "密码保护导出" : "明文导出") : "解锁并预演") {
                    onSubmit(usePassword || !action.isExport ? .password(password) : .legacy)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action.isExport ? (usePassword && (password != confirmation || !passwordIsValid)) : !passwordIsValid)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

private struct SettingsPersistenceErrorBanner: View {
    @Environment(\.themeTokens) private var theme
    let error: SettingsPersistenceError
    let onDismiss: () -> Void

    private var message: String {
        switch error {
        case .encodingFailed:
            return "设置保存失败，当前设置未改变；请重试。"
        case .directoryCreationFailed:
            return "设置保存失败，无法创建设置目录；请检查磁盘权限后重试。"
        case .writeFailed:
            return "设置保存失败，当前设置未改变；请检查磁盘权限后重试。"
        case .transactionReopenRequired:
            return "导入已完成，请重新打开应用后继续修改设置。"
        case .transactionRecoveryRequired:
            return "数据恢复尚未完成，请重新打开应用处理恢复。"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            MinisIconView(.warning, size: 14, accessibilityLabel: "设置保存错误")
                .foregroundPalette(theme?.statusWarning ?? AppStatusColor.warning)
            Text(message)
                .accessibilityIdentifier("settings.persistence.error.message")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭提示", action: onDismiss)
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭设置保存错误提示")
                .accessibilityIdentifier("settings.persistence.error.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((theme?.statusWarning ?? AppStatusColor.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.persistence.error")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 设置中心 UI（D5）
//
// macOS 设置窗口：项目 Keyline 侧栏 + 右侧设置内容。
// 全部绑定 SettingsCenter（D1 SettingsStore 数据层 + C1a/C1c/C2b Store 接线）。
// 设置能力与风格参照 OpenMinis 手机端；页面和设置消费由本工程组织。

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "常规"
    case safety = "安全"
    case permissions = "权限"
    case projects = "项目"
    case typography = "排版"
    case shortcuts = "快捷键"
    case agent = "Agent"
    case mcp = "MCP"
    case skills = "技能"
    case scheduler = "定时任务"
    case usage = "用量"
    case privacy = "隐私"
    case storage = "存储"
    case browser = "浏览器"
    case memory = "记忆"
    case environment = "环境变量"
    case logs = "日志"
    case about = "关于"

    var id: String { rawValue }

    var displayTitle: String { self == .environment ? "模型" : self == .agent ? "智能体运行" : rawValue }

    var icon: MinisIcon {
        switch self {
        case .general: return .settings
        case .safety: return .lock
        case .permissions: return .handOpen // 审批/授权，与“安全”的锁区分
        case .privacy: return .eyeOff
        case .typography: return .edit
        case .shortcuts: return .command
        case .agent: return .user
        case .mcp: return .server
        case .skills: return .library
        case .memory: return .archive
        case .projects: return .folder
        case .scheduler: return .schedule
        case .usage: return .analytics
        case .storage: return .database
        case .browser: return .globe
        case .environment: return .terminal
        case .logs: return .document
        case .about: return .info
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .general: return "settings-tab-general"
        case .safety: return "settings-tab-safety"
        case .permissions: return "settings-tab-permissions"
        case .projects: return "settings-tab-projects"
        case .typography: return "settings-tab-typography"
        case .shortcuts: return "settings-tab-shortcuts"
        case .agent: return "settings-tab-agent"
        case .mcp: return "settings-tab-mcp"
        case .skills: return "settings-tab-skills"
        case .scheduler: return "settings-tab-scheduler"
        case .usage: return "settings-tab-usage"
        case .privacy: return "settings-tab-privacy"
        case .storage: return "settings-tab-storage"
        case .browser: return "settings-tab-browser"
        case .memory: return "settings-tab-memory"
        case .environment: return "settings-tab-environment"
        case .logs: return "settings-tab-logs"
        case .about: return "settings-tab-about"
        }
    }
}

private struct SettingsNavigationGroup: Identifiable {
    let id: String
    let pages: [SettingsPage]

    static let all: [Self] = [
        .init(id: "通用与外观", pages: [.general, .typography, .shortcuts]),
        .init(id: "模型与 API", pages: [.environment]),
        .init(id: "权限与安全", pages: [.safety, .permissions, .agent, .privacy]),
        .init(id: "工具", pages: [.mcp, .skills, .browser]),
        .init(id: "自动化", pages: [.scheduler, .projects]),
        .init(id: "数据", pages: [.memory, .storage, .usage, .logs]),
        .init(id: "关于", pages: [.about]),
    ]
}

struct SettingsSearchResult: Identifiable {
    let group: String
    let page: SettingsPage
    let title: String
    var anchor: String? = nil
    var keywords: String = ""
    var id: String { anchor ?? page.accessibilityIdentifier }

    static let fontSizeAnchor = "settings-navigation-font-size"
    static let hooksAnchor = "settings-navigation-hooks"

    private static let pageKeywords: [SettingsPage: String] = [
        .general: "语言 外观 主题 默认模型 通知 审批通知 任务完成通知 后台任务完成后自动继续 自动续跑 文件检查点 回答风格 打断并发送", .typography: "字号 字体 排版",
        .shortcuts: "快捷键 键盘 按键", .environment: "API Key 服务商 密钥 模型",
        .safety: "安全模式 紧急停止 保护", .permissions: "权限 授权 审批 已允许 持久审批规则 规则管理 拒绝 每次询问 导入 撤销",
        .agent: "绕过 上限 预算 循环 循环上限 运行安全上限 允许访问的网站 工具审批 已允许 审批等待超时 超时自动拒绝 审批提示条 弹窗", .privacy: "隐私 日志级别 数据保护",
        .mcp: "MCP 工具 服务器", .skills: "技能 插件 能力", .browser: "浏览器 页面 网页 联网搜索 web_search Brave Tavily SearXNG 用户代理",
        .scheduler: "定时任务 自动化 运行记录", .projects: "项目 工作区 工作目录",
        .memory: "记忆 事实 搜索", .storage: "备份 删除 回收站 恢复",
        .usage: "用量 消耗 统计", .logs: "日志 诊断 清空", .about: "关于 版本 应用",
    ]

    static var entries: [Self] {
        SettingsNavigationGroup.all.flatMap { group in
            group.pages.map { Self(group: group.id, page: $0, title: $0.displayTitle, keywords: pageKeywords[$0] ?? "") }
        } + [
            .init(group: "通用与外观", page: .typography, title: "文字大小",
                  anchor: fontSizeAnchor, keywords: "字号 字体 font size"),
            .init(group: "自动化", page: .agent, title: "Hooks",
                  anchor: hooksAnchor, keywords: "钩子 hook"),
        ]
    }

    static func matches(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { result in
            let searchable = [result.group, result.title, result.keywords].joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains(String($0)) }
        }
    }
}

/// Layout contract for the settings surface. The sidebar remains readable at
/// the supported compact width while yielding space to the actual settings
/// consumer; larger windows retain the project Keyline proportions.
enum SettingsLayoutPolicy {
    static let minimumSupportedWidth: CGFloat = 600
    static let compactSidebarWidth: CGFloat = 168
    static let preferredSidebarWidth: CGFloat = 220

    static func sidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else {
            return preferredSidebarWidth
        }
        return min(
            preferredSidebarWidth,
            max(compactSidebarWidth, availableWidth * 0.28)
        )
    }
}

/// Width policy for the settings surface.  The window remains usable at the
/// smallest supported width while preserving generous Keyline breathing room
/// on wide displays; the policy is pure so the same thresholds can be checked
/// by direct consumer tests without launching AppKit.
enum SettingsResponsiveWidthClass: String, Equatable, Sendable {
    case compact
    case medium
    case regular
    case wide
}

struct SettingsLayoutMetrics: Equatable, Sendable {
    let widthClass: SettingsResponsiveWidthClass
    let sidebarWidth: CGFloat
    let contentGutter: CGFloat
    let showsSidebarLabels: Bool

    /// Environment/provider rows keep their existing controls and change only
    /// their arrangement at the compact boundary.  The decision is derived
    /// from the same width metrics used by the settings shell.
    var environmentRowLayout: SettingsEnvironmentRowLayout {
        widthClass == .compact ? .stacked : .inline
    }

    /// Long provider/env values get one extra readable line when the row is
    /// stacked.  Secret values remain represented by their existing safe
    /// Keychain reference label.
    var environmentValueLineLimit: Int {
        environmentRowLayout == .stacked ? 2 : 1
    }

    /// The same independent action-column budget is used by both row kinds.
    var environmentActionColumnWidth: CGFloat {
        widthClass == .compact ? 200 : 220
    }

    var adaptiveWidthClass: AdaptiveWidthClass {
        switch widthClass {
        case .compact: return .compact
        case .medium: return .medium
        case .regular: return .regular
        case .wide: return .wide
        }
    }

    static func forWidth(_ width: CGFloat) -> SettingsLayoutMetrics {
        switch AdaptiveLayoutPolicy.widthClass(for: width) {
        case .compact:
            return SettingsLayoutMetrics(
                widthClass: .compact,
                sidebarWidth: 168,
                contentGutter: 12,
                showsSidebarLabels: true
            )
        case .medium:
            return SettingsLayoutMetrics(
                widthClass: .medium,
                sidebarWidth: 196,
                contentGutter: 16,
                showsSidebarLabels: true
            )
        case .regular:
            return SettingsLayoutMetrics(
                widthClass: .regular,
                sidebarWidth: 220,
                contentGutter: 20,
                showsSidebarLabels: true
            )
        case .wide:
            return SettingsLayoutMetrics(
                widthClass: .wide,
                sidebarWidth: 248,
                contentGutter: 28,
                showsSidebarLabels: true
            )
        }
    }
}

/// Identity and public badges share a row only while their full intrinsic
/// widths fit. At a narrow width the name wraps above intact single-line badges.
/// This is used by both Provider and ordinary environment-variable rows.
struct SettingsEnvironmentIdentityHeader<Badges: View>: View {
    let name: String
    let nameFont: Font
    private let badges: Badges

    init(name: String, nameFont: Font, @ViewBuilder badges: () -> Badges) {
        self.name = name
        self.nameFont = nameFont
        self.badges = badges()
    }

    private var nameLabel: some View {
        Text(name)
            .font(nameFont)
            .fontWeight(.medium)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .help(name)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                nameLabel
                badges
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                nameLabel
                badges
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsEnvironmentRowLayout: String, Equatable, Sendable {
    case inline
    case stacked
}

struct SettingsView: View {
    nonisolated static let approvalPolicyFootnoteIdentifier = "settings.agent.approval-policy.footnote"
    nonisolated static let approvalPolicyFootnote = "自动模式下，权限模式先决定文件编辑与命令行是否需要审批。此选项决定其它工具是每次询问，还是只问高风险；在授权目录里读文件、搜索不需要审批，敏感文件除外。"
    nonisolated static let toolsDisabledHelp = "开启后拒绝所有工具调用。关闭后恢复为每次询问。"

    @Bindable var center: SettingsCenter
    /// AJ-57：快捷键设置（与 ContentView 共享同一实例，改即生效）。
    @Bindable var shortcutStore: ShortcutStore
    /// 波4：技能管理（设置「技能」分区数据源，扫描 + 启用/禁用 + 详情）。
    @Bindable var skillsStore: SkillsStore
    /// 波4：定时任务管理（设置「定时任务」分区数据源，CRUD + cron 校验 + 启用开关）。
    @Bindable var schedulerStore: SchedulerTaskStore
    var schedulerRuntime: SchedulerTaskRuntime? = nil
    var initialPageID: String? = nil
    var chatStore: ChatStore? = nil
    var approvalCenter: ApprovalPromptCenter? = nil

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    /// AJ-61：sheet 呈现后「关闭设置」右键项用（非 sheet 场景为 no-op）。
    @Environment(\.dismiss) private var dismiss
    @State private var dismissedPersistenceError: SettingsPersistenceError?
    @State private var selectedPage: SettingsPage = .general
    @State private var settingsSearch = ""
    @State private var settingsSearchAnchor: String?
    private var isSearchingSettings: Bool {
        !settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }


    /// Focused field instrumentation seam for NSHosting/AppKit measurement.
    @MainActor
    internal func typographyInstrumentationView() -> AnyView {
        AnyView(TypographySettingsTab(center: center))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = SettingsLayoutMetrics.forWidth(geometry.size.width)
            VStack(spacing: 0) {
                if let error = center.lastPersistenceError
                    ?? (center.settingsStore.lastPersistenceError == .transactionRecoveryRequired
                        ? .transactionRecoveryRequired : nil),
                   dismissedPersistenceError != error {
                    SettingsPersistenceErrorBanner(error: error) {
                        dismissedPersistenceError = error
                    }
                }
                SettingsAppliedStateBanner(
                    projection: center.settingsAppliedStateProjection
                )
                if center.legacyApprovalPolicyNoticePending || center.legacyApprovalScopeNoticePending {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            if center.legacyApprovalPolicyNoticePending {
                                Text(center.legacyAutomaticApprovalCompatibilityActive
                                     ? "普通高风险操作已收紧；原自动执行的定时/项目任务暂按原方式运行，你改一次审批设置后统一按新设置。"
                                     : "原工具审批策略为「自动批准」。普通高风险操作已收紧，定时与项目任务也按当前审批设置执行。")
                            }
                            if center.legacyApprovalScopeNoticePending {
                                Text("原默认审批范围已保留。新请求按「仅这次」处理。")
                            }
                        }
                        Spacer()
                        Button("知道了") { center.acknowledgeLegacyApprovalNotices() }
                    }
                    .padding(12)
                    .accessibilityIdentifier("settings.approval-migration.notice")
                }

                HStack(spacing: 0) {
                    settingsSidebar(metrics: metrics)
                    Divider()
                    settingsPage(title: isSearchingSettings ? "搜索设置" : selectedPage.displayTitle, metrics: metrics) {
                        if isSearchingSettings {
                            settingsSearchResults()
                        } else {
                            ScrollViewReader { reader in
                                settingsContent(for: selectedPage, metrics: metrics)
                                    .task(id: settingsSearchAnchor) {
                                        guard let anchor = settingsSearchAnchor else { return }
                                        reader.scrollTo(anchor, anchor: .top)
                                        settingsSearchAnchor = nil
                                    }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // R29-E4（settings-residual-043 最小修复候选，单变量对照 E3 吞并实测）：
            // 容器级 identifier 此前直接挂在布局容器上，SwiftUI 把它下传继承给容器内
            // 每个可访问性叶子——两个失败用例的本地/公共双通道均只读到
            // settings.surface（diag-D11/D12 原行），叶子自身
            // settings.reset.defaults / settings.logs.clear 从未投射。现改为显式聚合
            // 元素承载标识符：identifier 只属于该聚合元素本身，叶子保留各自标识符，
            // settings.surface 的 readiness 轮询与源码扫描契约均不受影响。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.surface")
        }
        .font(typography?.body ?? .body)
        .frame(minWidth: SettingsLayoutPolicy.minimumSupportedWidth, minHeight: 460)
        // A7-A 只约束布局；设置侧栏保留项目 Keyline/MinisIcon 视觉权威。
        // 自有侧栏让双色位图处于确定 16pt 画布，避开 TabView 标签宿主的模板化/拉伸。
        // AJ-38/E13：强调色跟随主题色选择（accentTheme 默认伪仙赭橙，选其它主题即切换）。
        .tint(center.effectiveThemeAccentColor)
        .onChange(of: center.lastPersistenceError) { _, error in
            if error == nil {
                dismissedPersistenceError = nil
            }
        }
        // Reopen is a real reload boundary: external provider/env updates and
        // readiness metadata must be reflected before the user edits again.
        // 设置已经打开时再收到"打开某页"的请求（例如对话里说"忘掉…"），也切过去。
        .onChange(of: initialPageID) { _, pageID in
            guard let pageID else { return }
            if pageID == ProviderConnectionRoute.id {
                selectedPage = .environment
            } else if let page = SettingsPage(rawValue: pageID)
                        ?? SettingsPage.allCases.first(where: { $0.accessibilityIdentifier == pageID }) {
                selectedPage = page
            }
        }
        .onAppear {
            center.reloadAll()
            if initialPageID == ProviderConnectionRoute.id {
                selectedPage = .environment
            } else if let pageID = initialPageID,
                      let page = SettingsPage(rawValue: pageID)
                        ?? SettingsPage.allCases.first(where: { $0.accessibilityIdentifier == pageID }) {
                selectedPage = page
            }
            dismissedPersistenceError = nil
        }
        // AJ-61：设置内容区右键挂点（浮动菜单：复制路径 / 刷新 / 关于 / 关闭设置）。
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present(settingsContextMenuItems(), at: windowPoint)
        })
        // 浮动菜单渲染层：sheet 内自挂一份 —— 主窗口 overlay 被 sheet 窗口遮挡，
        // 菜单必须在本 sheet 窗口内呈现（macOS sheet 模态，右键只可能落在 sheet 内）。
        .overlay { FloatingMenuOverlay() }
    }

    private func settingsSidebar(metrics: SettingsLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(typography?.headline ?? .headline)
                .accessibilityIdentifier("settings.sidebar.title")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            TextField("搜索设置", text: $settingsSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索设置")
                .accessibilityIdentifier("settings.navigation.search")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            // 原生 AX 曝光契约（A7-A）：导航条目是破坏性动作入口的可达前提。
            // 懒物化堆栈只按滚动视口节奏建行，视口外的页签（如「日志」）在可访问性
            // 树里根本不存在，清空日志的权威入口就永远无法被键盘/VoiceOver/验收侧到达。
            // 固定页签全部常驻物化的成本可忽略，这里不使用任何懒物化容器。
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsNavigationGroup.all) { group in
                        Text(group.id)
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.pages) { page in
                            settingsNavigationButton(page, metrics: metrics)
                        }
                        if group.pages.contains(.scheduler) {
                            Button("Hooks") {
                                selectedPage = .agent
                                settingsSearchAnchor = SettingsSearchResult.hooksAnchor
                                settingsSearch = ""
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("settings.navigation.hooks")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: metrics.sidebarWidth)
        .background(
            theme?.aj38.backgroundSecondary.swiftUIColor
                ?? Color(nsColor: .controlBackgroundColor)
        )
    }

    private func settingsNavigationButton(_ page: SettingsPage, metrics: SettingsLayoutMetrics) -> some View {
        let isSelected = selectedPage == page
        return Button {
            selectedPage = page
            settingsSearch = ""
            settingsSearchAnchor = nil
        } label: {
            HStack(spacing: 10) {
                MinisIconView(
                    page.icon,
                    state: isSelected ? .active : .normal,
                    size: 16,
                    accessibilityLabel: page.displayTitle
                )
                .accessibilityHidden(true)

                if metrics.showsSidebarLabels {
                    Text(page.displayTitle)
                        .font(typography?.sidebarItem ?? .body)
                        .foregroundStyle(Color.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? MinisIconTokens.keylineOrangeA7A.opacity(0.12)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(page.displayTitle)设置")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(page.accessibilityIdentifier)
    }

    private func settingsSearchResults() -> some View {
        let results = SettingsSearchResult.matches(settingsSearch)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if results.isEmpty {
                    Text("没有匹配的设置")
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { result in
                    Button {
                        selectedPage = result.page
                        settingsSearchAnchor = result.anchor
                        settingsSearch = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title)
                            Text(result.group)
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.navigation.result.\(result.id)")
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("settings.navigation.results")
    }

    @ViewBuilder
    private func settingsContent(
        for page: SettingsPage,
        metrics: SettingsLayoutMetrics
    ) -> some View {
        switch page {
        case .general:
            GeneralSettingsTab(center: center)
        case .safety:
            SafetyRuntimeSettingsTab(center: center)
        case .permissions, .projects:
            PermissionScopeSettingsTab(approvalCenter: approvalCenter, chat: chatStore)
        case .typography:
            TypographySettingsTab(center: center)
        case .shortcuts:
            KeyboardShortcutsSettingsTab(store: shortcutStore)
        case .agent:
            AgentSettingsTab(center: center, approvalCenter: approvalCenter)
        case .mcp:
            MCPSettingsTab(center: center, widthClass: metrics.adaptiveWidthClass)
        case .skills:
            SkillsSettingsTab(store: skillsStore, chat: chatStore)
        case .scheduler:
            SchedulerSettingsTab(store: schedulerStore, runtime: schedulerRuntime)
        case .usage:
            UsageSettingsTab(center: center, chatStore: chatStore)
        case .privacy:
            PrivacySettingsTab(center: center)
        case .storage:
            StorageSettingsTab(center: center, chatStore: chatStore)
        case .browser:
            BrowserSettingsTab(center: center)
        case .memory:
            MemorySettingsTab(center: center, schedulerStore: schedulerStore, chatStore: chatStore)
        case .environment:
            EnvironmentSettingsTab(center: center, metrics: metrics,
                                   opensProviderConnection: initialPageID == ProviderConnectionRoute.id)
        case .logs:
            LogsSettingsTab(center: center)
        case .about:
            AboutSettingsTab(center: center)
        }
    }

    /// 标题和关闭入口属于右侧页面内容，不能用覆盖整个设置容器的 safe-area header，
    /// 否则会压住左侧 sidebar 的标题和第一行导航。
    private func settingsPage<Content: View>(
        title: String,
        metrics: SettingsLayoutMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(typography?.headline ?? .headline)
                    .accessibilityIdentifier("settings.title")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Label { Text("关闭") } icon: { MinisIconView(.close, size: 14) }
                }
                .keyboardShortcut(.cancelAction)
                .escapeShortcut(closePopover: FloatingMenuHost.shared.escapeDismissalAction(),
                                closeSheet: { dismiss(); return true })
                .accessibilityLabel("关闭设置")
                .accessibilityHint("关闭设置面板")
                .accessibilityIdentifier("settings.close")
                .help("关闭设置面板")
            }
            .padding(.horizontal, metrics.contentGutter)
            .padding(.vertical, 10)
            Divider()
            content()
                .padding(.horizontal, metrics.contentGutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// AJ-61：设置内容区右键菜单项。
    private func settingsContextMenuItems() -> [FloatingMenuItem] {
        let settingsFile = center.settingsDirectory.appendingPathComponent("settings.json").path
        return [
            FloatingMenuItem(kind: .button(title: "复制设置文件路径", icon: "doc.on.clipboard", role: nil, help: "复制 settings.json 完整路径到剪贴板") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(settingsFile, forType: .string)
            }, catalogIcon: .copy),
            FloatingMenuItem(kind: .button(title: "复制日志文件路径", icon: "doc.on.clipboard", role: nil, help: "复制日志文件完整路径到剪贴板") {
                if let logURL = center.logManager.logFileURL() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logURL.path, forType: .string)
                }
            }, catalogIcon: .copy),
            FloatingMenuItem(kind: .button(title: "在 Finder 中显示日志", icon: "folder", role: nil, help: "在 Finder 中定位当前日志文件") {
                if let logURL = center.logManager.logFileURL() {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            }, catalogIcon: .folder),
            FloatingMenuItem(kind: .divider),
            FloatingMenuItem(kind: .button(title: "刷新设置", icon: "arrow.clockwise", role: nil, help: "重新加载环境变量 / 日志 / 存储 / MCP") {
                center.reloadAll()
            }, catalogIcon: .refresh),
            FloatingMenuItem(kind: .button(title: "关于 MinisCanvas", icon: "info.circle", role: nil, help: "打开系统「关于」面板") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }, catalogIcon: .info),
            FloatingMenuItem(kind: .button(title: "关闭设置", icon: "xmark.circle", role: nil, help: "关闭设置面板") {
                dismiss()
            }, catalogIcon: .close),
        ]
    }
}

private struct SettingsAppliedStateBanner: View {
    let projection: SettingsAppliedStateProjection
    private let message = "部分设置在下一次运行时生效"

    @Environment(\.typographyTokens) private var typography

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MinisIconView(
                projection.state == .liveApplied ? .success : .refresh,
                size: 16
            )
            .accessibilityHidden(true)
            Text(message)
                .font(typography?.caption ?? .caption)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("设置应用状态")
        .accessibilityValue(message)
        .accessibilityIdentifier("settings.applied-state")
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Safe Mode / Kill Switch（P3-SAFE-01 / P3-SET-01 / P3-REC-01）

private struct SafetyRuntimeSettingsTab: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var center: SettingsCenter

    var body: some View {
        let safetyFlags: [SafetyFeatureFlag] = Array(center.safetyFeatureFlags)
        Form {
            Section("运行安全") {
                Toggle(
                    "安全模式",
                    isOn: Binding(
                        get: { center.safeModeEnabled },
                        set: { center.safeModeEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("settings.safety.safe-mode")

                Text("关闭 Canvas、MCP、外部 Agent 和其他可选副作用；Chat、备份、恢复保持可用。").font(.caption).foregroundStyle(.secondary)

                Toggle("停用所有工具", isOn: Binding(
                    get: { center.toolsDisabled },
                    set: { center.toolsDisabled = $0 }
                ))
                    .accessibilityIdentifier("settings.safety.tools-disabled")

                Text(SettingsView.toolsDisabledHelp).font(.caption).foregroundStyle(.secondary)

                Toggle(
                    "紧急停止",
                    isOn: Binding(
                        get: { center.killSwitchEnabled },
                        set: { center.killSwitchEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("settings.safety.kill-switch")

                Text("离线立即关闭可选模块，并请求活动任务取消与还原点。").font(.caption).foregroundStyle(.secondary)
            }

            Section("安全状态") {
                safetyRow("作用范围", center.safetyRuntimeSnapshot.scope)
                safetyRow("默认值", center.safetyRuntimeSnapshot.resetDescription)
                safetyRow("有效状态", center.safetyRuntimeSnapshot.effectiveState)
                safetyRow("生效来源", center.safetyRuntimeSnapshot.source)

                Button("恢复安全默认值") {
                    center.restoreSafetyControlDefaults()
                }
                .accessibilityIdentifier("settings.safety.reset")
            }

            Section("能力状态（只读）") {
                ForEach(
                    safetyFlags,
                    id: \SafetyFeatureFlag.key
                ) { (flag: SafetyFeatureFlag) in
                    let stateMeaning = flag.isForced
                        ? "核心能力，始终保持开启"
                        : flag.isEnabled
                            ? "当前可用；开启 安全模式或紧急停止 后会停止"
                            : "当前已由 安全模式或紧急停止 关闭"
                    let controlMeaning = flag.isForced
                        ? "强制保留，只读"
                        : "只读，由 安全模式与紧急停止统一控制"
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(flag.feature.displayName)
                            Spacer()
                            Text(flag.isEnabled ? "开启" : "关闭")
                                .foregroundStyle(flag.isEnabled ? Color.secondary : (theme?.statusWarningText ?? AppStatusColor.warning))
                        }
                        safetyRow(
                            "默认 / 当前",
                            "\(flag.defaultEnabled ? "开启" : "关闭") / \(flag.isEnabled ? "开启" : "关闭")"
                        )
                        safetyRow("作用", flag.feature.safetyMeaning)
                        safetyRow("当前安全含义", stateMeaning)
                        safetyRow("控制方式", controlMeaning)
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(flag.feature.displayName)
                    .accessibilityValue("\(flag.isEnabled ? "开启" : "关闭")；默认 / 当前 \(flag.defaultEnabled ? "开启" : "关闭") / \(flag.isEnabled ? "开启" : "关闭")；作用 \(flag.feature.safetyMeaning)；当前安全含义 \(stateMeaning)；控制方式 \(controlMeaning)")
                    .accessibilityIdentifier("settings.safety.feature.\(flag.key)")
                }
            }
            .accessibilityElement(children: .contain)
        }
        .formStyle(.grouped)
    }

    private func safetyRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 常规（General）

/// P3-UI-02（N-UI02-WIRE）：主题预设选择器的目录闸。
///
/// 外观轴预设（浅色/深色/跟随系统/高对比）在设置页可见的前提，是版本化主题
/// 预设目录（MinisCore `ThemePresetCatalog`，BATCH1 unit 10 落头）确有
/// 「亮侧已批准且已具色」的预设条目：候选集以
/// `ThemePresetCatalog.selectableIDs`（仅 `.acceptedForLight`）为入口，
/// 逐条经 `entry(for:).accent(for: .light)` 核实存在批准色材料。
/// 当前唯一合格条目是 keylineOrangeA7A（与 MinisIconTokens 定版字面量
/// 字节同源，见目录注释），因此本闸放行 `ThemePreset.selectable`，
/// 选择器沿同一目录闸消费已具完整token的预设集合。
/// 失败关闭：目录批准亮侧集合为空（例如未来撤权）→ 输出空候选，
/// 不回落到旧列表。warmCoralA7A（pendingColorMaterial、无材料不造色）仍排除。
/// 20261004T1115：仅产品主题与跟随系统原生可选，旧高对比只用于迁移；
/// dark/System 目录强调色的裁决字段仍 pending，本闸不发明豁免。
enum ThemePresetCatalogPickerGate {
    static var selectableThemePresets: [ThemePreset] {
        let hasApprovedLightAccentMaterial = ThemePresetCatalog.selectableIDs.contains { id in
            ThemePresetCatalog.entry(for: id)?.accent(for: .light) != nil
        }
        guard hasApprovedLightAccentMaterial else { return [] }
        return ThemePreset.selectable
    }
}

private struct GeneralSettingsTab: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var center: SettingsCenter
    @State private var showingResetDefaultsConfirmation = false
    @Environment(\.typographyTokens) private var typography

    private var languageBinding: Binding<String> {
        Binding(
            get: { center.language },
            set: { center.language = $0 }
        )
    }

    var body: some View {
        Form {
            if let notifications = center.systemNotifications {
                SystemNotificationSettingsSection(controller: notifications)
            }
            Section("外观") {
                // SETTINGS-27 / THEME-01：收敛为单一「主题预设」选择器。
                // 此前这里是 `Picker("外观模式")` × `Picker("主题色")` 两个
                // 独立轴，用户可存下 3×6=18 种从未整体验收过的组合。
                // 布局沿用同一 Section / .menu 选择器语言，未新增视觉层级。
                // 列出已具备 token 的预设（含高对比）；完整包验仍由四预设矩阵验证。
                // P3-UI-02（N-UI02-WIRE）：候选集经
                // `ThemePresetCatalogPickerGate` 接版本化目录的亮侧已批准
                // 集合（目录无批准具色条目 → 空候选，失败关闭）。
                Picker("主题预设", selection: Binding(
                    get: { center.themePreset },
                    set: { center.themePreset = $0 }
                )) {
                    ForEach(ThemePresetCatalogPickerGate.selectableThemePresets, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("主题预设")
                .accessibilityIdentifier("settings.general.theme-preset")

                Picker("明暗", selection: Binding(
                    get: { center.appearance },
                    set: { center.appearance = $0 }
                )) {
                    Text("浅色").tag(Appearance.light)
                    Text("深色").tag(Appearance.dark)
                    Text("跟随系统").tag(Appearance.system)
                }
                .pickerStyle(.menu)
                .accessibilityLabel("明暗")
                .accessibilityIdentifier("settings.general.appearance-mode")

                // 旧调色板（codex/graphite/ocean/crimson/emerald）与高对比
                // 若将来拿到批准色板，需要 C0 另开预设验收；此处不得
                // 恢复成第二个自由轴，也不新增可见行（A7-A 布局保持）。
            }

            Section("默认模型") {
                // 默认模型候选 = 内置聊天 Provider + 用户自定义供应商记录（U5）。
                // 此前只列内置 ProviderType → 自定义供应商「只能加 key、模型选不了」；
                // 合并后自定义供应商同样可设为默认 Provider / 默认模型。
                let allProviderOptions = center.providers.map { ChatStore.ChatProvider.builtIn($0) }
                    + center.providerRecords.map { ChatStore.ChatProvider.custom($0) }
                // 默认模型只列“检查通过、可用于对话”的：选了没通过的模型会静默不生效。
                let readyKeys = Set(center.chatModelPickerProjection.items.filter(\.isSelectable).map {
                    ProviderReadinessRevision.canonicalProviderID($0.providerID) + "\u{1F}" + $0.modelID
                })
                let readinessKey: (ChatStore.ChatProvider, String) -> String = { option, modelID in
                    let name: String
                    switch option {
                    case .builtIn(let t): name = t.rawValue
                    case .custom(let r): name = r.name
                    }
                    return ProviderReadinessRevision.canonicalProviderID(name) + "\u{1F}" + ChatStore.canonicalModelID(modelID)
                }
                let providerOptions = allProviderOptions.filter { option in
                    let tag: String
                    switch option {
                    case .builtIn(let t): tag = t.rawValue
                    case .custom(let r): tag = "custom.\(r.name)"
                    }
                    return tag == center.defaultProviderID
                        || option.modelOptions.contains { readyKeys.contains(readinessKey(option, $0.id)) }
                }
                // 持久化 tag：内置 = rawValue（与旧配置兼容）；自定义 = "custom.<name>"
                let providerTag: (ChatStore.ChatProvider) -> String = { option in
                    switch option {
                    case .builtIn(let t): return t.rawValue
                    case .custom(let r): return "custom.\(r.name)"
                    }
                }
                Picker("模型服务商", selection: Binding(
                    get: { center.defaultProviderID },
                    set: { center.defaultProviderID = $0 }
                )) {
                    Text("未选择").tag(String?.none)
                    ForEach(providerOptions, id: \.id) { option in
                        Text(option.displayName).tag(String?.some(providerTag(option)))
                    }
                }
                .pickerStyle(.menu)

                // 模型目录随选中 Provider 取：内置 = builtInModels；自定义 = record.modelNames
                let models: [LLMModel] = {
                    guard let pid = center.defaultProviderID,
                          let option = providerOptions.first(where: { providerTag($0) == pid }) else { return [] }
                    return option.modelOptions.filter {
                        readyKeys.contains(readinessKey(option, $0.id)) || $0.id == center.defaultModelID
                    }
                }()
                // 已保存的默认模型没有通过检查：给出提示，说明它不会生效。
                let defaultModelNotEffective: Bool = {
                    guard let pid = center.defaultProviderID, let mid = center.defaultModelID,
                          let option = providerOptions.first(where: { providerTag($0) == pid }) else { return false }
                    return !readyKeys.contains(readinessKey(option, mid))
                }()
                Picker("模型", selection: Binding(
                    get: { center.defaultModelID },
                    set: { center.defaultModelID = $0 }
                )) {
                    Text("未选择").tag(String?.none)
                    ForEach(models, id: \.id) { model in
                        Text(model.displayName).tag(String?.some(model.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(models.isEmpty)
                .help(models.isEmpty ? "请先选择服务商" : "默认模型")
                if defaultModelNotEffective {
                    Text("当前默认模型尚未通过连接检查，新会话不会使用它。请先到「模型服务」检查连接，或改选已通过检查的模型。")
                        .font(.caption)
                        .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                }

                // AJ-40：辅助模型 —— 轻量任务（标题生成/摘要等）的默认模型，未选继承主模型。
                Picker("辅助模型", selection: Binding(
                    get: { center.subModelID },
                    set: { center.subModelID = $0 }
                )) {
                    Text("继承主模型").tag(String?.none)
                    ForEach(models, id: \.id) { model in
                        Text(model.displayName).tag(String?.some(model.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(models.isEmpty)
                .help(models.isEmpty ? "请先选择服务商" : "辅助模型目前只用于画布里的轻量任务，对话的标题生成和摘要不使用它；未选则继承主模型。")
            }

            Section("语言") {
                Picker("语言", selection: languageBinding) {
                    ForEach(SettingsCenter.languageOptions, id: \.code) { option in
                        Text(option.display).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                Text("此语言设置仅用于语音识别与朗读，不会切换界面语言。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // E19 / AJ-52：行为 —— 模型速度档位 + 对话输出模式（数据层已就绪，补 UI）。
            Section("行为") {
                Picker("模型速度档位", selection: Binding(
                    get: { center.modelSpeedTier },
                    set: { center.modelSpeedTier = $0 }
                )) {
                    ForEach(ModelSpeedTier.allCases, id: \.self) { tier in
                        Label {
                            Text(ModelSpeedTierPresentation.label(for: tier))
                        } icon: {
                            ModelSpeedTierPresentation(tier)
                                .iconView(selected: center.modelSpeedTier == tier, size: 14)
                        }
                        .tag(tier)
                    }
                }
                .pickerStyle(.menu)
                .help("速度档位用来在模型列表里挑选对应档位的模型（极快 / 快 / 均衡 / 质量），不会改变发给服务商的请求参数。")

                Picker("回答风格", selection: Binding(
                    get: { center.chatOutputMode },
                    set: { center.chatOutputMode = $0 }
                )) {
                    Text("默认").tag(ChatOutputMode.normal)
                    ForEach(ChatOutputMode.presets, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("回答风格：简洁 / 详细 / 讲解；默认保持原回答行为")

                // Goal18：默认排队，仍保留用户显式选择的打断偏好。
                Toggle("保留文件检查点", isOn: Binding(
                    get: { center.fileCheckpointsEnabled },
                    set: { center.fileCheckpointsEnabled = $0 }
                ))
                .help(FileCheckpointStore.scopeDisclosure + "关闭后保留已有记录。")
                Toggle("后台任务完成后自动继续", isOn: Binding(
                    get: { center.backgroundAutoContinueEnabled },
                    set: { center.backgroundAutoContinueEnabled = $0 }
                ))
                .help("后台命令或后台子任务完成后，如果这个会话空闲，自动接着跑一轮。仍遵守当前权限模式和审批；连续自动继续 3 次后停下，等你发话。关闭后，结果只在你下一条消息时带上。")
                Toggle("生成中回车打断并发送（默认排队）", isOn: Binding(
                    get: { center.newMessageInterruptsGeneration },
                    set: { center.newMessageInterruptsGeneration = $0 }
                ))
                .help("关闭：生成中回车加入队列；开启：回车打断并发送。⌘⇧⏎ 始终打断并发送，⌘⏎ 发送；Esc 停止后队列保留，不自动发送。")
            }

            // 波4：人格（Persona）—— 预设一键切换 + 名称/简介/语气/能力编辑。
            Section {
                Toggle("启用对话人格", isOn: Binding(
                    get: { center.personaEnabled },
                    set: { center.personaEnabled = $0 }
                ))

                Picker("预设", selection: Binding(
                    get: { center.personaPreset },
                    set: { center.applyPersonaPreset($0) }
                )) {
                    ForEach(PersonaPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                TextField("姓名", text: personaFieldBinding(\.name))
                TextField("简介", text: personaFieldBinding(\.summary))
                TextField("语气", text: personaFieldBinding(\.tone))
                TextField("能力", text: personaFieldBinding(\.abilities))
            } header: {
                Text("人格")
            } footer: {
                Text("启用后，人格描述会作为系统提示的前缀注入，影响助手的身份、语气与能力。")
            }
        }
        .formStyle(.grouped)
        // 原生 AX 曝光契约（A7-A）：grouped Form 的行由滚动容器按视口节奏物化，
        // 原先「恢复全部默认设置」埋在超长滚动内容的最底部，可访问性树里根本没有
        // 这个触发元素——验收侧因此永远到不了真实的原生确认。破坏性入口必须常驻、
        // 可聚焦、可执行，所以把触发按钮固定在 Form 之外的底部条内；确认仍走同一
        // 原生 confirmationDialog，取消或关闭不写任何字节。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                Button("恢复全部默认设置", role: .destructive) {
                    showingResetDefaultsConfirmation = true
                }
                // AX-EXPOSURE-189（QA 行028 两条 AX 断言 / 043-residual 实测缺口）：
                // 单一元素配方的四行声明块按 SettingsAXExposure189ContractTests
                // 冻结合同原样保留（标题、样式、位置未变）。
                .accessibilityLabel("恢复全部默认设置")
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.reset.defaults")
                // DEV-272-SETAX（R27 实测根因，沿用 lane 190 在
                // SchedulerControlSettingsView.swift 删除入口上收敛并经
                // SchedulerNativeAXExposure190Tests 运行时验证的同一配方）：
                // `.accessibilityElement(children: .ignore)` 生成的聚合元素只承接
                // 它之后声明的属性与动作；lane 189 的声明块把标签留在聚合之前，
                // 且没有把默认动作接到聚合元素上（lane 190 注释原文：该形态实测为
                // 「有 role、无 label、按压空转」，pendingDeletion 永不置位，
                // 确认区从未进入 AX 树）。因此即便探针按
                // settings.reset.defaults 命中本元素，settingsAXPress 也永远打不开
                // 本标签页 safeAreaInset 链尾部的 .confirmationDialog，
                // :146/:168 的
                // settings.reset.defaults.cancel/.confirm 就"从未有机会出现"。
                // 这里在聚合之后补投真实标签，并把显式默认动作接到与 Button 闭包
                // 完全相同的生产入口 showingResetDefaultsConfirmation = true 上——
                // 不是隐藏替身、不是静态 fixture：按压驱动的仍是同一原生确认面、
                // 同一 resetToDefaults 写边界与同一取消不写字节语义。
                .accessibilityLabel("恢复全部默认设置")
                .accessibilityAction { showingResetDefaultsConfirmation = true }
                Text("将清空所有自定义设置并恢复出厂默认值；取消或关闭不会改变当前设置。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog(
            "确认恢复全部默认设置？",
            isPresented: $showingResetDefaultsConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认设置", role: .destructive) {
                center.resetToDefaults()
            }
            .accessibilityIdentifier("settings.reset.defaults.confirm")

            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("settings.reset.defaults.cancel")
        } message: {
            Text("将恢复应用偏好及安全控制默认值，并重新应用相关运行配置；不会删除会话、供应商与凭据、记忆、MCP 配置、日志，也不会重置快捷键。取消或关闭不会改变当前设置。")
        }
    }

    /// 波4：绑定到 `center.persona` 的单个字段（name/summary/tone/abilities）。
    private func personaFieldBinding(_ keyPath: WritableKeyPath<Persona, String>) -> Binding<String> {
        Binding(
            get: { center.persona[keyPath: keyPath] },
            set: { newValue in
                var p = center.persona
                p[keyPath: keyPath] = newValue
                center.persona = p
            }
        )
    }
}

// MARK: - 排版（UX-01）

private struct TypographySettingsTab: View {
    @Bindable var center: SettingsCenter
    @State private var resetToken = 0

    var body: some View {
        let typography = TypographyTokenProvider(center: center)
        let range = TypographySettings.uiBaseFontSizeRange

        Form {
            Section("文字大小") {
                HStack {
                    Text("系统字号")
                    Spacer()
                    Text("\(center.uiBaseFontSize) pt")
                        .font(typography.status)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ValidatedNumericSettingField(
                        "输入字号",
                        value: Binding(
                            get: { center.uiBaseFontSize },
                            set: { center.uiBaseFontSize = $0 }
                        ),
                        in: range,
                        step: TypographySettings.uiBaseFontSizeStep,
                        accessibilityIdentifier: "settings.typography.base-font-size.input",
                        resetToken: resetToken,
                        unit: "pt"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                Text("默认 14 pt；范围 \(range.lowerBound)-\(range.upperBound) pt，步长 \(TypographySettings.uiBaseFontSizeStep)。")
                    .font(typography.status)
                    .foregroundStyle(.secondary)
                Text("正文、输入框、侧栏与任务卡会使用同一排版基准。")
                    .font(typography.status)
                    .foregroundStyle(.secondary)
            }.id(SettingsSearchResult.fontSizeAnchor)

            Section {
                Button("恢复默认 14 pt") {
                    center.resetTypographyToDefaults()
                    resetToken &+= 1
                }
                .accessibilityIdentifier("settings.typography.reset")
            }
        }
        .font(typography.body)
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键（AJ-57）

/// 录制交互模型：点「录制」后挂本地 keyDown 监听，捕获下一次按键并尝试写入 Store；
/// 冲突时返回原因（不写入），Esc 取消。纯逻辑（冲突检测/写入）在 ShortcutStore，可单测。
@MainActor
@Observable
final class ShortcutRecorderModel {
    private let store: ShortcutStore
    /// 正在录制的动作（nil = 未在录制）。
    var recordingAction: ShortcutAction?
    /// 最近一次冲突（alert 呈现）。
    var conflictError: ShortcutConflict?
    private var monitor: Any?
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS || DEBUG
    struct NativeMonitorObservation: Sendable {
        let keyCode: UInt16
        let modifiers: UInt
        let windowNumber: Int
        let timestamp: TimeInterval
        let recordingActionID: String?
        let receiverAlive: Bool
    }
    // Optional test-build observation only; default nil, no production UI/API.
    static var testLocalMonitorObserver: (@MainActor (NativeMonitorObservation) -> Void)? = nil
#endif
// B1213_DIAGNOSTIC_END

    init(store: ShortcutStore) {
        self.store = store
    }

    func beginRecording(_ action: ShortcutAction) {
        cancelRecording()
        conflictError = nil
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
// B1213_DIAGNOSTIC_BEGIN
#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS || DEBUG
            ShortcutRecorderModel.testLocalMonitorObserver?(.init(
                keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue,
                windowNumber: event.windowNumber, timestamp: event.timestamp,
                recordingActionID: self?.recordingAction?.id, receiverAlive: self != nil
            ))
#endif
// B1213_DIAGNOSTIC_END
            self?.handle(event)
            return nil
        }
    }

    func cancelRecording() {
        recordingAction = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    func handle(_ event: NSEvent) {
        // 只有无修饰的 Esc 取消录制；修饰 Esc 与其它合法组合一样交给 Store。
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.keyCode == 53 && event.modifierFlags.intersection(shortcutModifiers).isEmpty {
            cancelRecording()
            return
        }
        guard let action = recordingAction else { return }
        let key = ShortcutBinding.keyName(
            fromKeyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
        let binding = ShortcutBinding(key: key, modifiers: ShortcutModifiers(
            command: event.modifierFlags.contains(.command),
            control: event.modifierFlags.contains(.control),
            option: event.modifierFlags.contains(.option),
            shift: event.modifierFlags.contains(.shift)
        ))
        // 纯修饰键（无 key）或「无修饰的普通字符键」忽略（避免误改输入）。
        if binding.isEmpty || (binding.modifiers == .none && !isSpecialKey(key)
            && action != .approveRequest && action != .rejectRequest) {
            return
        }
        if let conflict = store.setBinding(binding, for: action) {
            conflictError = conflict
        } else {
            conflictError = nil
        }
        cancelRecording()
    }

    private func isSpecialKey(_ key: String) -> Bool {
        ["space", "return", "upArrow", "downArrow", "leftArrow", "rightArrow", "delete", "escape", "tab"].contains(key)
    }
}

/// 设置中心的「快捷键」Tab：搜索 + 分组列表 + 点击录制 + 冲突检测 + 恢复默认。
private struct KeyboardShortcutsSettingsTab: View {
    @Bindable var store: ShortcutStore
    @State private var query = ""
    @State private var recorder: ShortcutRecorderModel

    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    init(store: ShortcutStore) {
        self.store = store
        _recorder = State(initialValue: ShortcutRecorderModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MinisIconView(.search, size: 12)
                    .foregroundPalette(.secondary)
                TextField("搜索快捷键…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.shortcuts.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        MinisIconView(.close, size: 12)
                            .foregroundPalette(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
                }
                Spacer()
                Button("恢复全部默认") {
                    store.resetAll()
                }
                .disabled(isAllDefault)
                .accessibilityIdentifier("settings.shortcuts.restore-all")
            }
            .padding(10)

            Divider()

            List {
                ForEach(ShortcutGroup.allCases) { group in
                    let actions = filteredActions(in: group)
                    if !actions.isEmpty {
                        Section(group.rawValue) {
                            ForEach(actions) { action in
                                row(action)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .alert(item: $recorder.conflictError) { conflict in
            Alert(
                title: Text("快捷键冲突"),
                message: Text(conflict.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .onDisappear {
            recorder.cancelRecording()
        }
    }

    private var isAllDefault: Bool {
        ShortcutAction.allCases.allSatisfy { store.binding(for: $0) == $0.defaultBinding }
    }

    private func filteredActions() -> [ShortcutAction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Canvas runtime remains frozen; keep saved bindings for a future
        // version without advertising unavailable controls in this product.
        let visible = ShortcutAction.allCases.filter { $0.group != .canvas && $0 != .mainPaneCanvas }
        guard !q.isEmpty else { return visible }
        return visible.filter {
            $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    private func filteredActions(in group: ShortcutGroup) -> [ShortcutAction] {
        filteredActions().filter { $0.group == group }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let commands = AppCommandCatalog.shortcutSettingsLabels(for: action)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(commands.slash)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.shortcuts.\(action.id).slash")
                Text(commands.palette)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.shortcuts.\(action.id).palette-command")
                if let reason = action.unavailableReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if recorder.recordingAction == action {
                Text("按下新快捷键…（Esc 取消）")
                    .font(.system(size: 12))
                    .foregroundStyle(theme?.statusWarning ?? .orange)
            } else {
                Text(store.binding(for: action).displayString)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.shortcuts.\(action.id).binding")
            }
            Button(recorder.recordingAction == action ? "取消" : "录制") {
                if recorder.recordingAction == action {
                    recorder.cancelRecording()
                } else {
                    recorder.beginRecording(action)
                }
            }
            .disabled(action.unavailableReason != nil
                      || (recorder.recordingAction != nil && recorder.recordingAction != action))
            .accessibilityIdentifier("settings.shortcuts.\(action.id).record")
            Button("清除") {
                recorder.conflictError = store.setBinding(
                    ShortcutBinding(key: "", modifiers: ShortcutModifiers.none), for: action
                )
            }
            .disabled(action.unavailableReason != nil
                      || store.binding(for: action).isEmpty || recorder.recordingAction != nil)
            .help("清除绑定（停用该快捷键）")
            .accessibilityIdentifier("settings.shortcuts.\(action.id).clear")
            Button {
                recorder.conflictError = store.reset(for: action)
            } label: {
                MinisIconView(.refresh, size: 12)
            }
            .buttonStyle(.borderless)
            .disabled(action.unavailableReason != nil
                      || store.binding(for: action) == action.defaultBinding)
            .help("恢复默认（\(action.defaultBinding.displayString)）")
            .accessibilityLabel("恢复默认（\(action.defaultBinding.displayString)）")
            .accessibilityIdentifier("settings.shortcuts.\(action.id).restore")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Agent

/// A Composer acknowledgement cannot widen the separately persisted runtime
/// ceiling. Keep the two writes independent and verify the settings write
/// before the UI displays the bypass acknowledgement as enabled.
@MainActor
enum Policy05BypassSettingsConfirmation {
    @discardableResult
    static func setConfirmed(_ confirmed: Bool, in center: SettingsCenter) -> Bool {
        if confirmed {
            guard center.composerPolicy.mode == .bypassPermission,
                  center.policyRuntimeDefaults.autonomyLevel == .l3 else { return false }
        }
        var policy = center.composerPolicy
        policy.bypassModeConfirmed = confirmed
        center.composerPolicy = policy
        return center.composerPolicy.bypassModeConfirmed == confirmed
    }
}

private struct PermissionScopeSettingsTab: View {
    var approvalCenter: ApprovalPromptCenter?
    var chat: ChatStore?
    @Environment(\.typographyTokens) private var typography
    @State private var refresh = UUID()
    @State private var feedback: String?

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); feedback = nil }
        catch { feedback = "权限变更未完成，请重新打开当前会话权限后再试。" }
        refresh = UUID()
    }

    var body: some View {
        Form {
            if let center = approvalCenter {
                Section("已授权项目与可访问目录") {
                    ForEach(center.permissionProjects?() ?? [], id: \.id) { project in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ContentSecretRedactor.redact(project.name))
                                Text(ContentSecretRedactor.redact(project.path))
                                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤销项目", role: .destructive) {
                                perform { try center.revokePermissionProject?(project.id) }
                            }
                            .accessibilityIdentifier("permissions.project-revoke-" + project.id)
                        }
                    }
                    ForEach(center.permissionDirectories?() ?? []) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ContentSecretRedactor.redact(row.path)).lineLimit(2)
                                Text(row.scope).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("移除", role: .destructive) {
                                perform { try center.revokePermissionDirectory?(row.id) }
                            }
                            .accessibilityIdentifier("permissions.directory-remove-" + row.id.uuidString)
                        }
                    }
                    HStack {
                        Button("添加本会话目录…") {
                            perform { try center.requestPermissionDirectory?(false) }
                        }.accessibilityIdentifier("permissions.add-session-directory")
                        Button("添加本项目目录…") {
                            perform { try center.requestPermissionDirectory?(true) }
                        }.accessibilityIdentifier("permissions.add-project-directory")
                    }.disabled(center.permissionDirectoryCreationAvailable?() != true)
                    Text("生成中可查看和撤销；新增目录需在生成结束后选择目录并确认授权。撤销仅影响后续工具调用，已开始的操作无法撤回。其他明确批准的独立权限不变。")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
                Section("项目信任文件与哈希") {
                    ForEach(center.projectInstructionTrustRows?() ?? []) { row in
                        VStack(alignment: .leading) {
                            Text(ContentSecretRedactor.redact(row.path))
                            Text(row.hash).font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            if row.refused {
                                Text("已选择不加载（记住）；文件内容变了才会再询问").font(typography?.caption ?? .caption)
                            }
                            Button(row.refused ? "恢复询问" : "撤销此项目的指令信任", role: .destructive) {
                                perform { try center.revokeProjectInstructionTrust?(row.projectID) }
                            }.accessibilityIdentifier("permissions.project-instructions-revoke-" + row.projectID)
                        }
                    }
                    Text("撤销对后续请求生效；已开始请求及其子任务继续使用已确认的冻结快照。目录访问权限保持不变。")
                        .font(typography?.caption ?? .caption)
                }
                Section("当前会话临时文件许可") {
                    if let sessionID = chat?.activeSessionID?.uuidString {
                        ForEach(center.temporaryPermissionRows(sessionID: sessionID)) { row in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(ContentSecretRedactor.redact(row.path)).lineLimit(2)
                                    Text("\(row.tool) · 到期 \(row.expiresAt.formatted(date: .omitted, time: .shortened))")
                                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("撤销") {
                                    center.revokeTemporaryPermission(row.id, sessionID: sessionID)
                                    refresh = UUID()
                                }.accessibilityIdentifier("permissions.temporary-revoke-" + row.id.uuidString)
                            }
                        }
                    }
                    Text("临时许可只对应已确认的单个文件与操作，不等于目录授权。")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
                if let rules = center.persistentRules {
                    Section("规则管理") { PersistentApprovalRulesSettingsView(store: rules, approvalCenter: center) }
                }
                if let feedback { Text(feedback).font(typography?.caption ?? .caption) }
            } else { Text("当前权限来源未接入，不能添加目录授权。") }
        }
        .id(refresh)
        .accessibilityIdentifier("settings.permissions")
    }
}

private struct AgentSettingsTab: View {
    @Bindable var center: SettingsCenter
    var approvalCenter: ApprovalPromptCenter? = nil
    @Environment(\.typographyTokens) private var typography
    @Environment(\.themeTokens) private var theme
    @State private var terminalPolicyQuery = ""
    @State private var terminalPolicyResetPending = false
    @State private var policyBudgetDraft = ""
    @State private var policyDeadlineDraft = ""
    @State private var policyAutonomyDraft: AutonomyLevel = .l1
    @State private var policyDomainsDraft = ""
    @State private var policySaveMessage: String?
    @State private var bypassConfirmationMessage: String?
    @State private var showSkillBypassRisk = false
    @State private var skillRiskFacts: ComposerPolicyFactSource?
    @State private var skillRiskPresentationID = UUID()
    @State private var ruleRefreshID = UUID()
    @State private var childDeletionReviewMessage: String?
    @State private var childDeletionReviewMessageIsError = false

    var body: some View {
        Form {
            Section("新对话默认权限") {
                Picker("权限模式", selection: Binding(
                    get: { center.composerPolicy.mode },
                    set: { mode in
                        var policy = center.composerPolicy
                        policy.mode = mode
                        if mode != .bypassPermission {
                            policy.bypassModeConfirmed = false
                        }
                        center.composerPolicy = policy
                    }
                )) {
                    ForEach(ComposerTaskMode.allCases.filter {
                        !(center.composerPolicy.disableBypass && $0 == .bypassPermission)
                    }, id: \.rawValue) { mode in
                        Text(ComposerPolicyPresentation.modeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("权限模式")

                Picker("工作量", selection: Binding(
                    get: { center.composerPolicy.effort },
                    set: { effort in
                        var policy = center.composerPolicy
                        policy.effort = effort
                        center.composerPolicy = policy
                    }
                )) {
                    ForEach(ComposerEffort.allCases, id: \.rawValue) { effort in
                        Text(ComposerPolicyPresentation.effortLabel(effort)).tag(effort)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("工作量")

                Toggle("我同意绕过权限：可读写删除电脑上任意文件、执行任意命令（系统文件与已安装软件除外；本次选择只确认一次）", isOn: Binding(
                    get: { center.composerPolicy.bypassModeConfirmed },
                    set: { confirmed in
                        if confirmed {
                            skillRiskFacts = approvalCenter?.skillRuleFactsProvider?()
                            skillRiskPresentationID = UUID()
                            showSkillBypassRisk = true
                        } else if Policy05BypassSettingsConfirmation.setConfirmed(false, in: center) {
                            bypassConfirmationMessage = nil
                        } else {
                            bypassConfirmationMessage = "绕过权限确认未保存，请检查设置持久化后重试。"
                        }
                    }
                ))
                .sheet(isPresented: $showSkillBypassRisk) {
                    let presentationID = skillRiskPresentationID
                    SkillBypassRiskView(projectSummary: SkillRiskPresentation.projectSummary(skillRiskFacts),
                        canRememberSkillActions: SkillBypassRiskConfirmation.canRemember(facts: skillRiskFacts,
                            store: approvalCenter?.persistentRules), onConfirm: { tools in
                            guard showSkillBypassRisk, skillRiskPresentationID == presentationID else { return }
                            let saved = SkillBypassRiskConfirmation.confirm(tools, riskConfirmed: true,
                                expectedFacts: skillRiskFacts, currentFacts: approvalCenter?.skillRuleFactsProvider?(),
                                store: approvalCenter?.persistentRules) {
                                    Policy05BypassSettingsConfirmation.setConfirmed(true, in: center)
                                }
                            bypassConfirmationMessage = saved
                                ? (tools.isEmpty ? "绕过权限已确认；技能动作仍逐次询问。" : "已保存所选技能动作的放行，可在上方逐条撤销。")
                                : "风险确认未保存，请检查当前项目和运行上限后重试。"
                            if saved {
                                showSkillBypassRisk = false
                                ruleRefreshID = UUID()
                            }
                        }, onCancel: { showSkillBypassRisk = false })
                }
                .disabled(center.composerPolicy.mode != .bypassPermission)
                .accessibilityLabel("绕过权限需二次确认")
                .accessibilityIdentifier("settings.agent.composer-policy.bypass-confirmed")

                if center.composerPolicy.mode != .bypassPermission {
                    Text("此开关当前不可用：请先在上方把权限模式选为“绕过权限”。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.agent.composer-policy.bypass-disabled-reason")
                }

                if center.composerPolicy.mode == .bypassPermission,
                   center.policyRuntimeDefaults.autonomyLevel != .l3 {
                    Text("绕过权限需要将最高模式设为绕过权限。当前确认不会自动提高权限；请在下方选择“绕过权限”、点击“保存运行上限”，然后再确认绕过权限。")
                        .foregroundStyle(theme?.statusWarningText ?? .orange)
                        .accessibilityIdentifier("settings.agent.composer-policy.bypass-requires-l3")
                    Button("选择“绕过权限”（仍须保存）") {
                        policyAutonomyDraft = .l3
                        policySaveMessage = "已选择“绕过权限”，尚未保存。请点击下方“保存运行上限”。"
                    }
                    .accessibilityIdentifier("settings.agent.composer-policy.prepare-l3")
                }
                if let bypassConfirmationMessage {
                    Text(bypassConfirmationMessage)
                        .foregroundStyle(theme?.statusWarningText ?? .orange)
                        .accessibilityIdentifier("settings.agent.composer-policy.bypass-feedback")
                }

                Toggle("禁用绕过权限模式（共用电脑建议开启）", isOn: Binding(
                    get: { center.composerPolicy.disableBypass },
                    set: { disabled in
                        var policy = center.composerPolicy
                        policy.disableBypass = disabled
                        if disabled, policy.mode == .bypassPermission {
                            policy.mode = .manual
                            policy.bypassModeConfirmed = false
                            bypassConfirmationMessage = "已禁用绕过权限模式，任务模式已回落到手动审批。"
                        }
                        center.composerPolicy = policy
                    }
                ))
                .accessibilityLabel("禁用绕过权限模式")
                .accessibilityIdentifier("settings.agent.composer-policy.disable-bypass")

                Toggle("绕过模式下保护凭据类路径（~/.ssh、~/.aws、~/.gnupg、.env、密钥文件，以及 security 钥匙串读取/导出/删除命令；默认开启，关闭后绕过模式的模型可读写这些路径；其他模式照常走审批）。钥匙串目录、MinisCanvas 自身数据/设置目录和 ~/.config/miniscanvas-test 是绕过模式的硬拦截，不受此开关控制", isOn: Binding(
                    get: { center.composerPolicy.protectCredentialPaths },
                    set: { protected in
                        var policy = center.composerPolicy
                        policy.protectCredentialPaths = protected
                        center.composerPolicy = policy
                    }
                ))
                .accessibilityLabel("绕过模式下保护凭据路径")
                .accessibilityIdentifier("settings.agent.composer-policy.protect-credentials")

                Text(center.composerPolicy.mode == .bypassPermission
                     ? "确认后可读写删除电脑上任意文件、执行任意命令；操作系统文件、已安装软件、MinisCanvas 自身数据目录、测试配置目录与钥匙串仍不可改动（命令层只能尽力拦截，不是安全边界）。删除：文件检查点开启（默认）时先留检查点再删除，可从恢复入口找回，不进废纸篓；关闭检查点时才移入废纸篓。模型修改权限或审批设置仍须用户批准。"
                     : "每次发送消息都会冻结当前策略；已开始的回合不会被设置变更改写。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let approvalCenter {
                Section("工具审批") {
                    ApprovalPresentationSettingsView(center: approvalCenter)
                    if let rules = approvalCenter.persistentRules {
                        PersistentApprovalRulesSettingsView(store: rules, approvalCenter: approvalCenter).id(ruleRefreshID)
                    }
                    if let browserRules = approvalCenter.browserInteractionRules {
                        BrowserInteractionRulesSettingsView(store: browserRules)
                    }
                }
            }
            HooksSettingsSection().id(SettingsSearchResult.hooksAnchor)
            ResidentSettingsSection()
            Section("命令环境") {
                Toggle("剥离凭据", isOn: Binding(
                    get: { center.stripModelShellCredentials },
                    set: { center.stripModelShellCredentials = $0 }
                ))
                .accessibilityIdentifier("settings.agent.strip-shell-credentials")
                Text("默认继承登录 Shell 的 PATH 和凭据（包括 SSH、GitHub）。开启后，模型命令与可见终端不再传递凭据变量。MCP、Hook 和外部桥使用各自的环境配置。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("非交互命令环境", isOn: Binding(
                    get: { center.modelShellNoninteractive },
                    set: { center.modelShellNoninteractive = $0 }
                ))
                .accessibilityIdentifier("settings.agent.noninteractive-shell")
                Text("默认关闭 Git 口令提示、编辑器和分页器。需要这些程序自己的交互行为时可关闭；命令输入仍为空。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("循环与工具") {
                if center.maxLoopIterationsNoticePending {
                    Text("你已保存的循环上限为10。新版默认不限次数；当前仍保留10，请选择是否更新。")
                    HStack {
                        Button("改为不限") { center.acknowledgeLoopLimitNotice(useNewDefault: true) }
                        Button("保留10") { center.acknowledgeLoopLimitNotice(useNewDefault: false) }
                    }
                }
                ValidatedNumericSettingField(
                    "累计 Token 上限（默认1000000）",
                    value: Binding(get: { center.maxTokensPerSession }, set: { center.maxTokensPerSession = $0 }),
                    in: 1...Int.max,
                    accessibilityIdentifier: "settings.agent.max-tokens-per-session"
                )
                .disabled(center.tokenBudgetUnlimited)
                Toggle("不限制累计 Token 用量", isOn: Binding(
                    get: { center.tokenBudgetUnlimited }, set: { center.tokenBudgetUnlimited = $0 }))
                    .accessibilityIdentifier("settings.agent.token-budget-unlimited")
                Text("更改立即作用于当前会话，保留已累计用量。")
                    .font(.caption).foregroundStyle(.secondary)
                ValidatedNumericSettingField(
                    "最大循环迭代数",
                    value: Binding(
                        get: { center.maxLoopIterations },
                        set: { center.maxLoopIterations = $0 }
                    ),
                    in: 1...100,
                    accessibilityIdentifier: "settings.agent.max-loop-iterations"
                )
                .disabled(center.loopIterationsUnlimited)
                Toggle("不限制每回合循环次数", isOn: Binding(
                    get: { center.loopIterationsUnlimited }, set: { center.loopIterationsUnlimited = $0 }))
                    .accessibilityIdentifier("settings.agent.loop-iterations-unlimited")
                Text("默认不限，和 Claude Code、Codex 一样；仍受累计 Token 上限、重复调用检测和手动停止约束。")
                    .font(.caption).foregroundStyle(.secondary)
                ValidatedNumericSettingField(
                    "命令超时（秒，默认120，最多600）",
                    value: Binding(
                        get: { center.shellCommandTimeoutSeconds },
                        set: { center.shellCommandTimeoutSeconds = $0 }
                    ),
                    in: 1...600,
                    accessibilityIdentifier: "settings.agent.shell-command-timeout"
                )
                .help("仅用于命令执行；单次命令可设置更短时限，最长600秒。")
                ValidatedNumericSettingField(
                    "并发工具上限",
                    value: Binding(
                        get: { center.concurrentToolLimit },
                        set: { center.concurrentToolLimit = $0 }
                    ),
                    in: 1...16,
                    accessibilityIdentifier: "settings.agent.concurrent-tool-limit"
                )
            }

            Section("子 Agent 并发") {
                    ValidatedNumericSettingField(
                        "用户选择",
                        value: Binding(
                            get: { center.childConcurrencyUserSelected },
                            set: { center.childConcurrencyUserSelected = $0 }
                        ),
                        in: 1...center.childConcurrencyHardLimit,
                        accessibilityIdentifier: "settings.agent.child-concurrency.selected"
                    )

                    // P3-CHILD-40 / D-CHILDA · 166-B：启用并行会话数由用户在设置里
                    // 显式选择（1...40，与每会话 1–40 同级同上限、共用同一风险确认
                    // 闸）。默认 1 = 旧行为。全局请求预算 = N × 每会话用户选择。
                    ValidatedNumericSettingField(
                        "启用并行会话数",
                        value: Binding(
                            get: { center.childConcurrencyEnabledSessionCount },
                            set: { center.childConcurrencyEnabledSessionCount = $0 }
                        ),
                        in: 1...center.childConcurrencyHardLimit,
                        accessibilityIdentifier: "settings.agent.child-concurrency.enabled-sessions"
                    )
                    policyBoundaryRow(
                        "全局请求预算（会话数×每会话）",
                        value: "\(center.childConcurrencySelection.globalRequestedCapacity)"
                    )
                    .accessibilityIdentifier("settings.agent.child-concurrency.global-budget")

                    policyBoundaryRow(
                        "系统建议值",
                        value: "\(center.childConcurrencyRecommended)"
                    )
                    .accessibilityIdentifier("settings.agent.child-concurrency.recommended")
                    policyBoundaryRow(
                        "有效运行上限",
                        value: "\(center.childConcurrencyEffective)"
                    )
                    .accessibilityIdentifier("settings.agent.child-concurrency.effective")
                    policyBoundaryRow(
                        "硬上限",
                        value: "\(center.childConcurrencyHardLimit)"
                    )
                    .accessibilityIdentifier("settings.agent.child-concurrency.hard-limit")

                    if center.childConcurrencyUserSelected > center.childConcurrencyRecommended
                        || center.childConcurrencyEnabledSessionCount > 1 {
                        Toggle(
                            "确认高于建议值的资源风险",
                            isOn: Binding(
                                get: { center.childConcurrencyRiskAcknowledged },
                                set: { center.childConcurrencyRiskAcknowledged = $0 }
                            )
                        )
                        .accessibilityIdentifier("settings.agent.child-concurrency.risk-ack")
                        Text(
                            center.childConcurrencyRiskAcknowledged
                                ? "已确认；有效运行上限采用用户选择。"
                                : "未确认；有效运行上限暂按系统建议值，用户选择不会被改写。"
                        )
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        center.resetChildConcurrencyToDefaults()
                    } label: {
                        Label { Text("恢复子任务默认值") } icon: {
                            MinisIconView(.refresh, size: 14)
                        }
                    }
                    .disabled(
                        center.childConcurrencyUserSelected
                            == ChildConcurrencySelection.default.userSelected
                        && center.childConcurrencyEnabledSessionCount == 1
                        && !center.childConcurrencyRiskAcknowledged
                    )
                    .accessibilityIdentifier("settings.agent.child-concurrency.reset")
            }

            Section("高级") {
                if center.toolsDisabled {
                    Text("所有工具已停用。可在安全设置重新启用。")
                } else {
                    Picker("自动模式下其它工具", selection: Binding(
                        get: { center.approvalPolicy },
                        set: { center.approvalPolicy = $0 }
                    )) {
                        Text("每次询问").tag(ApprovalPolicy.alwaysAsk)
                        Text("只问高风险").tag(ApprovalPolicy.riskOnlyAsk)
                    }
                    .pickerStyle(.menu)
                }

                if center.legacyAutomaticApprovalCompatibilityActive {
                    Text("原自动执行的定时／项目任务兼容已启用。")
                    Button("确认使用当前审批策略") {
                        center.confirmApprovalPolicy(center.approvalPolicy)
                    }
                    Button("关闭存量自动执行兼容") {
                        center.disableLegacyAutomaticApprovalCompatibility()
                    }
                } else {
                    Text("存量自动执行兼容未启用。")
                }

                Text(SettingsView.approvalPolicyFootnote)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(SettingsView.approvalPolicyFootnoteIdentifier)
            }

            Section("终端命令策略") {
                Text("规则只影响新命令；已提交的终端请求和 Agent 回合继续使用各自冻结的策略快照。“自动允许”只影响你自己在终端里敲的命令；智能体执行命令是否询问，由输入框的模式和已保存的“以后都允许”规则决定，只有“拒绝”和“每次确认”对智能体同样生效。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("搜索命令", text: $terminalPolicyQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.agent.terminal-policy.search")

                terminalPolicyEditor(
                    title: "自动允许",
                    keyPath: \.automaticAllowCommands,
                    accessibilityIdentifier: "settings.agent.terminal-policy.allow"
                )
                terminalPolicyEditor(
                    title: "每次确认",
                    keyPath: \.confirmationCommands,
                    accessibilityIdentifier: "settings.agent.terminal-policy.confirm"
                )
                terminalPolicyEditor(
                    title: "用户追加拒绝",
                    keyPath: \.userDeniedCommands,
                    accessibilityIdentifier: "settings.agent.terminal-policy.user-deny"
                )

                terminalPolicyRuleList(
                    title: "当前可见规则",
                    commands: center.terminalPolicySnapshot.automaticAllowCommands.sorted()
                        + center.terminalPolicySnapshot.confirmationCommands.sorted()
                        + center.terminalPolicySnapshot.userDeniedCommands.sorted(),
                    accessibilityPrefix: "settings.agent.terminal-policy.rule"
                )

                terminalPolicyRuleList(
                    title: "产品硬拒绝（只读）",
                    commands: center.terminalPolicySnapshot.productHardDeniedCommands.sorted(),
                    accessibilityPrefix: "settings.agent.terminal-policy.hard-deny"
                )

                Button("恢复终端规则默认值", role: .destructive) {
                    terminalPolicyResetPending = true
                }
                .accessibilityIdentifier("settings.agent.terminal-policy.reset")
            }

            Section("运行安全上限") {
                policyBoundaryRow("预算", value: "\(center.policyRuntimeDefaults.budget) 次工具调用")
                policyBoundaryRow(
                    "时限",
                    value: policyDuration(center.policyRuntimeDefaults.deadlineHorizon)
                )
                policyBoundaryRow(
                    "最高模式",
                    value: autonomyLabel(center.policyRuntimeDefaults.autonomyLevel)
                )
                policyBoundaryRow(
                    "网络默认",
                    value: center.policyRuntimeDefaults.networkDomains.isEmpty
                        ? "默认拒绝（无域名）"
                        : center.policyRuntimeDefaults.networkDomains.sorted().joined(separator: "、")
                )
                Text("这些是生产运行时的保守上限；输入框里只能选择请求策略，不能放宽预算、时限、自主权或网络域名边界。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                ValidatedNumericSettingField(
                    "预算上限",
                    text: $policyBudgetDraft,
                    accessibilityIdentifier: "settings.agent.policy-runtime.budget",
                    boundsDescription: "非负整数",
                    commit: { raw in
                        guard ValidatedNumericSettingField.integerValue(raw, in: 0...Int.max) != nil else {
                            // Keep the invalid staged text visible to Save's existing
                            // admission check; no SettingsCenter write occurs here.
                            policyBudgetDraft = raw
                            return ValidatedNumericSettingField.integerError(
                                for: raw, in: 0...Int.max
                            )
                        }
                        return nil
                    }
                )
                ValidatedNumericSettingField(
                    "时限上限（分钟）",
                    text: $policyDeadlineDraft,
                    accessibilityIdentifier: "settings.agent.policy-runtime.deadline",
                    boundsDescription: "非负有限分钟，且截止日期可表示",
                    commit: { raw in
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let minutes = Double(trimmed), minutes.isFinite, minutes >= 0,
                              let value = policyDeadlineSeconds(minutes: minutes),
                              Date().addingTimeInterval(value).timeIntervalSinceReferenceDate.isFinite
                        else {
                            policyDeadlineDraft = raw
                            return "请输入非负有限分钟，且截止日期必须可表示"
                        }
                        return nil
                    }
                )
                if let minutes = Double(policyDeadlineDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
                   minutes.isFinite, minutes >= 0 {
                    Text("= \(String(format: "%.2f", minutes / 60)) 小时")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                Text("预算单位为工具调用次数（每次计 1）；上限为非负整数。填 0 时，不允许消耗预算的工具调用。时限为非负有限分钟，且截止日期必须可表示。无效输入不会保存。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Picker("最高模式", selection: $policyAutonomyDraft) {
                    ForEach([AutonomyLevel.l0, .l1, .l2, .l3], id: \.rawValue) { level in
                        Text(autonomyLabel(level)).tag(level)
                    }
                }
                .accessibilityIdentifier("settings.agent.policy-runtime.autonomy")
                Text("仅计划用于观察；手动审批需要你确认；自动编辑在已授权范围内执行；绕过权限仍需开启确认，仍须用户确认，硬安全边界始终有效。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("允许子任务写入、编辑、删除文件及执行命令", isOn: Binding(
                    get: { center.childMutationsEnabled },
                    set: { center.childMutationsEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.agent.child-mutations-enabled")
                Text("默认开启，仅影响新回合；已有回合保留原设置。子任务仍遵循父会话当前权限和审批规则，浏览器写入受浏览器写操作设置控制。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("允许子任务使用其他模型和思考档位", isOn: Binding(
                    get: { center.childModelOverridesEnabled },
                    set: { center.childModelOverridesEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.agent.child-model-overrides-enabled")
                if center.childModelOverridesEnabled {
                    Picker("子任务思考档位上限", selection: Binding(
                        get: { center.childModelThinkingLevelCeiling },
                        set: { center.childModelThinkingLevelCeiling = $0 }
                    )) {
                        Text("模型自身上限").tag(ThinkingLevel?.none)
                        ForEach(ThinkingLevel.allCases, id: \.self) { level in
                            Text(ComposerThinkingSelection.label(level)).tag(Optional(level))
                        }
                    }
                    .accessibilityIdentifier("settings.agent.child-thinking-ceiling")
                }
                Text("默认继承父级；开启后仅可选择已配置且就绪的模型，仍遵循父会话权限与审批。注意：子任务选的模型可能属于另一家供应商，开启后对话内容会发到那一家，不想外发就保持关闭。设置变更仅影响后续派发。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(BrowserNavigationPolicy.allowedWebsitesSettingLabel, text: $policyDomainsDraft,
                    prompt: Text("填写域名，多个域名用逗号分隔"))
                    .accessibilityIdentifier("settings.agent.policy-runtime.domains")
                Button("保存运行上限") { savePolicyRuntimeDefaults() }
                    .accessibilityIdentifier("settings.agent.policy-runtime.save")
                if let policySaveMessage {
                    Text(policySaveMessage)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                Text("保存后仅影响新回合；已有回合保留冻结策略。网络域名不会代替独立的能力、审批和租约检查。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear(perform: loadPolicyRuntimeDraft)

            // Goal18 CHILD-DELETE-AUTO：用户专属开关 + 白名单目录。模型设置工具没有这两项的
            // 修改入口；默认关闭、白名单为空。
            Section("子任务删除自动审查") {
                Toggle("自动审查子任务的文件删除（默认关闭）", isOn: Binding(
                    get: { center.childDeletionAutoReviewEnabled },
                    set: { center.childDeletionAutoReviewEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.agent.child-deletion-auto-review-enabled")
                Text("仅在本页「允许子任务写入、编辑、删除文件及执行命令」与「常规」页「保留文件检查点」均开启时才可能生效，且只针对子任务发起的单个文件删除，不影响你或主对话的操作。开启后，每次子任务删除都会先建立检查点备份；删除白名单目录内、非敏感且非权限/配置类的文件时，该文件相对白名单目录的路径和大小（不含文件内容）会发送给当前所选模型的服务方，做一次独立判断；仅当判断为可恢复删除才自动放行，放行仍经原审批闸门及文件访问根目录、策略限制。白名单外、检查点不可用、模型不确定、出错或超过 10 秒时仍走人工审批。自动删除的文件可在检查点恢复。仅影响新回合；已在运行的子任务保持原设置。家目录及其上级、系统目录、资源库和 MinisCanvas 自身数据目录不能加入白名单。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if center.childDeletionAutoReviewWhitelist.isEmpty {
                    Label { Text("白名单为空：即使开启也不会自动放行任何删除") } icon: { MinisIconView(.folderAdd, size: 14).foregroundPalette(.secondary) }
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.childDeletionAutoReviewWhitelist, id: \.self) { path in
                        HStack {
                            MinisIconView(.database, size: 12)
                                .foregroundPalette(.secondary)
                            Text(path)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            if case .stale(let reason) = center.childDeletionAutoReviewEntryStatus(path) {
                                Text("已失效：\(reason)")
                                    .font(typography?.caption ?? .caption)
                                    .foregroundStyle(theme?.statusDanger ?? Color.red)
                                    .accessibilityIdentifier("settings.agent.child-deletion-auto-review.stale")
                            }
                            Button {
                                if center.removeChildDeletionAutoReviewDirectory(path) {
                                    showChildDeletionReviewMessage("已移除白名单目录：\(path)")
                                } else {
                                    showChildDeletionReviewMessage("无法移除该白名单目录。", isError: true)
                                }
                            } label: {
                                MinisIconView(.remove, size: 14)
                            }
                            .buttonStyle(.borderless)
                            .help("从白名单移除该目录")
                            .accessibilityLabel("移除白名单目录 \(path)")
                            .accessibilityIdentifier("settings.agent.child-deletion-auto-review.remove")
                        }
                    }
                }

                HStack {
                    Button {
                        presentChildDeletionWhitelistPicker()
                    } label: {
                        Label { Text("+ 选择白名单目录") } icon: { MinisIconView(.folderAdd, size: 14) }
                    }
                    .disabled(center.childDeletionAutoReviewWhitelist.count >= ChildDeletionReviewSettings.maxWhitelistDirectories)
                    .accessibilityIdentifier("settings.agent.child-deletion-auto-review.add")
                    .help("选择允许自动审查删除的目录；保存其符号链接解析后的真实路径")
                    Spacer()
                    Text("\(center.childDeletionAutoReviewWhitelist.count) / \(ChildDeletionReviewSettings.maxWhitelistDirectories)")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                if let childDeletionReviewMessage {
                    Text(childDeletionReviewMessage)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(childDeletionReviewMessageIsError ? (theme?.statusDanger ?? Color.red) : Color.secondary)
                }
            }

            Section("画布与对话隔离") {
                let isolation = center.canvasChatIsolationPolicy
                Toggle(
                    "画布与对话始终隔离",
                    isOn: .constant(isolation.effectiveValue)
                )
                .disabled(true)
                .accessibilityIdentifier("settings.policy.canvas-chat-isolation")
                .accessibilityValue(isolation.effectiveValue ? "已启用，只读，不可关闭" : "未启用")
                .help("画布与对话独立运行，此保护始终开启。")

                policyBoundaryRow("当前状态", value: isolation.effectiveValue ? "已启用" : "未启用")
                policyBoundaryRow("默认状态", value: isolation.defaultValue ? "保持隔离" : "未启用")
                policyBoundaryRow("重置", value: "无需重置，始终保持隔离")
                policyBoundaryRow("保护范围", value: "对话不能直接修改画布内容")

                Text("画布与对话独立运行，此保护始终开启。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.policy.canvas-chat-isolation.reason")
            }

            Section("智能体可用模型") {
                // AJ-40：可用模型白名单（多选 chip，可选）。空 = 全部可用（不限制）。
                // F1-05：自定义服务商的模型也要能选；只列内置模型会让一旦设了白名单，
                // 自定义服务商的模型被整体拦掉又选不回来。按模型 ID 去重（列表以 ID 为键）。
                let builtInModels = center.providers
                    .flatMap { p in center.models(forProviderID: p.rawValue).map { (provider: p.displayName, id: $0.id, display: $0.displayName) } }
                let customModels = center.providerRecords
                    .flatMap { r in r.modelNames.map { (provider: r.providerDisplayName, id: $0, display: $0) } }
                let allModels: [(provider: String, id: String, display: String)] = {
                    var seen = Set<String>()
                    return (builtInModels + customModels).filter { seen.insert($0.id).inserted }
                }()
                if allModels.isEmpty {
                    Text("暂无可用模型")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(allModels, id: \.id) { m in
                            let selected = center.availableModelWhitelist.contains(m.id)
                            Button {
                                var wl = center.availableModelWhitelist
                                if let idx = wl.firstIndex(of: m.id) { wl.remove(at: idx) } else { wl.append(m.id) }
                                center.availableModelWhitelist = wl
                            } label: {
                                HStack(spacing: 6) {
                                    MinisIconView(selected ? .check : .status, size: 14)
                                        .foregroundPalette(selected ? Color.accentColor : .secondary)
                                    Text(m.display)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .font(typography?.caption ?? .caption)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(m.provider) · \(m.display)")
                        }
                    }
                    Text(center.availableModelWhitelist.isEmpty
                         ? "未限制：Agent 可使用所有可用模型。点选模型可限制为仅白名单内。"
                         : "已限制 \(center.availableModelWhitelist.count) 个模型；白名单外模型将被忽略。清空所有选择即恢复全部可用。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("上下文管理") {
                VStack(alignment: .leading, spacing: 6) {
                    ValidatedNumericSettingField(
                        "上下文长度（tokens）",
                        value: Binding(
                            get: { center.contextLengthTokens },
                            set: { center.contextLengthTokens = $0 }
                        ),
                        in: 0...Int.max,
                        accessibilityIdentifier: "settings.agent.context-length-tokens"
                    )
                    Text(center.defaultModelContextWindowTokens.map {
                        "输入 0 使用模型上下文窗口；当前默认模型为 \($0) tokens。其他模型按本轮上限校验；文本裁剪为估算值。"
                    } ?? "输入 0 使用本轮模型的上下文窗口；显式值按本轮模型元数据校验，文本裁剪为估算值。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ValidatedNumericSettingField(
                        "保留历史轮数",
                        value: Binding(
                            get: { center.historyTurnLimit },
                            set: { center.historyTurnLimit = $0 }
                        ),
                        in: 0...Int.max,
                        accessibilityIdentifier: "settings.agent.history-turn-limit"
                    )
                    Text("输入 0 保留全部历史；正值包含当前用户轮次。只影响下一轮发送给模型的副本，不改已保存对话。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("自动压缩阈值")
                        Spacer()
                        Text(center.autoCompactThreshold, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                    ValidatedNumericSettingField(
                        "自动压缩阈值",
                        value: Binding(
                            get: { center.autoCompactThreshold },
                            set: { center.autoCompactThreshold = $0 }
                        ),
                        in: 0.5...1.0,
                        step: 0.05,
                        accessibilityIdentifier: "settings.agent.auto-compact-threshold"
                    )
                }
            }

            Section("容错") {
                Toggle("主服务失败时换用备用模型", isOn: Binding(
                    get: { center.fallbackEnabled },
                    set: { center.fallbackEnabled = $0 }
                ))
                Text("默认关闭。开启后，主服务出现授权、限流或额度问题时，消息会改发到另一个已配置的供应商，请确认你接受内容发送给它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("恢复终端规则默认值？", isPresented: $terminalPolicyResetPending) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                center.resetTerminalPolicyToDefaults()
            }
        } message: {
            Text("仅恢复终端命令分类；产品硬拒绝始终保留，其它设置和数据不受影响。")
        }
    }

    private func terminalPolicyEditor(
        title: String,
        keyPath: WritableKeyPath<TerminalPolicySettings, [String]>,
        accessibilityIdentifier: String
    ) -> some View {
        TextField(
            title,
            text: terminalPolicyTextBinding(keyPath)
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(keyPath == \.confirmationCommands
            ? "使用逗号分隔命令名；产品硬拒绝项不可加入允许或确认。默认 git 仍自动允许只读命令；若要每次确认，请先删除 git，再重新加入并保存。"
            : "使用逗号分隔命令名；产品硬拒绝项不可加入允许或确认。")
    }

    private func terminalPolicyTextBinding(
        _ keyPath: WritableKeyPath<TerminalPolicySettings, [String]>
    ) -> Binding<String> {
        Binding(
            get: {
                center.terminalPolicySettings[keyPath: keyPath].joined(separator: ", ")
            },
            set: { raw in
                var policy = center.terminalPolicySettings
                let names = raw
                    .components(separatedBy: ",")
                    .compactMap(TerminalPolicySnapshot.normalizeCommandName)
                if keyPath == \.confirmationCommands {
                    policy = policy.editingConfirmationCommands(names)
                } else {
                    policy[keyPath: keyPath] = names
                }
                center.terminalPolicySettings = policy
            }
        )
    }

    @ViewBuilder
    private func terminalPolicyRuleList(
        title: String,
        commands: [String],
        accessibilityPrefix: String
    ) -> some View {
        let query = terminalPolicyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? commands
            : commands.filter { $0.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            if filtered.isEmpty {
                Text(query.isEmpty ? "暂无规则" : "没有匹配命令")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(Set(filtered)).sorted(), id: \.self) { command in
                    Text(command)
                        .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
                        .accessibilityIdentifier("\(accessibilityPrefix).\(command)")
                }
            }
        }
    }

    private func policyBoundaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func showChildDeletionReviewMessage(_ message: String, isError: Bool = false) {
        childDeletionReviewMessage = message
        childDeletionReviewMessageIsError = isError
    }

    /// NSOpenPanel 选目录；SettingsCenter 保存符号链接解析后的真实路径。
    private func presentChildDeletionWhitelistPicker() {
        let panel = NSOpenPanel()
        panel.title = "选择允许自动审查删除的目录"
        panel.prompt = "加入白名单"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            switch center.addChildDeletionAutoReviewDirectory(url) {
            case .added(let path): showChildDeletionReviewMessage("已加入白名单目录：\(path)")
            case .alreadyPresent(let path): showChildDeletionReviewMessage("该目录已在白名单中：\(path)", isError: true)
            case .notADirectory: showChildDeletionReviewMessage("只能选择已存在的目录（不能是文件或系统根目录）。", isError: true)
            case .tooBroad(let reason): showChildDeletionReviewMessage("无法加入：\(reason)。请选择更具体的项目或工作目录。", isError: true)
            case .limitReached:
                showChildDeletionReviewMessage("已达到最大数量（\(ChildDeletionReviewSettings.maxWhitelistDirectories)）。", isError: true)
            case .persistenceFailed: showChildDeletionReviewMessage("设置保存失败，白名单未改变。", isError: true)
            }
        }
    }

    private func loadPolicyRuntimeDraft() {
        let value = center.policyRuntimeDefaults
        policyBudgetDraft = String(value.budget)
        policyDeadlineDraft = String(value.deadlineHorizon / 60)
        policyAutonomyDraft = value.autonomyLevel
        policyDomainsDraft = value.networkDomains.sorted().joined(separator: ", ")
        policySaveMessage = nil
    }

    private func policyDeadlineSeconds(minutes: Double) -> TimeInterval? {
        let savedSeconds = center.policyRuntimeDefaults.deadlineHorizon
        let seconds = minutes == savedSeconds / 60 ? savedSeconds : minutes * 60
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func savePolicyRuntimeDefaults() {
        let rawDomains = policyDomainsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let domains = rawDomains.isEmpty ? [] : rawDomains
            .replacingOccurrences(of: "\n", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let budget = Int(policyBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              let minutes = Double(policyDeadlineDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              let deadline = policyDeadlineSeconds(minutes: minutes),
              domains.allSatisfy({ !$0.isEmpty }) else {
            policySaveMessage = "未保存：预算、时限或域名格式无效。"
            return
        }
        let value = ProductionPolicyDefaults(
            budget: budget,
            deadlineHorizon: deadline,
            autonomyLevel: policyAutonomyDraft,
            networkDomains: Set(domains)
        )
        guard center.updatePolicyRuntimeDefaults(value) else {
            policySaveMessage = "未保存：检查上限和域名，或重试设置持久化。"
            return
        }
        loadPolicyRuntimeDraft()
        policySaveMessage = "已保存；新回合使用更新后的上限。"
        if center.policyRuntimeDefaults.autonomyLevel == .l3 {
            bypassConfirmationMessage = nil
        }
    }

    private func policyDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分钟"
        }
        return "\(minutes) 分钟"
    }

    private func autonomyLabel(_ level: AutonomyLevel) -> String {
        switch level {
        case .l0: return "仅计划"
        case .l1: return "手动审批"
        case .l2: return "自动编辑"
        case .l3: return "绕过权限"
        }
    }
}

// MARK: - MCP（E6 管理面板）

/// 设置窗口的 MCP tab：直接嵌 MCPManagerView（服务器列表/新增/删除/测试连接）。
private struct MCPSettingsTab: View {
    @Bindable var center: SettingsCenter
    let widthClass: AdaptiveWidthClass

    var body: some View {
        MCPManagerView(center: center, widthClass: widthClass)
    }
}

// MARK: - 技能（波4）

/// 设置窗口的「技能」tab：技能列表 + 启用开关 + 详情（描述/路径）+ 刷新。
private struct SkillsSettingsTab: View {
    @Bindable var store: SkillsStore
    @Environment(\.themeTokens) private var theme
    var chat: ChatStore? = nil

    private var currentReviewScope: MemoryScope? {
        guard let chat, let scope = chat.activeMemoryScope,
              chat.trustedProjectRootProvider?(scope) != nil else { return nil }
        return scope
    }
    @Environment(\.typographyTokens) private var typography
    @State private var dismissedErrorMessage: String?
    @State private var showLocalSkillPicker = false
    @State private var showBuiltinSkillList = false
    @State private var showSkillDirectoryPicker = false
    @State private var directoryPickerIsProject = false
    @State private var updatingSkillID: String?
    @State private var deletionReview: SkillDeletionReviewDraft?
    @State private var importReview: SkillImportReviewDraft?
    @State private var importReviewErrorMessage: String?
    @State private var maintenanceDiff: SkillMaintenanceChangeRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(store.entries.count) 个技能")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.reloadInBackground()
                } label: {
                    Label { Text("刷新") } icon: { MinisIconView(.refresh, size: 14) }
                }
                Button("导入本地技能…") {
                    importReviewErrorMessage = nil
                    updatingSkillID = nil
                    showLocalSkillPicker = true
                }
                .accessibilityIdentifier("settings.skills.import-local")
                Button("导入内置技能…") {
                    importReviewErrorMessage = nil
                    showBuiltinSkillList.toggle()
                }
                .accessibilityIdentifier("settings.skills.import-builtin")
                Spacer()
            }
            .padding(12)

            if showBuiltinSkillList {
                VStack(alignment: .leading, spacing: 6) {
                    Text("内置技能库 v\(DefaultPromptSkills.version)：选一个查看全文，明确批准后才会启用。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    ForEach(DefaultPromptSkills.entries, id: \.name) { entry in
                        HStack {
                            Button(entry.name) {
                                switch store.proposeBuiltinSkill(named: entry.name) {
                                case .success(let draft):
                                    importReviewErrorMessage = nil
                                    importReview = draft
                                case .failure(let error):
                                    importReviewErrorMessage = error.userMessage
                                }
                            }
                            Text(entry.description)
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let importReviewErrorMessage, importReview == nil {
                        Text(importReviewErrorMessage)
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(theme?.statusDangerText ?? AppStatusColor.danger)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if let chat {
                ExternalSkillsSection(chat: chat)
                ProjectSubagentsSection(chat: chat)
            }

            DisclosureGroup("技能目录") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.localSkillRoots, id: \.path) { directory in
                        HStack {
                            Text(directory.path).font(typography?.caption ?? .caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("移除") { _ = store.removeSkillDirectory(directory) }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button("添加技能目录…") {
                            directoryPickerIsProject = false
                            showSkillDirectoryPicker = true
                        }
                        Button("添加项目目录…") {
                            directoryPickerIsProject = true
                            showSkillDirectoryPicker = true
                        }
                    }
                    Text("项目目录扫描其 .claude/skills；发现技能后仍须导入、审核并批准启用。")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)

            if let importReviewErrorMessage {
                Text(importReviewErrorMessage)
                    .modifier(ReadableStatusForeground(status: .danger))
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("settings.skills.import-error")
            }

            if let message = store.lastErrorMessage,
               dismissedErrorMessage != message {
                SkillToggleErrorBanner(message: message) {
                    dismissedErrorMessage = message
                }
            }

            if store.catalogDiagnostics.rejectedCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现 \(store.catalogDiagnostics.rejectedCount) 项技能扫描异常；相关项未加入列表。")
                        .font(typography?.caption ?? .caption)
                        .modifier(ReadableStatusForeground(status: .danger))
                    ForEach(Array(store.catalogDiagnostics.userMessages.enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(typography?.caption2 ?? .caption2)
                            .foregroundStyle(.secondary)
                    }
                    if store.catalogDiagnostics.suppressedSampleCount > 0 {
                        Text("另有 \(store.catalogDiagnostics.suppressedSampleCount) 项未逐一显示。")
                            .font(typography?.caption2 ?? .caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("settings.skills.catalog-diagnostics")
            }

            if !store.maintenanceChanges.isEmpty {
                DisclosureGroup("技能修改记录") {
                    ForEach(store.maintenanceChanges) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((record.automatic ? "按你的放行" : "本次批准") + " · "
                                    + (SkillRiskPresentation.actionTitle(record.action) ?? "技能操作") + "：" + record.skillID)
                                Text(record.status == "applied" ? "已保存执行结果" : "差异已保存，是否执行尚待核实")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("查看完整差异") { maintenanceDiff = record }
                                .accessibilityIdentifier("settings.skills.maintenance-diff")
                        }
                    }
                    Text("修改后的技能可在下方回退上一版；已删除的技能可在回收站恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
            if !store.deletedSkillReceipts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("技能回收站").font(.headline)
                    ForEach(store.deletedSkillReceipts, id: \.operationID) { receipt in
                        HStack {
                            Text(receipt.targetID)
                            Spacer()
                            Button("恢复") {
                                do { try store.restoreDeletedSkill(receipt) }
                                catch { importReviewErrorMessage = "恢复失败：\(UserFacingErrorText.describe(error))" }
                            }
                            .accessibilityIdentifier("settings.skills.restore.\(receipt.targetID)")
                        }
                    }
                }
                .padding(12)
            }
            Divider()

            if store.entries.isEmpty {
                ContentUnavailableView(
                    "暂无技能",
                    systemImage: "books.vertical",
                    description: Text("扫描已配置的本地技能目录与 App 技能库；未找到 SKILL.md。")
                )
            } else {
                List {
                    ForEach(store.groupedByCategory, id: \.category) { group in
                        Section(group.category) {
                            ForEach(group.items) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .fileImporter(
            isPresented: $showLocalSkillPicker,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let selectedDirectory) = result else { return }
            let accessed = selectedDirectory.startAccessingSecurityScopedResource()
            defer { if accessed { selectedDirectory.stopAccessingSecurityScopedResource() } }
            switch store.proposeLocalSkill(from: selectedDirectory, replacing: updatingSkillID) {
            case .success(let draft):
                importReviewErrorMessage = nil
                importReview = draft
            case .failure(let error):
                importReviewErrorMessage = error.userMessage
            }
        }
        .background(
            Color.clear.fileImporter(isPresented: $showSkillDirectoryPicker, allowedContentTypes: [.folder]) { result in
                guard case .success(let directory) = result else { return }
                _ = store.addSkillDirectory(directory, isProject: directoryPickerIsProject)
            }
        )
        .sheet(item: $importReview) { draft in
            SkillImportReviewSheet(
                draft: draft,
                errorMessage: importReviewErrorMessage,
                onApprove: {
                    let scope = draft.replacesExistingApproval ? currentReviewScope : nil
                    switch store.approveLocalSkill(draft, currentScope: scope) {
                    case .success:
                        importReviewErrorMessage = nil
                        importReview = nil
                    case .failure(let error):
                        importReviewErrorMessage = error.userMessage
                    }
                },
                onClose: {
                    importReviewErrorMessage = nil
                    importReview = nil
                }
            )
        }
        .sheet(item: $maintenanceDiff) { record in
            VStack(alignment: .leading, spacing: 12) {
                ApprovalFilePreviewView(diff: record.diff)
                Button("关闭") { maintenanceDiff = nil }
            }.padding(16).frame(minWidth: 600, minHeight: 400)
        }
        .sheet(item: $deletionReview) { draft in
            SkillDeletionReviewSheet(intent: draft.intent, onDelete: { confirmed in
                do {
                    _ = try store.deleteSkill(confirmed)
                    deletionReview = nil
                    importReviewErrorMessage = nil
                } catch {
                    importReviewErrorMessage = "技能删除或恢复记录未完成：\(UserFacingErrorText.describe(error))"
                    deletionReview = nil
                }
            }, onClose: { deletionReview = nil })
        }
    }

    private func row(_ entry: SkillEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.name)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.isEnabled(entry.id) },
                    set: {
                        dismissedErrorMessage = nil
                        _ = store.setEnabled(entry.id, enabled: $0)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(entry.requiresImport || store.hasPendingLocalSkillReview(for: entry.id))
                .accessibilityLabel("启用技能 \(entry.name)")
                .accessibilityValue(store.isEnabled(entry.id) ? "已启用" : "已停用")
                .accessibilityIdentifier("settings.skills.toggle.\(entry.id)")
            }
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !entry.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("版本：\(entry.version)")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.skills.version.\(entry.id)")
            }
            if entry.requiresImport {
                Button("导入并审核…") {
                    switch store.proposeDiscoveredSkill(entry) {
                    case .success(let draft):
                        importReviewErrorMessage = nil
                        importReview = draft
                    case .failure(let error):
                        importReviewErrorMessage = error.userMessage
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings.skills.import-discovered.\(entry.id)")
            }
            if entry.source == .app {
                HStack(spacing: 8) {
                    Button("更新技能…") {
                        importReviewErrorMessage = nil
                        updatingSkillID = entry.id
                        showLocalSkillPicker = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.hasPendingLocalSkillReview(for: entry.id))
                    .accessibilityIdentifier("settings.skills.update.\(entry.id)")
                    Button("移入回收站") {
                        do {
                            deletionReview = SkillDeletionReviewDraft(intent: try store.previewSkillDeletion(entry.id))
                        } catch {
                            importReviewErrorMessage = "无法准备删除：\(UserFacingErrorText.describe(error))"
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.skills.delete.\(entry.id)")
                    if let scope = currentReviewScope {
                        Button("在当前会话和项目重新审核…") {
                            switch store.reviewAppSkill(for: entry.id, in: scope) {
                            case .success(let draft):
                                importReviewErrorMessage = nil
                                importReview = draft
                            case .failure(let error):
                                importReviewErrorMessage = error.userMessage
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.hasPendingLocalSkillReview(for: entry.id))
                        .accessibilityIdentifier("settings.skills.review-scope.\(entry.id)")
                    }
                    if store.hasPendingLocalSkillReview(for: entry.id) {
                        Button("审核待批准技能") {
                            importReviewErrorMessage = nil
                            importReview = store.pendingLocalSkillReview(for: entry.id)
                            if importReview == nil {
                                importReviewErrorMessage = SkillImportReviewError.proposalChanged.userMessage
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.skills.review.\(entry.id)")
                    }
                    Button("回滚上一版本") {
                        dismissedErrorMessage = nil
                        _ = store.rollback(entry.id, reason: "settings explicit rollback")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!store.canRollback(entry.id))
                    .accessibilityLabel("回滚技能 \(entry.name) 上一版本")
                    .accessibilityIdentifier("settings.skills.rollback.\(entry.id)")
                    Spacer()
                }
            }
            Text("来源：\(entry.source.displayName) · \(entry.path.path)")
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

private struct SkillDeletionReviewDraft: Identifiable {
    let intent: OperationIntent
    var id: UUID { intent.operationID }
}

private struct SkillDeletionReviewSheet: View {
    let intent: OperationIntent
    let onDelete: (OperationIntent) -> Void
    let onClose: () -> Void
    @State private var reviewed = false
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("移入技能回收站").font(.title2)
            Text("技能：\(intent.targetName)")
            Text(intent.impactSummary)
            Toggle("我已核对该技能和影响范围", isOn: $reviewed)
            Toggle("确认将该技能移入可恢复的回收站", isOn: $confirmed)
                .disabled(!reviewed)
            HStack {
                Button("取消", action: onClose)
                Spacer()
                Button("移入回收站") {
                    guard reviewed && confirmed else { return }
                    onDelete(intent.withFirstConfirmation("Settings exact skill preview reviewed")
                        .withSecondConfirmation("Settings reversible trash confirmed"))
                }
                .disabled(!reviewed || !confirmed)
                .accessibilityIdentifier("settings.skills.delete-confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}

private struct SkillImportReviewSheet: View {
    @Environment(\.themeTokens) private var theme
    let draft: SkillImportReviewDraft
    let errorMessage: String?
    let onApprove: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("审核本地技能")
                .font(.title2)
            Text(draft.replacesExistingApproval
                 ? "正在审核已安装副本。确认后，这个技能只在当前会话和项目里获得批准，会替换它原来的批准范围；保留当前启用开关。"
                 : "已导入 App 技能库，当前为待批准、未启用。只有明确批准后才会激活。")
            if draft.replacesGlobalApproval {
                Text("注意：这个技能现在是全局批准的。确认后全局批准会被取代，其它会话和项目需要各自重新审核才能使用它。")
                    .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                    .accessibilityIdentifier("settings.skills.review.global-replace-warning")
            }
            Text("名称：\(draft.name) · 版本：\(draft.version)")
            Text("所选来源／现有快照：\(draft.sourcePath)")
                .textSelection(.enabled)
            Text("内容 SHA-256：\(draft.contentHash)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text("来源身份：\(draft.sourceIdentity)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            if let scope = draft.scope {
                Text("适用范围：当前会话和项目。其它会话或项目需要重新审核。")
                    .foregroundStyle(.secondary)
                Text("会话：\(scope.sessionID)\n项目：\(scope.projectID)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("适用范围：无项目会话。项目会话需要精确匹配的作用域，本次批准不会放宽该限制。")
                    .foregroundStyle(.secondary)
            }
            if !draft.bodyPreview.isEmpty {
                Text("内容预览")
                    .font(.headline)
                ScrollView {
                    Text(draft.bodyPreview)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                if draft.bodyPreviewIsTruncated {
                    Text("仅展示前 2048 个字符；批准将作用于上方哈希对应的完整文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .modifier(ReadableStatusForeground(status: .danger))
                    .accessibilityIdentifier("settings.skills.review-error")
            }
            HStack {
                Spacer()
                Button("暂不批准", action: onClose)
                Button(draft.replacesExistingApproval ? "明确批准当前会话和项目" : "明确批准并启用") { onApprove() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.skills.approve-local")
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 390)
    }
}

private struct SkillToggleErrorBanner: View {
    @Environment(\.themeTokens) private var theme
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MinisIconView(.warning, size: 14, accessibilityLabel: "技能状态错误")
                .foregroundPalette(theme?.statusWarning ?? AppStatusColor.warning)
            Text(message)
                .accessibilityIdentifier("settings.skills.toggle-error.message")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("关闭提示", action: onDismiss)
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭技能状态错误提示")
                .accessibilityIdentifier("settings.skills.toggle-error.dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((theme?.statusWarning ?? AppStatusColor.warning).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.skills.toggle-error")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 定时任务（波4）

/// 设置窗口的「定时任务」tab：任务列表 + 新建/编辑/删除 + 启用开关 + cron 校验。
struct SchedulerSettingsTab: View {
    @Bindable var store: SchedulerTaskStore
    let runtime: SchedulerTaskRuntime?
    var body: some View { SchedulerControlSettingsView(store: store, runtime: runtime) }
}

private struct PrivacySettingsTab: View {
    @Bindable var center: SettingsCenter
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    /// AJ-28：新增授权目录/被拒绝目录的路径输入框。
    @State private var newAllowedRoot = ""
    @State private var newDeniedRoot = ""
    /// AJ-28：最近一次操作反馈（失败原因等）。
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    var body: some View {
        Form {
            Section("日志") {
                Picker("日志级别", selection: Binding(
                    get: { center.privacyLogLevel },
                    set: { center.privacyLogLevel = $0 }
                )) {
                    ForEach(SettingsLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
            }

            // AJ-28：文件访问权限设置入口 —— 联动 ToolExecutor.allowedRoot / deniedRoots。
            Section {
                LabeledContent("授权目录") {
                    Text(center.effectiveAllowedRoot)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack {
                    TextField("输入授权目录绝对路径…", text: $newAllowedRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        if center.setFileAccessAllowedRoot(newAllowedRoot) {
                            newAllowedRoot = ""
                            showFeedback("授权目录已更新。")
                        } else {
                            showFeedback("请输入有效的绝对路径（以 / 开头）。", isError: true)
                        }
                    }
                    .disabled(newAllowedRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !center.effectiveDeniedRoots.isEmpty {
                    Divider()
                    Text("拒绝目录")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    ForEach(center.effectiveDeniedRoots, id: \.self) { path in
                        HStack {
                            Text(path)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                center.removeFileAccessDeniedRoot(path)
                                showFeedback("已移除拒绝目录：\(path)")
                            } label: {
                                MinisIconView(.remove, size: 14)
                            }
                            .buttonStyle(.borderless)
                            .help("移除该拒绝目录")
                            .accessibilityLabel("移除该拒绝目录")
                        }
                    }
                }

                HStack {
                    TextField("输入拒绝目录绝对路径…", text: $newDeniedRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        if center.addFileAccessDeniedRoot(newDeniedRoot) {
                            newDeniedRoot = ""
                            showFeedback("已添加拒绝目录。")
                        } else {
                            showFeedback("请输入有效的绝对路径（以 / 开头）。", isError: true)
                        }
                    }
                    .disabled(newDeniedRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(feedbackIsError ? (theme?.statusDanger ?? .red) : .secondary)
                }

                Button("重置为默认（主目录 + 默认拒绝目录）", role: .destructive) {
                    center.resetFileAccessRoots()
                    showFeedback("文件访问权限已重置为默认。")
                }
            } header: {
                Text("文件访问权限")
            } footer: {
                Text("Agent 的文件工具（读/写/编辑/终端）只能访问授权目录内的路径；拒绝目录即使位于授权目录内也会被拦截。默认拒绝目录包含 App 自身数据目录（Application Support）。")
            }

            Section {
                Toggle("允许读取本机 Codex / Claude Code 会话", isOn: Binding(
                    get: { center.allowLocalAgentSessionRead },
                    set: { center.allowLocalAgentSessionRead = $0 }))
            } footer: {
                Text("只读、内容脱敏；仅外部会话工具可用，文件工具不能访问这些目录；关闭后需挂载会话目录才可读取")
            }

            // AJ-45：挂载外部文件夹 —— NSOpenPanel 选目录 + 列表管理（最多 10 个）+ 加入白名单。
            Section {
                if center.effectiveMountedFolders.isEmpty {
                    Label { Text("点击「+ 选择文件夹」挂载外部目录") } icon: { MinisIconView(.folderAdd, size: 14).foregroundPalette(.secondary) }
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.effectiveMountedFolders, id: \.self) { path in
                        HStack {
                            MinisIconView(.database, size: 12)
                                .foregroundPalette(.secondary)
                            Text(path)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                center.unmountFolder(path)
                                showFeedback("已取消挂载：\(path)")
                            } label: {
                                MinisIconView(.remove, size: 14)
                            }
                            .buttonStyle(.borderless)
                            .help("取消挂载该文件夹")
                            .accessibilityLabel("取消挂载该文件夹")
                        }
                    }
                }

                HStack {
                    Button {
                        presentFolderPicker()
                    } label: {
                        Label { Text("+ 选择文件夹") } icon: { MinisIconView(.folderAdd, size: 14) }
                    }
                    .disabled(!center.canMountMoreFolders)
                    .help(center.canMountMoreFolders
                        ? "选择要挂载到 Agent 的外部文件夹"
                        : "已达到最大挂载数量（\(PrivacySettings.maxMountedFolders)）")
                    Spacer()
                    Text("\(center.effectiveMountedFolders.count) / \(PrivacySettings.maxMountedFolders)")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("挂载文件夹")
            } footer: {
                Text("已挂载的外部文件夹会加入授权目录；挂载目录在项目会话中可读写。最多同时挂载 \(PrivacySettings.maxMountedFolders) 个。挂载目录同样受拒绝目录拦截。")
            }
        }
        .formStyle(.grouped)
    }

    /// AJ-45：NSOpenPanel 选择目录并挂载（加入白名单）。
    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "选择要挂载的文件夹"
        panel.prompt = "挂载"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            if ExternalSessionMountQualification.requiresDisclosure(forMountedPath: path),
               !confirmExternalSessionMount() { return }
            if center.mountFolder(path) {
                if [".codex", ".claude"].contains((path as NSString).lastPathComponent) {
                    showFeedback("已挂载文件夹：\(path)。注意：该目录包含 Codex / Claude Code 的外部会话记录，文件工具可读写其中内容；如只需读取会话，建议改挂其中的 sessions 或 projects 子目录。")
                } else {
                    showFeedback("已挂载文件夹：\(path)")
                }
            } else if center.effectiveMountedFolders.contains(path) {
                showFeedback("该文件夹已在挂载列表中。", isError: true)
            } else if center.effectiveMountedFolders.count >= PrivacySettings.maxMountedFolders {
                showFeedback("已达到最大挂载数量（\(PrivacySettings.maxMountedFolders)）。", isError: true)
            } else {
                showFeedback("无法挂载该文件夹。", isError: true)
            }
        }
    }

    /// 首次挂载外部会话目录（~/.codex/sessions、~/.claude/projects）前的确认；返回 false 即取消挂载。
    private func confirmExternalSessionMount() -> Bool {
        let alert = NSAlert()
        alert.messageText = "挂载外部会话目录？"
        alert.informativeText = """
        ① 读到的会话内容会作为工具结果发给当前使用的模型提供商（可能是云端）。
        ② 已做通用密钥脱敏，但不保证去除个人信息与他方工作内容。
        ③ 挂载目录同时对文件工具可读写，请只挂载这一个目录。
        ④ 取消挂载即撤销。
        ⑤ 挂载后模型还可以请求向这些会话发送消息，每次都需要你确认。
        """
        alert.addButton(withTitle: "挂载")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedbackMessage = message
        feedbackIsError = isError
    }
}

// MARK: - 存储（Storage）

private struct StorageSettingsTab: View {
    @Bindable var center: SettingsCenter
    var chatStore: ChatStore? = nil
    @State private var importDraft: SettingsCenter.AtomicBackupDraft?
    @State private var backupProtectionAction: BackupProtectionAction?
    @State private var backupPasswordError: String?
    @State private var backupOperation: Task<Void, Never>?
    @State private var backupGeneration = UUID()

    @State private var memoryLimitText = ""
    @State private var lastActionMessage: String?
    @State private var lastActionIsError = false
    @State private var pendingDeletion: SettingsDeletionRequest?
    @State private var expiredDeletion: SettingsDeletionRequest?
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        Form {
            Section("回收站") {
                if let chatStore {
                    SessionTrashEntryButton(chat: chatStore, title: "打开回收站（保留30天）")
                } else {
                    Text("回收站暂不可用，请从会话列表打开。")
                        .foregroundStyle(.secondary)
                }
            }
            Section("数据备份") {
                Button("导出备份") {
                    exportBackup()
                }

                Button("导入备份") {
                    importBackup()
                }
                .disabled(center.atomicBackupReopenRequired || center.atomicBackupInProgress)
                Text("备份文件含会话、记忆、技能和设置，区别于 Markdown 文件导入和记忆事实 JSON 导入。快照含私人会话与记忆，但不包含 Keychain 密钥。未选择密码保护导出时，文件以明文保存；请妥善保管，并仅从可信来源恢复。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("选择密码保护导出后，文件会加密保存。未选择密码时按明文保存。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if center.atomicBackupReopenRequired {
                    Text(center.atomicBackupRecoveryRequired
                         ? "恢复需要处理。原始备份和日志已保留，请退出并重新打开应用。"
                         : "导入已完整提交。当前窗口保留导入前的数据视图，请退出并重新打开应用。")
                    Button("退出应用以重新打开") { NSApplication.shared.terminate(nil) }
                }
            }

            Section("保留策略") {
                ValidatedNumericSettingField(
                    "会话保留天数",
                    value: Binding(
                        get: { center.sessionRetentionDays },
                        set: { center.sessionRetentionDays = $0 }
                    ),
                    in: 1...365,
                    accessibilityIdentifier: "settings.storage.session-retention-days"
                )

                ValidatedNumericSettingField(
                    "记忆体积上限（MB，留空 = 不限制）",
                    text: $memoryLimitText,
                    accessibilityIdentifier: "settings.storage.memory-limit",
                    boundsDescription: "0 或留空"
                ) { raw in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty else {
                        guard let parsed = Int(trimmed), parsed >= 0 else {
                            return "请输入非负整数，或留空表示不限制"
                        }
                        center.memoryLimitMB = parsed
                        return nil
                    }
                    center.memoryLimitMB = nil
                    return nil
                }
                .onAppear {
                    memoryLimitText = center.memoryLimitMB.map(String.init) ?? ""
                }

                Toggle("提醒清理过期会话（不会自动删除）", isOn: Binding(
                    get: { center.autoDeleteOldSessions },
                    set: { center.autoDeleteOldSessions = $0 }
                ))
            }

            Section("会话（\(center.sessions.count)）") {
                Button("清理超过 \(center.sessionRetentionDays) 天的会话") {
                    beginDeletion(
                        preview: { try center.previewSessionsOlderThanRetention() },
                        execute: { try center.deleteSessionsOlderThanRetention(intent: $0) }
                    )
                }

                // storage.autoDeleteOldSessions 消费者：仅在用户开启自动清理且存在超期会话时出现。
                // 该行为读取 canonical Settings 入口；开启也永不静默删除——点击后仍走同一个
                // 预览 + 两步确认门禁，并把会话移入回收站（可恢复）。
                if center.pendingAutoCleanupCount > 0 {
                    Button("清理 \(center.pendingAutoCleanupCount) 个过期会话（需确认，移入回收站）") {
                        beginDeletion(
                            preview: {
                                guard let intent = try center.previewAutoCleanupIntentIfEnabled() else {
                                    return try center.previewSessionsOlderThanRetention()
                                }
                                return intent
                            },
                            execute: { try center.deleteSessionsOlderThanRetention(intent: $0) }
                        )
                    }
                }

                Button("清空全部会话", role: .destructive) {
                    beginDeletion(
                        preview: { try center.previewAllSessions() },
                        execute: { try center.deleteAllSessions(intent: $0) }
                    )
                }
            }

            Section("记忆（\(center.memoryFacts.count)）") {
                Button("清空全部记忆", role: .destructive) {
                    beginDeletion(
                        preview: { try center.previewMemoryClear() },
                        execute: { try center.clearAllMemory(intent: $0) }
                    )
                }

                if !center.memoryFacts.isEmpty {
                    ForEach(center.memoryFacts.prefix(5)) { fact in
                        HStack {
                            Text(fact.text)
                                .lineLimit(1)
                            .truncationMode(.tail)
                            Spacer()
                            Button(role: .destructive) {
                                beginDeletion(
                                    preview: { try center.previewMemoryFactDeletion(id: fact.id) },
                                    execute: { try center.removeMemoryFact(id: fact.id, intent: $0) }
                                )
                            } label: {
                                MinisIconView(.delete, size: 12)
                            }
                            .buttonStyle(.borderless)
                            .help("删除该条记忆")
                            .accessibilityLabel("删除该条记忆")
                        }
                    }
                }
            }

            if let lastActionMessage {
                Section {
                    Text(lastActionMessage)
                        .foregroundStyle(lastActionIsError ? (theme?.statusDanger ?? .red) : .secondary)
                }
            } else if let expired = expiredDeletion, let preview = expired.preview, let execute = expired.execute {
                Section {
                    SettingsDeletionExpiredNotice(accessibilityPrefix: "settings.storage") {
                        beginDeletion(preview: preview, execute: execute, restarting: expired.intent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $importDraft) { draft in
            AtomicBackupImportSheet(center: center, draft: draft)
        }
        .sheet(item: $backupProtectionAction) { action in
            BackupProtectionSheet(
                action: action,
                errorMessage: backupPasswordError,
                onCancel: {
                    backupPasswordError = nil
                    backupGeneration = UUID()
                    backupOperation?.cancel()
                    backupOperation = nil
                    backupProtectionAction = nil
                },
                onSubmit: { protection in
                    startBackupOperation(action: action, protection: protection)
                }
            )
        }

        .sheet(item: $pendingDeletion) { request in
            SettingsDeletionPrompt(
                request: request,
                onCancel: { pendingDeletion = nil },
                onConfirm: { intent in executeDeletion(request, intent: intent) }
            )
        }
        .onDisappear {
            backupGeneration = UUID()
            backupOperation?.cancel()
            backupOperation = nil
        }
    }

    private func beginDeletion(
        preview: @escaping () throws -> OperationIntent,
        execute: @escaping (OperationIntent) throws -> DeletionReceipt,
        restarting expired: OperationIntent? = nil
    ) {
        expiredDeletion = nil
        do {
            pendingDeletion = try SettingsDeletionRequest(preview: preview, execute: execute, restarting: expired)
            lastActionMessage = nil
            lastActionIsError = false
        } catch {
            lastActionMessage = expired == nil
                ? "删除未开始（DELETE-PREVIEW-FAILED）。请刷新列表并重新确认删除范围。"
                : "无法重新打开原确认。请回到原删除入口，重新选择并核对范围。"
            lastActionIsError = true
        }
    }

    private func executeDeletion(_ request: SettingsDeletionRequest, intent: OperationIntent) {
        do {
            guard let execute = request.execute else { return }
            let receipt = try execute(intent)
            pendingDeletion = nil
            lastActionIsError = false
            lastActionMessage = "已执行删除：\(receipt.affectedCount) 项。操作 ID：\(receipt.operationID.uuidString.prefix(8))。"
        } catch DeletionGateError.expired {
            pendingDeletion = nil
            lastActionMessage = nil
            expiredDeletion = request
        } catch {
            pendingDeletion = nil
            lastActionIsError = true
            lastActionMessage = SettingsFailureMessage.deletion(error)
        }
    }

    // MARK: - 备份导出/导入（F14 P1-3：错误传播到 UI，不静默吞）

    /// 导出备份：NSSavePanel 选目标路径，全四域导出。
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (SyncManager.defaultSnapshotFilename() as NSString).deletingPathExtension
        if let type = UTType(filenameExtension: SyncManager.snapshotFileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupProtectionAction = .export(url)
    }

    /// 导入备份：NSOpenPanel 选 .minissync 文件；
    /// 部分域失败/校验失败时展示中文摘要 + 条目级明细（isError 标红）。
    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let type = UTType(filenameExtension: SyncManager.snapshotFileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startBackupImportDetection(url: url)
    }

    private func startBackupImportDetection(url: URL) {
        backupOperation?.cancel()
        let generation = UUID()
        backupGeneration = generation
        backupOperation = Task { @MainActor in
            defer { if generation == backupGeneration { backupOperation = nil } }
            do {
                switch try await center.backupProtectionKindAsync(from: url) {
                case .legacyPlaintext:
                    let draft = try await center.readAtomicBackupDraftAsync(from: url, protection: .legacy)
                    guard generation == backupGeneration, !Task.isCancelled else { return }
                    importDraft = draft
                    lastActionMessage = nil
                    lastActionIsError = false
                case .passwordProtected:
                    guard generation == backupGeneration, !Task.isCancelled else { return }
                    backupProtectionAction = .importFile(url)
                }
            } catch {
                guard generation == backupGeneration, !Task.isCancelled else { return }
                lastActionMessage = SettingsFailureMessage.backup(error, operation: .preview).message
                lastActionIsError = true
            }
        }
    }

    private func startBackupOperation(
        action: BackupProtectionAction,
        protection: SyncSnapshotProtection
    ) {
        backupOperation?.cancel()
        let generation = UUID()
        backupGeneration = generation
        let url = action.url
        backupPasswordError = nil
        backupOperation = Task { @MainActor in
            defer { if generation == backupGeneration { backupOperation = nil } }
            switch action {
            case .export:
                let result = await center.exportBackupAsync(to: url, protection: protection)
                guard generation == backupGeneration, !Task.isCancelled else { return }
                backupProtectionAction = nil
                lastActionMessage = result.message
                lastActionIsError = result.isError
            case .importFile:
                do {
                    let draft = try await center.readAtomicBackupDraftAsync(from: url, protection: protection)
                    guard generation == backupGeneration, !Task.isCancelled else { return }
                    backupProtectionAction = nil
                    importDraft = draft
                    lastActionMessage = nil
                    lastActionIsError = false
                } catch {
                    guard generation == backupGeneration, !Task.isCancelled else { return }
                    let failure = SettingsFailureMessage.backup(error, operation: .preview)
                    if failure.needsPasswordRetry {
                        // 密码错误：留在密码框，原因显示在框内，可直接重输。
                        backupPasswordError = failure.message
                    } else {
                        backupProtectionAction = nil
                        lastActionMessage = failure.message
                        lastActionIsError = true
                    }
                }
            }
        }
    }
}

struct AtomicBackupImportSheet: View {
    @Bindable var center: SettingsCenter
    let draft: SettingsCenter.AtomicBackupDraft
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<SyncScope> = []
    @State private var sessionID = ""
    @State private var projectID = ""
    @State private var preview: SyncAtomicImportPreview?
    @State private var acknowledged = false
    @State private var confirmPresented = false
    @State private var message: String?
    @State private var runningTask: Task<Void, Never>?

    @MainActor
    init(center: SettingsCenter, draft: SettingsCenter.AtomicBackupDraft) {
        self._center = Bindable(wrappedValue: center)
        self.draft = draft
    }

    private var targetScope: MemoryScope? {
        guard selected.contains(.memories), !sessionID.isEmpty, !projectID.isEmpty else { return nil }
        return MemoryScope(sessionID: sessionID, projectID: projectID)
    }
    var displayedMetadata: [String] {
        ["版本：v\(draft.manifest.version)",
         "来源设备：\(draft.manifest.deviceName.isEmpty ? "未提供" : draft.manifest.deviceName)",
         "导出时间：\(draft.manifest.exportedAt.formatted(date: .abbreviated, time: .standard))"]
    }
    func sourceSummary(for scope: SyncScope) -> String {
        guard let count = draft.sourceCounts[scope] else { return "\(scope.displayName)：未包含" }
        return "\(scope.displayName)：\(count)\(scope == .settings ? "组" : "项")"
    }
    static func overwriteSemantics(for scope: SyncScope) -> String {
        switch scope {
        case .sessions: return "同标识会话以备份内容更新，其他会话保留。"
        case .memories: return "替换指定项目与会话范围内的记忆，其他范围保留；已恢复的相同记忆备份不会重复导入。"
        case .skills: return "同标识技能在校验通过后更新，其他技能保留。"
        case .settings: return "以备份中的设置替换现有设置；权限与安全设置（审批、绕过、自主权、终端规则、文件访问边界等）不会被导入，保留本机现值；独立保存的凭据不在恢复范围内。"
        }
    }
    static func conflictSummary(_ domain: SyncAtomicImportDomainPreview) -> String {
        switch domain.scope {
        case .sessions, .skills:
            return "\(domain.scope.displayName)：备份 \(domain.incomingCount) 项，与当前同标识 \(domain.overlappingCount) 项，其他 \(domain.retainedCount) 项保留。"
        case .memories:
            return "记忆：备份 \(domain.incomingCount) 项，目标范围内现有 \(domain.overlappingCount) 项，其他范围 \(domain.retainedCount) 项保留。"
        case .settings:
            return "设置：备份 \(domain.incomingCount) 组，将覆盖现有 \(domain.overlappingCount) 组设置。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入备份预演").font(.title2)
            Text(draft.sourceURL.lastPathComponent)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
            ForEach(displayedMetadata, id: \.self) { Text($0).textSelection(.enabled) }
            Text("选择需要恢复的数据域；未选择的域保持不变，预演和取消都不会修改现有数据。")
            ForEach(SyncScope.allCases, id: \.rawValue) { scope in
                Toggle(sourceSummary(for: scope), isOn: Binding(
                    get: { selected.contains(scope) },
                    set: { enabled in
                        if enabled { selected.insert(scope) } else { selected.remove(scope) }
                        preview = nil; acknowledged = false
                    }))
                    .disabled(draft.sourceCounts[scope] == nil || center.atomicBackupInProgress)
                if draft.sourceCounts[scope] != nil { Text(Self.overwriteSemantics(for: scope)).font(.caption).foregroundStyle(.secondary) }
            }
            if draft.sourceCounts[.settings] != nil && draft.settingsRecovery == nil {
                Text("此旧版备份不含模型服务商配置和快捷键覆盖值；可导入原有设置，但这两项恢复不完整。")
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .warning))
            }
            if !plainHTTPRecoveredProviderNames.isEmpty {
                Text("备份里的供应商 \(plainHTTPRecoveredProviderNames.joined(separator: "、")) 使用 http 地址，恢复后 Key 会在网络上明文传输，有被截获的风险。仅在你信任该网络和服务时导入。")
                    .font(.caption)
                    .modifier(ReadableStatusForeground(status: .warning))
            }
            if selected.contains(.memories) {
                Text("明确记忆目标范围；目标必须与备份中的来源一致。")
                TextField("项目标识", text: $projectID)
                TextField("会话标识", text: $sessionID)
                ForEach(draft.sourceMemoryScopes, id: \.self) { scope in
                    Text("来源：\(scope.projectID) / \(scope.sessionID)").font(.caption)
                }
                if draft.hasMissingMemoryProvenance {
                    Text("此备份包含缺少来源的记忆。请取消选择记忆域；不会猜测或迁移其项目归属。")
                }
            }
            if let preview {
                Text("预演完成：\(preview.selected.count) 个域，现有 \(preview.destinationFileCount) 个文件。确认后先保存完整自动备份，再执行导入。")
                ForEach(preview.domains, id: \.scope) { domain in Text(Self.conflictSummary(domain)) }
                Text("预演有效至 \(preview.expiresAt.formatted(date: .omitted, time: .standard))。选择变化后需要重新预演。")
                Toggle(plainHTTPRecoveredProviderNames.isEmpty
                       ? "我已核对恢复范围，并知悉完成后必须重新打开应用"
                       : "我已核对恢复范围，知悉完成后必须重新打开应用，并了解 http 地址会明文传输 Key 的风险",
                       isOn: $acknowledged)
            }
            if let message { Text(message).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
            if center.atomicBackupInProgress { ProgressView("正在备份、验证并提交数据…") }
            HStack {
                Button(center.atomicBackupInProgress ? "取消导入" : "关闭") {
                    if center.atomicBackupInProgress { runningTask?.cancel() } else { dismiss() }
                }
                Spacer()
                Button("只读预演") { dryRun() }
                    .disabled(selected.isEmpty || center.atomicBackupInProgress || center.atomicBackupReopenRequired)
                Button("确认范围并导入") { confirmPresented = true }
                    .disabled(preview == nil || !acknowledged || center.atomicBackupInProgress || center.atomicBackupReopenRequired)
            }
            if center.atomicBackupReopenRequired {
                Button("退出应用以重新打开") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620)
        .interactiveDismissDisabled(center.atomicBackupInProgress)
        .onAppear {
            selected = Set(draft.manifest.scopes.compactMap(SyncScope.init(rawValue:)))
            // A current real scope is only a visible suggestion, confirmed below.
            if let scope = center.memoryScopeProvider?() { sessionID = scope.sessionID; projectID = scope.projectID }
        }
        .onChange(of: sessionID) { _, _ in preview = nil; acknowledged = false }
        .onChange(of: projectID) { _, _ in preview = nil; acknowledged = false }
        .confirmationDialog("现在导入选定的数据域？", isPresented: $confirmPresented) {
            Button("自动备份并开始导入", role: .destructive) { commit() }
            Button("返回检查", role: .cancel) { }
        } message: {
            Text("过程中会暂停数据写入；失败时恢复全部原始目标文件。导入成功后需要重新打开应用。")
        }
    }
    /// 备份里地址为 http 公网的供应商：恢复后 Key 会以明文在网络上传输。
    private var plainHTTPRecoveredProviderNames: [String] {
        guard selected.contains(.settings), let providers = draft.settingsRecovery?.providers else { return [] }
        return providers.filter {
            $0.baseURL.map(ProviderEndpointPolicy.isPlainHTTPToPublicHost) == true
        }.map(\.name)
    }

    private func dryRun() {
        do {
            preview = try center.previewAtomicBackup(draft, selecting: selected, memoryScope: targetScope)
            acknowledged = false; message = nil
        } catch {
            preview = nil
            message = "当前选择与输入已保留。" + SettingsFailureMessage.backup(error, operation: .preview).message
        }
    }
    private func commit() {
        guard let preview, acknowledged else { return }
        runningTask = Task { @MainActor in
            do {
                let receipt = try await center.confirmAtomicBackup(draft, preview: preview,
                                                                  confirmation: SyncAtomicImportConfirmation(preview: preview))
                message = "已完整导入 \(receipt.selected.count) 个域。自动备份已保存，需重新打开应用。"
            } catch {
                message = center.atomicBackupRecoveryRequired
                    ? "回滚尚未完整验证。数据写入已停止，原始备份和日志已保留；请重新打开应用恢复。"
                    : {
                        SettingsFailureMessage.log(code: "BACKUP-IMPORT-FAILED", error: error)
                        return "导入未提交。请检查恢复状态，必要时重新打开应用后再继续；详情已写入日志。"
                    }()
            }
            self.preview = nil; acknowledged = false; runningTask = nil
        }
    }
}

// MARK: - 浏览器（Browser, AJ-49）

/// 设置中心的「浏览器」Tab：UA 预设/自定义、viewport（默认/自定义宽高）、空闲标签页超时。
/// 接线 SettingsCenter → AppSettings.browser（持久化），供内置浏览器 WKWebView 消费。
/// E1 联网搜索设置：选搜索服务、填密钥所在的环境变量名（不在这里存密钥）、SearXNG 地址、条数。
/// 配置存在 WebSearchSettingsStore；改动对新的对话回合立即生效。
private struct WebSearchSettingsSection: View {
    @State private var draft = WebSearchSettingsStore.shared.configuration
    @State private var saveFailed = false

    private var keyEnvVarName: String {
        draft.normalized().apiKeyEnvVar ?? draft.backend.defaultKeyEnvVar ?? ""
    }

    private var keyStatus: String {
        switch EnvCredentials.resolution(for: keyEnvVarName).status {
        case .configured: return "已找到该环境变量的值"
        case .unset: return "还没有这个环境变量，请到「环境变量」里添加"
        case .invalidName, .disallowedName: return "变量名需以 _API_KEY、_TOKEN 等结尾，例如 BRAVE_API_KEY"
        }
    }

    private func save() {
        saveFailed = !WebSearchSettingsStore.shared.update(draft)
    }

    var body: some View {
        Section("联网搜索") {
            Picker("搜索服务", selection: Binding(
                get: { draft.backend },
                set: { draft.backend = $0; save() }
            )) {
                ForEach(WebSearchBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityIdentifier("settings.web-search.backend")
            if draft.backend == .brave || draft.backend == .tavily {
                TextField("密钥所在的环境变量名", text: Binding(
                    get: { draft.apiKeyEnvVar ?? draft.backend.defaultKeyEnvVar ?? "" },
                    set: { draft.apiKeyEnvVar = $0 }
                ))
                .onSubmit { save() }
                .accessibilityIdentifier("settings.web-search.key-env-var")
                Text(keyStatus).font(.caption).foregroundStyle(.secondary)
            }
            if draft.backend == .searxng {
                TextField("SearXNG 地址，例如 http://localhost:8080", text: Binding(
                    get: { draft.searxngBaseURL ?? "" },
                    set: { draft.searxngBaseURL = $0 }
                ))
                .onSubmit { save() }
                .accessibilityIdentifier("settings.web-search.searxng-url")
                Text("实例需要在设置里开启 JSON 输出格式。").font(.caption).foregroundStyle(.secondary)
            }
            if draft.backend != .off {
                Stepper("每次最多返回 \(draft.maxResults) 条", value: Binding(
                    get: { draft.maxResults },
                    set: { draft.maxResults = $0; save() }
                ), in: WebSearchConfiguration.maxResultsRange)
                .accessibilityIdentifier("settings.web-search.max-results")
            }
            Text("默认关闭。选好服务并配置好密钥后，对话里才会出现联网搜索；搜索词会发给所选服务，请勿让它搜索私密内容。回车保存输入框里的改动。")
                .font(.caption).foregroundStyle(.secondary)
            if saveFailed {
                Text("保存失败，请检查应用数据目录是否可写。").font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { save() }
    }
}

private struct BrowserSettingsTab: View {
    @Bindable var center: SettingsCenter
    @Environment(\.typographyTokens) private var typography
    @State private var customUAText = ""

    var body: some View {
        Form {
            Section("浏览器写操作") {
                Toggle("允许浏览器写操作", isOn: Binding(
                    get: { center.browserWriteEnabled },
                    set: { center.browserWriteEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.browser.write-enabled")
                Text("默认开启；点击、输入、下载、上传仍逐项审批，绕过模式也不跳过。可以关闭；备份导入后会关闭，需要你重新开启。仅支持无需登录的同站表单上传；需要登录或额外字段的页面会失败。不自动使用浏览器 Cookie，也不回退到页面文件对象或文件选择器。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WebSearchSettingsSection()
            Section("用户代理（User Agent）") {
                Picker("浏览器身份", selection: Binding(
                    get: { center.userAgentPreset },
                    set: { center.userAgentPreset = $0 }
                )) {
                    ForEach(UserAgentPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                if center.userAgentPreset == .custom {
                    TextField("自定义 UA 字符串", text: $customUAText)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .onAppear { customUAText = center.customUserAgent }
                        .onChange(of: customUAText) { _, newValue in
                            center.customUserAgent = newValue
                        }
                    Text("留空时回退到桌面 Chrome UA。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Viewport") {
                Picker("页面尺寸", selection: Binding(
                    get: { center.browserViewportMode },
                    set: { center.browserViewportMode = $0 }
                )) {
                    ForEach(BrowserViewportMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if center.browserViewportMode == .custom {
                    HStack {
                        ValidatedNumericSettingField(
                            "宽",
                            value: Binding(
                                get: { center.customViewportWidth },
                                set: { center.customViewportWidth = $0 }
                            ),
                            in: 1...10_000,
                            accessibilityIdentifier: "settings.browser.viewport-width"
                        )
                        Text("×")
                        ValidatedNumericSettingField(
                            "高",
                            value: Binding(
                                get: { center.customViewportHeight },
                                set: { center.customViewportHeight = $0 }
                            ),
                            in: 1...10_000,
                            accessibilityIdentifier: "settings.browser.viewport-height"
                        )
                        Text("px")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("空闲标签页") {
                ValidatedNumericSettingField(
                    "回收内存超时（分钟）",
                    value: Binding(
                        get: { center.idleTabTimeoutMinutes },
                        set: { center.idleTabTimeoutMinutes = $0 }
                    ),
                    in: BrowserSettings.idleTimeoutRange,
                    accessibilityIdentifier: "settings.browser.idle-tab-timeout"
                )
                Text("标签页空闲超过该时长后停止加载并回收内存（1~240 分钟，默认 15）。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 记忆（Memory）

/// The examples use the same encoders as the JSON and Markdown export actions.
/// Fixed, fictional input keeps the settings explanation independent of user data.
enum MemoryImportFormatExamples {
    private static let fact = MemoryFact(
        id: "example-preference-001",
        text: "喜欢深色界面",
        sourceSessionID: "example-session",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        category: .userPref
    )

    static let json: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode([fact]) else { return "示例暂不可用" }
        return String(decoding: data, as: UTF8.self)
    }()

    static let markdown: String =
        (try? MemoryMarkdownCodec.encodeString([fact])) ?? "示例暂不可用"
}

/// Show the durable submission source separately from the proposal's free-form
/// reference. The displayed identity is informational; approval still goes
/// through the current envelope/epoch binding in SettingsCenter and Core.
struct MemoryProposalReviewSourcePresentation: Equatable {
    let sourceLine: String
    let referenceLine: String

    init(envelope: MemoryProposalEnvelope) {
        let sourceID = envelope.sourceID ?? "旧记录未提供"
        let epoch = envelope.submissionEpoch.map { String($0) } ?? "旧记录未提供"
        sourceLine = "候选来源 ID：\(sourceID) · 提交授权纪元：\(epoch)"
        referenceLine = "来源引用（候选声明）：\(envelope.sourceRef ?? "未提供")"
    }
}

/// 设置中心的「记忆」Tab：新增 + 列出（内容/分类/时间）+ 删除 + 清空。
/// 接线 SettingsCenter → MemoryStore（持久化格式不变）。
private struct MemorySettingsTab: View {
    @Bindable var center: SettingsCenter
    var schedulerStore: SchedulerTaskStore
    var chatStore: ChatStore?
    @Environment(\.externalSessionAuthorizationComposition) private var externalSources
    @State private var newFactText = ""
    @State private var newCategory = MemoryCategory.fact
    @State private var activeFactSources = MemoryActiveFactSourceSnapshot.unavailable
    // MEMORY-05 编辑半区：行内编辑器状态（同一时刻最多编辑一条）。
    @State private var editingFactID: String?
    @State private var editingFactText = ""
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var lastActionMessage: String?
    @State private var pendingDeletion: SettingsDeletionRequest?
    @State private var expiredDeletion: SettingsDeletionRequest?
    // AJ-47：文件式记忆编辑
    @State private var fileEditorPresentation: MemoryFileEditorPresentation?
    @State private var markdownImportPreview: MemoryMarkdownImportPreview?
    @State private var markdownImportGeneration = UUID()
    @State private var pendingProposalReviews: [MemoryProposalEnvelope] = []
    @State private var proposalReviewMessage: String?
    @State private var memorySearchText = ""
    @State private var memorySearchResult: MemorySearchDisplayResult?
    @State private var memorySearchKeyword: String?
    @State private var memorySearchError: String?
    private struct SearchContext: Equatable {
        let sessionID: UUID?
        let scope: MemoryScope?
        let principal: MemoryTrustedPrincipal?
    }

    @State private var memorySearchContext: SearchContext?
    @State private var memorySearchGlobalMatch = false
    @State private var candidateSourceEnabled: [String: Bool] = [:]
    @State private var candidateSourceError: String?

    private var activeMemoryScope: MemoryScope? {
        center.memoryScopeProvider?()
    }

    private var currentMemorySearchContext: SearchContext {
        let scope = activeMemoryScope
        return SearchContext(sessionID: chatStore?.activeSessionID, scope: scope,
            principal: scope == nil ? center.memoryTrustedPrincipalProvider?() : nil)
    }

    private var visiblePendingProposalReviews: [MemoryProposalEnvelope] {
        guard let scope = center.memoryScopeProvider?(), scope.isValid else { return [] }
        return pendingProposalReviews.filter { $0.proposal.memoryScope == scope }
    }

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            Toggle("对话中使用全局指令", isOn: Binding(
                get: { center.globalInstructionsEnabled },
                set: { center.globalInstructionsEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Button("编辑全局指令…") {
                guard let current = center.readMemoryDocument(named: "GLOBAL.md")
                        ?? (center.memoryFiles.contains { $0.relativePath == "GLOBAL.md" } ? nil : "") else { return }
                fileEditorPresentation = MemoryFileEditorPresentation(fileName: "GLOBAL.md", content: current)
            }
            .padding(.horizontal, 12)
            // The real per-turn gate selects approved memory facts only.
            Toggle("对话中使用已批准记忆", isOn: Binding(
                get: { center.memoryEnabled },
                set: { center.memoryEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .help("每回合按当前开关选择作用域内已批准的记忆；本轮记忆区显示检索和响应确认状态与总长度上限。")
            .padding(.horizontal, 12)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("记忆候选来源")
                    .font(typography?.headline ?? .headline)
                Text("内建来源默认开启，可随时撤销；每条记忆仍须单独批准。外部来源默认关闭。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                ForEach(SettingsCenter.BuiltInMemoryCandidateSource.allCases) { source in
                    Toggle(source.label, isOn: Binding(
                        get: { candidateSourceEnabled[source.rawValue] ?? false },
                        set: { setCandidateSource(source, enabled: $0) }
                    ))
                    .accessibilityIdentifier("settings.memory.candidate-source.\(source.rawValue)")
                }
                let scheduledTasks = schedulerStore.allTasks().filter {
                    ScheduledMemoryCandidateSource.proposalText(command: $0.command) != nil
                }
                if !scheduledTasks.isEmpty {
                    Text("定时任务来源（逐任务手动开启）")
                        .font(typography?.caption ?? .caption)
                    ForEach(scheduledTasks) { task in
                        let sourceID = ScheduledMemoryCandidateSource.sourceID(taskID: task.id)
                        Toggle("\(task.name) · \(task.id.uuidString)", isOn: Binding(
                            get: { candidateSourceEnabled[sourceID] ?? false },
                            set: { setScheduledCandidateSource(taskID: task.id, enabled: $0) }
                        ))
                        .accessibilityIdentifier("settings.memory.candidate-source.\(sourceID)")
                        Text("来源 ID：\(sourceID)")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let externalSources, !externalSources.externalMemoryCandidates.isEmpty {
                    Text("已注册外部来源（当前作用域单独授权）")
                        .font(typography?.caption ?? .caption)
                    ForEach(externalSources.externalMemoryCandidates) { candidate in
                        Toggle(candidate.label, isOn: Binding(
                            get: { candidateSourceEnabled[candidate.memorySourceID] ?? false },
                            set: { setExternalCandidateSource(candidate, enabled: $0) }
                        ))
                        .accessibilityIdentifier("settings.memory.candidate-source.\(candidate.memorySourceID)")
                        Text("来源 ID：\(candidate.memorySourceID) · 绑定作用域：\(externalSources.boundMemoryScope(for: candidate).map { "\($0.sessionID) / \($0.projectID)" } ?? "未授权")")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let candidateSourceError {
                    Text(candidateSourceError)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider().padding(.vertical, 6)

            // AJ-47：文件式记忆（GLOBAL.md / SOUL.md / 每日日志）
            fileMemorySection

            Divider()

            HStack(spacing: 8) {
                TextField("检索当前作用域记忆…", text: $memorySearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.memory.search")
                    .onSubmit { runMemorySearch() }
                Button("检索") { runMemorySearch() }
                    .disabled(memorySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.memory.search.submit")
                if !memorySearchText.isEmpty {
                    Button("清除") {
                        memorySearchText = ""
                        clearMemorySearchResult()
                    }
                    .accessibilityIdentifier("settings.memory.search.clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let memorySearchError {
                Text("检索失败：\(memorySearchError)")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDangerText ?? .red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if let memorySearchResult,
               memorySearchContext == currentMemorySearchContext,
               memorySearchKeyword == memorySearchText.trimmingCharacters(in: .whitespacesAndNewlines),
               memorySearchKeyword != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("检索结果（\(memorySearchResult.items.count + (memorySearchGlobalMatch ? 1 : 0))）")
                        .font(typography?.headline ?? .headline)
                    Text(memorySearchResult.explanation)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    if memorySearchGlobalMatch {
                        Text("GLOBAL.md · 全局记忆")
                            .accessibilityIdentifier("settings.memory.search.document.global")
                    }
                    if memorySearchResult.items.isEmpty && !memorySearchGlobalMatch {
                        Text("当前作用域没有可显示的匹配记忆。")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memorySearchResult.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text).textSelection(.enabled)
                                Text("\(item.sourceDescription) · \(item.createdAtLabel) · 修订 \(item.revision)")
                                    .font(typography?.caption2 ?? .caption2)
                                    .foregroundStyle(.secondary)
                                Text(item.recallExplanation)
                                    .font(typography?.caption2 ?? .caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("settings.memory.search.result.\(item.factID)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                TextField("输入要记住的内容…", text: $newFactText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addFact() }

                Picker("", selection: $newCategory) {
                    ForEach(MemoryCategory.allCases, id: \.self) { category in
                        Text(category.label).tag(category)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                if activeMemoryScope == nil {
                    if let global = center.memoryFiles.first(where: { $0.kind == .global && $0.relativePath == "GLOBAL.md" }) {
                        Button("打开全局记忆") { openMemoryFile(global) }
                    }
                } else {
                    Text("对本项目所有会话生效").font(.caption).foregroundStyle(.secondary)
                }
                Button("新增") { addFact() }
                    .disabled(newFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("清空全部", role: .destructive) {
                    beginDeletion(
                        preview: { try center.previewMemoryClear() },
                        execute: { try center.clearAllMemory(intent: $0) }
                    )
                }
                .disabled(center.memoryFacts.isEmpty)
            }
            .padding(12)

            // P3-MEM-01：结构化 JSON 与可编辑 Markdown 使用明确的独立入口。
            HStack(spacing: 8) {
                Button("导出 JSON") { exportMemory() }
                    .help("把当前全部记忆导出为可无损回导的 JSON 文件")
                    .accessibilityIdentifier("settings.memory.export-json")
                Button("导出 Markdown") { exportMemoryMarkdown() }
                    .help("把当前全部记忆导出为可阅读、可编辑的 Markdown 文件")
                    .accessibilityIdentifier("settings.memory.export-markdown")
                Button("导入 JSON") { importMemory() }
                    .help("从 JSON 文件导入记忆（保持旧格式并按稳定 ID 合并）")
                    .accessibilityIdentifier("settings.memory.import-json")
                Button("导入 Markdown") { importMemoryMarkdown() }
                    .help("先预览记忆内容，再选择个人、项目或临时作用域确认导入")
                    .accessibilityIdentifier("settings.memory.import-markdown")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                Text("JSON 与 Markdown 格式说明和示例")
                    .font(typography?.headline ?? .headline)
                Text("结构化事实 JSON（.json）：事实对象数组；导入时按当前会话与项目范围合并。")
                memoryFormatExample(MemoryImportFormatExamples.json)

                Text("Markdown 记忆文件（.md）：分类标题与事实列表便于阅读和编辑；注释保留回导所需的身份与来源。导入前会预览，再选择作用域。")
                memoryFormatExample(MemoryImportFormatExamples.markdown)

                Text("以上是虚构示例。上方 GLOBAL.md、SOUL.md 和每日日志在文件式记忆区单独编辑。")
                    .foregroundStyle(.secondary)
            }
            .font(typography?.caption ?? .caption)
            .accessibilityIdentifier("settings.memory.format-examples")
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            HStack {
                Text("待审核记忆提议（\(visiblePendingProposalReviews.count)）")
                    .font(typography?.headline ?? .headline)
                Spacer()
                Button("刷新待审") { refreshPendingProposalReviews() }
                    .accessibilityIdentifier("settings.memory.refresh-proposals")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if !visiblePendingProposalReviews.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visiblePendingProposalReviews, id: \.proposal.proposalID) { proposal in
                            let source = MemoryProposalReviewSourcePresentation(envelope: proposal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(proposal.text)
                                    .textSelection(.enabled)
                                DisclosureGroup("来源详情") {
                                    Text(source.sourceLine)
                                    Text(source.referenceLine)
                                    Text("提议：\(proposal.proposal.proposalID) · 待审核")
                                    Text("内容摘要：\(proposal.contentDigest ?? "未提供")")
                                    if let origin = proposal.writeProvenance {
                                        Text("来源声明（非身份签名或授权）：actor \(origin.actorID) · run \(origin.runID) · trigger \(origin.triggerID)")
                                            .textSelection(.enabled)
                                    }
                                }
                                Button("批准并记住") { approvePendingProposal(proposal) }
                                    .accessibilityIdentifier("settings.memory.approve-proposal")
                                Button("拒绝") { rejectPendingProposal(proposal) }
                                    .accessibilityIdentifier("settings.memory.reject-proposal")
                            }
                            .font(typography?.caption ?? .caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 220)
            }

            if let proposalReviewMessage {
                Text(proposalReviewMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider()

            if center.memoryFacts.isEmpty && center.memoryFactsLoadFailed {
                ContentUnavailableView {
                    Label { Text("记忆读取失败") } icon: { MinisIconView(.warning, size: 28) }
                } description: {
                    Text("记忆文件读不出来，不是没有记忆。原文件没有被改动，请检查文件后重新打开设置。")
                }
            } else if center.memoryFacts.isEmpty {
                ContentUnavailableView(
                    "暂无记忆",
                    systemImage: "brain",
                    description: Text("添加用户偏好、经验教训等长期记忆，供 Agent 跨会话记忆。")
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("记忆（\(center.memoryFacts.count)）")
                        .font(typography?.headline ?? .headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        ForEach(center.memoryFacts) { fact in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    if editingFactID == fact.id {
                                        HStack(spacing: 6) {
                                            TextField("编辑这条记忆…", text: $editingFactText)
                                                .textFieldStyle(.roundedBorder)
                                                .onSubmit { saveFactEdit(id: fact.id) }
                                                .accessibilityIdentifier("settings.memory.edit-fact-field")
                                            Button("保存") { saveFactEdit(id: fact.id) }
                                                .disabled(editingFactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                                .accessibilityIdentifier("settings.memory.save-fact-edit")
                                            Button("取消") { editingFactID = nil }
                                                .buttonStyle(.borderless)
                                        }
                                    } else {
                                        Text(fact.text)
                                            .textSelection(.enabled)
                                    }
                                    HStack(spacing: 6) {
                                        Text(fact.category.label)
                                            .font(typography?.caption2 ?? .caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill((theme?.aj38.accent.swiftUIColor ?? .blue).opacity(0.15)))
                                            .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? .blue)
                                        Text(fact.createdAt, format: .dateTime.year().month().day().hour().minute())
                                            .font(typography?.caption ?? .caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    MemoryActiveFactSourceView(
                                        fact: fact, snapshot: activeFactSources,
                                        redactor: ChatTranscriptRedactor(store: center.envStore)
                                    )
                                    .font(typography?.caption ?? .caption)
                                }
                                Spacer()
                                Button {
                                    editingFactID = fact.id
                                    editingFactText = fact.text
                                } label: {
                                    MinisIconView(.edit, size: 12)
                                }
                                .buttonStyle(.borderless)
                                .help("编辑该条记忆")
                                .accessibilityLabel("编辑该条记忆")
                                .accessibilityIdentifier("settings.memory.edit-fact.\(fact.id)")
                                Button(role: .destructive) {
                                    beginDeletion(
                                        preview: { try center.previewMemoryFactDeletion(id: fact.id) },
                                        execute: { try center.removeMemoryFact(id: fact.id, intent: $0) }
                                    )
                                } label: {
                                    MinisIconView(.delete, size: 12)
                                }
                                .buttonStyle(.borderless)
                                .help("删除该条记忆")
                                .accessibilityLabel("删除该条记忆")
                                .accessibilityIdentifier("settings.memory.delete-fact.\(fact.id)")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider()
                        }
                }
            }

            if let lastActionMessage {
                Divider()
                Text(lastActionMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else if let expired = expiredDeletion, let preview = expired.preview, let execute = expired.execute {
                Divider()
                SettingsDeletionExpiredNotice(accessibilityPrefix: "settings.memory") {
                    beginDeletion(preview: preview, execute: execute, restarting: expired.intent)
                }
                .padding(8)
            }
        }
        }
        // AJ-47：文件式记忆编辑器
        .sheet(item: $fileEditorPresentation) { presentation in
            MemoryFileEditorSheet(
                presentation: presentation,
                onSave: { name, content in
                    let result = center.saveMemoryDocumentResult(named: name, content: content)
                    lastActionMessage = result.message(for: name)
                    return result
                },
                onDelete: { name in
                    let result = center.deleteMemoryDocumentResult(named: name)
                    lastActionMessage = result.message(for: name)
                    return result
                }
            )
        }
        .sheet(item: $pendingDeletion) { request in
            SettingsDeletionPrompt(
                request: request,
                onCancel: { pendingDeletion = nil },
                onConfirm: { intent in executeDeletion(request, intent: intent) }
            )
        }
        .sheet(item: $markdownImportPreview) { preview in
            MemoryImportPreviewView(
                preview: preview,
                onCancel: {
                    markdownImportPreview = nil
                },
                onConfirm: { scope in
                    confirmMarkdownImport(preview, scope: scope)
                }
            )
        }
        .onChange(of: currentMemorySearchContext) { _, _ in
            clearMemorySearchResult()
        }
        .onChange(of: memorySearchText) { _, newText in
            // 预填检索（"忘掉…"）同步写入文字并检索；结果与当前文字一致时不清掉。
            if memorySearchKeyword != newText.trimmingCharacters(in: .whitespacesAndNewlines) {
                clearMemorySearchResult()
            }
            // 用户自己改了检索框，预填词作废。
            if let pending = center.pendingMemorySearchQuery, newText != pending {
                center.pendingMemorySearchQuery = nil
            }
        }
        .onChange(of: center.memoryFacts) { _, _ in
            clearMemorySearchResult()
            refreshActiveFactSources()
        }
        .onChange(of: center.pendingMemorySearchQuery) { _, _ in
            consumePendingMemorySearch()
        }
        .onAppear {
            refreshCandidateSources()
            refreshPendingProposalReviews()
            consumePendingMemorySearch()
        }
        .onChange(of: schedulerStore.tasks) { _, _ in
            refreshCandidateSources()
        }
    }

    private func refreshCandidateSources() {
        do {
            var states: [String: Bool] = [:]
            for source in SettingsCenter.BuiltInMemoryCandidateSource.allCases {
                states[source.rawValue] = try center.memoryCandidateSubmissionEnabled(for: source)
            }
            for task in schedulerStore.allTasks() where
                ScheduledMemoryCandidateSource.proposalText(command: task.command) != nil {
                let sourceID = ScheduledMemoryCandidateSource.sourceID(taskID: task.id)
                states[sourceID] = try center.scheduledMemoryCandidateSubmissionEnabled(
                    taskID: task.id, in: schedulerStore
                )
            }
            if let externalSources {
                for candidate in externalSources.externalMemoryCandidates {
                    states[candidate.memorySourceID] = try externalSources.memoryCandidateSubmissionEnabled(
                        for: candidate
                    ) && externalSources.boundMemoryScope(for: candidate) != nil
                }
            }
            candidateSourceEnabled = states
            candidateSourceError = nil
        } catch {
            candidateSourceEnabled = [:]
            candidateSourceError = "记忆来源授权读取失败（MEMORY-SOURCE-READ-FAILED）。请刷新设置后重试。"
        }
    }

    private func setCandidateSource(
        _ source: SettingsCenter.BuiltInMemoryCandidateSource,
        enabled: Bool
    ) {
        do {
            let authorization = try center.setMemoryCandidateSubmission(
                for: source,
                enabled: enabled
            )
            candidateSourceEnabled[source.rawValue] = authorization.canSubmit
            candidateSourceError = nil
            refreshPendingProposalReviews()
        } catch {
            refreshCandidateSources()
            candidateSourceError = "记忆来源授权更新失败（MEMORY-SOURCE-UPDATE-FAILED）。请刷新并重新确认当前来源授权。"
        }
    }

    private func setScheduledCandidateSource(taskID: UUID, enabled: Bool) {
        do {
            let authorization = try center.setScheduledMemoryCandidateSubmission(
                taskID: taskID, in: schedulerStore, enabled: enabled
            )
            candidateSourceEnabled[authorization.sourceID] = authorization.canSubmit
            candidateSourceError = nil
            refreshPendingProposalReviews()
        } catch {
            refreshCandidateSources()
            candidateSourceError = "定时来源授权更新失败（MEMORY-SCHEDULE-FAILED）。请刷新并重新确认当前来源授权。"
        }
    }

    private func setExternalCandidateSource(
        _ candidate: ExternalSessionAuthorizationComposition.ExternalMemoryCandidate,
        enabled: Bool
    ) {
        do {
            guard let externalSources else {
                throw ExternalMemoryProposalError.sourceUnavailable
            }
            let authorization = try externalSources.setMemoryCandidateSubmission(
                for: candidate, within: activeMemoryScope, enabled: enabled
            )
            candidateSourceEnabled[candidate.memorySourceID] = authorization.canSubmit
            candidateSourceError = nil
            refreshPendingProposalReviews()
        } catch {
            refreshCandidateSources()
            candidateSourceError = "外部记忆来源授权更新失败（MEMORY-EXTERNAL-SOURCE-FAILED）。请刷新并重新确认当前来源授权。"
        }
    }

    private func memoryFormatExample(_ example: String) -> some View {
        ScrollView(.vertical) {
            Text(example)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func refreshPendingProposalReviews() {
        refreshActiveFactSources()
        do {
            pendingProposalReviews = try center.pendingMemoryProposals()
            proposalReviewMessage = nil
        } catch {
            pendingProposalReviews = []
            proposalReviewMessage = "待审记忆读取失败（MEMORY-REVIEW-READ-FAILED）。请刷新待审列表后重试。"
        }
    }

    private func refreshActiveFactSources() {
        do {
            activeFactSources = try MemoryActiveFactSourceSnapshot(consumer: center.memoryProposalConsumer)
        } catch {
            // Keep the fact's captured origin visible, but never show a stale
            // enabled grant when the current authority cannot be read.
            activeFactSources = .unavailable
        }
    }

    private func approvePendingProposal(_ proposal: MemoryProposalEnvelope) {
        do {
            try center.approveDisplayedMemoryProposal(proposal)
            proposalReviewMessage = "已批准该条记忆提议。"
        } catch {
            proposalReviewMessage = "记忆提议未获批准（MEMORY-REVIEW-FAILED）。请刷新待审列表并重新检查来源。"
        }
        // Reload after the explicit click, including a rejected stale binding.
        // Rendering and refresh never call the approval consumer.
        do {
            pendingProposalReviews = try center.pendingMemoryProposals()
        } catch {
            pendingProposalReviews = []
            proposalReviewMessage = "待审记忆读取失败（MEMORY-REVIEW-READ-FAILED）。请刷新待审列表后重试。"
        }
    }

    private func rejectPendingProposal(_ proposal: MemoryProposalEnvelope) {
        do {
            try center.rejectDisplayedMemoryProposal(proposal)
            proposalReviewMessage = "已拒绝该条记忆提议，未写入记忆。"
        } catch {
            proposalReviewMessage = "记忆提议未被拒绝（MEMORY-REJECT-FAILED）。请刷新待审列表并重新检查来源。"
        }
        do {
            pendingProposalReviews = try center.pendingMemoryProposals()
        } catch {
            pendingProposalReviews = []
            proposalReviewMessage = "待审记忆读取失败（MEMORY-REVIEW-READ-FAILED）。请刷新待审列表后重试。"
        }
    }

    private func clearMemorySearchResult() {
        memorySearchResult = nil
        memorySearchKeyword = nil
        memorySearchContext = nil
        memorySearchGlobalMatch = false
        memorySearchError = nil
    }

    /// 对话里"忘掉…"留下的检索词：填入检索框、检索一次、清空待办。
    private func consumePendingMemorySearch() {
        // 搜索词保留到用户改动检索框或关闭设置为止：页面重建（@State 归零）后还能重新填上。
        guard let query = center.pendingMemorySearchQuery, memorySearchText != query else { return }
        memorySearchText = query
        runMemorySearch()
    }

    private func runMemorySearch() {
        let keyword = memorySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            clearMemorySearchResult()
            return
        }
        let context = currentMemorySearchContext
        let consumer = MemorySearchDisplayConsumer(search: MemorySearch(store: center.memoryStore))
        do {
            if let scope = context.scope {
                memorySearchResult = try consumer.retrieve(keyword: keyword, scope: .session(scope))
                memorySearchGlobalMatch = false
            } else {
                let result = try consumer.retrieveUserLevel(keyword: keyword,
                    trustedPrincipal: context.principal, files: center.memoryFileStore)
                memorySearchResult = result.facts
                memorySearchGlobalMatch = result.globalDocumentMatched
            }
            memorySearchKeyword = keyword
            memorySearchContext = context
            memorySearchError = nil
        } catch {
            clearMemorySearchResult()
            memorySearchError = SettingsFailureMessage.memoryAction(
                error, action: "记忆检索", code: "MEMORY-SEARCH-FAILED", hint: "请检查检索词后重试。")
        }
    }

    private func addFact() {
        let trimmed = newFactText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = center.addMemoryFactResult(trimmed, category: newCategory)
        if result == .added { newFactText = "" }
        lastActionMessage = result.message
    }

    /// MEMORY-05 编辑保存：写入走 SettingsCenter.editMemoryFact 唯一入口
    /// （store 追加修订并刷新 active 投影）；失败只报告原因，不改动原条目。
    private func saveFactEdit(id: String) {
        do {
            _ = try center.editMemoryFact(id: id, newText: editingFactText)
            editingFactID = nil
            lastActionMessage = "已更新该条记忆。"
        } catch {
            lastActionMessage = "记忆未能保存（MEMORY-SAVE-FAILED）。请确认内容非空、该条记忆仍存在，然后重试。"
        }
    }

    private func beginDeletion(
        preview: @escaping () throws -> OperationIntent,
        execute: @escaping (OperationIntent) throws -> DeletionReceipt,
        restarting expired: OperationIntent? = nil
    ) {
        expiredDeletion = nil
        do {
            pendingDeletion = try SettingsDeletionRequest(preview: preview, execute: execute, restarting: expired)
            lastActionMessage = nil
        } catch {
            lastActionMessage = expired == nil
                ? "删除未开始（DELETE-PREVIEW-FAILED）。请刷新列表并重新确认删除范围。"
                : "无法重新打开原确认。请回到原删除入口，重新选择并核对范围。"
        }
    }

    private func executeDeletion(_ request: SettingsDeletionRequest, intent: OperationIntent) {
        do {
            guard let execute = request.execute else { return }
            let receipt = try execute(intent)
            pendingDeletion = nil
            lastActionMessage = "已执行删除：\(receipt.affectedCount) 项。操作 ID：\(receipt.operationID.uuidString.prefix(8))。"
        } catch DeletionGateError.expired {
            pendingDeletion = nil
            lastActionMessage = nil
            expiredDeletion = request
        } catch {
            pendingDeletion = nil
            lastActionMessage = SettingsFailureMessage.deletion(error)
        }
    }

    // MARK: - P3-MEM-01 记忆导入/导出

    /// 导出当前记忆为 JSON 文件。保存面板关闭后，读取与写入在后台执行；
    /// SettingsCenter 只有在实际文件完成并读回校验后才返回成功。
    private func exportMemory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "memory-\(Int(Date().timeIntervalSince1970)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportMemoryFile(format: .json, to: url)
    }

    private func exportMemoryMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "memory-\(Int(Date().timeIntervalSince1970)).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportMemoryFile(format: .markdown, to: url)
    }

    private func exportMemoryFile(format: MemoryExportFormat, to url: URL) {
        Task { @MainActor in
            do {
                let receipt = try await center.exportMemoryFileAsync(format: format, to: url)
                // I2-MEMORY-PROJECTION: 导出的文件包含全部历史修订，计数用持久化
                // 总数而不是 Memory tab 的 active 投影，避免文案与文件内容不一致。
                lastActionMessage = "已导出 \(center.memoryFactTotalCount) 条记忆为 \(receipt.format.label)：\(receipt.url.lastPathComponent)（\(receipt.byteCount) B）"
            } catch {
                lastActionMessage = SettingsFailureMessage.memoryAction(
                    error, action: "记忆导出", code: "EXPORT-FAILED",
                    hint: "请检查目标目录与写入权限后重试。", writing: true)
            }
        }
    }

    /// 导入记忆 JSON 并合并：按文本去重（跳过与现有记忆重复的条目），不清空现有记忆。
    private func importMemory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let selectedScope = center.memoryScopeProvider?(), selectedScope.isValid else {
            lastActionMessage = "导入失败：当前会话没有有效的记忆作用域。"
            return
        }
        // R9 卡顿专项：Data(contentsOf:) + JSON 解码移后台线程（记忆 JSON 可达数百 KB），
        // 避免主线程同步 I/O 卡设置面板；合并写回仍在主线程。
        Task.detached(priority: .userInitiated) {
            let imported = (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([MemoryFact].self, from: $0) }
            await MainActor.run {
                guard let imported else {
                    lastActionMessage = "导入失败：无法读取或解析记忆 JSON"
                    return
                }
                do {
                    let result = try center.importMemoryFactsThrowing(
                        imported, expectedScope: selectedScope
                    )
                    lastActionMessage = result.added > 0 || result.skipped > 0
                        ? "已导入 \(result.added) 条记忆（跳过重复 \(result.skipped) 条）。"
                        : "导入完成：没有可导入的新记忆。"
                } catch MemoryProposalConsumerError.scopeMismatch {
                    lastActionMessage = "导入失败：读取文件期间会话或项目已切换，未写入记忆。"
                } catch MemoryProposalConsumerError.restoreConflict {
                    lastActionMessage = "导入失败：记忆文件与现有记录冲突；请核对目标会话、项目及文件版本，未写入记忆。"
                } catch {
                    lastActionMessage = SettingsFailureMessage.memoryAction(
                        error, action: "记忆导入", code: "IMPORT-FAILED",
                        hint: "请检查文件格式、当前授权和存储空间后重试。", writing: true)
                }
            }
        }
    }

    /// Read and parse Markdown off the main actor, then present an immutable
    /// content preview.  A generation token drops late results from an earlier
    /// file selection; no import write occurs on this path.
    private func importMemoryMarkdown() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let generation = UUID()
        markdownImportGeneration = generation
        let selectedURL = url
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: selectedURL)
                    let document = try MemoryMarkdownCodec.decode(data)
                    return (data, document)
                }.value
                guard !Task.isCancelled else { return }
                let preview = try center.makeMemoryMarkdownPreview(
                    result.0,
                    document: result.1,
                    sourceURL: selectedURL
                )
                guard markdownImportGeneration == generation else { return }
                markdownImportPreview = preview
                lastActionMessage = "已读取 \(preview.factCount) 条记忆，请核对内容和作用域。"
            } catch {
                guard markdownImportGeneration == generation else { return }
                lastActionMessage = SettingsFailureMessage.memoryAction(
                    error, action: "Markdown 导入预览", code: "MARKDOWN-PREVIEW-FAILED",
                    hint: "请检查文本格式与文件访问权限后重试。")
            }
        }
    }

    private func confirmMarkdownImport(
        _ preview: MemoryMarkdownImportPreview,
        scope: MemoryImportScope
    ) {
        markdownImportPreview = nil
        Task { @MainActor in
            do {
                let result = try await center.confirmMemoryMarkdownImportAsync(
                    preview,
                    selecting: scope
                )
                lastActionMessage = "已导入 \(result.added) 条 Markdown 记忆（跳过重复 \(result.skipped) 条）。"
            } catch {
                lastActionMessage = SettingsFailureMessage.memoryAction(
                    error, action: "Markdown 导入", code: "MARKDOWN-IMPORT-FAILED",
                    hint: "请刷新待导入内容并重新确认目标范围。", writing: true)
            }
        }
    }

    /// AJ-47：文件式记忆分区（GLOBAL.md / SOUL.md / 每日日志列表 + 查看/编辑）。
    @ViewBuilder
    private var fileMemorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件式记忆")
                .font(typography?.headline ?? .headline)
                .padding(.horizontal, 12)

            if center.memoryFiles.isEmpty {
                Text("暂无记忆文件（GLOBAL.md / SOUL.md / 每日日志）")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                List(center.memoryFiles) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.relativePath)
                                .font(typography?.body ?? .system(size: 12))
                            Text(file.preview)
                                .font(typography?.caption2 ?? .caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if file.kind == .global {
                                Text(!center.globalInstructionsEnabled
                                     ? "全局指令已关闭 · 文件 \(file.byteCount) B（不会注入）"
                                     : (file.isReadable
                                        ? "文件已加载 · 全文 \(file.byteCount) B；新回合最多使用 \(MemoryInjector.maxGlobalInstructionCharacters) 字"
                                        : "记忆读取失败，文件尚未加载"))
                                    .font(typography?.caption ?? .caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("settings.memory.global-load-status")
                            }
                            Text("\(file.modifiedAt, format: .dateTime.year().month().day().hour().minute()) · \(file.byteCount) B")
                                .font(typography?.caption2 ?? .caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("打开") {
                            openMemoryFile(file)
                        }
                        .buttonStyle(.borderless)
                        .font(typography?.caption ?? .system(size: 11))
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(.vertical, 4)
    }

    private func openMemoryFile(_ file: MemoryFileInfo) {
        switch center.prepareMemoryFileEditor(file) {
        case .ready(let relativePath, let content):
            fileEditorPresentation = MemoryFileEditorPresentation(
                fileName: relativePath, content: content
            )
        case .unreadable:
            lastActionMessage = "无法读取记忆文件，未打开编辑器，原文件未修改。"
        }
    }
}

/// A selected document and its bytes enter the sheet in one presentation update.
/// Each open gets a fresh identity so a previous document's draft is not reused.
struct MemoryFileEditorPresentation: Identifiable {
    let id = UUID()
    let fileName: String
    let content: String
}

/// AJ-47：文件式记忆编辑器（sheet 内查看/编辑/删除 GLOBAL.md / SOUL.md / 每日日志）。
struct MemoryFileEditorSheet: View {
    let fileName: String
    let onSave: (String, String) -> MemoryFileOperationResult
    let onDelete: (String) -> MemoryFileOperationResult

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State var editedContent: String
    @State private var operationMessage: String?

    init(
        presentation: MemoryFileEditorPresentation,
        onSave: @escaping (String, String) -> MemoryFileOperationResult,
        onDelete: @escaping (String) -> MemoryFileOperationResult
    ) {
        fileName = presentation.fileName
        self.onSave = onSave
        self.onDelete = onDelete
        _editedContent = State(initialValue: presentation.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(fileName)
                    .font(typography?.headline ?? .headline)
                Spacer()
                Button(role: .destructive) {
                    let result = onDelete(fileName)
                    if result.succeeded {
                        dismiss()
                    } else {
                        operationMessage = result.message(for: fileName)
                    }
                } label: {
                    Label { Text("删除") } icon: { MinisIconView(.delete, size: 14) }
                }
            }
            if fileName == "GLOBAL.md" {
                Button("导入内置默认指令") {
                    editedContent = MemoryInjector.defaultGlobalInstructions
                }
                .disabled(!editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editedContent.count > MemoryInjector.maxGlobalInstructionCharacters {
                    Text("已超过 \(MemoryInjector.maxGlobalInstructionCharacters) 字。保存会保留全文，新回合只使用前 \(MemoryInjector.maxGlobalInstructionCharacters) 字。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $editedContent)
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    let result = onSave(fileName, editedContent)
                    if result.succeeded {
                        dismiss()
                    } else {
                        operationMessage = result.message(for: fileName)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(width: 460, height: 360)
    }
}

// MARK: - 环境变量（Environment）

/// AJ-39：把普通环境变量（旧 key）转成模型供应商的请求。携带条目本身与
/// 自动建议（`EnvVarStore.providerSuggestion(for:)`），供 ProviderEditSheet 预填
/// Base URL / 模型 / 协议；建议为 nil 时仍可转换（用户手动填写）。
private struct ProviderConversionRequest: Identifiable {
    let id = UUID()
    let entry: EnvVarEntry
    let suggestion: ProviderSuggestion?
}

struct EnvironmentSettingsTab: View {
    @Bindable var center: SettingsCenter
    let metrics: SettingsLayoutMetrics
    var opensProviderConnection = false
    @State private var hasOpenedConnectionFlow = false
    @State private var showingAddSheet = false
    @State private var showingAddProviderSheet = false
    @State private var addProviderInitialPresetID: String?
    @State private var showingKeyImportSheet = false
    @State private var editingEntry: EnvVarEntry?
    @State private var editingProvider: EnvVarEntry?
    /// AJ-39：普通环境变量 → 模型供应商 的转换请求（携带自动建议供预填）。
    @State private var convertingProvider: ProviderConversionRequest?
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var lastImportMessage: String?
    /// SETTINGS-25：「从进程导入」的只读预览清单；确认（apply）前不落盘、
    /// 不写 Keychain、不改动任何内存条目。
    @State private var pendingImportPreview: EnvVarImportPreviewRequest?
    @State private var pendingDeletion: SettingsDeletionRequest?
    @State private var pendingProviderDeletion: SettingsDeletionRequest?
    @State private var expiredDeletion: SettingsDeletionRequest?
    /// K45：degraded provider 的一次性设置恢复路由；不携带或读取密钥。
    @State private var pendingRecoveryDestination: ProviderRecoveryDestination?
    /// Configuration-local recovery route. Unlike runtime readiness recovery,
    /// this is derived solely from the persisted metadata snapshot and points
    /// at the field that can repair the invalid configuration.
    @State private var pendingConfigurationRecovery: ProviderConfigurationRecoveryDestination?

    /// U5：普通环境变量（不含供应商记录，供应商在独立分区展示）。
    private var plainEnvEntries: [EnvVarEntry] {
        center.envEntries.filter { !$0.isProviderRecord }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 保持动作在同一工具栏，但允许窄窗横向滚动；状态消息独占一行，
            // 避免按钮压缩后与列表首行重叠或被裁切。
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Button {
                            showingAddProviderSheet = true
                        } label: {
                            Label { Text("新增供应商") } icon: { MinisIconView(.add, size: 14) }
                        }
                        .accessibilityIdentifier("settings.environment.add-provider")

                        Button {
                            showingKeyImportSheet = true
                        } label: {
                            Label { Text("导入 Key") } icon: { MinisIconView(.download, size: 14) }
                        }
                        .help("从环境变量、Claude Code 或 Codex 的配置文件导入 API Key（不导入登录令牌）")
                        .accessibilityIdentifier("settings.environment.import-key")

                        Button {
                            showingAddSheet = true
                        } label: {
                            Label { Text("新增变量") } icon: { MinisIconView(.add, size: 14) }
                        }
                        .accessibilityIdentifier("settings.environment.add-variable")

                        Button {
                            presentProcessEnvironmentImportPreview()
                        } label: {
                            Label { Text("导入本机环境变量") } icon: { MinisIconView(.download, size: 14) }
                        }
                        .accessibilityIdentifier("settings.environment.import-process")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if let lastImportMessage {
                    Text(lastImportMessage)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.environment.status")
                } else if let expired = expiredDeletion, let preview = expired.preview, let execute = expired.execute {
                    SettingsDeletionExpiredNotice(accessibilityPrefix: "settings.environment") {
                        beginDeletion(preview: preview, execute: execute, restarting: expired.intent)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ChatGPTAccountCard(center: center)

            Divider()

            if center.envEntries.isEmpty {
                ContentUnavailableView(
                    "暂无环境变量",
                    systemImage: "terminal",
                    description: Text("这里管理模型供应商与 API Key 等凭据引用；模型执行的命令使用登录 Shell 的环境，不读取这里的普通变量。")
                )
            } else {
                List {
                    if !center.providerRecords.isEmpty {
                        Section("模型供应商") {
                            ForEach(center.providerRecords) { provider in
                                providerRow(provider)
                            }
                        }
                    }
                    if !plainEnvEntries.isEmpty {
                        Section("其它环境变量（供应商之外）") {
                            ForEach(plainEnvEntries) { entry in
                                envRow(entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if opensProviderConnection, !hasOpenedConnectionFlow {
                hasOpenedConnectionFlow = true
                // 已有供应商（但没有可用模型）时直接打开它的编辑表单；没有才新增。
                let preferredID = ProviderConnectionRoute.preferredProviderID
                ProviderConnectionRoute.preferredProviderID = nil
                let preferredPresetID = ProviderConnectionRoute.preferredPresetID
                ProviderConnectionRoute.preferredPresetID = nil
                if let preferredPresetID {
                    // 模型选择里点了还没有记录的内置服务商：直接新增它（预选对应预设），不去编辑别家。
                    addProviderInitialPresetID = preferredPresetID.isEmpty ? nil : preferredPresetID
                    showingAddProviderSheet = true
                } else if preferredID == ChatGPTAccountSession.providerName {
                    // ChatGPT 账号没有 Key 可编辑：停在页面上方的登录卡，由用户重新登录。
                } else if let preferredID,
                   let preferred = center.providerRecords.first(where: {
                       $0.isProviderRecord && $0.name.caseInsensitiveCompare(preferredID) == .orderedSame
                   }) {
                    editingProvider = preferred
                } else if let repair = ChatStore.providerRecordNeedingRepair(
                    records: center.providerRecords, readiness: center.providerReadinessStore.records) {
                    editingProvider = repair
                } else {
                    showingAddProviderSheet = true
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            EnvVarEditSheet(existing: nil) { name, value, isSecret in
                if center.saveExplicitlyClassifiedEnvironmentVariable(name: name, value: value, isSecret: isSecret) {
                    lastImportMessage = "已保存 \(EnvVarStore.canonicalName(name))。"
                } else {
                    lastImportMessage = "保存失败：变量名不合法（需字母开头，仅含字母/数字/下划线）。"
                }
            }
        }
        .sheet(item: $editingEntry) { entry in
            EnvVarEditSheet(
                existing: entry,
                prefilledValue: center.environmentEditablePrefill(for: entry)
            ) { name, value, isSecret in
                if center.saveExplicitlyClassifiedEnvironmentVariable(name: name, value: value, isSecret: isSecret) {
                    lastImportMessage = "已更新 \(EnvVarStore.canonicalName(name))。"
                } else {
                    lastImportMessage = "保存失败：没有写入成功（钥匙串或磁盘写入出错），原值未改动。"
                }
            }
        }
        .sheet(isPresented: $showingKeyImportSheet) {
            ProviderKeyImportSheet(center: center) { summary in
                lastImportMessage = summary
            }
        }
        .sheet(isPresented: $showingAddProviderSheet, onDismiss: { addProviderInitialPresetID = nil }) {
            ProviderEditSheet(
                existing: nil,
                suggestion: nil,
                fromConnectionRoute: opensProviderConnection,
                initialPresetID: addProviderInitialPresetID,
                onRenamePreview: nil,
                onProbe: { name, apiKey, baseURL, protocolType in
                    await center.probeProviderDraft(
                        providerID: EnvVarStore.canonicalName(name),
                        apiKey: apiKey,
                        baseURL: baseURL,
                        protocolType: protocolType
                    )
                }
            ) { draft in
                guard !center.providerExists(named: draft.name) else {
                    lastImportMessage = "保存失败：已存在同名供应商「\(draft.name)」，不会覆盖已有的。请换个名字。"
                    return .failed(.duplicateName)
                }
                if center.saveProvider(name: draft.name, credential: draft.credential, baseURL: draft.baseURL,
                                       modelNames: draft.modelNames, protocolType: draft.protocolType, displayName: draft.displayName,
                                       modelContextWindows: draft.modelContextWindows) {
                    center.envStore.setModelModalityDeclarations(
                        name: draft.name, image: draft.modelImageInput, audio: draft.modelAudioInput)
                    center.envStore.setModelMaxOutputTokens(name: draft.name, tokens: draft.modelMaxOutputTokens)
                    center.envStore.setProviderNetworkOptions(name: draft.name, options: draft.networkOptions)
                    lastImportMessage = "已保存供应商 \(EnvVarStore.canonicalName(draft.name))（\(draft.modelNames.count) 个模型）。"
                    _ = center.startProviderReadinessAfterSave(forProviderName: draft.name)
                    return .saved
                } else {
                    lastImportMessage = center.providerSaveFailure?.message
                    return .failed(center.providerSaveFailure ?? .unknown)
                }
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(existing: provider, suggestion: nil, credentialSettings: center, initialFocus: recoveryFocus(for: provider), onRenamePreview: { old, new, draft in
                let intent = try center.previewProviderRename(from: old, to: new)
                let apiKey = draft.apiKey
                let baseURL = draft.baseURL
                let modelNames = draft.modelNames
                let protocolType = draft.protocolType
                let modelContextWindows = draft.modelContextWindows
                let modelImageInput = draft.modelImageInput
                let modelAudioInput = draft.modelAudioInput
                let modelMaxOutputTokens = draft.modelMaxOutputTokens
                let networkOptions = draft.networkOptions
                let envStore = center.envStore
                return SettingsDeletionRequest(intent: intent, executeAsync: { confirmedIntent in
                    let receipt = try await center.renameProviderAsync(
                        from: old,
                        to: new,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        modelNames: modelNames,
                        protocolType: protocolType,
                        modelContextWindows: modelContextWindows,
                        intent: confirmedIntent
                    )
                    envStore.setModelModalityDeclarations(
                        name: new, image: modelImageInput, audio: modelAudioInput)
                    envStore.setModelMaxOutputTokens(name: new, tokens: modelMaxOutputTokens)
                    envStore.setProviderNetworkOptions(name: new, options: networkOptions)
                    return receipt
                })
            }, onProbe: { name, apiKey, baseURL, protocolType in
                await center.probeProviderDraft(
                    providerID: EnvVarStore.canonicalName(name),
                    apiKey: apiKey,
                    baseURL: baseURL,
                    protocolType: protocolType
                )
            }) { draft in
                guard !center.providerExists(named: draft.name, excluding: provider.id) else {
                    lastImportMessage = "保存失败：已存在同名供应商「\(draft.name)」，不会覆盖已有的。请换个名字。"
                    return .failed(.duplicateName)
                }
                if center.saveProvider(name: draft.name, credential: draft.credential, baseURL: draft.baseURL,
                                       modelNames: draft.modelNames, protocolType: draft.protocolType, displayName: draft.displayName,
                                       modelContextWindows: draft.modelContextWindows) {
                    center.envStore.setModelModalityDeclarations(
                        name: draft.name, image: draft.modelImageInput, audio: draft.modelAudioInput)
                    center.envStore.setModelMaxOutputTokens(name: draft.name, tokens: draft.modelMaxOutputTokens)
                    center.envStore.setProviderNetworkOptions(name: draft.name, options: draft.networkOptions)
                    lastImportMessage = "已更新供应商 \(EnvVarStore.canonicalName(draft.name))。"
                    _ = center.startProviderReadinessAfterSave(forProviderName: draft.name)
                    return .saved
                } else {
                    lastImportMessage = center.providerSaveFailure?.message
                    return .failed(center.providerSaveFailure ?? .unknown)
                }
            }
        }
        .sheet(item: $convertingProvider) { request in
            // AJ-39：把普通环境变量（旧 key）转成模型供应商。旧值不读入
            // apiKey 字段，用户需显式输入新 Key；已知模式自动预填 URL/模型/协议。
            ProviderEditSheet(existing: request.entry, suggestion: request.suggestion, credentialSettings: center, onRenamePreview: { old, new, draft in
                let intent = try center.previewProviderRename(from: old, to: new)
                let apiKey = draft.apiKey
                let baseURL = draft.baseURL
                let modelNames = draft.modelNames
                let protocolType = draft.protocolType
                let modelContextWindows = draft.modelContextWindows
                let modelImageInput = draft.modelImageInput
                let modelAudioInput = draft.modelAudioInput
                let modelMaxOutputTokens = draft.modelMaxOutputTokens
                let networkOptions = draft.networkOptions
                let envStore = center.envStore
                return SettingsDeletionRequest(intent: intent, executeAsync: { confirmedIntent in
                    let receipt = try await center.renameProviderAsync(
                        from: old,
                        to: new,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        modelNames: modelNames,
                        protocolType: protocolType,
                        modelContextWindows: modelContextWindows,
                        intent: confirmedIntent
                    )
                    envStore.setModelModalityDeclarations(
                        name: new, image: modelImageInput, audio: modelAudioInput)
                    envStore.setModelMaxOutputTokens(name: new, tokens: modelMaxOutputTokens)
                    envStore.setProviderNetworkOptions(name: new, options: networkOptions)
                    return receipt
                })
            }, onProbe: { name, apiKey, baseURL, protocolType in
                await center.probeProviderDraft(
                    providerID: EnvVarStore.canonicalName(name),
                    apiKey: apiKey,
                    baseURL: baseURL,
                    protocolType: protocolType
                )
            }) { draft in
                guard !center.providerExists(named: draft.name) || draft.name.caseInsensitiveCompare(request.entry.name) == .orderedSame else {
                    lastImportMessage = "保存失败：已存在同名供应商「\(draft.name)」，不会覆盖已有的。请换个名字。"
                    return .failed(.duplicateName)
                }
                if center.saveProvider(name: draft.name, credential: draft.credential, baseURL: draft.baseURL,
                                       modelNames: draft.modelNames, protocolType: draft.protocolType, displayName: draft.displayName,
                                       modelContextWindows: draft.modelContextWindows) {
                    center.envStore.setModelModalityDeclarations(
                        name: draft.name, image: draft.modelImageInput, audio: draft.modelAudioInput)
                    center.envStore.setModelMaxOutputTokens(name: draft.name, tokens: draft.modelMaxOutputTokens)
                    center.envStore.setProviderNetworkOptions(name: draft.name, options: draft.networkOptions)
                    _ = center.startProviderReadinessAfterSave(forProviderName: draft.name)
                    lastImportMessage = "已将 \(EnvVarStore.canonicalName(draft.name)) 转为模型供应商（\(draft.modelNames.count) 个模型）。"
                    return .saved
                } else {
                    lastImportMessage = center.providerSaveFailure?.message
                    return .failed(center.providerSaveFailure ?? .unknown)
                }
            }
        }
        .sheet(item: $pendingImportPreview) { request in
            EnvVarProcessImportPreviewSheet(items: request.items) { selectedNames in
                // SETTINGS-25：唯一写入口=预览表「确认」。apply 只持久化被
                // 勾选名称，add-only（绝不覆盖既有条目）语义由 EnvVarStore 保证。
                let outcomes = center.envStore.applyProcessEnvironmentImport(selectedNames: selectedNames)
                let imported = outcomes.values.filter { $0 == .imported }.count
                center.lastImportCount = imported
                center.reloadEnv()
                lastImportMessage = imported > 0
                    ? "已从进程环境导入 \(imported) 个变量（仅新增，不覆盖）。"
                    : "未导入任何变量（仅新增，不覆盖）。"
            }
        }
        .alert("删除模型供应商？", isPresented: Binding(
            get: { pendingProviderDeletion != nil },
            set: { if !$0 { pendingProviderDeletion = nil } }
        ), presenting: pendingProviderDeletion) { request in
            Button("取消", role: .cancel) { pendingProviderDeletion = nil }
                .accessibilityIdentifier("settings.environment.provider-delete.cancel")
            Button("删除", role: .destructive) {
                guard pendingProviderDeletion?.id == request.id else { return }
                pendingProviderDeletion = nil
                executeDeletion(request, intent: request.intent
                    .withFirstConfirmation("provider-delete-alert")
                    .withSecondConfirmation(SettingsDeletionPresentation(intent: request.intent).secondPhrase))
            }
            .accessibilityIdentifier("settings.environment.provider-delete.confirm")
        } message: { request in
            Text("\(request.intent.targetName)将从配置中移除，其密钥链副本也会删除。你可以重新添加供应商并输入 API Key。")
        }
        .sheet(item: $pendingDeletion) { request in
            SettingsDeletionPrompt(
                request: request,
                onCancel: { pendingDeletion = nil },
                onConfirm: { intent in executeDeletion(request, intent: intent) }
            )
        }
        .onChange(of: editingProvider) { _, provider in
            if provider == nil {
                pendingRecoveryDestination = nil
                pendingConfigurationRecovery = nil
            }
        }
    }

    // MARK: SETTINGS-25 从进程导入（先只读预览，确认后才写入）

    /// SETTINGS-25：按下「从进程导入」不再静默批量导入，而是先调用
    /// `EnvVarStore.processEnvironmentImportPreview()` 做只读预览（不落盘、
    /// 不写 Keychain、不改动内存条目）。没有可新增的变量时仅提示，与旧
    /// 文案一致；有候选时弹出确认清单，用户显式确认前不发生任何写入。
    private func presentProcessEnvironmentImportPreview() {
        let items = center.envStore.processEnvironmentImportPreview()
        guard items.contains(where: \.isSelectableForImport) else {
            lastImportMessage = "进程环境没有新变量可导入。"
            return
        }
        pendingImportPreview = EnvVarImportPreviewRequest(items: items)
    }

    // MARK: U5 模型供应商行（名称 + 协议徽章 + Base URL + 模型列表 + 操作）

    @ViewBuilder
    private func providerRow(_ provider: EnvVarEntry) -> some View {
        let report = center.providerReadinessReport(for: provider)
        let localSummary = center.providerLocalReadinessSummary(for: provider)
        let configuration = SettingsProviderConfigurationSnapshot(entry: provider)
        let providerAXComponent = settingsAXComponent(provider.name)
        let providerAXName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名供应商"
            : ProviderDisplayLabel.resolve(record: provider)
        let builtInType = ChatStore.chatProviderTypes.first {
            $0.rawValue.caseInsensitiveCompare(provider.name) == .orderedSame
        }
        let isBoundBuiltIn = builtInType.map {
            ChatStore.BuiltinReadinessBinding.record(for: $0, in: center.providerRecords)?.id == provider.id
        } ?? false

        Group {
            if metrics.environmentRowLayout == .stacked {
                VStack(alignment: .leading, spacing: 8) {
                    providerDetails(
                        provider,
                        report: report,
                        localSummary: localSummary,
                        configuration: configuration,
                        isUnboundBuiltIn: builtInType != nil && !isBoundBuiltIn
                    )
                    providerActionArea(
                        provider,
                        configuration: configuration,
                        providerAXComponent: providerAXComponent,
                        providerAXName: providerAXName,
                        builtInType: builtInType,
                        isBoundBuiltIn: isBoundBuiltIn
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    providerDetails(
                        provider,
                        report: report,
                        localSummary: localSummary,
                        configuration: configuration,
                        isUnboundBuiltIn: builtInType != nil && !isBoundBuiltIn
                    )
                    Spacer(minLength: 0)
                    providerActionArea(
                        provider,
                        configuration: configuration,
                        providerAXComponent: providerAXComponent,
                        providerAXName: providerAXName,
                        builtInType: builtInType,
                        isBoundBuiltIn: isBoundBuiltIn
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.environment.provider.\(providerAXComponent)")
    }

    @ViewBuilder
    private func providerDetails(
        _ provider: EnvVarEntry,
        report: SettingsProviderReadinessReport?,
        localSummary: ProviderLocalReadinessSummary,
        configuration: SettingsProviderConfigurationSnapshot,
        isUnboundBuiltIn: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SettingsEnvironmentIdentityHeader(
                name: ProviderDisplayLabel.resolve(record: provider),
                nameFont: typography?.monospaced ?? .system(.body, design: .monospaced)
            ) {
                HStack(spacing: 6) {
                    Text(provider.protocolType.displayName)
                        .font(typography?.caption2 ?? .caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((theme?.aj38.accent.swiftUIColor ?? .blue).opacity(0.15)))
                        .foregroundStyle(theme?.aj38.accent.swiftUIColor ?? .blue)
                    Text("密钥")
                        .font(typography?.caption2 ?? .caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((theme?.statusWarning ?? .orange).opacity(0.2)))
                        .foregroundStyle(theme?.statusWarning ?? .orange)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Text(providerCredentialReferenceLabel(for: provider))
                .font(typography?.caption2 ?? .system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(metrics.environmentValueLineLimit)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.provider.credential-reference")
                .help(providerCredentialReferenceLabel(for: provider))
            HStack(spacing: 5) {
                MinisIconView(configuration.isValid ? .success : .warning, size: 16)
                    .foregroundPalette(configuration.isValid ? (theme?.statusSuccess ?? .green) : (theme?.statusWarning ?? .orange))
                Text(configuration.statusLabel)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(configuration.isValid ? .secondary : (theme?.statusWarning ?? .orange))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("供应商配置状态")
            .accessibilityValue(configuration.statusMessage)
            .accessibilityIdentifier("settings.provider.configuration-status")
            if !configuration.isValid {
                Text(configuration.statusMessage)
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.provider.configuration-status.message")
            }
            if let baseURL = provider.baseURL, !baseURL.isEmpty {
                Text(baseURL)
                    .font(typography?.caption2 ?? .system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(metrics.environmentValueLineLimit)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(baseURL)
            }
            if isUnboundBuiltIn {
                Text("内置模型就绪需要官方地址、匹配协议和已保存的内置模型；当前配置不可用于内置发送。")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(theme?.statusWarning ?? .orange)
            }
            if !provider.modelNames.isEmpty {
                Text("模型：\(provider.modelNames.joined(separator: "、"))")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(metrics.environmentValueLineLimit)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(provider.modelNames.joined(separator: "、"))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("逐个模型测试")
                            .font((typography?.caption ?? .caption).weight(.medium))
                        if provider.modelNames.count > 1 {
                            Button("检查全部") {
                                _ = center.startCheckAllProviderModels(forProviderName: provider.name)
                            }
                            .buttonStyle(.borderless)
                            .font(typography?.caption ?? .caption)
                            .accessibilityIdentifier("settings.provider.model.readiness.check-all.\(provider.name)")
                            .help("依次检查该供应商的全部模型（同时最多 3 个）")
                        }
                    }
                    ForEach(provider.modelNames, id: \.self) { modelID in
                        savedModelReadinessRow(provider: provider, modelID: modelID)
                    }
                }
                .padding(.top, 2)
            }
            if let report {
                ProviderReadinessReportView(report: report)
            }
            if let message = center.providerReadinessLocalControlMessage(for: provider) {
                Text(message)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.provider.readiness.local-control")
            }
            ProviderLocalReadinessSummaryView(summary: localSummary) {
                performProviderLocalSummaryAction(localSummary, for: provider)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.details.\(settingsAXComponent(provider.name))")
    }

    @ViewBuilder
    private func providerActionArea(
        _ provider: EnvVarEntry,
        configuration: SettingsProviderConfigurationSnapshot,
        providerAXComponent: String,
        providerAXName: String,
        builtInType: ProviderType?,
        isBoundBuiltIn: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                providerReadinessButton(provider, providerAXName: providerAXName, builtInType: builtInType, isBoundBuiltIn: isBoundBuiltIn)
                providerRecoveryButton(provider, configuration: configuration)
                entryActionButtons(for: provider, axComponent: providerAXComponent,
                                   onEdit: { editingProvider = provider })
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 8) {
                providerReadinessButton(provider, providerAXName: providerAXName, builtInType: builtInType, isBoundBuiltIn: isBoundBuiltIn)
                providerRecoveryButton(provider, configuration: configuration)
                entryActionButtons(for: provider, axComponent: providerAXComponent,
                                   onEdit: { editingProvider = provider })
            }
        }
        .frame(width: metrics.environmentActionColumnWidth, alignment: .trailing)
        .frame(maxWidth: metrics.environmentRowLayout == .stacked ? .infinity : nil,
               alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.actions.\(providerAXComponent)")
    }

    private func providerReadinessButton(
        _ provider: EnvVarEntry, providerAXName: String,
        builtInType: ProviderType?, isBoundBuiltIn: Bool
    ) -> some View {
        Button {
            if let lane = center.mm01FieldLane, lane.requiresOwnedOutboundAudit {
                guard builtInType == nil,
                      provider.name == DeepSeekProviderContract.apiKeyEnvironmentVariable else { return }
                do {
                    let ticket = try lane.beginOwnedUIAction(.providerReadinessButton)
                    Task {
                        await OwnedMMOutboundContext.$action.withValue(ticket) {
                            _ = await center.checkProviderReadiness(forProviderName: provider.name)
                        }
                    }
                } catch { return } // ledger emitted a fixed refusal; never retry
            } else {
            Task {
                if let builtInType {
                    _ = await center.checkBuiltInProviderReadiness(for: builtInType)
                } else {
                    _ = await center.checkProviderReadiness(forProviderName: provider.name)
                }
            }
            }
        } label: {
            Label { Text("检查就绪") } icon: { MinisIconView(.success, size: 14) }
        }
        .buttonStyle(.borderless)
        .disabled(center.isCheckingProviderReadiness || (builtInType != nil && !isBoundBuiltIn))
        .accessibilityLabel("检查 \(providerAXName) 就绪状态")
        .accessibilityHint("区分配置、可达、鉴权、模型发现和逐模型最小请求")
        .accessibilityIdentifier("settings.provider.readiness.check")
        .accessibilityValue(center.isCheckingProviderReadiness ? "进行中" : "可操作")
        .help("检查服务商配置与模型就绪状态")
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func providerRecoveryButton(
        _ provider: EnvVarEntry, configuration: SettingsProviderConfigurationSnapshot
    ) -> some View {
        if !configuration.isValid {
            Button {
                pendingConfigurationRecovery = ProviderConfigurationRecoveryDestination(
                    providerID: provider.name,
                    focus: configurationRecoveryFocus(for: configuration.state)
                )
                editingProvider = provider
            } label: {
                Label { Text("修复配置") } icon: { MinisIconView(.edit, size: 14) }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("修复 \(provider.name) 配置")
            .accessibilityHint(configuration.statusMessage)
            .accessibilityIdentifier("settings.provider.configuration-recovery")
            .accessibilityValue(configuration.statusLabel)
            .fixedSize(horizontal: true, vertical: false)
        } else if let destination = center.providerRecoveryDestination(for: provider.name) {
            Button {
                pendingRecoveryDestination = destination
                editingProvider = provider
            } label: {
                Label { Text("修复 API Key") } icon: { MinisIconView(.edit, size: 14) }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("修复 \(provider.name) API Key")
            .accessibilityHint("打开该供应商编辑页并聚焦 API Key 输入框")
            .accessibilityIdentifier("settings.provider.recovery")
            .accessibilityValue(destination.focus.rawValue)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func performProviderLocalSummaryAction(
        _ summary: ProviderLocalReadinessSummary,
        for provider: EnvVarEntry
    ) {
        switch summary.action {
        case .replaceAPIKey:
            editingProvider = provider
        case .checkReadiness, .retryReadiness:
            Task {
                if let type = ChatStore.chatProviderTypes.first(where: {
                    $0.rawValue.caseInsensitiveCompare(provider.name) == .orderedSame
                }) {
                    _ = await center.checkBuiltInProviderReadiness(for: type)
                } else {
                    _ = await center.checkProviderReadiness(forProviderName: provider.name)
                }
            }
        case .none:
            break
        }
    }

    private func recoveryFocus(for provider: EnvVarEntry) -> ProviderEditFocus? {
        if let configurationRecovery = pendingConfigurationRecovery,
           configurationRecovery.providerID.caseInsensitiveCompare(provider.name) == .orderedSame {
            return configurationRecovery.focus
        }
        guard let destination = pendingRecoveryDestination,
              destination.providerID.caseInsensitiveCompare(provider.name) == .orderedSame else {
            return nil
        }
        switch destination.focus {
        case .apiKey:
            return .apiKey
        }
    }

    private func configurationRecoveryFocus(
        for state: SettingsProviderConfigurationState
    ) -> ProviderEditFocus {
        switch state {
        case .missingCredentialReference:
            return .apiKey
        case .missingModel:
            return .modelFirst
        case .missingBaseURL, .invalidBaseURL, .unsupportedProtocol, .factoryUnavailable:
            return .baseURL
        case .ready:
            return .name
        }
    }

    @ViewBuilder
    private func savedModelReadinessRow(
        provider: EnvVarEntry,
        modelID rawModelID: String
    ) -> some View {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = center.providerModelReadiness(for: provider, modelID: modelID)
        let isLoading = state?.status == .loading
        let actionTitle = state?.status == .failed ? "重试" : "测试连接"
        let actionIcon = state?.status == .failed ? "arrow.clockwise" : "checkmark.shield"
        let isBoundBuiltIn = ChatStore.chatProviderTypes.contains {
            $0.rawValue.caseInsensitiveCompare(provider.name) == .orderedSame
                && ChatStore.BuiltinReadinessBinding.route(for: $0) != nil
        }

        Group {
            if metrics.environmentRowLayout == .stacked {
                VStack(alignment: .leading, spacing: 4) {
                    modelReadinessIdentity(
                        modelID: modelID,
                        status: state?.status
                    )
                    HStack(spacing: 6) {
                        modelReadinessResult(state)
                        Spacer(minLength: 4)
                        modelReadinessAction(
                            provider: provider,
                            modelID: modelID,
                            isLoading: isLoading,
                            actionTitle: actionTitle,
                            actionIcon: actionIcon,
                            isBoundBuiltIn: isBoundBuiltIn
                        )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    modelReadinessIdentity(
                        modelID: modelID,
                        status: state?.status
                    )
                    modelReadinessResult(state)
                    Spacer(minLength: 4)
                    modelReadinessAction(
                        provider: provider,
                        modelID: modelID,
                        isLoading: isLoading,
                        actionTitle: actionTitle,
                        actionIcon: actionIcon,
                        isBoundBuiltIn: isBoundBuiltIn
                    )
                }
            }
        }
        .frame(
            maxWidth: metrics.environmentRowLayout == .stacked ? .infinity : nil,
            alignment: .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型 \(modelID) 就绪状态")
        .accessibilityValue(modelStatusName(state?.status))
        .accessibilityIdentifier(
            "settings.provider.model.readiness.\(provider.name).\(modelID)"
        )
    }

    @ViewBuilder
    private func modelReadinessIdentity(
        modelID: String,
        status: ProviderReadinessStageStatus?
    ) -> some View {
        let stateIcon = modelStatusIcon(status)
        HStack(spacing: 6) {
            Image(systemName: stateIcon)
                .accessibilityHidden(true)
                .foregroundStyle(modelStatusColor(status))
            Text(modelID.isEmpty ? "未命名模型" : modelID)
                .font(typography?.caption2 ?? .system(.caption2, design: .monospaced))
                .lineLimit(metrics.environmentValueLineLimit)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .help(modelID)
        }
    }

    @ViewBuilder
    private func modelReadinessResult(
        _ state: ProviderModelReadiness?
    ) -> some View {
        if let state, !state.redactedResult.isEmpty {
            Text(ProviderStatusTextProjection.project(state.redactedResult))
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(metrics.environmentValueLineLimit)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(ProviderStatusTextProjection.project(state.redactedResult))
        }
    }

    @ViewBuilder
    private func modelReadinessAction(
        provider: EnvVarEntry,
        modelID: String,
        isLoading: Bool,
        actionTitle: String,
        actionIcon: String,
        isBoundBuiltIn: Bool
    ) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在检查 \(modelID) 的就绪状态")
            Button {
                center.cancelProviderModelReadiness(
                    forProviderName: provider.name,
                    modelID: modelID
                )
            } label: {
                Label { Text("取消") } icon: { MinisIconView(.cancel, size: 14) }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("取消 \(modelID) 的就绪检查")
            .accessibilityHint("停止当前模型的检查")
            .accessibilityIdentifier(
                "settings.provider.model.readiness.cancel.\(provider.name).\(modelID)"
            )
            .help("取消 \(modelID) 的就绪检查")
        } else {
            Button {
                _ = center.startProviderModelReadiness(
                    forProviderName: provider.name,
                    modelID: modelID
                )
            } label: {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.borderless)
            .disabled(isBoundBuiltIn)
            .accessibilityLabel("\(actionTitle) \(modelID) 的就绪检查")
            .accessibilityIdentifier(
                "settings.provider.model.readiness.check.\(provider.name).\(modelID)"
            )
            .help(isBoundBuiltIn ? "内置模型请使用供应商级检查就绪" : "\(actionTitle) \(modelID) 的就绪检查")
        }
    }

    private func modelStatusIcon(_ status: ProviderReadinessStageStatus?) -> String {
        switch status {
        case .loading:
            return "hourglass"
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "slash.circle"
        case .notRun, nil:
            return "circle"
        }
    }

    private func modelStatusColor(_ status: ProviderReadinessStageStatus?) -> Color {
        switch status {
        case .passed:
            return theme?.statusSuccess ?? .green
        case .failed:
            return theme?.statusDanger ?? .red
        case .cancelled:
            return theme?.statusWarning ?? .orange
        case .loading, .notRun, nil:
            return .secondary
        }
    }

    private func modelStatusName(_ status: ProviderReadinessStageStatus?) -> String {
        switch status {
        case .loading:
            return "检查中"
        case .passed:
            return "通过"
        case .failed:
            return "失败，可重试"
        case .cancelled:
            return "已取消"
        case .notRun, nil:
            return "未检查"
        }
    }

    @ViewBuilder
    private func envRow(_ entry: EnvVarEntry) -> some View {
        let component = settingsAXComponent(entry.name)
        Group {
            if metrics.environmentRowLayout == .stacked {
                VStack(alignment: .leading, spacing: 8) {
                    envDetails(entry)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        envConversionButton(entry)
                        entryActionButtons(for: entry, onEdit: { editingEntry = entry })
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: metrics.environmentActionColumnWidth, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    envDetails(entry)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        envConversionButton(entry)
                        entryActionButtons(for: entry, onEdit: { editingEntry = entry })
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: metrics.environmentActionColumnWidth, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.environment.row.\(component)")
    }

    @ViewBuilder
    private func envDetails(_ entry: EnvVarEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SettingsEnvironmentIdentityHeader(
                name: entry.name,
                nameFont: typography?.monospaced ?? .system(.body, design: .monospaced)
            ) {
                HStack(spacing: 6) {
                    if entry.isSecret {
                        Text("密钥")
                            .font(typography?.caption2 ?? .caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((theme?.statusWarning ?? .orange).opacity(0.2)))
                            .foregroundStyle(theme?.statusWarning ?? .orange)
                    }
                    if let suggestion = EnvVarStore.providerSuggestion(for: entry.name) {
                        // AJ-39：已知供应商 key 模式 → 提示可一键转为模型供应商。
                        Text(suggestion.providerLabel)
                            .font(typography?.caption2 ?? .caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((theme?.statusSuccess ?? .green).opacity(0.15)))
                            .foregroundStyle(theme?.statusSuccess ?? .green)
                            .help("可转为模型供应商（已预填 \(suggestion.providerLabel) 配置）")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Text(providerCredentialReferenceLabel(for: entry))
                .font(typography?.caption2 ?? .system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(metrics.environmentValueLineLimit)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .help(providerCredentialReferenceLabel(for: entry))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.environment.details.\(settingsAXComponent(entry.name))")
    }

    /// AJ-39：普通环境变量 → 模型供应商转换入口（旧值不读入，需显式
    /// 输入新 Key；补填 Base URL / 模型 / 协议）。已知模式自动建议预填。
    private func envConversionButton(_ entry: EnvVarEntry) -> some View {
        let component = settingsAXComponent(entry.name)
        return Button {
            convertingProvider = ProviderConversionRequest(
                entry: entry,
                suggestion: EnvVarStore.providerSuggestion(for: entry.name)
            )
        } label: {
            MinisIconView(.externalLink, size: 12)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("将变量 \(entry.name) 转为模型供应商")
        .accessibilityHint("打开编辑器并要求显式输入新的凭证")
        .accessibilityIdentifier("settings.environment.convert.\(component)")
        .help("转为模型供应商（编辑 Base URL / 模型 / 协议）")
    }

    /// 行级操作按钮（显示/隐藏密钥、编辑、删除）——环境变量行与供应商行共用。
    private func entryActionButtons(
        for entry: EnvVarEntry,
        axComponent: String? = nil,
        onEdit: @escaping () -> Void
    ) -> some View {
        let component = axComponent ?? settingsAXComponent(entry.name)
        let entryKind = entry.isProviderRecord ? "供应商" : "变量"
        return HStack(spacing: 10) {
            Button {
                onEdit()
            } label: {
                MinisIconView(.edit, size: 12)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑\(entryKind) \(entry.name)")
            .accessibilityIdentifier("settings.environment.edit.\(component)")
            .help("编辑\(entryKind)")

            Button(role: .destructive) {
                let name = entry.name
                if entry.isProviderRecord {
                    beginDeletion(
                        preview: { try center.previewProviderDeletion(name: name) },
                        execute: { try center.deleteProvider(name: name, intent: $0) }
                    )
                } else {
                    beginDeletion(
                        preview: {
                            guard center.envStore.entry(name: name)?.isProviderRecord == false else {
                                throw SettingsDeletionError.notFound(name)
                            }
                            return try center.previewEnvVarDeletion(name: name)
                        },
                        execute: { try center.deleteEnvVar(name: name, intent: $0) }
                    )
                }
            } label: {
                MinisIconView(.delete, size: 12)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除\(entryKind) \(entry.name)")
            .accessibilityIdentifier("settings.environment.delete.\(component)")
            .help("删除\(entryKind)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.environment.actions.\(component)")
    }

    private func beginDeletion(
        preview: @escaping () throws -> OperationIntent,
        execute: @escaping (OperationIntent) throws -> DeletionReceipt,
        restarting expired: OperationIntent? = nil
    ) {
        expiredDeletion = nil
        do {
            let request = try SettingsDeletionRequest(preview: preview, execute: execute, restarting: expired)
            if request.intent.operationType == .delete && request.intent.targetType == "provider" {
                pendingProviderDeletion = request
            } else {
                pendingDeletion = request
            }
            lastImportMessage = nil
        } catch {
            lastImportMessage = expired == nil
                ? "删除未开始（DELETE-PREVIEW-FAILED）。请刷新列表并重新确认删除范围。"
                : "无法重新打开原确认。请回到原删除入口，重新选择并核对范围。"
        }
    }

    private func executeDeletion(_ request: SettingsDeletionRequest, intent: OperationIntent) {
        do {
            guard let execute = request.execute else { return }
            let receipt = try execute(intent)
            pendingDeletion = nil
            lastImportMessage = "已执行删除：\(receipt.affectedCount) 项。操作 ID：\(receipt.operationID.uuidString.prefix(8))。"
        } catch DeletionGateError.expired {
            pendingDeletion = nil
            lastImportMessage = nil
            expiredDeletion = request
        } catch {
            pendingDeletion = nil
            lastImportMessage = SettingsFailureMessage.deletion(error)
        }
    }

    private func providerCredentialReferenceLabel(for entry: EnvVarEntry) -> String {
        center.environmentDisplayValue(for: entry)
    }

    private func settingsAXComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = (trimmed.isEmpty ? "entry" : trimmed).unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let component = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return component.isEmpty ? "entry" : String(component.prefix(64))
    }
}

private struct ProviderReadinessReportView: View {
    @Environment(\.themeTokens) private var theme
    let report: SettingsProviderReadinessReport
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stateIcon)
                    .accessibilityHidden(true)
                    .foregroundStyle(stateColor)
                Text("就绪状态：\(stateName)")
                    .fontWeight(.medium)
            }

            HStack(spacing: 8) {
                stageLabel("配置", report.configuration)
                stageLabel("可达", report.reachability)
                stageLabel("鉴权", report.authentication)
                stageLabel("模型发现", report.modelDiscovery)
            }
            .font(typography?.caption2 ?? .caption2)
            .foregroundStyle(.secondary)

            if !report.modelChecks.isEmpty {
                Text("供应商级模型摘要：\(report.modelChecks.count) 项（逐个模型测试 不受此检查替代）")
                    .font(typography?.caption2 ?? .caption2)
                    .foregroundStyle(.secondary)
            }

            if !report.redactedResult.isEmpty {
                Text(ProviderStatusTextProjection.project(report.redactedResult))
                    .font(typography?.caption2 ?? .system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型服务商测试结果")
        .accessibilityIdentifier("settings.provider.readiness")
    }

    private func stageLabel(
        _ name: String,
        _ stage: ProviderReadinessStage
    ) -> some View {
        Label {
            Text("\(name)：\(stageName(stage.status))")
        } icon: {
            MinisIconView(stage.status == .passed ? .check : .status, size: 14)
                .foregroundPalette(stage.status == .failed ? (theme?.statusDanger ?? AppStatusColor.danger) : Color.secondary)
        }
    }

    private func stageName(_ status: ProviderReadinessStageStatus) -> String {
        switch status {
        case .notRun: return "未执行"
        case .loading: return "检查中"
        case .passed: return "通过"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var stateName: String {
        switch report.state {
        case .mock: return "Mock"
        case .local: return "本地"
        case .live: return "Live"
        case .beta: return "Beta"
        case .blocked: return "阻断"
        case .unverified: return "未验证"
        }
    }

    private var stateIcon: String {
        switch report.state {
        case .mock, .local: return "checkmark.shield.fill"
        case .live: return "bolt.horizontal.circle.fill"
        case .beta: return "exclamationmark.shield.fill"
        case .blocked: return "xmark.shield.fill"
        case .unverified: return "questionmark.diamond.fill"
        }
    }

    private var stateColor: Color {
        switch report.state {
        case .mock, .local: return theme?.statusSuccess ?? AppStatusColor.success
        case .live: return theme?.statusInfo ?? AppStatusColor.info
        case .beta: return theme?.statusWarning ?? AppStatusColor.warning
        case .blocked: return theme?.statusDanger ?? AppStatusColor.danger
        case .unverified: return .secondary
        }
    }
}

/// 环境变量新增/编辑表单（编辑时名称只读，避免误建新条目）。
private enum EnvVarEditFocus: Hashable {
    case name
    case value
}

private struct EnvVarEditSheet: View {
    let existing: EnvVarEntry?
    var prefilledValue = ""
    let onSave: (_ name: String, _ value: String, _ isSecret: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var name = ""
    @State private var value = ""
    @State private var isSecret = false
    @FocusState private var focusedField: EnvVarEditFocus?
    @State private var didInitializeDraft = false

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.isEmpty
            && (isEditing || !EnvVarStore.canonicalName(name).isEmpty)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑环境变量" : "新增环境变量")
                .font(typography?.headline ?? .headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                if isEditing {
                    Text(existing!.name)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                } else {
                    TextField("如 OPENAI_API_KEY", text: $name)
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .value }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("值").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                Group {
                    if isSecret {
                        SecureField("变量值", text: $value)
                    } else {
                        TextField("变量值", text: $value)
                    }
                }
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .value)
                .onSubmit { submitIfValid() }
            }

            Toggle("敏感值（日志/模型上下文脱敏）", isOn: $isSecret)
            Text("保存为非敏感后，值可在列表及相关命令中显示。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    focusedField = nil
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                Button(isSecret ? "保存为敏感" : "保存为非敏感") {
                    submitIfValid()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity)
        .frame(minHeight: 220, idealHeight: 300, maxHeight: .infinity)
        .onAppear {
            guard !didInitializeDraft else { return }
            didInitializeDraft = true
            if let existing {
                name = existing.name
                value = prefilledValue
                isSecret = existing.isSecret
            }
            Task { @MainActor in
                await Task.yield()
                focusedField = isEditing ? .value : .name
            }
        }
        .onDisappear {
            focusedField = nil
        }
    }

    private func submitIfValid() {
        guard canSave else { return }
        focusedField = nil
        onSave(name, value, isSecret)
        dismiss()
    }
}

// MARK: - SETTINGS-25 从进程导入：只读预览与逐项确认
//
// 预览类型（EnvVarProcessImportPreviewItem 等）由 MinisCore EnvVarStore
// 拥有；本节只做呈现与确认门，不重新实现任何比对或写入语义。

/// SETTINGS-25：承载「从进程导入」的只读预览清单，供 `.sheet(item:)`
/// 呈现；本身不含任何写语义。
private struct EnvVarImportPreviewRequest: Identifiable {
    let id = UUID()
    let items: [EnvVarStore.EnvVarProcessImportPreviewItem]
}

/// SETTINGS-25：「从进程导入」确认表。
///
/// 只渲染 `EnvVarStore.processEnvironmentImportPreview()` 的比对结果：
/// add 类默认勾选、可逐项取消；update/skip 类只展示原因且永不进入
/// apply。用户点「确认导入」才会回调被勾选名称，由调用方执行显式
/// apply（add-only，绝不覆盖既有条目）；取消则直接关闭，零副作用。
/// 值列透传预览的 `valueDisplay`：secret 类恒为占位符，明文不经此处。
private struct EnvVarProcessImportPreviewSheet: View {
    let items: [EnvVarStore.EnvVarProcessImportPreviewItem]
    let onConfirm: (_ selectedNames: [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var selection: EnvVarStore.EnvVarProcessImportSelection

    init(
        items: [EnvVarStore.EnvVarProcessImportPreviewItem],
        onConfirm: @escaping (_ selectedNames: [String]) -> Void
    ) {
        self.items = items
        self.onConfirm = onConfirm
        _selection = State(initialValue: EnvVarStore.EnvVarProcessImportSelection(items: items))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text("导入本机环境变量预览")
                    .font(typography?.headline ?? .headline)
                Text("仅新增，不覆盖。以下为进程环境与当前存储的只读比对；确认前不会写入任何数据。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("全选") { selection.selectAll() }
                        .accessibilityIdentifier("settings.environment.import-preview.select-all")
                    Button("全不选") { selection.selectNone() }
                        .accessibilityIdentifier("settings.environment.import-preview.select-none")
                }

                ForEach(items, id: \.name) { item in
                    previewRow(item)
                }

                HStack {
                    Spacer()
                    Button("取消") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.environment.import-preview.cancel")

                    Button("确认导入所选 \(selection.selectedNames.count) 项") {
                        onConfirm(selection.selectedNames.sorted())
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.selectedNames.isEmpty)
                    .accessibilityIdentifier("settings.environment.import-preview.confirm")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(minWidth: 360, idealWidth: 460, maxWidth: .infinity)
        .frame(minHeight: 260, idealHeight: 360, maxHeight: .infinity)
        .accessibilityIdentifier("settings.environment.import-preview")
    }

    @ViewBuilder
    private func previewRow(_ item: EnvVarStore.EnvVarProcessImportPreviewItem) -> some View {
        switch item.changeKind {
        case .add:
            Toggle(isOn: selectionBinding(for: item.name)) {
                rowLabel(item, detail: "新增 · \(item.valueDisplay)")
            }
        case .update:
            skippedRow(item, detail: "已存在且值不同（仅新增不覆盖，跳过）")
        case .skip:
            skippedRow(item, detail: skipReasonText(item.skipReason))
        }
    }

    private func rowLabel(
        _ item: EnvVarStore.EnvVarProcessImportPreviewItem,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
            Text(detail)
                .font(typography?.caption2 ?? .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func skippedRow(
        _ item: EnvVarStore.EnvVarProcessImportPreviewItem,
        detail: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.slash")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            rowLabel(item, detail: detail)
        }
        .foregroundStyle(.secondary)
    }

    private func selectionBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selection.selectedNames.contains(name) },
            set: { isOn in selection.set(name, selected: isOn) }
        )
    }

    private func skipReasonText(_ reason: EnvVarStore.EnvVarProcessImportSkipReason?) -> String {
        switch reason {
        case .alreadyStored: return "已存在（不覆盖）"
        case .emptyValue: return "进程值为空"
        case .invalidName: return "名称不合法"
        case nil: return "不可导入"
        }
    }
}

// MARK: - U5 模型供应商新增/编辑表单
//
// 参照 Codex / Hermes 的新增模型配置：base_url + api_key + 模型列表（可多个）
// + wire API 协议类型（OpenAI 兼容 / Anthropic / 其他）。编辑时名称只读，
// 避免误建新条目。

/// 供应商编辑表单的一行模型名（可增删）。
private struct ProviderEditDraft {
    let displayName: String
    let name: String
    let apiKey: String
    let credential: ProviderCredentialUpdate
    let baseURL: String?
    let modelNames: [String]
    let protocolType: ProviderWireProtocol
    /// C8：自定义模型窗口（tokens），键为 `modelNames` 中的模型名；留空的行不出现。
    let modelContextWindows: [String: Int]
    /// 用户与推断不一致的图片/音频输入声明（与推断一致的不写入，推断升级可继续生效）。
    let modelImageInput: [String: Bool]
    let modelAudioInput: [String: Bool]
    /// 自定义模型的单次最大输出（tokens），键为 `modelNames` 中的模型名；留空的行不出现。
    let modelMaxOutputTokens: [String: Int]
    /// 自定义请求头与代理（默认值 = 无自定义头、跟随系统代理）。
    let networkOptions: ProviderNetworkOptions
}

/// 供应商编辑表单的一行自定义请求头。
private struct ProviderHeaderRow: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    /// true：`value` 是环境变量名，运行时才取值（密钥类内容用这个）。
    var valueIsEnvVar: Bool = false

    var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ProviderModelRow: Identifiable {
    let id = UUID()
    var modelName: String
    /// C8：窗口大小输入文本；留空 = 按目录/启发式。
    var contextWindowText: String = ""
    /// 最大输出输入文本；留空 = 按内置目录或默认值请求。
    var maxOutputText: String = ""
    /// 用户显式勾选/取消；nil = 未声明，显示与保存都按模型名推断。
    var imageInputOverride: Bool?
    var audioInputOverride: Bool?
    var supportsImage: Bool {
        get { imageInputOverride ?? ModelModalityInference.supportsImageInput(modelID: modelName) }
        set { imageInputOverride = newValue }
    }
    var supportsAudio: Bool {
        get { audioInputOverride ?? ModelModalityInference.supportsAudioInput(modelID: modelName) }
        set { audioInputOverride = newValue }
    }
}

/// C8：供应商模型“窗口大小（tokens）”输入的解析。留空合法（按目录/启发式取值），
/// 非留空必须是正整数，否则保存按钮不可用。
enum ProviderModelContextWindowInput: Equatable {
    case empty
    case valid(Int)
    case invalid

    static func parse(_ text: String) -> ProviderModelContextWindowInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = Int(trimmed), value > 0 else { return .invalid }
        return .valid(value)
    }
}

private struct ProviderConfigurationRecoveryDestination: Equatable, Sendable {
    let providerID: String
    let focus: ProviderEditFocus
}

private enum ProviderEditFocus: Hashable {
    case name
    case apiKey
    case baseURL
    case modelFirst
    case model(UUID)
}

/// Provider API Key 输入：始终使用 SecureField。
///
/// 对已保存供应商，空白表示保留现有 Keychain 引用；Settings 不会读取、
/// 显示或复制真实 secret。只有用户主动输入的新值才会进入保存边界。
private struct ProviderSecretField: View {
    @Binding var value: String
    let focus: FocusState<ProviderEditFocus?>.Binding
    let onSubmit: () -> Void

    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("输入新 Key；留空保留现有 Keychain 引用", text: $value)
                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .apiKey)
                .onSubmit { onSubmit() }
                .accessibilityLabel("API Key（仅输入或替换，不读取旧值）")
                .accessibilityHint("编辑已有供应商时留空表示保留 Keychain 引用")
                .accessibilityIdentifier("settings.provider.apiKey")
            Text("仅保存 Keychain 引用；此输入框只写入或替换 Key，不读取旧值；查看或复制请使用专门的凭据控件。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.provider.apiKey.reference-note")
        }
    }
}

enum ProviderEditSaveOutcome: Equatable, Sendable {
    case saved
    case failed(ProviderSaveFailureCategory)
}

/// The readiness reset scope is carried by the recovery state rather than by
/// a UI callback or an error string. This makes it impossible for a provider
/// replacement to accidentally clear a sibling provider's model state.
struct ProviderRecoveryScope: Equatable, Sendable {
    let providerID: String
    let modelIDs: [String]
    let credentialVersion: ProviderCredentialVersion

    init(
        providerID: String,
        modelIDs: [String],
        credentialVersion: ProviderCredentialVersion = .fresh()
    ) {
        self.providerID = providerID
        self.credentialVersion = credentialVersion
        var seen = Set<String>()
        self.modelIDs = modelIDs.compactMap { raw in
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID).inserted else { return nil }
            return modelID
        }
    }
}

/// Typed commands emitted by the provider edit UI. Commands never carry a
/// credential value; the replacement text stays inside the secure form field
/// and is passed only to the existing save boundary.
enum ProviderRecoveryCommand: Equatable, Sendable {
    case credentialReadFailed(scope: ProviderRecoveryScope, reason: ProviderSaveFailureCategory)
    case submitReplacement(scope: ProviderRecoveryScope, hasNonEmptyKey: Bool)
    case saveSucceeded(scope: ProviderRecoveryScope)
    case saveFailed(scope: ProviderRecoveryScope, failure: ProviderSaveFailureCategory)
    case cancel(scope: ProviderRecoveryScope)
}

enum ProviderRecoveryState: Equatable, Sendable {
    case idle
    case awaitingReplacement(scope: ProviderRecoveryScope, reason: ProviderSaveFailureCategory)
    case replacing(scope: ProviderRecoveryScope)
    case failed(scope: ProviderRecoveryScope, failure: ProviderSaveFailureCategory)
    case succeeded(scope: ProviderRecoveryScope)
    case cancelled(scope: ProviderRecoveryScope)

    /// Only a completed replacement exposes a reset scope to the caller.
    var readinessResetScope: ProviderRecoveryScope? {
        if case .succeeded(let scope) = self { return scope }
        return nil
    }

    var readinessResetCredentialVersion: ProviderCredentialVersion? {
        readinessResetScope?.credentialVersion
    }

    var scope: ProviderRecoveryScope? {
        switch self {
        case .idle: return nil
        case .awaitingReplacement(let scope, _), .replacing(let scope),
             .failed(let scope, _), .succeeded(let scope), .cancelled(let scope):
            return scope
        }
    }
}

/// Pure state reducer for the recovery action. Persistence/readiness mutation
/// remains owned by SettingsCenter.saveProvider; this reducer only guarantees
/// that cancellation, blank input, failures, and success stay scoped.
enum ProviderRecoveryReducer {
    static func reduce(
        _ state: ProviderRecoveryState,
        command: ProviderRecoveryCommand
    ) -> ProviderRecoveryState {
        switch command {
        case .credentialReadFailed(let scope, let reason):
            guard state.scope == nil || sameProvider(state.scope, scope) else {
                return state
            }
            guard isCredentialReadFailure(reason) else {
                return .failed(scope: scope, failure: reason)
            }
            return .awaitingReplacement(scope: scope, reason: reason)

        case .submitReplacement(let scope, let hasNonEmptyKey):
            guard state.scope == nil || sameProvider(state.scope, scope) else {
                // An action from another sheet/provider cannot mutate this
                // sheet's recovery state or readiness scope.
                return state
            }
            guard hasNonEmptyKey else {
                return .awaitingReplacement(scope: scope, reason: .missingCredential)
            }
            switch state {
            case .idle, .awaitingReplacement(_, _):
                return .replacing(scope: scope)
            case .replacing(_), .failed(_, _), .succeeded(_), .cancelled(_):
                return state
            }

        case .saveSucceeded(let scope):
            guard sameProvider(state.scope, scope) else { return state }
            switch state {
            case .replacing(_), .awaitingReplacement(_, _):
                return .succeeded(scope: scope)
            case .idle, .failed(_, _), .succeeded(_), .cancelled(_):
                return state
            }

        case .saveFailed(let scope, let failure):
            guard state.scope == nil || sameProvider(state.scope, scope) else { return state }
            if isCredentialReadFailure(failure) {
                return .awaitingReplacement(scope: scope, reason: failure)
            }
            return .failed(scope: scope, failure: failure)

        case .cancel(let scope):
            guard state.scope == nil || sameProvider(state.scope, scope) else { return state }
            return .cancelled(scope: scope)
        }
    }

    private static func sameProvider(
        _ lhs: ProviderRecoveryScope?,
        _ rhs: ProviderRecoveryScope
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.providerID.caseInsensitiveCompare(rhs.providerID) == .orderedSame
    }

    private static func isCredentialReadFailure(
        _ category: ProviderSaveFailureCategory
    ) -> Bool {
        switch category {
        case .keychainReadMissing, .keychainReadDenied, .keychainReadFailed:
            return true
        default:
            return false
        }
    }
}

/// Pure presentation transition for the credential sheet's typed save result.
/// Keeping this separate from the SwiftUI action makes the no-dismiss failure
/// contract executable without constructing a native sheet or touching a key.
enum ProviderEditSaveTransition: Equatable, Sendable {
    case dismiss
    case present(errorMessage: String)

    init(outcome: ProviderEditSaveOutcome) {
        switch outcome {
        case .saved:
            self = .dismiss
        case .failed(let failure):
            self = .present(errorMessage: failure.message)
        }
    }

    var keepsSheetPresented: Bool {
        if case .present = self { return true }
        return false
    }

    var accessibilityValue: String? {
        if case .present(let errorMessage) = self { return errorMessage }
        return nil
    }
}

private struct ProviderEditSheet: View {
    @Environment(\.themeTokens) private var theme
    let existing: EnvVarEntry?
    private let credentialSettings: SettingsCenter?
    @State private var credentialControlsModel: ProviderCredentialControlsModel?
    /// AJ-39：把旧 key 转成供应商时的自动建议（预填 Base URL / 模型 / 协议）。
    let suggestion: ProviderSuggestion?
    /// K45：由 provider recovery route 指定的初始焦点；普通编辑保持旧行为。
    let initialFocus: ProviderEditFocus?
    let onRenamePreview: ((String, String, ProviderEditDraft) throws -> SettingsDeletionRequest)?
    let onProbe: (String, String, String, ProviderWireProtocol) async -> ProviderDraftProbeState
    let onSave: (ProviderEditDraft) -> ProviderEditSaveOutcome

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var name = ""
    @State private var displayName = ""
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var protocolType: ProviderWireProtocol = .openaiCompatible
    @State private var modelRows: [ProviderModelRow] = []
    @State private var headerRows: [ProviderHeaderRow] = []
    @State private var proxyMode: ProviderProxySetting.Mode = .system
    @State private var proxyURL = ""
    @State private var pendingRename: SettingsDeletionRequest?
    @State private var errorMessage: String?
    @State private var providerRecoveryState: ProviderRecoveryState = .idle
    @State private var draftProbeState: ProviderDraftProbeState = .idle
    @State private var draftProbeTask: Task<Void, Never>?
    /// 最近一次由显示名自动推导出的凭据名（用来判断用户是否手改过）。
    @State private var autoDerivedName: String?
    /// S11：目录里被勾选要追加的模型（获取成功后默认全选）与搜索词。
    @State private var catalogSelection: Set<String> = []
    @State private var catalogSearch = ""
    @FocusState private var focusedField: ProviderEditFocus?
    @State private var didInitializeDraft = false
    /// U-04：新增供应商时的预设选择状态（仅新增路径使用）。
    @State private var presetForm: ProviderAddFormState

    init(
        existing: EnvVarEntry?,
        suggestion: ProviderSuggestion?,
        credentialSettings: SettingsCenter? = nil,
        initialFocus: ProviderEditFocus? = nil,
        fromConnectionRoute: Bool = false,
        initialPresetID: String? = nil,
        onRenamePreview: ((String, String, ProviderEditDraft) throws -> SettingsDeletionRequest)?,
        onProbe: @escaping (String, String, String, ProviderWireProtocol) async -> ProviderDraftProbeState,
        onSave: @escaping (ProviderEditDraft) -> ProviderEditSaveOutcome
    ) {
        self.existing = existing
        self.suggestion = suggestion
        self.credentialSettings = credentialSettings
        self.initialFocus = initialFocus
        self.onRenamePreview = onRenamePreview
        self.onProbe = onProbe
        self.onSave = onSave
        self.initialPresetID = initialPresetID
        _presetForm = State(initialValue: .initial(fromConnectionRoute: fromConnectionRoute))
    }

    /// 打开时预选的预设（模型选择里点了某个还没配置的内置服务商）。
    private let initialPresetID: String?

    private var isEditing: Bool { existing != nil }

    private var offersPresets: Bool { existing == nil && suggestion == nil }

    /// 选中预设：除 API Key 外的字段整体替换，焦点落到 Key。
    private func applyPreset(id: String) {
        presetForm.selectPreset(id: id)
        name = presetForm.name
        baseURL = presetForm.baseURL
        protocolType = presetForm.protocolType
        modelRows = presetForm.modelNames.map { ProviderModelRow(modelName: $0) }
        displayName = ProviderPreset.all.first { $0.id == id }?.displayName ?? displayName
        focusedField = .apiKey
    }

    @ViewBuilder
    private var presetPicker: some View {
        if presetForm.showsPresetPicker {
            VStack(alignment: .leading, spacing: 6) {
                Text("选择服务商（自动填好除 Key 外的字段）")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                ForEach(presetForm.presets) { preset in
                    Button(preset.displayName) { applyPreset(id: preset.id) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.provider.preset.\(preset.id)")
                }
                Button("自定义") { presetForm.showsPresetPicker = false }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.provider.preset.custom")
            }
        } else {
            Menu("使用预设") {
                ForEach(presetForm.presets) { preset in
                    Button(preset.displayName) { applyPreset(id: preset.id) }
                }
            }
            .accessibilityIdentifier("settings.provider.preset.menu")
        }
    }

    /// 保存用模型名（trim 后过滤空串，保持与存储层一致的清洗规则）。
    private var cleanedModelNames: [String] {
        modelRows
            .map { $0.modelName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// C8：有模型名的行里，窗口文本非空且不是正整数的行。
    private var hasInvalidContextWindowRow: Bool {
        modelRows.contains { row in
            !row.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ProviderModelContextWindowInput.parse(row.contextWindowText) == .invalid
        }
    }

    /// 有模型名的行里，最大输出文本非空且不是正整数的行。
    private var hasInvalidMaxOutputRow: Bool {
        modelRows.contains { row in
            !row.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ProviderModelContextWindowInput.parse(row.maxOutputText) == .invalid
        }
    }

    private var cleanedModelMaxOutputTokens: [String: Int] {
        var result: [String: Int] = [:]
        for row in modelRows {
            let name = row.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  case .valid(let limit) = ProviderModelContextWindowInput.parse(row.maxOutputText)
            else { continue }
            result[name] = limit
        }
        return result
    }

    private var cleanedModelContextWindows: [String: Int] {
        var result: [String: Int] = [:]
        for row in modelRows {
            let name = row.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  case .valid(let window) = ProviderModelContextWindowInput.parse(row.contextWindowText)
            else { continue }
            result[name] = window
        }
        return result
    }

    /// 仅记录与推断不一致的声明；同一模型名多行时以首行为准。
    private var cleanedModalityDeclarations: (image: [String: Bool], audio: [String: Bool]) {
        var image: [String: Bool] = [:]
        var audio: [String: Bool] = [:]
        for row in modelRows {
            let name = row.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let value = row.imageInputOverride,
               value != ModelModalityInference.supportsImageInput(modelID: name), image[name] == nil {
                image[name] = value
            }
            if let value = row.audioInputOverride,
               value != ModelModalityInference.supportsAudioInput(modelID: name), audio[name] == nil {
                audio[name] = value
            }
        }
        return (image, audio)
    }

    /// 表单里的请求头与代理（空行忽略）。
    private var cleanedNetworkOptions: ProviderNetworkOptions {
        ProviderNetworkOptions(
            headers: headerRows.filter { !$0.isBlank }.map {
                ProviderCustomHeader(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines),
                    valueIsEnvVar: $0.valueIsEnvVar)
            },
            proxy: ProviderProxySetting(
                mode: proxyMode,
                url: proxyMode == .custom ? proxyURL.trimmingCharacters(in: .whitespacesAndNewlines) : nil))
    }

    /// 第一条不合法请求头或代理地址的中文说明；nil = 全部可用。
    private var networkOptionsProblem: String? {
        let options = cleanedNetworkOptions
        for header in options.headers {
            switch ProviderNetworkOptionsPolicy.issue(for: header) {
            case .invalidName: return "请求头名称「\(header.name)」不合法，只能用英文字母、数字和连字符。"
            case .reservedName: return "请求头「\(header.name)」是认证或协议头，不能自定义。"
            case .emptyValue: return "请求头「\(header.name)」的值不能为空。"
            case .invalidValue: return "请求头「\(header.name)」的值不合法（环境变量名只能含字母、数字、下划线，值里不能有换行）。"
            case nil: continue
            }
        }
        if options.proxy.mode == .custom,
           (try? ProviderNetworkOptionsPolicy.proxyDictionary(for: options.proxy)) == nil {
            return "代理地址不合法：请填 http:// 或 https:// 开头的地址，如 http://127.0.0.1:7890，不要带用户名密码。"
        }
        return nil
    }

    /// 已保存的 Key 是否仍可沿用：只有 Base URL 和协议都没变时才可以。
    /// 任一变化都必须重新输入 Key，避免把旧 Key 发给新地址（安全）。
    private var savedCredentialUsable: Bool {
        guard let existing, existing.isProviderRecord, existing.isSecret, existing.valueInKeychain else { return false }
        func normalized(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalized(effectiveBaseURL) == normalized(existing.baseURL ?? "")
            && protocolType == existing.protocolType
    }

    /// 编辑中且已有保存的 Key，但地址或协议改了、又没重输 Key。
    private var needsKeyReentryAfterEndpointChange: Bool {
        guard let existing, existing.isProviderRecord, existing.isSecret, existing.valueInKeychain else { return false }
        return !savedCredentialUsable && !blankKeyAllowed
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存前还缺哪些项（列出来，而不是让保存按钮悄悄变灰）。
    private var missingItems: [String] {
        var items: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { items.append("服务商标识") }
        let hasKeyInput = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasKeyInput && !savedCredentialUsable && !blankKeyAllowed { items.append("API Key") }
        if effectiveBaseURL.isEmpty { items.append("Base URL") }
        if cleanedModelNames.isEmpty && !blankKeyAllowed { items.append("模型名（可用“获取模型列表”选择）") }
        return items
    }

    /// 内置供应商占用的凭据名；自动推导时不能与它们重名，免得新供应商悄悄绑到内置路由。
    private static let builtinCredentialNames: Set<String> = [
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY", "OPENROUTER_API_KEY",
        "DASHSCOPE_API_KEY", "GEMINI_API_KEY", "MOONSHOT_API_KEY", "ZHIPU_API_KEY", "SILICONFLOW_API_KEY",
        "HERMES_CUSTOM_NEW_API_KEY", "OLLAMA_API_KEY", "LMSTUDIO_API_KEY"
    ]

    /// 由显示名推导凭据名：只留英文字母和数字，其余变下划线；结果以 _API_KEY 结尾，且不与内置名重名。
    static func derivedCredentialName(fromDisplayName displayName: String) -> String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var slug = ""
        for scalar in trimmed.uppercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("_") {
                slug += "_"
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.isEmpty { slug = "CUSTOM" }
        if let first = slug.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { slug = "P_" + slug }
        var candidate = slug + "_API_KEY"
        if builtinCredentialNames.contains(candidate) { candidate = slug + "_CUSTOM_API_KEY" }
        return candidate
    }

    private var canSave: Bool {
        let hasExistingProviderReference = savedCredentialUsable
        let hasCredentialInput = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (hasCredentialInput || hasExistingProviderReference || blankKeyAllowed)
            && (isEditing || !EnvVarStore.canonicalName(name).isEmpty)
            && !hasInvalidContextWindowRow
            && !hasInvalidMaxOutputRow
            && networkOptionsProblem == nil
    }

    private var credentialForSave: ProviderCredentialUpdate {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let hasExistingProviderReference = savedCredentialUsable
            if hasExistingProviderReference { return .keepExisting }
            // 本机/局域网模型服务不需要 Key：内部存一个占位值，聊天与检查连接都能照常工作。
            return blankKeyAllowed ? .replace(ProviderEndpointPolicy.localPlaceholderAPIKey) : .missing
        }
        return .replace(trimmed)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// S9：当前凭据名对应的预设默认地址（没有预设则为 nil）。
    private var presetDefaultBaseURL: String? {
        ProviderPreset.defaultBaseURL(forCredentialName: name)
    }

    /// 基础地址留空时用预设默认地址。
    private var effectiveBaseURL: String {
        trimmedBaseURL.isEmpty ? (presetDefaultBaseURL ?? "") : trimmedBaseURL
    }

    /// S1：基础地址是本机或私网时，API Key 可以留空。
    private var blankKeyAllowed: Bool {
        ProviderEndpointPolicy.allowsBlankAPIKey(forBaseURL: effectiveBaseURL)
    }

    private var canProbe: Bool {
        (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blankKeyAllowed || savedCredentialUsable)
            && !effectiveBaseURL.isEmpty
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "编辑模型供应商" : "新增模型供应商")
                .font(typography?.headline ?? .headline)

            if offersPresets {
                presetPicker
            }

            if let errorMessage {
                let safeMessage = ProviderStatusTextProjection.project(errorMessage)
                Text(safeMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusDangerText ?? AppStatusColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("保存错误")
                    .accessibilityValue(safeMessage)
                    .accessibilityIdentifier("settings.provider.save.error")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("显示名").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField("如 我的模型服务", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("显示名")
                    .accessibilityIdentifier("settings.provider.displayName")
                Text("修改显示名不会更改服务商标识、密钥引用或历史归属。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("服务商标识（也是密钥的保存名）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                Text("用来在本机区分不同服务商、保存 API Key，不会发给模型；建议用英文大写加下划线。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                // 编辑时也可改名（保存时 onRename 删除旧记录，防 upsert 残留）。
                TextField("如 MY_PROVIDER_API_KEY", text: $name)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("服务商标识")
                    .onSubmit { focusedField = .apiKey }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(blankKeyAllowed ? "API Key（本机或局域网服务可留空）" : "API Key")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                ProviderSecretField(
                    value: $apiKey,
                    focus: $focusedField,
                    onSubmit: { focusedField = .baseURL }
                )
                if let credentialControlsModel {
                    ProviderCredentialControls(model: credentialControlsModel)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presetDefaultBaseURL == nil ? "Base URL" : "Base URL（可选，留空使用预设地址）")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                TextField(presetDefaultBaseURL ?? "如 https://api.openai.com/v1", text: $baseURL)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .baseURL)
                    .accessibilityLabel("服务地址（Base URL）")
                    .accessibilityIdentifier("settings.provider.baseURL")
                    .onSubmit {
                        if let firstModel = modelRows.first {
                            focusedField = .model(firstModel.id)
                        } else {
                            submitIfValid()
                        }
                    }
                if effectiveBaseURL.isEmpty {
                    Text("没有默认地址：留空会导致无法检查连接，请填写服务商提供的基础地址。")
                        .font(typography?.caption ?? .caption)
                        .modifier(ReadableStatusForeground(status: .warning))
                        .accessibilityIdentifier("settings.provider.baseURL.missing")
                } else if ProviderEndpointPolicy.isPlainHTTPToPublicHost(effectiveBaseURL) {
                    Text("该地址使用 http，明文传输 Key 有风险；仅在你信任该网络和服务时使用。")
                        .font(typography?.caption ?? .caption)
                        .modifier(ReadableStatusForeground(status: .warning))
                        .accessibilityIdentifier("settings.provider.baseURL.plainHTTP")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("URL 协议类型").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                Picker("", selection: $protocolType) {
                    ForEach(ProviderWireProtocol.allCases, id: \.self) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("接口协议类型")
                .help("该 Base URL 支持的接口协议（参照 Codex/Hermes 的 wire API 类型）")
            }

            if needsKeyReentryAfterEndpointChange {
                Text("Base URL 或协议已更改：为避免把已保存的 Key 发给新地址，请重新输入 API Key。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                    .accessibilityIdentifier("settings.provider.reenterKeyHint")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        startDraftProbe()
                    } label: {
                        Label { Text("获取模型列表") } icon: { MinisIconView(.download, size: 14) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canProbe || isDraftProbeLoading)
                    .accessibilityIdentifier("settings.provider.fetchModels")
                    .help("使用当前表单内容获取模型目录，不会保存")

                    if isDraftProbeLoading {
                        ProgressView()
                            .controlSize(.small)
                        Button("取消") {
                            cancelDraftProbe()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.provider.fetchModels.cancel")
                    }
                }

                switch draftProbeState {
                case .idle:
                    EmptyView()
                case .loading:
                    Text("正在获取模型目录…")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                case .loaded(let modelIDs):
                    catalogPicker(modelIDs)
                case .empty:
                    Text("目录为空，没有可应用的模型。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(ProviderStatusTextProjection.project(message))
                        .font(typography?.caption ?? .caption)
                        .modifier(ReadableStatusForeground(status: .danger))
                case .cancelled:
                    Text("已取消获取模型目录。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("模型名称（可添加多个）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        modelRows.append(ProviderModelRow(modelName: ""))
                    } label: {
                        Label { Text("添加模型") } icon: { MinisIconView(.add, size: 14) }
                    }
                    .buttonStyle(.borderless)
                }

                if modelRows.isEmpty {
                    Text("尚未添加模型，点右上角「添加模型」增加。")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.tertiary)
                } else {
                    if hasInvalidContextWindowRow {
                        Text("窗口大小必须是正整数（或留空）。")
                            .font(typography?.caption ?? .caption)
                            .modifier(ReadableStatusForeground(status: .danger))
                            .accessibilityIdentifier("settings.provider.context-window.invalid")
                    }
                    if hasInvalidMaxOutputRow {
                        Text("最大输出必须是正整数（或留空）。")
                            .font(typography?.caption ?? .caption)
                            .modifier(ReadableStatusForeground(status: .danger))
                            .accessibilityIdentifier("settings.provider.max-output.invalid")
                    }
                    ForEach($modelRows) { $row in
                        VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            TextField("模型名，如 gpt-4o", text: $row.modelName)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .model(row.id))
                                .accessibilityLabel("模型名")
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row))
                                .onSubmit {
                                    if let next = modelRows.drop(while: { $0.id != row.id }).dropFirst().first {
                                        focusedField = .model(next.id)
                                    } else {
                                        submitIfValid()
                                    }
                                }
                            TextField("窗口大小（tokens）", text: $row.contextWindowText)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .accessibilityLabel("上下文窗口大小（tokens）")
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row) + ".context-window")
                                .help("留空 = 按内置目录或默认值；填写后作为该模型的上下文窗口")
                            Button(role: .destructive) {
                                modelRows.removeAll { $0.id == row.id }
                            } label: {
                                MinisIconView(.delete, size: 12)
                            }
                            .buttonStyle(.borderless)
                            .help("删除该模型")
                            .accessibilityLabel("删除该模型")
                        }
                        HStack(spacing: 16) {
                            Toggle("支持图片", isOn: $row.supportsImage)
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row) + ".image-input")
                                .help("默认按模型名推断；勾选后该模型可接收图片附件")
                            Toggle("支持音频", isOn: $row.supportsAudio)
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row) + ".audio-input")
                                .help("默认按模型名推断；勾选后该模型可接收音频附件")
                            TextField("最大输出（tokens，可选）", text: $row.maxOutputText)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 190)
                                .accessibilityLabel("单次最大输出（tokens，可选）")
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row) + ".max-output")
                                .help("留空 = 按内置目录或默认值请求；该模型的单次输出上限低于默认值时请填写，否则服务商可能拒绝请求")
                        }
                        .toggleStyle(.checkbox)
                        .font(typography?.caption ?? .caption)
                        if row.contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !row.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           ModelContextWindowCatalog.usesFallbackWindow(
                               explicitWindow: nil,
                               modelID: row.modelName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Text("上下文窗口为估计值（按 128,000 计），可在上面的窗口大小里改成实际值。")
                                .font(typography?.caption ?? .caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(modelAccessibilityIdentifier(for: row) + ".context-window.estimated")
                        }
                        }
                    }
                }
            }

            networkOptionsSection

            if !missingItems.isEmpty {
                Text("还缺：" + missingItems.joined(separator: "、"))
                    .font(typography?.caption ?? .caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("settings.provider.missingItems")
            }

            if cleanedModelNames.isEmpty, catalogSelection.isEmpty {
                Text("还没有添加模型，保存后不能对话。可先点“获取模型列表”，或手动添加模型名。")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.provider.noModelsHint")
            }
            HStack {
                Spacer()
                Button("取消") {
                    focusedField = nil
                    cancelProviderRecovery()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.provider.cancel")
                Button("保存", action: submitIfValid)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings.provider.save")
                .disabled(!canSave)
            }
        }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
        .frame(minHeight: 260, idealHeight: 560, maxHeight: .infinity)
        .onDisappear {
            draftProbeTask?.cancel()
            draftProbeTask = nil
        }
        .sheet(item: $pendingRename) { request in
            SettingsDeletionPrompt(
                request: request,
                onCancel: { pendingRename = nil },
                onConfirm: { intent in executeRename(request, intent: intent) }
            )
        }
        .onChange(of: focusedField) { _, _ in credentialControlsModel?.focusLost() }
        .onChange(of: name) { _, value in
            if EnvVarStore.canonicalName(value) != existing?.name {
                credentialControlsModel?.close()
            }
        }
        // 新增时凭据名留空（或仍是上次自动推导的值）就跟着显示名自动推导，用户手改后不再覆盖。
        .onChange(of: displayName) { _, value in
            guard existing == nil else { return }
            let current = name.trimmingCharacters(in: .whitespaces)
            guard current.isEmpty || current == autoDerivedName else { return }
            if let derived = Self.derivedCredentialName(fromDisplayName: value) {
                autoDerivedName = derived
                name = derived
            }
        }
        .onDisappear { credentialControlsModel?.close() }
        .onAppear {
            if let existing {
                credentialControlsModel = credentialSettings?.makeProviderCredentialControlsModel(recordID: existing.id)
            }
            guard !didInitializeDraft else { return }
            didInitializeDraft = true
            if let existing {
                name = existing.name
                // 与列表标题同一规则（按 Base URL 认出内置服务商），保存时不会把名字换掉。
                displayName = ProviderDisplayLabel.resolve(record: existing)
                // Never read a legacy plaintext value or a Keychain-backed
                // value into the form. A replacement is explicit user input;
                // an existing provider record can retain its opaque Keychain
                // reference by leaving this field blank.
                apiKey = ""
                // 已有供应商元数据 → 以现有为准；旧 key（无元数据）转换 →
                // 用自动建议预填 Base URL / 模型 / 协议（AJ-39）。
                if existing.baseURL != nil || !existing.modelNames.isEmpty {
                    baseURL = existing.baseURL ?? ""
                    protocolType = existing.protocolType
                    modelRows = existing.modelNames.map { name in
                        ProviderModelRow(
                            modelName: name,
                            contextWindowText: existing.modelContextWindows?[name].map(String.init) ?? "",
                            maxOutputText: existing.modelMaxOutputTokens?[name].map(String.init) ?? "",
                            imageInputOverride: existing.modelImageInput?[name],
                            audioInputOverride: existing.modelAudioInput?[name]
                        )
                    }
                } else if let suggestion {
                    baseURL = suggestion.baseURL ?? ""
                    protocolType = suggestion.protocolType
                    modelRows = suggestion.modelNames.map { ProviderModelRow(modelName: $0) }
                }
                if let options = existing.networkOptions {
                    headerRows = options.headers.map {
                        ProviderHeaderRow(name: $0.name, value: $0.value, valueIsEnvVar: $0.valueIsEnvVar)
                    }
                    proxyMode = options.proxy.mode
                    proxyURL = options.proxy.url ?? ""
                }
            }
            if existing == nil, offersPresets, let initialPresetID {
                applyPreset(id: initialPresetID)
            }
            // 新增或转换时默认给一行空白模型输入，降低首次使用门槛。
            if modelRows.isEmpty {
                modelRows = [ProviderModelRow(modelName: "")]
            }
            // 等 sheet 的首个字段真正挂载后再设置焦点，避免 macOS sheet
            // 首次呈现时焦点落回标题或被 ScrollView 吞掉。
            Task { @MainActor in
                await Task.yield()
                let requestedFocus = initialFocus ?? (isEditing ? .name : .apiKey)
                if requestedFocus == .modelFirst {
                    focusedField = modelRows.first.map { .model($0.id) } ?? .baseURL
                } else {
                    focusedField = requestedFocus
                }
            }
        }
    }

    /// 自定义请求头与代理（高级，默认折叠不影响现有流程：不填就是无自定义头、跟随系统代理）。
    @ViewBuilder
    private var networkOptionsSection: some View {
        DisclosureGroup("高级：自定义请求头与代理") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("自定义请求头").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            headerRows.append(ProviderHeaderRow())
                        } label: {
                            Label { Text("添加请求头") } icon: { MinisIconView(.add, size: 14) }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.provider.headers.add")
                    }
                    Text("不能设置认证和协议头（如 Authorization、Content-Type）。密钥类的值请勾选“环境变量名”，只保存变量名，不保存密钥本身。")
                        .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    ForEach($headerRows) { $row in
                        HStack(spacing: 8) {
                            TextField("名称，如 X-Org-Id", text: $row.name)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("请求头名称")
                            TextField(row.valueIsEnvVar ? "环境变量名，如 MY_ORG_TOKEN" : "值", text: $row.value)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("请求头的值")
                            Toggle("环境变量名", isOn: $row.valueIsEnvVar)
                                .toggleStyle(.checkbox)
                                .font(typography?.caption ?? .caption)
                            Button(role: .destructive) {
                                headerRows.removeAll { $0.id == row.id }
                            } label: {
                                MinisIconView(.delete, size: 12)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除该请求头")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("代理").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    Picker("", selection: $proxyMode) {
                        Text("跟随系统").tag(ProviderProxySetting.Mode.system)
                        Text("不用代理").tag(ProviderProxySetting.Mode.direct)
                        Text("指定地址").tag(ProviderProxySetting.Mode.custom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("代理方式")
                    .accessibilityIdentifier("settings.provider.proxy.mode")
                    if proxyMode == .custom {
                        TextField("如 http://127.0.0.1:7890", text: $proxyURL)
                            .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("代理地址")
                            .accessibilityIdentifier("settings.provider.proxy.url")
                    }
                }
                if let problem = networkOptionsProblem {
                    Text(problem)
                        .font(typography?.caption ?? .caption)
                        .modifier(ReadableStatusForeground(status: .danger))
                        .accessibilityIdentifier("settings.provider.network.invalid")
                }
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("settings.provider.network.group")
    }

    private func filteredCatalog(_ modelIDs: [String]) -> [String] {
        let query = catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return modelIDs }
        return modelIDs.filter { $0.lowercased().contains(query) }
    }

    /// S11：目录可搜索、可勾选；默认全选，只追加勾选的模型。
    @ViewBuilder
    private func catalogPicker(_ modelIDs: [String]) -> some View {
        let visible = filteredCatalog(modelIDs)
        let selectedCount = modelIDs.filter { catalogSelection.contains($0) }.count
        VStack(alignment: .leading, spacing: 6) {
            Text("已发现 \(modelIDs.count) 个模型，已选 \(selectedCount) 个")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
            TextField("搜索模型", text: $catalogSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.provider.fetchModels.search")
            HStack(spacing: 12) {
                Button("全选当前列表") { catalogSelection.formUnion(visible) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.provider.fetchModels.selectAll")
                Button("取消选择当前列表") { catalogSelection.subtract(visible) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.provider.fetchModels.selectNone")
            }
            .font(typography?.caption ?? .caption)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible, id: \.self) { modelID in
                        Toggle(isOn: Binding(
                            get: { catalogSelection.contains(modelID) },
                            set: { isOn in
                                if isOn { catalogSelection.insert(modelID) } else { catalogSelection.remove(modelID) }
                            }
                        )) {
                            Text(modelID)
                                .font(typography?.caption2 ?? .system(.caption, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                    if visible.isEmpty {
                        Text("没有匹配的模型。")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 160)
            Button("应用所选（\(selectedCount)）") {
                applyDiscoveredModels(modelIDs.filter { catalogSelection.contains($0) }, fullCatalog: modelIDs)
            }
            .buttonStyle(.borderless)
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("settings.provider.fetchModels.apply")
            .help("保留手动模型，仅追加勾选的新模型")
        }
    }

    private func submitIfValid() {
        guard canSave else { return }
        // 已获取模型列表、勾选了模型但没点“应用”就直接保存：自动应用所选，避免存成 0 个模型。
        if cleanedModelNames.isEmpty, case .loaded(let discovered) = draftProbeState {
            let picked = discovered.filter { catalogSelection.contains($0) }
            if !picked.isEmpty { applyDiscoveredModels(picked, fullCatalog: discovered) }
        }
        let draft = ProviderEditDraft(
            displayName: displayName,
            name: name,
            apiKey: apiKey,
            credential: credentialForSave,
            baseURL: effectiveBaseURL.isEmpty ? nil : effectiveBaseURL,
            modelNames: cleanedModelNames,
            protocolType: protocolType,
            modelContextWindows: cleanedModelContextWindows,
            modelImageInput: cleanedModalityDeclarations.image,
            modelAudioInput: cleanedModalityDeclarations.audio,
            modelMaxOutputTokens: cleanedModelMaxOutputTokens,
            networkOptions: cleanedNetworkOptions
        )
        let recoveryScope = existing.flatMap { record in
            record.isProviderRecord
                ? ProviderRecoveryScope(
                    providerID: record.name,
                    modelIDs: record.modelNames + draft.modelNames
                )
                : nil
        }
        let hasReplacementKey = !draft.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if let recoveryScope {
            let isCurrentRecoveryProvider = providerRecoveryState.scope.map {
                $0.providerID.caseInsensitiveCompare(recoveryScope.providerID) == .orderedSame
            } ?? false
            if hasReplacementKey || isCurrentRecoveryProvider {
                providerRecoveryState = ProviderRecoveryReducer.reduce(
                    providerRecoveryState,
                    command: .submitReplacement(
                        scope: recoveryScope,
                        hasNonEmptyKey: hasReplacementKey
                    )
                )
            }
            if isCurrentRecoveryProvider && !hasReplacementKey {
                // A missing/denied credential recovery cannot fall through to
                // .keepExisting: require a replacement before persistence.
                focusedField = .apiKey
                errorMessage = ProviderSaveFailureCategory.missingCredential.message
                return
            }
        }
        if let existing {
            let newCanonical = EnvVarStore.canonicalName(draft.name)
            if existing.name != newCanonical {
                do {
                    guard let onRenamePreview else {
                        errorMessage = "改名未执行：缺少确认流程。"
                        return
                    }
                    pendingRename = try onRenamePreview(existing.name, newCanonical, draft)
                    errorMessage = nil
                } catch {
                    focusedField = .apiKey
                    errorMessage = "供应商保存流程未完成（PROVIDER-UPDATE-FAILED）。请刷新列表，确认名称和凭据引用后重试。"
                }
                return
            }
        }
        let outcome = onSave(draft)
        if let recoveryScope {
            switch outcome {
            case .saved:
                providerRecoveryState = ProviderRecoveryReducer.reduce(
                    providerRecoveryState,
                    command: .saveSucceeded(scope: recoveryScope)
                )
            case .failed(let failure):
                providerRecoveryState = ProviderRecoveryReducer.reduce(
                    providerRecoveryState,
                    command: .saveFailed(scope: recoveryScope, failure: failure)
                )
            }
        }
        // Keep the existing contract boundary: ProviderEditSaveTransition(outcome: onSave(draft)).
        switch ProviderEditSaveTransition(outcome: outcome) {
        case .dismiss:
            focusedField = nil
            dismiss()
        case .present(let message):
            // Keep the sheet open so the user can correct or retry.
            // Only the typed, secret-free category is rendered.
            focusedField = .apiKey
            errorMessage = message
        }
    }

    private func cancelProviderRecovery() {
        guard let scope = providerRecoveryState.scope else { return }
        providerRecoveryState = ProviderRecoveryReducer.reduce(
            providerRecoveryState,
            command: .cancel(scope: scope)
        )
    }

    private func modelAccessibilityIdentifier(for row: ProviderModelRow) -> String {
        let index = modelRows.firstIndex(where: { $0.id == row.id }) ?? 0
        return "settings.provider.model.\(index + 1)"
    }

    private func executeRename(_ request: SettingsDeletionRequest, intent: OperationIntent) {
        if let executeAsync = request.executeAsync {
            pendingRename = nil
            Task { @MainActor in
                do {
                    _ = try await executeAsync(intent)
                    dismiss()
                } catch {
                    focusedField = .apiKey
                    errorMessage = "供应商保存流程未完成（PROVIDER-UPDATE-FAILED）。请刷新列表，确认名称和凭据引用后重试。"
                }
            }
            return
        }
        do {
            guard let execute = request.execute else { return }
            _ = try execute(intent)
            pendingRename = nil
            dismiss()
        } catch {
            pendingRename = nil
            focusedField = .apiKey
            errorMessage = "供应商保存流程未完成（PROVIDER-UPDATE-FAILED）。请刷新列表，确认名称和凭据引用后重试。"
        }
    }

    private var isDraftProbeLoading: Bool {
        if case .loading = draftProbeState {
            return true
        }
        return false
    }

    private func startDraftProbe() {
        draftProbeTask?.cancel()
        draftProbeState = .loading
        draftProbeTask = Task { @MainActor in
            // 地址和协议都没变时，用已保存的凭据获取模型列表，不必重输 Key；
            // 任一变化都不会走到这里（canProbe 会要求重新输入 Key）。
            // 等待期间用户可能改了地址或协议：发出前先记下，等待后复核，变了就丢弃这次请求，
            // 免得旧 Key 发到新地址。
            let probeName = name
            let probeBaseURL = effectiveBaseURL
            let probeProtocol = protocolType
            @MainActor func formUnchanged() -> Bool {
                name == probeName && effectiveBaseURL == probeBaseURL && protocolType == probeProtocol
            }
            var probeKey = apiKey
            if probeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               savedCredentialUsable, let existing, let credentialSettings {
                probeKey = await credentialSettings.providerCredentialAsync(named: existing.name) ?? ""
            }
            guard !Task.isCancelled else { return }
            guard formUnchanged() else {
                draftProbeState = .cancelled
                draftProbeTask = nil
                return
            }
            let result = await onProbe(
                probeName,
                probeKey,
                probeBaseURL,
                probeProtocol
            )
            guard !Task.isCancelled else { return }
            guard formUnchanged() else {
                // 地址或协议已变，这份目录属于旧地址，不套用到当前表单。
                draftProbeState = .cancelled
                draftProbeTask = nil
                return
            }
            if case .loaded(let modelIDs) = result {
                // 默认勾选可能是对话的模型；向量、重排、语音、图像等名字的模型默认不勾，用户仍可手动勾选。
                catalogSelection = Set(modelIDs.filter { !ProviderModelNameHeuristics.likelyNonChat($0) })
                catalogSearch = ""
            }
            draftProbeState = result
            draftProbeTask = nil
        }
    }

    private func cancelDraftProbe() {
        draftProbeTask?.cancel()
        draftProbeTask = nil
        draftProbeState = .cancelled
    }

    private func applyDiscoveredModels(_ modelIDs: [String], fullCatalog: [String]) {
        let merged = ProviderDraftModelMerger.merge(
            manual: modelRows.map(\.modelName),
            discovered: modelIDs
        )
        let typedWindows = Dictionary(
            modelRows.map { ($0.modelName, $0.contextWindowText) },
            uniquingKeysWith: { first, _ in first }
        )
        let typedRows = Dictionary(modelRows.map { ($0.modelName, $0) }, uniquingKeysWith: { first, _ in first })
        modelRows = merged.map {
            ProviderModelRow(
                modelName: $0, contextWindowText: typedWindows[$0] ?? "",
                maxOutputText: typedRows[$0]?.maxOutputText ?? "",
                imageInputOverride: typedRows[$0]?.imageInputOverride,
                audioInputOverride: typedRows[$0]?.audioInputOverride)
        }
        draftProbeState = .loaded(fullCatalog)
    }
}

// MARK: - 用量统计（波4）

/// 用量统计页：总消耗（token in/out/调用次数）+ 分模型聚合 + 近期调用明细。
struct UsageSettingsTab: View {
    @Bindable var center: SettingsCenter
    var chatStore: ChatStore? = nil

    var body: some View {
        UsageFilteredSettingsView(usageStore: center.usageStore, chatStore: chatStore)
    }
}

// MARK: - 日志（Logs）

private struct LogsSettingsTab: View {
    @Bindable var center: SettingsCenter
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @State private var pendingDeletion: SettingsDeletionRequest?
    @State private var lastActionMessage: String?
    @State private var lastActionIsError = false

    private var visibleEntries: [LogEntry] { center.visibleLogEntries }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("级别", selection: Binding(
                    get: { center.liveLogLevel },
                    set: { center.liveLogLevel = $0 }
                )) {
                    ForEach(SettingsLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                .accessibilityIdentifier("settings.logs.level")

                Button(role: .destructive) {
                    beginClearLogs()
                } label: {
                    Label { Text("清空") } icon: { MinisIconView(.delete, size: 14) }
                }
                // AX-EXPOSURE-189：单一元素配方的四行声明块按
                // SettingsAXExposure189ContractTests 冻结合同原样保留
                // （文案、图标、样式与提示均未改变）。
                .accessibilityLabel("清空")
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("settings.logs.clear")
                .accessibilityHint("只清空当前进程日志缓冲区，磁盘日志文件保留")
                // DEV-272-SETAX：与「恢复全部默认设置」触发元素同一根因、同一
                // lane 190 已验证配方——聚合元素只承接其后声明的属性与动作；
                // 189 块内标签在聚合之前且无默认动作，实测形态为「有 role、无
                // label、按压空转」，beginClearLogs() 永不执行，共享两步删除
                // 确认面（.sheet(item: $pendingDeletion)）从未进入 AX 树，
                // :226/:251/:265 的取消/下一步/执行控件因此"从未有机会出现"。
                // 聚合之后补投真实标签，并把显式默认动作接到与 Button 闭包
                // 完全相同的生产入口 beginClearLogs() 上：预览只读、两步确认、
                // 只清环形缓冲、磁盘 app.log 保盘语义全部原样。
                .accessibilityLabel("清空")
                .accessibilityAction { beginClearLogs() }

                Spacer()

                Text("\(visibleEntries.count) 条")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Text("清空只影响当前进程日志缓冲区，磁盘日志文件保留。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if let lastActionMessage {
                Text(lastActionMessage)
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(lastActionIsError ? (theme?.statusDanger ?? .red) : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "doc.text",
                    description: Text("级别过滤后的日志会实时出现在这里。")
                )
                .accessibilityIdentifier("settings.logs.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visibleEntries.enumerated()), id: \.offset) { _, entry in
                            Text(entry.formatted)
                                .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .textBackgroundColor).opacity(0.5))
            }
        }
        .sheet(item: $pendingDeletion) { request in
            SettingsDeletionPrompt(
                request: request,
                onCancel: { pendingDeletion = nil },
                onConfirm: { intent in executeClearLogs(request, intent: intent) }
            )
        }
        .task {
            // 每 2 秒刷新一次（跟随 LogManager 环形缓冲）。
            while !Task.isCancelled {
                center.reloadLogs()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func beginClearLogs() {
        do {
            pendingDeletion = SettingsDeletionRequest(
                intent: try center.previewLogClear(),
                execute: { try center.clearLogs(intent: $0) }
            )
            lastActionMessage = nil
            lastActionIsError = false
        } catch {
            lastActionMessage = "日志清空未开始（LOG-CLEAR-PREVIEW-FAILED）。请刷新并重新确认清空范围。"
            lastActionIsError = true
        }
    }

    private func executeClearLogs(_ request: SettingsDeletionRequest, intent: OperationIntent) {
        do {
            guard let execute = request.execute else { return }
            let receipt = try execute(intent)
            pendingDeletion = nil
            lastActionMessage = "已清空当前进程日志缓冲区 \(receipt.affectedCount) 条；磁盘日志文件保留。"
            lastActionIsError = false
        } catch {
            pendingDeletion = nil
            lastActionMessage = "日志未能清空（LOG-CLEAR-FAILED）。请刷新当前日志状态后重试。"
            lastActionIsError = true
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warn: theme?.statusWarning ?? .orange
        case .error: theme?.statusDanger ?? .red
        }
    }
}

// MARK: - 关于（About）

private struct AboutSettingsTab: View {
    @State private var isLegalNoticePresented = false
    @Bindable var center: SettingsCenter
    @Environment(\.typographyTokens) private var typography

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "\(version) (\(build))"
    }

    private var featureManifestState: PackageFeatureManifest.LoadState {
        PackageFeatureManifest.load(
            bundle: .main,
            expectedIdentity: PackageFeatureManifest.expectedIdentity(from: .main)
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    MinisIconView(.library, size: 44)
                        .foregroundPalette(.tint)
                        .font(.system(size: 44))
                    Text("MinisCanvas")
                        .font((typography?.headline ?? .title2).bold())
                    Text("版本 \(versionText)")
                        .font(typography?.caption ?? .subheadline)
                        .foregroundStyle(.secondary)
                    Button("复制版本信息") { copyTextToClipboard("MinisCanvas \(versionText)") }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("settings.about.copy-version")
                    Text("画布功能将在后续版本开放")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    Text("本地优先的 AI 工作台")
                        .font(typography?.caption ?? .subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section("许可证") {
                Button("许可证与第三方声明") { isLegalNoticePresented = true }
                    .accessibilityIdentifier("settings.about.legal-notices")
            }

            Section("构建信息") {
                DisclosureGroup("详细信息") {
                    LabeledContent("设置 Schema 版本", value: "\(center.settings.settingsVersion)")
                    LabeledContent("设置文件", value: center.settingsDirectory.appendingPathComponent("settings.json").path)
                    LabeledContent("日志文件", value: center.logManager.logFileURL()?.path ?? "尚未生成")
                    LabeledContent("环境变量数", value: "\(center.envEntries.count)")
                    LabeledContent("会话数", value: "\(center.sessions.count)")
                }
                .accessibilityIdentifier("settings.about.build-details")
            }

            Section("版本与功能清单") {
                DisclosureGroup("详细信息") {
                    switch featureManifestState {
                    case .loaded(let manifest):
                        LabeledContent("版本渠道", value: manifest.channel)
                        LabeledContent("source SHA", value: manifest.sourceSHA)
                        LabeledContent("source tree", value: manifest.treeSHA)
                        LabeledContent("构建时间", value: manifest.buildTime)
                        LabeledContent("自动测试状态", value: manifest.automatedTests)
                        LabeledContent("packaged 状态", value: manifest.packagedStatus)
                        LabeledContent("field_verified", value: manifest.fieldVerified ? "是" : "否")
                        LabeledContent("release_ready", value: manifest.releaseReady ? "是" : "否")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("本版新增能力")
                                .font((typography?.caption ?? .caption).weight(.medium))
                            ForEach(manifest.features, id: \.self) { feature in
                                Text("• \(feature)")
                                    .font(typography?.caption ?? .caption)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("仍待现场验证 / 已知问题")
                                .font((typography?.caption ?? .caption).weight(.medium))
                            ForEach(manifest.knownFieldIssues, id: \.self) { issue in
                                Text("• \(issue)")
                                    .font(typography?.caption ?? .caption)
                                    .modifier(ReadableStatusForeground(status: .warning))
                            }
                        }
                    case .unavailable(let message):
                        Text(message)
                            .modifier(ReadableStatusForeground(status: .warning))
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("settings.about.feature-details")
            }

            Section("组件") {
                DisclosureGroup("详细信息") {
                    Text("MinisCore（Settings/EnvVar/Log/Memory/Session/Provider）")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                    Text("CanvasCore（画布 DAG）")
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.about.components-details")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isLegalNoticePresented) { AboutLegalNoticeView() }
    }
}

private struct AboutLegalNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    private func legalText(_ name: String) -> String {
        guard let url = MinisCanvasResourceBundle.current?.bundle.url(
            forResource: name, withExtension: nil, subdirectory: "Legal"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "此安装包未能读取许可证资源（LEGAL-RESOURCE-UNAVAILABLE）。请重新安装完整应用后重试。"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("许可证与第三方声明").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("LICENSE").font(.headline)
                    Text(legalText("LICENSE")).textSelection(.enabled)
                    Text("NOTICE").font(.headline)
                    Text(legalText("NOTICE")).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .accessibilityIdentifier("settings.about.legal-notices-sheet")
    }
}

// MARK: - Preview

#Preview {
    SettingsView(
        center: SettingsCenter(
            settingsStore: SettingsStore(directory: FileManager.default.temporaryDirectory),
            envStore: EnvVarStore(directory: FileManager.default.temporaryDirectory),
            memoryStore: MemoryStore(directory: FileManager.default.temporaryDirectory),
            sessionStore: SessionStore(directory: FileManager.default.temporaryDirectory)
        ),
        shortcutStore: ShortcutStore(),
        skillsStore: SkillsStore(),
        schedulerStore: SchedulerTaskStore(defaults: UserDefaults(suiteName: "scheduler.preview")!)
    )
}


private struct BrowserInteractionRulesSettingsView: View {
    @Bindable var store: BrowserInteractionRuleStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("浏览器站点放行").font(.headline)
            if store.rules.isEmpty { Text("没有已放行的站点动作").foregroundStyle(.secondary) }
            ForEach(store.rules) { rule in
                HStack {
                    VStack(alignment: .leading) {
                        Text(rule.origin.absoluteString)
                        Text("\(rule.category.title) · \(rule.mode == .bypass ? "绕过" : "以后都允许")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("撤销") { store.revoke(rule.id) }
                        .accessibilityIdentifier("settings.browser-revoke-\(rule.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("settings.browser-interaction-rules")
    }
}
