import AppKit
import Foundation
import MinisCore
import SwiftUI
import Testing
@testable import MinisCanvasApp

@Suite("L2 chat surface allocated width")
struct ChatSurfaceAllocatedWidthL2Tests {
    @Test(arguments: [600.0, 800, 1_000, 1_280, 1_600], [0, 1, 2, 3])
    func chatMinimumFitsTheProductionSplitBudget(windowWidth: Double, collapsedPanels: Int) {
        let decision = AdaptiveLayoutPolicy.decision(
            for: windowWidth, preferredLeftWidth: 900, preferredRightWidth: 900
        )
        let leftRequest = decision.leftPanel == .overlay || collapsedPanels & 1 != 0
            ? 0 : decision.leftWidth
        let rightRequest = decision.rightPanel == .overlay || collapsedPanels & 2 != 0
            ? 0 : decision.rightWidth
        let left = DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: windowWidth, requestedSidebarWidth: leftRequest,
            mainMinimumWidth: decision.mainMinimumWidth + rightRequest
        )
        let right = DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: windowWidth - left, requestedSidebarWidth: rightRequest,
            mainMinimumWidth: decision.mainMinimumWidth
        )
        let chatWidth = windowWidth - left - right
        let metrics = ChatSurfaceLayoutMetrics.forWidth(chatWidth)
        #expect(chatWidth >= decision.mainMinimumWidth)
        #expect(metrics.minimumContentWidth > 0)
        #expect(metrics.minimumContentWidth <= chatWidth)
        #expect(metrics.minimumContentWidth <= AdaptiveLayoutPolicy.minimumSupportedWidth)
    }

    @Test(arguments: [CGFloat(0), -1, .nan, .infinity, -.infinity])
    func unmeasuredOrInvalidWidthRetainsInitialContract(width: CGFloat) {
        let metrics = ChatSurfaceLayoutMetrics.forWidth(width)
        #expect(metrics.widthClass == .compact)
        #expect(metrics.surfaceGutter == 0)
        #expect(metrics.minimumContentWidth == 600)
        #expect(metrics.minimumContentWidth.isFinite)
    }

    @Test(arguments: [CGFloat(600), 800, 1_000, 1_280, 1_600])
    func fullWindowMinimumRemainsSixHundred(width: CGFloat) {
        #expect(ChatSurfaceLayoutMetrics.forWidth(width).minimumContentWidth == 600)
    }
}

/// Requires the approved native NSApplication.run host and an exclusive UI lease.
/// This mounts the production chat/transcript/Composer child, not a metrics copy.
@Suite("L2 native chat child stays within allocated pane", .serialized)
@MainActor
struct ChatSurfaceAllocatedWidthNativeL2Tests {
    @Test(arguments: [CGFloat(560), 579, 600], [CGFloat(12), 20])
    func productionChatAndComposerDoNotWidenTheAllocatedPane(
        allocatedWidth: CGFloat, fontSize: CGFloat
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "L2-Chat-Allocated-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 20)
        )
        center.uiBaseFontSize = Int(fontSize)
        let provider = TypographyTokenProvider(center: center)
        #expect(provider.composerBodySize == fontSize)
        let bridge = BridgeStore(agentTaskStore: AgentTaskStore())
        let root = ContentView(bridge: bridge).chatSurfaceInstrumentationView()
            .environment(\.typographyTokens, provider)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let lease = NativeTestHostLifecycle.begin("L2-Chat-Allocated")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: allocatedWidth, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: allocatedWidth, height: 620))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        for _ in 0..<30 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.display()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        NativeTestHostLifecycle.observe(window, phase: "sampled")
        let content = try #require(window.contentView)
        let allocatedFrame = window.convertToScreen(content.convert(content.bounds, to: nil))
        #expect(abs(allocatedFrame.width - allocatedWidth) <= 1)
        for identifier in ["chat.surface", "chat.composer"] {
            let element = try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier))
            let frame = try #require(NativeConsumerOwnedAX.frame(element))
            print("L2_CHAT_CHILD width=\(allocatedWidth) font=\(fontSize) id=\(identifier) allocated=\(allocatedFrame) actual=\(frame)")
            #expect(!frame.isEmpty)
            #expect(frame.minX >= allocatedFrame.minX - 1)
            #expect(frame.maxX <= allocatedFrame.maxX + 1)
            #expect(frame.width <= allocatedWidth + 1)
        }
    }
}
