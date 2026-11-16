import Foundation
#if !TASK3057_SOURCE_QUALIFICATION
import Testing
@testable import MinisCore
#endif

enum NativeTimerScenario3057: String, CaseIterable, Sendable {
    case registerThenDisable, enableThenDisable, unregister, replaceGeneration, ordinary
    var rejectsLateTimer: Bool { self != .ordinary }
    var permitsAction: Bool { self == .ordinary || self == .replaceGeneration }
}

private final class NativeTimerFactory3057: @unchecked Sendable {
    private let lock = NSLock()
    let creationEntered = DispatchSemaphore(value: 0)
    let releaseCreation = DispatchSemaphore(value: 0)
    private var sources: [(any DispatchSourceTimer, DispatchSemaphore)] = []
    private var creationTimedOut = false

    func make(on queue: DispatchQueue) -> any DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let cancelled = DispatchSemaphore(value: 0)
        source.setCancelHandler { cancelled.signal() }
        let first = lock.withLock {
            let first = sources.isEmpty
            sources.append((source, cancelled))
            return first
        }
        if first {
            creationEntered.signal()
            if releaseCreation.wait(timeout: .now() + 5) != .success {
                lock.withLock { creationTimedOut = true }
            }
        }
        return source
    }

    func source(at index: Int) -> (any DispatchSourceTimer, DispatchSemaphore)? {
        lock.withLock { sources.indices.contains(index) ? sources[index] : nil }
    }
    var timedOut: Bool { lock.withLock { creationTimedOut } }
}

private final class NativeTimerActions3057: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    let completed = DispatchSemaphore(value: 0)
    func record(_ name: String) {
        lock.withLock { values.append(name) }
        completed.signal()
    }
    var names: [String] { lock.withLock { values } }
}

struct NativeTimerObservation3057: Sendable {
    let scenario: NativeTimerScenario3057
    let lateSourceCancelled: Bool
    let lateCancellationDelivered: Bool
    let freshSourceCancelled: Bool?
    let enabledAfterControl: Bool?
    let generationAfterControl: UUID?
    let expectedCurrentGeneration: UUID?
    let actionNames: [String]
    let producerExited: Bool
}

/// The factory holds a real suspended DispatchSourceTimer after the actual
/// registration publishes its task, then returns that same native source.
/// No simulated timer, gate, action result, or receipt participates.
enum NativeTimerConsumer3057 {
    enum FixtureError: Error { case creationNotReached, producerDidNotExit, creationTimedOut, missingSource, actionDidNotExit }

    static func observe(_ scenario: NativeTimerScenario3057) throws -> NativeTimerObservation3057 {
        let factory = NativeTimerFactory3057()
        let actions = NativeTimerActions3057()
        let scheduler = TaskScheduler(timerFactory: { factory.make(on: $0) })
        let generation = UUID()
        let task = BackgroundTask(id: "owned-native3057", title: "Owned native timer", intervalSeconds: 3600,
            isEnabled: scenario != .enableThenDisable, generation: generation) { actions.record("old") }
        if scenario == .enableThenDisable {
            _ = scheduler.register(task)
        }
        let producerDone = DispatchGroup()
        producerDone.enter()
        let producer = Thread {
            if scenario == .enableThenDisable {
                _ = scheduler.enable(id: task.id)
            } else {
                _ = scheduler.register(task)
            }
            producerDone.leave()
        }
        producer.start()
        defer {
            factory.releaseCreation.signal()
            _ = producerDone.wait(timeout: .now() + 5)
            scheduler.stopAll()
        }
        guard factory.creationEntered.wait(timeout: .now() + 5) == .success else {
            throw FixtureError.creationNotReached
        }
        var expectedGeneration: UUID? = generation
        switch scenario {
        case .registerThenDisable, .enableThenDisable:
            _ = scheduler.disable(id: task.id)
        case .unregister:
            scheduler.unregister(id: task.id)
            expectedGeneration = nil
        case .replaceGeneration:
            let fresh = BackgroundTask(id: task.id, title: "Fresh generation", intervalSeconds: 3600) {
                actions.record("fresh")
            }
            expectedGeneration = fresh.generation
            _ = scheduler.register(fresh)
        case .ordinary:
            break
        }
        factory.releaseCreation.signal()
        guard producerDone.wait(timeout: .now() + 5) == .success else { throw FixtureError.producerDidNotExit }
        guard !factory.timedOut else { throw FixtureError.creationTimedOut }
        guard let late = factory.source(at: 0) else { throw FixtureError.missingSource }
        let wasCancelled = late.0.isCancelled
        // Observe native cancellation delivery only for a source that was
        // actually cancelled, rather than adding a delay to hide a live source.
        let cancellationDelivered = wasCancelled && late.1.wait(timeout: .now() + 5) == .success
        scheduler.runNow(id: task.id)
        if scenario.permitsAction,
           actions.completed.wait(timeout: .now() + 5) != .success {
            throw FixtureError.actionDidNotExit
        }
        let current = scheduler.task(id: task.id)
        return NativeTimerObservation3057(scenario: scenario, lateSourceCancelled: wasCancelled,
            lateCancellationDelivered: cancellationDelivered,
            freshSourceCancelled: factory.source(at: 1)?.0.isCancelled,
            enabledAfterControl: current?.isEnabled, generationAfterControl: current?.generation,
            expectedCurrentGeneration: expectedGeneration, actionNames: actions.names, producerExited: true)
    }
}

#if !TASK3057_SOURCE_QUALIFICATION
@Suite("3057 actual native timer lifetime follows registration control", .serialized)
struct TaskSchedulerNativeTimerLifetime3057Tests {
    @Test("a late source is cancelled after disable/delete or generation replacement; a fresh source still runs",
          arguments: NativeTimerScenario3057.allCases)
    func nativeResourceIsNotInstalledAfterControl(_ scenario: NativeTimerScenario3057) throws {
        let observed = try NativeTimerConsumer3057.observe(scenario)
        #expect(observed.producerExited)
        #expect(observed.generationAfterControl == observed.expectedCurrentGeneration)
        #expect(observed.lateSourceCancelled == scenario.rejectsLateTimer)
        if scenario.rejectsLateTimer { #expect(observed.lateCancellationDelivered) }
        switch scenario {
        case .registerThenDisable, .enableThenDisable:
            #expect(observed.enabledAfterControl == false)
            #expect(observed.actionNames.isEmpty, "resource cancellation must not be confused with the enabled action guard")
        case .unregister:
            #expect(observed.enabledAfterControl == nil)
            #expect(observed.actionNames.isEmpty)
        case .replaceGeneration:
            #expect(observed.enabledAfterControl == true)
            #expect(observed.freshSourceCancelled == false)
            #expect(observed.actionNames == ["fresh"], "the rejected old source cannot cancel the fresh registration")
        case .ordinary:
            #expect(observed.enabledAfterControl == true)
            #expect(observed.actionNames == ["old"])
        }
    }
}
#endif
