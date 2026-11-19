import MinisCore
import SwiftUI

/// 音频附件卡片上的转写控件：转为文字 / 进度与取消 / 同意联网 / 失败重试 / 查看与修改文字 / 切换语言。
struct AudioTranscriptionChipControls: View {
    @Environment(\.themeTokens) private var theme
    @Bindable var chat: ChatStore
    let attachment: ChatAttachment

    @State private var showingEditor = false
    @State private var draft = ""
    @State private var pendingRestartLocaleID: String?

    private var id: String { attachment.id.uuidString }
    private var state: AudioTranscriptionUIState? { chat.audioTranscriptionStates[attachment.id] }

    var body: some View {
        if attachment.kind == .audio, attachment.status == .ready, attachment.data != nil {
            HStack(spacing: 5) {
                stateContent
                if !isRunning { languageMenu }
            }
            .font(.system(size: 9))
        }
    }

    private var isRunning: Bool {
        if case .running = state?.phase { return true }
        return false
    }

    @ViewBuilder private var stateContent: some View {
        switch state?.phase {
        case .running(let done, let total):
            ProgressView().controlSize(.mini)
            Text(total > 0 ? "转写中 第 \(done)/\(total) 段" : "准备转写…")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("composer.attachment.transcribe.progress.\(id)")
            Button("取消") { chat.cancelAudioTranscription(id: attachment.id) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachment.transcribe.cancel.\(id)")
        case .needsOnlineConsent:
            Text("本机不支持识别这种语言。联网识别会把音频发送给 Apple 识别，是否同意？")
                .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                .lineLimit(2)
            Button("同意并转写") { chat.approveOnlineAudioTranscription(id: attachment.id) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachment.transcribe.consent.\(id)")
            Button("不同意") { chat.declineOnlineAudioTranscription(id: attachment.id) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachment.transcribe.decline.\(id)")
        case .failed(let message):
            Text(message)
                .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                .lineLimit(2)
                .help(message)
                .accessibilityIdentifier("composer.attachment.transcribe.failure.\(id)")
            Button("重试") { chat.startAudioTranscription(id: attachment.id) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.attachment.transcribe.retry.\(id)")
        case nil:
            if let transcript = attachment.audioTranscript {
                Text("已转为文字（\(AudioTranscriptionLanguages.displayName(for: transcript.localeIdentifier))，"
                    + (transcript.onDevice ? "本机识别" : "Apple 在线识别")
                    + (transcript.edited ? "，已修改" : "") + "）")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("composer.attachment.transcribe.done.\(id)")
                Button("查看文字") {
                    draft = transcript.text
                    showingEditor = true
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("composer.attachment.transcribe.view.\(id)")
                .popover(isPresented: $showingEditor) { editor }
            } else {
                Button("转为文字") { chat.startAudioTranscription(id: attachment.id) }
                    .buttonStyle(.plain)
                    .help("在本机把音频识别成文字，发送时以文字代替音频")
                    .accessibilityIdentifier("composer.attachment.transcribe.start.\(id)")
            }
        }
    }

    private var languageMenu: some View {
        Menu("语言") {
            ForEach(AudioTranscriptionLanguages.options()) { option in
                Button(option.name) {
                    if attachment.audioTranscript?.edited == true {
                        pendingRestartLocaleID = option.id
                    } else {
                        chat.restartAudioTranscription(id: attachment.id, localeID: option.id)
                    }
                }
            }
        }
        .confirmationDialog(
            "重新转写会覆盖你修改过的文字", isPresented: Binding(
                get: { pendingRestartLocaleID != nil },
                set: { if !$0 { pendingRestartLocaleID = nil } }),
            titleVisibility: .visible
        ) {
            Button("重新转写并覆盖", role: .destructive) {
                if let locale = pendingRestartLocaleID {
                    chat.restartAudioTranscription(id: attachment.id, localeID: locale)
                }
                pendingRestartLocaleID = nil
            }
            Button("取消", role: .cancel) { pendingRestartLocaleID = nil }
        } message: {
            Text("你改过的转写文字会被新的识别结果替换，无法恢复。")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择音频的语言并重新转写（默认跟随 App 语言）")
        .accessibilityIdentifier("composer.attachment.transcribe.language.\(id)")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("转写文字（发送时使用这里的内容）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 12))
                .frame(width: 380, height: 220)
                .accessibilityIdentifier("composer.attachment.transcribe.editor.\(id)")
            HStack {
                Spacer()
                Button("取消") { showingEditor = false }
                Button("保存") {
                    chat.setAudioTranscriptText(id: attachment.id, text: draft)
                    showingEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("composer.attachment.transcribe.save.\(id)")
            }
        }
        .padding(12)
    }
}
