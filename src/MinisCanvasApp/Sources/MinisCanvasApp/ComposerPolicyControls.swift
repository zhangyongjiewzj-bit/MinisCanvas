import SwiftUI
import CoreFoundation
import MinisCore

// CF can call an observer from a nested AppKit run loop without entering a
// Swift actor first. Construct its C block here, outside the MainActor owner.
// Only the explicit main-thread/actor gate invokes the control's callback.
nonisolated func composerPolicyTurnBoundaryObserver(
    _ action: @escaping @MainActor () -> Void
) -> CFRunLoopObserver? {
    CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
        CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
        false, CFIndex.max) { observer, _ in
            guard Thread.isMainThread else { return }
            if let observer { CFRunLoopObserverInvalidate(observer) }
            MainActor.assumeIsolated { action() }
        }
}

@MainActor
private func composerPolicyLifecycleTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

/// Shared, visible controls used by Global Composer and Companion Composer.
/// The controls deliberately bind only to ChatStore, never to a View-local
/// authorization or receipt state.
struct ComposerPolicyControls: View {
    let chat: ChatStore
    var modeShortcutBinding: ShortcutBinding? = nil
    var showsBypassIndicator = true
    /// Collapsed Composer: this control lives in a popover, where a `.sheet`
    /// cannot be presented reliably. In this mode the bypass risk confirmation
    /// replaces the control's own content inside the popover instead.
    var usesInlineBypassRisk = false
    @State private var modeMenuRequestID: UUID?
    @State private var ceilingRequestOwner = UUID()
    @State private var showSkillBypassRisk = false
    @State private var riskFacts: ComposerPolicyFactSource?
    @State private var riskSessionID: UUID?
    @State private var riskPresentationID = UUID()
    @State private var riskSaveMessage: String?
    @Environment(\.minisOpenSettingsPage) private var openSettingsPage
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    private var activeSessionSnapshot: ComposerSubmissionSnapshot? {
        guard let activeSessionID = chat.activeSessionID,
              let snapshot = chat.lastComposerSubmissionSnapshot,
              snapshot.sessionID == activeSessionID.uuidString else {
            return nil
        }
        return ComposerPolicyPresentation.activeSnapshot(
            snapshot,
            activeSessionID: activeSessionID
        )
    }

    /// The summary is an immutable value tied to the active turn identity.
    /// Capability defaults to unsupported; only an explicitly probed Provider
    /// may opt into safe summary display.
    private var activeReasoningSummary: BL6ReasoningSummarySnapshot? {
        guard let snapshot = activeSessionSnapshot else { return nil }
        let settings = chat.effectiveSettingsSnapshotSource?()
        let providerID: String
        let modelID: String
        if let settings,
           case let .text(value) = settings.values["general.default-provider-id"] {
            providerID = value
        } else {
            providerID = "未配置"
        }
        if let settings,
           case let .text(value) = settings.values["general.default-model-id"] {
            modelID = value
        } else {
            modelID = "未配置"
        }
        return (settings ?? BL6EffectiveSettingsSnapshot(
            catalogRevision: "composer-unavailable",
            values: [:]
        )).reasoningSummarySnapshot(
            providerID: providerID,
            modelID: modelID,
            providerSupportsSafeSummary: false,
            capturedForTurnID: "\(snapshot.sessionID):\(snapshot.turnID)"
        )
    }

    /// Retain every policy control while adapting from one row through two
    /// columns to a single column, before the group can squeeze draft input.
    @ViewBuilder
    private var policyMenuContent: some View {
        modeMenu
        effortMenu
        thinkingMenu
    }

    private var modeMenu: some View {
        ComposerPolicyMenu(
            label: "任务模式",
            selection: Binding(
                get: { chat.composerPolicySelection.mode },
                set: { chat.selectInteractiveComposerMode($0, owner: ceilingRequestOwner) }
            ),
            // 设置里「禁用绕过」打开时，绕过权限不出现在可选项里。
            options: ComposerTaskMode.allCases.filter {
                !(chat.composerBypassDisabled && $0 == .bypassPermission)
            },
            title: ComposerPolicyPresentation.modeLabel,
            fontSize: typography?.composerBodySize ?? 13,
            help: "选择本回合如何规划与执行；超过最高模式时需要确认",
            isEnabled: { _ in chat.composerPolicyFacts.autonomyCeiling != nil },
            optionHelp: { mode in ComposerModeAvailability.explanation(mode, ceiling: chat.composerPolicyFacts.autonomyCeiling) },
            openRequestID: modeMenuRequestID
        )
    }

    private var effortMenu: some View {
        ComposerPolicyMenu(
            label: "工作量",
            selection: Binding(
                get: { chat.composerPolicySelection.effort },
                set: { chat.composerPolicySelection.effort = $0 }
            ),
            options: Array(ComposerEffort.allCases),
            title: ComposerPolicyPresentation.effortLabel,
            fontSize: typography?.composerBodySize ?? 13,
            help: "选择本回合投入程度：低、标准或高；不会改变工具权限、预算上限或模型能力"
        )
    }

    private var thinkingMenu: some View {
        ComposerPolicyMenu(
            label: "思考强度",
            selection: Binding<ThinkingLevel?>(
                get: {
                    ComposerThinkingSelection.capturedLevel(
                        chat.composerThinkingLevel, modelID: chat.selectedModelID)
                },
                set: { chat.composerThinkingLevel = $0 }
            ),
            options: ComposerThinkingSelection.options(modelID: chat.selectedModelID),
            title: ComposerThinkingSelection.title,
            fontSize: typography?.composerBodySize ?? 13,
            help: ComposerThinkingSelection.help(modelID: chat.selectedModelID)
        )
    }

    @ViewBuilder
    private var bypassControls: some View {
        if chat.composerPolicySelection.mode == .bypassPermission {
            Toggle(
                "我同意：可读写删除任意文件、执行任意命令",
                isOn: Binding(
                    get: { chat.composerPolicySelection.bypassModeConfirmed },
                    set: { confirmed in
                        if confirmed {
                            beginBypassRiskConfirmation()
                        } else { chat.composerPolicySelection.bypassModeConfirmed = false }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme?.aj38.danger.swiftUIColor ?? .red)
            // 可访问性标签有意保持旧文本：原生旅程脚本
            // （scripts/release/run_typography_package_journey.sh）按它找控件。
            // 新的完整说明放在可见标题与下面的 help（AXHelp）里。
            .accessibilityLabel("确认绕过权限模式仍受硬安全边界约束")
            .help("可读写删除电脑上任意文件、执行任意命令（系统文件与已安装软件除外）；删除：文件检查点开启时可从恢复入口找回（不进废纸篓），关闭检查点时才移入废纸篓；权限类设置修改仍需逐次审批")
            .accessibilityIdentifier("composer.bypass-confirm")

            if chat.composerPolicySelection.bypassModeConfirmed,
               chat.activeSessionID != nil, chat.composerPolicyFacts.autonomyCeiling == .l3,
               !chat.hasNativeCommandBypassConfirmation {
                Button("确认本会话命令免审批", action: beginBypassRiskConfirmation)
                    .buttonStyle(.link)
            }

            if showsBypassIndicator, chat.composerPolicySelection.bypassModeConfirmed {
                ComposerBypassIndicator()
            }
        }
    }

    func hidingBypassIndicator() -> Self {
        var controls = self
        controls.showsBypassIndicator = false
        return controls
    }

    /// Shows the bypass risk confirmation inline (no sheet).
    func inlineBypassRiskConfirmation() -> Self {
        var controls = self
        controls.usesInlineBypassRisk = true
        return controls
    }

    private func beginBypassRiskConfirmation() {
        riskFacts = chat.composerPolicyFacts
        riskSessionID = chat.activeSessionID
        riskPresentationID = UUID()
        showSkillBypassRisk = true
    }

    /// One risk form, one set of confirm/cancel guards, whether it is shown in
    /// the sheet (expanded) or inline (collapsed popover).
    private func bypassRiskContent() -> SkillBypassRiskView {
        let presentationID = riskPresentationID
        let sessionID = riskSessionID
        return SkillBypassRiskView(projectSummary: SkillRiskPresentation.projectSummary(riskFacts),
            canRememberSkillActions: SkillBypassRiskConfirmation.canRemember(facts: riskFacts,
                store: chat.composerGrantStore.persistentRules), onConfirm: { tools in
                guard showSkillBypassRisk, riskPresentationID == presentationID,
                      chat.activeSessionID == sessionID else { return }
                let saved = SkillBypassRiskConfirmation.confirm(tools, riskConfirmed: true,
                    expectedFacts: riskFacts, currentFacts: chat.composerPolicyFacts,
                    store: chat.composerGrantStore.persistentRules) {
                        chat.confirmComposerBypass(for: sessionID)
                    }
                riskSaveMessage = saved
                    ? (tools.isEmpty ? "绕过权限已确认；技能动作仍逐次询问。" : "已保存所选技能动作的放行，可在设置中逐条撤销。")
                    : "风险确认未保存，请检查当前项目和权限后重试。"
                if saved { showSkillBypassRisk = false }
            }, onCancel: { showSkillBypassRisk = false })
    }

    @ViewBuilder
    var body: some View {
        if usesInlineBypassRisk, showSkillBypassRisk {
            VStack(alignment: .leading, spacing: 4) {
                bypassRiskContent()
                // A failed save keeps the form open; its message must stay visible.
                if let riskSaveMessage {
                    Text(riskSaveMessage).font(.caption).foregroundStyle(theme?.statusWarning ?? .orange)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("composer.skill-risk.feedback")
                }
            }
        } else {
            policyBody
        }
    }

    private var policyBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    policyMenuContent
                }
                VStack(alignment: .leading, spacing: 4) {
                    modeMenu
                    HStack(spacing: 6) {
                        effortMenu
                        thinkingMenu
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    policyMenuContent
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            bypassControls

            if let request = chat.composerCeilingRequest, request.owner == ceilingRequestOwner,
               request.sessionID == chat.activeSessionID {
                Text(request.confirmationText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption)
                HStack {
                    Button("提高最高模式") {
                        Task { @MainActor in await chat.confirmInteractiveComposerMode(owner: ceilingRequestOwner) }
                    }
                    Button("取消") { chat.cancelComposerCeilingRequest(owner: ceilingRequestOwner) }
                }
            }
            if let riskSaveMessage {
                Text(riskSaveMessage).font(.caption).foregroundStyle(theme?.statusWarning ?? .orange)
                    .accessibilityIdentifier("composer.skill-risk.feedback")
            }
            if let feedback = chat.composerBypassDisabledFeedback {
                Text(feedback)
                    .font(typography?.caption ?? .caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("composer.bypass-disabled-feedback")
            } else if chat.composerBypassUnconfirmedFallbackActive {
                Text("绕过权限未确认，暂按手动审批处理")
                    .font(typography?.caption ?? .caption)
                    .modifier(ReadableStatusForeground(status: .warning))
                    .accessibilityIdentifier("composer.bypass-unconfirmed-feedback")
            }
            if let snapshot = activeSessionSnapshot {
                Text(ComposerPolicyPresentation.snapshotSummary(snapshot))
                    .font(typography?.status ?? .system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("composer.snapshot")
                    .accessibilityLabel("当前回合冻结策略")
                    .accessibilityValue(ComposerPolicyPresentation.snapshotSummary(snapshot))
                if let hint = ComposerPolicyPresentation.modeChangeDeferredHint(
                    snapshot: snapshot,
                    currentMode: chat.composerPolicySelection.mode,
                    isTurnInFlight: chat.isStreaming
                ) {
                    Text(hint)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("composer.mode-change-deferred-hint")
                }
            }

            if let reasoning = activeReasoningSummary {
                Text(reasoning.displayText ?? reasoning.statusText)
                    .font(typography?.status ?? .system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("composer.reasoning-summary")
                    .accessibilityLabel("当前回合推理摘要状态")
                    .accessibilityValue(reasoning.statusText)
            }
        }
        .background {
            if let modeShortcutBinding {
                Button("") { modeMenuRequestID = UUID() }
                    .shortcutKey(modeShortcutBinding)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
        .sheet(isPresented: Binding(
            get: { showSkillBypassRisk && !usesInlineBypassRisk },
            set: { showSkillBypassRisk = $0 }
        )) {
            bypassRiskContent()
        }
        .controlSize(.small)
        .font(typography?.composerBody ?? .system(size: 13))
        .lineLimit(1)
    }
}

struct ComposerBypassIndicator: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 3) {
            MinisIconView(.warning, state: .danger, size: 12)
                .accessibilityHidden(true)
            Text("绕过权限已生效")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme?.aj38.danger.swiftUIColor ?? .red)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("绕过权限已生效")
        .accessibilityIdentifier("composer.bypass-active")
    }
}

/// AppKit owns the menu, selected title, actions and accessibility frame. The
/// SwiftUI wrapper only synchronizes the existing ChatStore selection binding.
@MainActor
private struct ComposerPolicyMenu<Value: Hashable>: NSViewRepresentable {
    let label: String
    let selection: Binding<Value>
    let options: [Value]
    let title: (Value) -> String
    let fontSize: CGFloat
    let help: String
    var isEnabled: (Value) -> Bool = { _ in true }
    var optionHelp: (Value) -> String? = { _ in nil }
    var openRequestID: UUID? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = ComposerPolicyIdentityButton(frame: .zero, pullsDown: false)
        button.menu = ComposerPolicyChoiceMenu(title: label)
        button.controlSize = .small
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        (button as? ComposerPolicyIdentityButton)?.bindIdentity(titles: titles)
        button.menu?.autoenablesItems = false
        for (index, option) in options.enumerated() {
            button.item(at: index)?.isEnabled = isEnabled(option)
            button.item(at: index)?.toolTip = optionHelp(option)
        }
        button.selectItem(at: options.firstIndex(of: selection.wrappedValue) ?? -1)
        button.font = .systemFont(ofSize: fontSize)
        button.toolTip = help
        button.setAccessibilityLabel(label)
        if let requestID = openRequestID,
           context.coordinator.lastOpenRequestID != requestID, button.window != nil {
            context.coordinator.lastOpenRequestID = requestID
            button.performClick(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ComposerPolicyMenu
        var lastOpenRequestID: UUID?
        init(_ parent: ComposerPolicyMenu) { self.parent = parent }

        @objc func select(_ button: NSPopUpButton) {
            guard let producer = button as? ComposerPolicyIdentityButton else { return }
            guard producer.captureNativeSelectionAction(),
                  let index = producer.committedSelectionIndex else { return }
            guard parent.options.indices.contains(index),
                  parent.isEnabled(parent.options[index]) else {
                producer.completeNativeSelectionAction()
                producer.menu?.cancelTracking()
                return
            }
            parent.selection.wrappedValue = parent.options[index]
            producer.completeNativeSelectionAction()
            producer.menu?.cancelTracking()
        }
    }
}

/// Production identity is tied to the actual AppKit menu object, never a test label.
@MainActor
final class ComposerPolicyIdentityButton: NSPopUpButton {
    private static var serial: UInt64 = 0
    private static func nextIdentity() -> String {
        precondition(serial < UInt64.max)
        serial += 1
        return "composer.policy.instance." + UUID().uuidString + "." + String(serial)
    }
    private let instanceID = ComposerPolicyIdentityButton.nextIdentity()
    private(set) var menuGeneration: Int = 0
    private weak var boundMenu: NSMenu?
    private var boundItems: [NSMenuItem] = []
    private var boundTitles: [String] = []
    private var identityValid = false
    private(set) var committedSelectionIndex: Int?
    private var presentingChoice = false
    private var queuedChoiceID: UUID?
    private var queuedChoiceObserver: CFRunLoopObserver?
    private weak var queuedChoiceMenu: ComposerPolicyChoiceMenu?
    private weak var queuedChoiceWindow: NSWindow?

    private final class NativeChoice {
        weak var menu: ComposerPolicyChoiceMenu?
        weak var window: NSWindow?
        let generation: Int
        let items: [NSMenuItem]
        var beganTracking = false
        var endedTracking = false
        weak var actionItem: NSMenuItem?
        var closingObserver: CFRunLoopObserver?

        init(menu: ComposerPolicyChoiceMenu, window: NSWindow, generation: Int) {
            self.menu = menu; self.window = window; self.generation = generation
            items = menu.items
        }
    }
    private var nativeChoice: NativeChoice?

    override func performClick(_ sender: Any?) {
        _ = enqueueOwnedChoice()
    }
    override func mouseDown(with event: NSEvent) { _ = presentOwnedChoice() }
    override func accessibilityPerformPress() -> Bool { enqueueOwnedChoice() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { _ = presentOwnedChoice() }
        else { super.keyDown(with: event) }
    }

    // Legacy callers may name this actual control as its menu's parent. Resolve
    // only that exact owner to its real accessible cell on the main actor;
    // an unrelated parent is never repaired or accepted.
    private func prepareOwnedMenuParent() {
        guard !presentingChoice, identityValid,
              let choice = menu as? ComposerPolicyChoiceMenu, choice === boundMenu,
              let cell = cell as? NSPopUpButtonCell,
              cell.controlView === self, cell.menu === choice,
              (choice.accessibilityParent() as AnyObject?) === self else { return }
        choice.setAccessibilityParent(cell)
    }

    private func enqueueOwnedChoice() -> Bool {
        prepareOwnedMenuParent()
        guard queuedChoiceID == nil, !presentingChoice, identityValid, isEnabled,
              !isHiddenOrHasHiddenAncestor, let ownerWindow = window, ownerWindow.isVisible,
              let choice = menu as? ComposerPolicyChoiceMenu, choice === boundMenu,
              let selectedItem,
              identityRequest(menu: choice, query: selectedItem.title) != nil else { return false }
        let generation = menuGeneration
        let requestID = UUID()
        queuedChoiceID = requestID
        queuedChoiceMenu = choice
        queuedChoiceWindow = ownerWindow
        // Let the original default-mode turn reach its closing boundary before
        // entering nested menu tracking. This is still exactly the requested open.
        let observer = composerPolicyTurnBoundaryObserver { [weak self] in
            guard let self, self.queuedChoiceID == requestID else { return }
            self.queuedChoiceObserver = nil
            let choice = self.queuedChoiceMenu
            let ownerWindow = self.queuedChoiceWindow
            self.queuedChoiceID = nil
            self.queuedChoiceMenu = nil
            self.queuedChoiceWindow = nil
            guard let choice, let ownerWindow, self.menu === choice,
                  self.menuGeneration == generation, self.window === ownerWindow,
                  ownerWindow.isVisible else { return }
            // Use the same native cell click as mouse/keyboard. Superclass AX
            // press can return before tracking begins, letting the no-op closing
            // turn revoke this opening before its real item action arrives.
            _ = self.presentOwnedChoice()
        }
        guard let observer else {
            cancelQueuedChoice(for: choice)
            return false
        }
        queuedChoiceObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        return true
    }

    func cancelQueuedChoice(for expectedMenu: NSMenu) {
        guard menu === expectedMenu else { return }
        if let observer = queuedChoiceObserver { CFRunLoopObserverInvalidate(observer) }
        queuedChoiceObserver = nil
        queuedChoiceID = nil
        queuedChoiceMenu = nil
        queuedChoiceWindow = nil
    }

    private func presentOwnedChoice() -> Bool {
        performNativeOwnedChoice { choice in
            guard let cell = self.cell as? NSPopUpButtonCell,
                  cell.controlView === self, cell.menu === choice else { return false }
            self.performNativeControlClick()
            return true
        }
    }

    private func performNativeControlClick() { super.performClick(nil) }

    // Native open may return before AppKit sends the item's action. Retain the
    // exact opening witness until its own tracking/action notifications close it.
    // The injected open is only a lifecycle seam; it cannot select/commit an item.
    func performNativeOwnedChoice(_ open: (ComposerPolicyChoiceMenu) -> Bool) -> Bool {
        prepareOwnedMenuParent()
        guard !presentingChoice, identityValid, isEnabled,
              !isHiddenOrHasHiddenAncestor, let ownerWindow = window, ownerWindow.isVisible,
              let choice = menu as? ComposerPolicyChoiceMenu, choice === boundMenu,
              let selectedItem,
              identityRequest(menu: choice, query: selectedItem.title) != nil else { return false }
        let witness = NativeChoice(menu: choice, window: ownerWindow, generation: menuGeneration)
        nativeChoice = witness
        presentingChoice = true
        committedSelectionIndex = nil
        choice.beginChoice(owner: self, generation: witness.generation)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                     NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(nativeChoiceNotification(_:)),
                name: name, object: choice)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(nativeChoiceWindowClosed(_:)),
            name: NSWindow.willCloseNotification, object: ownerWindow)
        let nativeResult = open(choice)
        // An injected open may return before real menu tracking starts. Its
        // Bool is not a cancellation or selection receipt.
        composerPolicyLifecycleTrace("UF03_LIFECYCLE native open returned result=\(nativeResult) active=\(nativeChoice === witness) tracking=\(witness.beganTracking)")
        // A failed/no-op native opening must not leave an unlimited action lease.
        if nativeChoice === witness, !witness.beganTracking { scheduleNativeChoiceClose(witness) }
        return true
    }

    @objc private func nativeChoiceNotification(_ notification: Notification) {
        guard Thread.isMainThread, let witness = nativeChoice,
              let choice = witness.menu,
              let notified = notification.object as? NSMenu, notified === choice else { return }
        guard ownsActiveChoice(choice, generation: witness.generation) else {
            endNativeChoice(witness); return
        }
        switch notification.name {
        case NSMenu.didBeginTrackingNotification:
            guard !witness.beganTracking, !witness.endedTracking else { return }
            witness.beganTracking = true
            if let observer = witness.closingObserver { CFRunLoopObserverInvalidate(observer) }
            witness.closingObserver = nil
        case NSMenu.didEndTrackingNotification:
            witness.endedTracking = true
            // AppKit can send the selected item action after tracking ends.
            // Only that menu's action notification may admit it in this closing
            // run-loop turn; a cancelled menu produces no such action.
            scheduleNativeChoiceClose(witness)
        case NSMenu.willSendActionNotification:
            let items = notification.userInfo?.values.compactMap { $0 as? NSMenuItem } ?? []
            guard witness.beganTracking, committedSelectionIndex == nil, witness.actionItem == nil,
                  items.count == 1, let item = items.first,
                  witness.items.contains(where: { $0 === item }), item.menu === choice,
                  item.isEnabled, item.target === self,
                  item.action == #selector(commitSelectedPolicyItem(_:)),
                  identityRequest(menu: choice, query: item.title) != nil else { return }
            witness.actionItem = item
            composerPolicyLifecycleTrace("UF03_LIFECYCLE native action admitted item=\(item.title)")
        case NSMenu.didSendActionNotification:
            endNativeChoice(witness)
        default: break
        }
    }

    @objc private func nativeChoiceWindowClosed(_ notification: Notification) {
        guard let witness = nativeChoice,
              let notified = notification.object as? NSWindow, notified === witness.window else { return }
        endNativeChoice(witness)
    }

    private func scheduleNativeChoiceClose(_ witness: NativeChoice) {
        if let observer = witness.closingObserver { CFRunLoopObserverInvalidate(observer) }
        // A one-shot turn boundary, never an elapsed-time guess or retry loop.
        let observer = composerPolicyTurnBoundaryObserver { [weak self, weak witness] in
            guard let self, let witness, self.nativeChoice === witness else { return }
            witness.closingObserver = nil
            self.endNativeChoice(witness)
        }
        guard let observer else { endNativeChoice(witness); return }
        witness.closingObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }

    private func endNativeChoice(_ witness: NativeChoice) {
        guard nativeChoice === witness else { return }
        if let observer = witness.closingObserver { CFRunLoopObserverInvalidate(observer) }
        witness.closingObserver = nil
        if let choice = witness.menu {
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                         NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: choice)
            }
            choice.endChoice()
        }
        if let ownerWindow = witness.window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification,
                object: ownerWindow)
        }
        composerPolicyLifecycleTrace("UF03_LIFECYCLE native close committed=\(committedSelectionIndex != nil) ended=\(witness.endedTracking)")
        nativeChoice = nil
        committedSelectionIndex = nil
        presentingChoice = false
    }

    func completeNativeSelectionAction() {
        guard let witness = nativeChoice, committedSelectionIndex != nil else { return }
        endNativeChoice(witness)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let witness = nativeChoice, window !== witness.window { endNativeChoice(witness) }
    }

    // Internal tracking dependency allows deterministic contract tests. The
    // production press paths above always use the actual native pop-up button cell.
    func performOwnedChoice(_ track: (ComposerPolicyChoiceMenu, NSMenuItem) -> Bool) -> Bool {
        composerPolicyLifecycleTrace("UF03_LIFECYCLE performOwnedChoice enter presenting=\(presentingChoice) generation=\(menuGeneration)")
        prepareOwnedMenuParent()
        guard !presentingChoice, identityValid, isEnabled,
              !isHiddenOrHasHiddenAncestor, let ownerWindow = window, ownerWindow.isVisible,
              let choice = menu as? ComposerPolicyChoiceMenu, choice === boundMenu,
              let selectedItem,
              identityRequest(menu: choice, query: selectedItem.title) != nil else { return false }
        let openingGeneration = menuGeneration
        let openingItems = choice.items
        presentingChoice = true
        committedSelectionIndex = nil
        choice.beginChoice(owner: self, generation: openingGeneration)
        composerPolicyLifecycleTrace("UF03_LIFECYCLE beginChoice generation=\(openingGeneration)")
        defer {
            composerPolicyLifecycleTrace("UF03_LIFECYCLE endChoice generation=\(openingGeneration) chosen=\(choice.chosenItem?.title ?? "nil")")
            choice.endChoice()
            presentingChoice = false
            committedSelectionIndex = nil
        }
        // This synchronous contract requires a successful tracking return and
        // a captured item. Production's native open uses the lifecycle above.
        let selected = track(choice, selectedItem)
        composerPolicyLifecycleTrace("UF03_LIFECYCLE track returned selected=\(selected) chosen=\(choice.chosenItem?.title ?? "nil")")
        guard selected, isEnabled, !isHiddenOrHasHiddenAncestor,
              window === ownerWindow, ownerWindow.isVisible,
              menu === choice, choice === boundMenu, menuGeneration == openingGeneration,
              choice.items.count == openingItems.count,
              zip(choice.items, openingItems).allSatisfy({ $0 === $1 }),
              let item = choice.chosenItem,
              let index = openingItems.firstIndex(where: { $0 === item }),
              identityRequest(menu: choice, query: item.title) != nil,
              let action, let target else { return false }
        // A normal production binding commit from the native chosen item.
        // No selectItem setter is used to manufacture a precondition.
        committedSelectionIndex = index
        return sendAction(action, to: target)
    }

    // Record the concrete selected item. Synchronous contracts commit after
    // their injected tracking return; native routes commit only within AppKit's
    // exact item-action delivery, even if the open already returned.
    @discardableResult
    func captureNativeSelectionAction() -> Bool {
        guard presentingChoice else { return false }
        if committedSelectionIndex != nil { return nativeChoice == nil }
        guard let choice = menu as? ComposerPolicyChoiceMenu,
              ownsActiveChoice(choice, generation: menuGeneration),
              let cell = cell as? NSPopUpButtonCell, cell.controlView === self,
              cell.menu === choice, let item = cell.selectedItem,
              selectedItem === item else { return false }
        if let witness = nativeChoice {
            guard witness.beganTracking, committedSelectionIndex == nil, witness.actionItem === item else { return false }
        }
        choice.captureNativeChoice(item)
        guard choice.chosenItem === item else { return false }
        if let witness = nativeChoice {
            guard let index = witness.items.firstIndex(where: { $0 === item }) else { return false }
            committedSelectionIndex = index
        }
        return true
    }

    func ownsActiveChoice(_ choice: ComposerPolicyChoiceMenu, generation: Int) -> Bool {
        guard presentingChoice, identityValid, menu === choice, boundMenu === choice,
              menuGeneration == generation, isEnabled,
              !isHiddenOrHasHiddenAncestor, window?.isVisible == true else { return false }
        if let witness = nativeChoice {
            return witness.menu === choice && witness.generation == generation
                && window === witness.window && witness.window?.isVisible == true
                && choice.items.count == witness.items.count
                && zip(choice.items, witness.items).allSatisfy { $0 === $1 }
        }
        return true
    }

    func bindIdentity(titles: [String]) {
        guard let menu, let cell = cell as? NSPopUpButtonCell,
              cell.controlView === self, cell.menu === menu,
              !titles.isEmpty, titles.count <= 16,
              Set(titles).count == titles.count, menu.items.map(\.title) == titles else {
            identityValid = false; return
        }
        let sameItems = boundItems.count == menu.items.count &&
            zip(boundItems, menu.items).allSatisfy { $0 === $1 }
        if boundMenu !== menu || boundTitles != titles || !sameItems {
            guard menuGeneration < Int.max else { identityValid = false; return }
            menuGeneration += 1
            boundMenu = menu; boundItems = menu.items; boundTitles = titles
        }
        let root = instanceID + ".g" + String(menuGeneration)
        setAccessibilityIdentifier(root + ".popup")
        menu.setAccessibilityIdentifier(root + ".menu")
        // A single-cell control is represented in the public AX hierarchy by
        // its actual cell. Parenting to the ignored outer view exports AXUnknown.
        // Keep the real cell/menu/controlView ownership; no proxy element.
        menu.setAccessibilityParent(cell)
        for (index, item) in menu.items.enumerated() {
            item.setAccessibilityIdentifier(root + ".option." + String(index))
            if let choice = menu as? ComposerPolicyChoiceMenu,
               !choice.bindNativeItemAction(item),
               !(item.target === self && item.action == #selector(commitSelectedPolicyItem(_:))) {
                identityValid = false; return
            }
            item.target = self
            item.action = #selector(commitSelectedPolicyItem(_:))
        }
        identityValid = true
    }

    // AppKit has already selected this concrete item before its action runs.
    // Forward the original popup action only after the full owned identity and
    // selection checks pass; this never selects an item or closes the menu.
    @objc func commitSelectedPolicyItem(_ item: NSMenuItem) {
        guard presentingChoice else { return }
        if let witness = nativeChoice {
            guard committedSelectionIndex == nil, witness.actionItem === item else { return }
        }
        guard identityValid, isEnabled, item.isEnabled,
              let menu, boundMenu === menu, item.menu === menu,
              let index = boundItems.firstIndex(where: { $0 === item }),
              menu.items.count == boundItems.count,
              zip(menu.items, boundItems).allSatisfy({ $0 === $1 }),
              indexOfSelectedItem == index, selectedItem === item,
              identityRequest(menu: menu, query: item.title) != nil,
              item.target === self,
              item.action == #selector(commitSelectedPolicyItem(_:)),
              let action, let target else { return }
        _ = sendAction(action, to: target)
    }

    private(set) var identityFailure: String?

    func identityRequest(menu expectedMenu: NSMenu, query: String) -> [String: Any]? {
        identityFailure = nil
        func refused(_ reason: String) -> [String: Any]? { identityFailure = reason; return nil }
        guard identityValid else { return refused("PRODUCER_IDENTITY_INVALID") }
        guard boundMenu === expectedMenu, menu === expectedMenu else { return refused("PRODUCER_MENU_INSTANCE_STALE") }
        guard menuGeneration > 0 else { return refused("PRODUCER_GENERATION_INVALID") }
        guard expectedMenu.items.count == boundItems.count,
              zip(expectedMenu.items, boundItems).allSatisfy({ $0 === $1 }) else { return refused("PRODUCER_ITEMS_STALE") }
        guard expectedMenu.items.map(\.title) == boundTitles else { return refused("PRODUCER_TITLES_STALE") }
        guard boundTitles.filter({ $0 == query }).count == 1,
              let index = boundTitles.firstIndex(of: query) else { return refused("PRODUCER_TARGET_NOT_UNIQUE") }
        let root = instanceID + ".g" + String(menuGeneration)
        let ids = boundItems.indices.map { root + ".option." + String($0) }
        guard let cell = cell as? NSPopUpButtonCell,
              cell.controlView === self, cell.menu === expectedMenu,
              (expectedMenu.accessibilityParent() as AnyObject?) === cell,
              accessibilityIdentifier() == root + ".popup",
              expectedMenu.accessibilityIdentifier() == root + ".menu",
              zip(expectedMenu.items, ids).allSatisfy({ $0.accessibilityIdentifier() == $1 }) else { return refused("PRODUCER_IDENTIFIER_STALE") }
        return ["revision": "R14_PRODUCTION_MENU_IDENTITY_V1", "popup_id": root + ".popup",
                "menu_id": root + ".menu", "generation": menuGeneration,
                "option_ids": ids, "option_titles": boundTitles, "target_id": ids[index]]
    }
}

/// Captures only an item belonging to this actual menu while its current
/// owner presents it. Native delivery and synchronous contracts share this gate.
@MainActor
final class ComposerPolicyChoiceMenu: NSMenu {
    private struct NativeItemAction {
        weak var target: AnyObject?
        let hadTarget: Bool
        let action: Selector?

        init(_ item: NSMenuItem) {
            target = item.target; hadTarget = item.target != nil; action = item.action
        }

        func matches(_ item: NSMenuItem) -> Bool {
            action == item.action && hadTarget == (item.target != nil)
                && (!hadTarget || target === item.target)
        }
    }
    private var nativeItemActions: [ObjectIdentifier: NativeItemAction] = [:]

    // Preserve AppKit's original item target/action, including its normal popup
    // dismissal. Rebinding cannot silently adopt a changed action route.
    func bindNativeItemAction(_ item: NSMenuItem) -> Bool {
        guard item.menu === self else { return false }
        let live = Set(items.map(ObjectIdentifier.init))
        nativeItemActions = nativeItemActions.filter { live.contains($0.key) }
        let key = ObjectIdentifier(item)
        if let original = nativeItemActions[key] { return original.matches(item) }
        nativeItemActions[key] = NativeItemAction(item)
        return true
    }

    private weak var choiceOwner: ComposerPolicyIdentityButton?
    private var choiceGeneration = 0
    private(set) var chosenItem: NSMenuItem?
    private var receivedAction = false

    func beginChoice(owner: ComposerPolicyIdentityButton, generation: Int) {
        choiceOwner = owner; choiceGeneration = generation
        chosenItem = nil; receivedAction = false
        composerPolicyLifecycleTrace("UF03_LIFECYCLE menu beginChoice generation=\(generation)")
    }
    func endChoice() { composerPolicyLifecycleTrace("UF03_LIFECYCLE menu endChoice chosen=\(chosenItem?.title ?? "nil") received=\(receivedAction)"); choiceOwner = nil; chosenItem = nil; receivedAction = false }
    @objc func captureNativeChoice(_ item: NSMenuItem) {
        guard !receivedAction else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=received"); return }
        guard let owner = choiceOwner else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=owner_nil"); return }
        guard owner.ownsActiveChoice(self, generation: choiceGeneration) else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=ownsActiveChoice generation=\(choiceGeneration)"); return }
        guard item.menu === self else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=item_menu"); return }
        guard items.contains(where: { $0 === item }) else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=item_membership"); return }
        guard item.isEnabled else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=item_disabled"); return }
        guard nativeItemActions[ObjectIdentifier(item)] != nil,
              item.target === owner,
              item.action == #selector(owner.commitSelectedPolicyItem(_:)) else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=action_route"); return }
        guard owner.identityRequest(menu: self, query: item.title) != nil else { composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice reject=identity"); return }
        composerPolicyLifecycleTrace("UF03_LIFECYCLE captureNativeChoice accept item=\(item.title)")
        receivedAction = true; chosenItem = item
    }
}

/// UI eligibility mirrors the existing core gate, never grants permission.
enum ComposerModeAvailability {
    static func isEnabled(_ mode: ComposerTaskMode, ceiling: AutonomyLevel?) -> Bool {
        guard let ceiling else { return false }
        return mode.requiredAutonomyLevel <= ceiling
    }
    static func explanation(_ mode: ComposerTaskMode, ceiling: AutonomyLevel?) -> String {
        if !isEnabled(mode, ceiling: ceiling) {
            return "当前权限上限不允许此模式；选择后需先确认提高上限"
        }
        switch mode {
        case .manual: return "每一步都先问你，你同意后才执行工具操作"
        case .plan: return "仅制定计划，不修改文件"
        case .autoEdit: return "自动编辑文件，其它操作按审批策略确认"
        case .auto: return "自动编辑文件；只读命令、已记住的命令、项目内构建测试和新建、移动、复制文件的命令免问，其余仍询问"
        case .bypassPermission: return "可读写删除任意文件、执行任意命令（系统文件与已安装软件除外）；权限类设置修改仍逐次确认"
        }
    }
}

/// Local presentation state only; the existing rule store owns authorization.
struct SkillRiskActionSelection: Equatable {
    var create = false
    var update = false
    var delete = false
    var tools: Set<String> {
        Set([(create, "skill_create"), (update, "skill_update"), (delete, "skill_delete")]
            .compactMap { $0.0 ? $0.1 : nil })
    }
}

enum SkillRiskPresentation {
    static let warning = "之后智能体新建、修改、删除技能将不再询问你；技能会影响以后所有对话，一条错误规则可能持续生效；你可以随时在设置里撤销放行，也可以把技能回退到上一版。"
    static func projectSummary(_ facts: ComposerPolicyFactSource?) -> String {
        guard let facts, let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots) else {
            return "未选择项目"
        }
        return scope.roots.joined(separator: "、")
    }
    static func offerProjectSummary(_ offer: ApprovalPersistentAllowOffer?) -> String {
        guard let summary = offer?.summary, !summary.isEmpty,
              summary != PersistentApprovalRuleMatcher.skillAlwaysPattern,
              summary != PersistentApprovalRuleMatcher.skillBypassPattern else { return "当前项目" }
        return summary
    }
    static func actionTitle(_ tool: String) -> String? {
        switch tool {
        case "skill_create": return "新建技能"
        case "skill_update": return "修改技能"
        case "skill_delete": return "删除技能"
        default: return nil
        }
    }
}

/// Both bypass entry points must acknowledge this visible warning before
/// saving selected action rules. Unselected actions continue to ask each time.
struct SkillBypassRiskView: View {
    let projectSummary: String
    let canRememberSkillActions: Bool
    let onConfirm: (Set<String>) -> Void
    let onCancel: () -> Void
    @State private var selection = SkillRiskActionSelection()
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认绕过权限的风险").font(.headline)
            Text("可读写删除电脑上任意文件、执行任意命令（系统文件与已安装软件除外）。")
            Text(SkillRiskPresentation.warning)
                .foregroundStyle(theme?.statusWarning ?? .orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("技能放行仅限当前项目和当前应用配置：\(projectSummary)")
                .font(.caption)
            Text("仅对勾选的动作放行，其他动作仍逐次询问；删除需要单独选择。")
                .font(.caption)
            Toggle("新建技能", isOn: $selection.create)
                .disabled(!canRememberSkillActions)
                .accessibilityIdentifier("skill-risk.action.create")
            Toggle("修改技能", isOn: $selection.update)
                .disabled(!canRememberSkillActions)
                .accessibilityIdentifier("skill-risk.action.update")
            Toggle("删除技能", isOn: $selection.delete)
                .disabled(!canRememberSkillActions)
                .accessibilityIdentifier("skill-risk.action.delete")
            if !canRememberSkillActions {
                Text("当前没有可确认的项目范围，技能动作仍会逐次询问。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("skill-risk.cancel")
                Spacer()
                Button("我了解风险，仍然允许") {
                    onConfirm(canRememberSkillActions ? selection.tools : [])
                }
                .accessibilityIdentifier("skill-risk.bypass.confirm")
            }
        }
        .padding(20)
        .frame(width: 480)
        .toggleStyle(.checkbox)
        .lineLimit(nil)
    }
}

/// One bound native confirmation shared by Composer and Settings. This never
/// derives authorization from model text and cannot widen to a different project.
@MainActor
enum SkillBypassRiskConfirmation {
    static func canRemember(facts: ComposerPolicyFactSource?, store: PersistentApprovalRuleStore?) -> Bool {
        guard let facts, let store else { return false }
        return store.makeSkillBypassRule(capability: "skill_create", facts: facts) != nil
    }

    static func confirm(_ tools: Set<String>, riskConfirmed: Bool,
                        expectedFacts: ComposerPolicyFactSource?, currentFacts: ComposerPolicyFactSource?,
                        store: PersistentApprovalRuleStore?, commitBypass: () -> Bool) -> Bool {
        guard riskConfirmed, tools.isSubset(of: SkillMaintenanceTool.names) else { return false }
        if tools.isEmpty { return commitBypass() }
        guard let facts = expectedFacts, facts == currentFacts, let store else { return false }
        let rules = tools.sorted().compactMap { store.makeSkillBypassRule(capability: $0, facts: facts) }
        guard rules.count == tools.count else { return false }
        var insertedIDs: [String] = []
        for rule in rules {
            guard store.add(rule) else {
                for id in insertedIDs { _ = store.remove(id: id) }
                return false
            }
            if store.allRules().contains(where: { $0.id == rule.id }) { insertedIDs.append(rule.id) }
        }
        guard commitBypass() else {
            for id in insertedIDs { _ = store.remove(id: id) }
            return false
        }
        return true
    }
}
