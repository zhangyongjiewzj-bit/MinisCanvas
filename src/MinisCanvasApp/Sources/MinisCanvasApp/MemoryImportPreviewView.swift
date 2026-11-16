import SwiftUI
import MinisCore

/// Write-free preview for an imported Markdown document.
///
/// The selected scope is only a user-facing choice here.  The parent settings
/// owner binds it to the captured concrete `MemoryScope` and performs the
/// explicit confirmation through `SettingsCenter`.
struct MemoryImportPreviewView: View {
    let preview: MemoryMarkdownImportPreview
    let onCancel: () -> Void
    let onConfirm: (MemoryImportScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.typographyTokens) private var typography
    @State private var selectedScope: MemoryImportScope

    init(
        preview: MemoryMarkdownImportPreview,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (MemoryImportScope) -> Void
    ) {
        self.preview = preview
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedScope = State(initialValue: preview.selectedScope ?? .project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("预览导入记忆")
                        .font(typography?.headline ?? .headline)
                    Text(preview.sourceName)
                        .font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text("\(preview.factCount) 条")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
            }

            Text("Markdown 只作为记忆内容读取；其中的标题、列表和注释不会被执行。确认前不会写入记忆。")
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("导入作用域", selection: $selectedScope) {
                ForEach(MemoryImportScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.memory.markdown.scope")

            Text(selectedScope.explanation)
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let capturedScope = preview.capturedScope {
                Text("绑定范围：项目 \(capturedScope.projectID) · 会话 \(capturedScope.sessionID)")
                    .font(typography?.caption ?? .caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("当前没有可用的会话/项目 scope，确认时会拒绝写入。")
                    .font(typography?.caption ?? .caption)
                    .modifier(ReadableStatusForeground(status: .warning))
            }

            List {
                ForEach(MemoryCategory.allCases, id: \.self) { category in
                    let facts = preview.facts.filter { $0.category == category }
                    if !facts.isEmpty {
                        Section(category.label) {
                            ForEach(facts) { fact in
                                Text(fact.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            HStack {
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("确认导入") {
                    onConfirm(selectedScope)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.memory.markdown.confirm")
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 500)
        .accessibilityIdentifier("settings.memory.markdown.preview")
    }
}
