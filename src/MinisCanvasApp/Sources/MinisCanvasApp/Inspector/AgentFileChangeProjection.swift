import Foundation
import MinisCore

// MARK: - D-OUTPUT-02 变更文件事实（清单:381「智能体创建、修改、删除的文件形成可展开变更列表，并可查看逐文件 Diff」）
//
// 本文件只做纯值投影与纯函数派生：真实写盘仍由 MinisCore BuiltinToolExecutor
// （ToolExecutor.swift runFileWrite :849 / runFileEdit :894）唯一持有；这里在
// RecordingToolExecutor 的成功缝上，从同一次调用的 input（path/content、
// old_string/new_string）与执行前预检派生一条有界、已脱敏的变更文件记录。
// 不新造第二套写盘语义：
// - file_edit 成功即目标文件已存在（ToolExecutor.swift :906-908 fileNotFound
//   前置检查），故 kind 恒为 .edited（修改）；
// - file_write 以执行前的绝对路径存在性区分 .created（创建）与 .overwritten
//   （覆盖修改）；append=true 且已存在为 .appended（追加修改）。
//   路径必为绝对路径：resolveAllowedPath 只接受 `hasPrefix("/")`（
//   ToolExecutor.swift :965-968），相对路径在写 seam 前即 pathViolation。
// - file_delete 仅在真实单文件删除成功后记录 .deleted；shell 删除仍不产生
//   可归属的逐文件 Diff。

/// 一次成功的 Agent 文件写/编辑的可展示事实（有界、脱敏后的逐文件 Diff）。
struct AgentFileChangeRecord: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case created
        case overwritten
        case appended
        case edited
        case deleted

        var label: String {
            switch self {
            case .created: return "新建"
            case .overwritten: return "覆盖写入"
            case .appended: return "追加写入"
            case .edited: return "编辑替换"
            case .deleted: return "删除"
            }
        }
    }

    let id: UUID
    /// 智能体提交给文件工具的绝对路径（原样展示，供用户定位）。
    let path: String
    let kind: Kind
    let timestamp: Date
    /// 产生该事实的工具名（file_write / file_edit / file_delete）。
    let toolName: String
    /// unified diff（git 风格 +/- 行），已按 ContentSecretRedactor 脱敏并有界截断。
    let diffText: String
    let additions: Int
    let deletions: Int
    /// Diff 不完整（旧文超过捕获预算 / 无法按 UTF-8 读取 / 渲染被截断）时为真。
    let diffIsPartial: Bool
}

/// RecordingToolExecutor 使用的纯派生缝：执行前 precheck，执行成功后 change。
enum AgentFileChangeRecorder {
    /// 覆盖写旧文捕获预算：超过则不读取旧内容（Diff 只呈现新增并标记 partial）。
    static let maximumOldTextBytes = 64 * 1024
    /// 逐文件 Diff 存储上限（字符）：不把完整大文件塞进面板（与 OUTPUT-05 有界方向一致）。
    static let maximumDiffCharacters = 6_000

    struct Precheck: Sendable {
        let existedBefore: Bool
        let oldText: String?
        let oldTextOverCaptureBudget: Bool
    }

    static func relevant(_ toolName: String) -> Bool {
        toolName == "file_write" || toolName == "file_edit" || toolName == "file_delete"
    }

    /// Reuse the actual Builtin owner's canonical allow/deny/mount gate.
    /// An absent owner or refused path disables this optional read; it does
    /// not grant, refuse or replace the subsequent tool execution. Capture
    /// the admitted canonical target rather than reopening a raw symlink.
    static func authorizedPrecheckInput(
        toolName: String, input: [String: Any], owner: BuiltinToolExecutor?
    ) -> [String: Any]? {
        guard relevant(toolName), let path = input["path"] as? String,
              let owner else { return nil }
        let validate = owner.fileArtifactTargetValidator()
        for root in [owner.allowedRoot] + owner.additionalAllowedRoots {
            if let target = validate(path, root.path) {
                var admitted = input
                admitted["path"] = target.path
                return admitted
            }
        }
        return nil
    }

    /// Child file effects are projected from the exact receipt's write-locked
    /// ledger, never the outer recorder's potentially stale pre-write sample.
    /// A missing capture omits this optional UI diff rather than inventing one.
    static func authoritativeChildChange(
        toolName: String, input: [String: Any], owner: BuiltinToolExecutor?,
        receipt: ToolExecutionReceipt?, knownSecretValues: [String]
    ) -> AgentFileChangeRecord? {
        guard relevant(toolName), let receipt, receipt.childTranscriptLocator != nil,
              receipt.toolName == toolName, let key = receipt.compositeKey,
              let ledger = owner?.fileChangeLedger,
              let record = ledger.records(sessionID: key.sessionID).last(where: {
                  $0.producerReceiptID == receipt.receiptID && $0.producerCompositeKey == key
              }),
              let payload = ledger.diffPayload(diffID: record.diffID, sessionID: key.sessionID),
              let path = input["path"] as? String else { return nil }
        let kind: AgentFileChangeRecord.Kind
        if toolName == "file_delete" { kind = .deleted }
        else if record.kind == .created { kind = .created }
        else if toolName == "file_edit" { kind = .edited }
        else if input["append"] as? Bool == true { kind = .appended }
        else { kind = .overwritten }
        var text = ContentSecretRedactor.redact(payload.unifiedDiff, knownSecrets: knownSecretValues)
        let partial = text.count > maximumDiffCharacters
        if partial { text = String(text.prefix(maximumDiffCharacters)) + "\n…[diff 已截断]" }
        return AgentFileChangeRecord(id: UUID(), path: path, kind: kind,
            timestamp: record.timestamp, toolName: toolName, diffText: text,
            additions: payload.insertions, deletions: payload.deletions, diffIsPartial: partial)
    }

    /// 在真正执行前捕获写 seam 的可观察前置事实（存在性 + 有界旧文）。
    /// 只在 path 为绝对路径时预检；任何 IO 失败都退化为「无旧文」，绝不抛错、
    /// 绝不阻断真实写盘。
    static func precheck(toolName: String, input: [String: Any]) -> Precheck? {
        guard relevant(toolName),
              let path = input["path"] as? String,
              path.hasPrefix("/"), !path.isEmpty else { return nil }
        let exists = FileManager.default.fileExists(atPath: path)
        guard exists else {
            return Precheck(existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        let append = (input["append"] as? Bool) ?? false
        guard !append, size <= maximumOldTextBytes else {
            return Precheck(
                existedBefore: true,
                oldText: nil,
                oldTextOverCaptureBudget: append ? false : size > maximumOldTextBytes
            )
        }
        let oldText = try? String(contentsOfFile: path, encoding: .utf8)
        return Precheck(existedBefore: true, oldText: oldText, oldTextOverCaptureBudget: false)
    }

    /// 成功后派生一条变更文件事实；base 抛错（写失败）时调用方不会走到这里。
    static func change(
        toolName: String,
        input: [String: Any],
        precheck: Precheck?,
        knownSecretValues: [String],
        timestamp: Date,
        id: UUID = UUID()
    ) -> AgentFileChangeRecord? {
        guard relevant(toolName),
              let path = input["path"] as? String,
              path.hasPrefix("/"), !path.isEmpty else { return nil }
        let pre = precheck ?? Precheck(existedBefore: false, oldText: nil, oldTextOverCaptureBudget: false)

        switch toolName {
        case "file_delete":
            guard pre.existedBefore else { return nil }
            return makeRecord(
                id: id, path: path, kind: .deleted, toolName: toolName,
                timestamp: timestamp, oldText: pre.oldText ?? "", newText: "",
                knownSecretValues: knownSecretValues,
                partialByConstruction: pre.oldText == nil || pre.oldTextOverCaptureBudget
            )
        case "file_edit":
            guard let oldString = input["old_string"] as? String,
                  let newString = input["new_string"] as? String else { return nil }
            return makeRecord(
                id: id, path: path, kind: .edited, toolName: toolName,
                timestamp: timestamp, oldText: oldString, newText: newString,
                knownSecretValues: knownSecretValues,
                partialByConstruction: false
            )
        default: // file_write
            guard let content = input["content"] as? String else { return nil }
            let append = (input["append"] as? Bool) ?? false
            let kind: AgentFileChangeRecord.Kind
            let oldText: String?
            if append {
                kind = pre.existedBefore ? .appended : .created
                // 追加语义：新增内容即 diff 主体；不重构全文件旧文。
                oldText = ""
            } else if pre.existedBefore {
                kind = .overwritten
                oldText = pre.oldText
            } else {
                kind = .created
                oldText = nil
            }
            let partial = (pre.existedBefore && !append && pre.oldText == nil)
                || pre.oldTextOverCaptureBudget
            return makeRecord(
                id: id, path: path, kind: kind, toolName: toolName,
                timestamp: timestamp, oldText: oldText ?? "", newText: content,
                knownSecretValues: knownSecretValues,
                partialByConstruction: partial
            )
        }
    }

    private static func makeRecord(
        id: UUID,
        path: String,
        kind: AgentFileChangeRecord.Kind,
        toolName: String,
        timestamp: Date,
        oldText: String,
        newText: String,
        knownSecretValues: [String],
        partialByConstruction: Bool
    ) -> AgentFileChangeRecord {
        let hunks = TextDiff.diff(old: oldText, new: newText)
        let stats = DiffRenderer.changeStats(hunks)
        var text = ContentSecretRedactor.redact(
            DiffRenderer.renderUnifiedWithHeaders(hunks),
            knownSecrets: knownSecretValues
        )
        var truncated = false
        if text.count > maximumDiffCharacters {
            text = String(text.prefix(maximumDiffCharacters)) + "\n…[diff 已截断]"
            truncated = true
        }
        return AgentFileChangeRecord(
            id: id,
            path: path,
            kind: kind,
            timestamp: timestamp,
            toolName: toolName,
            diffText: text,
            additions: stats.additions,
            deletions: stats.deletions,
            diffIsPartial: partialByConstruction || truncated
        )
    }
}

/// 变更文件行的展示投影（供 ChatInspector 的纯值消费；本文件不触任何 store）。
enum AgentFileChangePresentation {
    static func accessibilityLabel(for change: AgentFileChangeRecord) -> String {
        let partial = change.diffIsPartial ? "，diff 不完整" : ""
        return "\(change.kind.label) \(change.path)，新增 \(change.additions) 行，删除 \(change.deletions) 行\(partial)"
    }
}
