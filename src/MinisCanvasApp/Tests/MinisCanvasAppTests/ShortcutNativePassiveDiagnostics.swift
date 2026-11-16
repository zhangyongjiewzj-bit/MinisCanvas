#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS
import AppKit
import ApplicationServices
import Foundation
@testable import MinisCanvasApp

/// Test-only metadata. No AX lookup/action, dequeue/sendEvent, activation,
/// characters, new assertion, store mutation or production UI fields.
@MainActor
enum ShortcutNativePassiveDiagnostics {
    private static var expectedWindowNumber: Int?
    private static weak var sourceWindow: NSWindow?
    private static var receiveCount = 0
    private static var emitted = 0
    private static var last: [String: Any]?
    private static var previous: (@MainActor (ShortcutRecorderModel.NativeMonitorObservation) -> Void)?

    private static func emit(_ fields: [String: Any], final: Bool = false) {
        guard final || emitted < 64 else { return }
        emitted += 1
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("SHORTCUT_B1213_PASSIVE=" + text)
        } else { print("SHORTCUT_B1213_PASSIVE_ENCODING_FAILED") }
    }
    static func install(window: NSWindow) {
        expectedWindowNumber = window.windowNumber
        sourceWindow = window
        receiveCount = 0; emitted = 0; last = nil
        previous = ShortcutRecorderModel.testLocalMonitorObserver
        ShortcutRecorderModel.testLocalMonitorObserver = { facts in
            receiveCount += 1
            let metadata: [String: Any] = [
                "phase": "production-localMonitor-callback-entry", "count": receiveCount,
                "keyCode": facts.keyCode, "modifiers": facts.modifiers,
                "windowNumber": facts.windowNumber, "timestamp": facts.timestamp,
                "expectedWindowMatches": facts.windowNumber == expectedWindowNumber,
                "recordingActionID": facts.recordingActionID as Any? ?? NSNull(),
                "receiverAlive": facts.receiverAlive
            ]
            last = metadata
            emit(metadata)
            previous?(facts)
        }
        emit(["phase": "installed-test-observer", "windowNumber": window.windowNumber,
              "previousObserverPresent": previous != nil, "newAXLookupOrEvent": false])
    }
    static func finish() {
// B1555_DUAL_BEGIN
#if MINISCANVAS_SHORTCUT_DUAL_READONLY_FOCUS_B1555
        resetB1555Focus()
#endif
// B1555_DUAL_END
        emit(["phase": "test-observer-final", "receivedCount": receiveCount,
              "lastReceived": last as Any? ?? NSNull()], final: true)
        ShortcutRecorderModel.testLocalMonitorObserver = previous
        previous = nil; expectedWindowNumber = nil; sourceWindow = nil
    }
    static func found(_ object: AnyObject, identifier: String, window: NSWindow) {
        emit(["phase": "original-found-control", "identifier": identifier,
              "actualClass": String(reflecting: type(of: object)),
              "isAXUIElement": CFGetTypeID(object) == AXUIElementGetTypeID(),
              "conformsNSAccessibilityProtocol": object is NSAccessibilityProtocol,
              "windowNumber": window.windowNumber])
    }
    static func key(_ event: NSEvent, phase: String) {
        emit(["phase": phase, "keyCode": event.keyCode,
              "modifiers": event.modifierFlags.rawValue, "windowNumber": event.windowNumber,
              "timestamp": event.timestamp, "eventType": event.type.rawValue,
              "NSApp_isActive": NSApp.isActive,
              "keyWindowIsSourceWindow": sourceWindow != nil && NSApp.keyWindow === sourceWindow,
              "keyWindowNumber": NSApp.keyWindow.map { $0.windowNumber as Any } ?? NSNull(),
              "sourceWindowNumber": sourceWindow.map { $0.windowNumber as Any } ?? NSNull()])
    }
    static func pressBranch(_ object: AnyObject, branch: String) {
        emit(["phase": "original-press-branch", "branch": branch,
              "actualClass": String(reflecting: type(of: object))])
    }
    static func protocolPress(_ object: AnyObject, accepted: Bool) {
        emit(["phase": "original-protocol-press-return", "accepted": accepted,
              "actualClass": String(reflecting: type(of: object))])
    }
    static func publicPress(_ object: AnyObject, status: Int32, branch: String) {
        emit(["phase": "original-public-AXPress-return", "status": status,
              "branch": branch, "actualClass": String(reflecting: type(of: object))])
    }
    static func legacyPressReturned() {
        emit(["phase": "original-legacy-perform-returned", "typedNativeStatus": NSNull(),
              "originalReturn": true, "reason": "original selector return ignored; no invented AXError"])
    }
}
#endif

#if MINISCANVAS_SHORTCUT_EVENT_DIAGNOSTICS && MINISCANVAS_SHORTCUT_TITLEBAR_HANDOFF
import CryptoKit
import Darwin
import Dispatch

private enum ShortcutTitlebarGateFailure: Error { case rejected(String) }

/// Tests-only protocol boundary. It never activates, clicks, pumps or changes a recorder/store.
@MainActor
private final class ShortcutTitlebarGateWaiter {
    private let config: [String: Any]
    private let directory: String
    private let witnessPath: String
    private let ackPath: String
    private let consumedPath: String
    private let deadline: Date
    private weak var window: NSWindow?
    private let witness: [String: Any]
    private var witnessSHA = ""
    private var continuation: CheckedContinuation<Void, any Error>?
    private var source: (any DispatchSourceFileSystemObject)?
    private var timer: (any DispatchSourceTimer)?
    private var finishing = false
    private var fd: Int32 = -1

    private static func require(_ predicate: Bool, _ reason: String) throws {
        if !predicate { throw ShortcutTitlebarGateFailure.rejected(reason) }
    }
    private static func digest(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func physical(_ path: String, directory: Bool, mode: mode_t) throws -> stat {
        var info = stat(), actual = stat()
        try require(path.hasPrefix("/") && lstat(path, &info) == 0,
                    "physical-path")
        try require(info.st_uid == geteuid() && info.st_mode & 0o777 == mode,
                    "physical-owner-mode")
        try require(info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                    "physical-type")
        if !directory { try require(info.st_nlink == 1, "physical-nlink") }
        guard let resolved = realpath(path, nil) else {
            throw ShortcutTitlebarGateFailure.rejected("physical-realpath")
        }
        defer { free(resolved) }
        try require(stat(String(cString: resolved), &actual) == 0
                    && actual.st_dev == info.st_dev && actual.st_ino == info.st_ino,
                    "physical-devino")
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" {
            var value = stat()
            try require(lstat(parent, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
                        && (value.st_uid == geteuid() || value.st_uid == 0)
                        && value.st_mode & 0o022 == 0, "physical-parent")
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        return info
    }
    private static func object(_ path: String) throws -> [String: Any] {
        _ = try physical(path, directory: false, mode: 0o600)
        guard let value = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
            throw ShortcutTitlebarGateFailure.rejected("object-schema")
        }
        return value
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw ShortcutTitlebarGateFailure.rejected("missing-" + key)
        }
        return value
    }
    private static func exclusive(_ path: String, _ value: [String: Any]) throws {
        let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(output >= 0, "exclusive-create")
        defer { close(output) }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                try require(count > 0, "exclusive-write")
                offset += count
            }
        }
        try require(fsync(output) == 0, "exclusive-fsync")
    }

    init(window: NSWindow) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let configPath = environment["MINISCANVAS_SHORTCUT_TITLEBAR_HANDOFF_PLAN"] else {
            throw ShortcutTitlebarGateFailure.rejected("default-off-no-root-config")
        }
        let config = try Self.object(configPath)
        try Self.require(config["start"] as? Bool == true
                         && config["root_exclusive_native_slot"] as? Bool == true
                         && config["formal_guard_qualification_approved"] as? Bool == true,
                         "root-or-formal-qualification-not-approved")
        try Self.require(config["scope"] as? String == "COMMAND04_B1325_TITLEBAR_HANDOFF_V1",
                         "exact-scope")
        let nonce = try Self.string(config, "nonce")
        try Self.require(UUID(uuidString: nonce) != nil, "fresh-nonce")
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: try Self.string(config, "not_before_utc")),
              let deadline = formatter.date(from: try Self.string(config, "deadline_utc")) else {
            throw ShortcutTitlebarGateFailure.rejected("root-clock")
        }
        try Self.require(start <= Date() && Date() < deadline
                         && deadline.timeIntervalSince(start) <= 360, "root-clock-range")
        let directory = try Self.string(config, "handoff_directory")
        _ = try Self.physical(directory, directory: true, mode: 0o700)
        guard let scratch = environment["MINISCANVAS_TEST_SCRATCH_DIRECTORY"],
              let formalRoot = environment["MINISCANVAS_TEST_DIRECTORY"],
              let profile = environment["MINISCANVAS_PROFILE_IDENTITY"] else {
            throw ShortcutTitlebarGateFailure.rejected("formal-profile")
        }
        try Self.require(directory.hasPrefix(scratch + "/")
                         && config["formal_root"] as? String == formalRoot
                         && config["profile_identity"] as? String == profile,
                         "exact-formal-root-and-profile")
        let rootStat = try Self.physical(formalRoot, directory: true, mode: 0o700)
        var birth = proc_bsdinfo()
        try Self.require(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &birth,
                         Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                         "own-kernel-birth")
        var executable = [CChar](repeating: 0, count: 4096)
        try Self.require(proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0,
                         "own-kernel-path")
        guard let terminator = executable.firstIndex(of: 0) else {
            throw ShortcutTitlebarGateFailure.rejected("own-kernel-path-unterminated")
        }
        let hostPath = String(decoding: executable[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let hostSHA = try Self.digest(hostPath)
        let bundlePath = try Self.string(config, "bundle_path")
        let arguments = CommandLine.arguments
        guard let bundleIndex = arguments.firstIndex(of: "--test-bundle-path"),
              arguments.indices.contains(bundleIndex + 1) else {
            throw ShortcutTitlebarGateFailure.rejected("actual-dso-argument")
        }
        try Self.require(arguments[bundleIndex + 1] == bundlePath
                         && config["host_path"] as? String == hostPath
                         && config["host_sha256"] as? String == hostSHA
                         && config["bundle_sha256"] as? String == (try Self.digest(bundlePath)),
                         "own-host-dso-hashes")
        try Self.require(window.windowNumber > 0 && window.isVisible
                         && !window.accessibilityIdentifier().isEmpty, "original-window-ready")
        let witnessPath = directory + "/ready.json"
        let ackPath = directory + "/ack.json"
        let consumedPath = directory + "/ack-consumed.json"
        try Self.require(!FileManager.default.fileExists(atPath: witnessPath)
                         && !FileManager.default.fileExists(atPath: ackPath)
                         && !FileManager.default.fileExists(atPath: consumedPath), "fresh-gate-files")
        self.config = config
        self.directory = directory
        self.witnessPath = witnessPath
        self.ackPath = ackPath
        self.consumedPath = consumedPath
        self.deadline = deadline
        self.window = window
        self.witness = [
            "schema": "miniscanvas.shortcut-native-titlebar-ready/v1",
            "phase": "ORIGINAL_SHORTCUT_WINDOW_READY_BEFORE_BUSINESS",
            "mode": "formalTest", "nonce": nonce,
            "pid": Int(getpid()), "uid": Int(geteuid()),
            "generation": ["pid": Int(getpid()), "uid": Int(geteuid()),
                           "start_sec": birth.pbi_start_tvsec, "start_usec": birth.pbi_start_tvusec],
            "binary": hostPath, "binary_sha256": hostSHA,
            "bundle_path": bundlePath, "bundle_sha256": config["bundle_sha256"]!,
            "root_path": formalRoot, "root_device": UInt64(rootStat.st_dev),
            "root_inode": UInt64(rootStat.st_ino), "profile_identity": profile,
            "window_id": window.windowNumber, "window_identifier": window.accessibilityIdentifier(),
            "observed_epoch_ms": Date().timeIntervalSince1970 * 1000,
            "no_placeholder_or_new_pump": true
        ]
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                fd = open(directory, O_EVTONLY | O_NOFOLLOW)
                try Self.require(fd >= 0, "handoff-watch-open")
                let queue = DispatchQueue(label: "miniscanvas.shortcut-titlebar-handoff")
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                self.source = source; self.timer = timer
                source.setEventHandler { [weak self] in
                    Task { @MainActor in self?.receiveIfPublished() }
                }
                timer.setEventHandler { [weak self] in
                    Task { @MainActor in self?.cancel("root-deadline") }
                }
                timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow), leeway: .milliseconds(10))
                source.resume(); timer.resume()
                try Self.exclusive(witnessPath, witness)
                witnessSHA = try Self.digest(witnessPath)
                print("SHORTCUT_TITLEBAR_READY=\(witnessPath) sha256=\(witnessSHA)")
                receiveIfPublished()
            } catch { finish(.failure(error)) }
        }
    }
    func cancel(_ reason: String) {
        finish(.failure(ShortcutTitlebarGateFailure.rejected(reason)))
    }
    private func receiveIfPublished() {
        guard !finishing, FileManager.default.fileExists(atPath: ackPath) else { return }
        do {
            try Self.require(Date() < deadline && !Task.isCancelled, "ack-deadline-or-cancel")
            let ack = try Self.object(ackPath)
// B1555_DUAL_BEGIN
#if MINISCANVAS_SHORTCUT_DUAL_READONLY_FOCUS_B1555
            if config["focus_qualification_method"] as? String == "B_READONLY_PRE_AND_PUBLIC4_TWO_SNAPSHOTS" {
                try receiveDualReadOnly(ack)
                return
            }
#endif
// B1555_DUAL_END
            try Self.require(ack["schema"] as? String == "miniscanvas.shortcut-titlebar-post-ack/v1"
                             && ack["nonce"] as? String == witness["nonce"] as? String
                             && ack["witness_sha256"] as? String == witnessSHA,
                             "ack-schema-nonce-witness")
            let postPath = try Self.string(config, "native_post_path")
            let ownerPath = try Self.string(config, "native_post_owner_custody_path")
            try Self.require(postPath.hasPrefix(directory + "/") && ownerPath.hasPrefix(directory + "/")
                             && ack["native_post_path"] as? String == postPath
                             && ack["native_post_sha256"] as? String == (try Self.digest(postPath))
                             && ack["native_post_owner_custody_path"] as? String == ownerPath
                             && ack["native_post_owner_custody_sha256"] as? String == (try Self.digest(ownerPath)),
                             "actual-post-and-owner-hashes")
            let post = try Self.object(postPath), owner = try Self.object(ownerPath)
            try Self.require(owner["HOST_REAL_EXIT"] as? Int == 0
                             && owner["real_wait"] as? Bool == true && owner["stdout_EOF"] as? Bool == true
                             && owner["stdout_FD_closed"] as? Bool == true && owner["selector_closed"] as? Bool == true
                             && owner["all_observed_owned_generations_settled"] as? Bool == true
                             && (owner["signals"] as? [Any])?.isEmpty == true
                             && (owner["collection_errors"] as? [Any])?.isEmpty == true,
                             "native-post-actual-wait-eof-fd")
            let guardSHA = try Self.string(config, "guard_binary_sha256")
            let guardPath = try Self.string(config, "guard_binary_path")
            try Self.require(guardSHA.count == 64 && (try Self.digest(guardPath)) == guardSHA
                             && post["guard_binary_sha256"] as? String == guardSHA
                             && post["status"] as? String == "POST_GUARD_PASS_PUBLIC_NATIVE_MAPPING"
                             && post["pid"] as? Int == witness["pid"] as? Int
                             && post["window_id"] as? Int == witness["window_id"] as? Int
                             && post["binary"] as? String == witness["binary"] as? String
                             && post["binary_sha256"] as? String == witness["binary_sha256"] as? String
                             && post["handoff_nonce"] as? String == witness["nonce"] as? String
                             && post["witness_sha256"] as? String == witnessSHA,
                             "post-same-host-window-nonce")
            guard let observedBirth = post["generation"] as? NSDictionary,
                  let expectedBirth = witness["generation"] as? NSDictionary else {
                throw ShortcutTitlebarGateFailure.rejected("post-generation")
            }
            try Self.require(observedBirth.isEqual(expectedBirth), "post-same-generation")
            try Self.require(post["fresh_frontmostPID"] as? Int == Int(getpid())
                             && post["NSRunningApplication_isActive"] as? Bool == true
                             && post["AXFocusedWindow_equals_selected"] as? Bool == true
                             && post["AXMainWindow_equals_selected"] as? Bool == true
                             && post["private_NSApp_mapping_B_accepted"] as? Bool == true,
                             "actual-public-four-field-post")
            guard let freshness = post["freshness_runloop"] as? [String: Any],
                  let ended = freshness["ended_epoch"] as? Double,
                  let readyMS = witness["observed_epoch_ms"] as? Double,
                  let call = post["cua_call_receipt"] as? [String: Any] else {
                throw ShortcutTitlebarGateFailure.rejected("post-freshness-receipt")
            }
            let now = Date().timeIntervalSince1970
            try Self.require(ended >= readyMS / 1000 && ended <= now && now - ended < 5
                             && call["call_count"] as? Int == 1
                             && call["status"] as? String == "RETURNED_VOID", "one-click-fresh-post")
            guard let window else { throw ShortcutTitlebarGateFailure.rejected("original-window-gone") }
            try Self.require(window.windowNumber == witness["window_id"] as? Int
                             && NSApp.isActive && NSApp.keyWindow === window,
                             "actual-in-process-active-key-original-window")
            try Self.exclusive(consumedPath, ["schema": "miniscanvas.shortcut-titlebar-ack-consumed/v1",
                "nonce": witness["nonce"]!, "witness_sha256": witnessSHA,
                "ack_sha256": try Self.digest(ackPath), "pid": Int(getpid()),
                "window_id": window.windowNumber, "consumed_epoch": now])
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<Void, any Error>) {
        guard !finishing else { return }; finishing = true
        timer?.cancel()
        guard let source else {
            if fd >= 0 { close(fd); fd = -1 }
            didClose(result); return
        }
        let descriptor = fd; fd = -1
        source.setCancelHandler { [weak self] in
            if descriptor >= 0 { close(descriptor) }
            Task { @MainActor in self?.didClose(result) }
        }
        source.cancel()
    }
    private func didClose(_ result: Result<Void, any Error>) {
        source = nil; timer = nil
        let pending = continuation; continuation = nil
        print("SHORTCUT_TITLEBAR_GATE_TERMINAL fdClosed=true waitResumedOnce=true result=\(String(describing: result))")
        pending?.resume(with: result)
    }
}

extension ShortcutNativePassiveDiagnostics {
    static func awaitValidatedTitlebarPost(window: NSWindow) async throws {
        try Task.checkCancellation()
        let waiter = try ShortcutTitlebarGateWaiter(window: window)
        try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            Task { @MainActor in waiter.cancel("testing-task-cancelled") }
        }
    }
}
#endif
// B1555_DUAL_BEGIN
#if MINISCANVAS_SHORTCUT_DUAL_READONLY_FOCUS_B1555

@MainActor
private extension ShortcutTitlebarGateWaiter {
    func receiveDualReadOnly(_ ack: [String: Any]) throws {
        try Self.require(config["dual_readonly_focus_B_qualified"] as? Bool == true
            && ack["schema"] as? String == "miniscanvas.shortcut-dual-readonly-focus-ack/v1"
            && ack["nonce"] as? String == witness["nonce"] as? String
            && ack["witness_sha256"] as? String == witnessSHA, "B1555-explicit-dual-schema-no-legacy-fallback")
        let bPath = try Self.string(config, "B1555_path"), bSHA = try Self.string(config, "B1555_sha256")
        try Self.require((try Self.digest(bPath)) == bSHA && ack["B1555_sha256"] as? String == bSHA, "B1555-authority-pin")
        let observerPath = try Self.string(config, "readonly_observer_path")
        let observerSHA = try Self.string(config, "readonly_observer_sha256")
        try Self.require((try Self.digest(observerPath)) == observerSHA, "B1555-observer-exact-binary")
        guard let items = ack["readonly_snapshot_records"] as? [[String: Any]], items.count == 2 else {
            throw ShortcutTitlebarGateFailure.rejected("B1555-exact-two-independent-snapshots")
        }
        let nowMS = Date().timeIntervalSince1970 * 1000
        var lastObserved = -Double.infinity
        var previousFrame: NSDictionary?
        var previousKnown = Set<String>()
        var seenPaths = Set<String>(), seenHashes = Set<String>()
        for (index, item) in items.enumerated() {
            let path = try Self.string(item, "path"), custodyPath = try Self.string(item, "custody_path")
            try Self.require(path.hasPrefix(directory + "/") && custodyPath.hasPrefix(directory + "/")
                && seenPaths.insert(path).inserted && seenPaths.insert(custodyPath).inserted, "B1555-independent-own-paths")
            let digest = try Self.digest(path)
            try Self.require(item["sha256"] as? String == digest && seenHashes.insert(digest).inserted
                && item["custody_sha256"] as? String == (try Self.digest(custodyPath)), "B1555-snapshot-owner-hashes")
            let row = try Self.object(path), owner = try Self.object(custodyPath)
            try Self.require(owner["HOST_REAL_EXIT"] as? Int == 0 && owner["real_wait"] as? Bool == true
                && owner["stdout_EOF"] as? Bool == true && owner["stdout_FD_closed"] as? Bool == true
                && owner["selector_closed"] as? Bool == true && owner["all_observed_owned_generations_settled"] as? Bool == true
                && (owner["signals"] as? [Any])?.isEmpty == true && (owner["collection_errors"] as? [Any])?.isEmpty == true,
                "B1555-actual-independent-child-wait-eof-fd")
            guard let known = owner["known"] as? [String: Any], !known.isEmpty else {
                throw ShortcutTitlebarGateFailure.rejected("B1555-known-child-receipt")
            }
            let knownIDs = Set(known.keys)
            try Self.require(previousKnown.isDisjoint(with: knownIDs), "B1555-distinct-child-owners")
            previousKnown.formUnion(knownIDs)
            try Self.require(row["status"] as? String == "READONLY_PRE_PUBLIC4_PASS"
                && row["method"] as? String == "B_READONLY_PRE_AND_PUBLIC4_TWO_SNAPSHOTS"
                && row["phase"] as? String == "observe\(index + 1)"
                && row["observer_binary_sha256"] as? String == observerSHA
                && row["CUA"] as? Int == 0 && row["click"] as? Int == 0 && row["getApp"] as? Int == 0,
                "B1555-readonly-status-never-post-or-returned-void")
            try Self.require(row["pid"] as? Int == witness["pid"] as? Int
                && row["window_id"] as? Int == witness["window_id"] as? Int
                && row["binary"] as? String == witness["binary"] as? String
                && row["binary_sha256"] as? String == witness["binary_sha256"] as? String
                && row["witness_sha256"] as? String == witnessSHA
                && row["handoff_nonce"] as? String == witness["nonce"] as? String
                && (row["generation"] as? NSDictionary)?.isEqual(witness["generation"] as? NSDictionary ?? [:]) == true,
                "B1555-same-actual-host-generation-window-witness")
            try Self.require(row["pre_public_native_state_satisfied"] as? Bool == true
                && row["public_post_state_satisfied"] as? Bool == true
                && row["systemwide_hit_status"] as? Int == 0 && row["systemwide_hit_owner_status"] as? Int == 0
                && row["systemwide_hit_owner_pid"] as? Int == Int(getpid())
                && row["systemwide_hit_owner_verified_before_attributes"] as? Bool == true
                && row["own_hit_ancestor_verified"] as? Bool == true && row["hit_is_exact_main_or_titleUIElement"] as? Bool == true,
                "B1555-own-hit-and-both-public-samples-required")
            guard let first = row["pre_public_native_state"] as? [String: Any] else {
                throw ShortcutTitlebarGateFailure.rejected("B1555-first-public-fields")
            }
            for publicRow in [first, row] {
                try Self.require(publicRow["fresh_frontmostPID"] as? Int == Int(getpid())
                    && publicRow["NSRunningApplication_isActive"] as? Bool == true
                    && publicRow["AXFocusedWindow_equals_selected"] as? Bool == true
                    && publicRow["AXMainWindow_equals_selected"] as? Bool == true, "B1555-all-four-fields-strict")
            }
            try Self.require(row["NSApp_isActive_direct"] as? String == "UNREADABLE_EXTERNAL_PROCESS"
                && row["NSApp_keyWindow_pointer_equality_direct"] as? String == "UNREADABLE_EXTERNAL_PROCESS", "B1555-private-getters-not-faked")
            guard let observed = row["observed_epoch_ms"] as? Double, let valid = row["valid_until_epoch_ms"] as? Double,
                let frame = row["window_frame"] as? NSDictionary, let point = row["click_point_CG_global"] as? [String: Double],
                let x = frame["x"] as? Double, let y = frame["y"] as? Double,
                let width = frame["width"] as? Double, let height = frame["height"] as? Double,
                let px = point["x"], let py = point["y"] else { throw ShortcutTitlebarGateFailure.rejected("B1555-original-geometry-clock") }
            try Self.require([observed,valid,x,y,width,height,px,py].allSatisfy(\.isFinite)
                && observed >= (witness["observed_epoch_ms"] as? Double ?? .infinity) && observed > lastObserved
                && observed <= nowMS && nowMS < valid && valid - observed <= 5000
                && width >= 400 && height >= 200 && px > x + 120 && px < x + width - 120
                && abs(px - (x + width / 2)) < 0.01 && abs(py - (y + 12)) < 0.01, "B1555-two-original-fresh-geometry-predicates")
            if let previousFrame { try Self.require(previousFrame.isEqual(frame), "B1555-same-window-frame") }
            previousFrame = frame; lastObserved = observed
        }
        guard let window else { throw ShortcutTitlebarGateFailure.rejected("B1555-original-window-gone") }
        try Self.require(window.windowNumber == witness["window_id"] as? Int
            && NSApp.isActive && NSApp.keyWindow === window, "B1555-actual-inprocess-active-key-original-window")
        try Self.exclusive(consumedPath, ["schema":"miniscanvas.shortcut-dual-readonly-focus-consumed/v1",
            "nonce":witness["nonce"]!, "witness_sha256":witnessSHA, "ack_sha256":try Self.digest(ackPath),
            "pid":Int(getpid()), "window_id":window.windowNumber, "consumed_epoch":Date().timeIntervalSince1970,
            "CUA":0,"click":0,"getApp":0])
        ShortcutNativePassiveDiagnostics.acceptB1555Focus(window: window)
        finish(.success(()))
    }
}

@MainActor
extension ShortcutNativePassiveDiagnostics {
    private static var dualReadOnlyWindowID: Int?
    static func acceptB1555Focus(window: NSWindow) { dualReadOnlyWindowID = window.windowNumber }
    static func resetB1555Focus() { dualReadOnlyWindowID = nil }
    static func requireB1555FocusIfSelected(window: NSWindow) throws {
        guard let expected = dualReadOnlyWindowID else { return } // legacy route remains unchanged.
        guard expected == window.windowNumber, sourceWindow === window,
              NSApp.isActive, NSApp.keyWindow === window,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              NSRunningApplication(processIdentifier: getpid())?.isActive == true else {
            throw ShortcutTitlebarGateFailure.rejected("B1555-before-input-private-and-public-active-key")
        }
        let app = AXUIElementCreateApplication(getpid()); AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { throw ShortcutTitlebarGateFailure.rejected("B1555-before-input-windows") }
        func copied(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }; return v
        }
        var selected: [AXUIElement] = []
        for e in windows {
            var pid: pid_t = 0
            guard AXUIElementGetPid(e, &pid) == .success, pid == getpid() else { throw ShortcutTitlebarGateFailure.rejected("B1555-before-input-own-window") }
            if copied(e, "AXIdentifier") as? String == window.accessibilityIdentifier() { selected.append(e) }
        }
        guard selected.count == 1, let focused = copied(app, kAXFocusedWindowAttribute), let main = copied(app, kAXMainWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFGetTypeID(main) == AXUIElementGetTypeID(),
              CFEqual(focused, selected[0]), CFEqual(main, selected[0]) else {
            throw ShortcutTitlebarGateFailure.rejected("B1555-before-input-fresh-public-main-focused")
        }
        // No activation, input action, event send/dequeue, new pump, sleep, or state mutation.
    }
}

#endif
// B1555_DUAL_END
