import Foundation

// MARK: - P3-OUTPUT-01 · 普通 Agent 输出统一卡片投影（producer-only）
//
// 本文件只建模「普通 Agent 输出」的统一卡片：摘要、分页游标、Diff 引用、
// Finder/编辑器打开目标解析，以及缺失/越界两类错误态。
// 它是纯投影层：不做 SwiftUI 接线、不触网、不落盘、不读写全局可变状态。
// 消费方接线（ChatStore/ContentView）由后续 OUTPUT-01 接线线负责，
// 因此这里的所有产物都不携带绝对路径或内容载荷，只携带可判定的引用。

// MARK: - 卡片种类与错误态

/// 统一卡片种类。普通 Agent 回合的三类产出物共用同一卡片协议。
enum AgentOutputCardKind: String, Codable, Sendable, Equatable {
    case file
    case diff
    case toolResult
}

/// 卡片可见的两类失败态。语义刻意收敛到最小可证集合：
/// - `missing`：请求的目标（文件/差异记录/正文）在事实源中不存在。
/// - `outOfBounds`：请求越出了允许边界（游标越界、路径逃逸工作区、非法请求参数）。
enum AgentOutputCardFailure: String, Codable, Sendable, Equatable {
    case missing
    case outOfBounds
}

// MARK: - 输入记录

/// 单个普通 Agent 输出的最小事实描述。仅含工作区相对路径与逻辑 ID，
/// 不含绝对路径、不含正文、不含 diff 载荷。
struct AgentOutputRecord: Codable, Sendable, Equatable {
    let outputID: String
    let kind: AgentOutputCardKind
    let title: String
    /// 工具结果正文的行数（分页用）；非工具结果可传 0。
    let bodyLineCount: Int
    /// 产出/修改文件时的工作区相对路径；无文件跳转为 nil。
    let relativeFilePath: String?
    /// 差异台账 ID；无可审阅差异时为 nil。
    let diffID: String?

    init(
        outputID: String,
        kind: AgentOutputCardKind,
        title: String,
        bodyLineCount: Int = 0,
        relativeFilePath: String? = nil,
        diffID: String? = nil
    ) {
        self.outputID = outputID
        self.kind = kind
        self.title = title
        self.bodyLineCount = bodyLineCount
        self.relativeFilePath = relativeFilePath
        self.diffID = diffID
    }
}

// MARK: - 卡片摘要

/// 用户可见的统一卡片摘要。detail 文案是闭集枚举文本，
/// 绝不拼接任何路径（相对或绝对）或正文内容，沿用
/// `ArtifactOutputUserProjection` 的「投影不携带路径运输」契约。
struct AgentOutputCardSummary: Codable, Sendable, Equatable {
    let outputID: String
    let kind: AgentOutputCardKind
    let title: String
    let detail: String
    /// 卡片是否暴露文件跳转（Finder/编辑器）能力位。
    let offersFileJump: Bool
    /// 卡片是否暴露 Diff 跳转能力位。
    let offersDiffJump: Bool
    /// 卡片是否分页展示正文。
    let offersPagination: Bool
}

enum AgentOutputCardSummarizer {
    /// 把事实记录投影为统一卡片摘要。纯函数，无副作用。
    static func summarize(_ record: AgentOutputRecord) -> AgentOutputCardSummary {
        let detail: String
        switch record.kind {
        case .file:
            detail = "产出文件，可在 Finder 中定位或用编辑器打开。"
        case .diff:
            detail = "包含可审阅的变更记录。"
        case .toolResult:
            detail = "工具输出共 \(max(record.bodyLineCount, 0)) 行，可分页查看。"
        }
        return AgentOutputCardSummary(
            outputID: record.outputID,
            kind: record.kind,
            title: record.title,
            detail: detail,
            offersFileJump: record.relativeFilePath != nil,
            offersDiffJump: record.diffID != nil,
            offersPagination: record.kind == .toolResult
        )
    }
}

// MARK: - 分页游标
//
// 最小可证语义（回执 adjudication_pending 已列明）：
// 页索引 0 起、固定页大小（单位=行）；总页数 = ceil(行数/页大小)，
// 空正文仍保留唯一第 0 页；越界索引、负页大小、负行数一律判 .outOfBounds，
// fail-closed，不做环绕或钳制。
//
// 入参域：`bodyLineCount`、`pageSize`、`pageIndex` 均为任意非负 `Int`
// （上游是行计数与请求参数，本层不做「实际数据只有几千行」的隐含假设）。
//
// 244B 纠偏（独审静态确证的缺陷）：页数原写作
// `(bodyLineCount + pageSize - 1) / pageSize` 的向上取整形式。加法按
// Swift 的 `+`/`-` 左结合展开为 `(bodyLineCount + pageSize) - 1`，
// 而 `Int` 加法溢出即 trap，因此入参域内至少两组输入会崩溃：
//   - `bodyLineCount = Int.max, pageSize = 2`：`Int.max + 2` 先溢出；
//   - `bodyLineCount = 1, pageSize = Int.max`：`1 + Int.max` 先溢出。
// 现改为「商 + 余数」形式（见 `AgentOutputPageMath.ceilDiv`），
// 只做除法/取模与至多一次 +1，非负域内可逐项证明不溢出。

struct AgentOutputPageCursor: Codable, Sendable, Equatable {
    let pageIndex: Int
    let pageSize: Int
}

enum AgentOutputPaginationOutcome: Sendable, Equatable {
    case window(pageIndex: Int, firstLine: Int, lineCount: Int, totalPages: Int)
    case failure(AgentOutputCardFailure)
}

enum AgentOutputPageMath {
    /// 非负整数域的向上取整商 `ceil(n / d)`，在任何 `n >= 0 && d > 0` 的
    /// `Int` 输入上都不溢出。
    ///
    /// 论证（`n`、`d` 为调用方已归一到非负的 `Int`）：
    /// 1. `q = n / d`、`r = n % d`：`d > 0` 已由守卫保证，`Int` 除法只除零
    ///    才 trap（唯一另一个 trap 形 `Int.min / (-1)` 需负操作数，不在域内）；
    ///    且 `0 <= q <= n <= Int.max`、`0 <= r < d`，两个结果本身不溢出。
    /// 2. 只在 `r != 0` 时做 `q + 1`。`r != 0` 意味着 `n = q*d + r >= q*d + 1`，
    ///    故 `q <= (n - 1) / d`：
    ///      - `d == 1` 时 `r == n % 1 == 0`，永不进入 +1 分支；
    ///      - `d >= 2` 时 `q <= (n - 1) / 2 <= (Int.max - 1) / 2`，
    ///        于是 `q + 1 <= (Int.max + 1) / 2 < Int.max`，加法不溢出。
    /// 3. 无任何 `*`、无 `n + d` 形态的中间量，故不存在别的溢出点。
    static func ceilDiv(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator > 0, "ceilDiv requires a positive denominator")
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        return quotient + (remainder == 0 ? 0 : 1)
    }
}

enum AgentOutputPaginator {
    static func paginate(cursor: AgentOutputPageCursor, bodyLineCount: Int) -> AgentOutputPaginationOutcome {
        guard cursor.pageSize > 0, cursor.pageIndex >= 0, bodyLineCount >= 0 else {
            return .failure(.outOfBounds)
        }
        // 商余形式：无 `n + d - 1` 中间加法，非负域内不溢出（见 ceilDiv 论证）。
        let pagesOfBody = AgentOutputPageMath.ceilDiv(bodyLineCount, cursor.pageSize)
        // 空正文仍保留唯一第 0 页；`max` 只做比较，不做算术。
        let totalPages = max(1, pagesOfBody)
        guard cursor.pageIndex < totalPages else {
            return .failure(.outOfBounds)
        }
        // `firstLine` 的乘法同样不溢出：由 `pageIndex < totalPages = ceil(n/d)` 得
        //   - 余数 = 0 时 pageIndex <= q - 1 ⇒ pageIndex*d <= n - d <= n；
        //   - 余数 ≠ 0 时 pageIndex <= q     ⇒ pageIndex*d = n - r <= n；
        // 两种情形的数学值都 <= bodyLineCount <= Int.max，故 `Int` 乘法不溢出。
        let firstLine = cursor.pageIndex * cursor.pageSize
        let lineCount = min(cursor.pageSize, bodyLineCount - firstLine)
        return .window(
            pageIndex: cursor.pageIndex,
            firstLine: firstLine,
            lineCount: lineCount,
            totalPages: totalPages
        )
    }
}

// MARK: - Diff 引用
//
// 最小可证语义：卡片只携带台账 ID 与统计（改动文件数/增删行数），
// diff 载荷本体保存在差异台账；台账无该 ID 即 .missing。

struct AgentOutputDiffReference: Codable, Sendable, Equatable {
    let diffID: String
    let changedFileCount: Int
    let insertions: Int
    let deletions: Int
}

enum AgentOutputDiffResolution: Sendable, Equatable {
    case resolved(AgentOutputDiffReference)
    case failure(AgentOutputCardFailure)
}

enum AgentOutputDiffResolver {
    /// 在只读台账里解析 diff 引用；不复制载荷。
    static func resolve(
        diffID: String?,
        in ledger: [String: AgentOutputDiffReference]
    ) -> AgentOutputDiffResolution {
        guard let diffID else {
            return .failure(.missing)
        }
        guard let reference = ledger[diffID] else {
            return .failure(.missing)
        }
        return .resolved(reference)
    }
}

// MARK: - 打开目标解析
//
// 纯解析：把「工作区根 + 相对路径 + 打开模式」解析为带错误态的目标，
// 存在性经注入闭包判定（测试可给固定表，生产由接线线注入 FileManager）。
// 边界语义（adjudication_pending 已列明）：只接受可被 standardize 后
// 仍位于工作区根之内（或恰为根）的路径；空路径判 .missing；
// 绝对路径与逃逸（.. /波浪号）判 .outOfBounds；不存在判 .missing。
//
// 已知边界缺口（244B 登记，见下一节「物理路径边界合同」）：上面的
// `standardizedFileURL` 只是**词法**标准化，它不解析符号链接，因此
// 「词法形在工作区内、物理目标在工作区外」的 symlink（含祖先目录被
// symlink 的情形）当前会被判为合法目标。本文件只把合同写清楚并给出
// 可测的纯判定函数，**不接入生产入口**；是否接入、以及接入点由 C0 裁决。

enum AgentOutputOpenMode: String, Codable, Sendable, Equatable {
    case finderReveal
    case editor
}

enum AgentOutputOpenResolution: Sendable, Equatable {
    case target(url: URL, mode: AgentOutputOpenMode)
    case failure(AgentOutputCardFailure)
}

enum AgentOutputOpenTargetResolver {
    /// - Parameters:
    ///   - rawPath: 工作区相对路径（不允许绝对路径与 `~` 展开）。
    ///   - workspaceRoot: 已标准化的工作区根目录 URL。
    ///   - exists: 注入的存在性判定（无副作用；生产实现由接线线提供）。
    static func resolve(
        rawPath: String?,
        mode: AgentOutputOpenMode,
        workspaceRoot: URL,
        exists: (URL) -> Bool
    ) -> AgentOutputOpenResolution {
        guard let raw = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(.missing)
        }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            return .failure(.outOfBounds)
        }
        let root = workspaceRoot.standardizedFileURL
        let joined = root.path + "/" + raw
        let candidate = URL(fileURLWithPath: joined).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return .failure(.outOfBounds)
        }
        guard exists(candidate) else {
            return .failure(.missing)
        }
        return .target(url: candidate, mode: mode)
    }
}

// MARK: - 物理路径边界合同（contract_documented_not_wired · 待 C0 裁决）
//
// 状态声明（重要）：本节类型**不被本文件的任何生产入口调用**——
// `AgentOutputOpenTargetResolver.resolve` 与 `AgentOutputCardProjection.project`
// 仍是纯词法判定，唯一的引用者是测试文件。是否把物理边界接入生产入口、
// 接入哪一层（投影层 / 接线层的 FileManager 包装）、以及下面的错误投影
// 选择，全部登记为待裁决项，由 C0 裁决后另派接线线执行。
//
// 为什么需要这份合同：`URL.standardizedFileURL` 只做字符串级 `.`/`..` 折叠，
// 不解析符号链接。于是「词法形在工作区内、真实目标在工作区外」的 symlink
// （`workspace/logs/link -> /etc/passwd`）、以及祖先目录被 symlink 换出的情形，
// 都能绕过当前判定，把打开动作（Finder 定位 / 编辑器打开）指到工作区之外。
//
// 合同条款（拟定，逐条对应下方实现）：
// C-1 顺序：先做既有词法判定；词法已越界即刻 fail-closed 返回 .outOfBounds，
//     不再触碰工作区外的任何解析（避免对越界节点做 symlink 遍历）。
// C-2 解析对象：词法通过之后，工作区根与候选目标**都**要经过 symlink 解析
//     （即两侧都取物理路径），只解析一侧会留下「根本身是 symlink」的镜像缺口。
//     具体用哪个解析 API（`resolvingSymlinksInPath` / `realpath` /
//     `FileManager.destinationOfSymbolicLink` 多跳循环保护）属接线决策，
//     本层只接收注入的解析结果，不自己调文件系统。
// C-3 比较方式：物理包含判定按**路径分量**逐个比较，不用裸字符串前缀，
//     因此 `/workspace` 的根不会把 `/workspace-evil/...` 误判为在内。
//     入参必须是已词法标准化的绝对路径（分量里不含 `.`、`..`、重复斜杠）。
//     入参绝对性核验 fail-closed：candidate 或 root 任一缺少前导 `/`
//     即无法证明在内，直接判不在内（不扩语义，仅落实上述入参约定）。
// C-4 边界归属：解析后恰等于工作区根视为「在内」（与词法阶段的根判定一致）。
// C-5 错误投影（沿用既有两态闭集，不新增 case）：
//     - 目标不存在（ENOENT）→ .missing（与今天 exists == false 同态）；
//     - 解析失败（ELOOP / ENOTDIR / EACCES / EPERM 等任何非 ENOENT 错误）
//       → .outOfBounds（无法证明在内即拒绝，fail-closed）；
//     - 工作区根自身解析不出物理路径 → .outOfBounds（连边界都无法确定）；
//     - 物理目标在根之外 → .outOfBounds，即使词法形在内。
// C-6 返回载荷：判定通过后交给打开动作的仍是**词法 URL**，不回传物理路径，
//     以免把工作区外的真实位置写进卡片/日志/可访问性文本（与「投影不携带
//     路径运输」契约一致）。若裁决要求改为回传物理 URL，属接线线适配。

/// 物理（symlink 解析后）路径的解析结果。由接线方注入，本层不触碰文件系统。
enum AgentOutputPhysicalPathResolution: Sendable, Equatable {
    /// 解析成功后的物理绝对路径（已词法标准化）。
    case resolved(physicalPath: String)
    /// 目标不存在（ENOENT）。合同 C-5 投影为 `.missing`。
    case targetAbsent
    /// 解析失败但不属于「不存在」（ELOOP/EACCES/ENOTDIR/EPERM…）。
    /// 合同 C-5 投影为 `.outOfBounds`。
    case targetUnresolvable
}

/// 物理边界判定的结论。`allowed` 不新增失败态：错误投影仍是
/// `AgentOutputCardFailure` 的两态闭集（合同 C-5）。
enum AgentOutputPhysicalBoundaryVerdict: Sendable, Equatable {
    case allowed
    case failure(AgentOutputCardFailure)
}

enum AgentOutputPhysicalPathBoundaryContract {
    /// 供排重/审计读取的状态常量：合同已成文但未接入生产入口。
    static let wiringStatus: String = "pending_C0_ruling_not_wired"

    /// 按合同 C-1…C-5 判定一次打开请求是否越出物理边界。
    /// - Parameters:
    ///   - lexicalPathInsideWorkspaceRoot: 既有词法阶段（`standardizedFileURL`
    ///     + 根内比较）的结论。`false` 表示词法已越界。
    ///   - physicalWorkspaceRoot: 工作区根的物理路径；`nil` 表示根解析不出。
    ///   - physicalTarget: 候选目标的物理解析结果。
    static func judge(
        lexicalPathInsideWorkspaceRoot: Bool,
        physicalWorkspaceRoot: String?,
        physicalTarget: AgentOutputPhysicalPathResolution
    ) -> AgentOutputPhysicalBoundaryVerdict {
        guard lexicalPathInsideWorkspaceRoot else {
            // C-1：词法越界优先，且不进入物理解析。
            return .failure(.outOfBounds)
        }
        switch physicalTarget {
        case .targetAbsent:
            // C-5：不存在与既有 exists == false 同态。
            return .failure(.missing)
        case .targetUnresolvable:
            // C-5：无法证明在内即拒。
            return .failure(.outOfBounds)
        case .resolved(let physicalPath):
            // C-2/C-5：根没有物理形态时边界无从判定，fail-closed。
            guard let root = physicalWorkspaceRoot else {
                return .failure(.outOfBounds)
            }
            // C-3/C-4：分量级包含判定，恰等于根算在内。
            return isPhysicalPath(physicalPath, inside: root) ? .allowed : .failure(.outOfBounds)
        }
    }

    /// 合同 C-3 的分量级包含判定。纯字符串比较，不访问文件系统。
    static func isPhysicalPath(_ candidate: String, inside root: String) -> Bool {
        // C-3 绝对性守卫（fail-closed）：入参约定为绝对路径，candidate 或 root
        // 任一缺少前导 "/" 即不满足约定，无法证明在内，直接判不在内（false）。
        // 否则 split 会抹掉「相对路径无前导斜杠」的信息，让 "a/b/c" 被
        // 误判为在 "/a/b" 之内。
        guard candidate.hasPrefix("/"), root.hasPrefix("/") else {
            return false
        }
        let rootComponents = pathComponents(root)
        let candidateComponents = pathComponents(candidate)
        if rootComponents.isEmpty {
            // 根为 "/"（分量集为空）时任何绝对路径都在其内。
            return true
        }
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        let paired = zip(rootComponents, candidateComponents)
        for (rootComponent, candidateComponent) in paired where rootComponent != candidateComponent {
            return false
        }
        return true
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - 统一投影入口
//
// 单次把一条记录投影为「摘要 + 分页窗口 + Diff 引用 + 打开目标」的
// 组合结果，供未来接线线一次性消费；各子结果独立携带错误态。

struct AgentOutputCardProjectionRequest: Sendable, Equatable {
    var record: AgentOutputRecord
    var pageCursor: AgentOutputPageCursor?
    var diffLedger: [String: AgentOutputDiffReference]
    var workspaceRoot: URL
    var requestedOpenMode: AgentOutputOpenMode?
}

struct AgentOutputCardProjectionResult: Sendable, Equatable {
    var summary: AgentOutputCardSummary
    var pagination: AgentOutputPaginationOutcome?
    var diff: AgentOutputDiffResolution
    var openTarget: AgentOutputOpenResolution?
}

enum AgentOutputCardProjection {
    static func project(
        _ request: AgentOutputCardProjectionRequest,
        fileExists: (URL) -> Bool
    ) -> AgentOutputCardProjectionResult {
        let pagination: AgentOutputPaginationOutcome?
        if let cursor = request.pageCursor {
            pagination = AgentOutputPaginator.paginate(
                cursor: cursor,
                bodyLineCount: request.record.bodyLineCount
            )
        } else {
            pagination = nil
        }

        let openTarget: AgentOutputOpenResolution?
        if let mode = request.requestedOpenMode {
            openTarget = AgentOutputOpenTargetResolver.resolve(
                rawPath: request.record.relativeFilePath,
                mode: mode,
                workspaceRoot: request.workspaceRoot,
                exists: fileExists
            )
        } else {
            openTarget = nil
        }

        return AgentOutputCardProjectionResult(
            summary: AgentOutputCardSummarizer.summarize(request.record),
            pagination: pagination,
            diff: AgentOutputDiffResolver.resolve(
                diffID: request.record.diffID,
                in: request.diffLedger
            ),
            openTarget: openTarget
        )
    }
}
