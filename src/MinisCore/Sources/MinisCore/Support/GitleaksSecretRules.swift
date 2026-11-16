import Foundation

// Derived rule data from gitleaks v8.24.3 (MIT, Zachary Rice).
// See docs/third-party/gitleaks-v8.24.3 for pinned source records and license.
enum GitleaksSecretRules {
    static let expressions: [NSRegularExpression] = [
        // aws-access-token
        try! NSRegularExpression(pattern: #"\b((?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16})\b"#),
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
        try! NSRegularExpression(pattern: #"(?i)\b(npm_[a-z0-9]{36})(?:[\x60'"\s;]|\\[nr]|$)"#),
        // openai-api-key
        try! NSRegularExpression(pattern: #"\b(sk-(?:proj|svcacct|admin)-(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})T3BlbkFJ(?:[A-Za-z0-9_-]{74}|[A-Za-z0-9_-]{58})\b|sk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20})(?:[\x60'"\s;]|\\[nr]|$)"#),
        // private-key
        try! NSRegularExpression(pattern: #"(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[\s\S-]{64,}?KEY(?: BLOCK)?-----"#),
        // pypi-upload-token
        try! NSRegularExpression(pattern: #"pypi-AgEIcHlwaS5vcmc[\w-]{50,1000}"#),
        // slack-bot-token
        try! NSRegularExpression(pattern: #"xoxb-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*"#),
        // slack-user-token
        try! NSRegularExpression(pattern: #"xox[pe](?:-[0-9]{10,13}){3}-[a-zA-Z0-9-]{28,34}"#),
        // stripe-access-token
        try! NSRegularExpression(pattern: #"\b((?:sk|rk)_(?:test|live|prod)_[a-zA-Z0-9]{10,99})(?:[\x60'"\s;]|\\[nr]|$)"#),
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
