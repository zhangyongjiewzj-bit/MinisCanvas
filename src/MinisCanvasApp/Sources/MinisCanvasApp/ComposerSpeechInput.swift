import AVFoundation
import Foundation
import MinisCore
import Speech
import SwiftUI

enum ComposerSpeechPermission: Equatable {
    case granted
    case requestable
    case denied
    case unknown
}

enum ComposerSpeechPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case finishing
    case failed(String)
}

struct ComposerSpeechContext: Equatable {
    let sessionID: UUID
    let projectID: String?
    /// Monotonic active-session transition identity supplied by BridgeStore.
    /// A queued click cannot be revived by leaving and returning to the same
    /// session/project before its MainActor task starts.
    let sessionTransitionEpoch: UInt64
}

enum ComposerSpeechAvailability: Equatable {
    case ready
    case permissionRequired
    case permissionStatusUnknown
    case noSession
    case unsupported(SpeechCapabilityBoundary.UnsupportedReason)

    var canStartFromClick: Bool {
        switch self {
        case .ready, .permissionRequired: return true
        case .permissionStatusUnknown, .noSession, .unsupported: return false
        }
    }

    var explanation: String {
        switch self {
        case .ready: return "点击开始语音输入"
        case .permissionRequired: return "点击请求语音识别与麦克风权限并开始输入"
        case .permissionStatusUnknown: return "无法确认语音识别或麦克风权限状态，暂不能开始语音输入"
        case .noSession: return "请先打开一个会话"
        case .unsupported(.speechLocaleUnresolved): return "当前语言不支持语音输入"
        case .unsupported(.speechRecognitionNotAuthorized): return "语音识别权限已拒绝，请在系统设置中开启"
        case .unsupported(.microphoneNotAuthorized): return "麦克风权限已拒绝，请在系统设置中开启"
        case .unsupported(.recognizerMissingForEffectiveLocale): return "当前语言没有可用的语音识别器"
        case .unsupported(.recognizerEngineUnavailable): return "语音识别服务当前不可用"
        case .unsupported(.noAudioInputDevice): return "未检测到麦克风输入设备"
        case .unsupported: return "语音输入当前不可用"
        }
    }
}

/// The App consumer owns authorization and result routing. Tests inject this
/// interface so they never consult devices or request real system permission.
@MainActor
protocol ComposerSpeechInputDriver: AnyObject {
    var configured: Bool { get }
    var recognizerAvailable: Bool { get }
    var hasAudioInput: Bool { get }
    var speechPermission: ComposerSpeechPermission { get }
    var microphonePermission: ComposerSpeechPermission { get }
    func requestAuthorization() async -> Bool
    func start() throws
    func stop() async -> String
    func cancel()
}

@MainActor
final class LiveComposerSpeechInputDriver: ComposerSpeechInputDriver {
    private let recognizer: SpeechRecognizer?

    init(recognizer: SpeechRecognizer?) {
        self.recognizer = recognizer
    }

    var configured: Bool { recognizer != nil }
    var recognizerAvailable: Bool { recognizer?.isAvailable ?? false }
    var hasAudioInput: Bool { AVCaptureDevice.default(for: .audio) != nil }

    var speechPermission: ComposerSpeechPermission {
        switch SpeechRecognizer.authorizationStatus {
        case .authorized: return .granted
        case .notDetermined: return .requestable
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    var microphonePermission: ComposerSpeechPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .requestable
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        guard let recognizer else { return false }
        return await recognizer.requestAuthorization()
    }

    func start() throws {
        guard let recognizer else {
            throw SpeechRecognizerError.recognizerUnavailable("unconfigured")
        }
        try recognizer.start()
    }

    func stop() async -> String { recognizer?.stop() ?? "" }
    func cancel() { _ = recognizer?.stop() }
}

enum ComposerSpeechPresentation {
    static func feedback(
        phase: ComposerSpeechPhase,
        availability: ComposerSpeechAvailability
    ) -> String? {
        switch phase {
        case .failed(let reason): return reason
        case .recording: return "录音中"
        case .requestingPermission: return "等待系统权限确认"
        case .finishing: return "正在结束语音输入"
        case .idle:
            switch availability {
            case .ready: return nil
            case .permissionRequired: return "点击授权语音输入"
            case .permissionStatusUnknown, .noSession, .unsupported: return availability.explanation
            }
        }
    }
}

struct ComposerSpeechStatusLine: View {
    @Bindable var bridge: BridgeStore
    let accessibilityID: String

    var body: some View {
        if let feedback = ComposerSpeechPresentation.feedback(
            phase: bridge.composerSpeechPhase,
            availability: bridge.composerSpeechAvailability
        ) {
            Text(feedback)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(feedback)
                .accessibilityIdentifier(accessibilityID)
        }
    }
}

/// Both composer surfaces render the same BridgeStore state and invoke the
/// same lifecycle. The control never calls ChatStore.submitComposer().
struct ComposerSpeechControl: View {
    @Bindable var bridge: BridgeStore
    @Bindable var chat: ChatStore
    let accessibilityID: String

    private var availability: ComposerSpeechAvailability {
        bridge.composerSpeechAvailability
    }

    private var isDisabled: Bool {
        switch bridge.composerSpeechPhase {
        case .idle, .failed: return !availability.canStartFromClick
        case .requestingPermission, .recording, .finishing: return false
        }
    }

    private var actionLabel: String {
        switch bridge.composerSpeechPhase {
        case .idle, .failed: return "开始语音输入"
        case .requestingPermission: return "取消语音权限请求"
        case .recording: return "停止语音输入并加入草稿"
        case .finishing: return "取消语音输入结果"
        }
    }

    var body: some View {
        Button {
            switch bridge.composerSpeechPhase {
            case .idle, .failed:
                guard let context = bridge.composerSpeechClickContext else { return }
                Task { @MainActor in
                    _ = await bridge.startComposerSpeechInput(expectedContext: context)
                }
            case .recording:
                guard let generation = bridge.composerSpeechClickGeneration else { return }
                Task { @MainActor in
                    _ = await bridge.stopComposerSpeechInput(expectedGeneration: generation)
                }
            case .requestingPermission, .finishing:
                bridge.cancelComposerSpeechInput()
            }
        } label: {
            MinisIconView(
                .microphone,
                state: bridge.composerSpeechPhase == .recording ? .active : .normal,
                size: MinisIconTokens.defaultSize
            )
            .frame(
                width: ComposerLayoutMetrics.iconButtonHitSize,
                height: ComposerLayoutMetrics.iconButtonHitSize
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(isDisabled ? availability.explanation : actionLabel)
        .accessibilityLabel(actionLabel)
        .accessibilityIdentifier(accessibilityID)
        .onChange(of: chat.activeSessionID) { _, _ in
            bridge.cancelComposerSpeechInputIfContextChanged()
        }
        .onChange(of: chat.sessions) { _, _ in
            bridge.cancelComposerSpeechInputIfContextChanged()
        }
    }
}
