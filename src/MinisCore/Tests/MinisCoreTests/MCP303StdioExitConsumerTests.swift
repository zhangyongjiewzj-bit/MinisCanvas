import Foundation
import Darwin
import Testing
@testable import MinisCore

@Suite("MCP303 stdio terminal consumer")
struct MCP303StdioExitConsumerTests {
    @Test("root exit settles its request before a descendant closes inherited stdout")
    func rootExitSettlesBeforeInheritedPipeEOF() async throws {
        // Reanchored d3a413bafc/c08b34f748 fixture: the finite sleep closes its
        // inherited pipe later; the root terminal must settle before timeout.
        let transport = MCPStdioTransport(
            command: "/bin/sh",
            args: ["-c", "IFS= read -r line; (sleep 2) & exit 7"],
            env: [:], timeoutSeconds: 1
        )
        defer { transport.stop() }
        try await transport.start()
        let started = Date()
        await #expect(throws: MCPClientError.processExited(7)) {
            _ = try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "initialize"))
        }
        #expect(Date().timeIntervalSince(started) < 0.75)
        #expect(!transport.isReady)
        #expect(transport.runtimeSnapshot().state != .running)
        #expect(transport.runtimeSnapshot().runtimeIdentity == nil)
        transport.stop()
    }

    @Test("an exit before handle installation cannot retain a running owner")
    func immediateExitCannotRetainRunningOwner() async throws {
        for _ in 0..<5 {
            let transport = MCPStdioTransport(command: "/bin/sh", args: ["-c", "exit 127"], env: [:], timeoutSeconds: 1)
            defer { transport.stop() }
            try await transport.start()
            for _ in 0..<100 where transport.runtimeSnapshot().state == .running {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(transport.runtimeSnapshot().state != .running)
            #expect(transport.runtimeSnapshot().runtimeIdentity == nil)
            #expect(!transport.isReady)
        }
    }

    @Test("owned stdio exit, stop and request cancellation leave no pipe-holding descendant",
          arguments: ["exit", "stop", "cancel"])
    func ownedDescendantLifecycleCycles(mode: String) async throws {
        for cycle in 0..<2 {
            let ownedRoot = try #require(ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"])
            let directory = URL(fileURLWithPath: ownedRoot, isDirectory: true)
                .appendingPathComponent("MCP735-\(mode)-\(cycle)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pidsFile = directory.appendingPathComponent("owned-pids")
            let receivedFile = directory.appendingPathComponent("received")
            // Both processes have a finite natural lifetime even if an assertion
            // fails. No test-side signal compensates for production teardown.
            let script = """
            /bin/sleep 4 &
            child=$!
            printf '%s %s\\n' "$$" "$child" > "$MCP735_PIDS"
            if IFS= read -r -t 5 line; then
                printf 'received' > "$MCP735_RECEIVED"
                if [ "$MCP735_MODE" = exit ]; then exit 7; fi
                while IFS= read -r -t 5 line; do :; done
            fi
            exit 0
            """
            let transport = MCPStdioTransport(command: "/bin/sh", args: ["-c", script], env: [
                "MCP735_PIDS": pidsFile.path,
                "MCP735_RECEIVED": receivedFile.path,
                "MCP735_MODE": mode
            ], timeoutSeconds: 2)
            try await transport.start()
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidsFile.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let rawPIDs = try String(contentsOf: pidsFile, encoding: .utf8)
            let pids = rawPIDs.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            let root = try #require(pids.first)
            let child = try #require(pids.last)
            let group = Darwin.getpgid(root)
            let observation = try await Self.observeOwnedProcesses(root: root, child: child, group: group)
            let ownedGroup = pids.count == 2 && root != child
                && transport.runtimeSnapshot().processIdentifier == root
                && group == root && group != Darwin.getpgrp()
                && Darwin.getpgid(child) == group
                && observation.groupPIDs == Set([root, child])
                && observation.childParent == root
            print("MCP735 START mode=\(mode) cycle=\(cycle) root=\(root) child=\(child) group=\(group) owned=\(ownedGroup) at=\(Date().timeIntervalSince1970)")
            print(observation.metadata)
            guard ownedGroup else {
                // Never invoke group teardown without proving exclusive owned
                // membership. The bounded fixture expires without test signals.
                await Self.awaitNaturalRetirement(pids)
                Issue.record("synthetic process group ownership was not established; teardown not invoked")
                return
            }
            defer { transport.stop() }
            #expect(Self.alive(root) && Self.alive(child))
            let identity = try #require(transport.runtimeSnapshot().runtimeIdentity)
            let request = Task {
                try await transport.send(MCPJSONRPCRequest(id: .int(cycle + 1), method: "initialize"))
            }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: receivedFile.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: receivedFile.path))
            let retiring = Date()
            if mode == "cancel" {
                request.cancel()
                await #expect(throws: CancellationError.self) { _ = try await request.value }
                // Cancelling one request does not disconnect its reusable server.
                #expect(transport.accepts(identity))
                transport.stop()
            } else if mode == "stop" {
                transport.stop()
                await #expect(throws: MCPClientError.processExited(-1)) { _ = try await request.value }
            } else {
                await #expect(throws: MCPClientError.processExited(7)) { _ = try await request.value }
            }
            for _ in 0..<75 where Self.alive(root) || Self.alive(child) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let rootAlive = Self.alive(root)
            let childAlive = Self.alive(child)
            print("MCP735 RETIRED mode=\(mode) cycle=\(cycle) rootAlive=\(rootAlive) childAlive=\(childAlive) elapsed=\(Date().timeIntervalSince(retiring)) at=\(Date().timeIntervalSince1970)")
            print(try await Self.observeOwnedProcesses(root: root, child: child, group: group).metadata)
            #expect(!rootAlive)
            #expect(!childAlive, "a stopped/exited stdio server must not leave its pipe-holding child alive")
            #expect(Date().timeIntervalSince(retiring) < 2)
            #expect(!transport.accepts(identity))
            #expect(!transport.isReady)
            #expect(transport.runtimeSnapshot().runtimeIdentity == nil)
            transport.stop()
            // Preserve a RED without leaving a fixture process behind. A new
            // cycle is admitted only after actual disappearance, never a timeout.
            await Self.awaitNaturalRetirement(pids)
            let allRetired = pids.allSatisfy { !Self.alive($0) }
            print("MCP735 FINAL mode=\(mode) cycle=\(cycle) allRetired=\(allRetired) at=\(Date().timeIntervalSince1970)")
            try #require(allRetired)
        }
    }

    @Test("stdio keeps only its explicitly configured token and PATH; nested zsh does not reload a user profile")
    func stdioEnvironmentDropsAmbientCredentialsAndRetainsExplicitServerSettings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-environment-" + UUID().uuidString, isDirectory: true)
        try #require(directory.resolvingSymlinksInPath().path.hasPrefix(
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = "MCP_SYNTH_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let names = ["API_KEY", "TOKEN", "SECRET", "PASSWORD", "AUTHORIZATION", "UNKNOWN", "ORDINARY_ALIAS"]
            .map { prefix + "_" + $0 }
        var installed: [String] = []
        defer { for name in installed { unsetenv(name) } }
        for name in names {
            try #require(setenv(name, "synthetic-app-value-never-output", 0) == 0)
            installed.append(name)
        }
        let profileName = prefix + "_PROFILE_API_KEY"
        try "export \(profileName)='synthetic-profile-value-never-output'\n".write(
            to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let checks = (names + [profileName]).map {
            "[ \"${\($0)+x}\" != x ] || exit 41"
        }.joined(separator: "\n")
        let nestedCheck = checks.replacingOccurrences(of: "'", with: "'\\''")
        let isolatedDirectoryChecks: String
        if let profile = try ChildProcessEnvironment.profileRoot() {
            let home = profile.appendingPathComponent("home", isDirectory: true).path.replacingOccurrences(of: "'", with: "'\\''")
            let temporary = profile.appendingPathComponent("temporary", isDirectory: true).path.replacingOccurrences(of: "'", with: "'\\''")
            isolatedDirectoryChecks = "[ \"$HOME\" = '\(home)' ] && [ \"$TMPDIR\" = '\(temporary)' ] || exit 50"
        } else { isolatedDirectoryChecks = "" }
        let stage = directory.appendingPathComponent("environment-stage")
        let stagePath = stage.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        printf '%s' started > '\(stagePath)'
        \(checks)
        \(isolatedDirectoryChecks)
        [ "$MCP_SERVER_TOKEN" = synthetic-server-configured-token ] || exit 42
        [ "$MCP_WORKSPACE_ID" = synthetic-workspace ] || exit 43
        [ "$ZDOTDIR" = /var/empty ] || exit 44
        /bin/zsh -c '\(nestedCheck)' || exit 45
        printf '%s' awaiting-request > '\(stagePath)'
        IFS= read -r request || exit 46
        printf '%s' received-request > '\(stagePath)'
        printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"environmentClean":true,"configuredTokenPresent":true,"nestedClean":true}}'
        printf '\n'
        printf '%s' response-written > '\(stagePath)'
        while IFS= read -r ignored; do :; done
        """
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wrapper = bin.appendingPathComponent("synthetic-mcp-host")
        let wrapperStage = directory.appendingPathComponent("bare-wrapper-entered")
        let wrapperStagePath = wrapperStage.path.replacingOccurrences(of: "'", with: "'\\''")
        // Exercise explicit PATH resolution of a native executable without
        // adding a generated script's separate kernel/shebang launch contract.
        try FileManager.default.createSymbolicLink(at: wrapper,
            withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))
        // The bare-name case exercises the existing /usr/bin/env resolution
        // protocol using a specifically configured, owned toolchain directory.
        for command in ["/bin/zsh", "synthetic-mcp-host"] {
            let form = command == "/bin/zsh" ? "absolute" : "bare"
            // A previous process may finish its final printf after stop().
            // Separate fixed per-form sidecars prevent a late stale witness.
            let stage = directory.appendingPathComponent("environment-stage-" + form)
            let formStagePath = stage.path.replacingOccurrences(of: "'", with: "'\\''")
            var formScript = script.replacingOccurrences(of: stagePath, with: formStagePath)
            if form == "bare" {
                formScript = "printf '%s' wrapper-entered > '\(wrapperStagePath)'\n" + formScript
            }
            if FileManager.default.fileExists(atPath: stage.path) {
                try FileManager.default.removeItem(at: stage)
            }
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let transport = MCPStdioTransport(command: command, args: ["-c", formScript], env: [
                "HOME": directory.path,
                "PATH": bin.path + ":/usr/bin:/bin",
                "MCP_SERVER_TOKEN": "synthetic-server-configured-token",
                "MCP_WORKSPACE_ID": "synthetic-workspace"
            ], timeoutSeconds: 2)
            defer { transport.stop() }
            try await transport.start()
            let launched = transport.runtimeSnapshot()
            print("MCP_LAUNCH_WITNESS form=\(form) start_return_ns=\(DispatchTime.now().uptimeNanoseconds) pid=\(launched.processIdentifier.map { String($0) } ?? "none") wrapper_entered=\(FileManager.default.fileExists(atPath: wrapperStage.path))")
            // Observe independently; no ARM, extra request, or wait precedes send.
            let responseWrittenObserver = Task<UInt64?, Never> {
                var wrapperObserved = false
                var lastObservedStage: String?
                let fixedStages = ["started", "awaiting-request", "received-request", "response-written"]
                while !Task.isCancelled {
                    // These are observation upper bounds, not child execution
                    // timestamps. A fast transition may never be sampled.
                    if form == "bare", !wrapperObserved,
                       FileManager.default.fileExists(atPath: wrapperStage.path) {
                        wrapperObserved = true
                        print("MCP_STAGE_WITNESS form=\(form) stage=wrapper-entered observed_ns=\(DispatchTime.now().uptimeNanoseconds)")
                    }
                    let observedStage = try? String(contentsOf: stage, encoding: .utf8)
                    if let observedStage, fixedStages.contains(observedStage),
                       observedStage != lastObservedStage {
                        lastObservedStage = observedStage
                        print("MCP_STAGE_WITNESS form=\(form) stage=\(observedStage) observed_ns=\(DispatchTime.now().uptimeNanoseconds)")
                    }
                    if observedStage == "response-written" {
                        return DispatchTime.now().uptimeNanoseconds
                    }
                    do { try await Task.sleep(for: .milliseconds(1)) }
                    catch { return nil }
                }
                return nil
            }
            let sendStartedAt = DispatchTime.now().uptimeNanoseconds
            let response: MCPJSONRPCResponse
            do {
                response = try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "environment/check"))
            } catch {
                let caughtAt = DispatchTime.now().uptimeNanoseconds
                responseWrittenObserver.cancel()
                let writtenAt = await responseWrittenObserver.value
                // Only fixed synthetic labels and monotonic timing: never dump
                // a request, environment, credentials, response body or stderr.
                let observedStage = (try? String(contentsOf: stage, encoding: .utf8)) ?? "not-started"
                let written = writtenAt.map { String($0) } ?? "not-observed"
                let runtime = transport.runtimeSnapshot()
                let wrapperEntered = FileManager.default.fileExists(atPath: wrapperStage.path)
                if let pid = launched.processIdentifier, launched.runtimeIdentity != nil,
                   runtime.runtimeIdentity == launched.runtimeIdentity,
                   runtime.processIdentifier == pid {
                    // Existing bounded-scope diagnostic consumer: only this
                    // owned PID's executable image/state, never args or env.
                    let observed = try? await Self.capture("/bin/ps", ["-p", String(pid),
                        "-o", "pid=,ppid=,pgid=,state=,comm="])
                    print("MCP_LAUNCH_WITNESS form=\(form) observed_ns=\(DispatchTime.now().uptimeNanoseconds) pid=\(pid) wrapper_entered=\(wrapperEntered) ps_status=\(observed.map { String($0.status) } ?? "unavailable")")
                    if let observed { print(observed.output) }
                } else {
                    print("MCP_LAUNCH_WITNESS form=\(form) observed_ns=\(DispatchTime.now().uptimeNanoseconds) pid=UNKNOWN wrapper_entered=\(wrapperEntered)")
                }
                Issue.record("environment fixture form=\(form) stage=\(observedStage), state=\(transport.runtimeSnapshot().state), start_ns=\(startedAt), send_ns=\(sendStartedAt), catch_ns=\(caughtAt), response_written_seen_ns=\(written)")
                throw error
            }
            let returnedAt = DispatchTime.now().uptimeNanoseconds
            responseWrittenObserver.cancel()
            let writtenAt = await responseWrittenObserver.value
            let written = writtenAt.map { String($0) } ?? "not-observed"
            let finalStage = (try? String(contentsOf: stage, encoding: .utf8)) ?? "not-started"
            let fixedFinalStage = ["started", "awaiting-request", "received-request", "response-written"].contains(finalStage)
                ? finalStage : "not-observed"
            print("MCP_ENV_WITNESS form=\(form) start_ns=\(startedAt) send_ns=\(sendStartedAt) return_ns=\(returnedAt) response_written_seen_ns=\(written) final_stage=\(fixedFinalStage) wrapper_entered=\(FileManager.default.fileExists(atPath: wrapperStage.path))")
            #expect(response.error == nil)
            #expect(response.result == .object([
                "environmentClean": .bool(true),
                "configuredTokenPresent": .bool(true),
                "nestedClean": .bool(true)
            ]))
            transport.stop()
            #expect(transport.runtimeSnapshot().state != .running)
        }
    }

    private static func alive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func awaitNaturalRetirement(_ pids: [pid_t]) async {
        for _ in 0..<700 where pids.contains(where: alive) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func observeOwnedProcesses(root: pid_t, child: pid_t, group: pid_t) async throws
        -> (groupPIDs: Set<pid_t>, childParent: pid_t?, metadata: String) {
        let ps = try await capture("/bin/ps", ["-axo", "pid=,ppid=,pgid=,state=,lstart=,comm="])
        var groupPIDs = Set<pid_t>()
        var childParent: pid_t?
        var rows: [String] = []
        for line in ps.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                  let pgid = pid_t(fields[2]) else { continue }
            if pgid == group { groupPIDs.insert(pid) }
            if pid == child { childParent = ppid }
            if pid == root || pid == child { rows.append(String(line)) }
        }
        let descriptors = try await capture("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(root),\(child)", "-d", "0,1,2", "-Fpcftn"])
        return (groupPIDs, childParent,
                "MCP735 PS exit=\(ps.status)\n\(rows.joined(separator: "\n"))\nMCP735 LSOF exit=\(descriptors.status)\n\(descriptors.output)")
    }

    private static func capture(_ executable: String, _ arguments: [String]) async throws -> (output: String, status: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try captureSynchronously(executable, arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func captureSynchronously(_ executable: String, _ arguments: [String]) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = [:]
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: bytes, as: UTF8.self), process.terminationStatus)
    }

}
