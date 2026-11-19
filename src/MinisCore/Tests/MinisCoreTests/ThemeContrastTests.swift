import Foundation
import Testing
@testable import MinisCore

/// THEME-03 对比度合同测试。
///
/// 三组职责分别对应验收条件：
/// (a) `ratioMath*` / `luminance*` —— 用已知色对钉住文档化比值，防公式漂移；
/// (b) `roleThreshold*` / `perRoleGate*` —— 逐角色（正文/辅助/禁用/选中/状态）门槛断言；
/// (c) `floatingMenu*` / `contract*Duplication*` —— FloatingMenu 必须继续经由合同取面板底。
///
/// (c) 为什么必须是源码级守卫：合同住在 `MinisCore`，消费者住在 `MinisCanvasApp`，
/// 而 `MinisCoreTests` 只依赖 `MinisCore` target（见 src/MinisCore/Package.swift:22-24），
/// 无法 import MinisCanvasApp，运行时打不到 `FloatingMenuPanel.panelBackground`。
/// 守卫读的是**生产构建实际编译的那份 FloatingMenu.swift**（仓库路径由 #filePath 反推），
/// 因此它不是同义反复：把 ad-hoc 双外观 switch 抄回来（`switch theme.mode` /
/// 硬编码 `windowBackgroundColor).opacity(0.9)`）会让它立刻失败，删掉合同调用同样失败；
/// 它断言的对象不是本 lane 新写的文件，而是另一个 target 里的消费者。
struct ThemeContrastTests {

    // MARK: - 工具

    private func color(_ r: Double, _ g: Double, _ b: Double) -> ThemeColor {
        ThemeColor(r: r, g: g, b: b)
    }

    private func srgb(_ hex: Int) -> ThemeColor {
        ThemeColor(
            r: Double((hex >> 16) & 0xFF) / 255.0,
            g: Double((hex >> 8) & 0xFF) / 255.0,
            b: Double(hex & 0xFF) / 255.0
        )
    }

    private let white = ThemeColor(r: 1, g: 1, b: 1)
    private let black = ThemeColor(r: 0, g: 0, b: 0)

    /// 仓库根：本文件在 <root>/src/MinisCore/Tests/MinisCoreTests/ 下，上溯 5 层。
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCore
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository root
    }

    /// 读取生产源码；文件缺失即 `throws` 让测试失败（不静默 skip —— 那会让守卫变成假守卫）。
    private func productionSource(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func roles(_ evaluations: [ThemeContrastEvaluation]) -> [ThemeContrastRole] {
        evaluations.map(\.role)
    }

    // MARK: - (a) 相对亮度：只做复用，不复制公式

    @Test func luminanceIsPassthroughOfThemeColor() {
        // 合同不得有第二套 sRGB 线性化实现：逐点等价于 ThemeColor.luminance。
        for sample in [white, black, srgb(0xFAF9F6), srgb(0x14181C), color(0.5, 0.5, 0.5),
                       color(0.04045, 0.3, 0.9)] {
            #expect(ThemeContrast.relativeLuminance(of: sample) == sample.luminance)
        }
    }

    @Test func luminanceMatchesDocumentedSRGBValues() {
        // 已知锚点：纯白 1.0、纯黑 0.0、#FAF9F6 ≈ 0.947292、#14181C ≈ 0.008858。
        #expect(abs(ThemeContrast.relativeLuminance(of: white) - 1.0) < 1e-12)
        #expect(abs(ThemeContrast.relativeLuminance(of: black) - 0.0) < 1e-12)
        #expect(abs(ThemeContrast.relativeLuminance(of: srgb(0xFAF9F6)) - 0.947292) < 1e-6)
        #expect(abs(ThemeContrast.relativeLuminance(of: srgb(0x14181C)) - 0.008858) < 1e-6)
    }

    // MARK: - (a) 对比度数学：已知色对钉死

    @Test func contrastRatioKnownPairs() {
        #expect(abs(ThemeContrast.contrastRatio(white, black) - 21.0) < 1e-9)
        // WCAG 参考对：#767676/白 = 4.542（AA 常规文本刚好过），#777777/白 = 4.478（差一点不过）。
        #expect(abs(ThemeContrast.contrastRatio(srgb(0x767676), white) - 4.542225) < 1e-6)
        #expect(abs(ThemeContrast.contrastRatio(srgb(0x777777), white) - 4.478089) < 1e-6)
        // 纯红/白 = 3.998；中灰(0.5)/黑 = 5.281。
        #expect(abs(ThemeContrast.contrastRatio(srgb(0xFF0000), white) - 3.998477) < 1e-6)
        #expect(abs(ThemeContrast.contrastRatio(color(0.5, 0.5, 0.5), black) - 5.280823) < 1e-6)
    }

    @Test func contrastRatioIsSymmetricBoundedAndReflexive() {
        let a = srgb(0x9D623D)
        let b = srgb(0xFAF9F6)
        #expect(ThemeContrast.contrastRatio(a, b) == ThemeContrast.contrastRatio(b, a))
        #expect(ThemeContrast.contrastRatio(a, a) == 1.0)
        #expect(ThemeContrast.contrastRatio(white, white) == 1.0)
        let ratio = ThemeContrast.contrastRatio(a, b)
        #expect((1.0...21.0).contains(ratio))
    }

    @Test func thresholdComparisonIsInclusive() {
        // 门槛语义：恰好等于门槛算通过，低于一丁点算不通过（含 1e-9 容差）。
        let atGate = ThemeContrastEvaluation(
            role: .body, foreground: black, background: white, ratio: 4.5, minimumRatio: 4.5)
        #expect(atGate.passes)
        let justUnder = ThemeContrastEvaluation(
            role: .body, foreground: black, background: white, ratio: 4.49, minimumRatio: 4.5)
        #expect(!justUnder.passes)
        let justUnderTolerance = ThemeContrastEvaluation(
            role: .body, foreground: black, background: white,
            ratio: 4.5 - ThemeContrast.ratioTolerance / 10, minimumRatio: 4.5)
        #expect(justUnderTolerance.passes)
    }

    // MARK: - (b) 每角色门槛常量

    @Test func roleThresholdsArePinned() {
        #expect(ThemeContrastRole.allCases.count == 5)
        #expect(ThemeContrast.minimumRatio(for: .body) == 4.5)        // 正文
        #expect(ThemeContrast.minimumRatio(for: .secondary) == 4.5)   // 辅助
        #expect(ThemeContrast.minimumRatio(for: .disabled) == 2.5)    // 禁用
        #expect(ThemeContrast.minimumRatio(for: .selected) == 3.0)    // 选中
        #expect(ThemeContrast.minimumRatio(for: .status) == 3.0)      // 状态
        // 入口一致性：枚举属性与静态函数不得给出两个答案。
        for role in ThemeContrastRole.allCases {
            #expect(ThemeContrast.minimumRatio(for: role) == role.minimumRatio)
        }
    }

    @Test func evaluateReportsRatioGateAndVerdict() {
        let bg = white
        // 正文：#767676 过 4.5，#777777 不过 —— 合同必须给出相反的结论。
        let passing = ThemeContrast.evaluate(role: .body, foreground: srgb(0x767676), background: bg)
        let failing = ThemeContrast.evaluate(role: .body, foreground: srgb(0x777777), background: bg)
        #expect(passing.passes && !passing.ratio.isNaN)
        #expect(!failing.passes)
        #expect(passing.minimumRatio == 4.5 && failing.minimumRatio == 4.5)
        #expect(ThemeContrast.isCompliant(role: .body, foreground: black, background: bg))
        #expect(!ThemeContrast.isCompliant(role: .body, foreground: srgb(0xFF0000), background: bg))
        // 禁用地板（2.5）比正文松：同一前景色在两个角色下结论不同。
        #expect(ThemeContrast.isCompliant(role: .disabled, foreground: srgb(0xFF0000), background: bg))
    }

    // MARK: - (b) 生产 token 逐角色实跑（5 套 × 亮/暗）

    @Test func lightTokensMeetBodySecondaryDisabledGates() {
        // 已批准浅色三套文本/禁用角色必须实过门槛（不是仅存在常量）。
        for theme in AccentTheme.allCases {
            let tokens = theme.semanticTokens(for: .light)
            for role in [ThemeContrastRole.body, .secondary, .disabled] {
                let evaluation = ThemeContrast.evaluate(
                    role: role,
                    foreground: role.colors(in: tokens)[0],
                    background: tokens.background
                )
                #expect(evaluation.passes, "\(theme)/light \(role) = \(evaluation.ratio)")
            }
        }
    }

    @Test func lightTokenViolationBaselineIsExactlyDocumented() {
        // 逐主题钉住「哪些角色目前不达标」。这不是 pass 断言，而是漂移闸：
        // 浅色 token 值一改（属 SETTINGS-27 + THEME-01 + THEME-05 收敛线），本测试即失败，
        // 强迫那条线重新核对门槛结论，而不是让合同悄悄与 token 脱节。
        for theme in AccentTheme.allCases {
            let violations = roles(ThemeContrast.violations(tokens: theme.semanticTokens(for: .light)))
            switch theme {
            case .pseudo:
                // 第 1 套浅色（暖中性 + 陶土橙）：选中 5.26、状态最弱支（弱字灰 4.92）均过，无违例。
                #expect(violations.isEmpty)
            case .codex, .graphite, .ocean, .crimson, .emerald:
                #expect(violations == [.selected, .status])
            }
        }
    }

    @Test func darkTokenViolationBaselineIsExactlyDocumented() {
        for theme in AccentTheme.allCases {
            let violations = roles(ThemeContrast.violations(tokens: theme.semanticTokens(for: .dark)))
            switch theme {
            case .pseudo:
                #expect(violations.isEmpty)   // 第 1 套深色：状态最弱支 5.7，无违例
            case .codex, .graphite, .ocean, .crimson, .emerald:
                #expect(violations.isEmpty)
            }
        }
    }

    @Test func statusRoleIsJudgedByItsWeakestColor() {
        // 「状态达标」不得被一支好色掩盖：取该套状态色里实测最弱的一支。
        let tokens = AccentTheme.pseudo.semanticTokens(for: .light)
        guard let status = ThemeContrast.evaluateAll(tokens: tokens)
            .first(where: { $0.role == .status }) else {
            Issue.record("evaluateAll 未返回 status 角色判定")
            return
        }
        // 第 1 套浅色最弱支是「执行/待执行」的弱字灰 #6F6D66（对底 #FAF9F5 约 4.92）。
        #expect(abs(status.ratio - 4.9155) < 1e-3)
        #expect(status.foreground == ThemeColor(hex: 0x6F6D66))
        // 该支确实是 6 支状态色里最低的一支。
        let every = status.foreground
        for candidate in ThemeContrastRole.status.colors(in: tokens) {
            #expect(ThemeContrast.contrastRatio(candidate, tokens.background) >=
                    ThemeContrast.contrastRatio(every, tokens.background) - 1e-12)
        }
    }

    @Test func assertCompliantPassesForApprovedLightBodyToken() {
        // 生产断言入口：已批准浅色正文必须过门槛（过则 Debug/Release 都不触发；
        // 未通过会在 Debug 失败，Release 编译掉，不产生线上崩溃面）。
        let tokens = AccentTheme.pseudo.semanticTokens(for: .light)
        let evaluation = ThemeContrast.evaluate(
            role: .body, foreground: tokens.textPrimary, background: tokens.background)
        #expect(ThemeContrast.assertCompliant(evaluation, "浅色正文").passes)
    }

    // MARK: - (c) FloatingMenu 面板底判定 + 消费者守卫

    @Test func panelFaceConstantsArePinned() {
        #expect(ThemeContrast.panelFaceMinimumSeparation == 1.25)
        #expect(ThemeContrast.themedPanelFaceOpacity == 0.5)
        #expect(ThemeContrast.systemPanelFaceOpacity == 0.9)
    }

    @Test func lightPanelFaceSameAsCanvasFallsBackToSystemFace() {
        // 改前事实的等价复现：浮层候选底与画布底同为 #FAF9F6 → 分离度恰为 1.0 →
        // 合同判换系统窗口底 @0.9。A7-A 像素结果与改前逐字一致。
        let canvasFace = srgb(0xFAF9F6)
        let decision = ThemeContrast.panelSurfaceDecision(
            mode: .light, themedFace: canvasFace, canvasBackdrop: canvasFace)
        #expect(decision.face == .systemWindowBackground)
        #expect(decision.opacity == 0.9)
        #expect(abs(decision.measuredFaceSeparation - 1.0) < 1e-12)
        #expect(!decision.separationSatisfied)
        #expect(!decision.usesSettledDarkPin)
    }

    @Test func panelDecisionIsComputedNotHardcoded() {
        // 反同义反复证明：同样走 .light 分支，只要分离度跨过 1.25 地板，
        // 合同就自动回到主题面 @0.5 —— 视图里没有任何模式分支能做出这个结果。
        let separated = ThemeContrast.panelSurfaceDecision(
            mode: .light, themedFace: white, canvasBackdrop: color(0.9, 0.9, 0.9))
        #expect(abs(separated.measuredFaceSeparation - 1.253863) < 1e-6)
        #expect(separated.separationSatisfied)
        #expect(separated.face == .themedPalette)
        #expect(separated.opacity == 0.5)

        // 地板另一侧：#E6E6E6 与白底分离度 1.248 < 1.25 → 仍判隐形、仍换系统面。
        let borderline = ThemeContrast.panelSurfaceDecision(
            mode: .light, themedFace: white, canvasBackdrop: srgb(0xE6E6E6))
        #expect(abs(borderline.measuredFaceSeparation - 1.248072) < 1e-6)
        #expect(!borderline.separationSatisfied)
        #expect(borderline.face == .systemWindowBackground)
        #expect(borderline.opacity == 0.9)
    }

    @Test func darkPanelFaceKeepsSettledAppearanceAndStillMeasuresSeparation() {
        // 暗色：定案「深底 50% 透明 + 浅字」保持像素不变（暗色 token 集尚未存在，
        // THEME-02/04 被 hold），但分离度照常实测并随结果返回，供收敛线接手时断言。
        let darkFace = srgb(0x14181C)
        let decision = ThemeContrast.panelSurfaceDecision(
            mode: .dark, themedFace: darkFace, canvasBackdrop: darkFace)
        #expect(decision.face == .themedPalette)
        #expect(decision.opacity == 0.5)
        #expect(decision.usesSettledDarkPin)
        #expect(!decision.separationSatisfied)
        #expect(abs(decision.measuredFaceSeparation - 1.0) < 1e-12)
    }

    @Test func floatingMenuRoutesItsPanelFaceThroughTheContract() throws {
        let source = try productionSource(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/FloatingMenu.swift")

        // 1) 生产消费者必须真的调用合同（面板底 + 正文角色两处）。
        #expect(source.contains("ThemeContrast.panelSurfaceDecision("))
        #expect(source.contains("ThemeContrast.evaluate("))
        #expect(source.contains("ThemeContrast.assertCompliant("))
        #expect(source.contains("import MinisCore"))
        // 2) 结论只能来自返回值：视图按合同的 face 枚举分派，不自己判外观。
        #expect(source.contains("case .systemWindowBackground:"))
        #expect(source.contains("case .themedPalette:"))
        // 3) ad-hoc 双外观修正必须消失——把改前代码抄回来即在此失败。
        #expect(!source.contains("switch theme.mode"))
        #expect(!source.contains("windowBackgroundColor).opacity(0.9)"))
        #expect(!source.contains("backgroundPrimary.swiftUIColor.opacity(0.5)"))
        // 4) 不透明度取自合同值，而不是面板路径上的字面量。
        #expect(source.contains("opacity(surface.opacity)"))
    }

    @Test func contractDoesNotDuplicateTheLuminanceFormula() throws {
        // 合同必须复用 `ThemeColor.luminance`，不得自带第二套 sRGB 实现（ThemeTokens.swift
        // 由另一条线持有，两处公式必然漂移）。
        let source = try productionSource(
            "src/MinisCore/Sources/MinisCore/Settings/ThemeContrast.swift")
        #expect(!source.contains("0.2126"))
        #expect(!source.contains("0.7152"))
        #expect(!source.contains("0.0722"))
        #expect(!source.contains("pow("))
        #expect(source.contains("color.luminance"))
        // 且不得声明新 token 集/预设类型（那是 SETTINGS-27 + THEME-01 + THEME-05 的地盘）：
        // 只查声明形式，因为本文件的边界说明注释里会提到那个名字。
        #expect(!source.contains("struct ThemePreset"))
        #expect(!source.contains("enum ThemePreset"))
        #expect(!source.contains("extension ThemePreset"))
        #expect(!source.contains("backgroundSecondary"))
    }
    // 834: actual selectable-preset producer, rather than the legacy accent palette.
    @Test(arguments: ThemePreset.selectable, [false, true])
    func selectablePresetRolesPassOnTheirOwnedTokenSurfaces834(
        preset: ThemePreset, systemIsDark: Bool
    ) throws {
        let tokens = try #require(preset.semanticTokens(systemIsDark: systemIsDark))
        for surface in [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised] {
            for result in ThemeContrast.evaluateAll(tokens: tokens, background: surface) {
                #expect(result.passes, "\(preset)/\(systemIsDark) \(result.role) ratio=\(result.ratio)")
            }
            // Tertiary text is still readable auxiliary copy; it is not a disabled control.
            #expect(ThemeContrast.evaluate(role: .secondary,
                foreground: tokens.textTertiary, background: surface).passes)
        }
        #expect(preset.palette == AccentTheme.pseudo.palette)
        #expect(preset.accentRGB?.r == AccentTheme.pseudo.accentRGB.r)
        #expect(preset.accentRGB?.g == AccentTheme.pseudo.accentRGB.g)
        #expect(preset.accentRGB?.b == AccentTheme.pseudo.accentRGB.b)
        #expect(preset.semanticTokens(systemIsDark: systemIsDark) == tokens)
    }

}

/// F-2：用户气泡是「强调色底 + 白字」，深色强调色（#E08B68）原来只有约 2.6:1。
struct UserBubbleWhiteTextContrastTests {
    private let white = ThemeColor(r: 1, g: 1, b: 1)

    @Test func darkAccentBubbleMeetsFourPointFive() {
        let darkAccent = ThemeColor(
            r: AccentTheme.pseudo.darkAccentRGB.r, g: AccentTheme.pseudo.darkAccentRGB.g,
            b: AccentTheme.pseudo.darkAccentRGB.b)
        #expect(ThemeContrast.contrastRatio(white, darkAccent) < 4.5)   // 复现问题
        let fill = ThemeContrast.fillMeetingWhiteText(darkAccent)
        #expect(ThemeContrast.contrastRatio(white, fill) >= 4.5)
    }

    @Test func lightAccentBubbleIsUnchanged() {
        let lightAccent = ThemeColor(
            r: AccentTheme.pseudo.accentRGB.r, g: AccentTheme.pseudo.accentRGB.g,
            b: AccentTheme.pseudo.accentRGB.b)
        #expect(ThemeContrast.contrastRatio(white, lightAccent) >= 4.5)
        #expect(ThemeContrast.fillMeetingWhiteText(lightAccent) == lightAccent)
    }
}
