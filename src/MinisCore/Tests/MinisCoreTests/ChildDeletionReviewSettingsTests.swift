import Foundation
import Testing
@testable import MinisCore

@Suite("Goal18 CHILD-DELETE-AUTO user settings -> reviewer configuration")
struct ChildDeletionReviewSettingsTests {
    // MARK: defaults and persistence compatibility

    @Test func emptyAndLegacyJSONDecodeAsOffAndEmptyWithoutLosingOtherFields() throws {
        let empty = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(!empty.childDeletionAutoReviewEnabled)
        #expect(empty.childDeletionAutoReviewWhitelist.isEmpty)

        let original = AgentSettings(maxLoopIterations: 7, toolTimeoutSeconds: 37, fallbackEnabled: false,
            childMutationsEnabled: true, childDeletionAutoReviewEnabled: true,
            childDeletionAutoReviewWhitelist: ["/usr/local/goal18-fixture"])
        let encoded = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AgentSettings.self, from: encoded) == original)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "childDeletionAutoReviewEnabled")
        legacy.removeValue(forKey: "childDeletionAutoReviewWhitelist")
        let decoded = try JSONDecoder().decode(AgentSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        var expected = original
        expected.childDeletionAutoReviewEnabled = false
        expected.childDeletionAutoReviewWhitelist = []
        #expect(decoded == expected)
        #expect(decoded.childMutationsEnabled)
        #expect(decoded.maxLoopIterations == 7)
    }

    @Test func persistedWhitelistIsNormalizedAtEveryBoundary() throws {
        let messy = ["/usr/local/a/../goal18-b", "relative/path", "", "/", "/usr/local/goal18-b/",
                     "/usr/local/goal18-b", "/usr/local/goal18-\u{0007}bell", "~/home-relative"]
        let constructed = AgentSettings(childDeletionAutoReviewWhitelist: messy)
        #expect(constructed.childDeletionAutoReviewWhitelist == ["/usr/local/goal18-b"])

        let json = try JSONSerialization.data(withJSONObject: [
            "childDeletionAutoReviewEnabled": true,
            "childDeletionAutoReviewWhitelist": messy
        ])
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: json)
        #expect(decoded.childDeletionAutoReviewWhitelist == ["/usr/local/goal18-b"])

        // A keyPath write that bypasses init is still normalized on encode.
        var polluted = AgentSettings.default
        polluted.childDeletionAutoReviewWhitelist = messy
        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(polluted)) as? [String: Any])
        #expect(object["childDeletionAutoReviewWhitelist"] as? [String] == ["/usr/local/goal18-b"])
    }

    @Test func whitelistIsCapped() {
        let many = (0..<(ChildDeletionReviewSettings.maxWhitelistDirectories + 5)).map { "/usr/local/goal18-\($0)" }
        #expect(ChildDeletionReviewSettings.normalizedWhitelist(many).count
            == ChildDeletionReviewSettings.maxWhitelistDirectories)
    }

    // MARK: configuration derivation

    @Test func enabledSettingsYieldCanonicalRealDirectoriesTheReviewerAccepts() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-delete-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)

        // Add-time canonicalization resolves a symlink to the real directory.
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(link))
        #expect(canonical == ChildDeletionReviewSettings.canonicalDirectory(files))
        #expect(canonical == files.resolvingSymlinksInPath().standardizedFileURL.path)

        let agent = AgentSettings(childDeletionAutoReviewEnabled: true,
            childDeletionAutoReviewWhitelist: [canonical])
        let configuration = ChildDeletionReviewSettings.configuration(from: agent)
        #expect(configuration.enabled)
        #expect(configuration.whitelistDirectories.map(\.path) == [canonical])
        // The reviewer only accepts a root that is already its own real path.
        for url in configuration.whitelistDirectories {
            let root = url.standardizedFileURL
            #expect(root.isFileURL && root == root.resolvingSymlinksInPath())
        }
    }

    @Test func staleOrReplacedDirectoriesAreDroppedSoTheHumanUIDecides() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-delete-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept")
        let moved = root.appendingPathComponent("moved")
        let plainFile = root.appendingPathComponent("file.txt")
        let target = root.appendingPathComponent("target")
        for directory in [kept, moved, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data("x".utf8).write(to: plainFile)
        let keptPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(kept))
        let movedPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(moved))
        let filePath = ChildDeletionReviewSettings.normalizedWhitelist([plainFile.path])
        #expect(ChildDeletionReviewSettings.canonicalDirectory(plainFile) == nil)
        #expect(ChildDeletionReviewSettings.canonicalDirectory(root.appendingPathComponent("absent")) == nil)
        #expect(ChildDeletionReviewSettings.canonicalDirectory(path: "relative") == nil)
        #expect(ChildDeletionReviewSettings.canonicalDirectory(path: "/") == nil)

        // `moved` is replaced by a symlink to another directory after being saved.
        try FileManager.default.removeItem(at: moved)
        try FileManager.default.createSymbolicLink(at: moved, withDestinationURL: target)
        let agent = AgentSettings(childDeletionAutoReviewEnabled: true,
            childDeletionAutoReviewWhitelist: [keptPath, movedPath] + filePath)
        let configuration = ChildDeletionReviewSettings.configuration(from: agent)
        #expect(configuration.enabled)
        #expect(configuration.whitelistDirectories.map(\.path) == [keptPath])
    }

    // MARK: broad / protected directories (injected HOME, temporary directories only)

    private func makeFakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-fake-home-" + UUID().uuidString, isDirectory: true)
        for sub in ["Library/Application Support/MinisCanvas/sessions", "Library/Application Support/MinisCore",
                    "Library/Application Support/Other", "projects/app"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        return home
    }

    @Test func homeItsAncestorsSystemRootsAndOwnDataDirectoriesAreTooBroad() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let homePath = home.path
        func reason(_ path: String) -> String? {
            ChildDeletionReviewSettings.broadDirectoryReason(path, home: homePath)
        }
        // home itself and every ancestor, including "/" and the temp parents
        #expect(reason(homePath) != nil)
        #expect(reason(home.deletingLastPathComponent().path) != nil)
        #expect(reason("/") != nil)
        // fixed system roots, both /private spellings, case-insensitive
        for system in ["/Volumes", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc",
                       "/var", "/private", "/opt", "/tmp", "/private/var", "/private/etc", "/private/tmp",
                       "/APPLICATIONS", "/Private/Var"] {
            #expect(reason(system) != nil, "\(system) should be too broad")
        }
        // ~/Library, Application Support and MinisCanvas/MinisCore data (and children)
        #expect(reason(homePath + "/Library") != nil)
        #expect(reason(homePath + "/library/application support") != nil)
        #expect(reason(homePath + "/Library/Application Support/MinisCanvas") != nil)
        #expect(reason(homePath + "/Library/Application Support/MinisCanvas/sessions") != nil)
        #expect(reason(homePath + "/library/application support/miniscore") != nil)
        // specific project directories stay acceptable, so does the temp dir itself
        #expect(reason(homePath + "/projects/app") == nil)
        #expect(reason(homePath + "/Library/Application Support/Other") != nil)
        // The fake HOME lives inside the temporary directory, so the temp dir itself is a HOME ancestor
        // here; a sibling project folder under it (not an ancestor of HOME) must stay acceptable.
        #expect(reason(FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-sibling-project", isDirectory: true).path) == nil)
        #expect(reason("/Volumes/External/work") == nil)
        #expect(reason("/Volumes/External") != nil)
    }

    @Test func systemAndUserLibrarySubtreesAreRefusedButCarveOutsStayUsable() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let homePath = home.path
        func reason(_ path: String) -> String? {
            ChildDeletionReviewSettings.broadDirectoryReason(path, home: homePath)
        }
        for denied in ["/Library/LaunchDaemons", "/System/Applications", "/Applications/Foo.app",
                       "/usr/bin", "/bin/x", "/sbin/x", "/etc/ssh", "/private/etc/ssh", "/OPT/x",
                       "/Volumes/External", "/library/launchdaemons",
                       homePath + "/Library/Caches/x", homePath + "/Library/LaunchAgents"] {
            #expect(reason(denied) != nil, "\(denied) should be refused")
        }
        // /var, /private, /tmp: only the directory itself.
        for exact in ["/var", "/private", "/tmp", "/private/var", "/private/tmp"] {
            #expect(reason(exact) != nil)
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-sub-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(reason(temp.path) == nil)
        #expect(reason("/private/tmp/x") == nil)
        #expect(reason("/usr/local/x") == nil)
        #expect(reason("/usr/local") == nil)
        #expect(reason(homePath + "/Projects/x") == nil)
        #expect(reason(homePath + "/projects/app") == nil)
        // add-time check goes through the same rule
        guard case .tooBroad = ChildDeletionReviewSettings.checkedDirectory(
            home.appendingPathComponent("Library/Application Support/Other"), home: homePath) else {
            Issue.record("~/Library subtree must be refused"); return
        }
    }

    @Test func addTimeCheckRefusesBroadDirectoriesAndKeepsNormalOnes() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("projects/app", isDirectory: true)
        let projectPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(project))
        #expect(ChildDeletionReviewSettings.checkedDirectory(project, home: home.path) == .accepted(projectPath))
        guard case .tooBroad = ChildDeletionReviewSettings.checkedDirectory(home, home: home.path) else {
            Issue.record("home must be refused"); return
        }
        guard case .tooBroad = ChildDeletionReviewSettings.checkedDirectory(
            home.appendingPathComponent("Library/Application Support/MinisCore"), home: home.path) else {
            Issue.record("own data directory must be refused"); return
        }
        #expect(ChildDeletionReviewSettings.checkedDirectory(
            home.appendingPathComponent("missing"), home: home.path) == .notADirectory)
    }

    @Test func useTimeDropsBroadEntriesReportsAReasonAndMarksThemStale() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(
            home.appendingPathComponent("projects/app", isDirectory: true)))
        let homePath = try #require(ChildDeletionReviewSettings.canonicalDirectory(home))
        let dataPath = try #require(ChildDeletionReviewSettings.canonicalDirectory(
            home.appendingPathComponent("Library/Application Support/MinisCanvas/sessions", isDirectory: true)))
        // A stored (e.g. restored or hand-edited) list may contain broad entries.
        let agent = AgentSettings(childDeletionAutoReviewEnabled: true,
            childDeletionAutoReviewWhitelist: [homePath, projectPath, dataPath])
        #expect(agent.childDeletionAutoReviewWhitelist == [homePath, projectPath, dataPath])

        var reasons: [String] = []
        let configuration = ChildDeletionReviewSettings.configuration(
            from: agent, home: home.path, onDropped: { reasons.append($0) })
        #expect(configuration.enabled)
        #expect(configuration.whitelistDirectories.map(\.path) == [projectPath])
        #expect(reasons.count == 2)
        guard case .stale(let homeReason) = ChildDeletionReviewSettings.entryStatus(homePath, home: home.path) else {
            Issue.record("home entry must be stale"); return
        }
        #expect(!homeReason.isEmpty)
        #expect(ChildDeletionReviewSettings.entryStatus(projectPath, home: home.path) == .usable(projectPath))
        guard case .stale = ChildDeletionReviewSettings.entryStatus(
            projectPath + "/nope", home: home.path) else {
            Issue.record("missing entry must be stale"); return
        }
    }

    // MARK: reviewer behaviour with settings-derived configuration

    @Test func disabledSettingsKeepChildDeletionOnTheManualApprovalPath() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-delete-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("owned synthetic file".utf8).write(to: file)

        let model = SettingsDeletionClassifierProbe()
        let manual = SettingsManualDeletionDelegate()
        var disabledSettings = AgentSettings.default
        disabledSettings.childDeletionAutoReviewWhitelist = [
            try #require(ChildDeletionReviewSettings.canonicalDirectory(root))
        ]
        let configuration = ChildDeletionReviewSettings.configuration(from: disabledSettings)
        #expect(!configuration.enabled)
        #expect(configuration.whitelistDirectories.isEmpty)
        let reviewer = ChildDeletionReviewer(configuration: configuration, classifier: model)
        let review = await reviewer.review(request: settingsDeletionRequest(for: file),
            checkpointStore: nil, checkpointID: nil)
        #expect(!review.recommendsRecoverableDeletion)
        #expect(review.record.reason == .disabled)

        let delegate = ChildDeletionApprovalDelegate(manualDelegate: manual, reviewer: reviewer)
        #expect(!delegate.requiresDeletionPreparation)
        #expect(!delegate.reviewConfiguration.enabled)
        let decision = await delegate.requestApproval(settingsDeletionRequest(for: file))
        #expect(!decision.approved)
        #expect(await manual.callCount == 1)
        #expect(await model.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func enabledWhitelistedSettingsLetTheReviewerRecommendOnlyInsideTheWhitelist() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("goal18-delete-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let inside = files.appendingPathComponent("note.txt")
        let outside = elsewhere.appendingPathComponent("note.txt")
        try Data("inside".utf8).write(to: inside)
        try Data("outside".utf8).write(to: outside)

        let store = try FileCheckpointStore(directory: root.appendingPathComponent("checkpoints"),
            allowedRoots: [files, elsewhere])
        let canonical = try #require(ChildDeletionReviewSettings.canonicalDirectory(files))
        let configuration = ChildDeletionReviewSettings.configuration(from: AgentSettings(
            childDeletionAutoReviewEnabled: true, childDeletionAutoReviewWhitelist: [canonical]))
        let model = SettingsDeletionClassifierProbe()
        let reviewer = ChildDeletionReviewer(configuration: configuration, classifier: model,
            recordSink: { _ in })

        let outsideID = try store.begin(path: outside, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let blocked = await reviewer.review(request: settingsDeletionRequest(for: outside),
            checkpointStore: store, checkpointID: outsideID)
        #expect(!blocked.recommendsRecoverableDeletion)
        #expect(blocked.record.reason == .outsideWhitelist)
        #expect(await model.callCount == 0)

        let insideID = try store.begin(path: inside, sessionID: "child-session", operation: .delete, expectedAfter: nil)
        let allowed = await reviewer.review(request: settingsDeletionRequest(for: inside),
            checkpointStore: store, checkpointID: insideID)
        #expect(allowed.recommendsRecoverableDeletion)
        #expect(allowed.record.reason == .independentRecommendation)
        #expect(await model.callCount == 1)
        // The reviewer only recommends; it never deletes.
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

private func settingsDeletionRequest(for file: URL) -> ApprovalRequest {
    let input: [String: Any] = ["path": file.path]
    let context = ApprovalAuthorizationContext(actorID: "child:child-session", sessionID: "child-session", turnID: 1,
        taskID: "child-task", runID: "child-run", attemptID: "child-attempt", effectID: UUID().uuidString,
        scope: "parent-scope", payloadDigest: ApprovalAuthorizationContext.payloadDigest(for: input)!,
        expiresAt: Date().addingTimeInterval(60), policyRevision: "current-parent-policy", grantEpoch: "generation",
        toolName: "file_delete")
    var request = ApprovalGate().makeBoundRequest(tool: "file_delete", input: input, context: context)
    request.source = .childTask(taskID: "child-task", parentID: "parent-task")
    return request
}

private actor SettingsDeletionClassifierProbe: IndependentDeletionClassifying {
    private(set) var callCount = 0
    func classify(_ input: ChildDeletionClassifierInput) async throws -> ChildDeletionModelVerdict {
        callCount += 1
        return .allowRecoverableDeletion
    }
}

private actor SettingsManualDeletionDelegate: ApprovalDelegate {
    private(set) var callCount = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        callCount += 1
        return ApprovalDecision(approved: false, reason: "synthetic human refused",
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
