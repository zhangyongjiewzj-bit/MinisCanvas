import Foundation
import Testing
@testable import MinisCanvasApp

// MARK: - P3-ISO-01 measured Chat -> Canvas coupling baseline
//
// 本套件是「可测量」的那一半：它不复述 `RuntimeIsolationProfile` 里那个写死的
// `phase3CanvasChatConsumerCount = 0` 字面量，而是真的扫描 Chat 壳源码。
//
// 基线在 blessed 头
// `e7ab196637d382741e963ff127f253a08a02df40` (tree 91fe839587dbd2d0e2b2a0b1ee6687fec60bfb6b)
// 由 DEV-241 lane 自行复测（口径见下），不是沿用派工单引用的数字：
//
//   跨域直连调用点（Chat 视图体内解引用 CanvasStore 成员）
//     `git grep -o -E "bridge\.canvas\.[a-zA-Z]+" ContentView.swift | wc -l` = 19
//     成员分布: graph 5 / assetItems 4 / assetPanelPresented 3 /
//               contentEditorNodeID 2 / isRunning 1 / statusMessage 1 /
//               showStoryboardWorkbench 1 / toggleAssetPanel 1 / closeContentEditor 1
//   派工单引用的字面串计数 (72/71) 在 blessed 头**不复现**：
//     `git grep -c -iE "canvas"` → BridgeStore 248 / ContentView 86
//     同一口径在 lane 工作树头 e092999d → 71 / 70
//   字面串计数把 App 自身名（MinisCanvas）、@AppStorage 键、注释与类型名都算成
//   耦合，不能当隔离度指标；因此本套件以「直连成员解引用」为验收口径。
//
// 收敛后：上述 19 → 0，全部改走唯一具名边界
// `BridgeStore.canvasBoundary` → `ChatCanvasRuntimeBoundary`。

@Suite("P3-ISO-01 Chat/Canvas direct-coupling boundary is measured, not declared")
struct CanvasChatIsolationBoundaryTests {

    // MARK: 扫描器

    /// DEV-271（P3-ISO-01 RED 根因修复）：定位器错误必须可诊断——报出参与解析的
    /// 绝对路径。任何解析失败都抛错，绝不静默返回空文本；空文本会让
    /// “零直连解引用”变成假绿，违反“可测量而非声明”的套件契约。
    private enum BoundaryLocatorError: Error, CustomStringConvertible {
        case rootNotFound(fromFile: String, probedCandidateRoot: String, rootMarkerSubpath: String)
        case requiredFileMissing(resolvedPath: String)

        var description: String {
            switch self {
            case let .rootNotFound(fromFile, probedCandidateRoot, marker):
                return "P3-ISO-01 定位器失败：从 \(fromFile) 逐级向上直到 \(probedCandidateRoot)"
                    + " 仍未找到包含 \(marker) 的仓库根"
            case let .requiredFileMissing(resolvedPath):
                return "P3-ISO-01 定位器失败：被测源文件不存在：\(resolvedPath)"
            }
        }
    }

    /// `#filePath` 是编译期绝对路径。仓库根 = 从测试文件目录逐级向上，第一个包含
    /// `src/MinisCanvasApp/Sources/MinisCanvasApp` 的祖先目录；该判据与本套件要读的
    /// 相对路径同源，因此解析结果必然能定位到被测源文件。
    /// 旧实现写死 6 连 `deletingLastPathComponent()`，多删了一层：
    /// `<root>/src/MinisCanvasApp/Tests/MinisCanvasAppTests/<file>.swift` 回到根只需 5 次，
    /// 第 6 次落到仓库根的上一级（R27 实测 `/Users/<user>/.codex/worktrees`），
    /// 导致 6 例全部 NSCocoaErrorDomain Code=260（见 DEV-271 raw.log 路径算术证明）。
    private func repositoryRoot() throws -> URL {
        let rootMarkerSubpath = "src/MinisCanvasApp/Sources/MinisCanvasApp"
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            var isDir: ObjCBool = false
            let marker = candidate.appendingPathComponent(rootMarkerSubpath)
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw BoundaryLocatorError.rootNotFound(
                    fromFile: #filePath,
                    probedCandidateRoot: candidate.path,
                    rootMarkerSubpath: rootMarkerSubpath
                )
            }
            candidate = parent
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue == false else {
            throw BoundaryLocatorError.requiredFileMissing(resolvedPath: url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static let contentViewPath =
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
    private static let bridgeStorePath =
        "src/MinisCanvasApp/Sources/MinisCanvasApp/BridgeStore.swift"

    /// blessed 头实测基线，PKG 首执行时核对。
    static let baselineDirectDereferenceCount = 19

    // MARK: 验收 1：跨域直连调用点相对基线确实下降，且降到 0

    @Test("Chat shell dereferences zero CanvasStore members directly")
    func chatShellHasNoDirectCanvasMemberDereference() throws {
        let content = try source(Self.contentViewPath)
        let direct = matches(#"bridge\.canvas\.[a-zA-Z]+"#, in: content)

        #expect(
            direct.isEmpty,
            "P3-ISO-01 回归：Chat 壳体内出现 \(direct.count) 处对 CanvasStore 成员的直连解引用（基线 \(Self.baselineDirectDereferenceCount)，目标 0）。请改走 bridge.canvasBoundary。发现项：\(direct)"
        )
    }

    @Test("Coupling count strictly decreases from the measured baseline")
    func couplingCountDecreasedFromBaseline() throws {
        let content = try source(Self.contentViewPath)
        let direct = matches(#"bridge\.canvas\.[a-zA-Z]+"#, in: content)
        let routed = matches(
            #"bridge\.canvasBoundary(?:IfAvailable\?)?\.[a-zA-Z]+"#,
            in: content
        )

        #expect(
            direct.count < Self.baselineDirectDereferenceCount,
            "直连计数未下降：当前 \(direct.count)，基线 \(Self.baselineDirectDereferenceCount)"
        )
        // Phase 3 absence-aware UI reads use the optional projection;
        // Phase 4 may still use the original boundary. Both are the same
        // BridgeStore-owned seam, and neither may revive direct Canvas reads.
        #expect(
            routed.count > 0 && routed.count <= Self.baselineDirectDereferenceCount,
            "边界未真正成为唯一读取面：routed=\(routed.count)"
        )
    }

    // MARK: 验收 2：边界之外的直连为 0 —— 整只 store 的 handoff 必须逐条枚举

    /// 唯一允许的残留：把整只 CanvasStore 交给 **Canvas 自有视图** 的对象 handoff。
    /// 它们不再是成员解引用，但仍是对象持有，需跨文件改 init 签名才能清零
    /// （见派工单写集），故在本 lane 如实记为 serial 残留而不是静默放行。
    @Test("Residual whole-store handoffs are exactly the enumerated serial set")
    func residualHandoffsAreEnumerated() throws {
        let content = try source(Self.contentViewPath)
        let handoffLines = wholeStoreHandoffLines(in: content)

        let expectedForms = [
            "store: bridge.canvas",        // NodeContentEditorView / AssetPanelView sheets
            "? bridge.canvas : nil",       // contextPanel -> ContextPanelView(canvas:)
            "{ bridge.canvas }",           // MultiCanvasTabBar.store（Canvas 自有 chrome）
        ]
        for site in handoffLines {
            let body = site.split(separator: ":", maxSplits: 1).dropFirst()
                .joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            #expect(
                expectedForms.contains { body.contains($0) },
                "边界外新增加整只 store 的直连 handoff：\(site)"
            )
        }
        // 基线实测 4 处（2 个 sheet + 共享面板 + tab bar 内部），不得增加。
        #expect(
            handoffLines.count <= 4,
            "整只 store handoff 数量由基线 4 增至 \(handoffLines.count)：\(handoffLines)"
        )
    }

    private func wholeStoreHandoffLines(in content: String) -> [String] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var handoffLines: [String] = []
        for (index, line) in lines.enumerated() {
            // 排除边界用法与既有 mutation coordinator
            let stripped = line
                .replacingOccurrences(of: "bridge.canvasIfAvailable", with: "")
                .replacingOccurrences(of: "bridge.canvasBoundary", with: "")
                .replacingOccurrences(of: "bridge.canvasMutationCoordinator", with: "")
            if !matches(#"\bbridge\.canvas\b"#, in: stripped).isEmpty {
                handoffLines.append("line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        return handoffLines
    }

    @Test("Whole-store scanner requires the exact canvas property token")
    func handoffScannerUsesExactCanvasPropertyToken() throws {
        // The actual failing producer is an enum guard, not a CanvasStore.
        let content = try source(Self.contentViewPath)
        for featureLane in content.split(separator: "\n")
            where featureLane.contains("bridge.canvasFeatureLane") {
            #expect(wholeStoreHandoffLines(in: String(featureLane)).isEmpty)
        }
        for unrelated in ["bridge.canvasFeatureLane", "bridge.canvasBoundaryIfAvailable?.graph",
            "bridge.canvasMutationCoordinator", "bridge.canvasIfAvailable", "bridge.canvas2",
            "bridge.canvas_state", "otherbridge.canvas"] {
            #expect(wholeStoreHandoffLines(in: unrelated).isEmpty,
                "A differently named property/owner must not count as the whole CanvasStore")
        }
        let actualHandoffs = """
        NodeContentEditorView(store: bridge.canvas)
        AssetPanelView(store: bridge.canvas)
        canvasAvailable ? bridge.canvas : nil
        Lazy { bridge.canvas }
        """
        #expect(wholeStoreHandoffLines(in: actualHandoffs).count == 4,
            "All three original handoff forms must remain counted, including both sheets")
        // An unenumerated use must still be surfaced for the original residual
        // assertion to reject; this cannot become an allow-list-only scanner.
        #expect(wholeStoreHandoffLines(in: "consume(bridge.canvas)").count == 1)
        #expect(wholeStoreHandoffLines(in: "bridge.canvas.graph").count == 1)
    }

    // MARK: 验收 3：边界是唯一具名 seam，且不夺走既有权威

    @Test("The boundary is a single named seam owned by BridgeStore")
    func boundaryIsSingleNamedSeam() throws {
        let bridge = try source(Self.bridgeStorePath)

        #expect(bridge.contains("struct ChatCanvasRuntimeBoundary"))
        #expect(bridge.contains("var canvasBoundary: ChatCanvasRuntimeBoundary"))
        // 边界自身只允许出现一次定义，防止长出第二套机制。
        #expect(
            matches(#"struct ChatCanvasRuntimeBoundary\b"#, in: bridge).count == 1,
            "ChatCanvasRuntimeBoundary 出现多份定义"
        )
    }

    @Test("Existing isolation authorities keep their roles")
    func existingAuthoritiesUnchanged() throws {
        let bridge = try source(Self.bridgeStorePath)

        // Phase 4 keeps the explicit Canvas API; Phase 3 has an absent
        // projection instead of eagerly allocating a CanvasStore.
        #expect(
            bridge.contains("var canvasIfAvailable: CanvasStore?")
                && bridge.contains("var canvas: CanvasStore"),
            "BridgeStore 必须同时保留 Phase 4 Canvas 入口与 Phase 3 可缺席投影"
        )
        // mutation 仍只有 dispatchCanvasMutation 一个入口；本 lane 未新增变更面。
        #expect(
            bridge.contains("func dispatchCanvasMutation("),
            "Canvas 变更唯一入口丢失"
        )
        #expect(
            matches(#"func executeCanvasMutation\("#, in: bridge).count == 1,
            "Canvas 变更执行入口数量发生变化"
        )
    }

    @Test("The boundary fronts only reads and Canvas-local UI commands")
    func boundaryExposesNoGraphMutation() throws {
        let bridge = try source(Self.bridgeStorePath)
        // 只扫描边界定义体：从 struct 声明起，到 BridgeStore 顶层声明之前为止。
        guard let start = bridge.range(of: "struct ChatCanvasRuntimeBoundary") else {
            Issue.record("未找到 ChatCanvasRuntimeBoundary 定义")
            return
        }
        let afterStruct = String(bridge[start.lowerBound...])
        let upper = afterStruct.range(
            of: "\n@MainActor\n@Observable\nfinal class BridgeStore"
        )
        let body = String(afterStruct[..<(upper?.lowerBound ?? afterStruct.endIndex)])

        // 语义纪律：边界不得成为绕过审批的写图通道。
        for forbidden in ["nodes.append", "graph.nodes =", "graph.edges =", "removeNode", "setContent"] {
            #expect(
                !body.contains(forbidden),
                "边界出现了图数据写路径「\(forbidden)」——会绕过 ChatCanvasBoundaryContract 审批语义"
            )
        }
        // 三态语义不在本 lane 重定义，仍由 RuntimeIsolationProfile 独占。
        #expect(
            !body.contains("canvas-disabled") && !body.contains("canvas-absent") && !body.contains("canvas-corrupt"),
            "边界内私自复制了 disabled/absent/corrupt 三态语义"
        )
    }
}
