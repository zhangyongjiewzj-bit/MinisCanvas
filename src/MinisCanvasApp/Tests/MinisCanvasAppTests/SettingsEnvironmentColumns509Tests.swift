import AppKit
import Darwin
import ApplicationServices
import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SETTINGS-18 production environment columns and native actions", .serialized)
@MainActor
struct SettingsEnvironmentColumns509Tests {
    private let providerName = "OWNED509_PROVIDER_" + String(repeating: "P", count: 36)
    private let variableName = "OWNED509_VARIABLE_" + String(repeating: "V", count: 36)

    private struct FixtureFailure: Error {
        let stage: String
        let code: Int32
    }
    private struct FixtureFailures: Error {
        let business: Error?
        let cleanup: [Error]
    }

    /// Pins the actual FileManager temporary parent and an immediately fresh
    /// UUID child. The formal contract supplies the expected uid/device; no
    /// environment string is accepted as the child's observed identity.
    private struct OwnedRoot {
        let url: URL
        let parentURL: URL
        let name: String
        let parentFD: Int32
        let rootFD: Int32
        let parentIdentity: stat
        let identity: stat
        let formal: FormalTestIsolationPaths

        static func make() throws -> OwnedRoot {
            guard let formal = try FormalTestIsolationPaths.resolveCurrentProcess() else {
                throw FixtureFailure(stage: "formal profile missing", code: EINVAL)
            }
            let parentURL = FileManager.default.temporaryDirectory
                .standardizedFileURL.resolvingSymlinksInPath()
            let parentFD = parentURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard parentFD >= 0 else { throw FixtureFailure(stage: "open actualFM", code: errno) }
            var parentIdentity = stat()
            guard fstat(parentFD, &parentIdentity) == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "stat actualFM", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "stat actualFM", code: code)
            }
            guard parentIdentity.st_mode & S_IFMT == S_IFDIR,
                  parentIdentity.st_mode & 0o7777 == 0o700,
                  parentIdentity.st_uid == geteuid(), parentIdentity.st_uid == formal.rootOwner,
                  UInt64(parentIdentity.st_dev) == formal.rootDevice else {
                let error = FixtureFailure(stage: "actualFM parent uid/device/700", code: ESTALE)
                guard Darwin.close(parentFD) == 0 else {
                    throw FixtureFailures(business: error,
                        cleanup: [FixtureFailure(stage: "close invalid actualFM parent", code: errno)])
                }
                throw error
            }
            let name = "settings18-509-\(UUID().uuidString)"
            let created = name.withCString { mkdirat(parentFD, $0, 0o700) }
            guard created == 0 else {
                let code = errno
                let closeResult = Darwin.close(parentFD)
                if closeResult != 0 {
                    throw FixtureFailures(business: FixtureFailure(stage: "mkdir fresh UUID", code: code),
                                          cleanup: [FixtureFailure(stage: "close actualFM", code: errno)])
                }
                throw FixtureFailure(stage: "mkdir fresh UUID", code: code)
            }
            let rootFD = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            var identity = stat()
            guard rootFD >= 0, fstat(rootFD, &identity) == 0 else {
                let code = errno
                var errors: [Error] = []
                // mkdirat just created this still-empty child; unlinkat removes
                // only that directory entry, never follows a replacement link.
                if name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) != 0 {
                    errors.append(FixtureFailure(stage: "remove uninitialized fresh child", code: errno))
                }
                if rootFD >= 0, Darwin.close(rootFD) != 0 {
                    errors.append(FixtureFailure(stage: "close fresh child", code: errno))
                }
                if Darwin.close(parentFD) != 0 {
                    errors.append(FixtureFailure(stage: "close actualFM", code: errno))
                }
                throw FixtureFailures(business: FixtureFailure(stage: "open/stat fresh child", code: code),
                                      cleanup: errors)
            }
            // All later validation is business work under a cleanup owner.
            return OwnedRoot(url: parentURL.appendingPathComponent(name, isDirectory: true),
                             parentURL: parentURL, name: name, parentFD: parentFD, rootFD: rootFD,
                             parentIdentity: parentIdentity, identity: identity, formal: formal)
        }

        func validate() throws {
            var parentNow = stat()
            var childNow = stat()
            var rootNow = stat()
            guard parentURL.path.withCString({ fstatat(AT_FDCWD, $0, &parentNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  parentNow.st_mode & S_IFMT == S_IFDIR,
                  parentNow.st_mode & 0o7777 == 0o700,
                  parentNow.st_dev == parentIdentity.st_dev,
                  parentNow.st_ino == parentIdentity.st_ino,
                  parentNow.st_uid == geteuid(), parentNow.st_uid == formal.rootOwner,
                  UInt64(parentNow.st_dev) == formal.rootDevice,
                  name.withCString({ fstatat(parentFD, $0, &childNow, AT_SYMLINK_NOFOLLOW) }) == 0,
                  fstat(rootFD, &rootNow) == 0,
                  childNow.st_mode & S_IFMT == S_IFDIR,
                  childNow.st_uid == geteuid(), childNow.st_uid == formal.rootOwner,
                  childNow.st_mode & 0o7777 == 0o700,
                  childNow.st_dev == parentNow.st_dev,
                  childNow.st_dev == identity.st_dev, childNow.st_ino == identity.st_ino,
                  rootNow.st_dev == identity.st_dev, rootNow.st_ino == identity.st_ino,
                  childNow.st_ino != parentNow.st_ino,
                  UInt64(childNow.st_ino) != formal.rootInode,
                  url.deletingLastPathComponent().path == parentURL.path,
                  url.standardizedFileURL.resolvingSymlinksInPath().path == url.path else {
                throw FixtureFailure(stage: "freshFM uid/dev/inode/700/nosymlink", code: ESTALE)
            }
        }

        func finish<T>(_ business: Result<T, Error>) throws -> T {
            var errors: [Error] = []
            do {
                try validate()
                try FileManager.default.removeItem(at: url)
                var absent = stat()
                let result = name.withCString {
                    fstatat(parentFD, $0, &absent, AT_SYMLINK_NOFOLLOW)
                }
                guard result == -1, errno == ENOENT else {
                    throw FixtureFailure(stage: "cleanup verify ENOENT", code: errno)
                }
            } catch { errors.append(error) }
            if Darwin.close(rootFD) != 0 {
                errors.append(FixtureFailure(stage: "close fresh child", code: errno))
            }
            if Darwin.close(parentFD) != 0 {
                errors.append(FixtureFailure(stage: "close actualFM", code: errno))
            }
            if !errors.isEmpty {
                switch business {
                case .failure(let error): throw FixtureFailures(business: error, cleanup: errors)
                case .success: throw FixtureFailures(business: nil, cleanup: errors)
                }
            }
            print("SETTINGS509_FIXTURE_CLEANUP root=\(url.path) uid=\(identity.st_uid) dev=\(identity.st_dev) inode=\(identity.st_ino) ENOENT=true")
            return try business.get()
        }
    }

    @MainActor
    private final class Fixture {
        let providerConfigurationDirectory: URL
        let center: SettingsCenter
        let usage: UsageStore
        var windows: [NSWindow] = []
        init(providerConfigurationDirectory: URL, center: SettingsCenter, usage: UsageStore) {
            self.providerConfigurationDirectory = providerConfigurationDirectory
            self.center = center
            self.usage = usage
        }
    }

    private func makeFixture(root: URL, suiteName: String, usageKey: String) throws -> Fixture {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureFailure(stage: "owned preferences suite unavailable", code: EINVAL)
        }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let privacy = EnvVarPrivacyStore(defaults: defaults)
        privacy.unmarkSecret(name: variableName)
        let env = EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain,
                              privacyStore: privacy)
        #expect(env.saveProvider(name: providerName, apiKey: "owned-in-memory509",
            baseURL: "invalid-owned-endpoint-" + String(repeating: "x", count: 120),
            modelNames: ["owned-model-" + String(repeating: "m", count: 100)],
            protocolType: .openaiCompatible))
        #expect(env.setEnvVar(name: variableName, value: String(repeating: "owned plain text ", count: 24),
                             isSecret: false))
        let usage = UsageStore(domain: .suite(suiteName), storageKey: usageKey)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")), envStore: env,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: usage,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        return Fixture(providerConfigurationDirectory: root.appendingPathComponent("providers"),
                       center: center, usage: usage)
    }

    /// The UUID key is proved absent before construction. Cleanup follows
    /// actual UsageStore-tail completion, never just cancellation or timeout.
    private func removeOwnedUsageLock(_ path: String, formal: FormalTestIsolationPaths) throws {
        var identity = stat()
        let result = path.withCString { lstat($0, &identity) }
        if result == -1, errno == ENOENT { return }
        guard result == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_mode & 0o7777 == 0o600,
              identity.st_uid == geteuid(), identity.st_uid == formal.rootOwner,
              UInt64(identity.st_dev) == formal.rootDevice else {
            throw FixtureFailure(stage: "owned Usage lock uid/dev/type/600", code: ESTALE)
        }
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw FixtureFailure(stage: "open owned Usage lock", code: errno) }
        let business = Result<Void, Error> {
            var held = stat()
            var current = stat()
            guard fstat(fd, &held) == 0,
                  path.withCString({ lstat($0, &current) }) == 0,
                  held.st_dev == identity.st_dev, held.st_ino == identity.st_ino,
                  current.st_dev == held.st_dev, current.st_ino == held.st_ino else {
                throw FixtureFailure(stage: "owned Usage lock replaced", code: ESTALE)
            }
            guard path.withCString({ unlink($0) }) == 0 else {
                throw FixtureFailure(stage: "unlink owned Usage lock", code: errno)
            }
            var absent = stat()
            guard path.withCString({ lstat($0, &absent) }) == -1, errno == ENOENT else {
                throw FixtureFailure(stage: "Usage lock ENOENT", code: ESTALE)
            }
        }
        if Darwin.close(fd) != 0 {
            let error = FixtureFailure(stage: "close owned Usage lock", code: errno)
            switch business {
            case .success: throw error
            case .failure(let original): throw FixtureFailures(business: original, cleanup: [error])
            }
        }
        try business.get()
    }

    private func withFixture<T>(_ body: (Fixture) throws -> T) async throws -> T {
        // Public SDK interfaces expose Test.current.id and Case.current's
        // parameterized presence, not a public Case.ID. Actual width identity
        // must still be verified by the frozen runner's raw/event case binding.
        guard let callerTestID = Test.current?.id,
              Test.Case.current?.isParameterized == true,
              withUnsafeCurrentTask(body: { $0 != nil }) else {
            throw FixtureFailure(stage: "missing original Testing test/case/task context", code: EINVAL)
        }
        let contextMatches: () -> Bool = {
            Test.current?.id == callerTestID
                && Test.Case.current?.isParameterized == true
                && withUnsafeCurrentTask { $0 != nil }
        }
        let owned = try OwnedRoot.make()
        let token = UUID().uuidString
        let suiteName = "MinisCanvas.Settings509.Native.\(token)"
        let usageKey = "settings509.\(token)"
        let lockPath = UsageStore.persistenceLockPath(for: usageKey)
        var suiteAdmitted = false
        var lockAdmitted = false
        var fixture: Fixture?
        // This original Environment tab + Edit/Cancel path does not enqueue
        // Usage mutations. Join init's actual self-heal tail before any host.
        var preparationError: Error?
        do {
            try owned.validate()
            guard UserDefaults.standard.persistentDomain(forName: suiteName) == nil else {
                throw FixtureFailure(stage: "fresh preferences suite collision", code: EEXIST)
            }
            suiteAdmitted = true
            var priorLock = stat()
            guard lockPath.withCString({ lstat($0, &priorLock) }) == -1, errno == ENOENT else {
                throw FixtureFailure(stage: "fresh Usage key collision", code: EEXIST)
            }
            lockAdmitted = true
            print("SETTINGS509_FIXTURE root=\(owned.url.path) uid=\(owned.identity.st_uid) dev=\(owned.identity.st_dev) inode=\(owned.identity.st_ino) mode=700 nosymlink=true")
            let created = try makeFixture(root: owned.url, suiteName: suiteName, usageKey: usageKey)
            fixture = created
            let clock = ContinuousClock()
            let began = clock.now
            let joined = await created.usage.waitForPersistence()
            let withinBudget = began.duration(to: clock.now) <= .seconds(5)
            print("SETTINGS509_USAGE_JOIN phase=before-native-body actualFinished=true success=\(joined) within5s=\(withinBudget)")
            guard joined && withinBudget else {
                throw FixtureFailure(stage: "Usage actual join/persistence/5s budget", code: EIO)
            }
        } catch { preparationError = error }
        // Called synchronously: no post-close suspension and no new Task bridge.
        // Also handles callback-delivery refusal, when no native body ran.
        let finishOwned: (Result<T, Error>) throws -> T = { business in
            var cleanupErrors: [Error] = []
            var nativeStillActive = false
            if let fixture {
                for window in fixture.windows {
                    if window.isVisible || !window.sheets.isEmpty || window.contentViewController != nil {
                        close(window)
                    }
                    if window.isVisible || !window.sheets.isEmpty || window.contentViewController != nil {
                        nativeStillActive = true
                        cleanupErrors.append(FixtureFailure(stage: "owned native window not closed", code: EBUSY))
                    }
                }
            }
            if nativeStillActive {
                // Never delete a root still reachable by an owned native view.
                // Preserve it for this failed run's owner instead of claiming ENOENT.
                if Darwin.close(owned.rootFD) != 0 {
                    cleanupErrors.append(FixtureFailure(stage: "close retained root FD", code: errno))
                }
                if Darwin.close(owned.parentFD) != 0 {
                    cleanupErrors.append(FixtureFailure(stage: "close retained parent FD", code: errno))
                }
                print("SETTINGS509_CLEANUP_REFUSED nativeStillActive=true root=\(owned.url.path) ENOENT=false")
                switch business {
                case .success: throw FixtureFailures(business: nil, cleanup: cleanupErrors)
                case .failure(let error): throw FixtureFailures(business: error, cleanup: cleanupErrors)
                }
            }
            if lockAdmitted {
                do { try removeOwnedUsageLock(lockPath, formal: owned.formal) }
                catch { cleanupErrors.append(error) }
            }
            if suiteAdmitted {
                UserDefaults.standard.removePersistentDomain(forName: suiteName)
                if UserDefaults.standard.persistentDomain(forName: suiteName) != nil {
                    cleanupErrors.append(FixtureFailure(stage: "owned preferences removal verification", code: EIO))
                }
            }
            let combined: Result<T, Error>
            if cleanupErrors.isEmpty { combined = business }
            else {
                switch business {
                case .success: combined = .failure(FixtureFailures(business: nil, cleanup: cleanupErrors))
                case .failure(let error): combined = .failure(FixtureFailures(business: error, cleanup: cleanupErrors))
                }
            }
            return try owned.finish(combined)
        }
        var scopeEntered = false
        var finalized: T?
        do {
            try withOwnedS20NativeRunLoopScope {
                scopeEntered = true
                let contextOK = contextMatches()
                print("SETTINGS509_CONTEXT phase=owned-callback testMatches=\(contextOK) parameterized=\(Test.Case.current?.isParameterized == true) taskPresent=\(withUnsafeCurrentTask { $0 != nil })")
                let business: Result<T, Error>
                if !contextOK {
                    let contextError = FixtureFailure(stage: "Testing context lost before original assertions", code: ESTALE)
                    if let preparationError {
                        business = .failure(FixtureFailures(business: preparationError, cleanup: [contextError]))
                    } else {
                        business = .failure(contextError)
                    }
                } else if let preparationError {
                    business = .failure(preparationError)
                } else if let fixture {
                    business = Result { try body(fixture) }
                } else {
                    business = .failure(FixtureFailure(stage: "fixture not initialized", code: EINVAL))
                }
                finalized = .some(try finishOwned(business))
                guard contextMatches() else {
                    throw FixtureFailure(stage: "Testing context lost after original body/cleanup", code: ESTALE)
                }
            }
        } catch {
            if !scopeEntered {
                // The nonescaping callback never ran: no host exists, but the
                // pre-joined fixture still has an owner and must be cleaned.
                if let preparationError {
                    let combinedError = FixtureFailures(business: preparationError, cleanup: [error])
                    return try finishOwned(.failure(combinedError))
                }
                return try finishOwned(.failure(error))
            }
            throw error
        }
        guard contextMatches(), let finalized else {
            throw FixtureFailure(stage: "owned scope lost context or finalized result", code: ESTALE)
        }
        return finalized
    }

    private func host(fixture: Fixture, width: Int) -> NSWindow {
        let center = fixture.center
        let metrics = SettingsLayoutMetrics.forWidth(CGFloat(width))
        // Offer the production content budget after the original shell sidebar/gutters.
        let contentWidth = CGFloat(width) - metrics.sidebarWidth - 2 * metrics.contentGutter
        let lease = NativeTestHostLifecycle.begin("EnvironmentColumns509")
        let controller = NSHostingController(rootView: EnvironmentSettingsTab(center: center, metrics: metrics)
            .environment(\.typographyTokens, TypographyTokenProvider(center: center)))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        fixture.windows.append(window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: contentWidth, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 900)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        pump(window)
        print("SETTINGS509_OWNED_WINDOW id=\(window.windowNumber) requestedShellWidth=\(width) actualContentWidth=\(window.contentView?.bounds.width ?? 0) globalFont=\(center.uiBaseFontSize) note=contentBudgetHostNotWholeSettingsShell")
        NativeTestHostLifecycle.observe(window, phase: "sampled")
        if let view = window.contentView {
            print("SETTINGS509_COORDINATES contentAppKit=\(NSAccessibility.screenRect(fromView: view, rect: view.bounds)) zeroScreenFrame=\(String(describing: NSScreen.screens.first?.frame)) localContentBounds=\(view.bounds)")
        }
        return window
    }

    private func close(_ window: NSWindow) {
        for sheet in window.sheets {
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        NativeTestHostLifecycle.end(window)
    }

    private func pump(_ window: NSWindow) {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func node(_ identifier: String, in window: NSWindow) throws -> AnyObject {
        for _ in 0..<12 {
            pump(window)
            if let result = NativeConsumerOwnedAX.find(in: window, identifier: identifier) { return result }
        }
        return try #require(NativeConsumerOwnedAX.find(in: window, identifier: identifier))
    }

    private func viewport(_ window: NSWindow) throws -> CGRect {
        let view = try #require(window.contentView)
        return NSAccessibility.screenRect(fromView: view, rect: view.bounds)
    }

    // The owned content viewport is in AppKit screen coordinates; CF AX
    // positions use the opposite Y origin. Reuse the existing production
    // point conversion without clipping or changing the +/-1 containment gate.
    private func observedFrameInViewportCoordinates(_ element: AnyObject) throws -> CGRect {
        let wire = try #require(NativeConsumerOwnedAX.frame(element))
        return try #require(UF03AXScreenCoordinates.appKitFrame(
            position: wire.origin, size: wire.size,
            zeroScreenFrame: NSScreen.screens.first?.frame))
    }

    private func checkedButton(_ identifier: String, in window: NSWindow) throws -> CGRect {
        let button = try node(identifier, in: window)
        #expect(NativeConsumerOwnedAX.role(button) == .button)
        #expect(NativeConsumerOwnedAX.enabled(button) == true)
        let frame = try observedFrameInViewportCoordinates(button)
        #expect(frame.width > 0 && frame.height > 0)
        let bounds = try viewport(window)
        #expect(bounds.insetBy(dx: -1, dy: -1).contains(frame))
        return frame
    }

    @Test(arguments: [600, 720, 800, 1600])
    func rowGeometryKeepsEveryActualOperationVisible(width: Int) async throws {
        try await withFixture { fixture in
        let center = fixture.center
        for font in [16, 20] {
            center.uiBaseFontSize = font
            let window = host(fixture: fixture, width: width)
            defer { close(window) }
            let providerDetails = try node("settings.provider.details.\(providerName)", in: window)
            let plainDetails = try node("settings.environment.details.\(variableName)", in: window)
            let detailsFrames = [try observedFrameInViewportCoordinates(providerDetails),
                                 try observedFrameInViewportCoordinates(plainDetails)]
            let bounds = try viewport(window)
            for details in detailsFrames {
                #expect(details.width > 0 && details.height > 0)
                #expect(bounds.insetBy(dx: -1, dy: -1).contains(details))
            }
            let identifiers = ["settings.provider.readiness.check", "settings.provider.configuration-recovery",
                "settings.environment.edit.\(providerName)", "settings.environment.delete.\(providerName)",
                "settings.environment.convert.\(variableName)", "settings.environment.edit.\(variableName)",
                "settings.environment.delete.\(variableName)"]
            var frames: [CGRect] = []
            for identifier in identifiers { frames.append(try checkedButton(identifier, in: window)) }
            for (index, frame) in frames.enumerated() {
                let details = detailsFrames[index < 4 ? 0 : 1]
                #expect(!details.intersects(frame))
                for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
            }
            #expect(abs(frames[3].maxX - frames[6].maxX) <= 1)
        }
        }
    }

    @Test(arguments: [600, 720, 800, 1600])
    func originalNativeEditorActionsCancelWithoutPersistence(width: Int) async throws {
        try await withFixture { fixture in
        let profile = fixture
        let center = fixture.center
        center.uiBaseFontSize = 20
        let window = host(fixture: fixture, width: width)
        defer { close(window) }
        let file = profile.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)
        let before = try Data(contentsOf: file)
        let entries = center.envEntries
        for (identifier, providerEditor) in [
            ("settings.environment.edit.\(variableName)", false),
            ("settings.environment.convert.\(variableName)", true),
            ("settings.environment.edit.\(providerName)", true)
        ] {
            _ = try checkedButton(identifier, in: window)
            let button = try node(identifier, in: window)
            try #require(NativeConsumerOwnedAX.press(button))
            for _ in 0..<12 { pump(window); if window.sheets.count == 1 { break } }
            let sheet = try #require(window.sheets.count == 1 ? window.sheets.first : nil)
            #expect(sheet.sheetParent === window)
            let field = try #require(NativeConsumerOwnedAX.find(in: window,
                label: providerEditor ? "如 MY_PROVIDER_API_KEY" : "变量值", textField: true))
            let fieldValue = try #require(NativeConsumerOwnedAX.attribute(field, kAXValueAttribute as CFString) as? String)
            let expectedValue = providerEditor
                ? (identifier.hasSuffix(providerName) ? providerName : variableName)
                : String(repeating: "owned plain text ", count: 24)
            #expect(fieldValue == expectedValue)
            let cancel: AnyObject
            if providerEditor {
                cancel = try node("settings.provider.cancel", in: window)
            } else {
                cancel = try #require(NativeConsumerOwnedAX.find(in: window, label: "取消", pressable: true))
            }
            try #require(NativeConsumerOwnedAX.press(cancel))
            for _ in 0..<12 { pump(window); if window.sheets.isEmpty { break } }
            #expect(window.sheets.isEmpty)
            #expect(center.envEntries == entries)
            let after = try Data(contentsOf: file)
            #expect(after == before)
        }
        }
    }
}
