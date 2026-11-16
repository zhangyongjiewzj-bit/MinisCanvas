import CanvasCore
import Darwin
import Foundation

/// Repeatable local performance probe for the production CanvasCore graph and
/// scheduler APIs.  It intentionally does not construct the SwiftUI app, call
/// a provider, or make network requests.  Results are laboratory evidence only.
private final class BaselineContext: NodeExecutionContext {
    private(set) var executedCount = 0

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        let predecessors = graph.predecessors(of: node.id)
        guard !predecessors.isEmpty else { return nil }
        var inputs: [String: AnyHashable] = [:]
        for predecessor in predecessors {
            if let value = outputs(predecessor.id)?["value"] {
                inputs["input_\(predecessor.id.uuidString)"] = value
            }
        }
        return inputs
    }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executedCount += 1
        let input = inputs?.values.map(String.init(describing:)).sorted().joined(separator: "|") ?? "root"
        return ["value": AnyHashable("node-\(node.title)-\(input)")]
    }
}

private struct ScenarioMeasurement {
    let durations: [Double]
    let checks: [[String: Any]]
    let peakRSSBytes: [Int64]
}

private func stableUUID(_ index: Int, salt: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-%04x-%012x", salt, index + 1))!
}

private func makeGraph(size: Int) -> NodeGraph {
    var graph = NodeGraph()
    for index in 0..<size {
        let input = Port(
            id: stableUUID(index, salt: 0x1000), name: "in", direction: .input, dataType: "text"
        )
        let output = Port(
            id: stableUUID(index, salt: 0x2000), name: "out", direction: .output, dataType: "text"
        )
        graph.addNode(CanvasNode(
            id: stableUUID(index, salt: 0x3000), type: "baseline", title: "N\(index)",
            position: Point(x: Double(index % 64) * 13, y: Double(index / 64) * 17),
            inputs: [input], outputs: [output]
        ))
        if index > 0 {
            graph.addEdge(Edge(
                id: stableUUID(index, salt: 0x4000),
                fromNode: stableUUID(index - 1, salt: 0x3000), fromPort: stableUUID(index - 1, salt: 0x2000),
                toNode: stableUUID(index, salt: 0x3000), toPort: stableUUID(index, salt: 0x1000)
            ))
        }
    }
    return graph
}

private func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Int64(usage.ru_maxrss)
}

private func elapsedMilliseconds(_ body: () throws -> [String: Any]) rethrows -> (Double, [String: Any]) {
    let start = DispatchTime.now().uptimeNanoseconds
    let checks = try body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return (max(0.001, elapsed), checks)
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int(ceil(fraction * Double(sorted.count))) - 1))
    return sorted[index]
}

private func jsonNumber(_ value: Double) -> NSNumber { NSNumber(value: value) }

private func measure(scenario: String, size: Int, samples: Int) throws -> ScenarioMeasurement {
    var durations: [Double] = []
    var checkList: [[String: Any]] = []
    var rssSamples: [Int64] = []
    for _ in 0..<samples {
        let (duration, checks): (Double, [String: Any]) = try elapsedMilliseconds {
            switch scenario {
            case "idle":
                let graph = makeGraph(size: size)
                var checksum = 0
                for _ in 0..<10 {
                    checksum += graph.nodes.count
                    _ = graph.node(id: stableUUID(size / 2, salt: 0x3000))
                    _ = graph.successors(of: stableUUID(size / 2, salt: 0x3000)).count
                }
                return ["checksum": checksum, "graph_nodes": graph.nodes.count]

            case "normal":
                let graph = makeGraph(size: size)
                let context = BaselineContext()
                var scheduler = DAGScheduler()
                var events = 0
                let result = try scheduler.run(graph: graph, context: context) { _ in events += 1 }
                return [
                    "graph_nodes": size, "executed_nodes": context.executedCount,
                    "event_count": events, "succeeded_nodes": result.statuses.values.filter { $0 == .succeeded }.count,
                    "cache_count": scheduler.cacheCount
                ]

            case "stress":
                let graph = makeGraph(size: size)
                let context = BaselineContext()
                var scheduler = DAGScheduler()
                var eventCount = 0
                let first = try scheduler.run(graph: graph, context: context) { _ in eventCount += 1 }
                let second = try scheduler.run(graph: graph, context: context) { _ in eventCount += 1 }
                let firstSucceeded = first.statuses.values.filter { $0 == .succeeded }.count
                let secondCached = second.statuses.values.filter { $0 == .cached }.count
                return [
                    "graph_nodes": size, "iterations": 2, "executed_nodes": context.executedCount,
                    "event_count": eventCount, "cache_count": scheduler.cacheCount,
                    "first_success_nodes": firstSucceeded, "second_cached_nodes": secondCached,
                    "stress_success": firstSucceeded == size && secondCached == size
                ]

            case "recovery":
                let graph = makeGraph(size: size)
                let context = BaselineContext()
                var scheduler = DAGScheduler()
                var firstEvents = 0
                let interrupted = try scheduler.run(
                    graph: graph, context: context,
                    onEvent: { _ in firstEvents += 1 },
                    isCancelled: { context.executedCount >= max(1, size / 2) }
                )
                let resume = Set(interrupted.statuses.compactMap { id, status in
                    status == .succeeded || status == .cached ? id : nil
                })
                var resumeEvents = 0
                let recovered = try scheduler.run(
                    graph: graph, context: context, resumeFrom: resume,
                    seedOutputs: interrupted.outputs,
                    onEvent: { _ in resumeEvents += 1 }
                )
                let recoveredCount = recovered.statuses.values.filter { $0 == .succeeded || $0 == .cached }.count
                return [
                    "graph_nodes": size, "interrupted": interrupted.wasCancelled,
                    "first_events": firstEvents, "resume_events": resumeEvents,
                    "resume_nodes": resume.count, "recovered_nodes": recoveredCount,
                    "final_complete": recoveredCount == size, "cache_count": scheduler.cacheCount
                ]

            case "drag":
                // This exercises the production Point value used by CanvasNode.
                // SwiftUI DragGesture/frame pacing is intentionally not claimed here.
                var checksum = 0.0
                for index in 0..<(size * 10) {
                    let original = Point(x: Double(index % 64) * 13, y: Double(index / 64) * 17)
                    let translated = Point(x: original.x + 18.5, y: original.y - 7.25)
                    checksum += translated.x * 0.25 + translated.y * 0.125
                }
                return ["point_transforms": size * 10, "checksum": jsonNumber(checksum), "ui_exercised": false]

            case "cache":
                let graph = makeGraph(size: size)
                let context = BaselineContext()
                var scheduler = DAGScheduler()
                var firstEvents = 0
                _ = try scheduler.run(graph: graph, context: context) { _ in firstEvents += 1 }
                let executedAfterFirst = context.executedCount
                var cachedEvents = 0
                let second = try scheduler.run(graph: graph, context: context) { event in
                    if case .nodeCached = event { cachedEvents += 1 }
                }
                return [
                    "graph_nodes": size, "first_events": firstEvents,
                    "executed_after_first": executedAfterFirst, "executed_after_second": context.executedCount,
                    "cached_events": cachedEvents, "cached_nodes": second.statuses.values.filter { $0 == .cached }.count,
                    "cache_count": scheduler.cacheCount, "cache_hit_complete": cachedEvents == size
                ]

            default:
                throw NSError(domain: "CanvasPerfBaseline", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown scenario \(scenario)"])
            }
        }
        durations.append(duration)
        checkList.append(checks)
        rssSamples.append(peakMemoryBytes())
    }
    return ScenarioMeasurement(durations: durations, checks: checkList, peakRSSBytes: rssSamples)
}

private func budgetMilliseconds(for scenario: String) -> Double {
    switch scenario {
    // The idle probe includes deterministic graph fixture construction and ten
    // read-only queries.  100 ms is a CLI-operation budget, not a UI frame claim.
    case "idle": return 100
    case "drag": return 16.667
    case "normal", "recovery", "cache": return 5_000
    case "stress": return 15_000
    default: return 0
    }
}

@main
private enum CanvasPerfBaseline {
    static func main() {
        let arguments = CommandLine.arguments
        func value(_ flag: String, default fallback: String) -> String {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return fallback }
            return arguments[index + 1]
        }
        let scenario = value("--scenario", default: "normal")
        let size = max(1, Int(value("--size", default: "1000")) ?? 1000)
        let samples = min(30, max(1, Int(value("--samples", default: "7")) ?? 7))
        do {
            let measurement = try measure(scenario: scenario, size: size, samples: samples)
            let p50 = percentile(measurement.durations, 0.50)
            let p95 = percentile(measurement.durations, 0.95)
            let max = measurement.durations.max() ?? 0
            let budget = budgetMilliseconds(for: scenario)
            let budgetPass = budget > 0 && p95 <= budget
            let payload: [String: Any] = [
                "schema": "miniscanvas.performance-baseline.v1",
                "scenario": scenario, "size": size, "samples": samples,
                "evidence_class": "LOCAL_CLI_BASELINE",
                "field_status": "UNVERIFIED", "release_status": "UNVERIFIED",
                "duration_ms": measurement.durations.map(jsonNumber),
                "p50_ms": jsonNumber(p50), "p95_ms": jsonNumber(p95), "max_ms": jsonNumber(max),
                "budget_p95_ms": jsonNumber(budget), "local_budget_pass": budgetPass,
                "peak_rss_bytes_cumulative_peak": peakMemoryBytes(), "checks": measurement.checks,
                "sample_resources": measurement.peakRSSBytes.map { ["peak_rss_bytes_cumulative_peak": $0] },
                "rss_budget_bytes": NSNull(), "rss_participates_in_local_pass": false,
                "network_calls": 0, "provider_calls": 0, "gui_actions": 0,
                "ui_frame_pacing_measured": false,
                "app_performance_eligible": false,
                "runAll_overall_max_latency": "UNVERIFIED"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            let payload: [String: Any] = ["schema": "miniscanvas.performance-baseline.v1", "error": error.localizedDescription]
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{\"error\":\"serialization\"}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            exit(1)
        }
    }
}
