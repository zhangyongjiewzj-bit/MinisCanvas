import Foundation
import Testing
@testable import MinisCore

@Suite("D-PERF-01 Unicode format prefilter and redaction")
struct ContentSecretUnicodeFastNegative2975Tests {
    @Test func uncasedScalarsCannotCompleteAnASCIITrigger() {
        let ordinary = String(repeating: "中🙂e\u{301}文", count: 20_000)
        #expect(!ContentSecretRedactor.mayContainFormatTrigger(ordinary))
        for separator in ["中", "🙂", "\u{0301}", "\u{200D}", "\u{FE0F}"] {
            let split = "s" + separator + "k-12345678"
            #expect(!ContentSecretRedactor.mayContainFormatTrigger(split))
            #expect(ContentSecretRedactor.redact(split) == split)
        }
    }

    @Test func casedUnicodeAndActualFormatTokensStillUseOriginalMasking() {
        let marker = "syntheticValue2975"
        for prefix in ["Bearer ", "Key=", "ſecret="] {
            let text = "中🙂 " + prefix + marker + " 文"
            #expect(ContentSecretRedactor.mayContainFormatTrigger(text))
            let masked = ContentSecretRedactor.redact(text)
            #expect(!masked.contains(marker), "format value escaped: \(prefix)")
            #expect(masked.hasPrefix("中🙂 ") && masked.hasSuffix(" 文"))
        }
        let known = "syntheticOpaque2975"
        let ordinary = String(repeating: "中🙂e\u{301}文", count: 10_000)
        let protected = ContentSecretRedactor.redact(ordinary + known, knownSecrets: [known])
        #expect(protected == ordinary + ContentSecretRedactor.mask(known))
    }
}
