import XCTest
import AppKit
import MinisCore
@testable import MinisCanvasApp

@MainActor
final class O15InlineToolFlowTests: XCTestCase {
    private func key(session: UUID, attempt: Int = 1) -> ToolExecutionCompositeKey {
        ToolExecutionCompositeKey(sessionID: session.uuidString, turnID: 1, messageID: "message",
            operationID: "operation", attemptID: "attempt-\(attempt)", attemptNumber: attempt, toolCallID: "read")
    }
    private func event(session: UUID, key: ToolExecutionCompositeKey, id: String) -> MinisCore.ConversationEvent {
        MinisCore.ConversationEvent(id: id, identity: ConversationEventIdentity(sessionID: session.uuidString,
            turnID: "1", taskID: "task", attempt: key.attemptNumber, scopeID: "scope")!,
            sequence: 1, occurredAt: Date(timeIntervalSince1970: 1), kind: .tool,
            status: .succeeded, summary: "读取完成", toolName: "file_read", toolCallID: "read", toolCompositeKey: key)
    }

    func testExactBoundaryInsertsNodeBetweenAssistantFragmentsWithoutBorrowingRetry() throws {
        let session = UUID()
        var message = ChatMessageUI(role: .assistant, content: "先说明🙂")
        let actualKey = key(session: session)
        message.captureInlineToolAnchor(for: actualKey)
        message.content += "之后继续"
        let messages = [ChatMessageUI(role: .user, content: "请检查"), message]
        let runs = ChatTranscriptInlineTools.runs(messages: messages, events: [
            event(session: session, key: actualKey, id: "actual"),
            event(session: session, key: key(session: session, attempt: 2), id: "other-attempt")
        ], sessionID: session, heights: [:], baseSize: 13)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.group.events.map(\.id), ["actual"])
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.accessibilityLabel,
            "第 2 条消息，第 1 处工具插入点：\(run.group.title)")
        let cache = ChatTranscriptDocumentCache()
        let document = cache.render(sessionID: session, messages: messages, baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: []),
            inlineTools: ChatTranscriptInlineTools.gapsByMessage(runs))
        var markerRange: NSRange?
        document.attributedString.enumerateAttribute(ChatInlineToolGap.marker,
            in: NSRange(location: 0, length: document.attributedString.length)) { value, range, _ in
            if value != nil { markerRange = range }
        }
        let marker = try XCTUnwrap(markerRange)
        let text = document.attributedString.string as NSString
        XCTAssertLessThanOrEqual(NSMaxRange(text.range(of: "先说明🙂")), marker.location)
        XCTAssertGreaterThan(text.range(of: "之后继续").location, marker.location)
        XCTAssertNotNil(cache.inlineToolOffsets(contentWidth: 360)[runs[0].id])
    }

    func testMessageAnchorsMatchFullNativeLayoutAcrossTablesWidthsAndTailUpdates() throws {
        let cache = ChatTranscriptDocumentCache()
        let session = UUID()
        var messages = [
            ChatMessageUI(role: .user, content: "表格之前的合成问题。"),
            ChatMessageUI(role: .assistant, content: "前文。\n\n| 列一 | 列二 |\n|---|---|\n| 合成 | 保留原生表格布局和消息位置。 |\n\n表后说明。"),
            ChatMessageUI(role: .user, content: "表格之后的消息。"),
            ChatMessageUI(role: .assistant, content: "合成流式尾部。")
        ]
        messages[3].isStreaming = true
        for phase in 0..<3 {
            if phase == 1 { messages[3].content += "继续追加，但不移动已经存在的消息起点。" }
            if phase == 2 {
                messages[1].content = messages[1].content.replacingOccurrences(of: "保留原生表格布局和消息位置。",
                    with: String(repeating: "较长的合成单元格用于验证换行后的表后位置。", count: 4))
                messages[3].isStreaming = false
            }
            let document = cache.render(sessionID: session, messages: messages, baseSize: 13,
                redactor: ChatTranscriptRedactor(secretValues: []))
            for width in [CGFloat(360), 500] {
                let actual = cache.messageOffsets(contentWidth: width)
                XCTAssertEqual(actual.count, document.messageStartLocations.count)
                guard actual.count == document.messageStartLocations.count, actual.count == 4 else { continue }
                XCTAssertEqual(cache.messageOffsets(contentWidth: width), actual)
                // Independent AppKit full-document layout is the compatibility
                // oracle, rather than another implementation of anchor math.
                let storage = NSTextStorage(attributedString: document.attributedString)
                let manager = NSLayoutManager()
                let container = NSTextContainer(containerSize:
                    NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                for (index, location) in document.messageStartLocations.enumerated() {
                    let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: location, length: 1),
                        actualCharacterRange: nil)
                    XCTAssertGreaterThan(glyphs.length, 0)
                    let expected = max(0, manager.boundingRect(forGlyphRange: glyphs, in: container).minY)
                    XCTAssertTrue(actual[index].isFinite)
                    XCTAssertEqual(actual[index], expected, accuracy: 0.001,
                        "phase=\(phase) width=\(width) message=\(index)")
                }
                XCTAssertGreaterThan(actual[2], actual[1], "The message after the table must retain its real Y.")
            }
        }
    }

    func testExpandedCardSpaceMovesFollowingMessageAndRetainsSelectableText() {
        let session = UUID()
        let message = ChatMessageUI(role: .assistant, content: "前后正文")
        let following = ChatMessageUI(role: .user, content: "下一条消息")
        let id = message.id.uuidString + ":2"
        let cache = ChatTranscriptDocumentCache()
        let first = cache.render(sessionID: session, messages: [message, following], baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: []),
            inlineTools: [message.id: [ChatInlineToolGap(id: id, sourceUTF16Offset: 2, height: 30)]])
        let collapsedY = cache.messageOffsets(contentWidth: 360)[1]
        let expanded = cache.render(sessionID: session, messages: [message, following], baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: []),
            inlineTools: [message.id: [ChatInlineToolGap(id: id, sourceUTF16Offset: 2, height: 180)]])
        XCTAssertGreaterThan(cache.messageOffsets(contentWidth: 360)[1] - collapsedY, 100)
        XCTAssertEqual(expanded.attributedString.string, first.attributedString.string)
        XCTAssertTrue(expanded.attributedString.string.contains("下一条消息"))
    }

    func testRedactionAcrossToolBoundaryKeepsWholeBodyMaskedWithoutGuessingPosition() {
        let session = UUID()
        var message = ChatMessageUI(role: .assistant, content: "前文abc")
        message.captureInlineToolAnchor(for: key(session: session))
        message.content += "XYZ后文"
        let gap = ChatInlineToolGap(id: message.id.uuidString + ":5", sourceUTF16Offset: 5, height: 30)
        let document = ChatTranscriptFormatter.formattedMessage(message, baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: ["abcXYZ"]), inlineTools: [gap])
        XCTAssertFalse(document.string.contains("abcXYZ"))
        XCTAssertTrue(document.string.contains("前文"))
        XCTAssertTrue(document.string.contains("后文"))
        XCTAssertTrue(ChatTranscriptInlineTools.renderedIDs(in: document).isEmpty)
    }

    func testCanonicalTurnHasOneFoldedSummaryAndKeepsExpandedNativeBoundaries() async throws {
        let session = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("O15-turn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let execution = AgentExecutionIdentity(turn: AgentTurnIdentity(sessionID: session.uuidString,
            turnID: 1, messageID: "message"), operationID: "operation", attempt: 1)
        let consumer = ToolLifecycleConsumer()
        var keys: [ToolExecutionCompositeKey] = []
        for call in ["first", "second"] {
            let receipt = try ledger.mint(toolCallID: call, toolName: "file_read",
                attemptID: "attempt", attemptNumber: 1, executionIdentity: execution)
            keys.append(try XCTUnwrap(receipt.compositeKey))
            let settled = try ledger.settle(receipt, status: .succeeded)
            let fact = try XCTUnwrap(settled)
            let accepted = await consumer.ingestToolExecutionFact(fact, eventID: call, eventName: "file_read",
                taskID: "task", expectedAttemptID: "attempt", scopeID: "scope")
            XCTAssertTrue(accepted)
        }
        let events = consumer.toolLifecycleEvents
        XCTAssertEqual(events.count, 2)
        var message = ChatMessageUI(role: .assistant, content: "前文🙂")
        message.captureInlineToolAnchor(for: keys[0])
        message.content += "中间正文"
        message.captureInlineToolAnchor(for: keys[1])
        message.content += "后文"
        let messages = [ChatMessageUI(role: .user, content: "两个合成只读调用"), message]
        let runs = ChatTranscriptInlineTools.runs(messages: messages, events: events,
            sessionID: session, heights: [:], baseSize: 13)
        XCTAssertEqual(runs.count, 2)
        let first = try XCTUnwrap(runs.first)
        let second = runs[1]
        let turn = try XCTUnwrap(first.turnIdentity)
        XCTAssertEqual(second.turnIdentity, turn)
        XCTAssertEqual(first.group.events.map(\.toolCallID), ["first"])
        XCTAssertEqual(second.group.events.map(\.toolCallID), ["second"])
        XCTAssertTrue(first.ownsSummary)
        XCTAssertFalse(second.ownsSummary)
        XCTAssertEqual(first.summaryTitle, "本轮 2 次工具调用")
        XCTAssertEqual(second.summaryOwnerID, first.id)
        let folded = ChatTranscriptInlineTools.visibleRuns(runs, expandedTurns: [])
        XCTAssertEqual(folded.map(\.id), [first.id])
        let cache = ChatTranscriptDocumentCache()
        _ = cache.render(sessionID: session, messages: messages, baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: []),
            inlineTools: ChatTranscriptInlineTools.gapsByMessage(folded))
        let foldedMarkers = cache.inlineToolMarkerIDs()
        let foldedOffsets = Set(cache.inlineToolOffsets(contentWidth: 360).keys)
        XCTAssertEqual(foldedMarkers, [first.id])
        let allIDs = Set(events.map(\.id))
        XCTAssertEqual(ChatTranscriptInlineTools.positionedEventIDs(runs, markerIDs: foldedMarkers,
            offsetIDs: foldedOffsets, expandedTurns: []), allIDs)
        XCTAssertTrue(ChatTranscriptInlineTools.positionedEventIDs(runs, markerIDs: foldedMarkers,
            offsetIDs: [], expandedTurns: []).isEmpty)
        let expandedTurns: Set<AgentTurnIdentity> = [turn]
        let expanded = ChatTranscriptInlineTools.visibleRuns(runs, expandedTurns: expandedTurns)
        XCTAssertEqual(expanded.map(\.id), runs.map(\.id))
        let document = cache.render(sessionID: session, messages: messages, baseSize: 13,
            redactor: ChatTranscriptRedactor(secretValues: []),
            inlineTools: ChatTranscriptInlineTools.gapsByMessage(expanded))
        let markers = cache.inlineToolMarkerIDs()
        let offsets = Set(cache.inlineToolOffsets(contentWidth: 360).keys)
        XCTAssertEqual(markers, Set(runs.map(\.id)))
        XCTAssertEqual(ChatTranscriptInlineTools.positionedEventIDs(runs, markerIDs: markers,
            offsetIDs: offsets, expandedTurns: expandedTurns), allIDs)
        XCTAssertEqual(ChatTranscriptInlineTools.positionedEventIDs(runs, markerIDs: markers,
            offsetIDs: [first.id], expandedTurns: expandedTurns), Set(first.group.events.map(\.id)))
        var positions: [String: Int] = [:]
        document.attributedString.enumerateAttribute(ChatInlineToolGap.marker,
            in: NSRange(location: 0, length: document.attributedString.length)) { value, range, _ in
            if let id = value as? String { positions[id] = range.location }
        }
        let text = document.attributedString.string as NSString
        let firstPosition = try XCTUnwrap(positions[first.id])
        let secondPosition = try XCTUnwrap(positions[second.id])
        XCTAssertLessThanOrEqual(NSMaxRange(text.range(of: "前文🙂")), firstPosition)
        XCTAssertLessThan(firstPosition, text.range(of: "中间正文").location)
        XCTAssertLessThanOrEqual(NSMaxRange(text.range(of: "中间正文")), secondPosition)
        XCTAssertLessThan(secondPosition, text.range(of: "后文").location)
        // A late-arriving earlier boundary changes only the owner, not the
        // canonical turn's already-expanded state or the later card position.
        let laterOnly = ChatTranscriptInlineTools.runs(messages: messages, events: [events[1]],
            sessionID: session, heights: [:], baseSize: 13)
        XCTAssertEqual(laterOnly.first?.id, second.id)
        XCTAssertEqual(laterOnly.first?.turnIdentity, turn)
        XCTAssertEqual(ChatTranscriptInlineTools.visibleRuns(runs, expandedTurns: expandedTurns).count, 2)
    }

    func testMixedOrMissingCanonicalTurnCannotBorrowAnotherTurnSummary() {
        let session = UUID()
        let actual = key(session: session)
        let first = event(session: session, key: actual, id: "first")
        let otherKey = ToolExecutionCompositeKey(sessionID: session.uuidString, turnID: 2, messageID: "other-message",
            operationID: "other-operation", attemptID: "attempt-1", attemptNumber: 1, toolCallID: "other")
        let other = MinisCore.ConversationEvent(id: "other", identity: ConversationEventIdentity(
            sessionID: session.uuidString, turnID: "2", taskID: "task", attempt: 1, scopeID: "scope")!,
            sequence: 2, occurredAt: Date(timeIntervalSince1970: 2), kind: .tool,
            status: .succeeded, summary: "完成", toolName: "file_read", toolCallID: "other", toolCompositeKey: otherKey)
        let mixed = ChatTranscriptInlineToolRun(messageID: UUID(), messageNumber: 1, insertionNumber: 1,
            gap: ChatInlineToolGap(id: UUID().uuidString + ":0", sourceUTF16Offset: 0, height: 30),
            group: ChatTranscriptToolGroup(id: "mixed", events: [first, other]))
        XCTAssertNil(mixed.turnIdentity)
        XCTAssertTrue(mixed.ownsSummary)
        XCTAssertEqual(ChatTranscriptInlineTools.visibleRuns([mixed], expandedTurns: []).count, 1)
        let missing = MinisCore.ConversationEvent(id: "missing", identity: first.identity,
            sequence: 3, occurredAt: Date(timeIntervalSince1970: 3), kind: .tool,
            status: .succeeded, summary: "旧记录", toolName: "file_read")
        let unknown = ChatTranscriptInlineToolRun(messageID: UUID(), messageNumber: 1, insertionNumber: 1,
            gap: mixed.gap, group: ChatTranscriptToolGroup(id: "unknown", events: [missing]))
        XCTAssertNil(unknown.turnIdentity)
        XCTAssertEqual(ChatTranscriptInlineTools.visibleRuns([unknown], expandedTurns: []).count, 1)
    }

}
