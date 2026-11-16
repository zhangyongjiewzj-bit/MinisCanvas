import Foundation
import Testing
@testable import MinisCore

struct SkillLifecycleTests {
    private enum BL6SyntheticFault: Error { case interrupted }

    @Test func trustedGlobalSkillApprovalCanEnterProjectWithoutWideningOtherReceipts() {
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let sibling = MemoryScope(sessionID: "other-session", projectID: scope.projectID)
        let now = Date(timeIntervalSince1970: 10_000)
        let hash = "synthetic-content-hash"

        func receipt(_ approver: String, scope: MemoryScope? = nil, expiry: Date? = nil,
                     trust: SkillTrust = .local) -> SkillLifecycleReceipt {
            SkillLifecycleReceipt(skillID: "owned-skill", contentHash: hash, trust: trust,
                action: .activate, state: .active, reason: "synthetic activation",
                approvedBy: approver, scope: scope, expiresAt: expiry)
        }

        for approver in ["settings-explicit-review:local-uid-501", "explicit-user-import"] {
            let global = receipt(approver)
            #expect(SkillLifecycle.isActivationValid(global, currentContentHash: hash, scope: scope, now: now))
            #expect(!SkillLifecycle.isActivationValid(global, currentContentHash: "different", scope: scope, now: now))
            #expect(!SkillLifecycle.isActivationValid(receipt(approver, expiry: now),
                currentContentHash: hash, scope: scope, now: now))
            #expect(!SkillLifecycle.isActivationValid(receipt(approver, trust: .untrusted),
                currentContentHash: hash, scope: scope, now: now))
        }
        for approver in ["composer-explicit-review:synthetic", "composer-confirmed-bypass:synthetic",
                         "composer-risk-confirmed-rule:synthetic:call:synthetic", "legacy-explicit-boundary"] {
            let original = receipt(approver)
            #expect(SkillLifecycle.isActivationValid(original, currentContentHash: hash, now: now))
            #expect(!SkillLifecycle.isActivationValid(original, currentContentHash: hash, scope: scope, now: now))
        }
        let scoped = receipt("settings-explicit-review:local-uid-501", scope: scope)
        #expect(SkillLifecycle.isActivationValid(scoped, currentContentHash: hash, scope: scope, now: now))
        #expect(!SkillLifecycle.isActivationValid(scoped, currentContentHash: hash, scope: sibling, now: now))
    }

    private static func bl6SkillRecord(
        requestID: String, profileID: String, scope: MemoryScope,
        skillID: String, enabled: Bool, previousEnabled: Bool,
        operation: BL6SettingsOperation = .apply, undoReceiptID: String? = nil,
        previousRevision: String, effectiveRevision: String
    ) -> BL6SettingsReplayRecord {
        let key = "skills.app:\(skillID).enabled"
        let input = BL6SettingsApprovedInput(
            operation: operation,
            changes: operation == .apply ? [key: .toggle(enabled)] : [:],
            expectedRevision: previousRevision,
            undoReceiptID: undoReceiptID
        )
        let receipt = BL6SettingsReceipt(
            requestID: requestID, operation: operation,
            previousRevision: previousRevision, effectiveRevision: effectiveRevision,
            changedKeys: [key], rollbackValues: [:]
        )
        return BL6SettingsReplayRecord(
            requestID: requestID, payloadDigest: "synthetic-bound-input",
            frozenInput: input, approvalBindingDigest: "synthetic-approved-binding",
            profileID: profileID, scope: "session", sessionID: scope.sessionID,
            policyRevision: "synthetic-policy", grantEpoch: "synthetic-epoch",
            approvalExpiresAt: Date().addingTimeInterval(600),
            operation: operation, receipt: receipt,
            rollbackValues: [key: .toggle(previousEnabled)]
        )
    }

    @Test func bl6EnablementIntentAndTerminalReopenAtBothFaultBoundaries() throws {
        let fixtureRoot = FormalTestIsolationPaths.currentOrFail()?.temporaryDirectory
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let parent = fixtureRoot
            .appendingPathComponent("miniscore-bl6-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let skillsRoot = parent.appendingPathComponent("skills", isDirectory: true)
        let store = SkillStore(skillsRoot: skillsRoot)
        let skill = try store.importSkillThroughLifecycle(
            content: "---\nname: Synthetic Enablement\n---\nowned fixture body",
            source: .bundled, reason: "owned fixture",
            approval: SkillApproval(approverID: "synthetic reviewer")
        ).skill
        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let key = "skills.app:\(skill.id).enabled"
        let original = try store.bl6SkillEnablementSnapshot(visibleTo: scope)
        #expect(original.values[key] == true)
        store.bl6EnablementFaultInjector = { point in
            if case .afterIntentPersisted = point { throw BL6SyntheticFault.interrupted }
        }
        #expect(throws: BL6SyntheticFault.self) {
            try store.commitBL6SkillEnablement(
                skillID: skill.id, enabled: false, visibleTo: scope,
                profileID: "owned-profile", expectedRevision: original.revision
            ) { previous, effective in
                Self.bl6SkillRecord(requestID: "first-interrupted", profileID: "owned-profile",
                    scope: scope, skillID: skill.id, enabled: false, previousEnabled: true,
                    previousRevision: previous, effectiveRevision: effective)
            }
        }
        #expect(store.snapshot().skills.first(where: { $0.id == skill.id })?.isEnabled == false)
        #expect(!store.isInjectable(skill))
        let afterIntent = SkillStore(skillsRoot: skillsRoot)
        #expect(try afterIntent.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == true)
        #expect(try afterIntent.bl6SkillEnablementReplayRecord(
            for: "first-interrupted", profileID: "owned-profile") == nil)

        afterIntent.bl6EnablementFaultInjector = { point in
            if case .afterSharedStatePersisted = point { throw BL6SyntheticFault.interrupted }
        }
        let secondRevision = try afterIntent.bl6SkillEnablementSnapshot(visibleTo: scope).revision
        #expect(throws: BL6SyntheticFault.self) {
            try afterIntent.commitBL6SkillEnablement(
                skillID: skill.id, enabled: false, visibleTo: scope,
                profileID: "owned-profile", expectedRevision: secondRevision
            ) { previous, effective in
                Self.bl6SkillRecord(requestID: "second-interrupted", profileID: "owned-profile",
                    scope: scope, skillID: skill.id, enabled: false, previousEnabled: true,
                    previousRevision: previous, effectiveRevision: effective)
            }
        }
        #expect(afterIntent.snapshot().skills.first(where: { $0.id == skill.id })?.isEnabled == false)
        let recovered = SkillStore(skillsRoot: skillsRoot)
        #expect(try recovered.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == false)
        #expect(SkillInjector(store: recovered, minimumScore: 1)
            .matchingSkills(for: "synthetic enablement").isEmpty)
        let recoveredRecord = try recovered.bl6SkillEnablementReplayRecord(
            for: "second-interrupted", profileID: "owned-profile")
        let disable = try #require(recoveredRecord)
        #expect(try recovered.replayBL6SkillEnablementRecord(
            disable, profileID: "owned-profile") == disable.receipt)
        #expect(throws: BL6SkillEnablementError.self) {
            try recovered.replayBL6SkillEnablementRecord(disable, profileID: "foreign-profile")
        }

        let undoRevision = try recovered.bl6SkillEnablementSnapshot(visibleTo: scope).revision
        let undo = try recovered.commitBL6SkillEnablement(
            skillID: skill.id, enabled: true, visibleTo: scope,
            profileID: "owned-profile", expectedRevision: undoRevision, undo: disable
        ) { previous, effective in
            Self.bl6SkillRecord(requestID: "undo", profileID: "owned-profile",
                scope: scope, skillID: skill.id, enabled: true, previousEnabled: false,
                operation: .rollback, undoReceiptID: disable.receipt.receiptID,
                previousRevision: previous, effectiveRevision: effective)
        }
        let reopened = SkillStore(skillsRoot: skillsRoot)
        #expect(try reopened.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == true)
        #expect(SkillInjector(store: reopened, minimumScore: 1)
            .matchingSkills(for: "synthetic enablement").map(\.id) == [skill.id])
        #expect(try reopened.bl6SkillEnablementReplayRecord(
            receiptID: undo.receipt.receiptID, profileID: "owned-profile") == undo)
        #expect(try reopened.replayBL6SkillEnablementRecord(
            disable, profileID: "owned-profile") == disable.receipt)
        #expect(throws: BL6SkillEnablementError.self) {
            try reopened.commitBL6SkillEnablement(
                skillID: skill.id, enabled: true, visibleTo: scope,
                profileID: "owned-profile", expectedRevision: undoRevision, undo: disable
            ) { _, _ in undo }
        }

        // A pre-existing plain skill key is still the App's fallback when
        // there is no namespaced mask. A canonical enable must not lose it.
        let sharedURL = parent.appendingPathComponent("skills-enabled.json")
        try JSONEncoder().encode([skill.id: false]).write(to: sharedURL, options: .atomic)
        let legacyStore = SkillStore(skillsRoot: skillsRoot)
        let legacyBefore = try legacyStore.bl6SkillEnablementSnapshot(visibleTo: scope)
        #expect(legacyBefore.values[key] == false)
        let legacyEnable = try legacyStore.commitBL6SkillEnablement(
            skillID: skill.id, enabled: true, visibleTo: scope,
            profileID: "owned-profile", expectedRevision: legacyBefore.revision
        ) { previous, effective in
            Self.bl6SkillRecord(requestID: "legacy-enable", profileID: "owned-profile",
                scope: scope, skillID: skill.id, enabled: true, previousEnabled: false,
                previousRevision: previous, effectiveRevision: effective)
        }
        let legacyReopened = SkillStore(skillsRoot: skillsRoot)
        #expect(try legacyReopened.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == true)
        let legacyUndoRevision = try legacyReopened.bl6SkillEnablementSnapshot(visibleTo: scope).revision
        _ = try legacyReopened.commitBL6SkillEnablement(
            skillID: skill.id, enabled: false, visibleTo: scope,
            profileID: "owned-profile", expectedRevision: legacyUndoRevision,
            undo: legacyEnable
        ) { previous, effective in
            Self.bl6SkillRecord(requestID: "legacy-undo", profileID: "owned-profile",
                scope: scope, skillID: skill.id, enabled: false, previousEnabled: true,
                operation: .rollback, undoReceiptID: legacyEnable.receipt.receiptID,
                previousRevision: previous, effectiveRevision: effective)
        }
        let legacyRestored = SkillStore(skillsRoot: skillsRoot)
        #expect(try legacyRestored.bl6SkillEnablementSnapshot(visibleTo: scope).values[key] == false)
        #expect(try JSONDecoder().decode([String: Bool].self,
            from: Data(contentsOf: sharedURL)) == [skill.id: false])
    }

    @Test func localSkillHasStableManifestAndCompleteLifecycle() {
        let manifest = SkillManifest(skillID: "demo", name: "Demo", content: "body", trust: .local)
        let proposal = SkillLifecycle.propose(manifest, reason: "import")
        let approval = SkillLifecycle.approve(proposal, reason: "user approved")
        let active = approval.flatMap { SkillLifecycle.activate($0, currentContentHash: manifest.contentHash, reason: "enable") }
        let rollback = active.flatMap { SkillLifecycle.rollback($0, reason: "disable") }

        #expect(manifest.contentHash == SkillManifest.hash("body"))
        #expect(proposal.state == .proposed)
        #expect(approval?.state == .approved)
        #expect(active?.state == .active)
        #expect(rollback?.state == .rolledBack)
    }

    @Test func rollbackPreservesPreviousRevisionAndAuthorizationBoundary() {
        let previousContent = "---\nname: Demo\nversion: 1.0.0\n---\nprevious"
        let currentContent = "---\nname: Demo\nversion: 2.0.0\n---\ncurrent"
        let previousManifest = SkillManifest(
            skillID: "demo",
            name: "Demo",
            content: previousContent,
            trust: .local
        )
        let currentManifest = SkillManifest(
            skillID: "demo",
            name: "Demo",
            content: currentContent,
            trust: .local
        )
        let previousApproval = SkillApproval(
            approverID: "previous-reviewer",
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let currentApproval = SkillApproval(approverID: "current-reviewer")
        let previousActive = SkillLifecycle.approve(
            SkillLifecycle.propose(previousManifest, reason: "previous import"),
            approval: previousApproval,
            reason: "previous approve"
        ).flatMap {
            SkillLifecycle.activate($0, currentContentHash: previousManifest.contentHash, reason: "previous activate")
        }
        let currentActive = SkillLifecycle.approve(
            SkillLifecycle.propose(currentManifest, reason: "current import"),
            approval: currentApproval,
            reason: "current approve"
        ).flatMap {
            SkillLifecycle.activate($0, currentContentHash: currentManifest.contentHash, reason: "current activate")
        }

        let rollback = currentActive.flatMap { current in
            previousActive.flatMap { previous in
                SkillLifecycle.rollback(
                    current,
                    previousContentHash: previousManifest.contentHash,
                    previousReceipt: previous,
                    reason: "reject current"
                )
            }
        }

        #expect(rollback?.state == .rolledBack)
        #expect(rollback?.contentHash == previousManifest.contentHash)
        #expect(rollback?.sourceIdentity == previousManifest.sourceIdentity)
        #expect(rollback?.approvedBy == previousActive?.approvedBy)
        #expect(rollback?.scope == previousActive?.scope)
        #expect(rollback?.expiresAt == previousActive?.expiresAt)
    }

    @Test func untrustedSkillIsQuarantinedAndCannotBeApproved() {
        let manifest = SkillManifest(skillID: "remote", name: "Remote", content: "body", trust: .untrusted)
        let proposal = SkillLifecycle.propose(manifest, reason: "import")

        #expect(proposal.state == .quarantined)
        #expect(SkillLifecycle.approve(proposal, reason: "approve") == nil)
    }

    @Test func changedPayloadCannotActivateApprovedReceipt() {
        let manifest = SkillManifest(skillID: "demo", name: "Demo", content: "body", trust: .bundled)
        let approval = SkillLifecycle.approve(SkillLifecycle.propose(manifest, reason: "import"), reason: "approve")

        #expect(approval != nil)
        #expect(SkillLifecycle.activate(approval!, currentContentHash: SkillManifest.hash("changed"), reason: "enable") == nil)
    }

    @Test func registryRejectsMissingManifestAfterReload() throws {
        try assertRegistryRejectsInvalidManifest { store, skill in
            try FileManager.default.removeItem(at: store.skillManifestURL(for: skill.id))
        }
    }

    @Test func registryRejectsCorruptManifestAfterReload() throws {
        try assertRegistryRejectsInvalidManifest { store, skill in
            try Data("{not-json".utf8).write(
                to: store.skillManifestURL(for: skill.id),
                options: .atomic
            )
        }
    }

    @Test func registryRejectsMismatchedManifestAfterReload() throws {
        try assertRegistryRejectsInvalidManifest { store, skill in
            let mismatched = SkillSourceManifest(
                skillID: skill.id,
                source: skill.importSource,
                skillVersion: skill.version,
                content: "different payload"
            )
            try JSONEncoder().encode(mismatched).write(
                to: store.skillManifestURL(for: skill.id),
                options: .atomic
            )
        }
    }

    @Test func registryAcceptsVerifiedManifest() throws {
        try withTemporarySkillStore { store in
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: Verified\n---\nbody",
                source: .bundled,
                reason: "test",
                approval: SkillApproval(approverID: "test")
            )
            let skill = imported.skill
            let rejection = SkillRegistry(store: store).rejection(
                for: skill,
                content: store.rawContent(skill.id)
            )
            #expect(rejection == nil)
        }
    }

    @Test func invalidManifestIsRejectedByMatchingAndInjection() throws {
        try withTemporarySkillStore { store in
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: Registry Test\ndescription: registry test\n---\nbody",
                source: .bundled,
                reason: "test",
                approval: SkillApproval(approverID: "test")
            )
            try FileManager.default.removeItem(at: store.skillManifestURL(for: imported.skill.id))
            store.reload()

            let injector = SkillInjector(store: store, minimumScore: 1)
            #expect(injector.matchingSkills(for: "registry test").isEmpty)
            #expect(injector.buildInjectionFragment(for: "registry test") == nil)
        }
    }

    @Test func turnSnapshotRevisionSeparatesEnablementAndRestart() throws {
        try withTemporarySkillStore { store in
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: Registry Test\ndescription: registry test\n---\nbody",
                source: .bundled,
                reason: "test",
                approval: SkillApproval(approverID: "test")
            )
            let firstTurn = SkillInjector(store: store, minimumScore: 1).snapshotForTurn()
            #expect(firstTurn.matchingSkills(for: "registry test").map(\.id) == [imported.skill.id])

            store.setEnabled(imported.skill.id, enabled: false)
            let nextTurn = SkillInjector(store: store, minimumScore: 1).snapshotForTurn()
            #expect(firstTurn.registryRevision != nextTurn.registryRevision)
            #expect(
                (revisionOrdinal(firstTurn.registryRevision) ?? 0)
                    < (revisionOrdinal(nextTurn.registryRevision) ?? 0)
            )
            #expect(firstTurn.matchingSkills(for: "registry test").map(\.id) == [imported.skill.id])
            #expect(nextTurn.matchingSkills(for: "registry test").isEmpty)

            let restarted = SkillStore(skillsRoot: store.skillsRoot)
            let restartedTurn = SkillInjector(store: restarted, minimumScore: 1).snapshotForTurn()
            #expect(restartedTurn.registryRevision != nextTurn.registryRevision)
            #expect(
                (revisionOrdinal(nextTurn.registryRevision) ?? 0)
                    < (revisionOrdinal(restartedTurn.registryRevision) ?? 0)
            )
            #expect(restartedTurn.matchingSkills(for: "registry test").isEmpty)
        }
    }

    private func revisionOrdinal(_ revision: String) -> UInt64? {
        UInt64(revision.split(separator: ":", maxSplits: 1).first ?? "")
    }

    @Test func rollbackRestoresPreviousRevisionConsumesCandidateAndStaysDisabled() throws {
        try withTemporarySkillStore { store in
            let previousContent = "---\nname: Rollback Test\nversion: 1.0.0\n---\nprevious body"
            let currentContent = "---\nname: Rollback Test\nversion: 2.0.0\n---\ncurrent body"
            let previous = try store.importSkillThroughLifecycle(
                content: previousContent,
                source: .bundled,
                reason: "previous",
                approval: SkillApproval(approverID: "previous-reviewer")
            )
            let previousReceipt = store.lifecycleReceipt(for: previous.skill.id)
            _ = try store.importSkillThroughLifecycle(
                content: currentContent,
                source: .bundled,
                reason: "current",
                approval: SkillApproval(approverID: "current-reviewer")
            )

            #expect(store.canRollbackSkill(previous.skill.id))
            let rollback = try store.rollbackSkill(previous.skill.id, reason: "reject current")
            #expect(rollback.contentHash == SkillManifest.hash(previousContent))
            #expect(rollback.sourceIdentity == "skill:\(previous.skill.id)@\(SkillManifest.hash(previousContent))")
            #expect(rollback.approvedBy == previousReceipt?.approvedBy)
            #expect(store.rawContent(previous.skill.id) == previousContent)
            #expect(store.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
            #expect(!store.isInjectable(store.allSkills().first(where: { $0.id == previous.skill.id })!))
            #expect(!store.canRollbackSkill(previous.skill.id))
            #expect(throws: SkillError.self) {
                try store.rollbackSkill(previous.skill.id, reason: "replay")
            }

            let restarted = SkillStore(skillsRoot: store.skillsRoot)
            #expect(restarted.rawContent(previous.skill.id) == previousContent)
            #expect(restarted.lifecycleReceipt(for: previous.skill.id)?.contentHash == rollback.contentHash)
            #expect(restarted.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
            #expect(SkillInjector(store: restarted, minimumScore: 1)
                .matchingSkills(for: "rollback test").isEmpty)
        }
    }

    @Test func rollbackRejectsQuarantinedCurrentRevision() throws {
        try withTemporarySkillStore { store in
            let previousContent = "---\nname: Quarantine Rollback\nversion: 1.0.0\n---\nprevious"
            let currentContent = "---\nname: Quarantine Rollback\nversion: 2.0.0\n---\nquarantined"
            let previous = try store.importSkillThroughLifecycle(
                content: previousContent,
                source: .bundled,
                reason: "previous",
                approval: SkillApproval(approverID: "reviewer")
            )
            _ = try store.importSkillThroughLifecycle(
                content: currentContent,
                source: .url("https://example.invalid/skill.md"),
                reason: "remote current"
            )
            #expect(store.lifecycleReceipt(for: previous.skill.id)?.state == .quarantined)
            #expect(!store.canRollbackSkill(previous.skill.id))
            #expect(throws: SkillError.self) {
                try store.rollbackSkill(previous.skill.id, reason: "reject quarantined")
            }
            #expect(store.rawContent(previous.skill.id) == currentContent)
            #expect(store.allSkills().first(where: { $0.id == previous.skill.id })?.isEnabled == false)
        }
    }

    @Test func rollbackPreservesPreviousSourceManifestAndAuthorization() throws {
        try withTemporarySkillStore { store in
            let previousContent = "---\nname: Cross Source Rollback\nversion: 1.0.0\n---\nprevious"
            let currentContent = "---\nname: Cross Source Rollback\nversion: 2.0.0\n---\ncurrent"
            let previous = try store.importSkillThroughLifecycle(
                content: previousContent,
                source: .bundled,
                reason: "previous",
                approval: SkillApproval(
                    approverID: "previous-reviewer",
                    expiresAt: Date(timeIntervalSinceNow: 600)
                )
            )
            let previousReceipt = try #require(store.lifecycleReceipt(for: previous.skill.id))
            let previousManifestData = try Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
            let previousManifest = try JSONDecoder().decode(
                SkillSourceManifest.self,
                from: previousManifestData
            )
            _ = try store.importSkillThroughLifecycle(
                content: currentContent,
                source: .file,
                reason: "current",
                approval: SkillApproval(approverID: "current-reviewer")
            )

            let rollback = try store.rollbackSkill(previous.skill.id, reason: "reject source change")
            let restoredManifest = try JSONDecoder().decode(
                SkillSourceManifest.self,
                from: Data(contentsOf: store.skillManifestURL(for: previous.skill.id))
            )
            let restoredSkill = try #require(
                store.allSkills().first(where: { $0.id == previous.skill.id })
            )

            #expect(restoredManifest == previousManifest)
            #expect(restoredManifest.source == .bundled)
            #expect(restoredSkill.importSource == .bundled)
            #expect(rollback.contentHash == previousReceipt.contentHash)
            #expect(rollback.sourceIdentity == previousReceipt.sourceIdentity)
            #expect(rollback.approvedBy == previousReceipt.approvedBy)
            #expect(rollback.scope == previousReceipt.scope)
            #expect(rollback.expiresAt == previousReceipt.expiresAt)
            #expect(restoredSkill.isEnabled == false)

            let restarted = SkillStore(skillsRoot: store.skillsRoot)
            let restartedSkill = try #require(
                restarted.allSkills().first(where: { $0.id == previous.skill.id })
            )
            #expect(restartedSkill.importSource == .bundled)
            #expect(SkillRegistry(store: restarted).entry(for: previous.skill.id)?.sourceIdentity
                == previousReceipt.sourceIdentity)
            #expect(SkillInjector(store: restarted, minimumScore: 1)
                .matchingSkills(for: "cross source rollback").isEmpty)
        }
    }

    @Test func registryRevisionPersistsRollbackIdentityAcrossRestart() throws {
        try withTemporarySkillStore { store in
            let initial = try store.importSkillThroughLifecycle(
                content: "---\nname: Registry Test\ndescription: registry test\n---\ninitial",
                source: .bundled,
                reason: "initial",
                approval: SkillApproval(approverID: "test")
            )
            let initialRevision = SkillRegistry(store: store).revision

            _ = try store.importSkillThroughLifecycle(
                content: "---\nname: Registry Test\ndescription: registry test\n---\nupdated",
                source: .bundled,
                reason: "upgrade",
                approval: SkillApproval(approverID: "test")
            )
            let updatedRevision = SkillRegistry(store: store).revision
            #expect(updatedRevision != initialRevision)

            let rollback = try store.rollbackSkill(initial.skill.id, reason: "reject upgrade")
            let rollbackRevision = SkillRegistry(store: store).revision
            #expect(rollback.state == .rolledBack)
            #expect(rollbackRevision != updatedRevision)

            let restarted = SkillStore(skillsRoot: store.skillsRoot)
            #expect(SkillRegistry(store: restarted).revision == rollbackRevision)
            #expect(SkillInjector(store: restarted, minimumScore: 1)
                .matchingSkills(for: "registry test").isEmpty)
        }
    }

    private func assertRegistryRejectsInvalidManifest(
        _ mutate: (SkillStore, Skill) throws -> Void
    ) throws {
        try withTemporarySkillStore { store in
            let imported = try store.importSkillThroughLifecycle(
                content: "---\nname: Registry Test\n---\nbody",
                source: .bundled,
                reason: "test",
                approval: SkillApproval(approverID: "test")
            )
            try mutate(store, imported.skill)
            store.reload()
            guard let reloaded = store.allSkills().first else {
                Issue.record("skill disappeared while reloading registry test fixture")
                return
            }
            let rejection = SkillRegistry(store: store).rejection(
                for: reloaded,
                content: store.rawContent(reloaded.id)
            )
            #expect(rejection == .invalidManifest)
        }
    }

    private func withTemporarySkillStore<T>(
        _ body: (SkillStore) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscore-skill-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(SkillStore(skillsRoot: root))
    }
}
