import Foundation
import Testing
@testable import MinisCore

@Suite("D-PERF-05 conservative format discovery retains complete masking")
struct SecretFormatProbe590Tests {
    @Test("all existing format families and ICU Unicode folds still redact",
          arguments: ["sk", "bearer", "query", "quoted-query", "assignment", "quoted-assignment",
                      "authorization", "cookie", "userinfo", "session", "kelvin-key", "long-s-secret"])
    func formatFamiliesAndUnicodeFolds(shape: String) throws {
        let value = "OwnedSyntheticValue590"
        let input: String
        switch shape {
        case "sk": input = "prefix sk-" + value + " suffix"
        case "bearer": input = "prefix Bearer " + value + " suffix"
        case "query": input = "prefix ?access_token=" + value + "&page=2 suffix"
        case "quoted-query": input = "prefix ?api_key=\"" + value + "\"&page=2 suffix"
        case "assignment": input = "prefix FOO_KEY=" + value + " suffix"
        case "quoted-assignment": input = "prefix API_KEY='" + value + "' suffix"
        case "authorization": input = "prefix Authorization: " + value + "\nsuffix"
        case "cookie": input = "prefix Cookie: opaque=" + value + "; harmless prose\nsuffix"
        case "userinfo": input = "prefix https://owner:" + value + "@example.invalid suffix"
        case "session": input = "prefix session_id=" + value + " suffix"
        case "kelvin-key": input = "prefix KEY=" + value + " suffix"
        case "long-s-secret": input = "prefix ſecret=" + value + " suffix"
        default: throw CocoaError(.validationMissingMandatoryProperty)
        }
        let safe = ContentSecretRedactor.redact(input)
        #expect(!safe.contains(value))
        #expect(safe.hasPrefix("prefix "))
        #expect(safe.hasSuffix("suffix"))
        #expect(safe.contains("***"))
    }

    @Test("opaque custody values remain protected even when no format literal exists")
    func knownOpaqueValuesAndVerbatimPlainText() {
        let plain = String(repeating: "长草稿 ordinary owned text\n", count: 2_000)
        #expect(ContentSecretRedactor.redact(plain) == plain)
        let opaque = "OwnedOpaque590Value"
        let input = plain + opaque + " end"
        let safe = ContentSecretRedactor.redact(input, knownSecrets: [opaque])
        #expect(safe == plain + ContentSecretRedactor.mask(opaque) + " end")
        #expect(!safe.contains(opaque))
    }
}
