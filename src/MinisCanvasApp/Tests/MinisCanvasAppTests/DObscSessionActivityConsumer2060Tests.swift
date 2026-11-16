import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-OBSC last activity consumer 2060")
@MainActor
struct DObscSessionActivityConsumer2060Tests {
    @Test("canonical session activity reaches the visible row without refreshing the transcript")
    func lastActivityLabelKeepsTimeMovingWhileSessionIsIdle() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "obsc-activity2060", canvasRuntimeState: .disabled
        )
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager()
        )
        let sessionID = try #require(chat.activeSessionID)
        let before = try #require(chat.sessionList.first { $0.id == sessionID })
        chat.appendUser("synthetic activity")
        let after = try #require(chat.sessionList.first { $0.id == sessionID })
        #expect(after.lastActivityAt == after.session.updatedAt)
        #expect(after.lastActivityAt >= before.lastActivityAt)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
            ), encoding: .utf8
        )
        let rowStart = try #require(source.range(of: "private func sessionRow(_ item:"))
        let rowEnd = try #require(source.range(
            of: "private func archivedRow(_ item:", range: rowStart.lowerBound..<source.endIndex
        ))
        let row = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
        #expect(row.contains("SessionSidebarRelativeTime(date: item.lastActivityAt, sessionID: item.session.id)"))
        let relativeTimeViewStart = try #require(source.range(of: "private struct SessionSidebarRelativeTime"))
        let relativeTimeViewEnd = try #require(source.range(
            of: "/// Presentation and input validation only;", range: relativeTimeViewStart.lowerBound..<source.endIndex
        ))
        let relativeTimeView = String(source[relativeTimeViewStart.lowerBound..<relativeTimeViewEnd.lowerBound])
        #expect(relativeTimeView.contains("TimelineView(.periodic(from: .now, by: 30)"))
        #expect(relativeTimeView.contains("SessionSidebarPresentation.relativeTime(date, relativeTo: timeline.date)"))
        #expect(source.contains("LazyVStack(spacing: 3)"))
        #expect(!row.contains("ChatTranscriptTurnTimingStrip"))
    }
}
