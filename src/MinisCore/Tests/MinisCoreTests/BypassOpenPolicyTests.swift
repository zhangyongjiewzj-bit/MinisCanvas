import Foundation
import Testing
@testable import MinisCore

/// 绕过模式「全面放开」（用户 2026-10-22 决定）的 Core 测试。
/// 路径只用临时目录；不做真实删除；不读取凭据文件，只对路径字符串做判断。
@Suite("Bypass mode opened up: system floor, credential paths, scope")
struct BypassOpenPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func outsideBypassWriteKeepsADurableCheckpointAndRestoresWithoutWideningTheStore() async throws {
        let project = try makeTempDirectory().resolvingSymlinksInPath()
        let outside = try makeTempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: project); try? FileManager.default.removeItem(at: outside) }
        let path = outside.appendingPathComponent("probe.txt")
        try Data("before".utf8).write(to: path)
        let directory = project.appendingPathComponent("checkpoints")
        let store = try FileCheckpointStore(directory: directory, allowedRoots: [project])
        let builtin = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        builtin.fileCheckpointsEnabled = true
        builtin.fileCheckpointStore = store
        builtin.fileChangeSessionID = "session-1"
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [project.path]), now: { now })
        let executor = ComposerPolicyEnforcedToolExecutor(base: builtin, controller: controller)
        _ = try await executor.execute(name: "file_write", input: ["path": path.path, "content": "after"])
        #expect(try Data(contentsOf: path) == Data("after".utf8))
        let id = try #require(store.summaries(sessionID: "session-1").first?.id)
        let reopened = try FileCheckpointStore(directory: directory, allowedRoots: [project])
        #expect(throws: FileCheckpointStore.Failure.self) { try reopened.restore(id, sessionID: "session-1") }
        #expect(try Data(contentsOf: path) == Data("after".utf8))
        _ = try await ToolFileMutationScope.withLock(path: path) {
            try await controller.restoreFileCheckpoint(id, store: reopened, sessionID: "session-1")
        }
        #expect(try Data(contentsOf: path) == Data("before".utf8))
        #expect(try reopened.summaries(sessionID: "session-1").isEmpty)
        let normal = ComposerPolicyEnforcedToolExecutor(base: builtin,
            controller: ComposerAuthorizationController(snapshot: snapshot(mode: .auto),
                facts: facts(roots: [project.path]), now: { now }))
        await #expect(throws: ComposerAuthorizationError.pathOutsideAllowedRoots(path.path)) {
            _ = try await normal.execute(name: "file_write", input: ["path": path.path, "content": "blocked"])
        }
        #expect(try Data(contentsOf: path) == Data("before".utf8))
    }

    @Test func outsideBypassDeletionCapturesBeforeTrashAndCanRestoreTheFile() async throws {
        let project = try makeTempDirectory().resolvingSymlinksInPath()
        let outside = try makeTempDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: project); try? FileManager.default.removeItem(at: outside) }
        let path = outside.appendingPathComponent("delete.txt")
        try Data("keepable".utf8).write(to: path)
        let store = try FileCheckpointStore(directory: project.appendingPathComponent("checkpoints"), allowedRoots: [project])
        let builtin = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        builtin.fileCheckpointsEnabled = true
        builtin.fileCheckpointStore = store
        builtin.fileChangeSessionID = "session-1"
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [project.path]), now: { now })
        let executor = ComposerPolicyEnforcedToolExecutor(base: builtin, controller: controller)
        let trash = try RecordingTrash(in: project)
        _ = try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
            try await executor.execute(name: "file_delete", input: ["path": path.path])
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(trash.urls.map(\.path) == [path.path])
        let id = try #require(store.summaries(sessionID: "session-1").first?.id)
        _ = try await ToolFileMutationScope.withLock(path: path) {
            try await controller.restoreFileCheckpoint(id, store: store, sessionID: "session-1")
        }
        #expect(try Data(contentsOf: path) == Data("keepable".utf8))
        #expect(try Data(contentsOf: trash.directory.appendingPathComponent("delete.txt")) == Data("keepable".utf8))
        let link = outside.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        await #expect(throws: FileCheckpointStore.Failure.self) {
            _ = try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                try await executor.execute(name: "file_delete", input: ["path": link.path])
            }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == path.path)
        #expect(try Data(contentsOf: path) == Data("keepable".utf8))
        #expect(trash.urls.count == 1)
    }

    private func makeTempDirectory() throws -> URL {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent("BypassOpen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 捕获异步闭包抛出的错误；没抛则返回 nil。用于断言具体错误，而不只是「抛了」。
    private func capturedError(_ body: () async throws -> Void) async -> (any Error)? {
        do { try await body(); return nil } catch { return error }
    }

    /// 记录执行器在效果边界看到的 `BypassOpenScope.isActive`，不做任何真实动作。
    private final class ScopeProbeExecutor: ToolExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Bool] = []
        var observations: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
        private func record(_ active: Bool) { lock.lock(); seen.append(active); lock.unlock() }
        func execute(name: String, input: [String: Any]) async throws -> String {
            record(BypassOpenScope.isActive)
            return "probe"
        }
    }

    /// 假废纸篓：记录收到的 URL，并把它移进临时目录里的 fake-trash。
    private final class RecordingTrash: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [URL] = []
        let directory: URL
        init(in root: URL) throws {
            directory = root.appendingPathComponent("fake-trash", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return received }
        func move(_ url: URL) throws -> URL? {
            lock.lock(); received.append(url); lock.unlock()
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func snapshot(mode: ComposerTaskMode, confirmed: Bool? = nil) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: mode, approvalScope: .request, effort: .standard,
            sessionID: "session-1", turnID: 1, taskID: "task-1", messageID: "message-1",
            workspaceID: "workspace-1", createdAt: now,
            policyRevision: "facts-1", grantEpoch: "epoch-0",
            bypassModeConfirmed: confirmed ?? (mode == .bypassPermission),
            autonomyCeiling: .l3
        )
    }

    private func facts(roots: [String]) -> ComposerPolicyFactSource {
        let caps: Set<String> = ["file_read", "file_write", "file_edit", "file_delete", "shell_execute"]
        return ComposerPolicyFactSource(
            knownCapabilities: caps, grantedCapabilities: caps, allowedWriteRoots: roots,
            workspaceID: "workspace-1", revision: "facts-1", grantEpoch: "epoch-0",
            leaseID: "lease-1", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3
        )
    }

    // MARK: - 系统底线（文件）

    @Test("system files are protected for modify and delete, /usr/local is exempt")
    func systemFloorPaths() {
        for path in ["/System/Library/CoreServices/Finder.app/x", "/usr/bin/ls", "/private/var/db/dslocal/x",
                     "/bin/sh", "/sbin/mount", "/Library/Apple/System/x"] {
            #expect(BypassSystemFloor.violation(path: path, operation: .modify) != nil, "\(path) modify")
            #expect(BypassSystemFloor.violation(path: path, operation: .delete) != nil, "\(path) delete")
        }
        #expect(BypassSystemFloor.violation(path: "/usr/local/bin/tool", operation: .modify) == nil)
        #expect(BypassSystemFloor.violation(path: "/usr/local/bin/tool", operation: .delete) == nil)
        // macOS 卷大小写不敏感：换大小写写法不能绕过。
        #expect(BypassSystemFloor.violation(path: "/SYSTEM/library/x", operation: .modify) != nil)
        // 删除包含系统内容的父目录同样被拒。
        #expect(BypassSystemFloor.violation(path: "/", operation: .delete) != nil)
        #expect(BypassSystemFloor.violation(path: "/Library", operation: .delete) != nil)
        #expect(BypassSystemFloor.violation(path: "/private/var", operation: .delete) != nil)
    }

    @Test("path aliases /var, /etc, /tmp are judged exactly like their /private counterparts")
    func systemFloorAliasParity() {
        let pairs = [("/var/db/x", "/private/var/db/x"), ("/etc/hosts", "/private/etc/hosts"),
                     ("/tmp/bypass-open-x", "/private/tmp/bypass-open-x")]
        for (alias, real) in pairs {
            for operation in [BypassSystemFloor.Operation.modify, .delete] {
                #expect((BypassSystemFloor.violation(path: alias, operation: operation) == nil)
                        == (BypassSystemFloor.violation(path: real, operation: operation) == nil),
                        "\(alias) vs \(real) \(operation)")
            }
        }
        // /var/db 是 /private/var/db 的别名，底线里两种写法都必须拒绝。
        #expect(BypassSystemFloor.violation(path: "/var/db/x", operation: .modify) != nil)
        #expect(BypassSystemFloor.violation(path: "/private/var/db/x", operation: .modify) != nil)
    }

    @Test("symlink into a system directory is judged by its real path")
    func systemFloorFollowsSymlinks() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("usr-bin")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin")
        #expect(BypassSystemFloor.violation(path: link.appendingPathComponent("ls").path, operation: .modify) != nil)
        #expect(BypassSystemFloor.violation(path: dir.appendingPathComponent("plain.txt").path, operation: .delete) == nil)
    }

    @Test("installed apps are protected; new bundles and ordinary Applications siblings are not")
    func installedAppsFloor() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let realHome = PolicyRuntimePathBoundary.canonicalPath(home.path) ?? home.path
        let userApp = realHome + "/Applications/Foo.app"
        #expect(BypassSystemFloor.violation(path: userApp, operation: .delete, home: realHome) != nil)
        #expect(BypassSystemFloor.violation(path: userApp + "/Contents/Info.plist", operation: .delete, home: realHome) != nil)
        #expect(BypassSystemFloor.violation(path: "/Applications/Safari.app", operation: .delete, home: realHome) != nil)
        // 改写：已存在的 .app 内部拒绝，尚不存在的不拦（安装新软件）。
        #expect(BypassSystemFloor.violation(path: userApp + "/Contents/x", operation: .modify,
                                            home: realHome, fileExists: { _ in true }) != nil)
        #expect(BypassSystemFloor.violation(path: userApp + "/Contents/x", operation: .modify,
                                            home: realHome, fileExists: { _ in false }) == nil)
        // 非 .app 的普通文件不受影响。
        #expect(BypassSystemFloor.violation(path: realHome + "/Applications/notes.txt", operation: .delete, home: realHome) == nil)
        // 整个 Applications 目录不可删。
        #expect(BypassSystemFloor.violation(path: "/Applications", operation: .delete, home: realHome) != nil)
    }

    // MARK: - 系统底线（shell 尽力匹配）

    @Test("shell best-effort floor catches uninstall commands and protected targets")
    func shellFloorMatches() {
        let home = "/Users/tester"
        let blocked = [
            "brew uninstall wget", "rm -rf /Applications/Foo.app", "echo hi > /System/Library/x",
            "sed -i '' s/a/b/ /etc/hosts", "tee /usr/bin/x < in", "dd if=/dev/zero of=/sbin/x",
            "chmod 777 /bin/sh", "find /Applications/Foo.app -delete",
            "pkgutil --forget com.example.pkg", "mas uninstall 497799835", "cp a /usr/bin/x",
        ]
        for command in blocked {
            #expect(BypassSystemFloor.shellViolation(command: command, home: home, fileExists: { _ in true }) != nil,
                   "should be blocked: \(command)")
        }
        let allowed = [
            "cat /System/Library/x", "brew install wget", "echo hi > /tmp/x",
        ]
        for command in allowed {
            #expect(BypassSystemFloor.shellViolation(command: command, home: home, fileExists: { _ in true }) == nil,
                   "should pass: \(command)")
        }
    }

    @Test("shell best-effort floor: wildcards under Applications and non-.app Applications subfolders")
    func shellFloorApplicationsWildcardsAndFolders() {
        let home = "/Users/tester"
        let isUtilitiesFolder: (String) -> Bool = { $0 == "/Applications/Utilities" }
        let blocked: [String] = [
            "rm -rf /Applications/*", "rm -r /Applications/Utilities",
            "rm -rf /Applications/Utilities/Terminal.app",
        ]
        for command in blocked {
            #expect(BypassSystemFloor.shellViolation(
                command: command, home: home, fileExists: { _ in true }, isDirectory: isUtilitiesFolder) != nil,
                "should be blocked: \(command)")
        }
        let allowed = [
            "rm /Applications/notes.txt", "ls /Applications/*", "cp x /Applications/Utilities",
        ]
        for command in allowed {
            #expect(BypassSystemFloor.shellViolation(
                command: command, home: home, fileExists: { _ in true }, isDirectory: isUtilitiesFolder) == nil,
                "should pass: \(command)")
        }
    }

    @Test("file floor: /Applications non-.app folders and nested .app bundles are not deletable")
    func installedAppsFloorFoldersAndNestedBundles() {
        let home = "/Users/tester"
        #expect(BypassSystemFloor.violation(path: "/Applications/Utilities", operation: .delete,
                                            home: home, isDirectory: { _ in true }) != nil)
        // 同名但不是目录（普通文件）不按「可能含已装软件」处理。
        #expect(BypassSystemFloor.violation(path: "/Applications/Utilities", operation: .delete,
                                            home: home, isDirectory: { _ in false }) == nil)
        #expect(BypassSystemFloor.violation(path: "/Applications/Utilities/Terminal.app", operation: .delete,
                                            home: home) != nil)
        #expect(BypassSystemFloor.violation(path: "/Applications/Utilities/Terminal.app/Contents/x",
                                            operation: .modify, home: home, fileExists: { _ in true }) != nil)
        #expect(BypassSystemFloor.violation(path: "/Applications/*", operation: .delete, home: home) != nil)
        // 通配符只对删除/移动源生效；改写目标里的 * 不按这条拒绝。
        #expect(BypassSystemFloor.violation(path: "/Applications/*", operation: .modify, home: home) == nil)
    }

    @Test("credential protection also covers security keychain subcommands")
    func keychainSecurityCommands() {
        let home = "/Users/tester"
        let blocked = [
            "security find-generic-password -s foo -w", "sudo security export -k x -t certs", "security -i",
            "security delete-keychain a.keychain", "/usr/bin/security dump-keychain -d login.keychain",
            "FOO=1 security find-key", "security -q find-generic-password -s x",
            "security -p prompt find-generic-password -s x",
        ]
        for command in blocked {
            #expect(SensitiveFilePolicy.credentialShellViolation(command: command, home: home) != nil,
                    "should be blocked: \(command)")
        }
        let allowed = [
            "security find-identity -v -p codesigning", "security list-keychains", "echo security find-generic-password",
        ]
        for command in allowed {
            #expect(SensitiveFilePolicy.credentialShellViolation(command: command, home: home) == nil,
                    "should pass: \(command)")
        }
    }

    // MARK: - 凭据路径

    @Test("credential paths: dirs under home, key files, .env — templates are not credentials")
    func credentialPaths() throws {
        let home = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let h = PolicyRuntimePathBoundary.canonicalPath(home.path) ?? home.path
        for path in [h + "/.ssh/id_rsa", h + "/Library/Keychains/login.keychain-db", h + "/.aws/credentials"] {
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: h), "\(path)")
        }
        #expect(SensitiveFilePolicy.isCredentialPath(h + "/.netrc", home: h))
        for path in ["/tmp/project/.env", "/tmp/a/server.pem", "/tmp/a/private.key"] {
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: h), "\(path)")
        }
        for path in [h + "/Documents/notes.txt", "/tmp/project/.env.example", h + "/.sshkeys-not/readme"] {
            #expect(!SensitiveFilePolicy.isCredentialPath(path, home: h), "\(path)")
        }
        #expect(SensitiveFilePolicy.isCredentialPath(h + "/.ssh/id_rsa", home: h, directoriesOnly: true))
        #expect(!SensitiveFilePolicy.isCredentialPath("/tmp/project/.env", home: h, directoriesOnly: true))
        #expect(SensitiveFilePolicy.credentialProtectionEnabled, "default must be on")
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "cat ~/.ssh/id_rsa", home: h) != nil)
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "ls \(h)/Library/Keychains", home: h) != nil)
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "ls ~/Documents", home: h) == nil)
    }

    // MARK: - Composer 授权

    @Test("confirmed bypass reaches paths outside project roots; other modes still refuse")
    func controllerRootsOnlyOpenedForConfirmedBypass() async throws {
        let outside = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let input = try ComposerToolInput(["path": outside.appendingPathComponent("a.txt").path])
        let roots = ["/tmp/workspace-bypass-open-test"]

        let bypass = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: roots), now: { now })
        for capability in ["file_read", "file_write", "file_edit", "file_delete"] {
            #expect(try await bypass.authorize(capability: capability, input: input) == .execute, "\(capability)")
        }

        for mode in [ComposerTaskMode.manual, .autoEdit, .auto] {
            let controller = ComposerAuthorizationController(
                snapshot: snapshot(mode: mode), facts: facts(roots: roots), now: { now })
            await #expect(throws: ComposerAuthorizationError.self) {
                _ = try await controller.authorize(capability: "file_write", input: input)
            }
        }

        let unconfirmed = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission, confirmed: false), facts: facts(roots: roots), now: { now })
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await unconfirmed.authorize(capability: "file_write", input: input)
        }
    }

    @Test("bypass still refuses system modify/delete but may read system files")
    func controllerSystemFloor() async throws {
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: ["/tmp/workspace"]), now: { now })
        for capability in ["file_write", "file_edit", "file_delete"] {
            let input = try ComposerToolInput(["path": "/usr/bin/ls"])
            do {
                _ = try await controller.authorize(capability: capability, input: input)
                Issue.record("\(capability) on /usr/bin/ls must be refused")
            } catch let error as ComposerAuthorizationError {
                guard case .approvalDenied = error else {
                    Issue.record("unexpected error \(error)"); continue
                }
            }
        }
        let read = try ComposerToolInput(["path": "/usr/bin/ls"])
        #expect(try await controller.authorize(capability: "file_read", input: read) == .execute)
    }

    @Test("credential directories are refused for writes only in confirmed bypass; other modes keep the original path")
    func controllerCredentialWrites() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sshTarget = try ComposerToolInput(["path": NSHomeDirectory() + "/.ssh/authorized_keys", "content": "x"])
        let envTarget = try ComposerToolInput(["path": dir.appendingPathComponent(".env").path, "content": "x"])
        // 绕过：写/改/删 ~/.ssh 是凭据保护的硬拒绝，原因里带「凭据保护」。
        let bypassSSH = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [dir.path, NSHomeDirectory()]), now: { now })
        for capability in ["file_write", "file_edit", "file_delete"] {
            do {
                _ = try await bypassSSH.authorize(capability: capability, input: sshTarget)
                Issue.record("bypass \(capability) on ~/.ssh must be refused")
            } catch let error as ComposerAuthorizationError {
                guard case .approvalDenied(let reason?) = error, reason.contains("凭据保护") else {
                    Issue.record("unexpected \(error)"); continue
                }
            }
        }
        // 非绕过模式（用户 2026-10-22 决定）：恢复 7428f83 原行为，凭据保护不在此硬拒绝。
        // manual：写要审批，删要审批；auto：写直接放行（路径在授权根内）。
        let manual = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual), facts: facts(roots: [dir.path, NSHomeDirectory()]), now: { now })
        #expect(try await manual.authorize(capability: "file_write", input: sshTarget)
                == .requestApproval(requiresSecondConfirmation: false))
        #expect(try await manual.authorize(capability: "file_delete", input: sshTarget)
                == .requestApproval(requiresSecondConfirmation: false))
        let auto = ComposerAuthorizationController(
            snapshot: snapshot(mode: .auto), facts: facts(roots: [dir.path, NSHomeDirectory()]), now: { now })
        #expect(try await auto.authorize(capability: "file_write", input: sshTarget) == .execute)
        // 项目内 .env 的写入：绕过下直接放行，manual 仍走原有审批。
        let bypass = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [dir.path]), now: { now })
        #expect(try await bypass.authorize(capability: "file_write", input: envTarget) == .execute)
        let manualEnv = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual), facts: facts(roots: [dir.path]), now: { now })
        #expect(try await manualEnv.authorize(capability: "file_write", input: envTarget)
                == .requestApproval(requiresSecondConfirmation: false))
    }

    @Test("credential paths are refused for reads only in confirmed bypass; manual/autoEdit/plan/auto are not hard-denied")
    func controllerCredentialPaths() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = try ComposerToolInput(["path": dir.appendingPathComponent(".env").path])
        let key = try ComposerToolInput(["path": dir.appendingPathComponent("server.pem").path])
        let ssh = try ComposerToolInput(["path": NSHomeDirectory() + "/.ssh/config"])
        // 绕过：.env、密钥文件、~/.ssh 读都拒绝，原因带「凭据保护」。
        let bypass = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [dir.path, NSHomeDirectory()]), now: { now })
        for input in [env, key, ssh] {
            do {
                _ = try await bypass.authorize(capability: "file_read", input: input)
                Issue.record("bypass must refuse a credential path read")
            } catch let error as ComposerAuthorizationError {
                guard case .approvalDenied(let reason?) = error, reason.contains("凭据保护") else {
                    Issue.record("unexpected \(error)"); continue
                }
            }
        }
        // 其他四种模式：读 .env 等不被凭据保护硬拒绝（授权根内读取直接放行，和 7428f83 一致）。
        for mode in [ComposerTaskMode.manual, .autoEdit, .plan, .auto] {
            let controller = ComposerAuthorizationController(
                snapshot: snapshot(mode: mode), facts: facts(roots: [dir.path, NSHomeDirectory()]), now: { now })
            for input in [env, key, ssh] {
                #expect(try await controller.authorize(capability: "file_read", input: input) == .execute,
                        "\(mode.rawValue) must not hard-deny credential-path reads")
            }
        }
        // 快照里残留 bypassModeConfirmed == true 的非绕过模式同样不算绕过。
        let residual = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, confirmed: true), facts: facts(roots: [dir.path]), now: { now })
        #expect(try await residual.authorize(capability: "file_read", input: env) == .execute)
    }

    // MARK: - 设置兼容

    @Test("settings decode: old JSON gets safe defaults; new fields round-trip")
    func settingsBackwardCompatibleDecoding() throws {
        let old = #"{"mode":"bypass-permission","approvalScope":"workspace","effort":"high","bypassModeConfirmed":true}"#
        let decoded = try JSONDecoder().decode(ComposerPolicySettings.self, from: Data(old.utf8))
        #expect(decoded.mode == .bypassPermission)
        #expect(decoded.bypassModeConfirmed)
        #expect(decoded.disableBypass == false)
        #expect(decoded.protectCredentialPaths == true)

        let custom = ComposerPolicySettings(mode: .manual, disableBypass: true, protectCredentialPaths: false)
        let round = try JSONDecoder().decode(ComposerPolicySettings.self, from: JSONEncoder().encode(custom))
        #expect(round == custom)
        #expect(ComposerPolicySettings.default.disableBypass == false)
        #expect(ComposerPolicySettings.default.protectCredentialPaths == true)
    }

    // MARK: - 执行器

    @Test("executor: file tools leave the project root only inside BypassOpenScope")
    func executorRootsOnlyOpenInScope() async throws {
        let project = try makeTempDirectory()
        let elsewhere = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let executor = BuiltinToolExecutor(allowedRoot: project)
        let target = elsewhere.appendingPathComponent("outside.txt")

        // 范围外：因为路径在项目授权根之外被拒，错误类型是 pathViolation。
        let outsideError = await capturedError {
            _ = try await executor.execute(name: "file_write", input: ["path": target.path, "content": "x"])
        }
        #expect((outsideError as? ToolExecutorError) == .pathViolation(target.path),
                "outside scope must fail with pathViolation, got \(String(describing: outsideError))")
        #expect(!FileManager.default.fileExists(atPath: target.path))

        _ = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "file_write", input: ["path": target.path, "content": "hello"])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "hello")
        let read = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "file_read", input: ["path": target.path])
        }
        #expect(read.contains("hello"))

        // 系统底线在 scope 内仍然生效，且没有任何写入。
        // 错误必须是「绕过模式底线」的 writeFailed，而不是 pathViolation 之类别的拒绝。
        let floorError = await capturedError {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "file_write", input: ["path": "/usr/bin/bypass-open-test", "content": "x"])
            }
        }
        if case .writeFailed(let message)? = floorError as? ToolExecutorError {
            #expect(message.hasPrefix("绕过模式底线"), "unexpected message: \(message)")
        } else {
            Issue.record("expected writeFailed from the bypass floor, got \(String(describing: floorError))")
        }
        #expect(!FileManager.default.fileExists(atPath: "/usr/bin/bypass-open-test"))
    }

    @Test("executor: credential file read is refused only inside BypassOpenScope; outside it keeps the original behaviour")
    func executorCredentialRefusal() async throws {
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let env = project.appendingPathComponent(".env")
        try "TOKEN=synthetic".write(to: env, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: project)
        // 范围外（manual/autoEdit/plan/auto）：7428f83 原行为，项目内读 .env 不被硬拒绝。
        let plain = try await executor.execute(name: "file_read", input: ["path": env.path])
        #expect(plain.contains("TOKEN=synthetic"))
        // 绕过范围内：凭据保护拒绝，错误是 permissionDenied。
        let refused = await capturedError {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "file_read", input: ["path": env.path])
            }
        }
        #expect((refused as? ToolExecutorError) == .permissionDenied(env.path),
                "got \(String(describing: refused))")
        // 范围内写项目 .env 保持原有路径（凭据保护只拦凭据目录的写入）。
        _ = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "file_write", input: ["path": env.path, "content": "TOKEN=changed"])
        }
        #expect(try String(contentsOf: env, encoding: .utf8) == "TOKEN=changed")
    }

    @Test("executor: terminal policy hard-deny table applies outside the scope and is lifted inside it")
    func executorShellPolicyLiftedInScope() async throws {
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let executor = BuiltinToolExecutor(allowedRoot: project)

        // `mount` 在产品硬拒绝表里；不带参数只列出挂载点，无副作用。
        #expect(TerminalPolicySnapshot.default.classify(command: "mount") == .denied)
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await executor.execute(name: "shell_execute", input: ["command": "mount"])
        }
        let listed = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "shell_execute", input: ["command": "mount"])
        }
        #expect(!listed.isEmpty)

        // 未登记命令：普通模式审批后与绕过模式均可执行。
        let script = project.appendingPathComponent("qqq-unregistered-tool")
        try "#!/bin/sh\necho bypass-open-ok\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let unknownInput: [String: Any] = ["command": "qqqnotacommand"]
        let unknownResult = try await withFreshShellApprovalForTest(input: unknownInput) {
            try await executor.execute(name: "shell_execute", input: unknownInput)
        }
        let unknownEnvelope = try #require(try JSONSerialization.jsonObject(with: Data(unknownResult.utf8)) as? [String: Any])
        #expect((unknownEnvelope["exit_code"] as? Int) == 127)
        let ran = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "shell_execute", input: ["command": script.path])
        }
        #expect(ran.contains("bypass-open-ok"))

        // 底线（尽力匹配）在范围内仍拒绝：错误是「绕过模式底线」的 shellRejected，
        // 与范围外的「终端策略」拒绝信息不同。
        let floorError = await capturedError {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "shell_execute", input: ["command": "brew uninstall bypass-open-test-pkg"])
            }
        }
        #expect((floorError as? ToolExecutorError)
                == .shellRejected("绕过模式底线：不可卸载已安装软件（brew uninstall）"),
                "got \(String(describing: floorError))")

        // 凭据目录字面量在范围内同样拒绝（命令只是 echo，万一回归也不会读任何文件）。
        let credentialError = await capturedError {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "shell_execute", input: ["command": "echo ~/.ssh/bypass-open-test"])
            }
        }
        #expect((credentialError as? ToolExecutorError)
                == .shellRejected("凭据保护：不允许模型访问 ~/.ssh（可在设置里关闭此保护）"),
                "got \(String(describing: credentialError))")
    }

    // MARK: - 端到端：经 ComposerPolicyEnforcedToolExecutor

    @Test("end to end: only a confirmed bypass snapshot opens the scope; unconfirmed bypass and the other four modes never do")
    func enforcedExecutorOpensScopeOnlyForConfirmedBypass() async throws {
        let project = try makeTempDirectory()
        let elsewhere = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let seed = elsewhere.appendingPathComponent("seed.txt")
        try "seed".write(to: seed, atomically: true, encoding: .utf8)
        let roots = [project.path, elsewhere.path]   // 控制器放行；是否越过项目根只看执行器的 scope。

        func makeEnforced(_ base: any ToolExecutor, mode: ComposerTaskMode, confirmed: Bool?) -> ComposerPolicyEnforcedToolExecutor {
            ComposerPolicyEnforcedToolExecutor(
                base: base,
                controller: ComposerAuthorizationController(
                    snapshot: snapshot(mode: mode, confirmed: confirmed), facts: facts(roots: roots), now: { now }))
        }

        // manual / autoEdit / plan / auto，包括快照里残留 bypassModeConfirmed == true 的情形。
        for mode in [ComposerTaskMode.manual, .autoEdit, .plan, .auto] {
            for confirmed in [false, true] {
                let label = "\(mode.rawValue) confirmed=\(confirmed)"
                // 观察法：效果边界看到的 scope 必须是 false。
                let probe = ScopeProbeExecutor()
                let probed = makeEnforced(probe, mode: mode, confirmed: confirmed)
                _ = try await probed.execute(name: "file_read", input: ["path": seed.path])
                if mode == .auto || mode == .autoEdit {
                    _ = try await probed.execute(name: "file_write",
                        input: ["path": elsewhere.appendingPathComponent("probe.txt").path, "content": "x"])
                }
                #expect(probe.observations.allSatisfy { $0 == false } && !probe.observations.isEmpty, "\(label)")

                // 效果法：真实执行器（项目根只含 project）读写 elsewhere 必须被项目根拒绝。
                let real = makeEnforced(BuiltinToolExecutor(allowedRoot: project), mode: mode, confirmed: confirmed)
                let readError = await capturedError {
                    _ = try await real.execute(name: "file_read", input: ["path": seed.path])
                }
                #expect((readError as? ToolExecutorError) == .pathViolation(seed.path), "\(label)")
                let written = elsewhere.appendingPathComponent("e2e-\(mode.rawValue)-\(confirmed).txt")
                let writeError = await capturedError {
                    _ = try await real.execute(name: "file_write", input: ["path": written.path, "content": "leak"])
                }
                if mode == .auto || mode == .autoEdit {
                    #expect((writeError as? ToolExecutorError) == .pathViolation(written.path), "\(label)")
                }
                #expect(!FileManager.default.fileExists(atPath: written.path), "\(label)")
            }
        }

        // 未确认的绕过：控制器直接拒绝，执行器一次都没被调用，也没有写入。
        let unconfirmedProbe = ScopeProbeExecutor()
        let unconfirmed = makeEnforced(unconfirmedProbe, mode: .bypassPermission, confirmed: false)
        for name in ["file_read", "file_write"] {
            await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
                _ = try await unconfirmed.execute(name: name, input: ["path": seed.path, "content": "x"])
            }
        }
        #expect(unconfirmedProbe.observations.isEmpty)
        let unconfirmedReal = makeEnforced(BuiltinToolExecutor(allowedRoot: project), mode: .bypassPermission, confirmed: false)
        let unconfirmedTarget = elsewhere.appendingPathComponent("unconfirmed.txt")
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await unconfirmedReal.execute(name: "file_write", input: ["path": unconfirmedTarget.path, "content": "x"])
        }
        #expect(!FileManager.default.fileExists(atPath: unconfirmedTarget.path))

        // 对照：已确认的绕过才打开 scope，真实执行器可写项目根之外。
        let confirmedProbe = ScopeProbeExecutor()
        _ = try await makeEnforced(confirmedProbe, mode: .bypassPermission, confirmed: true)
            .execute(name: "file_write", input: ["path": seed.path, "content": "x"])
        #expect(confirmedProbe.observations == [true])
        let confirmedTarget = elsewhere.appendingPathComponent("confirmed.txt")
        _ = try await makeEnforced(BuiltinToolExecutor(allowedRoot: project), mode: .bypassPermission, confirmed: true)
            .execute(name: "file_write", input: ["path": confirmedTarget.path, "content": "opened"])
        #expect(try String(contentsOf: confirmedTarget, encoding: .utf8) == "opened")
    }

    // MARK: - 废纸篓（runFileTrash）

    @Test("trash failure surfaces as an error and leaves the original file; it never falls back to permanent delete")
    func trashFailureKeepsOriginal() async throws {
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let file = project.appendingPathComponent("keep-me.txt")
        try "precious".write(to: file, atomically: true, encoding: .utf8)
        let executor = BuiltinToolExecutor(allowedRoot: project)
        let failing: @Sendable (URL) throws -> URL? = { _ in throw CocoaError(.fileWriteNoPermission) }

        let error = await capturedError {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await BypassTrashSeam.$mover.withValue(failing) {
                    try await executor.execute(name: "file_delete", input: ["path": file.path])
                }
            }
        }
        if case .writeFailed(let message)? = error as? ToolExecutorError {
            #expect(message.hasPrefix("无法移入废纸篓"), "unexpected message: \(message)")
        } else {
            Issue.record("expected writeFailed from the trash step, got \(String(describing: error))")
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "precious")
    }

    @Test("trash of a symlink leaf moves the link itself, not what it points to")
    func trashSymlinkLeafMovesLinkOnly() async throws {
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let target = project.appendingPathComponent("real.txt")
        try "target-content".write(to: target, atomically: true, encoding: .utf8)
        let link = project.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let trash = try RecordingTrash(in: project)
        let executor = BuiltinToolExecutor(allowedRoot: project)

        let result = try await BypassOpenScope.$isActive.withValue(true) {
            try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                try await executor.execute(name: "file_delete", input: ["path": link.path])
            }
        }
        #expect(result.contains("已移入废纸篓"))
        #expect(trash.urls.map(\.lastPathComponent) == ["link.txt"])
        // 链接已离开原位，目标文件原样保留；废纸篓里的仍是一条指向目标的符号链接。
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(try String(contentsOf: target, encoding: .utf8) == "target-content")
        let trashed = trash.directory.appendingPathComponent("link.txt")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: trashed.path))?.hasSuffix("real.txt") == true)
    }

    // MARK: - 用户 2026-10-22 决定：系统底线新增 LaunchDaemons / Frameworks / etc

    @Test("system floor also covers /Library/LaunchDaemons, /Library/Frameworks and /etc (with the /private/etc alias)")
    func systemFloorLaunchDaemonsFrameworksEtc() async throws {
        for path in ["/Library/LaunchDaemons/com.example.bypass-open.plist",
                     "/Library/Frameworks/Example.framework/Versions/A/Example",
                     "/etc/hosts"] {
            #expect(BypassSystemFloor.violation(path: path, operation: .modify) != nil, "\(path) modify")
            #expect(BypassSystemFloor.violation(path: path, operation: .delete) != nil, "\(path) delete")
        }
        // 范围没有被无意扩大：LaunchAgents、其他 /Library 子目录、名字相近的目录、/tmp 不受影响。
        for path in ["/Library/LaunchAgents/com.example.plist", "/etcetera/x", "/tmp/bypass-open-x"] {
            #expect(BypassSystemFloor.violation(path: path, operation: .modify) == nil, "\(path) modify")
        }
        // 读不拦（底线只约束改写/删除）：控制器对绕过读 /etc/hosts 放行，写/改/删拒绝。
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: ["/tmp/workspace"]), now: { now })
        #expect(try await controller.authorize(
            capability: "file_read", input: try ComposerToolInput(["path": "/etc/hosts"])) == .execute)
        for (capability, path) in [("file_write", "/etc/hosts"), ("file_edit", "/Library/Frameworks/x"),
                                   ("file_delete", "/Library/LaunchDaemons/x.plist")] {
            do {
                _ = try await controller.authorize(
                    capability: capability, input: try ComposerToolInput(["path": path, "content": "x"]))
                Issue.record("\(capability) on \(path) must be refused")
            } catch let error as ComposerAuthorizationError {
                guard case .approvalDenied = error else { Issue.record("unexpected \(error)"); continue }
            }
        }
        // shell 尽力匹配（不是安全边界）。
        for command in ["rm /etc/hosts", "echo x > /Library/LaunchDaemons/a.plist",
                        "mv /Library/Frameworks/X.framework /tmp/x"] {
            #expect(BypassSystemFloor.shellViolation(command: command) != nil, "should be blocked: \(command)")
        }
        for command in ["cat /etc/hosts", "ls /Library/LaunchDaemons", "cp /etc/hosts ./hosts-copy"] {
            #expect(BypassSystemFloor.shellViolation(command: command) == nil, "should pass: \(command)")
        }
        // 执行器：scope 内写这些路径被「绕过模式底线」拒绝（底线检查在任何写入之前）。
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let executor = BuiltinToolExecutor(allowedRoot: project)
        for path in ["/etc/bypass-open-test", "/Library/LaunchDaemons/bypass-open-test.plist",
                     "/Library/Frameworks/bypass-open-test"] {
            let error = await capturedError {
                _ = try await BypassOpenScope.$isActive.withValue(true) {
                    try await executor.execute(name: "file_write", input: ["path": path, "content": "x"])
                }
            }
            if case .writeFailed(let message)? = error as? ToolExecutorError {
                #expect(message.hasPrefix("绕过模式底线"), "unexpected message for \(path): \(message)")
            } else {
                Issue.record("expected writeFailed from the bypass floor for \(path), got \(String(describing: error))")
            }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: - 用户 2026-10-22 决定：Application Support 只拦 MinisCanvas 自己的目录与钥匙串

    private struct FakeHome {
        let root: URL
        let home: String      // 规范化路径
        let support: String   // <home>/Library/Application Support
    }

    private func makeFakeHome() throws -> FakeHome {
        let root = try makeTempDirectory()
        let home = PolicyRuntimePathBoundary.canonicalPath(root.path) ?? root.path
        let support = home + "/Library/Application Support"
        for sub in ["Application Support/OtherApp", "Application Support/MinisCore",
                    "Application Support/MinisCanvas", "Keychains"] {
            try FileManager.default.createDirectory(
                atPath: home + "/Library/" + sub, withIntermediateDirectories: true)
        }
        return FakeHome(root: root, home: home, support: support)
    }

    @Test("app data floor: only MinisCore, MinisCanvas and Keychains are protected; other Application Support content is open")
    func appDataFloorPaths() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home, support = fake.support
        let openPaths: [String] = [support + "/OtherApp/x.txt", support + "/MinisCoreExtra/x", h + "/Library/Preferences/x.plist"]
        let blocked: [String] = [support + "/MinisCore/settings.json", support + "/MinisCanvas/sessions/a.json",
                                h + "/Library/Keychains/login.keychain-db"]
        for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
            for path in openPaths {
                #expect(BypassAppDataFloor.violation(path: path, access: access, home: h) == nil, "\(path) \(access)")
            }
            for path in blocked {
                #expect(BypassAppDataFloor.violation(path: path, access: access, home: h) != nil, "\(path) \(access)")
            }
        }
        // 删除包含这些目录的父目录同样拒绝；读/改父目录本身不拦。
        for ancestor in [support, h + "/Library"] {
            #expect(BypassAppDataFloor.violation(path: ancestor, access: .delete, home: h) != nil, "\(ancestor)")
            #expect(BypassAppDataFloor.violation(path: ancestor, access: .read, home: h) == nil, "\(ancestor)")
            #expect(BypassAppDataFloor.violation(path: ancestor, access: .modify, home: h) == nil, "\(ancestor)")
        }
        // 符号链接按真实路径判断。
        let link = h + "/alias-to-core"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: support + "/MinisCore")
        #expect(BypassAppDataFloor.violation(path: link + "/x", access: .modify, home: h) != nil)
        // 默认的整个 Application Support 拒绝项被识别为「通用根」，MinisCore 和用户自己的目录不是。
        #expect(BypassAppDataFloor.isGenericApplicationSupportRoot(support, home: h))
        #expect(!BypassAppDataFloor.isGenericApplicationSupportRoot(support + "/MinisCore", home: h))
        #expect(!BypassAppDataFloor.isGenericApplicationSupportRoot(h + "/Documents/private", home: h))
    }

    @Test("executor: in bypass scope Application Support is no longer denied as a whole; MinisCanvas dirs and Keychains still are")
    func executorApplicationSupportNarrowed() async throws {
        let fake = try makeFakeHome()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: fake.root)
            try? FileManager.default.removeItem(at: project)
        }
        let h = fake.home, support = fake.support
        let userDenied = h + "/Documents/private"
        try FileManager.default.createDirectory(atPath: userDenied, withIntermediateDirectories: true)
        // 默认拒绝项 = 整个 Application Support；另有用户自己加的拒绝目录。
        let executor = BuiltinToolExecutor(
            allowedRoot: project,
            deniedRoots: [URL(fileURLWithPath: support, isDirectory: true), URL(fileURLWithPath: userDenied, isDirectory: true)])
        let trash = try RecordingTrash(in: project)
        func run(_ name: String, _ input: [String: Any]) async throws -> String {
            try await BypassHomeSeam.$homeOverride.withValue(h) {
                try await BypassOpenScope.$isActive.withValue(true) {
                    try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                        try await executor.execute(name: name, input: input)
                    }
                }
            }
        }

        // 范围外：不在项目根内，且整个 Application Support 被拒绝。
        let other = support + "/OtherApp/x.txt"
        let outside = await capturedError {
            _ = try await executor.execute(name: "file_write", input: ["path": other, "content": "x"])
        }
        #expect((outside as? ToolExecutorError) == .pathViolation(other))
        #expect(!FileManager.default.fileExists(atPath: other))

        // 范围内：别的应用的目录可读可写。
        _ = try await run("file_write", ["path": other, "content": "other-app-data"])
        #expect(try String(contentsOf: URL(fileURLWithPath: other), encoding: .utf8) == "other-app-data")
        #expect(try await run("file_read", ["path": other]).contains("other-app-data"))

        // 范围内：MinisCanvas 自己的目录（含 MinisCore 设置/规则所在目录）与钥匙串仍被拒绝，且没有任何写入。
        let protectedPaths: [String] = [support + "/MinisCore/settings.json", support + "/MinisCore/rules/terminal.json",
                              support + "/MinisCanvas/sessions/a.json", h + "/Library/Keychains/login.keychain-db"]
        for path in protectedPaths {
            for (name, input) in [("file_write", ["path": path, "content": "x"]), ("file_read", ["path": path]),
                                  ("file_delete", ["path": path])] as [(String, [String: Any])] {
                let error = await capturedError { _ = try await run(name, input) }
                #expect((error as? ToolExecutorError) == .pathViolation(path), "\(name) \(path): \(String(describing: error))")
            }
            #expect(!FileManager.default.fileExists(atPath: path), "\(path)")
        }

        // 删除整个 Application Support（包含上面的受保护目录）被拒绝，什么都没进废纸篓。
        let wipe = await capturedError { _ = try await run("file_delete", ["path": support]) }
        if case .writeFailed(let message)? = wipe as? ToolExecutorError {
            #expect(message.hasPrefix("绕过模式底线"), "unexpected message: \(message)")
        } else {
            Issue.record("expected writeFailed for deleting Application Support, got \(String(describing: wipe))")
        }
        #expect(trash.urls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: support + "/MinisCore"))

        // 用户自己加的拒绝目录在绕过下继续生效。
        let denied = userDenied + "/secret.txt"
        let userError = await capturedError { _ = try await run("file_write", ["path": denied, "content": "x"]) }
        #expect((userError as? ToolExecutorError) == .pathViolation(denied))
        #expect(!FileManager.default.fileExists(atPath: denied))

        // 经 Composer 执行器的完整链路：OtherApp 可写；MinisCore 在控制器就被拒绝。
        let enforced = ComposerPolicyEnforcedToolExecutor(
            base: executor,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .bypassPermission), facts: facts(roots: [project.path]), now: { now }))
        let viaComposer = support + "/OtherApp/via-composer.txt"
        _ = try await BypassHomeSeam.$homeOverride.withValue(h) {
            try await enforced.execute(name: "file_write", input: ["path": viaComposer, "content": "ok"])
        }
        #expect(try String(contentsOf: URL(fileURLWithPath: viaComposer), encoding: .utf8) == "ok")
        let ownFile = support + "/MinisCanvas/via-composer.txt"
        let composerError = await capturedError {
            _ = try await BypassHomeSeam.$homeOverride.withValue(h) {
                try await enforced.execute(name: "file_write", input: ["path": ownFile, "content": "x"])
            }
        }
        if case .approvalDenied? = composerError as? ComposerAuthorizationError {} else {
            Issue.record("expected approvalDenied from the controller, got \(String(describing: composerError))")
        }
        #expect(!FileManager.default.fileExists(atPath: ownFile))
    }

    @Test("shell best-effort: writes, deletes and moves into MinisCanvas dirs and Keychains are refused; literal mentions too")
    func appDataFloorShell() async throws {
        let fake = try makeFakeHome()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: fake.root)
            try? FileManager.default.removeItem(at: project)
        }
        let h = fake.home, support = fake.support
        let blocked: [String] = [
            "rm -rf \"\(support)/MinisCore\"", "echo x > '\(support)/MinisCore/rules.json'",
            "mv \"\(support)/MinisCanvas\" /tmp/elsewhere",
        ]
        for command in blocked {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        let allowed: [String] = [
            "touch \"\(support)/OtherApp/x\"", "rm \"\(support)/OtherApp/x\"", "echo x > ~/Library/Application\\ Support/OtherApp/y",
        ]
        for command in allowed {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) == nil, "should pass: \(command)")
        }
        // 字面提及（含只读）：反斜杠空格、引号、$HOME、绝对路径、钥匙串。
        for command in ["cat ~/Library/Application\\ Support/MinisCore/envvars.json",
                        "cat \"$HOME/Library/Application Support/MinisCanvas/x\"", "cat /Library/Keychains/System.keychain"] {
            #expect(BypassAppDataFloor.shellMentionViolation(command: command) != nil, "should be blocked: \(command)")
        }
        for command in ["ls ~/Library/Application\\ Support/OtherApp", "echo hi", "ls ~/Library/Preferences"] {
            #expect(BypassAppDataFloor.shellMentionViolation(command: command) == nil, "should pass: \(command)")
        }

        // 执行器：范围内 shell 写 MinisCore 被拒绝且没有写入；写别的应用目录可以执行。
        let executor = BuiltinToolExecutor(allowedRoot: project)
        func run(_ command: String) async throws -> String {
            try await BypassHomeSeam.$homeOverride.withValue(h) {
                try await BypassOpenScope.$isActive.withValue(true) {
                    try await executor.execute(name: "shell_execute", input: ["command": command])
                }
            }
        }
        let own = support + "/MinisCore/shell-write.txt"
        let error = await capturedError { _ = try await run("echo x > \"\(own)\"") }
        if case .shellRejected(let message)? = error as? ToolExecutorError {
            #expect(message.hasPrefix("绕过模式底线：不可访问 MinisCanvas 自身"), "unexpected message: \(message)")
        } else {
            Issue.record("expected shellRejected, got \(String(describing: error))")
        }
        #expect(!FileManager.default.fileExists(atPath: own))
        let fine = support + "/OtherApp/shell-write.txt"
        _ = try await run("echo shell-ok > \"\(fine)\"")
        #expect(try String(contentsOf: URL(fileURLWithPath: fine), encoding: .utf8).contains("shell-ok"))
    }

    // MARK: - 用户 2026-10-22 决定：绕过下 userDeniedCommands 继续生效

    @Test("userDeniedExecutable uses the same matching as classify and ignores the product hard-deny table")
    func userDeniedExecutableMatching() {
        let echoDenied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo"], confirmationCommands: [], userDeniedCommands: ["echo"]))
        #expect(echoDenied.userDeniedExecutable(in: "echo denied") == "echo")
        #expect(echoDenied.userDeniedExecutable(in: "ls") == nil)
        let rmDenied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["ls", "echo"], confirmationCommands: [], userDeniedCommands: ["rm"]))
        #expect(rmDenied.userDeniedExecutable(in: "ls; rm -rf .") == "rm")
        // 产品硬拒绝表不是用户拒绝表：bypass 下它们被取消，这里不算命中。
        #expect(rmDenied.userDeniedExecutable(in: "sudo ls") == nil)
        #expect(rmDenied.userDeniedExecutable(in: "mount") == nil)
        // 引号里的词只是参数。
        #expect(rmDenied.userDeniedExecutable(in: #"echo "rm""#) == nil)
        let printfDenied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["env", "nice", "echo", "open", "printf"], confirmationCommands: [],
            userDeniedCommands: ["printf"]))
        #expect(printfDenied.userDeniedExecutable(in: "env nice -- printf synthetic") == "printf")
        #expect(TerminalPolicySnapshot.default.userDeniedExecutable(in: "rm -rf x") == nil)
    }

    @Test("executor: userDeniedCommands stay denied inside the bypass scope while the system hard-deny table and unregistered refusal are lifted")
    func executorUserDeniedCommandsStayInScope() async throws {
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let snapshot = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["echo"], confirmationCommands: [], userDeniedCommands: ["echo"]))
        let executor = BuiltinToolExecutor(allowedRoot: project, terminalPolicySnapshot: snapshot)
        let marker = project.appendingPathComponent("should-not-exist.txt")

        // 范围外：用户拒绝照旧。
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await executor.execute(name: "shell_execute", input: ["command": "echo outside"])
        }
        // 范围内：用户拒绝继续生效，命令没有执行（包括带重定向的写文件）。
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "shell_execute", input: ["command": "echo inside"])
            }
        }
        await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
            _ = try await BypassOpenScope.$isActive.withValue(true) {
                try await executor.execute(name: "shell_execute",
                                           input: ["command": "echo x; echo y > \"\(marker.path)\""])
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // 范围内：系统硬拒绝表（mount）和未登记命令（printf 不在允许表里）被取消。
        let listed = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "shell_execute", input: ["command": "mount"])
        }
        #expect(!listed.isEmpty)
        let printed = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "shell_execute", input: ["command": "/usr/bin/printf bypass-user-ok"])
        }
        #expect(printed.contains("bypass-user-ok"))
    }

    // MARK: - 用户 2026-10-22 决定：子任务文件跟随父会话

    @Test("child file scope opens only when the parent is a confirmed bypass AND the child-write switch is on")
    func childFilesOpenIntent() {
        let confirmedBypass = snapshot(mode: .bypassPermission)
        #expect(AgentOrchestrator.childFilesOpen(childMutationsEnabled: true, parent: confirmedBypass))
        // 开关关闭：行为不变。
        #expect(!AgentOrchestrator.childFilesOpen(childMutationsEnabled: false, parent: confirmedBypass))
        // 父会话不是已确认的绕过：不打开（含快照里残留 bypassModeConfirmed 的非绕过模式）。
        #expect(!AgentOrchestrator.childFilesOpen(
            childMutationsEnabled: true, parent: snapshot(mode: .bypassPermission, confirmed: false)))
        for mode in [ComposerTaskMode.manual, .autoEdit, .plan, .auto] {
            for confirmed in [false, true] {
                #expect(!AgentOrchestrator.childFilesOpen(
                    childMutationsEnabled: true, parent: snapshot(mode: mode, confirmed: confirmed)),
                        "\(mode.rawValue) confirmed=\(confirmed)")
            }
        }
        #expect(!AgentOrchestrator.childFilesOpen(childMutationsEnabled: true, parent: nil))
    }

    @Test("child workspace scope: files leave the child roots only with filesOpen AND a bypass scope; floor and trash still apply")
    func childScopeFilesOpenNeedsBothSwitches() async throws {
        let project = try makeTempDirectory()
        let elsewhere = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let physicalProject = try #require(PolicyRuntimePathBoundary.canonicalPath(project.path))
        let executor = BuiltinToolExecutor(allowedRoot: project, deniedRoots: [])
        let trash = try RecordingTrash(in: project)
        func run(open: Bool, bypass: Bool, _ name: String, _ input: [String: Any]) async throws -> String {
            let scope = ChildToolWorkspaceScope(
                readRoots: [physicalProject], writeRoots: [physicalProject], workingDirectory: physicalProject,
                deniedRoots: [], parentAuthorityCheck: nil, filesOpen: open)
            return try await ChildToolWorkspaceScope.$current.withValue(scope) {
                try await BypassOpenScope.$isActive.withValue(bypass) {
                    try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                        try await executor.execute(name: name, input: input)
                    }
                }
            }
        }
        let target = elsewhere.appendingPathComponent("child-outside.txt")
        let input: [String: Any] = ["path": target.path, "content": "child-wrote"]

        // 缺任一条件都仍被子任务根拒绝：开关关、不在绕过范围内、两者都没有。
        for (open, bypass) in [(false, true), (true, false), (false, false)] {
            let error = await capturedError { _ = try await run(open: open, bypass: bypass, "file_write", input) }
            #expect((error as? ToolExecutorError) == .pathViolation(target.path), "open=\(open) bypass=\(bypass)")
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        // 两者都有：写、读、删（移入废纸篓）都可以在子任务根之外进行。
        _ = try await run(open: true, bypass: true, "file_write", input)
        #expect(try String(contentsOf: target, encoding: .utf8) == "child-wrote")
        #expect(try await run(open: true, bypass: true, "file_read", ["path": target.path]).contains("child-wrote"))
        let deleted = try await run(open: true, bypass: true, "file_delete", ["path": target.path])
        #expect(deleted.contains("已移入废纸篓"))
        #expect(trash.urls.map(\.lastPathComponent) == ["child-outside.txt"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // 底线仍然生效。
        let floorError = await capturedError {
            _ = try await run(open: true, bypass: true, "file_write",
                              ["path": "/usr/bin/bypass-open-child-test", "content": "x"])
        }
        if case .writeFailed(let message)? = floorError as? ToolExecutorError {
            #expect(message.hasPrefix("绕过模式底线"), "unexpected message: \(message)")
        } else {
            Issue.record("expected writeFailed from the bypass floor, got \(String(describing: floorError))")
        }
        // 凭据读保护仍然生效（子任务读 .env 被拒）。
        let env = elsewhere.appendingPathComponent(".env")
        try "TOKEN=synthetic".write(to: env, atomically: true, encoding: .utf8)
        let credentialError = await capturedError {
            _ = try await run(open: true, bypass: true, "file_read", ["path": env.path])
        }
        #expect((credentialError as? ToolExecutorError) == .permissionDenied(env.path))
    }

    // MARK: - 复核必改项（firmlink 前缀、大小写、符号链接根、测试配置、通配符）

    private let dataVolume = "/System/Volumes/Data"

    @Test("firmlink form /System/Volumes/Data/... cannot bypass the app-data floor, the credential paths or the system floor")
    func firmlinkPrefixCannotBypassFloors() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home, support = fake.support
        let fm = dataVolume
        // 受保护目录的 firmlink 写法：读、改、删都拒绝（路径为 firmlink 形式，或 HOME 为 firmlink 形式）。
        for tail in ["/Library/Application Support/MinisCore/settings.json", "/Library/Application Support/MinisCanvas/x",
                     "/Library/Keychains/login.keychain-db"] {
            for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
                #expect(BypassAppDataFloor.violation(path: fm + h + tail, access: access, home: h) != nil, "\(tail) \(access)")
                #expect(BypassAppDataFloor.violation(path: h + tail, access: access, home: fm + h) != nil, "home firmlink \(tail) \(access)")
            }
        }
        #expect(BypassAppDataFloor.violation(path: fm + "/Library/Keychains/System.keychain", access: .modify, home: h) != nil)
        // 别的应用目录不受影响；删除父目录仍拒绝，读不拦。
        #expect(BypassAppDataFloor.violation(path: fm + support + "/OtherApp/x", access: .modify, home: h) == nil)
        #expect(BypassAppDataFloor.violation(path: fm + support, access: .delete, home: h) != nil)
        #expect(BypassAppDataFloor.violation(path: fm + support, access: .read, home: h) == nil)
        #expect(BypassAppDataFloor.isGenericApplicationSupportRoot(fm + support, home: h))

        // 凭据路径：~/.ssh、钥匙串、云凭据（合成家目录，不碰真实文件）。
        let user = "/Users/bypass-synthetic-user"
        for path in [fm + user + "/.ssh/id_rsa", fm + user + "/.aws/credentials",
                     fm + user + "/Library/Keychains/login.keychain-db"] {
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: user), "\(path)")
            #expect(SensitiveFilePolicy.isCredentialPath(path, home: fm + user), "firmlink home \(path)")
        }
        #expect(SensitiveFilePolicy.isCredentialPath(fm + user + "/.ssh/config", home: user, directoriesOnly: true))
        #expect(SensitiveFilePolicy.isCredentialPath(fm + NSHomeDirectory() + "/.ssh/id_rsa"))
        #expect(!SensitiveFilePolicy.isCredentialPath(fm + user + "/Documents/notes.txt", home: user))
        #expect(!SensitiveFilePolicy.isCredentialPath(fm + user + "/.sshkeys-not/readme", home: user))

        // 系统底线：firmlink 写法与原写法一致（/private 也折回）。
        for path in [fm + "/usr/bin/x", fm + "/private/etc/hosts", fm + "/private/var/db/x"] {
            #expect(BypassSystemFloor.violation(path: path, operation: .modify, home: h) != nil, "\(path)")
        }
        #expect(BypassSystemFloor.violation(path: fm + "/usr/local/bin/x", operation: .modify, home: h) == nil)
        #expect(BypassSystemFloor.violation(path: fm + user + "/Documents/a.txt", operation: .modify, home: h) == nil)
        #expect(BypassSystemFloor.violation(path: fm + "/Applications/Foo.app", operation: .delete, home: h) != nil)
    }

    @Test("firmlink form is refused by the shell best-effort checks and the credential shell check")
    func firmlinkPrefixShell() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home, support = fake.support
        let fm = dataVolume
        for command in ["rm -rf \"\(fm)\(support)/MinisCore\"", "echo x > '\(fm)\(support)/MinisCanvas/a'",
                        "mv \(fm)\(h)/Library/Keychains /tmp/bypass-x"] {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        #expect(BypassSystemFloor.shellViolation(
            command: "touch \"\(fm)\(support)/OtherApp/x\"", home: h) == nil)
        let user = "/Users/bypass-synthetic-user"
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "cat \(fm)\(user)/.ssh/id_rsa", home: user) != nil)
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "ls \(fm)\(user)/Library/Keychains", home: user) != nil)
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "cat \(fm)\(user)/.ssh/id_rsa", home: fm + user) != nil)
        #expect(SensitiveFilePolicy.credentialShellViolation(command: "ls \(fm)\(user)/Documents", home: user) == nil)
        #expect(BypassAppDataFloor.shellMentionViolation(command: "cat \(fm)\(support)/MinisCore/envvars.json") != nil)
        #expect(BypassAppDataFloor.shellMentionViolation(command: "ls \(fm)/Library/Keychains") != nil)
    }

    @Test("executor: firmlink spellings of protected directories are refused for read, write and delete inside the scope")
    func executorFirmlinkProtectedDirectories() async throws {
        let fake = try makeFakeHome()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: fake.root)
            try? FileManager.default.removeItem(at: project)
        }
        let h = fake.home, support = fake.support
        let executor = BuiltinToolExecutor(
            allowedRoot: project, deniedRoots: [URL(fileURLWithPath: support, isDirectory: true)])
        let trash = try RecordingTrash(in: project)
        func run(_ name: String, _ input: [String: Any]) async throws -> String {
            try await BypassHomeSeam.$homeOverride.withValue(h) {
                try await BypassOpenScope.$isActive.withValue(true) {
                    try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                        try await executor.execute(name: name, input: input)
                    }
                }
            }
        }
        for path in [dataVolume + support + "/MinisCore/settings.json", dataVolume + h + "/Library/Keychains/login.keychain-db",
                     dataVolume + h + "/.config/miniscanvas-test/k.json"] {
            for (name, input) in [("file_write", ["path": path, "content": "x"]), ("file_read", ["path": path]),
                                  ("file_delete", ["path": path])] as [(String, [String: Any])] {
                let error = await capturedError { _ = try await run(name, input) }
                #expect((error as? ToolExecutorError) == .pathViolation(path), "\(name) \(path): \(String(describing: error))")
            }
        }
        #expect(trash.urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: support + "/MinisCore/settings.json"))
    }

    @Test("protected directories are normalised one by one: a symlinked MinisCore is hit by both spellings; results are stable across repeated calls")
    func appDataFloorSymlinkedProtectedRoot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = PolicyRuntimePathBoundary.canonicalPath(root.path) ?? root.path
        let support = h + "/Library/Application Support"
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        let elsewhere = h + "/elsewhere-core"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: support + "/MinisCore", withDestinationPath: elsewhere)
        for _ in 0..<2 {
            // 经链接访问、直接访问链接指向的真实目录，都命中。
            for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
                #expect(BypassAppDataFloor.violation(path: support + "/MinisCore/x.json", access: access, home: h) != nil)
                #expect(BypassAppDataFloor.violation(path: support + "/MinisCore", access: access, home: h) != nil)
                #expect(BypassAppDataFloor.violation(path: elsewhere + "/x.json", access: access, home: h) != nil)
            }
            #expect(BypassAppDataFloor.violation(path: support + "/OtherApp/x", access: .modify, home: h) == nil)
        }
        // 受保护目录表同时含「链接字面形式」与「链接指向的真实目录」两种折叠写法，且没有重复项。
        let roots = BypassAppDataFloor.protectedRoots(home: h)
        #expect(roots.contains(BypassPathNormalizer.strip(support + "/MinisCore").folded))
        #expect(roots.contains(BypassPathNormalizer.normalize(elsewhere).folded))
        #expect(Set(roots).count == roots.count)
    }

    @Test("~/.config/miniscanvas-test is a hard floor for file tools and shell, independent of the credential switch")
    func miniscanvasTestConfigIsHardFloor() async throws {
        let fake = try makeFakeHome()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: fake.root)
            try? FileManager.default.removeItem(at: project)
        }
        let h = fake.home
        let dir = h + "/.config/miniscanvas-test"
        for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
            #expect(BypassAppDataFloor.violation(path: dir, access: access, home: h) != nil)
            #expect(BypassAppDataFloor.violation(path: dir + "/key.json", access: access, home: h) != nil)
            #expect(BypassAppDataFloor.violation(path: h + "/.config/other-tool/x", access: access, home: h) == nil)
        }
        #expect(BypassAppDataFloor.violation(path: h + "/.config", access: .delete, home: h) != nil)
        #expect(BypassAppDataFloor.violation(path: h + "/.config", access: .modify, home: h) == nil)
        // shell：目标与字面提及都拦（这条链路不经过凭据开关）。
        for command in ["rm -rf ~/.config/miniscanvas-test", "echo x > \(dir)/key.json", "mv \(dir) /tmp/bypass-x"] {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        #expect(BypassAppDataFloor.shellMentionViolation(command: "cat ~/.config/miniscanvas-test/key.json") != nil)
        #expect(BypassAppDataFloor.shellMentionViolation(command: "cat $HOME/.config/miniscanvas-test/key.json") != nil)
        #expect(BypassAppDataFloor.shellMentionViolation(command: "ls ~/.config/other-tool") == nil)
        // 执行器：scope 内读写删都是 pathViolation（先于凭据检查，所以与开关无关）。
        let executor = BuiltinToolExecutor(allowedRoot: project)
        let trash = try RecordingTrash(in: project)
        let target = dir + "/key.json"
        for (name, input) in [("file_write", ["path": target, "content": "x"]), ("file_read", ["path": target]),
                              ("file_delete", ["path": target])] as [(String, [String: Any])] {
            let error = await capturedError {
                _ = try await BypassHomeSeam.$homeOverride.withValue(h) {
                    try await BypassOpenScope.$isActive.withValue(true) {
                        try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                            try await executor.execute(name: name, input: input)
                        }
                    }
                }
            }
            #expect((error as? ToolExecutorError) == .pathViolation(target), "\(name): \(String(describing: error))")
        }
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(trash.urls.isEmpty)
    }

    @Test("shell delete/move/modify targets with wildcards that may expand onto MinisCanvas dirs, Keychains or their parents are refused")
    func shellWildcardTargetsOverProtectedDirectories() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home
        let blocked = [
            "rm -rf ~/Library/*", "rm -rf ~/Library/Application\\ Support/Minis*", "mv ~/Library/Key* /tmp/bypass-x",
        ]
        for command in blocked {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        let allowed = [
            "rm ~/Library/Application\\ Support/OtherApp/*", "rm ~/Documents/*.txt", "ls ~/Library/*",
        ]
        for command in allowed {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) == nil, "should pass: \(command)")
        }
    }

    @Test("userDeniedExecutable folds case: RM, /BIN/RM and wrapped rm are refused when rm is denied")
    func userDeniedExecutableCaseFolding() async throws {
        let rmDenied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["ls", "echo"], confirmationCommands: [], userDeniedCommands: ["rm"]))
        for command in ["RM -rf x", "/BIN/RM x", "env nice -- RM x"] {
            #expect(rmDenied.userDeniedExecutable(in: command) != nil, "should be denied: \(command)")
        }
        for command in ["ls", "echo rm", "nohup ls"] {
            #expect(rmDenied.userDeniedExecutable(in: command) == nil, "should pass: \(command)")
        }
        // 用户把大写写进拒绝表同样折叠。
        let upperDenied = TerminalPolicySnapshot(settings: TerminalPolicySettings(
            automaticAllowCommands: ["ls"], confirmationCommands: [], userDeniedCommands: ["RM"]))
        #expect(upperDenied.userDeniedExecutable(in: "rm x") != nil)
        // 执行器：scope 内 RM 被拒绝（命令里的文件不存在，即使漏过也无害）。
        let project = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: project) }
        let executor = BuiltinToolExecutor(allowedRoot: project, terminalPolicySnapshot: rmDenied)
        for command in ["RM bypass-nonexistent-file", "/BIN/RM bypass-nonexistent-file", "nohup rm bypass-nonexistent-file"] {
            await #expect(throws: ToolExecutorError.shellRejected("command denied by terminal policy")) {
                _ = try await BypassOpenScope.$isActive.withValue(true) {
                    try await executor.execute(name: "shell_execute", input: ["command": command])
                }
            }
        }
    }

    // MARK: - Goal19 首单：deniedRoots 的 firmlink 折叠、大括号展开、缓存按 HOME 隔离、Unicode、段数不一致

    @Test("executor: a user-added denied root cannot be bypassed through the /System/Volumes/Data spelling in bypass; outside bypass nothing changes")
    func executorUserDeniedRootFirmlink() async throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home
        let fm = dataVolume
        // /var 是指向 /private/var 的根级符号链接；Data 卷上真实存在的 firmlink 写法是 /System/Volumes/Data/private/var/…，
        // 所以先取真实路径再拼前缀（直接拼在 /var/… 前会得到不存在的路径）。
        func fmOf(_ path: String) -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let real: String
            if realpath(path, &buffer) != nil {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                real = String(decoding: bytes, as: UTF8.self)
            } else {
                real = path
            }
            return fm + real
        }
        let deniedDir = h + "/Documents/private"
        let openDir = h + "/Documents/open"
        for dir in [deniedDir, openDir] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try "synthetic-secret".write(toFile: deniedDir + "/secret.txt", atomically: true, encoding: .utf8)
        try "open-ok".write(toFile: openDir + "/ok.txt", atomically: true, encoding: .utf8)
        let home = URL(fileURLWithPath: h, isDirectory: true)
        let trash = try RecordingTrash(in: fake.root)

        func run(_ executor: BuiltinToolExecutor, bypass: Bool, _ name: String, _ input: [String: Any]) async throws -> String {
            try await BypassHomeSeam.$homeOverride.withValue(h) {
                try await BypassOpenScope.$isActive.withValue(bypass) {
                    try await BypassTrashSeam.$mover.withValue({ try trash.move($0) }) {
                        try await executor.execute(name: name, input: input)
                    }
                }
            }
        }

        // deniedRoots 写普通形式，请求用 firmlink 形式。
        let plainDenied = BuiltinToolExecutor(
            allowedRoot: home, deniedRoots: [URL(fileURLWithPath: deniedDir, isDirectory: true)])
        for path in [deniedDir + "/secret.txt", fmOf(deniedDir) + "/secret.txt", fmOf(deniedDir) + "/new.txt"] {
            for (name, input) in [("file_read", ["path": path]), ("file_write", ["path": path, "content": "x"]),
                                  ("file_delete", ["path": path])] as [(String, [String: Any])] {
                let error = await capturedError { _ = try await run(plainDenied, bypass: true, name, input) }
                #expect((error as? ToolExecutorError) == .pathViolation(path), "bypass \(name) \(path): \(String(describing: error))")
            }
        }
        // deniedRoots 写 firmlink 形式，请求用普通形式与大写形式。
        let firmlinkDenied = BuiltinToolExecutor(
            allowedRoot: home, deniedRoots: [URL(fileURLWithPath: fmOf(deniedDir), isDirectory: true)])
        for path in [deniedDir + "/secret.txt", h + "/DOCUMENTS/PRIVATE/secret.txt"] {
            let error = await capturedError { _ = try await run(firmlinkDenied, bypass: true, "file_read", ["path": path]) }
            #expect((error as? ToolExecutorError) == .pathViolation(path), "firmlink deniedRoots \(path): \(String(describing: error))")
        }
        // 没被拒绝的兄弟目录：绕过下普通写法与 firmlink 写法都能读。
        for path in [openDir + "/ok.txt", fmOf(openDir) + "/ok.txt"] {
            let text = try await run(plainDenied, bypass: true, "file_read", ["path": path])
            #expect(text.contains("open-ok"), "\(path)")
        }
        #expect(FileManager.default.fileExists(atPath: deniedDir + "/secret.txt"))
        #expect(!FileManager.default.fileExists(atPath: deniedDir + "/new.txt"))
        #expect(trash.urls.isEmpty)

        // 非绕过：行为与 7428f83 一致——授权根内的拒绝目录照拒，兄弟目录可读，授权根外的 firmlink 写法照拒。
        let denied = await capturedError { _ = try await run(plainDenied, bypass: false, "file_read", ["path": deniedDir + "/secret.txt"]) }
        #expect((denied as? ToolExecutorError) == .pathViolation(deniedDir + "/secret.txt"))
        let sibling = try await run(plainDenied, bypass: false, "file_read", ["path": openDir + "/ok.txt"])
        #expect(sibling.contains("open-ok"))
        // 注：非绕过模式下 firmlink 写法（真实存在的路径）的结果取决于 7428f83 的 canonicalPath 行为，
        // 此处没有该基线的证据，故不断言；"非绕过不变"由结构保证——本次所有新逻辑都在 BypassOpenScope.isActive 守卫内
        // （ToolExecutor.resolveAllowedPath 中 strippedCandidate/deniedComparable 在非绕过时等于原值）。
    }

    @Test("brace expansion: nesting, multiplication, slash inside braces, literal braces, and the expansion cap")
    func braceExpansion() throws {
        let expand = BypassPathNormalizer.expandBraces
        #expect(expand("{a,{MinisCore,y}}", 64) == ["a", "MinisCore", "y"])
        #expect(expand("{a,b}{c,d}", 64) == ["ac", "ad", "bc", "bd"])
        #expect(expand("~/{Library/Application Support/MinisCore,x}", 64)
                == ["~/Library/Application Support/MinisCore", "~/x"])
        // 没有顶层逗号或没有配对的大括号按字面保留（bash 同样不展开）。
        #expect(expand("{a}", 64) == ["{a}"])
        #expect(expand("{a,b", 64) == ["{a,b"])
        #expect(expand("plain/path", 64) == ["plain/path"])
        // 上限：6 组 = 64 项刚好通过；7 组、30 组、超长输入返回 nil（调用方按拒绝处理）。
        func groups(_ count: Int) -> String { String(repeating: "{a,b}", count: count) }
        #expect(BypassPathNormalizer.expandBraces(groups(6))?.count == 64)
        #expect(BypassPathNormalizer.expandBraces(groups(7)) == nil)
        #expect(BypassPathNormalizer.expandBraces(String(repeating: "{", count: 5000)) == nil)
    }

    @Test("brace expansion scans Unicode scalars: a combining mark after { , } must not stop the expansion (bash expands by bytes)")
    func braceExpansionCombiningMarks() throws {
        let mark = "\u{301}"
        // 复核实测：Character 扫描时 `,\u{301}` 合成一个字素簇，原实现返回原串；按标量扫描必须展开。
        let a = BypassPathNormalizer.expandBraces("x{MinisCore,\(mark)}")
        #expect(a == ["xMinisCore", "x\(mark)"])
        let b = BypassPathNormalizer.expandBraces("~/Library/Application Support/{MinisCore,\(mark)}")
        #expect(b?.contains("~/Library/Application Support/MinisCore") == true)
        #expect(b?.count == 2)
        // 组合符紧跟 `{` 与 `}` 也一样（`{\u{301}` 里 `{` 不再是独立 Character）。
        #expect(BypassPathNormalizer.expandBraces("{\(mark)a,MinisCore}") == ["\(mark)a", "MinisCore"])
        #expect(BypassPathNormalizer.expandBraces("{a,MinisCore}\(mark)") == ["a\(mark)", "MinisCore\(mark)"])

        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home, support = fake.support
        // AppDataFloor 直接调用（globbing）与 shell 目标都要拒绝。
        for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
            #expect(BypassAppDataFloor.violation(path: support + "/{MinisCore,\(mark)}", access: access, home: h, globbing: true) != nil,
                    "access \(access)")
            #expect(BypassAppDataFloor.violation(path: support + "/{\(mark)a,MinisCore}", access: access, home: h, globbing: true) != nil,
                    "access \(access) (brace followed by a combining mark)")
        }
        let escaped = "~/Library/Application\\ Support"
        for command in ["rm -rf \(escaped)/{MinisCore,\(mark)}", "rm -rf \(escaped)/{\(mark)a,MinisCore}",
                        "mv \(escaped)/{MinisCore,\(mark)} /tmp/bypass-x"] {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        // 展开超限且首字符是 `{` 后跟组合符：也按拒绝处理（前缀判断按标量，不能被字素簇绕过）。
        let groups7 = String(repeating: "{a,b}", count: 7)
        let overflow = BypassSystemFloor.shellViolation(command: "rm -rf {\(mark)x,y}\(groups7)", home: h)
        #expect(overflow?.contains("大括号展开超过") == true)
        // 普通路径不受影响。
        #expect(BypassSystemFloor.shellViolation(command: "rm ~/Documents/{a,\(mark)}.txt", home: h) == nil)
    }

    @Test("brace expansion recursion depth is capped at 32 (deeper = nil), so a hostile nest cannot overflow the stack")
    func braceExpansionDepthCap() throws {
        func nest(_ n: Int) -> String { String(repeating: "{a,", count: n) + "b" + String(repeating: "}", count: n) }
        // 32 层嵌套仍展开（33 项 <= 64，说明 33 层返回 nil 是深度上限而不是数量上限）。
        #expect(BypassPathNormalizer.expandBraces(nest(32))?.count == 33)
        #expect(BypassPathNormalizer.expandBraces(nest(33)) == nil)
        #expect(BypassPathNormalizer.expandBraces(nest(100)) == nil)
        // `{,` 重复 100 次再接 100 个 `}`（配对嵌套）：返回 nil、不崩溃。
        #expect(BypassPathNormalizer.expandBraces(String(repeating: "{,", count: 100) + String(repeating: "}", count: 100)) == nil)
        // `{,` 重复 100 次只接一个 `}`：只有最里面一组配对，其余 `{` 按字面保留（bash 同样如此）；不崩溃，展开 2 项。
        let single = BypassPathNormalizer.expandBraces(String(repeating: "{,", count: 100) + "}")
        #expect(single?.count == 2)
        // shell 入口：深嵌套的绝对路径目标按拒绝处理。
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let reason = BypassSystemFloor.shellViolation(command: "rm -rf /tmp/bypass-x\(nest(40))", home: fake.home)
        #expect(reason?.contains("大括号展开超过") == true)
    }

    @Test("shell targets with nested braces, slash-containing braces and exploding braces are refused; ordinary braces pass")
    func shellBraceTargets() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home
        let escapedSupport = "~/Library/Application\\ Support"
        let blocked = [
            "rm -rf \(escapedSupport)/{a,{MinisCore,y}}",
            "mv ~/{x,Library/Keychains} /tmp/bypass-x",
            "rm -rf /{usr,tmp}/bypass-x",
        ]
        for command in blocked {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) != nil, "should be blocked: \(command)")
        }
        // 膨胀：绝对路径上重复 30 次、7 次（128 项）都按「拒绝」处理，并说明是展开超限。
        let groups30 = String(repeating: "{a,b}", count: 30)
        let groups7 = String(repeating: "{a,b}", count: 7)
        for command in ["rm -rf /tmp/bypass-x\(groups7)",
                        "rm -rf ~/bypass-x\(groups7)", "rm -rf {~/a,b}\(groups7)"] {
            let reason = BypassSystemFloor.shellViolation(command: command, home: h)
            #expect(reason?.contains("大括号展开超过") == true, "should be refused as overflow: \(command.prefix(40))")
        }
        // 直接调用 AppDataFloor（globbing）也一样。
        #expect(BypassAppDataFloor.violation(path: h + "/{Library/Application Support/MinisCore,x}", access: .modify, home: h, globbing: true) != nil)
        #expect(BypassAppDataFloor.violation(path: h + "/x" + groups30, access: .modify, home: h, globbing: true)?.contains("大括号展开超过") == true)
        #expect(BypassAppDataFloor.violation(path: h + "/{a,{b,{Library/Keychains,c}}}", access: .delete, home: h, globbing: true) != nil)

        let allowed = [
            "rm -rf /tmp/bypass-x/{a,b}/{c,d}", "touch \(escapedSupport)/OtherApp/{a,b}.txt",
            // 相对路径即使展开超限也与旧行为一致（不判断），不能被误拒。
            "touch relative\(groups30)",
        ]
        for command in allowed {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) == nil, "should pass: \(command.prefix(60))")
        }
    }

    @Test("protected-root cache is keyed by HOME: two different HOMEs never share results, in either call order")
    func appDataFloorCacheIsPerHome() throws {
        let a = try makeFakeHome()
        let b = try makeFakeHome()
        defer {
            try? FileManager.default.removeItem(at: a.root)
            try? FileManager.default.removeItem(at: b.root)
        }
        let foldedA = BypassPathNormalizer.normalize(a.home).folded
        let foldedB = BypassPathNormalizer.normalize(b.home).folded
        #expect(foldedA != foldedB)
        for _ in 0..<2 {
            #expect(BypassAppDataFloor.violation(path: a.support + "/MinisCore/x.json", access: .modify, home: a.home) != nil)
            // 在 B 的 HOME 下，A 的 MinisCore 不是受保护目录（反之亦然），不能拿到 A 缓存的结果。
            #expect(BypassAppDataFloor.violation(path: a.support + "/MinisCore/x.json", access: .modify, home: b.home) == nil)
            #expect(BypassAppDataFloor.violation(path: b.support + "/MinisCore/x.json", access: .modify, home: b.home) != nil)
            #expect(BypassAppDataFloor.violation(path: b.support + "/MinisCore/x.json", access: .modify, home: a.home) == nil)
            let rootsA = BypassAppDataFloor.protectedRoots(home: a.home)
            let rootsB = BypassAppDataFloor.protectedRoots(home: b.home)
            #expect(rootsA.contains(foldedA + "/library/application support/miniscore"))
            #expect(rootsB.contains(foldedB + "/library/application support/miniscore"))
            #expect(!rootsA.contains { $0.hasPrefix(foldedB + "/") })
            #expect(!rootsB.contains { $0.hasPrefix(foldedA + "/") })
        }
        // 家目录归一缓存同样按 HOME 区分。
        #expect(BypassPathNormalizer.normalizeHome(a.home).folded == foldedA)
        #expect(BypassPathNormalizer.normalizeHome(b.home).folded == foldedB)
        #expect(BypassPathNormalizer.normalizeHome(a.home).folded == foldedA)
    }

    @Test("Unicode file names (CJK, emoji, decomposed accents) are not refused by the floors; the protected names still are")
    func unicodeFileNamesAreNotFalselyRefused() async throws {
        let fake = try makeFakeHome()
        let project = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: fake.root)
            try? FileManager.default.removeItem(at: project)
        }
        let h = fake.home, support = fake.support
        let names = ["中文文件.txt", "报告😀.md", "日本語/📁/メモ.txt", "cafe\u{0301}.txt", "Ünï/𝒳.txt"]
        for name in names {
            for operation in [BypassSystemFloor.Operation.modify, .delete] {
                #expect(BypassSystemFloor.violation(path: h + "/Documents/" + name, operation: operation, home: h) == nil, "\(name)")
                #expect(BypassSystemFloor.violation(path: "/Applications/" + name, operation: operation, home: h) == nil, "\(name)")
            }
            for access in [BypassAppDataFloor.Access.read, .modify, .delete] {
                #expect(BypassAppDataFloor.violation(path: support + "/OtherApp/" + name, access: access, home: h) == nil, "\(name)")
            }
            #expect(!SensitiveFilePolicy.isCredentialPath(h + "/Documents/" + name, home: h), "\(name)")
        }
        for command in ["touch \"\(support)/OtherApp/中文😀.txt\"", "rm \(h)/Documents/文档{一,二}.txt",
                        "echo x > '\(h)/Documents/报告😀.md'", "mv \(h)/Documents/a.txt \(h)/Documents/日本語😀.txt"] {
            #expect(BypassSystemFloor.shellViolation(command: command, home: h) == nil, "should pass: \(command)")
        }
        // 受保护目录的中文/emoji 子路径仍然拒绝（目录名本身才是判断依据）。
        #expect(BypassAppDataFloor.violation(path: support + "/MinisCore/中文😀.json", access: .modify, home: h) != nil)
        // 执行器：项目根内写入、再在 scope 内读回 Unicode 文件名。
        let executor = BuiltinToolExecutor(allowedRoot: project)
        let target = project.path + "/文档😀.txt"
        _ = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "file_write", input: ["path": target, "content": "unicode-ok"])
        }
        let read = try await BypassOpenScope.$isActive.withValue(true) {
            try await executor.execute(name: "file_read", input: ["path": target])
        }
        #expect(read.contains("unicode-ok"))
    }

    @Test("a path whose folded form has a different segment count (full-width slash U+FF0F) is refused conservatively under Applications")
    func foldedSegmentCountMismatchIsRefused() throws {
        let fake = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let h = fake.home
        let fullwidthSlash = "\u{FF0F}"
        for path in ["/Applications/Foo\(fullwidthSlash)Bar.app/Contents/x", "/Applications/Foo\(fullwidthSlash)Bar.txt",
                     h + "/Applications/Foo\(fullwidthSlash)Bar.app"] {
            for operation in [BypassSystemFloor.Operation.modify, .delete] {
                let reason = BypassSystemFloor.violation(path: path, operation: operation, home: h)
                #expect(reason?.contains("段数") == true, "\(path) \(operation): \(String(describing: reason))")
            }
        }
        // 不在应用目录下的同类文件名、以及普通应用目录路径不受影响。
        #expect(BypassSystemFloor.violation(path: h + "/Documents/a\(fullwidthSlash)b.txt", operation: .modify, home: h) == nil)
        #expect(BypassSystemFloor.violation(path: "/Applications/Plain.txt", operation: .modify, home: h) == nil)
    }
}
