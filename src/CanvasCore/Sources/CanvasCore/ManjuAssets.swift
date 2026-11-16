import Foundation

// MARK: - 漫剧全局资产（资产锁定层）
//
// manju-core 铁律 2/3/6：参考图只写"只继承什么、不继承什么"，锁参考图只写锁定部位清单，
// 禁止对部位做细节描述；垫图/资产已有的信息不重复描述。
// 因此资产模型只承载「锁定清单 + 具体色值/结构」，不承载形容词。

/// 角色锁定卡：定妆图锁脸和肤色（铁律3）
public struct ManjuCharacterCard: Equatable, Sendable, Codable, Hashable {
    /// 角色名，如 "魏衔"
    public var name: String
    /// 锁定部位清单（脸、五官、眼型、骨相、肤色……）——只写部位名，禁细节描述
    public var lockParts: [String]
    /// 定妆图资产引用（8角度脸参考板），如文件路径/资产 ID
    public var referenceImageID: String?
    /// 定妆图真实图片路径（P0 资产层承载图：进画布 assetRef 节点缩略图 / 下游 img2img 参考图）
    public var referenceImagePath: String?
    /// 角色参考视频路径（B2：V2V 动作/神态参考视频，进 assetRef.video 输出端口 → 生视频节点）
    public var referenceVideoPath: String?

    public init(name: String, lockParts: [String], referenceImageID: String? = nil, referenceImagePath: String? = nil, referenceVideoPath: String? = nil) {
        self.name = name
        self.lockParts = lockParts
        self.referenceImageID = referenceImageID
        self.referenceImagePath = referenceImagePath
        self.referenceVideoPath = referenceVideoPath
    }

    /// 注入 REFERENCE / REFERENCE MAP 槽的锁定文本（只继承清单，禁止细节描述）
    public var referenceLockText: String {
        let parts = lockParts.joined(separator: "、")
        let ref = referenceImageID.map { "参考图：\($0)。" } ?? ""
        return "\(ref)\(name) 定妆图只继承：\(parts)；以上部位只锁定、不许改，禁止对部位做细节描述（铁律2/3）。"
    }
}

/// 服装资产：结构写具体织纹/磨损/厚度/垂坠（审美闸口S3），禁形容词
public struct ManjuCostumeAsset: Equatable, Sendable, Codable, Hashable {
    /// 服装名，如 "魏衔·玄色道袍"
    public var name: String
    /// 结构/材质锁定描述（具体织纹、磨损、厚度、垂坠）
    public var structure: String
    /// 服装定妆图资产引用（4张）
    public var referenceImageID: String?
    /// 服装图真实图片路径（P0 资产层承载图）
    public var referenceImagePath: String?
    /// 服装参考视频路径（B2：布料动态/穿着效果参考视频，进 assetRef.video 输出端口）
    public var referenceVideoPath: String?

    public init(name: String, structure: String, referenceImageID: String? = nil, referenceImagePath: String? = nil, referenceVideoPath: String? = nil) {
        self.name = name
        self.structure = structure
        self.referenceImageID = referenceImageID
        self.referenceImagePath = referenceImagePath
        self.referenceVideoPath = referenceVideoPath
    }

    /// 注入 STRUCTURE 槽的锁定文本
    public var structureLockText: String {
        let ref = referenceImageID.map { "参考图：\($0)。" } ?? ""
        return "\(ref)\(name)：\(structure)；服装结构以资产图为准，不重复描述（铁律6）。"
    }
}

/// 场景资产：场景俯视母图 + 九宫格（生产优先顺序）
public struct ManjuSceneAsset: Equatable, Sendable, Codable, Hashable {
    /// 场景名，如 "青崖观·大殿"
    public var name: String
    /// 空间结构锁定描述（布局方向、前中后景层次）
    public var layout: String
    /// 场景母图资产引用
    public var masterImageID: String?
    /// 场景母图真实图片路径（P0 资产层承载图）
    public var masterImagePath: String?
    /// 场景母视频路径（B2：空间运镜/布光参考视频，进 assetRef.video 输出端口）
    public var masterVideoPath: String?

    public init(name: String, layout: String, masterImageID: String? = nil, masterImagePath: String? = nil, masterVideoPath: String? = nil) {
        self.name = name
        self.layout = layout
        self.masterImageID = masterImageID
        self.masterImagePath = masterImagePath
        self.masterVideoPath = masterVideoPath
    }

    /// 注入 LAYOUT 槽的场景锁定文本
    public var layoutLockText: String {
        let ref = masterImageID.map { "母图：\($0)。" } ?? ""
        return "\(ref)\(name)：\(layout)；场景空间以母图为准，只继承空间结构、不继承镜头角度（铁律1）。"
    }
}

/// 色板条目：具体色名 + 色值 + 面积比例
public struct ManjuPaletteEntry: Equatable, Sendable, Codable, Hashable {
    public var colorName: String
    public var hex: String
    /// 面积占比（0-100），主辅压边强调合计 100（70/20/8/2）
    public var areaPercent: Int

    public init(colorName: String, hex: String, areaPercent: Int) {
        self.colorName = colorName
        self.hex = hex
        self.areaPercent = areaPercent
    }
}

/// 全局色板：颜色必须写具体色名+色值或面积比例，禁"高级灰/仙气"等模糊词（审美闸口S2）
public struct ManjuPalette: Equatable, Sendable, Codable, Hashable {
    /// 色板版本（阶段交接要求色板版本一致）
    public var version: String
    public var entries: [ManjuPaletteEntry]

    public init(version: String, entries: [ManjuPaletteEntry]) {
        self.version = version
        self.entries = entries
    }

    /// 注入 COLOR 槽的锁定文本（色名+色值+面积比例）
    public var colorLockText: String {
        let parts = entries.map { "\($0.colorName)(#\($0.hex)) \($0.areaPercent)%" }
        return "色板 \(version)：\(parts.joined(separator: "、"))；强调色只出现在细线、窄带、光效、点睛位置（审美闸口S2）。"
    }
}

/// 漫剧资产库：角色卡/服装/场景/色板 + 项目固定风格锁
public struct ManjuAssetLibrary: Equatable, Sendable, Codable {
    public var characters: [ManjuCharacterCard]
    public var costumes: [ManjuCostumeAsset]
    public var scenes: [ManjuSceneAsset]
    public var palette: ManjuPalette?
    /// 项目固定风格锁（从项目锁定层复制，如 weixian-lock），视频 STYLE LOCK 槽必填
    public var styleLock: String?

    public init(
        characters: [ManjuCharacterCard] = [],
        costumes: [ManjuCostumeAsset] = [],
        scenes: [ManjuSceneAsset] = [],
        palette: ManjuPalette? = nil,
        styleLock: String? = nil
    ) {
        self.characters = characters
        self.costumes = costumes
        self.scenes = scenes
        self.palette = palette
        self.styleLock = styleLock
    }

    /// 演示资产库（伪仙题材示例，对齐模板中的 weixian-lock）
    public static var demo: ManjuAssetLibrary {
        ManjuAssetLibrary(
            characters: [
                ManjuCharacterCard(
                    name: "魏衔",
                    lockParts: ["脸", "五官", "眼型", "骨相", "肤色", "发型"],
                    referenceImageID: "asset://weixian-face-8angle"
                )
            ],
            costumes: [
                ManjuCostumeAsset(
                    name: "魏衔·玄色道袍",
                    structure: "粗麻织纹、袖口磨损起毛、厚垂坠、领口窄边压线",
                    referenceImageID: "asset://weixian-costume-4x"
                )
            ],
            scenes: [
                ManjuSceneAsset(
                    name: "青崖观·大殿",
                    layout: "纵深三进、前景香炉、中景立柱、后景神像暗部",
                    masterImageID: "asset://qingya-hall-master"
                )
            ],
            palette: ManjuPalette(
                version: "v1",
                entries: [
                    ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 70),
                    ManjuPaletteEntry(colorName: "灰褐", hex: "6B5D4F", areaPercent: 20),
                    ManjuPaletteEntry(colorName: "暗金", hex: "B08D3E", areaPercent: 8),
                    ManjuPaletteEntry(colorName: "朱砂", hex: "C2452D", areaPercent: 2),
                ]
            ),
            styleLock: "weixian-lock：伪仙写实、暗部带色相、危险但美（美感70%/危险30%）"
        )
    }
}

// MARK: - 资产媒体种类（assetRef 节点挂载的视频/图片资产）

/// 资产引用（assetRef）节点已挂载媒体的种类：图片 / 视频（assetKind 等价字段）。
///
/// 与 F12 结果媒体键约定同源：`backendConfig.params["result.kind"]` 存原始串
/// （"image" / "video"），此处提供类型化视图；`NodeBackendConfig` 为 Codable，
/// 原始串经 JSON 往返无损，恢复/导入旧图时按 `result.kind` 重建种类（无字段漂移）。
public enum ManjuAssetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case image
    case video

    /// 挂载媒体键 `result.kind` 的原始串（写回 params 用）
    public var rawParamValue: String { rawValue }
}

public extension CanvasNode {
    /// Canonical mounted media identity. The ID is the only new node write;
    /// path/kind accessors below remain legacy read projections.
    var mediaAssetID: UUID? {
        backendConfig?.params["asset.id"].flatMap(UUID.init(uuidString:))
    }

    /// assetRef 已挂载资产的种类（读取 `result.kind`；未挂载/未知返回 nil）。
    /// 画布渲染据此选择图片缩略图面板或视频播放入口面板。
    var assetKind: ManjuAssetKind? {
        guard let raw = backendConfig?.params["result.kind"] else { return nil }
        return ManjuAssetKind(rawValue: raw)
    }

    /// Legacy assetRef media path read projection for old documents.
    var assetMediaPath: String? {
        backendConfig?.params["result.path"]
    }
}

// MARK: - 资产锁定注入

/// 资产锁定注入：把全局资产拼入提示词节点 backendConfig.params 的对应槽位键。
///
/// 生成时强制携带：注入键以 `slot.` 前缀写入节点参数，执行端组装最终提示词时
/// 必须原样带上对应槽位文本（只继承、不重复描述），保证角色一致性。
public enum ManjuAssetInjection {
    /// 注入参数键前缀：`slot.<槽名>` = 该槽位的锁定文本
    public static let slotKeyPrefix = "slot."
    /// 标记键：值为 "1" 表示该节点已完成资产锁定注入
    public static let lockedFlagKey = "manju.assets.locked"
    /// 资产摘要键：注入到 assetRef 节点，描述其引用的资产内容
    public static let assetRefSummaryKey = "asset.summary"

    /// 图片提示词节点（8槽）注入：REFERENCE / STRUCTURE / COLOR（场景进 LAYOUT）
    public static func imagePromptParams(for assets: ManjuAssetLibrary) -> [String: String] {
        var params: [String: String] = [:]
        let refs = assets.characters.map(\.referenceLockText)
        if !refs.isEmpty {
            params[slotKeyPrefix + "REFERENCE"] = refs.joined(separator: "\n")
        }
        let structures = assets.costumes.map(\.structureLockText)
        if !structures.isEmpty {
            params[slotKeyPrefix + "STRUCTURE"] = structures.joined(separator: "\n")
        }
        let layouts = assets.scenes.map(\.layoutLockText)
        if !layouts.isEmpty {
            params[slotKeyPrefix + "LAYOUT"] = layouts.joined(separator: "\n")
        }
        if let palette = assets.palette {
            params[slotKeyPrefix + "COLOR"] = palette.colorLockText
        }
        if !params.isEmpty { params[lockedFlagKey] = "1" }
        return params
    }

    /// 视频提示词节点（9槽）注入：REFERENCE MAP / STYLE LOCK / COLOR
    public static func videoPromptParams(for assets: ManjuAssetLibrary) -> [String: String] {
        var params: [String: String] = [:]
        let refs = assets.characters.map(\.referenceLockText)
        if !refs.isEmpty {
            params[slotKeyPrefix + "REFERENCE MAP"] = refs.joined(separator: "\n")
        }
        if let styleLock = assets.styleLock, !styleLock.isEmpty {
            params[slotKeyPrefix + "STYLE LOCK"] = styleLock
        }
        if let palette = assets.palette {
            params[slotKeyPrefix + "COLOR"] = palette.colorLockText
        }
        if !params.isEmpty { params[lockedFlagKey] = "1" }
        return params
    }

    /// 按节点类型返回应注入的锁定参数；非提示词节点返回空
    public static func injectionParams(for assets: ManjuAssetLibrary, nodeType: ManjuNodeType) -> [String: String] {
        switch nodeType {
        case .imagePrompt: return imagePromptParams(for: assets)
        case .videoPrompt: return videoPromptParams(for: assets)
        default: return [:]
        }
    }

    /// 对图中所有提示词节点重新注入资产锁定（资产更新后调用），返回更新后的图。
    /// 已有同键参数会被覆盖，保证锁定文本与最新资产库一致。
    public static func applyLockedAssets(_ assets: ManjuAssetLibrary, to graph: NodeGraph) -> NodeGraph {
        var updated = graph
        for index in updated.nodes.indices {
            let node = updated.nodes[index]
            guard let type = ManjuNodeType(rawValue: node.type) else { continue }
            let injected = injectionParams(for: assets, nodeType: type)
            guard !injected.isEmpty else { continue }
            var config = node.backendConfig ?? NodeBackendConfig()
            for (key, value) in injected {
                config.params[key] = value
            }
            updated.nodes[index].backendConfig = config
        }
        return updated
    }
}
