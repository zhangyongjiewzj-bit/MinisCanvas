import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// P3-SET-01 · lane 148 (QODER-DEV-W10-SET-01-DESCRIPTOR-ORPHAN-GATE-148):
// descriptor orphan/consistency gate.
//
// The single source of descriptor truth stays `SettingsStateClassification.
// descriptors` (hard-excluded from this lane's write set). This gate adds the
// missing ENFORCEMENT, not a second table:
//   1. It enumerates the real UI bindings (`center.<name> = ...` assignments)
//      by scanning the app sources at test time — no copied list.
//   2. A binding must either resolve to a canonical descriptor (exact
//      `settingsKey`, the trailing segment of one, or a name the descriptor
//      declares in its `uiBindings` proxy list — lane 155), or be tolerated
//      explicitly-by-name in the frozen allow-list below with a written
//      reason.
//   3. The allow-list cannot silence the gate: entries that no longer match a
//      real binding, or that became described, fail the suite (anti-rot), and
//      every entry must carry a non-trivial reason.
//   4. Described rows must surface in the app's own applied-state projection
//      (a descriptor whose key never reaches `settingsAppliedStateProjection`
//      is a declared consumer it does not have).
//
// Where a binding's runtime semantics were not adjudicated, this lane did NOT
// invent a description, did NOT mark anything live, and did NOT delete a UI
// control: the binding sits in the allow-list and needs a product ruling
// (see receipt). Nothing in this file was compiled or executed at authoring
// time; execution belongs to the next PKG intake round.

private enum OrphanGateSources {
    /// Probes upward from the compile-time test-file location for the app
    /// sources directory, so the gate scans the same tree it was built from.
    static func appSourcesDirectory(filePath: String) throws -> URL {
        var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = url
                .appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        throw OrphanGateError.missingSourcesDirectory(filePath)
    }

    static func swiftFiles(in directory: URL) throws -> [URL] {
        var found: [URL] = []
        for item in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                found += try swiftFiles(in: item)
            } else if item.pathExtension == "swift" {
                found.append(item)
            }
        }
        return found
    }
}

private enum OrphanGateError: Error {
    case missingSourcesDirectory(String)
    case unreadableFile(String)
}

/// Function bodies whose `center` parameter has an explicit owner. Only a
/// proven non-SettingsCenter owner can be excluded below. An untyped binding
/// or a local rebinding stays in the gate so a new setting cannot disappear.
private func typedCenterFunctionBodies(in source: String) throws -> [(range: NSRange, owner: String)] {
    let function = try #require(try? NSRegularExpression(
        pattern: #"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^{}]*\bcenter\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\b[^{}]*\)[^{]*\{"#
    ))
    let text = source as NSString
    var bodies: [(range: NSRange, owner: String)] = []
    for match in function.matches(in: source, range: NSRange(location: 0, length: text.length)) {
        let owner = text.substring(with: match.range(at: 1))
        let open = NSMaxRange(match.range) - 1
        var cursor = open + 1
        var depth = 1
        while cursor < text.length && depth > 0 {
            switch text.character(at: cursor) {
            case 123: depth += 1 // {
            case 125: depth -= 1 // }
            default: break
            }
            cursor += 1
        }
        // An ambiguous or malformed source remains fail-closed: no exclusion.
        if depth == 0 {
            bodies.append((NSRange(location: open, length: cursor - open), owner))
        }
    }
    return bodies
}

/// Real `center.<name> = ` assignments in the app sources. Requires a
/// single `=` (never `==`/`>=`/`!=`); compound forms like `+=` are a known
/// limitation and would surface as orphans, which is the safe direction.
private func extractedUIBindings(in sources: URL) throws -> Set<String> {
    let pattern = try #require(
        try? NSRegularExpression(pattern: #"\bcenter\.([A-Za-z][A-Za-z0-9]*)[ \t]*=[ \t]*[^=]"#)
    )
    let notificationCenterDeclaration = try NSRegularExpression(
        pattern: #"\blet\s+center\s*=\s*UNUserNotificationCenter\.current\(\)"#
    )
    var names: Set<String> = []
    for file in try OrphanGateSources.swiftFiles(in: sources) {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw OrphanGateError.unreadableFile(file.path)
        }
        let range = NSRange(text.startIndex..., in: text)
        let typedBodies = try typedCenterFunctionBodies(in: text)
        for match in pattern.matches(in: text, range: range) {
            // A native notification-center local is not SettingsCenter. Its
            // lexical scope must still contain this assignment, with no local
            // rebinding; unknown receivers remain gated as before.
            let preceding = (text as NSString).substring(to: match.range.location)
            if let declaration = notificationCenterDeclaration.matches(in: preceding,
                range: NSRange(location: 0, length: (preceding as NSString).length)).last {
                let tail = (preceding as NSString).substring(from: NSMaxRange(declaration.range))
                var depth = 0
                var sameScope = true
                for character in tail {
                    if character == "{" { depth += 1 }
                    else if character == "}" {
                        if depth == 0 { sameScope = false; break }
                        depth -= 1
                    }
                }
                if sameScope, tail.range(of: #"\b(?:let|var)\s+center\b|\{\s*center\s+in\b"#,
                    options: .regularExpression) == nil { continue }
            }
            if let explicitOwner = typedBodies
                .filter({ NSLocationInRange(match.range.location, $0.range) })
                .min(by: { $0.range.length < $1.range.length }),
               explicitOwner.owner != "SettingsCenter" {
                let preceding = (text as NSString).substring(with: NSRange(
                    location: explicitOwner.range.location,
                    length: match.range.location - explicitOwner.range.location
                ))
                let localRebinding = preceding.range(
                    of: #"\b(?:let|var)\s+center\b|\{\s*center\s+in\b"#,
                    options: .regularExpression
                ) != nil
                if !localRebinding { continue }
            }
            if let captured = Range(match.range(at: 1), in: text) {
                names.insert(String(text[captured]))
            }
        }
    }
    return names
}

/// Binding names the descriptor matrix already describes: an exact canonical
/// `settingsKey`, the trailing segment of one (the matrix's documented
/// binding-proxy form, e.g. `general.themePreset` ↔ `center.themePreset`),
/// or a name the descriptor explicitly declares in `uiBindings` (lane 155:
/// a UI proxy whose persisted field name differs, e.g. `privacyLogLevel` /
/// `liveLogLevel` → `privacy.logLevel`).
private func describedBindingNames() -> Set<String> {
    var names: Set<String> = []
    for descriptor in SettingsStateClassification.descriptors(for: .canonicalSetting) {
        if let key = descriptor.settingsKey {
            names.insert(key)
            if let last = key.split(separator: ".").last {
                names.insert(String(last))
            }
        }
        names.formUnion(descriptor.uiBindings)
    }
    return names
}

/// Frozen, explicit-by-name tolerance list. Lane 148 froze 36 tolerance
/// entries at head 11dc4510. Lane 155 (P3-SET-01 descriptor coverage)
/// adjudicated every one of them: 34 now bind to a canonical descriptor —
/// via a new binding-granularity row (agent/general/privacy/storage/
/// typography domains), via `uiBindings` proxies on the existing `browser`
/// and `__miniscanvas.safetyControl` aggregate rows, or via the renamed-
/// field proxies `browserViewportMode`/`terminalPolicySettings`/
/// `privacyLogLevel`/`liveLogLevel`. Those 34 entries were deleted here
/// (the anti-rot test below forbids keeping them). Only structural
/// non-persistent bindings remain tolerated; `lastImportCount` is a
/// drift orphan that appeared between lane 148's authoring head and
/// 23cf25e — its tolerance entry landed first via lane 165 at head
/// 23dbb39f and is kept here verbatim (lane 155's duplicate variant was
/// dropped in this re-anchor to avoid a repeated dictionary key).
private let frozenAllowList148: [String: String] = [
    "pendingMemorySearchQuery": "transient chat-to-memory-page search handoff; editing the query or dismissing Settings clears it, and it is never serialized as a setting",
    // Deliberately not a persistent state today.
    "childConcurrencyRiskAcknowledged": "session-scoped non-persisted acknowledgement gate (never written to settings.json); outside the persistent-state matrix by design — lane 155 ruling (P3-SET-01)",
    // Pattern artifact: dependency-injection wiring, not a settings binding.
    "bl6CredentialResolver": "SettingsCenter closure property wired by ChatCredentialBroker.attach (composition injection), matched by the generic center.<name> = pattern; not a settings binding (P3-SET-01 lane 148, kept by lane 155)",
    // Pattern artifact: runtime import counter, not a user-settable setting.
    "lastImportCount": "non-persisted runtime counter on SettingsCenter (declared SettingsCenter.swift:755, 'recent import hit count for UI hint'); written only by SettingsCenter.importFromProcessEnvironment (SettingsCenter.swift:2795, function-internal, not scan-matched) and the env-import preview sheet callback center.lastImportCount = imported (SettingsView.swift:3264, result of an apply action, not a user input binding); no read sites in product sources and no persistence-key/descriptor entry (grep at this base finds only SettingsCenter.swift:755/2795 and SettingsView.swift:3264 plus one test consumer), never serialized to settings.json; not a user-writable setting binding (P3-SET-01 lane 165)",
]

@Suite("P3-SET-01 descriptor orphan gate 148")
struct SettingsDescriptorOrphanGate148Tests {

    @Test("typed non-settings center is excluded while settings and ambiguous bindings stay gated")
    func sourceScanUsesCenterOwnerWithoutHidingUnknownSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01OwnerScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        func bindCommand(center: ComposerCommandAdjudicationCenter) {
            center.prepareWorkflow = {}
            center.applyApprovedWorkflow = {}
            let center: SettingsCenter = makeSettingsCenter()
            center.newUnknownSetting = 4
        }
        func bindSettings(center: SettingsCenter) {
            center.themePreset = .dark
            center.anotherUnknownSetting = 5
        }
        func bindAmbiguous() {
            center.untypedUnknownSetting = 6
        }
        """
        try source.write(to: root.appendingPathComponent("OwnerProbe.swift"),
                         atomically: true, encoding: .utf8)

        let bindings = try extractedUIBindings(in: root)
        #expect(bindings == ["newUnknownSetting", "themePreset",
                             "anotherUnknownSetting", "untypedUnknownSetting"])
        let orphans = bindings.subtracting(describedBindingNames())
            .subtracting(frozenAllowList148.keys)
        #expect(orphans.contains("newUnknownSetting"))
        #expect(orphans.contains("anotherUnknownSetting"))
        #expect(orphans.contains("untypedUnknownSetting"))
    }

    @Test
    func sourcesRootResolvesAndBindingsAreFound() throws {
        let sources = try OrphanGateSources.appSourcesDirectory(filePath: #filePath)
        let bindings = try extractedUIBindings(in: sources)
        // The settings surface must always contribute bindings; an empty or
        // vanished scan means the gate itself broke, not that the repo healed.
        #expect(!bindings.isEmpty, "orphan gate scan found no center.<name> = bindings")
        for anchor in ["themePreset", "memoryLimitMB", "childConcurrencyUserSelected"] {
            #expect(bindings.contains(anchor), "scan regressed: lost known binding \(anchor)")
        }
    }

    @Test
    func everyWritableBindingIsDescribedOrExplicitlyTolerated() throws {
        let sources = try OrphanGateSources.appSourcesDirectory(filePath: #filePath)
        let bindings = try extractedUIBindings(in: sources)
        let described = describedBindingNames()
        let orphans = bindings.subtracting(described).subtracting(frozenAllowList148.keys)
        #expect(
            orphans.isEmpty,
            "P3-SET-01 orphan: UI-writable bindings without a descriptor or an explicit frozen tolerance: \(orphans.sorted())"
        )
    }

    @Test
    func frozenAllowListCannotSilenceAndCannotRot() throws {
        let sources = try OrphanGateSources.appSourcesDirectory(filePath: #filePath)
        let bindings = try extractedUIBindings(in: sources)
        let described = describedBindingNames()
        for (name, reason) in frozenAllowList148 {
            // Anti-rot: every tolerated name must still be a real binding…
            #expect(
                bindings.contains(name),
                "stale orphan-gate tolerance: '\(name)' is no longer an extracted UI binding; remove it from the frozen allow-list"
            )
            // …and must NOT already be described (once a descriptor exists,
            // the tolerance must be deleted, forcing a visible reconciliation).
            #expect(
                !described.contains(name),
                "obsolete orphan-gate tolerance: '\(name)' now resolves to a canonical descriptor; delete it from the frozen allow-list"
            )
            // Silence guard: a tolerance is only valid with a written reason.
            #expect(
                reason.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20,
                "orphan-gate tolerance '\(name)' lacks a real reason"
            )
        }
    }

    @Test
    func coveredBindingsResolveToCanonicalDescriptors() throws {
        let sources = try OrphanGateSources.appSourcesDirectory(filePath: #filePath)
        let bindings = try extractedUIBindings(in: sources)
        let described = bindings.intersection(describedBindingNames())
        // Lane 155 (P3-SET-01 coverage ruling) closed 34 of the 36 lane-148
        // tolerances into canonical descriptors; with the three pre-existing
        // bindings this is the full described surface at head 23cf25e+155.
        // A drift here is a matrix change the next intake must review, so it
        // fails closed in BOTH directions.
        // 11/18：隐私页两个未启用的开关（collectAnalytics、redactEnvValues）从界面移除，不再是界面绑定。
        #expect(
            described == [
                "allowLocalAgentSessionRead", "appearance", "approvalPolicy", "autoCompactThreshold", "autoDeleteOldSessions",
                "availableModelWhitelist", "backgroundAutoContinueEnabled", "browserViewportMode", "browserWriteEnabled", "chatOutputMode",
                "childConcurrencyEnabledSessionCount", "childConcurrencyUserSelected", "childDeletionAutoReviewEnabled",
                "childModelOverridesEnabled", "childModelThinkingLevelCeiling",
                "childMutationsEnabled",
                "composerPolicy",
                "concurrentToolLimit", "contextLengthTokens", "customUserAgent", "customViewportHeight",
                "customViewportWidth", "defaultModelID", "defaultProviderID",
                "expirationInterval", "fallbackEnabled", "fileCheckpointsEnabled", "historyTurnLimit", "idleTabTimeoutMinutes", "killSwitchEnabled",
                "language", "liveLogLevel", "maxLoopIterations", "maxTokensPerSession", "tokenBudgetUnlimited", "loopIterationsUnlimited", "memoryEnabled", "globalInstructionsEnabled",
                "memoryLimitMB", "modelSpeedTier", "newMessageInterruptsGeneration",
                "persona", "personaEnabled", "privacyLogLevel",
                "safeModeEnabled", "sessionRetentionDays", "subModelID",
                "stripModelShellCredentials", "modelShellNoninteractive",
                "terminalPolicySettings", "themePreset", "shellCommandTimeoutSeconds",
                "toolsDisabled", "uiBaseFontSize", "userAgentPreset"
            ],
            "P3-SET-01: described-binding set drifted at this head: \(described.sorted())"
        )
        for name in described {
            let matches = SettingsStateClassification.descriptors(for: .canonicalSetting).filter {
                $0.settingsKey == name
                    || $0.settingsKey?.split(separator: ".").last.map(String.init) == name
                    || $0.uiBindings.contains(name)
            }
            #expect(!matches.isEmpty, "described binding '\(name)' no longer resolves to a canonical descriptor")
        }
    }

    /// Consistency half of the gate: every canonical descriptor key must
    /// reach the app's own applied-state projection. A row that declares a
    /// consumer/effective source but never surfaces there is a descriptor
    /// claiming a consumer it does not have.
    @Test
    @MainActor
    func everyCanonicalDescriptorSurfacesInAppliedStateProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3SET01OrphanGate148-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
        let projection = center.settingsAppliedStateProjection
        let keys = Set(SettingsStateClassification.descriptors(for: .canonicalSetting).compactMap(\.settingsKey))
        let surfaced = Set(projection.liveAppliedSettingKeys).union(projection.restartRequiredSettingKeys)
        #expect(surfaced == keys, "applied-state projection diverges from the canonical descriptor keys")
        #expect(
            Set(projection.liveAppliedSettingKeys).isDisjoint(with: projection.restartRequiredSettingKeys),
            "a descriptor cannot be both live-applied and restart-required"
        )
    }
}
