import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("CONC3 owned cooperative stdio close and selective raw subscribers")
struct ExternalSessionOwnedCloseAndSubscribers3117Tests {
    @Test func closeSettlesInFlightRPCAndJoinsConsumerWhileOtherConnectionLives3164() async throws {
        let oldFixture = try OwnedStdioFixture3117()
        let otherFixture = try OwnedStdioFixture3117()
        let old = try oldFixture.connection(timeoutNanoseconds: 10_000_000_000)
        let other = try otherFixture.connection()
        let oldEvents = StdioEvents3117()
        let otherEvents = StdioEvents3117()
        let requestTerminal = StdioEvents3117()
        let oldStream = await old.notifications()
        let otherStream = await other.notifications()
        let oldReader = Task {
            for await message in oldStream { await oldEvents.append(message) }
            await oldEvents.finish()
        }
        let otherReader = Task {
            for await message in otherStream { await otherEvents.append(message) }
            await otherEvents.finish()
        }
        var pendingRequest: Task<ExternalSessionCodexJSONRPCError?, Never>?
        do {
            try await old.connect()
            try await other.connect()
            let oldChild = try oldFixture.witness()
            let otherChild = try otherFixture.witness()
            try oldFixture.validate(oldChild)
            try otherFixture.validate(otherChild)
            try #require(oldChild.pid != otherChild.pid)
            let oldState = try await old.request(method: "test/state", params: [:])
            let otherState = try await other.request(method: "test/state", params: [:])
            #expect(oldState["fixture"] == .string(oldFixture.id))
            #expect(otherState["fixture"] == .string(otherFixture.id))
            try oldFixture.gate("emit-1")
            try otherFixture.gate("emit-1")
            try #require(await waitUntil3117 {
                let oldSnapshot = await oldEvents.snapshot()
                let otherSnapshot = await otherEvents.snapshot()
                return oldSnapshot.events == ["E1"] && otherSnapshot.events == ["E1"]
            })
            let request = Task {
                let terminal: ExternalSessionCodexJSONRPCError?
                do {
                    _ = try await old.request(method: "test/hold", params: ["tag": .string(oldFixture.id)])
                    terminal = nil
                } catch let error as ExternalSessionCodexJSONRPCError {
                    terminal = error
                } catch {
                    Issue.record("Unexpected held RPC error: \(error)")
                    terminal = nil
                }
                await requestTerminal.finish()
                return terminal
            }
            pendingRequest = request
            // The owned server has received this exact RPC, not a guessed
            // queue position or a caller-side Task cancellation flag.
            try #require(await waitUntil3117 { oldFixture.hasHeldRequestWitness() })
            let held = try oldFixture.heldRequestWitness()
            #expect(held["fixture"] == .string(oldFixture.id))
            #expect(held["pid"] == .integer(Int(oldChild.pid)))
            #expect(held["root"] == .string(oldFixture.root.path))
            #expect(held["requestID"] == .integer(3)) // initialize, state, held RPC
            #expect(held["tag"] == .string(oldFixture.id))
            #expect(await requestTerminal.snapshot().finished == false)
            #expect(await oldEvents.snapshot().finished == false)

            await old.close()
            try #require(await waitUntil3117 { await requestTerminal.snapshot().finished })
            #expect(await request.value == .effectUnknown)
            try #require(await waitUntil3117 { await oldEvents.snapshot().finished })
            await oldReader.value
            #expect(await oldEvents.snapshot().events == ["E1"])
            #expect(await oldEvents.snapshot().fixtures == [oldFixture.id])
            try #require(await waitUntil3117 {
                oldFixture.hasExitWitness() && !oldFixture.childExists(oldChild.pid)
            })
            try oldFixture.validateExit(oldChild)
            await #expect(throws: ExternalSessionCodexJSONRPCError.notConnected) {
                _ = try await old.request(method: "test/state", params: [:])
            }
            // Logical close, the two actual task joins, and this owned child
            // OS terminal are distinct observations; none is App OS exit or
            // a private transport read-pump join.
            try oldFixture.record("inflight-close-consumers-joined.json", events: ["E1"])
            #expect(await other.isReady())
            #expect(otherFixture.childExists(otherChild.pid))
            let stillLive = try await other.request(method: "test/state", params: [:])
            #expect(stillLive["fixture"] == .string(otherFixture.id))
            #expect(stillLive["calls"] == .array([.string("test/state"), .string("test/state")]))
            try otherFixture.gate("emit-2")
            try #require(await waitUntil3117 { await otherEvents.snapshot().events == ["E1", "E2"] })
            #expect(await otherEvents.snapshot().finished == false)
            #expect(await oldEvents.snapshot().events == ["E1"])
            await other.close()
            try #require(await waitUntil3117 { await otherEvents.snapshot().finished })
            await otherReader.value
            try #require(await waitUntil3117 {
                otherFixture.hasExitWitness() && !otherFixture.childExists(otherChild.pid)
            })
            try otherFixture.validateExit(otherChild)
        } catch {
            try? oldFixture.gate("stop")
            try? otherFixture.gate("stop")
            await old.close()
            await other.close()
            pendingRequest?.cancel()
            oldReader.cancel()
            otherReader.cancel()
            if let pendingRequest { _ = await pendingRequest.value }
            await oldReader.value
            await otherReader.value
            throw error
        }
    }

    @Test func cooperativeCloseHasActualChildOSTerminalAfterPositiveRPC() async throws {
        let fixture = try OwnedStdioFixture3117()
        let connection = try fixture.connection()
        let observation = StdioEvents3117()
        let stream = await connection.notifications()
        let reader = Task {
            for await message in stream { await observation.append(message) }
            await observation.finish()
        }
        do {
            try await connection.connect()
            let child = try fixture.witness()
            try fixture.validate(child)
            let state = try await connection.request(method: "test/state", params: [:])
            #expect(state["fixture"] == .string(fixture.id))
            #expect(state["calls"] == .array([.string("test/state")]))
            #expect(fixture.childExists(child.pid))

            await connection.close()
            #expect(await connection.isReady() == false)
            try #require(await waitUntil3117 { await observation.snapshot().finished })
            await reader.value
            let terminal = await observation.snapshot()
            #expect(terminal.events.isEmpty)
            // Connection state and AsyncStream termination are not OS exit.
            try #require(await waitUntil3117 {
                fixture.hasExitWitness() && !fixture.childExists(child.pid)
            })
            try fixture.validateExit(child)
        } catch {
            try? fixture.gate("stop")
            await connection.close()
            reader.cancel()
            throw error
        }
    }

    @Test func cancellingRawSubscriberALeavesBReceivingGatedEventsAndRPC() async throws {
        let fixture = try OwnedStdioFixture3117()
        let connection = try fixture.connection()
        let a = StdioEvents3117()
        let b = StdioEvents3117()
        let streamA = await connection.notifications()
        let streamB = await connection.notifications()
        let readerA = Task {
            for await message in streamA { await a.append(message) }
            await a.finish()
        }
        let readerB = Task {
            for await message in streamB { await b.append(message) }
            await b.finish()
        }
        do {
            try await connection.connect()
            let child = try fixture.witness()
            try fixture.validate(child)
            try fixture.gate("emit-1")
            try #require(await waitUntil3117 {
                let observedA = await a.snapshot()
                let observedB = await b.snapshot()
                return observedA.events == ["E1"] && observedB.events == ["E1"]
            })

            readerA.cancel()
            try #require(await waitUntil3117 { await a.snapshot().finished })
            await readerA.value // A's actual consumer terminal precedes E2.
            let cancelledA = await a.snapshot()
            #expect(cancelledA.events == ["E1"])
            #expect(cancelledA.fixtures == [fixture.id])
            try fixture.record("subscriber-a-terminal.json", events: cancelledA.events)
            try fixture.gate("emit-2")
            try #require(await waitUntil3117 { await b.snapshot().events == ["E1", "E2"] })
            #expect(await a.snapshot().events == cancelledA.events)
            #expect(await connection.isReady())
            #expect(fixture.childExists(child.pid))

            let state = try await connection.request(method: "test/state", params: [:])
            #expect(state["fixture"] == .string(fixture.id))
            #expect(state["calls"] == .array([.string("test/state")]))
            try fixture.gate("emit-3")
            try #require(await waitUntil3117 { await b.snapshot().events == ["E1", "E2", "E3"] })
            #expect(await a.snapshot().events == ["E1"])
            #expect(await b.snapshot().finished == false)

            await connection.close()
            try #require(await waitUntil3117 { await b.snapshot().finished })
            await readerB.value
            #expect(await b.snapshot().events == ["E1", "E2", "E3"])
            #expect(await b.snapshot().fixtures == [fixture.id, fixture.id, fixture.id])
            try #require(await waitUntil3117 {
                fixture.hasExitWitness() && !fixture.childExists(child.pid)
            })
            try fixture.validateExit(child)
            // This proves delivery isolation, not private UUID removal/count.
        } catch {
            try? fixture.gate("stop")
            await connection.close()
            readerA.cancel()
            readerB.cancel()
            throw error
        }
    }
}

private actor StdioEvents3117 {
    private var events: [String] = []
    private var fixtures: [String] = []
    private var finished = false
    func append(_ message: ExternalSessionCodexJSONRPCMessage) {
        if message.method == "test/event", let id = message.params["eventId"]?.stringValue {
            events.append(id)
            fixtures.append(message.params["fixture"]?.stringValue ?? "MISSING_FIXTURE")
        }
    }
    func finish() { finished = true }
    func snapshot() -> (events: [String], fixtures: [String], finished: Bool) {
        (events, fixtures, finished)
    }
}

private func waitUntil3117(_ predicate: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

private struct OwnedStdioFixture3117: Sendable {
    struct ChildWitness: Decodable, Sendable {
        let fixture: String
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let argv: [String]
        let root: String
        let startedAtUnix: Double
        let reason: String?
    }

    let id: String
    let root: URL
    let script: URL

    init() throws {
        id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCoreToolContract-stdio3117-\(id)", isDirectory: true)
        script = root.appendingPathComponent("owned-server.py")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(Self.server.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // Retain fixture metadata/data for raw evidence; no directory deletion.
        try record("fixture.json", events: [])
    }

    func connection(timeoutNanoseconds: UInt64 = 2_000_000_000) throws -> ExternalSessionCodexStdioConnection {
        try ExternalSessionCodexStdioConnection(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-S", "-u", script.path, root.path, id],
            environment: ["PYTHONDONTWRITEBYTECODE": "1", "HOME": root.path,
                          "TMPDIR": root.path, "CODEX_HOME": root.path],
            workingDirectory: root, timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func hasHeldRequestWitness() -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("held-request.json").path)
    }
    func heldRequestWitness() throws -> [String: CodexJSONValue] {
        try JSONDecoder().decode([String: CodexJSONValue].self,
                                 from: Data(contentsOf: root.appendingPathComponent("held-request.json")))
    }

    func gate(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
    func record(_ name: String, events: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "fixture": id, "root": root.path, "testParentPID": getpid(),
            "executable": "/usr/bin/python3", "argv": ["-I", "-S", "-u", script.path, root.path, id],
            "events": events
        ], options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent(name))
        print("CONC3_3117_OWNED_FIXTURE \(String(decoding: data, as: UTF8.self))")
    }
    func witness() throws -> ChildWitness {
        try JSONDecoder().decode(ChildWitness.self,
                                from: Data(contentsOf: root.appendingPathComponent("child.json")))
    }
    func validate(_ child: ChildWitness) throws {
        try #require(child.fixture == id && child.root == root.path)
        try #require(child.pid > 0 && child.pid != getpid() && child.ppid == getpid())
        #expect(child.pgid == getpgid(child.pid))
        #expect(child.argv == [script.path, root.path, id])
        print("CONC3_3117_OWNED_CHILD pid=\(child.pid) ppid=\(child.ppid) pgid=\(child.pgid) root=\(root.path)")
    }
    func childExists(_ pid: Int32) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }
    func hasExitWitness() -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("child-exit.json").path)
    }
    func validateExit(_ original: ChildWitness) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("child-exit.json"))
        let terminal = try JSONDecoder().decode(ChildWitness.self, from: data)
        #expect(terminal.fixture == id && terminal.pid == original.pid && terminal.ppid == original.ppid)
        #expect(terminal.root == root.path && terminal.argv == original.argv)
        #expect(terminal.startedAtUnix == original.startedAtUnix)
        #expect(terminal.reason == "SIGTERM" || terminal.reason == "stdinEOF")
        #expect(!childExists(original.pid))
        print("CONC3_3117_OWNED_CHILD_OS_TERMINAL \(String(decoding: data, as: UTF8.self))")
    }

    private static let server = #"""
    import json, os, signal, sys, threading, time
    root, fixture = sys.argv[1], sys.argv[2]
    started_at = time.time()
    stopped = threading.Event()
    send_lock = threading.Lock()
    reason = ['stdinEOF']
    calls = []
    def witness(name, why=None):
        payload = {'fixture':fixture, 'pid':os.getpid(), 'ppid':os.getppid(),
                   'pgid':os.getpgid(0), 'argv':sys.argv, 'root':root,
                   'startedAtUnix':started_at, 'reason':why}
        with open(os.path.join(root, name), 'w') as output:
            json.dump(payload, output, sort_keys=True)
    def send(payload):
        with send_lock:
            print(json.dumps(payload), flush=True)
    def terminate(signum, frame):
        reason[0] = 'SIGTERM'
        stopped.set()
    signal.signal(signal.SIGTERM, terminate)
    witness('child.json')
    def requests():
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if method == 'initialize':
                send({'id':request['id'], 'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)'}})
            elif method == 'initialized':
                pass
            elif method == 'test/state':
                calls.append(method)
                send({'id':request['id'], 'result':{'fixture':fixture, 'calls':calls}})
            elif method == 'test/hold':
                calls.append(method)
                held = {'fixture':fixture, 'pid':os.getpid(), 'root':root,
                        'requestID':request['id'], 'tag':request.get('params', {}).get('tag')}
                with open(os.path.join(root, 'held-request.partial'), 'w') as output:
                    json.dump(held, output, sort_keys=True)
                os.replace(os.path.join(root, 'held-request.partial'), os.path.join(root, 'held-request.json'))
                # No response: actual close must settle the written request.
        stopped.set()
    threading.Thread(target=requests, daemon=True).start()
    emitted = set()
    while not stopped.is_set():
        if os.path.exists(os.path.join(root, 'stop')):
            reason[0] = 'stop-gate'
            stopped.set()
            break
        for number in (1, 2, 3):
            if number not in emitted and os.path.exists(os.path.join(root, 'emit-' + str(number))):
                send({'method':'test/event', 'params':{'eventId':'E' + str(number), 'fixture':fixture}})
                emitted.add(number)
        time.sleep(0.005)
    witness('child-exit.json', reason[0])
    """#
}
