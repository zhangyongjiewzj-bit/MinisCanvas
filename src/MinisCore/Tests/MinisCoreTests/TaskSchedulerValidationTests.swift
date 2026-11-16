import Foundation
import Testing
@testable import MinisCore

@Suite("TaskScheduler registration validation")
struct TaskSchedulerValidationTests {
    private func schedule(
        taskID: String = "task-1",
        cron: String,
        timeZone: String = "UTC",
        version: Int = 3
    ) throws -> TaskScheduleDefinition {
        try TaskScheduleDefinition(
            taskID: taskID,
            cronExpression: cron,
            timeZoneIdentifier: timeZone,
            pinnedVersion: version
        )
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        timeZone: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    @Test("canonical cron normalizes fields and rejects malformed schedules")
    func canonicalCronValidationIsFailClosed() throws {
        let normalized = try schedule(cron: "  */15  9-10  1,15  *  7 ")
        #expect(normalized.cronExpression == "0,15,30,45 9,10 1,15 * 0")
        #expect(normalized.timeZoneIdentifier == "UTC")
        #expect(normalized.pinnedVersion == 3)

        #expect(throws: TaskScheduleValidationError.invalidCronExpression) {
            _ = try schedule(cron: "61 * * * *")
        }
        #expect(throws: TaskScheduleValidationError.invalidTimeZone) {
            _ = try schedule(cron: "0 * * * *", timeZone: "Not/AZone")
        }
        #expect(throws: TaskScheduleValidationError.invalidPinnedVersion) {
            _ = try schedule(cron: "0 * * * *", version: 0)
        }
    }

    @Test("next fire is future-only and carries task/version identity")
    func nextFireBindsPinnedOccurrenceIdentity() throws {
        let definition = try schedule(taskID: "daily", cron: "0 0 * * *", version: 8)
        let reference = localDate(year: 2025, month: 1, day: 1, hour: 12, timeZone: "UTC")
        let occurrence = try TaskScheduler.nextOccurrence(for: definition, after: reference)

        #expect(occurrence.taskID == "daily")
        #expect(occurrence.pinnedVersion == 8)
        #expect(occurrence.scheduledDate > reference)
        #expect(occurrence.occurrenceID == "daily#v8#m1735776000")
        #expect(occurrence.timeZoneIdentifier == "UTC")
    }

    @Test("DST gap and repeated local minute fail closed")
    func daylightSavingTransitionsDoNotInventOccurrences() throws {
        let gap = try schedule(
            taskID: "spring",
            cron: "30 2 * * *",
            timeZone: "America/New_York"
        )
        let springReference = localDate(
            year: 2025,
            month: 3,
            day: 9,
            timeZone: "America/New_York"
        )
        #expect(throws: TaskScheduleValidationError.missingLocalTime) {
            _ = try TaskScheduler.nextOccurrence(for: gap, after: springReference)
        }

        let repeated = try schedule(
            taskID: "autumn",
            cron: "30 1 * * *",
            timeZone: "America/New_York"
        )
        let autumnReference = localDate(
            year: 2025,
            month: 11,
            day: 2,
            timeZone: "America/New_York"
        )
        #expect(throws: TaskScheduleValidationError.ambiguousLocalTime) {
            _ = try TaskScheduler.nextOccurrence(for: repeated, after: autumnReference)
        }
    }

    @Test("over-dense schedules and duplicate identities are rejected")
    func denseAndDuplicateOccurrencesFailClosed() throws {
        let dense = try schedule(taskID: "dense", cron: "* * * * *")
        let reference = localDate(year: 2025, month: 1, day: 1, timeZone: "UTC")
        #expect(throws: TaskScheduleValidationError.tooFrequent) {
            _ = try TaskScheduler.nextOccurrence(
                for: dense,
                after: reference,
                minimumSpacing: 120
            )
        }

        let first = try TaskScheduler.nextOccurrence(for: dense, after: reference)
        let duplicate = try TaskScheduleOccurrence(
            definition: dense,
            scheduledDate: first.scheduledDate
        )
        #expect(throws: TaskScheduleValidationError.duplicateOccurrence) {
            _ = try TaskScheduler.uniqueOccurrences([first, duplicate])
        }
        #expect(try TaskScheduler.uniqueOccurrences([first]) == [first])
    }

    @Test("malformed interval or identity is rejected before timer creation")
    func malformedDefinitionsAreRejectedWithoutRegistration() {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        let intervals: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
        for (index, interval) in intervals.enumerated() {
            let task = BackgroundTask(
                id: "invalid-\(index)",
                title: "invalid",
                intervalSeconds: interval
            ) {}
            #expect(!scheduler.register(task))
            #expect(scheduler.task(id: task.id) == nil)
        }

        let blankID = BackgroundTask(
            id: " \n\t ",
            title: "invalid",
            intervalSeconds: 1
        ) {}
        #expect(!scheduler.register(blankID))
        #expect(scheduler.allTasks().isEmpty)
    }

    @Test("invalid replacement preserves the existing valid registration")
    func invalidReplacementDoesNotEraseExistingTask() {
        let scheduler = TaskScheduler()
        defer { scheduler.stopAll() }

        let valid = BackgroundTask(
            id: "stable",
            title: "stable",
            intervalSeconds: 60
        ) {}
        #expect(scheduler.register(valid))

        let invalid = BackgroundTask(
            id: valid.id,
            title: "invalid replacement",
            intervalSeconds: 0
        ) {}
        #expect(!scheduler.register(invalid))
        #expect(scheduler.task(id: valid.id)?.generation == valid.generation)
    }
}
