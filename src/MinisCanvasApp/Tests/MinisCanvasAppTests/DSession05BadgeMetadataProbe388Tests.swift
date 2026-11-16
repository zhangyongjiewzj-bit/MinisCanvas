import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Metadata is evidence, not a second projection or a claim that the field
/// failure is repaired. Every store here is an explicit isolated authority.
@Suite("D-SESSION-05 opt-in row badge metadata 388")
@MainActor
struct DSession05BadgeMetadataProbe388Tests {
    private struct Fixture {
        let chat: ChatStore
        let badges: SessionBadgeStore
    }

    private func fixture() throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "badge-metadata388", canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        return Fixture(
            chat: ChatStore(preferencesDefaults: profile.makeUserDefaults(),
                            logManager: profile.makeLogManager()),
            badges: SessionBadgeStore(directory: profile.rootDirectory
                .appendingPathComponent("badge-probe", isDirectory: true))
        )
    }

    private func metadata(_ projection: ChatStore.SessionBadgeProjection) throws -> [String: Any] {
        let diagnostic = try #require(projection.diagnostic)
        let data = try #require(diagnostic.accessibilityValue.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data)
        let values = try #require(decoded as? [String: Any])
        let probe = try #require(values["aProbe"] as? [String: Any])
        #expect(Set(probe.keys) == Set(["itemUnread", "liveUnread", "projectAccepted"]))
        for key in ["itemUnread", "liveUnread", "projectAccepted"] {
            let compact = try #require(probe[key] as? NSObject)
            let original = try #require(values[key] as? NSObject)
            #expect(compact.isEqual(original))
        }
        return values
    }

    @Test func actualMarkDistinguishesCapturedItemFromLiveBoolAndFinalProjection() throws {
        let f = try fixture()
        let id = try #require(f.chat.activeSessionID)
        let captured = try #require(f.chat.sessionList.first { $0.id == id })
        #expect(!captured.session.unread)
        f.chat.setUnread(true, sessionID: id)
        let live = try #require(f.chat.sessions.first { $0.id == id })
        let staleObservation = ChatStore.projectSessionBadge(
            for: captured, source: captured.indicator, store: f.badges,
            liveUnread: live.unread, diagnosticsEnabled: true
        )
        let stale = try metadata(staleObservation)
        #expect(stale["liveUnread"] as? Bool == true)
        #expect(stale["itemUnread"] as? Bool == false)
        #expect(stale["finalStatus"] as? String == "idle")
        #expect(stale["beforeBadge"] is NSNull)

        let current = try #require(f.chat.sessionList.first { $0.id == id })
        let observation = ChatStore.projectSessionBadge(
            for: current, source: current.indicator, store: f.badges,
            liveUnread: live.unread, diagnosticsEnabled: true
        )
        let values = try metadata(observation)
        #expect(values["itemUnread"] as? Bool == true)
        #expect(values["projectAccepted"] as? Bool == true)
        #expect(values["sourceTime"] as? Double == current.lastActivityAt.timeIntervalSinceReferenceDate)
        #expect(values["finalStatus"] as? String == "unread")
        #expect(values["finalGlyph"] as? String == "circle.fill")
        let identity = try #require(values["sourceIdentity"] as? [String: Any])
        #expect(identity["sessionID"] as? String == id.uuidString)
        let before = try #require(values["beforeBadge"] as? [String: Any])
        #expect(before["status"] as? String == "idle")
        #expect(f.badges.snapshot(for: id.uuidString)?.presentation() == observation.presentation)
    }

    @Test func optInIsExactAndDisabledProjectionKeepsOrdinaryAXValues() throws {
        #expect(!SessionSidebarView.badgeDiagnosticsRequested(arguments: []))
        #expect(!SessionSidebarView.badgeDiagnosticsRequested(
            arguments: ["--miniscanvas-session-badge-diagnostic=false"]
        ))
        #expect(SessionSidebarView.badgeDiagnosticsRequested(
            arguments: ["--miniscanvas-session-badge-diagnostic"]
        ))
        let f = try fixture()
        let item = try #require(f.chat.sessionList.first)
        f.chat.setUnread(true, sessionID: item.id)
        let current = try #require(f.chat.sessionList.first { $0.id == item.id })
        let ordinary = ChatStore.projectSessionBadge(
            for: current, source: current.indicator, store: f.badges
        )
        #expect(ordinary.diagnostic == nil)
        #expect(ordinary.presentation.status == .unread)
        #expect(SessionSidebarView.sessionRowAccessibilityValue(
            isActive: true, diagnostic: ordinary.diagnostic
        ) == "当前会话")
        #expect(SessionSidebarView.sessionRowAccessibilityValue(
            isActive: false, diagnostic: ordinary.diagnostic
        ) == "会话")
        let enabled = ChatStore.projectSessionBadge(
            for: current, source: current.indicator, store: f.badges,
            liveUnread: true, diagnosticsEnabled: true
        )
        #expect(enabled.presentation == ordinary.presentation)
        let diagnostic = try #require(enabled.diagnostic)
        _ = try metadata(enabled)
        #expect(diagnostic.accessibilityValue.hasPrefix(
            #"{"aProbe":{"itemUnread":true,"liveUnread":true,"projectAccepted":true},"beforeBadge":"#
        ))
        #expect(SessionSidebarView.sessionRowAccessibilityValue(
            isActive: false, diagnostic: diagnostic
        ) == "会话 | badgeDiag=" + diagnostic.accessibilityValue)
    }

    @Test func rejectedSeedIsClassifiedWithoutReplacingItsIdleFallback() throws {
        let f = try fixture()
        let id = try #require(f.chat.activeSessionID)
        let item = try #require(f.chat.sessionList.first { $0.id == id })
        // Artificial classification only: not a natural producer RED.
        let seedTime = item.lastActivityAt.addingTimeInterval(60)
        let seed = f.badges.project(
            identity: .init(sessionID: id.uuidString, turnID: 99, taskID: "private-task-marker",
                            providerID: "private-provider-marker", lineageOwner: "private-owner-marker"),
            source: .idle, unread: false, updatedAt: seedTime
        )
        let before = try #require(seed)
        f.chat.setUnread(true, sessionID: id)
        let marked = try #require(f.chat.sessionList.first { $0.id == id })
        let observation = ChatStore.projectSessionBadge(
            for: marked, source: marked.indicator, store: f.badges,
            liveUnread: true, diagnosticsEnabled: true
        )
        let values = try metadata(observation)
        #expect(values["itemUnread"] as? Bool == true)
        #expect(values["projectAccepted"] as? Bool == false)
        #expect(values["finalStatus"] as? String == "idle")
        #expect(values["finalGlyph"] as? String == "circle")
        let previous = try #require(values["beforeBadge"] as? [String: Any])
        #expect(previous["time"] as? Double == seedTime.timeIntervalSinceReferenceDate)
        let previousIdentity = try #require(previous["identity"] as? [String: Any])
        #expect(previousIdentity["matchesSource"] as? Bool == false)
        #expect(previousIdentity["taskMatchesSource"] as? Bool == false)
        #expect(previousIdentity["turnID"] as? Int == 99)
        #expect(previousIdentity["providerPresent"] as? Bool == true)
        #expect(previousIdentity["ownerPresent"] as? Bool == true)
        #expect(values["finalTime"] as? Double == seedTime.timeIntervalSinceReferenceDate)
        #expect(f.badges.snapshot(for: id.uuidString) == before)
        #expect(observation.presentation == before.presentation())
        #expect(observation.diagnostic?.accessibilityValue.contains("private-task-marker") == false)
        #expect(observation.diagnostic?.accessibilityValue.contains("private-provider-marker") == false)
        #expect(observation.diagnostic?.accessibilityValue.contains("private-owner-marker") == false)
    }

    @Test func failedProjectionMetadataDoesNotExposeFailureOrTaskStrings() throws {
        let f = try fixture()
        let id = try #require(f.chat.activeSessionID)
        let item = try #require(f.chat.sessionList.first { $0.id == id })
        let execution = ChatStore.ExecutionSnapshot(
            sessionID: id, turnID: 7, taskID: "private-execution-task",
            state: .failed, updatedAt: item.lastActivityAt, failureReason: "private-failure-body"
        )
        let failed = ChatStore.SessionListItem(session: item.session, execution: execution)
        let observation = ChatStore.projectSessionBadge(
            for: failed, source: failed.indicator, store: f.badges,
            liveUnread: item.session.unread, diagnosticsEnabled: true
        )
        let values = try metadata(observation)
        #expect(values["sourceStatus"] as? String == "failed")
        #expect(values["projectAccepted"] as? Bool == true)
        #expect(values["finalStatus"] as? String == "failed")
        #expect(values["finalGlyph"] as? String == "exclamationmark.triangle.fill")
        let encoded = try #require(observation.diagnostic?.accessibilityValue)
        #expect(!encoded.contains("private-failure-body"))
        #expect(!encoded.contains("private-execution-task"))
        #expect(!encoded.contains(item.session.title))
    }
}
