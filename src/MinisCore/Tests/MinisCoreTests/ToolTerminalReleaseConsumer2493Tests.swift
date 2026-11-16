import CoreFoundation
import Foundation
import Testing
@testable import MinisCore

@MainActor
private final class ToolNameLifetime2493 {
    weak var object: NSString?
    init(_ object: NSString) { self.object = object }
    var isAlive: Bool { object != nil }
}

private actor ToolPhysicalGate2493 {
    private var entered = false
    private var exited = false
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        open = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
    func markExited() { exited = true }
    func hasEntered() -> Bool { entered }
    func hasExited() -> Bool { exited }
}

@Suite("D-CONC2 actual tool terminal resource release", .serialized)
@MainActor
struct ToolTerminalReleaseConsumer2493Tests {
    // A foreign immutable CF string gives the real helper's String argument
    // an observable backing object. The controls must prove the bridge keeps
    // it alive and ordinary scope exit releases it before any leak inference.
    private func foreignName() -> (String, ToolNameLifetime2493) {
        let text = "SYNTHETIC_TOOL_2493_" + UUID().uuidString
            + String(repeating: "界", count: 4096)
        let characters = Array(text.utf16)
        let foreign = characters.withUnsafeBufferPointer {
            CFStringCreateWithCharacters(kCFAllocatorDefault, $0.baseAddress, $0.count)!
        }
        let object = unsafeBitCast(foreign, to: NSString.self)
        return (object as String, ToolNameLifetime2493(object))
    }

    private func nameScopeControl() throws -> ToolNameLifetime2493 {
        let (name, lifetime) = foreignName()
        try withExtendedLifetime(name) {
            #expect(name.utf16.count > 4096)
            let retained = lifetime.isAlive
            try #require(retained)
        }
        return lifetime
    }

    @Test("foreign name has a retained backing object and releases without a tool")
    func foreignNameRetainAndReleaseControl() throws {
        let lifetime = try nameScopeControl()
        let released = !lifetime.isAlive
        #expect(released)
    }

    nonisolated private func performActualTimedTool(terminal: String) async throws -> ToolNameLifetime2493 {
        let (name, lifetime) = await foreignName()
        let retained = await lifetime.isAlive
        try #require(retained)
        let root = try minisCoreToolContractRoot("tool-terminal-2493-\(terminal)")
        let file = root.appendingPathComponent("owned.txt")
        try Data("SYNTHETIC_2493_OWNED_FILE".utf8).write(to: file)
        let builtin = BuiltinToolExecutor(
            allowedRoot: root, deniedRoots: [root.appendingPathComponent("denied")]
        )
        let physical = ToolPhysicalGate2493()
        let caller = Task {
            try await executeToolWithTimeout(
                name: name, timeout: terminal == "timeout" ? 0.25 : 60
            ) {
                // This is the actual guarded file consumer. The gate only
                // holds its already-read result so terminal arbitration and
                // actual operation exit can be observed separately.
                let result = try await builtin.execute(
                    name: "file_read", input: ["path": file.path]
                )
                await physical.enterAndWait()
                await physical.markExited()
                return result
            }
        }
        let clock = ContinuousClock()
        let entryDeadline = clock.now.advanced(by: .seconds(2))
        while !(await physical.hasEntered()), clock.now < entryDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await physical.hasEntered()
        if !entered {
            await physical.release()
            caller.cancel()
            _ = try? await caller.value
            try #require(entered)
        }
        if terminal == "success" {
            await physical.release()
            let result = try await caller.value
            #expect(result.contains("SYNTHETIC_2493_OWNED_FILE"))
        } else if terminal == "timeout" {
            var timedOut = false
            do { _ = try await caller.value }
            catch ToolExecutorError.toolTimeout { timedOut = true }
            catch {
                await physical.release()
                throw error
            }
            await physical.release()
            #expect(timedOut)
        } else {
            caller.cancel()
            var cancelled = false
            do { _ = try await caller.value }
            catch is CancellationError { cancelled = true }
            catch {
                await physical.release()
                throw error
            }
            await physical.release()
            #expect(cancelled)
        }
        let exitDeadline = clock.now.advanced(by: .seconds(2))
        while !(await physical.hasExited()), clock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let exited = await physical.hasExited()
        try #require(exited)
        return lifetime
    }

    @Test("actual terminal and physical exit release timer name ownership",
          arguments: ["success", "timeout", "cancel"])
    func terminalReleasesActualName(terminal: String) async throws {
        let lifetime = try await performActualTimedTool(terminal: terminal)
        let clock = ContinuousClock()
        let releaseDeadline = clock.now.advanced(by: .seconds(1))
        while lifetime.isAlive, clock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let released = !lifetime.isAlive
        #expect(released)
    }
}
