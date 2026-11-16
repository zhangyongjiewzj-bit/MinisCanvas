import Foundation
import MinisCore

/// Stable, value-only reasons emitted by catalog discovery.
/// The enum is intentionally closed so the aggregation map cannot grow with
/// attacker-controlled input.
enum SkillCatalogDiagnosticCode: String, CaseIterable, Sendable {
    case missingDocument = "missing_document"
    case untrustedEntry = "untrusted_entry"
    case invalidMetadata = "invalid_metadata"
    case snapshotRejected = "snapshot_rejected"
    case documentRejected = "document_rejected"
    case identityRejected = "identity_rejected"
    case duplicateIdentity = "duplicate_identity"
    case presentationRejected = "presentation_rejected"

    var userMessage: String {
        switch self {
        case .missingDocument: return "缺少 SKILL.md，未加入技能列表"
        case .documentRejected: return "SKILL.md 内容损坏或格式无效，未加入技能列表"
        case .snapshotRejected: return "SKILL.md 无法安全读取，未加入技能列表"
        case .untrustedEntry: return "技能目录不可信或无法读取，未加入技能列表"
        case .invalidMetadata: return "技能元数据无效，未加入技能列表"
        case .identityRejected: return "技能身份校验失败，未加入技能列表"
        case .duplicateIdentity: return "技能标识重复，未加入技能列表"
        case .presentationRejected: return "技能信息无法展示，未加入技能列表"
        }
    }
}

/// One safe locator for a rejected skill. It contains only a bounded final
/// directory/id component, never an absolute path, body, manifest or OS error.
struct SkillCatalogDiagnostic: Equatable, Sendable {
    static let invalidLocator = "<invalid-skill>"
    static let maxLocatorBytes = 128

    let source: SkillSource
    let locator: String
    let code: SkillCatalogDiagnosticCode

    var safeMessage: String {
        "\(source.rawValue):\(locator):\(code.rawValue)"
    }

    static func safeLocator(_ candidate: String) -> String {
        guard candidate.utf8.count <= maxLocatorBytes,
              SkillFilesystemBoundary.isSafePathComponent(candidate)
        else { return invalidLocator }
        return candidate
    }
}

/// Bounded discovery diagnostics. Counts preserve the full rejection total;
/// only the first `maxSamples` safe samples are retained for UI/logging.
struct SkillCatalogDiagnosticReport: Equatable, Sendable {
    static let maxSamples = 32

    var batchIncomplete = false
    private(set) var rejectedCount: Int = 0
    private(set) var suppressedSampleCount: Int = 0
    private(set) var samples: [SkillCatalogDiagnostic] = []
    private(set) var counts: [SkillCatalogDiagnosticCode: Int] = [:]

    var safeMessages: [String] { samples.map(\.safeMessage) }
    var userMessages: [String] {
        samples.map { "\($0.source.displayName) · \($0.locator)：\($0.code.userMessage)" }
    }

    /// A bounded, deterministic summary suitable for settings/picker status
    /// surfaces. It is deliberately composed only from fixed labels and
    /// counts; locators, paths, document text and OS errors never enter it.
    var stableSummary: String {
        guard rejectedCount > 0 else { return "技能目录：未发现拒绝项" }
        let countSummary = SkillCatalogDiagnosticCode.allCases.compactMap { code in
            guard let count = counts[code], count > 0 else { return nil }
            return "\(code.rawValue)=\(count)"
        }.joined(separator: ",")
        return "技能目录：拒绝 \(rejectedCount) 项；样本 \(samples.count) 项；省略 \(suppressedSampleCount) 项；\(countSummary)"
    }

    mutating func record(
        source: SkillSource,
        locator: String,
        code: SkillCatalogDiagnosticCode
    ) {
        rejectedCount += 1
        counts[code, default: 0] += 1
        guard samples.count < Self.maxSamples else {
            suppressedSampleCount += 1
            return
        }
        samples.append(SkillCatalogDiagnostic(
            source: source,
            locator: SkillCatalogDiagnostic.safeLocator(locator),
            code: code
        ))
    }

    mutating func merge(_ other: SkillCatalogDiagnosticReport) {
        batchIncomplete = batchIncomplete || other.batchIncomplete
        rejectedCount += other.rejectedCount
        suppressedSampleCount += other.suppressedSampleCount
        for code in SkillCatalogDiagnosticCode.allCases {
            if let count = other.counts[code] {
                counts[code, default: 0] += count
            }
        }
        for sample in other.samples {
            guard samples.count < Self.maxSamples else {
                suppressedSampleCount += 1
                continue
            }
            samples.append(sample)
        }
    }
}
