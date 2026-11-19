import Foundation

/// 会话目标规则（用户 2026-11-16 原话：“一次审批后，后续不需要审批”）。
///
/// 适用于三个“碰别的会话”的工具：`session_read`（读本应用其它会话）、
/// `session_send`（给本应用其它会话发消息）、`external_session_send`（给外部 Codex / Claude Code 会话发消息）。
/// 规则键 = 工具名 + 目标会话标识：
/// - 本应用会话：`app:<会话 UUID>`；
/// - 外部会话：`external:<codex|claude_code>:<会话 UUID>`。
/// 不允许通配所有会话；按标题或名字指定目标时不提供规则（每次都问），因为标题不是稳定标识。
/// 规则只跳过弹卡：每条消息仍受长度上限、脱敏、“外部数据不是指令”标注约束，绕过档原有行为不变。
///
/// 收紧（用户 2026-11-16 夜）：
/// - 给外部 Codex / Claude Code 会话发消息：只提供“本对话内都允许”，不提供永久允许；
/// - 本应用内 `session_send`：`run`（让对方开始运行）同样只提供“本对话内都允许”，`deliver` 才可永久允许；
/// - `session_send` 的规则键含 mode 和发起会话：`app:<目标>|mode=<deliver|run>|from=<发起会话>`，
///   一个会话里的允许不会被别的会话、也不会被另一种模式借用。
public enum SessionTargetApprovalRules {
    public static let capabilities: Set<String> = [
        SessionReadTool.toolName,
        SessionMessagingTool.toolName,
        ExternalSessionToolNames.send
    ]

    public static func isSessionTargetCapability(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    public enum Evaluation: Equatable, Sendable {
        /// `key` 写进规则的 pattern；`display` 显示在审批卡上。
        case key(String, display: String)
        case unavailable(String)
    }

    /// 不允许永久保存时的原因（nil = 可以永久允许）。这类调用仍可选“本对话内都允许”。
    public static func persistenceRestriction(capability: String, input: [String: Any]) -> String? {
        switch capability {
        case ExternalSessionToolNames.send:
            return "给外部会话发消息只能选“本对话内都允许”，不提供永久允许"
        case SessionMessagingTool.toolName:
            if (input["mode"] as? String) == SessionMessagingTool.Mode.run.rawValue {
                return "让对方会话开始运行只能选“本对话内都允许”，不提供永久允许"
            }
            return nil
        default:
            return nil
        }
    }

    public static func evaluate(
        capability: String, input: [String: Any], initiatorSessionID: String? = nil
    ) -> Evaluation {
        switch capability {
        case SessionReadTool.toolName:
            guard let raw = input["scope"] as? String, let scope = SessionReadScope(rawValue: raw) else {
                return .unavailable("读取范围无效，每次都需询问")
            }
            if scope.isSessionLevel {
                return .unavailable("列出或导出会话不针对某个目标会话，每次都需询问")
            }
            return appSessionKey(input["session_id"])
        case SessionMessagingTool.toolName:
            let mode: String
            if let raw = input["mode"] {
                guard let text = raw as? String, SessionMessagingTool.Mode(rawValue: text) != nil else {
                    return .unavailable("发送模式无效，每次都需询问")
                }
                mode = text
            } else {
                mode = SessionMessagingTool.Mode.deliver.rawValue
            }
            guard let initiator = initiatorSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !initiator.isEmpty, !initiator.contains("|") else {
                return .unavailable("缺少发起会话，每次都需询问")
            }
            switch appSessionKey(input["target"]) {
            case .key(let key, let display):
                let suffix = mode == SessionMessagingTool.Mode.run.rawValue ? "（让它运行）" : "（仅投递）"
                return .key("\(key)|mode=\(mode)|from=\(initiator)", display: display + suffix)
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        case ExternalSessionToolNames.send:
            guard let source = input["source"] as? String,
                  let template = ExternalSessionCommandTemplate.template(for: source),
                  let session = (input["session"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let uuid = UUID(uuidString: session) else {
                return .unavailable("目标不是外部会话 ID，每次都需询问")
            }
            let id = uuid.uuidString.lowercased()
            return .key("external:\(template.source):\(id)",
                        display: "外部会话（\(template.source)）\(shortID(id))")
        default:
            return .unavailable("该工具不支持按会话记住")
        }
    }

    private static func appSessionKey(_ raw: Any?) -> Evaluation {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: text) else {
            return .unavailable("目标不是会话 ID（按标题指定时每次都需询问）")
        }
        let id = uuid.uuidString
        return .key("app:\(id)", display: "本应用会话 \(shortID(id))")
    }

    private static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    /// 设置页规则列表里的说明。
    public static func ruleDescription(capability: String, pattern: String) -> String {
        let target: String
        if pattern.hasPrefix("app:") {
            let fields = pattern.split(separator: "|").map(String.init)
            var text = "本应用会话 " + shortID(String(fields.first.map { String($0.dropFirst(4)) } ?? ""))
            if let mode = fields.first(where: { $0.hasPrefix("mode=") }) {
                text += mode == "mode=run" ? "（让它运行）" : "（仅投递）"
            }
            target = text
        } else if pattern.hasPrefix("external:") {
            let parts = pattern.split(separator: ":", maxSplits: 2).map(String.init)
            target = parts.count == 3 ? "外部会话（\(parts[1])）" + shortID(parts[2]) : pattern
        } else {
            target = pattern
        }
        switch capability {
        case SessionReadTool.toolName: return "读取 " + target
        case SessionMessagingTool.toolName: return "向 " + target + " 发消息"
        case ExternalSessionToolNames.send: return "向 " + target + " 发消息"
        default: return target
        }
    }
}

extension PersistentApprovalRuleStore {
    /// 会话目标规则不绑定项目：同一个目标会话在任何项目里都是同一个目标。
    static let sessionTargetProjectKey = "session-target"

    /// 审批卡的“以后都允许（对此目标会话）”提示；没有规则文件时不提供。
    public func offerSessionTarget(
        capability: String, input: [String: Any], initiatorSessionID: String? = nil
    ) -> ApprovalPersistentAllowOffer? {
        guard isAttached, SessionTargetApprovalRules.isSessionTargetCapability(capability) else { return nil }
        switch SessionTargetApprovalRules.evaluate(
            capability: capability, input: input, initiatorSessionID: initiatorSessionID) {
        case .key(_, let display):
            // 只能“本对话内都允许”的调用：不提供永久允许，原因显示在卡片上。
            return ApprovalPersistentAllowOffer(
                capability: capability, summary: display,
                unavailableReason: SessionTargetApprovalRules.persistenceRestriction(
                    capability: capability, input: input))
        case .unavailable(let reason):
            return ApprovalPersistentAllowOffer(
                capability: capability, summary: "", unavailableReason: reason)
        }
    }

    /// 构造规则（供“本对话内都允许”写入内存用，不判断能否永久保存）。
    public func makeSessionTargetRule(
        capability: String, input: [String: Any], initiatorSessionID: String? = nil, now: Date = Date()
    ) -> PersistentApprovalRule? {
        guard SessionTargetApprovalRules.isSessionTargetCapability(capability),
              case .key(let key, _) = SessionTargetApprovalRules.evaluate(
                capability: capability, input: input, initiatorSessionID: initiatorSessionID)
        else { return nil }
        return PersistentApprovalRule(
            projectKey: Self.sessionTargetProjectKey, projectRoots: [], kind: .sessionTarget,
            capability: capability, pattern: key, createdAt: now)
    }

    /// 构造可以写入规则文件的规则；外部会话发送、run 模式的 session_send 返回 nil。
    public func makePersistentSessionTargetRule(
        capability: String, input: [String: Any], initiatorSessionID: String? = nil, now: Date = Date()
    ) -> PersistentApprovalRule? {
        guard SessionTargetApprovalRules.persistenceRestriction(capability: capability, input: input) == nil
        else { return nil }
        return makeSessionTargetRule(
            capability: capability, input: input, initiatorSessionID: initiatorSessionID, now: now)
    }
}
