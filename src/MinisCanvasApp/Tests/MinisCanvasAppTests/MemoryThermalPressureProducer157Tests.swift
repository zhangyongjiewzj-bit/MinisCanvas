import Foundation
import AppKit
import Dispatch
import Testing
@testable import MinisCanvasApp

// MARK: - Lane 157：attributed 文本缓存的资源压力「生产者」合同
//
// 被钉住的是生产者侧（降级与恢复同等重要），不是重新定义压力语义：
//  1. OS 档位 → 既有 `PressureLevel` 的一一映射（内存压力 warning/critical/normal、
//     热压力 nominal/fair/serious/critical），以及两路信号按既有枚举次序取更严重的一档。
//  2. 幂等启动：生产入口 `AttributedCache.build`（生产调用点 ChatSidebarView.swift:1495）
//     第一次真实使用就挂上 OS 信号源，重复启动不长出第二组源、不重复注册观察者。
//  3. 生产者只调用既有 `setPressureLevel`：critical 仍清空缓存、恢复必须两路都回到
//     OS 的 normal / .nominal（一路回到 normal 而另一路仍降级时不得提前恢复）。
//
// 边界（如实记录）：本套件不模拟、也不等待真实 OS 压力/热压力事件 —— OS 真事件驱动的
// 端到端触发在本 lane 是 NOT_RUN（不跑绝不是 PASS）。这里只钉映射函数与幂等激活守卫，
// 事件入口用直接注入映射结果的方式驱动（`applyObserved…` 与 handler 走的是同一条落点）。

@MainActor
@Suite(.serialized)
struct MemoryThermalPressureProducer157Tests {

    /// 每个用例结束后把两路信号放回 normal，避免把降级状态泄漏给同模块其它套件。
    private func restoring(_ body: () throws -> Void) rethrows {
        defer {
            AttributedCache.applyObservedMemoryPressureLevel(.normal)
            AttributedCache.applyObservedThermalPressureLevel(.normal)
        }
        try body()
    }

    // MARK: - 1) OS → PressureLevel 一一映射

    @Test func memoryPressureEventsMapOntoExistingLevels() {
        // 内存压力：只有 OS 的三档，一一对应既有枚举三档。
        // （OS 两个信号域都有 `.critical`，故左侧档位一律写全类型名，不靠推断消歧。）
        let memoryNormal = DispatchSource.MemoryPressureEvent.normal
        let memoryWarning = DispatchSource.MemoryPressureEvent.warning
        let memoryCritical = DispatchSource.MemoryPressureEvent.critical
        #expect(AttributedCache.pressureLevel(for: memoryNormal) == .normal)
        #expect(AttributedCache.pressureLevel(for: memoryWarning) == .elevated)
        #expect(AttributedCache.pressureLevel(for: memoryCritical) == .critical)
        // OS 允许同一事件同时带上多档：取其中更严重的一档，不引入自造阈值。
        #expect(AttributedCache.pressureLevel(for: [.warning, .critical]) == .critical)
        #expect(AttributedCache.pressureLevel(for: [.normal, .warning]) == .elevated)
        #expect(AttributedCache.pressureLevel(for: [.normal, .warning, .critical]) == .critical)
    }

    @Test func thermalStatesMapOntoExistingLevelsMonotonically() {
        // OS 四档 → 既有三档：只折叠不复用（nominal 才是恢复，fair/serious 都是降级，critical 最重）。
        #expect(AttributedCache.pressureLevel(for: ProcessInfo.ThermalState.nominal) == .normal)
        #expect(AttributedCache.pressureLevel(for: ProcessInfo.ThermalState.fair) == .elevated)
        #expect(AttributedCache.pressureLevel(for: ProcessInfo.ThermalState.serious) == .elevated)
        #expect(AttributedCache.pressureLevel(for: ProcessInfo.ThermalState.critical) == .critical)
    }

    @Test func combinationTakesTheMoreSevereOsSignal() {
        #expect(AttributedCache.moreSeverePressureLevel(.normal, .normal) == .normal)
        #expect(AttributedCache.moreSeverePressureLevel(.normal, .elevated) == .elevated)
        #expect(AttributedCache.moreSeverePressureLevel(.elevated, .normal) == .elevated)
        #expect(AttributedCache.moreSeverePressureLevel(.elevated, .critical) == .critical)
        #expect(AttributedCache.moreSeverePressureLevel(.critical, .elevated) == .critical)
        #expect(AttributedCache.moreSeverePressureLevel(.critical, .normal) == .critical)
    }

    // MARK: - 2) 幂等激活守卫（生产者可达性）

    @Test func productionBuildEntryActivatesTheOsProducer() {
        restoring {
            // 走真实生产入口：不是测试自己调 API，而是产品入口把生产者挂上。
            _ = AttributedCache.build(
                content: "pressure157-activation-\(UUID().uuidString)",
                isMarkdown: false,
                baseSize: 13,
                baseColor: .labelColor
            )
            #expect(AttributedCache.isPressureMonitoringActive)
            #expect(AttributedCache.pressureSourceCount == 2,
                    "降级（.warning/.critical）与恢复（.normal）两路 OS 信号源都必须在场")
            #expect(AttributedCache.isThermalMonitoringActive)
        }
    }

    @Test func repeatedActivationIsIdempotentAndKeepsExactlyTwoSignalSources() {
        restoring {
            AttributedCache.startPressureMonitoringIfNeeded()
            let sourcesAfterFirst = AttributedCache.pressureSourceCount
            let activeFlag = AttributedCache.isPressureMonitoringActive
            let thermalObserver = AttributedCache.isThermalMonitoringActive
            // 再启动两次：守卫必须让状态一位不动（没有第二组 DispatchSource、没有第二个观察者）。
            AttributedCache.startPressureMonitoringIfNeeded()
            AttributedCache.startPressureMonitoringIfNeeded()
            #expect(activeFlag)
            #expect(thermalObserver)
            #expect(sourcesAfterFirst == 2)
            #expect(AttributedCache.pressureSourceCount == sourcesAfterFirst)
            #expect(AttributedCache.isThermalMonitoringActive)
        }
    }

    // MARK: - 3) 降级 / 恢复双向 + 既有语义不变

    @Test func degradeAndRestoreFollowBothSignalPathsAndKeepCriticalSemantics() {
        restoring {
            // 未降级时先放一条缓存，用来钉住「critical 仍清空」这条既有语义。
            AttributedCache.clear()
            let content = "pressure157-semantics-\(UUID().uuidString)"
            _ = AttributedCache.build(content: content, isMarkdown: false, baseSize: 13, baseColor: .labelColor)
            #expect(AttributedCache.currentPressureLevel == .normal)
            AttributedCache.clear()
            _ = AttributedCache.build(content: content, isMarkdown: false, baseSize: 13, baseColor: .labelColor)
            #expect(AttributedCache.count == 1)

            // 降级方向：内存压力 warning → elevated。
            AttributedCache.applyObservedMemoryPressureLevel(.elevated)
            #expect(AttributedCache.currentPressureLevel == .elevated)
            // 热压力 critical 更严重 → critical，且既有 setPressureLevel 语义仍清空缓存。
            AttributedCache.applyObservedThermalPressureLevel(.critical)
            #expect(AttributedCache.currentPressureLevel == .critical)
            #expect(AttributedCache.count == 0, "critical 仍必须清空缓存（生产者不得改写降级语义）")

            // 恢复方向：一路回到 normal、另一路仍 critical → 不得提前恢复。
            AttributedCache.applyObservedMemoryPressureLevel(.normal)
            #expect(AttributedCache.currentPressureLevel == .critical)
            AttributedCache.applyObservedThermalPressureLevel(.normal)
            #expect(AttributedCache.currentPressureLevel == .normal)

            // 恢复后条目重新可缓存（同一入口、同一参数）。
            _ = AttributedCache.build(content: content, isMarkdown: false, baseSize: 13, baseColor: .labelColor)
            #expect(AttributedCache.count == 1)
        }
    }

    @Test func thermalAloneDegradesAndMemoryNormalAloneCannotRestoreIt() {
        restoring {
            AttributedCache.applyObservedThermalPressureLevel(.elevated)
            AttributedCache.applyObservedMemoryPressureLevel(.normal)
            #expect(AttributedCache.currentPressureLevel == .elevated)
            AttributedCache.applyObservedThermalPressureLevel(.normal)
            #expect(AttributedCache.currentPressureLevel == .normal)
        }
    }

    @Test func missingSignalSourceLeavesLevelUntouched() {
        restoring {
            AttributedCache.applyObservedMemoryPressureLevel(.elevated)
            let before = AttributedCache.currentPressureLevel
            // handler 只在来源存在时才有档位可读；nil 必须原样返回，不得凭空造档位。
            AttributedCache.recordMemoryPressureEvent(from: nil)
            #expect(AttributedCache.currentPressureLevel == before)
            #expect(before == .elevated)
        }
    }
}
