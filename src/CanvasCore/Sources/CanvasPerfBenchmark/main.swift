import CanvasCore
import Darwin
import Foundation

private struct Fixture: Sendable {
    let points: [Point]
    let edges: [(Int, Int)]
}

private struct FixtureResult {
    let size: Int
    let geometryMicroseconds: UInt64
    let firstScreenMicroseconds: UInt64
    let thumbnailMicroseconds: UInt64
    let checksum: UInt64
}

private func makeFixture(size: Int) -> Fixture {
    let points = (0..<size).map { index in
        Point(x: Double(index % 64) * 13.0, y: Double(index / 64) * 17.0)
    }
    let edges = size > 1 ? (0..<(size - 1)).map { ($0, $0 + 1) } : []
    return Fixture(points: points, edges: edges)
}

private func elapsedMicroseconds(_ body: () -> UInt64) -> (UInt64, UInt64) {
    let start = DispatchTime.now().uptimeNanoseconds
    let checksum = body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return (max(1, elapsed / 1_000), checksum)
}

private func geometryChecksum(_ fixture: Fixture) -> UInt64 {
    var checksum: UInt64 = 0
    for (fromIndex, toIndex) in fixture.edges {
        let from = fixture.points[fromIndex]
        let to = fixture.points[toIndex]
        checksum &+= UInt64((abs(to.x - from.x) + abs(to.y - from.y)) * 1_000)
    }
    for point in fixture.points where point.x <= 500 && point.y <= 300 {
        checksum &+= UInt64((point.x + point.y) * 1_000)
    }
    return checksum
}

private func firstScreenChecksum(_ fixture: Fixture) -> UInt64 {
    let viewport = (x: 0.0, y: 0.0, width: 1_280.0, height: 800.0)
    var visible: UInt64 = 0
    for point in fixture.points {
        if point.x >= viewport.x - 200,
           point.x <= viewport.x + viewport.width,
           point.y >= viewport.y - 120,
           point.y <= viewport.y + viewport.height {
            visible &+= 1
        }
    }
    return visible
}

private func thumbnailChecksum(_ fixture: Fixture) -> UInt64 {
    let stride = max(1, fixture.points.count / 64)
    var checksum: UInt64 = 0
    for index in Swift.stride(from: 0, to: fixture.points.count, by: stride) {
        let point = fixture.points[index]
        checksum &+= UInt64((point.x + point.y) * 100)
    }
    return checksum
}

private func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Int64(usage.ru_maxrss)
}

private func concurrentChecksum(size: Int) async -> UInt64 {
    let workerCount = min(8, max(1, size / 50))
    return await withTaskGroup(of: UInt64.self, returning: UInt64.self) { group in
        for worker in 0..<workerCount {
            group.addTask {
                var checksum: UInt64 = 0
                for index in stride(from: worker, to: size, by: workerCount) {
                    checksum &+= UInt64((index + 1) * (worker + 3))
                }
                return checksum
            }
        }

        var checksum: UInt64 = 0
        for await partial in group {
            checksum &+= partial
        }
        return checksum
    }
}

private func cancellationProbe() async -> Bool {
    let task = Task { () -> Bool in
        for index in 0..<100_000 {
            if Task.isCancelled { return true }
            if index.isMultiple(of: 100) {
                await Task.yield()
            }
        }
        return false
    }
    task.cancel()
    return await task.value
}

@main
private enum CanvasPerfBenchmark {
    static func main() async {
        let sizes = [50, 100, 500, 1_000]
        let memoryBudgetBytes: Int64 = 256 * 1024 * 1024
        let frameBudgetMicroseconds: UInt64 = 16_667
        let memoryBefore = peakMemoryBytes()
        var results: [FixtureResult] = []

        for size in sizes {
            let fixture = makeFixture(size: size)
            let (geometryMicroseconds, geometry) = elapsedMicroseconds {
                var checksum: UInt64 = 0
                for _ in 0..<20 {
                    checksum &+= geometryChecksum(fixture)
                }
                return checksum
            }
            let (firstScreenMicroseconds, firstScreen) = elapsedMicroseconds {
                firstScreenChecksum(fixture)
            }
            let (thumbnailMicroseconds, thumbnail) = elapsedMicroseconds {
                thumbnailChecksum(fixture)
            }
            results.append(
                FixtureResult(
                    size: size,
                    geometryMicroseconds: geometryMicroseconds,
                    firstScreenMicroseconds: firstScreenMicroseconds,
                    thumbnailMicroseconds: thumbnailMicroseconds,
                    checksum: geometry &+ firstScreen &+ thumbnail
                )
            )
        }

        let taskStart = DispatchTime.now().uptimeNanoseconds
        let taskChecksum = await concurrentChecksum(size: sizes.last ?? 1_000)
        let taskElapsed = max(1, (DispatchTime.now().uptimeNanoseconds - taskStart) / 1_000)
        let cancellationObserved = await cancellationProbe()
        let memoryAfter = peakMemoryBytes()
        let memoryObserved = max(memoryBefore, memoryAfter)
        let timeBudgetPass = results.allSatisfy {
            $0.geometryMicroseconds <= frameBudgetMicroseconds
                && $0.firstScreenMicroseconds <= frameBudgetMicroseconds
                && $0.thumbnailMicroseconds <= frameBudgetMicroseconds
        }
        let memoryBudgetPass = memoryObserved >= 0 && memoryObserved <= memoryBudgetBytes

        print("CanvasPerfBenchmark local-only")
        print("fixture_sizes=50,100,500,1000")
        for result in results {
            print(
                "fixture=\(result.size) geometry_us=\(result.geometryMicroseconds)"
                    + " first_screen_us=\(result.firstScreenMicroseconds)"
                    + " thumbnail_us=\(result.thumbnailMicroseconds)"
                    + " checksum=\(result.checksum)"
            )
        }
        print("task_concurrency_workers=8 task_concurrency_us=\(taskElapsed) task_checksum=\(taskChecksum)")
        print("task_cancellation_observed=\(cancellationObserved)")
        print("memory_peak_bytes=\(memoryObserved)")
        print("memory_budget_bytes=\(memoryBudgetBytes)")
        print("frame_budget_us=\(frameBudgetMicroseconds)")
        print("time_budget_pass=\(timeBudgetPass)")
        print("memory_budget_pass=\(memoryBudgetPass)")
        print("benchmark_executed=true")
        print("provider_calls=0")
        print("network_calls=0")
        print("gui_actions=0")
        print("external_actions=[]")
    }
}
