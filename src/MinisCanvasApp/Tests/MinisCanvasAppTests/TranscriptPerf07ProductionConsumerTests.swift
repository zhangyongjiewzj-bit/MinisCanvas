import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// D-PERF-07's bounded in-memory source consumer. Instruments still needs a
/// package-bound App field run for 60/120 Hz and long-run acceptance.
@Suite("D-PERF-07 production transcript signpost paths")
@MainActor
struct TranscriptPerf07ProductionConsumerTests {
    @Test(arguments: [50_000, 100_000])
    func twentyStreamingUpdatesTraverseFormatterNativeApplyAndLayout(characterCount: Int) throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: String(repeating: "史", count: characterCount))
        var tail = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
        let messages = [history, tail]
        let initial = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
        #expect(history.content.utf16.count == characterCount)

        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let initialView = ReadOnlyAttributedTextView(transcriptDocument: initial, update: cache.update)
        let host = initialView.makeNSView(coordinator: coordinator)
        let textView = try #require(host.documentView as? NSTextView)
        let proposal = ProposedViewSize(width: 600, height: nil)
        _ = try #require(initialView.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
        let initialGeneration = cache.update.generation
        let initialRevision = cache.update.revision

        // Unchanged SwiftUI refreshes are a real production path. Their
        // historical equality cost must appear inside TranscriptRender.
        for _ in 0..<20 {
            _ = cache.render(sessionID: session, messages: messages, baseSize: 13, redactor: redactor)
            #expect(cache.update.revision == initialRevision)
            #expect(cache.lastFormattedMessageCount == 0)
        }

        for _ in 1...20 {
            tail.content += "增"
            let document = cache.render(
                sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor
            )
            let view = ReadOnlyAttributedTextView(transcriptDocument: document, update: cache.update)
            view.updateNSView(host, coordinator: coordinator)
            let size = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator))
            #expect(size.height > 0)
            #expect(cache.update.generation == initialGeneration)
            #expect(cache.lastFormattedMessageCount == 1)
            #expect(coordinator.appliedTranscriptRevision == cache.update.revision)
            #expect(coordinator.pendingTailStart == nil)
            #expect(textView.string == document.attributedString.string)
        }
    }

    /// 流畅度第四轮：增量（尾段）测量与缓存命中的高度，必须等于对同一文档全新全量测量的高度。
    @Test func incrementalAndCachedHeightsMatchFreshFullMeasurement() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let history = ChatMessageUI(role: .user, content: "历史消息")
        var tail = ChatMessageUI(role: .assistant, content: "开头", isStreaming: true)
        let first = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
        let coordinator = ReadOnlyAttributedTextView.Coordinator()
        let initialView = ReadOnlyAttributedTextView(transcriptDocument: first, update: cache.update)
        let host = initialView.makeNSView(coordinator: coordinator)
        let proposal = ProposedViewSize(width: 400, height: nil)
        _ = try #require(initialView.sizeThatFits(proposal, nsView: host, coordinator: coordinator))

        func freshHeight(_ document: ChatTranscriptFormattedDocument, width: CGFloat) throws -> CGFloat {
            let freshCoordinator = ReadOnlyAttributedTextView.Coordinator()
            let freshView = ReadOnlyAttributedTextView(
                transcriptDocument: document, update: ChatTranscriptDocumentCache().update)
            let freshHost = freshView.makeNSView(coordinator: freshCoordinator)
            return try #require(freshView.sizeThatFits(
                ProposedViewSize(width: width, height: nil), nsView: freshHost,
                coordinator: freshCoordinator)).height
        }

        var lastDocument = first
        for i in 1...12 {
            tail.content += String(repeating: "流式追加的较长中文内容", count: 3) + (i % 3 == 0 ? "\n\n" : "")
            lastDocument = cache.render(sessionID: session, messages: [history, tail], baseSize: 13, redactor: redactor)
            let view = ReadOnlyAttributedTextView(transcriptDocument: lastDocument, update: cache.update)
            view.updateNSView(host, coordinator: coordinator)
            let incremental = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator)).height
            #expect(abs(incremental - (try freshHeight(lastDocument, width: 400))) < 1)
            // 同宽度再次测量命中缓存，值不变。
            let cached = try #require(view.sizeThatFits(proposal, nsView: host, coordinator: coordinator)).height
            #expect(cached == incremental)
        }
        // 宽度变化后整篇重排，仍与全新测量一致。
        let narrow = ProposedViewSize(width: 260, height: nil)
        let view = ReadOnlyAttributedTextView(transcriptDocument: lastDocument, update: cache.update)
        view.updateNSView(host, coordinator: coordinator)
        let narrowed = try #require(view.sizeThatFits(narrow, nsView: host, coordinator: coordinator)).height
        #expect(abs(narrowed - (try freshHeight(lastDocument, width: 260))) < 1)
    }
}

// MARK: - 流畅度基线（只打印耗时，不做通过/失败断言）

/// 流畅度基线：在合成数据上量化已知热点，便于修复前后对比。
/// 每项重复多次，打印 `PERF name=… n=… median_ms=… p95_ms=…`，没有耗时阈值断言。
/// 只覆盖无界面可测的部分（ChatStore 与转录格式化）；SwiftUI body 次数、真实滚动、
/// AppKit 布局、窗口缩放等需要 Instruments，见《流畅度基线_测量方法.md》。
/// 单独运行：`test_app_multi.sh <标签> PERFBaseline`
@Suite("PERF-BASELINE")
@MainActor
struct PERFBaselineTests {
    // MARK: 工具

    private static func ms(_ work: () -> Void) -> Double {
        let d = ContinuousClock().measure { work() }
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private static func report(_ name: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1))
        print(String(format: "PERF name=%@ n=%d median_ms=%.3f p95_ms=%.3f",
                     name, samples.count, median, sorted[p95Index]))
    }

    private static func sampleBody(_ index: Int, needle: Bool = false) -> String {
        let core = "第 \(index) 条消息：这是一段用于基线测量的合成文本，含 `code`、**加粗** 与列表。- 要点一 - 要点二。"
        return (needle ? "needle-marker " : "") + core + core + core
    }

    private static func makeThread(index: Int, messageCount: Int) -> ChatThread {
        var messages: [ChatMessageUI] = []
        messages.reserveCapacity(messageCount)
        for j in 0..<messageCount {
            messages.append(ChatMessageUI(
                role: j % 2 == 0 ? .user : .assistant,
                content: sampleBody(j, needle: index % 10 == 0 && j == 3)
            ))
        }
        return ChatThread(
            title: "性能基线会话 \(index)",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            messages: messages
        )
    }

    /// 用磁盘预置 + attachPersistence 得到带 N 个会话的 ChatStore（装配耗时不计入测量）。
    private static func makeLoadedStore(sessionCount: Int, messagesPerSession: Int)
        throws -> (chat: ChatStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-baseline-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: root)
        for i in 0..<sessionCount {
            try store.updateSession(makeThread(index: i, messageCount: messagesPerSession).asPersisted())
        }
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        return (chat, root)
    }

    /// 约 `characters` 个字符的类 Markdown 回复；`triggerWords` 为真时每行含凭据探测会匹配的普通词
    /// （无真实密钥），用于量化脱敏慢路径。触发词集合是推测，未对照脱敏实现逐个核实。
    private static func markdownCorpus(characters: Int, triggerWords: Bool) -> [Character] {
        var text = ""
        var i = 0
        while text.count < characters {
            text += "## 小节 \(i)\n\n这是第 \(i) 段说明文字，包含 **加粗**、`行内代码` 和 [链接](https://example.com/\(i))。\n"
            text += "- 列表项 A\n- 列表项 B\n\n```swift\nlet x\(i) = \(i)\n```\n"
            if triggerWords {
                text += "token budget, password policy, api_key rotation, Authorization header, sk- prefix.\n"
            }
            i += 1
        }
        return Array(text.prefix(characters))
    }

    // MARK: 1. persistSessions

    @Test("persistSessions：回合结束一次全量保存", arguments: [200, 500])
    func persistSessionsAfterTurn(sessionCount: Int) throws {
        let (chat, root) = try Self.makeLoadedStore(sessionCount: sessionCount, messagesPerSession: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let save = chat.onSessionsChanged else {
            Issue.record("onSessionsChanged 未接线，无法量化 persistSessions")
            return
        }
        var samples: [Double] = []
        for _ in 0..<7 {
            chat.messages += [ChatMessageUI(role: .assistant, content: "回合结束追加")]
            samples.append(Self.ms { save() })
        }
        Self.report("persist_sessions_s\(sessionCount)_m50", samples)
    }

    // MARK: 2. 流式

    @Test("流式：2 万字回复 20 字一段的每段耗时", arguments: [false, true])
    func streamingPerChunk(triggerWords: Bool) {
        let chunkSize = 20
        let corpus = Self.markdownCorpus(characters: 20_000, triggerWords: triggerWords)
        let broker = ChatCredentialBroker()
        let cache = ChatTranscriptDocumentCache()
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let session = UUID()
        let messageID = UUID()
        var tail = ChatMessageUI(id: messageID, role: .assistant, content: "", isStreaming: true)
        _ = cache.render(sessionID: session, messages: [tail], baseSize: 13, redactor: redactor)

        var redactSamples: [Double] = []
        var renderSamples: [Double] = []
        var offset = 0
        while offset < corpus.count {
            let chunk = String(corpus[offset..<min(offset + chunkSize, corpus.count)])
            offset += chunkSize
            var projected = ""
            let current = tail.content
            redactSamples.append(Self.ms {
                projected = broker.projectStream(messageID: messageID, current: current, append: chunk)
            })
            tail.content = projected
            let snapshot = tail
            renderSamples.append(Self.ms {
                _ = cache.render(sessionID: session, messages: [snapshot], baseSize: 13, redactor: redactor)
            })
        }
        let tag = triggerWords ? "trigger" : "plain"
        let lastTenth = max(1, redactSamples.count / 10)
        Self.report("stream_redact_per_chunk_\(tag)_all", redactSamples)
        Self.report("stream_redact_per_chunk_\(tag)_last10pct", Array(redactSamples.suffix(lastTenth)))
        Self.report("stream_render_per_chunk_\(tag)_all", renderSamples)
        Self.report("stream_render_per_chunk_\(tag)_last10pct", Array(renderSamples.suffix(lastTenth)))
        print("PERF name=stream_prepare_reuse_\(tag) reuse=\(cache.streamPrepareReuseCount) rebuild=\(cache.streamPrepareRebuildCount)")
    }

    // MARK: 3. 转录

    private static func makeTranscript(count: Int) -> [ChatMessageUI] {
        (0..<count).map { j in
            if j % 10 == 9 {
                return ChatMessageUI(
                    role: .tool,
                    content: String(repeating: "build output line with some detail\n", count: 250),
                    toolCallID: "call-\(j)"
                )
            }
            return ChatMessageUI(role: j % 2 == 0 ? .user : .assistant, content: sampleBody(j))
        }
    }

    private static func displayMessages(_ messages: [ChatMessageUI], expanded: Set<UUID>) -> [ChatMessageUI] {
        messages.map {
            ChatTranscriptFormatter.thinkingDisplayMessage(
                ChatTranscriptFormatter.toolOutputDisplayMessage($0, expanded: expanded.contains($0.id)),
                expanded: false)
        }
    }

    @Test("转录：长会话格式化、切换、空刷新与展开工具输出", arguments: [1000])
    func transcriptLongSession(count: Int) {
        let messages = Self.makeTranscript(count: count)
        let redactor = ChatTranscriptRedactor(secretValues: [])

        // 展示投影（transcriptDocumentForDisplay 里的 map 部分）
        var projection: [Double] = []
        for _ in 0..<7 {
            projection.append(Self.ms { _ = Self.displayMessages(messages, expanded: []) })
        }
        Self.report("transcript_display_projection_n\(count)", projection)

        // 修复后路径：展示投影缓存（生产 body 使用）。首次建立不计，测稳态重算。
        let projectionCache = ChatTranscriptDisplayProjectionCache()
        _ = projectionCache.project(messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
        var cachedProjection: [Double] = []
        for _ in 0..<7 {
            cachedProjection.append(Self.ms {
                _ = projectionCache.project(messages, toolExpanded: { _ in false }, thinkingExpanded: { _ in false })
            })
        }
        Self.report("transcript_display_projection_cached_n\(count)", cachedProjection)

        // 全量格式化 = 切换到该会话时视图重建后的首次 render（每次新缓存）
        var full: [Double] = []
        for _ in 0..<5 {
            let cache = ChatTranscriptDocumentCache()
            let display = Self.displayMessages(messages, expanded: [])
            full.append(Self.ms {
                _ = cache.render(sessionID: UUID(), messages: display, baseSize: 13, redactor: redactor)
            })
        }
        Self.report("transcript_full_format_n\(count)", full)

        // 内容未变的重复 render（SwiftUI body 重算时的缓存比较成本）
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        let display = Self.displayMessages(messages, expanded: [])
        _ = cache.render(sessionID: session, messages: display, baseSize: 13, redactor: redactor)
        var unchanged: [Double] = []
        for _ in 0..<20 {
            unchanged.append(Self.ms {
                _ = cache.render(sessionID: session, messages: display, baseSize: 13, redactor: redactor)
            })
        }
        Self.report("transcript_unchanged_render_n\(count)", unchanged)

        // 展开 / 收起一条工具输出（非 samePolicy，整篇重建）
        guard let toolID = messages.first(where: { $0.role == .tool })?.id else { return }
        var toggle: [Double] = []
        var expanded: Set<UUID> = []
        for k in 0..<8 {
            if k % 2 == 0 { expanded = [toolID] } else { expanded = [] }
            let shown = Self.displayMessages(messages, expanded: expanded)
            let ids = expanded
            toggle.append(Self.ms {
                _ = cache.render(sessionID: session, messages: shown, baseSize: 13,
                                 redactor: redactor, expandedToolOutputIDs: ids)
            })
        }
        Self.report("transcript_toggle_tool_output_n\(count)", toggle)
    }

    // MARK: 4. 侧栏 / 搜索 / 切换会话

    @Test("侧栏：sessionGroups、搜索与切换会话", arguments: [500])
    func sidebarAndSwitch(sessionCount: Int) throws {
        let (chat, root) = try Self.makeLoadedStore(sessionCount: sessionCount, messagesPerSession: 50)
        defer { try? FileManager.default.removeItem(at: root) }

        var groups: [Double] = []
        for _ in 0..<10 { groups.append(Self.ms { _ = chat.sessionGroups }) }
        Self.report("sidebar_session_groups_s\(sessionCount)", groups)

        chat.searchText = "needle"
        var filtered: [Double] = []
        for _ in 0..<10 { filtered.append(Self.ms { _ = chat.sessionGroups }) }
        Self.report("sidebar_session_groups_with_search_s\(sessionCount)", filtered)
        chat.searchText = ""

        var search: [Double] = []
        for _ in 0..<5 {
            search.append(Self.ms { _ = chat.searchMessageResults(query: "needle", limit: 100) })
        }
        Self.report("session_search_s\(sessionCount)", search)

        // 切换会话（同步部分；含 onSessionSelectionChanged / onSessionsChanged 触发的保存，取决于装配状态）
        let ids = Array(chat.sessionsSorted.prefix(2).map(\.id))
        guard ids.count == 2 else { return }
        var switches: [Double] = []
        for k in 0..<10 {
            let target = ids[k % 2]
            switches.append(Self.ms { _ = chat.applySwitchSession(id: target) })
        }
        Self.report("session_switch_s\(sessionCount)", switches)
    }

    // MARK: 5. 输入框

    @Test("输入框：5000 字草稿时一次按键的草稿提交", arguments: [false, true])
    func composerKeystroke(triggerWords: Bool) {
        let chat = ChatStore()
        let phrase = triggerWords
            ? "token budget password policy api_key Authorization sk- notes. "
            : "plain draft sentence without any special words in it at all. "
        var draft = ""
        while draft.count < 5000 { draft += phrase }
        draft = String(draft.prefix(5000))
        chat.draftText = draft
        var samples: [Double] = []
        for _ in 0..<50 {
            draft.append("x")
            let value = draft
            samples.append(Self.ms { chat.draftText = value })
        }
        // 只含 ChatStore.setDraftText（含凭据探测）；SwiftUI 外壳重算与 NSTextView 快照需 Instruments。
        Self.report("composer_keystroke_draft5000_\(triggerWords ? "trigger" : "plain")", samples)
    }
}
