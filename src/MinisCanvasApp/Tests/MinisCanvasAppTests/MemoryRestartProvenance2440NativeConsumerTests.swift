import AppKit
import ApplicationServices
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("D-MEMORY-12 restarted Settings provenance and effective state", .serialized)
@MainActor
struct MemoryRestartProvenance2440NativeConsumerTests {
    private let scope = MemoryScope(sessionID: "memory12-session", projectID: "memory12-project")
    private let source = SettingsCenter.BuiltInMemoryCandidateSource.composerCommand
    private let factText = "orbit2440 approved synthetic memory"
    private let sourceRef = "synthetic://memory12/owned-origin"

    @Test("a fresh Center reloads approved origin and revoked source into the native Settings consumer")
    func reopenedFactsAndRevocationReachSettings() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory12-restart2440", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let defaults = profile.makeUserDefaults()
        let origin = MemoryWriteProvenanceInput(
            actorID: "synthetic-actor2440", runID: "synthetic-run2440",
            triggerID: "synthetic-trigger2440", sourceID: source.rawValue)
        weak var oldCenter: SettingsCenter?
        weak var oldStore: MemoryStore?

        // The first Center owns the real proposal/approval/revocation writers.
        // No recovered view model value is copied into the next instance.
        let before: (MemoryFact, UInt64) = try {
            let writer = makeCenter(profile)
            oldCenter = writer
            oldStore = writer.memoryStore
            writer.memoryScopeProvider = { scope }
            _ = try writer.provisionBuiltInMemoryCandidateSubmissions()
            let proposed = try writer.memoryProposalConsumer.submit(
                proposalID: "memory12-approved2440", text: factText,
                within: scope, sourceRef: sourceRef,
                sourceID: source.rawValue, writeProvenance: origin)
            try writer.approveDisplayedMemoryProposal(proposed)
            let fact = try #require(writer.memoryFacts.first { $0.text == factText })
            #expect(fact.writeProvenance?.actorID == origin.actorID)
            #expect(fact.writeProvenance?.runID == origin.runID)
            #expect(fact.writeProvenance?.triggerID == origin.triggerID)
            _ = try writer.memoryProposalConsumer.submit(
                proposalID: "memory12-pending2440", text: "orbit2440 pending must stay inactive",
                within: scope, sourceID: source.rawValue, writeProvenance: origin)
            let revoked = try writer.setMemoryCandidateSubmission(for: source, enabled: false)
            #expect(!revoked.canSubmit)
            return (fact, revoked.epoch)
        }()
        #expect(oldCenter == nil)
        #expect(oldStore == nil)

        let reopened = makeCenter(profile)
        reopened.memoryScopeProvider = { scope }
        _ = try reopened.provisionBuiltInMemoryCandidateSubmissions()
        reopened.reloadStorage()
        let fact = try #require(reopened.memoryFacts.first { $0.id == before.0.id })
        #expect(reopened.memoryFacts == [before.0])
        #expect(fact.lifecycleState == .active)
        #expect(fact.sourceProposalID == "memory12-approved2440")
        #expect(fact.sourceRef == sourceRef)
        #expect(fact.createdAt == before.0.createdAt)
        #expect(fact.memoryScope == scope)
        #expect(fact.writeProvenance?.actorID == origin.actorID)
        #expect(fact.writeProvenance?.runID == origin.runID)
        #expect(fact.writeProvenance?.triggerID == origin.triggerID)
        #expect(fact.writeProvenance?.sourceID == source.rawValue)
        #expect(try reopened.memoryCandidateSubmissionEnabled(for: source) == false)
        let authorization = try #require(reopened.memoryProposalConsumer
            .candidateSubmissionAuthorizations().first { $0.sourceID == source.rawValue })
        #expect(authorization.epoch == before.1)
        #expect(!authorization.canSubmit)
        #expect(try reopened.memoryProposalConsumer.envelopes().first {
            $0.proposal.proposalID == "memory12-pending2440"
        }?.state == .revoked)
        #expect(try reopened.pendingMemoryProposals().isEmpty)
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try reopened.memoryProposalConsumer.submit(
                text: "orbit2440 new submission denied after restart",
                within: scope, sourceID: source.rawValue, writeProvenance: origin)
        }
        let display = try MemorySearchDisplayConsumer(
            search: MemorySearch(store: reopened.memoryStore)
        ).retrieve(keyword: "orbit2440", scope: .session(scope))
        let item = try #require(display.items.first)
        #expect(display.items.map(\.factID) == [fact.id])
        #expect(item.sourceDescription == sourceRef)
        #expect(item.createdAt == fact.createdAt)
        #expect(item.recallExplanation.contains("命中 1 个检索词"))

        let window = host(center: reopened, defaults: defaults, profile: profile)
        defer { close(window) }
        let memoryTab = try node("settings-tab-memory", in: window)
        try #require(NativeConsumerOwnedAX.press(memoryTab))
        let sourceToggle = try node(
            "settings.memory.candidate-source.\(source.rawValue)", in: window)
        let toggleValue = NativeConsumerOwnedAX.attribute(
            sourceToggle, kAXValueAttribute as CFString) as? NSNumber
        #expect(toggleValue?.boolValue == false)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(
            in: window, prefix: "settings.memory.approve-proposal") == true)

        let field = try node("settings.memory.search", in: window)
        let axField = try #require(NativeConsumerOwnedAX.element(field))
        try #require(AXUIElementSetAttributeValue(
            axField, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success)
        let fieldFocused = NativeConsumerOwnedAX.attribute(field, kAXFocusedAttribute as CFString) as? NSNumber
        try #require(fieldFocused?.boolValue == true)
        let focusedEditor = try #require(window.firstResponder as? NSTextView)
        try #require(focusedEditor.isFieldEditor && focusedEditor.window === window)
        let nativeField = try #require(focusedEditor.delegate as? NSTextField)
        try #require(nativeField.window === window && nativeField.currentEditor() === focusedEditor)
        try #require(window.makeFirstResponder(nativeField))
        nativeField.selectText(nil)
        let editor = try #require(nativeField.currentEditor() as? NSTextView)
        try #require(editor === focusedEditor)
        editor.insertText("orbit2440", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try #require(window.makeFirstResponder(nil))
        let submit = try node("settings.memory.search.submit", in: window)
        _ = try #require(NativeConsumerOwnedAX.find(
            in: window, identifier: "settings.memory.search.clear"),
            "confirmed edit must reach the real nonempty search binding")
        try #require(NativeConsumerOwnedAX.enabled(submit) == true,
                     "confirmed edit must enable the actual search button")
        try #require(NativeConsumerOwnedAX.press(submit))
        let result = try node("settings.memory.search.result.\(fact.id)", in: window)
        #expect((NativeConsumerOwnedAX.attribute(result, kAXValueAttribute as CFString) as? String)?
            .contains("命中 1 个检索词") == true)
        let visible = try ownedTexts(in: window)
        #expect(visible.contains("\(sourceRef) · \(item.createdAtLabel) · 修订 \(fact.revision)"))
        #expect(visible.contains(where: { $0.contains("orbit2440 pending must stay inactive") }) == false)
    }

    @Test("single displayed refusal persists across reopen without touching facts or neighboring proposals")
    func singleRefusalPersistsWithoutFactOrNeighborEffects() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory-single-refusal", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let center = makeCenter(profile)
        center.memoryScopeProvider = { scope }
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        let existing = try center.memoryProposalConsumer.submit(
            proposalID: "refusal-existing", text: "owned existing fact", within: scope,
            sourceID: source.rawValue)
        try center.approveDisplayedMemoryProposal(existing)
        let rejected = try center.memoryProposalConsumer.submit(
            proposalID: "refusal-target", text: "owned rejected candidate", within: scope,
            sourceID: source.rawValue)
        let neighbor = try center.memoryProposalConsumer.submit(
            proposalID: "refusal-neighbor", text: "owned pending neighbor", within: scope,
            sourceID: source.rawValue)
        let foreign = try center.memoryProposalConsumer.submit(
            proposalID: "refusal-foreign", text: "owned foreign candidate",
            within: MemoryScope(sessionID: "other-session", projectID: "other-project"),
            sourceID: source.rawValue)
        let before = try center.memoryStore.facts()
        try center.rejectDisplayedMemoryProposal(rejected)
        #expect(try center.memoryStore.facts() == before)
        #expect(try center.pendingMemoryProposals() == [neighbor])
        #expect(try center.memoryProposalConsumer.envelopes().first {
            $0.proposal.proposalID == foreign.proposal.proposalID
        } == foreign)

        let reopened = makeCenter(profile)
        reopened.memoryScopeProvider = { scope }
        #expect(try reopened.memoryStore.facts() == before)
        #expect(try reopened.pendingMemoryProposals() == [neighbor])
        let reopenedRecords = try reopened.memoryProposalConsumer.envelopes()
        let settled = try #require(reopenedRecords.first {
            $0.proposal.proposalID == rejected.proposal.proposalID
        })
        #expect(settled.state == .rejected && settled.approvalReceipt == nil)
        #expect(throws: MemoryProposalConsumerError.invalidState(.rejected)) {
            try reopened.approveDisplayedMemoryProposal(settled)
        }
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try reopened.rejectDisplayedMemoryProposal(rejected)
        }
        try reopened.approveDisplayedMemoryProposal(neighbor)
        #expect(try reopened.memoryStore.facts().map(\.text).sorted()
            == ["owned existing fact", "owned pending neighbor"].sorted())
    }

    @Test("single refusal rejects a stale display, a foreign scope and a revoked source without fact effects")
    func singleRefusalKeepsDisplayScopeAndSourceFences() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "memory-refusal-fences", canvasRuntimeState: .disabled)
        defer { try? profile.cleanupDisposableRoots() }
        let center = makeCenter(profile)
        center.memoryScopeProvider = { scope }
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        let proposed = try center.memoryProposalConsumer.submit(
            proposalID: "refusal-bound", text: "owned bound candidate", within: scope,
            sourceID: source.rawValue)
        var stale = proposed
        stale.approvalReason = "owned changed display"
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try center.rejectDisplayedMemoryProposal(stale)
        }
        center.memoryScopeProvider = {
            MemoryScope(sessionID: "other-session", projectID: "other-project")
        }
        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            try center.rejectDisplayedMemoryProposal(proposed)
        }
        center.memoryScopeProvider = { scope }
        #expect(try center.pendingMemoryProposals() == [proposed])
        _ = try center.setMemoryCandidateSubmission(for: source, enabled: false)
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try center.rejectDisplayedMemoryProposal(proposed)
        }
        let records = try center.memoryProposalConsumer.envelopes()
        #expect(records.count == 1)
        let settled = try #require(records.first)
        #expect(settled.state == .revoked)
        #expect(try center.memoryStore.facts().isEmpty)
    }

    private func makeCenter(_ profile: RuntimeIsolationProfile) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")))
    }

    private func host(center: SettingsCenter, defaults: UserDefaults,
                      profile: RuntimeIsolationProfile) -> NSWindow {
        let controller = NSHostingController(rootView: AnyView(SettingsView(
            center: center,
            shortcutStore: ShortcutStore(defaults: defaults),
            skillsStore: SkillsStore(
                appStore: center.skillStore,
                stateFileURL: profile.rootDirectory.appendingPathComponent("skills-state.json"),
                loadImmediately: false),
            schedulerStore: SchedulerTaskStore(defaults: defaults))
            .environment(\.typographyTokens, TypographyTokenProvider(center: center))))
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("MemoryRestart2440")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_000, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        window.setAccessibilityIdentifier("memory-restart2440-\(UUID().uuidString)")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        pump(window)
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }

    private func pump(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    }

    private func node(_ identifier: String, in window: NSWindow) throws -> AnyObject {
        for _ in 0..<20 {
            pump(window)
            if let result = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
                return result
            }
        }
        return try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier))
    }

    private func ownedTexts(in window: NSWindow) throws -> [String] {
        let application = AXUIElementCreateApplication(getpid())
        try #require(AXUIElementSetMessagingTimeout(application, 0.05) == .success)
        var rawWindows: CFTypeRef?
        try #require(AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows) == .success)
        let windows = try #require(rawWindows as? [AXUIElement])
        let identifier = window.accessibilityIdentifier()
        let owners = windows.filter {
            _ = AXUIElementSetMessagingTimeout($0, 0.05)
            return NativeConsumerOwnedAX.attribute($0, kAXIdentifierAttribute as CFString) as? String == identifier
        }
        let owner = try #require(owners.count == 1 ? owners.first : nil)
        var queue = [owner]
        var visited: [AXUIElement] = []
        var values: [String] = []
        var index = 0
        while index < queue.count {
            try #require(index < 2_048)
            let node = queue[index]
            index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            _ = AXUIElementSetMessagingTimeout(node, 0.05)
            if let value = NativeConsumerOwnedAX.attribute(node, kAXValueAttribute as CFString) as? String {
                values.append(value)
            }
            var rawChildren: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            if status == .attributeUnsupported || status == .noValue { continue }
            try #require(status == .success)
            queue.append(contentsOf: try #require(rawChildren as? [AXUIElement]))
        }
        return values
    }
}
