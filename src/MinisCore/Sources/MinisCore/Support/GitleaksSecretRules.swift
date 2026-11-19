import Foundation

// Derived rule data from gitleaks v8.24.3 (MIT, Zachary Rice).
// See docs/third-party/gitleaks-v8.24.3 for pinned source records and license.
enum GitleaksSecretRules {
    /// private-key 规则单独暴露：流式增量脱敏需要知道哪些区间属于同一个跨行匹配。
    static let privateKeyExpression = try! NSRegularExpression(pattern: #"(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[\s\S-]{64,}?KEY(?: BLOCK)?-----"#)

    static let expressions: [NSRegularExpression] = [
        // aws-access-token
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])((?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16})(?![A-Za-z0-9_])"#),
        // github-app-token
        try! NSRegularExpression(pattern: #"(?:ghu|ghs)_[0-9a-zA-Z]{36}"#),
        // github-fine-grained-pat
        try! NSRegularExpression(pattern: #"github_pat_\w{82}"#),
        // github-oauth
        try! NSRegularExpression(pattern: #"gho_[0-9a-zA-Z]{36}"#),
        // github-pat
        try! NSRegularExpression(pattern: #"ghp_[0-9a-zA-Z]{36}"#),
        // gitlab-pat
        try! NSRegularExpression(pattern: #"glpat-[\w-]{20}"#),
        // npm-access-token
        try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_])(npm_[a-z0-9]{36})(?![A-Za-z0-9_\-])"#),
        // openai-api-key
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(sk-(?:proj|svcacct|admin)-(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})T3BlbkFJ(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})|sk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20})(?![A-Za-z0-9_\-])"#),
        // private-key
        privateKeyExpression,
        // pypi-upload-token
        try! NSRegularExpression(pattern: #"pypi-AgEIcHlwaS5vcmc[\w-]{50,1000}"#),
        // slack-bot-token
        try! NSRegularExpression(pattern: #"xoxb-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*"#),
        // slack-user-token
        try! NSRegularExpression(pattern: #"xox[pe](?:-[0-9]{10,13}){3}-[a-zA-Z0-9-]{28,34}"#),
        // stripe-access-token
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])((?:sk|rk)_(?:test|live|prod)_[a-zA-Z0-9]{10,99})(?![A-Za-z0-9_\-])"#),
    ]

    static func containsMatch(_ text: String) -> Bool {
        expressions.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    static func redact(_ text: String) -> String {
        var result = text
        for expression in expressions {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                let secret = match.range(at: expression.numberOfCaptureGroups > 0 ? 1 : 0)
                guard let range = Range(secret, in: result) else { continue }
                result.replaceSubrange(range, with: ContentSecretRedactor.mask(String(result[range])))
            }
        }
        return result
    }
}
