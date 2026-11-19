import SwiftUI
import MinisCore

public enum MinisIconState: Sendable {
    case normal
    case hover
    case active
    case disabled
    case danger
    case success
}

/// Shared icon sizing and color contract for the Keyline duotone system.
public enum MinisIconTokens {
    public static let defaultSize: CGFloat = 16
    public static let smallSize: CGFloat = 12
    public static let largeSize: CGFloat = 20
    public static let neutralPrimary = Color(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1D / 255)
    /// 全 App 唯一强调色（第 1 套陶土橙）：浅 #A84E2A / 深 #E08B68，随外观自动切换。
    /// 原激活橙 #D97707 已被取代；名字保留是为了不动既有引用与测试。
    public static let keylineOrangeA7A = AccentTheme.pseudo.color
    /// 第 1 套状态色（浅色侧）：危险 #B3261E、成功 #2A7549。
    public static let danger = Color(red: 0xB3 / 255, green: 0x26 / 255, blue: 0x1E / 255)
    public static let success = Color(red: 0x2A / 255, green: 0x75 / 255, blue: 0x49 / 255)
    public static let secondaryOpacity: Double = 0.24
    public static let activeSecondaryOpacity: Double = 0.26
    public static let disabledOpacity: Double = 0.38

    /// Theme-bound primary layers consume the already resolved disabled role
    /// in both modes. The legacy translucent light primary is below its 2.5
    /// floor on the owned light surfaces; decorative layers and identity
    /// colors retain their existing contract.
    public static func primaryColor(
        for state: MinisIconState, mode: ThemeMode, themeTokens: ThemeSemanticTokens
    ) -> Color {
        if case .disabled = state { return themeTokens.disabled.swiftUIColor }
        return primaryColor(for: state, darkTokens: mode == .dark ? themeTokens : nil)
    }

    public static func primaryColor(for state: MinisIconState, darkTokens: ThemeSemanticTokens? = nil) -> Color {
        switch state {
        case .normal, .hover:
            return darkTokens?.textPrimary.swiftUIColor ?? neutralPrimary
        case .active:
            return keylineOrangeA7A
        case .disabled:
            return darkTokens?.disabled.swiftUIColor ?? neutralPrimary.opacity(disabledOpacity)
        case .danger:
            return darkTokens?.statusDanger.swiftUIColor ?? danger
        case .success:
            return darkTokens?.statusSuccess.swiftUIColor ?? success
        }
    }

    public static func secondaryColor(for state: MinisIconState, darkTokens: ThemeSemanticTokens? = nil) -> Color {
        switch state {
        case .normal:
            return (darkTokens?.textPrimary.swiftUIColor ?? neutralPrimary).opacity(secondaryOpacity)
        case .hover:
            return keylineOrangeA7A.opacity(0.16)
        case .active:
            return keylineOrangeA7A.opacity(activeSecondaryOpacity)
        case .disabled:
            return (darkTokens?.disabled.swiftUIColor ?? neutralPrimary).opacity(0.12)
        case .danger:
            return (darkTokens?.statusDanger.swiftUIColor ?? danger).opacity(secondaryOpacity)
        case .success:
            return (darkTokens?.statusSuccess.swiftUIColor ?? success).opacity(secondaryOpacity)
        }
    }
}
