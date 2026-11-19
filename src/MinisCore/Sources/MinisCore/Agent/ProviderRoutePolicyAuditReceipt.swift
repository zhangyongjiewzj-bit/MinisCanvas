import CryptoKit
import Foundation

/// Shared redaction and bounding policy for product-facing routing and
/// transcript consumers. The policy is deliberately content-only: it never
/// performs routing, reads credentials, or fetches remote content.
public enum ProductRedactionPolicy {
    public static let maxAuditFieldLength = 512
    public static let maxTranscriptFieldLength = 4_096

    public static func redact(
        _ text: String,
        knownSecrets: [String] = [],
        maxLength: Int = maxAuditFieldLength
    ) -> String {
        guard maxLength > 0 else { return "" }
        var result = ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
        result = replace(result, regex: remoteURLRegex, replacement: "<remote-url>")
        result = replace(result, regex: absolutePathRegex, replacement: "<path>")
        return String(result.prefix(maxLength))
    }

    /// Ordinary conversation display/copy only. Local paths the user typed are
    /// kept verbatim (aligned with Claude Code/Codex); secrets and credential
    /// links are still masked. General audit/tool redaction above remains
    /// stricter and still masks paths. Never recover anything from the original text.
    public static func redactConversationBody(_ text: String, knownSecrets: [String] = []) -> String {
        let redacted = ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
        return maskCredentialLinks(inRedacted: redacted, knownSecrets: knownSecrets)
    }

    /// `redactConversationBody` 的第二步（原样抽出，逻辑未改）：对已经过 `ContentSecretRedactor`
    /// 的文本把带凭据的链接遮蔽为 `<remote-url>`。链接匹配不含空白，所以以换行结尾的前缀与其后
    /// 文本可以分开处理，供转录显示层的流式增量脱敏复用。
    public static func maskCredentialLinks(inRedacted redacted: String, knownSecrets: [String] = []) -> String {
        guard let urls = conversationURLRegex else {
            return redacted
        }
        let source = redacted as NSString
        var result = ""
        var cursor = 0
        var searchCursor = 0
        while searchCursor < source.length,
              let match = urls.firstMatch(in: redacted, range: NSRange(
                location: searchCursor, length: source.length - searchCursor)) {
            // URLComponents validates URL syntax, not Markdown's closing ')'.
            // Retain balanced URL parentheses and percent-encoded characters.
            var end = NSMaxRange(match.range)
            var depth = 0
            var slashes = 0
            for index in match.range.location..<end {
                let character = source.character(at: index)
                if character == 92 { slashes += 1; continue }
                let escaped = slashes % 2 != 0
                slashes = 0
                if !escaped && character == 40 { depth += 1 }
                if !escaped && character == 41 {
                    if depth == 0 { end = index; break }
                    depth -= 1
                }
            }
            searchCursor = end
            let range = NSRange(location: match.range.location, length: end - match.range.location)
            let candidate = source.substring(with: range)
            let isPlainLink: Bool = {
                guard let url = URLComponents(string: candidate),
                      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      url.url != nil,
                      url.user == nil, url.password == nil,
                      !(url.queryItems ?? []).contains(where: {
                          ContentSecretRedactor.isCredentialURLQueryName($0.name)
                      }),
                      let decoded = candidate.removingPercentEncoding,
                      decoded.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) == nil
                else { return false }
                return ContentSecretRedactor.redact(decoded, knownSecrets: knownSecrets) == decoded
            }()
            guard !isPlainLink else { continue }
            result += source.substring(with: NSRange(location: cursor,
                length: range.location - cursor))
            result += "<remote-url>"
            cursor = NSMaxRange(range)
        }
        result += source.substring(from: cursor)
        return result
    }

    private static let remoteURLRegex = try? NSRegularExpression(pattern: #"https?://[^\s\"'`<>]+"#)
    private static let absolutePathRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?:/|~\/)[^\s\"'`<>]+"#)
    private static let conversationURLRegex = try? NSRegularExpression(pattern: #"(?i)https?://[^\s\"'`<>]+"#)

    private static func replace(_ text: String, regex: NSRegularExpression?, replacement: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

/// A deterministic, execution-free policy handoff derived from routing evidence.
///
/// Only selected and explicitly declared fallback observations are admissible. All
/// failures, including observations that already failed closed for an unknown
/// external outcome, deny the handoff and omit the route payload.
public struct ProviderRoutePolicyAuditReceipt: Sendable, Equatable {
    public enum Decision: String, Sendable, Equatable {
        case admitted
        case denied
    }

    public let receiptID: String
    public let decision: Decision
    public let route: ProviderRouteSnapshot?
    public let reason: String
    /// Opaque composite identity for the admitted route. It includes the
    /// provider/model binding and the policy revision, never their raw values.
    public let bindingFingerprint: String?
    /// Present when the receipt carried the complete typed policy input. A
    /// projection-only observation cannot manufacture this revision.
    public let policyRevision: String?

    public init(observation: ProviderRouteResolutionObservation) {
        self.init(observation: observation, policyRevision: nil)
    }

    private init(
        observation: ProviderRouteResolutionObservation,
        policyRevision: String?
    ) {
        receiptID = ProductRedactionPolicy.redact(observation.receiptID)
        self.policyRevision = policyRevision

        var resolvedDecision: Decision = .denied
        var resolvedRoute: ProviderRouteSnapshot?
        var resolvedReason = observation.selectionReason
        var resolvedFingerprint: String?

        switch observation.outcome {
        case .selected, .fallback:
            guard Self.isValidReceiptID(observation.receiptID),
                  let route = observation.route,
                  Self.isValidRoute(route) else {
                resolvedReason = "routing audit denied; invalid route identity"
                break
            }
            let fingerprint = Self.bindingFingerprint(
                receiptID: observation.receiptID,
                outcome: observation.outcome,
                route: route,
                policyRevision: policyRevision
            )
            guard ProviderRoutePolicyAuditLedger.shared.admit(
                receiptID: observation.receiptID,
                fingerprint: fingerprint
            ) else {
                resolvedReason = "routing audit denied; receipt replay or identity conflict"
                break
            }
            resolvedDecision = .admitted
            resolvedRoute = Self.redactedRoute(route)
            resolvedFingerprint = fingerprint
        case .failure:
            resolvedRoute = nil
        }

        decision = resolvedDecision
        route = resolvedRoute
        reason = ProductRedactionPolicy.redact(resolvedReason)
        bindingFingerprint = resolvedFingerprint
    }

    public init(receipt: ProviderRouteResolutionReceipt) {
        self.init(
            observation: ProviderRouteResolutionObservation(receipt: receipt),
            policyRevision: Self.policyRevision(for: receipt.policyInput)
        )
    }

    private static func isValidReceiptID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value != "."
            && value != ".."
    }

    private static func isValidRoute(_ route: ProviderRouteSnapshot) -> Bool {
        isValidReceiptID(route.providerID)
            && isValidReceiptID(route.providerName)
            && isValidReceiptID(route.modelID)
            && route.requiredCapabilities.isSubset(of: route.availableCapabilities)
            && (route.configurationFingerprint.map(isValidReceiptID) ?? true)
    }

    private static func bindingFingerprint(
        receiptID: String,
        outcome: ProviderRouteResolutionObservationOutcome,
        route: ProviderRouteSnapshot,
        policyRevision: String?
    ) -> String {
        let canonical = [
            receiptID,
            outcome.rawValue,
            route.providerID,
            route.providerName,
            route.modelID,
            route.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ","),
            route.availableCapabilities.map(\.rawValue).sorted().joined(separator: ","),
            route.configurationFingerprint ?? "",
            policyRevision ?? "<projection-only>",
        ].joined(separator: "|")
        return "provider-route-audit:\(digest(canonical))"
    }

    private static func policyRevision(for input: ProviderRoutePolicyInput) -> String {
        let request = input.request
        let allowed = request.allowedProviderIDs?.sorted().joined(separator: ",") ?? "<any>"
        let capabilities = request.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ",")
        let fallback: String
        switch input.fallback {
        case .fail:
            fallback = "fail"
        case let .binding(providerID, providerName, modelID, fingerprint, reason):
            fallback = [providerID, providerName, modelID, fingerprint, reason].joined(separator: ":")
        }
        let canonical = [
            capabilities,
            allowed,
            String(format: "%.6f", request.policy.costWeight),
            String(format: "%.6f", request.policy.latencyWeight),
            String(format: "%.6f", request.policy.qualityWeight),
            fallback,
        ].joined(separator: "|")
        return "provider-policy:\(digest(canonical))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func redactedRoute(_ route: ProviderRouteSnapshot?) -> ProviderRouteSnapshot? {
        guard let route else { return nil }
        let candidate = ProviderRouteCandidate(
            id: ProductRedactionPolicy.redact(route.providerID),
            providerName: ProductRedactionPolicy.redact(route.providerName),
            modelID: ProductRedactionPolicy.redact(route.modelID),
            capabilities: route.availableCapabilities
        )
        return ProviderRouteSnapshot(
            candidate: candidate,
            requiredCapabilities: route.requiredCapabilities,
            configurationFingerprint: route.configurationFingerprint.map {
                ProductRedactionPolicy.redact($0)
            },
            selectionScore: route.selectionScore
        )
    }
}

/// Process-local terminal fence for product audit handoffs. A receipt ID may
/// be admitted once; a conflicting route/policy or replay is denied. The
/// bounded FIFO prevents unbounded growth while retaining recent identities.
private final class ProviderRoutePolicyAuditLedger: @unchecked Sendable {
    static let shared = ProviderRoutePolicyAuditLedger()
    private static let capacity = 4_096

    private let lock = NSLock()
    private var fingerprints: [String: String] = [:]
    private var insertionOrder: [String] = []

    func admit(receiptID: String, fingerprint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fingerprints[receiptID] == nil else { return false }
        fingerprints[receiptID] = fingerprint
        insertionOrder.append(receiptID)
        if insertionOrder.count > Self.capacity,
           let retired = insertionOrder.first {
            insertionOrder.removeFirst()
            fingerprints.removeValue(forKey: retired)
        }
        return true
    }
}
