import SwiftUI
import ImageIO
import MinisCore

struct ToolEventCard: View {
    struct DisplayModel: Equatable {
        let kind: String
        let summary: String
        let status: String
        let elapsed: String
        let provider: String
        let model: String
        let errorCategory: String?
        let accessibilityLabel: String
        let browserResult: String?
        let automaticExecutionNotice: String?
        let browserContentIsUntrusted: Bool
        /// 英文内部码只放在展开详情里，不进主句。
        var technicalDetail: String? = nil
    }

    /// 浏览器拒绝/失败的中文原因与做法；英文码单独返回，只在详情显示。
    struct BrowserFailureText: Equatable {
        let text: String
        let code: String
    }

    nonisolated static func browserDenialText(refusalReason: String?) -> BrowserFailureText {
        let code = refusalReason ?? "browser_denied"
        let navPrefix = "navigation_denied:"
        let text: String
        if code == "write_authorization_required" {
            text = "这个浏览器操作（点击、输入、下载或上传）需要你批准后才能执行。请在审批卡中批准，或在设置里调整审批方式"
        } else if code == "invalid_scope" {
            text = "浏览器会话的授权范围已失效。请让助手重新发起该操作"
        } else if code.hasPrefix(navPrefix),
                  let denial = BrowserNavigationPolicy.Denial(rawValue: String(code.dropFirst(navPrefix.count))) {
            switch denial {
            case .invalidScope:
                text = "浏览器会话的授权范围已失效。请让助手重新发起该操作"
            case .staleGeneration:
                text = "浏览器页面已更新，之前的授权已失效。请让助手重新打开网页后再试"
            case .missingURL:
                text = "没有给出网址。请提供完整的 http 或 https 网址"
            case .unsupportedScheme:
                text = "只支持 http 或 https 网址。请换成以 http:// 或 https:// 开头的地址"
            case .missingHost:
                text = "网址缺少主机名。请检查网址是否完整"
            case .invalidURL:
                text = "网址格式无效。请检查拼写后重试"
            case .credentialsInURL:
                text = "网址里不能带账号或密码。请去掉后重试"
            case .domainNotAuthorized, .crossOriginNotAuthorized:
                text = denial == .domainNotAuthorized
                    ? "这个网站不在你允许访问的网站列表里"
                    : "网页要跳转到另一个未被允许的网站"
            case .insecureRedirect:
                text = "网页试图从加密的 https 退回不加密的 http，已被拦截。请改用 https 地址"
            case .newWindowNotAllowed:
                text = "网页要求打开新窗口，已被拦截。请在当前页面内访问目标链接"
            case .downloadNotAuthorized:
                text = "下载需要你逐次批准。请在审批卡中批准后重试"
            case .formSubmissionNotAuthorized:
                text = "提交表单需要你逐次批准。请在审批卡中批准后重试"
            case .requestMethodNotAuthorized:
                text = "该网络请求方式需要你批准。请在审批卡中批准后重试"
            case .resourceUnavailable:
                text = "浏览器当前不可用（可能已关闭或被回收）。请重新打开浏览器后重试"
            }
        } else {
            text = "浏览器拒绝了这次操作。请查看详情，必要时让助手换一种做法"
        }
        let guidance = BrowserNavigationPolicy.settingsGuidance(forBrowserRefusalReason: refusalReason)
        return BrowserFailureText(text: guidance.map { text + "。" + $0 } ?? text, code: code)
    }

    nonisolated static func browserFailureText(failureCode: String?) -> BrowserFailureText {
        let code = failureCode ?? "browser_failed"
        if code == "cannot_go_back" {
            return BrowserFailureText(text: "无法返回：没有上一页", code: code)
        }
        return BrowserFailureText(text: "浏览器操作没有完成。请重试一次；仍失败请让助手换一种方式", code: code)
    }

    let event: MinisCore.ConversationEvent
    private let concurrentEvents: [MinisCore.ConversationEvent]
    private let approvalReceipts: [ComposerApprovalReceipt]
    @State private var isExpanded = false
    @State private var isOutputExpanded = false
    @State private var isInputExpanded = false
    @Environment(BridgeStore.self) private var bridge: BridgeStore?
    @Environment(\.themeTokens) private var theme
    private let liveBoard = ShellLiveOutputBoard.shared

    init(event: MinisCore.ConversationEvent, concurrentEvents: [MinisCore.ConversationEvent] = [],
         approvalReceipts: [ComposerApprovalReceipt] = []) {
        self.event = event
        self.concurrentEvents = concurrentEvents
        self.approvalReceipts = approvalReceipts
    }

    /// Count only dispatched, nonterminal native facts in one exact operation
    /// and attempt. Terminal evidence wins over any late phase replay.
    nonisolated static func concurrentRunningCount(
        for event: MinisCore.ConversationEvent, events: [MinisCore.ConversationEvent]
    ) -> Int {
        guard event.kind == .tool, event.status == .running,
              let target = event.toolCompositeKey, target.isValid else { return 0 }
        let same = events.filter {
            guard $0.kind == .tool, let key = $0.toolCompositeKey, key.isValid else { return false }
            return key.sessionID == target.sessionID && key.turnID == target.turnID
                && key.messageID == target.messageID
                && key.operationID == target.operationID && key.attemptID == target.attemptID
                && key.attemptNumber == target.attemptNumber
                && $0.identity.sessionID == target.sessionID
                && $0.toolCallID == key.toolCallID
        }
        let closed = Set(same.filter { $0.status.isTerminal }.compactMap { $0.toolCompositeKey?.rawValue })
        guard !closed.contains(target.rawValue) else { return 0 }
        let active = Set(same.filter { $0.status == .running }.compactMap { $0.toolCompositeKey?.rawValue })
        return active.subtracting(closed).count
    }

    nonisolated static func displayModel(
        for event: MinisCore.ConversationEvent,
        approvalReceipts: [ComposerApprovalReceipt] = []
    ) -> DisplayModel {
        let projection = MinisCore.ConversationEventProjection.display(for: event)
        let browser = event.kind == .tool ? event.browserDetail : nil
        let action = browser.map { browserActionLabel($0.action) }
        let persistentRuleWasUsed: Bool
        if event.kind == .tool, event.status == .succeeded,
           let key = event.toolCompositeKey, key.isValid {
            persistentRuleWasUsed = approvalReceipts.contains { receipt in
                receipt.persistentRuleID?.isEmpty == false
                    && receipt.sessionID == key.sessionID
                    && receipt.turnID == key.turnID
                    && receipt.messageID == key.messageID
                    && receipt.taskID == event.identity.taskID
                    && receipt.attemptID == key.attemptID
                    && receipt.callID == key.toolCallID
                    && event.toolCallID == key.toolCallID
                    && event.identity.sessionID == key.sessionID
                    && event.identity.turnID == String(key.turnID)
                    && event.identity.attempt == key.attemptNumber
            }
        } else {
            persistentRuleWasUsed = false
        }
        let automaticNotice = event.kind == .tool && event.status == .succeeded && browser?.outcome == "succeeded"
            ? browser?.automaticRuleCategory.map { "已按你的放行自动执行：" + $0.title }
            : (persistentRuleWasUsed ? "已按持久批准规则自动执行" : nil)
        let safeToolAction = browser == nil && (event.kind == .tool || event.kind == .approval)
            ? safeToolActionLabel(event.toolName) : nil
        let target = event.toolTargetDisplay
        let safeOutputSummary = safeToolAction == nil
            ? nil : event.outputSummary?.displaySuffix
        // Old ledger facts have no structured target/output. Restore only
        // their exact producer-owned generic label, never arbitrary summary.
        let missingTargetSummary: String
        if target == nil, safeOutputSummary == nil, let action = safeToolAction,
           let toolName = event.toolName,
           event.summary == "\(action)：参数与结果正文已隐藏"
                || event.summary == "工具调用：\(toolName)" {
            missingTargetSummary = "\(action)：参数与结果正文已隐藏"
        } else {
            missingTargetSummary = "目标未记录"
        }
        let result: String?
        var technicalDetail: String?
        if let browser {
            switch browser.outcome {
            case "denied":
                let denial = browserDenialText(refusalReason: browser.refusalReason)
                result = "已拒绝：" + denial.text
                technicalDetail = "内部代码：" + denial.code
            case "read":
                result = "已读取网页内容 \(browser.readCharacterCount ?? 0) 字符"
            case "failed":
                let failure = browserFailureText(failureCode: browser.failureCode)
                result = failure.text
                technicalDetail = "内部代码：" + failure.code
            default:
                result = browser.resultPreview
            }
        } else {
            result = nil
        }
        let isToolTimeout = browser == nil && event.kind == .tool
            && event.status == .failed && event.errorCategory == .timeout
        let isRefusal = event.approvalDecision == .denied || browser?.outcome == "denied"
        let status = isRefusal ? "已拒绝"
            : browser?.outcome == "failed" ? "失败"
            : isToolTimeout ? "超时" : projection.statusLabel
        let failureReason = safeToolFailureReason(for: event)
        let safeToolErrorCategory = !isRefusal && event.status == .failed
            && event.errorCategory != .tool && event.errorCategory != .unknown
            ? projection.errorCategory : nil
        let kind = browser == nil
            ? (safeToolAction.map { event.kind == .approval ? "审批 · \($0)" : $0 } ?? projection.kindLabel)
            : "浏览器 · \(action ?? "动作")"
        let safeToolAccessibilityFields = [kind, target ?? "目标未记录", status, "耗时 \(projection.elapsed)"]
            + (event.providerID?.isEmpty == false ? ["服务商 \(projection.provider)"] : [])
            + (event.modelID?.isEmpty == false ? ["模型 \(projection.model)"] : [])
            + (safeOutputSummary.map { [$0] } ?? [])
            + (failureReason.map { [$0] } ?? [])
            + (safeToolErrorCategory.map { ["错误 \($0)"] } ?? [])
            + (automaticNotice.map { [$0] } ?? [])
        let accessibilityLabel = browser == nil
            ? (safeToolAction != nil ? safeToolAccessibilityFields.joined(separator: "，")
                : projection.accessibilityLabel)
            : ([kind, target ?? "目标未记录", status, result ?? "无结果"]
                + (automaticNotice.map { [$0] } ?? [])).joined(separator: "，")

        return DisplayModel(
            kind: kind,
            summary: browser != nil ? ["浏览器动作：\(action ?? "未知")", target].compactMap { $0 }.joined(separator: " · ")
                : safeToolAction.map { _ in
                    ([target ?? missingTargetSummary] + (safeOutputSummary.map { [$0] } ?? [])
                        + (failureReason.map { [$0] } ?? []))
                        .joined(separator: " · ")
                } ?? projection.summary,
            status: status,
            elapsed: projection.elapsed,
            provider: projection.provider,
            model: projection.model,
            errorCategory: isRefusal ? nil : (safeToolAction != nil
                ? safeToolErrorCategory : projection.errorCategory),
            accessibilityLabel: accessibilityLabel,
            browserResult: result.map(InvisibleCharacterPolicy.visible),
            automaticExecutionNotice: automaticNotice,
            browserContentIsUntrusted: browser?.outcome == "read",
            technicalDetail: technicalDetail.map(InvisibleCharacterPolicy.visible)
        )
    }

    private nonisolated static func safeToolFailureReason(for event: MinisCore.ConversationEvent) -> String? {
        guard event.status == .failed || event.status == .blocked,
              event.approvalDecision != .denied,
              event.browserDetail?.outcome != "denied" else { return nil }
        if event.kind == .tool, event.toolName == "file_read", event.status == .failed,
           event.approvalDecision == nil, event.browserDetail == nil,
           event.summary == "工具调用：file_read · 读取被拒绝：没有访问此文件的权限" {
            // Exact producer-owned output only; never derive authority/status.
            return "读取被拒绝：没有访问此文件的权限"
        }
        switch event.errorCategory {
        case .timeout:
            return "操作超过时限，请检查已得输出后重试"
        case .authorization:
            return "当前权限不足，请检查审批或授权范围"
        case .provider:
            return providerFailureReason(statusCode: statusCode(in: event.summary))
        case .model:
            return "模型不存在或当前不可用：请检查模型名，或换一个模型"
        case .network:
            return "网络请求未完成，请检查连接后重试"
        case .validation:
            return "参数不完整或无效，请检查后重试"
        case .review:
            return "结果需要复核，请查看详情"
        case .cancelled:
            return nil
        case .tool, .unknown, nil:
            return toolFailureReason(toolName: event.toolName, status: event.status)
        }
    }

    /// 模型服务失败按 HTTP 状态码分流；没有状态码时只给通用说明。
    nonisolated static func providerFailureReason(statusCode: Int?) -> String {
        switch statusCode {
        case 401, 403:
            return "模型服务拒绝了凭据：请到设置里检查或更换 API Key"
        case 404:
            return "模型服务找不到该模型或接口：请检查模型名和服务地址"
        case 429:
            return "模型服务限流或额度用尽：请稍后再试，或检查账户额度"
        case .some(let code) where (500...599).contains(code):
            return "模型服务暂时出错（服务端问题）：请稍后重试"
        default:
            return "模型服务未完成请求：请检查连接与设置里的服务商配置后重试"
        }
    }

    /// 只认带前缀的状态码（如 “HTTP 429”“状态码 401”），避免把摘要里的其他数字当状态码。
    nonisolated static func statusCode(in summary: String) -> Int? {
        guard let range = summary.range(
            of: #"(?i)(?:http|status|状态码)[\s:：]*([45]\d\d)"#, options: .regularExpression) else { return nil }
        let digits = summary[range].filter(\.isNumber)
        return Int(digits.suffix(3))
    }

    /// 工具失败带上工具名与失败阶段：blocked = 未执行（被拦截），其余 = 执行中失败。
    nonisolated static func toolFailureReason(toolName: String?, status: MinisCore.ConversationEventStatus) -> String {
        let label = safeToolActionLabel(toolName).map { "「\($0)」" } ?? "该工具调用"
        return status == .blocked
            ? "\(label)被拦截，没有执行：请查看详情中的原因后重试"
            : "\(label)执行中失败：请查看结果详情后重试"
    }

    // Only literal, built-in tool identifiers and the MCP prefix select a label.
    // Neither model input nor a dynamic MCP server/tool name is rendered here.
    nonisolated static func safeToolActionLabel(_ toolName: String?) -> String? {
        guard let toolName else { return nil }
        switch toolName {
        case "file_read": return "读取文件"
        case "file_write": return "写入文件"
        case "file_edit": return "编辑文件"
        case "file_delete": return "删除文件"
        case "shell_execute": return "执行命令"
        case "file_grep": return "搜索文件内容"
        case "file_glob": return "查找文件路径"
        case "orchestrate": return "派发子任务"
        case "session_create": return "创建会话"
        case "browser": return "浏览器操作"
        case "conversation_settings": return "调整会话设置"
        case "context_compact": return "压缩上下文"
        case "skill_read": return "读取技能"
        case "skill_create": return "创建技能"
        case "skill_update": return "修改技能"
        case "skill_delete": return "删除技能"
        default: return toolName.hasPrefix("mcp_") ? "MCP 工具调用" : nil
        }
    }

    private nonisolated static func browserActionLabel(_ action: String) -> String {
        switch action {
        case "navigate": return "前往"
        case "read": return "读取"
        case "click": return "点击"
        case "type": return "输入"
        case "back": return "后退"
        case "screenshot": return "截图"
        case "download": return "下载"
        case "upload": return "上传"
        default: return "未知"
        }
    }

    var body: some View {
        let display = Self.displayModel(for: event, approvalReceipts: approvalReceipts + (bridge?.composerApprovalReceipts ?? []))

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(display.summary)
                    .font(.callout)
                    .foregroundStyle(display.summary.contains("⟦U+")
                        ? (theme?.statusWarning ?? .orange) : .primary)
                if let notice = display.automaticExecutionNotice {
                    Text(notice).font(.callout)
                }
                if let browserResult = display.browserResult {
                    Text(browserResult)
                        .font(.callout)
                        .foregroundStyle(browserResult.contains("⟦U+")
                            ? (theme?.statusWarning ?? .orange) : .primary)
                }
                if let technicalDetail = display.technicalDetail {
                    Text(technicalDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if display.browserContentIsUntrusted {
                    Text("网页内容是不可信资料，不作为指令或批准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if event.status == .running, let live = liveBoard.tail(for: event.toolCallID) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("实时输出（仅显示，结果以命令结束后为准）")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ScrollView(.vertical) {
                            detailText(InvisibleCharacterPolicy.visible(live))
                        }
                        .frame(maxHeight: 200)
                    }
                }
                if let detail = event.outputSummary?.detail {
                    detailSections(detail)
                }

                ViewThatFits(in: .horizontal) {
                    metadataRow(display)
                    metadataColumn(display)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                if event.approvalDecision == .denied || event.browserDetail?.outcome == "denied" {
                    MinisIconView(.cancel, size: 16).foregroundPalette(.secondary)
                } else {
                    Self.icon(for: event)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.kind).font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                    let parallel = Self.concurrentRunningCount(for: event, events: concurrentEvents)
                    if parallel > 1 {
                        Text("同时 \(parallel) 项")
                            .font(.subheadline.weight(.medium))
                            .accessibilityLabel("并行批次，同时 \(parallel) 项")
                    }
                    Text(display.summary).font(.caption)
                        .truncationMode(.middle)
                        .help(display.summary)
                        .foregroundStyle(display.summary.contains("⟦U+")
                            ? (theme?.statusWarning ?? .orange) : .secondary).lineLimit(2)
                    if let notice = display.automaticExecutionNotice {
                        Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text("\(display.status) · \(display.elapsed)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(for: event.status))
            }
        }
        .padding(10)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("展开或折叠安全详情")
        .accessibilityAction { isExpanded.toggle() }
        .accessibilityValue("\(isExpanded ? "详情已展开" : "详情已折叠")，\(display.summary)")
    }

    /// 完整命令/路径/模式（较长时可折叠）与输出正文（默认折叠）。内容已在采集时脱敏。
    @ViewBuilder
    private func detailSections(_ detail: MinisCore.ToolOutputSummary.ToolCallDetail) -> some View {
        if let input = detail.input {
            let visible = InvisibleCharacterPolicy.visible(input)
            let isLong = visible.count > 160 || visible.contains("\n")
            VStack(alignment: .leading, spacing: 3) {
                if isLong {
                    DisclosureGroup(isExpanded: $isInputExpanded) {
                        detailText(visible)
                    } label: {
                        Text(isInputExpanded ? "完整内容" : "完整内容（点开查看）")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                } else {
                    detailText(visible)
                }
            }
        }
        if let output = detail.output {
            let visible = InvisibleCharacterPolicy.visible(output)
            let lineCount = visible.split(separator: "\n", omittingEmptySubsequences: false).count
            DisclosureGroup(isExpanded: $isOutputExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    ScrollView(.vertical) {
                        detailText(visible)
                    }
                    .frame(maxHeight: 260)
                    if detail.omittedLines > 0 || detail.isTruncated {
                        Text(detail.omittedLines > 0
                             ? "只显示前 \(lineCount) 行，另有 \(detail.omittedLines) 行未显示"
                             : "输出过长，已截断显示")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text(isOutputExpanded ? "输出" : "输出（\(lineCount) 行，点开查看）")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        do {
            let imagePaths = Self.thumbnailPaths(toolName: event.toolName, detail: detail)
            if !imagePaths.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(imagePaths, id: \.self) { path in
                        ToolResultImageThumbnail(path: path)
                    }
                }
            }
        }
        if let fullPath = Self.openableFullOutputPath(detail.fullOutputPath) {
            Button("打开完整输出") {
                _ = TranscriptLocalFileLink.openInTextEditor(URL(fileURLWithPath: fullPath))
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("用文本编辑器打开已保存的完整输出（只读查看）")
        }
    }

    /// 完整输出只认会话输出目录（tool-output）里已存在的普通文件，且不含敏感路径。
    private static func openableFullOutputPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), path.contains("/tool-output/"),
              !path.split(separator: "/").contains(".."),
              !SensitiveFilePolicy.contains(path) else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return path
    }

    /// MCP 工具返回的图片会存进会话输出目录，结果里写成"已保存：<路径>]"；
    /// 只认该目录下已存在、体积不超过 20 MB 的普通图片文件，不含敏感路径，最多取 4 张。
    nonisolated static func savedImagePaths(in output: String) -> [String] {
        var result: [String] = []
        var rest = output[...]
        while result.count < 4, let start = rest.range(of: "已保存：") {
            let tail = rest[start.upperBound...]
            guard let end = tail.firstIndex(of: "]") else { break }
            // 生成端写成"（image/png，已保存：路径）]"，路径后紧跟全角或半角右括号。
            let candidate = String(tail[..<end])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "）)"))
                .trimmingCharacters(in: .whitespaces)
            if let path = openableImagePath(candidate), !result.contains(path) { result.append(path) }
            rest = tail[end...]
        }
        return result
    }

    /// 工具卡片的缩略图来源：MCP 图片（会话输出目录）、file_read 读到的图片文件、浏览器截图（browser_*.jpg）。
    nonisolated static func thumbnailPaths(toolName: String?,
                                           detail: MinisCore.ToolOutputSummary.ToolCallDetail) -> [String] {
        var result: [String] = []
        if let output = detail.output {
            result = savedImagePaths(in: output)
            if toolName == "browser" {
                let plain = output.replacingOccurrences(of: "\\/", with: "/")
                if let range = plain.range(of: "Screenshot saved to: ") {
                    let tail = plain[range.upperBound...]
                    let end = tail.firstIndex(where: { $0 == "\"" || $0 == "\n" || $0 == "\\" }) ?? tail.endIndex
                    let candidate = String(tail[..<end]).trimmingCharacters(in: .whitespaces)
                    if URL(fileURLWithPath: candidate).lastPathComponent.hasPrefix("browser_"),
                       let path = openableImagePath(candidate, requireToolOutputDirectory: false),
                       !result.contains(path) { result.append(path) }
                }
            }
        }
        if toolName == "file_read", let input = detail.input {
            let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.contains("\n"),
               let path = openableImagePath(candidate, requireToolOutputDirectory: false),
               !result.contains(path) { result.append(path) }
        }
        return Array(result.prefix(4))
    }

    nonisolated static func openableImagePath(_ path: String, requireToolOutputDirectory: Bool = true) -> String? {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
        guard path.hasPrefix("/"), !requireToolOutputDirectory || path.contains("/tool-output/"),
              !path.split(separator: "/").contains(".."),
              imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              !SensitiveFilePolicy.contains(path) else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 20 * 1024 * 1024 else { return nil }
        return path
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func metadataRow(_ display: DisplayModel) -> some View {
        HStack(spacing: 10) {
            metadataText("耗时", display.elapsed)
            if event.providerID?.isEmpty == false { metadataText("服务商", display.provider) }
            if event.modelID?.isEmpty == false { metadataText("模型", display.model) }
            if let errorCategory = display.errorCategory {
                metadataText("错误", errorCategory)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataColumn(_ display: DisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metadataText("耗时", display.elapsed)
            if event.providerID?.isEmpty == false { metadataText("服务商", display.provider) }
            if event.modelID?.isEmpty == false { metadataText("模型", display.model) }
            if let errorCategory = display.errorCategory {
                metadataText("错误", errorCategory)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataText(_ label: String, _ value: String) -> some View {
        Text("\(label) \(value)")
            .lineLimit(1)
    }

    private static func icon(for event: MinisCore.ConversationEvent) -> some View {
        let icon: MinisIcon = event.kind == .tool && event.toolName == "file_read"
            ? .documentSearch : semanticIcon(for: event.kind)
        return MinisIconView(icon, size: 16,
                      accessibilityLabel: kindLabel(for: event.kind))
            // The card's text already names the event and its state.
            .accessibilityHidden(true)
    }

    nonisolated static func semanticIcon(for kind: MinisCore.ConversationEventKind) -> MinisIcon {
        switch kind {
        case .thinking: return .activity
        case .stop: return .stop
        case .duration: return .schedule
        case .model: return .server
        case .tool: return .command
        case .approval: return .success
        case .task: return .task
        }
    }

    private nonisolated static func kindLabel(for kind: MinisCore.ConversationEventKind) -> String {
        switch kind {
        case .thinking: return "思考"
        case .stop: return "停止"
        case .duration: return "耗时"
        case .model: return "模型"
        case .tool: return "工具"
        case .approval: return "审批"
        case .task: return "任务"
        }
    }

    private nonisolated static func statusLabel(for status: MinisCore.ConversationEventStatus) -> String {
        switch status {
        case .queued: return "排队中"
        case .requested: return "已请求"
        case .running: return "进行中"
        case .waiting: return "等待中"
        case .needsReview: return "待复核"
        case .succeeded: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .blocked: return "已阻断"
        case .stopped: return "已停止"
        }
    }

    private func statusColor(for status: MinisCore.ConversationEventStatus) -> Color {
        if event.approvalDecision == .denied || event.browserDetail?.outcome == "denied" { return .secondary }
        switch status {
        case .succeeded: return theme?.statusSuccess ?? .green
        case .failed, .blocked: return theme?.statusDanger ?? .red
        case .cancelled, .stopped: return .secondary
        case .waiting, .needsReview: return theme?.statusWarning ?? .orange
        case .queued, .requested, .running: return theme?.aj38.accent.swiftUIColor ?? .accentColor
        }
    }
}

/// 把工具结果里的图片文件送到右侧预览面板；没有安装（面板不可用）时为 nil，只保留系统看图。
private struct PreviewToolOutputFileKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL) -> Void)? = nil
}

extension EnvironmentValues {
    var previewToolOutputFile: (@MainActor (URL) -> Void)? {
        get { self[PreviewToolOutputFileKey.self] }
        set { self[PreviewToolOutputFileKey.self] = newValue }
    }
}

/// 工具结果里已保存图片的缩略图；点击用系统看图工具打开，旁边的“预览”送右侧面板。只显示本地文件，不加载任何远程图片。
struct ToolResultImageThumbnail: View {
    let path: String
    @State private var image: NSImage?
    @Environment(\.previewToolOutputFile) private var previewFile

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200, maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("点击用系统看图工具打开")
                    .accessibilityLabel("工具返回的图片，点击打开")
                    if let previewFile {
                        Button("预览") { previewFile(URL(fileURLWithPath: path)) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("在右侧面板预览这张图片")
                    }
                }
            }
        }
        .task(id: path) {
            if let cached = ToolResultImageThumbnailCache.shared.object(forKey: path as NSString) {
                image = cached
                return
            }
            // 解码放到后台、只解成缩略图，列表滚动时不再在主线程读整张大图。
            let decoded = await Task.detached(priority: .utility) { () -> ThumbnailCGImageBox? in
                let url = URL(fileURLWithPath: path)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    .map { ThumbnailCGImageBox(image: $0) }
            }.value
            guard !Task.isCancelled, let decoded else { return }
            let loaded = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
            ToolResultImageThumbnailCache.shared.setObject(loaded, forKey: path as NSString)
            image = loaded
        }
    }
}

private struct ThumbnailCGImageBox: @unchecked Sendable { let image: CGImage }

private enum ToolResultImageThumbnailCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
}
