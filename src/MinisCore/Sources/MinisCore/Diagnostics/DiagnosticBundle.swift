import Foundation

// MARK: - Fixed diagnostic schema

/// The only health domains that may appear in a diagnostic bundle.
///
/// This list intentionally mirrors the existing `HealthCategory` values while
/// keeping the exported format independent from the full `HealthReport`
/// payload.  A bundle contains module state and counts only; names, messages,
/// details, URLs, and identifiers from a health item never cross this boundary.
public enum DiagnosticBundleModule: String, Codable, CaseIterable, Hashable, Sendable {
    case environment
    case backends
    case network
    case providers
    case storage

    fileprivate var healthCategory: HealthCategory {
        switch self {
        case .environment: return .env
        case .backends: return .backends
        case .network: return .network
        case .providers: return .providers
        case .storage: return .storage
        }
    }
}

/// Health state used by the export format.  `unknown` is explicit so a
/// missing/stale report cannot be mistaken for a healthy empty report.
public enum DiagnosticBundleHealthState: String, Codable, CaseIterable, Hashable, Sendable {
    case ok
    case warning
    case error
    case unknown
}

/// Safe, bounded application identity.  It contains no host name, user name,
/// filesystem path, bundle URL, or process arguments.
public struct DiagnosticApplicationInfo: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case platform
        case platformVersion = "platform_version"
        case architecture
    }

    public let version: String
    public let build: String
    public let platform: String
    public let platformVersion: String
    public let architecture: String

    /// Constructs a sanitized identity.  Values outside a deliberately small
    /// token alphabet become `unknown` rather than being copied to the file.
    public init(
        version: String? = nil,
        build: String? = nil,
        platform: String = "macOS",
        platformVersion: String? = nil,
        architecture: String? = nil
    ) {
        self.version = Self.safeToken(version)
        self.build = Self.safeToken(build)
        self.platform = platform == "macOS" ? "macOS" : "unknown"
        self.platformVersion = Self.safeVersion(platformVersion)
        self.architecture = Self.safeToken(architecture ?? Self.currentArchitecture)
    }

    /// Reads only fixed version fields from the main bundle and numeric OS
    /// facts from ProcessInfo.  It never reads environment values or paths.
    public static var current: Self {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Self(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            platformVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func safeToken(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return "unknown" }
        guard value.unicodeScalars.allSatisfy({ scalar in
            let code = scalar.value
            let alphanumeric = (code >= 48 && code <= 57)
                || (code >= 65 && code <= 90)
                || (code >= 97 && code <= 122)
            return alphanumeric || code == 45 || code == 46 || code == 95
        }) else {
            return "unknown"
        }
        return value
    }

    private static func safeVersion(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || $0.value == 46
              }) else {
            return "unknown"
        }
        return value
    }
}

/// A small runtime projection collected by the App composition root.  It is
/// deliberately boolean/enumerated only: no session IDs, titles, transcripts,
/// drafts, prompts, or task payloads can enter this type.
public enum DiagnosticRuntimeState: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case degraded
    case unknown
}

public struct DiagnosticRuntimeSummary: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case appState = "app_state"
        case activeSessionPresent = "active_session_present"
        case activeSessionStreaming = "active_session_streaming"
        case networkProbeTriggered = "network_probe_triggered"
    }

    public let appState: DiagnosticRuntimeState
    public let activeSessionPresent: Bool?
    public let activeSessionStreaming: Bool?
    /// This is a proof field for consumers: an export never starts a probe.
    /// The initializer hard-codes it to false so callers cannot opt into a
    /// network claim accidentally.
    public let networkProbeTriggered: Bool

    public init(
        appState: DiagnosticRuntimeState,
        activeSessionPresent: Bool? = nil,
        activeSessionStreaming: Bool? = nil
    ) {
        self.appState = appState
        self.activeSessionPresent = activeSessionPresent
        self.activeSessionStreaming = activeSessionStreaming
        self.networkProbeTriggered = false
    }

    public static let unknown = Self(
        appState: .unknown
    )
}

/// One fixed module projection. `itemCount` is a count only; all item-level
/// fields from `HealthReport` are intentionally discarded.
public struct DiagnosticModuleSnapshot: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case module
        case state
        case itemCount = "item_count"
    }

    public let module: DiagnosticBundleModule
    public let state: DiagnosticBundleHealthState
    public let itemCount: Int?

    public init(
        module: DiagnosticBundleModule,
        state: DiagnosticBundleHealthState,
        itemCount: Int?
    ) {
        self.module = module
        self.state = state
        self.itemCount = itemCount.map {
            max(0, min($0, DiagnosticBundleSnapshot.maxItemsPerModule))
        }
    }
}

public struct DiagnosticHealthSummary: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case overall
        case okCount = "ok_count"
        case warningCount = "warning_count"
        case errorCount = "error_count"
        case unknownCount = "unknown_count"
    }

    public let overall: DiagnosticBundleHealthState
    public let okCount: Int
    public let warningCount: Int
    public let errorCount: Int
    public let unknownCount: Int

    public init(
        overall: DiagnosticBundleHealthState,
        okCount: Int,
        warningCount: Int,
        errorCount: Int,
        unknownCount: Int
    ) {
        self.overall = overall
        self.okCount = max(0, min(okCount, DiagnosticBundleSnapshot.maxHealthCount))
        self.warningCount = max(0, min(warningCount, DiagnosticBundleSnapshot.maxHealthCount))
        self.errorCount = max(0, min(errorCount, DiagnosticBundleSnapshot.maxHealthCount))
        self.unknownCount = max(0, min(unknownCount, DiagnosticBundleModule.allCases.count))
    }
}

/// A static explanation of the export boundary.  These are policy labels, not
/// values read from the user's settings, logs, or credentials.
public struct DiagnosticRedactionSummary: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case policy
        case omittedFields = "omitted_fields"
    }

    public let policy: String
    public let omittedFields: [String]

    public init() {
        self.policy = "allowlisted_projection"
        self.omittedFields = [
            "credentials",
            "environment_values",
            "authorization",
            "cookies",
            "credential_urls",
            "transcripts",
            "drafts",
            "prompts",
            "attachments",
            "absolute_paths",
            "raw_errors",
        ]
    }
}

public enum DiagnosticBundleSnapshotError: Error, Equatable, Sendable, LocalizedError {
    case tooManyHealthItems
    case invalidTimestamp

    public var errorDescription: String? {
        switch self {
        case .tooManyHealthItems:
            return "诊断快照条目过多，未生成导出文件。"
        case .invalidTimestamp:
            return "诊断快照时间无效，未生成导出文件。"
        }
    }
}

/// Bounded, already-projected data prepared for export.  The optional
/// `HealthReport` exists only at construction time; this value stores no raw
/// report fields after projection.
public struct DiagnosticBundleSnapshot: Codable, Equatable, Hashable, Sendable {
    fileprivate static let maxHealthItems = 100
    fileprivate static let maxItemsPerModule = 100
    fileprivate static let maxHealthCount = 100

    private enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case healthSnapshotAt = "health_snapshot_at"
        case application
        case modules
        case health
        case runtime
        case redaction
    }

    public let capturedAt: Date
    public let healthSnapshotAt: Date?
    public let application: DiagnosticApplicationInfo
    public let modules: [DiagnosticModuleSnapshot]
    public let health: DiagnosticHealthSummary
    public let runtime: DiagnosticRuntimeSummary
    public let redaction: DiagnosticRedactionSummary

    /// Projects an existing report without copying any item string.  Passing
    /// nil is the normal App path until a prior health run is available; all
    /// five modules then remain explicitly unknown.
    public init(
        application: DiagnosticApplicationInfo = .current,
        healthReport: HealthReport? = nil,
        runtime: DiagnosticRuntimeSummary = .unknown,
        capturedAt: Date = Date()
    ) throws {
        guard capturedAt.timeIntervalSince1970.isFinite else {
            throw DiagnosticBundleSnapshotError.invalidTimestamp
        }
        if let healthReport {
            guard healthReport.items.count <= Self.maxHealthItems,
                  healthReport.timestamp.timeIntervalSince1970.isFinite else {
                throw healthReport.timestamp.timeIntervalSince1970.isFinite
                    ? DiagnosticBundleSnapshotError.tooManyHealthItems
                    : DiagnosticBundleSnapshotError.invalidTimestamp
            }
        }

        let moduleSnapshots = DiagnosticBundleModule.allCases.map { module in
            let items = healthReport?.items(in: module.healthCategory) ?? []
            return DiagnosticModuleSnapshot(
                module: module,
                state: Self.state(for: items),
                itemCount: healthReport == nil ? nil : items.count
            )
        }
        let knownItems = healthReport?.items ?? []
        let okCount = knownItems.reduce(into: 0) { count, item in
            if item.status == .ok { count += 1 }
        }
        let warningCount = knownItems.reduce(into: 0) { count, item in
            if item.status == .warning { count += 1 }
        }
        let errorCount = knownItems.reduce(into: 0) { count, item in
            if item.status == .error { count += 1 }
        }
        let unknownCount = moduleSnapshots.reduce(into: 0) { count, module in
            if module.state == .unknown { count += 1 }
        }

        self.capturedAt = capturedAt
        self.healthSnapshotAt = healthReport?.timestamp
        self.application = application
        self.modules = moduleSnapshots
        self.health = DiagnosticHealthSummary(
            overall: Self.overall(for: moduleSnapshots),
            okCount: okCount,
            warningCount: warningCount,
            errorCount: errorCount,
            unknownCount: unknownCount
        )
        self.runtime = runtime
        self.redaction = DiagnosticRedactionSummary()
    }

    private static func state(for items: [HealthItem]) -> DiagnosticBundleHealthState {
        guard !items.isEmpty else { return .unknown }
        if items.contains(where: { $0.status == .error }) { return .error }
        if items.contains(where: { $0.status == .warning }) { return .warning }
        return .ok
    }

    private static func overall(
        for modules: [DiagnosticModuleSnapshot]
    ) -> DiagnosticBundleHealthState {
        if modules.contains(where: { $0.state == .error }) { return .error }
        if modules.contains(where: { $0.state == .warning }) { return .warning }
        if modules.contains(where: { $0.state == .unknown }) { return .unknown }
        return .ok
    }
}

/// The versioned envelope written by `DiagnosticBundleExporter`.
public struct DiagnosticBundle: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case capturedAt = "captured_at"
        case healthSnapshotAt = "health_snapshot_at"
        case application
        case modules
        case health
        case runtime
        case redaction
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let allowedKeys: Set<String> = [
        "schema_version",
        "captured_at",
        "health_snapshot_at",
        "application",
        "modules",
        "health",
        "runtime",
        "redaction",
    ]

    public let schemaVersion: Int
    public let capturedAt: Date
    public let healthSnapshotAt: Date?
    public let application: DiagnosticApplicationInfo
    public let modules: [DiagnosticModuleSnapshot]
    public let health: DiagnosticHealthSummary
    public let runtime: DiagnosticRuntimeSummary
    public let redaction: DiagnosticRedactionSummary

    public init(snapshot: DiagnosticBundleSnapshot) {
        self.schemaVersion = Self.currentSchemaVersion
        self.capturedAt = snapshot.capturedAt
        self.healthSnapshotAt = snapshot.healthSnapshotAt
        self.application = snapshot.application
        self.modules = snapshot.modules
        self.health = snapshot.health
        self.runtime = snapshot.runtime
        self.redaction = snapshot.redaction
    }

    public init(
        application: DiagnosticApplicationInfo = .current,
        healthReport: HealthReport? = nil,
        runtime: DiagnosticRuntimeSummary = .unknown,
        capturedAt: Date = Date()
    ) throws {
        try self.init(snapshot: DiagnosticBundleSnapshot(
            application: application,
            healthReport: healthReport,
            runtime: runtime,
            capturedAt: capturedAt
        ))
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        let keys = Set(dynamic.allKeys.map(\.stringValue))
        guard keys.isSubset(of: Self.allowedKeys) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected diagnostic bundle key"
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostic bundle schema"
            )
        }
        let modules = try container.decode([DiagnosticModuleSnapshot].self, forKey: .modules)
        guard modules.map(\.module) == DiagnosticBundleModule.allCases,
              modules.count == DiagnosticBundleModule.allCases.count,
              modules.allSatisfy({ module in
                  module.itemCount.map {
                      (0...DiagnosticBundleSnapshot.maxItemsPerModule).contains($0)
                  } ?? true
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modules,
                in: container,
                debugDescription: "Diagnostic modules are not the fixed allowlist"
            )
        }
        let runtime = try container.decode(DiagnosticRuntimeSummary.self, forKey: .runtime)
        guard !runtime.networkProbeTriggered else {
            throw DecodingError.dataCorruptedError(
                forKey: .runtime,
                in: container,
                debugDescription: "Diagnostic export cannot claim a network probe"
            )
        }

        let health = try container.decode(DiagnosticHealthSummary.self, forKey: .health)
        guard (0...DiagnosticBundleSnapshot.maxHealthCount).contains(health.okCount),
              (0...DiagnosticBundleSnapshot.maxHealthCount).contains(health.warningCount),
              (0...DiagnosticBundleSnapshot.maxHealthCount).contains(health.errorCount),
              (0...DiagnosticBundleModule.allCases.count).contains(health.unknownCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .health,
                in: container,
                debugDescription: "Diagnostic health counts exceed the bounded schema"
            )
        }
        let redaction = try container.decode(DiagnosticRedactionSummary.self, forKey: .redaction)
        guard redaction == DiagnosticRedactionSummary() else {
            throw DecodingError.dataCorruptedError(
                forKey: .redaction,
                in: container,
                debugDescription: "Diagnostic redaction policy changed"
            )
        }

        self.schemaVersion = schemaVersion
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        self.healthSnapshotAt = try container.decodeIfPresent(Date.self, forKey: .healthSnapshotAt)
        self.application = try container.decode(DiagnosticApplicationInfo.self, forKey: .application)
        self.modules = modules
        self.health = health
        self.runtime = runtime
        self.redaction = redaction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encodeIfPresent(healthSnapshotAt, forKey: .healthSnapshotAt)
        try container.encode(application, forKey: .application)
        try container.encode(modules, forKey: .modules)
        try container.encode(health, forKey: .health)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(redaction, forKey: .redaction)
    }
}
