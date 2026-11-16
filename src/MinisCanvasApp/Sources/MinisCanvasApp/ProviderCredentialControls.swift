import AppKit
import Observation
import SwiftUI
import MinisCore

/// Stable, secret-free identity supplied by the provider settings parent.
/// `revision` must come from the parent's validated credential binding (for
/// example the store's process consistency token); it must never be derived
/// from the provider name alone.
struct ProviderCredentialBinding: Equatable, Hashable, Sendable {
    let providerID: String
    let credentialName: String
    let revision: String

    init(providerID: String, credentialName: String, revision: String) {
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialName = EnvVarStore.canonicalName(credentialName)
        self.revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !providerID.isEmpty && EnvVarStore.isValidName(credentialName) && !revision.isEmpty
    }
}

enum ProviderCredentialControlFailure: Equatable, Sendable {
    case missing
    case denied
    case failed
    case staleBinding
    case staleRequest
    case copyFailed

    var message: String {
        switch self {
        case .missing:
            return "无法读取当前 API Key：未找到；请直接输入新 Key 替换。"
        case .denied:
            return "无法读取当前 API Key：钥匙串访问被拒绝；请检查权限，或直接输入新 Key 替换。"
        case .failed:
            return "无法读取当前 API Key：钥匙串读取失败；请重试，或直接输入新 Key 替换。"
        case .staleBinding, .staleRequest:
            return "当前供应商已发生变化，请关闭后重新打开。"
        case .copyFailed:
            return "复制 API Key 失败，请重试。"
        }
    }
}

enum ProviderCredentialControlState: Equatable, Sendable {
    case hidden
    case readingReveal
    case readingCopy
    case revealed(until: Date)
    case copied(until: Date)
    case failed(ProviderCredentialControlFailure)
}

struct ProviderCredentialAccessibilitySnapshot: Equatable, Sendable {
    let controlLabels: [String]
    let exposedValues: [String]
}

/// The only pasteboard operations this control needs. It can write and clear
/// its own copy, but it cannot read the user's clipboard.
@MainActor
protocol ProviderCredentialPasteboard: AnyObject {
    var changeCount: Int { get }
    @discardableResult
    func write(_ value: String) -> Bool
    @discardableResult
    func clearIfUnchanged(since changeCount: Int) -> Bool
}

@MainActor
final class NativeProviderCredentialPasteboard: ProviderCredentialPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    @discardableResult
    func write(_ value: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    @discardableResult
    func clearIfUnchanged(since changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        return true
    }
}

@MainActor
@Observable
final class ProviderCredentialControlsModel {
    private enum ReadKind {
        case reveal
        case copy
    }

    private struct ReadRequest {
        let generation: UInt64
        let binding: ProviderCredentialBinding
        let kind: ReadKind
    }

    private let readCredential: @MainActor (String) async -> SettingsCenter.ProviderCredentialReadOutcome
    private let currentBinding: @MainActor () -> ProviderCredentialBinding?
    private let pasteboard: any ProviderCredentialPasteboard
    private let now: @MainActor () -> Date
    private let binding: ProviderCredentialBinding
    private var requestGeneration: UInt64 = 0
    private var pendingTask: Task<Void, Never>?
    private var revealedValue: String?
    private var revealDeadline: Date?
    private var ownedPasteboardChangeCount: Int?
    private var copyDeadline: Date?
    private(set) var isClosed = false
    private(set) var state: ProviderCredentialControlState = .hidden

    convenience init(
        settings: SettingsCenter,
        binding: ProviderCredentialBinding,
        currentBinding: @escaping @MainActor () -> ProviderCredentialBinding?,
        pasteboard: any ProviderCredentialPasteboard = NativeProviderCredentialPasteboard(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.init(
            binding: binding,
            currentBinding: currentBinding,
            pasteboard: pasteboard,
            now: now,
            readCredential: { name in
                await settings.providerCredentialReadAsync(named: name)
            }
        )
    }

    init(
        binding: ProviderCredentialBinding,
        currentBinding: @escaping @MainActor () -> ProviderCredentialBinding?,
        pasteboard: any ProviderCredentialPasteboard,
        now: @escaping @MainActor () -> Date,
        readCredential: @escaping @MainActor (String) async -> SettingsCenter.ProviderCredentialReadOutcome
    ) {
        self.binding = binding
        self.currentBinding = currentBinding
        self.pasteboard = pasteboard
        self.now = now
        self.readCredential = readCredential
    }

    var accessibilitySnapshot: ProviderCredentialAccessibilitySnapshot {
        ProviderCredentialAccessibilitySnapshot(
            controlLabels: [
                "显示 API Key",
                "复制 API Key"
            ],
            // The actual value is deliberately absent even while visible.
            exposedValues: []
        )
    }

    var visibleValue: String? {
        guard case .revealed = state, !isClosed, currentBinding() == binding else { return nil }
        return revealedValue
    }

    func reveal() {
        startRead(kind: .reveal)
    }

    func copy() {
        startRead(kind: .copy)
    }

    /// Called by the parent when the provider row loses focus or the scene is
    /// backgrounded. Copy ownership remains independently time-bounded.
    func focusLost() {
        cancelPendingRead()
        maskReveal()
    }

    func appDidEnterBackground() {
        focusLost()
    }

    /// The parent view routes every scene-phase transition through this
    /// policy entry. On macOS `ScenePhase` reports `.inactive` when the app
    /// resigns front or the window stops being key, while `.background` only
    /// arrives once the scene is not visible. Treating any non-active phase
    /// as focus loss re-masks an explicit reveal immediately (失焦回遮)
    /// instead of leaving the real Keychain value readable on a visible
    /// unfocused window until the 15-second deadline. This only tightens
    /// masking; it never grants additional visibility.
    func scenePhaseChanged(to phase: ScenePhase) {
        guard phase != .active else { return }
        focusLost()
    }

    @discardableResult
    func close() -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let cancelledRead = pendingTask
        isClosed = true
        cancelPendingRead()
        maskReveal()
        clearOwnedPasteboardIfSafe()
        state = .hidden
        return cancelledRead
    }

    /// The view supplies a clock tick; tests can advance an injected clock
    /// without reading or mutating the system clipboard.
    func refresh(now date: Date? = nil) {
        guard !isClosed, currentBinding() == binding else {
            close()
            return
        }
        let current = date ?? now()
        if let deadline = revealDeadline, current >= deadline {
            maskReveal()
        }
        if let deadline = copyDeadline, current >= deadline {
            clearOwnedPasteboardIfSafe()
            copyDeadline = nil
            if !isClosed, revealedValue == nil {
                state = .hidden
            }
        }
    }

    private func startRead(kind: ReadKind) {
        guard !isClosed, binding.isValid, currentBinding() == binding else {
            state = .failed(.staleBinding)
            return
        }
        cancelPendingRead()
        requestGeneration &+= 1
        let request = ReadRequest(generation: requestGeneration, binding: binding, kind: kind)
        state = kind == .reveal ? .readingReveal : .readingCopy
        pendingTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !self.isClosed,
                  request.generation == self.requestGeneration else { return }
            guard self.currentBinding() == request.binding else {
                self.pendingTask = nil
                self.state = .failed(.staleRequest)
                return
            }
            let outcome = await self.readCredential(request.binding.credentialName)
            guard !Task.isCancelled else { return }
            self.complete(outcome, request: request)
        }
    }

    private func complete(
        _ outcome: SettingsCenter.ProviderCredentialReadOutcome,
        request: ReadRequest
    ) {
        guard !isClosed,
              request.generation == requestGeneration,
              currentBinding() == request.binding else {
            state = isClosed ? .hidden : .failed(.staleRequest)
            return
        }
        pendingTask = nil
        switch outcome {
        case .failure(let failure):
            state = .failed(Self.map(failure))
        case .success(let value):
            guard !value.isEmpty else {
                state = .failed(.missing)
                return
            }
            switch request.kind {
            case .reveal:
                revealedValue = value
                revealDeadline = now().addingTimeInterval(15)
                state = .revealed(until: revealDeadline ?? now())
            case .copy:
                guard pasteboard.write(value) else {
                    state = .failed(.copyFailed)
                    return
                }
                ownedPasteboardChangeCount = pasteboard.changeCount
                copyDeadline = now().addingTimeInterval(60)
                if revealedValue == nil {
                    state = .copied(until: copyDeadline ?? now())
                }
            }
        }
    }

    private func cancelPendingRead() {
        pendingTask?.cancel()
        pendingTask = nil
        requestGeneration &+= 1
    }

    private func maskReveal() {
        revealedValue = nil
        revealDeadline = nil
        guard !isClosed else { return }
        if let copyDeadline {
            state = .copied(until: copyDeadline)
        } else {
            state = .hidden
        }
    }

    private func clearOwnedPasteboardIfSafe() {
        guard let ownedPasteboardChangeCount else { return }
        _ = pasteboard.clearIfUnchanged(since: ownedPasteboardChangeCount)
        self.ownedPasteboardChangeCount = nil
    }

    private static func map(
        _ failure: SettingsCenter.ProviderCredentialReadFailure
    ) -> ProviderCredentialControlFailure {
        switch failure {
        case .missing: return .missing
        case .denied: return .denied
        case .failed: return .failed
        }
    }
}

/// Stable view contract for PKG's later SettingsView wiring. The parent owns
/// provider context and must update `currentBinding` when a row is renamed,
/// deleted, replaced, cancelled or closed.
@MainActor
struct ProviderCredentialControls: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ProviderCredentialControlsModel

    init(model: ProviderCredentialControlsModel) {
        _model = State(initialValue: model)
    }

    init(
        settings: SettingsCenter,
        binding: ProviderCredentialBinding,
        currentBinding: @escaping @MainActor () -> ProviderCredentialBinding?,
        pasteboard: any ProviderCredentialPasteboard = NativeProviderCredentialPasteboard(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.init(
            model: ProviderCredentialControlsModel(
                settings: settings,
                binding: binding,
                currentBinding: currentBinding,
                pasteboard: pasteboard,
                now: now
            )
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if let value = model.visibleValue {
                // privacySensitive is a native presentation hint. The text is
                // hidden from AX so the real value never becomes an AX value.
                Text(value)
                    .privacySensitive()
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
            } else {
                Text("API Key 已隐藏")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.provider.credential.hidden")
            }
            Button("显示 API Key") { model.reveal() }
                .accessibilityLabel("显示 API Key")
                .accessibilityHint("仅暂时显示，15 秒后自动遮回")
                .accessibilityIdentifier("settings.provider.credential.reveal")
            Button("复制 API Key") { model.copy() }
                .accessibilityLabel("复制 API Key")
                .accessibilityHint("复制后 60 秒清除，若剪贴板未被替换")
                .accessibilityIdentifier("settings.provider.credential.copy")
            if case .failed(let failure) = model.state {
                Text(failure.message)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("凭据操作失败")
                    .accessibilityValue(failure.message)
                    .accessibilityIdentifier("settings.provider.credential.error")
            }
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { date in
            model.refresh(now: date)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        .onDisappear { model.close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.credential.controls")
    }
}
