import Foundation

private final class MinisCanvasResourceBundleAnchor {}

/// The app's single resource owner. Packaged apps resolve their signed
/// Contents/Resources payload before SwiftPM's generated scratch-path accessor.
enum MinisCanvasResourceBundle {
    enum Origin: Equatable, Sendable {
        case packagedResources
        case owningExecutable
        case swiftPackage
    }

    struct Resolution {
        let bundle: Bundle
        let origin: Origin

        var resourceURL: URL? { bundle.resourceURL }
    }

    nonisolated static var current: Resolution? {
        resolve(
            mainBundleURL: Bundle.main.bundleURL,
            mainResourceURL: Bundle.main.resourceURL,
            owningBundle: owningResourceBundle,
            moduleBundle: { .module }
        )
    }

    /// Both injected providers are lazy. An `.app` with missing packaged
    /// resources fails closed; only DEV/test executables may use other owners.
    nonisolated static func resolve(
        mainBundleURL: URL,
        mainResourceURL: URL?,
        owningBundle: () -> Bundle? = { nil },
        moduleBundle: () -> Bundle
    ) -> Resolution? {
        if let mainResourceURL {
            let packagedURL = mainResourceURL.appendingPathComponent(
                "MinisCanvasApp_MinisCanvasApp.bundle", isDirectory: true
            )
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: packagedURL.path, isDirectory: &isDirectory
            ), isDirectory.boolValue, let bundle = Bundle(url: packagedURL) {
                return Resolution(bundle: bundle, origin: .packagedResources)
            }
        }
        guard mainBundleURL.pathExtension != "app" else { return nil }
        if let bundle = owningBundle() {
            return Resolution(bundle: bundle, origin: .owningExecutable)
        }
        return Resolution(bundle: moduleBundle(), origin: .swiftPackage)
    }

    nonisolated private static func owningResourceBundle() -> Bundle? {
        // Keep the existing icon host contract: a DEV/test executable can
        // directly own the shipped raster payload rather than a nested bundle.
        let bundle = Bundle(for: MinisCanvasResourceBundleAnchor.self)
        guard bundle.url(
            forResource: "filter-primary", withExtension: "png",
            subdirectory: "KeylineIcons/Raster"
        ) != nil else { return nil }
        return bundle
    }
}
