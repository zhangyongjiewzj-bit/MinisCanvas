import SwiftUI

struct SystemNotificationSettingsSection: View {
    @Bindable var controller: SystemNotificationController
    @State private var permissionTask: Task<Void, Never>?
    var body: some View {
        Section("通知") {
            ForEach(SystemNotificationCategory.allCases) { category in
                Toggle(category.label, isOn: Binding(get: { controller.isEnabled(category) },
                    set: { controller.setEnabled(category, $0) }))
                    .accessibilityLabel(category.label)
                    .accessibilityIdentifier("settings.notifications." + category.rawValue)
            }
            Text(controller.message).foregroundStyle(.secondary)
            Button(controller.isRequesting ? "正在请求系统授权…" : "允许系统通知") {
                permissionTask = Task { await controller.enableFromUserAction() }
            }
            .disabled(!controller.canRequestAuthorization)
            .accessibilityIdentifier("settings.notifications.authorize")
            Button("重新检查系统通知权限") {
                permissionTask = Task { await controller.refreshAuthorizationStatus() }
            }
            .disabled(!controller.canRequestAuthorization)
        }
        .task { await controller.refreshAuthorizationStatus() }
        .onChange(of: controller.isModuleActive) { _, active in
            permissionTask?.cancel()
            permissionTask = nil
            if active { permissionTask = Task { await controller.refreshAuthorizationStatus() } }
        }
        .onDisappear {
            permissionTask?.cancel()
            permissionTask = nil
            controller.cancelAuthorizationRequest()
        }
    }
}
