import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("2167 ShortcutStore transaction ownership", .serialized)
@MainActor
struct ShortcutStoreTransaction2167Tests {
    private static let key = "miniscanvas.shortcuts.v1"
    private let profile = "/synthetic/shortcut-profile-2167"
    private let setting = "shortcuts.createPipeline"

    private func defaults() throws -> (String, UserDefaults) {
        let name = "ShortcutTransaction2167.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        return (name, preferences)
    }

    private func value(_ key: String) -> BL6SettingValue {
        .object(["key": .text(key), "modifiers": .object([
            "command": .toggle(true), "control": .toggle(false),
            "option": .toggle(false), "shift": .toggle(false)
        ])])
    }

    private func record(_ store: ShortcutStore, scope: String = "request", requestID: String = UUID().uuidString,
                        operation: BL6SettingsOperation = .apply, changes: [String: BL6SettingValue]? = nil,
                        undoID: String? = nil, after: [String: BL6SettingValue]? = nil) throws -> BL6SettingsReplayRecord {
        let snapshot = try store.bl6Snapshot(profileID: profile).get()
        let changes = changes ?? (operation == .apply ? [setting: value("g")] : [:])
        let input = BL6SettingsApprovedInput(operation: operation, changes: changes,
                                             expectedRevision: snapshot.revision, undoReceiptID: undoID)
        let encoded = try JSONEncoder().encode(input)
        let raw = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let digest = try #require(ApprovalAuthorizationContext.payloadDigest(for: raw))
        var target = after ?? snapshot.values
        if operation == .apply { for (key, value) in changes { target[key] = value } }
        let receipt = BL6SettingsReceipt(requestID: requestID, operation: operation,
                                         previousRevision: snapshot.revision, effectiveRevision: UUID().uuidString,
                                         changedKeys: snapshot.values.keys.filter { snapshot.values[$0] != target[$0] },
                                         rollbackValues: [:])
        return BL6SettingsReplayRecord(requestID: requestID, payloadDigest: digest, frozenInput: input,
                                        approvalBindingDigest: "synthetic-consumed-\(scope)-\(requestID)",
                                        profileID: profile, scope: scope, sessionID: "synthetic-session-2167",
                                        policyRevision: "synthetic-policy-1", grantEpoch: "synthetic-grant-1",
                                        approvalExpiresAt: Date().addingTimeInterval(600), operation: operation,
                                        receipt: receipt, rollbackValues: snapshot.values)
    }

    @Test("one committed value reopens and exact completed identities never reapply", arguments: ["request", "turn", "session", "workspace"])
    func reopenAndReplay(scope: String) throws {
        let (name, preferences) = try defaults()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: preferences)
        let effect = try record(store, scope: scope)
        #expect(try store.commitBL6Replay(effect, profileID: profile).get() == effect.receipt)
        let reopenedDefaults = try #require(UserDefaults(suiteName: name))
        let reopened = ShortcutStore(defaults: reopenedDefaults)
        #expect(reopened.binding(for: .createPipeline) == ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command))
        #expect(try reopened.bl6ReplayRecord(for: effect.requestID, profileID: profile).get() == effect)
        let beforeRetry = reopenedDefaults.data(forKey: Self.key)
        #expect(try reopened.commitBL6Replay(effect, profileID: profile).get() == effect.receipt)
        #expect(reopenedDefaults.data(forKey: Self.key) == beforeRetry)
        #expect(reopened.setBinding(ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command), for: .createPipeline) == nil)
        let beforeSecondRetry = reopenedDefaults.data(forKey: Self.key)
        #expect(try reopened.commitBL6Replay(effect, profileID: profile).get() == effect.receipt)
        #expect(reopenedDefaults.data(forKey: Self.key) == beforeSecondRetry)
        #expect(reopened.binding(for: .createPipeline).key == "u")
        let conflict = try record(reopened, scope: scope, requestID: effect.requestID)
        #expect(reopened.commitBL6Replay(conflict, profileID: profile) == .failure(.conflict))
    }

    @Test("Store-owned undo restores original overrides and rejects stale undo")
    func undoAndExternalChange() throws {
        let (name, preferences) = try defaults()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: preferences)
        let before = try store.bl6Snapshot(profileID: profile).get()
        let effect = try record(store)
        _ = try store.commitBL6Replay(effect, profileID: profile).get()
        let reopenedDefaults = try #require(UserDefaults(suiteName: name))
        let reopened = ShortcutStore(defaults: reopenedDefaults)
        let undo = try record(reopened, operation: .rollback, undoID: effect.receipt.receiptID, after: before.values)
        _ = try reopened.commitBL6Replay(undo, profileID: profile).get()
        #expect(try reopened.bl6Snapshot(profileID: profile).get().values == before.values)
        let persistedData = try #require(preferences.data(forKey: Self.key))
        let object = try #require(try JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        #expect((object["overrides"] as? [String: Any])?.isEmpty == true)
        #expect(try reopened.bl6ReplayRecord(receiptID: undo.receipt.receiptID, profileID: profile).get() == undo)

        let second = try record(reopened)
        _ = try reopened.commitBL6Replay(second, profileID: profile).get()
        let pendingUndo = try record(reopened, operation: .rollback, undoID: second.receipt.receiptID, after: before.values)
        let externalDefaults = try #require(UserDefaults(suiteName: name))
        let external = ShortcutStore(defaults: externalDefaults)
        #expect(external.setBinding(ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command), for: .createPipeline) == nil)
        let externalData = preferences.data(forKey: Self.key)
        #expect(reopened.commitBL6Replay(pendingUndo, profileID: profile) == .failure(.staleRevision))
        #expect(preferences.data(forKey: Self.key) == externalData)
        #expect(ShortcutStore(defaults: preferences).binding(for: .createPipeline).key == "u")
    }

    @Test("foreign profiles, conflicts and malformed values publish no completion")
    func rejectedCandidates() throws {
        let (name, preferences) = try defaults()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: preferences)
        let valid = try record(store)
        #expect(store.commitBL6Replay(valid, profileID: "/synthetic/other-profile") == .failure(.conflict))
        #expect(preferences.data(forKey: Self.key) == nil)
        for input in [value("1"), value("space"), value("LONG"), .text("g")] {
            let rejected = try record(store, changes: [setting: input])
            #expect(store.commitBL6Replay(rejected, profileID: profile) == .failure(.conflict))
            #expect(preferences.data(forKey: Self.key) == nil)
            #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        }
        _ = try store.commitBL6Replay(valid, profileID: profile).get()
        let copy = ShortcutStore(defaults: preferences)
        guard case .failure(.conflict) = copy.bl6Snapshot(profileID: "/synthetic/other-profile") else {
            Issue.record("A different canonical profile must not acquire the transaction snapshot")
            return
        }
        #expect(copy.bl6ReplayRecord(for: valid.requestID, profileID: "/synthetic/other-profile") == .failure(.conflict))
    }

    @Test("damaged transaction evidence is preserved and blocks new effects")
    func damagedCompletion() throws {
        let (name, preferences) = try defaults()
        defer { preferences.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: preferences)
        let effect = try record(store)
        _ = try store.commitBL6Replay(effect, profileID: profile).get()
        let pending = try record(store, changes: [setting: value("u")])
        let persistedData = try #require(preferences.data(forKey: Self.key))
        var object = try #require(try JSONSerialization.jsonObject(with: persistedData) as? [String: Any])
        object["version"] = 99
        let damaged = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        preferences.set(damaged, forKey: Self.key)
        #expect(store.commitBL6Replay(pending, profileID: profile) == .failure(.persistence(.transactionRecoveryRequired)))
        #expect(store.bl6ReplayRecord(for: effect.requestID, profileID: profile) == .failure(.persistence(.transactionRecoveryRequired)))
        #expect(store.setBinding(ShortcutBinding(key: "u", modifiers: ShortcutModifiers.command), for: .createPipeline) == .persistence)
        #expect(preferences.data(forKey: Self.key) == damaged)
        #expect(store.binding(for: .createPipeline).key == "g")
    }

    @Test("ignored writes never publish success or undo; reset commits through the same boundary")
    func failedWriteAndReset() throws {
        let name = "ShortcutTransaction2167.Failure.\(UUID().uuidString)"
        let preferences = try #require(IgnoringShortcutDefaults2167(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let store = ShortcutStore(defaults: preferences)
        let before = try store.bl6Snapshot(profileID: profile).get()
        let effect = try record(store)
        preferences.ignoreWrites = true
        #expect(store.setBinding(ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .createPipeline) == .persistence)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        #expect(store.commitBL6Replay(effect, profileID: profile) == .failure(.persistence(.writeFailed)))
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        #expect(try store.bl6ReplayRecord(for: effect.requestID, profileID: profile).get() == nil)
        let reopenedDefaults = try #require(UserDefaults(suiteName: name))
        let reopenedAfterFailure = ShortcutStore(defaults: reopenedDefaults)
        #expect(reopenedAfterFailure.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        preferences.ignoreWrites = false
        _ = try store.commitBL6Replay(effect, profileID: profile).get()
        let reset = try record(store, operation: .reset, after: before.values)
        _ = try store.commitBL6Replay(reset, profileID: profile).get()
        #expect(try store.bl6Snapshot(profileID: profile).get().values == before.values)
        #expect(try store.bl6ReplayRecord(for: reset.requestID, profileID: profile).get() == reset)
    }
}

private final class IgnoringShortcutDefaults2167: UserDefaults {
    var ignoreWrites = false
    override func set(_ value: Any?, forKey defaultName: String) {
        if !ignoreWrites { super.set(value, forKey: defaultName) }
    }
}
