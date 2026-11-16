import Testing
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

// MARK: - ThemeTokens 缺口补写（swift-testing）
//
// C3_2ThemeTokenTests / AJ38ThemeTokenTests 已覆盖：palette/semantic/亮暗双模式/Provider 注入。
// 本文件补未覆盖的边界：
//   ① ThemeColor(r:g:b:) 构造即 clamp 到 0~1（越界收敛）
//   ② Aj38Palette.withAccent：替换 accent/accentHover、其余语义色保持不变、越界 RGB 收敛
//   ③ 缺失兜底：未注入 ThemeTokenProvider 时 Environment 值为 nil（视图回退系统色）

@Suite("ThemeTokens 边界：clamp / withAccent / 缺失兜底")
struct ThemeTokensEdgeTests {

    // MARK: ① ThemeColor 构造 clamp

    @Test func themeColorClampsOutOfRangeComponents() {
        let clamped = ThemeColor(r: -0.5, g: 1.5, b: 0)
        #expect(clamped.r == 0, "负分量收敛到 0")
        #expect(clamped.g == 1, "超 1 分量收敛到 1")
        #expect(clamped.b == 0)
        #expect(clamped == ThemeColor(r: 0, g: 1, b: 0))

        // 边界值不被误伤
        let boundary = ThemeColor(r: 0, g: 1, b: 0.5)
        #expect(boundary.r == 0 && boundary.g == 1 && boundary.b == 0.5)

        // 元组构造同样收敛
        let tuple = ThemeColor(rgb: (r: 2, g: -1, b: 0.25))
        #expect(tuple == ThemeColor(r: 1, g: 0, b: 0.25))
    }

    // MARK: ② withAccent

    @Test func withAccentReplacesAccentPairAndKeepsOtherSemanticColors() {
        let base = Aj38Palette.light
        let accented = base.withAccent((r: 0.2, g: 0.4, b: 0.6))
        #expect(accented.accent == ThemeColor(r: 0.2, g: 0.4, b: 0.6))
        #expect(accented.accentHover == ThemeColor(r: 0.2, g: 0.4, b: 0.6), "hover 同主题色")
        // 其余语义色与基准调色板逐字段一致
        #expect(accented.backgroundPrimary == base.backgroundPrimary)
        #expect(accented.backgroundSecondary == base.backgroundSecondary)
        #expect(accented.textPrimary == base.textPrimary)
        #expect(accented.textSecondary == base.textSecondary)
        #expect(accented.borderSubtle == base.borderSubtle)
        #expect(accented.success == base.success)
        #expect(accented.danger == base.danger)
        #expect(accented != base, "accent 已替换，调色板整体变化")
    }

    @Test func withAccentClampsOutOfRangeRGB() {
        let accented = Aj38Palette.dark.withAccent((r: 2.0, g: -1.0, b: 0.5))
        #expect(accented.accent == ThemeColor(r: 1, g: 0, b: 0.5), "越界 RGB 经 ThemeColor 构造收敛")
        #expect(accented.accentHover == accented.accent)
        // 非 accent 字段不受影响（dark 基准）
        #expect(accented.backgroundPrimary == Aj38Palette.dark.backgroundPrimary)
    }

    // MARK: ③ 缺失兜底

    @Test func missingProviderFallsBackToNilEnvironment() {
        // 未注入 ThemeTokenProvider 的默认环境：themeTokens == nil
        // （视图据此回退系统色，测试/预览环境安全，不崩不黑屏）
        #expect(EnvironmentValues().themeTokens == nil)
    }
}
