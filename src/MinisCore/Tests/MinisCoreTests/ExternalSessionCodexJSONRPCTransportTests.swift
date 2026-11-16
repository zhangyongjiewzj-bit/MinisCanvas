import Foundation
import Testing
@testable import MinisCore

@Suite("Official Codex JSON-RPC over a synthetic stdio process")
struct ExternalSessionCodexJSONRPCTransportTests {
    private let sourceID = ExternalSessionSourceID(rawValue: "synthetic-codex")
    private let threadID = ExternalSessionThreadID(rawValue: "thr_source")
    private let turnID = ExternalSessionTurnID(rawValue: "turn_1")

    private func connection(serverVersion: String = "0.151.0") throws -> ExternalSessionCodexStdioConnection {
        let script = #"""
import json,sys,os
assert os.environ.get('CODEX_HOME') == '/synthetic-codex-home'
assert os.environ.get('PYTHONDONTWRITEBYTECODE') == '1'
assert os.environ.get('PYTHONUNBUFFERED') == '1'
assert 'SYNTHETIC_CONFIGURED_TOKEN' not in os.environ
assert os.environ.get('PATH') != '/synthetic-untrusted-path'
assert os.environ.get('ZDOTDIR') == '/var/empty'
ready=False
threads={'thr_source'}
calls=[]
approval=None
for line in sys.stdin:
    req=json.loads(line)
    method=req.get('method')
    rid=req.get('id')
    if method is None and rid=='approval-1':
        approval=req.get('result')
        continue
    if method=='initialized':
        ready=True
        continue
    if method=='initialize':
        result={'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}
    elif not ready:
        result=None
    else:
        calls.append(method)
        params=req.get('params',{})
        if method=='thread/resume':
            result={'thread':{'id':params['threadId']}}
        elif method=='thread/fork':
            threads.add('thr_child')
            result={'thread':{'id':'thr_child','forkedFromId':params['threadId']}}
            print(json.dumps({'method':'thread/started','params':{'thread':{'id':'thr_child'}}}),flush=True)
        elif method=='turn/steer':
            result={'turnId':params['expectedTurnId']}
        elif method=='turn/interrupt':
            result={}
        elif method=='test/triggerApproval':
            print(json.dumps({'id':'approval-1','method':'item/commandExecution/requestApproval','params':{'threadId':'thr_source','turnId':'turn_1','itemId':'item_1'}}),flush=True)
            result={}
        elif method=='test/state':
            result={'calls':calls,'threads':sorted(threads),'approval':approval}
        else:
            result=None
    if rid is not None:
        if result is None:
            print(json.dumps({'id':rid,'error':{'code':-32000,'message':'not initialized or unsupported'}}),flush=True)
        else:
            print(json.dumps({'id':rid,'result':result}),flush=True)
"""#
        return try ExternalSessionCodexStdioConnection(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script.replacingOccurrences(of: "miniscanvas/0.151.0", with: "miniscanvas/\(serverVersion)")],
            environment: ["PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1",
                "CODEX_HOME": "/synthetic-codex-home", "SYNTHETIC_CONFIGURED_TOKEN": "synthetic-only",
                "PATH": "/synthetic-untrusted-path"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeoutNanoseconds: 2_000_000_000
        )
    }

    private func grant() -> ExternalSessionControlGrantV1 {
        ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "synthetic-control"),
            sourceID: sourceID,
            profileID: ExternalSessionProfileID(rawValue: "synthetic-profile"),
            target: .thread(threadID),
            operations: [.resume, .fork, .steer, .interrupt],
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            revocationEpoch: 0
        )
    }

    private func request(_ operation: ExternalSessionControlOperationV1, key: String,
                         turnID: ExternalSessionTurnID? = nil,
                         input: String? = nil,
                         sequence: UInt64? = nil) -> ExternalSessionControlRequestV1 {
        ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            operation: operation,
            expectedCursor: .beginning,
            expectedSequence: sequence,
            idempotencyKey: key,
            boundedInput: input
        )
    }

    @Test func handshakeAndFourActionsCrossRealPipesWithCorrelatedResults() async throws {
        let connection = try connection()
        do {
            let stream = await connection.notifications()
            try await connection.connect()
            let transport = ExternalSessionCodexJSONRPCControlTransport(connection: connection, sourceID: sourceID)
            let grant = grant()

            let resume = try await transport.send(request: request(.resume, key: "resume"), controlGrant: grant)
            #expect(resume.outcome == .accepted)
            let fork = try await transport.send(request: request(.fork, key: "fork"), controlGrant: grant)
            #expect(fork.outcome == .completed)
            #expect(fork.threadID == threadID)
            #expect(fork.childThreadID == ExternalSessionThreadID(rawValue: "thr_child"))
            #expect(fork.detail?.contains("thr_child") == true)
            let steer = try await transport.send(request: request(.steer, key: "steer", turnID: turnID, input: "more"), controlGrant: grant)
            #expect(steer.outcome == .accepted)
            let interrupt = try await transport.send(request: request(.interrupt, key: "interrupt", turnID: turnID), controlGrant: grant)
            #expect(interrupt.outcome == .accepted)

            let state = try await connection.request(method: "test/state", params: [:])
            #expect(state["threads"] == .array([.string("thr_child"), .string("thr_source")]))
            #expect(state["calls"] == .array([
                .string("thread/resume"), .string("thread/fork"), .string("turn/steer"),
                .string("turn/interrupt"), .string("test/state")
            ]))
            var iterator = stream.makeAsyncIterator()
            let notification = await iterator.next()
            #expect(notification?.method == "thread/started")
            #expect(notification?.params["thread"]?.objectValue?["id"]?.stringValue == "thr_child")
        } catch {
            // Cleanup is actually awaited even when a business requirement throws.
            let failedClose = await connection.close()
            #expect(failedClose.isComplete, "failed test left its owned stdio connection in HOLD")
            throw error
        }
        // Business/control assertions above precede the lifecycle-only stop.
        // close requests stdin EOF / own-process termination; no RPC is added.
        let closed = await connection.close()
        #expect(closed.processIdentifier != nil && closed.terminationStatus != nil)
        #expect(closed.processWaited)
        #expect(closed.readerReachedEOF)
        #expect(closed.parserTasksJoined == 1)
        #expect(closed.stdoutClosed && closed.allPipeHandlesClosed)
        #expect(closed.isComplete, "owned stdio close must finish, not merely return a bounded HOLD")
    }

    @Test func serverRequestRequiresMatchingPendingIDBeforeResponseCrossesPipe() async throws {
        let connection = try connection()
        do {
            let stream = await connection.notifications()
            try await connection.connect()
            await #expect(throws: ExternalSessionCodexJSONRPCError.self) {
                try await connection.respond(to: .string("unseen"), result: .object(["decision": .string("decline")]))
            }
            _ = try await connection.request(method: "test/triggerApproval", params: [:])
            var iterator = stream.makeAsyncIterator()
            let request = await iterator.next()
            #expect(request?.method == "item/commandExecution/requestApproval")
            #expect(request?.requestID == .string("approval-1"))
            try await connection.respond(to: .string("approval-1"), result: .object(["decision": .string("decline")]))
            let state = try await connection.request(method: "test/state", params: [:])
            #expect(state["approval"] == .object(["decision": .string("decline")]))
        } catch {
            // Cleanup is actually awaited even when a business requirement throws.
            let failedClose = await connection.close()
            #expect(failedClose.isComplete, "failed test left its owned stdio connection in HOLD")
            throw error
        }
        // Business/control assertions above precede the lifecycle-only stop.
        // close requests stdin EOF / own-process termination; no RPC is added.
        let closed = await connection.close()
        #expect(closed.processIdentifier != nil && closed.terminationStatus != nil)
        #expect(closed.processWaited)
        #expect(closed.readerReachedEOF)
        #expect(closed.parserTasksJoined == 1)
        #expect(closed.stdoutClosed && closed.allPipeHandlesClosed)
        #expect(closed.isComplete, "owned stdio close must finish, not merely return a bounded HOLD")
    }

    @Test func unknownServerVersionFailsHandshakeBeforeControlCanRun() async throws {
        let connection = try connection(serverVersion: "0.152.0")
        await #expect(throws: ExternalSessionCodexJSONRPCError.self) {
            try await connection.connect()
        }
        #expect(await connection.isReady() == false)
        await #expect(throws: ExternalSessionCodexJSONRPCError.self) {
            try await connection.request(method: "thread/resume", params: ["threadId": .string("thr_source")])
        }
    }

    @Test func alreadyCancelledCallerNeverWritesAControlRequest() async throws {
        let connection = try connection()
        do {
            try await connection.connect()
            let result = await Task { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try await connection.request(method: "thread/resume", params: ["threadId": .string("thr_source")])
                    return false
                } catch {
                    return true
                }
            }.value
            #expect(result)
            let state = try await connection.request(method: "test/state", params: [:])
            #expect(state["calls"] == .array([.string("test/state")]))
        } catch {
            // Cleanup is actually awaited even when a business requirement throws.
            let failedClose = await connection.close()
            #expect(failedClose.isComplete, "failed test left its owned stdio connection in HOLD")
            throw error
        }
        // Business/control assertions above precede the lifecycle-only stop.
        // close requests stdin EOF / own-process termination; no RPC is added.
        let closed = await connection.close()
        #expect(closed.processIdentifier != nil && closed.terminationStatus != nil)
        #expect(closed.processWaited)
        #expect(closed.readerReachedEOF)
        #expect(closed.parserTasksJoined == 1)
        #expect(closed.stdoutClosed && closed.allPipeHandlesClosed)
        #expect(closed.isComplete, "owned stdio close must finish, not merely return a bounded HOLD")
    }

    @Test func stoppedReaderCannotBlockActorPastRequestTimeout() async throws {
        let script = #"""
import json,sys,time
for line in sys.stdin:
    req=json.loads(line)
    if req.get('method')=='initialize':
        print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)'}}),flush=True)
    elif req.get('method')=='initialized':
        time.sleep(3)
        sys.exit(0)
"""#
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ["PYTHONDONTWRITEBYTECODE": "1"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeoutNanoseconds: 700_000_000
        )
        try await connection.connect()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: Error.self) {
            try await connection.request(method: "turn/steer", params: [
                "threadId": .string("thr_source"),
                "expectedTurnId": .string("turn_1"),
                "input": .array([.object(["type": .string("text"), "text": .string(String(repeating: "x", count: 1_000_000))])])
            ])
        }
        #expect(start.duration(to: clock.now) < .milliseconds(1_500))
    }

    @Test(arguments: ["notifications", "partialFrame"])
    func overLimitInboundStreamClosesConnectionWithoutSilentEventLoss(mode: String) async throws {
        let script = #"""
import json,sys,time
for line in sys.stdin:
    req=json.loads(line)
    if req.get('method')=='initialize':
        print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)'}}),flush=True)
    elif req.get('method')=='initialized':
        if 'MODE'=='notifications':
            for i in range(300):
                print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'thr_source','delta':str(i)}}),flush=True)
        else:
            sys.stdout.write('x'*(9*1024*1024))
            sys.stdout.flush()
        time.sleep(10)
        sys.exit(0)
"""#
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script.replacingOccurrences(of: "MODE", with: mode)],
            environment: ["PYTHONDONTWRITEBYTECODE": "1"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeoutNanoseconds: 2_000_000_000
        )
        let unconsumedStream = await connection.notifications()
        _ = unconsumedStream
        do { try await connection.connect() }
        catch {
            #expect(error as? ExternalSessionCodexJSONRPCError == .disconnected)
        }
        for _ in 0..<150 {
            if !(await connection.isReady()) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await connection.isReady() == false)
    }

    @Test func cancellationAfterServerReceivesBytesReportsUnknownEffect() async throws {
        let script = #"""
import json,os,sys,time
def line():
    data=b''
    while not data.endswith(b'\n'):
        chunk=os.read(0,1)
        if not chunk: sys.exit(0)
        data+=chunk
    return json.loads(data)
req=line()
print(json.dumps({'id':req['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)'}}),flush=True)
line()
os.read(0,4096)
print(json.dumps({'method':'test/receivedPrefix','params':{'threadId':'thr_source'}}),flush=True)
time.sleep(10)
"""#
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ["PYTHONDONTWRITEBYTECODE": "1"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeoutNanoseconds: 2_000_000_000
        )
        let stream = await connection.notifications()
        try await connection.connect()
        let request = Task {
            try await connection.request(method: "turn/steer", params: [
                "threadId": .string("thr_source"),
                "expectedTurnId": .string("turn_1"),
                "input": .array([.object(["type": .string("text"), "text": .string(String(repeating: "x", count: 1_000_000))])])
            ])
        }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.method == "test/receivedPrefix")
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled, already-written request must not report success")
        } catch {
            #expect(error as? ExternalSessionCodexJSONRPCError == .effectUnknown)
        }
        #expect(await connection.isReady() == false)
    }

    @Test func explicitCloseRetiresOwnedConnectionAndEventStream() async throws {
        let connection = try connection()
        let stream = await connection.notifications()
        try await connection.connect()
        await connection.close()
        #expect(await connection.isReady() == false)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func unsupportedConditionalSequenceAndDuplicateKeyNeverReachProcess() async throws {
        let connection = try connection()
        try await connection.connect()
        let transport = ExternalSessionCodexJSONRPCControlTransport(connection: connection, sourceID: sourceID)
        let grant = grant()
        await #expect(throws: ExternalSessionAppServerTransportError.self) {
            try await transport.send(request: request(.resume, key: "conditional", sequence: 1), controlGrant: grant)
        }
        _ = try await transport.send(request: request(.resume, key: "once"), controlGrant: grant)
        await #expect(throws: ExternalSessionAppServerTransportError.self) {
            try await transport.send(request: request(.resume, key: "once"), controlGrant: grant)
        }
        let state = try await connection.request(method: "test/state", params: [:])
        #expect(state["calls"] == .array([.string("thread/resume"), .string("test/state")]))
    }
}
