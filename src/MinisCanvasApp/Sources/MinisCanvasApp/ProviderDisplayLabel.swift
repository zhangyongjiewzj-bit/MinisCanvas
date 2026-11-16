import Foundation
import MinisCore

enum ProviderDisplayLabel {
    static func resolve(identity: String?) -> String? {
        guard let identity, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if identity == "Mock" { return "演示模式" }
        return ProviderIDMap.providerType(fromID: identity)?.displayName ?? "自定义"
    }

    static func resolve(record: EnvVarEntry) -> String {
        if let name = safeDisplayText(record.displayName) {
            return name
        }
        guard let host = displayHost(record.baseURL) else {
            return resolve(identity: record.name) ?? "自定义"
        }
        for type in [ProviderType.openAI, .anthropic, .openRouter, .dashScope, .deepSeek] {
            if displayHost(ChatStore.BuiltinReadinessBinding.route(for: type)?.baseURL) == host {
                return type.displayName
            }
        }
        return "自定义（\(host)）"
    }

    static func safeDisplayText(_ value: String?) -> String? {
        guard let value, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !label.contains("://"),
              ContentSecretRedactor.redact(label) == label else { return nil }
        return label
    }

    private static func displayHost(_ address: String?) -> String? {
        guard let address, let validated = try? CustomProviderURL.validate(address),
              let host = URLComponents(string: validated.absoluteString)?.host?.lowercased(),
              !host.isEmpty,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0)
                  || $0 == 45 || $0 == 46 || $0 == 58 }) else { return nil }
        return host
    }
}
