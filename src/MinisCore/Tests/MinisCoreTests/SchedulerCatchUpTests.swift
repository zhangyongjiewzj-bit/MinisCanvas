import Foundation
import Testing
@testable import MinisCore

@Suite("Latest missed scheduler occurrence")
struct SchedulerCatchUpTests {
    @Test func keepsOnlyLatestMissedMinuteAndHonorsWatermark() throws {
        let definition = try TaskScheduleDefinition(taskID: "hourly", cronExpression: "0 * * * *",
            timeZoneIdentifier: "UTC", pinnedVersion: 4)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-24T13:30:00Z"))
        let latest = try #require(try TaskScheduler.mostRecentMissedOccurrence(for: definition,
            after: now.addingTimeInterval(-3 * 24 * 3600), before: now))
        #expect(latest.scheduledDate == Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600))
        #expect(latest.pinnedVersion == 4)
        #expect(try TaskScheduler.mostRecentMissedOccurrence(for: definition,
            after: latest.scheduledDate, before: now) == nil)
    }

    @Test func ignoresOlderThanSevenDaysAndUsesSavedZone() throws {
        let definition = try TaskScheduleDefinition(taskID: "monthly", cronExpression: "0 9 1 * *",
            timeZoneIdentifier: "Asia/Shanghai", pinnedVersion: 1)
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-10-15T02:00:00Z"))
        #expect(try TaskScheduler.mostRecentMissedOccurrence(for: definition,
            after: now.addingTimeInterval(-30 * 24 * 3600), before: now) == nil)
        let daily = try TaskScheduleDefinition(taskID: "daily", cronExpression: "0 9 * * *",
            timeZoneIdentifier: "Asia/Shanghai", pinnedVersion: 1)
        #expect(try TaskScheduler.mostRecentMissedOccurrence(for: daily,
            after: now.addingTimeInterval(-24 * 3600), before: now)?.scheduledDate
            == formatter.date(from: "2026-10-15T01:00:00Z"))
    }

    @Test func missedAmbiguousLocalMinuteKeepsExistingDSTRejection() throws {
        let definition = try TaskScheduleDefinition(taskID: "fold", cronExpression: "30 1 * * *",
            timeZoneIdentifier: "America/New_York", pinnedVersion: 1)
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2025-11-02T08:00:00Z"))
        #expect(throws: TaskScheduleValidationError.ambiguousLocalTime) {
            _ = try TaskScheduler.mostRecentMissedOccurrence(for: definition,
                after: now.addingTimeInterval(-24 * 3600), before: now)
        }
    }
}
