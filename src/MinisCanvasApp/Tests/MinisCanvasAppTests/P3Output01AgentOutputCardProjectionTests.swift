import Foundation
import Testing
@testable import MinisCanvasApp

/// P3-OUTPUT-01（明细 :301）：普通 Agent 输出统一卡片与跳转的投影测试。
/// 纯投影层验证——摘要、分页游标、Diff 引用、Finder/编辑器打开目标、
/// 缺失与越界错误态。不依赖 SwiftUI / ChatStore / ContentView。
///
/// DEV-244B（本线续修，取代未合入的 244 内容）另加两组：
/// 1. 分页器在 `Int.max` 量级入参上的溢出边界反例（244 的
///    `(n + d - 1) / d` 写法会 runtime trap，现改为商余形式）；
/// 2. 物理（symlink）路径边界合同的负例——合同本身按派工单§A 只成文、
///    不接入生产入口，故另有 `productionEntryRemainsLexicalOnly` 记录现状。
///
/// 注：`workspaceRoot` 是纯字符串夹具（存在性由注入闭包给出），本文件不
/// 读写任何真实文件系统，也不依赖 `/tmp` 目录真实存在。
@Suite("P3-OUTPUT-01 agent output card projection")
struct P3Output01AgentOutputCardProjectionTests {

    private static let workspaceRoot = URL(fileURLWithPath: "/tmp/minis-p3-output-01/workspace")
        .standardizedFileURL

    private static let diffLedger: [String: AgentOutputDiffReference] = [
        "diff-42": AgentOutputDiffReference(
            diffID: "diff-42",
            changedFileCount: 3,
            insertions: 120,
            deletions: 18
        ),
    ]

    /// 固定虚拟文件系统：只有 expectedRelativePath 存在。
    private static func makeExists(table: Set<String>) -> (URL) -> Bool {
        let root = workspaceRoot
        return { url in
            let rootPath = root.path + "/"
            guard url.path.hasPrefix(rootPath) else { return false }
            return table.contains(String(url.path.dropFirst(rootPath.count)))
        }
    }

    @Test("projection covers diff, pagination and open target")
    func agentOutputCardProjectionCoversDiffPaginationAndOpenTarget() {
        let record = AgentOutputRecord(
            outputID: "out-1",
            kind: .toolResult,
            title: "构建日志",
            bodyLineCount: 95,
            relativeFilePath: "logs/build.log",
            diffID: "diff-42"
        )
        let request = AgentOutputCardProjectionRequest(
            record: record,
            pageCursor: AgentOutputPageCursor(pageIndex: 3, pageSize: 30),
            diffLedger: Self.diffLedger,
            workspaceRoot: Self.workspaceRoot,
            requestedOpenMode: .finderReveal
        )
        let result = AgentOutputCardProjection.project(
            request,
            fileExists: Self.makeExists(table: ["logs/build.log"])
        )

        // 摘要：统一卡片携带跳转能力位。
        #expect(result.summary.offersFileJump)
        #expect(result.summary.offersDiffJump)
        #expect(result.summary.offersPagination)

        // 分页：95 行、页大小 30 → 共 4 页；第 3 页覆盖第 90..94 行。
        if case .window(let pageIndex, let firstLine, let lineCount, let totalPages) = result.pagination {
            #expect(pageIndex == 3)
            #expect(firstLine == 90)
            #expect(lineCount == 5)
            #expect(totalPages == 4)
        } else {
            Issue.record("expected pagination window, got \(String(describing: result.pagination))")
        }

        // Diff：只解析引用，不携带载荷。
        if case .resolved(let reference) = result.diff {
            #expect(reference.diffID == "diff-42")
            #expect(reference.changedFileCount == 3)
            #expect(reference.insertions == 120)
            #expect(reference.deletions == 18)
        } else {
            Issue.record("expected resolved diff reference")
        }

        // 打开目标：Finder 定位解析到工作区内的规范 URL。
        if case .target(let url, let mode) = result.openTarget {
            #expect(mode == .finderReveal)
            #expect(url == Self.workspaceRoot.appendingPathComponent("logs/build.log"))
        } else {
            Issue.record("expected open target, got \(String(describing: result.openTarget))")
        }
    }

    @Test("missing and out-of-bounds states are explicit and fail-closed")
    func failureStatesAreExplicit() {
        let exists = Self.makeExists(table: ["logs/build.log"])

        // 游标越界 → outOfBounds（不环绕、不钳制）。
        let beyond = AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 4, pageSize: 30),
            bodyLineCount: 95
        )
        #expect(beyond == .failure(.outOfBounds))

        // 非法请求（负页大小）→ outOfBounds。
        let invalid = AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: 0),
            bodyLineCount: 95
        )
        #expect(invalid == .failure(.outOfBounds))

        // 空正文仍有唯一第 0 页。
        let empty = AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: 30),
            bodyLineCount: 0
        )
        #expect(empty == .window(pageIndex: 0, firstLine: 0, lineCount: 0, totalPages: 1))

        // Diff 台账无记录 → missing。
        #expect(
            AgentOutputDiffResolver.resolve(diffID: "diff-absent", in: Self.diffLedger)
                == .failure(.missing)
        )

        // 路径逃逸工作区 → outOfBounds。
        #expect(
            AgentOutputOpenTargetResolver.resolve(
                rawPath: "../outside.txt",
                mode: .editor,
                workspaceRoot: Self.workspaceRoot,
                exists: exists
            ) == .failure(.outOfBounds)
        )

        // 绝对路径 → outOfBounds。
        #expect(
            AgentOutputOpenTargetResolver.resolve(
                rawPath: "/etc/passwd",
                mode: .editor,
                workspaceRoot: Self.workspaceRoot,
                exists: exists
            ) == .failure(.outOfBounds)
        )

        // 已知目录内但不存在的文件 → missing。
        #expect(
            AgentOutputOpenTargetResolver.resolve(
                rawPath: "logs/gone.log",
                mode: .finderReveal,
                workspaceRoot: Self.workspaceRoot,
                exists: exists
            ) == .failure(.missing)
        )

        // 无路径 → missing；编辑器模式对存在文件可解析。
        #expect(
            AgentOutputOpenTargetResolver.resolve(
                rawPath: nil,
                mode: .editor,
                workspaceRoot: Self.workspaceRoot,
                exists: exists
            ) == .failure(.missing)
        )
        if case .target(let url, let mode) = AgentOutputOpenTargetResolver.resolve(
            rawPath: "logs/build.log",
            mode: .editor,
            workspaceRoot: Self.workspaceRoot,
            exists: exists
        ) {
            #expect(mode == .editor)
            #expect(url.lastPathComponent == "build.log")
        } else {
            Issue.record("expected editor open target")
        }
    }

    @Test("summaries are kind-specific and never carry paths")
    func summariesArePathFree() {
        let fileCard = AgentOutputCardSummarizer.summarize(AgentOutputRecord(
            outputID: "out-file",
            kind: .file,
            title: "生成的图",
            relativeFilePath: "assets/secret-relative/render.png"
        ))
        #expect(fileCard.offersFileJump)
        #expect(!fileCard.offersDiffJump)
        #expect(!fileCard.detail.contains("secret-relative"))
        #expect(!fileCard.detail.contains("/"))

        let diffCard = AgentOutputCardSummarizer.summarize(AgentOutputRecord(
            outputID: "out-diff",
            kind: .diff,
            title: "代码修改",
            diffID: "diff-42"
        ))
        #expect(diffCard.offersDiffJump)
        #expect(!diffCard.offersFileJump)

        let toolCard = AgentOutputCardSummarizer.summarize(AgentOutputRecord(
            outputID: "out-tool",
            kind: .toolResult,
            title: "命令输出",
            bodyLineCount: 12
        ))
        #expect(toolCard.offersPagination)
        #expect(toolCard.detail.contains("12"))
    }

    // MARK: - DEV-244B 追加 1：分页商余形式的溢出边界反例
    //
    // 独审在 244 补丁 `AgentOutputCardModel.swift:124` 静态确证的缺陷：
    // 页数为 `(bodyLineCount + pageSize - 1) / pageSize` 的向上取整写法。
    // `+`/`-` 左结合 ⇒ 先算 `bodyLineCount + pageSize`，而 `Int` 加法溢出即
    // runtime trap，故入参域（任意非负 `Int`）内下面两组输入会直接崩溃：
    //   A. bodyLineCount = Int.max, pageSize = 2（Int.max + 2 溢出）
    //   B. bodyLineCount = 1, pageSize = Int.max（1 + Int.max 溢出）
    // 下面两个 @Test 原样把这两组输入喂进分页器：修前 trap，修后必须给出
    // 可判定的窗口。同时把 pageSize == 0 / bodyLineCount == 0 的既有合同钉住。

    @Test("overflow counterexample A: Int.max lines with page size 2 stays in bounds")
    func maxLineCountWithSmallPageSizeDoesNotOverflow() {
        // ceil(Int.max / 2) = 4_611_686_018_427_387_904（= Int.max/2 再加 1）。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: 2),
            bodyLineCount: Int.max
        ) == .window(
            pageIndex: 0,
            firstLine: 0,
            lineCount: 2,
            totalPages: 4_611_686_018_427_387_904
        ))

        // 末页同样不溢出：firstLine = (pages-1)*2 = Int.max - 1，该页只剩 1 行。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 4_611_686_018_427_387_903, pageSize: 2),
            bodyLineCount: Int.max
        ) == .window(
            pageIndex: 4_611_686_018_427_387_903,
            firstLine: 9_223_372_036_854_775_806,
            lineCount: 1,
            totalPages: 4_611_686_018_427_387_904
        ))

        // 越界索引仍 fail-closed（旧写法在返回这里之前就已崩在加法上）。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 4_611_686_018_427_387_904, pageSize: 2),
            bodyLineCount: Int.max
        ) == .failure(.outOfBounds))
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: Int.max, pageSize: 2),
            bodyLineCount: Int.max
        ) == .failure(.outOfBounds))
    }

    @Test("overflow counterexample B: one line with Int.max page size stays in bounds")
    func singleLineWithMaxPageSizeDoesNotOverflow() {
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: Int.max),
            bodyLineCount: 1
        ) == .window(pageIndex: 0, firstLine: 0, lineCount: 1, totalPages: 1))

        // 同量级另一侧：行数与页大小同为 Int.max ⇒ 余数为 0，恰一页，不做 +1。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: Int.max),
            bodyLineCount: Int.max
        ) == .window(pageIndex: 0, firstLine: 0, lineCount: Int.max, totalPages: 1))

        // pageSize == 1 时余数恒 0：页数即行数，末页 firstLine 落在 Int.max - 1。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: Int.max - 1, pageSize: 1),
            bodyLineCount: Int.max
        ) == .window(
            pageIndex: Int.max - 1,
            firstLine: 9_223_372_036_854_775_806,
            lineCount: 1,
            totalPages: Int.max
        ))
    }

    @Test("overflow-free ceil-div is exact across the whole non-negative domain")
    func ceilDivIsExactOnDomainEdges() {
        #expect(AgentOutputPageMath.ceilDiv(0, 1) == 0)
        #expect(AgentOutputPageMath.ceilDiv(1, 2) == 1)
        #expect(AgentOutputPageMath.ceilDiv(2, 2) == 1)
        #expect(AgentOutputPageMath.ceilDiv(3, 2) == 2)
        #expect(AgentOutputPageMath.ceilDiv(95, 30) == 4)
        #expect(AgentOutputPageMath.ceilDiv(Int.max, 2) == 4_611_686_018_427_387_904)
        #expect(AgentOutputPageMath.ceilDiv(1, Int.max) == 1)
        #expect(AgentOutputPageMath.ceilDiv(Int.max, Int.max) == 1)
        #expect(AgentOutputPageMath.ceilDiv(Int.max, 1) == Int.max)
    }

    @Test("existing pageSize == 0 and empty-body contracts survive the rewrite, including at Int.max scale")
    func preservedContractsAtExtremeInputs() {
        // 非法页大小：无论行数多大都判越界，且绝不做除法。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: 0),
            bodyLineCount: Int.max
        ) == .failure(.outOfBounds))
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: -1),
            bodyLineCount: Int.max
        ) == .failure(.outOfBounds))
        // 负行数 / 负索引同样判越界。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: Int.max),
            bodyLineCount: -1
        ) == .failure(.outOfBounds))
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: -1, pageSize: Int.max),
            bodyLineCount: Int.max
        ) == .failure(.outOfBounds))
        // 空正文仍保留唯一第 0 页，且在极端页大小下不变。
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: 1),
            bodyLineCount: 0
        ) == .window(pageIndex: 0, firstLine: 0, lineCount: 0, totalPages: 1))
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 0, pageSize: Int.max),
            bodyLineCount: 0
        ) == .window(pageIndex: 0, firstLine: 0, lineCount: 0, totalPages: 1))
        #expect(AgentOutputPaginator.paginate(
            cursor: AgentOutputPageCursor(pageIndex: 1, pageSize: Int.max),
            bodyLineCount: 0
        ) == .failure(.outOfBounds))
    }

    // MARK: - DEV-244B 追加 2：物理路径边界合同（负例；合同未接入生产入口）
    //
    // 派工单§A 要求：先把合同成文并给负例，等 C0 裁决后才决定是否接线到
    // 生产路径。因此下面的用例只直接驱动 `AgentOutputPhysicalPathBoundaryContract`
    // 这个纯判定函数，另有 `productionEntryRemainsLexicalOnly` 明确记录
    // 「生产入口仍是词法判定」这一未接线现状（现状断言，不是对现状的背书）。

    @Test("physical boundary contract rejects symlink escapes and unprovable resolutions")
    func physicalBoundaryContractNegativeCases() {
        let root = "/tmp/minis-p3-output-01/workspace"

        // C-1：词法已越界时直接判越界，物理侧说什么都不放宽。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: false,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: "\(root)/logs/build.log")
        ) == .failure(.outOfBounds))

        // 合同核心负例：词法形在内、symlink 的物理目标在工作区外 → 越界。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: "/etc/passwd")
        ) == .failure(.outOfBounds))

        // 祖先目录被 symlink 换出工作区：物理路径同样落在根外 → 越界。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: "/Users/other/Library/Containers/x/notes.txt")
        ) == .failure(.outOfBounds))

        // C-3 前缀陷阱：同前缀的兄弟目录不得算在内。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: "/tmp/minis-p3-output-01/workspace-evil/x.txt")
        ) == .failure(.outOfBounds))

        // C-5：目标不存在 → missing；解析失败（非 ENOENT）→ outOfBounds。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .targetAbsent
        ) == .failure(.missing))
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .targetUnresolvable
        ) == .failure(.outOfBounds))
        // C-2/C-5：工作区根自身解析不出物理路径 → fail-closed。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: nil,
            physicalTarget: .resolved(physicalPath: "\(root)/logs/build.log")
        ) == .failure(.outOfBounds))

        // 正例（对照组）：物理目标确在根内才允许；C-4 恰等于根也允许。
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: "\(root)/logs/build.log")
        ) == .allowed)
        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: root,
            physicalTarget: .resolved(physicalPath: root)
        ) == .allowed)
    }

    @Test("containment comparison is component-wise, not a raw string prefix")
    func containmentComparisonIsComponentWise() {
        #expect(AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("/a/b/c", inside: "/a/b"))
        #expect(AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("/a/b", inside: "/a/b"))
        #expect(AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("/anything", inside: "/"))
        // 重复斜杠在分量级比较下等价（入参约定已词法标准化，此处为稳健性对照）。
        #expect(AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("//a//b//c", inside: "/a/b"))
        // 兄弟目录同前缀 / 更短路径 / 相对路径都不算在内。
        #expect(!AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("/a/bc", inside: "/a/b"))
        #expect(!AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("/a", inside: "/a/b"))
        #expect(!AgentOutputPhysicalPathBoundaryContract.isPhysicalPath("a/b/c", inside: "/a/b"))
    }

    @Test("contract stays unwired: production open entry is still lexical-only")
    func productionEntryRemainsLexicalOnly() {
        // 裁决点的可执行记录：同一条「词法在内、物理出界」的 symlink 场景，
        // 生产入口给 target、成文合同给 outOfBounds。二者不一致即本线登记
        // 给 C0 的待裁决差额，本线不擅自接入。
        #expect(AgentOutputPhysicalPathBoundaryContract.wiringStatus == "pending_C0_ruling_not_wired")

        let rootPath = Self.workspaceRoot.path + "/"
        let symlinkShapedExists: (URL) -> Bool = { url in
            // 注入的「存在性」模拟：symlink 条目本身存在；词法层区分不出它指向根外。
            url.path.hasPrefix(rootPath)
        }
        if case .target(let url, let mode) = AgentOutputOpenTargetResolver.resolve(
            rawPath: "logs/link-to-outside.log",
            mode: .editor,
            workspaceRoot: Self.workspaceRoot,
            exists: symlinkShapedExists
        ) {
            #expect(mode == .editor)
            #expect(url.path == Self.workspaceRoot.path + "/logs/link-to-outside.log")
        } else {
            Issue.record("lexical-only entry is expected to accept the symlink-shaped path")
        }

        #expect(AgentOutputPhysicalPathBoundaryContract.judge(
            lexicalPathInsideWorkspaceRoot: true,
            physicalWorkspaceRoot: Self.workspaceRoot.path,
            physicalTarget: .resolved(physicalPath: "/etc/passwd")
        ) == .failure(.outOfBounds))
    }
}
