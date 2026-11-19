import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore

/// 会话内文档面板。
///
/// 这里的「Tab」只属于传入的 sessionID；视图不创建 workspace ID，也不把
/// 文档状态挂到画布。编辑由 SessionDocumentStore 原子写入恢复快照，视图
/// 只负责当前会话的选择、系统文件面板和关闭确认。
struct SessionDocumentWorkspaceView: View {
    let store: SessionDocumentStore
    let sessionID: UUID?
    @Bindable var chat: ChatStore

    @Environment(\.themeTokens) private var theme
    @State private var state: SessionDocumentSessionState
    @State private var closeTargetID: UUID?
    @State private var errorMessage: String?
    @State private var stageInputSnapshot: SessionDocumentTextSnapshot?
    @State private var showsDocumentStages = false
    @State private var stageTask: Task<Void, Never>?
    @State private var stageTaskTabID: UUID?

    init(store: SessionDocumentStore, sessionID: UUID?, chat: ChatStore) {
        self.store = store
        self.sessionID = sessionID
        self._chat = Bindable(chat)
        let initial = sessionID.map { store.restoreSession($0) }
            ?? SessionDocumentSessionState(sessionID: UUID())
        self._state = State(initialValue: initial)
        self._stageInputSnapshot = State(initialValue: nil)
    }

    private var accent: Color {
        theme?.aj38.accent.swiftUIColor ?? Color.accentColor
    }

    private var selectedTab: SessionDocumentTab? {
        guard let selectedID = state.selectedTabID else { return nil }
        return state.tabs.first { $0.id == selectedID }
    }

    private enum StageRevisionState: Equatable {
        case unbound
        case current
        case stale
    }

    private var stageRevisionState: StageRevisionState {
        guard let stageInputSnapshot else { return .unbound }
        return store.isCurrent(stageInputSnapshot) ? .current : .stale
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            tabBar
            Divider()
            if showsDocumentStages { documentStages; Divider() }
            editorArea
        }
        .background(theme?.aj38.backgroundPrimary.swiftUIColor ?? Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: sessionID) { _, _ in stageTask?.cancel(); reload() }
        .onDisappear { stageTask?.cancel() }
        .alert("关闭未保存文档", isPresented: closeAlertBinding) {
            Button("保存") { resolveClose(.save) }
            Button("放弃修改", role: .destructive) { resolveClose(.discard) }
            Button("取消", role: .cancel) { closeTargetID = nil }
        } message: {
            Text("文档还有未保存的修改。")
        }
        .alert("文档操作失败", isPresented: errorAlertBinding) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label {
                Text("会话文档")
            } icon: {
                MinisIconView(.document, size: 16, accessibilityLabel: "会话文档")
            }
                .font(.system(size: 12, weight: .semibold))
            if selectedTab?.isDirty == true {
                Text("未保存")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme?.statusWarning ?? .orange)
            }
            if let stageInputSnapshot {
                Text("阶段版本 \(stageInputSnapshot.revision.prefix(8))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        stageRevisionState == .stale
                            ? (theme?.statusWarning ?? .orange)
                            : .secondary
                    )
                    .help(
                        stageRevisionState == .stale
                            ? "文档已修改，旧阶段结果不可写回"
                            : "阶段输入绑定到当前文档版本"
                    )
            }
            Spacer()
            Button(action: newTab) {
                MinisIconView(
                    .add,
                    state: sessionID == nil ? .disabled : .normal,
                    size: 16,
                    accessibilityLabel: "新建会话文档 Tab"
                )
            }
            .buttonStyle(.plain)
            .help("新建会话文档 Tab")
            .disabled(sessionID == nil)

            Button(action: openDocument) {
                MinisIconView(
                    .folder,
                    state: sessionID == nil ? .disabled : .normal,
                    size: 16,
                    accessibilityLabel: "打开文本文件"
                )
            }
            .buttonStyle(.plain)
            .help("打开文本文件到当前会话")
            .disabled(sessionID == nil)

            Button(action: save) {
                MinisIconView(
                    .download,
                    state: selectedTab == nil ? .disabled : .normal,
                    size: 16,
                    accessibilityLabel: "保存当前文档"
                )
            }
            .buttonStyle(.plain)
            .help("保存当前文档")
            .disabled(selectedTab == nil)

            Button(action: saveAs) {
                MinisIconView(
                    .download,
                    state: selectedTab == nil ? .disabled : .normal,
                    size: 16,
                    accessibilityLabel: "另存为文本文件"
                )
            }
            .buttonStyle(.plain)
            .help("另存为文本文件")
            .disabled(selectedTab == nil)

            Button("文档阶段") { showsDocumentStages.toggle() }
                .disabled(selectedTab == nil)
                .accessibilityIdentifier("document.stages.toggle")

            Button(action: sendToConversation) {
                MinisIconView(
                    .upload,
                    state: selectedTab == nil ? .disabled : .normal,
                    size: 16,
                    accessibilityLabel: "发送当前文档到对话"
                )
            }
            .buttonStyle(.plain)
            .help("发送当前文档到对话")
            .disabled(selectedTab == nil)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var documentStages: some View {
        ScrollView {
            if let tab = selectedTab {
                if let pipeline = tab.documentPipeline {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("逐阶段执行，结果须人工审核；不会调用工具或画布。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(pipeline.stages.enumerated()), id: \.element.id) { index, stage in
                            stageRow(tab: tab, pipeline: pipeline, index: index, stage: stage)
                        }
                    }.padding(10)
                } else {
                    Button("启用当前文档的逐阶段文本流程") {
                        changePipeline(tab: tab) { value, _ in value = ManjuDocumentTemplate.make() }
                    }.disabled(stageTask != nil)
                }
            }
        }
        .frame(maxHeight: 320)
        .accessibilityIdentifier("document.stages.panel")
    }

    private func stageRow(tab: SessionDocumentTab, pipeline: DocumentPipeline,
                          index: Int, stage: DocumentStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1). \(stage.name)").font(.headline)
                Text((stage.execution?.state ?? .pending).displayName)
                    .accessibilityIdentifier("document.stage.state.\(stage.id)")
                Text(stage.status.displayName).foregroundStyle(.secondary)
            }
            Picker("Provider / 模型", selection: Binding(
                get: { chat.chatModelPickerItems.first { $0.providerID == stage.providerID && $0.modelID == stage.modelID }?.id ?? "" },
                set: { id in
                    guard let item = chat.chatModelPickerItems.first(where: { $0.id == id }) else { return }
                    changePipeline(tab: tab, stageID: stage.id) { value, currentIndex in
                        guard let index = currentIndex else { return }
                        guard value.stages[index].providerID != item.providerID
                            || value.stages[index].modelID != item.modelID else { return }
                        value.stages[index].providerID = item.providerID
                        value.stages[index].modelID = item.modelID
                        value.stages[index].execution = nil
                        value.stages[index].status = .pending
                        value.markDownstreamStale(fromIndex: index)
                        for j in value.stages.indices where j > index { value.stages[j].execution = nil }
                    }
                })) {
                Text("请选择已就绪的模型").tag("")
                ForEach(chat.chatModelPickerItems) { item in
                    Text("\(item.providerID) / \(item.modelID)").tag(item.id)
                }
            }.disabled(stageTask != nil)
            TextField("阶段提示词（使用 {{input}} 引用输入）", text: Binding(
                get: { chat.credentialBroker.protect(stage.promptTemplate) },
                set: { text in changePipeline(tab: tab, stageID: stage.id) { value, currentIndex in
                        guard let index = currentIndex else { return }
                    let protected = chat.credentialBroker.protect(text)
                    guard value.stages[index].promptTemplate != protected else { return }
                    value.stages[index].promptTemplate = protected
                    value.stages[index].execution = nil
                    value.stages[index].status = .pending
                    value.markDownstreamStale(fromIndex: index)
                    for j in value.stages.indices where j > index { value.stages[j].execution = nil }
                } }))
                .disabled(stageTask != nil)
                .accessibilityIdentifier("document.stage.prompt.\(stage.id)")
            if let message = stage.execution?.failureMessage {
                Text(message).modifier(ReadableStatusForeground(status: .danger))
            }
            if !stage.output.isEmpty {
                TextEditor(text: Binding(get: { chat.credentialBroker.protect(stage.output) }, set: { text in
                    changePipeline(tab: tab, stageID: stage.id) { value, currentIndex in
                        guard let index = currentIndex else { return }
                        let protected = chat.credentialBroker.protect(text)
                        guard value.stages[index].output != protected else { return }
                        value.stages[index].output = protected
                        value.stages[index].status = .awaitingReview
                        value.markDownstreamStale(fromIndex: index)
                        for j in value.stages.indices where j > index { value.stages[j].execution = nil }
                    }
                })).frame(minHeight: 72).disabled(stageTask != nil)
            }
            HStack {
                Button(stage.execution?.state == .failed ? "重试此阶段" : "执行此阶段") {
                    executeStage(tab: tab, index: index, stage: stage)
                }
                .disabled(stageTask != nil || stage.providerID.isEmpty || stage.modelID.isEmpty
                    || stage.execution?.state == .succeeded || stage.status == .done)
                if stageTask != nil { Button("停止阶段") { stageTask?.cancel() } }
                if !stage.output.isEmpty {
                    Button("结果新建为文档") {
                        do {
                            _ = try store.newTab(sessionID: tab.sessionID,
                                title: stage.name + "结果", content: chat.credentialBroker.protect(stage.output))
                            state = try store.documentStageState(sessionID: tab.sessionID)
                        } catch { errorMessage = "阶段结果未能新建为文档；原结果仍保留。" }
                    }.disabled(stageTask != nil)
                }
                Button("审核通过") {
                    changePipeline(tab: tab, stageID: stage.id) { value, currentIndex in
                        guard let index = currentIndex else { return }
                        DocumentStageRunner.confirmStage(pipeline: &value, index: index)
                    }
                }.disabled(stageTask != nil || stage.status != .awaitingReview)
                if stage.execution?.state == .succeeded || stage.status == .done {
                    Button("重新执行此阶段") {
                        changePipeline(tab: tab, stageID: stage.id) { value, currentIndex in
                        guard let index = currentIndex else { return }
                            value.stages[index].execution = nil
                            value.stages[index].status = .pending
                            value.markDownstreamStale(fromIndex: index)
                            for j in value.stages.indices where j > index { value.stages[j].execution = nil }
                        }
                    }.disabled(stageTask != nil)
                }
            }
        }.padding(8).background(Color.secondary.opacity(0.06))
    }

    private func changePipeline(tab: SessionDocumentTab, stageID: UUID? = nil,
                                _ update: (inout DocumentPipeline, Int?) -> Void) {
        guard stageTask == nil, sessionID == tab.sessionID, chat.activeSessionID == tab.sessionID,
              state.sessionID == tab.sessionID, state.selectedTabID == tab.id,
              let current = state.tabs.first(where: { $0.id == tab.id }),
              current.documentRevision == tab.documentRevision else {
            errorMessage = "文档或阶段已变化，请重新打开阶段面板。"
            return
        }
        var pipeline = current.documentPipeline ?? DocumentPipeline()
        let index = stageID.flatMap { id in pipeline.stages.firstIndex { $0.id == id } }
        guard stageID == nil || index != nil,
              !pipeline.stages.contains(where: { $0.execution?.state == .running }) else {
            errorMessage = "文档或阶段已变化，请重新打开阶段面板。"
            return
        }
        update(&pipeline, index)
        // An unchanged field preserves execution/review metadata. Still pass
        // the original Store CAS so an external writer is never skipped.
        do {
            _ = try store.setDocumentPipeline(sessionID: current.sessionID, tabID: current.id,
                pipeline: pipeline, expectedRevision: current.documentRevision,
                expectedPipeline: current.documentPipeline)
            state = store.state(for: current.sessionID)
        } catch { errorMessage = UserFacingErrorText.describe(error) }
    }

    private func providerRevisions() -> [String: String] {
        var result: [String: String] = [:]
        for record in chat.providerRecordsSource?() ?? [] {
            result[record.name] = chat.schedulerCredentialVersionSource?(record.name) ?? "unavailable"
        }
        return result
    }

    private func executeStage(tab: SessionDocumentTab, index: Int, stage: DocumentStage) {
        guard stageTask == nil, chat.activeSessionID == tab.sessionID,
              let item = chat.chatModelPickerItems.first(where: {
                  $0.providerID == stage.providerID && $0.modelID == stage.modelID
              }) else { return }
        do {
            let (pipeline, run, text) = try store.beginDocumentStage(sessionID: tab.sessionID,
                tabID: tab.id, index: index, expectedRevision: tab.documentRevision, expectedStage: stage)
            let revisions = providerRevisions()
            let providerRecords = chat.providerRecordsSource?()
            state = store.state(for: tab.sessionID)
            stageTaskTabID = tab.id
            stageTask = Task { @MainActor in
                defer {
                    stageTask = nil; stageTaskTabID = nil
                    if chat.activeSessionID == tab.sessionID { reload() }
                }
                do {
                    let provider = try await chat.prepareSelectedChildProvider(stableID: item.id, expectedItem: item)
                    try Task.checkCancellation()
                    guard chat.activeSessionID == tab.sessionID,
                          store.documentStageIsCurrent(sessionID: tab.sessionID, tabID: tab.id, stageID: stage.id, run: run),
                          providerRevisions() == revisions, chat.providerRecordsSource?() == providerRecords else { throw CancellationError() }
                    let invoke = DocumentStageRunner.makeLLM(provider: provider.value)
                    let ownerChat = chat
                    let documentStore = store
                    let output = try await DocumentStageRunner.runSessionStage(pipeline: pipeline,
                        index: index, documentContent: text, llm: { prompt in
                            let protected = try await MainActor.run {
                                var currentVersions: [String: String] = [:]
                                for record in ownerChat.providerRecordsSource?() ?? [] {
                                    currentVersions[record.name] = ownerChat.schedulerCredentialVersionSource?(record.name) ?? "unavailable"
                                }
                                guard ownerChat.activeSessionID == tab.sessionID,
                                      documentStore.documentStageIsCurrent(sessionID: tab.sessionID,
                                        tabID: tab.id, stageID: stage.id, run: run),
                                      ownerChat.chatModelPickerItems.first(where: { $0.id == item.id }) == item,
                                      currentVersions == revisions,
                                      ownerChat.providerRecordsSource?() == providerRecords else { throw CancellationError() }
                                return ownerChat.credentialBroker.protect(prompt)
                            }
                            try Task.checkCancellation()
                            return try await invoke(protected)
                        })
                    try Task.checkCancellation()
                    guard chat.activeSessionID == tab.sessionID,
                          chat.chatModelPickerItems.first(where: { $0.id == item.id }) == item,
                          providerRevisions() == revisions, chat.providerRecordsSource?() == providerRecords else { throw CancellationError() }
                    _ = try store.finishDocumentStage(sessionID: tab.sessionID, tabID: tab.id,
                        stageID: stage.id, run: run, output: chat.credentialBroker.protect(output), failure: nil)
                } catch {
                    let message = error is CancellationError ? "阶段已停止或输入已变化；原结果保留。"
                        : DocumentStageRunner.userFailureMessage(error) + " 原结果保留。"
                    do { _ = try store.finishDocumentStage(sessionID: tab.sessionID, tabID: tab.id,
                        stageID: stage.id, run: run, output: nil, failure: message) }
                    catch {
                        if chat.activeSessionID == tab.sessionID {
                            errorMessage = "阶段结果未能保存，请重新打开文档检查；原文未改动。"
                        }
                    }
                }
            }
        } catch { errorMessage = UserFacingErrorText.describe(error) }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(state.tabs) { tab in
                    tabButton(tab)
                }
                if state.tabs.isEmpty {
                    Text("当前会话还没有文档")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(minHeight: 32)
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor))
    }

    private func tabButton(_ tab: SessionDocumentTab) -> some View {
        let selected = tab.id == state.selectedTabID
        return HStack(spacing: 5) {
            Button {
                select(tabID: tab.id)
            } label: {
                HStack(spacing: 5) {
                    MinisIconView(
                        .document,
                        state: selected ? .active : .normal,
                        size: 12,
                        accessibilityLabel: tab.isDirty ? "未保存文档" : "会话文档"
                    )
                    Text(tab.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(selected ? accent : Color.primary)
            }
            .buttonStyle(.plain)

            Button {
                requestClose(tab)
            } label: {
                MinisIconView(
                    .close,
                    size: 12,
                    accessibilityLabel: "关闭文档 Tab"
                )
            }
            .buttonStyle(.plain)
            .help("关闭文档 Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? accent.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(selected ? accent : Color.clear)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if selectedTab == nil {
            VStack(spacing: 10) {
                MinisIconView(
                    .documentSearch,
                    size: 28,
                    accessibilityLabel: "文档搜索"
                )
                Text("选择或新建一个会话文档")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("新建文档", action: newTab)
                    .buttonStyle(.bordered)
                    .disabled(sessionID == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TextEditor(text: editorBinding)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { selectedTab?.text ?? "" },
            set: { value in
                guard let sessionID, let tabID = state.selectedTabID else { return }
                do {
                    if stageTaskTabID == tabID { stageTask?.cancel() }
                    let updated = try store.updateText(
                        sessionID: sessionID,
                        tabID: tabID,
                        text: value
                    )
                    replace(updated)
                    refreshRecoveryStatus(for: sessionID)
                } catch {
                    errorMessage = UserFacingErrorText.describe(error)
                }
            }
        )
    }

    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { closeTargetID != nil },
            set: { if !$0 { closeTargetID = nil } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reload() {
        stageInputSnapshot = nil
        errorMessage = nil
        guard let sessionID else {
            state = SessionDocumentSessionState(sessionID: UUID())
            return
        }
        state = store.restoreSession(sessionID)
        do {
            try store.recoverInterruptedDocumentStages(sessionID: sessionID)
            state = try store.documentStageState(sessionID: sessionID)
        } catch { errorMessage = "阶段恢复记录不可读；原文保留，请检查恢复文件。" }
        if store.hasRecoveryFailure(for: sessionID) {
            errorMessage = store.recoveryDiagnostic(for: sessionID)
                ?? "会话文档恢复文件已隔离，当前显示为空白状态；请检查隔离备份后再继续编辑。"
        }
    }

    private func replace(_ tab: SessionDocumentTab) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        state.tabs[index] = tab
    }

    private func newTab() {
        guard let sessionID else { return }
        do {
            let tab = try store.newTab(sessionID: sessionID, title: "未命名文档")
            state = store.state(for: sessionID)
            state.selectedTabID = tab.id
            stageInputSnapshot = nil
            refreshRecoveryStatus(for: sessionID)
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func select(tabID: UUID) {
        guard let sessionID else { return }
        do {
            _ = try store.selectTab(sessionID: sessionID, tabID: tabID)
            state = store.state(for: sessionID)
            stageInputSnapshot = nil
            refreshRecoveryStatus(for: sessionID)
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func openDocument() {
        guard let sessionID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try store.openDocument(sessionID: sessionID, fileURL: url)
            state = store.state(for: sessionID)
            stageInputSnapshot = nil
            refreshRecoveryStatus(for: sessionID)
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func save() {
        guard let sessionID, let tabID = state.selectedTabID else { return }
        do {
            let saved = try store.save(sessionID: sessionID, tabID: tabID)
            replace(saved)
            refreshRecoveryStatus(for: sessionID)
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func saveAs() {
        guard let sessionID, let tabID = state.selectedTabID else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = selectedTab?.title ?? "未命名文档"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let saved = try store.saveAs(sessionID: sessionID, tabID: tabID, to: url)
            replace(saved)
            refreshRecoveryStatus(for: sessionID)
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func requestClose(_ tab: SessionDocumentTab) {
        guard let sessionID else { return }
        do {
            if !tab.isDirty, stageTaskTabID == tab.id { stageTask?.cancel() }
            let result = try store.closeTab(sessionID: sessionID, tabID: tab.id)
            if result == .requiresConfirmation {
                closeTargetID = tab.id
            } else {
                if result == .closed, stageTaskTabID == tab.id { stageTask?.cancel() }
                state = store.state(for: sessionID)
                refreshRecoveryStatus(for: sessionID)
            }
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func resolveClose(_ decision: SessionDocumentCloseDecision) {
        guard let sessionID, let tabID = closeTargetID else { return }
        do {
            if decision != .cancel, stageTaskTabID == tabID { stageTask?.cancel() }
            _ = try store.closeTab(
                sessionID: sessionID,
                tabID: tabID,
                decision: decision
            )
            closeTargetID = nil
            state = store.state(for: sessionID)
            stageInputSnapshot = nil
            refreshRecoveryStatus(for: sessionID)
        } catch {
            closeTargetID = nil
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func sendToConversation() {
        guard let sessionID, let tabID = state.selectedTabID else { return }
        do {
            let snapshot = try store.sendToConversation(sessionID: sessionID, tabID: tabID)
            stageInputSnapshot = snapshot
            chat.draftText = "请处理会话文档「\(snapshot.title)」：\n\n\(snapshot.text)"
            chat.submitComposer()
        } catch {
            errorMessage = UserFacingErrorText.describe(error)
        }
    }

    private func refreshRecoveryStatus(for sessionID: UUID) {
        if store.hasRecoveryFailure(for: sessionID) {
            errorMessage = store.recoveryDiagnostic(for: sessionID)
                ?? "会话文档恢复清理未完成，隔离备份已保留；请检查隔离证据后再继续编辑。"
        } else {
            errorMessage = store.documentStageCloseWarning(sessionID: sessionID)
        }
    }
}
