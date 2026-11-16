import AppKit
import MinisCore

/// Pure text-layout input. The marker is an App-authored newline attribute;
/// it carries no URL, attachment, command, or tool arguments.
struct ChatInlineToolGap: Equatable {
    static let marker = NSAttributedString.Key("MinisCanvas.inlineToolGap")
    let id: String
    let sourceUTF16Offset: Int
    let height: CGFloat

    static func isMarkerID(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
            && Int(parts[1]).map { $0 >= 0 } == true
    }
}

struct ChatTranscriptInlineToolRun: Identifiable {
    let messageID: UUID
    let messageNumber: Int
    let insertionNumber: Int
    let gap: ChatInlineToolGap
    let group: ChatTranscriptToolGroup
    var summaryOwnerID: String? = nil
    var summaryTitle: String? = nil
    var id: String { gap.id }
    var ownsSummary: Bool { summaryOwnerID == nil || summaryOwnerID == id }

    var turnIdentity: AgentTurnIdentity? {
        var result: AgentTurnIdentity?
        for event in group.events {
            guard let key = event.toolCompositeKey ?? event.approvalCompositeKey, key.isValid,
                  event.identity.sessionID == key.sessionID, event.identity.turnID == String(key.turnID),
                  event.toolCallID == key.toolCallID else { return nil }
            let turn = AgentTurnIdentity(sessionID: key.sessionID, turnID: key.turnID, messageID: key.messageID)
            guard turn.isValid, result == nil || result == turn else { return nil }
            result = turn
        }
        return result
    }
    var accessibilityLabel: String {
        "第 \(messageNumber) 条消息，第 \(insertionNumber) 处工具插入点：\(summaryTitle ?? group.title)"
    }
}

enum ChatTranscriptInlineTools {
    static func runs(
        messages: [ChatMessageUI], events: [MinisCore.ConversationEvent], sessionID: UUID?,
        heights: [String: CGFloat], baseSize: CGFloat
    ) -> [ChatTranscriptInlineToolRun] {
        guard let sessionID else { return [] }
        let current = events.filter { $0.identity.sessionID == sessionID.uuidString }
        var byKey: [ToolExecutionCompositeKey: [MinisCore.ConversationEvent]] = [:]
        for event in current where event.kind == .tool || event.kind == .approval {
            if let key = event.toolCompositeKey ?? event.approvalCompositeKey {
                byKey[key, default: []].append(event)
            }
        }
        var runs = messages.enumerated().flatMap { messageIndex, message -> [ChatTranscriptInlineToolRun] in
            guard message.role == .assistant else { return [] }
            let boundaries = Dictionary(grouping: ChatInlineToolAnchor.validated(
                message.inlineToolAnchors, in: message.content), by: \.utf16Offset)
            return boundaries.keys.sorted().enumerated().compactMap { boundaryIndex, offset in
                let keys = Set((boundaries[offset] ?? []).map(\.compositeKey))
                let matching = keys.flatMap { byKey[$0] ?? [] }.sorted {
                    if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                    return $0.id < $1.id
                }
                guard !matching.isEmpty else { return nil }
                let id = message.id.uuidString + ":" + String(offset)
                let minimum = ceil(baseSize + ChatReadingLayout.blockSpacing)
                let gap = ChatInlineToolGap(id: id, sourceUTF16Offset: offset,
                    height: max(minimum, heights[id] ?? minimum))
                return ChatTranscriptInlineToolRun(messageID: message.id,
                    messageNumber: messageIndex + 1, insertionNumber: boundaryIndex + 1, gap: gap,
                    group: ChatTranscriptToolGroup(id: id, events: matching))
            }
        }
        // The first existing text boundary owns the turn summary. Event cards
        // remain in their original runs; only the count and fold state are shared.
        var byTurn: [AgentTurnIdentity: [Int]] = [:]
        for index in runs.indices {
            if let turn = runs[index].turnIdentity { byTurn[turn, default: []].append(index) }
        }
        for indices in byTurn.values {
            guard let first = indices.first else { continue }
            var seen = Set<String>()
            let events = indices.flatMap { runs[$0].group.events }.filter { seen.insert($0.id).inserted }
            let title = ChatTranscriptToolGroup(id: runs[first].id, events: events).title
            let ownerID = runs[first].id
            for index in indices {
                runs[index].summaryOwnerID = ownerID
                runs[index].summaryTitle = title
            }
        }
        return runs
    }

    static func visibleRuns(_ runs: [ChatTranscriptInlineToolRun],
                            expandedTurns: Set<AgentTurnIdentity>) -> [ChatTranscriptInlineToolRun] {
        runs.filter { run in
            run.ownsSummary || run.turnIdentity.map(expandedTurns.contains) == true
        }
    }

    /// A marker without a measured native offset has not positioned a card.
    /// Folded secondary events are represented only by a positioned owner.
    static func positionedEventIDs(_ runs: [ChatTranscriptInlineToolRun], markerIDs: Set<String>,
                                   offsetIDs: Set<String>, expandedTurns: Set<AgentTurnIdentity>) -> Set<String> {
        let positioned = markerIDs.intersection(offsetIDs)
        return Set(runs.filter { run in
            if positioned.contains(run.id) { return true }
            guard let turn = run.turnIdentity, !expandedTurns.contains(turn),
                  let ownerID = run.summaryOwnerID else { return false }
            return positioned.contains(ownerID)
        }.flatMap { $0.group.events.map(\.id) })
    }

    static func gapsByMessage(_ runs: [ChatTranscriptInlineToolRun]) -> [UUID: [ChatInlineToolGap]] {
        Dictionary(grouping: runs, by: \.messageID).mapValues { $0.map(\.gap) }
    }

    static func renderedIDs(in text: NSAttributedString) -> Set<String> {
        var ids = Set<String>()
        text.enumerateAttribute(ChatInlineToolGap.marker, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let id = value as? String { ids.insert(id) }
        }
        return ids
    }
}
