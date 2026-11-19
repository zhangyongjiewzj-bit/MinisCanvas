import SwiftUI
import MinisCore

/// The header is only a count chip. Actual lifecycle cards are reached from
/// message-bound nodes inside the transcript, never a second scrolling pane.
@MainActor
struct ChatToolLifecycleView: View {
    let readEvents: () -> [MinisCore.ConversationEvent]

    var body: some View {
        // 外层读一次：投影里的观察信号变化时重算；没有未结束的事件时时钟暂停，空闲不再每 0.5 秒重算。
        let current = readEvents()
        let needsClock = current.contains { !$0.status.isTerminal }
        TimelineView(.animation(minimumInterval: 0.5, paused: !needsClock)) { _ in
            let events = (needsClock ? readEvents() : current).filter { $0.kind == .tool }
            if !events.isEmpty {
                Text("工具 \(events.count) · 失败 \(events.filter { $0.status == .failed }.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("chat-tool-events-count")
            }
        }
    }
}

/// Legacy/unplaced activity remains a separate, explicitly unpositioned group.
/// A turn or wall clock alone cannot invent an assistant text boundary.
struct ChatTranscriptToolGroup: Identifiable {
    let id: String
    let events: [MinisCore.ConversationEvent]

    var title: String {
        let toolCount = events.filter { $0.kind == .tool }.count
        return toolCount > 0 ? "本轮 \(toolCount) 次工具调用" : "本轮 \(events.count) 项审批活动"
    }

    static func groups(events: [MinisCore.ConversationEvent], sessionID: UUID?) -> [Self] {
        guard let sessionID else { return [] }
        let current = events.filter {
            $0.identity.sessionID == sessionID.uuidString && ($0.kind == .tool || $0.kind == .approval)
        }
        return Dictionary(grouping: current, by: { $0.identity.turnID }).map { turnID, values in
            Self(id: turnID, events: values.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.id < $1.id
            })
        }.sorted {
            guard let left = $0.events.first, let right = $1.events.first else { return $0.id < $1.id }
            if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
            return $0.id < $1.id
        }
    }
}

/// Cards expand in the space reserved by the same native transcript layout.
/// Geometry preferences report rendered height; there is no fixed tool pane.
struct ChatInlineToolHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

@MainActor
struct ChatTranscriptToolNode: View {
    let group: ChatTranscriptToolGroup
    var insertionAccessibilityLabel: String? = nil
    var sharedExpansion: Binding<Bool>? = nil
    var showsSummary = true
    var summaryTitle: String? = nil
    @State private var showsDetails = false

    private var expansion: Binding<Bool> { sharedExpansion ?? $showsDetails }
    private var concurrentCount: Int {
        group.events.map { ToolEventCard.concurrentRunningCount(for: $0, events: group.events) }.max() ?? 0
    }
    private var visibleSummary: String {
        let title = summaryTitle ?? group.title
        return concurrentCount > 1 ? title + " · 同时 \(concurrentCount) 项" : title
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.events) { event in
                ToolEventCard(event: event, concurrentEvents: group.events)
                    .accessibilityIdentifier("chat-tool-event-\(event.id)")
            }
        }
    }

    var body: some View {
        Group {
            if showsSummary {
                DisclosureGroup(isExpanded: expansion) {
                    cards
                } label: {
                    Text(visibleSummary)
                        .font(.caption)
                        .accessibilityLabel(insertionAccessibilityLabel.map {
                            concurrentCount > 1 ? $0 + "，同时 \(concurrentCount) 项" : $0
                        } ?? visibleSummary)
                        .accessibilityIdentifier("chat-tool-turn-\(group.id)")
                }
            } else if expansion.wrappedValue {
                cards
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ChatInlineToolHeightPreferenceKey.self,
                    value: [group.id: geometry.size.height])
            }
        }
    }
}
