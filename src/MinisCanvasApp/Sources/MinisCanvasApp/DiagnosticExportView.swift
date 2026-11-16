import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MinisCore

/// Local diagnostic surface. Opening it and exporting never run a check.
struct DiagnosticExportView: View {
    @Bindable var controller: DiagnosticExportController
    @Bindable var healthController: DiagnosticHealthRunController
    var restartInSafeMode: () -> Void = {}
    var openSettings: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var exportTask: Task<Void, Never>?
    @State private var healthTask: Task<Void, Never>?
    @State private var confirmStorageProbe = false
    @State private var confirmSafeRestart = false
    @State private var copiedLocalStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("状态与自检", systemImage: "stethoscope")
                .font(.title2.weight(.semibold))

            Text("导出一个仅保存在本机的 JSON 诊断快照，帮助定位版本、平台和固定模块的健康状态。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("包含")
                    .font(.headline)
                Text("版本、平台、五个固定模块（环境、本地后端、网络、Provider、存储）的状态、快照时间和有限运行状态。")
                Text("不包含凭据、环境值、Authorization/Cookie、带凭据 URL、完整对话、草稿、提示词、附件、绝对路径或原始错误。")
                    .foregroundStyle(.secondary)
                Text("导出不会运行健康检查或触发网络探测。没有新鲜检查结果的模块显示“未知”，不能据此判断整体健康。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                Text("运行阶段")
                    .font(.headline)
                Text(controller.visibleRuntimePhase)
                    .accessibilityIdentifier("diagnostics.runtime.phase")
                Text("这里只显示应用和当前会话活动；模块健康以各项检查状态为准。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            localStatusSection
            healthSection
            statusView

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(controller.isExporting ? "取消导出" : "选择位置并导出") {
                    if controller.isExporting {
                        controller.cancel()
                    } else {
                        chooseDestinationAndExport()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isExporting && exportTask == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { healthController.refreshReadOnlyStatus() }
        .confirmationDialog("允许检查本次隔离临时目录？", isPresented: $confirmStorageProbe, titleVisibility: .visible) {
            Button("创建、读回并移除临时探针") {
                healthTask = Task { @MainActor in await healthController.run() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会写入本次隔离 profile 的临时目录，不修改其他数据；取消不会执行写入测试。")
        }
        .confirmationDialog("以安全模式正常退出并重启？", isPresented: $confirmSafeRestart, titleVisibility: .visible) {
            Button("保存安全模式并重启") { restartInSafeMode() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("禁用技能、MCP 和其他可选模块；保持当前应用包与设置作用域。现有任务先按正常退出流程收尾，不会复制凭据或重新播种现场数据。")
        }
        .onDisappear {
            healthTask?.cancel()
            healthController.cancel()
            exportTask?.cancel()
            controller.cancel()
        }
    }

    private var localStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("刷新只读状态") { healthController.refreshReadOnlyStatus() }
                    .accessibilityIdentifier("diagnostics.status.refresh")
                Button("复制脱敏报告") {
                    NSPasteboard.general.clearContents()
                    copiedLocalStatus = NSPasteboard.general.setString(healthController.localStatusText, forType: .string)
                }
                .accessibilityIdentifier("diagnostics.status.copy")
                if copiedLocalStatus { Text("已复制本地状态快照").foregroundStyle(.secondary) }
            }
            Text("以下为已保存或已观察的本地状态，不会自动检查网络、读取凭据或修复数据。缓存检查不代表现在仍然就绪。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(healthController.localStatuses) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline)
                            Text(ContentSecretRedactor.redact(row.message))
                            if row.id == "permissions" {
                                Text(healthController.defaultKeychainStatusText)
                                    .accessibilityIdentifier("diagnostics.keychain.status")
                                Text("仅本人点击查询默认库元数据；未使用凭据内容接口。系统如需交互，请由本人处理。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("检查默认钥匙串库状态（仅本人）") {
                                    Task { await healthController.checkDefaultKeychainStatus() }
                                }
                                .disabled(healthController.defaultKeychainStatus == .checking)
                                .accessibilityIdentifier("diagnostics.keychain.check")
                            }
                            if let date = row.checkedAt {
                                Text("已有检查时间：" + date.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(ContentSecretRedactor.redact("怎么办：" + row.nextStep)).font(.caption).foregroundStyle(.secondary)
                            Button("去设置") { openSettings(row.settingsPageID) }
                                .accessibilityLabel("去设置：" + row.title)
                                .accessibilityIdentifier("diagnostics.settings." + row.id)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 250)
            Button("安全模式重启") { confirmSafeRestart = true }
                .disabled(healthController.safeRestartRequested)
                .accessibilityIdentifier("diagnostics.safe-restart")
            if let message = healthController.safeRestartMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("安全设置") { openSettings("settings-tab-safety") }
                .accessibilityIdentifier("diagnostics.settings.safety")
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("隔离临时目录检查")
                .font(.headline)
            Text("仅在已验证的隔离运行环境内，点击按钮后写入、读回并移除本次创建的临时探针。生产或受阻运行环境不可检查。")
                .foregroundStyle(.secondary)
            Text("仅最近 10 分钟内完成的同一隔离 profile 快照可供导出；过期或时钟回拨均按未知处理。")
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    Text("环境、本地后端、网络、Provider：未检测。存储（隔离临时目录）：\(storageStatusLabel)。这不是整体健康结论。")
                        .foregroundStyle(.secondary)
                    healthRunStatus
                }
            }
            Button(healthController.isRunning ? "取消目录检查" : "运行隔离目录检查") {
                if healthController.isRunning {
                    healthController.cancel()
                    healthTask?.cancel()
                } else {
                    confirmStorageProbe = true
                }
            }
            .disabled(!healthController.canRun && !healthController.isRunning)
        }
        .font(.callout)
    }

    private var storageStatusLabel: String {
        switch healthController.storageStatus {
        case .ok: "最近完成的检查：可写"
        case .error: "最近完成的检查：不可写"
        case .warning, nil: "未知"
        }
    }

    @ViewBuilder
    private var healthRunStatus: some View {
        switch healthController.state {
        case .unavailable:
            Text("当前不是可验证的隔离 profile；未运行目录检查。")
                .foregroundStyle(.secondary)
        case .idle:
            Text("尚未运行目录检查。")
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在检查隔离临时目录；导出仍只消费上次新鲜完成的结果。")
            }
        case .completed(let date):
            Text(healthController.hasFreshSnapshot
                 ? "目录检查完成于 \(date.formatted(date: .abbreviated, time: .standard))。"
                 : "上次检查已过期；导出中的健康模块将显示未知。")
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("目录检查已取消；上次完成的结果只在未过期时可供导出。")
                .foregroundStyle(.secondary)
        case .failed:
            Text("目录检查未能安全完成；上次完成的结果只在未过期时可供导出。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.state {
        case .idle:
            Text("选择一个本地保存位置后开始导出。")
                .foregroundStyle(.secondary)
        case .exporting:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在生成并验证诊断包…")
            }
        case .succeeded(let receipt):
            Label {
                Text("已完成：\(receipt.destinationURL.lastPathComponent)（\(receipt.byteCount) 字节）")
            } icon: {
                MinisIconView(.check, state: .success, size: 14, accessibilityLabel: "已完成")
            }
        case .cancelled:
            Label {
                Text("导出已取消，目标文件未改变。")
            } icon: {
                MinisIconView(.close, size: 14)
                    .accessibilityHidden(true)
            }
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Label {
                Text(reason.message)
            } icon: {
                MinisIconView(.warning, state: .danger, size: 14)
                    .accessibilityHidden(true)
            }
                .modifier(ReadableStatusForeground(status: .danger))
        }
    }

    private func chooseDestinationAndExport() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = DiagnosticBundleExporter.defaultFilename()
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        controller.reset()
        exportTask?.cancel()
        exportTask = Task { @MainActor in
            await controller.export(to: destinationURL)
        }
    }
}
