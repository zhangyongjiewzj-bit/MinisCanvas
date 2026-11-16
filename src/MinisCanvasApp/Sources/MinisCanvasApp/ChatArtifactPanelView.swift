import SwiftUI
import MinisCore

/// Ordinary Chat asset presentation consumes the existing immutable inspector
/// projection. It owns only presentation width, not files, receipts or authority.
struct ChatArtifactPanelView: View {
    let snapshot: ChatInspectorSnapshot
    @State var widthSetting: AssetPanelWidthSetting
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeTokens) private var theme

    @MainActor
    init(snapshot: ChatInspectorSnapshot, preferencesDefaults: UserDefaults) {
        self.snapshot = snapshot
        _widthSetting = State(initialValue: AssetPanelWidthSetting(defaults: preferencesDefaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MinisIconView(.file, size: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text("资产预览").font(.headline)
                    Text(snapshot.artifactPersistenceUnavailable ? "当前会话 · 引用记录不可用" : "当前会话 · \(snapshot.fileArtifacts.count) 项已证实产物")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { MinisIconView(.close, size: 14) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭资产预览")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if snapshot.artifactPersistenceUnavailable {
                        Text("产物引用记录读取或保存失败；文件可能已写入，引用暂不可用。原记录未被清空。")
                            .foregroundStyle(.secondary)
                    }
                    if snapshot.fileChanges.isEmpty && snapshot.fileArtifacts.isEmpty && !snapshot.artifactPersistenceUnavailable {
                        Text("当前会话暂无文件变更或已证实产物。")
                            .foregroundStyle(.secondary)
                    }
                    if !snapshot.fileChanges.isEmpty {
                        Text("文件变更").font(.subheadline.weight(.semibold))
                        ForEach(snapshot.fileChanges, id: \.id) { change in
                            FileChangeRow(change: change)
                        }
                    }
                    if !snapshot.fileArtifacts.isEmpty {
                        Text("已证实产物").font(.subheadline.weight(.semibold))
                        ForEach(snapshot.fileArtifacts, id: \.diffID) { artifact in
                            FileArtifactEvidenceRow(artifact: artifact)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: widthSetting.width, height: 520)
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottomTrailing) { widthDragHandle }
        .onDisappear { widthSetting.endDrag() }
        .accessibilityIdentifier("chat-assets.panel")
    }

    /// Same cumulative pointer/AX width consumer and persisted key as the
    /// existing asset sheet. Closing the sheet never writes width zero.
    private var widthDragHandle: some View {
        MinisIconView(.sidebarRight, size: 14)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { widthSetting.applyDragTranslation($0.translation.width) }
                .onEnded { _ in widthSetting.endDrag() })
            .accessibilityElement()
            .accessibilityLabel("调整资产预览宽度")
            .accessibilityValue("\(Int(widthSetting.width)) 点")
            .accessibilityIdentifier("assetPanel.width")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: widthSetting.adjust(by: 40)
                case .decrement: widthSetting.adjust(by: -40)
                @unknown default: break
                }
            }
            .help("左右拖动调整资产预览宽度")
    }
}
