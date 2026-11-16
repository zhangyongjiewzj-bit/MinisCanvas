import Foundation

/// The app's default outbound User-Agent for LLM provider requests.
///
/// Ported from OpenMinis `Shared/MinisUserAgent.swift` with the UIKit
/// dependency removed: instead of `UIDevice` we read the OS version from
/// `ProcessInfo` and the marketing version from the main bundle (nil when
/// running under `swift test`, where no app bundle exists).
public enum MinisUserAgent {
    // Swift initializes this immutable process-wide value once, including
    // when multiple provider requests first access it concurrently.
    private static let cached: String = {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "MinisCanvas/\(version) (macOS \(os.majorVersion).\(os.minorVersion); Apple Silicon)"
    }()

    public static var `default`: String { cached }
}
