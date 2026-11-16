import SwiftUI

@MainActor
struct P03CleanupAppView: View {
    @Bindable var controller: P03CleanupAppController
    @Bindable var approvalCenter: ApprovalPromptCenter
    var shortcutStore: ShortcutStore?
    @Environment(\.dismiss) private var dismiss

    /// Same condition and dismissal as the task-center approval sheet in
    /// ContentView, hosted here while this panel owns the sheet stack.
    private var approvalBinding: Binding<Bool> {
        let actions = approvalCenter.actionsForPresentedRequest()
        return Binding(
            get: { approvalCenter.isPromptPresented },
            set: { if !$0 { actions.dismiss() } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("残留子任务隔离工作树").font(.headline)
            Text("仅列出本次运行捕获的真实隔离资源。只移目录到废纸篓；Git 登记与分支保留，后续元数据处理需另行逐次确认。")
                .foregroundStyle(.secondary)
            Text("完整流程分开确认：准备与执行前各一次只读检查审批，共两次；移动精确目录到废纸篓另需一次确认。")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("p03-cleanup.approval-stages")
            ScrollView {
                if controller.rows.isEmpty { Text("当前没有已捕获的残留隔离资源。") }
                ForEach(controller.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务：\(row.snapshot.allocation.identity.taskID)")
                        Text("会话：\(row.snapshot.allocation.identity.parentSessionID)")
                        Text(row.snapshot.allocation.workingDirectory).textSelection(.enabled)
                        Text("分支：\(row.snapshot.allocation.branch)")
                        Text(row.status).accessibilityIdentifier("p03-cleanup.status.\(row.id)")
                        if let result = row.result {
                            Text("原路径：\(result.originalPath)").textSelection(.enabled)
                            Text("废纸篓位置：\(result.trashURL.path)").textSelection(.enabled)
                            Text("如需恢复，请从废纸篓放回上述原路径，原 Git 登记可继续使用。没有自动 prune 或删除分支。")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Button("刷新状态") { Task { await controller.refresh(row.id) } }
                                    .disabled(row.isBusy)
                                Button("检查并移到废纸篓…") { Task { await controller.prepare(row.id) } }
                                    .disabled(!row.canPrepare || controller.confirmation != nil)
                            }
                        }
                    }
                    .padding(10)
                    Divider()
                }
            }
            Button("关闭") { dismiss() }
        }
        .padding(20).frame(minWidth: 600, minHeight: 400)
        .alert("确认移动隔离目录", isPresented: Binding(
            get: { controller.confirmation != nil },
            set: { if !$0 { controller.cancelConfirmation() } }
        ), presenting: controller.confirmation) { confirmation in
            Button("移到废纸篓", role: .destructive) {
                controller.confirm(confirmation.id)
            }
            Button("取消", role: .cancel) { controller.cancelConfirmation() }
        } message: { confirmation in
            Text(confirmation.request.approvalText)
        }
        .sheet(isPresented: approvalBinding) {
            // This sheet is nested in the task-center and panel sheets and is
            // sized by the shared card's flexible ScrollView, which has no
            // lower bound: give it enough height that the action row below the
            // details is never squeezed out of reach. The shared card is
            // unchanged.
            ApprovalPromptView(center: approvalCenter, shortcutStore: shortcutStore)
                .frame(minHeight: 280)
        }
        .task { await controller.refreshAll() }
        .onDisappear {
            controller.isPanelPresented = false
            controller.cancelConfirmation()
        }
        .accessibilityIdentifier("p03-cleanup.residual-list")
    }
}
