import SwiftUI
import MinisCore

/// Provider-local status used by the Settings list.  It intentionally accepts
/// only one provider's report and model states, so a failed sibling cannot
/// contaminate this summary.
enum ProviderLocalSummaryState: String, Equatable, Sendable {
    case blocked
    case checking
    case ready
}

enum ProviderLocalSummaryAction: String, Equatable, Sendable {
    case checkReadiness
    case retryReadiness
    case replaceAPIKey
    case none

    var title: String? {
        switch self {
        case .checkReadiness: return "检查就绪"
        case .retryReadiness: return "重试检查"
        case .replaceAPIKey: return "替换 API Key"
        case .none: return nil
        }
    }

    var accessibilityHint: String? {
        switch self {
        case .checkReadiness: return "只检查当前供应商，不改变其他供应商状态"
        case .retryReadiness: return "重试当前供应商的就绪检查"
        case .replaceAPIKey: return "打开当前供应商表单并输入新 API Key"
        case .none: return nil
        }
    }
}

struct ProviderLocalReadinessSummary: Equatable, Sendable, Identifiable {
    let providerID: String
    let state: ProviderLocalSummaryState
    /// Shared stable projection consumed by the chat model picker.
    let projectionState: ProviderReadinessProjectionState?
    let projectionReason: ProviderReadinessProjectionReason?
    let message: String
    let action: ProviderLocalSummaryAction

    var id: String { providerID }
    var isActionable: Bool { action != .none }

    /// Aggregate one provider only.  The report and model states are already
    /// scoped by the caller; no global readiness state is consulted.
    static func aggregate(
        providerID: String,
        report: SettingsProviderReadinessReport?,
        modelStates: [ProviderModelReadiness],
        isChecking: Bool
    ) -> Self {
        if isChecking || modelStates.contains(where: { $0.status == .loading }) {
            return Self(
                providerID: providerID,
                state: .checking,
                projectionState: nil,
                projectionReason: nil,
                message: "正在检查此供应商；其他供应商状态不受影响。",
                action: .none
            )
        }

        if let report {
            if report.authentication.status == .failed {
                return blocked(
                    providerID: providerID,
                    projectionState: .blocked,
                    message: "鉴权失败；请直接替换 API Key。",
                    action: .replaceAPIKey
                )
            }
            if report.configuration.status == .failed {
                return blocked(
                    providerID: providerID,
                    projectionState: .blocked,
                    message: "配置失败；请检查 Base URL 和 API Key。",
                    action: .retryReadiness
                )
            }
            if report.reachability.status == .failed {
                return blocked(
                    providerID: providerID,
                    projectionState: .blocked,
                    message: "供应商不可达；请检查 Base URL 或网络。",
                    action: .retryReadiness
                )
            }
            if report.modelDiscovery.status == .failed {
                return blocked(
                    providerID: providerID,
                    projectionState: .blocked,
                    message: "模型发现失败；请重试检查。",
                    action: .retryReadiness
                )
            }
            if modelStates.contains(where: { $0.status == .failed })
                || report.state == .unverified
                || report.state == .blocked {
                return blocked(
                    providerID: providerID,
                    projectionState: report.state == .blocked ? .blocked : .unverified,
                    message: "模型就绪检查未通过；请重试检查。",
                    action: .retryReadiness
                )
            }
            if report.state != .blocked, report.state != .unverified {
                return ready(
                    providerID: providerID,
                    projectionState: .init(
                        readinessState: report.state,
                        status: .passed
                    )
                )
            }
        }

        if !modelStates.isEmpty, modelStates.allSatisfy({ $0.status == .passed }) {
            return ready(
                providerID: providerID,
                projectionState: modelStates.compactMap { $0.readiness?.state }
                    .first.map { .init(readinessState: $0, status: .passed) }
                    ?? .unknown
            )
        }
        return blocked(
            providerID: providerID,
            projectionState: .unverified,
            message: "尚未验证；请检查此供应商的就绪状态。",
            action: .checkReadiness
        )
    }

    /// Direct consumer seam: Settings and the chat picker can render the same
    /// per-model projection and fail-closed reason without re-deriving status.
    static func aggregate(
        providerID: String,
        projection: ChatModelPickerProjection,
        isChecking: Bool
    ) -> Self {
        if isChecking {
            return Self(
                providerID: providerID,
                state: .checking,
                projectionState: nil,
                projectionReason: nil,
                message: "正在检查此供应商；其他供应商状态不受影响。",
                action: .none
            )
        }
        let items = (projection.items + projection.pending).filter {
            $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
        }
        guard !items.isEmpty else {
            return blocked(
                providerID: providerID,
                projectionState: .unverified,
                message: "尚未验证；请检查此供应商的就绪状态。",
                action: .checkReadiness
            )
        }
        if let blockedItem = items.first(where: \.isBlocked) {
            return blocked(
                providerID: providerID,
                projectionState: blockedItem.projectionState,
                message: "供应商就绪检查已阻断；请重试检查。",
                action: .retryReadiness
            )
        }
        if let unverifiedItem = items.first(where: { $0.projectionState == .unverified }) {
            return blocked(
                providerID: providerID,
                projectionState: unverifiedItem.projectionState,
                message: "供应商就绪检查尚未验证；请重试检查。",
                action: .retryReadiness
            )
        }
        let state = items.first?.projectionState ?? .unknown
        guard items.allSatisfy(\.isSelectable) else {
            return blocked(
                providerID: providerID,
                projectionState: state,
                message: "供应商就绪检查未通过；请重试检查。",
                action: .retryReadiness
            )
        }
        return ready(providerID: providerID, projectionState: state)
    }

    private static func ready(
        providerID: String,
        projectionState: ProviderReadinessProjectionState
    ) -> Self {
        Self(
            providerID: providerID,
            state: .ready,
            projectionState: projectionState,
            projectionReason: .init(state: projectionState),
            message: "此供应商已就绪。",
            action: .none
        )
    }

    private static func blocked(
        providerID: String,
        projectionState: ProviderReadinessProjectionState,
        message: String,
        action: ProviderLocalSummaryAction
    ) -> Self {
        Self(
            providerID: providerID,
            state: .blocked,
            projectionState: projectionState,
            projectionReason: .init(state: projectionState),
            message: message,
            action: action
        )
    }
}

/// Explicit successor-rebind transition helper.  A new check is visible as
/// `checking` before its terminal report arrives, then reduces to the same
/// provider-local aggregate without inheriting a sibling's failure.
enum ProviderLocalReadinessTransition {
    static func successorRebindStarted(providerID: String) -> ProviderLocalReadinessSummary {
        ProviderLocalReadinessSummary(
            providerID: providerID,
            state: .checking,
            projectionState: nil,
            projectionReason: nil,
            message: "正在重新绑定此供应商；其他供应商状态不受影响。",
            action: .none
        )
    }

    static func successorRebindCompleted(
        providerID: String,
        report: SettingsProviderReadinessReport,
        modelStates: [ProviderModelReadiness]
    ) -> ProviderLocalReadinessSummary {
        ProviderLocalReadinessSummary.aggregate(
            providerID: providerID,
            report: report,
            modelStates: modelStates,
            isChecking: false
        )
    }
}

struct ProviderLocalReadinessSummaryView: View {
    @Environment(\.themeTokens) private var theme
    let summary: ProviderLocalReadinessSummary
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            MinisIconView(icon, size: MinisIconTokens.smallSize)
                .foregroundPalette(iconColor)
                .accessibilityHidden(true)
            Text(summary.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let actionTitle = summary.action.title {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel(actionTitle)
                    .accessibilityHint(summary.action.accessibilityHint ?? "")
                    .accessibilityIdentifier("settings.provider.local-summary.action")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("供应商就绪摘要")
        .accessibilityValue(summary.message)
        .accessibilityIdentifier("settings.provider.local-summary.\(summary.providerID)")
    }

    private var icon: MinisIcon {
        switch summary.state {
        case .blocked: return .warning
        case .checking: return .spinner
        case .ready: return .success
        }
    }

    private var iconColor: Color {
        switch summary.state {
        case .blocked: return theme?.statusDanger ?? .red
        case .checking: return theme?.statusWarning ?? .orange
        case .ready: return theme?.statusSuccess ?? .green
        }
    }
}
