import Foundation
import Testing
import SwiftUI
import AppKit
import MinisCore
@testable import MinisCanvasApp

@Suite("MinisIcon semantic contract")
@MainActor
struct MinisIconContractTests {
    @Test("theme-bound disabled primary consumes the original contrast role, retaining all other icon states",
          arguments: ThemePreset.selectable, [false, true])
    func disabledPrimaryUsesAcceptedRole1620(preset: ThemePreset, systemIsDark: Bool) throws {
        let mode = preset.resolvedMode(systemIsDark: systemIsDark)
        let tokens = try #require(preset == .system
            ? ThemeTokenProvider.nativeSystemTokens(for: mode)
            : preset.semanticTokens(systemIsDark: systemIsDark))
        let actual = MinisIconTokens.primaryColor(for: .disabled, mode: mode, themeTokens: tokens)
        // The actual color factory must return the opaque, resolved foreground,
        // not another opacity applied to a passing token.
        #expect(actual == tokens.disabled.swiftUIColor)
        let overlay = mode == .light ? Aj38Palette.readableLight : Aj38Palette.readableDark
        // System's live AJ38 backgrounds come from the same native tokens;
        // retired four-theme material is no longer a selectable consumer.
        let overlaySurfaces = preset == .system
            ? [tokens.background, tokens.sidebarBackground]
            : [overlay.backgroundPrimary, overlay.backgroundSecondary]
        let surfaces = [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised] + overlaySurfaces
        for surface in surfaces {
            #expect(ThemeContrast.evaluate(
                role: .disabled, foreground: tokens.disabled, background: surface).passes)
            if mode == .light {
                // Negative control: the old light primary on the same owned
                // surface must fail the unchanged predicate.
                let alpha = MinisIconTokens.disabledOpacity
                let neutral = Double(0x1C) / 255.0
                let legacy = ThemeColor(
                    r: alpha * neutral + (1 - alpha) * surface.r,
                    g: alpha * neutral + (1 - alpha) * surface.g,
                    b: alpha * neutral + (1 - alpha) * surface.b)
                #expect(!ThemeContrast.evaluate(
                    role: .disabled, foreground: legacy, background: surface).passes)
            }
        }
        let darkTokens = mode == .dark ? tokens : nil
        for state in [MinisIconState.normal, .hover, .active, .danger, .success] {
            #expect(MinisIconTokens.primaryColor(for: state, mode: mode, themeTokens: tokens)
                    == MinisIconTokens.primaryColor(for: state, darkTokens: darkTokens))
        }
        #expect(MinisIconTokens.primaryColor(for: .disabled)
                == MinisIconTokens.neutralPrimary.opacity(0.38))
        #expect(MinisIconTokens.secondaryColor(for: .disabled, darkTokens: darkTokens)
                == (darkTokens?.disabled.swiftUIColor ?? MinisIconTokens.neutralPrimary).opacity(0.12))
        #expect(ThemeContrastRole.disabled.minimumRatio == 2.5)
        #expect(ThemeContrast.ratioTolerance == 1e-9)
    }

    @Test(arguments: [ThemeMode.light, ThemeMode.dark])
    func explicitThemeRolesReachBothIconLayers866(mode: ThemeMode) {
        let tokens = AccentTheme.pseudo.semanticTokens(for: mode)
        let darkTokens = mode == .dark ? tokens : nil
        let neutral = mode == .dark ? tokens.textPrimary.swiftUIColor : MinisIconTokens.neutralPrimary
        let disabled = mode == .dark ? tokens.disabled.swiftUIColor : MinisIconTokens.neutralPrimary.opacity(0.38)
        let danger = mode == .dark ? tokens.statusDanger.swiftUIColor : MinisIconTokens.danger
        let success = mode == .dark ? tokens.statusSuccess.swiftUIColor : MinisIconTokens.success
        #expect(MinisIconTokens.primaryColor(for: .normal, darkTokens: darkTokens) == neutral)
        #expect(MinisIconTokens.primaryColor(for: .hover, darkTokens: darkTokens) == neutral)
        #expect(MinisIconTokens.primaryColor(for: .disabled, darkTokens: darkTokens) == disabled)
        #expect(MinisIconTokens.primaryColor(for: .danger, darkTokens: darkTokens) == danger)
        #expect(MinisIconTokens.primaryColor(for: .success, darkTokens: darkTokens) == success)
        #expect(MinisIconTokens.primaryColor(for: .active, darkTokens: darkTokens) == MinisIconTokens.keylineOrangeA7A)
        #expect(MinisIconTokens.secondaryColor(for: .normal, darkTokens: darkTokens) == neutral.opacity(0.24))
        #expect(MinisIconTokens.secondaryColor(for: .hover, darkTokens: darkTokens) == MinisIconTokens.keylineOrangeA7A.opacity(0.16))
        #expect(MinisIconTokens.secondaryColor(for: .active, darkTokens: darkTokens) == MinisIconTokens.keylineOrangeA7A.opacity(0.26))
        let disabledLayer = mode == .dark ? tokens.disabled.swiftUIColor : MinisIconTokens.neutralPrimary
        #expect(MinisIconTokens.secondaryColor(for: .disabled, darkTokens: darkTokens) == disabledLayer.opacity(0.12))
        #expect(MinisIconTokens.secondaryColor(for: .danger, darkTokens: darkTokens) == danger.opacity(0.24))
        #expect(MinisIconTokens.secondaryColor(for: .success, darkTokens: darkTokens) == success.opacity(0.24))
        // No theme injection keeps the original public token API byte semantics.
        #expect(MinisIconTokens.primaryColor(for: .normal) == MinisIconTokens.neutralPrimary)
        #expect(MinisIconTokens.secondaryColor(for: .normal) == MinisIconTokens.neutralPrimary.opacity(0.24))
    }

    @Test("semantic IDs are unique and cover the K0 foundation")
    func semanticIDsAreUnique() {
        let ids = MinisIcon.allCases.map(\.rawValue)
        #expect(ids.count == 79)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every semantic ID has a vendor asset and an allowlisted fallback")
    func descriptorsAreComplete() {
        for icon in MinisIcon.allCases {
            #expect(!icon.assetName.isEmpty)
            #expect(!icon.upstreamFilename.isEmpty)
            #expect(!icon.fallbackSystemName.isEmpty)
        }
    }

    /// `MinisIconView.renderSource(for:bundle:)` stays main-actor isolated on
    /// purpose: it resolves asset layers through `NSImage`, an AppKit main-actor
    /// type. The probe therefore runs from a main-actor context instead of
    /// reaching into the actor synchronously; assertions are unchanged.
    @Test("missing compile-time assets fail closed to SF fallback")
    @MainActor
    func missingAssetFallsBack() {
        let source = MinisIconView.renderSource(for: .search, bundle: .main)
        #expect(source == .fallback(systemName: "magnifyingglass"))
    }

    @Test("every selected semantic ID resolves to its bundled primary and secondary layers")
    func bundledAssetsResolve() {
        for icon in MinisIcon.allCases {
            #expect(MinisIconView.renderSource(for: icon) == .keyline)
        }
    }

    @Test("a packaged app resolves icon layers inside its own Resources directory")
    @MainActor
    func packagedAppUsesSelfContainedIcons() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-icon-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let appURL = fixtureRoot.appendingPathComponent("SyntheticMinisCanvas.app", isDirectory: true)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundledURL = resourcesURL.appendingPathComponent(
            "MinisCanvasApp_MinisCanvasApp.bundle", isDirectory: true
        )
        let rasterURL = bundledURL.appendingPathComponent("KeylineIcons/Raster", isDirectory: true)
        try FileManager.default.createDirectory(at: rasterURL, withIntermediateDirectories: true)

        let sourceRaster = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/Resources/ThirdParty/KeylineIcons/Raster")
        for layer in ["primary", "secondary"] {
            let filename = "search-\(layer).png"
            try FileManager.default.copyItem(
                at: sourceRaster.appendingPathComponent(filename),
                to: rasterURL.appendingPathComponent(filename)
            )
        }

        var externalFallbackUsed = false
        let resolved = MinisIconView.resolveResourceBundle(
            mainBundleURL: appURL,
            mainResourceURL: resourcesURL,
            moduleBundle: {
                externalFallbackUsed = true
                return .main
            }
        )
        let bundle = try #require(resolved)
        #expect(!externalFallbackUsed)
        #expect(bundle.bundleURL.standardizedFileURL == bundledURL.standardizedFileURL)
        #expect(MinisIconView.renderSource(for: .search, bundle: bundle) == .keyline)
    }

    @Test("an app missing its resources cannot fall back to an external build path")
    @MainActor
    func packagedAppMissingResourcesDoesNotLoadScratch() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-icon-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let appURL = fixtureRoot.appendingPathComponent("SyntheticMinisCanvas.app", isDirectory: true)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let resolved = MinisIconView.resolveResourceBundle(
            mainBundleURL: appURL,
            mainResourceURL: resourcesURL,
            moduleBundle: { fatalError("packaged apps must not load SwiftPM build scratch") }
        )
        #expect(resolved == nil)
    }

    @Test("non-app SwiftPM runs retain their lazy module bundle fallback")
    @MainActor
    func commandLineUsesItsOwnModuleBundle() {
        var fallbackUsed = false
        let resolved = MinisIconView.resolveResourceBundle(
            mainBundleURL: URL(fileURLWithPath: "/synthetic/minis-cli"),
            mainResourceURL: nil,
            moduleBundle: {
                fallbackUsed = true
                return .main
            }
        )
        #expect(fallbackUsed)
        #expect(resolved?.bundleURL == Bundle.main.bundleURL)
    }

    @Test func loadedRasterLayersCarryMenuPointSizeForAppKitHosts() throws {
        // Default Menu/Picker labels and menu items draw the NSImage at its own
        // point size; a 96 pt raster became a huge black glyph (Task Center filters).
        let bundle = try #require(MinisCanvasResourceBundle.current?.bundle)
        for icon in [MinisIcon.filter, .messages, .check, .database] {
            let layers = MinisIconView.bundledLayers(for: icon, bundle: bundle)
            #expect(layers != nil, "missing raster for \(icon)")
        }
        let url = try #require(bundle.url(forResource: "filter-primary", withExtension: "png",
                                          subdirectory: "KeylineIcons/Raster"))
        let image = MinisIconView.menuSafe(try #require(NSImage(contentsOf: url)))
        #expect(image.size == NSSize(width: MinisIconView.appKitPointSize, height: MinisIconView.appKitPointSize))
        #expect(image.isTemplate)
        #expect(image.representations.first.map { $0.pixelsWide } == 96)
    }

}
