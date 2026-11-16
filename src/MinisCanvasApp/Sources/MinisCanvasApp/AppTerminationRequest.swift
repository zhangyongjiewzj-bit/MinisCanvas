import AppKit
import Foundation
import Darwin

/// The non-Sendable Foundation token never escapes this main-actor owner.
@MainActor
private final class QuitSheetEndObservation {
    private var token: NSObjectProtocol?

    init(_ action: @escaping AppTerminationRequest.Action) {
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { action() } }
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

/// Owns only the interval between a user's Quit request and Cocoa termination.
/// Approval/settings dismissal happens in the product, never in the UI driver.
@MainActor
final class AppTerminationRequest {
    typealias Action = @MainActor () -> Void
    typealias Cancellation = @MainActor () -> Void
    typealias Registration = (@escaping Action) -> Cancellation

    enum Outcome: Equatable { case idle, preparing, waitingForSheet, forwarded, timedOut }
    private(set) var outcome: Outcome = .idle
    private var requestID: UUID?
    private var cancelObservation: Cancellation?
    private var cancelScheduledResume: Cancellation?
    private var cancelTimeout: Cancellation?
    private var checkScheduled = false
    private var burstChecksRemaining = 0
    private var totalChecksRemaining = 0
    private let hasAttachedSheet: () -> Bool
    private let terminate: Action
    private let observeSheetEnd: Registration
    private let scheduleResume: Registration
    private let scheduleTimeout: Registration

    convenience init() {
        self.init(
            hasAttachedSheet: { NSApplication.shared.windows.contains { $0.attachedSheet != nil } },
            terminate: { NSApplication.shared.terminate(nil) },
            observeSheetEnd: { action in
                let observation = QuitSheetEndObservation(action)
                return { observation.cancel() }
            },
            scheduleResume: { action in
                let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: item)
                return { item.cancel() }
            },
            scheduleTimeout: { action in
                let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
                return { item.cancel() }
            }
        )
    }

    init(hasAttachedSheet: @escaping () -> Bool, terminate: @escaping Action,
         observeSheetEnd: @escaping Registration, scheduleResume: @escaping Registration,
         scheduleTimeout: @escaping Registration) {
        self.hasAttachedSheet = hasAttachedSheet
        self.terminate = terminate
        self.observeSheetEnd = observeSheetEnd
        self.scheduleResume = scheduleResume
        self.scheduleTimeout = scheduleTimeout
    }

    /// Returns true only when this Quit owns an approval or Settings dismissal.
    /// Other dialogs retain Cocoa's original terminate/cancel behavior.
    func request(prepareOwnedPresentations: () -> Bool) {
        guard requestID == nil else { return }
        let id = UUID()
        requestID = id
        outcome = .preparing
        totalChecksRemaining = 16
        cancelObservation = observeSheetEnd { [weak self] in
            // didEndSheet can precede clearing attachedSheet. Never decide
            // synchronously from this notification; at most eight deferred
            // checks follow it, within the per-request total of sixteen.
            self?.enqueueChecks(id, budget: 8)
        }
        let ownedPresentation = prepareOwnedPresentations()
        guard ownedPresentation else {
            clearOwnedCallbacks()
            outcome = .forwarded
            terminate()
            return
        }
        outcome = .waitingForSheet
        cancelTimeout = scheduleTimeout { [weak self] in self?.expire(id) }
        enqueueChecks(id, budget: 4)
    }

    /// Session-ending AppleEvents must not wait for a UI dismissal callback.
    func cancelForSystemTermination() {
        clearOwnedCallbacks()
        outcome = .forwarded
    }

    private func enqueueChecks(_ id: UUID, budget: Int = 0) {
        guard requestID == id, outcome == .waitingForSheet else { return }
        burstChecksRemaining = max(burstChecksRemaining, budget)
        guard !checkScheduled, burstChecksRemaining > 0, totalChecksRemaining > 0 else { return }
        checkScheduled = true
        burstChecksRemaining -= 1
        totalChecksRemaining -= 1
        cancelScheduledResume = scheduleResume { [weak self] in self?.resumeIfReady(id) }
    }

    private func resumeIfReady(_ id: UUID) {
        guard requestID == id, outcome == .waitingForSheet else { return }
        checkScheduled = false
        cancelScheduledResume = nil // this scheduled callback has actually run
        guard !hasAttachedSheet() else {
            enqueueChecks(id)
            return
        }
        clearOwnedCallbacks()
        outcome = .forwarded
        terminate()
    }

    private func expire(_ id: UUID) {
        guard requestID == id else { return }
        clearOwnedCallbacks()
        outcome = .timedOut
    }

    private func clearOwnedCallbacks() {
        requestID = nil
        checkScheduled = false
        burstChecksRemaining = 0
        totalChecksRemaining = 0
        cancelObservation?(); cancelObservation = nil
        cancelScheduledResume?(); cancelScheduledResume = nil
        cancelTimeout?(); cancelTimeout = nil
    }
}

/// Runs only at Cocoa's final termination boundary, after the existing owned
/// sheet coordinator has forwarded Quit. Empty exits never enter this owner.
@MainActor
final class AppToolTerminationDrain {
    typealias Action = @MainActor () -> Void
    typealias Registration = (@escaping Action) -> Action
    private var requestID: UUID?
    private var cancelDeadline: Action?
    private let scheduleDeadline: Registration

    init(scheduleDeadline: @escaping Registration = { action in
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
        return { item.cancel() }
    }) {
        self.scheduleDeadline = scheduleDeadline
    }

    var isWaiting: Bool { requestID != nil }

    func request(start: (@escaping Action) -> Void, reply: @escaping Action) {
        guard requestID == nil else { return }
        let id = UUID()
        requestID = id
        let finish: Action = { [weak self] in
            guard let self, self.requestID == id else { return }
            self.requestID = nil
            self.cancelDeadline?()
            self.cancelDeadline = nil
            reply()
        }
        // An uncooperative tool cannot hang application termination. This
        // bound is not evidence that physical cleanup succeeded.
        cancelDeadline = scheduleDeadline(finish)
        start(finish)
    }
}

/// One bounded handoff to this executable, not a resident service. The relay
/// branch exits before any profile/store composition and launches only after
/// its exact parent has exited. No original environment is forwarded.
@MainActor
enum SafeModeRelaunch {
    static let argument = "--miniscanvas-safe-relaunch-relay"
    enum Failure: Error { case refused }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        // sys/proc_info.h: PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN;
        // sys/param.h aliases MAXPATHLEN to the imported PATH_MAX constant.
        let capacity = 4 * Int(PATH_MAX)
        var path = [CChar](repeating: 0, count: capacity)
        guard proc_pidpath(pid, &path, UInt32(capacity)) > 0,
              let terminator = path.firstIndex(of: 0) else { return nil }
        let decoded = String(decoding: path[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: decoded).resolvingSymlinksInPath().path
    }

    private static func rootMatches(_ path: String, device: UInt64, inode: UInt64) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat(), named = stat()
        return fstat(fd, &info) == 0 && lstat(path, &named) == 0
            && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700
            && info.st_uid == getuid() && named.st_mode & S_IFMT == S_IFDIR
            && info.st_dev == named.st_dev && info.st_ino == named.st_ino
            && UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode
    }

    static func start(profile: RuntimeIsolationProfile,
                      onReady: @escaping @MainActor (Process) -> Void,
                      onFailure: @escaping @MainActor (Process) -> Void) throws -> Process {
        guard let executable = Bundle.main.executableURL,
              let parent = processInfo(getpid()), parent.pbi_uid == getuid(),
              profile.mode == .production || profile.mode == .packagedField else { throw Failure.refused }
        var root = stat()
        let field = profile.mode == .packagedField
        if field {
            guard lstat(profile.rootDirectory.path, &root) == 0,
                  rootMatches(profile.rootDirectory.path, device: UInt64(root.st_dev), inode: UInt64(root.st_ino))
            else { throw Failure.refused }
        }
        let nonce = UUID().uuidString
        let ready = Data(("MINISCANVAS_RELAUNCH_READY:" + nonce + "\n").utf8)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, String(getpid()), String(parent.pbi_start_tvsec), String(parent.pbi_start_tvusec),
            Bundle.main.bundleURL.resolvingSymlinksInPath().path, field ? "field" : "production",
            field ? profile.rootDirectory.path : "", field ? String(UInt64(root.st_dev)) : "0",
            field ? String(UInt64(root.st_ino)) : "0", RuntimeIsolationProfile.fieldWitnessRequested() ? "1" : "0", nonce]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { completed in
            Task { @MainActor in onFailure(completed) }
        }
        try process.run()
        // One finite handshake off the main actor. Short reads, EOF and EINTR
        // are failures, never READY; no retry can reuse this nonce.
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = pipe.fileHandleForReading.fileDescriptor
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let tokenLength = ready.count
            var bytes = [UInt8](repeating: 0, count: tokenLength)
            let available = poll(&descriptor, 1, 5_000)
            let count = available == 1 && descriptor.revents & Int16(POLLIN) != 0
                ? read(fd, &bytes, tokenLength) : -1
            let matches = count == ready.count && Data(bytes) == ready
            try? pipe.fileHandleForReading.close()
            Task { @MainActor in
                guard matches, process.isRunning else {
                    if process.isRunning { process.terminate() }
                    onFailure(process)
                    return
                }
                onReady(process)
            }
        }
        return process
    }

    static func runRelayIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(argument) else { return }
        runRelay(arguments)
    }

    private static func runRelay(_ args: [String]) -> Never {
        guard args.count == 12, args[1] == argument,
              let pid = Int32(args[2]), pid == getppid(), pid > 1,
              let seconds = UInt64(args[3]), let micros = UInt64(args[4]),
              let device = UInt64(args[8]), let inode = UInt64(args[9]),
              let nonce = UUID(uuidString: args[11]), nonce.uuidString == args[11],
              args[10] == "0" || args[10] == "1",
              let executable = Bundle.main.executableURL,
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == args[5],
              executablePath(pid) == executable.resolvingSymlinksInPath().path,
              let parent = processInfo(pid), parent.pbi_uid == getuid(),
              UInt64(parent.pbi_start_tvsec) == seconds, UInt64(parent.pbi_start_tvusec) == micros
        else { exit(64) }
        let field = args[6] == "field"
        guard field || (args[6] == "production" && args[7].isEmpty && device == 0 && inode == 0),
              !field || rootMatches(args[7], device: device, inode: inode) else { exit(64) }
        let queue = kqueue()
        guard queue >= 0 else { exit(70) }
        var registration = kevent64_s()
        registration.ident = UInt64(pid)
        registration.filter = Int16(EVFILT_PROC)
        registration.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT)
        registration.fflags = UInt32(NOTE_EXIT)
        guard Darwin.kevent64(queue, &registration, 1, nil, 0, 0, nil) == 0 else { close(queue); exit(70) }
        let token = Array(("MINISCANVAS_RELAUNCH_READY:" + nonce.uuidString + "\n").utf8)
        guard write(STDOUT_FILENO, token, token.count) == token.count else { close(queue); exit(70) }
        close(STDOUT_FILENO)
        var event = kevent64_s()
        var timeout = timespec(tv_sec: 20, tv_nsec: 0)
        let received = Darwin.kevent64(queue, nil, 0, &event, 1, 0, &timeout)
        close(queue)
        guard received == 1, event.ident == UInt64(pid), event.filter == Int16(EVFILT_PROC),
              event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXIT) != 0 else { exit(71) }
        if let remaining = processInfo(pid), UInt64(remaining.pbi_start_tvsec) == seconds,
           UInt64(remaining.pbi_start_tvusec) == micros, remaining.pbi_status != UInt32(SZOMB) { exit(71) }
        guard !field || rootMatches(args[7], device: device, inode: inode) else { exit(71) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = field ? [RuntimeIsolationProfile.fieldActivationArgument] : []
        configuration.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        if field {
            configuration.environment[RuntimeIsolationProfile.fieldActivationMarkerKey] = "1"
            configuration.environment[RuntimeIsolationProfile.fieldActivationRootKey] = args[7]
            if args[10] == "1" { configuration.arguments.append(RuntimeIsolationProfile.fieldWitnessArgument) }
        }
        // The OS may add standard launch environment; no original environment,
        // credential or journey/seed argument is supplied by this handoff.
        let loop = CFRunLoopGetCurrent()
        guard let deadline = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 10, 0, 0, 0, { _ in
            exit(72)
        }) else { exit(70) }
        CFRunLoopAddTimer(loop, deadline, .defaultMode)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args[5]), configuration: configuration) { app, error in
            exit(app != nil && error == nil ? 0 : 72)
        }
        CFRunLoopRun()
        // A timed-out or interrupted LS result is unknown, never a retry.
        exit(72)
    }
}
