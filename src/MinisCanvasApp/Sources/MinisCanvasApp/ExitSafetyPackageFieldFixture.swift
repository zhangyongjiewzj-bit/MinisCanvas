import Foundation
import Darwin
import MinisCore

/// Explicit D-APP-12 field producer. It combines the existing canonical Task
/// journey (including its real pending ApprovalPromptCenter request) with one
/// owned MCP stdio transport. No user MCP configuration or credential is read.
enum ExitSafetyPackageFieldFixture {
    static let activationArgument = "--exit-safety-field-journey"
    private static let markerName = "exit-safety-field-v1.marker"
    private static let markerContents = "EXIT_SAFETY_FIELD_V1\n"
    private static let taskMarkerName = "task-field-fixture-v1.marker"
    private static let processLifetimeSeconds = 180

    enum FixtureError: LocalizedError {
        case unsafeRoot, invalidMarker, occupiedTaskField, storeMismatch
        case unavailableInterpreter, missingOwnedProcess

        var errorDescription: String? {
            switch self {
            case .unsafeRoot: "退出现场根不是本用户的 0700 隔离目录"
            case .invalidMarker: "退出现场标记无效；拒绝重启子进程"
            case .occupiedTaskField: "任务现场已启动；拒绝补造退出现场子进程"
            case .storeMismatch: "退出现场会话存储不是生产视图的同一实例"
            case .unavailableInterpreter: "受控 stdio 现场解释器不可执行"
            case .missingOwnedProcess: "生产 MCP stdio 未形成可追踪的真实子进程"
            }
        }
    }

    static func isRequested(
        profile: RuntimeIsolationProfile,
        sessionFieldJourney: Bool,
        taskFieldJourney: Bool,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        profile.mode == .packagedField && sessionFieldJourney && taskFieldJourney
            && arguments.filter({ $0 == activationArgument }).count == 1
            && arguments.filter({ $0 == RuntimeIsolationProfile.fieldActivationArgument }).count == 1
            && environment[RuntimeIsolationProfile.fieldActivationMarkerKey] == "1"
    }

    /// Called from the production WindowGroup task after BridgeStore attaches
    /// the exact SettingsCenter SessionStore. Cancellation leaves the scope,
    /// disconnects the MCP client, and cancels TaskPackageFieldFixture's held
    /// child work. A marked restart is read-only and never relaunches either.
    @MainActor
    static func run(
        profile: RuntimeIsolationProfile,
        bridge: BridgeStore,
        sessionStore: SessionStore
    ) async throws {
        try Task.checkCancellation()
        var metadata = stat()
        guard profile.mode == .packagedField,
              lstat(profile.rootDirectory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else { throw FixtureError.unsafeRoot }
        guard let attached = bridge.chat.sessionStore, attached === sessionStore else {
            throw FixtureError.storeMismatch
        }
        let marker = profile.minisCanvasDirectory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == markerContents else {
                throw FixtureError.invalidMarker
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: profile.minisCanvasDirectory
            .appendingPathComponent(taskMarkerName).path) else {
            throw FixtureError.occupiedTaskField
        }
        let interpreter = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: interpreter) else {
            throw FixtureError.unavailableInterpreter
        }
        let fixtureRoot = profile.rootDirectory.appendingPathComponent(
            "exit-safety-field", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let script = fixtureRoot.appendingPathComponent("owned_stdio.py")
        let pidFile = fixtureRoot.appendingPathComponent("owned-pid")
        try controlledServerSource.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: script.path
        )
        // /usr/bin/env -i clears the inherited App environment before the
        // bounded child runs. The production MCPClient still owns its process.
        let server = MCPServer(
            id: "exit-safety-field", name: "退出现场受控 stdio", type: .stdio,
            command: "/usr/bin/env",
            args: ["-i", interpreter, script.path, pidFile.path,
                   String(processLifetimeSeconds)],
            timeoutSeconds: 10
        )
        let client = MCPClient(server: server)
        defer { client.disconnect() }
        try await client.connect()
        try Task.checkCancellation()
        guard let runtime = client.lifecycleSnapshot.runtime,
              runtime.state == .running,
              let pid = runtime.processIdentifier, pid > 0,
              client.isConnected,
              (try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == String(pid) else {
            throw FixtureError.missingOwnedProcess
        }
        try markerContents.write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: marker.path
        )
        print("EXIT_SAFETY_FIELD_STDIO_READY owned_pid=\(pid) parent_pid=\(getpid())")
        try await TaskPackageFieldFixture.run(
            profile: profile, bridge: bridge, sessionStore: sessionStore
        )
    }

    /// Tiny external server with a hard 180-second maximum. It answers only
    /// the production initialize handshake, then waits for stdin EOF (App
    /// exit) or its deadline. No network, tools, grants, or user data access.
    private static let controlledServerSource = """
    import json, os, select, sys, time
    pid_path, lifetime = sys.argv[1], int(sys.argv[2])
    with open(pid_path, "x", encoding="ascii") as out:
        out.write(str(os.getpid()))
    deadline = time.monotonic() + min(max(lifetime, 1), 180)
    while time.monotonic() < deadline:
        ready, _, _ = select.select([sys.stdin], [], [], min(deadline - time.monotonic(), 1))
        if not ready:
            continue
        line = sys.stdin.readline()
        if not line:
            break
        try:
            message = json.loads(line)
        except (ValueError, TypeError):
            break
        if message.get("method") == "initialize" and "id" in message:
            response = {"jsonrpc": "2.0", "id": message["id"], "result": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "serverInfo": {"name": "exit-safety-field", "version": "1"}}}
            print(json.dumps(response, separators=(",", ":")), flush=True)
    """
}
