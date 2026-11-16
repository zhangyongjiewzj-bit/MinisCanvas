import AppKit
import CryptoKit
import Dispatch

// MARK: - P3-P1-03 consumer：storage.memoryLimitMB → 进程内解码缓存内存预算

/// 设置中心「记忆体积上限（MB）」（`AppSettings.storage.memoryLimitMB`，声明在 MinisCore
/// `Settings/AppSettings.swift:803`，由 `SettingsCenter.memoryLimitMB` /
/// `SettingsView` 的同一属性写入）的唯一运行时 consumer。
///
/// 该值此前只有 UI 写入与自引用回显，没有任何行为侧 reader（= 影子配置；
/// QA/BUG-REPORT.md `P3-P1-03`，Canonical 总表 `P3-SET-01` 的
/// `effective_source/consumer` 列）。本类型把它接到进程内既有解码缓存的预算上：
///
/// - 规范值只有一份：每次经 `SettingsCenter.active?.memoryLimitMB` 读 App 组合根安装的
///   唯一设置中心。这里不持有该值的副本、不新增 settings_key、不建第二份缓存、
///   不加定时器/观察者，也不改 `AppSettings`/`SettingsCenter`/`SettingsView` 任何一行。
/// - 语义是「上限」：`生效预算 = min(该缓存自身基线, 配置上限)`，**永不上调** ——
///   卡顿/内存专项已验证的更严格基线（attributed 30MB / 资产大图 128MB /
///   视频首帧 64MB / 文件树缩略图 48MB）不会因为用户填个大数字而被放大。
/// - `nil`（默认）/ `0`（UI 允许「0 或留空」，与不限制同义）/ 负数 / 溢出量级 →
///   按未配置处理 → 各缓存保持自身基线，行为与本 consumer 引入前逐位一致。
///   注意 `NSCache.totalCostLimit == 0` 的框架语义是「无上限」：把 0 直接透传会把
///   「压到最小」反向变成「不封顶」，因此非正值必须回落到基线而不是透传。
/// - 实现只写 `NSCache.totalCostLimit`（框架自带的可写实例属性，且仅在算出的预算与当前
///   不同才写）：缓存实例仍是 `static let`（身份不变），没有 static let → var 的转换，
///   也没有新增可变全局状态；调用点全部在 @MainActor 缓存入口，与周围代码同一隔离域。
///
/// 已知副作用（如实记录，不掩盖）：读 `settingsMirror` 支撑的属性会把该 keypath 注册进
/// 正在求值的 SwiftUI body 的观察依赖，因此改任意设置后聊天转录 / 资产面板 / 文件树会多
/// 一次 body 重算（缓存命中，不重新解析，无 jank 回归路径）。要彻底消掉它，需要在组合根
/// `MinisCanvasApp.swift`（非本 lane 写集）把 memoryLimitMB 挂成 change 回调再推送；
/// 见 lane receipt 的 residual 说明。
///
/// 覆盖边界：`CanvasStore.swift`（Canvas 由 AGENTS.md 延期）与 `ChatStore.swift`
/// （已收编 lane 063/070）里的同类 `totalCostLimit` 站点不在本写集内，仍待对应 owner
/// 接入同一个 `applyTotalCostLimit(baseline:to:)` 入口，以免长出第二个配置面。
@MainActor
enum MemoryLimitCachePolicy {
    private static let bytesPerMB = 1024 * 1024

    /// 预算规则（纯函数：不读全局设置，便于逐项钉住）。
    static func effectiveTotalCostBytes(baseline: Int, memoryLimitMB: Int?) -> Int {
        guard baseline > 0, let memoryLimitMB, memoryLimitMB > 0 else { return baseline }
        guard memoryLimitMB <= Int.max / bytesPerMB else { return baseline }
        return min(baseline, memoryLimitMB * bytesPerMB)
    }

    /// 当前规范上限（MB）；唯一来源 = 活动设置中心（nil = 未装配或未配置 = 不限制）。
    /// 读取先例：`ContextPanelView.swift:283`、`BridgeStore.swift:1504`。
    static var configuredMemoryLimitMB: Int? { SettingsCenter.active?.memoryLimitMB }

    /// 把规范上限落到某个缓存实例（只在预算变化时写；`countLimit` 不受影响）。
    static func applyTotalCostLimit<KeyType: AnyObject, ObjectType: AnyObject>(
        baseline: Int,
        to cache: NSCache<KeyType, ObjectType>
    ) {
        let desired = effectiveTotalCostBytes(
            baseline: baseline,
            memoryLimitMB: configuredMemoryLimitMB
        )
        if cache.totalCostLimit != desired {
            cache.totalCostLimit = desired
        }
    }
}

// MARK: - AttributedCache（滚动卡顿修复：attributed 字符串进程级缓存）
//
// 背景：ChatBubble.bubbleAttributedBody / DocumentView 预览 每次 body 重算都
// 全量 markdown 解析（MarkdownAttributedTextBuilder.build）→ 长文本 × 多消息
// 滚动时 CoreText 重排风暴（sample 实证：CPU 97.7% 全在 TBaseFont::GetGlyphs 布局）。
// LazyVStack 回收 row 后 @State 缓存会丢，故用进程级 @MainActor 单例。
// 键 = SHA-256(content + 渲染参数)，避免 hashValue 跨进程不稳定；NSCache 同时按条数和
// 总成本施加上限，压力级别升高时主动跳过大条目，避免长文本缓存挤压 UI 内存。

@MainActor
enum AttributedCache {
    /// 本缓存的基线内存预算（字节）= 接入 memoryLimitMB consumer 前的硬编码上限。
    static let baselineTotalCostBytes = 30 * 1024 * 1024

    private static let store: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 300
        cache.totalCostLimit = baselineTotalCostBytes
        return cache
    }()
    private static var keyIndex: Set<String> = []
    private static var pressureLevel: PressureLevel = .normal

    enum PressureLevel: Sendable, Equatable {
        case normal
        case elevated
        case critical
    }

    private static let maxEntryCost = 512 * 1024
    private static let capacity = 300

    /// 构建（命中缓存直接复用；未命中构建后按压力级别决定是否存入）。
    /// 参数与 MarkdownAttributedTextBuilder.build 对齐（content / isMarkdown / baseSize / baseColor）。
    static func build(content: String,
                      isMarkdown: Bool,
                      baseSize: CGFloat,
                      baseColor: NSColor) -> NSAttributedString {
        // 首次真实生产使用即接上 OS 资源压力生产者（幂等；见下方压力生产者一节）。
        startPressureMonitoringIfNeeded()
        let key = makeKey(content: content, isMarkdown: isMarkdown, baseSize: baseSize, baseColor: baseColor)
        if let hit = store.object(forKey: key as NSString) { return hit }
        let result = MarkdownAttributedTextBuilder.build(
            content: content,
            isMarkdown: isMarkdown,
            baseSize: baseSize,
            baseColor: baseColor
        )
        let cost = max(1, content.utf8.count + (result.length * MemoryLayout<unichar>.size * 4))
        let entryCostLimit: Int
        switch pressureLevel {
        case .normal: entryCostLimit = maxEntryCost
        case .elevated: entryCostLimit = maxEntryCost / 4
        case .critical: entryCostLimit = 0
        }
        guard cost <= entryCostLimit else { return result }
        // P3-P1-03 consumer：入缓存前把规范内存上限（storage.memoryLimitMB）落到本缓存；
        // 未配置时等于基线，故默认路径不写任何新值。
        MemoryLimitCachePolicy.applyTotalCostLimit(baseline: baselineTotalCostBytes, to: store)
        if keyIndex.count >= capacity {
            store.removeAllObjects()
            keyIndex.removeAll(keepingCapacity: true)
        }
        store.setObject(result, forKey: key as NSString, cost: cost)
        keyIndex.insert(key)
        return result
    }

    /// 测试/诊断：当前缓存条目数
    static var count: Int { keyIndex.count }

    /// 测试/诊断：当前生效的内存预算（字节）= min(基线, storage.memoryLimitMB)。
    static var currentTotalCostLimitBytes: Int { store.totalCostLimit }

    static func clear() {
        store.removeAllObjects()
        keyIndex.removeAll(keepingCapacity: true)
    }

    static func setPressureLevel(_ level: PressureLevel) {
        pressureLevel = level
        if level == .critical { clear() }
    }

    static var currentPressureLevel: PressureLevel { pressureLevel }

    private static func makeKey(content: String,
                                isMarkdown: Bool,
                                baseSize: CGFloat,
                                baseColor: NSColor) -> String {
        var canonicalColor: String
        if let rgb = baseColor.usingColorSpace(.deviceRGB) {
            canonicalColor = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                .map { String(Double($0)) }
                .joined(separator: ",")
        } else {
            // Preserve non-RGB colors without falling back to process-seeded hashValue.
            // The color-space name and scalar components form a stable cache scope.
            var components = [CGFloat](repeating: 0, count: baseColor.numberOfComponents)
            baseColor.getComponents(&components)
            canonicalColor = "\(String(describing: baseColor.colorSpace.colorSpaceModel)):\(components.map { String(Double($0)) }.joined(separator: ","))"
        }
        let size = String(Double(baseSize))
        let canonical = "markdown=\(isMarkdown ? 1 : 0);size=\(size);color=\(canonicalColor);content=\(content)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 资源压力生产者（OS 内存压力 / 热压力 → setPressureLevel）
    //
    // 本文件此前只有消费者：`setPressureLevel` 全仓（src）零生产调用点，
    // `DispatchMemoryPressure` / `thermalState` / `ProcessInfo.processInfo.thermal` 也全是 0，
    // 于是降级/恢复路径是「测试绿、生产不可达」这一既有反模式的又一个实例。这里补上唯一
    // 生产者，信号只取自 OS 自身来源，档位一一映射到既有 `PressureLevel`：
    //
    // - 内存压力：`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`
    //   给降级信号，`eventMask: [.normal]` 给 OS 的恢复信号；档位读来源自带的 `data`。
    // - 热压力：`ProcessInfo.processInfo.thermalState` + `ProcessInfo.thermalStateDidChangeNotification`
    //   （OS 明确把它投到全局队列，故观察者用 `queue: .main` 回主 actor）。
    // - 映射一一（无自造阈值/定时器/迟滞）：warning→elevated、critical→critical、
    //   normal→normal；nominal→normal、fair/serious→elevated（OS 四档折叠进既有三档，
    //   只并列不复用：fair 与 serious 都不是 normal，也不是 critical）、critical→critical。
    // - 两路信号各自记账后取「同批 OS 事实里更严重的一档」（次序就是既有枚举
    //   normal < elevated < critical，不是新阈值）；任一路仍非 normal 时不恢复，两路都回到
    //   OS 的 normal / .nominal 才回到非降级档，即恢复方向与降级方向同等重要。
    // - 只调用既有 `setPressureLevel`，不改它定义的降级语义（critical 仍清空缓存）。
    // - 生命周期：首次真实生产使用（`build`；生产调用点 ChatSidebarView.swift:1495）幂等启动，
    //   不需要组合根 `MinisCanvasApp.swift`（非本写集）。状态全是本 @MainActor enum 自身的
    //   静态成员（沿用本文件既有 static let/var 形状）：没有新单例、没有新全局可变状态、
    //   没有锁；handler 用 `queue: .main` 回到主 actor（先例 ComposerPolicyControls.swift:261）。
    // - 观察者在进程生命周期内常驻（与缓存本身同寿），不重复注册，故不需要配对移除。

    private static var pressureMonitoringStarted = false
    private static var memoryPressureDegradeSource: (any DispatchSourceMemoryPressure)?
    private static var memoryPressureRecoverSource: (any DispatchSourceMemoryPressure)?
    private static var thermalStateObserver: (any NSObjectProtocol)?
    private static var observedMemoryPressureLevel: PressureLevel = .normal
    private static var observedThermalPressureLevel: PressureLevel = .normal

    /// 幂等启动 OS 压力生产者：重复调用不会长出第二组信号源。
    static func startPressureMonitoringIfNeeded() {
        guard !pressureMonitoringStarted else { return }
        pressureMonitoringStarted = true

        let degrade = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        degrade.setEventHandler {
            MainActor.assumeIsolated {
                recordMemoryPressureEvent(from: memoryPressureDegradeSource)
            }
        }
        let recover = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal],
            queue: .main
        )
        recover.setEventHandler {
            MainActor.assumeIsolated {
                recordMemoryPressureEvent(from: memoryPressureRecoverSource)
            }
        }
        // 先存后 activate：handler 在主队列异步投递，最早已赋值之后，读不到 nil。
        memoryPressureDegradeSource = degrade
        memoryPressureRecoverSource = recover
        degrade.activate()
        recover.activate()

        // 启动即采纳 OS 当前热压力真值，之后再跟 transition 通知。
        observedThermalPressureLevel = pressureLevel(for: ProcessInfo.processInfo.thermalState)
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                recordThermalStateEvent(ProcessInfo.processInfo.thermalState)
            }
        }
        setPressureLevel(
            moreSeverePressureLevel(observedMemoryPressureLevel, observedThermalPressureLevel)
        )
    }

    /// OS 内存压力事件档位 → 既有 PressureLevel（纯映射，便于逐项钉住）。
    static func pressureLevel(for event: DispatchSource.MemoryPressureEvent) -> PressureLevel {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .elevated }
        return .normal
    }

    /// OS 热压力档位 → 既有 PressureLevel（纯映射；OS 四档单调折叠进既有三档）。
    static func pressureLevel(for state: ProcessInfo.ThermalState) -> PressureLevel {
        switch state {
        case .nominal: return .normal
        case .critical: return .critical
        case .fair, .serious: return .elevated
        default: return .elevated  // OS 未来新增的非 nominal 档位按降级处理，不被误判成恢复
        }
    }

    /// 两路 OS 信号的合成：取更严重的一档（次序 = 既有枚举 normal < elevated < critical）。
    static func moreSeverePressureLevel(_ lhs: PressureLevel, _ rhs: PressureLevel) -> PressureLevel {
        severityRank(lhs) >= severityRank(rhs) ? lhs : rhs
    }

    private static func severityRank(_ level: PressureLevel) -> Int {
        switch level {
        case .normal: return 0
        case .elevated: return 1
        case .critical: return 2
        }
    }

    /// 内存压力事件入口：读该来源当前的 OS 档位（不自行判级）并落到缓存级别。
    static func recordMemoryPressureEvent(from source: (any DispatchSourceMemoryPressure)?) {
        guard let source else { return }
        applyObservedMemoryPressureLevel(pressureLevel(for: source.data))
    }

    /// 热压力事件入口（OS 真值 = `ProcessInfo.processInfo.thermalState`）。
    static func recordThermalStateEvent(_ state: ProcessInfo.ThermalState) {
        applyObservedThermalPressureLevel(pressureLevel(for: state))
    }

    static func applyObservedMemoryPressureLevel(_ level: PressureLevel) {
        observedMemoryPressureLevel = level
        setPressureLevel(
            moreSeverePressureLevel(observedMemoryPressureLevel, observedThermalPressureLevel)
        )
    }

    static func applyObservedThermalPressureLevel(_ level: PressureLevel) {
        observedThermalPressureLevel = level
        setPressureLevel(
            moreSeverePressureLevel(observedMemoryPressureLevel, observedThermalPressureLevel)
        )
    }

    /// 测试/诊断：生产者是否已启动（幂等守卫的可观察状态）。
    static var isPressureMonitoringActive: Bool { pressureMonitoringStarted }

    /// 测试/诊断：已装配的 OS 信号源数量（降级 + 恢复两路 DispatchSource；重复启动不增长）。
    static var pressureSourceCount: Int {
        (memoryPressureDegradeSource == nil ? 0 : 1) + (memoryPressureRecoverSource == nil ? 0 : 1)
    }

    /// 测试/诊断：热压力观察者是否已装配（重复启动不重复注册）。
    static var isThermalMonitoringActive: Bool { thermalStateObserver != nil }
}
