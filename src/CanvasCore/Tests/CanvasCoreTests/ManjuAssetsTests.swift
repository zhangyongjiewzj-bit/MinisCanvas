import Foundation
import Testing
@testable import CanvasCore

// MARK: - ManjuAssets 测试：资产注册 / 锁定 / 版本（A3）

/// 资产库默认构造：所有集合为空、色板与风格锁为 nil
@Test func testLibraryEmptyDefaults() {
    let lib = ManjuAssetLibrary()
    #expect(lib.characters.isEmpty)
    #expect(lib.costumes.isEmpty)
    #expect(lib.scenes.isEmpty)
    #expect(lib.palette == nil)
    #expect(lib.styleLock == nil)
}

/// 资产注册：角色卡 / 服装 / 场景 / 色板 完整注册并保持原值
@Test func testRegisterAssets() {
    let character = ManjuCharacterCard(
        name: "魏衔",
        lockParts: ["脸", "肤色", "眼型"],
        referenceImageID: "asset://face-8angle"
    )
    let costume = ManjuCostumeAsset(
        name: "魏衔·玄色道袍",
        structure: "粗麻织纹、袖口磨损起毛、厚垂坠",
        referenceImageID: "asset://costume-4x"
    )
    let scene = ManjuSceneAsset(
        name: "青崖观·大殿",
        layout: "纵深三进、前景香炉、中景立柱",
        masterImageID: "asset://hall-master"
    )
    let palette = ManjuPalette(
        version: "v1",
        entries: [
            ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 70),
            ManjuPaletteEntry(colorName: "朱砂", hex: "C2452D", areaPercent: 2),
        ]
    )
    let lib = ManjuAssetLibrary(
        characters: [character],
        costumes: [costume],
        scenes: [scene],
        palette: palette,
        styleLock: "weixian-lock：伪仙写实"
    )
    #expect(lib.characters == [character])
    #expect(lib.costumes == [costume])
    #expect(lib.scenes == [scene])
    #expect(lib.palette == palette)
    #expect(lib.styleLock == "weixian-lock：伪仙写实")
}

/// 演示资产库：与模板对齐的 1 角色 / 1 服装 / 1 场景 / 4 色色板 / 风格锁
@Test func testDemoLibrary() {
    let demo = ManjuAssetLibrary.demo
    #expect(demo.characters.count == 1)
    #expect(demo.characters.first?.name == "魏衔")
    #expect(demo.characters.first?.lockParts.contains("脸") == true)
    #expect(demo.characters.first?.referenceImageID == "asset://weixian-face-8angle")
    #expect(demo.costumes.count == 1)
    #expect(demo.costumes.first?.name == "魏衔·玄色道袍")
    #expect(demo.scenes.count == 1)
    #expect(demo.scenes.first?.name == "青崖观·大殿")
    #expect(demo.palette?.version == "v1")
    #expect(demo.palette?.entries.count == 4)
    // 色板面积比例合计 100（70/20/8/2）
    #expect((demo.palette?.entries.map(\.areaPercent).reduce(0, +)) == 100)
    #expect(demo.styleLock?.isEmpty == false)
}

/// 资产库 Codable 往返：编码后解码保持等值（版本记录随库持久化）
@Test func testLibraryCodableRoundTrip() throws {
    let lib = ManjuAssetLibrary.demo
    let data = try JSONEncoder().encode(lib)
    let decoded = try JSONDecoder().decode(ManjuAssetLibrary.self, from: data)
    #expect(decoded == lib)
    #expect(decoded.palette?.version == "v1")
}

// MARK: - 锁定文本

/// 角色锁定卡：只写锁定部位清单 + 参考图，声明「只继承、不许改、禁细节描述」（铁律2/3）
@Test func testCharacterReferenceLockText() {
    let card = ManjuCharacterCard(
        name: "魏衔",
        lockParts: ["脸", "五官", "眼型", "肤色"],
        referenceImageID: "asset://face"
    )
    let text = card.referenceLockText
    #expect(text.contains("魏衔"))
    #expect(text.contains("参考图：asset://face"))
    #expect(text.contains("只继承：脸、五官、眼型、肤色"))
    #expect(text.contains("只锁定、不许改"))
    #expect(text.contains("禁止对部位做细节描述"))
    // 只写部位名，禁止细节描述词
    #expect(!text.contains("眼尾上挑"))
}

/// 服装锁定：结构写具体织纹/磨损/厚度/垂坠，禁形容词；带铁律6 声明
@Test func testCostumeStructureLockText() {
    let costume = ManjuCostumeAsset(
        name: "玄色道袍",
        structure: "粗麻织纹、袖口磨损起毛、厚垂坠、领口窄边压线",
        referenceImageID: "asset://costume"
    )
    let text = costume.structureLockText
    #expect(text.contains("玄色道袍"))
    #expect(text.contains("粗麻织纹、袖口磨损起毛、厚垂坠、领口窄边压线"))
    #expect(text.contains("参考图：asset://costume"))
    #expect(text.contains("不重复描述"))
}

/// 场景锁定：布局方向/层次 + 母图引用，只继承空间结构、不继承镜头（铁律1）
@Test func testSceneLayoutLockText() {
    let scene = ManjuSceneAsset(
        name: "青崖观·大殿",
        layout: "纵深三进、前景香炉、中景立柱、后景神像暗部",
        masterImageID: "asset://hall-master"
    )
    let text = scene.layoutLockText
    #expect(text.contains("青崖观·大殿"))
    #expect(text.contains("母图：asset://hall-master"))
    #expect(text.contains("只继承空间结构、不继承镜头角度"))
}

/// 色板锁定文本：色名(#色值) 面积比例 + 版本 + 强调色位置约束（审美闸口S2）
@Test func testPaletteColorLockText() {
    let palette = ManjuPalette(
        version: "v1",
        entries: [
            ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 70),
            ManjuPaletteEntry(colorName: "朱砂", hex: "C2452D", areaPercent: 2),
        ]
    )
    let text = palette.colorLockText
    #expect(text.contains("色板 v1"))
    #expect(text.contains("玄青(#1F2A33) 70%"))
    #expect(text.contains("朱砂(#C2452D) 2%"))
    #expect(text.contains("强调色只出现在细线、窄带、光效、点睛位置"))
}

// MARK: - 资产锁定注入

/// 图片提示词注入：REFERENCE / STRUCTURE / LAYOUT / COLOR 四槽 + 锁定标记
@Test func testImagePromptParams() {
    let params = ManjuAssetInjection.imagePromptParams(for: .demo)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "REFERENCE"]?.contains("魏衔") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "REFERENCE"]?.contains("只继承") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "STRUCTURE"]?.contains("玄色道袍") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "LAYOUT"]?.contains("青崖观·大殿") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "COLOR"]?.contains("色板 v1") == true)
    #expect(params[ManjuAssetInjection.lockedFlagKey] == "1")
}

/// 视频提示词注入：REFERENCE MAP / STYLE LOCK / COLOR + 锁定标记
@Test func testVideoPromptParams() {
    let params = ManjuAssetInjection.videoPromptParams(for: .demo)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "REFERENCE MAP"]?.contains("魏衔") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "STYLE LOCK"]?.contains("weixian-lock") == true)
    #expect(params[ManjuAssetInjection.slotKeyPrefix + "COLOR"]?.contains("色板 v1") == true)
    #expect(params[ManjuAssetInjection.lockedFlagKey] == "1")
}

/// 空资产库：不注入任何槽位、不写锁定标记
@Test func testEmptyLibraryNoInjection() {
    let params = ManjuAssetInjection.imagePromptParams(for: ManjuAssetLibrary())
    #expect(params.isEmpty)
}

/// 按节点类型注入：仅提示词节点有注入，生成/资产/文本节点为空
@Test
func testInjectionParamsByNodeType() {
    let assets = ManjuAssetLibrary.demo
    #expect(!ManjuAssetInjection.injectionParams(for: assets, nodeType: .imagePrompt).isEmpty)
    #expect(!ManjuAssetInjection.injectionParams(for: assets, nodeType: .videoPrompt).isEmpty)
    #expect(ManjuAssetInjection.injectionParams(for: assets, nodeType: .imageGen).isEmpty)
    #expect(ManjuAssetInjection.injectionParams(for: assets, nodeType: .videoGen).isEmpty)
    #expect(ManjuAssetInjection.injectionParams(for: assets, nodeType: .assetRef).isEmpty)
    #expect(ManjuAssetInjection.injectionParams(for: assets, nodeType: .qcCheck).isEmpty)
    #expect(ManjuAssetInjection.injectionParams(for: assets, nodeType: .novelImport).isEmpty)
}

/// 全图注入：提示词节点写入锁定槽位 + 标记，非提示词节点不受影响
@Test func testApplyLockedAssetsToGraph() {
    var graph = NodeGraph()
    graph.addNode(CanvasNode(type: ManjuNodeType.imagePrompt.rawValue, title: "图片提示词"))
    graph.addNode(CanvasNode(type: ManjuNodeType.videoPrompt.rawValue, title: "视频提示词"))
    graph.addNode(CanvasNode(type: "text", title: "文本"))
    graph.addNode(CanvasNode(type: ManjuNodeType.imageGen.rawValue, title: "图片生成"))

    let updated = ManjuAssetInjection.applyLockedAssets(.demo, to: graph)
    let imagePrompt = updated.nodes[0]
    let videoPrompt = updated.nodes[1]
    let text = updated.nodes[2]
    let imageGen = updated.nodes[3]

    #expect(imagePrompt.backendConfig?.params[ManjuAssetInjection.slotKeyPrefix + "REFERENCE"] != nil)
    #expect(imagePrompt.backendConfig?.params[ManjuAssetInjection.slotKeyPrefix + "STRUCTURE"] != nil)
    #expect(imagePrompt.backendConfig?.params[ManjuAssetInjection.lockedFlagKey] == "1")
    #expect(videoPrompt.backendConfig?.params[ManjuAssetInjection.slotKeyPrefix + "STYLE LOCK"] != nil)
    #expect(videoPrompt.backendConfig?.params[ManjuAssetInjection.lockedFlagKey] == "1")
    #expect(text.backendConfig == nil)
    #expect(imageGen.backendConfig == nil)
}

// MARK: - 版本

/// 版本记录：色板版本随注入文本原样携带，且每次注入覆盖为最新版本
@Test func testPaletteVersionInjectionAndUpdate() {
    var assets = ManjuAssetLibrary.demo
    let v1Color = ManjuAssetInjection.imagePromptParams(for: assets)[
        ManjuAssetInjection.slotKeyPrefix + "COLOR"
    ]
    #expect(v1Color?.contains("色板 v1") == true)

    // 资产更新（色板升 v2）后重新注入 → 锁定文本与最新资产库一致
    var palette = assets.palette!
    palette.version = "v2"
    assets.palette = palette

    let v2Color = ManjuAssetInjection.imagePromptParams(for: assets)[
        ManjuAssetInjection.slotKeyPrefix + "COLOR"
    ]
    #expect(v2Color?.contains("色板 v2") == true)

    // 对已注入的图重跑 applyLockedAssets：同键被覆盖为 v2，不留旧版本
    var graph = NodeGraph()
    graph.addNode(CanvasNode(type: ManjuNodeType.imagePrompt.rawValue, title: "图片提示词"))
    let updated = ManjuAssetInjection.applyLockedAssets(assets, to: graph)
    #expect(updated.nodes[0].backendConfig?.params[
        ManjuAssetInjection.slotKeyPrefix + "COLOR"
    ]?.contains("色板 v2") == true)
}

/// 色板条目：面积比例字段参与等值比较（版本一致 = 色板一致）
@Test func testPaletteEntryEquatable() {
    let a = ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 70)
    let b = ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 70)
    let c = ManjuPaletteEntry(colorName: "玄青", hex: "1F2A33", areaPercent: 2)
    #expect(a == b)
    #expect(a != c)
}
