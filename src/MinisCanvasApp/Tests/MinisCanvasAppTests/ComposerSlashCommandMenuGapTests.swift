import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// Registry-derived expectations shared by the Composer slash suites.
///
/// D-COMMAND-02 forbids a second command vocabulary — including inside tests:
/// an expected slash list here would then have to be edited in lockstep with
/// the registry and would go falsely RED when the registry grows. Every
/// expectation below is read back from `CommandRegistry` itself, and no
/// assertion pins an absolute row count.
enum SlashRegistryExpectations {
    /// The canonical Composer vocabulary in registry declaration order,
    /// de-duplicated by ID exactly like the menu projector.
    static func canonicalComposerIDs() -> [String] {
        var seen = Set<String>()
        return CommandRegistry.composerCommandMetadata
            .map(\.id)
            .filter { seen.insert($0).inserted }
    }

    static func routedComposerRegistry() -> CommandRegistry {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        return registry
    }
}

// W4-SLASHMENU-036 RED suite.
//
// These tests pin the two real gaps against the baseline source tree:
//  1. COMPOSER-17/D-COMMAND-01: the Composer slash menu must cover the full
//     Phase 3 common-command vocabulary (D-COMPOSER-16 baseline covers only
//     the 5 canonical routed IDs).
//  2. COMPOSER-17: each row must expose its description and the session-state
//     tri-state (可用 / 阻断 / 需审批) so VoiceOver and screenshot audits can
//     read it, plus F09-style keyboard-selection identity binding.
// On baseline 7d2ba890 all three tests fail for real (missing coverage and a
// missing view-model file); they must pass once the menu side is supplied.
@Suite("Composer slash command menu gaps (W4-036)")
struct ComposerSlashCommandMenuGapTests {

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test @MainActor
    func ordinaryLongDraftDoesNotProjectSlashMenu1713() {
        let registry = SlashRegistryExpectations.routedComposerRegistry()
        let draft = String(repeating: "普通长草稿内容", count: 5_000)
        var contextKeyReads = 0
        var registryReads = 0
        let rows = GlobalComposer.slashMenuEntries(
            for: draft,
            dismissedContextKey: nil,
            contextKey: { contextKeyReads += 1; return "session\u{001F}\(draft)" },
            registry: { registryReads += 1; return registry },
            sessionState: { .neutral },
            canvasAvailable: { false }
        )
        #expect(rows.isEmpty)
        #expect(contextKeyReads == 0)
        #expect(registryReads == 0)
    }

    @Test @MainActor
    func unicodeLeadingWhitespaceSlashHonorsDismissal1713() {
        let registry = SlashRegistryExpectations.routedComposerRegistry()
        let draft = "\u{2003}\u{00A0}/help"
        let contextKey = "session\u{001F}\(draft)"
        func entries(dismissed: String?) -> [ComposerSlashMenuEntry] {
            GlobalComposer.slashMenuEntries(
                for: draft,
                dismissedContextKey: dismissed,
                contextKey: { contextKey },
                registry: { registry },
                sessionState: { .neutral },
                canvasAvailable: { false }
            )
        }
        #expect(entries(dismissed: nil).map(\.id) == ["help"])
        #expect(entries(dismissed: contextKey).isEmpty)
        #expect(entries(dismissed: "other-session\u{001F}\(draft)").map(\.id) == ["help"])
    }

    @Test func slashMenuCoversFullPhaseThreeSlashVocabulary() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let ids = GlobalComposer.slashSuggestions(for: "/", registry: registry).map(\.id)
        for id in SlashRegistryExpectations.canonicalComposerIDs() {
            #expect(ids.contains(id), "slash 菜单未覆盖注册表常用命令 /\(id)")
        }
    }

    @Test func slashMenuExposesPerCommandDescriptionAndTriState() throws {
        let menuSource = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Sources/MinisCanvasApp/ComposerSlashCommandMenu.swift"
            ),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )
        // Tri-state labels are produced by the pure view model…
        #expect(menuSource.contains("可用"))
        #expect(menuSource.contains("需审批"))
        #expect(menuSource.contains("阻断"))
        #expect(menuSource.contains("zhSummary"))
        // …and the menu row renders the state badge with a stable AX id.
        #expect(viewSource.contains("composer.slash.state."))
    }

    @Test func slashKeyboardSelectionBindsCommandIdentityWhileFiltering() throws {
        let viewSource = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Sources/MinisCanvasApp/GlobalComposerView.swift"
            ),
            encoding: .utf8
        )
        // F09 family: selection must survive list filtering without drifting
        // onto a different command at the same index.
        #expect(viewSource.contains("slashCompletionSelectedCommandID"))
    }
}

// Behavior coverage for the pure view model supplied with W4-036. These pin
// the tri-state resolution and identity binding directly, without AppKit.
@Suite("Composer slash command menu states (W4-036)")
struct ComposerSlashCommandMenuStateTests {

    private func routedRegistry() -> CommandRegistry {
        SlashRegistryExpectations.routedComposerRegistry()
    }

    @Test func routedRowsResolveTriStateFromRegistryAndSessionState() {
        // W5-050 retarget of the W5-041 WRITE_SET_ESCALATION (expectation-only).
        // On the W5-041 base only the 5 canonical IDs were registered, so stop/
        // approve reached the menu un-routed and rendered the fail-closed
        // "尚未接入 Composer 路由" reason. After 041 registers the full Phase 3
        // vocabulary, a *routed* registry resolves those rows through session
        // gating instead. BOTH the original display-only fail-closed invariant
        // and the new routed tri-state are pinned below — no assertion deleted,
        // no dispatch/approval gate relaxed (the non-dispatch check is added
        // strictly stronger).
        //
        // (1) Display-only fail-closed, unchanged semantics: a command that the
        // canonical pipeline cannot consume still renders 阻断 with the routing
        // reason (never silently disappears) and NEVER dispatches on accept.
        let unroutedRegistry = CommandRegistry()
        let unroutedEntries = ComposerSlashCommandMenu.entries(
            matching: "/", registry: unroutedRegistry)
        func unrouted(_ id: String) -> ComposerSlashMenuEntry {
            unroutedEntries.first { $0.id == id }!
        }
        for id in ["stop", "approve"] {
            #expect(unrouted(id).state == .blocked(reason: "尚未接入 Composer 路由"),
                    "未接入路由的 \(id) 仍必须显示阻断并给出理由")
            #expect(!unrouted(id).shouldSendOnAccept,
                    "未接入路由的 \(id) Return/点击绝不 dispatch")
        }

        // (2) Routed rows resolve tri-state from registry + neutral session state.
        let registry = routedRegistry()
        let entries = ComposerSlashCommandMenu.entries(matching: "/", registry: registry)
        func state(_ id: String) -> ComposerSlashCommandState {
            entries.first { $0.id == id }!.state
        }
        #expect(state("help") == .available)
        #expect(state("status") == .available)
        #expect(state("tasks") == .available)
        #expect(state("compact") == .requiresApproval)
        #expect(state("model") == .available) // N05 opens a picker; applying a selection keeps its own gate.
        // Registered under the neutral session: stop needs an in-flight
        // generation, approve needs a pending request, so both stay 阻断 — now
        // for their real session reason (approval semantics unchanged: approve
        // only leaves 阻断 for 需审批 once a request is pending, see
        // sessionGatingBlocksRowsWithoutLosingDiscoverability).
        #expect(state("stop") == .blocked(reason: "当前没有进行中的生成"))
        #expect(state("approve") == .blocked(reason: "当前没有待审批请求"))
    }

    @Test @MainActor func boundarySetMenuExplainsTheCanonicalSettingsPath() throws {
        let registry = routedRegistry()
        let entries = ComposerSlashCommandMenu.entries(matching: "/", registry: registry,
            sessionState: .init(unavailableReasonsByCommandID:
                GlobalComposer.missingExecutorReasons(registry: registry)))
        let boundary = try #require(entries.first { $0.id == "boundary.set" })
        #expect(boundary.state == .blocked(reason: "暂不可用，请在设置→智能体调整自主权上限。"))
        #expect(!boundary.shouldSendOnAccept)
        #expect(entries.first { $0.id == "compact" }?.state == .requiresApproval)
        #expect(entries.first { $0.id == "model" }?.state == .available)
    }

    @Test func sessionGatingBlocksRowsWithoutLosingDiscoverability() {
        // D-COMMAND-02: the rows below are projected from the routed registry
        // itself, so the session gating rules (not a hand-written App list and
        // not a missing MinisCore registration) decide the rendered state.
        let registry = routedRegistry()
        let vocabulary = ComposerSlashCommandMenu.descriptors(registry: registry)
        var session = ComposerSlashSessionState.neutral
        session.isStreaming = false
        session.hasPendingComposerCommand = false
        func state(_ id: String, in s: ComposerSlashSessionState) -> ComposerSlashCommandState {
            ComposerSlashCommandMenu.entry(
                for: vocabulary.first { $0.id == id }!,
                registry: registry,
                sessionState: s
            ).state
        }
        #expect(state("stop", in: session) == .blocked(reason: "当前没有进行中的生成"))
        #expect(state("approve", in: session) == .blocked(reason: "当前没有待审批请求"))
        #expect(state("reject", in: session) == .blocked(reason: "当前没有待审批请求"))
        var busy = session
        busy.isStreaming = true
        busy.hasPendingComposerCommand = true
        #expect(state("stop", in: busy) == .available)
        #expect(state("approve", in: busy) == .requiresApproval)
        #expect(state("reject", in: busy) == .available)
    }

    @Test func filterMatchesIDTitleAndLocalizedAliasWithStableOrder() {
        let registry = routedRegistry()
        #expect(ComposerSlashCommandMenu.entries(matching: "", registry: registry).isEmpty)
        #expect(ComposerSlashCommandMenu.entries(matching: "/co", registry: registry)
            .map(\.id) == ["commands", "copy", "compact", "context", "usage"])
        #expect(ComposerSlashCommandMenu.entries(matching: "/压", registry: registry)
            .map(\.id) == ["compact"])
        #expect(ComposerSlashCommandMenu.entries(matching: "/canvas.", registry: registry)
            .map(\.id) == ["canvas.run", "canvas.cancel", "canvas.minimap"])
    }

    @Test func selectionIdentitySurvivesNarrowing() {
        let registry = routedRegistry()
        let broad = ComposerSlashCommandMenu.entries(matching: "/c", registry: registry)
        #expect(ComposerSlashCommandMenu.selectedIndex(for: "compact", in: broad)
            == broad.map(\.id).firstIndex(of: "compact"))
        let narrow = ComposerSlashCommandMenu.entries(matching: "/comp", registry: registry)
        #expect(narrow.map(\.id) == ["compact"])
        #expect(ComposerSlashCommandMenu.selectedIndex(for: "compact", in: narrow) == 0)
        // When the bound command leaves the list the highlight falls back to
        // the first row instead of staying on whatever shares the index.
        #expect(ComposerSlashCommandMenu.selectedIndex(for: "compact", in: broad.filter {
            $0.id != "compact"
        }) == nil)
    }

    @Test func onlyDispatchableRowsMaySend() {
        let registry = routedRegistry()
        for entry in ComposerSlashCommandMenu.entries(matching: "/", registry: registry) {
            switch entry.state {
            case .available, .requiresApproval:
                // A live row with required arguments completes for editing;
                // dispatch needs the exact typed argument payload.
                let requiresInput = entry.routedCommand?.argumentSpecs.contains(where: \.required) == true
                #expect(entry.shouldSendOnAccept == (entry.isRouted && !requiresInput))
            case .blocked:
                #expect(!entry.shouldSendOnAccept)
            }
        }
    }

    @Test func menuBoundaryRejectsSendForBlockedRows() throws {
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/MinisCanvasApp/GlobalComposerView.swift"
                ),
            encoding: .utf8
        )
        #expect(viewSource.contains("if case .returnKey = key, accepted.shouldSend"))
        #expect(viewSource.contains("if accepted.shouldSend"))
    }
}

// MARK: - D-COMMAND-02 (DEV-284) — the slash vocabulary is generated by the
// canonical command registry.
//
// Before this delta the menu owned a hand-written `phaseThreeCatalog` literal
// that restated title / aliases / risk / argument summaries for every command,
// i.e. a second static command source next to `CommandRegistry` (routing alone
// was registry-backed). The suite below pins the closed gap the way the
// requirement is written: expectations are read back from the registry, every
// registry command has an enumerable row, every row has a registry origin, and
// per-row metadata is compared field by field. No assertion pins an absolute
// vocabulary size, so growing the registry (D-COMMAND-01) keeps this suite
// meaningful instead of turning it into a false RED.

@Suite("Composer slash vocabulary is registry-derived (D-COMMAND-02)")
struct ComposerSlashVocabularyDerivationTests {

    private static let menuSourceURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Sources/MinisCanvasApp/ComposerSlashCommandMenu.swift"
        )

    private func routedRegistry() -> CommandRegistry {
        SlashRegistryExpectations.routedComposerRegistry()
    }

    private func vocabularyRows(
        in registry: CommandRegistry,
        session: ComposerSlashSessionState = .neutral
    ) -> [ComposerSlashMenuEntry] {
        ComposerSlashCommandMenu.entries(
            matching: "/",
            registry: registry,
            sessionState: session
        )
    }

    private func rowsByID(
        _ rows: [ComposerSlashMenuEntry]
    ) -> [String: ComposerSlashMenuEntry] {
        var map: [String: ComposerSlashMenuEntry] = [:]
        for row in rows { map[row.id] = row }
        return map
    }

    @Test func enumerableRowsAreTheRegistryVocabularyInRegistryOrder() {
        let expected = SlashRegistryExpectations.canonicalComposerIDs()
        let registry = routedRegistry()
        #expect(vocabularyRows(in: registry).map(\.id) == expected)
        #expect(ComposerSlashCommandMenu.descriptors(registry: registry).map(\.id) == expected)
        // Adaptive equivalence (row count follows the registry), never a literal.
        #expect(vocabularyRows(in: registry).count == expected.count)
    }

    @Test func perRowDisplayMetadataEqualsTheRegistryDeclaration() {
        let registry = routedRegistry()
        let rows = rowsByID(vocabularyRows(in: registry))
        for metadata in CommandRegistry.composerCommandMetadata {
            guard let row = rows[metadata.id] else {
                Issue.record("注册表命令 /\(metadata.id) 没有对应的可枚举行")
                continue
            }
            let descriptor = row.descriptor
            #expect(descriptor.id == metadata.id)
            #expect(descriptor.zhTitle == metadata.zhTitle)
            #expect(descriptor.enTitle == metadata.enTitle)
            #expect(descriptor.zhSummary == metadata.zhSummary)
            #expect(descriptor.enSummary == metadata.enSummary)
            #expect(descriptor.category == metadata.category)
            #expect(descriptor.risk == ComposerSlashCommandRisk(metadata.risk))
            #expect(descriptor.requiresPolicyApproval == metadata.requiresPolicyApproval)
            #expect(descriptor.argumentSummary == metadata.parameterSummary)
        }
    }

    @Test func everyRowAliasResolvesThroughTheRegistryToItsOwnCommand() {
        let registry = routedRegistry()
        for metadata in CommandRegistry.composerCommandMetadata {
            for alias in metadata.aliases where alias != metadata.id {
                #expect(registry.command(id: alias)?.id == metadata.id,
                        "别名 \(alias) 在注册表中并不解析到 /\(metadata.id)")
            }
        }
        let rows = rowsByID(vocabularyRows(in: registry))
        for metadata in CommandRegistry.composerCommandMetadata {
            guard let row = rows[metadata.id] else { continue }
            #expect(Set(row.descriptor.aliases) == Set(metadata.aliases),
                    "/\(metadata.id) 的 slash 别名与注册表别名不一致")
        }
    }

    @Test func menuContainsNoGhostRowWithoutRegistryOrigin() {
        for registry in [routedRegistry(), CommandRegistry()] {
            for row in vocabularyRows(in: registry) {
                #expect(CommandRegistry.composerCommandIDs.contains(row.id),
                        "幽灵 slash 行 \(row.id) 没有注册表来源")
                #expect(CommandRegistry.composerMetadata(for: row.id)?.id == row.id)
            }
        }
    }

    @Test func unroutedVocabularyStaysDiscoverableAndNeverDispatches() {
        let rows = vocabularyRows(in: CommandRegistry())
        #expect(rows.map(\.id) == SlashRegistryExpectations.canonicalComposerIDs())
        for row in rows {
            #expect(!row.isRouted)
            #expect(row.state == .blocked(reason: "尚未接入 Composer 路由"))
            #expect(!row.shouldSendOnAccept)
        }
    }

    @Test func routingPresenceIsResolvedAgainstTheInjectedRegistryOnEachRender() {
        // The instance — not an App-side list — decides whether a vocabulary row
        // can dispatch: registering the ID flips it off the fail-closed reason.
        let registry = CommandRegistry()
        let before = ComposerSlashCommandMenu.entries(matching: "/help", registry: registry)
        #expect(before.map(\.state) == [.blocked(reason: "尚未接入 Composer 路由")])
        guard let helpDescriptor = ComposerSlashCommandMenu
            .descriptors(registry: registry)
            .first(where: { $0.id == "help" }) else {
            Issue.record("注册表声明的 /help 未投影为菜单行")
            return
        }
        registry.register(helpDescriptor.menuCommand)
        let after = ComposerSlashCommandMenu.entries(matching: "/help", registry: registry)
        #expect(after.map(\.id) == ["help"])
        #expect(after.first?.isRouted == true)
        #expect(after.first?.state == .available)
    }

    @Test func approvalGatingFollowsTheRegistryDeclaration() {
        var busy = ComposerSlashSessionState.neutral
        busy.isStreaming = true
        busy.hasPendingComposerCommand = true
        let registry = routedRegistry()
        let rows = rowsByID(vocabularyRows(in: registry, session: busy))
        #expect(rows.count == SlashRegistryExpectations.canonicalComposerIDs().count)
        for metadata in CommandRegistry.composerCommandMetadata {
            let state = rows[metadata.id]?.state
            if metadata.requiresPolicyApproval {
                #expect(state == .requiresApproval,
                        "/\(metadata.id) 的审批态未由注册表投影")
            } else {
                #expect(state == .available, "/\(metadata.id) 应为可用")
            }
        }
    }

    @Test func sessionGatesAreOnlyAppSideStateAndCarryNoVocabulary() {
        // The App keeps exactly the gates the registry cannot express (ChatStore
        // state); every other ID has no gate and cannot gain or lose a row.
        let registry = routedRegistry()
        let routed = vocabularyRows(in: registry)
        let idle = vocabularyRows(
            in: registry,
            session: ComposerSlashSessionState(isStreaming: false, hasPendingComposerCommand: false)
        )
        #expect(routed.map(\.id) == SlashRegistryExpectations.canonicalComposerIDs())
        #expect(idle.map(\.id) == routed.map(\.id))
        var idleState = ComposerSlashSessionState.neutral
        idleState.isStreaming = false
        idleState.hasPendingComposerCommand = false
        // Gated IDs explain why they are blocked while idle; ungated registry
        // IDs never produce a gate reason.
        #expect(ComposerSlashCommandMenu.sessionGate(for: "stop")(idleState)
                == "当前没有进行中的生成")
        #expect(ComposerSlashCommandMenu.sessionGate(for: "approve")(idleState)
                == "当前没有待审批请求")
        #expect(ComposerSlashCommandMenu.sessionGate(for: "reject")(idleState)
                == "当前没有待审批请求")
        #expect(ComposerSlashCommandMenu.sessionGate(for: "help")(idleState) == nil)
        #expect(ComposerSlashCommandMenu.sessionGate(for: "not.a.command")(idleState) == nil)
        // The idle gating is what turns those rows into 阻断 for their real
        // session reason, while the rest stay dispatchable.
        let idleByID = rowsByID(idle)
        #expect(idleByID["stop"]?.state == .blocked(reason: "当前没有进行中的生成"))
        #expect(idleByID["help"]?.state == .available)
    }

    @Test func menuFileKeepsNoHandWrittenCommandVocabulary() throws {
        let source = try String(contentsOf: Self.menuSourceURL, encoding: .utf8)
        // The projector reads the registry; the old literal catalog is gone.
        #expect(source.contains("CommandRegistry.composerCommandMetadata"))
        #expect(source.contains("descriptors(registry: registry)"))
        #expect(!source.contains("phaseThreeCatalog"))
        // No restated command identity, title, argument summary or risk literal:
        // the only literals left in this file are the three ChatStore gates.
        #expect(!source.contains("zhTitle: \""))
        #expect(!source.contains("argumentSummary: \""))
        #expect(!source.contains("id: \""))
        #expect(!source.contains("\"canvas.minimap\""))
        #expect(!source.contains("\"memory.propose\""))
        #expect(!source.contains("\"provider.use\""))
        #expect(!source.contains("\"boundary.set\""))
    }
}
