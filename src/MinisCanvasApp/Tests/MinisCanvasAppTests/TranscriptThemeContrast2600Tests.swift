import AppKit
import Testing
import MinisCore
@testable import MinisCanvasApp

// Actual ChatTranscriptView forwards provider.aj38 to its document cache.
// Its NSTextView and scroll view are transparent; ChatSidebar's face is
// palette.backgroundPrimary. These tests consume returned attributed runs and
// their real shared NSTextBlock fill, without constructing a View or NSWindow.
@Suite("2600 production transcript semantic contrast", .serialized)
@MainActor
struct TranscriptThemeContrast2600Tests {
    enum Configuration: String, CaseIterable, Sendable {
        case productAqua, productDarkAqua, systemAqua, systemDarkAqua
        var preset: ThemePreset { self == .productAqua || self == .productDarkAqua ? .light : .system }
        var appearanceName: NSAppearance.Name { self == .productDarkAqua || self == .systemDarkAqua ? .darkAqua : .aqua }
    }
    private func makeCenter() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "transcript2600", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "transcript2600-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: suite))
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
    }

    private func opaque(_ color: NSColor, over background: ThemeColor) throws -> ThemeColor {
        let rgb = try #require(color.usingColorSpace(.sRGB))
        let alpha = Double(rgb.alphaComponent)
        return ThemeColor(r: Double(rgb.redComponent) * alpha + background.r * (1 - alpha),
                          g: Double(rgb.greenComponent) * alpha + background.g * (1 - alpha),
                          b: Double(rgb.blueComponent) * alpha + background.b * (1 - alpha))
    }

    private func evaluate(_ document: NSAttributedString, at location: Int,
                          role: ThemeContrastRole, palette: Aj38Palette) throws -> ThemeContrastEvaluation {
        let attributes = document.attributes(at: location, effectiveRange: nil)
        let style = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        let block = try #require(style.textBlocks.last)
        let fill = try #require(block.backgroundColor)
        var background = try opaque(fill, over: palette.backgroundPrimary)
        if let glyphBackground = attributes[.backgroundColor] as? NSColor {
            background = try opaque(glyphBackground, over: background)
        }
        let foreground = try #require(attributes[.foregroundColor] as? NSColor)
        let resolvedForeground = try opaque(foreground, over: background)
        print("TRANSCRIPT2600_PAIR role=\(role.rawValue) foreground=\(resolvedForeground) background=\(background)")
        return ThemeContrast.evaluate(role: role, foreground: resolvedForeground, background: background)
    }

    private func withPalette(_ configuration: Configuration,
                             _ body: (Aj38Palette) throws -> Void) throws {
        let center = try makeCenter()
        center.themePreset = configuration.preset
        let provider = ThemeTokenProvider(center: center)
        let appearance = try #require(NSAppearance(named: configuration.appearanceName))
        provider.updateSystemAppearance(appearance)
        var failure: (any Error)?
        appearance.performAsCurrentDrawingAppearance {
            do { try body(provider.aj38) } catch { failure = error }
        }
        if let failure { throw failure }
        #expect(center.themePreset == configuration.preset)
        #expect(ThemePresetCatalogPickerGate.selectableThemePresets == [.light, .system])
    }

    @Test(arguments: Configuration.allCases)
    func actualRoleHeaderAndBodyMatrix(configuration: Configuration) throws {
        try withPalette(configuration) { palette in
            for role: ChatRole in [.user, .assistant, .tool, .system] {
                let message = ChatMessageUI(role: role, content: "生产正文")
                let document = ChatTranscriptFormatter.formattedDocument([message], palette: palette).attributedString
                let header = try evaluate(document, at: 0, role: .secondary, palette: palette)
                let bodyRange = try #require(document.string.range(of: "生产正文"))
                let body = try evaluate(document, at: NSRange(bodyRange, in: document.string).location, role: .body, palette: palette)
                print("TRANSCRIPT2600 \(configuration.rawValue) \(role) header=\(header.ratio) body=\(body.ratio) gate=4.5")
                #expect(header.passes)
                #expect(body.passes)
                #expect(document.string.contains("生产正文"))
                #expect(ChatTranscriptFormatter.plainText([message]).contains("生产正文"))
            }
        }
    }

    @Test(arguments: Configuration.allCases)
    func actualStreamingStatusTextMatrix(configuration: Configuration) async throws {
        await ChatTranscriptStatusIconProjection.preload()
        try withPalette(configuration) { palette in
            let message = ChatMessageUI(role: .assistant, content: "", isStreaming: true)
            let document = ChatTranscriptFormatter.formattedDocument([message], palette: palette).attributedString
            let location = try #require(document.string.range(of: "生成中…")).lowerBound
            let result = try evaluate(document, at: NSRange(location..<document.string.endIndex, in: document.string).location, role: .secondary, palette: palette)
            print("TRANSCRIPT2600 \(configuration.rawValue) streaming=\(result.ratio) gate=4.5")
            #expect(result.passes)
            #expect(document.string == "助手\n\u{FFFC} 生成中…")
            let attachment = try #require(document.attribute(.attachment, at: 3, effectiveRange: nil) as? NSTextAttachment)
            let image = try #require(attachment.image)
            #expect(image.size.width >= 12 && image.size.height >= 12)
            #expect(ChatTranscriptFormatter.plainText([message]) == "【助手】")
            #expect(ChatTranscriptFormatter.accessibilityText([message]) == "助手：生成中…")
        }
    }

    @Test(arguments: Configuration.allCases)
    func actualMarkdownBodyAndAuxiliaryRuns(configuration: Configuration) throws {
        try withPalette(configuration) { palette in
            let message = ChatMessageUI(role: .assistant, content: "正文\n\n> 引用辅助\n\n```swift\nlet answer = 42\n```")
            let document = ChatTranscriptFormatter.formattedDocument([message], palette: palette).attributedString
            for (text, role): (String, ThemeContrastRole) in [("正文", .body), ("引用辅助", .secondary), ("swift", .secondary), ("let answer", .body)] {
                let range = try #require(document.string.range(of: text))
                let result = try evaluate(document, at: NSRange(range, in: document.string).location, role: role, palette: palette)
                print("TRANSCRIPT2600 \(configuration.rawValue) markdown \(text)=\(result.ratio) gate=\(role.minimumRatio)")
                #expect(result.passes)
            }
        }
    }
}
