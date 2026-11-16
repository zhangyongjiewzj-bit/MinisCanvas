import Foundation
import Testing
@testable import MinisCore

/// Controls discovery completion only; dispatch and registration use Core's
/// actual runner and BuiltinToolExecutor, without a second executor/store.
private actor DiscoveryCohort2108: MCPToolBridge {
    let tools: [MCPBoundTool]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var calledNames: [String] = []

    init(names: [String]) {
        tools = names.map {
            MCPBoundTool(fullName: $0, serverID: "cohort", tool: MCPTool(name: $0))
        }
    }

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == tools.count {
                let cohort = waiters
                waiters.removeAll()
                for waiter in cohort { waiter.resume() }
            }
        }
        return tools
    }

    nonisolated func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        await recordCall(fullName)
    }

    private func recordCall(_ fullName: String) -> String {
        calledNames.append(fullName)
        return "completed:" + fullName
    }

    var calls: [String] { calledNames }
}

@Suite("D-CONC2 shared Builtin registration after discovery")
struct BuiltinConcurrentCatalog2108Tests {
    @Test
    func independentDiscoveredCallsKeepEveryRegistration() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"]))
        // Four simultaneous calls match the production default concurrency
        // cap. Fresh cohorts expose first-use COW registration repeatedly.
        for cohort in 0..<64 {
            let names = (0..<4).map { "mcp_cohort_\(cohort)_tool_\($0)" }
            let bridge = DiscoveryCohort2108(names: names)
            let executor = BuiltinToolExecutor(
                allowedRoot: root, deniedRoots: [], mcpBridge: bridge,
                registeredToolNames: ["file_read"]
            )
            let results = await ConcurrentToolRunner(maxConcurrent: 4).run(
                names.enumerated().map {
                    ToolInvocation(id: "cohort-\(cohort)-\($0.offset)", name: $0.element)
                },
                executor: executor
            )
            #expect(results.count == 4)
            let allSucceeded = results.allSatisfy { $0.isSuccess }
            #expect(allSucceeded)
            #expect(Set(await bridge.calls) == Set(names))
            try #require(Set(names).isSubset(of: executor.registeredToolNames),
                         "independent discovery registrations were lost in cohort \(cohort)")
        }
    }
}
