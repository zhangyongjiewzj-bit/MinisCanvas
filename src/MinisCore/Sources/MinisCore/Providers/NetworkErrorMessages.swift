import Foundation

/// E20 中英文网络错误（URLError / NSError NSURLErrorDomain）→ 用户友好信息映射表。
///
/// 覆盖断网（-1009）、超时（-1001）、无法连接服务器（-1004）、找不到主机
/// （-1003）等常见场景；`LLMError.networkError` 通过它生成中英双语信息。
public enum NetworkErrorMessages {

    /// 中文用户友好信息。
    public static func zhMessage(for error: Error) -> String {
        switch code(of: error) {
        case NSURLErrorNotConnectedToInternet:
            return "网络连接失败，请检查网络是否可用"
        case NSURLErrorTimedOut:
            return "请求超时，请检查网络或稍后重试"
        case NSURLErrorCannotConnectToHost:
            return "无法连接到服务器，请检查网络或服务地址"
        case NSURLErrorCannotFindHost:
            return "找不到服务器地址，请检查服务地址是否配置正确"
        case NSURLErrorDNSLookupFailed:
            return "DNS 解析失败，请检查网络或服务地址"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接已断开，请检查网络后重试"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "安全连接失败，请检查服务证书或网络环境"
        default:
            return "网络请求未完成（E-NET-UNKNOWN）。请检查网络和服务地址，或到设置中的日志查看详情。"
        }
    }

    /// 英文用户友好信息。
    public static func enMessage(for error: Error) -> String {
        switch code(of: error) {
        case NSURLErrorNotConnectedToInternet:
            return "Network connection failed — please check if you are online"
        case NSURLErrorTimedOut:
            return "Request timed out — please check your network or retry later"
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to the server — please check your network or the service address"
        case NSURLErrorCannotFindHost:
            return "Server host not found — please check the service address"
        case NSURLErrorDNSLookupFailed:
            return "DNS lookup failed — please check your network or the service address"
        case NSURLErrorNetworkConnectionLost:
            return "Network connection was lost — please check your network and retry"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "Secure connection failed — please check the server certificate or your network"
        default:
            return "The network request could not be completed (E-NET-UNKNOWN). Check your connection and service address, or review Settings > Logs."
        }
    }

    /// 提取 URLError code（兼容 NSError 包装）。
    private static func code(of error: Error) -> Int {
        if let urlError = error as? URLError {
            return urlError.code.rawValue
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return ns.code
        }
        return -1
    }
}
