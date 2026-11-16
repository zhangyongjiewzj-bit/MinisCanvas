import Foundation
import Testing
@testable import MinisCore

/// C3-2 两层主题 token：5 套主题 × 亮/暗 palette 完备性、semantic 映射、
/// 亮暗只换语义层（状态色跨模式不变）、色值方向性断言。
struct ThemeTokenTests {

    // MARK: - 工具

    /// palette 全部 12 个字段（身份色 + 状态色 + 中性阶）。
    private func paletteFields(_ p: ThemePalette) -> [ThemeColor] {
        [p.primary, p.accent, p.success, p.warning, p.danger, p.info,
         p.surface0, p.surface1, p.surface2, p.text0, p.text1, p.text2]
    }

    /// semantic 全部 13 个字段。
    private func semanticFields(_ t: ThemeSemanticTokens) -> [ThemeColor] {
        [t.background, t.sidebarBackground, t.surfaceRaised, t.stroke,
         t.textPrimary, t.textSecondary, t.textTertiary,
         t.statusSuccess, t.statusWarning, t.statusDanger, t.statusInfo,
         t.statusRunning, t.statusMuted]
    }

    // MARK: - palette 完备性（5 套 × 12 字段全有值、色值收敛到 [0,1]）

    @Test func paletteCompleteForAllThemes() {
        for theme in AccentTheme.allCases {
            let p = theme.palette
            for color in paletteFields(p) {
                #expect((0.0...1.0).contains(color.r))
                #expect((0.0...1.0).contains(color.g))
                #expect((0.0...1.0).contains(color.b))
            }
        }
    }

    @Test func palettePrimaryDerivedFromAccentRGB() {
        // primary 由 accentRGB 派生覆盖 → 恒一致（实现不手抄，防漂移）。
        for theme in AccentTheme.allCases {
            let rgb = theme.accentRGB
            #expect(theme.palette.primary == ThemeColor(rgb: rgb))
            #expect(theme.palette.primary == ThemeColor(r: rgb.r, g: rgb.g, b: rgb.b))
        }
    }

    @Test func paletteDistinctAcrossThemes() {
        // 5 套主题的 primary 互不相同（身份色可区分）。
        let primaries = Set(AccentTheme.allCases.map { "\($0.palette.primary.r),\($0.palette.primary.g),\($0.palette.primary.b)" })
        #expect(primaries.count == AccentTheme.allCases.count)
    }

    @Test func paletteNeutralHierarchy() {
        // surface0 最深 → surface2 最突出；text0 最强 → text2 最弱化。
        for theme in AccentTheme.allCases {
            let p = theme.palette
            #expect(p.surface0.luminance < p.surface1.luminance)
            #expect(p.surface1.luminance < p.surface2.luminance)
            #expect(p.text0.luminance > p.text1.luminance)
            #expect(p.text1.luminance > p.text2.luminance)
        }
    }

    // MARK: - semantic 完备性（5 套 × 2 模式 × 13 字段）

    @Test func semanticCompleteForAllThemesAndModes() {
        for theme in AccentTheme.allCases {
            for mode in ThemeMode.allCases {
                let t = theme.semanticTokens(for: mode)
                for color in semanticFields(t) {
                    #expect((0.0...1.0).contains(color.r))
                    #expect((0.0...1.0).contains(color.g))
                    #expect((0.0...1.0).contains(color.b))
                }
            }
        }
    }

    // MARK: - semantic 映射正确性（dark 引用 palette 深色档；light 换浅色表）

    @Test func darkSemanticMapsToPaletteNeutrals() {
        for theme in AccentTheme.allCases {
            let p = theme.palette
            let t = theme.semanticTokens(for: .dark)
            #expect(t.background == p.surface0)
            #expect(t.sidebarBackground == p.surface1)
            #expect(t.surfaceRaised == p.surface2)
            #expect(t.stroke == p.text2)
            #expect(t.textPrimary == p.text0)
            #expect(t.textSecondary == p.text1)
            #expect(t.textTertiary == p.text2)
        }
    }

    @Test func lightSemanticUsesLightNeutralsAndBrightBackground() {
        for theme in AccentTheme.allCases {
            let dark = theme.semanticTokens(for: .dark)
            let light = theme.semanticTokens(for: .light)
            // 亮模式背景亮度显著高于暗模式、文本亮度显著低于暗模式。
            #expect(light.background.luminance > dark.background.luminance)
            #expect(light.sidebarBackground.luminance > dark.sidebarBackground.luminance)
            #expect(light.textPrimary.luminance < dark.textPrimary.luminance)
            #expect(light.textSecondary.luminance < dark.textSecondary.luminance)
            // 亮模式背景是「浅色」：亮度高于阈值（近白）。
            #expect(light.background.luminance > 0.9)
            // 亮模式文本是「深色」：亮度低于阈值（近黑）。
            #expect(light.textPrimary.luminance < 0.3)
            // 暗模式背景是「深色」。
            #expect(dark.background.luminance < 0.2)
        }
    }

    @Test func statusColorsInvariantAcrossModes() {
        // 核心不变量：亮/暗只换背景/文本层，状态色两套模式引用同一 palette 值。
        for theme in AccentTheme.allCases {
            let p = theme.palette
            let dark = theme.semanticTokens(for: .dark)
            let light = theme.semanticTokens(for: .light)
            #expect(dark.statusSuccess == p.success)
            #expect(dark.statusWarning == p.warning)
            #expect(dark.statusDanger == p.danger)
            #expect(dark.statusInfo == p.info)
            #expect(dark.statusRunning == p.info)
            #expect(light.statusSuccess == p.success)
            #expect(light.statusWarning == p.warning)
            #expect(light.statusDanger == p.danger)
            #expect(light.statusInfo == p.info)
            #expect(light.statusRunning == p.info)
            // 跨模式一致（同一语义色在两套模式下取同值）。
            #expect(light.statusSuccess == dark.statusSuccess)
            #expect(light.statusWarning == dark.statusWarning)
            #expect(light.statusDanger == dark.statusDanger)
            #expect(light.statusInfo == dark.statusInfo)
            #expect(light.statusRunning == dark.statusRunning)
        }
    }

    @Test func semanticSwitchesOnlyNeutralLayerBetweenModes() {
        // 亮暗差异只允许出现在背景/表面/描边/文本中性语义上；
        // 状态色（success/warning/danger/info/running）必须逐字段相同。
        for theme in AccentTheme.allCases {
            let dark = theme.semanticTokens(for: .dark)
            let light = theme.semanticTokens(for: .light)
            // 中性层确实不同（否则「亮暗切换」是空操作）。
            #expect(light.background != dark.background)
            #expect(light.textPrimary != dark.textPrimary)
            // 状态层完全一致。
            #expect(light.statusSuccess == dark.statusSuccess)
            #expect(light.statusWarning == dark.statusWarning)
            #expect(light.statusDanger == dark.statusDanger)
            #expect(light.statusInfo == dark.statusInfo)
            #expect(light.statusRunning == dark.statusRunning)
        }
    }

    // MARK: - 状态语义方向（绿/红/黄/青的通道特征）

    @Test func statusColorsFollowSemanticHueDirection() {
        for theme in AccentTheme.allCases {
            let p = theme.palette
            // success 绿：g 通道最高。
            #expect(p.success.g > p.success.r && p.success.g > p.success.b)
            // danger 红：r 通道最高。
            #expect(p.danger.r > p.danger.g && p.danger.r > p.danger.b)
            // warning 黄：r、g 都明显高于 b。
            #expect(p.warning.r > p.warning.b && p.warning.g > p.warning.b)
            // info 青/蓝：b 通道最高（codex info 偏青也满足 b 最高）。
            #expect(p.info.b > p.info.r && p.info.b > p.info.g)
        }
    }

    // MARK: - ThemeColor 工具行为

    @Test func themeColorClampsToUnitRange() {
        let c = ThemeColor(r: 1.5, g: -0.2, b: 0.5)
        #expect(c.r == 1.0)
        #expect(c.g == 0.0)
        #expect(c.b == 0.5)
    }

    @Test func luminanceMatchesStandardWeights() {
        let c = ThemeColor(r: 1.0, g: 0.5, b: 0.0)
        // 标准 sRGB 相对亮度：lin(1.0)=1.0, lin(0.5)=0.214041, lin(0.0)=0.0
        let expected = 0.2126 * 1.0 + 0.7152 * 0.214041 + 0.0722 * 0.0
        #expect(abs(c.luminance - expected) < 1e-6)
    }
}
