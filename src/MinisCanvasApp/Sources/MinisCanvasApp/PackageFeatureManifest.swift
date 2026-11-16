import Foundation

/// Read-only package evidence exposed by the About screen.
struct PackageFeatureManifest: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let sourceSHA: String
        let treeSHA: String
    }

    enum LoadState: Equatable, Sendable {
        case loaded(PackageFeatureManifest)
        case unavailable(String)
    }

    enum ReadError: Error, Equatable, LocalizedError {
        case resourceMissing
        case unreadable
        case malformed
        case missingFields([String])
        case identityMismatch

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "功能清单不可用：包内缺少 PACKAGE_FEATURE_MANIFEST.json"
            case .unreadable:
                return "功能清单不可用：PACKAGE_FEATURE_MANIFEST.json 无法读取"
            case .malformed:
                return "功能清单不可用：PACKAGE_FEATURE_MANIFEST.json 格式损坏"
            case .missingFields(let fields):
                return "功能清单不可用：缺少 \(fields.joined(separator: "、"))"
            case .identityMismatch:
                return "功能清单不可用：与当前包不匹配"
            }
        }
    }

    static let resourceName = "PACKAGE_FEATURE_MANIFEST"

    let channel: String
    let sourceSHA: String
    let treeSHA: String
    let buildTime: String
    let features: [String]
    let automatedTests: String
    let packagedStatus: String
    let fieldVerified: Bool
    let releaseReady: Bool
    let knownFieldIssues: [String]
    /// Optional package declaration for the artifact/result recovery contract.
    /// Older packages remain readable and report nil rather than claiming field
    /// verification that did not happen.
    let artifactContractRevision: String?

    var supportsArtifactRecovery: Bool {
        // A package may carry the optional field for forward compatibility;
        // only a non-empty, normalized revision is allowed to advertise the
        // persistence/reopen/recovery consumer contract.
        guard let revision = artifactContractRevision else { return false }
        return !revision.isEmpty
    }

    init(data: Data, expectedIdentity: Identity? = nil) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ReadError.malformed
        }

        let sourceSHA = Self.string(in: dictionary, keys: ["source_sha", "source_head", "sourceSHA", "source_hash"])
        let treeSHA = Self.string(in: dictionary, keys: ["tree_sha", "source_tree", "treeSHA", "tree"])
        let channel = Self.string(in: dictionary, keys: ["channel", "version_channel", "release_channel"])
        let buildTime = Self.string(in: dictionary, keys: ["build_time", "buildTime", "built_at", "build_timestamp"])
        let features = Self.stringList(in: dictionary, keys: ["features", "new_features"])
        let tests = Self.displayValue(in: dictionary, keys: ["tests", "automated_tests", "test_status"])
        let packaged = Self.displayValue(in: dictionary, keys: ["packaged", "packaged_status", "package_status"])
        let fieldVerified = Self.bool(in: dictionary, keys: ["field_verified", "fieldVerified"])
        let releaseReady = Self.bool(in: dictionary, keys: ["release_ready", "releaseReady"])
        let knownIssues = Self.stringList(
            in: dictionary,
            keys: ["known_field_issues", "knownFieldIssues", "known_issues"]
        )
        let artifactContractRevision = Self.string(
            in: dictionary,
            keys: ["artifact_contract_revision", "artifactContractRevision", "output_contract_revision"]
        )

        var missing: [String] = []
        if sourceSHA == nil { missing.append("source SHA") }
        if treeSHA == nil { missing.append("source tree") }
        if channel == nil { missing.append("版本渠道") }
        if buildTime == nil { missing.append("构建时间") }
        if features == nil { missing.append("本版新增能力") }
        if tests == nil { missing.append("自动测试状态") }
        if packaged == nil { missing.append("packaged 状态") }
        if fieldVerified == nil { missing.append("field_verified") }
        if releaseReady == nil { missing.append("release_ready") }
        if knownIssues == nil { missing.append("已知问题") }
        guard missing.isEmpty,
              let sourceSHA,
              let treeSHA,
              let channel,
              let buildTime,
              let features,
              let tests,
              let packaged,
              let fieldVerified,
              let releaseReady,
              let knownIssues else {
            throw ReadError.missingFields(missing)
        }

        if let expectedIdentity,
           expectedIdentity.sourceSHA != sourceSHA || expectedIdentity.treeSHA != treeSHA {
            throw ReadError.identityMismatch
        }

        self.channel = channel
        self.sourceSHA = sourceSHA
        self.treeSHA = treeSHA
        self.buildTime = buildTime
        self.features = features
        self.automatedTests = tests
        self.packagedStatus = packaged
        self.fieldVerified = fieldVerified
        self.releaseReady = releaseReady
        self.knownFieldIssues = knownIssues
        self.artifactContractRevision = artifactContractRevision
    }

    static func load(bundle: Bundle = .main, expectedIdentity: Identity? = nil) -> LoadState {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            return .unavailable(ReadError.resourceMissing.localizedDescription)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable(ReadError.unreadable.localizedDescription)
        }
        do {
            return .loaded(try Self(data: data, expectedIdentity: expectedIdentity))
        } catch let error as ReadError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable(ReadError.malformed.localizedDescription)
        }
    }

    static func expectedIdentity(from bundle: Bundle = .main) -> Identity? {
        let info = bundle.infoDictionary ?? [:]
        let source = string(in: info, keys: ["MinisCanvasSourceSHA", "SOURCE_SHA", "source_sha", "source_head"])
        let tree = string(in: info, keys: ["MinisCanvasSourceTree", "SOURCE_TREE", "tree_sha", "tree"])
        guard let source, let tree else { return nil }
        return Identity(sourceSHA: source, treeSHA: tree)
    }

    private static func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func bool(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool { return value }
            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }

    private static func stringList(in dictionary: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            guard let raw = dictionary[key] else { continue }
            if let values = raw as? [String] {
                let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return cleaned.isEmpty ? nil : cleaned
            }
            if let values = raw as? [[String: Any]] {
                let mapped = values.compactMap { entry in
                    string(in: entry, keys: ["name", "title", "label", "description", "issue"])
                }
                return mapped.isEmpty ? nil : mapped
            }
            if let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [value]
            }
        }
        return nil
    }

    private static func displayValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = dictionary[key] else { continue }
            if let value = raw as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let object = raw as? [String: Any] {
                if let value = string(in: object, keys: ["display", "summary", "status", "state", "result"]) {
                    return value
                }
                if let exit = object["real_exit"] as? NSNumber {
                    return "REAL_EXIT=\(exit.intValue)"
                }
            }
            if let value = raw as? NSNumber { return value.stringValue }
        }
        return nil
    }
}
