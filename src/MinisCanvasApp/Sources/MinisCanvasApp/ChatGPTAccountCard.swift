import AppKit
import Observation
import SwiftUI
import MinisCore

/// Drives "Continue with ChatGPT" in settings. Tokens stay inside `ChatGPTAccountSession`;
/// this type only holds status text and the sign-in task.
@MainActor
@Observable
final class ChatGPTAccountController {
    enum Phase: Equatable { case idle, signingIn, signingOut }

    private static let welcomeShownKey = "MinisCanvas.chatgptAccount.welcomeShown"

    var status: ChatGPTAccountStatus = .signedOut
    var phase: Phase = .idle
    var message: String?
    var showWelcome = false
    private var task: Task<Void, Never>?
    private let session: ChatGPTAccountSession?

    init(session: ChatGPTAccountSession? = ChatGPTAccountSessions.shared) {
        self.session = session
    }

    func refresh() async {
        guard let session else { return }
        status = await session.status()
    }

    func signIn(center: SettingsCenter, replaceAccount: Bool) {
        guard let session, phase == .idle else { return }
        phase = .signingIn
        message = nil
        task = Task { [weak self] in
            var result: String?
            do {
                let info = try await session.login(replaceRegistration: replaceAccount) { url in
                    await MainActor.run { NSWorkspace.shared.open(url) }
                }
                result = try await self?.provisionProvider(center: center, session: session, label: info.label)
            } catch {
                result = (error as? ChatGPTAccountError ?? .requestFailed).localizedDescription
            }
            guard let self else { return }
            self.message = result
            self.status = await session.status()
            self.phase = .idle
        }
    }

    /// 取账号可用模型并保存 ChatGPT 服务商；登录后和“重新获取模型”共用。
    private func provisionProvider(center: SettingsCenter, session: ChatGPTAccountSession, label: String) async throws -> String {
        let models = try await session.availableModels()
        let saved = center.saveProvider(
            name: ChatGPTAccountSession.providerName,
            credential: .replace(ChatGPTAccountSession.credentialPlaceholder),
            baseURL: ChatGPTAccountEndpoints.resource,
            modelNames: models.map(\.slug),
            protocolType: .openaiResponses,
            displayName: "ChatGPT 账号")
        guard saved else { return "已登录，但保存模型供应商失败，请点“重新获取模型”重试。" }
        let check = center.startProviderReadinessAfterSave(forProviderName: ChatGPTAccountSession.providerName)
        // 检查结果出来后把“通过”或“失败原因”写回卡片，不让用户对着“未验证”猜。
        Task { [weak self] in
            let report = await check.value
            self?.message = Self.readinessSummary(report, label: label)
        }
        if !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomeShownKey)
            showWelcome = true
        }
        return "已登录 \(label)，正在检查可用模型。"
    }

    /// 已登录但服务商没建成（取模型失败等）时，不必退出重登，直接重新取一次。
    func retryModels(center: SettingsCenter) {
        guard let session, phase == .idle, case .signedIn(let info) = status else { return }
        phase = .signingIn
        message = "正在重新获取模型…"
        task = Task { [weak self] in
            var result: String
            do {
                result = try await self?.provisionProvider(center: center, session: session, label: info.label) ?? ""
            } catch {
                result = (error as? ChatGPTAccountError ?? .requestFailed).localizedDescription
            }
            guard let self else { return }
            self.message = result
            self.status = await session.status()
            self.phase = .idle
        }
    }

    /// 已登录但账号模型还没有任何通过的检查（例如登录后检查没跑完就退出）时，进入设置页补做一次。
    private var autoCheckStarted = false
    func checkIfNeeded(center: SettingsCenter) async {
        guard !autoCheckStarted, phase == .idle, case .signedIn(let info) = status else { return }
        let name = ChatGPTAccountSession.providerName
        guard center.providerExists(named: name) else { return }
        let passed = center.providerReadinessStore.records.contains {
            $0.providerID.caseInsensitiveCompare(name) == .orderedSame && $0.status == .passed
        }
        guard !passed else { return }
        autoCheckStarted = true
        message = "正在检查可用模型。"
        let report = await center.startProviderReadinessAfterSave(forProviderName: name).value
        message = Self.readinessSummary(report, label: info.label)
    }

    /// 把一次连接检查的结果写成一句话：通过，或“原因 + 下一步”。
    static func readinessSummary(_ report: SettingsProviderReadinessReport?, label: String) -> String {
        guard let report else { return "已登录 \(label)，但这次模型检查没有完成，请稍后在设置里重新检查。" }
        if report.modelChecks.contains(where: { $0.status == .passed }) {
            return "已登录 \(label)，模型连接检查通过。"
        }
        if let failed = report.modelChecks.first(where: { $0.status == .failed }), let category = failed.errorCategory {
            let m = HTTPStatusMessages.providerReadinessMessage(for: category)
            return "已登录，但模型检查未通过：\(m.zh)。\(m.suggestionZH)。"
        }
        let stages = [report.configuration, report.reachability, report.authentication, report.modelDiscovery]
        if let stage = stages.first(where: { $0.status == .failed }), !stage.detail.isEmpty {
            return "已登录，但模型检查未通过：\(stage.detail)。"
        }
        return "已登录，但模型检查未通过，请稍后在设置里重新检查。"
    }

    /// Cancels a sign-in that is still waiting for the browser.
    func cancelSignIn() {
        task?.cancel()
        let session = self.session
        Task { await session?.cancelLogin() }
    }

    func signOut(center: SettingsCenter) {
        guard let session, phase == .idle else { return }
        phase = .signingOut
        task = Task { [weak self] in
            let revoked = await session.logout()
            let name = ChatGPTAccountSession.providerName
            if center.providerExists(named: name),
               let intent = try? center.previewProviderDeletion(name: name) {
                _ = try? center.deleteProvider(name: name, intent: intent)
            }
            guard let self else { return }
            self.message = revoked
                ? "已退出 ChatGPT 登录。"
                : "已在本机退出，但没能确认 ChatGPT 端已撤销授权。可到 ChatGPT 设置里断开本应用。"
            self.status = await session.status()
            self.phase = .idle
        }
    }
}

struct ChatGPTAccountCard: View {
    let center: SettingsCenter
    @State private var controller = ChatGPTAccountController()
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("使用你的 ChatGPT 套餐").font(typography?.headline ?? .headline)
            Text("符合条件的请求会使用 ChatGPT 套餐包含的用量或积分，与本应用自身的订阅或收费无关。登录在官方网页完成，本应用不会看到你的密码。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            statusLine
            HStack(spacing: 8) { actions }
            if let message = controller.message {
                Text(message).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.chatgpt-account.message")
            }
            Link("管理用量（Manage usage）", destination: ChatGPTAccountEndpoints.usageSettingsURL)
                .font(typography?.caption ?? .caption)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .accessibilityIdentifier("settings.chatgpt-account")
        .task {
            await controller.refresh()
            await controller.checkIfNeeded(center: center)
        }
        .alert("你正在使用你的 ChatGPT 套餐", isPresented: $controller.showWelcome) {
            Button("知道了") {}
        } message: {
            Text("符合条件的 AI 请求会使用 ChatGPT 套餐的用量，可随时在 ChatGPT 设置 → 用量中查看和管理。")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch controller.status {
        case .signedOut:
            Text("未登录").font(typography?.caption ?? .caption)
        case .signedIn(let info):
            Text("已登录：\(info.label)（使用 ChatGPT 套餐）").font(typography?.caption ?? .caption)
        case .needsRelogin(let info):
            Text("登录已过期\(info.map { "：\($0.label)" } ?? "")，请重新登录")
                .font(typography?.caption ?? .caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var actions: some View {
        switch controller.phase {
        case .signingIn:
            ProgressView().controlSize(.small)
            Text("请在浏览器里完成登录…").font(typography?.caption ?? .caption)
            Button("取消") { controller.cancelSignIn() }
                .accessibilityIdentifier("settings.chatgpt-account.cancel")
        case .signingOut:
            ProgressView().controlSize(.small)
        case .idle:
            switch controller.status {
            case .signedIn:
                if !center.providerExists(named: ChatGPTAccountSession.providerName) {
                    Button("重新获取模型") { controller.retryModels(center: center) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.chatgpt-account.retry-models")
                }
                Button("退出登录") { controller.signOut(center: center) }
                    .accessibilityIdentifier("settings.chatgpt-account.sign-out")
                Menu("更多") {
                    Button("使用其他账号登录") { controller.signIn(center: center, replaceAccount: true) }
                }
                .fixedSize()
            case .signedOut, .needsRelogin:
                Button("Continue with ChatGPT") { controller.signIn(center: center, replaceAccount: false) }
                    .buttonStyle(.borderedProminent).tint(.black)
                    .accessibilityIdentifier("settings.chatgpt-account.sign-in")
                Menu("更多") {
                    Button("使用其他账号登录") { controller.signIn(center: center, replaceAccount: true) }
                }
                .fixedSize()
            }
        }
    }
}
