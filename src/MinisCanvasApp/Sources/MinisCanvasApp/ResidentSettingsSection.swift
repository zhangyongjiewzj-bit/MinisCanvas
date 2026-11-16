import SwiftUI
import ServiceManagement

struct ResidentSettingsSection: View {
    @State private var resident = ResidentLifecycleController.shared

    var body: some View {
        Section("后台与登录") {
            Toggle("登录时启动", isOn: Binding(
                get: { resident.loginStatus == .enabled || resident.loginStatus == .requiresApproval },
                set: { resident.setLaunchAtLogin($0) }
            ))
            if resident.loginStatus == .requiresApproval {
                Text("请在系统设置的登录项中允许 MinisCanvas。").foregroundStyle(.secondary)
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            } else if resident.loginStatus == .notFound {
                Text("系统未找到可注册的应用；请使用安装后的签名应用。").foregroundStyle(.secondary)
            }
            Toggle("任务运行时保持唤醒", isOn: $resident.keepAwakeDuringWork)
            Text("仅在任务实际运行期间保持系统唤醒，等待下次定时触发时允许休眠；合盖仍会休眠。关闭最后一个窗口后，应用继续在菜单栏运行。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = resident.failureMessage { Text(message).modifier(ReadableStatusForeground(status: .danger)) }
        }
        .onAppear { resident.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resident.refreshLoginStatus()
        }
    }
}
