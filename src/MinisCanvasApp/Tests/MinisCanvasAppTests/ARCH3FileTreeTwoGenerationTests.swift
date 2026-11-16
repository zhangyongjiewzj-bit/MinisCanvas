import AppKit
import ApplicationServices
import CryptoKit
import ObjectiveC
import Foundation
import Darwin
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("ARCH3 FileTree two-generation read projection", .serialized)
@MainActor
struct ARCH3FileTreeTwoGenerationTests {
    @Test
    func originalFileTreeTwoGenerationsKeepCanonicalOwnersAndFiveFiles() async throws {
        _ = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "ui-projection2991", canvasRuntimeState: .disabled)
        try B1ARCHOriginalFixtureSupport.qualifyProfile(profile)
        guard let suite = profile.userDefaultsSuiteName,
              let runID = ProcessInfo.processInfo.environment[FormalTestIsolationPaths.runIDKey] else {
            throw External2991Failure("real-profile-suite-run-id")
        }
        let usageKey = "arch3.2991." + UUID().uuidString
        // Real external owner ACK must precede every Store/Task constructor.
        let externalOwner = try External2991RootLeaseClient(root: profile.rootDirectory,
            actualFM: FileManager().temporaryDirectory, suite: suite, usageKey: usageKey,
            usageLock: UsageStore.persistenceLockPath(for: usageKey), runID: runID)
        do {
        let defaults = profile.makeUserDefaults()
        let usage = UsageStore(domain: profile.usageStoreDefaultsDomain, storageKey: usageKey)
        let usageJoined = await usage.waitForPersistence()
        guard usageJoined else { throw External2991Failure("Usage-init-real-prejoin", EIO) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let memory = MemoryStore(directory: profile.memoryDirectory)
        let shortcuts = ShortcutStore(defaults: defaults)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: memory, memoryFileStore: MemoryFileStore(directory: profile.memoryDirectory),
            sessionStore: sessions, sessionBadgeStore: badges, logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.minisCoreDirectory.appendingPathComponent("skills")),
            usageStore: usage, shortcutStore: shortcuts,
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
        let skills = SkillsStore(appStore: center.skillStore,
            stateFileURL: profile.skillStateURL, loadImmediately: false)
        let scheduler = SchedulerTaskStore(defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory.appendingPathComponent("scheduler-occurrences-v1.json"))
        let schedulerRuntime = SchedulerTaskRuntime(store: scheduler, submitCommand: { _ in
            Issue.record("UI 重建不得提交调度任务")
        })
        defer { schedulerRuntime.stop() }
        let taskURL = profile.rootDirectory.appendingPathComponent("agent-tasks2991.json")
        let taskStore = try AgentTaskStore(persistenceURL: taskURL)
        _ = try taskStore.enqueue(taskID: "owned-task2991", parentID: "owned-parent2991",
                                  providerID: "offline", modelID: "synthetic")
        let syntheticSecret = "arch3-synthetic-secret-2991"
        #expect(center.envStore.setEnvVar(name: "ARCH3_SYNTHETIC_SECRET", value: syntheticSecret, isSecret: true))
        let sessionID = UUID()
        _ = try sessions.createSession(id: sessionID.uuidString, title: "ARCH3 初始会话2991")
        try sessions.saveMessage(.init(role: .user, content: "ARCH3 原领域原文2991 \(syntheticSecret)"),
                                 sessionID: sessionID.uuidString)
        try center.mcpManager.addServer(.init(id: "owned-mcp2991", name: "合成2991",
            type: .stdio, enabled: false, command: "echo"))
        center.safeModeEnabled = false
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills, settingsCatalogSchedulerStore: scheduler,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: profile.minisCanvasDirectory.appendingPathComponent("Workflows")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions, canvasRuntimeState: .disabled, agentTaskStore: taskStore,
            memoryStore: memory, memoryProposalConsumer: center.memoryProposalConsumer,
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.bindConfirmedSessionDeletionProjection(to: center))
        #expect(ProductionPickerCatalogWiring.bind(chat: bridge.chat, center: center, profile: profile))
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: sessions.directory, mcpManager: center.mcpManager, skillStore: center.skillStore,
            canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false,
            sessionReadSecretStore: center.envStore).value
        #expect(bridge.chat.applySwitchSession(id: sessionID))
        bridge.chat.draftText = "ARCH3 原父草稿2991"
        let originalMessages = bridge.chat.messages

        // These are actual synthetic files in the exact injected owner roots.
        // Capturing after each intentional owner update separates legal source
        // writes from an unexpected write/reversion caused by a rebuilt UI.
        let canonicalFiles = [center.settingsDirectory.appendingPathComponent(SettingsStore.fileName),
            sessions.sessionsDirectory.appendingPathComponent(sessionID.uuidString + ".json"),
            taskURL, center.mcpManager.fileURL,
            profile.providerConfigurationDirectory.appendingPathComponent(EnvVarStore.fileName)]
        guard !schedulerRuntime.isStarted else { throw External2991Failure("unexpected-scheduler-start", EBUSY) }
        let input = profile.rootDirectory.appendingPathComponent("p4-input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("P4_ALPHA_OWNED_PROJECTION".utf8).write(to: input.appendingPathComponent("alpha-owned.txt"))
        try Data("P4_BETA_OWNED_PROJECTION".utf8).write(to: input.appendingPathComponent("beta-owned.txt"))
        let previousCWD = FileManager.default.currentDirectoryPath
        try #require(FileManager.default.changeCurrentDirectoryPath(input.path))
        defer { #expect(FileManager.default.changeCurrentDirectoryPath(previousCWD), "Restore only this SDK process cwd") }
        let baseline = try canonicalFiles.map { try Data(contentsOf: $0) }
        let ownerIDs = [ObjectIdentifier(center), ObjectIdentifier(sessions), ObjectIdentifier(badges),
            ObjectIdentifier(bridge), ObjectIdentifier(bridge.chat), ObjectIdentifier(center.envStore),
            ObjectIdentifier(center.memoryStore), ObjectIdentifier(center.mcpManager)]
        var retiredWindows: [NSWindow] = []
        let inputOwnerPID = getpid() // Same SDK process registered with the external root owner.
        // Keep only the test host policy/lease alive across both windows; no activation here.
        let keyboardSequenceLease = NativeTestHostLifecycle.begin("ARCH3-P4-keyboard-sequence", requestActivation: false)
        defer { NativeTestHostLifecycle.endSequence(keyboardSequenceLease) }
        for generation in 0...1 {
            #expect(center.sessionStore === sessions && bridge.chat.sessionStore === sessions)
            #expect(bridge.chat.sessionManager?.store === sessions)
            #expect(bridge.sessionBadgeStore === badges)
            let fileView = FileTreeTabView(attachmentSelection: nil, sessionRoot: input)
            let lease = NativeTestHostLifecycle.begin("ARCH3-P4-generation-\(generation)", requestActivation: false)
            let controller = NSHostingController(rootView: fileView)
            controller.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "ARCH3-P4-" + UUID().uuidString
            let diagnosticWindowID = "arch3-filetree-" + UUID().uuidString
            window.setAccessibilityIdentifier(diagnosticWindowID)
            NativeTestHostLifecycle.bind(lease, to: window)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 700, height: 600))
            controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
            do {
                defer {
                    window.orderOut(nil); window.contentViewController = nil; window.close()
                    NativeTestHostLifecycle.end(window)
                }
                window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); window.layoutIfNeeded()
                controller.view.layoutSubtreeIfNeeded(); controller.view.display()
                NativeTestHostLifecycle.observe(window, phase: "sampled")
                do {
                try await Self.wait {
                    let snapshot = try FileTreePublicSnapshot.capture(window: window)
                    return try snapshot.uniqueStaticText("alpha-owned.txt") != nil
                        && snapshot.uniqueStaticText("beta-owned.txt") != nil
                }
                } catch {
                    if generation == 0 {
                        FileTreePostFailureReadOnlyDiagnostic.capture(window: window, input: input,
                            expectedWindowID: diagnosticWindowID, originalError: error)
                    }
                    throw error
                }
                let search = try #require(try Self.find(window, text: "搜索文件名…", textField: true))
                let searchControl = try #require(search as? NSAccessibilityProtocol)
                #expect((searchControl.accessibilityValue() as? String ?? "").isEmpty,
                    "New generation must expose its original empty filter")
                let chosen = generation == 0 ? "alpha" : "beta"
                // B1056: same input point, real field-editor key events only; no value or model setter.
                try FileTreeRealEditorKeyboardInput.typeChosen(chosen, window: window,
                    expectedWindowID: diagnosticWindowID, expectedPID: inputOwnerPID)
                let selected = chosen + "-owned.txt"
                let excluded = generation == 0 ? "beta-owned.txt" : "alpha-owned.txt"
                do {
                try await Self.wait {
                    let snapshot = try FileTreePublicSnapshot.capture(window: window)
                    return try snapshot.uniqueStaticText(selected) != nil
                        && snapshot.uniqueStaticText(excluded) == nil
                }
                } catch {
                    FileTreePublicSnapshot.dumpFilterFailure(window: window, search: search,
                        searchControl: searchControl, selected: selected, excluded: excluded, originalError: error)
                    throw error
                }
                #expect((searchControl.accessibilityValue() as? String) == chosen)
                let row = try #require(try Self.find(window, text: selected))
                try Self.clickOriginalRow(row, window: window, expectedFileName: selected)
                let expected = generation == 0 ? "P4_ALPHA_OWNED_PROJECTION" : "P4_BETA_OWNED_PROJECTION"
                try await Self.wait { try Self.find(window, text: expected) != nil }
                #expect(try canonicalFiles.map { try Data(contentsOf: $0) } == baseline,
                    "Actual FileTree filter/preview must leave five canonical files unchanged")
                #expect([ObjectIdentifier(center), ObjectIdentifier(sessions), ObjectIdentifier(badges),
                    ObjectIdentifier(bridge), ObjectIdentifier(bridge.chat), ObjectIdentifier(center.envStore),
                    ObjectIdentifier(center.memoryStore), ObjectIdentifier(center.mcpManager)] == ownerIDs)
                print("ARCH3_P4 generation=\(generation) originalFilter=\(chosen) originalPreview=true fiveFilesUnchanged=true")
            }
            #expect(!window.isVisible && window.contentViewController == nil)
            retiredWindows.append(window)
        }
        #expect(retiredWindows.count == 2 && retiredWindows[0] !== retiredWindows[1])
        #expect(try canonicalFiles.map { try Data(contentsOf: $0) } == baseline)
        #expect(bridge.chat.messages == originalMessages && !bridge.chat.isStreaming)
        let prefix = profile.rootDirectory.standardizedFileURL.path + "/"
        let terminalFiles = try canonicalFiles.map { file -> URL in
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw External2991Failure("canonical-file-outside-profile") }
            return externalOwner.root.appendingPathComponent(String(path.dropFirst(prefix.count)))
        }
        print("ARCH3_P4 perViewScanPreviewTaskJoin=UNKNOWN rootHeldUntilSDKTerminal=true")
        try externalOwner.finish(files: terminalFiles, defaultsSynchronized: defaults.synchronize(), usageJoined: usageJoined)
        } catch { externalOwner.abort(); throw error }
    }

    private static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    private static func wait(_ condition: @MainActor () throws -> Bool) async throws {
        for _ in 0..<100 { pump(); if try condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw External2991Failure("P4-original-control-projection-not-observed")
    }
    // Public NSAccessibility getters on this exact host only. A truncated tree throws,
    // so an unreadable/missing tree cannot pass the excluded-row negative assertion.
    private static func nodes(_ window: NSWindow) throws -> [AnyObject] {
        var queue: [AnyObject] = [window]; var visited = Set<ObjectIdentifier>(); var result: [AnyObject] = []
        while !queue.isEmpty {
            let object = queue.removeFirst(); guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count < 4096 else { throw External2991Failure("P4-accessibility-tree-truncated") }
            result.append(object)
            if let value = object as? NSObject {
                for name in ["accessibilityChildrenInNavigationOrder", "accessibilityChildren"] {
                    let selector = NSSelectorFromString(name)
                    if value.responds(to: selector), let raw = value.perform(selector)?.takeUnretainedValue() as? NSArray {
                        queue += raw.map { $0 as AnyObject }
                    }
                }
            }
            if let view = object as? NSView { queue += view.subviews }
            if let host = object as? NSWindow, let content = host.contentView { queue.append(content) }
        }
        return result
    }
    private static func scalar(_ object: AnyObject, _ name: String) -> String? {
        guard let object = object as? NSObject else { return nil }; let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? String : nil
    }
    private static func find(_ window: NSWindow, text: String, textField: Bool = false) throws -> AnyObject? {
        if !textField {
            return try FileTreePublicSnapshot.capture(window: window).uniqueStaticText(text)
        }
        let matches = try nodes(window).filter { node in
            let strings = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityPlaceholderValue"].compactMap { scalar(node, $0) }
            let role = (node as? NSAccessibilityProtocol)?.accessibilityRole()
            return strings.contains(text) && (!textField || role == .textField)
        }
        return matches.first
    }
    private static func clickOriginalRow(_ node: AnyObject, window: NSWindow) throws {
        let accessible = try #require(node as? NSAccessibilityProtocol)
        if accessible.accessibilityPerformPress() { return }
        let frame = accessible.accessibilityFrame()
        try Self.sendOriginalMouseFallback(frame, window: window)
    }
    private static func clickOriginalRow(_ node: AnyObject, window: NSWindow, expectedFileName: String) throws {
        if node is NSAccessibilityProtocol {
            print("ARCH3_P4_ACTION channel=local originalProtocolCastMacro=ENTERED")
            try Self.clickOriginalRow(node, window: window)
            return
        }
        guard CFGetTypeID(node) == AXUIElementGetTypeID() else {
            throw External2991Failure("P4-public-row-not-AXUIElement")
        }
        let element = unsafeDowncast(node, to: AXUIElement.self)
        let snapshot = try FileTreePublicSnapshot.capture(window: window)
        let action = try snapshot.pressExactlyOnce(element, expected: expectedFileName)
        switch action {
        case .pressed:
            print("ARCH3_P4_ACTION channel=public AXPress=SUCCESS originalProtocolCastMacro=NR originalFrameDownUpMacros=NR")
        case .mouseFallback(let frame):
            print("ARCH3_P4_ACTION channel=public AXPress=ACTION_UNSUPPORTED originalProtocolCastMacro=NR originalFrameDownUpMacros=ENTERED")
            try Self.sendOriginalMouseFallback(frame, window: window)
            try snapshot.revalidate(element, expected: expectedFileName)
        }
    }
    private static func sendOriginalMouseFallback(_ frame: NSRect, window: NSWindow) throws {
        try #require(frame.width > 0 && frame.height > 0)
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down); window.sendEvent(up)
    }
}

// Bounded observation only AFTER the original first-generation wait has thrown.
// It never supplies a matcher result, pumps the run loop, or changes that error.
@MainActor
private final class FileTreePostFailureReadOnlyDiagnostic {
    private let started = ProcessInfo.processInfo.systemUptime
    private var events: [[String: Any]] = []
    private var encodedEventBytes = 0
    private var reasons: [String] = []
    private let byteCap = 512 * 1024
    private let markers = ["p4-input", "空目录", "alpha-owned.txt", "beta-owned.txt", "搜索文件名…",
        "P4_ALPHA_OWNED_PROJECTION", "P4_BETA_OWNED_PROJECTION"]
    private var clock: Double { ProcessInfo.processInfo.systemUptime }

    static func capture(window: NSWindow, input: URL, expectedWindowID: String, originalError: Error) {
        let diagnostic = Self()
        diagnostic.run(window: window, input: input, expectedWindowID: expectedWindowID,
            errorType: String(reflecting: type(of: originalError)))
    }
    private func partial(_ reason: String) {
        if reasons.count < 64 && !reasons.contains(reason) { reasons.append(reason) }
    }
    private func allowed(_ end: Double) -> Bool {
        let ok = clock < min(end, started + 2) && encodedEventBytes < byteCap - 8192
        if !ok { partial("time-or-serialized-cap; remaining-tree-UNKNOWN") }
        return ok
    }
    private func append(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else {
            partial("event-serialization-error"); return
        }
        guard encodedEventBytes + data.count + 1 <= byteCap - 8192 else {
            partial("serialized-cap; omitted-event-UNKNOWN"); return
        }
        encodedEventBytes += data.count + 1
        events.append(row)
    }
    private func text(_ value: AnyObject?, role: Bool = false) -> [String: Any] {
        guard let value else { return ["present": false] }
        var result: [String: Any] = ["present": true,
            "actualClass": String(NSStringFromClass(type(of: value)).prefix(256))]
        if value is NSString || value is NSArray || value is NSNumber || value is NSData || value is NSDate || value is NSNull {
            result["CFTypeID"] = CFGetTypeID(value)
        } else { result["CFTypeID"] = "not-asserted-for-arbitrary-NSObject" }
        if let string = value as? String {
            let sample = String(string.prefix(256))
            result["kind"] = "String"
            result["utf16Length"] = (string as NSString).length
            result["sampleUnicodeLimit"] = 256
            result["sampleTruncated"] = (string as NSString).length != (sample as NSString).length
            result["sampleSHA256"] = SHA256.hash(data: Data(sample.utf8)).map { String(format: "%02x", $0) }.joined()
            result["knownMarkers"] = markers.filter { sample.contains($0) }
            if role && sample.hasPrefix("AX") { result["publicRole"] = sample }
        } else { result["kind"] = "nonString-type-only" }
        return result
    }
    // Runtime method return encoding must be an object (@), never a scalar/struct.
    // These selectors all return objects in the public NSAccessibility contract.
    private func objectGetter(_ object: NSObject, name: String, end: Double) -> (AnyObject?, [String: Any]) {
        let selector = NSSelectorFromString(name)
        let responds = object.responds(to: selector)
        var detail: [String: Any] = ["selector": name, "responds": responds]
        guard responds, allowed(end), let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else {
            detail["status"] = "not-called-unsupported-or-budget"; return (nil, detail)
        }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        let returnType = String(cString: encoding)
        detail["returnEncoding"] = String(returnType.prefix(64))
        guard returnType.hasPrefix("@") && returnType != "@?" else {
            detail["status"] = "refused-non-object-ABI"; partial("local-getter-ABI-refused"); return (nil, detail)
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let begin = clock
        let value = getter(object, selector)?.takeUnretainedValue()
        detail["status"] = "returned-once"
        detail["elapsedSeconds"] = clock - begin
        detail["phaseOverrun"] = clock > end
        if clock > end { partial("uninterruptible-local-getter-overrun; no-hard-realtime-claim") }
        detail["value"] = text(value)
        return (value, detail)
    }
    private func windowMetadata(_ window: NSWindow, expectedID: String, phase: String, end: Double) {
        guard allowed(end) else { return }
        let begin = clock
        append(["phase": phase, "kind": "typed-window-metadata", "pid": getpid(),
            "windowNumber": window.windowNumber, "expectedUniqueWindowID": expectedID,
            "actualUniqueWindowID": String(window.accessibilityIdentifier().prefix(256)),
            "windowFrame": NSStringFromRect(window.frame),
            "contentFrame": window.contentView.map { NSStringFromRect($0.frame) } ?? "nil",
            "sheetCount": window.sheets.count, "typedMetadataElapsedSeconds": clock - begin,
            "phaseOverrun": clock > end])
        if clock > end { partial("uninterruptible-window-metadata-overrun") }
    }
    private func inputMetadata(_ input: URL, end: Double) {
        guard allowed(end) else { return }
        let cwd = FileManager.default.currentDirectoryPath
        append(["phase": "local-before", "kind": "input-metadata", "cwd": String(cwd.prefix(256)),
            "expectedInputURL": String(input.path.prefix(256)), "cwdStringEqualsExpected": cwd == input.path,
            "cwdEnumerated": false, "fileContentRead": false])
        func info(_ path: String) -> [String: Any] {
            var s = stat(); let code = lstat(path, &s); let savedErrno = errno
            guard code == 0 else { return ["lstat": code, "errno": savedErrno] }
            return ["lstat": code, "dev": s.st_dev, "ino": s.st_ino, "uid": s.st_uid,
                "mode": String(s.st_mode & 0o7777, radix: 8), "size": s.st_size,
                "typeBits": s.st_mode & S_IFMT]
        }
        for name in ["alpha-owned.txt", "beta-owned.txt"] {
            guard allowed(end) else { return }
            append(["phase": "local-before", "kind": "expected-file-lstat", "basename": name,
                "metadata": info(input.appendingPathComponent(name).path)])
        }
        guard allowed(end) else { return }
        var expected = stat()
        guard lstat(input.path, &expected) == 0, expected.st_mode & S_IFMT == S_IFDIR,
              expected.st_uid == getuid(), expected.st_mode & 0o777 == 0o700 else {
            partial("input-directory-metadata-refused"); return
        }
        let fd = open(input.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { partial("input-directory-open-refused"); return }
        var pinned = stat()
        guard fstat(fd, &pinned) == 0, pinned.st_dev == expected.st_dev, pinned.st_ino == expected.st_ino,
              let directory = fdopendir(fd) else { close(fd); partial("input-directory-identity-refused"); return }
        defer { closedir(directory) }
        var names: [String] = []; var exceeded = false
        while allowed(end), let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if names.count == 16 { exceeded = true; partial("input-entry-cap16"); break }
            names.append(String(name.prefix(256)))
        }
        append(["phase": "local-before", "kind": "owned-expected-input-directory-only",
            "namesMax16": names, "truncated": exceeded, "metadata": info(input.path),
            "cwdEnumerated": false, "contentRead": false])
    }
    private func local(_ window: NSWindow, phase: String, end: Double) {
        var queue: [(AnyObject, Int)] = [(window, 0)]
        var visited = Set<ObjectIdentifier>(); var index = 0
        while index < queue.count && visited.count < 512 && allowed(end) {
            let (node, depth) = queue[index]; index += 1
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            var row: [String: Any] = ["phase": phase, "node": visited.count - 1, "depth": depth,
                "localObjectIdentity": String(describing: ObjectIdentifier(node)),
                "actualClass": String(NSStringFromClass(type(of: node)).prefix(256)),
                "conformsNSAccessibilityProtocol": node is NSAccessibilityProtocol]
            var children: [AnyObject] = []
            if let object = node as? NSObject {
                for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityPlaceholderValue",
                             "accessibilityChildrenInNavigationOrder", "accessibilityChildren"] {
                    guard allowed(end) else { break }
                    let (value, detail) = objectGetter(object, name: name, end: end)
                    row[name] = detail
                    if name == "accessibilityChildren" || name == "accessibilityChildrenInNavigationOrder",
                       let array = value as? NSArray {
                        if array.count > 512 { partial("local-child-array-cap512") }
                        for child in array.prefix(512) { children.append(child as AnyObject) }
                    }
                }
            }
            if allowed(end), let accessible = node as? NSAccessibilityProtocol {
                let begin = clock; let role = accessible.accessibilityRole()
                row["typedRole"] = String((role?.rawValue ?? "nil").prefix(256))
                row["typedRoleElapsedSeconds"] = clock - begin
                if clock > end { partial("uninterruptible-local-role-overrun") }
            }
            if allowed(end), let view = node as? NSView { children += Array(view.subviews.prefix(512)) }
            if allowed(end), let host = node as? NSWindow, let content = host.contentView { children.append(content) }
            append(row)
            if depth == 12 && !children.isEmpty { partial("local-depth-cap12"); continue }
            for child in children {
                guard allowed(end) else { break }
                if queue.count >= 512 { partial("local-queue-cap512"); break }
                queue.append((child, depth + 1))
            }
        }
        append(["phase": phase, "kind": "local-summary", "uniqueNodes": visited.count,
            "queued": queue.count, "consumed": index, "incomplete": index < queue.count,
            "absenceClaim": false, "elapsedTotalSeconds": clock - started])
        if index < queue.count { partial("local-tree-incomplete") }
        // Queue/visited/node references die here, before the next observation phase.
    }
    private func axRead(_ node: AXUIElement, _ name: String, end: Double) -> (CFTypeRef?, [String: Any]) {
        guard allowed(end) else { return (nil, ["attribute": name, "status": "budget-skipped"]) }
        let timeout = Float(min(0.05, max(0.000001, min(end, started + 2) - clock)))
        let timeoutStatus = AXUIElementSetMessagingTimeout(node, timeout)
        var pid: pid_t = 0; let pidStatus = AXUIElementGetPid(node, &pid)
        var detail: [String: Any] = ["attribute": name, "GetPidStatus": pidStatus.rawValue,
            "actualPid": pid, "expectedPid": getpid(), "timeoutSeconds": timeout,
            "timeoutStatus": timeoutStatus.rawValue]
        guard timeoutStatus == .success, pidStatus == .success, pid == getpid(), allowed(end) else {
            detail["status"] = "ownership-or-budget-refused"; partial("public-node-ownership-or-budget-refused"); return (nil, detail)
        }
        let begin = clock; var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, name as CFString, &value)
        detail["status"] = status.rawValue; detail["elapsedSeconds"] = clock - begin
        detail["phaseOverrun"] = clock > end
        if let value { detail["CFTypeID"] = CFGetTypeID(value); detail["value"] = text(value, role: name == kAXRoleAttribute) }
        else { detail["valuePresent"] = false }
        if clock > end { partial("public-query-overrun; no-hard-realtime-claim") }
        if status != .success { partial("public-attribute-status-\(status.rawValue); absence-not-inferred") }
        return (value, detail)
    }
    private func publicAX(_ window: NSWindow, expectedID: String, end: Double) {
        guard allowed(end), window.sheets.isEmpty, window.accessibilityIdentifier() == expectedID else {
            partial("public-own-window-ID-or-sheet-refused"); return
        }
        let application = AXUIElementCreateApplication(getpid())
        let (rawWindows, detail) = axRead(application, kAXWindowsAttribute, end: end)
        append(["phase": "public-own-AX", "kind": "ownPID-windows-query", "query": detail])
        guard let rawWindows, CFGetTypeID(rawWindows) == CFArrayGetTypeID(),
              let windows = rawWindows as? [AXUIElement], windows.count <= 16 else {
            partial("public-windows-unreadable-or-cap16"); return
        }
        var matches: [AXUIElement] = []; var ownershipComplete = true
        for candidate in windows {
            guard allowed(end) else { ownershipComplete = false; break }
            let (value, idDetail) = axRead(candidate, kAXIdentifierAttribute, end: end)
            append(["phase": "public-own-AX", "kind": "window-ID-qualification", "query": idDetail,
                "exactExpectedID": (value as? String) == expectedID])
            if let value = value as? String, value == expectedID { matches.append(candidate) }
            else if idDetail["status"] as? Int32 != AXError.success.rawValue { ownershipComplete = false }
        }
        guard ownershipComplete, matches.count == 1, let root = matches.first, allowed(end) else {
            partial("public-exact-window-not-uniquely-qualified"); return
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]; var visited: [AXUIElement] = []; var index = 0
        while index < queue.count && visited.count < 512 && allowed(end) {
            let (node, depth) = queue[index]; index += 1
            guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
            visited.append(node)
            var row: [String: Any] = ["phase": "public-own-AX", "node": visited.count - 1, "depth": depth]
            var children: [AXUIElement] = []
            for name in [kAXRoleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute,
                         kAXValueAttribute, kAXPlaceholderValueAttribute, kAXChildrenAttribute] {
                guard allowed(end) else { break }
                let (value, d) = axRead(node, name, end: end); row[name] = d
                if name == kAXChildrenAttribute, let value, CFGetTypeID(value) == CFArrayGetTypeID(),
                   let array = value as? [AXUIElement] { children = Array(array.prefix(512)); if array.count > 512 { partial("public-child-cap512") } }
            }
            append(row)
            if depth == 12 && !children.isEmpty { partial("public-depth-cap12"); continue }
            for child in children {
                guard allowed(end) else { break }
                if queue.count >= 512 { partial("public-queue-cap512"); break }
                queue.append((child, depth + 1))
            }
        }
        append(["phase": "public-own-AX", "kind": "public-summary", "uniqueNodes": visited.count,
            "queued": queue.count, "consumed": index, "incomplete": index < queue.count,
            "absenceClaim": false, "elapsedTotalSeconds": clock - started])
        if index < queue.count { partial("public-tree-incomplete") }
    }
    private func run(window: NSWindow, input: URL, expectedWindowID: String, errorType: String) {
        windowMetadata(window, expectedID: expectedWindowID, phase: "local-before", end: started + 0.4)
        inputMetadata(input, end: started + 0.4)
        local(window, phase: "local-before", end: started + 0.4)
        publicAX(window, expectedID: expectedWindowID, end: started + 1.6)
        windowMetadata(window, expectedID: expectedWindowID, phase: "local-after", end: started + 2)
        local(window, phase: "local-after", end: started + 2)
        var result: [String: Any] = ["phase": "first-generation-original-wait-error-already-decided",
            "originalErrorType": String(errorType.prefix(256)), "originalErrorWillBeRethrown": true,
            "pid": getpid(), "singleCapture": true, "totalBudgetSeconds": 2,
            "phaseBudgetSeconds": [0.4, 1.2, 0.4], "nodeCapPerPhase": 512, "depthCap": 12,
            "stringUnicodeCap": 256, "serializedByteCap": byteCap,
            "elapsedSeconds": clock - started, "uninterruptibleOverrun": clock > started + 2,
            "absenceClaim": false, "hardRealtimeGuarantee": false, "events": events, "partialReasons": reasons]
        let prefix = "ARCH3_FILETREE_POST_FAILURE_DIAGNOSTIC="
        var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        while let current = data, current.count + prefix.utf8.count + 1 > byteCap, !events.isEmpty {
            events.removeLast(); partial("final-serialized-cap"); result["events"] = events
            result["partialReasons"] = reasons
            data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
        result["elapsedIncludingSerializationUntilFinalEncodingSeconds"] = clock - started
        result["uninterruptibleOverrun"] = clock > started + 2
        data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        if let data, data.count + prefix.utf8.count + 1 <= byteCap, let line = String(data: data, encoding: .utf8) {
            print(prefix + line)
        } else { print("ARCH3_FILETREE_POST_FAILURE_DIAGNOSTIC=\"serialization-refused; originalFAIL-preserved\"") }
    }
}

// B0420/B0425: a fresh complete own-window public read for EACH predicate.
// No AX node/text snapshot is cached across predicate rounds or generations.
@MainActor
private final class FileTreePublicSnapshot {
    enum Action { case pressed, mouseFallback(NSRect) }
    private struct Row { let node: AXUIElement; let role: String; let value: String? }
    private let window: NSWindow
    private let expectedID: String
    private let windowNumber: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private var deadline: Double { started + 0.25 }
    private var owner: AXUIElement?
    private var rows: [Row] = []
    private var complete = false
    private var calls = 0
    private var providerNoneLeaves = 0
    private var clock: Double { ProcessInfo.processInfo.systemUptime }
    private init(window: NSWindow) {
        self.window = window
        expectedID = window.accessibilityIdentifier()
        windowNumber = window.windowNumber
    }
    static func capture(window: NSWindow) throws -> FileTreePublicSnapshot {
        let snapshot = Self(window: window)
        do {
            try snapshot.scan()
            print("ARCH3_P4_PUBLIC_SNAPSHOT complete=true pid=\(getpid()) window=\(window.windowNumber) nodes=\(snapshot.rows.count) calls=\(snapshot.calls) providerNoneLeaves=\(snapshot.providerNoneLeaves) seconds=\(snapshot.clock-snapshot.started) wallClockCap=0.25")
            return snapshot
        } catch {
            print("ARCH3_P4_PUBLIC_SNAPSHOT complete=false pid=\(getpid()) window=\(window.windowNumber) nodes=\(snapshot.rows.count) calls=\(snapshot.calls) seconds=\(snapshot.clock-snapshot.started) error=\(error) absenceClaim=false")
            throw error
        }
    }
    private func budget(_ stage: String) throws {
        guard clock < deadline else {
            print("ARCH3_P4_PUBLIC_BUDGET stage=\(stage) elapsed=\(clock-started) overrun=true hardRealtimeGuarantee=false")
            throw External2991Failure("P4-public-snapshot-time-budget")
        }
    }
    private func prepare(_ node: AXUIElement) throws {
        try budget("before-query")
        let timeout = Float(min(0.05, max(0.000001, deadline-clock)))
        guard AXUIElementSetMessagingTimeout(node, timeout) == .success else { throw External2991Failure("P4-public-timeout-config") }
        var pid: pid_t = 0
        guard AXUIElementGetPid(node, &pid) == .success, pid == getpid() else { throw External2991Failure("P4-public-node-PID") }
        try budget("after-PID")
    }
    private func read(_ node: AXUIElement, _ attribute: String, providerNone: Bool = false) throws -> CFTypeRef? {
        try prepare(node); calls += 1
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
        try budget("after-attribute")
        if providerNone && (status == .noValue || status == .attributeUnsupported) {
            providerNoneLeaves += 1
            print("ARCH3_P4_PUBLIC_PROVIDER_NONE attribute=\(attribute) status=\(status.rawValue)")
            return nil
        }
        guard status == .success, let value else {
            print("ARCH3_P4_PUBLIC_READ_REFUSED attribute=\(attribute) status=\(status.rawValue) valuePresent=\(value != nil)")
            throw External2991Failure("P4-public-attribute-\(attribute)", status.rawValue)
        }
        return value
    }
    private func string(_ node: AXUIElement, _ attribute: String) throws -> String {
        guard let raw = try read(node, attribute), CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String else {
            throw External2991Failure("P4-public-non-CFString-\(attribute)")
        }
        return text
    }
    private func elements(_ raw: CFTypeRef, cap: Int) throws -> [AXUIElement] {
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { throw External2991Failure("P4-public-not-CFArray") }
        let array = unsafeDowncast(raw, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count <= cap else { throw External2991Failure("P4-public-array-cap") }
        var result: [AXUIElement] = []
        for index in 0..<count {
            try budget("array-type-check")
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { throw External2991Failure("P4-public-null-array-element") }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw External2991Failure("P4-public-non-AX-element") }
            result.append(unsafeDowncast(value, to: AXUIElement.self))
        }
        return result
    }
    private func frame(_ node: AXUIElement) throws -> NSRect {
        guard let rawPosition = try read(node, kAXPositionAttribute),
              let rawSize = try read(node, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            throw External2991Failure("P4-public-frame-CFType")
        }
        let positionValue = unsafeDowncast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeDowncast(rawSize, to: AXValue.self)
        var position = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size),
              let actual = UF03AXScreenCoordinates.appKitFrame(position: position, size: size,
                  zeroScreenFrame: NSScreen.screens.first?.frame), actual.width > 0, actual.height > 0 else {
            throw External2991Failure("P4-public-frame-invalid")
        }
        try budget("after-frame-decode")
        return actual
    }
    private func qualifiedWindow() throws -> AXUIElement {
        try budget("window-qualification")
        guard window.windowNumber == windowNumber, !expectedID.isEmpty,
              window.accessibilityIdentifier() == expectedID, window.sheets.isEmpty,
              window.isVisible, window.contentView != nil else { throw External2991Failure("P4-public-AppKit-owner") }
        let application = AXUIElementCreateApplication(getpid())
        guard let raw = try read(application, kAXWindowsAttribute) else { throw External2991Failure("P4-public-windows-absent") }
        let candidates = try elements(raw, cap: 16)
        var matches: [AXUIElement] = []
        for candidate in candidates {
            let identifier = try string(candidate, kAXIdentifierAttribute)
            if identifier == expectedID { matches.append(candidate) }
        }
        guard matches.count == 1, let owner = matches.first,
              try string(owner, kAXRoleAttribute) == kAXWindowRole,
              try frame(owner) == window.frame else { throw External2991Failure("P4-public-owner-not-unique-or-frame") }
        return owner
    }
    private func sameOwner() throws -> AXUIElement {
        let current = try qualifiedWindow()
        guard let owner, CFEqual(current, owner) else { throw External2991Failure("P4-public-window-identity-changed") }
        return current
    }
    private func scan() throws {
        let root = try qualifiedWindow(); owner = root
        var queue: [(AXUIElement, Int)] = [(root, 0)]; var visited: [AXUIElement] = []; var index = 0
        while index < queue.count {
            try budget("node")
            let (node, depth) = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            guard visited.count < 512 else { throw External2991Failure("P4-public-node-cap512") }
            visited.append(node)
            let role = try string(node, kAXRoleAttribute)
            let value = role == kAXStaticTextRole ? try string(node, kAXValueAttribute) : nil
            rows.append(Row(node: node, role: role, value: value))
            if let rawChildren = try read(node, kAXChildrenAttribute, providerNone: true) {
                let children = try elements(rawChildren, cap: 512)
                guard depth < 12 || children.isEmpty else { throw External2991Failure("P4-public-depth-cap12") }
                for child in children {
                    try budget("enqueue")
                    guard queue.count < 512 else { throw External2991Failure("P4-public-queue-cap512") }
                    queue.append((child, depth + 1))
                }
            }
        }
        _ = try sameOwner(); try budget("snapshot-complete")
        complete = true
    }
    // B0508: called only AFTER the original filter wait has already thrown.
    // A new post-error snapshot is not the original predicate's last snapshot.
    static func dumpFilterFailure(window: NSWindow, search: AnyObject,
        searchControl: NSAccessibilityProtocol, selected: String, excluded: String, originalError: Error) {
        let snapshot = Self(window: window)
        var record: [String: Any] = ["phase": "after-error-already-decided",
            "originalError": String(describing: originalError), "originalErrorWillBeRethrown": true,
            "pid": getpid(), "window": window.windowNumber, "complete": false,
            "absenceClaim": false, "snapshotIsOriginalLastPredicate": false,
            "selectedExpected": selected, "excludedExpected": excluded,
            "localSearchClass": String(reflecting: type(of: search)),
            "localSearchRole": searchControl.accessibilityRole()?.rawValue ?? "nil",
            "localGetterErrorCode": "NOT_AVAILABLE_NSAccessibilityProtocol_object_getter"]
        let localValue = searchControl.accessibilityValue()
        record["localValuePresent"] = localValue != nil
        if let localValue {
            record["localValueDynamicType"] = String(reflecting: type(of: localValue))
            if let text = localValue as? String { record["localStringValue"] = text }
        }
        var searchRows: [[String: Any]] = []
        do {
            try snapshot.scan() // One new complete same-owner snapshot, only in this failure path.
            record["complete"] = snapshot.complete
            record["selectedCount"] = snapshot.rows.filter { $0.role == kAXStaticTextRole && $0.value == selected }.count
            record["excludedCount"] = snapshot.rows.filter { $0.role == kAXStaticTextRole && $0.value == excluded }.count
            record["rows"] = snapshot.rows.enumerated().map { index, row -> [String: Any] in
                var item: [String: Any] = ["index": index, "role": row.role]
                if let value = row.value { item["exactStaticTextValue"] = value }
                return item
            }
            for (index, row) in snapshot.rows.enumerated() where row.role == kAXTextFieldRole {
                var item: [String: Any] = ["index": index, "role": row.role]
                let (placeholder, detail) = try snapshot.failureAttribute(row.node, kAXPlaceholderValueAttribute)
                item["placeholder"] = detail
                let fixed = detail["status"] as? Int32 == AXError.success.rawValue
                    && placeholder.map { CFGetTypeID($0) == CFStringGetTypeID() } == true
                    && (placeholder as? String) == "搜索文件名…"
                item["fixedSearchQualified"] = fixed
                if fixed {
                    let owner = try snapshot.sameOwner()
                    let (targetWindow, ownerDetail) = try snapshot.failureAttribute(row.node, kAXWindowAttribute)
                    item["AXWindowQuery"] = ownerDetail
                    let same = ownerDetail["status"] as? Int32 == AXError.success.rawValue
                        && targetWindow.map { CFGetTypeID($0) == AXUIElementGetTypeID() && CFEqual($0, owner) } == true
                    item["sameCurrentWindowCFEqual"] = same
                    if same {
                        let (_, valueDetail) = try snapshot.failureAttribute(row.node, kAXValueAttribute)
                        item["AXValue"] = valueDetail
                    }
                }
                searchRows.append(item)
                try snapshot.budget("failure-search-observation")
            }
            _ = try snapshot.sameOwner()
            try snapshot.budget("failure-diagnostic-complete")
        } catch {
            record["diagnosticPartialError"] = String(describing: error)
            record["diagnosticPartial"] = true
        }
        record["publicSearchRows"] = searchRows
        record["elapsedSeconds"] = snapshot.clock - snapshot.started
        record["snapshotBudgetSeconds"] = 0.25
        record["hardRealtimeGuarantee"] = false
        record["budgetOverrun"] = snapshot.clock >= snapshot.deadline
        let prefix = "ARCH3_P4_FILTER_FAILURE_ONLY="
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           data.count + prefix.utf8.count + 1 <= 512 * 1024,
           let line = String(data: data, encoding: .utf8) { print(prefix + line) }
        else { print(prefix + "serialization-cap-or-error; original-error-preserved; diagnostic-partial") }
    }
    // Records the provider's original AXError and CF type even on failed reads.
    private func failureAttribute(_ node: AXUIElement, _ attribute: String) throws -> (CFTypeRef?, [String: Any]) {
        try prepare(node); calls += 1
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, attribute as CFString, &raw)
        var detail: [String: Any] = ["attribute": attribute, "status": status.rawValue,
            "valuePresent": raw != nil, "budgetOverrun": clock >= deadline]
        if let raw {
            detail["CFTypeID"] = CFGetTypeID(raw)
            detail["isCFString"] = CFGetTypeID(raw) == CFStringGetTypeID()
            if status == .success, CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String {
                detail["exactStringValue"] = text
            }
        }
        return (raw, detail)
    }
    func uniqueStaticText(_ expected: String) throws -> AXUIElement? {
        guard complete else { throw External2991Failure("P4-public-incomplete-not-absence") }
        try budget("predicate")
        let matches = rows.filter { $0.role == kAXStaticTextRole && $0.value == expected }
        guard matches.count <= 1 else { throw External2991Failure("P4-public-target-ambiguous") }
        guard let target = matches.first?.node else {
            _ = try sameOwner()
            try budget("return-complete-absence")
            return nil // Only a complete, valid-valued tree can prove absence.
        }
        try revalidate(target, expected: expected)
        return target
    }
    func revalidate(_ target: AXUIElement, expected: String) throws {
        let owner = try sameOwner()
        guard try string(target, kAXRoleAttribute) == kAXStaticTextRole,
              try string(target, kAXValueAttribute) == expected,
              let targetWindow = try read(target, kAXWindowAttribute),
              CFGetTypeID(targetWindow) == AXUIElementGetTypeID(), CFEqual(targetWindow, owner) else {
            throw External2991Failure("P4-public-target-current-window-value-role")
        }
        try budget("return-target")
    }
    func pressExactlyOnce(_ target: AXUIElement, expected: String) throws -> Action {
        guard let current = try uniqueStaticText(expected), CFEqual(current, target) else {
            throw External2991Failure("P4-public-row-not-current-unique")
        }
        let actualFrame = try frame(target)
        let center = NSPoint(x: actualFrame.midX, y: actualFrame.midY)
        guard window.frame.contains(center) else { throw External2991Failure("P4-public-row-frame-outside-own-window") }
        try revalidate(target, expected: expected)
        try prepare(target); calls += 1
        var actionNames: CFArray?
        let namesStatus = AXUIElementCopyActionNames(target, &actionNames)
        try budget("after-action-names")
        guard namesStatus == .success, let actionNames, CFArrayGetCount(actionNames) <= 32 else {
            throw External2991Failure("P4-public-action-names", namesStatus.rawValue)
        }
        var names: [String] = []
        for index in 0..<CFArrayGetCount(actionNames) {
            try budget("action-name-type")
            guard let pointer = CFArrayGetValueAtIndex(actionNames, index) else { throw External2991Failure("P4-public-action-name-null") }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(value) == CFStringGetTypeID(), let name = value as? String else {
                throw External2991Failure("P4-public-action-name-CFString")
            }
            names.append(name)
        }
        let advertisesPress = names.contains(kAXPressAction)
        try prepare(target); calls += 1
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        try budget("after-only-AXPress")
        print("ARCH3_P4_PUBLIC_ROW_ACTION pid=\(getpid()) window=\(windowNumber) filename=\(expected) role=AXStaticText actualFrame=\(NSStringFromRect(actualFrame)) AXPressStatus=\(status.rawValue) advertisesPress=\(advertisesPress) count=1")
        if status == .success {
            guard advertisesPress else { throw External2991Failure("P4-public-press-support-inconsistent") }
            try revalidate(target, expected: expected)
            return .pressed
        }
        guard status == .actionUnsupported else { throw External2991Failure("P4-public-press-unexpected-error", status.rawValue) }
        try revalidate(target, expected: expected)
        return .mouseFallback(actualFrame)
    }
}

// Pure CF/identity gate shared by the real input route and no-window negative tests.
private enum FileTreePublicSearchInputContract {
    static func requireExactString(_ raw: CFTypeRef?, status: AXError, expected: String, stage: String) throws {
        guard status == .success else { throw External2991Failure(stage, status.rawValue) }
        guard let raw, CFGetTypeID(raw) == CFStringGetTypeID(), let actual = raw as? String,
              actual == expected else { throw External2991Failure(stage + "-exact-CFString") }
    }
    static func requireGate(complete: Bool, candidateCount: Int, actualPID: pid_t, expectedPID: pid_t,
        sameWindow: Bool, role: String, placeholder: CFTypeRef?, placeholderStatus: AXError,
        settableStatus: AXError, settable: Bool) throws {
        guard complete, candidateCount == 1, actualPID == expectedPID, sameWindow,
              role == kAXTextFieldRole else { throw External2991Failure("P4-public-input-identity-gate") }
        try requireExactString(placeholder, status: placeholderStatus,
            expected: "搜索文件名…", stage: "P4-public-input-placeholder")
        guard settableStatus == .success else { throw External2991Failure("P4-public-input-settable-query", settableStatus.rawValue) }
        guard settable else { throw External2991Failure("P4-public-input-not-settable") }
    }
}

@Suite(.serialized)
struct ARCH3FileTreePublicInputGateTests {
    @Test
    func strictPureCFAndGateNegativeCases() throws {
        // No NSApp/NSWindow/AXUIElement RPC or synthetic input: only actual CF type and pure gate branches.
        let marker = "搜索文件名…" as CFString
        func gate(complete: Bool = true, count: Int = 1, pid: pid_t = 42, window: Bool = true,
            role: String = kAXTextFieldRole, placeholder: CFTypeRef? = "搜索文件名…" as CFString,
            placeholderStatus: AXError = .success, settableStatus: AXError = .success, settable: Bool = true) throws {
            try FileTreePublicSearchInputContract.requireGate(complete: complete, candidateCount: count,
                actualPID: pid, expectedPID: 42, sameWindow: window, role: role,
                placeholder: placeholder, placeholderStatus: placeholderStatus,
                settableStatus: settableStatus, settable: settable)
        }
        try gate(placeholder: marker)
        try FileTreePublicSearchInputContract.requireExactString("alpha" as CFString, status: .success,
            expected: "alpha", stage: "pure-positive")
        #expect(throws: External2991Failure.self) { try gate(complete: false) }
        #expect(throws: External2991Failure.self) { try gate(count: 0) }
        #expect(throws: External2991Failure.self) { try gate(count: 2) }
        #expect(throws: External2991Failure.self) { try gate(pid: 43) }
        #expect(throws: External2991Failure.self) { try gate(window: false) }
        #expect(throws: External2991Failure.self) { try gate(role: kAXStaticTextRole) }
        #expect(throws: External2991Failure.self) { try gate(placeholder: "foreign" as CFString) }
        #expect(throws: External2991Failure.self) { try gate(placeholder: nil) }
        #expect(throws: External2991Failure.self) { try gate(placeholder: NSNumber(value: 1)) }
        #expect(throws: External2991Failure.self) { try gate(placeholderStatus: .cannotComplete) }
        #expect(throws: External2991Failure.self) { try gate(settableStatus: .attributeUnsupported) }
        #expect(throws: External2991Failure.self) { try gate(settable: false) }
        #expect(throws: External2991Failure.self) {
            try FileTreePublicSearchInputContract.requireExactString("alpha" as CFString,
                status: .cannotComplete, expected: "alpha", stage: "raw-error")
        }
        #expect(throws: External2991Failure.self) {
            try FileTreePublicSearchInputContract.requireExactString(NSNumber(value: 1),
                status: .success, expected: "1", stage: "wrong-CF-type")
        }
        #expect(throws: External2991Failure.self) {
            try FileTreePublicSearchInputContract.requireExactString("beta" as CFString,
                status: .success, expected: "alpha", stage: "wrong-value")
        }
        do {
            try gate(settableStatus: .cannotComplete)
            Issue.record("Original provider AXError must remain fatal")
        } catch let failure as External2991Failure {
            #expect(failure.code == AXError.cannotComplete.rawValue)
        }
    }
}

// B1056 proposal: actual AppKit field-editor keyboard events, never a value/model setter.
// In-process NSWindow event dispatch is explicit: this is not an OS/HID/CGEvent-post claim.
@MainActor
private enum FileTreeRealEditorKeyboardInput {
    private static let placeholder = "搜索文件名…"

    // B1132: all fields are logged on rejection. The three system-active fields are observation only.
    private static func rejection(_ stage: String, window: NSWindow, expectedWindowID: String,
                                  expectedPID: pid_t, field: NSTextField? = nil,
                                  editor: NSTextView? = nil) -> External2991Failure {
        let app = NSApp
        let running = NSRunningApplication.current
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let fields: [String: Any] = [
            "stage": stage, "ownPID": getpid(), "expectedPID": expectedPID,
            "NSRunningOwnPID": running.processIdentifier,
            "ownPIDMatches": getpid() == expectedPID && running.processIdentifier == expectedPID,
            "NSAppPresent": app != nil, "windowNumber": window.windowNumber,
            "expectedAXID": expectedWindowID, "actualAXID": window.accessibilityIdentifier() as Any? ?? NSNull(),
            "exactAXIDMatches": window.accessibilityIdentifier() == expectedWindowID,
            "matchingAXIDCount": app.map { $0.windows.filter { $0.accessibilityIdentifier() == expectedWindowID }.count } as Any? ?? NSNull(),
            "windowVisible": window.isVisible, "belongsToAppWindows": app.map { $0.windows.contains { $0 === window } } as Any? ?? NSNull(),
            "keyWindowSame": app.map { $0.keyWindow === window } as Any? ?? NSNull(),
            "windowIsKey": window.isKeyWindow,
            "keyWindowNumber": app?.keyWindow?.windowNumber as Any? ?? NSNull(),
            "NSAppIsActiveObservationOnly": app?.isActive as Any? ?? NSNull(),
            "NSRunningIsActiveObservationOnly": running.isActive,
            "frontmostPIDObservationOnly": frontmostPID as Any? ?? NSNull(),
            "activationPolicyObservationOnly": app?.activationPolicy().rawValue as Any? ?? NSNull(),
            "diagnosticFieldReferenceProvided": field != nil, "diagnosticEditorReferenceProvided": editor != nil,
            "firstResponderClass": window.firstResponder.map { String(reflecting: type(of: $0)) } as Any? ?? NSNull(),
            "currentEditorSame": field.flatMap { target in editor.map { target.currentEditor() === $0 } } as Any? ?? NSNull(),
            "fieldSameWindow": field.map { $0.window === window } as Any? ?? NSNull(),
            "fieldCurrentEditorClass": field.flatMap { $0.currentEditor() }.map { String(reflecting: type(of: $0)) } as Any? ?? NSNull(),
            "firstResponderSameEditor": editor.map { window.firstResponder === $0 } as Any? ?? NSNull(),
            "editorSameWindow": editor.map { $0.window === window } as Any? ?? NSNull(),
            "editorIsFieldEditor": editor?.isFieldEditor as Any? ?? NSNull(),
            "editorMarkedText": editor?.hasMarkedText() as Any? ?? NSNull(),
            "editorStringCountOnly": editor?.string.count as Any? ?? NSNull(),
            "inputChannel": "owned NSWindow.sendEvent AppKit; not system foreground or HID",
            "retryOrActivation": false
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let encoded = String(data: bytes, encoding: .utf8) {
            print("D_ARCH3_B1132_KEYBOARD_GUARD_REJECTION " + encoded)
        } else {
            print("D_ARCH3_B1132_KEYBOARD_GUARD_REJECTION diagnosticEncodingFailed=true stage=\(stage)")
        }
        return External2991Failure(stage)
    }
    private static func currentWindow(_ window: NSWindow, expectedWindowID: String,
                                      expectedPID: pid_t, field: NSTextField? = nil,
                                      editor: NSTextView? = nil) throws {
        guard getpid() == expectedPID, NSRunningApplication.current.processIdentifier == expectedPID,
              let app = NSApp, window.isVisible, window.windowNumber > 0,
              window.accessibilityIdentifier() == expectedWindowID,
              app.windows.filter({ $0.accessibilityIdentifier() == expectedWindowID }).count == 1,
              app.windows.contains(where: { $0 === window }) else {
            throw rejection("P4-keyboard-owned-window-qualification-no-recovery", window: window,
                            expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
        }
    }
    private static func uniqueTextField(in window: NSWindow, expectedWindowID: String, expectedPID: pid_t) throws -> NSTextField {
        guard let root = window.contentView else { throw rejection("P4-keyboard-no-content", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID) }
        var queue: [(NSView, Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>(); var index = 0; var candidates: [NSTextField] = []
        while index < queue.count {
            let (view, depth) = queue[index]; index += 1
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            guard visited.count <= 512, depth <= 12 else {
                throw rejection("P4-keyboard-view-tree-partial", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
            }
            if let field = view as? NSTextField,
               field.placeholderString == placeholder || field.accessibilityPlaceholderValue() == placeholder {
                candidates.append(field)
            }
            guard depth < 12 || view.subviews.isEmpty else { throw rejection("P4-keyboard-view-depth", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID) }
            for child in view.subviews {
                guard queue.count < 512 else { throw rejection("P4-keyboard-view-queue", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID) }
                queue.append((child, depth + 1))
            }
        }
        guard candidates.count == 1, let field = candidates.first,
              field.window === window, field.isDescendant(of: root), field.isEditable, field.isEnabled,
              !field.isHiddenOrHasHiddenAncestor, field.bounds.width > 0, field.bounds.height > 0 else {
            throw rejection("P4-keyboard-real-field-not-unique-visible-editable", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
        }
        return field
    }
    private static func focused(_ field: NSTextField, editor: NSTextView,
                                window: NSWindow, expectedWindowID: String, expectedPID: pid_t) throws {
        try currentWindow(window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
        guard let root = window.contentView, field.window === window, field.isDescendant(of: root),
              field.currentEditor() === editor, window.firstResponder === editor,
              editor.isFieldEditor, editor.isEditable, editor.window === window,
              field.placeholderString == placeholder || field.accessibilityPlaceholderValue() == placeholder else {
            throw rejection("P4-keyboard-current-fieldeditor-focus-lost", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
        }
    }
    static func typeChosen(_ chosen: String, window: NSWindow, expectedWindowID: String, expectedPID: pid_t) throws {
        guard chosen == "alpha" || chosen == "beta" else { throw rejection("P4-keyboard-chosen-scope", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID) }
        try currentWindow(window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
        let field = try uniqueTextField(in: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
        guard field.stringValue.isEmpty else { throw rejection("P4-keyboard-initial-field-not-empty", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field) }
        // One public focus request; no click, AX focus/value setter, selectAll or replacement text.
        guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            throw rejection("P4-keyboard-real-editor-focus-refused", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field)
        }
        try focused(field, editor: editor, window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
        guard editor.string.isEmpty, !editor.hasMarkedText() else {
            throw rejection("P4-keyboard-editor-not-empty-or-composing", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
        }
        print("ARCH3_P4_KEYBOARD_FOCUS requests=1 actualFieldClass=\(String(reflecting: type(of: field))) actualEditorClass=\(String(reflecting: type(of: editor))) pid=\(getpid()) window=\(window.windowNumber) firstResponderExact=true editorEmpty=true")
        let codes: [Character: UInt16] = ["a": 0, "b": 11, "e": 14, "h": 4, "l": 37, "p": 35, "t": 17]
        var expectedPrefix = ""; var downs = 0; var ups = 0
        for character in chosen {
            try focused(field, editor: editor, window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
            guard editor.string == expectedPrefix, !editor.hasMarkedText(), let code = codes[character] else {
                throw rejection("P4-keyboard-before-pair-prefix-or-composition", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
            }
            let text = String(character)
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code),
                  let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw rejection("P4-keyboard-event-construction", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
            }
            window.sendEvent(down); downs += 1
            try focused(field, editor: editor, window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
            window.sendEvent(up); ups += 1
            try focused(field, editor: editor, window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID)
            expectedPrefix.append(character)
            guard editor.string == expectedPrefix, !editor.hasMarkedText() else {
                throw rejection("P4-keyboard-after-pair-prefix-or-composition-no-retry", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
            }
            print("ARCH3_P4_KEYBOARD_PAIR pid=\(getpid()) window=\(window.windowNumber) downs=\(downs) ups=\(ups) prefix=\(expectedPrefix) focusExact=true inputChannel=NSWindow.sendEvent keyRepeat=false")
        }
        guard downs == chosen.count, ups == chosen.count, editor.string == chosen else {
            throw rejection("P4-keyboard-complete-count-or-real-editor-value", window: window, expectedWindowID: expectedWindowID, expectedPID: expectedPID, field: field, editor: editor)
        }
        // Real editor readback is not a SwiftUI model assertion; the original filter predicate follows.
        print("ARCH3_P4_KEYBOARD_COMPLETE chosen=\(chosen) down=\(downs) up=\(ups) secondInput=false noCommitKey=true noFallback=true")
    }
}
