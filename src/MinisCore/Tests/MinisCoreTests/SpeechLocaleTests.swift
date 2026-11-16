import Testing
@testable import MinisCore

struct SpeechLocaleTests {
    @Test
    func mapsSupportedGeneralLanguages() throws {
        #expect(try SpeechLocaleResolver.runtimeLanguage(for: "zh-Hans") == "zh-CN")
        #expect(try SpeechLocaleResolver.runtimeLanguage(for: "en") == "en-US")
        #expect(try SpeechLocaleResolver.runtimeLanguage(for: "ja") == "ja-JP")
    }

    @Test
    func missingAndUnsupportedLanguagesFailClosed() {
        #expect(throws: SpeechLocaleError.missing) {
            try SpeechLocaleResolver.runtimeLanguage(for: nil)
        }
        #expect(throws: SpeechLocaleError.missing) {
            try SpeechLocaleResolver.runtimeLanguage(for: "  ")
        }
        #expect(throws: SpeechLocaleError.unsupported("fr")) {
            try SpeechLocaleResolver.runtimeLanguage(for: "fr")
        }
    }

    @Test
    func systemLocaleCapabilityIsObservational() {
        let capability = SpeechLocaleResolver.systemLocaleCapability
        #expect(!capability.identifier.isEmpty)
        #expect(SpeechLocaleResolver.supportedGeneralLanguages == ["zh-Hans", "en", "ja"])
    }
}
