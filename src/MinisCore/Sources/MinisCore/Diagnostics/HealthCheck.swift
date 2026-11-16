import Foundation

// MARK: - HealthStatus

/// 单项健康检查的结论。
public enum HealthStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case ok
    case warning
    case error

    /// 严重程度排序（数值越大越严重），用于汇总。
    public var severity: Int {
        switch self {
        case .ok: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    /// 取两个状态中更严重的一个。
    public static func worse(_ a: HealthStatus, _ b: HealthStatus) -> HealthStatus {
        a.severity >= b.severity ? a : b
    }
}

// MARK: - HealthCategory

/// 健康检查的分类。
public enum HealthCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case env        // 环境变量
    case backends   // 本地后端（Ollama / ComfyUI / SD WebUI / Wan）
    case network    // 网络连通性
    case providers  // ProviderFactory 配置解析
    case storage    // 存储目录可写性

    public var displayName: String {
        switch self {
        case .env: return "环境变量"
        case .backends: return "本地后端"
        case .network: return "网络"
        case .providers: return "Provider"
        case .storage: return "存储"
        }
    }
}

// MARK: - HealthItem

/// 单项健康检查结果。
public struct HealthItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let category: HealthCategory
    public let status: HealthStatus
    public let message: String
    /// 可选的补充细节（不含明文密钥，敏感值一律脱敏）。
    public let details: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        category: HealthCategory,
        status: HealthStatus,
        message: String,
        details: [String] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.status = status
        self.message = message
        self.details = details
    }
}

// MARK: - HealthSummary

/// 健康报告汇总：分状态计数 + 整体结论。
public struct HealthSummary: Codable, Sendable, Equatable {
    public let okCount: Int
    public let warningCount: Int
    public let errorCount: Int
    public let overall: HealthStatus

    public init(items: [HealthItem]) {
        okCount = items.filter { $0.status == .ok }.count
        warningCount = items.filter { $0.status == .warning }.count
        errorCount = items.filter { $0.status == .error }.count
        overall = items.reduce(HealthStatus.ok) { HealthStatus.worse($0, $1.status) }
    }

    /// 整体是否健康（无 error；warning 只提示不阻断）。
    public var isHealthy: Bool { overall != .error }

    public init(okCount: Int, warningCount: Int, errorCount: Int, overall: HealthStatus) {
        self.okCount = okCount
        self.warningCount = warningCount
        self.errorCount = errorCount
        self.overall = overall
    }
}

// MARK: - HealthReport

/// 一次完整健康诊断的结果：条目 + 时间戳 + 汇总。
public struct HealthReport: Codable, Sendable, Equatable {
    public let items: [HealthItem]
    public let timestamp: Date
    public let summary: HealthSummary

    public init(items: [HealthItem], timestamp: Date = Date()) {
        self.items = items
        self.timestamp = timestamp
        self.summary = HealthSummary(items: items)
    }

    /// 按分类取条目。
    public func items(in category: HealthCategory) -> [HealthItem] {
        items.filter { $0.category == category }
    }
}
