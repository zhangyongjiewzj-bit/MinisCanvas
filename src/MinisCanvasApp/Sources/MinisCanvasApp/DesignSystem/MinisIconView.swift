import AppKit
import SwiftUI
import MinisCore

public enum MinisIconRenderSource: Equatable, Sendable {
    case keyline
    case fallback(systemName: String)
}

public struct MinisIconView: View {
    // Synchronous resource probes remain available for contract tests. The
    // display path resolves this only inside the background reader below.
    nonisolated private static var resourceBundle: Bundle? {
        MinisCanvasResourceBundle.current?.bundle
    }

    private let icon: MinisIcon
    private let state: MinisIconState
    private let size: CGFloat
    private let accessibilityLabel: String?
    private let onAppearRender: ((MinisIcon, MinisIconRenderSource) -> Void)?
    // Opt-in legacy foreground palette for normal-state navigation glyphs.
    // Existing consumers retain their state/theme roles. New consumers retain
    // their original tint and the catalog's existing state-specific secondary alpha.
    private var foregroundPaletteStyle: AnyShapeStyle?

    func foregroundPalette<S: ShapeStyle>(_ style: S) -> Self {
        var copy = self
        copy.foregroundPaletteStyle = AnyShapeStyle(style)
        return copy
    }

    private var foregroundPaletteSecondaryOpacity: Double {
        guard foregroundPaletteStyle != nil else { return 1 }
        switch state {
        case .normal, .danger, .success: return MinisIconTokens.secondaryOpacity
        case .active: return MinisIconTokens.activeSecondaryOpacity
        case .hover: return 0.16
        case .disabled: return 0.12
        }
    }

    private var renderedPrimaryStyle: AnyShapeStyle {
        foregroundPaletteStyle ?? AnyShapeStyle(primaryColor)
    }

    private var renderedSecondaryStyle: AnyShapeStyle {
        foregroundPaletteStyle ?? AnyShapeStyle(
            MinisIconTokens.secondaryColor(for: state, darkTokens: darkTokens)
        )
    }

    @Environment(\.themeTokens) private var theme
    @Environment(\.minisIconRenderObservation) private var renderObservation
    @State private var renderInstanceID = UUID()
    private var layerCache: MinisIconLayerCache?
    @State private var loadedIcon: MinisIcon?
    @State private var loadedLayers: MinisIconLayerCache.Layers?

    // Decorative layers preserve light identity; dark surfaces use existing roles.
    private var darkTokens: ThemeSemanticTokens? {
        theme?.mode == .dark ? theme?.tokens : nil
    }

    private var primaryColor: Color {
        guard let theme else { return MinisIconTokens.primaryColor(for: state) }
        return MinisIconTokens.primaryColor(for: state, mode: theme.mode, themeTokens: theme.tokens)
    }

    public init(
        _ icon: MinisIcon,
        state: MinisIconState = .normal,
        size: CGFloat = MinisIconTokens.defaultSize,
        accessibilityLabel: String? = nil,
        onAppearRender: ((MinisIcon, MinisIconRenderSource) -> Void)? = nil
    ) {
        self.icon = icon
        self.state = state
        self.size = max(1, size)
        self.accessibilityLabel = accessibilityLabel
        self.onAppearRender = onAppearRender
    }

    /// Controlled native consumers can provide an isolated cache without
    /// replacing the production resource owner or changing the public API.
    init(
        _ icon: MinisIcon,
        state: MinisIconState = .normal,
        size: CGFloat = MinisIconTokens.defaultSize,
        accessibilityLabel: String? = nil,
        cache: MinisIconLayerCache,
        onAppearRender: ((MinisIcon, MinisIconRenderSource) -> Void)? = nil
    ) {
        self.init(icon, state: state, size: size,
                  accessibilityLabel: accessibilityLabel, onAppearRender: onAppearRender)
        self.layerCache = cache
    }

    public var body: some View {
        // Body reads only owned memory. In particular it must not initialize a
        // Bundle or ask NSImage to open a URL while drawing the first frame.
        let cache = layerCache ?? .shared
        let display = Self.displaySelection(
            for: icon, ownedIcon: loadedIcon, ownedLayers: loadedLayers, cache: cache
        )
        let layers = display.layers
        let renderSource = display.source
        // A stable container owns appearance and loading across fallback-to-PNG updates.
        return ZStack {
            if let layers {
                ZStack {
                    layers.secondary
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(renderedSecondaryStyle)
                        .opacity(foregroundPaletteSecondaryOpacity)
                    layers.primary
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(renderedPrimaryStyle)
                }
            } else {
                Image(systemName: icon.fallbackSystemName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(renderedPrimaryStyle)
            }
        }
            // Keep every semantic icon in a bounded canvas so host controls
            // cannot stretch the raster or let it crowd adjacent labels.
            .frame(width: size, height: size)
            .fixedSize(horizontal: true, vertical: true)
            .clipped()
            // The two raster layers are one icon: expose a single element so a
            // screen reader announces the label once, not once per layer.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? "")
            .accessibilityHidden(accessibilityLabel == nil)
            .accessibilityAddTraits(.isImage)
            // Keep the original appearance observation honest: a pending
            // first frame really displays fallback and is reported as such.
            .onAppear {
                renderObservation?.onAppear(icon: icon, source: renderSource,
                                            instanceID: renderInstanceID)
                onAppearRender?(icon, renderSource)
            }
            .task(id: icon) {
                await Self.prepareLayers(for: icon, cache: cache) { layers in
                    loadedLayers = layers
                    loadedIcon = icon
                }
            }
    }

    static func displaySelection(
        for icon: MinisIcon,
        ownedIcon: MinisIcon?,
        ownedLayers: MinisIconLayerCache.Layers?,
        cache: MinisIconLayerCache = .shared
    ) -> (layers: MinisIconLayerCache.Layers?, source: MinisIconRenderSource) {
        // Same-mount state and the shared success cache are main-actor memory.
        // A remount can draw already loaded pixels before its .task runs;
        // failed/unknown entries cannot trigger a read from this selection.
        let layers = (ownedIcon == icon ? ownedLayers : nil) ?? cache.cachedLayers(for: icon)
        return (layers, layers == nil ? .fallback(systemName: icon.fallbackSystemName) : .keyline)
    }

    static func prepareLayers(
        for icon: MinisIcon,
        cache: MinisIconLayerCache = .shared,
        publish: @MainActor (MinisIconLayerCache.Layers?) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let layers = await cache.layers(for: icon)
        // SwiftUI cancels this task when its icon or mounted view retires. A
        // shared resource worker can finish for other consumers, but an old
        // view must never publish that late result into its replacement.
        guard !Task.isCancelled else { return }
        publish(layers)
    }

    nonisolated private static let resourceReadQueue = DispatchQueue(
        label: "com.miniscanvas.icon-resource-read", qos: .utility
    )

    nonisolated static func readLayerBytes(
        for icon: MinisIcon,
        resourceReader: @escaping @Sendable (MinisIcon) -> MinisIconLayerBytes? = bundledBytes
    ) async -> MinisIconLayerBytes? {
        // Filesystem calls can stall indefinitely. A dedicated serial queue
        // bounds blocking I/O to one thread instead of occupying Swift's
        // cooperative executor with one detached task for every visible icon.
        await withCheckedContinuation { continuation in
            resourceReadQueue.async {
                let bytes = autoreleasepool { resourceReader(icon) }
                continuation.resume(returning: bytes)
            }
        }
    }

    nonisolated private static func bundledBytes(for icon: MinisIcon) -> MinisIconLayerBytes? {
        guard let bundle = resourceBundle else { return nil }
        let subdirectory = "KeylineIcons/Raster"
        guard let primaryURL = bundle.url(
            forResource: "\(icon.assetName)-primary", withExtension: "png",
            subdirectory: subdirectory
        ), let secondaryURL = bundle.url(
            forResource: "\(icon.assetName)-secondary", withExtension: "png",
            subdirectory: subdirectory
        ), let primary = try? Data(contentsOf: primaryURL),
           let secondary = try? Data(contentsOf: secondaryURL)
        else { return nil }
        return MinisIconLayerBytes(primary: primary, secondary: secondary)
    }

    /// Raster layers are 96 px at 72 dpi, so an untouched NSImage claims to be
    /// 96 pt. SwiftUI views ignore that (they resize to `size`), but a default
    /// `Menu` / `Picker` label or menu item hands the NSImage to AppKit, which
    /// draws it at its own size and produces a huge black glyph. Give every
    /// loaded layer a standard menu point size so any AppKit host draws it
    /// normally; pixel data is unchanged, so SwiftUI rendering is unaffected.
    nonisolated static let appKitPointSize: CGFloat = 16

    nonisolated static func menuSafe(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: appKitPointSize, height: appKitPointSize)
        image.isTemplate = true
        return image
    }

    static func bundledLayers(
        for icon: MinisIcon,
        bundle: Bundle
    ) -> (primary: Image, secondary: Image)? {
        let subdirectory = "KeylineIcons/Raster"
        guard let primaryURL = bundle.url(
                  forResource: "\(icon.assetName)-primary",
                  withExtension: "png",
                  subdirectory: subdirectory
              ),
              let secondaryURL = bundle.url(
                  forResource: "\(icon.assetName)-secondary",
                  withExtension: "png",
                  subdirectory: subdirectory
              ),
              let primary = NSImage(contentsOf: primaryURL).map(menuSafe),
              let secondary = NSImage(contentsOf: secondaryURL).map(menuSafe)
        else {
            return nil
        }
        return (Image(nsImage: primary), Image(nsImage: secondary))
    }

    nonisolated static func resolveResourceBundle(
        mainBundleURL: URL,
        mainResourceURL: URL?,
        moduleBundle: () -> Bundle
    ) -> Bundle? {
        MinisCanvasResourceBundle.resolve(
            mainBundleURL: mainBundleURL,
            mainResourceURL: mainResourceURL,
            moduleBundle: moduleBundle
        )?.bundle
    }

    public static func renderSource(
        for icon: MinisIcon,
        bundle: Bundle
    ) -> MinisIconRenderSource {
        bundledLayers(for: icon, bundle: bundle) == nil
            ? .fallback(systemName: icon.fallbackSystemName)
            : .keyline
    }

    public static func renderSource(for icon: MinisIcon) -> MinisIconRenderSource {
        guard let resourceBundle else {
            return .fallback(systemName: icon.fallbackSystemName)
        }
        return renderSource(for: icon, bundle: resourceBundle)
    }
}

/// Only immutable PNG bytes cross the worker boundary. AppKit images and
/// SwiftUI layers are created and retained by their main-actor owner.
struct MinisIconLayerBytes: Sendable {
    let primary: Data
    let secondary: Data
}

@MainActor
final class MinisIconLayerCache {
    typealias Layers = (primary: Image, secondary: Image)
    typealias Reader = @Sendable (MinisIcon) async -> MinisIconLayerBytes?
    static let shared = MinisIconLayerCache()
    nonisolated static let nativeBytes = MinisIconNativeLayerBytes()

    // The closed semantic catalog bounds this cache to 75 entries. There is
    // one worker per icon, shared across mounts; no filesystem lock is held
    // on the main actor and cancellation of one mount cannot retire another.
    private var cached: [MinisIcon: Layers] = [:]
    private var inFlight: [MinisIcon: Task<Void, Never>] = [:]
    private let readBytes: Reader

    init(readBytes: @escaping Reader = { await MinisIconView.readLayerBytes(for: $0) }) {
        self.readBytes = readBytes
    }

    func cachedLayers(for icon: MinisIcon) -> Layers? {
        cached[icon]
    }

    func layers(for icon: MinisIcon) async -> Layers? {
        if let layers = cached[icon] { return layers }
        if let worker = inFlight[icon] {
            await worker.value
            return cached[icon]
        }
        let worker = Task { @MainActor [self] in
            let bytes = await readBytes(icon)
            if let bytes,
               let primary = NSImage(data: bytes.primary).map(MinisIconView.menuSafe),
               let secondary = NSImage(data: bytes.secondary).map(MinisIconView.menuSafe) {
                cached[icon] = (Image(nsImage: primary), Image(nsImage: secondary))
                Self.nativeBytes.store(bytes, for: icon)
            }
            // Failed reads are not retained: a later mount may recover after
            // a temporary resource-filesystem error. Redraws do not retry.
            inFlight[icon] = nil
        }
        inFlight[icon] = worker
        await worker.value
        return cached[icon]
    }
}

/// The existing icon worker publishes the same immutable bytes to synchronous
/// native transcript preparation. No resource I/O occurs during layout/drawing.
final class MinisIconNativeLayerBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MinisIcon: MinisIconLayerBytes] = [:]
    private var revision: UInt64 = 0

    func store(_ bytes: MinisIconLayerBytes, for icon: MinisIcon) {
        lock.lock()
        defer { lock.unlock() }
        values[icon] = bytes
        revision &+= 1
    }

    func snapshot() -> (revision: UInt64, values: [MinisIcon: MinisIconLayerBytes]) {
        lock.lock()
        defer { lock.unlock() }
        return (revision, values)
    }
}
