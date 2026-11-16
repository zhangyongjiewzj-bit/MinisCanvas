import Foundation
import Dispatch
import Testing
@testable import MinisCore

@Suite("D-CONC2 C0049 write failure reconnect", .serialized)
struct MCPWriteFailureReconnectC0049Tests {
    @Test("partial stdin write failure recovers on the first request after stop and reconnect")
    func writeFailureThenStopReconnectRecoversFirstRequest() async throws {
        let formal = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
        let root = URL(fileURLWithPath: formal, isDirectory: true)
            .appendingPathComponent("MCP-C0049-RECONNECT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let script = root.appendingPathComponent("write-failure-then-echo.py")
        let body = #"""
        import json, os, select, sys, time
        root = os.environ["MCP_C0049_ROOT"]
        def mark(name, value):
            with open(os.path.join(root, name), "w") as f:
                f.write(str(value) + "\n")
        try:
            fd = os.open(os.path.join(root, "first-launch"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            first = False
        else:
            os.close(fd)
            first = True
        with open(os.path.join(root, "launches.jsonl"), "a") as f:
            f.write(json.dumps({"pid": os.getpid(), "phase": "nonreading" if first else "echo"}) + "\n")
        if first:
            queue = select.kqueue()
            event = select.kevent(0, filter=select.KQ_FILTER_READ,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE)
            queue.control([event], 0, 0)
            mark("first-ready", os.getpid())
            maximum_buffered = 0
            deadline = time.monotonic() + 8
            while True:
                for event in queue.control([], 1, 0.01):
                    if event.data > maximum_buffered:
                        maximum_buffered = event.data
                        mark("first-buffered-bytes", maximum_buffered)
                    if event.flags & select.KQ_EV_EOF:
                        mark("first-eof-exit", "last-writer-closed; explicit-stdin-read-calls=0")
                        queue.close()
                        raise SystemExit(0)
                if time.monotonic() >= deadline:
                    mark("first-backstop-exit", "unexpected fixture backstop")
                    queue.close()
                    raise SystemExit(0)
                time.sleep(0.01)
        # Only the new generation reads requests. The failed generation above
        # never consumes its partial line to turn a failed write into success.
        mark("second-ready", os.getpid())
        count = 0
        for line in sys.stdin.buffer:
            request = json.loads(line)
            count += 1
            mark("second-read-count", count)
            mark("second-received-id", request.get("id"))
            response = {"jsonrpc": "2.0", "id": request.get("id"),
                        "result": {"recovered": True, "method": request.get("method"), "pid": os.getpid()}}
            print(json.dumps(response), flush=True)
        mark("second-eof-exit", "normal stdin EOF")
        """#
        try body.write(to: script, atomically: true, encoding: .utf8)
        let transport = MCPStdioTransport(command: "/usr/bin/python3", args: ["-B", script.path],
            env: ["MCP_C0049_ROOT": root.path], timeoutSeconds: 1)
        defer { transport.stop() }
        try await transport.start()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("first-ready").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("first-ready").path))
        let beforeFailure = transport.runtimeSnapshot()
        let retiredIdentity = try #require(beforeFailure.runtimeIdentity)
        let id = MCPID.int(4_049)
        let bigRequest = MCPJSONRPCRequest(id: id, method: "tools/call",
            params: .object(["payload": .string(String(repeating: "x", count: 512 * 1024))]))
        let encodedBytes = try bigRequest.encodeLine().utf8.count
        let writeStarted = DispatchTime.now().uptimeNanoseconds
        var sawTimeout = false
        var writeError = "unexpected response"
        do { _ = try await transport.send(bigRequest) }
        catch {
            writeError = String(describing: error)
            if let typed = error as? MCPClientError, case .timeout = typed { sawTimeout = true }
        }
        let writeSeconds = Double(DispatchTime.now().uptimeNanoseconds - writeStarted) / 1e9
        #expect(sawTimeout, "first generation must produce a real write timeout: \(writeError)")
        #expect(writeSeconds < 2)
        let bufferedText = try String(contentsOf: root.appendingPathComponent("first-buffered-bytes"), encoding: .utf8)
        let buffered = try #require(Int(bufferedText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(buffered > 0 && buffered < encodedBytes, "the peer observed an unread partial message")
        let failed = transport.runtimeSnapshot()
        let markedFailed: Bool
        if case .failed = failed.state { markedFailed = true } else { markedFailed = false }
        #expect(markedFailed && !transport.isReady, "must exercise the failedWriteOwner fence, not only a response timeout")
        #expect(!transport.accepts(retiredIdentity))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("first-backstop-exit").path))
        let stopStarted = DispatchTime.now().uptimeNanoseconds
        transport.stop()
        let stopSeconds = Double(DispatchTime.now().uptimeNanoseconds - stopStarted) / 1e9
        #expect(stopSeconds < 1)
        #expect(transport.runtimeSnapshot().state == .stopped)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("first-eof-exit").path))

        // Reuse the same transport and same request id. There is exactly one
        // reconnect and exactly one post-reconnect request, with no retry.
        try await transport.start()
        let reopened = transport.runtimeSnapshot()
        #expect(reopened.state == .running && transport.isReady)
        #expect(reopened.generation > beforeFailure.generation)
        #expect(reopened.ownerID != beforeFailure.ownerID)
        #expect(!transport.accepts(retiredIdentity))
        let newIdentity = try #require(reopened.runtimeIdentity)
        #expect(transport.accepts(newIdentity))
        let recovered = try await transport.send(MCPJSONRPCRequest(id: id, method: "tools/call", params: nil))
        #expect(recovered.id == id && recovered.error == nil)
        let expected = MCPJSONValue.object(["recovered": .bool(true), "method": .string("tools/call"),
            "pid": .number(Double(try #require(reopened.processIdentifier)))])
        #expect(recovered.result == expected)
        let readCount = try String(contentsOf: root.appendingPathComponent("second-read-count"), encoding: .utf8)
        #expect(readCount.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        transport.stop()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("second-eof-exit").path))
        #expect(!transport.isReady)
        let evidence: [String: Any] = ["real_first_write_timeout": sawTimeout, "write_error": writeError,
            "write_seconds": writeSeconds, "unread_partial_bytes": buffered, "encoded_request_bytes": encodedBytes,
            "first_failedWriteOwner_exercised": markedFailed, "stop_seconds": stopSeconds,
            "generation_before": beforeFailure.generation, "generation_after": reopened.generation,
            "owner_changed": reopened.ownerID != beforeFailure.ownerID,
            "post_reconnect_requests": 1, "post_reconnect_retries": 0, "same_request_id_reused": true,
            "first_post_reconnect_response_matches": recovered.result == expected,
            "first_phase_explicit_stdin_read_calls": 0, "test_signal_calls": 0]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("C0049_WRITE_FAILURE_RECONNECT_ACTUAL_FACTS.json"), options: .atomic)
    }
}
