import Testing
import Foundation
@testable import MinisCore

/// 流式增量脱敏：密钥被拆开到达时任何中间显示状态都不含密钥片段，
/// 且增量结果与全量脱敏逐字节一致。样例全部是合成值。
@Suite("Incremental stream redaction")
struct IncrementalSecretRedactorTests {
    private struct Sample {
        let name: String
        let before: String
        let secret: String
        let after: String
        var probe: String? = nil
        var known: [String] = []

        var full: String { before + secret + after }
        /// 中间状态里不允许出现的片段（默认取密钥前 6 个字符）。
        var forbidden: String { probe ?? String(secret.prefix(6)) }
    }

    private static let samples: [Sample] = [
        Sample(name: "sk", before: "密钥如下 ", secret: "sk-synthetic-split-value-0123456789", after: " 其余说明。"),
        Sample(name: "github", before: "token 是 ",
               secret: "ghp_" + String(repeating: "aB3dE6gH9k", count: 3) + "aB3dE6", after: " 用完即弃\n"),
        Sample(name: "bearer", before: "curl 调用 Bearer ", secret: "abcdefghijklmnopqrstuv12345", after: " 成功"),
        Sample(name: "authorization-line", before: "请求头 Authorization: Basic ",
               secret: "dXNlcjpzZWNyZXQtdmFsdWU=", after: "\n下一行"),
        Sample(name: "assignment", before: "export DB_PASSWORD=", secret: "hunter2-hunter2", after: "\n"),
        Sample(name: "quoted", before: "run with password=\"", secret: "correct horse battery staple",
               after: "\" done"),
        Sample(name: "known-with-spaces", before: "回复：", secret: "Opaque Secret 12345 Value",
               after: "。结束", known: ["Opaque Secret 12345 Value"]),
        Sample(name: "private-key", before: "密钥文件：\n",
               secret: "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7abcdefgh\n-----END PRIVATE KEY-----",
               after: "\n完", probe: "MIIEvQ"),
    ]

    private struct LCG {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
    }

    private static func pieces(_ text: String, cuts: [Int]) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var last = 0
        for cut in Set(cuts).sorted() where cut > last && cut < characters.count {
            result.append(String(characters[last..<cut]))
            last = cut
        }
        result.append(String(characters[last...]))
        return result
    }

    private static func run(_ sample: Sample, cuts: [Int]) {
        var redactor = IncrementalSecretRedactor()
        for piece in pieces(sample.full, cuts: cuts) {
            let update = redactor.append(piece, knownSecrets: sample.known)
            #expect(!update.text.contains(sample.forbidden),
                    "\(sample.name) 中间显示状态出现了密钥片段，切分 \(cuts)")
        }
        let settled = redactor.settledProjection(knownSecrets: sample.known)
        #expect(settled == ContentSecretRedactor.redact(sample.full, knownSecrets: sample.known),
                "\(sample.name) 增量结果与全量脱敏不一致")
        #expect(!settled.contains(sample.forbidden))
    }

    @Test func secretSplitInTwoPiecesNeverShowsFragment() {
        for sample in Self.samples {
            let count = sample.full.count
            for cut in 1..<count { Self.run(sample, cuts: [cut]) }
        }
    }

    @Test func secretSplitInThreePiecesAndPerCharacterNeverShowsFragment() {
        var random = LCG(state: 20261117)
        for sample in Self.samples {
            let count = sample.full.count
            for _ in 0..<60 {
                let a = 1 + random.next() % (count - 1)
                let b = 1 + random.next() % (count - 1)
                Self.run(sample, cuts: [a, b])
            }
            Self.run(sample, cuts: Array(1..<count))
        }
    }

    private static let corpusLines: [String] = [
        "普通说明文字，没有密钥。\n",
        "export API_KEY=abcd1234efgh5678\n",
        "Authorization: Bearer abcdefghijklmnopqrstuv\n",
        "Authorization:\n  Basic dXNlcjpwYXNzd29yZA==\n",
        "curl -H 'X-Api-Key: zzzz9999yyyy'\n",
        "Cookie: sid=abc123456; theme=dark\n",
        "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7abcdefgh\nijklmnop\n-----END PRIVATE KEY-----\n",
        "visit https://user:pass1234@example.com/path now\n",
        "token ghp_aB3dE6gH9kaB3dE6gH9kaB3dE6gH9kaB3dE6 end\n",
        "password=\"correct horse\" and more\n",
        "Bearer\nabcdefghijklmnop12345\n",
        "sk-synthetic-abcdefghijklmnop\n",
        "Opaque Secret 12345 Value inside text\n",
        "代码：`let a = 1`\n\n",
        "没有换行的一段话 trailing words ",
    ]

    @Test func incrementalResultMatchesFullRedactionByteForByte() {
        let known = ["Opaque Secret 12345 Value"]
        var random = LCG(state: 7)
        for _ in 0..<80 {
            var raw = ""
            for _ in 0..<(3 + random.next() % 8) {
                raw += Self.corpusLines[random.next() % Self.corpusLines.count]
            }
            let count = raw.count
            var cuts: [Int] = []
            var position = 0
            while position < count {
                position += 1 + random.next() % 23
                cuts.append(position)
            }
            var redactor = IncrementalSecretRedactor()
            for piece in Self.pieces(raw, cuts: cuts) {
                _ = redactor.append(piece, knownSecrets: known)
            }
            #expect(redactor.rawText == raw)
            #expect(redactor.settledProjection(knownSecrets: known)
                    == ContentSecretRedactor.redact(raw, knownSecrets: known),
                    "切分 \(cuts) 下增量结果与全量不一致")
        }
    }

    @Test func settleReleasesWithheldTailAndKeepsItAcrossLaterText() {
        var redactor = IncrementalSecretRedactor()
        let first = redactor.append("先说 hello wor", knownSecrets: [])
        #expect(first.text == "先说 hello ")
        let settled = redactor.settle(knownSecrets: [])
        #expect(settled.text == "先说 hello wor")
        #expect(settled.extendsPrevious)
        let next = redactor.append("ld 完", knownSecrets: [])
        #expect(next.text.hasPrefix("先说 hello wor"))
    }

    @Test func withheldTailSurvivesCustodyDropAsMaskedText() {
        let secret = "SYNTH-OPAQUE-" + UUID().uuidString
        var redactor = IncrementalSecretRedactor()
        let shown = redactor.append("回复 " + secret, knownSecrets: [secret])
        #expect(shown.text == "回复 ")
        let withheld = redactor.withheldRedacted(knownSecrets: [secret])
        #expect(withheld == String(repeating: "*", count: secret.count))
    }

    // MARK: - 第二轮安全审查补充

    @Test func tokensGluedToChineseTextAreRedacted() {
        let cases: [(text: String, secret: String)] = [
            ("密钥sk-abcdefghijklmnop", "sk-abcdefgh"),
            ("使用Bearer abcdefghijklmnop1234 调用", "abcdefghijklmnop1234"),
            ("是AKIAIOSFODNN7EXAMPLE的密钥", "AKIAIOSFODNN7EXAMPLE"),
            ("中文API_KEY=abcd1234efgh", "abcd1234efgh"),
            ("令牌npm_" + String(repeating: "a1b2c3", count: 6) + "的", "npm_a1b2c3"),
            ("值sk_live_" + String(repeating: "Ab3dE6", count: 4) + "是", "sk_live_Ab3dE6"),
        ]
        for item in cases {
            let redacted = ContentSecretRedactor.redact(item.text)
            #expect(!redacted.contains(item.secret), "中文紧贴未命中：\(item.text)")
        }
        // 原有英文场景仍命中。
        #expect(!ContentSecretRedactor.redact("key sk-abcdefghijklmnop").contains("sk-abcdefgh"))
        #expect(!ContentSecretRedactor.redact("id AKIAIOSFODNN7EXAMPLE.").contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test func terminalProjectionMasksPartialTokensButKeepsPlainText() {
        let partials = [
            "说明 ghp_aB3dE6gH9kaB3dE6",
            "说明 sk-proj-abcd",
            "说明 xoxb-1234567890-",
            "说明 AKIAIOSFODNN",
            "说明 Authorization: Bearer abcdef",
            "说明\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwgg",
        ]
        let probes = ["ghp_aB3d", "sk-proj", "xoxb-1234", "AKIAIOSF", "abcdef", "MIIEvQ"]
        for (text, probe) in zip(partials, probes) {
            var redactor = IncrementalSecretRedactor()
            _ = redactor.append(String(text.prefix(5)), knownSecrets: [])
            _ = redactor.append(String(text.dropFirst(5)), knownSecrets: [])
            let closed = redactor.terminalProjection(knownSecrets: [])
            #expect(!closed.contains(probe), "终态泄露：\(text)")
            #expect(closed.hasPrefix("说明"))
        }
        var plain = IncrementalSecretRedactor()
        _ = plain.append("先说 hello wor", knownSecrets: [])
        #expect(plain.terminalProjection(knownSecrets: []) == "先说 hello wor")
    }

    @Test func terminalProjectionMasksPartialKnownSecretPrefix() {
        let secret = "Opaque Secret 12345 Value"
        var redactor = IncrementalSecretRedactor()
        _ = redactor.append("回复 Opaque Secret 123", knownSecrets: [secret])
        let closed = redactor.terminalProjection(knownSecrets: [secret])
        #expect(!closed.contains("Opaque Sec"))
        #expect(closed.hasPrefix("回复 "))
    }

    @Test func settleKeepsPartialTokenWithheldAndLaterTextStaysSafe() {
        var redactor = IncrementalSecretRedactor()
        _ = redactor.append("请使用 ghp_aB3dE6gH9kaB3dE6", knownSecrets: [])
        let settled = redactor.settle(knownSecrets: [])
        #expect(!settled.text.contains("ghp_aB3d"))
        #expect(settled.text.hasPrefix("请使用"))
        let next = redactor.append("gH9kaB3dE6gH9kaB3dE6gH9k 完", knownSecrets: [])
        #expect(!next.text.contains("ghp_aB3d"))
        #expect(!redactor.settledProjection(knownSecrets: []).contains("ghp_aB3d"))
    }

    @Test func unicodeWhitespaceBeforeNewlineDoesNotLeakValueOnNextLine() {
        let samples = [
            Sample(name: "nbsp", before: "说明\nAuthorization:\u{00A0}\n  ",
                   secret: "sk-live-aaaabbbbcccc", after: "\n后文"),
            Sample(name: "ideographic-space", before: "说明\nBearer\u{3000}\n",
                   secret: "abcdefghijklmnop12345", after: "\n后文"),
            Sample(name: "en-quad-colon", before: "api_key:\u{2003}\n", secret: "zzzz9999yyyy5555", after: "\n后文"),
        ]
        for sample in samples {
            for cut in 1..<sample.full.count { Self.run(sample, cuts: [cut]) }
        }
    }

    @Test func knownSecretAddedMidStreamIsMaskedInCommittedPrefix() {
        let secret = "OPAQUE-ZZ-12345"
        var redactor = IncrementalSecretRedactor()
        let first = redactor.append("值是 " + secret + " 好\n后文", knownSecrets: [])
        #expect(first.text.contains(secret))
        let second = redactor.append("x", knownSecrets: [secret])
        #expect(!second.text.contains(secret))
        #expect(!redactor.displayedText.contains(secret))
    }
}
