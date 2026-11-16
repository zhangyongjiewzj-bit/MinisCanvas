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
        let granted: Set<String> = ["file_read", "file_write", "file_edit", "file_delete", "shell_execute", "browser_use"]
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
        #expect(try await first.authorize(capability: "shell_execute", input: shell("git status")) == ask)
        let saved = await first.persistAllowRule(capability: "shell_execute", input: try shell("git status"))
        #expect(saved?.pattern == "git status")

        // New store object, new grant store, new session/task/epoch/lease.
        let rebuilt = controller(
            rules: makeStore(file), roots: roots,
            session: "session-2", task: "task-2", epoch: "epoch-9", lease: "lease-9")
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("git status -s")) == .execute)
        #expect(try await rebuilt.authorize(capability: "shell_execute", input: shell("git log")) == ask)
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

        _ = await inA.persistAllowRule(capability: "shell_execute", input: try shell("git status"))
        _ = await inA.persistAllowRule(capability: "file_write", input: try filePath(a.appendingPathComponent("x.txt").path))
        #expect(try await inA.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
        #expect(try await inA.authorize(capability: "file_write", input: filePath(a.appendingPathComponent("y.txt").path)) == .execute)
        #expect(try await inB.authorize(capability: "shell_execute", input: shell("git status")) == ask)
        #expect(try await inB.authorize(capability: "file_write", input: filePath(b.appendingPathComponent("y.txt").path)) == ask)
        // file_edit was not granted in project A.
        #expect(try await inA.authorize(capability: "file_edit", input: filePath(a.appendingPathComponent("y.txt").path)) == ask)
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

        let risky = [
            "git status; rm -rf x", "git status | cat", "echo $(whoami)",
            "git status > out.txt", "git status < in.txt", "git status $HOME",
            "git status `pwd`", "git status & ",
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

        for command in ["git", "python3 build.py", "rm -rf x", "/usr/bin/git status", "git push origin main", "sudo ls"] {
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
        #expect(await inert.persistentAllowOffer(capability: "shell_execute", input: try shell("git status")) == nil)
        #expect(await inert.persistAllowRule(capability: "shell_execute", input: try shell("git status")) == nil)
        #expect(try await inert.authorize(capability: "shell_execute", input: shell("git status")) == ask)

        let store = makeStore(dir.appendingPathComponent("rules.json"))
        _ = await controller(rules: store, roots: roots).persistAllowRule(capability: "shell_execute", input: try shell("git status"))
        #expect(try await controller(rules: store, roots: roots, mode: .plan)
            .authorize(capability: "shell_execute", input: shell("git status")) == .dryRun)
        #expect(try await controller(rules: store, roots: roots, mode: .bypassPermission)
            .authorize(capability: "shell_execute", input: shell("swift build")) == .execute)
        #expect(store.allRules().count == 1)
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
            #expect(try await c.authorize(capability: "shell_execute", input: shell("git status")) == ask)
            // The store stays usable and writes a valid file afterwards.
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell("git status")) != nil)
            #expect(makeStore(file).allRules().count == 1)
            #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
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
        #expect(try await executor.execute(callID: "call-1", name: "shell_execute", input: shell("git status")) == "executed")
        #expect(recorder.seenRequests.count == 1)
        #expect(recorder.seenRequests.first?.persistentAllowOffer?.isAvailable == true)
        #expect(recorder.seenRequests.first?.persistentAllowOffer?.summary == "git status")
        let rule = try #require(makeStore(file).allRules().first)
        #expect(recorder.seenReceipts.first?.persistentRuleID == nil)

        // Second call hits the rule: no new prompt, one more execution, a fresh receipt.
        #expect(try await executor.execute(callID: "call-2", name: "shell_execute", input: shell("git status -s")) == "executed")
        #expect(recorder.seenRequests.count == 1)
        #expect(probe.executions == 2)
        let receipt = try #require(recorder.seenReceipts.last)
        #expect(recorder.seenReceipts.count == 2)
        #expect(receipt.callID == "call-2")
        #expect(receipt.persistentRuleID == rule.id)
        #expect(receipt.inputDigest == (try shell("git status -s")).digest)
        #expect(receipt.identityDigest != recorder.seenReceipts.first?.identityDigest)

        // A different command in the same project still prompts.
        _ = try await executor.execute(callID: "call-3", name: "shell_execute", input: shell("swift build"))
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
        _ = try await eager.execute(callID: "call-2", name: "shell_execute", input: shell("git status; ls"))
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
            ("git status", "git status"), ("git status -s", "git status"), ("git diff HEAD~1", "git diff"),
            ("git log --oneline -5", "git log"), ("git show HEAD", "git show"),
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

        // Not on the allowlist: unavailable with the fixed reason.
        let unsupported = [
            "git reset --hard", "git checkout main", "git restore x", "git clean -fd", "git push",
            "git fetch", "git pull", "git config user.name x", "git commit -m x", "git stash",
            "npm publish", "npm install", "npm ci", "npm exec foo", "yarn add left-pad", "pnpm install",
            "pnpm run build", "yarn run build", "make build", "make", "mkdir foo", "touch x", "cat README.md",
            "echo hi", "xcodebuild -list", "git -c core.pager=evil status", "swift package update",
        ]
        for command in unsupported {
            let offer = await c.persistentAllowOffer(capability: "shell_execute", input: try shell(command))
            #expect(offer?.isAvailable == false, "offer for \(command)")
            #expect(offer?.unavailableReason == PersistentApprovalRuleMatcher.unsupportedCommandReason,
                    "reason for \(command): \(offer?.unavailableReason ?? "nil")")
        }
    }

    @Test("allowlisted prefixes with dangerous arguments are not remembered and never match")
    func dangerousArgumentsAreNotRemembered() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = controller(
            rules: makeStore(dir.appendingPathComponent("rules.json")),
            roots: [dir.appendingPathComponent("project").path])
        for command in ["git status", "git diff", "git branch", "ls", "make test", "npm run build", "pwd"] {
            #expect(await c.persistAllowRule(capability: "shell_execute", input: try shell(command)) != nil)
        }
        #expect(try await c.authorize(capability: "shell_execute", input: shell("git status")) == .execute)
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
            #expect(try await c.authorize(capability: "shell_execute", input: input) == ask)
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
            ".npmrc", ".yarnrc", ".yarnrc.yml", ".pnpmfile.cjs", "Package.swift", "Package.resolved",
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
        // Shell rules are unaffected by the file-root exclusion.
        let shellOnly = controller(rules: makeStore(separate, home: root.path), roots: [root.path])
        #expect(await shellOnly.persistAllowRule(capability: "shell_execute", input: try shell("git status")) != nil)
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
        _ = try await asking.execute(callID: "call-1", name: "shell_execute", input: shell("git status"))
        #expect(recorder.seenRequests.count == 1)
        _ = try await asking.execute(callID: "call-2", name: "shell_execute", input: shell("git status"))
        #expect(recorder.seenRequests.count == 1)
        #expect(probe.executions == 2)
        #expect(recorder.seenReceipts.last?.persistentRuleID != nil)

        // deny: the stored rule cannot override the user's policy.
        let denying = ComposerPolicyEnforcedToolExecutor(
            base: probe, controller: controller(rules: makeStore(file), roots: roots),
            approvalGate: ApprovalGate(policy: .deny, delegate: PersistingDelegate(recorder: recorder, persist: false)))
        await #expect(throws: (any Error).self) {
            _ = try await denying.execute(callID: "call-3", name: "shell_execute", input: shell("git status"))
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
        _ = try await executor.execute(callID: "call-1", name: "shell_execute", input: shell("git status"))
        _ = try await executor.execute(callID: "call-2", name: "shell_execute", input: shell("git status"))

        let prompted = try #require(recorder.seenReceipts.first)
        let hit = try #require(recorder.seenReceipts.last)
        #expect(hit.persistentRuleID != nil && prompted.persistentRuleID == nil)
        let expected = ApprovalRiskLevel.max(
            gate.riskLevel(for: "shell_execute"),
            ApprovalGate.inputRiskLevel(tool: "shell_execute", input: ["command": "git status"]))
        #expect(prompted.riskLevel == expected)
        #expect(hit.riskLevel == expected)
        #expect(hit.riskLevel == .high)
    }
}
