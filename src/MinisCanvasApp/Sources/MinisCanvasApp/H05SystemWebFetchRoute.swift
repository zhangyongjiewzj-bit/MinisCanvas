import Foundation
import CFNetwork
import MinisCore

/// Reads routing policy for this exact hop, never proxy addresses or credentials.
/// It does not evaluate PAC or make a network request.
enum H05SystemWebFetchRoute {
    static func route(for url: URL) -> WebFetchPinnedRoute {
        let names = Set(ProcessInfo.processInfo.environment.keys.map { $0.lowercased() })
        let hasEnvironmentDirective = !names.isDisjoint(with:
            ["http_proxy", "https_proxy", "all_proxy", "no_proxy", "ftp_proxy"])
        guard !hasEnvironmentDirective else { return .proxyRequiresExistingRoute }
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let settings = raw as? [String: Any] else { return .unknown }
        let automaticKeys = ["ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
        let automatic = automaticKeys.map { key -> Bool? in
            guard let value = settings[key] else { return false }
            guard let number = value as? NSNumber else { return nil }
            return number.boolValue
        }
        guard automatic.allSatisfy({ $0 == false }) else {
            return automatic.contains(true) ? .proxyRequiresExistingRoute : .unknown
        }
        let ordered = CFNetworkCopyProxiesForURL(url as CFURL, raw).takeRetainedValue()
        guard let proxies = ordered as? [[String: Any]] else { return .unknown }
        let types = proxies.map { $0[kCFProxyTypeKey as String] as? String }
        return classify(systemSettingsPresent: true,
                        automaticProxyFlags: automatic,
                        orderedProxyTypes: types,
                        environmentDirectivePresent: false,
                        appProxyDirectivePresent: false)
    }

    /// Current H05 App composition has no app proxy override. A future override
    /// must pass its presence here and retain its existing route rather than
    /// silently selecting the pinned direct backend.
    static func classify(systemSettingsPresent: Bool,
                         automaticProxyFlags: [Bool?],
                         orderedProxyTypes: [String?],
                         environmentDirectivePresent: Bool,
                         appProxyDirectivePresent: Bool) -> WebFetchPinnedRoute {
        guard !environmentDirectivePresent, !appProxyDirectivePresent else {
            return .proxyRequiresExistingRoute
        }
        guard systemSettingsPresent else { return .unknown }
        guard automaticProxyFlags.allSatisfy({ $0 == false }) else {
            return automaticProxyFlags.contains(true) ? .proxyRequiresExistingRoute : .unknown
        }
        guard !orderedProxyTypes.isEmpty,
              orderedProxyTypes.allSatisfy({ $0 != nil }) else { return .unknown }
        if orderedProxyTypes == [kCFProxyTypeNone as String] { return .directConfirmed }
        return .proxyRequiresExistingRoute
    }
}
