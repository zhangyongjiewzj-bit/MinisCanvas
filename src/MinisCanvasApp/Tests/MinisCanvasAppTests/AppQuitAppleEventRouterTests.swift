import AppKit
import Carbon
import Testing
@testable import MinisCanvasApp

@Suite("D-APP-12 AppleEvent Quit routing")
@MainActor
struct AppQuitAppleEventRouterTests {
    @Test func dockAndExternalQuitWithoutSystemReasonUseUserCoordinator() {
        var userQuits = 0
        var systemQuits = 0
        let router = AppQuitAppleEventRouter(onUserQuit: { userQuits += 1 },
                                            onSystemQuit: { systemQuits += 1 })
        router.route(reason: nil)
        router.route(reason: 0)
        #expect(userQuits == 2 && systemQuits == 0)
    }

    @Test func shutdownRestartAndLogoutDoNotEnterPresentationWait() {
        var userQuits = 0
        var systemQuits = 0
        let router = AppQuitAppleEventRouter(onUserQuit: { userQuits += 1 },
                                            onSystemQuit: { systemQuits += 1 })
        for reason in [OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart),
                       OSType(kAEReallyLogOut), OSType(kAELogOut)] {
            router.route(reason: reason)
        }
        #expect(userQuits == 0 && systemQuits == 5)
    }

    @Test func actualQuitReasonParameterKeepsItsDocumentedSystemMeaning() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)),
                       forKeyword: AEKeyword(kAEQuitReason))
        #expect(AppQuitAppleEventRouter.quitReason(in: event) == OSType(kAEShutDown))
    }
}
