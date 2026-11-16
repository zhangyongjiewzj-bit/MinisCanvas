import Foundation
import Dispatch
import Testing
@testable import MinisCore

enum C0049Scenario: String, Sendable {
    case peerExit
    case backpressure
}

private struct C0049WriteObservation: Sendable {
    let seconds: Double
    let typedTimeout: Bool
    let error: String
}

private actor C0049ObservationBox {
    private var results: [String: C0049WriteObservation] = [:]
    func finish(_ key: String, _ value: C0049WriteObservation) { results[key] = value }
    func snapshot() -> [String: C0049WriteObservation] { results }
}

/// B1122(b): two owned instances of the same never-reading fixture exercise
/// send and notify independently. Keep both stdin read ends open until the
/// write/stop-bound assertions; only SUT last-writer EOF permits natural exit. No global signal
/// disposition changes, test signals, stdin drain, or mocked transport.
@Suite("D-CONC2 C0049 C0206 stdio backpressure", .serialized)
struct MCPStdioBackpressureC0049Tests {
    @Test("live nonreading peer keeps stdin open through write-bound assertions",
          arguments: [C0049Scenario.peerExit, C0049Scenario.backpressure])
    func nonReadingStdinTimesOutAndConcurrentStopReturns(_ scenario: C0049Scenario) async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        if scenario == .peerExit {
            try await peerClosedStdinReturnsTypedErrors(formal: formal)
            return
        }
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("MCP-C0049-B1122-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = root.appendingPathComponent("non-reading-stdin-eof.py")
        let body = #"""
        import os, select, time
        root = os.environ["MCP_C0049_ROOT"]
        def mark(name, text):
            with open(os.path.join(root, name), "w") as f:
                f.write(text + "\n")
        mark("started-pid", str(os.getpid()))
        queue = select.kqueue()
        event = select.kevent(0, filter=select.KQ_FILTER_READ,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE)
        queue.control([event], 0, 0)
        deadline = time.monotonic() + 8
        maximum_buffered_bytes = 0
        while True:
            events = queue.control([], 1, 0.01)
            for event in events:
                maximum_buffered_bytes = max(maximum_buffered_bytes, event.data)
                if event.flags & select.KQ_EV_EOF:
                    mark("eof-exit", "last-writer-closed; stdin-read-calls=0; max-buffered=" + str(maximum_buffered_bytes))
                    queue.close()
                    raise SystemExit(0)
            if os.path.exists(os.path.join(root, "release")):
                mark("release-exit", "external-release-after-all-bound-assertions; stdin-read-calls=0")
                queue.close()
                raise SystemExit(0)
            if time.monotonic() >= deadline:
                mark("bounded-exit", "fixture-backstop; stdin-read-calls=0")
                queue.close()
                raise SystemExit(0)
            # Buffered data is observed via event.data, never consumed.
            time.sleep(0.01)
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        var roots: [String: URL] = [:]
        var transports: [String: MCPStdioTransport] = [:]
        defer {
            for directory in roots.values {
                try? Data("release\n".utf8).write(to: directory.appendingPathComponent("release"))
            }
            for transport in transports.values { transport.stop() }
        }
        for key in ["send", "notify"] {
            let directory = root.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            roots[key] = directory
            let transport = MCPStdioTransport(command: "/usr/bin/python3", args: ["-B", script.path],
                env: ["MCP_C0049_ROOT": directory.path], timeoutSeconds: 1)
            transports[key] = transport
            try await transport.start()
        }
        let sender = try #require(transports["send"])
        let notifier = try #require(transports["notify"])
        let payload = String(repeating: "x", count: 512 * 1024)
        let request = MCPJSONRPCRequest(id: .int(4_049), method: "tools/call",
            params: .object(["payload": .string(payload)]))
        let encodedBytes = try request.encodeLine().utf8.count
        #expect(encodedBytes > 512 * 1024 && encodedBytes < 1_048_576)
        let notification = MCPJSONRPCNotification(method: "notifications/initialized",
            params: .object(["payload": .string(payload)]))
        let box = C0049ObservationBox()
        let send = Task.detached {
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await sender.send(request)
                await box.finish("send", .init(seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9,
                    typedTimeout: false, error: "unexpected response"))
            } catch {
                let timeout: Bool
                if let typed = error as? MCPClientError, case .timeout = typed { timeout = true }
                else { timeout = false }
                await box.finish("send", .init(seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9,
                    typedTimeout: timeout, error: String(describing: error)))
            }
        }
        let notify = Task.detached {
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                try notifier.notify(notification)
                await box.finish("notify", .init(seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9,
                    typedTimeout: false, error: "unexpected success"))
            } catch {
                let timeout: Bool
                if let typed = error as? MCPClientError, case .timeout = typed { timeout = true }
                else { timeout = false }
                await box.finish("notify", .init(seconds: Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9,
                    typedTimeout: timeout, error: String(describing: error)))
            }
        }
        // Do not await the blocked writes on the old product. Observe their
        // completion bounds while both peer stdin read ends remain open.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let observed = await box.snapshot()
        #expect(observed["send"] != nil, "send did not return within the 2s observation window")
        #expect(observed["send"]?.typedTimeout == true, "send must report timeoutSeconds=1")
        #expect((observed["send"]?.seconds ?? .infinity) < 2)
        #expect(observed["notify"] != nil, "notify did not return within the 2s observation window")
        #expect(observed["notify"]?.typedTimeout == true, "notify must report a typed deadline error")
        #expect((observed["notify"]?.seconds ?? .infinity) < 2)
        for directory in roots.values {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("release").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("release-exit").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bounded-exit").path))
        }
        var evidence: [String: Any] = ["scenario": scenario.rawValue, "request_payload_bytes": 512 * 1024,
            "encoded_request_bytes": encodedBytes, "timeout_seconds": 1,
            "send_completed_before_release": observed["send"] != nil,
            "notify_completed_before_release": observed["notify"] != nil,
            "send_seconds": observed["send"].map { $0.seconds as Any } ?? NSNull(),
            "notify_seconds": observed["notify"].map { $0.seconds as Any } ?? NSNull(),
            "send_error": observed["send"].map { $0.error as Any } ?? NSNull(),
            "notify_error": observed["notify"].map { $0.error as Any } ?? NSNull(),
            "peer_stdin_read_calls": 0, "test_signal_calls": 0,
            "phase": "write_assertions_complete_before_release"]
        let preRelease = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try preRelease.write(to: root.appendingPathComponent("C0049_PRE_RELEASE_ASSERTION_FACTS.json"), options: .atomic)
        // No external release permits a broken stop to appear bounded.
        // Only SUT closing its last write FD can trigger fixture EV_EOF.
        let stopWindowStart = DispatchTime.now().uptimeNanoseconds
        let stopSend = Task.detached { () -> Double in
            let began = DispatchTime.now().uptimeNanoseconds
            await box.finish("stop-send-began", .init(seconds: Double(began - stopWindowStart) / 1e9,
                typedTimeout: false, error: "invocation begin"))
            sender.stop()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            await box.finish("stop-send", .init(seconds: elapsed, typedTimeout: false, error: "returned"))
            return elapsed
        }
        let stopNotify = Task.detached { () -> Double in
            let began = DispatchTime.now().uptimeNanoseconds
            await box.finish("stop-notify-began", .init(seconds: Double(began - stopWindowStart) / 1e9,
                typedTimeout: false, error: "invocation begin"))
            notifier.stop()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            await box.finish("stop-notify", .init(seconds: elapsed, typedTimeout: false, error: "returned"))
            return elapsed
        }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let stopObserved = await box.snapshot()
        let stopWindowSeconds = Double(DispatchTime.now().uptimeNanoseconds - stopWindowStart) / 1e9
        #expect(stopObserved["stop-send-began"] != nil && stopObserved["stop-notify-began"] != nil)
        #expect(stopObserved["stop-send"] != nil, "send transport stop did not return before external release")
        #expect((stopObserved["stop-send"]?.seconds ?? .infinity) < 1)
        #expect(stopObserved["stop-notify"] != nil, "notify transport stop did not return before external release")
        #expect((stopObserved["stop-notify"]?.seconds ?? .infinity) < 1)
        for directory in roots.values {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("release").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("release-exit").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bounded-exit").path))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("eof-exit").path),
                    "SUT stop must close the last writer and let zero-read fixture exit naturally")
        }
        evidence["phase"] = "write_and_stop_bound_assertions_complete_before_external_release"
        evidence["stop_observation_window_seconds"] = stopWindowSeconds
        evidence["send_stop_seconds"] = stopObserved["stop-send"].map { $0.seconds as Any } ?? NSNull()
        evidence["notify_stop_seconds"] = stopObserved["stop-notify"].map { $0.seconds as Any } ?? NSNull()
        evidence["send_stop_running_lower_bound"] = stopObserved["stop-send-began"].map {
            stopWindowSeconds - $0.seconds as Any
        } ?? NSNull()
        evidence["notify_stop_running_lower_bound"] = stopObserved["stop-notify-began"].map {
            stopWindowSeconds - $0.seconds as Any
        } ?? NSNull()
        let beforeRelease = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try beforeRelease.write(to: root.appendingPathComponent("C0049_ALL_BOUND_ASSERTIONS_BEFORE_RELEASE.json"), options: .atomic)
        // Failure cleanup only, after every write/stop bound assertion and raw
        // fact is emitted. Old product may SIGPIPE here; retain that outcome.
        for directory in roots.values {
            try Data("release\n".utf8).write(to: directory.appendingPathComponent("release"))
        }
        await send.value
        await notify.value
        let sendStopSeconds = await stopSend.value
        let notifyStopSeconds = await stopNotify.value
        #expect(sendStopSeconds < 1)
        #expect(notifyStopSeconds < 1)
        for directory in roots.values {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("eof-exit").path))
        }
        #expect(!sender.isReady && !notifier.isReady)
        evidence["phase"] = "all_assertions_after_natural_release"
        evidence["send_stop_seconds"] = sendStopSeconds
        evidence["notify_stop_seconds"] = notifyStopSeconds
        let final = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
        try final.write(to: root.appendingPathComponent("C0049_ACTUAL_ASSERTION_FACTS.json"), options: .atomic)
    }

    private func peerClosedStdinReturnsTypedErrors(formal: String) async throws {
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("MCP-C0049-PEER-CLOSED-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = root.appendingPathComponent("closed-stdin.py")
        let body = #"""
        import os, time
        root = os.environ["MCP_C0049_ROOT"]
        def mark(name, value):
            with open(os.path.join(root, name), "w") as f:
                f.write(value + "\n")
        mark("started-pid", str(os.getpid()))
        os.close(0)
        mark("stdin-closed", "explicit-read-calls=0")
        deadline = time.monotonic() + 8
        while not os.path.exists(os.path.join(root, "release")) and time.monotonic() < deadline:
            time.sleep(0.01)
        mark("normal-exit", "release" if os.path.exists(os.path.join(root, "release")) else "backstop")
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        let transport = MCPStdioTransport(command: "/usr/bin/python3", args: ["-B", script.path],
            env: ["MCP_C0049_ROOT": root.path], timeoutSeconds: 1)
        let release = root.appendingPathComponent("release")
        defer {
            try? Data("release\n".utf8).write(to: release)
            transport.stop()
        }
        try await transport.start()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("stdin-closed").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("stdin-closed").path))
        let request = MCPJSONRPCRequest(id: .int(4_050), method: "tools/call", params: nil)
        let sendStart = DispatchTime.now().uptimeNanoseconds
        var sendError = "unexpected success"
        var sendTyped = false
        do { _ = try await transport.send(request) }
        catch {
            sendError = String(describing: error)
            if let typed = error as? MCPClientError, case .spawnFailed = typed { sendTyped = true }
        }
        let sendSeconds = Double(DispatchTime.now().uptimeNanoseconds - sendStart) / 1e9
        let notifyStart = DispatchTime.now().uptimeNanoseconds
        var notifyError = "unexpected success"
        var notifyTyped = false
        do { try transport.notify(MCPJSONRPCNotification(method: "notifications/initialized", params: nil)) }
        catch {
            notifyError = String(describing: error)
            if let typed = error as? MCPClientError, case .spawnFailed = typed { notifyTyped = true }
        }
        let notifySeconds = Double(DispatchTime.now().uptimeNanoseconds - notifyStart) / 1e9
        #expect(sendTyped, "send must return typed broken-pipe error: \(sendError)")
        #expect(notifyTyped, "notify must return typed broken-pipe error: \(notifyError)")
        #expect(sendSeconds < 2 && notifySeconds < 2)
        let evidence: [String: Any] = ["scenario": "peerExit", "send_typed_error": sendTyped,
            "notify_typed_error": notifyTyped, "send_error": sendError, "notify_error": notifyError,
            "send_seconds": sendSeconds, "notify_seconds": notifySeconds, "test_signal_calls": 0,
            "reached_assertions_without_SIGPIPE": true]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("C0049_PEER_CLOSED_ASSERTION_FACTS.json"), options: .atomic)
        try Data("release\n".utf8).write(to: release)
        transport.stop()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("normal-exit").path))
        #expect(!transport.isReady)
    }

}
