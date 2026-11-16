import AppKit
import Foundation
import SwiftUI
import Testing
import MinisCore

@testable import MinisCanvasApp

@Suite("Settings public identity badges at narrow widths", .serialized)
@MainActor
struct SettingsIdentityHeader1030Tests {
    struct Scenario: Sendable {
        let windowWidth: CGFloat
        let fontSize: Int
        let provider: Bool
    }

    nonisolated static let scenarios: [Scenario] = [CGFloat(600), 720, 800, 1_600].flatMap { width in
        [16, 20].flatMap { font in
            [true, false].map { Scenario(windowWidth: width, fontSize: font, provider: $0) }
        }
    }

    private func measured<V: View>(_ view: V, width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
        // Only owned offscreen AppKit objects. No NSWindow, activation, AX or
        // screen input; the ordinary UI replay remains a separate package gate.
        return controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    @ViewBuilder
    private func publicBadges(_ scenario: Scenario, font: Font) -> some View {
        HStack(spacing: 6) {
            if scenario.provider {
                Text(ProviderWireProtocol.openaiCompatible.displayName)
                    .font(font)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
            }
            Text("secret")
                .font(font)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
            if !scenario.provider {
                Text("OpenAI")
                    .font(font)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @Test("Production identity header preserves the full name and complete single-line public badges",
          arguments: scenarios)
    func completePublicHeaderFitsWithoutVerticalBadgeCollapse(_ scenario: Scenario) throws {
        let metrics = SettingsLayoutMetrics.forWidth(scenario.windowWidth)
        let contentWidth = scenario.windowWidth - metrics.sidebarWidth - 2 * metrics.contentGutter
        let detailWidth = contentWidth - (metrics.environmentRowLayout == .inline
            ? metrics.environmentActionColumnWidth + 10 : 0)
        let tokens = TypographyTokenSet.forBaseFontSize(scenario.fontSize)
        let nameFont = Font.system(size: CGFloat(tokens.monospaced), design: .monospaced)
        let badgeFont = Font.system(size: CGFloat(tokens.caption2))
        let name = scenario.provider ? "TASK0744_SYNTHETIC_API_KEY" : "SETTINGS1030_SYNTHETIC_API_KEY"
        let badges = publicBadges(scenario, font: badgeFont)
        let badgeSize = measured(badges, width: detailWidth)
        let fullName = Text(name).font(nameFont).fontWeight(.medium)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        let nameSize = measured(fullName, width: detailWidth)
        let actual = measured(SettingsEnvironmentIdentityHeader(name: name, nameFont: nameFont) {
            badges
        }, width: detailWidth)

        #expect(detailWidth > 0)
        #expect(badgeSize.width <= detailWidth)
        #expect(badgeSize.height > 0)
        #expect(actual.width <= detailWidth + 0.5)
        #expect(actual.height.isFinite && actual.height > 0)
        // A vertical one-character badge can be many line-heights tall. The
        // real production header must instead fit either the complete inline
        // identity or all name lines followed by one intact badge row.
        #expect(actual.height <= nameSize.height + 4 + badgeSize.height + 0.5)
        #expect(actual.height >= max(nameSize.height, badgeSize.height) - 0.5)

        let intrinsicName = measured(fullName.fixedSize(horizontal: true, vertical: false), width: 10_000)
        if intrinsicName.width + 6 + badgeSize.width <= detailWidth {
            #expect(abs(actual.height - max(intrinsicName.height, badgeSize.height)) <= 0.5)
        } else {
            #expect(actual.height >= nameSize.height + 4 + badgeSize.height - 0.5)
        }
    }
}
