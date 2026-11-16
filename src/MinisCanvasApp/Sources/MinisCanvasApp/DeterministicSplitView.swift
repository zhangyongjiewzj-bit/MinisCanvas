import SwiftUI

enum AdaptiveDividerNativeContract {
    static let handleWidth: Double = 5
    static let typographyPointSizes: [Double] = [12, 13, 16, 20]
}

struct DeterministicSplitGeometry: Equatable, Sendable {
    static func effectiveSidebarWidth(
        containerWidth: Double,
        requestedSidebarWidth: Double,
        mainMinimumWidth: Double
    ) -> Double {
        min(
            max(requestedSidebarWidth, 0),
            max(0, containerWidth - max(mainMinimumWidth, 0))
        )
    }
}

/// 确定性双栏布局（替代 SwiftUI HSplitView，2026-08-06）。
///
/// 背景：HSplitView 是 NSSplitView 的 SwiftUI 桥接，在窗口大幅 resize（全屏切换/折叠恢复）时
/// autolayout 约束更新进入死循环/抛异常（_crashOnException + _updateConstraintsForSubtreeIfNeeded
/// 递归，14:18/14:40/14:48 三次 .ips + 统一日志 300-iteration 实证；minWidth 0→1、动画移除均
/// 只缓解未根治——约束循环根因是 NSSplitView 的 autolayout 桥接本身）。
///
/// 本组件：GeometryReader 取容器宽度 → 侧栏实际宽度 = min(目标宽, 容器宽 - 主区最小宽) →
/// HStack 显式 frame 定位。数学上保证主区恒 ≥ mainMinWidth；纯 SwiftUI frame 布局，
/// 无 NSSplitView、无 autolayout、无约束循环/冲突。
/// 折叠 = 宽度 0 且不渲染（无 0 宽 pane）；宽度变化瞬时生效（禁动画，HSplitView 动画中断纪律）。
struct DeterministicSplitView<Sidebar: View, Main: View>: View {
    /// 侧栏目标宽度（折叠传 0）
    var sidebarWidth: Double
    /// 主区最小宽度（与既有主区约束 420 一致）
    var mainMinWidth: Double = 420
    /// true = 侧栏渲染在右侧（右栏上下文面板）
    var trailing: Bool = false
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var main: () -> Main

    var body: some View {
        GeometryReader { geo in
            // 侧栏实际宽度：折叠=0；展开 = min(目标宽, 容器宽 - 主区最小宽) → 主区恒 ≥ mainMinWidth
            let w = DeterministicSplitGeometry.effectiveSidebarWidth(
                containerWidth: geo.size.width,
                requestedSidebarWidth: sidebarWidth,
                mainMinimumWidth: mainMinWidth
            )
            HStack(spacing: 0) {
                if trailing {
                    mainView
                    sideBarView(w)
                } else {
                    sideBarView(w)
                    mainView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var mainView: some View {
        main()
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func sideBarView(_ w: Double) -> some View {
        if w >= 1 {
            sidebar()
                .frame(width: w)
                .frame(maxHeight: .infinity)
                .clipped()
        }
    }
}
