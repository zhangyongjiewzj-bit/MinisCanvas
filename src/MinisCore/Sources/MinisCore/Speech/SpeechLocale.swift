import Foundation

/// Maps the existing AppSettings.general.language value to the native
/// locale identifiers consumed by speech recognition and synthesis.
public enum SpeechLocaleError: Error, Equatable, Sendable {
    case missing
    case unsupported(String)
}

public enum SpeechLocaleResolver {
    public static let defaultGeneralLanguage = "zh-Hans"
    public static let supportedGeneralLanguages = ["zh-Hans", "en", "ja"]

    /// The system locale is observational only; it is never changed by
    /// application language selection.
    public static var systemLocaleCapability: Locale {
        Locale.current
    }

    public static func runtimeLanguage(for generalLanguage: String?) throws -> String {
        guard let generalLanguage else {
            throw SpeechLocaleError.missing
        }
        let normalized = generalLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SpeechLocaleError.missing
        }
        switch normalized {
        case "zh-Hans":
            return "zh-CN"
        case "en":
            return "en-US"
        case "ja":
            return "ja-JP"
        default:
            throw SpeechLocaleError.unsupported(normalized)
        }
    }

    public static func runtimeLocale(for generalLanguage: String?) throws -> Locale {
        Locale(identifier: try runtimeLanguage(for: generalLanguage))
    }
}
