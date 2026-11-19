import Foundation
import MinisCore

/// 面向用户的错误说明（八组 G-08 / G-14 / U-10）。
///
/// 为什么需要：界面上直接写 `error.localizedDescription` 会把系统或供应商的英文原文
/// （例如 “The file couldn’t be opened…”，可能带路径）、“（network）”“（provider）” 这类内部标记展示给用户。
/// 这里统一成中文说明：
/// - 本项目自己的错误（LocalizedError 且说明本身是中文）：原样使用，它们是固定文案；
/// - LLMError / URLError：走既有的中文分类映射，并去掉英文内部标记；
/// - 其它来源（系统、第三方）的错误：只按错误域和错误码粗分类，不读取、不展示原文，
///   所以原文里的路径、响应正文或凭据片段不可能进入界面。
/// 日志里的 `localizedDescription` 不经过这里，保持不变。
enum UserFacingErrorText {
    /// 把错误转换成可直接展示的中文说明。
    nonisolated static func describe(_ error: Error) -> String {
        if let llm = error as? LLMError {
            if let guidance = ChatGPTAccountErrors.fixedGuidance(for: llm) { return guidance }
            return stripEnglishTag(llm.friendlyMessage(locale: Locale(identifier: "zh_CN")))
        }
        if let urlError = error as? URLError {
            return stripEnglishTag(
                LLMError.networkError(underlying: urlError)
                    .friendlyMessage(locale: Locale(identifier: "zh_CN"))
            )
        }
        // 系统错误域（Cocoa / POSIX / URL / OSStatus / Mach）的说明可能带路径，一律不直出；
        // 其它域（本项目自己的错误类型）的说明是固定文案，是中文就原样用。
        let ns = error as NSError
        let systemDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain,
                             NSOSStatusErrorDomain, NSMachErrorDomain]
        if !systemDomains.contains(ns.domain) {
            let text = error.localizedDescription
            if containsChinese(text) { return text }
        }
        switch ChatStore.unknownErrorCategory(error) {
        case .permission:
            return "没有权限访问所需的文件或目录，请在系统设置或应用授权中确认访问权限后重试。"
        case .configuration:
            return "配置或数据格式无法识别，请在设置中检查相关配置后重试。"
        case .storage:
            return "读写本地存储失败（文件缺失、磁盘空间不足或只读），请检查磁盘空间与文件位置后重试。"
        case .internalFailure:
            return "应用内部出现未归类的错误，请重试；反复出现时输入 /doctor 导出诊断包。"
        }
    }

    /// 去掉 “（network）”“（provider）”“（parse）” 这类只有英文字母的内部标记。
    /// HTTP 状态码（401、429、5xx 等含数字的标记）对用户排查有用，保留。
    nonisolated static func stripEnglishTag(_ message: String) -> String {
        guard let open = message.firstIndex(of: "（"),
              let close = message[open...].firstIndex(of: "）") else { return message }
        let tag = message[message.index(after: open)..<close]
        guard !tag.isEmpty, tag.allSatisfy({ $0.isASCII && $0.isLetter }) else { return message }
        var result = message
        result.removeSubrange(open...close)
        return result
    }

    nonisolated static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
