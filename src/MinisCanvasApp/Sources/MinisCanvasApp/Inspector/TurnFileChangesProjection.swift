import Foundation
import MinisCore

/// Read-only, session/receipt-bound presentation of the existing file ledger.
/// No file discovery, git access, checkpoint mutation, or additional ledger.
struct TurnFileChange: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: Int
    let path: String
    let absolutePath: String
    let additions: Int
    let deletions: Int
    let diff: String
    let exceedsExpandedLimit: Bool
    let sourceIsTruncated: Bool
    var childTaskID: String? = nil

    var expansionLabel: String {
        sourceIsTruncated ? "显示已保留的源片段" : "展开 Diff（最多 64 KB）"
    }
    var sourceTruncationNotice: String? {
        sourceIsTruncated ? "源已截断，展开不能恢复未保留的内容。" : nil
    }
}

enum TurnFileChangesProjection {
    static let previewCharacters = 6_000
    static let expandedBytes = 64 * 1024

    static func capture(
        sessionID: String?, ledger: FileChangeLedger?, facts: [ToolExecutionFact],
        redact: ((String) -> String)?
    ) -> [TurnFileChange] {
        guard let sessionID, !sessionID.isEmpty, let ledger, let redact else { return [] }
        let successful = facts.filter { $0.status == .succeeded }
        return ledger.records(sessionID: sessionID).compactMap { record in
            guard let key = record.producerCompositeKey, key.sessionID == sessionID,
                  let receipt = record.producerReceiptID,
                  successful.contains(where: { $0.receiptID == receipt && $0.compositeKey == key }),
                  let payload = ledger.diffPayload(diffID: record.diffID, sessionID: sessionID)
            else { return nil }
            // Redact before either display limit; a cut must never reveal part of a secret.
            let safe = redact(payload.unifiedDiff)
            return TurnFileChange(
                id: record.diffID, turnID: key.turnID, path: record.path,
                absolutePath: URL(fileURLWithPath: record.workspaceRoot ?? ledger.workspaceRoot)
                    .appendingPathComponent(record.path).path,
                additions: record.insertions, deletions: record.deletions,
                diff: utf8Prefix(safe, bytes: expandedBytes),
                exceedsExpandedLimit: safe.utf8.count > expandedBytes,
                // Exact footer emitted by FileChangeLedger for a bounded delete payload.
                sourceIsTruncated: payload.unifiedDiff.hasSuffix("\n…[diff truncated]"),
                childTaskID: record.childTaskID
            )
        }
    }

    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        var size = 0
        return String(text.prefix { character in
            size += String(character).utf8.count
            return size <= bytes
        })
    }

    static func comment(path: String, line: DiffReviewLine, text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let number = line.newLine ?? line.oldLine else { return nil }
        let side = line.newLine == nil ? "（删除前）" : ""
        return "针对 \(path):\(number)\(side) 的修改意见：\(body)"
    }
}

struct DiffReviewLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let oldLine: Int?
    let newLine: Int?
    var isAddition: Bool { text.hasPrefix("+") && newLine != nil }
    var isDeletion: Bool { text.hasPrefix("-") && oldLine != nil }

    static func parse(_ diff: String) -> [Self] {
        var old: Int?
        var new: Int?
        return diff.components(separatedBy: "\n").enumerated().map { offset, text in
            if text.hasPrefix("@@ ") {
                let fields = text.split(separator: " ")
                old = fields.count > 2 ? fields[1].dropFirst().split(separator: ",").first.flatMap { Int($0) } : nil
                new = fields.count > 2 ? fields[2].dropFirst().split(separator: ",").first.flatMap { Int($0) } : nil
                return Self(id: offset, text: text, oldLine: nil, newLine: nil)
            }
            var before: Int?
            var after: Int?
            if text.hasPrefix("-") { before = old; old = old.map { $0 + 1 } }
            else if text.hasPrefix("+") { after = new; new = new.map { $0 + 1 } }
            else if text.hasPrefix(" ") {
                before = old; after = new
                old = old.map { $0 + 1 }; new = new.map { $0 + 1 }
            }
            return Self(id: offset, text: text, oldLine: before, newLine: after)
        }
    }
}
