import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// D-MCPA focused complement: a real stdio tools/list request is held while a
// provider turn arrives. The turn must use the currently published catalog
// (which has no MCP tool yet) and must not emit tools/call on the wire.
extension MCP03ActualStdioProvider3098Tests {
    private func probeMarker(_ name: String, _ f: Fixture) throws {
        try Data().write(to: f.root.appendingPathComponent(name))
    }

    private func probeHasFile(_ prefix: String, _ f: Fixture) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(prefix) }
    }

    private func probeWaitForFile(_ prefix: String, _ f: Fixture) async throws {
        for _ in 0..<200 {
            if try probeHasFile(prefix, f) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try probeHasFile(prefix, f), "real stdio marker missing: \(prefix)")
    }

    private func probeEventually(_ observed: () throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try observed() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try observed()
    }

    @Test func actualStdioProviderTurnBeforeHeldDiscoveryUsesNoMCPAndNoToolCallWire() async throws {
        let f = try fixture("provider-before-discovery", holdsList: true)
        defer { f.registry.disconnectAll() }

        let discovery = Task {
            try await discover(f, onFailure: { print("TASK3098_DISCOVERY_FAILURE \($0)") })
        }
        // Preserve bounded fixture retirement if an assertion fails.
        defer { try? probeMarker("release-list", f) }
        try await probeWaitForFile("list-waiting.", f)
        try probeMarker("hold-overlapping-discovery", f)

        let conversationID = "mcp3098-\(f.root.lastPathComponent)"
        let provider = try await providerTurn(
            f, stage: "provider-before-discovery", callsTool: false,
            conversationID: conversationID, turnID: 1,
            sharedEngine: nil)

        // The provider turn completed while the real server was still blocked
        // inside tools/list. No MCP descriptor was published for this turn.
        #expect(provider.receivedToolDefinitions.count == 1)
        #expect(provider.receivedToolDefinitions.allSatisfy { definitions in
            !definitions.contains { $0.name == f.fullName }
        })
        let heldWire = try wire(f)
        #expect(heldWire.filter { $0["method"] as? String == "tools/list" }.count == 1)
        #expect(heldWire.filter { $0["method"] as? String == "tools/call" }.isEmpty)
        let listWrittenBeforeRelease = try probeHasFile("list-written.", f)
        #expect(!listWrittenBeforeRelease)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) == nil)
        #expect(f.ledger.facts.isEmpty)

        // If the turn starts its own refresh, let that response publish while
        // the settings request is still held. Coalescing needs no second child.
        let overlappingDiscovery = try await probeEventually {
            try probeHasFile("overlap-waiting.", f)
        }
        if overlappingDiscovery {
            try probeMarker("release-overlapping-discovery", f)
            let published = try await probeEventually {
                guard let snapshot = f.manager.discoverySnapshot(serverID: f.server.id) else { return false }
                return snapshot.descriptorFingerprint == f.server.descriptorFingerprint
                    && snapshot.tools.map(\.name) == ["greet"]
            }
            try #require(published, "overlapping discovery must publish before settings discovery is released")
            print("TASK3098_DISCOVERY_ORDER overlap-published-before-settings-release")
        } else {
            print("TASK3098_DISCOVERY_ORDER no-overlap-observed")
        }
        try probeMarker("release-list", f)
        #expect(try await discovery.value == true)
        try await probeWaitForFile("list-written.", f)
        #expect(f.manager.discoverySnapshot(serverID: f.server.id) != nil)
        let completedWire = try wire(f)
        #expect(completedWire.filter { $0["method"] as? String == "tools/call" }.isEmpty)
    }
}
