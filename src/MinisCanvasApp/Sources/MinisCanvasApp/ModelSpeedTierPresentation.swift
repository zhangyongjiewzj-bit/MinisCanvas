import SwiftUI
import MinisCore

/// The App-layer visual contract for model speed tiers.
struct ModelSpeedTierPresentation: Equatable, Sendable {
    let tier: ModelSpeedTier
    let icon: MinisIcon
    let label: String

    var accessibilityLabel: String { label }

    init(_ tier: ModelSpeedTier) {
        self.tier = tier
        switch tier {
        case .ultraFast:
            icon = .activity
            label = "极快"
        case .fast:
            icon = .next
            label = "快"
        case .balanced:
            icon = .settings
            label = "均衡"
        case .quality:
            icon = .target
            label = "质量"
        }
    }

    func iconState(selected: Bool) -> MinisIconState {
        selected ? .active : .normal
    }

    @MainActor
    @ViewBuilder
    func iconView(selected: Bool, size: CGFloat = MinisIconTokens.defaultSize) -> some View {
        MinisIconView(
            icon,
            state: iconState(selected: selected),
            size: size,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func icon(for tier: ModelSpeedTier) -> MinisIcon {
        Self(tier).icon
    }

    static func label(for tier: ModelSpeedTier) -> String {
        Self(tier).label
    }
}
