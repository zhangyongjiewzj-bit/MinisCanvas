import Foundation
import Darwin
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum U32SafetyRefusal: Error { case refused(String) }
private func requireU32(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    if !condition() { throw U32SafetyRefusal.refused(reason) }
}
private func infoU32(_ url: URL) -> stat? {
    var value = stat()
    return lstat(url.path, &value) == 0 ? value : nil
}
private func absentU32(_ url: URL) -> Bool {
    var value = stat()
    let result = lstat(url.path, &value)
    let code = errno
    return result == -1 && code == ENOENT
}
@Suite("U00032 actual Typography factory badge-owner construction", .serialized)
@MainActor
struct U00032BadgeOwnerConstructionDriver {
    @Test("the original Typography clone preserves the explicitly injected canonical badge owner")
    func typographyCloneDoesNotInitializeAnotherDefaultBadgeOwner() throws {
        print("U32_PHASE=ACTUAL_CURRENT_PROCESS_CORE_APP_GATE_BEGIN")
        // These are the real current-process resolvers. No input-dictionary or
        // forged processName seam is used to authorize a default factory.
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile()
        try requireU32(profile.mode == .isolatedTest, "App-mode-is-not-isolatedTest")
        try requireU32(profile.rootDirectory == formal.rootDirectory, "Core-App-root-mismatch")
        try requireU32(profile.keychainComposition == .testNamespacedInMemory(namespace: profile.keychainService),
                       "not-namespaced-in-memory-descriptor")
        try requireU32(profile.keychainLegacyServices.isEmpty && !profile.allowsExternalNetwork,
                       "legacy-Keychain-or-general-network-not-denied")
        let root = formal.rootDirectory
        guard let rootInfo = infoU32(root), let captured = profile.disposableRootIdentity else {
            throw U32SafetyRefusal.refused("formal-root-identity-unavailable")
        }
        try requireU32((rootInfo.st_mode & S_IFMT) == S_IFDIR && (rootInfo.st_mode & 0o777) == 0o700,
                       "formal-root-not-directory-700")
        try requireU32(rootInfo.st_uid == geteuid() && UInt32(rootInfo.st_uid) == formal.rootOwner,
                       "formal-root-not-own-UID")
        try requireU32(UInt64(rootInfo.st_dev) == formal.rootDevice && UInt64(rootInfo.st_ino) == formal.rootInode,
                       "formal-root-not-Core-dev-inode")
        try requireU32(captured.device == formal.rootDevice && captured.inode == formal.rootInode,
                       "formal-root-not-App-dev-inode")
        // The live Core resolver has already canonicalized and verified the
        // formal contract's scratch/root pair. Its public result exposes root;
        // scratch is that validated root's immediate parent, not Foundation TMP.
        let formalScratch = root.deletingLastPathComponent()
        guard let scratchInfo = infoU32(formalScratch) else {
            throw U32SafetyRefusal.refused("formal-scratch-identity-unavailable")
        }
        try requireU32((scratchInfo.st_mode & S_IFMT) == S_IFDIR
            && (scratchInfo.st_mode & 0o777) == 0o700
            && scratchInfo.st_uid == geteuid()
            && scratchInfo.st_dev == rootInfo.st_dev
            && scratchInfo.st_ino != rootInfo.st_ino,
            "formal-scratch-not-owned-700-parent")
        try requireU32(formal.packageName == "MinisCanvasApp"
            && root.lastPathComponent == "formal-test-root"
            && formalScratch.lastPathComponent == formal.packageName,
            "Core-formal-package-root-shape-mismatch")
        try requireU32(profile.label == "formal-test"
            && profile.userDefaultsSuiteName == formal.userDefaultsSuiteName
            && profile.keychainService == formal.keychainService
            && profile.environment[RuntimeIsolationProfile.profileMarkerKey] == "1"
            && profile.environment[RuntimeIsolationProfile.profileDirectoryKey] == root.path,
            "App-current-formal-profile-identity-mismatch")
        let processDefaultBadges = formal.minisCanvasDirectory
        try requireU32(processDefaultBadges == profile.minisCanvasDirectory
            && processDefaultBadges.deletingLastPathComponent() == root,
            "default-Canvas-not-this-formal-root")
        // B0508: the process default can legitimately have earlier-suite state.
        // It is neither removed nor asserted absent. File-footprint assertions
        // below concern only this invocation's owned fixture; the independent
        // weak identity assertion detects a clone that drops the injected owner.
        let fixture = root.appendingPathComponent("U32-isolated-\(UUID().uuidString)", isDirectory: true)
        try requireU32(absentU32(fixture), "isolated-fixture-not-fresh")
        let defaultBadges = fixture.appendingPathComponent("Canvas", isDirectory: true)
        try requireU32(absentU32(defaultBadges), "owned-Canvas-preexists-before-any-store")
        let canonical = fixture.appendingPathComponent("U32-canonical-\(UUID().uuidString)", isDirectory: true)
        try requireU32(absentU32(canonical), "canonical-root-not-fresh")
        let tracePath = root.deletingLastPathComponent().appendingPathComponent("U32_CONSTRUCTION_TRACE.json")
        var trace: [String: Any] = [
            "scope": "actual-production-factory-construction-only-no-body-or-host",
            "Core_current_process_gate": true, "App_current_process_mode": "isolatedTest",
            "Keychain_composition_descriptor": "testNamespacedInMemory-no-store-or-item-access",
            "root": root.path, "root_uid": rootInfo.st_uid, "root_mode": "0700",
            "root_device": rootInfo.st_dev, "root_inode": rootInfo.st_ino,
            "formal_scratch": formalScratch.path,
            "formal_scratch_uid": scratchInfo.st_uid, "formal_scratch_mode": "0700",
            "formal_scratch_device": scratchInfo.st_dev, "formal_scratch_inode": scratchInfo.st_ino,
            "Core_run_identity": formal.runIdentity, "Core_package": formal.packageName,
            "assertion_scope": "owned-fixture-footprint-and-returned-clone-injected-owner-identity",
            "process_default_badge_directory_not_asserted_or_modified": processDefaultBadges.path,
            "owned_fixture_directory": fixture.path,
            "default_badge_directory": defaultBadges.path,
            "default_directory_before_any_store_ENOENT": true, "canonical_badge_directory": canonical.path,
            "body_host_AppMain_NSApp_network_tool_subprocess_calls": "NONE_IN_DRIVER"
        ]
        var fixtureCreatedIdentity: stat?
        var defaultCreatedIdentity: stat?
        var canonicalCreatedIdentity: stat?
        defer {
            var cleanup: [[String: Any]] = []
            if let currentRoot = infoU32(root), currentRoot.st_dev == rootInfo.st_dev,
               currentRoot.st_ino == rootInfo.st_ino, currentRoot.st_uid == rootInfo.st_uid {
                if let fixtureIdentity = fixtureCreatedIdentity, let currentFixture = infoU32(fixture),
                   currentFixture.st_dev == fixtureIdentity.st_dev,
                   currentFixture.st_ino == fixtureIdentity.st_ino,
                   currentFixture.st_uid == fixtureIdentity.st_uid,
                   fixture.deletingLastPathComponent() == root {
                    for (path, identity) in [(canonical, canonicalCreatedIdentity), (defaultBadges, defaultCreatedIdentity)] {
                        if let identity, let current = infoU32(path),
                           current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
                           current.st_uid == identity.st_uid, current.st_uid == geteuid(),
                           (current.st_mode & S_IFMT) == S_IFDIR,
                           path.deletingLastPathComponent() == fixture {
                            do {
                                try FileManager.default.removeItem(at: path)
                                let removed = absentU32(path)
                                cleanup.append(["path": path.path, "identity_matched": true, "ENOENT": removed])
                                #expect(removed, "Driver-owned path must be absent after strict cleanup")
                            } catch {
                                cleanup.append(["path": path.path, "cleanup_error_type": String(reflecting: type(of: error))])
                                Issue.record("U32 own-directory cleanup failed")
                            }
                        } else if absentU32(path) {
                            cleanup.append(["path": path.path, "ENOENT": true, "not_created_or_already_absent": true])
                        } else {
                            cleanup.append(["path": path.path, "cleanup_refused_identity_mismatch": true])
                            Issue.record("U32 own-directory identity changed; cleanup refused")
                        }
                    }
                    do {
                        let remainingChildren = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
                        try requireU32(remainingChildren.isEmpty, "owned-fixture-has-unrecognized-children")
                        try FileManager.default.removeItem(at: fixture)
                        #expect(absentU32(fixture), "Owned fixture must be absent after strict cleanup")
                    } catch { Issue.record("U32 owned-fixture cleanup failed") }
                } else if !absentU32(fixture) {
                    Issue.record("U32 owned-fixture identity changed; cleanup refused")
                }
            } else { Issue.record("U32 formal root changed; all cleanup refused") }
            trace["strict_cleanup"] = cleanup
            do {
                let data = try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: tracePath, options: [.atomic])
                print("U32_TRACE_PATH=\(tracePath.path)")
            } catch { Issue.record("U32 safe evidence serialization failed") }
        }
        // All producer construction below is dominated by the real live gates.
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        fixtureCreatedIdentity = infoU32(fixture)
        guard let fixtureInfo = fixtureCreatedIdentity else { throw U32SafetyRefusal.refused("fixture-lstat") }
        try requireU32(fixtureInfo.st_uid == geteuid() && fixtureInfo.st_dev == rootInfo.st_dev
            && (fixtureInfo.st_mode & S_IFMT) == S_IFDIR && (fixtureInfo.st_mode & 0o777) == 0o700,
            "fixture-not-owned-700-same-device")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        canonicalCreatedIdentity = infoU32(canonical)
        guard let canonicalInfo = canonicalCreatedIdentity else { throw U32SafetyRefusal.refused("canonical-lstat") }
        try requireU32(canonicalInfo.st_uid == geteuid() && canonicalInfo.st_dev == rootInfo.st_dev
            && (canonicalInfo.st_mode & 0o777) == 0o700, "canonical-not-owned-700-same-device")
        let item = ChatStore.SessionListItem(session: ChatThread(title: "U32-owned-construction"), execution: nil)
        weak var canonicalOwnerWitness: SessionBadgeStore?
        var canonicalOwnerID: ObjectIdentifier?
        // A non-inlined function ends all local strong-owner lifetimes before
        // the assertion below. SessionBadgeStore.init/load are synchronous and
        // install no task, observer or self-healing owner retention.
        @MainActor @inline(never)
        func constructOriginalClone() throws -> AnyView {
            let canonicalBadges = SessionBadgeStore(directory: canonical)
            canonicalOwnerWitness = canonicalBadges
            canonicalOwnerID = ObjectIdentifier(canonicalBadges)
            let defaults = try #require(UserDefaults(suiteName: formal.userDefaultsSuiteName))
            // No defaults values are read/set/removed by this driver or this narrow
            // ChatStore init/toggle-free route. The unique formal suite is not .standard.
            let logger = LogManager(directory: canonical.appendingPathComponent("driver-logs", isDirectory: true))
            let chat = ChatStore(preferencesDefaults: defaults, logManager: logger)
            let outer = SessionSidebarView(chat: chat, collapsed: false,
                sessionBadgeStore: canonicalBadges, badgeDiagnosticsEnabled: false)
            try requireU32(absentU32(defaultBadges), "default-Canvas-created-before-original-factory")
            trace["default_directory_after_explicit_outer_ENOENT"] = true
            print("U32_GATE=READY_CANONICAL_AND_DEFAULT_SEPARATED")
            // This is the original internal production factory. No mirror of its
            // implementation, private owner reflection, body evaluation or hosting.
            let erased = outer.typographyInstrumentationRow(item)
            withExtendedLifetime(erased) {
                defaultCreatedIdentity = infoU32(defaultBadges)
            }
            let defaultExists = defaultCreatedIdentity != nil
            if let defaultInfo = defaultCreatedIdentity {
                try requireU32(defaultInfo.st_uid == geteuid() && defaultInfo.st_dev == rootInfo.st_dev
                    && (defaultInfo.st_mode & S_IFMT) == S_IFDIR, "new-default-directory-not-owned")
                trace["default_created_device"] = defaultInfo.st_dev
                trace["default_created_inode"] = defaultInfo.st_ino
                trace["default_created_uid"] = defaultInfo.st_uid
            }
            trace["factory_called"] = true
            trace["default_directory_after_factory_exists"] = defaultExists
            trace["canonical_snapshot_exists"] = canonicalBadges.snapshot(for: item.id.uuidString) != nil
            trace["canonical_badges_file_exists"] = !absentU32(canonical.appendingPathComponent("badges.json"))
            trace["default_badges_file_exists"] = !absentU32(defaultBadges.appendingPathComponent("badges.json"))
            print("U32_ORIGINAL_FACTORY default_directory_after=\(defaultExists)")
            // The footprint assertion now concerns this owned fixture only; it is
            // not a claim that the process-wide default factory was never used.
            return erased
        }
        let erased = try constructOriginalClone()
        let expectedOwnerID = try #require(canonicalOwnerID)
        try withExtendedLifetime(erased) {
            // Check before binding a new strong reference or evaluating the
            // original store assertions, so diagnostic captures cannot retain
            // the injected owner on behalf of a broken returned clone.
            let retainedID = canonicalOwnerWitness.map { ObjectIdentifier($0) }
            trace["returned_clone_retains_injected_owner"] = retainedID == expectedOwnerID
            #expect(retainedID == expectedOwnerID,
                    "Returned Typography clone must retain the exact explicitly injected badge owner")
            let canonicalBadges = try #require(canonicalOwnerWitness)
            let defaultExists = defaultCreatedIdentity != nil
            #expect(!defaultExists, "Typography clone must not initialize a second default persistent badge producer")
            #expect(canonicalBadges.snapshot(for: item.id.uuidString) == nil,
                    "Construction-only probe must not consume/render the row body")
            #expect(absentU32(canonical.appendingPathComponent("badges.json")),
                    "Construction-only probe must not persist a rendered badge")
            #expect(absentU32(defaultBadges.appendingPathComponent("badges.json")),
                    "Default initializer footprint must remain separate from body/persist coverage")
        }
    }
}
