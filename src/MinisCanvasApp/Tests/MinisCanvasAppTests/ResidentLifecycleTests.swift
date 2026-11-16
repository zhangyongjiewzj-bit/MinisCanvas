import XCTest
@testable import MinisCanvasApp

@MainActor
final class ResidentLifecycleTests: XCTestCase {
    func testWorkAcquiresOneAssertionAndIdleReleasesIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ResidentAssertionTests.\(UUID().uuidString)"))
        var creates = 0
        var released: [UInt32] = []
        let controller = ResidentLifecycleController(defaults: defaults, createAssertion: {
            creates += 1
            return (0, 42)
        }, releaseAssertion: { id in released.append(id); return 0 })
        controller.updateWorkload(hasWork: true)
        controller.updateWorkload(hasWork: true)
        XCTAssertTrue(controller.isKeepingAwake)
        XCTAssertEqual(creates, 1)
        controller.updateWorkload(hasWork: false)
        XCTAssertFalse(controller.isKeepingAwake)
        XCTAssertEqual(released, [42])
    }

    func testSchedulerExecutionRetainsAssertionAcrossBackgroundRefresh() throws {
        let suite = "ResidentSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var releases = 0
        var backgroundRunning = true
        let controller = ResidentLifecycleController(defaults: defaults,
            createAssertion: { (0, 17) },
            releaseAssertion: { _ in releases += 1; return 0 },
            backgroundHasRunning: { backgroundRunning })
        controller.trackWorkload { false }
        controller.schedulerExecutionChanged(isRunning: true)
        backgroundRunning = false
        controller.backgroundActivityChanged()
        XCTAssertTrue(controller.isKeepingAwake)
        XCTAssertEqual(releases, 0)
        controller.schedulerExecutionChanged(isRunning: false)
        XCTAssertFalse(controller.isKeepingAwake)
        XCTAssertEqual(releases, 1)
    }

    func testKeepAwakePreferenceSurvivesControllerRecreation() throws {
        let suite = "ResidentLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ResidentLifecycleController(defaults: defaults)
        controller.keepAwakeDuringWork = false
        XCTAssertFalse(ResidentLifecycleController(defaults: defaults).keepAwakeDuringWork)
    }
}
