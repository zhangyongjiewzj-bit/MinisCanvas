import Foundation
import MinisCore

/// Value-only inputs captured at the Composer turn boundary. The Skill
/// injector is already a turn-frozen projection from the composition root;
/// memory scope and picker catalog are likewise copied before leaving the UI
/// actor. No live ChatStore or settings callback crosses this boundary.
struct ChatTurnPromptPreprocessInput: Sendable {
    let basePrompt: String
    let userMessage: String
    /// Only the frozen current instruction can select picker items or skills.
    /// This is required at construction time: falling back to `userMessage`
    /// would let an appended reference capsule become a selection signal.
    let intentText: String
    let globalInstructionsEnabled: Bool
    let memoryEnabled: Bool
    let memoryInjector: MemoryInjector?
    let memoryScope: MemoryScope?
    let skillInjector: SkillInjector?
    let legacySkillResult: SkillInjectionResult
    let pickerCatalog: [PickerCatalogItem]
    let steers: [String]
    let memoryContext: MemoryInjectionContext?
    let trustedProjectRoot: URL?
    let trustedMemoryPrincipal: MemoryTrustedPrincipal?
    /// 本会话此前命中过的技能（最多 2 篇），本回合继续注入。
    let retainedSkills: [RetainedSkill]

    init(basePrompt: String, userMessage: String, memoryEnabled: Bool,
         memoryInjector: MemoryInjector?, memoryScope: MemoryScope?,
         skillInjector: SkillInjector?, legacySkillResult: SkillInjectionResult,
         pickerCatalog: [PickerCatalogItem], steers: [String],
         memoryContext: MemoryInjectionContext? = nil, intentText: String, trustedProjectRoot: URL? = nil,
         trustedMemoryPrincipal: MemoryTrustedPrincipal? = nil, globalInstructionsEnabled: Bool = true,
         retainedSkills: [RetainedSkill] = []) {
        self.retainedSkills = retainedSkills
        self.basePrompt = basePrompt
        self.userMessage = userMessage
        self.intentText = intentText
        self.globalInstructionsEnabled = globalInstructionsEnabled
        self.memoryEnabled = memoryEnabled
        self.memoryInjector = memoryInjector
        self.memoryScope = memoryScope
        self.skillInjector = skillInjector
        self.legacySkillResult = legacySkillResult
        self.pickerCatalog = pickerCatalog
        self.steers = steers
        self.memoryContext = memoryContext
        self.trustedProjectRoot = trustedProjectRoot
        self.trustedMemoryPrincipal = trustedMemoryPrincipal
    }
    func withSkillInjector(_ injector: SkillInjector?) -> Self {
        Self(basePrompt: basePrompt, userMessage: userMessage,
            memoryEnabled: memoryEnabled, memoryInjector: memoryInjector,
            memoryScope: memoryScope, skillInjector: injector,
            legacySkillResult: legacySkillResult, pickerCatalog: pickerCatalog, steers: steers,
            memoryContext: memoryContext, intentText: intentText, trustedProjectRoot: trustedProjectRoot,
            trustedMemoryPrincipal: trustedMemoryPrincipal, globalInstructionsEnabled: globalInstructionsEnabled,
            retainedSkills: retainedSkills)
    }

}

/// Describes the actual completed parent request, separately from billed usage.
/// Counts are source fragments/items, never token allocations or additive usage.
struct ChatContextSources: Sendable, Equatable {
    struct Source: Sendable, Equatable {
        let count: Int?
        let detail: String
        static func known(_ count: Int, _ unit: String) -> Self {
            Self(count: count, detail: count == 0 ? "无" : "\(count) \(unit)；token 未提供")
        }
        static let unavailable = Self(count: nil, detail: "来源分类未提供")
    }
    let system: Source
    let memory: Source
    let skills: Source
    let mcpTools: Source
    let messages: Source
    let attachments: Source
}

struct ChatTurnPromptPreprocessResult: Sendable {
    let systemPrompt: String
    let skillReceipts: [SkillInjectionReceipt]
    let memoryFactIDs: [String]
    var memoryFactDisplayInputs: [String: String] = [:]
    var memoryFactDisplayScope: MemoryScope? = nil
    var memorySourceCount: Int? = nil
    var skillSourceCount: Int? = nil
    var memoryReadFailed = false
    var globalDocumentByteCount: Int? = nil
    var trustedProjectInstructions: TrustedProjectInstructionSnapshot? = nil
    var systemPromptWithoutProjectInstructions: String? = nil
    var projectInstructionsUnavailable = false
    /// 仅在“项目有指令文件但没能加载”时有值（原因 + 下一步）；项目本来就没有指令文件时为 nil。
    var projectInstructionsUnavailableReason: String? = nil
    /// 与消息自动匹配、但未批准而没有加载的技能 id（已过滤成可显示字符）；只用于界面轻提示。
    var unapprovedMatchedSkillIDs: [String] = []

    /// User-selected Skills whose body was withheld because they lack an exact
    /// current session/project review. Identity only; never Skill content.
    var scopeRejectedSkillIDs: [String] {
        Self.promptSafeSkillIDs(skillReceipts)
    }

    /// Only plain identifier characters may enter a system prompt or UI notice.
    static func promptSafeSkillIDs(_ receipts: [SkillInjectionReceipt]) -> [String] {
        receipts.filter { $0.omittedReason == "scope_rejected" }.map { promptSafeSkillID($0.skillID) }
    }

    static func promptSafeSkillID(_ skillID: String) -> String {
        let safe = String(skillID.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0))
        }.prefix(64))
        return safe.isEmpty ? "所选技能" : safe
    }

    func excludingProjectInstructions() -> Self {
        Self(systemPrompt: systemPromptWithoutProjectInstructions ?? (trustedProjectInstructions == nil ? systemPrompt : ""),
             skillReceipts: skillReceipts, memoryFactIDs: memoryFactIDs, memoryFactDisplayInputs: memoryFactDisplayInputs, memoryFactDisplayScope: memoryFactDisplayScope,
             memorySourceCount: memorySourceCount, skillSourceCount: skillSourceCount,
             memoryReadFailed: memoryReadFailed, globalDocumentByteCount: globalDocumentByteCount)
    }
}

/// Synchronous, cancellation-aware work called only by ChatStore's detached
/// preparation task. The caller owns the MainActor identity and checks it
/// again before handing this result to an engine or Provider.
enum ChatTurnPromptPreprocessor {
    /// Project and scheduled turns use the same off-actor preparation lane as
    /// ordinary Composer turns, preserving optional recall failures as visible
    /// status without changing their exact session/project scope.
    static func preparePinnedPrompt(
        basePrompt: String,
        userMessage: String,
        memoryInjector: MemoryInjector?,
        memoryScope: MemoryScope,
        skillInjector: SkillInjector?,
        memoryContext: MemoryInjectionContext? = nil,
        trustedProjectRoot: URL? = nil
    ) throws -> String {
        try preparePinnedPromptResult(basePrompt: basePrompt, userMessage: userMessage,
            memoryInjector: memoryInjector, memoryScope: memoryScope, skillInjector: skillInjector,
            memoryContext: memoryContext, trustedProjectRoot: trustedProjectRoot).systemPrompt
    }

    static func preparePinnedPromptResult(
        basePrompt: String,
        userMessage: String,
        memoryInjector: MemoryInjector?,
        memoryScope: MemoryScope,
        skillInjector: SkillInjector?,
        memoryContext: MemoryInjectionContext? = nil,
        trustedProjectRoot: URL? = nil,
        memoryEnabled: Bool = true,
        globalInstructionsEnabled: Bool = true,
        alwaysIncludedSkillIDs: [String] = []
    ) throws -> ChatTurnPromptPreprocessResult {
        try Task.checkCancellation()
        var prompt = basePrompt
        var withoutProject = basePrompt
        var memoryFactIDs: [String] = []
        var memoryFactDisplayInputs: [String: String] = [:]
        var memoryFactDisplayScope: MemoryScope?
        var memorySourceCount: Int? = 0
        var skillSourceCount = 0
        var memoryReadFailed = false
        var globalDocumentByteCount: Int? = nil
        let instructionReport = try trustedProjectRoot.map {
            try TrustedProjectInstructions.loadReport(atTrustedRoot: $0)
        }
        let trustedInstructions = instructionReport?.snapshot
        if let trustedInstructions { prompt += "\n\n" + trustedInstructions.systemPromptPrefix }
        if globalInstructionsEnabled, let memoryInjector {
            do {
                if let global = try memoryInjector.globalInstructions() {
                    prompt += "\n\n" + global.block
                    withoutProject += "\n\n" + global.block
                    globalDocumentByteCount = global.byteCount
                }
            } catch {
                memoryReadFailed = true
            }
        }
        let context = memoryContext ?? MemoryInjectionContext(scope: memoryScope)
        if memoryEnabled, let memoryInjector, context.scope == memoryScope {
            let injection = try memoryInjector.optionalInjection(
                base: "", userMessage: userMessage, context: context, includeGlobalInstructions: false)
            if !injection.prompt.isEmpty {
                prompt = prompt.isEmpty ? injection.prompt : prompt + "\n\n" + injection.prompt
                withoutProject = withoutProject.isEmpty ? injection.prompt : withoutProject + "\n\n" + injection.prompt
            }
            memoryFactIDs = injection.injectedFactIDs
            memoryFactDisplayInputs = injection.projectFactDisplayInputs
            memoryFactDisplayScope = context.scope
            memorySourceCount = injection.readFailed ? nil : (injection.prompt.isEmpty ? 0 : 1)
            memoryReadFailed = memoryReadFailed || injection.readFailed
        }
        try Task.checkCancellation()
        if let skillInjector {
            // 2026-11-15 第七版：定时、跨项目回合也附技能目录；定时回合固定带上 scheduled-task 技能。
            if let catalog = skillInjector.catalogFragment(within: memoryScope, userMessage: userMessage) {
                prompt += "\n\n" + catalog
                withoutProject += "\n\n" + catalog
            }
            let injection = skillInjector.buildInjection(
                for: userMessage, selectedSkillIDs: alwaysIncludedSkillIDs, within: memoryScope
            )
            if let fragment = injection.fragment {
                skillSourceCount = 1
                prompt += "\n\n" + fragment
                withoutProject += "\n\n" + fragment
            }
        }
        try Task.checkCancellation()
        return ChatTurnPromptPreprocessResult(systemPrompt: prompt, skillReceipts: [], memoryFactIDs: memoryFactIDs, memoryFactDisplayInputs: memoryFactDisplayInputs, memoryFactDisplayScope: memoryFactDisplayScope, memorySourceCount: memorySourceCount, skillSourceCount: skillSourceCount, memoryReadFailed: memoryReadFailed,
            globalDocumentByteCount: globalDocumentByteCount, trustedProjectInstructions: trustedInstructions,
            systemPromptWithoutProjectInstructions: withoutProject,
            projectInstructionsUnavailable: instructionReport?.unavailableReason != nil,
            projectInstructionsUnavailableReason: instructionReport?.unavailableReason)
    }

    static func prepare(
        _ input: ChatTurnPromptPreprocessInput
    ) -> ChatTurnPromptPreprocessResult? {
        guard !Task.isCancelled else { return nil }
        var prompt = input.basePrompt
        var withoutProject = input.basePrompt
        var memoryFactIDs: [String] = []
        var memoryFactDisplayInputs: [String: String] = [:]
        var memoryFactDisplayScope: MemoryScope?
        var memorySourceCount: Int? = 0
        var skillSourceCount = 0
        var memoryReadFailed = false
        var globalDocumentByteCount: Int? = nil
        let instructionReport: TrustedProjectInstructions.LoadReport?
        var instructionReadFailed = false
        if let root = input.trustedProjectRoot {
            do { instructionReport = try TrustedProjectInstructions.loadReport(atTrustedRoot: root) }
            catch { instructionReport = nil; instructionReadFailed = true }
        } else { instructionReport = nil }
        let trustedInstructions = instructionReport?.snapshot
        let instructionUnavailableReason = instructionReadFailed
            ? "项目目录暂时无法读取，请确认文件夹仍在原位置。" : instructionReport?.unavailableReason
        if let trustedInstructions { prompt += "\n\n" + trustedInstructions.systemPromptPrefix }
        if input.globalInstructionsEnabled, let injector = input.memoryInjector {
            do {
                if let global = try injector.globalInstructions() {
                    prompt += "\n\n" + global.block
                    withoutProject += "\n\n" + global.block
                    globalDocumentByteCount = global.byteCount
                }
            } catch {
                memoryReadFailed = true
            }
        }
        if input.memoryEnabled, let injector = input.memoryInjector {
            do {
                let injection: MemoryInjectionResult?
                if let scope = input.memoryScope {
                    let context = input.memoryContext ?? MemoryInjectionContext(scope: scope)
                    injection = context.scope == scope
                        ? try injector.injection(base: "", userMessage: input.userMessage, context: context, includeGlobalInstructions: false)
                        : nil
                } else if input.memoryContext == nil {
                    injection = try injector.userLevelInjection(
                        base: "", userMessage: input.userMessage, trustedPrincipal: input.trustedMemoryPrincipal, includeGlobalInstructions: false)
                } else {
                    injection = nil
                }
                if let injection {
                    if !injection.prompt.isEmpty {
                        prompt = prompt.isEmpty ? injection.prompt : prompt + "\n\n" + injection.prompt
                        withoutProject = withoutProject.isEmpty ? injection.prompt : withoutProject + "\n\n" + injection.prompt
                    }
                    memorySourceCount = injection.readFailed ? nil : (injection.prompt.isEmpty ? 0 : 1)
                    memoryFactIDs = injection.injectedFactIDs
                    memoryFactDisplayInputs = injection.projectFactDisplayInputs
                    memoryFactDisplayScope = input.memoryScope
                    memoryReadFailed = memoryReadFailed || injection.readFailed
                }
            } catch {
                // A corrupt facts file must stop memory injection without
                // changing the user's turn or claiming the store is empty.
                memorySourceCount = nil
                memoryReadFailed = true
            }
        }
        guard !Task.isCancelled else { return nil }

        let refNames = ChatStore.pickerReferences(
            in: input.intentText,
            catalogNames: input.pickerCatalog.map(\.name)
        )
        let pickerItems = refNames.compactMap { name in
            input.pickerCatalog.first {
                $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame
            }
        }
        let selectedSkillIDs = pickerItems
            .filter { $0.kind == .skill }
            .map(\.id)
        let skillResult = input.skillInjector?.buildInjection(
            for: input.intentText,
            selectedSkillIDs: selectedSkillIDs,
            retainedSkills: input.retainedSkills,
            within: input.memoryScope
        ) ?? input.legacySkillResult
        guard !Task.isCancelled else { return nil }
        if let catalog = input.skillInjector?.catalogFragment(within: input.memoryScope, userMessage: input.intentText) {
            prompt += "\n\n" + catalog
            withoutProject += "\n\n" + catalog
        }
        if let extra = skillResult.fragment {
            skillSourceCount = 1
            prompt += "\n\n" + extra
            withoutProject += "\n\n" + extra
        }
        let rejectedSelections = ChatTurnPromptPreprocessResult.promptSafeSkillIDs(skillResult.receipts)
        if !rejectedSelections.isEmpty {
            let notice = "<skill_notice>用户选中的技能 \(rejectedSelections.joined(separator: "、")) 未在当前会话和项目审核，本次未注入；可在 设置→技能→“在当前会话和项目重新审核…” 后再使用。</skill_notice>"
            prompt += "\n\n" + notice
            withoutProject += "\n\n" + notice
        }
        // 自动匹配上但未批准的技能只做界面轻提示，不进发给模型的正文。
        let unapprovedMatches = input.skillInjector?
            .unapprovedMatchingSkillIDs(for: input.intentText, within: input.memoryScope)
            .map(ChatTurnPromptPreprocessResult.promptSafeSkillID) ?? []
        if let extra = ChatStore.pickerContentInjectionFragment(for: pickerItems) {
            prompt += "\n\n" + extra
            withoutProject += "\n\n" + extra
        }
        if !input.steers.isEmpty {
            prompt = ChatStore.systemPrompt(withSteers: prompt, steers: input.steers)
            withoutProject = ChatStore.systemPrompt(withSteers: withoutProject, steers: input.steers)
        }
        return ChatTurnPromptPreprocessResult(
            systemPrompt: prompt,
            skillReceipts: skillResult.receipts,
            memoryFactIDs: memoryFactIDs, memoryFactDisplayInputs: memoryFactDisplayInputs, memoryFactDisplayScope: memoryFactDisplayScope, memorySourceCount: memorySourceCount, skillSourceCount: skillSourceCount, memoryReadFailed: memoryReadFailed,
            globalDocumentByteCount: globalDocumentByteCount, trustedProjectInstructions: trustedInstructions,
            systemPromptWithoutProjectInstructions: withoutProject,
            projectInstructionsUnavailable: instructionUnavailableReason != nil,
            projectInstructionsUnavailableReason: instructionUnavailableReason,
            unapprovedMatchedSkillIDs: unapprovedMatches
        )
    }
}
