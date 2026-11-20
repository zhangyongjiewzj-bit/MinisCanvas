import Foundation

// MARK: - Enums

/// UI 外观偏好（设置中心 general 分组）。
public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// 主题色（设置中心 general 分组，E13）。
///
/// 每套主题含主强调色（RGB 分量，0~1）与「是否深色优先」。
/// 强调色存 RGB 而非 SwiftUI `Color`，保持 MinisCore 无 UI 依赖、
/// 可在测试中直接断言色值；`Color` 由 MinisCanvasApp 层转换。
public enum AccentTheme: String, Codable, CaseIterable, Sendable {
    /// 默认：伪仙赭橙（AJ-38 定版色板强调色，暗色 #A0613C / 亮色 #9D623D 的中间档）。
    case pseudo
    /// 深蓝灰 + 青，对齐 Codex 风格。
    case codex
    /// 石墨黑（中性灰）。
    case graphite
    /// 海洋蓝。
    case ocean
    /// 绯红。
    case crimson
    /// 翡翠绿。
    case emerald

    public var displayName: String {
        switch self {
        case .pseudo: "Pseudo"
        case .codex: "Codex"
        case .graphite: "Graphite"
        case .ocean: "Ocean"
        case .crimson: "Crimson"
        case .emerald: "Emerald"
        }
    }

    /// 主强调色 RGB 分量（0~1）。
    public var accentRGB: (r: Double, g: Double, b: Double) {
        switch self {
        // 第 1 套「暖中性 + 陶土橙」浅色强调 #A84E2A（深色强调 #E08B68 见 `darkAccentRGB`）。
        case .pseudo: (168.0 / 255.0, 78.0 / 255.0, 42.0 / 255.0)
        case .codex: (0.35, 0.78, 0.90)
        case .graphite: (0.65, 0.67, 0.71)
        case .ocean: (0.20, 0.52, 0.94)
        case .crimson: (0.92, 0.26, 0.34)
        case .emerald: (0.15, 0.68, 0.46)
        }
    }

    /// 深色模式下的强调色 RGB（仅产品主题 `.pseudo` 有专门深色值 #E08B68，其余沿用 `accentRGB`）。
    public var darkAccentRGB: (r: Double, g: Double, b: Double) {
        switch self {
        case .pseudo: (224.0 / 255.0, 139.0 / 255.0, 104.0 / 255.0)
        default: accentRGB
        }
    }

    /// 是否深色优先（主题默认观感；Appearance 为 system 时供 UI 预览底色参考）。
    public var prefersDark: Bool {
        switch self {
        case .pseudo, .codex, .graphite: true
        case .ocean, .crimson, .emerald: false
        }
    }
}

// MARK: - ThemePreset（SETTINGS-27 / THEME-01 外观收敛）

/// 20261004T1115 用户决定：产品主题 + 跟随系统（原生），合计两项。
/// 旧 dark/highContrast raw 值只供历史解码，永不进入可选/生效集合。
public enum ThemePreset: String, Codable, CaseIterable, Sendable {
    /// 浅色：伪仙定版 palette 的 light semantic 层（与收敛前默认外观逐值相同）。
    case light
    /// 旧深色存储词：仅解码/迁移到原生System，不可选。
    case dark
    /// 跟随系统：按 macOS 当前明暗在既有 light/dark 两套取值间解析。
    case system
    /// 旧高对比存储词：仅解码/迁移到原生System，不可选。
    case highContrast

    public var displayName: String {
        switch self {
        case .light: "浅色（产品主题）"
        case .dark: "深色"
        case .system: "跟随系统（原生）"
        case .highContrast: "高对比"
        }
    }

    /// 该预设是否已具备可用的验收 token 材料。
    ///
    /// false 的预设保留在枚举中（不因未填充而被静默删除），但既不出现在
    /// 设置页选择器里，也不能被任何存储值选中。
    public var isAccepted: Bool {
        switch self {
        case .light, .system: true
        case .dark, .highContrast: false
        }
    }

    /// 选择器可见集合：只有已验收预设可被用户选中。
    public static let allCases: [ThemePreset] = [.light, .system]
    public static var selectable: [ThemePreset] { allCases }

    /// Retirement is a deterministic projection, never a new selectable theme.
    public var current: ThemePreset {
        switch self {
        case .light, .system: self
        case .dark, .highContrast: .system
        }
    }

    /// 投影用的固定明暗：`.system` 返回 nil，交由 App 层按 macOS 明暗解析。
    public var fixedMode: ThemeMode? {
        switch self {
        // 产品主题（.light）自第 1 套配色起带深色版，明暗跟随系统，不再固定浅色。
        case .light: nil
        case .dark, .highContrast: nil
        case .system: nil
        }
    }

    /// 收敛后跟随系统时用于 `ColorScheme` 投影的旧 `Appearance` 值。
    public var appearanceProjection: Appearance {
        switch self {
        case .light: .system
        case .dark, .highContrast: .system
        case .system: .system
        }
    }

    /// 收敛后全部预设绑定的调色板：AJ-38 定版伪仙（唯一有批准色板的主题）。
    public static let canonicalAccentTheme: AccentTheme = .pseudo

    /// THEME-05：把旧「外观模式 × 主题色」组合确定性地映射到最近预设。
    ///
    /// 明暗是本枚举唯一承载的外观维度（调色板恒为 AJ-38 定版伪仙），
    /// 因此「最近」由 `Appearance` 单轴决定，对全部 3×6=18 种旧组合是
    /// 全函数且一对一到预设；不依赖随机、时间或不可读输入。
    /// 旧三种 Appearance 不主动映射到新增高对比，只有显式预设可选它。
    public static func nearest(
        for appearance: Appearance,
        accentTheme: AccentTheme = .pseudo
    ) -> ThemePreset {
        _ = accentTheme  // 保留形参以覆盖全部旧组合；调色板已收敛为定版伪仙。
        switch appearance {
        case .light: return .light
        case .dark: return .system
        case .system: return .system
        }
    }

    /// 把任意可能损坏/未验收的存储值收敛为可读预设。
    ///
    /// 不可解析或键缺失的取值一律回落到 `fallback`
    /// （默认 `.system`，其 token 恒为仓库既有 light/dark 两套之一），
    /// 因而永不恢复出不可读组合。
    public static func converging(_ raw: String?, fallback: ThemePreset = .system) -> ThemePreset {
        guard let raw, let parsed = ThemePreset(rawValue: raw) else {
            return fallback.current
        }
        return parsed.current
    }
}

/// P3-ISO: mandatory Canvas/Chat isolation policy projection.
///
/// This is deliberately not an `AppSettings` field. Isolation is a required
/// production guard, not a user-toggleable or persisted runtime option.
public struct CanvasChatIsolationPolicyDescriptor: Equatable, Sendable {
    public static let settingsKey = "policy.canvas_chat_isolation"
    public static let defaultValue = true
    public static let effectiveValue = true
    public static let isReadOnly = true
    public static let canDisable = false
    public static let disabledReason =
        "三期硬门禁：画布与对话运行时必须完全隔离，不提供关闭入口。"
    public static let resetValue = "N-A"
    public static let range = "N-A"
    /// Bind the projection to the existing P3-ISO production guard.
    public static let productionGuardCapability =
        ChatCanvasBoundaryContract.canvasMutationCapability

    public let key: String
    public let effectiveValue: Bool
    public let defaultValue: Bool
    public let isReadOnly: Bool
    public let canDisable: Bool
    public let disabledReason: String
    public let resetValue: String
    public let range: String
    public let productionGuardCapability: String

    public init() {
        self.key = Self.settingsKey
        self.effectiveValue = Self.effectiveValue
        self.defaultValue = Self.defaultValue
        self.isReadOnly = Self.isReadOnly
        self.canDisable = Self.canDisable
        self.disabledReason = Self.disabledReason
        self.resetValue = Self.resetValue
        self.range = Self.range
        self.productionGuardCapability = Self.productionGuardCapability
    }

    public static let current = CanvasChatIsolationPolicyDescriptor()
}

/// 日志级别（设置中心 privacy 分组；`LogManager` 消费）。
///
/// 命名加 `Settings` 前缀避免与 `LogManager`（C1c 在途）内部的
/// 日志级别类型重名。
public enum SettingsLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warn
    case error

    public var displayName: String {
        rawValue.uppercased()
    }
}

/// 回答风格：三个显式预设；normal 保留历史默认行为。
/// 控制 systemPrompt 注入的语气，以及极简模式下聊天区流式展示的简化。
/// 持久化于 `AppSettings.general.chatOutputMode`（默认 `.normal`）。
public enum ChatOutputMode: String, Codable, CaseIterable, Sendable, Hashable {
    /// 详细：要求输出完整推理步骤，再给结论。
    case detailed
    /// 正常：简洁准确（默认）。
    case normal
    /// 极简：只报工作状态与结果，省 token。
    case concise
    /// 讲解：解释概念、步骤与例子，不要求隐藏推理。
    case explanatory

    public static let presets: [ChatOutputMode] = [.concise, .detailed, .explanatory]

    public var displayName: String {
        switch self {
        case .detailed: "详细"
        case .normal: "默认"
        case .concise: "简洁"
        case .explanatory: "讲解"
        }
    }

    /// 注入到 systemPrompt 的语气片段（normal 为 nil，不注入）。
    public var systemPromptInstruction: String? {
        switch self {
        case .detailed:
            "输出要求：请先给出简要、可核验的步骤摘要和可行性结论，再给出最终结果；不暴露隐藏思维链、内部推理或安全策略。"
        case .explanatory:
            "回答风格：讲解。先说明关键概念，再用可核验的步骤和具体例子帮助理解；清楚标注假设和不确定性，不暴露隐藏思维链、内部推理或安全策略。"
        case .normal:
            nil
        case .concise:
            "输出要求：请只输出最终结果与工作状态（是否完成/关键结论），不要展开推理过程或中间步骤，尽量精简以节省 token。"
        }
    }
}

// MARK: - Typography

/// 全局 UI 排版偏好。
///
/// 这是基准字号设置，不会改变图标、工具栏或危险操作的尺寸。
/// 具体组件 token 由 MinisCanvasApp 的 `TypographyTokenProvider` 解释。
public struct TypographySettings: Codable, Equatable, Sendable {
    /// P3-SET-01：排版基准字号的稳定设置键，供设置 UI/证据/自动化定位共用。
    public static let settingsKey = "typography.uiBaseFontSize"
    /// 用户可选的基准字号范围（pt）。
    public static let uiBaseFontSizeRange: ClosedRange<Int> = 12...20
    /// 设置控件的离散步长（pt）。
    public static let uiBaseFontSizeStep = 1
    /// 默认基准字号（pt）。
    public static let defaultBaseFontSize = 14
    /// 当前没有禁用条件；窄窗口仍允许调整字号，布局由响应式约束负责。
    public static let disabledReason: String? = nil

    public var uiBaseFontSize: Int {
        didSet {
            uiBaseFontSize = Self.clamp(uiBaseFontSize)
        }
    }

    public static let `default` = TypographySettings()

    public init(uiBaseFontSize: Int = TypographySettings.defaultBaseFontSize) {
        self.uiBaseFontSize = Self.clamp(uiBaseFontSize)
    }

    /// 将外部值收敛到设置契约范围。
    public static func clamp(_ size: Int) -> Int {
        min(uiBaseFontSizeRange.upperBound, max(uiBaseFontSizeRange.lowerBound, size))
    }

    private enum CodingKeys: String, CodingKey {
        case uiBaseFontSize
    }

    /// 宽容解码：缺失字段回落默认值，越界值收敛到允许范围。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(Int.self, forKey: .uiBaseFontSize)
            ?? Self.defaultBaseFontSize
        uiBaseFontSize = Self.clamp(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uiBaseFontSize, forKey: .uiBaseFontSize)
    }
}

// MARK: - 浏览器（AJ-49）

/// 用户代理（UA）预设（AJ-49 浏览器设置）：移动 Chrome / 桌面 Chrome / 自定义。
///
/// 持久化于 `AppSettings.browser.userAgentPreset`（默认 `.desktopChrome`）。
/// 接入 WKWebView 的 `customUserAgent`；`.custom` 时由 `customUserAgent`
/// 字符串决定（空串回退桌面 Chrome UA，避免 WebKit 回退到默认 UA）。
public enum UserAgentPreset: String, Codable, CaseIterable, Sendable {
    /// 移动 Chrome（Android，窄视口）。
    case mobileChrome
    /// 桌面 Chrome（macOS，宽视口）。
    case desktopChrome
    /// 自定义字符串（由 `BrowserSettings.customUserAgent` 提供）。
    case custom

    public var displayName: String {
        switch self {
        case .mobileChrome: "移动 Chrome"
        case .desktopChrome: "桌面 Chrome"
        case .custom: "自定义"
        }
    }

    /// 预设的 UA 字符串；`.custom` 返回 `nil`（由用户自定义字符串决定）。
    public var userAgentString: String? {
        switch self {
        case .mobileChrome:
            "Mozilla/5.0 (Linux; Android 13; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        case .desktopChrome:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .custom:
            nil
        }
    }

    /// 该预设对应的逻辑视口尺寸（移动→窄，桌面→宽）。仅作默认 viewport 参考。
    public var viewportSize: (width: Int, height: Int) {
        switch self {
        case .mobileChrome: return (390, 844)
        case .desktopChrome, .custom: return (1280, 800)
        }
    }
}

/// 浏览器 Viewport 模式（AJ-49）：默认按 UA 自动 / 自定义宽×高。
public enum BrowserViewportMode: String, Codable, CaseIterable, Sendable {
    /// 默认：跟随 UA 预设（移动 UA → 窄视口，桌面 UA → 宽视口）。
    case autoByUA
    /// 自定义宽×高（`customViewportWidth` / `customViewportHeight`）。
    case custom

    public var displayName: String {
        switch self {
        case .autoByUA: "默认（按 UA 自动）"
        case .custom: "自定义宽×高"
        }
    }
}

// MARK: - 人格（Persona，波4）

/// 内置人格预设：一键切换的模板，选中后填充 `AgentSettings.persona`。
public enum PersonaPreset: String, Codable, CaseIterable, Sendable {
    /// 专业助手。
    case professional
    /// 创意写作。
    case creative
    /// 编码专家。
    case coder
    /// 极简。
    case minimal

    public var displayName: String {
        switch self {
        case .professional: "专业助手"
        case .creative: "创意写作"
        case .coder: "编码专家"
        case .minimal: "极简"
        }
    }

    /// 该预设的默认人格内容（应用到 `AgentSettings.persona`）。
    public var defaultPersona: Persona {
        switch self {
        case .professional:
            Persona(
                name: "专业助手",
                summary: "严谨、可靠的中文助手，擅长结构化分析与清晰表达。",
                tone: "专业、礼貌、简洁",
                abilities: "综合分析、文档撰写、方案规划、信息整理"
            )
        case .creative:
            Persona(
                name: "创意写作",
                summary: "富有想象力的文字创作者，擅长比喻与画面感表达。",
                tone: "生动、活泼、有画面感",
                abilities: "故事创作、文案润色、创意构思、多风格写作"
            )
        case .coder:
            Persona(
                name: "编码专家",
                summary: "精通 Swift/SwiftUI 与 macOS 开发的资深工程师。",
                tone: "务实、直接、技术导向",
                abilities: "代码编写、调试排查、架构设计、代码评审、性能优化"
            )
        case .minimal:
            Persona(
                name: "极简助手",
                summary: "只给结论、不废话的高效助手。",
                tone: "极简、干脆",
                abilities: "快速问答、摘要提炼、要点归纳"
            )
        }
    }
}

/// 人格配置（波4）：名称 / 简介 / 语气 / 能力。
/// 持久化于 `AgentSettings.persona`，启用后注入 systemPrompt 前缀。
public struct Persona: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    public var tone: String
    public var abilities: String

    public init(
        name: String = "",
        summary: String = "",
        tone: String = "",
        abilities: String = ""
    ) {
        self.name = name
        self.summary = summary
        self.tone = tone
        self.abilities = abilities
    }

    /// 是否未配置任何字段（空人格不注入 systemPrompt）。
    public var isEmpty: Bool {
        name.isEmpty && summary.isEmpty && tone.isEmpty && abilities.isEmpty
    }

    /// 注入 systemPrompt 的人格描述片段（前缀）：逐行拼装非空字段。
    public var systemPromptFragment: String {
        var parts: [String] = [
            "人格仅影响表达方式和偏好，不授予或扩大工具、文件、网络、MCP、记忆或画布权限；所有操作仍须遵守系统策略、审批和当前作用域。"
        ]
        if !name.isEmpty { parts.append("你是「\(name)」。") }
        if !summary.isEmpty { parts.append(summary) }
        if !tone.isEmpty { parts.append("语气：\(tone)") }
        if !abilities.isEmpty { parts.append("能力：\(abilities)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 分组模型

/// Stable provider-scoped model identity used by lightweight child work.
///
/// The provider namespace is part of the value rather than inferred from a
/// bare model ID. Built-in provider raw values are normalized to
/// `builtin.<rawValue>`; custom records should use `custom.<EnvVarEntry.id>`.
/// The legacy `custom.<name>` form remains readable as an alias until the
/// settings/UI layer can resolve it to the record ID.
public struct ProviderModelReference: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = Self.canonicalProviderID(providerID)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = provider.hasPrefix("builtin.")
            ? "builtin."
            : (provider.hasPrefix("custom.") ? "custom." : "")
        return !namespace.isEmpty
            && provider.dropFirst(namespace.count).isEmpty == false
            && !model.isEmpty
    }

    public static func canonicalProviderID(_ rawValue: String) -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("builtin.") || raw.hasPrefix("custom.") {
            return raw
        }
        if let builtIn = ProviderType(rawValue: raw) {
            return "builtin.\(builtIn.rawValue)"
        }
        // A legacy custom provider is currently name-based. Keep that alias
        // stable here; the app layer can replace the suffix with EnvVarEntry.id
        // once the provider catalog is available.
        return raw.isEmpty ? raw : "custom.\(raw)"
    }
}

/// general 分组：外观、主题色、默认 provider/model、速度档位、语言。
public struct GeneralSettings: Codable, Equatable, Sendable {
    /// SETTINGS-27/THEME-01 收敛后的唯一外观真值。
    ///
    /// 下面两个旧字段（`appearance`/`accentTheme`）在本结构里降级为
    /// `themePreset` 的派生投影：任何写入预设的路径都会经
    /// `projectLegacyAppearanceFields()` 重算它们，而设置页不再提供
    /// 单独改这两个字段的入口。字段本身保留是为了既有 consumer
    /// （BL6 投影、App 层 `.tint`、历史测试）继续编译。
    public var themePreset: ThemePreset {
        didSet {
            if !themePreset.isAccepted {
                if legacyThemePresetRawValue == nil { legacyThemePresetRawValue = themePreset.rawValue }
                themePreset = themePreset.current
            }
            projectLegacyAppearanceFields()
        }
    }
    /// Reversible migration provenance only. Never selectable or an effective input.
    public private(set) var legacyThemePresetRawValue: String? = nil
    public var appearance: Appearance
    /// 主题色（E13）：主强调色 + 深色优先倾向，默认 .pseudo（伪仙赭橙，与 AJ-38 色板一致）。
    public var accentTheme: AccentTheme
    /// 默认 provider ID（nil = 未选，UI 让用户选择）。
    public var defaultProviderID: String?
    /// 默认模型 ID（nil = 未选）。
    public var defaultModelID: String?
    /// AJ-40/P3-SET-01：辅助模型的 provider-scoped identity。
    /// nil = 未选，继承主模型；模型 ID 不能脱离 provider namespace 使用。
    public var subModelReference: ProviderModelReference?
    /// Compatibility projection for SettingsCenter/View code that still binds
    /// the old bare-string field. New writes preserve the current provider
    /// namespace when one is known; otherwise they remain unresolved legacy
    /// data and are never promoted to a model-only route.
    public var subModelID: String? {
        get { subModelReference?.modelID ?? unresolvedLegacySubModelID }
        set {
            guard let newValue else {
                subModelReference = nil
                unresolvedLegacySubModelID = nil
                return
            }
            let modelID = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty else {
                subModelReference = nil
                unresolvedLegacySubModelID = nil
                return
            }
            if let reference = subModelReference {
                subModelReference = ProviderModelReference(
                    providerID: reference.providerID,
                    modelID: modelID
                )
                unresolvedLegacySubModelID = nil
            } else if let defaultProviderID,
                      !defaultProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subModelReference = ProviderModelReference(
                    providerID: defaultProviderID,
                    modelID: modelID
                )
                unresolvedLegacySubModelID = nil
            } else {
                unresolvedLegacySubModelID = modelID
            }
        }
    }
    /// A bare value from a pre-P3-SET-01 file that could not be migrated yet
    /// because no default provider was available. It is intentionally not
    /// encoded as a canonical reference.
    private var unresolvedLegacySubModelID: String?
    /// E19 模型速度档位（极快/快/均衡/质量），默认 .balanced。
    public var modelSpeedTier: ModelSpeedTier
    /// AJ-52 对话输出模式（详细/正常/极简），默认 .normal。
    public var chatOutputMode: ChatOutputMode
    public var language: String

    /// 把 `themePreset` 投影回旧的主题色字段。
    ///
    /// 配色（预设）是唯一真值；`appearance` 现在是独立的「浅色 / 深色 / 跟随系统」
    /// 明暗选择（对齐 Claude Code），不再被预设覆盖。主题色恒为定版伪仙。
    public mutating func projectLegacyAppearanceFields() {
        accentTheme = ThemePreset.canonicalAccentTheme
    }

    /// 唯一的写入口：写入预设并同步重投影旧字段。
    ///
    /// 不具备token的预设不可成为存储真值：回落到当前旧组合的
    /// `nearest` 映射，因此调用它永远不会把外观状态变成不可读组合。
    public mutating func setThemePreset(_ preset: ThemePreset) {
        themePreset = preset
        projectLegacyAppearanceFields()
    }

    public static let `default` = GeneralSettings()

    public init(
        themePreset: ThemePreset? = nil,
        appearance: Appearance = .system,
        accentTheme: AccentTheme = .pseudo,
        defaultProviderID: String? = nil,
        defaultModelID: String? = nil,
        subModelReference: ProviderModelReference? = nil,
        subModelID: String? = nil,
        modelSpeedTier: ModelSpeedTier = .balanced,
        chatOutputMode: ChatOutputMode = .normal,
        language: String = "zh-Hans"
    ) {
        // 默认主题 = 产品主题（第 1 套配色）；只有显式给了非默认的旧外观才走旧映射。
        let selected = themePreset?.current
            ?? (appearance == .system && accentTheme == .pseudo
                ? ThemePreset.light
                : ThemePreset.nearest(for: appearance, accentTheme: accentTheme))
        self.themePreset = selected
        // 明暗是独立选择：构造时给什么就是什么（旧深色词只收敛配色预设，不再抹掉明暗）。
        self.appearance = appearance
        self.accentTheme = ThemePreset.canonicalAccentTheme
        if let themePreset, !themePreset.isAccepted {
            self.legacyThemePresetRawValue = themePreset.rawValue
        } else if themePreset == nil && (appearance != selected.appearanceProjection || accentTheme != .pseudo) {
            self.legacyThemePresetRawValue = "\(appearance.rawValue)|\(accentTheme.rawValue)"
        }
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        if let subModelReference, subModelReference.isValid {
            self.subModelReference = subModelReference
            self.unresolvedLegacySubModelID = nil
        } else if let subModelID {
            let modelID = subModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelID.isEmpty,
               let defaultProviderID,
               !defaultProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.subModelReference = ProviderModelReference(
                    providerID: defaultProviderID,
                    modelID: modelID
                )
                self.unresolvedLegacySubModelID = nil
            } else {
                self.subModelReference = nil
                self.unresolvedLegacySubModelID = modelID.isEmpty ? nil : modelID
            }
        } else {
            self.subModelReference = nil
            self.unresolvedLegacySubModelID = nil
        }
        self.modelSpeedTier = modelSpeedTier
        self.chatOutputMode = chatOutputMode
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case themePreset, legacyThemePresetRawValue, productThemeDefaultMigrated
        case appearance, accentTheme, defaultProviderID, defaultModelID
        case subModelReference, subModelID, modelSpeedTier, chatOutputMode, language
    }

    /// 宽容解码：缺失字段回落到默认值（旧版本 JSON 兼容）。
    public init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        // 旧 JSON 无 accentTheme → 默认 .pseudo（E13 迁移默认值；与 AJ-38 伪仙色板一致）。
        accentTheme = try c.decodeIfPresent(AccentTheme.self, forKey: .accentTheme) ?? d.accentTheme
        // SETTINGS-27/THEME-05：v4 之前的 payload 没有 themePreset 键，
        // 必须由旧「外观模式 × 主题色」组合确定性映射出最近预设；
        // v4+ 的存储值优先，但未验收/不可解析的值（例如被手改坏的
        // 未知 rawValue）一律回落，绝不让不可读组合重新生效。
        let storedPreset = try c.decodeIfPresent(ThemePreset.self, forKey: .themePreset)
        let storedRaw = storedPreset?.rawValue
        let legacyAppearance = appearance
        let legacyAccent = accentTheme
        themePreset = storedPreset?.current
            ?? ThemePreset.nearest(for: legacyAppearance, accentTheme: legacyAccent)
        // 一次性迁移（需披露）：第 1 套配色起默认主题改为产品主题。没有迁移标记的旧文件里，
        // 存的是「跟随系统」的用户改成产品主题；标记随后恒写入，用户之后手动切回「跟随系统」不再被改。
        let productDefaultMigrated = try c.decodeIfPresent(Bool.self, forKey: .productThemeDefaultMigrated) ?? false
        let presetBeforeMigration = themePreset
        if !productDefaultMigrated, themePreset == .system {
            themePreset = .light
        }
        legacyThemePresetRawValue = try c.decodeIfPresent(String.self, forKey: .legacyThemePresetRawValue)
        if legacyThemePresetRawValue == nil {
            if let storedPreset, !storedPreset.isAccepted { legacyThemePresetRawValue = storedPreset.rawValue }
            else if storedRaw == nil && (legacyAppearance != themePreset.appearanceProjection || legacyAccent != .pseudo) {
                legacyThemePresetRawValue = "\(legacyAppearance.rawValue)|\(legacyAccent.rawValue)"
            }
        }
        // 明暗选择（浅色 / 深色 / 跟随系统）是独立字段。没有迁移标记的旧文件写于「产品主题固定浅色」时代：
        // 原来是浅色的用户保持固定浅色，其余一律跟随系统；有标记的文件按存储值读取。
        if !productDefaultMigrated {
            appearance = presetBeforeMigration == .light ? .light : .system
        }
        accentTheme = ThemePreset.canonicalAccentTheme
        defaultProviderID = try c.decodeIfPresent(String.self, forKey: .defaultProviderID) ?? d.defaultProviderID
        defaultModelID = try c.decodeIfPresent(String.self, forKey: .defaultModelID) ?? d.defaultModelID
        // P3-SET-01：prefer the provider-scoped value. A legacy bare string is
        // migrated when defaultProviderID is present; otherwise it remains an
        // unresolved compatibility value and cannot be routed by itself.
        let decodedReference = try c.decodeIfPresent(
            ProviderModelReference.self,
            forKey: .subModelReference
        )
        let legacyModelID = try c.decodeIfPresent(String.self, forKey: .subModelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedReference, decodedReference.isValid {
            subModelReference = decodedReference
            unresolvedLegacySubModelID = nil
        } else if let legacyModelID, !legacyModelID.isEmpty,
                  let defaultProviderID,
                  !defaultProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subModelReference = ProviderModelReference(
                providerID: defaultProviderID,
                modelID: legacyModelID
            )
            unresolvedLegacySubModelID = nil
        } else {
            subModelReference = nil
            unresolvedLegacySubModelID = legacyModelID.flatMap { $0.isEmpty ? nil : $0 }
        }
        // 旧 JSON 无 modelSpeedTier → 默认 .balanced（E19）。
        modelSpeedTier = try c.decodeIfPresent(ModelSpeedTier.self, forKey: .modelSpeedTier) ?? d.modelSpeedTier
        // 旧 JSON 无 chatOutputMode → 默认 .normal（AJ-52）。
        chatOutputMode = try c.decodeIfPresent(ChatOutputMode.self, forKey: .chatOutputMode) ?? d.chatOutputMode
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(themePreset.current, forKey: .themePreset)
        try c.encodeIfPresent(legacyThemePresetRawValue, forKey: .legacyThemePresetRawValue)
        try c.encode(true, forKey: .productThemeDefaultMigrated)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(accentTheme, forKey: .accentTheme)
        try c.encodeIfPresent(defaultProviderID, forKey: .defaultProviderID)
        try c.encodeIfPresent(defaultModelID, forKey: .defaultModelID)
        if let subModelReference, subModelReference.isValid {
            try c.encode(subModelReference, forKey: .subModelReference)
        } else {
            // Preserve an unresolved legacy value for a later catalog-aware
            // migration, but never serialize it as a canonical selection.
            try c.encodeIfPresent(unresolvedLegacySubModelID, forKey: .subModelID)
        }
        try c.encode(modelSpeedTier, forKey: .modelSpeedTier)
        try c.encode(chatOutputMode, forKey: .chatOutputMode)
        try c.encode(language, forKey: .language)
    }
}

/// agent 分组：Agent 循环参数（并发/超时/compaction/fallback）。
public struct AgentSettings: Codable, Equatable, Sendable {
    public var legacyAutomaticApprovalCompatibilityActive = false
    public var legacyApprovalPolicyOriginal: ApprovalPolicy? = nil
    public var legacyApprovalPolicyNoticePending = false
    public var legacyApprovalScopeNoticePending = false
    /// 「停用所有工具」前的审批策略；恢复时还原并清空。nil 表示没有在停用中（旧数据解码为 nil，编码时不写）。
    public var approvalPolicyBeforeToolsDisabled: ApprovalPolicy? = nil

    /// 单轮任务最大循环迭代次数。
    public var maxLoopIterations: Int
    public var maxLoopIterationsNoticeAcknowledged: Bool
    /// 不限制每回合的循环（工具调用）次数，对齐 Claude Code / Codex 没有固定回合上限的做法；
    /// 打开时 maxLoopIterations 只保留为关掉开关后的数值。停止仍靠累计 Token 上限、
    /// 重复调用检测和用户中断。11/19 用户：“改成不限”。旧数据没有这个键时按不限处理。
    public var loopIterationsUnlimited: Bool

    /// 实际交给 AgentLoop 的上限：不限时是 `AgentLoop.unlimitedIterations`。
    public var effectiveLoopIterations: Int {
        loopIterationsUnlimited ? AgentLoop.unlimitedIterations : min(100, max(1, maxLoopIterations))
    }
    /// Finite cumulative token cap. Invalid legacy values remain bounded.
    public var maxTokensPerSession: Int
    public var tokenBudgetUnlimited: Bool
    /// 工具调用超时（秒）。
    public var toolTimeoutSeconds: Int
    /// Command-only timeout. Other tools retain their independent legacy budget.
    public var shellCommandTimeoutSeconds: Int
    /// Model shell only: credentials pass through unless explicitly stripped.
    public var stripModelShellCredentials: Bool
    public var modelShellNoninteractive: Bool
    /// 审批卡的呈现方式：true = 输入框上方的行内提示条（默认），false = 弹窗。重启后保持。
    public var approvalInlineEnabled: Bool = true
    /// 交互审批等待超时自动拒绝的秒数；默认 300 秒，0 = 一直等。重启后保持。
    /// 无人值守审批（定时任务等）不受这项影响，行为不变。
    public var approvalTimeoutSeconds: Double = 300
    /// 并发工具执行上限。
    public var concurrentToolLimit: Int
    /// P3-CHILD-40：用户选择的 child 并发上限（1...40）。
    /// Recommendation/effective runtime values are derived by SettingsCenter.
    public var childConcurrencyUserSelected: Int
    /// P3-CHILD-40 / D-CHILDA · 166-B（用户裁决 2026-09-25T06:51Z「B：设置里显式选 N」）：
    /// 用户在设置里显式选择的「启用并行会话数」（1...40，与每会话 1–40 同级同上限）。
    /// 默认 1 恒等旧行为（SettingsCenter 推导件此前不传 enabledSessionCount，落
    /// ChildConcurrencySelection 默认 1）。该键是全局预算 enabled_session_count 的
    /// 唯一用户侧取数源；模型/外部经 OrchestrateRequestV1 自报的 enabled_session_count
    /// 不移动任何上限（rejection 合同 EnabledSessionCountCeilingRejectionTests 原样钉死）。
    public var childConcurrencyEnabledSessionCount: Int
    /// 上下文使用率达到该比例时触发 compaction（0~1）。
    /// D-MEMORY-02(F04)：该值是 MEMORY-02「自动压缩阈值可以调整并持久化」的
    /// canonical 落盘字段。有效域与 BL6 命令面 guard（`0...1`）一致：
    /// 构造、解码与编码三个持久化边界都会经 `normalizedAutoCompactThreshold`
    /// 收敛；非有限数或越界值（含 keyPath 直写污染）回退默认 0.8，
    /// 保证磁盘上的 settings.json 永远携带合法阈值（0 与 1 为合法边界值：
    /// 0 = 消费方回退内置警告比例，见 ChatStore.configureBudget）。
    public var autoCompactThreshold: Double
    /// nil = 使用本轮模型元数据给出的完整上下文窗口；正值只对下一轮生效。
    /// 不在持久化层造独立模型上限，实际模型边界在回合快照处校验。
    public var contextLengthTokens: Int?
    /// nil = 不按轮数裁剪历史；正值包括当前用户轮次。持久 transcript 不变。
    public var historyTurnLimit: Int?
    /// 有效阈值越界时的回退值；独立常量以避免与 `default` 的惰性初始化递归。
    public static let autoCompactThresholdFallback: Double = 0.8
    /// 将任意候选阈值收敛到有效域 `0...1`；非有限或越界 → fallback。
    public static func normalizedAutoCompactThreshold(_ value: Double) -> Double {
        value.isFinite && (0...1).contains(value) ? value : autoCompactThresholdFallback
    }
    /// 主 provider 失败时是否允许 fallback 到备用 provider。
    public var fallbackEnabled: Bool
    /// 波4：是否启用人格（注入 systemPrompt 前缀）。
    public var personaEnabled: Bool
    /// 波4：当前选中的预设（UI 切换用；默认专业助手）。
    public var personaPreset: PersonaPreset
    /// 波4：人格内容（名称/简介/语气/能力），可编辑，已持久化。
    public var persona: Persona
    /// AJ-47：默认启用记忆（True = 新会话默认加载 GLOBAL.md 与每日记忆；
    /// 单会话开关可覆盖）。默认开启。
    public var globalInstructionsEnabled: Bool
    public var memoryEnabled: Bool
    /// AJ-33：工具审批策略四态（每次问 / 自动批准 / 仅风险操作询问 / 拒绝）。
    /// 默认每次询问（最安全）。
    public var approvalPolicy: ApprovalPolicy
    /// AJ-40：智能体可用模型白名单（模型 ID 列表）。空 = 全部可用（不限制）。
    /// 启用后，Agent 只允许使用白名单内的模型，否则回退主模型。
    public var availableModelWhitelist: [String]
    /// R8：对话执行阶段新输入是否打断当前生成（最高优先级执行）。
    /// true = 生成中发送新消息立即打断旧任务，新输入立刻执行；
    /// false = 生成中回车进入队列；停止后保留队列且不自动发送。
    public var newMessageInterruptsGeneration: Bool
    /// Goal18 O11: controls new checkpoints and recovery entry, never deletes history.
    public var fileCheckpointsEnabled: Bool
    /// 后台命令或后台子任务完成后，会话空闲时是否自动续跑一轮（默认开）。
    /// 续跑沿用当前权限模式与审批；同一会话连续自动续跑有上限，用户发言后清零。
    public var backgroundAutoContinueEnabled: Bool
    /// New child turns are writable by default; parent permissions and approval still apply.
    public var childMutationsEnabled: Bool
    public var childMutationsExplicitlySelected: Bool
    /// Browser write actions remain individually approved. Restores force this off.
    public var browserWriteEnabled: Bool
    /// User-only authorization; tool input and bypass mode cannot turn it on.
    public var childModelOverridesEnabled: Bool
    /// nil uses each ready model's maximum, without inventing a second model list.
    public var childModelThinkingLevelCeiling: ThinkingLevel?
    /// Goal18 CHILD-DELETE-AUTO: user-only opt-in (default off) for the optional
    /// independent review of child-task `file_delete` approvals. It never replaces
    /// the parent's approval policy; outside the whitelist or when the classifier
    /// is unsure the existing human approval UI still decides.
    public var childDeletionAutoReviewEnabled: Bool
    /// Canonical absolute directories (default empty) the auto review may cover.
    /// Normalized at every persistence boundary; see `ChildDeletionReviewSettings`.
    public var childDeletionAutoReviewWhitelist: [String]
    /// L2：新 Composer 请求的默认策略。每次提交会复制为 immutable snapshot。
    public var composerPolicy: ComposerPolicySettings
    /// L2：生产 PolicyRuntime 的持久化保守边界。
    /// Composer 只选择请求级策略，不能放宽这里的预算、时限、自主权或网络域名。
    public var policyRuntimeDefaults: ProductionPolicyDefaults
    /// P3-TERM-01：终端命令规则；产品硬拒绝集合由 Core snapshot 固定提供。
    public var terminalPolicy: TerminalPolicySettings

    public static let `default` = AgentSettings()

    public init(
        maxLoopIterations: Int = 50,
        maxLoopIterationsNoticeAcknowledged: Bool = true,
        loopIterationsUnlimited: Bool = true,
        maxTokensPerSession: Int = 1_000_000,
        tokenBudgetUnlimited: Bool = false,
        toolTimeoutSeconds: Int = 300,
        shellCommandTimeoutSeconds: Int = ShellCommandTimeoutPolicy.defaultSeconds,
        stripModelShellCredentials: Bool = false,
        modelShellNoninteractive: Bool = true,
        concurrentToolLimit: Int = 4,
        childConcurrencyUserSelected: Int = ChildConcurrencySelection.default.userSelected,
        childConcurrencyEnabledSessionCount: Int = 1,
        autoCompactThreshold: Double = 0.8,
        contextLengthTokens: Int? = nil,
        historyTurnLimit: Int? = nil,
        fallbackEnabled: Bool = false,
        personaEnabled: Bool = false,
        personaPreset: PersonaPreset = .professional,
        persona: Persona = PersonaPreset.professional.defaultPersona,
        memoryEnabled: Bool = true,
        globalInstructionsEnabled: Bool = true,
        approvalPolicy: ApprovalPolicy = .alwaysAsk,
        availableModelWhitelist: [String] = [],
        newMessageInterruptsGeneration: Bool = false,
        fileCheckpointsEnabled: Bool = true,
        backgroundAutoContinueEnabled: Bool = true,
        childMutationsEnabled: Bool = true,
        childMutationsExplicitlySelected: Bool = false,
        browserWriteEnabled: Bool = true,
        childModelOverridesEnabled: Bool = false,
        childModelThinkingLevelCeiling: ThinkingLevel? = nil,
        childDeletionAutoReviewEnabled: Bool = false,
        childDeletionAutoReviewWhitelist: [String] = [],
        composerPolicy: ComposerPolicySettings = .default,
        policyRuntimeDefaults: ProductionPolicyDefaults = .default,
        terminalPolicy: TerminalPolicySettings = .default
    ) {
        self.maxLoopIterations = min(100, max(1, maxLoopIterations))
        self.maxLoopIterationsNoticeAcknowledged = maxLoopIterationsNoticeAcknowledged
        self.loopIterationsUnlimited = loopIterationsUnlimited
        self.maxTokensPerSession = max(1, maxTokensPerSession)
        self.tokenBudgetUnlimited = tokenBudgetUnlimited
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.shellCommandTimeoutSeconds = Int(ShellCommandTimeoutPolicy.seconds(shellCommandTimeoutSeconds))
        self.stripModelShellCredentials = stripModelShellCredentials
        self.modelShellNoninteractive = modelShellNoninteractive
        self.concurrentToolLimit = concurrentToolLimit
        self.childConcurrencyUserSelected = (1...ChildConcurrencySelection.hardMaximum)
            .contains(childConcurrencyUserSelected)
            ? childConcurrencyUserSelected
            : ChildConcurrencySelection.default.userSelected
        // 166-B：与 childConcurrencyUserSelected 同一收敛形态——构造边界把越界的
        // 启用并行会话数回退默认 1（=旧行为），不回写用户每会话选择。
        self.childConcurrencyEnabledSessionCount = (1...ChildConcurrencySelection.hardMaximum)
            .contains(childConcurrencyEnabledSessionCount)
            ? childConcurrencyEnabledSessionCount
            : 1
        self.autoCompactThreshold = Self.normalizedAutoCompactThreshold(autoCompactThreshold)
        self.contextLengthTokens = contextLengthTokens.flatMap { $0 > 0 ? $0 : nil }
        self.historyTurnLimit = historyTurnLimit.flatMap { $0 > 0 ? $0 : nil }
        self.fallbackEnabled = fallbackEnabled
        self.personaEnabled = personaEnabled
        self.personaPreset = personaPreset
        self.persona = persona
        self.memoryEnabled = memoryEnabled
        self.globalInstructionsEnabled = globalInstructionsEnabled
        self.approvalPolicy = approvalPolicy
        self.availableModelWhitelist = availableModelWhitelist
        self.newMessageInterruptsGeneration = newMessageInterruptsGeneration
        self.fileCheckpointsEnabled = fileCheckpointsEnabled
        self.backgroundAutoContinueEnabled = backgroundAutoContinueEnabled
        self.childMutationsEnabled = childMutationsEnabled
        self.childMutationsExplicitlySelected = childMutationsExplicitlySelected
        self.browserWriteEnabled = browserWriteEnabled
        self.childModelOverridesEnabled = childModelOverridesEnabled
        self.childModelThinkingLevelCeiling = childModelThinkingLevelCeiling
        self.childDeletionAutoReviewEnabled = childDeletionAutoReviewEnabled
        self.childDeletionAutoReviewWhitelist = ChildDeletionReviewSettings.normalizedWhitelist(
            childDeletionAutoReviewWhitelist)
        self.composerPolicy = composerPolicy
        self.policyRuntimeDefaults = policyRuntimeDefaults
        self.terminalPolicy = terminalPolicy.normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case legacyAutomaticApprovalCompatibilityActive, legacyApprovalPolicyOriginal, legacyApprovalPolicyNoticePending, legacyApprovalScopeNoticePending, approvalPolicyBeforeToolsDisabled
        case approvalInlineEnabled, approvalTimeoutSeconds, approvalTimeoutDefaultMigrated
        case backgroundAutoContinueEnabled
        case browserWriteEnabled, childMutationsExplicitlySelected, maxLoopIterationsNoticeAcknowledged, loopIterationsUnlimited, maxTokensPerSession, tokenBudgetDefaultMigrated, tokenBudgetUnlimited, maxLoopIterations, toolTimeoutSeconds, shellCommandTimeoutSeconds, stripModelShellCredentials, modelShellNoninteractive, concurrentToolLimit, childConcurrencyUserSelected, childConcurrencyEnabledSessionCount, autoCompactThreshold, contextLengthTokens, historyTurnLimit, fallbackEnabled, fallbackDefaultOffMigrated, personaEnabled, personaPreset, persona, memoryEnabled, globalInstructionsEnabled, approvalPolicy, availableModelWhitelist, newMessageInterruptsGeneration, fileCheckpointsEnabled, childMutationsEnabled, childModelOverridesEnabled, childModelThinkingLevelCeiling, childDeletionAutoReviewEnabled, childDeletionAutoReviewWhitelist, composerPolicy, policyRuntimeDefaults, terminalPolicy
    }

    public init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedIterations = try c.decodeIfPresent(Int.self, forKey: .maxLoopIterations)
        maxLoopIterations = min(100, max(1, storedIterations ?? d.maxLoopIterations))
        maxLoopIterationsNoticeAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .maxLoopIterationsNoticeAcknowledged) ?? (storedIterations != 10)
        loopIterationsUnlimited = try c.decodeIfPresent(Bool.self, forKey: .loopIterationsUnlimited) ?? d.loopIterationsUnlimited
        // 旧默认 10 万迁移到新默认 100 万：只迁移恰好等于旧默认、且尚未迁移过的已存值；
        // 迁移后落盘会带标记，之后用户再手动设为 10 万不会被改回。
        let storedTokenCap = try c.decodeIfPresent(Int.self, forKey: .maxTokensPerSession)
        let tokenCapMigrated = try c.decodeIfPresent(Bool.self, forKey: .tokenBudgetDefaultMigrated) ?? false
        if !tokenCapMigrated, storedTokenCap == 100_000 {
            maxTokensPerSession = d.maxTokensPerSession
        } else {
            maxTokensPerSession = max(1, storedTokenCap ?? d.maxTokensPerSession)
        }
        tokenBudgetUnlimited = try c.decodeIfPresent(Bool.self, forKey: .tokenBudgetUnlimited) ?? false
        toolTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .toolTimeoutSeconds) ?? d.toolTimeoutSeconds
        let commandTimeout = try c.decodeIfPresent(Int.self, forKey: .shellCommandTimeoutSeconds) ?? d.shellCommandTimeoutSeconds
        shellCommandTimeoutSeconds = Int(ShellCommandTimeoutPolicy.seconds(commandTimeout))
        stripModelShellCredentials = try c.decodeIfPresent(Bool.self, forKey: .stripModelShellCredentials) ?? d.stripModelShellCredentials
        modelShellNoninteractive = try c.decodeIfPresent(Bool.self, forKey: .modelShellNoninteractive) ?? d.modelShellNoninteractive
        // 审批呈现：旧 JSON 无该键 → 行内提示条、不自动拒绝；超时值只接受有限的非负数，上限 1 小时。
        approvalInlineEnabled = try c.decodeIfPresent(Bool.self, forKey: .approvalInlineEnabled) ?? d.approvalInlineEnabled
        let storedApprovalTimeout = try c.decodeIfPresent(Double.self, forKey: .approvalTimeoutSeconds) ?? d.approvalTimeoutSeconds
        // 旧默认是 0（一直等）：没有迁移标记且已存值为 0 时一次性改成新默认 300 秒；
        // 落盘带标记后，用户再手动设为 0（一直等）会保持 0。
        let approvalTimeoutMigrated = try c.decodeIfPresent(Bool.self, forKey: .approvalTimeoutDefaultMigrated) ?? false
        if !approvalTimeoutMigrated, storedApprovalTimeout == 0 {
            approvalTimeoutSeconds = d.approvalTimeoutSeconds
        } else {
            approvalTimeoutSeconds = storedApprovalTimeout.isFinite ? min(3600, max(0, storedApprovalTimeout)) : d.approvalTimeoutSeconds
        }
        concurrentToolLimit = try c.decodeIfPresent(Int.self, forKey: .concurrentToolLimit) ?? d.concurrentToolLimit
        let decodedChildSelection = try c.decodeIfPresent(
            Int.self,
            forKey: .childConcurrencyUserSelected
        ) ?? d.childConcurrencyUserSelected
        childConcurrencyUserSelected = (1...ChildConcurrencySelection.hardMaximum)
            .contains(decodedChildSelection)
            ? decodedChildSelection
            : d.childConcurrencyUserSelected
        // 166-B：旧 settings.json 无该键 → 回落默认 1（保持旧行为）；
        // 越界磁盘值同样收敛回 1，编码边界保证落盘永远合法。
        let decodedEnabledSessionCount = try c.decodeIfPresent(
            Int.self,
            forKey: .childConcurrencyEnabledSessionCount
        ) ?? d.childConcurrencyEnabledSessionCount
        childConcurrencyEnabledSessionCount = (1...ChildConcurrencySelection.hardMaximum)
            .contains(decodedEnabledSessionCount)
            ? decodedEnabledSessionCount
            : d.childConcurrencyEnabledSessionCount
        autoCompactThreshold = Self.normalizedAutoCompactThreshold(
            try c.decodeIfPresent(Double.self, forKey: .autoCompactThreshold) ?? d.autoCompactThreshold
        )
        contextLengthTokens = try c.decodeIfPresent(Int.self, forKey: .contextLengthTokens)
            .flatMap { $0 > 0 ? $0 : nil }
        historyTurnLimit = try c.decodeIfPresent(Int.self, forKey: .historyTurnLimit)
            .flatMap { $0 > 0 ? $0 : nil }
        // 跨供应商自动回退默认关闭。旧版本默认开启且无法区分“用户从未改过”和“用户主动开启”，
        // 所以没有迁移标记的已存值统一按新默认处理为关闭；设置页可再次手动打开，之后落盘带标记不再被改回。
        let fallbackMigrated = try c.decodeIfPresent(Bool.self, forKey: .fallbackDefaultOffMigrated) ?? false
        let storedFallback = try c.decodeIfPresent(Bool.self, forKey: .fallbackEnabled)
        fallbackEnabled = fallbackMigrated ? (storedFallback ?? d.fallbackEnabled) : d.fallbackEnabled
        // 波4：旧 JSON 无人格字段 → 默认禁用 + 专业助手预设。
        personaEnabled = try c.decodeIfPresent(Bool.self, forKey: .personaEnabled) ?? d.personaEnabled
        personaPreset = try c.decodeIfPresent(PersonaPreset.self, forKey: .personaPreset) ?? d.personaPreset
        persona = try c.decodeIfPresent(Persona.self, forKey: .persona) ?? d.persona
        // AJ-47：旧 JSON 无 memoryEnabled → 默认开启。
        globalInstructionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalInstructionsEnabled) ?? d.globalInstructionsEnabled
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? d.memoryEnabled
        // AJ-33：旧 JSON 无 approvalPolicy → 默认每次询问。早期 UI 曾把
        // “仅风险操作询问”错误持久化为 rawValue=never；仅在设置迁移层
        // 将该旧值解释为 riskOnlyAsk。直接构造 ApprovalPolicy.never
        // 仍是明确 deny，不改变 Core 的 fail-closed 语义。
        let rawPolicy = try c.decodeIfPresent(String.self, forKey: .approvalPolicy)
        if let rawPolicy {
            approvalPolicy = rawPolicy == "never" || rawPolicy == ApprovalPolicy.autoApprove.rawValue
                ? .riskOnlyAsk
                : (ApprovalPolicy(rawValue: rawPolicy) ?? d.approvalPolicy)
        } else {
            approvalPolicy = d.approvalPolicy
        }
        let originalPolicy = try c.decodeIfPresent(String.self, forKey: .legacyApprovalPolicyOriginal)
        let migratedAutomaticApproval = rawPolicy == ApprovalPolicy.autoApprove.rawValue
        legacyApprovalPolicyOriginal = migratedAutomaticApproval || originalPolicy == ApprovalPolicy.autoApprove.rawValue
            ? .autoApprove : nil
        let compatibility = try c.decodeIfPresent(Bool.self, forKey: .legacyAutomaticApprovalCompatibilityActive)
        legacyAutomaticApprovalCompatibilityActive = approvalPolicy == .riskOnlyAsk && legacyApprovalPolicyOriginal == .autoApprove
            && (compatibility ?? migratedAutomaticApproval)
        let policyNotice = try c.decodeIfPresent(Bool.self, forKey: .legacyApprovalPolicyNoticePending)
        legacyApprovalPolicyNoticePending = legacyApprovalPolicyOriginal != nil
            && (policyNotice ?? migratedAutomaticApproval)
        // AJ-40：旧 JSON 无 availableModelWhitelist → 默认空（全部可用）。
        availableModelWhitelist = try c.decodeIfPresent([String].self, forKey: .availableModelWhitelist) ?? d.availableModelWhitelist
        // R8：旧 JSON 无 newMessageInterruptsGeneration → Goal18 默认排队；显式保存的选择不变。
        newMessageInterruptsGeneration = try c.decodeIfPresent(Bool.self, forKey: .newMessageInterruptsGeneration) ?? d.newMessageInterruptsGeneration
        fileCheckpointsEnabled = try c.decodeIfPresent(Bool.self, forKey: .fileCheckpointsEnabled) ?? d.fileCheckpointsEnabled
        backgroundAutoContinueEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundAutoContinueEnabled) ?? d.backgroundAutoContinueEnabled
        browserWriteEnabled = try c.decodeIfPresent(Bool.self, forKey: .browserWriteEnabled) ?? d.browserWriteEnabled
        childMutationsExplicitlySelected = try c.decodeIfPresent(Bool.self, forKey: .childMutationsExplicitlySelected) ?? false
        childMutationsEnabled = childMutationsExplicitlySelected
            ? (try c.decodeIfPresent(Bool.self, forKey: .childMutationsEnabled) ?? d.childMutationsEnabled)
            : true
        childModelOverridesEnabled = try c.decodeIfPresent(Bool.self, forKey: .childModelOverridesEnabled) ?? false
        childModelThinkingLevelCeiling = try c.decodeIfPresent(ThinkingLevel.self, forKey: .childModelThinkingLevelCeiling)
        // BROWSER-WRITE: legacy JSON without the key stays off.
        // 旧 JSON 无这两个键 → 关闭 + 空白名单；白名单经统一规范化（绝对路径、去重、封顶）。
        childDeletionAutoReviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .childDeletionAutoReviewEnabled)
            ?? d.childDeletionAutoReviewEnabled
        let decodedDeletionWhitelist = try c.decodeIfPresent(
            [String].self, forKey: .childDeletionAutoReviewWhitelist) ?? []
        childDeletionAutoReviewWhitelist = ChildDeletionReviewSettings.normalizedWhitelist(decodedDeletionWhitelist)
        // L2：旧 JSON 无 Composer 默认策略 → 最小权限默认值。
        composerPolicy = try c.decodeIfPresent(ComposerPolicySettings.self, forKey: .composerPolicy) ?? d.composerPolicy
        legacyApprovalScopeNoticePending = try c.decodeIfPresent(Bool.self, forKey: .legacyApprovalScopeNoticePending)
            ?? (composerPolicy.approvalScope != .request)
        approvalPolicyBeforeToolsDisabled = try c.decodeIfPresent(ApprovalPolicy.self, forKey: .approvalPolicyBeforeToolsDisabled)
        // L2：旧 JSON 无 PolicyRuntime 默认边界 → 保守默认值。
        policyRuntimeDefaults = try c.decodeIfPresent(ProductionPolicyDefaults.self, forKey: .policyRuntimeDefaults) ?? d.policyRuntimeDefaults
        // P3-TERM-01：旧 JSON 无终端规则 → 保留原内置分类默认值。
        terminalPolicy = try c.decodeIfPresent(TerminalPolicySettings.self, forKey: .terminalPolicy) ?? d.terminalPolicy
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(min(100, max(1, maxLoopIterations)), forKey: .maxLoopIterations)
        try c.encode(maxLoopIterationsNoticeAcknowledged, forKey: .maxLoopIterationsNoticeAcknowledged)
        try c.encode(loopIterationsUnlimited, forKey: .loopIterationsUnlimited)
        try c.encode(max(1, maxTokensPerSession), forKey: .maxTokensPerSession)
        try c.encode(true, forKey: .tokenBudgetDefaultMigrated)
        try c.encode(tokenBudgetUnlimited, forKey: .tokenBudgetUnlimited)
        try c.encode(toolTimeoutSeconds, forKey: .toolTimeoutSeconds)
        try c.encode(Int(ShellCommandTimeoutPolicy.seconds(shellCommandTimeoutSeconds)), forKey: .shellCommandTimeoutSeconds)
        try c.encode(stripModelShellCredentials, forKey: .stripModelShellCredentials)
        try c.encode(modelShellNoninteractive, forKey: .modelShellNoninteractive)
        try c.encode(approvalInlineEnabled, forKey: .approvalInlineEnabled)
        try c.encode(approvalTimeoutSeconds.isFinite ? min(3600, max(0, approvalTimeoutSeconds)) : 0, forKey: .approvalTimeoutSeconds)
        try c.encode(true, forKey: .approvalTimeoutDefaultMigrated)
        try c.encode(concurrentToolLimit, forKey: .concurrentToolLimit)
        try c.encode(childConcurrencyUserSelected, forKey: .childConcurrencyUserSelected)
        try c.encode(childConcurrencyEnabledSessionCount, forKey: .childConcurrencyEnabledSessionCount)
        // D-MEMORY-02(F04)：编码边界收敛，保证落盘字节永远在有效域内，
        // 也避免被 keyPath 直写污染的 NaN 让整份 settings.json 编码失败。
        try c.encode(
            Self.normalizedAutoCompactThreshold(autoCompactThreshold),
            forKey: .autoCompactThreshold
        )
        try c.encodeIfPresent(contextLengthTokens.flatMap { $0 > 0 ? $0 : nil }, forKey: .contextLengthTokens)
        try c.encodeIfPresent(historyTurnLimit.flatMap { $0 > 0 ? $0 : nil }, forKey: .historyTurnLimit)
        try c.encode(fallbackEnabled, forKey: .fallbackEnabled)
        try c.encode(true, forKey: .fallbackDefaultOffMigrated)
        try c.encode(personaEnabled, forKey: .personaEnabled)
        try c.encode(personaPreset, forKey: .personaPreset)
        try c.encode(persona, forKey: .persona)
        try c.encode(memoryEnabled, forKey: .memoryEnabled)
        try c.encode(globalInstructionsEnabled, forKey: .globalInstructionsEnabled)
        try c.encode(approvalPolicy, forKey: .approvalPolicy)
        try c.encode(legacyAutomaticApprovalCompatibilityActive, forKey: .legacyAutomaticApprovalCompatibilityActive)
        try c.encodeIfPresent(legacyApprovalPolicyOriginal, forKey: .legacyApprovalPolicyOriginal)
        try c.encode(legacyApprovalPolicyNoticePending, forKey: .legacyApprovalPolicyNoticePending)
        try c.encode(legacyApprovalScopeNoticePending, forKey: .legacyApprovalScopeNoticePending)
        try c.encodeIfPresent(approvalPolicyBeforeToolsDisabled, forKey: .approvalPolicyBeforeToolsDisabled)
        try c.encode(availableModelWhitelist, forKey: .availableModelWhitelist)
        try c.encode(newMessageInterruptsGeneration, forKey: .newMessageInterruptsGeneration)
        try c.encode(fileCheckpointsEnabled, forKey: .fileCheckpointsEnabled)
        try c.encode(backgroundAutoContinueEnabled, forKey: .backgroundAutoContinueEnabled)
        try c.encode(childMutationsEnabled, forKey: .childMutationsEnabled)
        try c.encode(childMutationsExplicitlySelected, forKey: .childMutationsExplicitlySelected)
        try c.encode(browserWriteEnabled, forKey: .browserWriteEnabled)
        try c.encode(childModelOverridesEnabled, forKey: .childModelOverridesEnabled)
        try c.encodeIfPresent(childModelThinkingLevelCeiling, forKey: .childModelThinkingLevelCeiling)
        try c.encode(childDeletionAutoReviewEnabled, forKey: .childDeletionAutoReviewEnabled)
        try c.encode(ChildDeletionReviewSettings.normalizedWhitelist(childDeletionAutoReviewWhitelist),
            forKey: .childDeletionAutoReviewWhitelist)
        try c.encode(composerPolicy, forKey: .composerPolicy)
        try c.encode(policyRuntimeDefaults, forKey: .policyRuntimeDefaults)
        try c.encode(terminalPolicy, forKey: .terminalPolicy)
    }
}

/// privacy 分组：隐私与数据采集。
public struct PrivacySettings: Codable, Equatable, Sendable {
    /// 环境变量值是否脱敏后进入日志/模型上下文（对接 `EnvVarRedactor`）。
    public var redactEnvValues: Bool
    /// 日志级别。
    public var logLevel: SettingsLogLevel
    /// 是否收集匿名使用统计。
    public var collectAnalytics: Bool
    /// Agent 文件访问授权根目录路径；nil = 当前会话项目目录。
    /// 与 `BuiltinToolExecutor.allowedRoot` 联动。
    public var allowedRootPath: String?
    /// v1 migrates the implicit default to the session project; explicit grants survive.
    public var fileRootPolicyVersion: Int
    /// AJ-28：Agent 额外被拒绝的目录路径列表（叠加在默认拒绝目录之上；
    /// 空 = 仅默认拒绝目录，即 Application Support）。与 `ToolExecutor.deniedRoots` 联动。
    public var deniedRootPaths: [String]
    /// AJ-45：挂载的外部文件夹路径列表（Agent 可访问的额外目录白名单）。
    /// 桌面端等价物 = 移动端 `/var/minis/mounts/<name>` 的挂载目录；每个挂载目录
    /// 作为 `BuiltinToolExecutor.additionalAllowedRoots` 之一，Agent 可读写其中的文件。
    /// 最多同时挂载 `maxMountedFolders`（10）个。
    public var mountedFolderPaths: [String]
    /// 允许 external_session_read/send 直接读取本机 Codex / Claude Code 会话目录（无需挂载）。
    /// 只对外部会话工具生效，不进入文件工具白名单。
    public var allowLocalAgentSessionRead: Bool

    /// AJ-45：同时挂载的外部文件夹上限。
    public static let maxMountedFolders = 10

    public static let `default` = PrivacySettings()

    public init(
        redactEnvValues: Bool = true,
        logLevel: SettingsLogLevel = .info,
        collectAnalytics: Bool = false,
        allowedRootPath: String? = nil,
        fileRootPolicyVersion: Int = 1,
        deniedRootPaths: [String] = [],
        mountedFolderPaths: [String] = [],
        allowLocalAgentSessionRead: Bool = true
    ) {
        self.redactEnvValues = redactEnvValues
        self.logLevel = logLevel
        self.collectAnalytics = collectAnalytics
        self.allowedRootPath = allowedRootPath
        self.fileRootPolicyVersion = fileRootPolicyVersion
        self.deniedRootPaths = deniedRootPaths
        self.mountedFolderPaths = mountedFolderPaths
        self.allowLocalAgentSessionRead = allowLocalAgentSessionRead
    }

    private enum CodingKeys: String, CodingKey {
        case redactEnvValues, logLevel, collectAnalytics, allowedRootPath, fileRootPolicyVersion, deniedRootPaths, mountedFolderPaths, allowLocalAgentSessionRead
    }

    public init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redactEnvValues = try c.decodeIfPresent(Bool.self, forKey: .redactEnvValues) ?? d.redactEnvValues
        logLevel = try c.decodeIfPresent(SettingsLogLevel.self, forKey: .logLevel) ?? d.logLevel
        collectAnalytics = try c.decodeIfPresent(Bool.self, forKey: .collectAnalytics) ?? d.collectAnalytics
        allowedRootPath = try c.decodeIfPresent(String.self, forKey: .allowedRootPath) ?? d.allowedRootPath
        fileRootPolicyVersion = try c.decodeIfPresent(Int.self, forKey: .fileRootPolicyVersion) ?? 1
        deniedRootPaths = try c.decodeIfPresent([String].self, forKey: .deniedRootPaths) ?? d.deniedRootPaths
        // 旧 JSON 无 mountedFolderPaths → 默认空（AJ-45）。
        mountedFolderPaths = try c.decodeIfPresent([String].self, forKey: .mountedFolderPaths) ?? d.mountedFolderPaths
        allowLocalAgentSessionRead = try c.decodeIfPresent(Bool.self, forKey: .allowLocalAgentSessionRead) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(redactEnvValues, forKey: .redactEnvValues)
        try c.encode(logLevel, forKey: .logLevel)
        try c.encode(collectAnalytics, forKey: .collectAnalytics)
        try c.encodeIfPresent(allowedRootPath, forKey: .allowedRootPath)
        try c.encode(fileRootPolicyVersion, forKey: .fileRootPolicyVersion)
        try c.encode(deniedRootPaths, forKey: .deniedRootPaths)
        try c.encode(mountedFolderPaths, forKey: .mountedFolderPaths)
        try c.encode(allowLocalAgentSessionRead, forKey: .allowLocalAgentSessionRead)
    }
}

/// storage 分组：会话/记忆存储策略。
public struct StorageSettings: Codable, Equatable, Sendable {
    /// 会话保留天数，超过后按 `autoDeleteOldSessions` 策略清理。
    public var sessionRetentionDays: Int
    /// 记忆体积上限（MB）；nil = 不限制。
    public var memoryLimitMB: Int?
    /// 是否自动删除过期会话。
    public var autoDeleteOldSessions: Bool

    public static let `default` = StorageSettings()

    public init(
        sessionRetentionDays: Int = 30,
        memoryLimitMB: Int? = nil,
        autoDeleteOldSessions: Bool = false
    ) {
        self.sessionRetentionDays = sessionRetentionDays
        self.memoryLimitMB = memoryLimitMB
        self.autoDeleteOldSessions = autoDeleteOldSessions
    }

    private enum CodingKeys: String, CodingKey {
        case sessionRetentionDays, memoryLimitMB, autoDeleteOldSessions
    }

    public init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionRetentionDays = try c.decodeIfPresent(Int.self, forKey: .sessionRetentionDays) ?? d.sessionRetentionDays
        memoryLimitMB = try c.decodeIfPresent(Int.self, forKey: .memoryLimitMB) ?? d.memoryLimitMB
        autoDeleteOldSessions = try c.decodeIfPresent(Bool.self, forKey: .autoDeleteOldSessions) ?? d.autoDeleteOldSessions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionRetentionDays, forKey: .sessionRetentionDays)
        try c.encodeIfPresent(memoryLimitMB, forKey: .memoryLimitMB)
        try c.encode(autoDeleteOldSessions, forKey: .autoDeleteOldSessions)
    }
}

// MARK: - 浏览器（AJ-49）

/// browser 分组（AJ-49 浏览器设置）：UA 预设/自定义、viewport、空闲标签页超时。
///
/// 接入内置浏览器（`ContextPanelView` 的 `BrowserTabView` / WKWebView）：
/// - `resolvedUserAgent()`：生效的 UA 字符串（写入 `WKWebView.customUserAgent`）；
/// - `resolvedViewport()`：生效的视口尺寸（自定义视口时注入 viewport-meta 覆盖）；
/// - `idleTabTimeoutMinutes`：空闲标签页回收内存的超时时长（1~240 分钟，默认 15）。
public struct BrowserSettings: Codable, Equatable, Sendable {
    /// 用户代理预设（移动 Chrome / 桌面 Chrome / 自定义），默认桌面 Chrome。
    public var userAgentPreset: UserAgentPreset
    /// 自定义 UA 字符串（`userAgentPreset == .custom` 时生效）。空 → 回退桌面 Chrome UA。
    public var customUserAgent: String
    /// Viewport 模式（默认按 UA 自动 / 自定义宽×高），默认 `.autoByUA`。
    public var viewportMode: BrowserViewportMode
    /// 自定义视口宽度（px），默认 1280。
    public var customViewportWidth: Int
    /// 自定义视口高度（px），默认 800。
    public var customViewportHeight: Int
    /// 空闲标签页超时（分钟，1~240），默认 15；超时后回收内存（停止 WKWebView）。
    public var idleTabTimeoutMinutes: Int

    /// 空闲超时允许的最小/最大值（分钟）。
    public static let idleTimeoutRange: ClosedRange<Int> = 1...240

    public static let `default` = BrowserSettings()

    public init(
        userAgentPreset: UserAgentPreset = .desktopChrome,
        customUserAgent: String = "",
        viewportMode: BrowserViewportMode = .autoByUA,
        customViewportWidth: Int = 1280,
        customViewportHeight: Int = 800,
        idleTabTimeoutMinutes: Int = 15
    ) {
        self.userAgentPreset = userAgentPreset
        self.customUserAgent = customUserAgent
        self.viewportMode = viewportMode
        self.customViewportWidth = max(1, customViewportWidth)
        self.customViewportHeight = max(1, customViewportHeight)
        self.idleTabTimeoutMinutes = Self.clampIdleTimeout(idleTabTimeoutMinutes)
    }

    /// 把空闲超时钳制到 `1...240`（分钟）。
    public static func clampIdleTimeout(_ minutes: Int) -> Int {
        min(idleTimeoutRange.upperBound, max(idleTimeoutRange.lowerBound, minutes))
    }

    /// 生效的 UA 字符串：
    /// - `.custom` 且自定义字符串非空 → 自定义字符串；
    /// - `.custom` 但字符串为空 → 回退桌面 Chrome（避免 WebKit 用默认 UA）；
    /// - 其余预设 → 预设 UA。
    public func resolvedUserAgent() -> String {
        switch userAgentPreset {
        case .mobileChrome, .desktopChrome:
            return userAgentPreset.userAgentString ?? UserAgentPreset.desktopChrome.userAgentString!
        case .custom:
            let trimmed = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? UserAgentPreset.desktopChrome.userAgentString!
                : trimmed
        }
    }

    /// 生效的视口尺寸（px）：
    /// - `.custom` 模式 → 自定义宽×高（至少 1）；
    /// - `.autoByUA` → 按 UA 预设（移动→390×844，桌面→1280×800）。
    public func resolvedViewport() -> (width: Int, height: Int) {
        switch viewportMode {
        case .custom:
            return (max(1, customViewportWidth), max(1, customViewportHeight))
        case .autoByUA:
            return userAgentPreset.viewportSize
        }
    }

    private enum CodingKeys: String, CodingKey {
        case userAgentPreset, customUserAgent, viewportMode, customViewportWidth, customViewportHeight, idleTabTimeoutMinutes
    }

    /// 宽容解码：缺失字段回落默认值（旧版本 JSON 兼容）；空闲超时钳制到 1...240。
    public init(from decoder: Decoder) throws {
        let d = Self.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userAgentPreset = try c.decodeIfPresent(UserAgentPreset.self, forKey: .userAgentPreset) ?? d.userAgentPreset
        customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent) ?? d.customUserAgent
        viewportMode = try c.decodeIfPresent(BrowserViewportMode.self, forKey: .viewportMode) ?? d.viewportMode
        customViewportWidth = try c.decodeIfPresent(Int.self, forKey: .customViewportWidth) ?? d.customViewportWidth
        customViewportHeight = try c.decodeIfPresent(Int.self, forKey: .customViewportHeight) ?? d.customViewportHeight
        let rawIdle = try c.decodeIfPresent(Int.self, forKey: .idleTabTimeoutMinutes) ?? d.idleTabTimeoutMinutes
        idleTabTimeoutMinutes = Self.clampIdleTimeout(rawIdle)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userAgentPreset, forKey: .userAgentPreset)
        try c.encode(customUserAgent, forKey: .customUserAgent)
        try c.encode(viewportMode, forKey: .viewportMode)
        try c.encode(customViewportWidth, forKey: .customViewportWidth)
        try c.encode(customViewportHeight, forKey: .customViewportHeight)
        try c.encode(idleTabTimeoutMinutes, forKey: .idleTabTimeoutMinutes)
    }
}

// MARK: - AppSettings

/// MinisCore 设置中心数据模型（macOS 版）。
///
/// 继承 OpenMinis 手机端设置能力（只做加法），按分组组织：
/// `general` / `agent` / `privacy` / `storage`，另预留
/// `providerSettings` 存放各 provider 的额外配置（如 kling 的
/// resolution/duration 默认值）。
///
/// 解码采用宽容策略：缺失字段回落到默认值，配合
/// `SettingsMigration` 完成版本迁移（`settingsVersion`）。
public struct AppSettings: Codable, Equatable, Sendable {
    /// 当前 schema 版本。v2 新增：agent.concurrentToolLimit /
    /// agent.autoCompactThreshold / agent.fallbackEnabled /
    /// storage.memoryLimitMB / storage.autoDeleteOldSessions。
    /// v3 新增：typography.uiBaseFontSize。
    /// v4 新增：general.themePreset（SETTINGS-27/THEME-01 外观收敛，并把
    ///   旧的 appearance/accentTheme 收敛为该预设的投影）。
    /// （E19 general.modelSpeedTier 走宽容解码兜底默认值，不 bump 版本。）
    /// v5：本版把各项“默认值已迁移”标记（令牌预算、回退默认关、子任务写入选择、
    ///   自动批准兼容标记）一并固化。旧版本读到 v5 文件会按“未来版本”拒绝加载并备份，
    ///   不会再把这些标记静默丢掉后重新迁移一遍。
    public static let currentVersion = 4

    public var settingsVersion: Int
    public var general: GeneralSettings
    public var agent: AgentSettings
    public var privacy: PrivacySettings
    public var storage: StorageSettings
    /// AJ-49 浏览器设置（UA 预设/自定义、viewport、空闲标签页超时）。
    public var browser: BrowserSettings
    /// UX-01 全局 UI 排版设置。
    public var typography: TypographySettings
    /// 各 provider 的额外配置，如 `["kling": ["resolution": "720p", "duration": "5"]]`。
    public var providerSettings: [String: [String: String]]

    public static var defaults: AppSettings {
        AppSettings(
            settingsVersion: currentVersion,
            general: .default,
            agent: .default,
            privacy: .default,
            storage: .default,
            browser: .default,
            typography: .default,
            providerSettings: [:]
        )
    }

    public init(
        settingsVersion: Int = AppSettings.currentVersion,
        general: GeneralSettings = .default,
        agent: AgentSettings = .default,
        privacy: PrivacySettings = .default,
        storage: StorageSettings = .default,
        browser: BrowserSettings = .default,
        typography: TypographySettings = .default,
        providerSettings: [String: [String: String]] = [:]
    ) {
        self.settingsVersion = settingsVersion
        self.general = general
        self.agent = agent
        self.privacy = privacy
        self.storage = storage
        self.browser = browser
        self.typography = typography
        self.providerSettings = providerSettings
    }

    private enum CodingKeys: String, CodingKey {
        case settingsVersion, general, agent, privacy, storage, browser, typography, providerSettings
    }

    /// 宽容解码：缺失分组/字段回落默认值；无 `settingsVersion` 视为 v1。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
        agent = try c.decodeIfPresent(AgentSettings.self, forKey: .agent) ?? .default
        privacy = try c.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? .default
        storage = try c.decodeIfPresent(StorageSettings.self, forKey: .storage) ?? .default
        // 旧 JSON 无 browser → 默认（AJ-49，宽容解码兜底）。
        browser = try c.decodeIfPresent(BrowserSettings.self, forKey: .browser) ?? .default
        // 旧 JSON 无 typography → 默认（UX-01，迁移层会提升 schema 版本）。
        typography = try c.decodeIfPresent(TypographySettings.self, forKey: .typography) ?? .default
        providerSettings = try c.decodeIfPresent([String: [String: String]].self, forKey: .providerSettings) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(settingsVersion, forKey: .settingsVersion)
        try c.encode(general, forKey: .general)
        try c.encode(agent, forKey: .agent)
        try c.encode(privacy, forKey: .privacy)
        try c.encode(storage, forKey: .storage)
        try c.encode(browser, forKey: .browser)
        try c.encode(typography, forKey: .typography)
        try c.encode(providerSettings, forKey: .providerSettings)
    }
}
