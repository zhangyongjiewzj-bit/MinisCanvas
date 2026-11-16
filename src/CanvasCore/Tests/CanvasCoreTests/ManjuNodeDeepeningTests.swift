import Testing
@testable import CanvasCore

// MARK: - A5 漫剧节点深化测试：QC 三刻度盘 + 生视频任务单 9 槽导出 + 资产锁定接线

struct ManjuNodeDeepeningTests {

    // MARK: - 测试数据

    /// 合法视频 9 槽提示词（三刻度盘 7/5/4，审美闸口 S1-S5 全过）
    static let validVideoPrompt = """
    [MODE]
    I2V

    [REFERENCE MAP]
    参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色；以上部位只锁定、不许改，禁止对部位做细节描述（铁律2/3）。

    [STYLE LOCK]
    weixian-lock：伪仙写实、暗部带色相、危险但美（美感70%/危险30%）

    [SHOT]
    中景、机位平视、缓慢推近、主体偏右留白；有主次关系和视觉动线，前中后景层次分明。

    [ACTION]
    0-1秒：转身。1-3秒：拔剑。3-5秒：挥剑定格。所有时间段之和必须精确等于镜头时长（铁律11）。

    [COLOR]
    玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%；强调色只在点睛位置。

    [SOUND]
    环境风声、衣袍摩擦声、剑鸣声。

    [FORBID]
    现代鞋、高跟鞋、换脸。

    [QC]
    status=PASS / skill_check=PASS / aesthetic_gate=PASS / style_lock=PASS / color_hierarchy=PASS / visual_flow=PASS / beauty_danger_ratio=70:30 / dial_variance=7 / dial_motion=5 / dial_density=4
    """

    /// 合法图片 8 槽提示词
    static let validImagePrompt = """
    [TYPE]
    9:16 竖屏定妆图，全身立绘，危险但美（美感70%/危险30%）。

    [REFERENCE]
    参考图：asset://weixian-face-8angle。魏衔 定妆图只继承：脸、五官、眼型、骨相、肤色。

    [LAYOUT]
    主体居中偏右、留白在左，有主次关系和视觉动线。

    [STRUCTURE]
    粗麻织纹、袖口磨损起毛、厚垂坠。

    [MATERIAL]
    粗麻、磨损、垂坠。

    [COLOR]
    玄青(#1F2A33) 70%、灰褐(#6B5D4F) 20%、暗金(#B08D3E) 8%、朱砂(#C2452D) 2%。

    [LIGHT]
    侧逆光、轮廓光、斑驳树影。

    [FORBID]
    现代鞋、高跟鞋、换脸。
    """

    // MARK: - QC：三刻度盘 + 结构闸口 + 审美闸口

    @Test func qcPassOnCompleteVideoPrompt() {
        let result = ManjuQCEvaluator.evaluate(prompt: Self.validVideoPrompt)
        #expect(result.status == .pass, "完整 9 槽 + 三刻度盘合法 + 闸口全过应 PASS")
        #expect(result.templateKind == .video9)
        #expect(result.missingSlots.isEmpty)
        #expect(result.dials == ManjuQCDials(variance: 7, motion: 5, density: 4))
        #expect(result.reasons.isEmpty)
        #expect(result.aestheticGates.allSatisfy { $0.passed }, "S1-S5 应全过")
        #expect(result.report.contains("状态: PASS"))
        #expect(result.report.contains("dial_variance=7"))
    }

    @Test func qcFailOnMissingSlotAndDials() {
        // 缺 MODE 槽、ACTION 为「（待填）」、QC 槽无三刻度盘
        let bad = Self.validVideoPrompt
            .replacingOccurrences(of: "[MODE]\nI2V\n\n", with: "")
            .replacingOccurrences(of: "0-1秒：转身。1-3秒：拔剑。3-5秒：挥剑定格。所有时间段之和必须精确等于镜头时长（铁律11）。", with: "（待填）")
            .replacingOccurrences(of: " / dial_variance=7 / dial_motion=5 / dial_density=4", with: "")
        let result = ManjuQCEvaluator.evaluate(prompt: bad)
        #expect(result.status == .fail)
        #expect(result.missingSlots.contains("MODE"), "缺 MODE 槽应被 BLOCKED（铁律7）")
        #expect(result.missingSlots.contains("ACTION"), "ACTION 为（待填）应视为缺字段")
        #expect(result.dialIssues.contains { $0.contains("缺少三刻度盘") }, "缺三刻度盘应 FAIL")
        #expect(result.reasons.contains { $0.contains("BLOCKED") })
    }

    @Test func qcFailOnDialsOutOfRange() {
        let bad = Self.validVideoPrompt
            .replacingOccurrences(of: "dial_variance=7", with: "dial_variance=12")
        let result = ManjuQCEvaluator.evaluate(prompt: bad)
        #expect(result.status == .fail)
        #expect(result.dialIssues.contains { $0.contains("越界") })
        #expect(result.dials?.isValid == false)
    }

    @Test func qcFailsOnEmptyInput() {
        let result = ManjuQCEvaluator.evaluate(prompt: nil)
        #expect(result.status == .fail)
        #expect(result.templateKind == .unknown)
    }

    @Test func qcPassOnCompleteImagePrompt() {
        let result = ManjuQCEvaluator.evaluate(prompt: Self.validImagePrompt)
        #expect(result.status == .pass, "完整 8 槽图片提示词应 PASS")
        #expect(result.templateKind == .image8)
        #expect(result.missingSlots.isEmpty)
        #expect(result.aestheticGates.allSatisfy { $0.passed })
    }

    @Test func qcSceneRangeAdvisoryMatchesSceneType() {
        let fight = Self.validVideoPrompt.replacingOccurrences(of: "I2V", with: "I2V\n打斗戏")
        let result = ManjuQCEvaluator.evaluate(prompt: fight)
        #expect(result.rangeAdvisory?.contains("打斗/渡劫戏") == true, "打斗关键词应给出戏型区间建议")
        #expect(result.status == .pass, "戏型区间建议只是提示，不参与判级")
    }

    // MARK: - QC 节点执行器（NodeExecutors 路由）

    @Test func qcNodeRoutedToDeterministicExecutor() {
        let executor = NodeExecutors().executor(for: ManjuNodeType.qcCheck.rawValue)
        #expect(executor is QCNodeExecutor, "qcCheck 应路由到 QCNodeExecutor（不依赖 LLM）")
        #expect(!(executor is LLMNodeExecutor))
    }

    @Test func qcNodeExecutorOutputsReportAndDials() async throws {
        let executor = QCNodeExecutor()
        let node = CanvasNode(
            type: ManjuNodeType.qcCheck.rawValue,
            title: "QC检查",
            inputs: [Port(name: "text", direction: .input, dataType: "string")],
            outputs: [Port(name: "report", direction: .output, dataType: "string")]
        )
        let output = try await executor.execute(
            node: node,
            inputs: ["prompt": Self.validVideoPrompt],
            backend: nil
        )
        #expect(output["status"] as? String == "PASS")
        #expect(output["qc_status"] as? String == "PASS")
        #expect(output["dial_variance"] as? Int == 7)
        #expect(output["dial_motion"] as? Int == 5)
        #expect(output["dial_density"] as? Int == 4)
        #expect((output["report"] as? String)?.contains("状态: PASS") == true)
    }

    @Test func qcNodeExecutorFailsOnBrokenInput() async throws {
        let executor = QCNodeExecutor()
        let node = CanvasNode(type: "qcCheck", title: "QC检查")
        let output = try await executor.execute(node: node, inputs: ["text": "随便一段没有槽位结构的文本"], backend: nil)
        #expect(output["status"] as? String == "FAIL")
        #expect((output["reasons"] as? String)?.contains("槽结构") == true)
    }

    // MARK: - 资产锁定接线（AssetLockExecutor）

    @Test func assetRefRoutedToAssetLockExecutor() {
        let executor = NodeExecutors().executor(for: ManjuNodeType.assetRef.rawValue)
        #expect(executor is AssetLockExecutor, "assetRef 应路由到 AssetLockExecutor（资产锁定接线）")
    }

    @Test func assetLockExecutorOutputsSummaryAndReferenceImages() async throws {
        let summary = """
        角色卡：魏衔（锁 脸、五官、眼型、骨相、肤色）
        服装：魏衔·玄色道袍
        场景：青崖观·大殿
        色板 v1：#1F2A33/#6B5D4F/#B08D3E/#C2452D
        风格锁：weixian-lock：伪仙写实
        参考图：asset://weixian-face-8angle。
        母图：asset://qingya-hall-master。
        """
        let config = NodeBackendConfig(
            providerType: .cloud, providerID: "bailian", modelID: "qwen3.8-max-preview",
            params: [ManjuAssetInjection.assetRefSummaryKey: summary]
        )
        let node = CanvasNode(
            type: ManjuNodeType.assetRef.rawValue,
            title: "资产引用",
            inputs: [],
            outputs: [Port(name: "assets", direction: .output, dataType: "string")],
            backendConfig: config
        )
        let executor = AssetLockExecutor()
        let output = try await executor.execute(node: node, inputs: nil, backend: config)
        #expect(output["status"] as? String == "succeeded")
        #expect(output["locked"] as? String == "1")
        #expect((output["assets"] as? String)?.contains("角色卡：魏衔") == true)
        let refs = output["referenceImages"] as? [String] ?? []
        #expect(refs == ["asset://weixian-face-8angle", "asset://qingya-hall-master"], "应提取参考图锁定清单（铁律2）")
    }

    // MARK: - 任务单导出内容（ManjuTicketParser：9 槽结构 + MODE + 时段校验）

    @Test func ticketParserBuildsFullNineSlotStructure() {
        let template = ManjuPromptTemplates.template(for: .videoPrompt)!
        let params: [String: String] = [
            "slot.MODE": "I2V",
            "slot.STYLE LOCK": "weixian-lock：伪仙写实",
        ]
        let prompt = ManjuTicketParser.buildPrompt(from: template, params: params)
        let sections = ManjuTicketParser.parseSlots(prompt, template: template)
        #expect(sections.count == 9, "视频任务单应导出完整 9 槽结构")
        #expect(sections.map(\.name) == ["MODE", "REFERENCE MAP", "STYLE LOCK", "SHOT",
                                         "ACTION", "COLOR", "SOUND", "FORBID", "QC"])
        #expect(sections.first { $0.name == "MODE" }?.content == "I2V")
        #expect(sections.first { $0.name == "SHOT" }?.content == ManjuTicketParser.pendingPlaceholder,
                "未注入的槽位应标「（待填）」（结构完整可复制）")
        // FORBID 段单独可取（铁律4）
        let forbid = sections.first { $0.name == "FORBID" }?.content ?? ""
        #expect(forbid == ManjuTicketParser.pendingPlaceholder)
    }

    @Test func ticketParserExtractsMode() {
        #expect(ManjuTicketParser.mode(from: Self.validVideoPrompt) == "I2V")
        #expect(ManjuTicketParser.mode(from: "[MODE]\nR2V\n[SHOT]") == "R2V")
        #expect(ManjuTicketParser.mode(from: "[MODE]\n（待填）\n[SHOT]") == nil)
        #expect(ManjuTicketParser.mode(from: "没有槽位标记的文本") == nil)
    }

    @Test func ticketParserExtractsReferenceIDsDedup() {
        let text = "参考图：asset://a。参考图：asset://a。母图：asset://b。垫图：asset://c"
        #expect(ManjuTicketParser.extractReferenceIDs(from: text) == ["asset://a", "asset://b", "asset://c"],
                "参考图清单按出现顺序去重（铁律2）")
        #expect(ManjuTicketParser.extractReferenceIDs(from: "无参考图").isEmpty)
    }

    @Test func actionDurationValidationMatchesShotDuration() {
        let segments = ManjuTicketParser.parseActionSegments("0-1秒：转身。1-3秒：拔剑。3-5秒：挥剑定格。")
        #expect(segments.map(\.duration) == [1, 2, 2])
        #expect(ManjuTicketParser.totalDuration(segments) == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "5") == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "5s") == 5)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "5秒") == 5)

        let note = ManjuTicketParser.actionDurationNote(
            actionText: "0-1秒：转身。1-3秒：拔剑。3-5秒：挥剑定格。",
            shotDurationSeconds: 5
        )
        #expect(note.contains("✓"), "时段总和 = 镜头时长应通过（铁律11）")
        #expect(note.contains("5 秒 = 镜头时长 5 秒"))
    }

    @Test func actionDurationValidationWarnsOnMismatch() {
        // 0-1 + 1-3 + 3-6 = 6 秒 ≠ 5 秒
        let note = ManjuTicketParser.actionDurationNote(
            actionText: "0-1秒 / 1-3秒 / 3-6秒",
            shotDurationSeconds: 5
        )
        #expect(note.contains("⚠️"), "时段总和 ≠ 镜头时长应警告（铁律11：超出=被截断，不足=用未批准动作填满）")
        #expect(note.contains("≠"))
    }

    @Test func actionDurationValidationHandlesMissingSegmentsAndDuration() {
        let missingSegments = ManjuTicketParser.actionDurationNote(actionText: "转身、拔剑（无时段）", shotDurationSeconds: 5)
        #expect(missingSegments.contains("未检测到时段段"))

        let noDuration = ManjuTicketParser.actionDurationNote(
            actionText: "0-1秒 / 1-3秒 / 3-5秒",
            shotDurationSeconds: nil
        )
        #expect(noDuration.contains("未配置镜头时长"))
        #expect(ManjuTicketParser.shotDurationSeconds(from: nil) == nil)
        #expect(ManjuTicketParser.shotDurationSeconds(from: "abc") == nil)
    }
}
