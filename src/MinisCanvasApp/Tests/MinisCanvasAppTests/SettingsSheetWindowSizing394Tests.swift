import AppKit
import Testing
@testable import MinisCanvasApp

// Native AppKit fixtures: requires explicit sole-UI + heavy admission to run.
// setContentSize verifies native sizing, not actual user mouse-drag acceptance.
@Suite("D-SETTINGS-17 native settings sheet sizing 394", .serialized)
@MainActor
struct SettingsSheetWindowSizing394Tests {
    private final class DelegateWitness: NSObject, NSWindowDelegate {}

    @MainActor
    private final class Fixture {
        let parent: NSWindow
        let sheet: NSWindow
        let delegate = DelegateWitness()
        let accessor = WindowAccessor.AccessorView()
        let sizing = SettingsSheetWindowSizing()

        init(parentWidth: CGFloat = 960, beginsSheet: Bool = true) {
            _ = NSApplication.shared
            parent = NSWindow(contentRect: NSRect(x: 80, y: 80, width: parentWidth, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            sheet.isReleasedWhenClosed = false
            sheet.delegate = delegate
            sheet.contentMaxSize = NSSize(width: 720, height: 520)
            accessor.sheetSizing = sizing
            sheet.contentView = accessor
            if beginsSheet {
                parent.beginSheet(sheet, completionHandler: nil)
            }
        }

        func dispose() {
            accessor.sheetSizing?.bind(to: nil)
            if sheet.sheetParent === parent {
                parent.endSheet(sheet)
            }
            sheet.orderOut(nil)
            sheet.close()
            parent.close()
        }
    }

    @Test
    func attachedNativeSheetReceivesBothAxisLimitsWithoutDelegateReplacement() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        // Assigning contentView invokes the real attachment callback before
        // beginSheet; allow its single deferred sheetParent check to complete.
        await Task.yield()
        #expect(fixture.sheet.sheetParent === fixture.parent)
        #expect(fixture.sheet.styleMask.contains(.resizable))
        #expect(fixture.sheet.styleMask.contains(.closable))
        #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
        #expect(fixture.sheet.contentMaxSize.width > 1100)
        #expect(fixture.sheet.contentMaxSize.height > 800)
        #expect(fixture.sheet.delegate === fixture.delegate)
        #expect(fixture.accessor.edgeClamp == nil)
    }

    @Test
    func nativeTwoAxisGrowthAndRepeatedBindingKeepTheChosenSize() {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.accessor.viewDidMoveToWindow()
        fixture.sheet.setContentSize(NSSize(width: 1040, height: 520))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 1040, height: 520))
        fixture.sheet.setContentSize(NSSize(width: 1040, height: 760))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 1040, height: 760))
        let grownFrame = fixture.sheet.frame
        for _ in 0..<5 { fixture.sizing.bind(to: fixture.sheet) }
        #expect(fixture.sheet.frame == grownFrame)
        #expect(fixture.sheet.delegate === fixture.delegate)
        fixture.sheet.setContentSize(SettingsSheetWindowSizing.minimumContentSize)
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 600, height: 520))
    }

    @Test
    func originalContractWidthMatrixAndBelowMinimumRequestKeepActualContentBounds2911() async {
        let fixture = Fixture(parentWidth: 1_600)
        defer { fixture.dispose() }
        await Task.yield()
        #expect(fixture.sheet.sheetParent === fixture.parent)

        // Test native content points, not screenshot pixels. The original
        // contract is 600...1600pt; a 500pt request must not lower its minimum.
        for width in [CGFloat(600), 800, 1_000, 1_280, 1_600, 600] {
            fixture.sheet.setContentSize(NSSize(width: width, height: 636))
            let actual = fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size
            #expect(actual == NSSize(width: width, height: 636))
            for _ in 0..<3 { fixture.sizing.bind(to: fixture.sheet) }
            #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == actual)
        }
        fixture.sheet.setContentSize(NSSize(width: 500, height: 68))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 600, height: 520))
        #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
        #expect(fixture.sheet.contentMaxSize.width >= 1_600)
        #expect(fixture.sheet.delegate === fixture.delegate)
    }

    @Test
    func liveResizeReappliesBothConstraintsBeforeSameWindowExpansion2911() async {
        let fixture = Fixture(parentWidth: 1_600)
        defer { fixture.dispose() }
        await Task.yield()
        let windowNumber = fixture.sheet.windowNumber
        fixture.sheet.contentMinSize = .zero
        fixture.sheet.contentMaxSize = NSSize(width: 720, height: 520)
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: fixture.sheet
        )
        #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
        #expect(fixture.sheet.contentMaxSize.width >= 1_600)
        #expect(fixture.sheet.contentMaxSize.height >= 760)
        fixture.sheet.setContentSize(NSSize(width: 1_600, height: 760))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 1_600, height: 760))
        #expect(fixture.sheet.windowNumber == windowNumber)
        #expect(fixture.sheet.delegate === fixture.delegate)
    }

    @Test
    func sixHundredPointParentCapsSheetAndTracksParentResizes() async {
        let fixture = Fixture(parentWidth: 600)
        defer { fixture.dispose() }
        await Task.yield()
        #expect(fixture.sheet.sheetParent === fixture.parent)
        #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
        #expect(fixture.sheet.contentMaxSize.width == 600)
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).width <= 600)

        fixture.parent.setContentSize(NSSize(width: 700, height: 640))
        #expect(fixture.sheet.contentMaxSize.width == 700)
        fixture.sheet.setContentSize(NSSize(width: 700, height: 520))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).width == 700)

        fixture.parent.setContentSize(NSSize(width: 600, height: 640))
        #expect(fixture.sheet.contentMaxSize.width == 600)
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).width <= 600)
    }

    @Test
    func lateSheetAttachmentAndRepeatedShrinkRestoreNativeMinimum() async {
        let fixture = Fixture(beginsSheet: false)
        defer { fixture.dispose() }
        // Exercise the production race: the background accessor can bind while
        // this window is not yet an AppKit sheet, and its deferred retry ends.
        await Task.yield()
        #expect(fixture.sheet.sheetParent == nil)
        fixture.parent.beginSheet(fixture.sheet, completionHandler: nil)
        #expect(fixture.sheet.sheetParent === fixture.parent)

        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: fixture.sheet
        )
        #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
        fixture.sheet.setContentSize(NSSize(width: 766, height: 636))
        #expect(fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size == NSSize(width: 766, height: 636))

        // A hosting update can replace the native constraint after expansion.
        // The real NSWindow resize notification must restore it and the size.
        for _ in 0..<2 {
            fixture.sheet.contentMinSize = .zero
            fixture.sheet.setContentSize(NSSize(width: 188, height: 68))
            #expect(fixture.sheet.contentMinSize == NSSize(width: 600, height: 520))
            let actual = fixture.sheet.contentRect(forFrameRect: fixture.sheet.frame).size
            #expect(actual.width >= 600)
            #expect(actual.height >= 520)
        }
        #expect(fixture.sheet.delegate === fixture.delegate)
    }

    @Test
    func ordinaryMainWindowAndAnotherWindowRemainUnmodified() {
        let fixture = Fixture()
        defer { fixture.dispose() }
        WindowEdgeClamp.applyMinimumContentSize(to: fixture.parent)
        fixture.parent.delegate = fixture.delegate
        let style = fixture.parent.styleMask
        let minimum = fixture.parent.contentMinSize
        let minimumFrame = fixture.parent.minSize
        let maximum = fixture.parent.contentMaxSize
        let frame = fixture.parent.frame
        let accidentalMainBinding = SettingsSheetWindowSizing()
        accidentalMainBinding.bind(to: fixture.parent)
        fixture.accessor.viewDidMoveToWindow()
        #expect(fixture.parent.styleMask == style)
        #expect(fixture.parent.contentMinSize == minimum)
        #expect(fixture.parent.contentMaxSize == maximum)
        #expect(fixture.parent.minSize == minimumFrame)
        #expect(fixture.parent.frame == frame)
        #expect(fixture.parent.delegate === fixture.delegate)
    }

    @Test
    func keyNotificationAfterDetachCannotReapplyToTheOldSheet() {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.accessor.viewDidMoveToWindow()
        fixture.sizing.bind(to: nil)
        fixture.sheet.styleMask.remove(.resizable)
        fixture.sheet.contentMinSize = .zero
        fixture.sheet.contentMaxSize = NSSize(width: 720, height: 520)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.sheet)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: fixture.sheet)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: fixture.sheet)
        #expect(!fixture.sheet.styleMask.contains(.resizable))
        #expect(fixture.sheet.contentMinSize == .zero)
        #expect(fixture.sheet.contentMaxSize == NSSize(width: 720, height: 520))
    }
}
