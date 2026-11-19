import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import MinisCore
import Observation
import ObjectiveC
import SwiftUI

// BEGIN UF03_NATIVE_OPERATION_TRACE — diagnostic metadata, never native PASS.
@MainActor
enum UF03NativeOperationTrace {
    enum Operation: String {
        case observation, host, layout, inventory, resolve, axPress, runLoop, cleanup
        case axReadAttribute, axReadActions
        case menuBeginExact, menuBeginForeign, menuEndExact, menuEndForeign, menuDeadline, menuResume
        case printExposure, printInput, printLabel, printCleanup, flushCleanup
        case encodeEvidence, printEvidence, flushEvidence, fixtureClose
    }
    struct Token { let id: Int; let ordinal: Int; let line: Int }
    static var caseOrdinal = -1
    private static var attempted = false
    private static var sink: Sink?

    static func begin(_ operation: Operation, line: Int = #line) -> Token? {
        guard (0..<57).contains(caseOrdinal) else { return nil }
        if !attempted {
            attempted = true
            sink = Sink.open(environment: ProcessInfo.processInfo.environment,
                executable: ProcessInfo.processInfo.arguments.first ?? "",
                arguments: ProcessInfo.processInfo.arguments)
        }
        guard let sink else { return nil }
        let token = Token(id: sink.records + 1, ordinal: caseOrdinal, line: line)
        return sink.emit(operation, phase: "begin", token: token) ? token : nil
    }
    static func end(_ operation: Operation, _ token: Token?, modeRunResult: CFRunLoopRunResult? = nil) {
        guard let token else { return }
        _ = sink?.emit(operation, phase: "end", token: token, modeRunResult: modeRunResult)
    }
    static func measure<T>(_ operation: Operation, line: Int = #line, _ body: () throws -> T) rethrows -> T {
        let token = begin(operation, line: line)
        defer { end(operation, token) }
        return try body()
    }

    // The shell owns exclusive creation. This reader cannot create a file or
    // accept a destination outside the admitted run root. No stdout is used.
    final class Sink {
        static let maximumBytes = 2 * 1024 * 1024
        static let maximumRecords = 8192
        static let maximumRecordBytes = 256
        static let maximumWriteSeconds = 0.020
        static let maximumTotalWriteSeconds = 0.200
        let descriptor: Int32
        var bytes: Int
        var records = 0
        var writeSeconds = 0.0
        var disabled = false
        init(descriptor: Int32, bytes: Int) { self.descriptor = descriptor; self.bytes = bytes }
        deinit { Darwin.close(descriptor) }

        private static func traceContractPermitted(_ batch: [String: Any]) -> Bool {
            if let diagnostic = batch["focused_diagnostic"] as? [String: Any],
               diagnostic["revision"] as? String == "R7_ORIGINAL_THREE_POLICY_MENU_DIAGNOSTIC_V3" { return true }
            guard let channel = batch["original_executor_ax"] as? [String: Any],
                  channel["revision"] as? String == "R9_ORIGINAL_EXECUTOR_AX_V1",
                  let identity = channel["production_menu_identity"] as? [String: Any] else { return false }
            let expected: [String: Any] = ["revision": "R14_PRODUCTION_MENU_IDENTITY_V1",
                "discovery": "application_frame_center_hit", "ownership": "complete_parent_chain_to_exact_focused_window",
                "uniqueness": "complete_owned_menu_children", "maximum_options": 16,
                "fallback": false, "cache": false, "control_root_reuse": false]
            return NSDictionary(dictionary: identity).isEqual(to: expected)
        }

        static func open(environment env: [String: String], executable: String, arguments: [String]) -> Sink? {
            guard env["RUN_TESTS_CONTROLLED"] == "1",
                  env["UF03_NATIVE_TRACE_REVISION"] == "R7_NATIVE_OPERATION_TRACE_V1",
                  URL(fileURLWithPath: executable).lastPathComponent == "swiftpm-testing-helper",
                  env["UF03_NATIVE_TRACE_SEGMENT"] == "owned-policy-case",
                  let rootPath = env["RUN_TESTS_SCRATCH_ROOT"], rootPath.hasPrefix("/"),
                  let runID = env["UF03_NATIVE_TRACE_RUN_ID"],
                  runID.range(of: #"^[0-9]{8}T[0-9]{6}Z-[0-9]+$"#, options: .regularExpression) != nil,
                  let nonce = env["UF03_NATIVE_TRACE_NONCE"],
                  nonce.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil,
                  let device = env["UF03_NATIVE_TRACE_DEVICE"].flatMap(UInt64.init),
                  let inode = env["UF03_NATIVE_TRACE_INODE"].flatMap(UInt64.init),
                  let index = arguments.firstIndex(of: "--test-bundle-path"), index + 1 < arguments.count,
                  arguments.contains("--testing-library"), arguments.contains("swift-testing") else { return nil }
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            let run = root.appendingPathComponent("run-" + runID, isDirectory: true)
            guard root.standardizedFileURL.path == rootPath,
                  root.resolvingSymlinksInPath().path == rootPath,
                  root.lastPathComponent == "01-focused-production-orchestration",
                  run.resolvingSymlinksInPath().path == run.path,
                  arguments[index + 1].hasPrefix(rootPath + "/MinisCanvasApp/"),
                  arguments[index + 1].hasSuffix("/MinisCanvasAppPackageTests.xctest/Contents/MacOS/MinisCanvasAppPackageTests") else { return nil }
            let contractURL = root.appendingPathComponent("launch-contract.json")
            guard let contractData = try? Data(contentsOf: contractURL), contractData.count < 262144,
                  let contract = try? JSONSerialization.jsonObject(with: contractData) as? [String: Any],
                  let batch = contract["pkg_batch"] as? [String: Any],
                  batch["allowed_stages"] as? [String] == ["01-focused-production-orchestration"],
                  traceContractPermitted(batch) else { return nil }
            let file = run.appendingPathComponent("diagnostic-native-operation.trace")
            let fd = Darwin.open(file.path, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  (info.st_mode & 0o777) == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
                  UInt64(info.st_dev) == device, UInt64(info.st_ino) == inode,
                  info.st_size > 0, info.st_size < maximumBytes - maximumRecordBytes else { Darwin.close(fd); return nil }
            var prefix = [UInt8](repeating: 0, count: 1024)
            let count = pread(fd, &prefix, prefix.count, 0)
            guard count > 0, let newline = prefix.prefix(count).firstIndex(of: 10),
                  let header = try? JSONSerialization.jsonObject(with: Data(prefix[..<newline])) as? [String: Any],
                  header["schema"] as? String == "R7_NATIVE_OPERATION_TRACE_V1",
                  header["run_id"] as? String == runID, header["nonce"] as? String == nonce,
                  header["maximum_bytes"] as? Int == maximumBytes,
                  header["maximum_records"] as? Int == maximumRecords else { Darwin.close(fd); return nil }
            var contents = [UInt8](repeating: 0, count: Int(info.st_size))
            guard pread(fd, &contents, contents.count, 0) == contents.count,
                  contents.last == 10 else { Darwin.close(fd); return nil }
            let records = contents.split(separator: 10, omittingEmptySubsequences: false)
            guard records.count >= 2, records.count - 2 < maximumRecords - 1,
                  !String(decoding: contents, as: UTF8.self).contains("UNVERIFIED"),
                  records.dropFirst().allSatisfy({ $0.count <= maximumRecordBytes }) else { Darwin.close(fd); return nil }
            let sink = Sink(descriptor: fd, bytes: contents.count)
            sink.records = records.count - 2
            return sink
        }

        func emit(_ operation: Operation, phase: String, token: Token,
                  modeRunResult: CFRunLoopRunResult? = nil) -> Bool {
            guard !disabled else { return false }
            if let modeRunResult {
                guard operation == .runLoop, phase == "end", (1...4).contains(modeRunResult.rawValue) else {
                    invalidate("mode-result"); return false
                }
            }
            guard records < Self.maximumRecords - 1,
                  bytes + Self.maximumRecordBytes * 2 <= Self.maximumBytes,
                  writeSeconds < Self.maximumTotalWriteSeconds else { invalidate("cap"); return false }
            let uptime = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            let resultField = modeRunResult.map { ",\"cf_run_result\":\($0.rawValue)" } ?? ""
            let line = "{\"seq\":\(records + 1),\"pair\":\(token.id),\"pid\":\(getpid()),\"case\":\(token.ordinal),\"op\":\"\(operation.rawValue)\",\"phase\":\"\(phase)\",\"line\":\(token.line),\"uptime_ns\":\(uptime)\(resultField)}\n"
            guard line.utf8.count <= Self.maximumRecordBytes else { invalidate("record"); return false }
            let data = Array(line.utf8)
            let start = ProcessInfo.processInfo.systemUptime
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            writeSeconds += elapsed
            if written > 0 { bytes += written }
            records += 1
            guard written == data.count else { invalidate("write"); return false }
            guard elapsed <= Self.maximumWriteSeconds, writeSeconds <= Self.maximumTotalWriteSeconds else {
                invalidate("elapsed"); return false
            }
            return true
        }
        private func invalidate(_ reason: String) {
            disabled = true
            // One reserved, bounded invalidation marker; failure/truncation is
            // UNVERIFIED. A regular-file syscall cannot be preempted here; the
            // original process timeout remains the hard wall-clock bound.
            let data = Array("\n{\"trace_status\":\"UNVERIFIED\",\"reason\":\"\(reason)\",\"pid\":\(getpid())}\n".utf8)
            if records < Self.maximumRecords, bytes + data.count <= Self.maximumBytes {
                _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            }
        }
    }
}
// END UF03_NATIVE_OPERATION_TRACE

// BEGIN UF03_ORIGINAL_STDOUT_FRAMES
// Full original observation bytes, framed only for the signed diagnostic.
// No raw-file writer, detached producer, sleep, or success fallback.
@MainActor
enum UF03OriginalStdoutFrames {
    static let maximumBytes = 2 * 1024 * 1024
    static let payloadBytes = 1536
    static let maximumParts = 1366
    static let maximumLineBytes = 4096
    static let maximumWriteSeconds = 0.200

    static func enabled(environment env: [String: String], executable: String, arguments: [String]) -> Bool {
        guard env["RUN_TESTS_CONTROLLED"] == "1",
              env["UF03_NATIVE_FRAME_REVISION"] == "R7_ORIGINAL_STDOUT_FRAMES_V1",
              ["owned-policy-case", "shared-single", "shared-related"].contains(env["UF03_NATIVE_FRAME_SEGMENT"] ?? ""),
              URL(fileURLWithPath: executable).lastPathComponent == "swiftpm-testing-helper",
              let rootPath = env["RUN_TESTS_SCRATCH_ROOT"], rootPath.hasPrefix("/"),
              let runID = env["UF03_NATIVE_FRAME_RUN_ID"],
              runID.range(of: #"^[0-9]{8}T[0-9]{6}Z-[0-9]+$"#, options: .regularExpression) != nil,
              let launchSHA = env["UF03_NATIVE_FRAME_LAUNCH_SHA256"], launchSHA.count == 64,
              let index = arguments.firstIndex(of: "--test-bundle-path"), index + 1 < arguments.count,
              arguments.contains("--testing-library"), arguments.contains("swift-testing") else { return false }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard root.standardizedFileURL.path == rootPath,
              root.resolvingSymlinksInPath().path == rootPath,
              root.lastPathComponent == "01-focused-production-orchestration",
              arguments[index + 1].hasPrefix(rootPath + "/MinisCanvasApp/"),
              arguments[index + 1].hasSuffix("/MinisCanvasAppPackageTests.xctest/Contents/MacOS/MinisCanvasAppPackageTests"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("run-" + runID).path),
              let data = try? Data(contentsOf: root.appendingPathComponent("launch-contract.json")),
              data.count < 262144,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == launchSHA,
              let contract = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let batch = contract["pkg_batch"] as? [String: Any],
              batch["allowed_stages"] as? [String] == ["01-focused-production-orchestration"],
              let diagnostic = batch["focused_diagnostic"] as? [String: Any],
              diagnostic["revision"] as? String == "R7_ORIGINAL_THREE_POLICY_MENU_DIAGNOSTIC_V3",
              diagnostic["case_ids"] as? [String] == ["companionEvidence.policy:p0:w220", "companionEvidence.policy:p0:w310"] else { return false }
        return true
    }

    static func emitIfEnabled(_ data: Data, caseID: String) -> Bool? {
        let env = ProcessInfo.processInfo.environment
        guard env["UF03_NATIVE_FRAME_REVISION"] != nil else { return nil }
        guard enabled(environment: env, executable: ProcessInfo.processInfo.arguments.first ?? "",
                      arguments: ProcessInfo.processInfo.arguments) else { return false }
        return emit(data, caseID: caseID, pid: getpid())
    }

    // A blocking stdio syscall is bounded by the original process deadline.
    // The 200ms cooperative cap forbids subsequent writes after it is reached.
    static func emit(_ data: Data, caseID: String, pid: Int32,
                     write: (Data) -> Bool = { bytes in
                         let count = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, stdout) }
                         return count == bytes.count && fflush(stdout) == 0
                     }, now: () -> Double = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes, pid > 0,
              caseID.utf8.count <= 128, caseID.hasPrefix("companionEvidence."),
              !caseID.contains("\n"), !caseID.contains("\r") else { return false }
        let count = (data.count + payloadBytes - 1) / payloadBytes
        guard count <= maximumParts else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let start = now()
        func line(_ prefix: String, _ object: [String: Any]) -> Bool {
            guard now() - start < maximumWriteSeconds,
                  let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  bytes.count + prefix.utf8.count + 1 <= maximumLineBytes else { return false }
            var output = Data(prefix.utf8); output.append(bytes); output.append(10)
            guard write(output) else { return false }
            return now() - start < maximumWriteSeconds
        }
        let metadata: [String: Any] = ["case_id": caseID, "pid": pid, "sha256": digest,
                                      "bytes": data.count, "parts": count]
        for index in 0..<count {
            var part = metadata
            part["index"] = index
            part["payload"] = data.subdata(in: index * payloadBytes..<min(data.count, (index + 1) * payloadBytes)).base64EncodedString()
            guard line("UF03_COMPANION_EVIDENCE_PART ", part) else { return false }
        }
        return line("UF03_COMPANION_EVIDENCE_END ", metadata)
    }
}
// END UF03_ORIGINAL_STDOUT_FRAMES


// PRIVATE1737: same original test host, one authenticated original-executor channel.
@MainActor
internal enum UF03OriginalExecutorAXHandshakeProbe {
    /// Returns nil for the normal helper/exact2 lifecycle, true only after the
    /// standalone handshake-only consumer has authenticated one hello, and
    /// false for an explicitly admitted handshake that failed closed.
    static func runIfAdmitted() -> Bool? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_TESTS_CONTROLLED"] == "1",
              environment["RUN_TESTS_AX_HANDSHAKE_ONLY"] == "1" else {
            return nil
        }
        return UF03OriginalExecutorAXChannel.runHandshakeOnlyProbe()
    }
}

@MainActor
private final class UF03OriginalExecutorAXChannel {
    struct Result { let error: AXError; let late: Bool; let dispatched: Bool; var nativeProof: [String: String]? = nil }
    private enum HostKind { case helper, standalone }
    private struct Identity: Equatable {
        let pid: Int32; let ppid: Int32; let start: String
    }
    static let shared: UF03OriginalExecutorAXChannel? = {
        var diagnosticStage = "entry"
        do { return try UF03OriginalExecutorAXChannel(diagnosticStage: &diagnosticStage) }
        catch {
            // Diagnostics only: initialization still fails closed and is never retried.
            // Fixed stage labels contain no socket, credentials, or unverified identity.
            if ProcessInfo.processInfo.environment["RUN_TESTS_CONTROLLED"] == "1" {
                let line = "UF03_EXECUTOR_AX_INIT_FAILURE {\"status\":\"INIT_REFUSED\",\"stage\":\"\(diagnosticStage)\",\"pid\":\(getpid())}\n"
                let bytes = Data(line.utf8)
                _ = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, stdout) }
                _ = fflush(stdout)
            }
            return nil
        }
    }()
    private var fd: Int32 = -1
    private var descriptor: CFFileDescriptor?
    private var source: CFRunLoopSource?
    private var buffer = Data()
    private var failed = false
    private var pending: (digest: String, fields: [String: Any], deadline: Double,
                          tick: UInt64, completion: @MainActor (Result) -> Void)?
    private let hostKind: HostKind
    private let identityLookup: Bool
    var requiresProducerIdentity: Bool { identityLookup }
    private let launchSHA: String
    private let admissionSHA: String
    private var actor: String
    private let launchNonce: String
    private let candidateHead: String
    private let candidateTree: String
    private let handshakeOnly: Bool
    private let hostIdentity: Identity
    private let parentIdentity: Identity
    private let runnerIdentity: Identity
    private var timebase = mach_timebase_info_data_t()
    final class FixtureLifetime {
        fileprivate let serial: Int
        fileprivate weak var owner: AnyObject?
        fileprivate var closed = false
        fileprivate init(serial: Int, owner: AnyObject) { self.serial = serial; self.owner = owner }
    }
    private var nextFixtureSerial = 0
    private var currentFixture: FixtureLifetime?
    func beginFixture(owner: AnyObject) -> FixtureLifetime? {
        guard !failed, pending == nil, currentFixture == nil, nextFixtureSerial < 256 else { return nil }
        nextFixtureSerial += 1
        let lifetime = FixtureLifetime(serial: nextFixtureSerial, owner: owner)
        currentFixture = lifetime
        return lifetime
    }
    func endFixture(_ lifetime: FixtureLifetime) {
        guard currentFixture === lifetime else { return }
        lifetime.closed = true
        cancelPending()
        currentFixture = nil
    }
    func ownsFixture(_ lifetime: FixtureLifetime) -> Bool {
        currentFixture === lifetime && !lifetime.closed && lifetime.owner != nil
    }

    private enum Failure: Error { case refused }
    private static func identity(_ pid: Int32) throws -> Identity {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_pid == UInt32(pid),
              info.pbi_status != 5, info.pbi_uid == geteuid() else { throw Failure.refused }
        return Identity(pid: pid, ppid: Int32(info.pbi_ppid),
            start: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4096, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.refused }
        // Peer responses are canonical ASCII JSON. This rejects duplicate keys as well.
        let canonical = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        guard canonical == data else { throw Failure.refused }
        return result
    }
    private static func peerPID(_ fd: Int32) throws -> Int32 {
        var pid: Int32 = 0; var count = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &count) == 0,
              count == MemoryLayout<Int32>.size, pid > 0 else { throw Failure.refused }
        return pid
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func isHex64(_ value: Any?) -> Bool {
        guard let value = value as? String, value.count == 64 else { return false }
        return value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func isHex40(_ value: Any?) -> Bool {
        guard let value = value as? String, value.count == 40 else { return false }
        return value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func regularOwnedFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { return false }
        return true
    }
    private static func standaloneMachOExecute(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 16 else { return false }
        let bytes = Array(data.prefix(16))
        let magic = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let filetype = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        return (magic == 0xfeedfacf || magic == 0xcffaedfe) && filetype == 2
    }
    private static func standaloneInfoSHA(_ bundle: Bundle) -> String? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard url.path == url.standardizedFileURL.path,
              regularOwnedFile(url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }
    private static func statPath(_ path: String, type: mode_t, mode: mode_t? = nil) -> stat? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == type,
              info.st_uid == getuid(),
              (type == S_IFDIR || info.st_nlink == 1),
              mode.map({ (info.st_mode & 0o777) == $0 }) ?? true else { return nil }
        return info
    }
    private static func exactStandaloneProfile(_ profile: [String: Any], bundle: Bundle) throws -> [String: Any] {
        guard let standalone = profile["standalone_app_main"] as? [String: Any],
              Set(standalone.keys) == Set(["revision", "bundle_identifier", "relative_app", "executable",
                  "macho_filetype", "launch", "no_helper", "codesign", "info_plist_sha256", "link_mode",
                  "link_contract_env", "non_promoting", "parallel", "allowed_phases"]),
              standalone["revision"] as? String == "R13_STANDALONE_APP_MAIN_HARNESS_V1",
              standalone["bundle_identifier"] as? String == "com.miniscanvas.r13.original-app-main",
              standalone["relative_app"] as? String == "R13OriginalAppMain.app",
              standalone["executable"] as? String == "MinisCanvasOriginalAppMain",
              standalone["macho_filetype"] as? String == "MH_EXECUTE",
              standalone["launch"] as? String == "direct_bundle_executable",
              standalone["no_helper"] as? Bool == true,
              standalone["codesign"] as? String == "ad-hoc-strict",
              standalone["link_mode"] as? String == "remove_one_linker_bundle_flag",
              standalone["link_contract_env"] as? String == "RUN_TESTS_STANDALONE_LINK_CONTRACT",
              standalone["non_promoting"] as? Bool == true,
              standalone["parallel"] as? Bool == false,
              standalone["allowed_phases"] as? [String] == [
                  "discovery", "native-control", "owned-policy-case", "shared-single", "shared-related"
              ],
              isHex64(standalone["info_plist_sha256"]),
              bundle.bundleIdentifier == standalone["bundle_identifier"] as? String,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executableURL = bundle.executableURL,
              executableURL.lastPathComponent == standalone["executable"] as? String,
              let relativeApp = standalone["relative_app"] as? String,
              let executable = standalone["executable"] as? String,
              executableURL.path.hasSuffix("/\(relativeApp)/Contents/MacOS/\(executable)"),
              executableURL.path == executableURL.standardizedFileURL.path,
              bundle.bundleURL.lastPathComponent == standalone["relative_app"] as? String,
              regularOwnedFile(executableURL.path), standaloneInfoSHA(bundle) == standalone["info_plist_sha256"] as? String,
              standaloneMachOExecute(executableURL.path) else { throw Failure.refused }
        return standalone
    }
    private init(diagnosticStage: inout String) throws {
        let env = ProcessInfo.processInfo.environment
        diagnosticStage = "environment_and_helper"
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? ""
        guard env["RUN_TESTS_CONTROLLED"] == "1",
              let runtimePath = env["RUN_TESTS_ADMISSION_JSON"], let expectedRuntime = env["RUN_TESTS_ADMISSION_SHA256"],
              let socketPath = env["RUN_TESTS_EXECUTOR_AX_SOCKET"], socketPath.hasPrefix("/"),
              socketPath.hasSuffix("/r9ax.sock"), socketPath.utf8.count < 104 else { throw Failure.refused }
        diagnosticStage = "runtime_read"
        let runtimeData = try Data(contentsOf: URL(fileURLWithPath: runtimePath))
        admissionSHA = Self.sha256(runtimeData)
        diagnosticStage = "runtime_hash_profile_arguments"
        guard admissionSHA == expectedRuntime,
              let runtime = try JSONSerialization.jsonObject(with: runtimeData) as? [String: Any],
              let selector = runtime["selector"] as? [String: Any],
              let profile = selector["original_executor_ax"] as? [String: Any],
              profile["revision"] as? String == "R9_ORIGINAL_EXECUTOR_AX_V1",
              let process = runtime["process"] as? [String: Any],
              CommandLine.arguments.contains("swift-testing") else { throw Failure.refused }
        let standaloneHost = executableName == "MinisCanvasOriginalAppMain"
        if standaloneHost {
            diagnosticStage = "standalone_profile"
            _ = try Self.exactStandaloneProfile(profile, bundle: Bundle.main)
            guard Set(runtime.keys) == Set(["schema", "launch", "actor_task_id", "candidate",
                    "execution_mode", "nonce", "selector", "process", "socket"]),
                  runtime["schema"] as? String == "R18_V8_STANDALONE_AX_RUNTIME_V1",
                  let mode = runtime["execution_mode"] as? String,
                  ["STANDALONE_APP_MAIN_AX_HANDSHAKE_ONLY", "STANDALONE_APP_MAIN_COMPOSER_EXACT2"].contains(mode),
                  (env["RUN_TESTS_AX_HANDSHAKE_ONLY"] == "1") == (mode == "STANDALONE_APP_MAIN_AX_HANDSHAKE_ONLY"),
                  let launch = runtime["launch"] as? [String: Any],
                  Set(launch.keys) == Set(["path", "sha256"]),
                  let launchPath = launch["path"] as? String, Self.regularOwnedFile(launchPath),
                  Self.isHex64(launch["sha256"]),
                  let launchData = try? Data(contentsOf: URL(fileURLWithPath: launchPath)),
                  Self.sha256(launchData) == launch["sha256"] as? String,
                  let candidate = runtime["candidate"] as? [String: Any],
                  Set(candidate.keys) == Set(["worktree", "head", "tree"]),
                  let candidateWorktree = candidate["worktree"] as? String, candidateWorktree.hasPrefix("/"),
                  Self.isHex40(candidate["head"]), Self.isHex40(candidate["tree"]),
                  let actorValue = runtime["actor_task_id"] as? String, !actorValue.isEmpty,
                  let launchNonceValue = runtime["nonce"] as? String, launchNonceValue.count >= 16,
                  launchNonceValue.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let socket = runtime["socket"] as? [String: Any],
                  Set(socket.keys) == Set(["path", "directory_device", "directory_inode", "socket_device", "socket_inode"]),
                  socket["path"] as? String == socketPath,
                  let directoryDevice = (socket["directory_device"] as? NSNumber)?.uint64Value,
                  let directoryInode = (socket["directory_inode"] as? NSNumber)?.uint64Value,
                  let socketDevice = (socket["socket_device"] as? NSNumber)?.uint64Value,
                  let socketInode = (socket["socket_inode"] as? NSNumber)?.uint64Value,
                  let directoryInfo = Self.statPath(URL(fileURLWithPath: socketPath).deletingLastPathComponent().path,
                      type: S_IFDIR, mode: 0o700), UInt64(directoryInfo.st_dev) == directoryDevice,
                  UInt64(directoryInfo.st_ino) == directoryInode,
                  let socketInfo = Self.statPath(socketPath, type: S_IFSOCK, mode: 0o600),
                  UInt64(socketInfo.st_dev) == socketDevice, UInt64(socketInfo.st_ino) == socketInode,
                  let standaloneProcess = runtime["process"] as? [String: Any],
                  Set(standaloneProcess.keys) == Set(["parent_pid", "parent_start", "runner_pid", "runner_start",
                      "runner_ppid", "host_pid", "host_start", "host_binary_sha256", "host_codesign_mode",
                      "host_codesign_strict_verified", "host_macho_filetype"]),
                  let parentValue = (standaloneProcess["parent_pid"] as? NSNumber)?.int32Value,
                  let runnerValue = (standaloneProcess["runner_pid"] as? NSNumber)?.int32Value,
                  let hostValue = (standaloneProcess["host_pid"] as? NSNumber)?.int32Value,
                  let runnerParentValue = (standaloneProcess["runner_ppid"] as? NSNumber)?.int32Value,
                  let parentStartValue = standaloneProcess["parent_start"] as? String,
                  let runnerStartValue = standaloneProcess["runner_start"] as? String,
                  let hostStartValue = standaloneProcess["host_start"] as? String,
                  let hostBinarySHA = standaloneProcess["host_binary_sha256"] as? String,
                  Self.isHex64(hostBinarySHA), standaloneProcess["host_codesign_mode"] as? String == "ad-hoc",
                  standaloneProcess["host_codesign_strict_verified"] as? Bool == true,
                  standaloneProcess["host_macho_filetype"] as? String == "MH_EXECUTE",
                  parentValue > 0, runnerValue > 0, hostValue == getpid(), runnerParentValue == parentValue,
                  Self.sha256(try Data(contentsOf: Bundle.main.executableURL!)) == hostBinarySHA else { throw Failure.refused }
            hostKind = .standalone
            actor = actorValue; launchNonce = launchNonceValue
            candidateHead = candidate["head"] as? String ?? ""; candidateTree = candidate["tree"] as? String ?? ""
            handshakeOnly = mode == "STANDALONE_APP_MAIN_AX_HANDSHAKE_ONLY"
            let parentPID = parentValue, runnerPID = runnerValue
            guard let launchObject = try? JSONSerialization.jsonObject(with: launchData) as? [String: Any],
                  let batch = launchObject["pkg_batch"] as? [String: Any],
                  let actorBatch = batch["actor_task_id"] as? String, actorBatch == actor,
                  batch["launch_nonce"] as? String == launchNonce,
                  let candidateBatch = batch["candidate"] as? [String: Any], NSDictionary(dictionary: candidateBatch).isEqual(to: candidate),
                  let profileBatch = batch["original_executor_ax"] as? [String: Any],
                  NSDictionary(dictionary: profileBatch).isEqual(to: profile),
                  let selectorBatch = batch["selector"] as? [String: Any],
                  NSDictionary(dictionary: selectorBatch).isEqual(to: selector) else { throw Failure.refused }
            diagnosticStage = "standalone_process_identity"
            hostIdentity = try Self.identity(hostValue)
            parentIdentity = try Self.identity(parentPID); runnerIdentity = try Self.identity(runnerPID)
            guard hostIdentity.pid == getpid(), hostIdentity.ppid == runnerPID,
                  hostIdentity.start == hostStartValue, parentIdentity.start == parentStartValue,
                  runnerIdentity.start == runnerStartValue, runnerIdentity.ppid == parentPID,
                  parentIdentity.pid == parentPID, runnerIdentity.pid == runnerPID else { throw Failure.refused }
        } else {
            guard executableName == "swiftpm-testing-helper",
                  profile["standalone_app_main"] == nil,
                  let scratch = runtime["scratch_root"] as? String,
                  let argsIndex = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
                  argsIndex + 1 < CommandLine.arguments.count,
                  CommandLine.arguments[argsIndex + 1].hasPrefix(scratch + "/") else { throw Failure.refused }
            hostKind = .helper; actor = ""; launchNonce = ""; candidateHead = ""; candidateTree = ""; handshakeOnly = false
            let parentPID = (process["outer_ppid"] as? NSNumber)?.int32Value ?? 0
            let runnerPID = (process["outer_pid"] as? NSNumber)?.int32Value ?? 0
            guard parentPID > 0, runnerPID > 0 else { throw Failure.refused }
            diagnosticStage = "live_process_identity"
            hostIdentity = try Self.identity(getpid()); parentIdentity = try Self.identity(parentPID); runnerIdentity = try Self.identity(runnerPID)
            diagnosticStage = "runner_parent_identity"
            guard runnerIdentity.ppid == parentPID else { throw Failure.refused }
            diagnosticStage = "host_runner_ancestry"
            var ancestor = hostIdentity; var visited = Set<Int32>()
            for _ in 0..<32 {
                if ancestor == runnerIdentity { break }
                guard ancestor.pid > 1, visited.insert(ancestor.pid).inserted else { throw Failure.refused }
                ancestor = try Self.identity(ancestor.ppid)
            }
            guard ancestor == runnerIdentity else { throw Failure.refused }
        }
        diagnosticStage = "launch_read"
        let launch: Data
        if hostKind == .helper {
            let scratch = (runtime["scratch_root"] as? String) ?? ""
            launch = try Data(contentsOf: URL(fileURLWithPath: scratch).appendingPathComponent("launch-contract.json"))
        } else {
            let launchPath = (runtime["launch"] as? [String: Any])?["path"] as? String ?? ""
            launch = try Data(contentsOf: URL(fileURLWithPath: launchPath))
        }
        launchSHA = SHA256.hash(data: launch).map { String(format: "%02x", $0) }.joined()
        diagnosticStage = "launch_actor_profile"
        guard let launchObject = try JSONSerialization.jsonObject(with: launch) as? [String: Any],
              let batch = launchObject["pkg_batch"] as? [String: Any],
              let actorValue = batch["actor_task_id"] as? String,
              let profileBatch = batch["original_executor_ax"] as? [String: Any],
              NSDictionary(dictionary: profileBatch).isEqual(to: profile) else { throw Failure.refused }
        if hostKind == .helper {
            actor = actorValue
        } else {
            guard actorValue == actor else { throw Failure.refused }
        }
        diagnosticStage = "production_identity_revision"
        if let identity = profile["production_menu_identity"] as? [String: Any] {
            guard identity["revision"] as? String == "R14_PRODUCTION_MENU_IDENTITY_V1" else { throw Failure.refused }
            identityLookup = true
        } else { identityLookup = false }
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.numer > 0, timebase.denom > 0 else { throw Failure.refused }
        diagnosticStage = "socket_create"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.refused }
        var connected = false
        defer { if !connected && fd >= 0 { Darwin.close(fd); fd = -1 } }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        diagnosticStage = "socket_timeouts"
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw Failure.refused }
        diagnosticStage = "socket_signal_policy"
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.refused }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(2 + bytes.count)
        let addressLength = socklen_t(address.sun_len)
        diagnosticStage = "socket_nonblocking"
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.refused }
        diagnosticStage = "socket_connect"
        let connectedRC = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
        if connectedRC != 0 {
            guard errno == EINPROGRESS else { throw Failure.refused }
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var socketError: Int32 = 0; var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.poll(&ready, 1, 200) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorSize) == 0,
                  socketError == 0 else { throw Failure.refused }
        }
        diagnosticStage = "socket_peer_identity"
        let expectedPeer = hostKind == .standalone ? runnerIdentity.pid : parentIdentity.pid
        guard try Self.peerPID(fd) == expectedPeer, fcntl(fd, F_SETFL, 0) == 0 else { throw Failure.refused }
        diagnosticStage = "hello_receive"
        var helloBytes = Data(); let setupDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        while !helloBytes.contains(10), helloBytes.count < 4096, ProcessInfo.processInfo.systemUptime < setupDeadline {
            var chunk = [UInt8](repeating: 0, count: 4096 - helloBytes.count)
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { throw Failure.refused }; helloBytes.append(contentsOf: chunk.prefix(n))
        }
        diagnosticStage = "hello_frame"
        guard helloBytes.last == 10, helloBytes.filter({ $0 == 10 }).count == 1 else { throw Failure.refused }
        diagnosticStage = "hello_json"
        let hello = try Self.object(helloBytes.dropLast())
        diagnosticStage = "hello_identity_and_live_recheck"
        guard Set(hello.keys) == Set(["revision","launch_sha","actor","parent_pid","parent_start","runner_pid","runner_start","host_pid","host_start"]),
              hello["revision"] as? String == "R9_ORIGINAL_EXECUTOR_AX_V1",
              hello["launch_sha"] as? String == launchSHA, hello["actor"] as? String == actor,
              (hello["parent_pid"] as? NSNumber)?.int32Value == parentIdentity.pid, hello["parent_start"] as? String == parentIdentity.start,
              (hello["runner_pid"] as? NSNumber)?.int32Value == runnerIdentity.pid, hello["runner_start"] as? String == runnerIdentity.start,
              (hello["host_pid"] as? NSNumber)?.int32Value == getpid(), hello["host_start"] as? String == hostIdentity.start,
              try Self.identity(parentIdentity.pid) == parentIdentity, try Self.identity(runnerIdentity.pid) == runnerIdentity,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Failure.refused }
        diagnosticStage = "runloop_descriptor"
        var context = CFFileDescriptorContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        descriptor = CFFileDescriptorCreate(nil, fd, false, { _, _, info in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<UF03OriginalExecutorAXChannel>.fromOpaque(info).takeUnretainedValue().receive()
            }
        }, &context)
        guard let descriptor, let runSource = CFFileDescriptorCreateRunLoopSource(nil, descriptor, 0) else { throw Failure.refused }
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .defaultMode)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, CFRunLoopMode(rawValue: UF03OwnedMenuActionTurn.trackingMode as CFString))
        CFFileDescriptorEnableCallBacks(descriptor, CFOptionFlags(kCFFileDescriptorReadCallBack))
        connected = true
    }
    static func runHandshakeOnlyProbe() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_TESTS_CONTROLLED"] == "1",
              env["RUN_TESTS_AX_HANDSHAKE_ONLY"] == "1",
              let channel = shared, channel.hostKind == .standalone, channel.handshakeOnly else { return false }
        let marker: [String: Any] = ["revision": "R9_ORIGINAL_EXECUTOR_AX_V1", "execution_mode": "STANDALONE_APP_MAIN_AX_HANDSHAKE_ONLY",
            "admission_sha": channel.admissionSHA, "launch_sha": channel.launchSHA, "actor": channel.actor,
            "nonce": channel.launchNonce, "candidate_head": channel.candidateHead, "candidate_tree": channel.candidateTree,
            "hello": 1, "requests": 0, "responses": 0, "tests": 0]
        guard let data = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= 1024, let json = String(data: data, encoding: .utf8) else {
            channel.finishHandshakeOnly(); return false
        }
        print("UF03_ORIGINAL_EXECUTOR_AX_HANDSHAKE_PASS " + json)
        _ = fflush(stdout)
        channel.finishHandshakeOnly()
        return true
    }

    private func finishHandshakeOnly() { invalidate() }

    private(set) var lastStartFailure: String?

    func start(element: AXUIElement? = nil, producerFrame: CGRect? = nil, producerTargetID: String? = nil, lifetime: FixtureLifetime, query: String, menu: String, caseID: String, kind: String,
               owner: String, generation: Int, ordinal: Int, deadline: Double,
               producerIdentity: [String: Any]? = nil,
               completion: @escaping @MainActor (Result) -> Void) -> Bool {
        lastStartFailure = nil
        func refused(_ reason: String) -> Bool { lastStartFailure = String(reason.prefix(192)); return false }
        guard !failed, pending == nil, fd >= 0, ownsFixture(lifetime), ProcessInfo.processInfo.systemUptime < deadline,
              (try? Self.identity(parentIdentity.pid)) == parentIdentity,
              (try? Self.identity(runnerIdentity.pid)) == runnerIdentity else { return refused("CHANNEL_TRANSPORT_OR_LIFETIME_ADMISSION") }
        let point: CGPoint
        let size: CGSize
        if let frame = producerFrame {
            guard identityLookup, element == nil, producerTargetID != nil,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                  frame.width > 0, frame.height > 0 else { return refused("PRODUCER_FRAME_ADMISSION") }
            point = frame.origin; size = frame.size
        } else {
            guard let element else { return refused("LOCAL_ELEMENT_MISSING") }
            let timeoutRC = AXUIElementSetMessagingTimeout(element, 0.01)
            guard timeoutRC == .success else { return refused("LOCAL_TIMEOUT_SETUP_RC_" + String(timeoutRC.rawValue)) }
            var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
            let positionRC = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            guard positionRC == .success else { return refused("LOCAL_POSITION_READ_RC_" + String(positionRC.rawValue)) }
            let sizeRC = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
            guard sizeRC == .success else { return refused("LOCAL_SIZE_READ_RC_" + String(sizeRC.rawValue)) }
            guard let positionValue, let sizeValue, CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return refused("LOCAL_FRAME_MISSING_OR_TYPE") }
            let p = unsafeDowncast(positionValue, to: AXValue.self), s = unsafeDowncast(sizeValue, to: AXValue.self)
            var legacyPoint = CGPoint.zero, legacySize = CGSize.zero
            guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
                  AXValueGetValue(p, .cgPoint, &legacyPoint), AXValueGetValue(s, .cgSize, &legacySize),
                  [legacyPoint.x, legacyPoint.y, legacySize.width, legacySize.height].allSatisfy({ $0.isFinite }), legacySize.width > 0, legacySize.height > 0 else { return refused("LOCAL_FRAME_VALUE") }
            point = legacyPoint; size = legacySize
        }
        // Sample ticks before remaining uptime: rounding is conservative, never extends the host deadline.
        let issued = mach_absolute_time()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, remaining <= 1 else { return refused("CHANNEL_DEADLINE_ADMISSION") }
        let tick = issued + UInt64(remaining * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
        var fields: [String: Any] = ["revision":"R9_ORIGINAL_EXECUTOR_AX_V1", "launch_sha":launchSHA,"actor":actor,
            "host_pid":getpid(),"host_start":hostIdentity.start,"lifetime":lifetime.serial,"case":caseID,"kind":kind,"owner":owner,
            "generation":generation,"ordinal":ordinal,"issued_tick":String(issued),"deadline_tick":String(tick),
            "query":query,"menu":menu,"frame":[point.x,point.y,size.width,size.height]]
        if identityLookup {
            guard let producerIdentity else { return refused("PRODUCER_IDENTITY_MISSING") }
            guard let targetID = producerIdentity["target_id"] as? String else { return refused("PRODUCER_TARGET_ID_TYPE") }
            if producerFrame != nil {
                guard producerTargetID == targetID else { return refused("PRODUCER_TARGET_ID_MISMATCH") }
            } else {
                guard let element else { return refused("LOCAL_ELEMENT_MISSING") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return refused("LOCAL_IDENTITY_DEADLINE_BEFORE") }
                var targetIdentityValue: CFTypeRef?
                let identityRC = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &targetIdentityValue)
                guard identityRC == .success else { return refused("LOCAL_AXIDENTIFIER_READ_RC_" + String(identityRC.rawValue)) }
                guard let targetIdentityValue else { return refused("LOCAL_AXIDENTIFIER_MISSING_RC_0") }
                guard CFGetTypeID(targetIdentityValue) == CFStringGetTypeID() else { return refused("LOCAL_AXIDENTIFIER_TYPE_RC_0") }
                guard targetIdentityValue as? String == targetID else { return refused("LOCAL_AXIDENTIFIER_VALUE_RC_0") }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return refused("LOCAL_IDENTITY_DEADLINE_AFTER_RC_0") }
            }
            fields["menu_identity"] = producerIdentity
        }
        guard var raw = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]), raw.count < 4096 else { return refused("CHANNEL_REQUEST_ENCODING_OR_BOUND") }
        raw.append(10)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        pending = (digest, fields, deadline, tick, completion)
        let n = raw.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard n == raw.count else {
            let transportErrno = n < 0 ? errno : 0
            _ = refused("CHANNEL_TRANSPORT_SEND_BYTES_" + String(n) + "_ERRNO_" + String(transportErrno))
            invalidate(); return false
        }
        return true
    }
    private func receive() {
        guard !failed, let descriptor else { return }
        defer { if !failed { CFFileDescriptorEnableCallBacks(descriptor, CFOptionFlags(kCFFileDescriptorReadCallBack)) } }
        var chunk = [UInt8](repeating: 0, count: max(1, 4097 - buffer.count))
        let n = recv(fd, &chunk, chunk.count, 0)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
        guard n > 0 else { invalidate(); return }
        buffer.append(contentsOf: chunk.prefix(n))
        guard buffer.count <= 4096 else { invalidate(); return }
        guard let end = buffer.firstIndex(of: 10) else { return }
        guard end == buffer.index(before: buffer.endIndex), let request = pending,
              let response = try? Self.object(buffer.prefix(upTo: end)),
              Set(response.keys) == Set(["revision","request_sha","launch_sha","actor","host_pid","host_start","lifetime","owner","generation","ordinal","case","kind","error","dispatched","completed_tick"]),
              response["revision"] as? String == "R9_ORIGINAL_EXECUTOR_AX_V1", response["request_sha"] as? String == request.digest,
              response["launch_sha"] as? String == launchSHA, response["actor"] as? String == actor,
              response["host_pid"] as? Int32 == getpid(), response["host_start"] as? String == hostIdentity.start,
              ["owner","case","kind"].allSatisfy({ response[$0] as? String == request.fields[$0] as? String }),
              ["lifetime","generation","ordinal"].allSatisfy({ response[$0] as? Int == request.fields[$0] as? Int }),
              let lifetime = currentFixture, ownsFixture(lifetime),
              response["lifetime"] as? Int == lifetime.serial,
              let error = response["error"] as? Int32, let dispatched = response["dispatched"] as? Bool, let tickText = response["completed_tick"] as? String,
              let completed = UInt64(tickText), let issuedText = request.fields["issued_tick"] as? String,
              let issued = UInt64(issuedText), completed >= issued, completed <= mach_absolute_time(),
              completed < request.tick, ProcessInfo.processInfo.systemUptime < request.deadline,
              (try? Self.identity(parentIdentity.pid)) == parentIdentity,
              (try? Self.identity(runnerIdentity.pid)) == runnerIdentity else { invalidate(); return }
        buffer.removeAll(keepingCapacity: true); pending = nil
        var nativeProof: [String: String]?
        if identityLookup, error == 0, dispatched,
           let identity = request.fields["menu_identity"] as? [String: Any],
           let targetID = identity["target_id"] as? String,
           let owner = request.fields["owner"] as? String {
            // The unchanged original executor proves fresh public ownership,
            // exact identity roster, enabled/frame equality and the real AX action.
            nativeProof = ["revision": "R15_ORIGINAL_EXECUTOR_VALIDATED_TARGET_V1",
                "request_sha": request.digest, "launch_sha": launchSHA, "actor": actor,
                "host_pid": String(getpid()), "host_start": hostIdentity.start,
                "owner": owner, "target_id": targetID]
        }
        request.completion(Result(error: AXError(rawValue: error) ?? .failure, late: false,
                                  dispatched: dispatched, nativeProof: nativeProof))
        if error != 0 { invalidate() }
    }
    func cancelPending() { if pending != nil { invalidate() } }
    private func invalidate() {
        guard !failed else { return }; failed = true
        let old = pending; pending = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode(rawValue: UF03OwnedMenuActionTurn.trackingMode as CFString))
        }
        if let descriptor { CFFileDescriptorInvalidate(descriptor) }
        source = nil; descriptor = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        old?.completion(Result(error: .cannotComplete, late: true, dispatched: false))
    }
}


// BEGIN UF03_OWNED_MENU_ACTION_TURN
// A single action in the menu's tracking turn. The queued block retains no
// owner or token; invalidation prevents a later menu from consuming it.
@MainActor
final class UF03OwnedMenuActionTurn: NSObject {
    static let trackingMode = "NSEventTrackingRunLoopMode"
    enum Status: String {
        case pending, armed, completed, invalidated, ownerGone, staleGeneration
        case foreignOwner, expired, wrongMode, inactiveMenu, actionRejected
    }
    private weak var owner: AnyObject?
    private weak var menu: NSMenu?
    private var trackingStarted = false
    private var trackingActive = false
    private let deadline: Double
    private let isCurrentGeneration: () -> Bool
    private let ownsTarget: () -> Bool
    private let startAction: (@escaping @MainActor (Bool) -> Void) -> Bool
    private let cleanup: () -> Void
    private var actionResult: Bool?
    private var consumeScheduled = false
    private var active = true
    private var armed = false
    private var deadlineTimer: Timer?
    private var actionStartObserver: CFRunLoopObserver?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var waiterResumptionQueued = false
    var lifetimeClosed: Bool { trackingStarted && !trackingActive && consumed }
    private(set) var consumed = false
    private(set) var actionCount = 0
    private(set) var cleanupCount = 0
    private(set) var status = Status.pending

    init(owner: AnyObject, menu: NSMenu, deadline: Double, isCurrentGeneration: @escaping () -> Bool,
         ownsTarget: @escaping () -> Bool,
         startAction: @escaping (@escaping @MainActor (Bool) -> Void) -> Bool,
         cleanup: @escaping () -> Void) {
        self.owner = owner; self.menu = menu; self.deadline = deadline
        self.isCurrentGeneration = isCurrentGeneration; self.ownsTarget = ownsTarget
        self.startAction = startAction; self.cleanup = cleanup
        super.init()
    }

    func arm() -> Bool {
        guard active, !armed, owner != nil, let menu, isCurrentGeneration(), ownsTarget(),
              ProcessInfo.processInfo.systemUptime < deadline else { return false }
        armed = true; status = .armed
        // Register before the first original AXPress. Queue the option action
        // only when this exact menu begins its own tracking lifetime.
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: menu)
        // One shot at the existing transaction deadline, also serviced while
        // this exact menu owns the nested tracking loop. No additional budget.
        let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime),
            target: self, selector: #selector(deadlineReached(_:)), userInfo: nil, repeats: false)
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: RunLoop.Mode(rawValue: Self.trackingMode))
        return true
    }

    @objc private func menuBeganTracking(_ notification: Notification) {
        guard Thread.isMainThread, active, armed, !trackingStarted,
              let menu, let notified = notification.object as? NSMenu, notified === menu else { return }
        trackingStarted = true
        trackingActive = true
        // Issue the one original request when the existing tracking loop has
        // processed its current timers/sources and is about to wait for input.
        // This is a one-shot lifecycle boundary, not an elapsed-time estimate.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { [weak self] _, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self?.actionStartObserver = nil
                self?.startTrackingAction()
            }
        }
        actionStartObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode(rawValue: Self.trackingMode as CFString))
    }

    private func startTrackingAction() {
        guard Thread.isMainThread, armed, !consumeScheduled else { return }
        // Re-evaluate every owner/action precondition immediately before the
        // worker is admitted; consume must never be the first guard.
        guard active, owner != nil, isCurrentGeneration(), ownsTarget(),
              trackingStarted, trackingActive,
              RunLoop.current.currentMode?.rawValue == Self.trackingMode,
              ProcessInfo.processInfo.systemUptime < deadline else {
            finishAction(false); return
        }
        // Start the one real AX request here: armed -> trackingStarted, before
        // the old consume block. consume only accepts its completed result.
        guard startAction({ [weak self] succeeded in
            self?.finishAction(succeeded)
        }) else {
            finishAction(false)
            return
        }
    }

    private func finishAction(_ succeeded: Bool) {
        guard active, !consumeScheduled else { return }
        actionResult = succeeded
        consumeScheduled = true
        // PRIVATE1737: completion is already delivered by the authenticated
        // descriptor on the original host run loop. A real option action may
        // end menu tracking before its response; do not queue behind that ended mode.
        consume()
        resumeIfClosed()
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        guard Thread.isMainThread, active, trackingStarted,
              let menu, let notified = notification.object as? NSMenu, notified === menu else { return }
        trackingActive = false
        resumeIfClosed()
    }

    private func resumeIfClosed() {
        guard lifetimeClosed else { return }
        finishWait(status == .completed && ProcessInfo.processInfo.systemUptime < deadline)
    }

    private func finishWait(_ success: Bool) {
        if let observer = actionStartObserver { CFRunLoopObserverInvalidate(observer) }
        actionStartObserver = nil
        guard waiter != nil, !waiterResumptionQueued else { return }
        waiterResumptionQueued = true
        // A tracking notification or deadline callback still runs inside the
        // native menu call. Resume the consumer on the existing default loop,
        // after that call can return and its normal binding commit can finish.
        // This neither pumps a mode nor grants another successful time budget.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.waiter else { return }
                self.waiter = nil
                self.waiterResumptionQueued = false
                self.deadlineTimer?.invalidate(); self.deadlineTimer = nil
                let stillCompleted = success && self.lifetimeClosed
                    && self.status == .completed
                    && ProcessInfo.processInfo.systemUptime < self.deadline
                UF03NativeOperationTrace.measure(.menuResume) {}
                current.resume(returning: stillCompleted)
            }
        }
    }

    private func cancelWait() {
        guard active else { return }
        status = .invalidated
        cancelOwnedTracking()
        active = false
        NotificationCenter.default.removeObserver(self)
        finishWait(false)
    }

    @objc private func deadlineReached(_ timer: Timer) {
        guard active, !lifetimeClosed else { return }
        UF03NativeOperationTrace.measure(.menuDeadline) {}
        status = .expired
        cancelOwnedTracking()
        finishWait(false)
    }

    func openAndWait(_ open: () -> Bool) async -> Bool {
        // Suspending the original MainActor caller lets the existing outer
        // NSApplication.run service the menu. No nested CFRunLoop or pump.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard active, armed, waiter == nil, !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    continuation.resume(returning: false); return
                }
                waiter = continuation
                guard open() else {
                    cancelOwnedTracking(); finishWait(false); return
                }
                resumeIfClosed()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelWait() }
        }
    }

    func invalidate() {
        finishWait(false)
        deadlineTimer?.invalidate(); deadlineTimer = nil
        active = false
        trackingActive = false
        NotificationCenter.default.removeObserver(self)
    }

    func cancelIfIncomplete() {
        if status != .completed { cancelOwnedTracking() }
    }

    private func consume() {
        guard !consumed else { return }
        consumed = true
        guard active else { status = .invalidated; return }
        guard owner != nil else { status = .ownerGone; return }
        guard isCurrentGeneration() else { status = .staleGeneration; return }
        guard ownsTarget() else { status = .foreignOwner; return }
        // PRIVATE1737 explicit exception: tracking active/mode remain mandatory
        // BEFORE dispatch in menuBeganTracking. Completion instead requires
        // the same living owner/generation, real result and original deadline.
        guard trackingStarted else { status = .inactiveMenu; return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            status = .expired; cancelOwnedTracking(); return
        }
        guard let succeeded = actionResult else {
            status = .actionRejected; cancelOwnedTracking(); return
        }
        actionCount = 1
        if ProcessInfo.processInfo.systemUptime >= deadline {
            status = .expired; cancelOwnedTracking()
        } else if succeeded {
            status = .completed
        } else {
            status = .actionRejected; cancelOwnedTracking()
        }
    }

    private func cancelOwnedTracking() {
        // Cleanup may close only the same current owner's menu. It does not
        // count as the option action, selection, or a business-state witness.
        guard active, owner != nil, isCurrentGeneration(), ownsTarget(), cleanupCount == 0 else { return }
        cleanupCount = 1
        cleanup()
    }
}
// END UF03_OWNED_MENU_ACTION_TURN

// The original menu consumer and its contract tests share these exact checks.
@MainActor
enum UF03OwnedPolicyMenuOwnership {
    static func failure(host: NSView, window: NSWindow, button: NSPopUpButton,
                        menu: NSMenu, caseID: String) -> String? {
        guard host.window === window else {
            return "HOST_WINDOW_MISMATCH"
        }
        guard window.contentViewController?.view === host else {
            return "HOST_CONTROLLER_VIEW_MISMATCH"
        }
        guard window.isVisible else {
            return "WINDOW_NOT_VISIBLE"
        }
        guard window.accessibilityIdentifier() == "uf03-owned-" + caseID else {
            return "WINDOW_IDENTIFIER_MISMATCH"
        }
        guard button.window === window else {
            return "BUTTON_WINDOW_MISMATCH"
        }
        guard button.isDescendant(of: host) else {
            return "BUTTON_NOT_DESCENDANT"
        }
        guard !button.isHiddenOrHasHiddenAncestor else {
            return "BUTTON_HIDDEN"
        }
        guard button.isEnabled else {
            return "BUTTON_DISABLED"
        }
        guard button.menu === menu else {
            return "BUTTON_MENU_MISMATCH"
        }
        guard (button.cell as? NSPopUpButtonCell)?.controlView === button else {
            return "CELL_CONTROL_VIEW_MISMATCH"
        }
        return nil
    }
}

// BEGIN UF03_COMPANION_OWNED_ROOT
// The root is the only retained AX value. The fixture lifetime and public
// owners must still match before every fresh subtree traversal.
struct State2958DiagnosticDimension: Codable, Equatable {
    let name: String
    let boolean: Bool?
    let observed: String?
    let error: String?
}

struct State2958DiagnosticPhase: Codable, Equatable {
    let phase: String
    let startUptime: Double
    let endUptime: Double
    let durationSeconds: Double
}

struct State2958DiagnosticRecord: Codable, Equatable {
    static let schema = "R18_STATE2958_RETRY2_COMPANION_DIAGNOSTIC_RECORD_V1"
    static let requiredDimensionNames = [
        "owner_window_identity", "owner_host_identity", "owner_lifetime_identity",
        "owner_generation", "owner_identifier", "owner_pid",
        "ownsWindow_host_window", "ownsWindow_content_view_owner", "ownsWindow_visible",
        "ownsWindow_host_visibility_alpha", "ownsWindow_identifier_prefix",
        "ownsWindow_unique_window", "ax_identifier_error_and_value",
        "ax_role_error_and_value", "ax_pid_error_and_value"
    ]
    static let requiredPhaseNames = [
        "prepare", "host_ready", "initial_search", "root_validation", "local_snapshot",
        "ax_traversal", "control_resolution", "transactions", "restoration", "cleanup", "total"
    ]

    let schema: String
    let caseID: String
    let zeroBasedOrdinal: Int
    let dimensions: [State2958DiagnosticDimension]
    let phases: [State2958DiagnosticPhase]
    let exactlyOneRecord: Bool
    let eligibilityDecisionUnchanged: Bool
    let extraAXActions: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case caseID = "case_id"
        case zeroBasedOrdinal = "zero_based_ordinal"
        case dimensions, phases, exactlyOneRecord = "exactly_one_record"
        case eligibilityDecisionUnchanged = "eligibility_decision_unchanged"
        case extraAXActions = "extra_ax_actions"
    }
}

@MainActor
final class State2958DiagnosticRecorder {
    private struct RawPhase {
        let start: Double
        var end: Double?
    }

    private let caseID: String
    private let zeroBasedOrdinal: Int
    private let startedUptime: Double
    private var phaseValues: [String: RawPhase] = [:]
    private var dimensionValues: [String: State2958DiagnosticDimension] = [:]
    private var finishedRecord: State2958DiagnosticRecord?

    init(caseID: String, zeroBasedOrdinal: Int) {
        self.caseID = caseID
        self.zeroBasedOrdinal = zeroBasedOrdinal
        self.startedUptime = ProcessInfo.processInfo.systemUptime
    }

    func begin(_ phase: String) {
        guard State2958DiagnosticRecord.requiredPhaseNames.dropLast().contains(phase),
              phaseValues[phase] == nil else { return }
        phaseValues[phase] = RawPhase(start: ProcessInfo.processInfo.systemUptime, end: nil)
    }

    func end(_ phase: String) {
        guard State2958DiagnosticRecord.requiredPhaseNames.dropLast().contains(phase),
              let value = phaseValues[phase], value.end == nil else { return }
        phaseValues[phase] = RawPhase(start: value.start,
            end: ProcessInfo.processInfo.systemUptime)
    }

    func isEnded(_ phase: String) -> Bool {
        phaseValues[phase]?.end != nil
    }

    func recordBoolean(_ name: String, _ value: Bool, observed: String) {
        dimensionValues[name] = State2958DiagnosticDimension(
            name: name, boolean: value, observed: observed, error: nil)
    }

    func recordAX(_ name: String, error: AXError, observed: String?) {
        dimensionValues[name] = State2958DiagnosticDimension(
            name: name, boolean: nil, observed: observed,
            error: String(describing: error) + "=" + String(error.rawValue))
    }

    func finish() -> State2958DiagnosticRecord {
        if let finishedRecord { return finishedRecord }
        var cursor = startedUptime
        var phases: [State2958DiagnosticPhase] = []
        for phase in State2958DiagnosticRecord.requiredPhaseNames.dropLast() {
            let raw = phaseValues[phase]
            let start = max(raw?.start ?? cursor, cursor)
            let end = max(raw?.end ?? start, start)
            phases.append(State2958DiagnosticPhase(phase: phase, startUptime: start,
                endUptime: end, durationSeconds: end - start))
            cursor = end
        }
        let totalEnd = max(ProcessInfo.processInfo.systemUptime, cursor)
        phases.append(State2958DiagnosticPhase(phase: "total", startUptime: startedUptime,
            endUptime: totalEnd, durationSeconds: totalEnd - startedUptime))
        let dimensions = State2958DiagnosticRecord.requiredDimensionNames.map { name in
            dimensionValues[name] ?? State2958DiagnosticDimension(
                name: name, boolean: nil, observed: "NOT_RECORDED", error: "NOT_RUN")
        }
        let record = State2958DiagnosticRecord(schema: State2958DiagnosticRecord.schema,
            caseID: caseID, zeroBasedOrdinal: zeroBasedOrdinal, dimensions: dimensions,
            phases: phases, exactlyOneRecord: true, eligibilityDecisionUnchanged: true,
            extraAXActions: 0)
        if let data = try? JSONEncoder.prettySorted.encode(record),
           data.count <= 16_384, let line = String(data: data, encoding: .utf8) {
            print("STATE2958_DIAGNOSTIC " + line.replacingOccurrences(of: "\n", with: ""))
        }
        finishedRecord = record
        return record
    }
}

@MainActor
final class UF03CompanionRootLifetime {
    private(set) var generation = 0
    private(set) var menuOpeningUnresolved = false
    func beginOwnedMenuOpening() -> Bool {
        guard !menuOpeningUnresolved else { return false }
        menuOpeningUnresolved = true
        return true
    }
    func finishOwnedMenuOpening() { menuOpeningUnresolved = false }
    func invalidate() { generation += 1 }
}

@MainActor
final class UF03CompanionOwnedRoot<Root> {
    private weak var window: AnyObject?
    private weak var host: AnyObject?
    private weak var lifetime: UF03CompanionRootLifetime?
    private let generation: Int
    private let root: Root
    private let identifier: String
    private let pid: Int32

    init(root: Root, window: AnyObject, host: AnyObject, lifetime: UF03CompanionRootLifetime,
         identifier: String, pid: Int32) {
        self.root = root; self.window = window; self.host = host
        self.lifetime = lifetime; self.generation = lifetime.generation
        self.identifier = identifier; self.pid = pid
    }

    func validatedRoot(window: AnyObject, host: AnyObject, lifetime: UF03CompanionRootLifetime,
                       identifier: String, pid: Int32, ownsWindow: () -> Bool,
                       validateAX: (Root, String, Int32) -> Bool,
                       diagnostic: State2958DiagnosticRecorder? = nil) -> Root? {
        let ownerWindowIdentity = self.window === window
        let ownerHostIdentity = self.host === host
        let ownerLifetimeIdentity = self.lifetime === lifetime
        let ownerGeneration = self.generation == lifetime.generation
        let ownerIdentifier = self.identifier == identifier
        let ownerPID = self.pid == pid
        let storedWindow = self.window.map { String(describing: ObjectIdentifier($0)) } ?? "NIL"
        let storedHost = self.host.map { String(describing: ObjectIdentifier($0)) } ?? "NIL"
        let storedLifetime = self.lifetime.map { String(describing: ObjectIdentifier($0)) } ?? "NIL"
        diagnostic?.recordBoolean("owner_window_identity", ownerWindowIdentity,
            observed: "stored=\(storedWindow);current=\(ObjectIdentifier(window))")
        diagnostic?.recordBoolean("owner_host_identity", ownerHostIdentity,
            observed: "stored=\(storedHost);current=\(ObjectIdentifier(host))")
        diagnostic?.recordBoolean("owner_lifetime_identity", ownerLifetimeIdentity,
            observed: "stored=\(storedLifetime);current=\(ObjectIdentifier(lifetime))")
        diagnostic?.recordBoolean("owner_generation", ownerGeneration,
            observed: "stored=\(self.generation);current=\(lifetime.generation)")
        diagnostic?.recordBoolean("owner_identifier", ownerIdentifier,
            observed: "stored=\(self.identifier);current=\(identifier)")
        diagnostic?.recordBoolean("owner_pid", ownerPID,
            observed: "stored=\(self.pid);current=\(pid)")
        guard self.window === window, self.host === host, self.lifetime === lifetime,
              self.generation == lifetime.generation, self.identifier == identifier,
              self.pid == pid, ownsWindow(), validateAX(root, identifier, pid) else { return nil }
        return root
    }
}
// END UF03_COMPANION_OWNED_ROOT

struct TypographyPackageFieldJourneyConfiguration: Equatable, Sendable {
    static let activationArgument = "--typography-field-journey"
    static let receiptArgument = "--typography-field-journey-receipt"
    static let sourceHeadKey = "MINISCANVAS_FIELD_SOURCE_HEAD"
    static let sourceTreeKey = "MINISCANVAS_FIELD_SOURCE_TREE"
    static let binarySHA256Key = "MINISCANVAS_FIELD_BINARY_SHA256"
    static let appTreeSHA256Key = "MINISCANVAS_FIELD_APP_TREE_SHA256"

    let receiptURL: URL
    let sourceHead: String
    let sourceTree: String
    let binarySHA256: String
    let appTreeSHA256: String

    static func resolveOrFail(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TypographyPackageFieldJourneyConfiguration? {
        // Bootstrap failures are rendered by the safe blocker and must never
        // reach this field-only assertion path, even if stale journey flags
        // remain in the process arguments.
        guard profile.mode != .blocked else { return nil }
        let activationCount = arguments.filter { $0 == activationArgument }.count
        guard activationCount > 0 else { return nil }
        precondition(activationCount == 1, "Typography field journey activation must be unique")
        precondition(profile.mode == .packagedField, "Typography field journey requires packaged-field profile")
        guard let receiptIndex = arguments.firstIndex(of: receiptArgument),
              arguments.indices.contains(receiptIndex + 1) else {
            preconditionFailure("Typography field journey receipt path is required")
        }
        let receiptURL = URL(fileURLWithPath: arguments[receiptIndex + 1]).standardizedFileURL
        precondition(receiptURL.path.hasPrefix("/"), "Typography field journey receipt path must be absolute")
        for key in [sourceHeadKey, sourceTreeKey] {
            precondition(
                environment[key]?.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
                "Typography field journey source identity is missing or malformed: \(key)"
            )
        }
        for key in [binarySHA256Key, appTreeSHA256Key] {
            precondition(
                environment[key]?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                "Typography field journey package identity is missing or malformed: \(key)"
            )
        }
        return TypographyPackageFieldJourneyConfiguration(
            receiptURL: receiptURL,
            sourceHead: environment[sourceHeadKey]!,
            sourceTree: environment[sourceTreeKey]!,
            binarySHA256: environment[binarySHA256Key]!,
            appTreeSHA256: environment[appTreeSHA256Key]!
        )
    }
}

struct NativeAccessibilityPackageFieldJourneyConfiguration: Equatable, Sendable {
    static let activationArgument = "--native-accessibility-field-journey"
    static let receiptArgument = "--native-accessibility-field-journey-receipt"

    let receiptURL: URL
    let sourceHead: String
    let sourceTree: String
    let binarySHA256: String
    let appTreeSHA256: String

    static func resolveOrFail(
        profile: RuntimeIsolationProfile,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NativeAccessibilityPackageFieldJourneyConfiguration? {
        guard profile.mode != .blocked else { return nil }
        let activationCount = arguments.filter { $0 == activationArgument }.count
        guard activationCount > 0 else { return nil }
        precondition(activationCount == 1, "Native accessibility field journey activation must be unique")
        precondition(profile.mode == .packagedField, "Native accessibility field journey requires packaged-field profile")
        guard let receiptIndex = arguments.firstIndex(of: receiptArgument),
              arguments.indices.contains(receiptIndex + 1) else {
            preconditionFailure("Native accessibility field journey receipt path is required")
        }
        let receiptURL = URL(fileURLWithPath: arguments[receiptIndex + 1]).standardizedFileURL
        precondition(receiptURL.path.hasPrefix("/"), "Native accessibility field journey receipt path must be absolute")
        for key in [
            TypographyPackageFieldJourneyConfiguration.sourceHeadKey,
            TypographyPackageFieldJourneyConfiguration.sourceTreeKey,
        ] {
            precondition(
                environment[key]?.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
                "Native accessibility field journey source identity is missing or malformed: \(key)"
            )
        }
        for key in [
            TypographyPackageFieldJourneyConfiguration.binarySHA256Key,
            TypographyPackageFieldJourneyConfiguration.appTreeSHA256Key,
        ] {
            precondition(
                environment[key]?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                "Native accessibility field journey package identity is missing or malformed: \(key)"
            )
        }
        return NativeAccessibilityPackageFieldJourneyConfiguration(
            receiptURL: receiptURL,
            sourceHead: environment[TypographyPackageFieldJourneyConfiguration.sourceHeadKey]!,
            sourceTree: environment[TypographyPackageFieldJourneyConfiguration.sourceTreeKey]!,
            binarySHA256: environment[TypographyPackageFieldJourneyConfiguration.binarySHA256Key]!,
            appTreeSHA256: environment[TypographyPackageFieldJourneyConfiguration.appTreeSHA256Key]!
        )
    }
}

enum TypographyPackageFieldJourneyContract {
    enum Surface: String, Codable, Sendable {
        case session
        case task
        case mcp
        case settings
    }

    struct Step: Equatable, Sendable {
        let semanticField: String
        let surface: Surface
        let identifier: String
        let widthMode: String
        let contentWidth: CGFloat
        let baseSize: Int
        let expectedPointSize: CGFloat
    }

    static func steps(sessionID: UUID) -> [Step] {
        let widths: [(String, CGFloat)] = [("narrow", 420), ("wide", 900)]
        var result: [Step] = []
        for (widthMode, width) in widths {
            result.append(contentsOf: [
                Step(semanticField: "sessionTitle", surface: .session,
                     identifier: "typography.session.title.\(sessionID.uuidString)",
                     widthMode: widthMode, contentWidth: width, baseSize: 12, expectedPointSize: 12),
                Step(semanticField: "sessionTitle", surface: .session,
                     identifier: "typography.session.title.\(sessionID.uuidString)",
                     widthMode: widthMode, contentWidth: width, baseSize: 20, expectedPointSize: 20),
                Step(semanticField: "sessionMetadata", surface: .session,
                     identifier: "typography.session.metadata.\(sessionID.uuidString)",
                     widthMode: widthMode, contentWidth: width, baseSize: 12, expectedPointSize: 11),
                Step(semanticField: "sessionMetadata", surface: .session,
                     identifier: "typography.session.metadata.\(sessionID.uuidString)",
                     widthMode: widthMode, contentWidth: width, baseSize: 20, expectedPointSize: 18),
                Step(semanticField: "taskGoalHeadline", surface: .task,
                     identifier: "typography.task.goal-headline",
                     widthMode: widthMode, contentWidth: width, baseSize: 12, expectedPointSize: 14),
                Step(semanticField: "taskGoalHeadline", surface: .task,
                     identifier: "typography.task.goal-headline",
                     widthMode: widthMode, contentWidth: width, baseSize: 20, expectedPointSize: 22),
                Step(semanticField: "mcpServerCount", surface: .mcp,
                     identifier: "typography.mcp.server-count",
                     widthMode: widthMode, contentWidth: width, baseSize: 12, expectedPointSize: 11),
                Step(semanticField: "mcpServerCount", surface: .mcp,
                     identifier: "typography.mcp.server-count",
                     widthMode: widthMode, contentWidth: width, baseSize: 20, expectedPointSize: 18),
                Step(semanticField: "settingsBody", surface: .settings,
                     identifier: "settings.typography.base-font-size.input",
                     widthMode: widthMode, contentWidth: widthMode == "narrow" ? 660 : width,
                     baseSize: 12, expectedPointSize: 12),
                Step(semanticField: "settingsBody", surface: .settings,
                     identifier: "settings.typography.base-font-size.input",
                     widthMode: widthMode, contentWidth: widthMode == "narrow" ? 660 : width,
                     baseSize: 20, expectedPointSize: 20),
            ])
        }
        return result
    }
}

@MainActor
struct TypographyPackageFieldJourneyView: View {
    let configuration: TypographyPackageFieldJourneyConfiguration
    let bridge: BridgeStore
    @Bindable var settingsCenter: SettingsCenter
    let shortcutStore: ShortcutStore
    let skillsStore: SkillsStore
    let schedulerStore: SchedulerTaskStore

    @State private var surface: TypographyPackageFieldJourneyContract.Surface = .session
    @State private var contentWidth: CGFloat = 420
    @State private var window: NSWindow?
    @State private var windowAccessorReady = false
    @State private var hasStarted = false

    private let sessionItem = ChatStore.SessionListItem(
        session: ChatThread(title: "Typography package field journey"),
        execution: nil
    )

    var body: some View {
        surfaceView
            .environment(\.typographyTokens, TypographyTokenProvider(center: settingsCenter))
            .environment(\.themeTokens, ThemeTokenProvider(center: settingsCenter))
            .frame(width: contentWidth, height: 520, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowAccessor(onWindowReady: {
                window = $0
                windowAccessorReady = true
            }))
            .task {
                guard !hasStarted else { return }
                hasStarted = true
                await runJourney()
            }
    }

    private var surfaceView: AnyView {
        switch surface {
        case .session:
            return SessionSidebarView(
                chat: bridge.chat,
                collapsed: false,
                sessionBadgeStore: bridge.sessionBadgeStore
            )
                .typographyInstrumentationRow(sessionItem)
        case .task:
            return TaskCenterObservationView(bridge: bridge).typographyInstrumentationView()
        case .mcp:
            return MCPManagerView(center: settingsCenter).typographyInstrumentationView()
        case .settings:
            return SettingsView(
                center: settingsCenter,
                shortcutStore: shortcutStore,
                skillsStore: skillsStore,
                schedulerStore: schedulerStore
            ).typographyInstrumentationView()
        }
    }

    private func runJourney() async {
        let steps = TypographyPackageFieldJourneyContract.steps(sessionID: sessionItem.session.id)
        var observations: [TypographyPackageFieldJourneyReceipt.Observation] = []
        var errors: [String] = []
        for _ in 0..<50 where window == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if window == nil {
            errors.append("window_group_not_ready")
        }
        for step in steps {
            surface = step.surface
            contentWidth = step.contentWidth
            settingsCenter.uiBaseFontSize = step.baseSize
            await settle()
            if let observation = await observe(step: step) {
                observations.append(observation)
                if !observation.matchesExpected {
                    errors.append("measurement_mismatch:\(step.semanticField):\(step.widthMode):\(step.baseSize)")
                }
            } else {
                errors.append("target_not_measurable:\(step.identifier):\(step.widthMode):\(step.baseSize)")
            }
        }
        let receipt = TypographyPackageFieldJourneyReceipt(
            schemaVersion: 1,
            status: errors.isEmpty && observations.count == steps.count ? "PASS" : "RED",
            realExit: errors.isEmpty && observations.count == steps.count ? 0 : 1,
            sourceHead: configuration.sourceHead,
            sourceTree: configuration.sourceTree,
            binarySHA256: configuration.binarySHA256,
            appTreeSHA256: configuration.appTreeSHA256,
            windowGroupReady: window != nil,
            windowAccessorReady: windowAccessorReady,
            expectedObservationCount: steps.count,
            observations: observations,
            errors: errors,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try FileManager.default.createDirectory(
                at: configuration.receiptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.prettySorted.encode(receipt)
            try data.write(to: configuration.receiptURL, options: .atomic)
        } catch {
            fputs("Typography package field receipt write failed: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        Darwin.exit(receipt.realExit == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(150))
        await Task.yield()
    }

    private func observe(
        step: TypographyPackageFieldJourneyContract.Step
    ) async -> TypographyPackageFieldJourneyReceipt.Observation? {
        for _ in 0..<20 {
            if let window,
               let selected = TypographyPackageAXProbe.measure(
                   identifier: step.identifier,
                   in: window
               ) {
                return .init(
                    semanticField: step.semanticField,
                    surface: step.surface.rawValue,
                    identifier: step.identifier,
                    widthMode: step.widthMode,
                    baseSize: step.baseSize,
                    expectedPointSize: Double(step.expectedPointSize),
                    observedPointSize: Double(selected.pointSize),
                    frameWidth: Double(selected.frame.width),
                    frameHeight: Double(selected.frame.height),
                    isClipped: selected.isClipped,
                    matchesExpected: abs(selected.pointSize - step.expectedPointSize) <= 0.5
                        && !selected.frame.isEmpty && !selected.isClipped
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

@MainActor
@Observable
private final class NativeAccessibilityJourneyNumericModel {
    private var storedValue = 12
    var value: Int {
        get { storedValue }
        set {
            storedValue = newValue
            persistedValue = newValue
            writeCount += 1
        }
    }

    private(set) var persistedValue = 12
    private(set) var writeCount = 0
}

@MainActor
private struct NativeAccessibilityJourneyNumericRoot: View {
    @Bindable var model: NativeAccessibilityJourneyNumericModel

    var body: some View {
        ValidatedNumericSettingField(
            "数值",
            value: $model.value,
            in: 1...100,
            accessibilityIdentifier: NativeAccessibilityPackageFieldJourneyView.numericFieldID
        )
        .padding(20)
        .frame(width: 420, height: 220, alignment: .topLeading)
    }
}

@MainActor
struct NativeAccessibilityPackageFieldJourneyView: View {
    static let taskID = "native-field-retry-task"
    static let retryTitle = "重试原任务"
    static let numericFieldID = "native.numeric.input"
    static let numericErrorID = "native.numeric.input.error"

    private enum Surface {
        case content
        case numeric
    }

    private struct InputState {
        let fieldStringValue: String
        let fieldEditorActive: Bool
        let firstResponderType: String?
    }

    let configuration: NativeAccessibilityPackageFieldJourneyConfiguration
    let bridge: BridgeStore
    let settingsCenter: SettingsCenter

    @State private var retryFixture: NativeFieldRetryFixture?
    private var journeyBridge: BridgeStore { retryFixture?.bridge ?? bridge }

    @State private var surface: Surface = .content
    @State private var window: NSWindow?
    @State private var windowAccessorReady = false
    @State private var hasStarted = false
    @State private var numericModel = NativeAccessibilityJourneyNumericModel()

    var body: some View {
        surfaceView
            .environment(journeyBridge)
            .environment(settingsCenter)
            .environment(\.typographyTokens, TypographyTokenProvider(center: settingsCenter))
            .environment(\.themeTokens, ThemeTokenProvider(center: settingsCenter))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowAccessor(onWindowReady: {
                window = $0
                windowAccessorReady = true
            }))
            .task {
                guard !hasStarted else { return }
                hasStarted = true
                await runJourney()
            }
    }

    private var surfaceView: AnyView {
        switch surface {
        case .content:
            return AnyView(ContentView(bridge: journeyBridge, transcriptEnvStore: settingsCenter.envStore))
        case .numeric:
            return AnyView(NativeAccessibilityJourneyNumericRoot(model: numericModel))
        }
    }

    private func runJourney() async {
        var errors: [String] = []
        var probeEvidence: [NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence] = []
        for _ in 0..<50 where window == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window else {
            writeReceipt(
                taskCenter: .missing,
                numeric: .missing,
                probeEvidence: [],
                composer: .notRun("window_group_not_ready"),
                errors: ["window_group_not_ready"]
            )
            return
        }

        let taskPrepared = await prepareFailedTask(errors: &errors)
        await settle(milliseconds: 300)

        let openSearch = await waitForAXElement(
            identifier: "open-task-center",
            phase: "open-before"
        )
        probeEvidence.append(openSearch.evidence)
        let openElement = openSearch.element
        let openBefore = NativeAccessibilityPackageAXProbe.control(
            identifier: "open-task-center",
            element: openElement,
            pressResult: nil
        )
        require(
            openBefore.found
                && openBefore.role == (kAXButtonRole as String)
                && openBefore.enabled == true
                && openBefore.label == "打开任务中心"
                && openBefore.value == "任务中心未打开",
            "open_task_center_contract_mismatch",
            errors: &errors
        )
        let openPress = openElement.map(NativeAccessibilityPackageAXProbe.press)
        let openPressed = openPress?.succeeded ?? false
        require(openPressed, "open_task_center_press_failed", errors: &errors)
        let open = NativeAccessibilityPackageAXProbe.control(
            identifier: "open-task-center",
            element: openElement,
            pressResult: openPress
        )

        let openState = await waitForOpenState()
        probeEvidence.append(contentsOf: openState.evidence)
        let observationFound = openState.witness.observationFound
        require(observationFound, "task_center_observation_missing", errors: &errors)

        let retryIdentifier = "task-center-control-retry-\(Self.taskID)"
        let retrySearch = await waitForAXElement(identifier: retryIdentifier, phase: "retry-before")
        probeEvidence.append(retrySearch.evidence)
        let retryElement = retrySearch.element
        let retryBefore = NativeAccessibilityPackageAXProbe.control(
            identifier: retryIdentifier,
            element: retryElement,
            pressResult: nil
        )
        require(
            retryBefore.found
                && retryBefore.role == (kAXButtonRole as String)
                && retryBefore.enabled == true
                && retryBefore.label == "重试任务 \(Self.retryTitle)"
                && retryBefore.value == "可用",
            "retry_contract_mismatch",
            errors: &errors
        )
        let retryPress = retryElement.map(NativeAccessibilityPackageAXProbe.press)
        let retryPressed = retryPress?.succeeded ?? false
        require(retryPressed, "retry_press_failed", errors: &errors)
        await retryFixture?.waitForHeldRetry()
        let retry = NativeAccessibilityPackageAXProbe.control(
            identifier: retryIdentifier,
            element: retryElement,
            pressResult: retryPress
        )
        let transition = journeyBridge.taskCenterControlConsumer.receiptRows(now: Date()).first {
            $0.taskID == Self.taskID
        }
        let transitionReceipt = NativeAccessibilityPackageFieldJourneyReceipt.TaskTransition(
            prepared: taskPrepared,
            taskID: transition?.taskID,
            parentID: transition?.parentID,
            runID: transition?.runID,
            taskState: transition?.taskState.rawValue,
            matchesExpected: retryFixture?.matchesHeldRetry(transition) == true,
            originalRunID: retryFixture?.originalReceipt.runID,
            originalParentID: retryFixture?.parentID
        )
        require(transitionReceipt.matchesExpected, "retry_transition_mismatch", errors: &errors)

        if let retryFixture { errors.append(contentsOf: await retryFixture.cleanup()) }

        let closeSearch = await waitForAXElement(
            identifier: "task-center-close",
            phase: "close-before"
        )
        probeEvidence.append(closeSearch.evidence)
        let closeElement = closeSearch.element
        let closeBefore = NativeAccessibilityPackageAXProbe.control(
            identifier: "task-center-close",
            element: closeElement,
            pressResult: nil
        )
        require(
            closeBefore.found
                && closeBefore.role == (kAXButtonRole as String)
                && closeBefore.enabled == true
                && closeBefore.label == "关闭任务中心"
                && closeBefore.value == "返回当前窗口",
            "close_task_center_contract_mismatch",
            errors: &errors
        )
        let closePress = closeElement.map(NativeAccessibilityPackageAXProbe.press)
        let closePressed = closePress?.succeeded ?? false
        require(closePressed, "close_task_center_press_failed", errors: &errors)
        let close = NativeAccessibilityPackageAXProbe.control(
            identifier: "task-center-close",
            element: closeElement,
            pressResult: closePress
        )
        await settle(milliseconds: 300)

        surface = .numeric
        await settle(milliseconds: 400)
        let numericResult = await runNumericJourney(in: window, errors: &errors)
        probeEvidence.append(contentsOf: numericResult.evidence)

        var composer = await runComposerJourney(in: window)
        if windowAccessorReady && self.window === window {
            composer.companionEvidence = await ComposerNativeFixtureContract.collectCompanionEvidence(journeyWindow: window)
        } else {
            composer.companionEvidence = ComposerNativeFixtureContract.companionNotRun("ORIGINAL_APP_HOST_NOT_READY")
        }
        errors.append(contentsOf: composer.errors)
        errors.append(contentsOf: composer.companionEvidence?.errors ?? ["companion_evidence_missing"])

        writeReceipt(
            taskCenter: .init(
                open: open,
                observationFound: observationFound,
                openStateWitness: openState.witness,
                retry: retry,
                transition: transitionReceipt,
                close: close
            ),
            numeric: numericResult.numeric,
            probeEvidence: Array(probeEvidence.prefix(12)),
            composer: composer,
            errors: errors
        )
    }


    private func runComposerJourney(in mainWindow: NSWindow) async -> ComposerNativeFixtureContract.JourneyResult {
        var observations: [ComposerNativeFixtureContract.Observation] = []
        var errors: [String] = []
        // Ordinary TaskCenter/numeric RED never prevents this independent matrix.
        // Only an actual missing host or fixture prerequisite produces NOT_RUN rows.
        guard window === mainWindow, windowAccessorReady else {
            return .notRun("composer_original_window_or_accessor_not_ready")
        }
        for group in ComposerNativeFixtureContract.Group.allCases {
            do {
                let fixture = try ComposerNativeFixtureContract.Fixture(group: group)
                defer { fixture.close() }
                for pair in fixture.pairs {
                    do {
                        let prepared = try await fixture.prepare(pair)
                        for consumer in ComposerNativeFixtureContract.Consumer.allCases {
                            let expected = pair.expected(consumer)
                            let probe = ComposerNativeFixtureContract.hostAndProbe(
                                prepared.root(consumer), width: expected.width,
                                rowIdentifier: expected.rowIdentifier, policyIdentifier: expected.policyIdentifier,
                                modelIdentifier: expected.modelIdentifier
                            )
                            let observation = prepared.observe(consumer, probe: probe)
                            observations.append(observation)
                            if !observation.stateMatchesExpected {
                                errors.append("composer_fixture_state_mismatch:\(expected.id)")
                            }
                            if !observation.usable {
                                errors.append("composer_native_geometry_missing_or_unusable:\(expected.id)")
                            }
                        }
                    } catch {
                        let reason = "composer_fixture_prerequisite:\(pair.id):\(error)"
                        errors.append(reason)
                        observations.append(contentsOf: ComposerNativeFixtureContract.Consumer.allCases.map {
                            .notRun(pair.expected($0), reason: reason)
                        })
                    }
                }
            } catch {
                let reason = "composer_fixture_owner_prerequisite:\(group.rawValue):\(error)"
                errors.append(reason)
                observations.append(contentsOf: ComposerNativeFixtureContract.expectedCases.filter {
                    $0.group == group
                }.map { .notRun($0, reason: reason) })
            }
        }
        let expected = ComposerNativeFixtureContract.expectedCases
        let completed = observations.map(\.expected) == expected
            && observations.allSatisfy(\.completed)
        if !completed { errors.append("composer_expected_matrix_incomplete") }
        // Every probe closes only its own secondary window. Return key status to
        // the original journey window before recording the existing native fields.
        mainWindow.makeKeyAndOrderFront(nil)
        return .init(expected: expected, observations: observations, completed: completed, errors: errors)
    }

    private func prepareFailedTask(errors: inout [String]) async -> Bool {
        do {
            let root = configuration.receiptURL.deletingLastPathComponent()
                .appendingPathComponent("native-retry-" + UUID().uuidString)
            retryFixture = try await NativeFieldRetryFixture.prepare(
                root: root, taskID: Self.taskID, title: Self.retryTitle)
            return true
        } catch {
            errors.append("failed_task_prepare:\(error)")
            return false
        }
    }

    private func runNumericJourney(
        in window: NSWindow,
        errors: inout [String]
    ) async -> (
        numeric: NativeAccessibilityPackageFieldJourneyReceipt.Numeric,
        evidence: [NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence]
    ) {
        guard let field = findTextField(in: window.contentView, title: "数值") else {
            errors.append("numeric_native_text_field_missing")
            return (.missing, [])
        }
        var inputWitnesses: [NativeAccessibilityPackageFieldJourneyReceipt.InputWitness] = []
        let outOfRangeBefore = inputState(field: field, window: window)
        let outOfRangeEvents = replaceInput("999", in: field, window: window)
            && sendKey(keyCode: 48, characters: "\t", window: window)
        await settle(milliseconds: 200)
        inputWitnesses.append(inputWitness(
            requestedInput: "999",
            terminator: "tab",
            eventsSucceeded: outOfRangeEvents,
            before: outOfRangeBefore,
            field: field,
            window: window
        ))
        let errorSearch = await waitForAXElement(
            identifier: Self.numericErrorID,
            phase: "numeric-out-of-range-error",
            maxAttempts: 60
        )
        let errorFound = errorSearch.element != nil
        let outOfRangeRetained = numericModel.value == 12
            && numericModel.persistedValue == 12
            && numericModel.writeCount == 0
        require(outOfRangeEvents, "numeric_out_of_range_events_failed", errors: &errors)
        require(errorFound, "numeric_error_identifier_missing", errors: &errors)
        require(outOfRangeRetained, "numeric_out_of_range_mutated_value", errors: &errors)

        let emptyBefore = inputState(field: field, window: window)
        let emptyEvents = replaceInput("", in: field, window: window)
            && sendKey(keyCode: 36, characters: "\r", window: window)
        await settle(milliseconds: 150)
        inputWitnesses.append(inputWitness(
            requestedInput: "",
            terminator: "return",
            eventsSucceeded: emptyEvents,
            before: emptyBefore,
            field: field,
            window: window
        ))
        let emptyRetained = numericModel.value == 12
            && numericModel.persistedValue == 12
            && numericModel.writeCount == 0
        require(emptyEvents, "numeric_empty_events_failed", errors: &errors)
        require(emptyRetained, "numeric_empty_mutated_value", errors: &errors)

        let negativeBefore = inputState(field: field, window: window)
        let negativeEvents = replaceInput("-1", in: field, window: window)
            && sendKey(keyCode: 36, characters: "\r", window: window)
        await settle(milliseconds: 150)
        inputWitnesses.append(inputWitness(
            requestedInput: "-1",
            terminator: "return",
            eventsSucceeded: negativeEvents,
            before: negativeBefore,
            field: field,
            window: window
        ))
        let negativeRetained = numericModel.value == 12
            && numericModel.persistedValue == 12
            && numericModel.writeCount == 0
        require(negativeEvents, "numeric_negative_events_failed", errors: &errors)
        require(negativeRetained, "numeric_negative_mutated_value", errors: &errors)

        return (.init(
            fieldFound: true,
            errorIdentifierFound: errorFound,
            outOfRangeRetained: outOfRangeRetained,
            emptyRetained: emptyRetained,
            negativeRetained: negativeRetained,
            finalValue: numericModel.value,
            persistedValue: numericModel.persistedValue,
            writeCount: numericModel.writeCount,
            eventsSucceeded: outOfRangeEvents && emptyEvents && negativeEvents,
            inputWitnesses: inputWitnesses
        ), [errorSearch.evidence])
    }

    private func waitForAXElement(
        identifier: String,
        phase: String,
        maxAttempts: Int = 20
    ) async -> NativeAccessibilityPackageAXProbe.SearchResult {
        var last = NativeAccessibilityPackageAXProbe.search(identifier: identifier, phase: phase)
        if last.element != nil { return last.recordingAttempts(1) }
        guard maxAttempts > 1 else { return last.recordingAttempts(1) }
        for attempt in 2...maxAttempts {
            try? await Task.sleep(for: .milliseconds(50))
            last = NativeAccessibilityPackageAXProbe.search(identifier: identifier, phase: phase)
            if last.element != nil {
                return last.recordingAttempts(attempt)
            }
        }
        return last.recordingAttempts(maxAttempts)
    }

    private func waitForOpenState() async -> (
        witness: NativeAccessibilityPackageFieldJourneyReceipt.OpenStateWitness,
        evidence: [NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence]
    ) {
        var lastOpen = NativeAccessibilityPackageAXProbe.search(
            identifier: "open-task-center",
            phase: "open-state"
        )
        var lastObservation = NativeAccessibilityPackageAXProbe.search(
            identifier: "task-center-observation",
            phase: "open-observation"
        )
        var lastValue = lastOpen.element.flatMap {
            NativeAccessibilityPackageAXProbe.stringAttribute(
                $0,
                kAXValueAttribute as CFString
            )
        }
        var openedValueObserved = lastValue == "任务中心已打开"
        var attempts = 1
        while attempts < 60 && lastObservation.element == nil {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
            lastOpen = NativeAccessibilityPackageAXProbe.search(
                identifier: "open-task-center",
                phase: "open-state"
            )
            lastObservation = NativeAccessibilityPackageAXProbe.search(
                identifier: "task-center-observation",
                phase: "open-observation"
            )
            lastValue = lastOpen.element.flatMap {
                NativeAccessibilityPackageAXProbe.stringAttribute(
                    $0,
                    kAXValueAttribute as CFString
                )
            }
            openedValueObserved = lastValue == "任务中心已打开"
        }
        return (
            .init(
                attempts: attempts,
                openControlFound: lastOpen.element != nil,
                lastOpenValue: lastValue,
                openedValueObserved: openedValueObserved,
                observationFound: lastObservation.element != nil,
                evidenceMeaning: "AX_STATE_WITNESS_ONLY_NOT_ACTION_CALLBACK_PROOF"
            ),
            [
                lastOpen.recordingAttempts(attempts).evidence,
                lastObservation.recordingAttempts(attempts).evidence,
            ]
        )
    }

    private func inputWitness(
        requestedInput: String,
        terminator: String,
        eventsSucceeded: Bool,
        before: InputState,
        field: NSTextField,
        window: NSWindow
    ) -> NativeAccessibilityPackageFieldJourneyReceipt.InputWitness {
        let after = inputState(field: field, window: window)
        return .init(
            requestedInput: requestedInput,
            terminator: terminator,
            eventsSucceeded: eventsSucceeded,
            fieldStringBefore: before.fieldStringValue,
            fieldStringAfter: after.fieldStringValue,
            fieldEditorActiveBefore: before.fieldEditorActive,
            fieldEditorActiveAfter: after.fieldEditorActive,
            firstResponderTypeBefore: before.firstResponderType,
            firstResponderTypeAfter: after.firstResponderType,
            focusOrResponderChanged: before.fieldEditorActive != after.fieldEditorActive
                || before.firstResponderType != after.firstResponderType,
            evidenceMeaning: "INPUT_DELIVERY_WITNESS_ONLY_NOT_COMMIT_PROOF"
        )
    }

    private func inputState(field: NSTextField, window: NSWindow) -> InputState {
        InputState(
            fieldStringValue: field.stringValue,
            fieldEditorActive: field.currentEditor() != nil,
            firstResponderType: window.firstResponder.map { String(describing: type(of: $0)) }
        )
    }

    private func settle(milliseconds: Int) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(milliseconds))
        await Task.yield()
    }

    private func require(_ condition: Bool, _ code: String, errors: inout [String]) {
        if !condition { errors.append(code) }
    }

    private func findTextField(in view: NSView?, title: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == title || field.accessibilityLabel() == title {
            return field
        }
        for child in view.subviews {
            if let field = findTextField(in: child, title: title) { return field }
        }
        return nil
    }

    private func replaceInput(_ text: String, in field: NSTextField, window: NSWindow) -> Bool {
        guard window.makeFirstResponder(field) else { return false }
        field.selectText(nil)
        pumpRunLoop()
        if text.isEmpty {
            return sendKey(keyCode: 51, characters: "", window: window)
        }
        for character in text {
            guard let keyCode = Self.digitKeyCodes[character],
                  sendKey(keyCode: keyCode, characters: String(character), window: window) else {
                return false
            }
        }
        return true
    }

    private func sendKey(keyCode: UInt16, characters: String, window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }
        window.sendEvent(event)
        pumpRunLoop()
        return true
    }

    private func pumpRunLoop() {
        for _ in 0..<4 {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func writeReceipt(
        taskCenter: NativeAccessibilityPackageFieldJourneyReceipt.TaskCenter,
        numeric: NativeAccessibilityPackageFieldJourneyReceipt.Numeric,
        probeEvidence: [NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence],
        composer: ComposerNativeFixtureContract.JourneyResult,
        errors: [String]
    ) {
        let receipt = NativeAccessibilityPackageFieldJourneyReceipt(
            schemaVersion: 1,
            status: errors.isEmpty ? "PASS" : "RED",
            realExit: errors.isEmpty ? 0 : 1,
            sourceHead: configuration.sourceHead,
            sourceTree: configuration.sourceTree,
            binarySHA256: configuration.binarySHA256,
            appTreeSHA256: configuration.appTreeSHA256,
            windowGroupReady: window != nil,
            windowAccessorReady: windowAccessorReady,
            applicationActive: NSApplication.shared.isActive,
            keyWindow: window?.isKeyWindow ?? false,
            formalGateResult: "NOT_APPLICABLE_DIAGNOSTIC_ONLY",
            taskCenter: taskCenter,
            numeric: numeric,
            probeEvidence: probeEvidence,
            composer: composer,
            errors: errors,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try FileManager.default.createDirectory(
                at: configuration.receiptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder.prettySorted.encode(receipt).write(
                to: configuration.receiptURL,
                options: .atomic
            )
        } catch {
            fputs("Native accessibility field receipt write failed: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        Darwin.exit(receipt.realExit == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static let digitKeyCodes: [Character: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "-": 27,
    ]
}

private enum NativeAccessibilityPackageAXProbe {
    struct PressResult {
        let error: AXError

        var succeeded: Bool { error == .success }
    }

    struct SearchResult {
        let element: AXUIElement?
        let evidence: NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence

        func recordingAttempts(_ attempts: Int) -> SearchResult {
            SearchResult(element: element, evidence: evidence.recordingAttempts(attempts))
        }
    }

    private struct AttributeRead {
        let name: String
        let error: AXError
        let value: CFTypeRef?

        var evidence: NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence {
            NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence(
                name: name,
                axErrorCode: error.rawValue,
                axErrorDescription: String(describing: error),
                rawTypeID: value.map(CFGetTypeID),
                rawTypeName: value.flatMap { raw in
                    CFCopyTypeIDDescription(CFGetTypeID(raw)) as String
                },
                decodedValues: Array(decodedStrings(from: value).prefix(32)),
                arrayCount: arrayCount(value),
                decodedElementCount: decodedElements(from: value).count
            )
        }
    }

    private struct TraversalState {
        var visited = Set<CFHashCode>()
        var visitedCount = 0
        var navigationEdgeCount = 0
        var ordinaryEdgeCount = 0
        var unionEdgeCount = 0
        var limitReached = false
        var rootIdentifier: NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence?
        var rootNavigationChildren: NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence?
        var rootChildren: NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence?
    }

    @MainActor
    static func search(identifier: String, phase: String) -> SearchResult {
        let application = AXUIElementCreateApplication(getpid())
        var state = TraversalState()
        let element = find(
            element: application,
            identifier: identifier,
            depth: 0,
            state: &state
        )
        return SearchResult(
            element: element,
            evidence: .init(
                phase: phase,
                identifier: identifier,
                attempts: 1,
                found: element != nil,
                visitedCount: state.visitedCount,
                traversalLimitReached: state.limitReached,
                navigationEdgeCount: state.navigationEdgeCount,
                ordinaryEdgeCount: state.ordinaryEdgeCount,
                unionEdgeCount: state.unionEdgeCount,
                rootIdentifier: state.rootIdentifier,
                rootNavigationChildren: state.rootNavigationChildren,
                rootChildren: state.rootChildren
            )
        )
    }

    @MainActor
    private static func find(
        element: AXUIElement,
        identifier: String,
        depth: Int,
        state: inout TraversalState
    ) -> AXUIElement? {
        guard state.visitedCount < 10_000 else {
            state.limitReached = true
            return nil
        }
        state.visitedCount += 1
        guard state.visited.insert(CFHash(element)).inserted else { return nil }

        let identifierRead = readAttribute(element, kAXIdentifierAttribute as CFString)
        if depth == 0 { state.rootIdentifier = identifierRead.evidence }
        if decodedString(from: identifierRead.value) == identifier {
            return element
        }

        let navigationRead = readAttribute(
            element,
            "AXChildrenInNavigationOrder" as CFString
        )
        let childrenRead = readAttribute(element, kAXChildrenAttribute as CFString)
        if depth == 0 {
            state.rootNavigationChildren = navigationRead.evidence
            state.rootChildren = childrenRead.evidence
        }
        let navigationChildren = decodedElements(from: navigationRead.value)
        let ordinaryChildren = decodedElements(from: childrenRead.value)
        let children = union(navigationChildren, ordinaryChildren)
        state.navigationEdgeCount += navigationChildren.count
        state.ordinaryEdgeCount += ordinaryChildren.count
        state.unionEdgeCount += children.count
        for child in children {
            if let match = find(
                element: child,
                identifier: identifier,
                depth: depth + 1,
                state: &state
            ) {
                return match
            }
        }
        return nil
    }

    @MainActor
    static func control(
        identifier: String,
        element: AXUIElement?,
        pressResult: PressResult?
    ) -> NativeAccessibilityPackageFieldJourneyReceipt.Control {
        guard let element else { return .missing(identifier: identifier) }
        let identifierRead = readAttribute(element, kAXIdentifierAttribute as CFString)
        let roleRead = readAttribute(element, kAXRoleAttribute as CFString)
        let enabledRead = readAttribute(element, kAXEnabledAttribute as CFString)
        let descriptionRead = readAttribute(element, kAXDescriptionAttribute as CFString)
        let titleRead = readAttribute(element, kAXTitleAttribute as CFString)
        let valueRead = readAttribute(element, kAXValueAttribute as CFString)
        let role = decodedString(from: roleRead.value)
        let enabled = decodedBool(from: enabledRead.value)
        let label = decodedString(from: descriptionRead.value)
            ?? decodedString(from: titleRead.value)
        let value = decodedString(from: valueRead.value)
        var actionNames: CFArray?
        let actionResult = UF03NativeOperationTrace.measure(.axReadActions) {
            AXUIElementCopyActionNames(element, &actionNames)
        }
        let actionRead = AttributeRead(
            name: "AXActionNames",
            error: actionResult,
            value: actionNames
        )
        let actions = actionResult == .success ? decodedStrings(from: actionNames) : []
        return .init(
            identifier: identifier,
            found: true,
            role: role,
            enabled: enabled,
            label: label,
            value: value,
            pressActionSupported: actions.contains(kAXPressAction as String),
            pressSucceeded: pressResult?.succeeded ?? false,
            pressAXErrorCode: pressResult?.error.rawValue,
            attributes: [
                identifierRead.evidence,
                roleRead.evidence,
                enabledRead.evidence,
                descriptionRead.evidence,
                titleRead.evidence,
                valueRead.evidence,
            ],
            actionNames: actionRead.evidence
        )
    }

    @MainActor
    static func press(_ element: AXUIElement) -> PressResult {
        let trace = UF03NativeOperationTrace.begin(.axPress)
        defer { UF03NativeOperationTrace.end(.axPress, trace) }
        return PressResult(error: AXUIElementPerformAction(element, kAXPressAction as CFString))
    }

    @MainActor
    static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        decodedString(from: readAttribute(element, name).value)
    }

    @MainActor
    private static func readAttribute(_ element: AXUIElement, _ name: CFString) -> AttributeRead {
        var value: CFTypeRef?
        let error = UF03NativeOperationTrace.measure(.axReadAttribute) {
            AXUIElementCopyAttributeValue(element, name, &value)
        }
        return AttributeRead(name: name as String, error: error, value: value)
    }

    private static func decodedString(from value: CFTypeRef?) -> String? {
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    private static func decodedBool(from value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private static func decodedStrings(from value: CFTypeRef?) -> [String] {
        if let string = decodedString(from: value) { return [string] }
        guard let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? NSArray else { return [] }
        return array.compactMap { item in
            let raw: CFTypeRef = item as AnyObject
            return decodedString(from: raw)
        }
    }

    private static func decodedElements(from value: CFTypeRef?) -> [AXUIElement] {
        guard let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? NSArray else { return [] }
        return array.compactMap { item in
            let raw: CFTypeRef = item as AnyObject
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }
    }

    private static func arrayCount(_ value: CFTypeRef?) -> Int? {
        guard let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? NSArray else { return nil }
        return array.count
    }

    private static func union(
        _ preferred: [AXUIElement],
        _ fallback: [AXUIElement]
    ) -> [AXUIElement] {
        var hashes = Set<CFHashCode>()
        return (preferred + fallback).filter { hashes.insert(CFHash($0)).inserted }
    }
}

private struct NativeAccessibilityPackageFieldJourneyReceipt: Encodable {
    struct AXValueEvidence: Codable {
        let name: String
        let axErrorCode: Int32
        let axErrorDescription: String
        let rawTypeID: CFTypeID?
        let rawTypeName: String?
        let decodedValues: [String]
        let arrayCount: Int?
        let decodedElementCount: Int
    }

    struct SearchEvidence: Codable {
        let phase: String
        let identifier: String
        let attempts: Int
        let found: Bool
        let visitedCount: Int
        let traversalLimitReached: Bool
        let navigationEdgeCount: Int
        let ordinaryEdgeCount: Int
        let unionEdgeCount: Int
        let rootIdentifier: AXValueEvidence?
        let rootNavigationChildren: AXValueEvidence?
        let rootChildren: AXValueEvidence?

        func recordingAttempts(_ attempts: Int) -> SearchEvidence {
            .init(
                phase: phase,
                identifier: identifier,
                attempts: attempts,
                found: found,
                visitedCount: visitedCount,
                traversalLimitReached: traversalLimitReached,
                navigationEdgeCount: navigationEdgeCount,
                ordinaryEdgeCount: ordinaryEdgeCount,
                unionEdgeCount: unionEdgeCount,
                rootIdentifier: rootIdentifier,
                rootNavigationChildren: rootNavigationChildren,
                rootChildren: rootChildren
            )
        }
    }

    struct OpenStateWitness: Codable {
        let attempts: Int
        let openControlFound: Bool
        let lastOpenValue: String?
        let openedValueObserved: Bool
        let observationFound: Bool
        let evidenceMeaning: String

        static let missing = OpenStateWitness(
            attempts: 0,
            openControlFound: false,
            lastOpenValue: nil,
            openedValueObserved: false,
            observationFound: false,
            evidenceMeaning: "AX_STATE_WITNESS_ONLY_NOT_ACTION_CALLBACK_PROOF"
        )
    }

    struct InputWitness: Codable {
        let requestedInput: String
        let terminator: String
        let eventsSucceeded: Bool
        let fieldStringBefore: String
        let fieldStringAfter: String
        let fieldEditorActiveBefore: Bool
        let fieldEditorActiveAfter: Bool
        let firstResponderTypeBefore: String?
        let firstResponderTypeAfter: String?
        let focusOrResponderChanged: Bool
        let evidenceMeaning: String
    }

    struct Control: Codable {
        let identifier: String
        let found: Bool
        let role: String?
        let enabled: Bool?
        let label: String?
        let value: String?
        let pressActionSupported: Bool
        let pressSucceeded: Bool
        let pressAXErrorCode: Int32?
        let attributes: [AXValueEvidence]
        let actionNames: AXValueEvidence?

        static func missing(identifier: String) -> Control {
            .init(
                identifier: identifier,
                found: false,
                role: nil,
                enabled: nil,
                label: nil,
                value: nil,
                pressActionSupported: false,
                pressSucceeded: false,
                pressAXErrorCode: nil,
                attributes: [],
                actionNames: nil
            )
        }
    }

    struct TaskTransition: Codable {
        let prepared: Bool
        let taskID: String?
        let parentID: String?
        let runID: String?
        let taskState: String?
        let matchesExpected: Bool
        var originalRunID: String? = nil
        var originalParentID: String? = nil
    }

    struct TaskCenter: Codable {
        let open: Control
        let observationFound: Bool
        let openStateWitness: OpenStateWitness
        let retry: Control
        let transition: TaskTransition
        let close: Control

        static let missing = TaskCenter(
            open: .missing(identifier: "open-task-center"),
            observationFound: false,
            openStateWitness: .missing,
            retry: .missing(identifier: "task-center-control-retry-native-field-retry-task"),
            transition: .init(
                prepared: false,
                taskID: nil,
                parentID: nil,
                runID: nil,
                taskState: nil,
                matchesExpected: false
            ),
            close: .missing(identifier: "task-center-close")
        )
    }

    struct Numeric: Codable {
        let fieldFound: Bool
        let errorIdentifierFound: Bool
        let outOfRangeRetained: Bool
        let emptyRetained: Bool
        let negativeRetained: Bool
        let finalValue: Int
        let persistedValue: Int
        let writeCount: Int
        let eventsSucceeded: Bool
        let inputWitnesses: [InputWitness]

        static let missing = Numeric(
            fieldFound: false,
            errorIdentifierFound: false,
            outOfRangeRetained: false,
            emptyRetained: false,
            negativeRetained: false,
            finalValue: 12,
            persistedValue: 12,
            writeCount: 0,
            eventsSucceeded: false,
            inputWitnesses: []
        )
    }

    let schemaVersion: Int
    let status: String
    let realExit: Int
    let sourceHead: String
    let sourceTree: String
    let binarySHA256: String
    let appTreeSHA256: String
    let windowGroupReady: Bool
    let windowAccessorReady: Bool
    let applicationActive: Bool
    let keyWindow: Bool
    let formalGateResult: String
    let taskCenter: TaskCenter
    let numeric: Numeric
    let probeEvidence: [SearchEvidence]
    let composer: ComposerNativeFixtureContract.JourneyResult
    let errors: [String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case realExit = "REAL_EXIT"
        case sourceHead = "source_head"
        case sourceTree = "source_tree"
        case binarySHA256 = "binary_sha256"
        case appTreeSHA256 = "app_tree_sha256"
        case windowGroupReady = "window_group_ready"
        case windowAccessorReady = "window_accessor_ready"
        case applicationActive = "application_active"
        case keyWindow = "key_window"
        case formalGateResult = "formal_gate_result"
        case taskCenter = "task_center"
        case numeric
        case probeEvidence = "probe_evidence"
        case composer
        case errors
        case createdAt = "created_at"
    }
}

private enum TypographyPackageAXProbe {
    struct Selection {
        let pointSize: CGFloat
        let frame: CGRect
        let isClipped: Bool
    }

    @MainActor
    static func measure(identifier: String, in window: NSWindow) -> Selection? {
        guard let contentView = window.contentView else { return nil }
        let application = AXUIElementCreateApplication(getpid())
        var visited = Set<CFHashCode>()
        var visitedCount = 0
        return find(
            element: application,
            identifier: identifier,
            window: window,
            contentView: contentView,
            visited: &visited,
            visitedCount: &visitedCount
        )
    }

    @MainActor
    private static func find(
        element: AXUIElement,
        identifier: String,
        window: NSWindow,
        contentView: NSView,
        visited: inout Set<CFHashCode>,
        visitedCount: inout Int
    ) -> Selection? {
        guard visitedCount < 10_000 else { return nil }
        visitedCount += 1
        guard visited.insert(CFHash(element)).inserted else { return nil }
        if attribute(element, kAXIdentifierAttribute as CFString) as? String == identifier,
           let pointSize = pointSize(in: element),
           let screenFrame = frame(of: element),
           !screenFrame.isEmpty {
            let windowFrame = window.convertFromScreen(screenFrame)
            let localFrame = contentView.convert(windowFrame, from: nil)
            return Selection(
                pointSize: pointSize,
                frame: localFrame,
                isClipped: !contentView.bounds.contains(localFrame)
            )
        }
        let children = (attribute(
            element,
            "AXChildrenInNavigationOrder" as CFString
        ) as? [AXUIElement]) ?? (attribute(
            element,
            kAXChildrenAttribute as CFString
        ) as? [AXUIElement]) ?? []
        for child in children {
            if let selected = find(
                element: child,
                identifier: identifier,
                window: window,
                contentView: contentView,
                visited: &visited,
                visitedCount: &visitedCount
            ) {
                return selected
            }
        }
        return nil
    }

    @MainActor
    private static func pointSize(in element: AXUIElement) -> CGFloat? {
        if let direct = directPointSize(in: element) { return direct }
        let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for child in children {
            if let nested = directPointSize(in: child) { return nested }
        }
        return nil
    }

    @MainActor
    private static func directPointSize(in element: AXUIElement) -> CGFloat? {
        guard let value = attribute(element, kAXValueAttribute as CFString) as? String,
              !value.isEmpty else { return nil }
        let range = NSRange(location: 0, length: value.utf16.count)
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success,
              let attributed = result as? NSAttributedString,
              attributed.length > 0,
              let font = attributed.attribute(
                  NSAttributedString.Key.accessibilityFont,
                  at: 0,
                  effectiveRange: nil
              ) as? [AnyHashable: Any],
              let size = font[NSAccessibility.FontAttributeKey.fontSize] as? NSNumber else {
            return nil
        }
        return CGFloat(size.doubleValue)
    }

    @MainActor
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let rawFrame = attribute(element, "AXFrame" as CFString),
              CFGetTypeID(rawFrame) == AXValueGetTypeID() else { return nil }
        let frameValue = unsafeDowncast(rawFrame, to: AXValue.self)
        var frame = CGRect.zero
        guard AXValueGetType(frameValue) == .cgRect,
              AXValueGetValue(frameValue, .cgRect, &frame) else { return nil }
        return frame
    }

    @MainActor
    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success
            ? value
            : nil
    }
}

private struct TypographyPackageFieldJourneyReceipt: Codable {
    struct Observation: Codable {
        let semanticField: String
        let surface: String
        let identifier: String
        let widthMode: String
        let baseSize: Int
        let expectedPointSize: Double
        let observedPointSize: Double
        let frameWidth: Double
        let frameHeight: Double
        let isClipped: Bool
        let matchesExpected: Bool
    }

    let schemaVersion: Int
    let status: String
    let realExit: Int
    let sourceHead: String
    let sourceTree: String
    let binarySHA256: String
    let appTreeSHA256: String
    let windowGroupReady: Bool
    let windowAccessorReady: Bool
    let expectedObservationCount: Int
    let observations: [Observation]
    let errors: [String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case realExit = "REAL_EXIT"
        case sourceHead = "source_head"
        case sourceTree = "source_tree"
        case binarySHA256 = "binary_sha256"
        case appTreeSHA256 = "app_tree_sha256"
        case windowGroupReady = "window_group_ready"
        case windowAccessorReady = "window_accessor_ready"
        case expectedObservationCount = "expected_observation_count"
        case observations, errors
        case createdAt = "created_at"
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}


// A single fixture contract is consumed by the original Swift Testing suite and
// the explicitly activated packaged-field journey. Normal App flow never calls it.
@MainActor
enum ComposerNativeFixtureContract {
    enum Group: String, Codable, CaseIterable {
        case widthsAndFonts, policies, generating
    }

    enum Consumer: String, Codable, CaseIterable {
        case global, companion
    }

    struct Pair {
        let id: String
        let group: Group
        let modelID: String
        let fontSize: Int
        let width: CGFloat
        let policy: ComposerPolicySelection
        let fixtureKey: String

        func expected(_ consumer: Consumer) -> ExpectedCase {
            ExpectedCase(
                id: "\(id):\(consumer.rawValue)", group: group, consumer: consumer,
                modelID: modelID, fontSize: fontSize, width: width, policy: policy,
                generating: group == .generating,
                attachmentPreparedCount: group == .generating ? 1 : 0,
                skillPreparedIDs: group == .generating ? ["skill:uf03-fixture"] : [],
                rowIdentifier: consumer == .global ? "composer.primary-row.global" : "composer.primary-row.companion",
                policyIdentifier: consumer == .global ? "composer.policy" : "composer.policy.companion",
                modelIdentifier: consumer == .global ? "composer.model" : "composer.model.companion"
            )
        }
    }

    struct ExpectedCase: Codable, Equatable {
        let id: String
        let group: Group
        let consumer: Consumer
        let modelID: String
        let fontSize: Int
        let width: CGFloat
        let policy: ComposerPolicySelection
        let generating: Bool
        let attachmentPreparedCount: Int
        let skillPreparedIDs: [String]
        let rowIdentifier: String
        let policyIdentifier: String
        let modelIdentifier: String
    }

    static var pairs: [Pair] {
        let defaultPolicy = ComposerPolicySelection(
            mode: .autoEdit, approvalScope: .request, effort: .high, bypassModeConfirmed: false
        )
        var result: [Pair] = []
        for (modelIndex, modelID) in ["deepseek-chat", "provider-model-with-a-deliberately-long-display-name-for-uf03"].enumerated() {
            for fontSize in [12, 13, 16, 20] {
                for width: CGFloat in [600, 800, 1000, 1280, 1600] {
                    result.append(Pair(
                        id: "widthsAndFonts:m\(modelIndex):f\(fontSize):w\(Int(width))",
                        group: .widthsAndFonts, modelID: modelID, fontSize: fontSize,
                        width: width, policy: defaultPolicy, fixtureKey: "model:\(modelIndex)"
                    ))
                }
            }
        }
        let policies: [ComposerPolicySelection] = [
            ComposerPolicySelection(mode: .manual, approvalScope: .request, effort: .low, bypassModeConfirmed: false),
            ComposerPolicySelection(mode: .autoEdit, approvalScope: .request, effort: .standard, bypassModeConfirmed: false),
            ComposerPolicySelection(mode: .plan, approvalScope: .request, effort: .high, bypassModeConfirmed: false),
            ComposerPolicySelection(mode: .auto, approvalScope: .request, effort: .standard, bypassModeConfirmed: false),
            ComposerPolicySelection(mode: .bypassPermission, approvalScope: .request, effort: .high, bypassModeConfirmed: true)
        ]
        for (index, policy) in policies.enumerated() {
            result.append(Pair(id: "policies:p\(index)", group: .policies,
                               modelID: "deepseek-chat", fontSize: 13, width: 800,
                               policy: policy, fixtureKey: "policy:\(index)"))
        }
        result.append(Pair(id: "generating", group: .generating, modelID: "deepseek-chat",
                           fontSize: 13, width: 800, policy: defaultPolicy, fixtureKey: "generating"))
        return result
    }

    static var expectedCases: [ExpectedCase] {
        pairs.flatMap { pair in Consumer.allCases.map { pair.expected($0) } }
    }

    enum FixtureError: Error {
        case defaultsUnavailable, closed, wrongGroup, modelSelectionFailed, incompleteGeneratingInputs
        case attachmentPreparation(String)
        case generatingSubmission(String)
    }

    @MainActor
    struct Prepared {
        let pair: Pair
        let chat: ChatStore
        let center: SettingsCenter
        let bridge: BridgeStore
        let attachmentPreparedCount: Int
        let skillPreparedIDs: [String]

        func root(_ consumer: Consumer) -> AnyView {
            switch consumer {
            case .global:
                return AnyView(
                    GlobalComposerView(bridge: bridge, chat: chat, mainPane: .chat)
                        .environment(\.typographyTokens, TypographyTokenProvider(center: center))
                )
            case .companion:
                return AnyView(
                    CompanionChatView(chat: chat, bridge: bridge, transcriptEnvStore: center.envStore)
                        .environment(\.typographyTokens, TypographyTokenProvider(center: center))
                )
            }
        }

        func observe(_ consumer: Consumer, probe: HostedProbe) -> Observation {
            let expected = pair.expected(consumer)
            let actual = ActualState(
                modelID: chat.selectedModelID,
                policy: chat.composerPolicySelection,
                fontSize: center.uiBaseFontSize,
                streaming: chat.isActiveSessionStreaming,
                attachmentPreparedCount: attachmentPreparedCount,
                skillPreparedIDs: skillPreparedIDs
            )
            return Observation(
                expected: expected, actual: actual, probe: probe, completed: true,
                completionStatus: "COMPLETED", prerequisiteFailure: nil,
                stateMatchesExpected: actual.modelID == expected.modelID
                    && actual.policy == expected.policy && actual.fontSize == expected.fontSize
                    && actual.streaming == expected.generating
                    && actual.attachmentPreparedCount == expected.attachmentPreparedCount
                    && actual.skillPreparedIDs == expected.skillPreparedIDs,
                usable: probe.isUsable
            )
        }
    }

    // Own only fresh fixture resources. Both hosts create the same real stores,
    // selected models, policy values, attachment and Skill preparation.
    @MainActor
    final class Fixture {
        let group: Group
        let center: SettingsCenter
        let bridge: BridgeStore
        private let directory: URL
        private let defaultsName: String
        private let defaults: UserDefaults
        private let modelSelectionObserved: (Bool) -> Void
        private var chats: [String: ChatStore] = [:]
        private var generatingInputs: (Int, [String]) = (0, [])
        private var closed = false

        var pairs: [Pair] { ComposerNativeFixtureContract.pairs.filter { $0.group == group } }

        init(group: Group, modelSelectionObserved: @escaping (Bool) -> Void = { _ in }) throws {
            self.group = group
            self.modelSelectionObserved = modelSelectionObserved
            let identity = UUID().uuidString
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UF03ComposerNative-\(identity)", isDirectory: true)
            defaultsName = "UF03ComposerNative.\(identity)"
            guard let defaults = UserDefaults(suiteName: defaultsName) else {
                throw FixtureError.defaultsUnavailable
            }
            self.defaults = defaults
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let log = LogManager(directory: directory, ringCapacity: 20)
            center = SettingsCenter(
                settingsStore: SettingsStore(directory: directory), envStore: EnvVarStore(directory: directory),
                memoryStore: MemoryStore(directory: directory), sessionStore: SessionStore(directory: directory),
                logManager: log
            )
            bridge = BridgeStore(
                shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults, logManager: log,
                sessionDocumentStore: SessionDocumentStore(directory: directory)
            )
        }

        func prepare(_ pair: Pair) async throws -> Prepared {
            guard !closed else { throw FixtureError.closed }
            guard pair.group == group else { throw FixtureError.wrongGroup }
            if center.uiBaseFontSize != pair.fontSize { center.uiBaseFontSize = pair.fontSize }
            let chat: ChatStore
            if let existing = chats[pair.fixtureKey] {
                chat = existing
            } else {
                chat = ChatStore(preferencesDefaults: defaults, logManager: center.logManager)
                chat.setProvider(.deepSeek)
                let applied = chat.applyPickedModel(modelID: pair.modelID)
                modelSelectionObserved(applied)
                guard applied else { throw FixtureError.modelSelectionFailed }
                chat.composerPolicySelection = pair.policy
                chats[pair.fixtureKey] = chat
                if group == .generating {
                    chat.agentEngine = InterruptRecordingEngine()
                    chat.streamingProviderOverride = MockProvider.shared
                    guard let sessionID = chat.activeSessionID else {
                        throw FixtureError.attachmentPreparation("missing_fixture_session")
                    }
                    let attachmentURL = directory.appendingPathComponent("uf03-native-fixture.txt")
                    try Data("fixture".utf8).write(to: attachmentURL)
                    let attachmentIDs = chat.addAttachments(urls: [attachmentURL]).map(\.id)
                    let skill = PickerCatalogItem(
                        id: "skill:uf03-fixture", kind: .skill, name: "UF03 Fixture Skill",
                        detail: "native fixture", content: "fixture"
                    )
                    chat.pickerCatalogLoader = { [skill] }
                    chat.loadPickerCatalog()
                    chat.togglePickerItem(skill)
                    generatingInputs = (chat.pendingAttachments.count, chat.selectedPickerItems.map(\.id))
                    guard generatingInputs.0 == 1, generatingInputs.1 == [skill.id] else {
                        throw FixtureError.incompleteGeneratingInputs
                    }
                    try await awaitAttachmentsReady(chat, sessionID: sessionID, attachmentIDs: attachmentIDs)
                    chat.draftText = "UF03 generating fixture"
                    let previousUserIDs = Set(chat.messages.filter { $0.role == .user }.map(\.id))
                    chat.submitComposer()
                    let submittedUsers = chat.messages.filter {
                        $0.role == .user && !previousUserIDs.contains($0.id)
                    }
                    let snapshot = chat.lastComposerSubmissionSnapshot
                    guard chat.activeSessionID == sessionID, submittedUsers.count == 1,
                          submittedUsers.first?.attachments.map(\.id) == attachmentIDs,
                          snapshot?.sessionID == sessionID.uuidString,
                          snapshot?.messageID == submittedUsers.first?.id.uuidString,
                          snapshot?.mode == pair.policy.mode,
                          snapshot?.approvalScope == pair.policy.approvalScope,
                          snapshot?.effort == pair.policy.effort,
                          snapshot?.bypassModeConfirmed == pair.policy.bypassModeConfirmed,
                          chat.isActiveSessionStreaming, chat.draftText.isEmpty,
                          chat.pendingAttachments.isEmpty else {
                        throw FixtureError.generatingSubmission(
                            "sessionMatches=\(chat.activeSessionID == sessionID) newUsers=\(submittedUsers.count) "
                            + "snapshotPresent=\(snapshot != nil) streaming=\(chat.isActiveSessionStreaming) "
                            + "draftEmpty=\(chat.draftText.isEmpty) pendingCount=\(chat.pendingAttachments.count)"
                        )
                    }
                }
            }
            return Prepared(pair: pair, chat: chat, center: center, bridge: bridge,
                            attachmentPreparedCount: generatingInputs.0, skillPreparedIDs: generatingInputs.1)
        }

        // Exercise the real detached reader and its MainActor owner-fenced commit.
        // A delay alone never establishes readiness; failed/missing/foreign slots fail closed.
        func awaitAttachmentsReady(
            _ chat: ChatStore, sessionID: UUID, attachmentIDs: [UUID],
            timeout: Duration = .seconds(5)
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                try Task.checkCancellation()
                let attachments = chat.pendingAttachments
                let readiness = chat.composerMediaReadinessSnapshot
                func failure(_ reason: String) -> FixtureError {
                    let states = attachments.map { "\($0.id.uuidString):\($0.status.rawValue)" }.joined(separator: ",")
                    return .attachmentPreparation(
                        "\(reason) owner=\(sessionID.uuidString) current=\(chat.activeSessionID?.uuidString ?? "nil") "
                        + "expected=\(attachmentIDs.map(\.uuidString).joined(separator: ",")) states=[\(states)] "
                        + "canSubmit=\(readiness.canSubmitAttachments) blocked=\(readiness.blockedReason ?? "none")"
                    )
                }
                guard !closed else { throw failure("fixture_closed") }
                guard chat.activeSessionID == sessionID else { throw failure("owner_changed") }
                guard !attachmentIDs.isEmpty, attachments.map(\.id) == attachmentIDs else {
                    throw failure("attachment_slots_changed")
                }
                guard attachments.allSatisfy({ $0.status != .failed }) else {
                    throw failure("attachment_failed")
                }
                if attachments.allSatisfy({ $0.status == .ready }) {
                    guard readiness.canSubmitAttachments else { throw failure("ready_but_submission_blocked") }
                    return
                }
                guard clock.now < deadline else { throw failure("attachment_ready_timeout") }
                // Conditional polling yields the MainActor to the real resolver; recheck every field.
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(10))))
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            for chat in chats.values {
                chat.stopStreaming()
                chat.pickerCatalogLoader = { [] }
            }
            chats.removeAll()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    struct ActualState: Codable {
        let modelID: String?
        let policy: ComposerPolicySelection
        let fontSize: Int
        let streaming: Bool
        // These witness input preparation before submit clears the composer chips.
        let attachmentPreparedCount: Int
        let skillPreparedIDs: [String]
    }

    struct Observation: Codable {
        let expected: ExpectedCase
        let actual: ActualState?
        let probe: HostedProbe?
        let completed: Bool
        let completionStatus: String
        let prerequisiteFailure: String?
        let stateMatchesExpected: Bool
        let usable: Bool

        static func notRun(_ expected: ExpectedCase, reason: String) -> Observation {
            Observation(expected: expected, actual: nil, probe: nil, completed: false,
                        completionStatus: "NOT_RUN_PREREQUISITE", prerequisiteFailure: reason,
                        stateMatchesExpected: false, usable: false)
        }
    }

    struct JourneyResult: Encodable {
        let expected: [ExpectedCase]
        let observations: [Observation]
        let completed: Bool
        let errors: [String]
        var companionEvidence: CompanionEvidenceResult? = nil

        @MainActor
        static func notRun(_ reason: String) -> JourneyResult {
            let expected = ComposerNativeFixtureContract.expectedCases
            return JourneyResult(expected: expected,
                                 observations: expected.map { .notRun($0, reason: reason) },
                                 completed: false, errors: [reason],
                                 companionEvidence: ComposerNativeFixtureContract.companionNotRun(reason))
        }
    }
    struct HostedProbe: Codable {
        let row: CGRect?
        let policy: CGRect?
        let model: CGRect?
        let diagnostics: String
        let samples: Int
        let rowAX: UF03AXSnapshot
        let policyAX: UF03AXSnapshot
        let modelAX: UF03AXSnapshot

        var isUsable: Bool {
            guard let row, let policy, let model,
                  !row.isEmpty, !policy.isEmpty, !model.isEmpty else { return false }
            let hostRect = hostFrame
            let yCenterTolerance = max(10, min(policy.height, model.height) * 0.75)
            let sameRow = abs(policy.midY - model.midY) <= yCenterTolerance
            let controlsAreAdjacent = policy.maxX <= model.minX || model.maxX <= policy.minX
            let rowContainsControls = hostRect.contains(row)
                && row.contains(policy)
                && row.contains(model)
            let controlsFullyVisible = hostRect.contains(policy) && hostRect.contains(model)
            return sameRow && controlsAreAdjacent && rowContainsControls && controlsFullyVisible
        }

        var hostFrame: CGRect = .zero
        var nativeHostReady: Bool = false
    }

    @MainActor
    private final class OwnedIdentifierWindow: NSWindow {
        private var ownedAccessibilityIdentifier: String?

        override func accessibilityIdentifier() -> String {
            ownedAccessibilityIdentifier ?? super.accessibilityIdentifier()
        }

        override func setAccessibilityIdentifier(_ identifier: String?) {
            ownedAccessibilityIdentifier = identifier
            super.setAccessibilityIdentifier(identifier)
        }
    }

    @MainActor
    static func hostAndProbe(
        _ root: AnyView,
        width: CGFloat,
        rowIdentifier: String,
        policyIdentifier: String,
        modelIdentifier: String,
        onCreated: (NSWindow) -> Void = { _ in },
        onSampled: (NSWindow) -> Void = { _ in },
        onClosed: (NSWindow) -> Void = { _ in },
        onEvidence: ((NSWindow, NSView, HostedProbe) -> Void)? = nil
    ) -> HostedProbe {
        let prepared = prepareHostedProbe(root, width: width, rowIdentifier: rowIdentifier,
            policyIdentifier: policyIdentifier, modelIdentifier: modelIdentifier,
            onCreated: onCreated, onSampled: onSampled)
        defer {
            prepared.window.orderOut(nil)
            prepared.window.contentViewController = nil
            prepared.window.close()
            onClosed(prepared.window)
        }
        onEvidence?(prepared.window, prepared.controller.view, prepared.probe)
        return prepared.probe
    }

    @MainActor
    static func hostAndProbeAsync(
        _ root: AnyView,
        width: CGFloat,
        rowIdentifier: String,
        policyIdentifier: String,
        modelIdentifier: String,
        onCreated: (NSWindow) -> Void = { _ in },
        onSampled: (NSWindow) -> Void = { _ in },
        onClosed: (NSWindow) -> Void = { _ in },
        onEvidence: @MainActor (NSWindow, NSView, HostedProbe) async -> Void
    ) async -> HostedProbe {
        let prepared = await prepareHostedProbeAsync(root, width: width, rowIdentifier: rowIdentifier,
            policyIdentifier: policyIdentifier, modelIdentifier: modelIdentifier,
            onCreated: onCreated, onSampled: onSampled)
        defer {
            prepared.window.orderOut(nil)
            prepared.window.contentViewController = nil
            prepared.window.close()
            onClosed(prepared.window)
        }
        await onEvidence(prepared.window, prepared.controller.view, prepared.probe)
        return prepared.probe
    }

    @MainActor
    private static func prepareHostedProbe(
        _ root: AnyView, width: CGFloat, rowIdentifier: String,
        policyIdentifier: String, modelIdentifier: String,
        onCreated: (NSWindow) -> Void, onSampled: (NSWindow) -> Void
    ) -> (window: NSWindow, controller: NSHostingController<AnyView>, probe: HostedProbe) {
        var preparation = makeHostedProbePreparation(root, width: width, rowIdentifier: rowIdentifier,
            policyIdentifier: policyIdentifier, modelIdentifier: modelIdentifier, onCreated: onCreated)
        for attempt in 1...30 {
            preparation.layout()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            preparation.takeSample(attempt)
            if preparation.ready { break }
        }
        return preparation.finish(onSampled: onSampled)
    }

    @MainActor
    private static func prepareHostedProbeAsync(
        _ root: AnyView, width: CGFloat, rowIdentifier: String,
        policyIdentifier: String, modelIdentifier: String,
        onCreated: (NSWindow) -> Void, onSampled: (NSWindow) -> Void
    ) async -> (window: NSWindow, controller: NSHostingController<AnyView>, probe: HostedProbe) {
        // Spend the first existing sampling slot before the activation request.
        // The prior host may have queued a resignation when restoring its policy;
        // let the original AppKit loop deliver that before activating this host.
        // A cancelled delay still proceeds through mount/close to release its lease.
        do { try await Task.sleep(nanoseconds: 10_000_000) }
        catch { }
        var preparation = makeHostedProbePreparation(root, width: width, rowIdentifier: rowIdentifier,
            policyIdentifier: policyIdentifier, modelIdentifier: modelIdentifier, onCreated: onCreated)
        // Keep thirty samples and thirty total 10 ms delay slots. The first
        // delay was consumed above; remaining samples yield to the same loop.
        for attempt in 1...30 {
            if Task.isCancelled { break }
            preparation.layout()
            if attempt > 1 {
                do { try await Task.sleep(nanoseconds: 10_000_000) }
                catch { break }
            }
            preparation.takeSample(attempt)
            if preparation.ready { break }
        }
        return preparation.finish(onSampled: onSampled)
    }

    @MainActor
    private struct HostedProbePreparation {
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        let ownerIdentifier: String
        let width: CGFloat
        let rowIdentifier: String
        let policyIdentifier: String
        let modelIdentifier: String
        var row: UF03AXSnapshot
        var policy: UF03AXSnapshot
        var model: UF03AXSnapshot
        let localBefore: String
        let publicExposure: String
        let localAfter: String
        var samples = 0

        func layout() {
            window.layoutIfNeeded()
            UF03NativeOperationTrace.measure(.layout) { controller.view.layoutSubtreeIfNeeded() }
            controller.view.display()
        }

        mutating func takeSample(_ attempt: Int) {
            samples = attempt
            row = UF03Snapshot(in: window, identifier: rowIdentifier)
            policy = UF03Snapshot(in: window, identifier: policyIdentifier)
            model = UF03Snapshot(in: window, identifier: modelIdentifier)
        }

        var ready: Bool {
            row.found && policy.found && model.found
                && row.frame?.isEmpty == false && policy.frame?.isEmpty == false
                && model.frame?.isEmpty == false
                && UF03OwnedHostFocusAdmission.isReady(window: window, host: controller.view,
                    ownerIdentifier: ownerIdentifier)
        }

        func finish(onSampled: (NSWindow) -> Void)
            -> (window: NSWindow, controller: NSHostingController<AnyView>, probe: HostedProbe) {
            onSampled(window)
            // Read-only diagnostic before any policy transaction. The description
            // never supplies an AX object or changes run-loop modes or eligibility.
            // Bound output per original host; an absent/truncated description is
            // unknown, never evidence that a native source is registered.
            let runLoopConfiguration = String(describing: CFCopyDescription(CFRunLoopGetMain()))
            print("UF03_ORIGINAL_RUNLOOP_CONFIGURATION \(String(runLoopConfiguration.prefix(2048)))")
            let hostFrame = window.convertToScreen(controller.view.convert(controller.view.bounds, to: nil))
            let diagnostics = "requestedWidth=\(width) contentFrame=\(String(describing: window.contentView?.frame)) hostFrame=\(hostFrame) visible=\(window.isVisible) key=\(window.isKeyWindow) active=\(NSApplication.shared.isActive) samples=\(samples) row=\(row) policy=\(policy) model=\(model) exposureOrder=local-before>bounded-own-AX>local-after localBefore={\(localBefore)} publicExposure={\(publicExposure)} localAfter={\(localAfter)}"
            UF03NativeOperationTrace.measure(.printExposure) { print("UF03_NATIVE_OWNED_EXPOSURE owner=\(ownerIdentifier) localBefore={\(localBefore)} publicExposure={\(publicExposure)} localAfter={\(localAfter)}") }
            let result = HostedProbe(row: row.frame, policy: policy.frame, model: model.frame, diagnostics: diagnostics, samples: samples, rowAX: row, policyAX: policy, modelAX: model, hostFrame: hostFrame,
                nativeHostReady: UF03OwnedHostFocusAdmission.isReady(window: window, host: controller.view,
                    ownerIdentifier: ownerIdentifier))
            if !result.isUsable {
                print("UF03_NATIVE_PROBE \(diagnostics)")
                // Observe the same production host after the original sampling has
                // finished. These reads never supply substitute nodes or frames to
                // HostedProbe and cannot turn a missing production identifier green.
                let host = controller.view
                let selector = NSSelectorFromString("accessibilityChildren")
                let responds = host.responds(to: selector)
                let rawChildren = UF03Getter(host, "accessibilityChildren") as? NSArray
                let directChildren = host.accessibilityChildren()
                func describe(_ values: [Any]) -> String {
                    let sample = values.prefix(12).map { value in
                        let object = value as AnyObject
                        let identifier = (UF03Getter(object, "accessibilityIdentifier") as? String)
                            ?? (object as? NSAccessibilityProtocol)?.accessibilityIdentifier()
                        return "type=\(String(reflecting: type(of: value))) identifier=\(String(describing: identifier))"
                    }
                    return "count=\(values.count) sample=\(sample)"
                }
                let rawDescription = rawChildren.map { describe($0.map { $0 }) } ?? "nil"
                let directDescription = directChildren.map(describe) ?? "nil"
                print("UF03_NATIVE_AX_READ_PATHS hostType=\(String(reflecting: type(of: host))) responds=\(responds) dynamicGetter={\(rawDescription)} publicDirect={\(directDescription)}")
            }
            return (window, controller, result)
        }
    }

    @MainActor
    private static func makeHostedProbePreparation(
        _ root: AnyView, width: CGFloat, rowIdentifier: String,
        policyIdentifier: String, modelIdentifier: String, onCreated: (NSWindow) -> Void
    ) -> HostedProbePreparation {
        let controller = NSHostingController(rootView: root)
        // The test supplies the window size; preserve the consumer's own layout cap.
        controller.sizingOptions = []
        let window = OwnedIdentifierWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        onCreated(window)
        // The lifecycle lease tracks the NSWindow object, not its public AX ID.
        // Preserve the companion transaction's existing ID when it supplies one.
        let ownerIdentifier: String
        let existing = window.accessibilityIdentifier()
        if !existing.isEmpty {
            ownerIdentifier = existing
        } else {
            ownerIdentifier = "uf03-owned-probe-" + UUID().uuidString
            window.setAccessibilityIdentifier(ownerIdentifier)
        }
        window.isReleasedWhenClosed = false
        // Fixture hosts must never enqueue -[_NSWindowTransformAnimation]: with
        // continuous main-runloop servicing, a stale transform animation from a
        // closed host deallocs during the next host's CA transaction commit and
        // over-releases its target (signal 11 in ComposerPrimaryControlsNativeTests).
        // Disabling ordered-window animation removes that object class from the
        // process without changing geometry, key/focus, or AX observation.
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(CGSize(width: width, height: 620))
        // A visible ordered window can still belong to a hidden application.
        // Unhide this original host before requesting activation; keep the
        // existing exact-focus sampling and external AX action requirements.
        NSApplication.shared.unhide(nil)
        // This explicit native-host run must activate independently of another
        // app yielding activation; the cooperative request is not sufficient.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        var row = UF03Snapshot(in: window, identifier: rowIdentifier)
        var policy = UF03Snapshot(in: window, identifier: policyIdentifier)
        var model = UF03Snapshot(in: window, identifier: modelIdentifier)
        let localBefore = "row=\(row) policy=\(policy) model=\(model)"
        let publicExposure = exposeOwnedWindow(
            window, controller: controller, ownerIdentifier: ownerIdentifier
        )
        // Public CF values are diagnostic only. The original local reader is
        // the sole source of all three frames, before and after this one read.
        row = UF03Snapshot(in: window, identifier: rowIdentifier)
        policy = UF03Snapshot(in: window, identifier: policyIdentifier)
        model = UF03Snapshot(in: window, identifier: modelIdentifier)
        let localAfter = "row=\(row) policy=\(policy) model=\(model)"
        return HostedProbePreparation(window: window, controller: controller,
            ownerIdentifier: ownerIdentifier, width: width, rowIdentifier: rowIdentifier,
            policyIdentifier: policyIdentifier, modelIdentifier: modelIdentifier,
            row: row, policy: policy, model: model, localBefore: localBefore,
            publicExposure: publicExposure, localAfter: localAfter)
    }

    @MainActor
    private static func exposeOwnedWindow(
        _ window: NSWindow, controller: NSViewController, ownerIdentifier: String
    ) -> String {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 0.2
        var reads = 0
        var windowCount = 0
        var matches = 0
        func finish(_ status: String) -> String {
            "status=\(status) reads=\(reads)/12 windows=\(windowCount)/8 matches=\(matches) elapsed=\(ProcessInfo.processInfo.systemUptime - started) budget=0.2 perRefTimeout=0.01"
        }
        func withinBudget() -> Bool {
            ProcessInfo.processInfo.systemUptime < deadline
        }
        func read(_ operation: () -> AXError) -> AXError? {
            guard withinBudget(), reads < 12 else { return nil }
            reads += 1
            return operation()
        }
        func prepare(_ element: AXUIElement) -> Bool {
            guard withinBudget() else { return false }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == getpid(),
                  AXUIElementSetMessagingTimeout(element, 0.01) == .success else { return false }
            return withinBudget()
        }
        guard !ownerIdentifier.isEmpty,
              window.accessibilityIdentifier() == ownerIdentifier,
              window.contentViewController === controller,
              controller.view.window === window, window.isVisible else {
            return finish("OWNED_HOST_UNCONFIRMED")
        }
        let localWindows = NSApplication.shared.windows
        guard localWindows.count <= 8, withinBudget() else {
            return finish("LOCAL_WINDOWS_OVER_BUDGET")
        }
        var localOwners: [NSWindow] = []
        for localWindow in localWindows {
            guard withinBudget() else { return finish("LOCAL_IDENTIFIERS_OVER_BUDGET") }
            if localWindow.accessibilityIdentifier() == ownerIdentifier { localOwners.append(localWindow) }
        }
        guard localOwners.count == 1, localOwners.first === window else {
            return finish("OWNED_IDENTIFIER_NOT_UNIQUE")
        }
        let application = AXUIElementCreateApplication(getpid())
        guard prepare(application) else { return finish("OWNED_APPLICATION_UNAVAILABLE") }
        let countError = read {
            AXUIElementGetAttributeValueCount(application, kAXWindowsAttribute as CFString, &windowCount)
        }
        guard countError == .success, (1...8).contains(windowCount), withinBudget() else {
            return finish("OWN_WINDOWS_UNAVAILABLE_OR_OVER_BUDGET(error=\(String(describing: countError?.rawValue)))")
        }
        var rawWindows: CFArray?
        let windowsError = read {
            AXUIElementCopyAttributeValues(application, kAXWindowsAttribute as CFString, 0, windowCount, &rawWindows)
        }
        guard windowsError == .success, let windows = rawWindows as? [AXUIElement],
              windows.count == windowCount, withinBudget() else {
            return finish("OWN_WINDOWS_UNREADABLE(error=\(String(describing: windowsError?.rawValue)))")
        }
        var owner: AXUIElement?
        for element in windows {
            guard prepare(element) else { return finish("OWN_WINDOW_REFERENCE_UNCONFIRMED") }
            var value: CFTypeRef?
            let error = read { AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) }
            guard error == .success, let identifier = value as? String, withinBudget() else {
                return finish("OWN_IDENTIFIER_UNREADABLE(error=\(String(describing: error?.rawValue)))")
            }
            if identifier == ownerIdentifier { matches += 1; owner = element }
        }
        guard matches == 1, let owner,
              window.accessibilityIdentifier() == ownerIdentifier,
              window.contentViewController === controller,
              controller.view.window === window else {
            return finish("PUBLIC_OWNER_NOT_UNIQUE_OR_HOST_CHANGED")
        }
        var childCount = 0
        let childrenCountError = read {
            AXUIElementGetAttributeValueCount(owner, kAXChildrenAttribute as CFString, &childCount)
        }
        guard childrenCountError == .success, childCount >= 0, withinBudget() else {
            return finish("OWN_CHILD_COUNT_UNREADABLE(error=\(String(describing: childrenCountError?.rawValue)))")
        }
        if childCount == 0 { return finish("OWN_WINDOW_EXPOSURE_READABLE(children=0)") }
        var children: CFArray?
        let childrenError = read {
            AXUIElementCopyAttributeValues(owner, kAXChildrenAttribute as CFString, 0, 1, &children)
        }
        guard childrenError == .success, let children = children as? [AXUIElement],
              children.count == 1, withinBudget() else {
            return finish("OWN_CHILDREN_UNREADABLE_OR_BUDGET_EXHAUSTED(error=\(String(describing: childrenError?.rawValue)))")
        }
        return finish("OWN_WINDOW_EXPOSURE_READABLE(children=\(childCount), sampled=\(children.count))")
    }
}

@MainActor
enum UF03NativeFrameReader {
    struct Evidence: Codable {
        let protocolCast: Bool
        let objectCast: Bool
        var selectorResponds = false
        var returnEncoding: String?
        var argumentCount: UInt32?
        var encodedSize: Int?
        var path = "missing"
    }

    struct Result {
        let frame: CGRect?
        let evidence: Evidence
    }

    static func read(_ object: AnyObject) -> Result {
        let ax = object as? NSAccessibilityProtocol
        let native = object as? NSObject
        var evidence = Evidence(protocolCast: ax != nil, objectCast: native != nil)
        let selector = NSSelectorFromString("accessibilityFrame")
        evidence.selectorResponds = native?.responds(to: selector) ?? false
        if let frame = ax?.accessibilityFrame(), isValid(frame) {
            evidence.path = "protocol"
            return Result(frame: frame, evidence: evidence)
        }
        guard let native else { return Result(frame: nil, evidence: evidence) }

        if ax == nil && evidence.selectorResponds {
            // SwiftUI proxies can expose the public getter without adopting the
            // full protocol. A CGRect return is not an Objective-C object: never
            // send this selector through perform/takeUnretainedValue.
            guard let method = class_getInstanceMethod(type(of: native), selector) else {
                evidence.path = "rejected-no-concrete-method"
                return Result(frame: nil, evidence: evidence)
            }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            evidence.returnEncoding = String(cString: returnType)
            evidence.argumentCount = method_getNumberOfArguments(method)
            let expectedEncoding = String(cString: NSValue(rect: .zero).objCType)
            guard evidence.argumentCount == 2, evidence.returnEncoding == expectedEncoding else {
                evidence.path = "rejected-signature"
                return Result(frame: nil, evidence: evidence)
            }
            let receiverType = method_copyArgumentType(method, 0)
            let selectorType = method_copyArgumentType(method, 1)
            defer { free(receiverType); free(selectorType) }
            guard let receiverType, let selectorType else {
                evidence.path = "rejected-signature"
                return Result(frame: nil, evidence: evidence)
            }
            var size = 0
            var alignment = 0
            NSGetSizeAndAlignment(returnType, &size, &alignment)
            evidence.encodedSize = size
            guard String(cString: receiverType) == "@",
                  String(cString: selectorType) == ":",
                  size == MemoryLayout<CGRect>.size,
                  alignment == MemoryLayout<CGRect>.alignment else {
                evidence.path = "rejected-signature"
                return Result(frame: nil, evidence: evidence)
            }
            typealias FrameGetter = @convention(c) (AnyObject, Selector) -> CGRect
            let getter = unsafeBitCast(method_getImplementation(method), to: FrameGetter.self)
            let frame = getter(native, selector)
            evidence.path = isValid(frame) ? "typed-selector" : "rejected-invalid-frame"
            return Result(frame: isValid(frame) ? frame : nil, evidence: evidence)
        }

        // Keep the existing legacy API, accepting only its declared value types.
        guard native.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else {
            return Result(frame: nil, evidence: evidence)
        }
        if let position = UF03LegacyAttribute(native, .position) as? NSValue,
           let size = UF03LegacyAttribute(native, .size) as? NSValue,
           String(cString: position.objCType) == String(cString: NSValue(point: .zero).objCType),
           String(cString: size.objCType) == String(cString: NSValue(size: .zero).objCType) {
            let frame = CGRect(origin: position.pointValue, size: size.sizeValue)
            evidence.path = isValid(frame) ? "legacy-position-size" : "rejected-invalid-frame"
            return Result(frame: isValid(frame) ? frame : nil, evidence: evidence)
        }
        return Result(frame: nil, evidence: evidence)
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}

@MainActor
struct UF03AXSnapshot: Codable {
    let found: Bool
    let frame: CGRect?
    let nodeType: String?
    let visitedCount: Int
    let traversalTruncated: Bool
    let sampledIdentifiers: [String]
    let frameRead: UF03NativeFrameReader.Evidence?
}

@MainActor
private func UF03Snapshot(
    in root: AnyObject, identifier: String,
    matching: ((AnyObject, String?) -> Bool)? = nil,
    collect: (([AnyObject]) -> Void)? = nil
) -> UF03AXSnapshot {
    var matchedObjects: [AnyObject] = []
    var queue: [AnyObject] = [root]
    var index = 0
    var visited = Set<ObjectIdentifier>()
    var sampledIdentifiers: [String] = []
    while index < queue.count && visited.count < 2_048 {
        let object = queue[index]
        index += 1
        guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
        let native = object as? NSObject
        let ax = object as? NSAccessibilityProtocol
        let currentID = (UF03Getter(object, "accessibilityIdentifier") as? String)
            ?? (UF03LegacyAttribute(native, .identifier) as? String)
            ?? ax?.accessibilityIdentifier()
        if let currentID, !currentID.isEmpty, sampledIdentifiers.count < 12 {
            sampledIdentifiers.append(currentID)
        }
        if let matching, matching(object, currentID) { matchedObjects.append(object) }
        if matching == nil && currentID == identifier {
            let reading = UF03NativeFrameReader.read(object)
            return UF03AXSnapshot(found: true, frame: reading.frame, nodeType: String(describing: type(of: object)), visitedCount: visited.count, traversalTruncated: false, sampledIdentifiers: sampledIdentifiers, frameRead: reading.evidence)
        }
        // Read untyped NSArray objects before bridging SwiftUI's private proxies.
        var children: [Any] = []
        for selector in ["accessibilityChildrenInNavigationOrder", "accessibilityChildren"] {
            if let array = UF03Getter(object, selector) as? NSArray {
                children.append(contentsOf: array.map { $0 })
            }
        }
        if children.isEmpty, let array = UF03LegacyAttribute(native, .children) as? NSArray {
            children.append(contentsOf: array.map { $0 })
        }
        children.append(contentsOf: NSAccessibility.unignoredChildren(from: children))
        if let view = object as? NSView { children.append(contentsOf: view.subviews) }
        if let window = object as? NSWindow, let content = window.contentView {
            children.append(content.superview ?? content)
            if matching != nil {
                // Additional action inventory includes only public owned child
                // windows/sheets. The original identifier-only probe is unchanged.
                children.append(contentsOf: window.sheets.filter { $0.sheetParent === window })
                children.append(contentsOf: window.childWindows ?? [])
            }
        }
        func append(_ value: Any) {
            if let nested = value as? NSArray {
                for child in nested { append(child) }
            } else {
                queue.append(value as AnyObject)
            }
        }
        for child in children { append(child) }
    }
    collect?(matchedObjects)
    if matchedObjects.count == 1, let object = matchedObjects.first {
        let reading = UF03NativeFrameReader.read(object)
        return UF03AXSnapshot(found: true, frame: reading.frame, nodeType: String(describing: type(of: object)), visitedCount: visited.count, traversalTruncated: index < queue.count, sampledIdentifiers: sampledIdentifiers, frameRead: reading.evidence)
    }
    return UF03AXSnapshot(found: false, frame: nil, nodeType: nil, visitedCount: visited.count, traversalTruncated: index < queue.count, sampledIdentifiers: sampledIdentifiers, frameRead: nil)
}

@MainActor
private func UF03Getter(_ object: AnyObject, _ name: String) -> Any? {
    guard let native = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(name)
    guard native.responds(to: selector), let value = native.perform(selector) else { return nil }
    return value.takeUnretainedValue()
}

/// 测试引擎：记录 interrupt 调用次数；streamReply 产出「部分输出」后挂起
/// 直到流被取消（模拟 Agent 循环 in-flight）。
/// interrupt() 与 ChatStore 同在 MainActor 同步调用 → 计数确定性。
final class InterruptRecordingEngine: ChatAgentEngine, @unchecked Sendable {
    var isAvailable: Bool { true }

    private let finishesImmediately: Bool

    init(finishesImmediately: Bool = false) {
        self.finishesImmediately = finishesImmediately
    }

    private let lock = NSLock()
    private var _interruptCount = 0
    var interruptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _interruptCount
    }

    func interrupt() {
        lock.lock()
        _interruptCount += 1
        lock.unlock()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeInterruptStream()
    }

    private func makeInterruptStream() -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            if self.finishesImmediately {
                continuation.yield(.textDelta("完成输出"))
                continuation.yield(.done(stopReason: .endTurn))
                continuation.finish()
                return
            }

            let task = Task {
                continuation.yield(.textDelta("部分输出"))
                // 挂起直到消费端取消（stopStreaming → Task 取消 → onTermination）
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Explicit fixture-only snapshot forwarding, moved from the existing test adapter.

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID
        )
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeInterruptStream()
    }

    func streamReply(
        provider: any LLMProvider,
        history: [ChatMessageUI],
        systemPrompt: String,
        maxTokens: Int,
        conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        turnRuntimeSnapshot: ChatTurnRuntimeSnapshot
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamReply(
            provider: provider,
            history: history,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            conversationID: conversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            turnID: turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity
        )
    }
}

// Additive V4 evidence uses the same Pair/Fixture/Prepared/HostedProbe as the
// original 92 cases. This is deliberately not a host-lifecycle workaround.
extension ComposerNativeFixtureContract {
    struct CompanionTransactionSpec: Codable, Equatable {
        let kind: String
        let budgetSeconds: Double
        let maxPresses: Int
    }

    struct CompanionCase: Codable, Equatable {
        let id: String
        let group: String
        let width: CGFloat
        let modelID: String
        let fontSize: Int
        let policy: ComposerPolicySelection
        let state: String
        let transactions: [CompanionTransactionSpec]

        var pair: Pair {
            let originalGroup: Group = state == "generating" || state == "bypassGenerating"
                ? .generating : (group == "policies" ? .policies : .widthsAndFonts)
            return Pair(id: id, group: originalGroup, modelID: modelID,
                        fontSize: fontSize, width: width, policy: policy,
                        fixtureKey: "companion-evidence:" + id)
        }
    }

    struct CompanionState: Codable, Equatable {
        let provider: String?
        let modelID: String?
        let tier: String
        var policy: ComposerPolicySelection
        let sessionID: String?
        let draft: String
        let attachmentNames: [String]
        let skillIDs: [String]
        let streaming: Bool
        let interruptCount: Int?
        let offlineEngine: Bool
        let engineIdentity: String?
        let catalogIDs: [String]
        let snapshot: ComposerSubmissionSnapshot?
        let reasoningSummary: BL6ReasoningSummarySnapshot?
        let pastedDraft: PastedTextDraft?
        let editing: Bool
        let messageIDs: [String]
        let messageContents: [String]
        let lastUserMessageID: String?
        let lastUserContent: String?
        let lastUserAttachmentNames: [String]

        @MainActor
        static func capture(_ prepared: Prepared) -> Self {
            let chat = prepared.chat
            return Self(provider: chat.selectedProviderType?.rawValue,
                        modelID: chat.selectedModelID, tier: chat.modelSpeedTier.rawValue,
                        policy: chat.composerPolicySelection,
                        sessionID: chat.activeSessionID?.uuidString, draft: chat.draftText,
                        attachmentNames: chat.pendingAttachments.map(\.fileName),
                        skillIDs: chat.selectedPickerItems.map(\.id),
                        streaming: chat.isActiveSessionStreaming,
                        interruptCount: (chat.agentEngine as? InterruptRecordingEngine)?.interruptCount,
                        offlineEngine: chat.agentEngine is InterruptRecordingEngine,
                        engineIdentity: (chat.agentEngine as? InterruptRecordingEngine).map { String(describing: ObjectIdentifier($0)) },
                        catalogIDs: chat.pickerCatalog.map(\.id),
                        snapshot: chat.lastComposerSubmissionSnapshot,
                        reasoningSummary: prepared.companionReasoningSummary,
                        pastedDraft: chat.activePastedTextDraft, editing: chat.isEditingMessage,
                        messageIDs: chat.messages.map { $0.id.uuidString },
                        messageContents: chat.messages.map(\.content),
                        lastUserMessageID: chat.messages.last(where: { $0.role == .user })?.id.uuidString,
                        lastUserContent: chat.messages.last(where: { $0.role == .user })?.content,
                        lastUserAttachmentNames: chat.messages.last(where: { $0.role == .user })?.attachments.map(\.fileName) ?? [])
        }
    }

    struct CompanionHostEvidence: Codable {
        let phase: String
        let uptime: Double
        let processID: Int32
        let mainThread: Bool
        let applicationType: String
        let isRunning: Bool
        let isActive: Bool
        let isHidden: Bool
        let activationPolicy: Int
        let isFinishedLaunching: Bool
        let delegateType: String?
        let bundleIdentifier: String?
        let bundlePackageType: String?
        let executableURL: String?
        let runLoopMode: String?
        let mainWindowNumber: Int?
        let windowNumber: Int
        let visible: Bool
        let key: Bool
        let main: Bool
        let canBecomeKey: Bool
        let windowFrame: CGRect
        let contentFrame: CGRect?
        let hostingBounds: CGRect?
        let hostingFrame: CGRect?
        let hostFrame: CGRect?
        let hostingWindowMatches: Bool
        let controllerOwnsHostingView: Bool
        let hiddenByAncestor: Bool?
        let alpha: CGFloat?
        let screenVisibleFrame: CGRect?
        let publicChildrenCount: Int?
        let publicChildrenTypes: [String]?
        let dynamicChildrenCount: Int?
        let dynamicChildrenTypes: [String]?

        @MainActor
        static func capture(_ phase: String, window: NSWindow, host: NSView?) -> Self {
            let app = NSApplication.shared
            let direct = host?.accessibilityChildren()
            let dynamic = host.flatMap { UF03Getter($0, "accessibilityChildren") as? NSArray }
            return Self(phase: phase, uptime: ProcessInfo.processInfo.systemUptime,
                        processID: getpid(), mainThread: Thread.isMainThread,
                        applicationType: String(reflecting: type(of: app)),
                        isRunning: app.isRunning, isActive: app.isActive, isHidden: app.isHidden,
                        activationPolicy: app.activationPolicy().rawValue,
                        isFinishedLaunching: NSRunningApplication.current.isFinishedLaunching,
                        delegateType: app.delegate.map { String(reflecting: type(of: $0)) },
                        bundleIdentifier: Bundle.main.bundleIdentifier,
                        bundlePackageType: Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
                        executableURL: Bundle.main.executableURL?.path,
                        runLoopMode: RunLoop.current.currentMode?.rawValue,
                        mainWindowNumber: app.mainWindow?.windowNumber,
                        windowNumber: window.windowNumber, visible: window.isVisible,
                        key: window.isKeyWindow, main: window.isMainWindow,
                        canBecomeKey: window.canBecomeKey, windowFrame: window.frame,
                        contentFrame: window.contentView?.frame,
                        hostingBounds: host?.bounds, hostingFrame: host?.frame,
                        hostFrame: host.map { window.convertToScreen($0.convert($0.bounds, to: nil)) },
                        hostingWindowMatches: host?.window === window,
                        controllerOwnsHostingView: host != nil && window.contentViewController?.view === host,
                        hiddenByAncestor: host?.isHiddenOrHasHiddenAncestor, alpha: host?.alphaValue,
                        screenVisibleFrame: window.screen?.visibleFrame,
                        publicChildrenCount: direct?.count,
                        publicChildrenTypes: direct.map { $0.prefix(12).map { String(reflecting: type(of: $0)) } },
                        dynamicChildrenCount: dynamic?.count,
                        dynamicChildrenTypes: dynamic.map { $0.prefix(12).map { String(reflecting: type(of: $0)) } })
        }
    }

    struct CompanionVisibleTextEvidence: Codable {
        let expectedText: String
        let expectedUTF16Count: Int
        let rangeLocation: Int?
        let rangeLength: Int?
        let decodedCFRange: Bool
        let elementRole: String?
        let rangeAppliesToEditableText: Bool
        let evidenceMeaning: String
        let queryAttempted: Bool
        let observedTextValue: String?
        fileprivate let attribute: NativeAccessibilityPackageFieldJourneyReceipt.AXValueEvidence?
        let status: String

        var isConsistent: Bool {
            guard !expectedText.isEmpty, expectedUTF16Count == expectedText.utf16.count else { return false }
            guard queryAttempted == (attribute != nil), !evidenceMeaning.isEmpty else { return false }
            if let attribute, attribute.name != "AXVisibleCharacterRange" { return false }
            if status == "RED" {
                guard rangeAppliesToEditableText, decodedCFRange, attribute?.axErrorCode == 0,
                      observedTextValue == expectedText, let rangeLocation, let rangeLength else { return false }
                return rangeLocation >= 0 && rangeLength >= 0
                    && rangeLocation <= expectedUTF16Count && rangeLength <= expectedUTF16Count - rangeLocation
                    && (rangeLocation != 0 || rangeLength != expectedUTF16Count)
            }
            // This observer has no rendered-text oracle. A full range alone
            // does not authorize a visual PASS, even on an editable text role.
            return status == "VISUAL_OBSERVATION_UNVERIFIED"
        }

        static func notRead(_ expectedText: String) -> Self {
            Self(expectedText: expectedText, expectedUTF16Count: expectedText.utf16.count,
                rangeLocation: nil, rangeLength: nil, decodedCFRange: false, elementRole: nil,
                rangeAppliesToEditableText: false, evidenceMeaning: "OBSERVATION_GAP_NATIVE_TARGET_NOT_BOUND",
                queryAttempted: false, observedTextValue: nil, attribute: nil,
                status: "VISUAL_OBSERVATION_UNVERIFIED")
        }
    }

    struct CompanionControlEvidence: Codable {
        let slot: String
        let query: String
        let queryKind: String
        let required: Bool
        let shouldExist: Bool
        let matchedCount: Int
        let snapshot: UF03AXSnapshot
        fileprivate let native: NativeAccessibilityPackageFieldJourneyReceipt.Control?
        let nativeMatchedCount: Int
        let nativeFrame: CGRect?
        let visibilityBounds: CGRect?
        let expectedEnabled: Bool?
        let expectedChecked: Bool?
        let nativeChecked: Bool?
        let expectedValue: String?
        let actualIdentifier: String?
        let actualLabel: String?
        let actualTitle: String?
        let actualHelp: String?
        let ownedWindowIdentifier: String
        let visibleText: CompanionVisibleTextEvidence?
        let fullyVisible: Bool
        let visibleTextStatus: String
        let nativeStatus: String
        let nativeReason: String?
        var externalNativeProof: [String: String]? = nil
        let status: String
        let reason: String?
    }

    struct CompanionWindowEvidence: Codable {
        let objectIdentity: String
        let windowNumber: Int
        let runtimeType: String
        let isOpenPanel: Bool
        let visible: Bool
        let key: Bool
        let canBecomeKey: Bool
        let frame: CGRect
        let identifier: String?

        @MainActor
        static func capture(_ window: NSWindow) -> Self {
            Self(objectIdentity: String(describing: ObjectIdentifier(window)), windowNumber: window.windowNumber,
                runtimeType: String(reflecting: type(of: window)), isOpenPanel: window is NSOpenPanel,
                visible: window.isVisible, key: window.isKeyWindow, canBecomeKey: window.canBecomeKey,
                frame: window.frame, identifier: window.accessibilityIdentifier())
        }
    }

    struct CompanionModalSample: Codable {
        let uptime: Double
        let runLoopMode: String?
        let modalObjectIdentity: String?
        let newlyAppearedPanels: [CompanionWindowEvidence]
        let uniquelyOwned: Bool
        let panelFrame: UF03AXSnapshot?
    }

    struct CompanionModalEvidence: Encodable {
        let fixtureWindowIdentity: String
        let fixtureWindowIdentifier: String
        let beforeModalObjectIdentity: String?
        let beforeWindows: [CompanionWindowEvidence]
        let timerMode: String
        var timerInstalled = false
        var timerInvalidated = false
        var samples: [CompanionModalSample] = []
        var panelObjectIdentity: String?
        var cancelInvocationCount = 0
        var cancelReturned = false
        var actionReturned = false
        var afterModalObjectIdentity: String?
        var afterWindows: [CompanionWindowEvidence] = []
        var ownedPanelVisibleAfter: Bool?
        let runModalReturnCode = "NOT_OBSERVED"
        let ownershipMeaning = "UNIQUE_NEW_APPLICATION_MODAL_PANEL_DURING_SOLE_OWNED_ACTION_NO_SHEET_PARENT_CLAIM"
        let fileSelectionPerformed = false
    }

    struct CompanionTransactionEvidence: Encodable {
        let id: String
        let kind: String
        let status: String
        let reason: String?
        let attempted: Bool
        let pressCount: Int
        let maxPresses: Int
        let witnessSamples: Int
        let maxWitnessSamples: Int
        let budgetSeconds: Double
        let durationSeconds: Double
        var startedUptime: Double = 0
        var endedUptime: Double = 0
        let maxAttempts = 1
        var attemptCount = 0
        var nativeInputDeliveryCount = 0
        var nativeInputObjectIdentity: String?
        var nativeInputResponderIdentity: String?
        var nativeInputFrame: CGRect?
        var nativeInputWindowMatches = false
        let before: CompanionState?
        let after: CompanionState?
        var checkpoints: [CompanionState] = []
        var presentationChecks: [CompanionControlEvidence] = []
        var ownedSheetCounts: [Int] = []
        var modal: CompanionModalEvidence?
        let nativeInputValue: String?
        let nativeInputFirstResponder: String?
        var callerIdentityDiagnostics: [String] = []
        let pressResults: [Int32]
        let targetEvidence: [CompanionControlEvidence]
        let witness: String
    }

    struct CompanionObservation: Encodable {
        let expected: CompanionCase
        var primary: Observation?
        var completed: Bool
        var status: String
        var errors: [String]
        var setup: CompanionState?
        var after: CompanionState?
        var controls: [CompanionControlEvidence]
        var transactions: [CompanionTransactionEvidence]
        var host: [CompanionHostEvidence]
        var windowClosed: Bool
        var fixtureResourcesClosed: Bool
        var restorationStatus: String
        let setupCleanupAreNativeEvidence: Bool
        var fixtureOnlyRestorations: [CompanionState] = []
        var restoredSelection: CompanionState?
        var nativeStatus = "NOT_RUN_PREREQUISITE"
        var visualStatus = "UNVERIFIED"
        var nativeErrors: [String] = []
        var visualErrors: [String] = []
        var state2958Diagnostic: State2958DiagnosticRecord?

        var visualRecordsConsistent: Bool {
            guard controls.count == 20 else { return false }
            return controls.allSatisfy { control in
                let requiredText = control.shouldExist
                    && ["bypass_confirmation", "frozen_snapshot", "reasoning_status"].contains(control.slot)
                return requiredText ? control.visibleText?.isConsistent == true : control.visibleText == nil
            } && transactions.flatMap(\.targetEvidence).allSatisfy { $0.visibleText?.isConsistent ?? true }
        }
    }

    struct CompanionEvidenceResult: Encodable {
        let contractSHA256: String
        let expected: [CompanionCase]
        let observations: [CompanionObservation]
        let expectedCount: Int
        let transactionCount: Int
        let completed: Bool
        let status: String
        let errors: [String]
        var nativeStatus = "NOT_RUN_PREREQUISITE"
        var visualStatus = "UNVERIFIED"
        var originWindowNumber: Int?
        var originWindowType: String?
        var originWindowStillVisible: Bool?
        let semanticRevision = "C0_V5_OWNED_MODAL_AND_NATIVE_VISUAL_RESPONSIBILITY"
    }

    @MainActor
    static func companionNotRun(_ reason: String) -> CompanionEvidenceResult {
        let expected = companionCases
        return CompanionEvidenceResult(contractSHA256: companionContractSHA256,
            expected: expected, observations: expected.map { spec in
                CompanionObservation(expected: spec, primary: nil, completed: false,
                    status: "NOT_RUN_PREREQUISITE", errors: [reason], setup: nil, after: nil,
                    controls: [], transactions: spec.transactions.map { transaction in
                        companionTransactionNotRun(spec.id, transaction: transaction, reason: reason)
                    }, host: [], windowClosed: false,
                    fixtureResourcesClosed: false, restorationStatus: "NOT_RUN",
                    setupCleanupAreNativeEvidence: false)
            }, expectedCount: 57, transactionCount: 54, completed: false,
            status: "NOT_RUN_PREREQUISITE", errors: [reason])
    }

    private static func companionTransactionNotRun(_ caseID: String, transaction: CompanionTransactionSpec,
                                                   reason: String) -> CompanionTransactionEvidence {
        CompanionTransactionEvidence(id: caseID + "/" + transaction.kind,
            kind: transaction.kind, status: "NOT_RUN_PREREQUISITE", reason: reason,
            attempted: false, pressCount: 0, maxPresses: transaction.maxPresses,
            witnessSamples: 0, maxWitnessSamples: 5, budgetSeconds: transaction.budgetSeconds,
            durationSeconds: 0, before: nil, after: nil, nativeInputValue: nil,
            nativeInputFirstResponder: nil, pressResults: [], targetEvidence: [], witness: "NOT_PROVEN")
    }

    static let companionContractSHA256 = "7d061d63a25bbe8e74ca43a0148ac4cfac6909ed8dbdbf1a3e24180249dbe563"
    static var companionCases: [CompanionCase] {
        // Exact static source data, not a file or runtime control input.
        let json = #"""
[{"id":"companionEvidence.widths:m0:f12:w220","group":"widths","width":220,"modelID":"deepseek-chat","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f12:w310","group":"widths","width":310,"modelID":"deepseek-chat","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f12:w600","group":"widths","width":600,"modelID":"deepseek-chat","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f13:w220","group":"widths","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f13:w310","group":"widths","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f13:w600","group":"widths","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f16:w220","group":"widths","width":220,"modelID":"deepseek-chat","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f16:w310","group":"widths","width":310,"modelID":"deepseek-chat","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f16:w600","group":"widths","width":600,"modelID":"deepseek-chat","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f20:w220","group":"widths","width":220,"modelID":"deepseek-chat","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f20:w310","group":"widths","width":310,"modelID":"deepseek-chat","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m0:f20:w600","group":"widths","width":600,"modelID":"deepseek-chat","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f12:w220","group":"widths","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f12:w310","group":"widths","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f12:w600","group":"widths","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":12,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f13:w220","group":"widths","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[{"kind":"model_select_commit","budgetSeconds":1.5,"maxPresses":4}]},{"id":"companionEvidence.widths:m1:f13:w310","group":"widths","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[{"kind":"model_select_commit","budgetSeconds":1.5,"maxPresses":4}]},{"id":"companionEvidence.widths:m1:f13:w600","group":"widths","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[{"kind":"model_select_commit","budgetSeconds":1.5,"maxPresses":4}]},{"id":"companionEvidence.widths:m1:f16:w220","group":"widths","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f16:w310","group":"widths","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f16:w600","group":"widths","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":16,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f20:w220","group":"widths","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f20:w310","group":"widths","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.widths:m1:f20:w600","group":"widths","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p0:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"low","mode":"manual"},"state":"idleEmpty","transactions":[{"kind":"mode_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"mode_restore","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_restore","budgetSeconds":0.5,"maxPresses":2}]},{"id":"companionEvidence.policy:p0:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"low","mode":"manual"},"state":"idleEmpty","transactions":[{"kind":"mode_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"mode_restore","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_restore","budgetSeconds":0.5,"maxPresses":2}]},{"id":"companionEvidence.policy:p0:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"low","mode":"manual"},"state":"idleEmpty","transactions":[{"kind":"mode_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"mode_restore","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_forward","budgetSeconds":0.5,"maxPresses":2},{"kind":"effort_restore","budgetSeconds":0.5,"maxPresses":2}]},{"id":"companionEvidence.policy:p1:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p1:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p1:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto-edit"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p2:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"plan"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p2:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"plan"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p2:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"plan"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p3:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p3:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p3:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"standard","mode":"auto"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p4:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p4:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p4:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[]},{"id":"companionEvidence.policy:p5:w220","group":"policies","width":220,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[{"kind":"bypass_check","budgetSeconds":0.5,"maxPresses":1},{"kind":"bypass_uncheck","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.policy:p5:w310","group":"policies","width":310,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[{"kind":"bypass_check","budgetSeconds":0.5,"maxPresses":1},{"kind":"bypass_uncheck","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.policy:p5:w600","group":"policies","width":600,"modelID":"deepseek-chat","fontSize":13,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"bypass-permission"},"state":"idleEmpty","transactions":[{"kind":"bypass_check","budgetSeconds":0.5,"maxPresses":1},{"kind":"bypass_uncheck","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:prepared:w220","group":"states","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"prepared","transactions":[{"kind":"attachment_open_cancel","budgetSeconds":2.0,"maxPresses":2},{"kind":"skill_toggle_roundtrip","budgetSeconds":1.0,"maxPresses":4},{"kind":"skill_chip_remove","budgetSeconds":0.5,"maxPresses":1},{"kind":"input_delivery","budgetSeconds":0.5,"maxPresses":0},{"kind":"send_offline","budgetSeconds":0.5,"maxPresses":1},{"kind":"stop_offline","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:prepared:w310","group":"states","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"prepared","transactions":[{"kind":"attachment_open_cancel","budgetSeconds":2.0,"maxPresses":2},{"kind":"skill_toggle_roundtrip","budgetSeconds":1.0,"maxPresses":4},{"kind":"skill_chip_remove","budgetSeconds":0.5,"maxPresses":1},{"kind":"input_delivery","budgetSeconds":0.5,"maxPresses":0},{"kind":"send_offline","budgetSeconds":0.5,"maxPresses":1},{"kind":"stop_offline","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:prepared:w600","group":"states","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"prepared","transactions":[{"kind":"attachment_open_cancel","budgetSeconds":2.0,"maxPresses":2},{"kind":"skill_toggle_roundtrip","budgetSeconds":1.0,"maxPresses":4},{"kind":"skill_chip_remove","budgetSeconds":0.5,"maxPresses":1},{"kind":"input_delivery","budgetSeconds":0.5,"maxPresses":0},{"kind":"send_offline","budgetSeconds":0.5,"maxPresses":1},{"kind":"stop_offline","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:generating:w220","group":"states","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"generating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:generating:w310","group":"states","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"generating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:generating:w600","group":"states","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"generating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:bypassGenerating:w220","group":"states","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"bypassGenerating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:bypassGenerating:w310","group":"states","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"bypassGenerating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:bypassGenerating:w600","group":"states","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":true,"effort":"high","mode":"bypass-permission"},"state":"bypassGenerating","transactions":[{"kind":"frozen_summary_policy_roundtrip","budgetSeconds":1.0,"maxPresses":4}]},{"id":"companionEvidence.state:pastedDraft:w220","group":"states","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"pastedDraft","transactions":[{"kind":"pasted_preview_cancel","budgetSeconds":1.0,"maxPresses":2},{"kind":"pasted_remove","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:pastedDraft:w310","group":"states","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"pastedDraft","transactions":[{"kind":"pasted_preview_cancel","budgetSeconds":1.0,"maxPresses":2},{"kind":"pasted_remove","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:pastedDraft:w600","group":"states","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"pastedDraft","transactions":[{"kind":"pasted_preview_cancel","budgetSeconds":1.0,"maxPresses":2},{"kind":"pasted_remove","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:editing:w220","group":"states","width":220,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"editing","transactions":[{"kind":"edit_cancel","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:editing:w310","group":"states","width":310,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"editing","transactions":[{"kind":"edit_cancel","budgetSeconds":0.5,"maxPresses":1}]},{"id":"companionEvidence.state:editing:w600","group":"states","width":600,"modelID":"provider-model-with-a-deliberately-long-display-name-for-uf03","fontSize":20,"policy":{"approvalScope":"request","bypassModeConfirmed":false,"effort":"high","mode":"auto-edit"},"state":"editing","transactions":[{"kind":"edit_cancel","budgetSeconds":0.5,"maxPresses":1}]}]
"""#
        return (try? JSONDecoder().decode([CompanionCase].self, from: Data(json.utf8))) ?? []
    }
}

extension ComposerNativeFixtureContract.Prepared {
    var companionReasoningSummary: BL6ReasoningSummarySnapshot? {
        guard let active = chat.activeSessionID, let snapshot = chat.lastComposerSubmissionSnapshot,
              snapshot.sessionID == active.uuidString else { return nil }
        let settings = chat.effectiveSettingsSnapshotSource?()
        func text(_ key: String) -> String {
            if let settings, case let .text(value) = settings.values[key] { return value }
            return "未配置"
        }
        return (settings ?? BL6EffectiveSettingsSnapshot(catalogRevision: "composer-unavailable", values: [:]))
            .reasoningSummarySnapshot(providerID: text("general.default-provider-id"),
                modelID: text("general.default-model-id"), providerSupportsSafeSummary: false,
                capturedForTurnID: "\(snapshot.sessionID):\(snapshot.turnID)")
    }
}

extension ComposerNativeFixtureContract.Fixture {
    @MainActor
    func prepareCompanion(_ spec: ComposerNativeFixtureContract.CompanionCase) async throws -> ComposerNativeFixtureContract.Prepared {
        let prepared = try await prepare(spec.pair)
        let chat = prepared.chat
        switch spec.state {
        case "prepared":
            chat.agentEngine = InterruptRecordingEngine()
            chat.streamingProviderOverride = MockProvider.shared
            guard let sessionID = chat.activeSessionID else {
                throw ComposerNativeFixtureContract.FixtureError.attachmentPreparation("missing_fixture_session")
            }
            let url = directory.appendingPathComponent("uf03-native-fixture.txt")
            try Data("fixture".utf8).write(to: url)
            let attachmentIDs = chat.addAttachments(urls: [url]).map(\.id)
            let skill = PickerCatalogItem(id: "skill:uf03-fixture", kind: .skill,
                name: "UF03 Fixture Skill", detail: "native fixture", content: "fixture")
            chat.pickerCatalogLoader = { [skill] }
            chat.loadPickerCatalog()
            chat.draftText = "UF03 narrow offline proof"
            chat.togglePickerItem(skill)
            try await awaitAttachmentsReady(chat, sessionID: sessionID, attachmentIDs: attachmentIDs)
        case "pastedDraft":
            guard chat.setPastedTextDraft(PastedTextDraft(id: UUID(),
                text: "UF03 isolated pasted evidence\nsecond line\n", source: .pasteboard)) else {
                throw ComposerNativeFixtureContract.FixtureError.defaultsUnavailable
            }
        case "editing":
            let message = ChatMessageUI(role: .user, content: "UF03 isolated edit evidence")
            chat.messages.append(message)
            chat.beginEdit(messageID: message.id)
        default:
            break
        }
        return prepared
    }
}

extension NativeAccessibilityPackageAXProbe {
    @MainActor
    static func companionRootMatches(_ root: AXUIElement, identifier: String, pid: Int32,
                                     diagnostic: State2958DiagnosticRecorder? = nil) -> Bool {
        let id = readAttribute(root, kAXIdentifierAttribute as CFString)
        let role = readAttribute(root, kAXRoleAttribute as CFString)
        var actualPID: pid_t = 0
        let pidError = AXUIElementGetPid(root, &actualPID)
        diagnostic?.recordAX("ax_identifier_error_and_value", error: id.error,
            observed: decodedString(from: id.value) ?? "UNREADABLE")
        diagnostic?.recordAX("ax_role_error_and_value", error: role.error,
            observed: decodedString(from: role.value) ?? "UNREADABLE")
        diagnostic?.recordAX("ax_pid_error_and_value", error: pidError,
            observed: String(actualPID))
        return id.error == .success && decodedString(from: id.value) == identifier
            && role.error == .success && decodedString(from: role.value) == (kAXWindowRole as String)
            && pidError == .success && actualPID == pid
    }

    @MainActor
    static func companionTree(root: AXUIElement?, deadline: Double) -> (nodes: [AXUIElement], complete: Bool) {
        guard let root else { return ([], false) }
        var queue = [root]
        var index = 0
        var visited = Set<CFHashCode>()
        var result: [AXUIElement] = []
        while index < queue.count && visited.count < 2_048 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return (result, false) }
            let node = queue[index]
            index += 1
            guard visited.insert(CFHash(node)).inserted else { continue }
            result.append(node)
            let ordered = decodedElements(from: readAttribute(node, "AXChildrenInNavigationOrder" as CFString).value)
            let ordinary = decodedElements(from: readAttribute(node, kAXChildrenAttribute as CFString).value)
            queue.append(contentsOf: union(ordered, ordinary))
        }
        return (result, index == queue.count)
    }

    @MainActor
    static func companionString(_ node: AXUIElement, kind: String) -> String? {
        let attribute: String
        switch kind {
        case "identifier": attribute = kAXIdentifierAttribute as String
        case "title": attribute = kAXTitleAttribute as String
        case "help": attribute = kAXHelpAttribute as String
        case "role": attribute = kAXRoleAttribute as String
        case "value": attribute = kAXValueAttribute as String
        default: attribute = kAXDescriptionAttribute as String
        }
        return decodedString(from: readAttribute(node, attribute as CFString).value)
    }

    @MainActor
    static func companionChecked(_ node: AXUIElement) -> Bool? {
        let read = readAttribute(node, kAXValueAttribute as CFString)
        guard read.error == .success, let value = read.value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var number = 0.0
        guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .doubleType, &number),
              number == 0 || number == 1 else { return nil }
        return number == 1
    }

    @MainActor
    static func companionFrame(_ node: AXUIElement, zeroScreenFrame: CGRect?) -> CGRect? {
        let positionRead = readAttribute(node, kAXPositionAttribute as CFString)
        guard positionRead.error == .success, let p = positionRead.value else { return nil }
        let sizeRead = readAttribute(node, kAXSizeAttribute as CFString)
        guard sizeRead.error == .success, let s = sizeRead.value,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(p, to: AXValue.self)
        let size = unsafeDowncast(s, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return UF03AXScreenCoordinates.appKitFrame(
            position: point, size: extent, zeroScreenFrame: zeroScreenFrame)
    }

    @MainActor
    static func companionVisibleText(_ node: AXUIElement, expectedText: String) -> ComposerNativeFixtureContract.CompanionVisibleTextEvidence {
        let read = readAttribute(node, kAXVisibleCharacterRangeAttribute as CFString)
        var decoded = false
        var location: Int?
        var length: Int?
        if read.error == .success, let value = read.value, CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(value, to: AXValue.self)
            if AXValueGetType(axValue) == .cfRange {
                var range = CFRange(location: 0, length: 0)
                decoded = AXValueGetValue(axValue, .cfRange, &range)
                if decoded { location = range.location; length = range.length }
            }
        }
        let role = companionString(node, kind: "role")
        // AXVisibleCharacterRange describes scrolling in editable text and is
        // required only for AXTextArea. Its absence on a checkbox/static text
        // is an observation gap, never evidence of a product clipping defect.
        let editableTextRange = role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String)
        let observedText = companionString(node, kind: "value")
        let applicable = editableTextRange && observedText == expectedText && !expectedText.isEmpty
        let partial: Bool
        if applicable, decoded, let location, let length,
           location >= 0, length >= 0, location <= expectedText.utf16.count,
           length <= expectedText.utf16.count - location {
            partial = location != 0 || length != expectedText.utf16.count
        } else { partial = false }
        let status = partial ? "RED" : "VISUAL_OBSERVATION_UNVERIFIED"
        return ComposerNativeFixtureContract.CompanionVisibleTextEvidence(expectedText: expectedText,
            expectedUTF16Count: expectedText.utf16.count, rangeLocation: location,
            rangeLength: length, decodedCFRange: decoded, elementRole: role,
            rangeAppliesToEditableText: editableTextRange,
            evidenceMeaning: partial ? "APPLICABLE_EDITABLE_TEXT_RANGE_INCOMPLETE"
                : "OBSERVATION_GAP_RANGE_DOES_NOT_PROVE_RENDERED_READABILITY",
            queryAttempted: true, observedTextValue: observedText, attribute: read.evidence, status: status)
    }
}

// Preserve the legacy object-return selector fallback for owned native objects.
// Modern typed selectors remain the first route; missing legacy selectors stay nil.
@MainActor
func UF03LegacyAttribute(_ object: NSObject?, _ attribute: NSAccessibility.Attribute) -> Any? {
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard let object, object.responds(to: selector) else { return nil }
    return object.perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
}

/// Exact local companion matching; a valid direct label remains authoritative.
@MainActor
enum UF03CompanionLocalLabelReader {
    static func role(_ object: AnyObject) -> String? {
        if let direct = UF03Getter(object, "accessibilityRole") as? String { return direct }
        guard let legacy = object as? NSObject,
              legacy.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return UF03LegacyAttribute(legacy, .role) as? String
    }

    /// A Composer input identifier can also be inherited by its placeholder.
    /// Resolve the input surface, keeping every real duplicate input in the set.
    static func inputTargets(_ identifierMatches: [AnyObject]) -> [AnyObject] {
        identifierMatches.filter {
            let value = role($0)
            return value == NSAccessibility.Role.textArea.rawValue
                || value == NSAccessibility.Role.scrollArea.rawValue
        }
    }

    static func readState(_ value: Any?, query: String) -> String {
        guard let value else { return "NIL" }
        guard let string = value as? String else { return "NON_STRING" }
        if string.isEmpty { return "EMPTY" }
        return string == query ? "EXACT" : "CONFLICT"
    }

    static func syntheticSample(_ value: Any?, attribute: String) -> String? {
        guard let string = value as? String,
              ["任务模式", "工作量"].contains(string) else { return nil }
        return "\(attribute):\(string)"
    }

    static func matchSource(_ object: AnyObject, query: String, kind: String,
                            onRead: ((String, String, String, [String]) -> Void)? = nil) -> String? {
        var labelState = "NOT_READ", legacyState = "NOT_READ", titleState = "NOT_READ"
        var samples: [String] = []
        defer { onRead?(labelState, legacyState, titleState, samples) }
        let selector: String
        switch kind {
        case "identifier": selector = "accessibilityIdentifier"
        case "help": selector = "accessibilityHelp"
        case "title": selector = "accessibilityTitle"
        default: selector = "accessibilityLabel"
        }
        let directRaw = UF03Getter(object, selector)
        let direct = directRaw as? String
        if onRead != nil {
            if selector == "accessibilityLabel" { labelState = readState(directRaw, query: query) }
            if selector == "accessibilityTitle" { titleState = readState(directRaw, query: query) }
            if let sample = syntheticSample(directRaw, attribute: selector) { samples.append(sample) }
        }
        if direct == query { return selector }
        if selector == "accessibilityLabel", direct == nil {
            let legacy = object as? NSObject
            let legacyRaw = legacy?.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) == true
                ? UF03LegacyAttribute(legacy, .description) : nil
            if onRead != nil {
                legacyState = readState(legacyRaw, query: query)
                if let sample = syntheticSample(legacyRaw, attribute: "AXDescription") { samples.append(sample) }
            }
            if (legacyRaw as? String) == query { return "AXDescription" }
        }
        if kind == "labelOrTitle" {
            let titleRaw = UF03Getter(object, "accessibilityTitle")
            if onRead != nil {
                titleState = readState(titleRaw, query: query)
                if let sample = syntheticSample(titleRaw, attribute: "accessibilityTitle") { samples.append(sample) }
            }
            if (titleRaw as? String) == query { return "accessibilityTitle" }
        }
        return nil
    }
}

extension ComposerNativeFixtureContract {
    @MainActor
    private final class CompanionInventory {
        private static var labelSourceRecords = 0
        private static var labelObservationWindow: String?
        private static var labelSampleCount = 0
        private static var inputIdentityRecorded = false
        let window: NSWindow
        let host: NSView
        let hostFrame: CGRect
        let zeroScreenFrame: CGRect?
        let windowIdentifier: String
        var objects: [AnyObject] = []
        let axNodes: [AXUIElement]
        let traversalComplete: Bool
        let rootBinding: UF03CompanionOwnedRoot<AXUIElement>?

        enum RootSource {
            case initial(UF03CompanionRootLifetime)
            case bound(UF03CompanionRootLifetime, UF03CompanionOwnedRoot<AXUIElement>?)
        }

        init(window: NSWindow, host: NSView, deadline: Double, rootSource: RootSource,
             diagnostic: State2958DiagnosticRecorder? = nil) {
            let trace = UF03NativeOperationTrace.begin(.inventory)
            defer { UF03NativeOperationTrace.end(.inventory, trace) }
            self.window = window
            self.host = host
            self.hostFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
            self.zeroScreenFrame = NSScreen.screens.first?.frame
            let windowIdentifier = window.accessibilityIdentifier()
            self.windowIdentifier = windowIdentifier
            var nodes: [AnyObject] = []
            diagnostic?.begin("local_snapshot")
            let snapshot = UF03Snapshot(in: window, identifier: "", matching: { _, _ in true }, collect: { nodes = $0 })
            diagnostic?.end("local_snapshot")
            objects = nodes
            let lifetime: UF03CompanionRootLifetime
            var initialSearch: NativeAccessibilityPackageFieldJourneyReceipt.SearchEvidence?
            switch rootSource {
            case .initial(let ownerLifetime):
                lifetime = ownerLifetime
                // This is the original initial control inventory lookup. Later
                // inventories cannot rediscover or fall back to another root.
                diagnostic?.begin("initial_search")
                let search = NativeAccessibilityPackageAXProbe.search(
                    identifier: windowIdentifier, phase: "companion-owned-window")
                diagnostic?.end("initial_search")
                initialSearch = search.evidence
                if let root = search.element {
                    rootBinding = UF03CompanionOwnedRoot(root: root, window: window, host: host,
                        lifetime: lifetime, identifier: windowIdentifier, pid: getpid())
                } else { rootBinding = nil }
            case .bound(let ownerLifetime, let binding):
                lifetime = ownerLifetime
                rootBinding = binding
            }
            diagnostic?.begin("root_validation")
            let root = rootBinding?.validatedRoot(window: window, host: host, lifetime: lifetime,
                identifier: windowIdentifier, pid: getpid(), ownsWindow: {
                    let hostWindow = host.window === window
                    let contentViewOwner = window.contentViewController?.view === host
                    let visible = window.isVisible
                    let hostVisibilityAlpha = !host.isHiddenOrHasHiddenAncestor && host.alphaValue > 0
                    let identifierPrefix = windowIdentifier.hasPrefix("uf03-owned-")
                    let matchingWindowCount = NSApplication.shared.windows.filter {
                        $0.accessibilityIdentifier() == windowIdentifier
                    }.count
                    let uniqueWindow = matchingWindowCount == 1
                    diagnostic?.recordBoolean("ownsWindow_host_window", hostWindow,
                        observed: host.window.map {
                            String(describing: ObjectIdentifier($0))
                        } ?? "NIL")
                    diagnostic?.recordBoolean("ownsWindow_content_view_owner", contentViewOwner,
                        observed: (window.contentViewController?.view as NSView?).map {
                            String(describing: ObjectIdentifier($0))
                        } ?? "NIL")
                    diagnostic?.recordBoolean("ownsWindow_visible", visible,
                        observed: String(visible))
                    diagnostic?.recordBoolean("ownsWindow_host_visibility_alpha", hostVisibilityAlpha,
                        observed: "hidden=\(host.isHiddenOrHasHiddenAncestor);alpha=\(host.alphaValue)")
                    diagnostic?.recordBoolean("ownsWindow_identifier_prefix", identifierPrefix,
                        observed: windowIdentifier)
                    diagnostic?.recordBoolean("ownsWindow_unique_window", uniqueWindow,
                        observed: "matchingWindowCount=\(matchingWindowCount)")
                    return hostWindow && contentViewOwner && visible && hostVisibilityAlpha
                        && identifierPrefix && uniqueWindow
                }, validateAX: { root, identifier, pid in
                    NativeAccessibilityPackageAXProbe.companionRootMatches(root, identifier: identifier,
                        pid: pid, diagnostic: diagnostic)
                }, diagnostic: diagnostic)
            diagnostic?.end("root_validation")
            diagnostic?.begin("ax_traversal")
            let external = NativeAccessibilityPackageAXProbe.companionTree(root: root, deadline: deadline)
            diagnostic?.end("ax_traversal")
            axNodes = external.nodes
            traversalComplete = !snapshot.traversalTruncated && external.complete
            // Reuse only results already produced by the original initial lookup.
            // This record neither retries AX nor changes any eligibility decision.
            if let initialSearch,
               ["uf03-owned-companionEvidence.policy:p0:w220",
                "uf03-owned-companionEvidence.policy:p0:w310"].contains(windowIdentifier) {
                let caseOrdinal = windowIdentifier.hasSuffix("w220") ? 24 : 25
                let disposition = !initialSearch.found ? "search_missing"
                    : root == nil ? "validation_rejected"
                    : !external.complete ? "subtree_incomplete" : "tree_ready"
                let evidence: [String: Any] = [
                    "case": caseOrdinal, "pid": getpid(), "phase": disposition,
                    "searchFound": initialSearch.found,
                    "searchVisited": initialSearch.visitedCount,
                    "searchLimit": initialSearch.traversalLimitReached,
                    "searchEdges": initialSearch.unionEdgeCount,
                    "rootIdentifierError": initialSearch.rootIdentifier.map { Int($0.axErrorCode) as Any } ?? NSNull(),
                    "rootNavigationError": initialSearch.rootNavigationChildren.map { Int($0.axErrorCode) as Any } ?? NSNull(),
                    "rootChildrenError": initialSearch.rootChildren.map { Int($0.axErrorCode) as Any } ?? NSNull(),
                    "rootNavigationCount": initialSearch.rootNavigationChildren.map { $0.decodedElementCount as Any } ?? NSNull(),
                    "rootChildrenCount": initialSearch.rootChildren.map { $0.decodedElementCount as Any } ?? NSNull(),
                    "validatedRoot": root != nil, "cfNodes": external.nodes.count,
                    "externalComplete": external.complete,
                    "localComplete": !snapshot.traversalTruncated
                ]
                if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                   data.count <= 768, let line = String(data: data, encoding: .utf8) {
                    print("UF03_COMPANION_INITIAL_ROOT \(line)")
                }
            }
        }


        func resolve(slot: String, query: String, kind: String = "identifier", shouldExist: Bool = true,
                     expectedEnabled: Bool? = nil, expectedChecked: Bool? = nil,
                     expectedValue: String? = nil, fullVisibleText: String? = nil,
                     transient: Bool = false) -> (evidence: CompanionControlEvidence, node: AXUIElement?) {
            let trace = UF03NativeOperationTrace.begin(.resolve)
            defer { UF03NativeOperationTrace.end(.resolve, trace) }
            let policySlot = ["mode", "effort"].contains(slot)
            if policySlot, Self.labelObservationWindow == nil, windowIdentifier.hasPrefix("uf03-owned-") {
                Self.labelObservationWindow = windowIdentifier
            }
            let recordReads = policySlot && Self.labelObservationWindow == windowIdentifier && Self.labelSourceRecords <= 10
            var localLabelStates: [String: Int] = [:], legacyStates: [String: Int] = [:], localTitleStates: [String: Int] = [:]
            var cfNameStates: [String: Int] = [:], cfTitleStates: [String: Int] = [:]
            var examples: [String] = []
            func sample(_ value: String) {
                guard Self.labelSampleCount < 8 else { return }
                Self.labelSampleCount += 1
                examples.append(String(value.prefix(96)))
            }
            let onRead: ((String, String, String, [String]) -> Void)? = recordReads ? { label, legacy, title, values in
                localLabelStates[label, default: 0] += 1
                legacyStates[legacy, default: 0] += 1
                localTitleStates[title, default: 0] += 1
                values.forEach(sample)
            } : nil
            var directLabelMatches = 0, descriptionMatches = 0, titleMatches = 0
            let identifierMatches = objects.filter { object in
                guard let source = UF03CompanionLocalLabelReader.matchSource(object, query: query, kind: kind, onRead: onRead) else { return false }
                switch source {
                case "accessibilityLabel": directLabelMatches += 1
                case "AXDescription": descriptionMatches += 1
                case "accessibilityTitle": titleMatches += 1
                default: break
                }
                return true
            }
            let inputQuery = slot == "input" && kind == "identifier"
                && query == "composer.companion.input" && shouldExist
            let matches = inputQuery
                ? UF03CompanionLocalLabelReader.inputTargets(identifierMatches) : identifierMatches
            let inputRole = inputQuery && matches.count == 1
                ? matches.first.flatMap(UF03CompanionLocalLabelReader.role) : nil
            let empty = UF03AXSnapshot(found: false, frame: nil, nodeType: nil,
                visitedCount: objects.count, traversalTruncated: !traversalComplete,
                sampledIdentifiers: [], frameRead: nil)
            var snapshot = empty
            if matches.count == 1, let object = matches.first {
                // The observed CF rectangle differs from the control's outer
                // rectangle. Bind through its own cell's public AX rectangle,
                // if available; never apply an inferred inset or tolerance.
                var frameObject: AnyObject? = object
                if let button = object as? NSPopUpButton {
                    frameObject = (button.cell as? NSPopUpButtonCell).flatMap { cell in
                        cell.controlView === button ? cell : nil
                    }
                }
                let reading = frameObject.map(UF03NativeFrameReader.read)
                snapshot = UF03AXSnapshot(found: true, frame: reading?.frame,
                    nodeType: frameObject.map { String(reflecting: type(of: $0)) }, visitedCount: objects.count,
                    traversalTruncated: !traversalComplete, sampledIdentifiers: [], frameRead: reading?.evidence)
            }
            var cfPreframeNameMatches = 0
            var cfNamedFrameReads: [[String: Any]] = []
            func frameRecord(_ frame: CGRect?) -> Any {
                guard let frame else { return NSNull() }
                return [[frame.origin.x, frame.origin.y], [frame.width, frame.height]]
            }
            let cfMatches: [(node: AXUIElement, frame: CGRect)] = axNodes.compactMap { node in
                let name = NativeAccessibilityPackageAXProbe.companionString(node, kind: kind)
                var titleState = "NOT_READ"
                let sameName: Bool
                if name == query {
                    sameName = true
                } else if kind == "labelOrTitle" {
                    let title = NativeAccessibilityPackageAXProbe.companionString(node, kind: "title")
                    sameName = title == query
                    if recordReads {
                        titleState = title.map { UF03CompanionLocalLabelReader.readState($0, query: query) } ?? "NO_DECODED_STRING"
                        if let value = UF03CompanionLocalLabelReader.syntheticSample(title, attribute: "CF.AXTitle") { sample(value) }
                    }
                } else {
                    sameName = false
                }
                if recordReads {
                    let nameState = name.map { UF03CompanionLocalLabelReader.readState($0, query: query) } ?? "NO_DECODED_STRING"
                    cfNameStates[nameState, default: 0] += 1
                    cfTitleStates[titleState, default: 0] += 1
                    if let value = UF03CompanionLocalLabelReader.syntheticSample(name, attribute: "CF.AXDescription") { sample(value) }
                    if sameName { cfPreframeNameMatches += 1 }
                }
                guard sameName else { return nil }
                if inputQuery {
                    guard let inputRole,
                          NativeAccessibilityPackageAXProbe.companionString(node, kind: "role") == inputRole else { return nil }
                }
                let frame = NativeAccessibilityPackageAXProbe.companionFrame(
                    node, zeroScreenFrame: zeroScreenFrame)
                if recordReads, cfNamedFrameReads.count < 3 {
                    cfNamedFrameReads.append(["localFrame": frameRecord(snapshot.frame),
                        "cfFrame": frameRecord(frame), "cfFrameDecoded": frame != nil,
                        "exactFrameMatch": frame != nil && frame == snapshot.frame])
                }
                guard let frame, frame == snapshot.frame else { return nil }
                return (node, frame)
            }
            if inputQuery, !Self.inputIdentityRecorded {
                Self.inputIdentityRecorded = true
                let candidates: [[String: Any]] = identifierMatches.prefix(4).map { object in
                    ["type": String(reflecting: type(of: object)),
                     "role": UF03CompanionLocalLabelReader.role(object) ?? "UNREADABLE",
                     "frame": frameRecord(UF03NativeFrameReader.read(object).frame)]
                }
                let reads: [String: Any] = ["owner": windowIdentifier,
                    "identifierMatches": identifierMatches.count, "inputMatches": matches.count,
                    "inputRole": inputRole ?? "UNRESOLVED", "candidates": candidates,
                    "localFrame": frameRecord(snapshot.frame), "nativeBoundMatches": cfMatches.count,
                    "traversalComplete": traversalComplete]
                if let data = try? JSONSerialization.data(withJSONObject: reads, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    UF03NativeOperationTrace.measure(.printInput) { print("UF03_COMPANION_INPUT_IDENTITY \(line)") }
                }
            }
            if recordReads {
                Self.labelSourceRecords += 2
                UF03NativeOperationTrace.measure(.printLabel) { print("UF03_COMPANION_LABEL_SOURCE owner=\(String(windowIdentifier.prefix(96))) slot=\(slot) directLabelMatches=\(directLabelMatches) AXDescriptionMatches=\(descriptionMatches) titleMatches=\(titleMatches) localMatches=\(matches.count) localFramePresent=\(snapshot.frame != nil) nativeBoundMatches=\(cfMatches.count) traversalComplete=\(traversalComplete)") }
                let reads: [String: Any] = ["owner": windowIdentifier, "slot": slot,
                    "localNodes": objects.count, "localLabel": localLabelStates, "localDescription": legacyStates,
                    "localTitle": localTitleStates, "cfNodes": axNodes.count, "cfDescriptionString": cfNameStates,
                    "cfTitleString": cfTitleStates, "cfPreframeNameMatches": cfPreframeNameMatches,
                    "cfNamedFrameReads": cfNamedFrameReads,
                    "cfBoundMatches": cfMatches.count, "traversalComplete": traversalComplete, "syntheticExamples": examples]
                if let data = try? JSONSerialization.data(withJSONObject: reads, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) {
                    UF03NativeOperationTrace.measure(.printLabel) { print("UF03_COMPANION_LABEL_READS \(line)") }
                }
            }
            let node = cfMatches.count == 1 ? cfMatches.first?.node : nil
            let nativeFrame = cfMatches.count == 1 ? cfMatches.first?.frame : nil
            let native = node.map { NativeAccessibilityPackageAXProbe.control(
                identifier: NativeAccessibilityPackageAXProbe.companionString($0, kind: "identifier") ?? "",
                element: $0, pressResult: nil) }
            let bounds = transient ? window.screen?.visibleFrame : hostFrame
            let visible = snapshot.frame.map { frame in bounds.map { $0.contains(frame) } ?? false } ?? false
            let textEvidence: CompanionVisibleTextEvidence?
            let textStatus: String
            if shouldExist, let fullVisibleText {
                let text = fullVisibleText.isEmpty ? (native?.value ?? "") : fullVisibleText
                textEvidence = node.map { NativeAccessibilityPackageAXProbe.companionVisibleText($0, expectedText: text) }
                    ?? CompanionVisibleTextEvidence.notRead(text)
                textStatus = textEvidence?.status ?? "VISUAL_OBSERVATION_UNVERIFIED"
            } else {
                textEvidence = nil
                textStatus = "NOT_REQUIRED"
            }
            let checked = node.flatMap(NativeAccessibilityPackageAXProbe.companionChecked)
            let nativeStatus: String
            let nativeReason: String?
            if !shouldExist {
                nativeStatus = matches.isEmpty && traversalComplete ? "PASS" : "RED"
                nativeReason = nativeStatus == "PASS" ? nil : "UNEXPECTED_NODE_OR_INCOMPLETE_TRAVERSAL"
            } else if !UF03AXScreenCoordinates.nativeTargetIsEligible(
                localMatchCount: matches.count, nativeMatchCount: cfMatches.count,
                traversalComplete: !snapshot.traversalTruncated, hasNativeRole: native?.role != nil
            ) {
                nativeStatus = "UNVERIFIED"
                nativeReason = "MISSING_AMBIGUOUS_OR_UNBOUND_NATIVE_TARGET"
            } else if !visible || (expectedEnabled != nil && native?.enabled != expectedEnabled)
                || (expectedChecked != nil && checked != expectedChecked)
                || (expectedValue != nil && native?.value != expectedValue) {
                nativeStatus = "RED"
                nativeReason = "CONTROL_GEOMETRY_ENABLED_OR_VALUE_MISMATCH"
            } else if textStatus == "RED" {
                nativeStatus = "RED"
                nativeReason = "APPLICABLE_VISUAL_RED"
            } else {
                nativeStatus = "PASS"
                nativeReason = nil
            }
            let status = nativeStatus == "PASS" && textStatus == "VISUAL_OBSERVATION_UNVERIFIED"
                ? "UNVERIFIED" : nativeStatus
            let reason = nativeReason ?? (status == "UNVERIFIED" ? "VISUAL_OBSERVATION_UNVERIFIED:OBSERVATION_GAP"
                : (shouldExist ? nil : "EXPECTED_ABSENT"))
            return (CompanionControlEvidence(slot: slot, query: query, queryKind: kind,
                required: shouldExist, shouldExist: shouldExist, matchedCount: matches.count,
                snapshot: snapshot, native: native, nativeMatchedCount: cfMatches.count,
                nativeFrame: nativeFrame,
                visibilityBounds: bounds, expectedEnabled: expectedEnabled, expectedChecked: expectedChecked,
                nativeChecked: checked, expectedValue: expectedValue,
                actualIdentifier: node.flatMap { NativeAccessibilityPackageAXProbe.companionString($0, kind: "identifier") },
                actualLabel: node.flatMap { NativeAccessibilityPackageAXProbe.companionString($0, kind: "label") },
                actualTitle: node.flatMap { NativeAccessibilityPackageAXProbe.companionString($0, kind: "title") },
                actualHelp: node.flatMap { NativeAccessibilityPackageAXProbe.companionString($0, kind: "help") },
                ownedWindowIdentifier: windowIdentifier, visibleText: textEvidence,
                fullyVisible: visible, visibleTextStatus: textStatus, nativeStatus: nativeStatus,
                nativeReason: nativeReason, status: status, reason: reason), node)
        }

        func controls(_ prepared: Prepared) -> [CompanionControlEvidence] {
            let chat = prepared.chat
            var result: [CompanionControlEvidence] = []
            func add(_ slot: String, _ query: String, kind: String = "identifier",
                     present: Bool = true, enabled: Bool? = nil, checked: Bool? = nil,
                     value: String? = nil, text: String? = nil) {
                result.append(resolve(slot: slot, query: query, kind: kind,
                    shouldExist: present, expectedEnabled: enabled, expectedChecked: checked,
                    expectedValue: value, fullVisibleText: text).evidence)
            }
            add("primary_row", "composer.primary-row.companion")
            add("policy_group", "composer.policy.companion")
            add("model", "composer.model.companion", enabled: true,
                value: "\(chat.providerLabel)，模型 ID：\(chat.selectedModelID ?? "未选择")")
            add("mode", "任务模式", kind: "labelOrTitle", enabled: true)
            add("effort", "工作量", kind: "labelOrTitle", enabled: true)
            add("bypass_confirmation", "确认绕过权限模式仍受硬安全边界约束", kind: "labelOrTitle",
                present: chat.composerPolicySelection.mode == .bypassPermission, enabled: true,
                checked: chat.composerPolicySelection.bypassModeConfirmed, text: "已知晓安全边界")
            let snapshot = chat.lastComposerSubmissionSnapshot
            add("frozen_snapshot", "composer.snapshot", present: snapshot != nil,
                value: snapshot.map(ComposerPolicyPresentation.snapshotSummary), text: snapshot.map(ComposerPolicyPresentation.snapshotSummary))
            let reasoning = prepared.companionReasoningSummary
            add("reasoning_status", "composer.reasoning-summary", present: reasoning != nil,
                value: reasoning?.statusText, text: reasoning.map { $0.displayText ?? $0.statusText })
            add("attachment_entry", "添加附件", kind: "labelOrTitle", enabled: true)
            add("skill_entry", "选择插件或技能", kind: "labelOrTitle", enabled: true)
            add("input", "composer.companion.input")
            add("send", "composer.send", present: !chat.isActiveSessionStreaming,
                enabled: !chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !chat.pendingAttachments.isEmpty || chat.activePastedTextDraft != nil)
            add("stop", "停止生成", kind: "labelOrTitle", present: chat.isActiveSessionStreaming, enabled: true)
            add("attachment_chip", "uf03-native-fixture.txt", kind: "labelOrTitle", present: !chat.pendingAttachments.isEmpty)
            add("skill_chip", "UF03 Fixture Skill", kind: "labelOrTitle", present: !chat.selectedPickerItems.isEmpty)
            add("skill_remove", "移除 UF03 Fixture Skill", kind: "help", present: !chat.selectedPickerItems.isEmpty, enabled: true)
            add("pasted_capsule", "composer.pasted-text.capsule", present: chat.activePastedTextDraft != nil)
            add("pasted_preview", "composer.pasted-text.preview", present: chat.activePastedTextDraft != nil, enabled: true)
            add("pasted_remove", "composer.pasted-text.remove", present: chat.activePastedTextDraft != nil, enabled: true)
            add("edit_cancel", "取消编辑", kind: "help", present: chat.isEditingMessage, enabled: true)
            return result
        }
    }
}

extension ComposerNativeFixtureContract {
    @MainActor
    private final class ModeTrackingObservation: NSObject {
        private weak var menu: NSMenu?
        private let menuIdentity: String
        private let ownerIdentity: String
        private let generation: Int
        private let kind: String
        private let deadline: Double
        private let isCurrentGeneration: () -> Bool
        private let ownsTarget: () -> Bool
        private var events: [[String: Any]] = []
        private var capped = false

        init(menu: NSMenu, owner: AnyObject, generation: Int, kind: String,
             deadline: Double, isCurrentGeneration: @escaping () -> Bool,
             ownsTarget: @escaping () -> Bool) {
            self.menu = menu
            self.menuIdentity = String(describing: ObjectIdentifier(menu))
            self.ownerIdentity = String(describing: ObjectIdentifier(owner))
            self.generation = generation; self.kind = kind; self.deadline = deadline
            self.isCurrentGeneration = isCurrentGeneration; self.ownsTarget = ownsTarget
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(began(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)),
                name: NSMenu.didEndTrackingNotification, object: nil)
        }

        @objc private func began(_ notification: Notification) {
            guard let notified = notification.object as? NSMenu else { return }
            UF03NativeOperationTrace.measure(notified === menu ? .menuBeginExact : .menuBeginForeign) {}
            mark(notified === menu ? "begin" : "begin_foreign", notified: notified)
        }
        @objc private func ended(_ notification: Notification) {
            guard let notified = notification.object as? NSMenu else { return }
            UF03NativeOperationTrace.measure(notified === menu ? .menuEndExact : .menuEndForeign) {}
            mark(notified === menu ? "end" : "end_foreign", notified: notified)
        }
        func mark(_ phase: String, turn: UF03OwnedMenuActionTurn? = nil, notified: NSMenu? = nil) {
            guard events.count < 8 else {
                capped = true
                NotificationCenter.default.removeObserver(self)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            events.append(["phase": phase, "uptime_ns": UInt64(now * 1_000_000_000),
                "main": Thread.isMainThread, "current": isCurrentGeneration(),
                "owned": ownsTarget(), "withinDeadline": now < deadline,
                "mode": String((RunLoop.current.currentMode?.rawValue ?? "NONE").prefix(64)),
                "actionCount": turn.map { $0.actionCount as Any } ?? NSNull(),
                "turnStatus": turn.map { $0.status.rawValue as Any } ?? NSNull()])
            if let notified {
                events[events.count - 1]["notifiedMenuIdentity"] = String(describing: ObjectIdentifier(notified))
                events[events.count - 1]["exactMenu"] = notified === menu
            }
        }
        func finish() {
            NotificationCenter.default.removeObserver(self)
            let value: [String: Any] = ["schema": "UF03_MODE_TRACKING_V1", "pid": getpid(),
                "case": 24, "kind": kind, "menuIdentity": menuIdentity,
                "ownerIdentity": ownerIdentity, "generation": generation,
                "deadline_ns": UInt64(deadline * 1_000_000_000), "capped": capped,
                "events": events]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               data.count <= 2048, let line = String(data: data, encoding: .utf8) {
                print("UF03_MODE_TRACKING_LIFECYCLE \(line)")
            }
        }
    }

    @MainActor
    private final class CompanionTransaction: NSObject {
        let prepared: Prepared
        let spec: CompanionTransactionSpec
        let caseID: String
        let window: NSWindow
        let host: NSView
        let rootLifetime: UF03CompanionRootLifetime
        let axFixture: UF03OriginalExecutorAXChannel.FixtureLifetime?
        let windowRoot: UF03CompanionOwnedRoot<AXUIElement>?
        let started = ProcessInfo.processInfo.systemUptime
        var deadline: Double { started + spec.budgetSeconds }
        var presses: [Int32] = []
        var targets: [CompanionControlEvidence] = []
        var samples = 0
        var attempted = false
        var reason: String?
        var callerIdentityDiagnostics: [String] = []
        func recordCallerIdentity(_ value: String) {
            if callerIdentityDiagnostics.count < 16 { callerIdentityDiagnostics.append(String(value.prefix(192))) }
        }
        var inputValue: String?
        var inputResponder: String?
        var inputObjectIdentity: String?
        var inputResponderIdentity: String?
        var inputFrame: CGRect?
        var inputWindowMatches = false
        var checkpoints: [CompanionState] = []
        var presentationChecks: [CompanionControlEvidence] = []
        var ownedSheetCounts: [Int] = []
        var modalEvidence: CompanionModalEvidence?
        var modalBeforeObjects = Set<ObjectIdentifier>()
        var ownedPanel: NSOpenPanel?
        private var menuActionGeneration = 0
        private var inFlightPresses = 0
        private var originalReadLoopObserver: CFRunLoopObserver?
        private var originalReadLoopSamples = 0
        private var originalReadLoopFirstNS: UInt64 = 0
        private var originalReadLoopLastNS: UInt64 = 0
        private var originalReadLoopMaxGapNS: UInt64 = 0
        private var originalReadLoopMaxGapStartNS: UInt64 = 0
        private var originalReadLoopReported = false
        private var originalMainQueueProbeActive = false
        private var originalMainQueueProbeEnqueuedNS: UInt64 = 0
        private var originalMainQueueProbeFiredNS: UInt64 = 0

        private func recordOriginalReadLoopSummary() {
            guard !originalReadLoopReported,
                  originalReadLoopSamples > 0 || originalReadLoopObserver != nil else { return }
            originalReadLoopReported = true
            recordCallerIdentity("mainQueue probe enqueued=\(originalMainQueueProbeEnqueuedNS) fired=\(originalMainQueueProbeFiredNS) active=\(originalMainQueueProbeActive)")
            let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            recordCallerIdentity("readLoop aggregate n=\(originalReadLoopSamples) first=\(originalReadLoopFirstNS) last=\(originalReadLoopLastNS) at=\(now)")
            recordCallerIdentity("readLoop maxGapStart=\(originalReadLoopMaxGapStartNS) gap=\(originalReadLoopMaxGapNS) tail=\(originalReadLoopLastNS == 0 ? 0 : now - originalReadLoopLastNS) capped=\(originalReadLoopSamples >= 4096)")
        }

        private func stopOriginalReadLoopObservation() {
            originalMainQueueProbeActive = false
            if let observer = originalReadLoopObserver { CFRunLoopObserverInvalidate(observer) }
            originalReadLoopObserver = nil
        }

        private func observeOriginalReadLoop() {
            guard caseID == "companionEvidence.policy:p0:w220", spec.kind == "mode_forward",
                  originalReadLoopObserver == nil, originalReadLoopSamples == 0 else { return }
            // One passive marker tests main-queue servicing separately from
            // CF run-loop progress. It never starts an action or supplies proof.
            // Weak capture and original cleanup reject a delayed callback.
            originalMainQueueProbeActive = true
            originalMainQueueProbeEnqueuedNS = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.originalMainQueueProbeActive else { return }
                self.originalMainQueueProbeFiredNS = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            }
            // Passive bounded timing: no AX reads, actions, retries, or admission changes.
            let activities = CFRunLoopActivity.beforeSources.rawValue
                | CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                activities, true, CFIndex.max) { [weak self] _, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                    if self.originalReadLoopSamples == 0 { self.originalReadLoopFirstNS = now }
                    if self.originalReadLoopLastNS > 0 {
                        let gap = now - self.originalReadLoopLastNS
                        if gap > self.originalReadLoopMaxGapNS {
                            self.originalReadLoopMaxGapNS = gap
                            self.originalReadLoopMaxGapStartNS = self.originalReadLoopLastNS
                        }
                    }
                    self.originalReadLoopLastNS = now
                    self.originalReadLoopSamples += 1
                    if self.originalReadLoopSamples >= 4096 { self.stopOriginalReadLoopObservation() }
                }
            }
            originalReadLoopObserver = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer,
                CFRunLoopMode(rawValue: UF03OwnedMenuActionTurn.trackingMode as CFString))
        }

        init(prepared: Prepared, spec: CompanionTransactionSpec, caseID: String, window: NSWindow, host: NSView,
             rootLifetime: UF03CompanionRootLifetime, windowRoot: UF03CompanionOwnedRoot<AXUIElement>?,
             axFixture: UF03OriginalExecutorAXChannel.FixtureLifetime? = nil) {
            self.prepared = prepared; self.spec = spec; self.caseID = caseID
            self.window = window; self.host = host
            self.rootLifetime = rootLifetime; self.windowRoot = windowRoot; self.axFixture = axFixture
            super.init()
        }

        func inventory() -> CompanionInventory {
            CompanionInventory(window: window, host: host, deadline: deadline,
                rootSource: .bound(rootLifetime, windowRoot), diagnostic: nil)
        }

        func press(_ query: String, kind: String = "identifier", transient: Bool = false,
                   drainDefaultMode: Bool = true) -> Bool {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  presses.count + inFlightPresses < spec.maxPresses, host.window === window, window.isVisible else {
                reason = "ACTION_BUDGET_OR_OWNED_WINDOW_PRECONDITION"; return false
            }
            let resolved = inventory().resolve(slot: "transaction_target", query: query, kind: kind,
                expectedEnabled: true, transient: transient)
            targets.append(resolved.evidence)
            guard let node = resolved.node, resolved.evidence.nativeStatus == "PASS",
                  ProcessInfo.processInfo.systemUptime < deadline else {
                reason = "NATIVE_TARGET_NOT_UNIQUE_VISIBLE_ENABLED_OR_OWNED"; return false
            }
            attempted = true
            inFlightPresses += 1
            let result = NativeAccessibilityPackageAXProbe.press(node)
            inFlightPresses -= 1
            presses.append(result.error.rawValue)
            guard result.succeeded else { reason = "NATIVE_PRESS_REJECTED"; return false }
            if drainDefaultMode {
                _ = UF03NativeOperationTrace.measure(.runLoop) { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
            }
            return true
        }


        @MainActor
        func startTrackingAXPress(
            _ query: String, menuLabel: String, generation: Int, channel: UF03OriginalExecutorAXChannel,
            producerButton: ComposerPolicyIdentityButton? = nil,
            completion: @escaping @MainActor (Bool) -> Void
        ) -> Bool {
            if channel.requiresProducerIdentity {
                return startProducerTrackingAXPress(query, menuLabel: menuLabel,
                    generation: generation, channel: channel, button: producerButton, completion: completion)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  presses.count + inFlightPresses < spec.maxPresses,
                  host.window === window, window.isVisible else {
                reason = "ACTION_BUDGET_OR_OWNED_WINDOW_PRECONDITION"; return false
            }
            let resolved = inventory().resolve(slot: "transaction_target", query: query,
                kind: "labelOrTitle", expectedEnabled: true, transient: true)
            targets.append(resolved.evidence)
            guard let node = resolved.node, resolved.evidence.nativeStatus == "PASS",
                  ProcessInfo.processInfo.systemUptime < deadline else {
                reason = "NATIVE_TARGET_NOT_UNIQUE_VISIBLE_ENABLED_OR_OWNED"; return false
            }
            attempted = true
            inFlightPresses += 1
            let producerButtons = channel.requiresProducerIdentity ? inventory().objects.compactMap { $0 as? ComposerPolicyIdentityButton }.filter {
                UF03CompanionLocalLabelReader.matchSource($0, query: menuLabel, kind: "labelOrTitle") != nil
            } : []
            let producerIdentity: [String: Any]?
            if channel.requiresProducerIdentity {
                func rejectProducer(_ value: String) -> Bool {
                    recordCallerIdentity(value); reason = value
                    inFlightPresses = max(0, inFlightPresses - 1); return false
                }
                guard producerButtons.count == 1, let button = producerButtons.first else {
                    return rejectProducer("PRODUCER_BUTTON_NOT_UNIQUE_COUNT_" + String(producerButtons.count))
                }
                guard let menu = button.menu else { return rejectProducer("PRODUCER_MENU_MISSING") }
                if let failure = UF03OwnedPolicyMenuOwnership.failure(host: host, window: window, button: button, menu: menu, caseID: caseID) {
                    return rejectProducer("PRODUCER_OWNER_REJECTED:" + String(failure.prefix(128)))
                }
                guard let identity = button.identityRequest(menu: menu, query: query) else {
                    return rejectProducer(button.identityFailure ?? "PRODUCER_IDENTITY_UNAVAILABLE")
                }
                producerIdentity = identity
            } else { producerIdentity = nil }
            guard let axFixture, channel.ownsFixture(axFixture) else {
                inFlightPresses = max(0, inFlightPresses - 1)
                recordCallerIdentity("CHANNEL_FIXTURE_LIFETIME_REFUSED")
                reason = "ORIGINAL_EXECUTOR_FIXTURE_LIFETIME_REFUSED"; return false
            }
            let started = channel.start(element: node, lifetime: axFixture, query: query, menu: menuLabel,
                caseID: caseID, kind: spec.kind, owner: "uf03-owned-" + caseID,
                generation: generation, ordinal: presses.count + inFlightPresses,
                deadline: deadline, producerIdentity: producerIdentity) { [weak self] result in
                guard let self else { return }
                self.inFlightPresses = max(0, self.inFlightPresses - 1)
                if result.dispatched { self.presses.append(result.error.rawValue) }
                let producerStillCurrent: Bool
                if channel.requiresProducerIdentity, let button = producerButtons.first,
                   let menu = button.menu, let producerIdentity,
                   let current = button.identityRequest(menu: menu, query: query) {
                    producerStillCurrent = NSDictionary(dictionary: producerIdentity).isEqual(to: current)
                } else { producerStillCurrent = !channel.requiresProducerIdentity }
                let accepted = producerStillCurrent && result.dispatched && result.error == .success && !result.late
                    && ProcessInfo.processInfo.systemUptime < self.deadline
                if !producerStillCurrent {
                    self.recordCallerIdentity("PRODUCER_IDENTITY_STALE_AT_COMPLETION")
                }
                if !accepted { self.reason = "NATIVE_PRESS_REJECTED_OR_LATE" }
                completion(accepted)
            }
            guard started else {
                inFlightPresses = max(0, inFlightPresses - 1)
                let failure = channel.lastStartFailure ?? "CHANNEL_ADMISSION_UNAVAILABLE"
                recordCallerIdentity(failure)
                reason = "ORIGINAL_EXECUTOR_AX_ADMISSION_REJECTED:" + failure
                return false
            }
            return true
        }

        // Never perform same-process CF AX inventory/frame reads inside native tracking.
        // Local producer geometry is a request constraint, not native evidence.
        @MainActor
        private func startProducerTrackingAXPress(
            _ query: String, menuLabel: String, generation: Int, channel: UF03OriginalExecutorAXChannel,
            button: ComposerPolicyIdentityButton?, completion: @escaping @MainActor (Bool) -> Void
        ) -> Bool {
            // Keep the original all-or-nothing admission semantics, but expose
            // the first failed predicate so a real run can distinguish budget,
            // owner, identity, and fixture rejection without changing the route.
            func refuse(_ detail: String) -> Bool {
                recordCallerIdentity("PRODUCER_TRACKING_OWNER_OR_BUDGET_REFUSED:" + detail)
                reason = "PRODUCER_TRACKING_OWNER_OR_BUDGET_REFUSED"
                return false
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return refuse("DEADLINE") }
            guard presses.count + inFlightPresses < spec.maxPresses else { return refuse("PRESS_BUDGET") }
            guard host.window === window else { return refuse("HOST_WINDOW") }
            guard window.isVisible else { return refuse("WINDOW_VISIBILITY") }
            guard let button else { return refuse("BUTTON_MISSING") }
            guard let menu = button.menu as? ComposerPolicyChoiceMenu else { return refuse("MENU_MISSING_OR_WRONG_TYPE") }
            // The real AXPress path begins menu tracking outside the button's
            // private presentingChoice flag. Ownership is already proven by
            // the exact window/menu/cell contract and identityRequest below.
            guard UF03OwnedPolicyMenuOwnership.failure(host: host, window: window, button: button,
                menu: menu, caseID: caseID) == nil else { return refuse("OWNER_CONTRACT") }
            guard let identity = button.identityRequest(menu: menu, query: query) else { return refuse("IDENTITY_REQUEST") }
            guard let targetID = identity["target_id"] as? String, !targetID.isEmpty else { return refuse("TARGET_ID") }
            guard let axFixture, channel.ownsFixture(axFixture) else { return refuse("FIXTURE_LIFETIME") }
            let items = menu.items.filter { $0.title == query && $0.accessibilityIdentifier() == targetID }
            guard items.count == 1, let item = items.first, item.menu === menu, item.isEnabled else {
                reason = "PRODUCER_TRACKING_ITEM_NOT_UNIQUE_ENABLED"; return false
            }
            let localRead = UF03NativeFrameReader.read(item)
            guard let localFrame = localRead.frame, let bounds = window.screen?.visibleFrame,
                  bounds.contains(localFrame),
                  let wireFrame = UF03AXScreenCoordinates.appKitFrame(position: localFrame.origin,
                      size: localFrame.size, zeroScreenFrame: NSScreen.screens.first?.frame) else {
                reason = "PRODUCER_TRACKING_LOCAL_FRAME_UNAVAILABLE"; return false
            }
            recordCallerIdentity("producerFrame query=\(query) appKit=\(localFrame) wire=\(wireFrame)")
            let owner = "uf03-owned-" + caseID
            let snapshot = UF03AXSnapshot(found: true, frame: localFrame, nodeType: "NSMenuItem",
                visitedCount: menu.items.count, traversalTruncated: false,
                sampledIdentifiers: [targetID], frameRead: localRead.evidence)
            attempted = true; inFlightPresses += 1
            observeOriginalReadLoop()
            if originalReadLoopObserver != nil {
                recordCallerIdentity("readLoop request ns=\(UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))")
            }
            let started = channel.start(producerFrame: wireFrame, producerTargetID: targetID,
                lifetime: axFixture, query: query, menu: menuLabel, caseID: caseID, kind: spec.kind,
                owner: owner, generation: generation, ordinal: presses.count + inFlightPresses,
                deadline: deadline, producerIdentity: identity) { [weak self, weak button, weak menu] result in
                guard let self else { return }
                self.recordOriginalReadLoopSummary()
                if self.originalReadLoopSamples > 0 || self.originalReadLoopObserver != nil {
                    self.recordCallerIdentity("readLoop response ns=\(UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)) samples=\(self.originalReadLoopSamples)")
                }
                self.stopOriginalReadLoopObservation()
                self.inFlightPresses = max(0, self.inFlightPresses - 1)
                if result.dispatched { self.presses.append(result.error.rawValue) }
                let current: Bool
                if let button, let menu, button.menu === menu,
                   let after = button.identityRequest(menu: menu, query: query) {
                    current = NSDictionary(dictionary: identity).isEqual(to: after)
                        && self.host.window === self.window && self.window.isVisible
                } else { current = false }
                let accepted = UF03TrackingMenuNativeProof.accepts(result.nativeProof, owner: owner,
                    targetID: targetID, current: current, error: result.error.rawValue,
                    dispatched: result.dispatched, late: result.late,
                    now: ProcessInfo.processInfo.systemUptime, deadline: self.deadline)
                self.targets.append(CompanionControlEvidence(slot: "transaction_target", query: query,
                    queryKind: "labelOrTitle", required: true, shouldExist: true, matchedCount: 1,
                    snapshot: snapshot, native: nil, nativeMatchedCount: accepted ? 1 : 0,
                    nativeFrame: accepted ? localFrame : nil, visibilityBounds: bounds,
                    expectedEnabled: true, expectedChecked: nil, nativeChecked: nil, expectedValue: nil,
                    actualIdentifier: targetID, actualLabel: nil, actualTitle: query, actualHelp: nil,
                    ownedWindowIdentifier: owner, visibleText: nil, fullyVisible: true,
                    visibleTextStatus: "NOT_REQUIRED", nativeStatus: accepted ? "PASS" : "UNVERIFIED",
                    nativeReason: accepted ? nil : "EXTERNAL_NATIVE_PROOF_REFUSED",
                    externalNativeProof: result.nativeProof,
                    status: accepted ? "PASS" : "UNVERIFIED", reason: accepted ? nil : "EXTERNAL_NATIVE_PROOF_REFUSED"))
                if !accepted { self.reason = "PRODUCER_NATIVE_PRESS_REJECTED_OR_LATE" }
                completion(accepted)
            }
            if !started {
                stopOriginalReadLoopObservation()
                inFlightPresses = max(0, inFlightPresses - 1)
                reason = "PRODUCER_CHANNEL_REFUSED:" + (channel.lastStartFailure ?? "UNKNOWN")
            }
            return started
        }

        func observe(_ predicate: (CompanionState) -> Bool) -> Bool {
            while samples < 5 && ProcessInfo.processInfo.systemUptime < deadline {
                samples += 1
                let state = CompanionState.capture(prepared)
                checkpoints.append(state)
                if predicate(state) { return true }
                _ = UF03NativeOperationTrace.measure(.runLoop) { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
            }
            reason = "STATE_WITNESS_MISSING_OR_TRANSACTION_BUDGET"; return false
        }

        func observePolicy(_ predicate: (CompanionState) -> Bool) async -> Bool {
            while samples < 5 && ProcessInfo.processInfo.systemUptime < deadline {
                guard !Task.isCancelled else { reason = "TRANSACTION_CANCELLED"; return false }
                samples += 1
                let state = CompanionState.capture(prepared)
                checkpoints.append(state)
                if predicate(state) { return true }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                do { try await Task.sleep(nanoseconds: UInt64(min(0.01, remaining) * 1_000_000_000)) }
                catch { reason = "TRANSACTION_CANCELLED"; return false }
            }
            reason = "STATE_WITNESS_MISSING_OR_TRANSACTION_BUDGET"; return false
        }

        func onlyPolicyChanged(_ state: CompanionState, from before: CompanionState,
                               expectedPolicy: ComposerPolicySelection) -> Bool {
            var expected = before
            expected.policy = expectedPolicy
            return state == expected
        }

        func choose(_ label: String, _ option: String) async -> Bool {
            guard !rootLifetime.menuOpeningUnresolved else {
                reason = "PREVIOUS_OWNED_MENU_LIFETIME_UNRESOLVED"; return false
            }
            // Local discovery does not consume a second full CF AX inventory.
            // The original press below still resolves a fresh owned native target.
            var localObjects: [AnyObject] = []
            let localSnapshot = UF03Snapshot(in: window, identifier: "", matching: { _, _ in true },
                collect: { localObjects = $0 })
            guard !localSnapshot.traversalTruncated else {
                reason = "OWNED_POLICY_LOCAL_DISCOVERY_INCOMPLETE"; return false
            }
            let buttons = localObjects.compactMap { $0 as? NSPopUpButton }.filter {
                UF03CompanionLocalLabelReader.matchSource($0, query: label, kind: "labelOrTitle") != nil
            }
            guard buttons.count == 1, let button = buttons.first, let menu = button.menu,
                  let cell = button.cell as? NSPopUpButtonCell, cell.controlView === button else {
                reason = "OWNED_POLICY_POPUP_NOT_UNIQUE"; return false
            }
            menuActionGeneration += 1
            let generation = menuActionGeneration
            var ownerPredicateFailure: String?
            let ownsTarget: () -> Bool = { [weak self, weak button, weak menu] in
                ownerPredicateFailure = nil
                guard let self, let button, let menu else {
                    ownerPredicateFailure = "OWNER_OR_TARGET_GONE"; return false
                }
                ownerPredicateFailure = UF03OwnedPolicyMenuOwnership.failure(
                    host: self.host, window: self.window, button: button, menu: menu, caseID: self.caseID)
                return ownerPredicateFailure == nil
            }
            let trackingObservation = caseID == "companionEvidence.policy:p0:w220"
                && ["mode_forward", "mode_restore"].contains(spec.kind)
                ? ModeTrackingObservation(menu: menu, owner: self, generation: generation,
                    kind: spec.kind, deadline: deadline,
                    isCurrentGeneration: { [weak self] in self?.menuActionGeneration == generation },
                    ownsTarget: ownsTarget) : nil
            guard let trackingChannel = UF03OriginalExecutorAXChannel.shared else {
                reason = "ORIGINAL_EXECUTOR_AX_CHANNEL_NOT_AUTHENTICATED"; return false
            }
            let turn = UF03OwnedMenuActionTurn(owner: self, menu: menu, deadline: deadline,
                isCurrentGeneration: { [weak self] in self?.menuActionGeneration == generation },
                ownsTarget: ownsTarget,
                startAction: { [weak self, weak button, trackingChannel] completion in
                    guard let self else { return false }
                    return self.startTrackingAXPress(option, menuLabel: label, generation: generation,
                        channel: trackingChannel, producerButton: button as? ComposerPolicyIdentityButton, completion: completion)
                },
                cleanup: { [weak self, weak button, weak menu] in
                    guard let menu else { return }
                    let captured = (menu as? ComposerPolicyChoiceMenu)?.chosenItem?.title ?? "nil"
                    self?.recordCallerIdentity("nativeCleanup selected=\(button?.indexOfSelectedItem ?? -1) captured=\(captured)")
                    (button as? ComposerPolicyIdentityButton)?.cancelQueuedChoice(for: menu)
                    menu.cancelTracking()
                })
            defer {
                recordOriginalReadLoopSummary()
                stopOriginalReadLoopObservation()
                trackingObservation?.mark("return", turn: turn)
                trackingObservation?.finish()
                if turn.lifetimeClosed { rootLifetime.finishOwnedMenuOpening() }
                turn.invalidate(); menuActionGeneration += 1
                trackingChannel.cancelPending()
            }
            guard turn.arm(), rootLifetime.beginOwnedMenuOpening() else {
                reason = "OWNED_POLICY_ACTION_ARM_REJECTED"; return false
            }
            let actionCompleted = await turn.openAndWait {
                let opened = press(label, kind: "labelOrTitle", drainDefaultMode: false)
                trackingObservation?.mark("after_label", turn: turn)
                return opened
            }
            trackingObservation?.mark("after_lifetime", turn: turn)
            let completed = actionCompleted && turn.lifetimeClosed
                && turn.status == .completed && turn.actionCount == 1
            if !completed {
                trackingObservation?.mark("before_cancel", turn: turn)
                turn.cancelIfIncomplete()
                trackingObservation?.mark("after_cancel", turn: turn)
                reason = "OWNED_POLICY_TRACKING_ACTION_" + turn.status.rawValue + ":" +
                    (ownerPredicateFailure ?? reason ?? "NOT_PROVEN")
            }
            return completed
        }

        func presentation(_ query: String, kind: String = "labelOrTitle", present: Bool) -> Bool {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                reason = "PRESENTATION_WITNESS_BUDGET"; return false
            }
            // 第七版：弹层出现/关闭是异步的，原来按压后约 10ms 只查一次就判失败。
            // 在本事务原有预算内有界轮询，只记录最后一次证据；预算与断言不放宽。
            var evidence = inventory().resolve(slot: "owned_presentation", query: query, kind: kind,
                shouldExist: present, transient: true).evidence
            while !(evidence.nativeStatus == "PASS" && (present || window.sheets.isEmpty))
                    && ProcessInfo.processInfo.systemUptime < deadline {
                _ = UF03NativeOperationTrace.measure(.runLoop) {
                    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
                evidence = inventory().resolve(slot: "owned_presentation", query: query, kind: kind,
                    shouldExist: present, transient: true).evidence
            }
            presentationChecks.append(evidence)
            ownedSheetCounts.append(window.sheets.filter { $0.sheetParent === window }.count)
            guard evidence.nativeStatus == "PASS", present || window.sheets.isEmpty else {
                reason = "OWNED_PRESENTATION_STATE_NOT_PROVEN"; return false
            }
            return true
        }

        @objc private func observeOwnedModal(_ timer: Timer) {
            guard samples < 4, modalEvidence != nil,
                  ProcessInfo.processInfo.systemUptime < deadline, host.window === window else {
                timer.invalidate(); return
            }
            samples += 1
            checkpoints.append(CompanionState.capture(prepared))
            let app = NSApplication.shared
            let newPanels = app.windows.compactMap { $0 as? NSOpenPanel }.filter {
                !modalBeforeObjects.contains(ObjectIdentifier($0))
            }
            let panel = newPanels.count == 1 ? newPanels.first : nil
            let unique = panel.map { app.modalWindow === $0 && $0.isVisible && $0.canBecomeKey } ?? false
            let frame = panel.map { panel -> UF03AXSnapshot in
                let read = UF03NativeFrameReader.read(panel)
                return UF03AXSnapshot(found: true, frame: read.frame,
                    nodeType: String(reflecting: type(of: panel)), visitedCount: 1,
                    traversalTruncated: false, sampledIdentifiers: [], frameRead: read.evidence)
            }
            let sample = CompanionModalSample(uptime: ProcessInfo.processInfo.systemUptime,
                runLoopMode: RunLoop.current.currentMode?.rawValue,
                modalObjectIdentity: app.modalWindow.map { String(describing: ObjectIdentifier($0)) },
                newlyAppearedPanels: newPanels.map { CompanionWindowEvidence.capture($0) },
                uniquelyOwned: unique, panelFrame: frame)
            modalEvidence?.samples.append(sample)
            if let data = try? JSONEncoder().encode(sample), let raw = String(data: data, encoding: .utf8) {
                print("UF03_COMPANION_MODAL_SAMPLE case=\(caseID) " + raw); fflush(stdout)
            }
            if unique, let panel, frame?.frame != nil, modalEvidence?.cancelInvocationCount == 0 {
                ownedPanel = panel
                modalEvidence?.panelObjectIdentity = String(describing: ObjectIdentifier(panel))
                modalEvidence?.cancelInvocationCount = 1
                // This exact object is newly created during the single action,
                // identical to modalWindow, and absent from the pre-action set.
                // No global stopModal/abortModal or unrelated-window cleanup.
                panel.cancel(nil)
                modalEvidence?.cancelReturned = true
                timer.invalidate()
            } else if samples >= 4 {
                reason = "OWNED_MODAL_IDENTITY_OR_FRAME_NOT_ESTABLISHED"
                timer.invalidate()
            } else {
                timer.fireDate = Date(timeIntervalSinceNow: 0.4)
            }
        }

        func attachmentOpenAndCancel(_ before: CompanionState) -> Bool {
            let app = NSApplication.shared
            guard Thread.isMainThread, app.modalWindow == nil, host.window === window, window.isVisible,
                  window.accessibilityIdentifier() == "uf03-owned-" + caseID,
                  !app.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                reason = "OWNED_MODAL_PRECONDITION_NOT_MET"; return false
            }
            modalBeforeObjects = Set(app.windows.map(ObjectIdentifier.init))
            modalEvidence = CompanionModalEvidence(fixtureWindowIdentity: String(describing: ObjectIdentifier(window)),
                fixtureWindowIdentifier: "uf03-owned-" + caseID,
                beforeModalObjectIdentity: app.modalWindow.map { String(describing: ObjectIdentifier($0)) },
                beforeWindows: app.windows.map { CompanionWindowEvidence.capture($0) }, timerMode: RunLoop.Mode.modalPanel.rawValue)
            let timer = Timer(timeInterval: 0.1, target: self,
                selector: #selector(observeOwnedModal(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .modalPanel)
            modalEvidence?.timerInstalled = timer.isValid
            defer { timer.invalidate(); modalEvidence?.timerInvalidated = !timer.isValid }
            guard timer.isValid else { reason = "OWNED_MODAL_OBSERVER_NOT_INSTALLED"; return false }
            print("UF03_COMPANION_MODAL_ARMED case=\(caseID) budget=\(spec.budgetSeconds)"); fflush(stdout)
            let pressed = press("添加附件", kind: "labelOrTitle")
            modalEvidence?.actionReturned = attempted
            let closed = observe { state in
                guard let panel = self.ownedPanel else { return false }
                return state == before && self.modalEvidence?.cancelInvocationCount == 1
                    && self.modalEvidence?.cancelReturned == true
                    && app.modalWindow == nil && !panel.isVisible
            }
            modalEvidence?.afterModalObjectIdentity = app.modalWindow.map { String(describing: ObjectIdentifier($0)) }
            modalEvidence?.afterWindows = app.windows.map { CompanionWindowEvidence.capture($0) }
            modalEvidence?.ownedPanelVisibleAfter = ownedPanel?.isVisible
            if !closed { reason = "OWNED_MODAL_CANCEL_AND_STATE_RESTORATION_NOT_PROVEN" }
            return pressed && closed
        }

        func dismissOwnedPresentation() {
            let trace = UF03NativeOperationTrace.begin(.cleanup)
            defer { UF03NativeOperationTrace.end(.cleanup, trace) }
            // Cleanup only: never counted as the native behavior under test.
            for sheet in window.sheets where sheet.sheetParent === window {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
            }
            let selector = NSSelectorFromString("cancelOperation:")
            let responder = window.firstResponder
            let view = responder as? NSView
            let supported = responder?.responds(to: selector) == true
            let owned = host.window === window && window.contentViewController?.view === host
                && window.accessibilityIdentifier() == "uf03-owned-" + caseID
                && view.map { $0.window === window && ($0 === host || $0.isDescendant(of: host)) } == true
            var status = "NO_TARGET"
            var invocationCount = 0
            var callReturned = false
            if responder != nil {
                if !owned {
                    status = "UNOWNED_TARGET_NOT_INVOKED"
                } else if !supported {
                    status = "UNSUPPORTED_SELECTOR_NOT_INVOKED"
                } else if let view {
                    invocationCount = 1
                    view.cancelOperation(nil)
                    callReturned = true
                    status = "OWNED_SUPPORTED_CALL_RETURNED"
                }
            }
            let evidence: [String: Any] = [
                "caseID": caseID, "kind": spec.kind, "selector": NSStringFromSelector(selector),
                "windowIdentity": String(describing: ObjectIdentifier(window)),
                "targetIdentity": responder.map { String(describing: ObjectIdentifier($0)) } ?? "NONE",
                "targetType": responder.map { String(reflecting: type(of: $0)) } ?? "NONE",
                "owned": owned, "selectorSupported": supported, "status": status,
                "invocationCount": invocationCount, "callReturned": callReturned,
                "nativeBehaviorEvidence": false, "restorationEvidence": false,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                UF03NativeOperationTrace.measure(.printCleanup) { print("UF03_COMPANION_CLEANUP " + json) }
            } else {
                UF03NativeOperationTrace.measure(.printCleanup) { print("UF03_COMPANION_CLEANUP_ENCODING_FAILED case=" + caseID + " kind=" + spec.kind) }
            }
            _ = UF03NativeOperationTrace.measure(.flushCleanup) { fflush(stdout) }
        }

        func run() async -> CompanionTransactionEvidence {
            let before = CompanionState.capture(prepared)
            let chat = prepared.chat
            var success = false
            switch spec.kind {
            case "attachment_open_cancel":
                success = attachmentOpenAndCancel(before)
            case "model_select_commit":
                if let model = chat.modelOptions.first(where: { $0.id == "deepseek-chat" }) {
                    success = press("composer.model.companion")
                        && presentation("选择模型", present: true)
                        && press(ProviderType.deepSeek.displayName, kind: "labelOrTitle", transient: true)
                        // 第七版：模型行的无障碍标签是“显示名，模型 ID”（两者相同时只有显示名），与 ModelPickerPanel 行构造一致，精确匹配完整标签。
                        && press(model.id == model.displayName ? model.displayName : "\(model.displayName)，\(model.id)",
                                 kind: "labelOrTitle", transient: true)
                        // 第七版：现行合同是“点选模型即提交并保留原档位”，不再要求随后点速度档位。
                        && observe { $0.provider == ProviderType.deepSeek.rawValue && $0.modelID == "deepseek-chat"
                            && $0.modelID != before.modelID && $0.tier == before.tier }
                        && presentation("选择模型", present: false)
                    let modelAfter = inventory().resolve(slot: "model_after_commit", query: "composer.model.companion",
                        expectedEnabled: true, expectedValue: "\(chat.providerLabel)，模型 ID：\(chat.selectedModelID ?? "未选择")")
                    targets.append(modelAfter.evidence)
                    success = success && modelAfter.evidence.nativeStatus == "PASS"
                } else { reason = "EXISTING_MODEL_CATALOG_TARGET_MISSING" }
            case "mode_forward", "mode_restore":
                let mode: ComposerTaskMode = spec.kind == "mode_forward" ? .autoEdit : .manual
                var policy = before.policy
                policy.mode = mode
                if before.policy.mode != mode {
                    let selected = await choose("任务模式", ComposerPolicyPresentation.modeLabel(mode))
                    if selected { success = await observePolicy { onlyPolicyChanged($0, from: before, expectedPolicy: policy) } }
                }
            case "effort_forward", "effort_restore":
                let effort: ComposerEffort = spec.kind == "effort_forward" ? .high : .low
                var policy = before.policy
                policy.effort = effort
                if before.policy.effort != effort {
                    let selected = await choose("工作量", ComposerPolicyPresentation.effortLabel(effort))
                    if selected { success = await observePolicy { onlyPolicyChanged($0, from: before, expectedPolicy: policy) } }
                }
            case "bypass_check", "bypass_uncheck":
                let checked = spec.kind == "bypass_check"
                if before.policy.mode == .bypassPermission && before.policy.bypassModeConfirmed != checked {
                    var policy = before.policy
                    policy.bypassModeConfirmed = checked
                    success = press("确认绕过权限模式仍受硬安全边界约束", kind: "labelOrTitle")
                        && observe { onlyPolicyChanged($0, from: before, expectedPolicy: policy) }
                } else { reason = "BYPASS_INITIAL_STATE_PRECONDITION" }
            case "skill_toggle_roundtrip":
                guardFixtureCatalog: do {
                    guard chat.pickerCatalog.map(\.id) == ["skill:uf03-fixture"],
                          before.skillIDs == ["skill:uf03-fixture"] else {
                        reason = "ISOLATED_FIXTURE_CATALOG_NOT_PROVEN"; break guardFixtureCatalog
                    }
                    success = press("选择插件或技能", kind: "labelOrTitle")
                        && presentation("插件与技能", present: true)
                        && press("UF03 Fixture Skill", kind: "labelOrTitle", transient: true)
                        && observe { $0.skillIDs.isEmpty && $0.draft != before.draft }
                        && press("UF03 Fixture Skill", kind: "labelOrTitle", transient: true)
                        && observe { $0.skillIDs == before.skillIDs && $0.draft == before.draft }
                        && press("选择插件或技能", kind: "labelOrTitle")
                        && presentation("插件与技能", present: false)
                }
            case "skill_chip_remove":
                if before.skillIDs == ["skill:uf03-fixture"] {
                    success = press("移除 UF03 Fixture Skill", kind: "help")
                        && observe { $0.skillIDs.isEmpty && $0.draft != before.draft }
                } else { reason = "FIXTURE_SKILL_CHIP_PRECONDITION" }
            case "input_delivery":
                let inv = inventory()
                let input = inv.resolve(slot: "input", query: "composer.companion.input")
                targets.append(input.evidence)
                let views = inv.objects.compactMap { $0 as? NSTextView }.filter { view in
                    guard view.window === window, view.isEditable, !view.isHiddenOrHasHiddenAncestor,
                          let inputFrame = input.evidence.snapshot.frame else { return false }
                    let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                    return !frame.isEmpty && inputFrame.contains(frame)
                }
                if views.count == 1, let view = views.first,
                   input.evidence.nativeStatus == "PASS", ProcessInfo.processInfo.systemUptime < deadline,
                   window.makeFirstResponder(view) {
                    attempted = true
                    view.insertText("UF03 narrow offline proof", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
                    inputValue = view.string
                    inputResponder = window.firstResponder.map { String(reflecting: type(of: $0)) }
                    inputObjectIdentity = String(describing: ObjectIdentifier(view))
                    inputResponderIdentity = window.firstResponder.map { String(describing: ObjectIdentifier($0)) }
                    inputFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
                    inputWindowMatches = view.window === window
                    success = observe { $0.draft == "UF03 narrow offline proof" && !$0.streaming
                        && $0.messageIDs == before.messageIDs && $0.sessionID == before.sessionID }
                        && view.string == "UF03 narrow offline proof" && window.firstResponder === view
                } else { reason = "UNIQUE_OWNED_NATIVE_TEXT_INPUT_NOT_PROVEN" }
            case "send_offline":
                if chat.agentEngine is InterruptRecordingEngine,
                   before.draft == "UF03 narrow offline proof", !before.streaming,
                   before.attachmentNames == ["uf03-native-fixture.txt"], before.skillIDs == ["skill:uf03-fixture"],
                   chat.pickerCatalog.map(\.id) == ["skill:uf03-fixture"] {
                    success = press("composer.send") && observe {
                        $0.streaming && $0.sessionID == before.sessionID && $0.draft.isEmpty
                            && $0.snapshot != nil && $0.snapshot != before.snapshot
                            && $0.messageIDs.count > before.messageIDs.count
                            && $0.snapshot?.inputDigest?.isEmpty == false
                            && $0.lastUserMessageID != before.lastUserMessageID
                            && $0.lastUserContent?.contains("UF03 narrow offline proof") == true
                            && $0.lastUserAttachmentNames == before.attachmentNames
                            && $0.attachmentNames.isEmpty && $0.skillIDs.isEmpty
                    }
                } else { reason = "ISOLATED_OFFLINE_SEND_PRECONDITION_NOT_PROVEN" }
            case "stop_offline":
                if before.streaming, let count = before.interruptCount, chat.agentEngine is InterruptRecordingEngine {
                    success = press("停止生成", kind: "labelOrTitle") && observe {
                        !$0.streaming && $0.interruptCount == count + 1
                            && $0.sessionID == before.sessionID && $0.snapshot == before.snapshot
                    }
                } else { reason = "OWNED_OFFLINE_STREAM_NOT_ACTIVE" }
            case "frozen_summary_policy_roundtrip":
                if before.streaming, before.snapshot != nil, before.policy.effort == .high,
                   chat.agentEngine is InterruptRecordingEngine {
                    if await choose("工作量", ComposerPolicyPresentation.effortLabel(.low)) {
                        if await observePolicy({ $0.policy.effort == .low && $0.snapshot == before.snapshot }) {
                            if await choose("工作量", ComposerPolicyPresentation.effortLabel(.high)) {
                                success = await observePolicy { $0.policy == before.policy && $0.snapshot == before.snapshot }
                            }
                        }
                    }
                    let summary = inventory().resolve(slot: "frozen_snapshot", query: "composer.snapshot",
                        fullVisibleText: before.snapshot.map(ComposerPolicyPresentation.snapshotSummary))
                    targets.append(summary.evidence)
                    success = success && summary.evidence.nativeStatus == "PASS"
                        && summary.evidence.native?.value == before.snapshot.map(ComposerPolicyPresentation.snapshotSummary)
                } else { reason = "OWNED_FROZEN_OFFLINE_STREAM_PRECONDITION" }
            case "pasted_preview_cancel":
                if before.pastedDraft != nil && window.sheets.isEmpty {
                    success = press("composer.pasted-text.preview")
                        && presentation("composer.pasted-text.editor", kind: "identifier", present: true)
                        && press("composer.pasted-text.cancel", transient: true)
                        && observe { $0.pastedDraft == before.pastedDraft && $0.messageIDs == before.messageIDs }
                        && presentation("composer.pasted-text.editor", kind: "identifier", present: false)
                } else { reason = "OWNED_PASTED_DRAFT_OR_SHEET_PRECONDITION" }
            case "pasted_remove":
                if before.pastedDraft != nil {
                    success = press("composer.pasted-text.remove")
                        && observe { $0.pastedDraft == nil && $0.messageIDs == before.messageIDs && !$0.streaming }
                } else { reason = "OWNED_PASTED_DRAFT_PRECONDITION" }
            case "edit_cancel":
                if before.editing {
                    success = press("取消编辑", kind: "help") && observe {
                        !$0.editing && $0.messageIDs == before.messageIDs
                            && $0.messageContents == before.messageContents && !$0.streaming
                    }
                } else { reason = "OWNED_EDITING_PRECONDITION" }
            default:
                reason = "UNKNOWN_FROZEN_TRANSACTION"
            }
            let after = CompanionState.capture(prepared)
            if ProcessInfo.processInfo.systemUptime > deadline { success = false; reason = "TRANSACTION_COOPERATIVE_BUDGET_EXCEEDED" }
            var result = CompanionTransactionEvidence(id: caseID + "/" + spec.kind,
                kind: spec.kind, status: success ? "PASS" : (attempted ? "RED" : "NOT_RUN_PREREQUISITE"),
                reason: success ? nil : (reason ?? "NATIVE_BEHAVIOR_NOT_PROVEN"), attempted: attempted,
                pressCount: presses.count, maxPresses: spec.maxPresses, witnessSamples: samples,
                maxWitnessSamples: 5, budgetSeconds: spec.budgetSeconds,
                durationSeconds: ProcessInfo.processInfo.systemUptime - started,
                before: before, after: after, nativeInputValue: inputValue,
                nativeInputFirstResponder: inputResponder, pressResults: presses,
                targetEvidence: targets, witness: success ? "NATIVE_ACTION_AND_STATE_CHANGE_OBSERVED" : "NOT_PROVEN")
            result.callerIdentityDiagnostics = callerIdentityDiagnostics
            result.startedUptime = started
            result.endedUptime = ProcessInfo.processInfo.systemUptime
            result.attemptCount = attempted ? 1 : 0
            result.nativeInputDeliveryCount = inputValue == nil ? 0 : 1
            result.nativeInputObjectIdentity = inputObjectIdentity
            result.nativeInputResponderIdentity = inputResponderIdentity
            result.nativeInputFrame = inputFrame
            result.nativeInputWindowMatches = inputWindowMatches
            result.checkpoints = checkpoints
            result.presentationChecks = presentationChecks
            result.ownedSheetCounts = ownedSheetCounts
            result.modal = modalEvidence
            dismissOwnedPresentation()
            return result
        }
    }
}

extension ComposerNativeFixtureContract.Fixture {
    var companionResourcesClosed: Bool {
        closed && !FileManager.default.fileExists(atPath: directory.path)
            && defaults.persistentDomain(forName: defaultsName) == nil
    }
}

extension ComposerNativeFixtureContract {
    @MainActor
    static func collectCompanionEvidence(
        journeyWindow: NSWindow? = nil,
        beforeHost: () -> Void = {},
        onCreated: (NSWindow) -> Void = { _ in },
        onSampled: (NSWindow) -> Void = { _ in },
        onClosed: (NSWindow) -> Void = { _ in }
    ) async -> CompanionEvidenceResult {
        let expected = companionCases
        guard expected.count == 57, Set(expected.map(\.id)).count == 57,
              expected.reduce(0, { $0 + $1.transactions.count }) == 54 else {
            return companionNotRun("FROZEN_COMPANION_CATALOG_INVALID")
        }
        var observations: [CompanionObservation] = []
        for spec in expected {
            observations.append(await collectCompanionObservation(spec,
                beforeHost: beforeHost, onCreated: onCreated, onSampled: onSampled, onClosed: onClosed))
        }
        let completed = observations.map(\.expected) == expected && observations.allSatisfy(\.completed)
        let errors = observations.flatMap { item in item.errors.map { item.expected.id + ":" + $0 } }
        var result = CompanionEvidenceResult(contractSHA256: companionContractSHA256, expected: expected,
            observations: observations, expectedCount: 57, transactionCount: 54, completed: completed,
            status: completed && errors.isEmpty ? "PASS" : "RED", errors: errors)
        result.nativeStatus = completed && observations.allSatisfy { $0.nativeStatus == "PASS" } ? "PASS" : "RED"
        result.visualStatus = observations.contains { $0.visualStatus == "RED" } ? "RED"
            : (observations.allSatisfy { $0.visualStatus == "PASS" } ? "PASS" : "UNVERIFIED")
        result.originWindowNumber = journeyWindow?.windowNumber
        result.originWindowType = journeyWindow.map { String(reflecting: type(of: $0)) }
        result.originWindowStillVisible = journeyWindow?.isVisible
        return result
    }

    // This is a diagnostic observation, never a full57/54 result receipt.
    @MainActor
    static func diagnosticCompanionPolicyCaseAt220(
        beforeHost: () -> Void,
        onCreated: (NSWindow) -> Void,
        onSampled: (NSWindow) -> Void,
        onClosed: (NSWindow) -> Void
    ) async throws -> CompanionObservation {
        let selected = companionCases.filter { $0.id == "companionEvidence.widths:m0:f12:w220" }
        guard selected.count == 1, let spec = selected.first,
              spec.width == 220, spec.fontSize == 12, spec.transactions.isEmpty else {
            throw CompanionSetupError.stateMismatch
        }
        return await collectCompanionObservation(spec, beforeHost: beforeHost,
            onCreated: onCreated, onSampled: onSampled, onClosed: onClosed)
    }

    // Original frozen cases 24/25; all six actions per case are retained.
    // This diagnostic never substitutes for the full57/54 contract.
    @MainActor
    static func diagnosticOriginalPolicyTransactionsAt220And310(
        beforeHost: () -> Void, onCreated: (NSWindow) -> Void,
        onSampled: (NSWindow) -> Void, onClosed: (NSWindow) -> Void
    ) async throws -> [CompanionObservation] {
        let ids = ["companionEvidence.policy:p0:w220", "companionEvidence.policy:p0:w310"]
        let kinds = ["mode_forward", "mode_restore", "effort_forward", "effort_restore"]
        let cases = companionCases
        let selected = cases.enumerated().filter { ids.contains($0.element.id) }
        guard selected.map({ $0.element.id }) == ids, selected.map({ $0.offset }) == [24, 25],
              selected.allSatisfy({ entry in
                  let spec = entry.element
                  return [220, 310].contains(Int(spec.width)) && spec.fontSize == 13
                      && spec.group == "policies" && spec.state == "idleEmpty" && spec.modelID == "deepseek-chat"
                      && spec.policy.mode == .manual && spec.policy.approvalScope == .request
                      && spec.policy.effort == .low && !spec.policy.bypassModeConfirmed
                      && spec.transactions.map(\.kind) == kinds
                      && spec.transactions.allSatisfy { $0.budgetSeconds == 0.5 && $0.maxPresses == 2 }
              }) else { throw CompanionSetupError.stateMismatch }
        defer { UF03NativeOperationTrace.caseOrdinal = -1 }
        var observations: [CompanionObservation] = []
        for entry in selected {
            UF03NativeOperationTrace.caseOrdinal = entry.offset
            observations.append(await collectCompanionObservation(entry.element, beforeHost: beforeHost,
                onCreated: onCreated, onSampled: onSampled, onClosed: onClosed))
        }
        return observations
    }

    @MainActor
    private static func collectCompanionObservation(
        _ spec: CompanionCase,
        beforeHost: () -> Void,
        onCreated: (NSWindow) -> Void,
        onSampled: (NSWindow) -> Void,
        onClosed: (NSWindow) -> Void
    ) async -> CompanionObservation {
        UF03NativeOperationTrace.caseOrdinal = companionCases.firstIndex { $0.id == spec.id } ?? -1
        let diagnostic = State2958DiagnosticRecorder(caseID: spec.id,
            zeroBasedOrdinal: companionCases.firstIndex { $0.id == spec.id } ?? -1)
        diagnostic.begin("prepare")
        let trace = UF03NativeOperationTrace.begin(.observation)
        defer {
            UF03NativeOperationTrace.end(.observation, trace)
            UF03NativeOperationTrace.caseOrdinal = -1
        }
        var item = CompanionObservation(expected: spec, primary: nil, completed: false,
            status: "NOT_RUN_PREREQUISITE", errors: [], setup: nil, after: nil,
            controls: [], transactions: [], host: [], windowClosed: false,
            fixtureResourcesClosed: false, restorationStatus: "NOT_RUN",
            setupCleanupAreNativeEvidence: false)
        do {
            let fixture = try Fixture(group: spec.pair.group)
            do {
                let prepared = try await fixture.prepareCompanion(spec)
                let setup = CompanionState.capture(prepared)
                item.setup = setup
                guard companionSetupMatches(spec, state: setup, prepared: prepared) else {
                    throw CompanionSetupError.stateMismatch
                }
                diagnostic.end("prepare")
                let savedTier = prepared.chat.modelSpeedTier
                let root = AnyView(prepared.root(.companion).frame(width: spec.width))
                let original = spec.pair.expected(.companion)
                diagnostic.begin("host_ready")
                beforeHost()
                var axFixture: UF03OriginalExecutorAXChannel.FixtureLifetime?
                if spec.transactions.contains(where: { ["mode_forward", "mode_restore", "effort_forward", "effort_restore", "frozen_summary_policy_roundtrip"].contains($0.kind) }) {
                    axFixture = UF03OriginalExecutorAXChannel.shared?.beginFixture(owner: fixture)
                }
                defer {
                    if let axFixture { UF03OriginalExecutorAXChannel.shared?.endFixture(axFixture) }
                }
                let hostTrace = UF03NativeOperationTrace.begin(.host)
                let probe = await hostAndProbeAsync(root, width: spec.width,
                    rowIdentifier: original.rowIdentifier, policyIdentifier: original.policyIdentifier,
                    modelIdentifier: original.modelIdentifier,
                    onCreated: { window in
                        window.setAccessibilityIdentifier("uf03-owned-" + spec.id)
                        onCreated(window)
                        diagnostic.end("host_ready")
                        item.host.append(CompanionHostEvidence.capture("before_mount", window: window, host: nil))
                    },
                    onSampled: onSampled,
                    onClosed: { window in
                        onClosed(window)
                        item.windowClosed = !window.isVisible && window.contentViewController == nil
                        item.host.append(CompanionHostEvidence.capture("after_close", window: window, host: nil))
                    },
                    onEvidence: { window, host, primary in
                        if !diagnostic.isEnded("host_ready") { diagnostic.end("host_ready") }
                        item.primary = prepared.observe(.companion, probe: primary)
                        item.host.append(CompanionHostEvidence.capture("after_sample", window: window, host: host))
                        if primary.hostFrame.width != spec.width || primary.hostFrame.height != 620
                            || window.contentView?.frame.width != spec.width || window.contentView?.frame.height != 620 {
                            item.errors.append("ACTUAL_HOST_DIMENSIONS_MISMATCH")
                        }
                        if !primary.isUsable { item.errors.append("ORIGINAL_PRIMARY_GEOMETRY_RED") }
                        if !primary.nativeHostReady { item.errors.append("OWNED_HOST_FOCUS_NOT_READY") }
                        if item.primary?.stateMatchesExpected != true { item.errors.append("PRIMARY_STATE_IDENTITY_MISMATCH") }
                        if host.window !== window || window.contentViewController?.view !== host
                            || !window.isVisible || host.isHiddenOrHasHiddenAncestor || host.alphaValue <= 0 {
                            item.errors.append("PUBLIC_HOST_OWNERSHIP_OR_VISIBILITY_NOT_PROVEN")
                        }
                        let rootLifetime = UF03CompanionRootLifetime()
                        defer { rootLifetime.invalidate() }
                        let inventory = CompanionInventory(window: window, host: host,
                            deadline: ProcessInfo.processInfo.systemUptime + 30 * 0.01,
                            rootSource: .initial(rootLifetime), diagnostic: diagnostic)
                        diagnostic.begin("control_resolution")
                        item.controls = inventory.controls(prepared)
                        diagnostic.end("control_resolution")
                        for control in item.controls where control.nativeStatus != "PASS" {
                            item.errors.append("CONTROL_" + control.slot + ":" + control.nativeStatus)
                        }
                        let model = item.controls.first { $0.slot == "model" }
                        let expectedIdentity = "\(prepared.chat.providerLabel)，模型 ID：\(spec.modelID)"
                        if model?.native?.value != expectedIdentity { item.errors.append("FULL_MODEL_AX_IDENTITY_NOT_PROVEN") }
                        diagnostic.begin("transactions")
                        for transaction in spec.transactions {
                            // Fixture-only restoration after the explicit chip removal;
                            // it is not passed off as a native add action.
                            if transaction.kind == "input_delivery",
                               prepared.chat.selectedPickerItems.isEmpty,
                               prepared.chat.pickerCatalog.map(\.id) == ["skill:uf03-fixture"],
                               let skill = prepared.chat.pickerCatalog.first {
                                item.fixtureOnlyRestorations.append(CompanionState.capture(prepared))
                                prepared.chat.togglePickerItem(skill)
                                item.fixtureOnlyRestorations.append(CompanionState.capture(prepared))
                            }
                            let result: CompanionTransactionEvidence
                            if !primary.nativeHostReady || !UF03OwnedHostFocusAdmission.isReady(
                                window: window, host: host, ownerIdentifier: "uf03-owned-" + spec.id) {
                                result = companionTransactionNotRun(spec.id, transaction: transaction,
                                    reason: "OWNED_HOST_FOCUS_NOT_READY")
                            } else if rootLifetime.menuOpeningUnresolved {
                                result = companionTransactionNotRun(spec.id, transaction: transaction,
                                    reason: "PREVIOUS_OWNED_MENU_LIFETIME_UNRESOLVED")
                            } else if transaction.kind == "stop_offline",
                               item.transactions.last(where: { $0.kind == "send_offline" })?.status != "PASS" {
                                result = companionTransactionNotRun(spec.id, transaction: transaction,
                                    reason: "THIS_CASE_SEND_OFFLINE_NOT_PROVEN")
                            } else {
                                result = await CompanionTransaction(prepared: prepared, spec: transaction,
                                    caseID: spec.id, window: window, host: host,
                                    rootLifetime: rootLifetime, windowRoot: inventory.rootBinding, axFixture: axFixture).run()
                            }
                            item.transactions.append(result)
                            if result.status != "PASS" { item.errors.append("TRANSACTION_" + transaction.kind + ":" + result.status) }
                            item.host.append(CompanionHostEvidence.capture("after_" + transaction.kind, window: window, host: host))
                        }
                        diagnostic.end("transactions")
                        item.after = CompanionState.capture(prepared)
                        // Restore selection through existing fixture APIs only, then
                        // destroy the isolated owner. Never rewrite a private snapshot.
                        diagnostic.begin("restoration")
                        prepared.chat.stopStreaming()
                        prepared.chat.cancelEdit()
                        prepared.chat.composerPolicySelection = spec.policy
                        prepared.chat.setProvider(.deepSeek)
                        let modelRestored = prepared.chat.applyPickedModel(modelID: spec.modelID)
                        prepared.chat.modelSpeedTier = savedTier
                        item.restoredSelection = CompanionState.capture(prepared)
                        let selectionRestored = modelRestored && prepared.chat.selectedModelID == spec.modelID
                            && prepared.chat.composerPolicySelection == spec.policy
                            && prepared.chat.modelSpeedTier == savedTier && !prepared.chat.isActiveSessionStreaming
                            && prepared.chat.selectedProviderType == .deepSeek
                            && prepared.chat.activeSessionID?.uuidString == setup.sessionID
                        item.restorationStatus = selectionRestored ? "SELECTION_RESTORED_PENDING_FIXTURE_CLOSE" : "FAILED"
                        if !selectionRestored { item.errors.append("FIXTURE_SELECTION_RESTORATION_FAILED") }
                        item.host.append(CompanionHostEvidence.capture("after_restore", window: window, host: host))
                        diagnostic.end("restoration")
                    })
                diagnostic.begin("cleanup")
                UF03NativeOperationTrace.end(.host, hostTrace)
                if item.primary == nil { item.primary = prepared.observe(.companion, probe: probe) }
                UF03NativeOperationTrace.measure(.fixtureClose) { fixture.close() }
                item.fixtureResourcesClosed = fixture.companionResourcesClosed
                if !item.windowClosed { item.errors.append("OWNED_WINDOW_NOT_CLOSED") }
                if !item.fixtureResourcesClosed { item.errors.append("ISOLATED_FIXTURE_NOT_CLOSED") }
                if item.restorationStatus == "SELECTION_RESTORED_PENDING_FIXTURE_CLOSE"
                    && item.windowClosed && item.fixtureResourcesClosed {
                    item.restorationStatus = "PASS"
                }
                item.completed = item.primary != nil && item.controls.count == 20
                    && item.transactions.count == spec.transactions.count
                    && item.transactions.allSatisfy { $0.status != "NOT_RUN_PREREQUISITE" }
                    && item.windowClosed && item.fixtureResourcesClosed
                item.status = item.completed && item.errors.isEmpty ? "PASS" : "RED"
                diagnostic.end("cleanup")
            } catch {
                UF03NativeOperationTrace.measure(.fixtureClose) { fixture.close() }
                item.fixtureResourcesClosed = fixture.companionResourcesClosed
                item.errors.append("FIXTURE_PREREQUISITE:\(error)")
            }
        } catch {
            item.errors.append("FIXTURE_OWNER_PREREQUISITE:\(error)")
        }
        if item.transactions.isEmpty && !spec.transactions.isEmpty {
            item.transactions = spec.transactions.map { transaction in
                companionTransactionNotRun(spec.id, transaction: transaction,
                    reason: "FIXTURE_OR_HOST_NOT_PREPARED")
            }
        }
        item.nativeErrors = item.errors
        let visualRecords = item.controls.compactMap(\.visibleText)
            + item.transactions.flatMap(\.targetEvidence).compactMap(\.visibleText)
        item.visualErrors = visualRecords.filter { $0.status != "PASS" }.map {
            $0.status + ":" + $0.evidenceMeaning
        }
        if !item.visualRecordsConsistent {
            item.nativeErrors.append("VISUAL_EVIDENCE_RECORD_INCOMPLETE_OR_INCONSISTENT")
        }
        let visualRed = visualRecords.contains { $0.status == "RED" }
        if visualRed { item.nativeErrors.append("CREDIBLE_VISUAL_RED") }
        item.nativeStatus = item.completed && item.nativeErrors.isEmpty ? "PASS" : "RED"
        item.visualStatus = visualRed ? "RED" : (item.visualErrors.isEmpty ? "PASS" : "UNVERIFIED")
        item.status = item.nativeStatus == "PASS" ? item.visualStatus : item.nativeStatus
        item.errors = item.nativeErrors + item.visualErrors
        item.state2958Diagnostic = diagnostic.finish()
        if let data = try? UF03NativeOperationTrace.measure(.encodeEvidence, { try JSONEncoder.prettySorted.encode(item) }), let json = String(data: data, encoding: .utf8) {
            // Raw progress survives an original outer timeout. It is not a
            // complete or successful final journey receipt.
            let rawWritten = UF03NativeOperationTrace.measure(.printEvidence) {
                // The authenticated production-identity channel binds this evidence to
                // the current launch. Preserve complete original bytes in bounded frames.
                if UF03OriginalExecutorAXChannel.shared?.requiresProducerIdentity == true {
                    return UF03OriginalStdoutFrames.emit(Data(json.utf8), caseID: spec.id, pid: getpid())
                }
                if let written = UF03OriginalStdoutFrames.emitIfEnabled(Data(json.replacingOccurrences(of: "\n", with: "").utf8), caseID: spec.id) {
                    return written
                }
                print("UF03_COMPANION_EVIDENCE " + json.replacingOccurrences(of: "\n", with: ""))
                return true
            }
            if !rawWritten {
                item.completed = false
                item.errors.append("ORIGINAL_STDOUT_FRAMES_UNVERIFIED")
                item.nativeErrors.append("ORIGINAL_STDOUT_FRAMES_UNVERIFIED")
                item.status = "RED"; item.nativeStatus = "RED"
            }
            _ = UF03NativeOperationTrace.measure(.flushEvidence) { fflush(stdout) }
        }
        return item
    }

    private enum CompanionSetupError: Error { case stateMismatch }

    @MainActor
    private static func companionSetupMatches(_ spec: CompanionCase, state: CompanionState, prepared: Prepared) -> Bool {
        guard state.modelID == spec.modelID, state.provider == ProviderType.deepSeek.rawValue,
              state.policy == spec.policy, prepared.center.uiBaseFontSize == spec.fontSize,
              state.sessionID != nil else { return false }
        switch spec.state {
        case "idleEmpty":
            return !state.streaming && state.draft.isEmpty && state.attachmentNames.isEmpty
                && state.skillIDs.isEmpty && state.snapshot == nil && state.pastedDraft == nil && !state.editing
        case "prepared":
            return !state.streaming && !state.draft.isEmpty
                && state.attachmentNames == ["uf03-native-fixture.txt"] && state.skillIDs == ["skill:uf03-fixture"]
                && state.snapshot == nil && prepared.chat.agentEngine is InterruptRecordingEngine
        case "generating", "bypassGenerating":
            return state.streaming && state.snapshot?.mode == spec.policy.mode
                && state.snapshot?.bypassModeConfirmed == spec.policy.bypassModeConfirmed
                && prepared.attachmentPreparedCount == 1 && prepared.skillPreparedIDs == ["skill:uf03-fixture"]
                && prepared.chat.agentEngine is InterruptRecordingEngine
        case "pastedDraft":
            return state.pastedDraft?.text == "UF03 isolated pasted evidence\nsecond line\n" && !state.streaming
        case "editing":
            return state.editing && state.draft == "UF03 isolated edit evidence" && !state.streaming
        default: return false
        }
    }
}

// AXPosition uses the zero screen's top-left origin in points; AppKit frames
// use its bottom-left origin. Other screens may extend into negative coordinates.
@MainActor
enum UF03OwnedHostFocusAdmission {
    static func accepts(applicationActive: Bool, exactKeyWindow: Bool, windowKey: Bool,
                        visible: Bool, exactHost: Bool, exactOwner: Bool) -> Bool {
        applicationActive && exactKeyWindow && windowKey && visible && exactHost && exactOwner
    }

    static func isReady(window: NSWindow, host: NSView, ownerIdentifier: String) -> Bool {
        let application = NSApplication.shared
        return accepts(applicationActive: application.isActive,
            exactKeyWindow: application.keyWindow === window, windowKey: window.isKeyWindow,
            visible: window.isVisible && !host.isHiddenOrHasHiddenAncestor && host.alphaValue > 0,
            exactHost: host.window === window && window.contentViewController?.view === host,
            exactOwner: !ownerIdentifier.isEmpty && window.accessibilityIdentifier() == ownerIdentifier)
    }
}

@MainActor
enum UF03TrackingMenuNativeProof {
    static func accepts(_ proof: [String: String]?, owner: String, targetID: String,
                        current: Bool, error: Int32, dispatched: Bool, late: Bool,
                        now: Double, deadline: Double) -> Bool {
        guard current, error == 0, dispatched, !late, now.isFinite, deadline.isFinite,
              now < deadline, let proof,
              proof["revision"] == "R15_ORIGINAL_EXECUTOR_VALIDATED_TARGET_V1",
              proof["owner"] == owner, proof["target_id"] == targetID,
              let digest = proof["request_sha"], digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        return true
    }
}

enum UF03AXScreenCoordinates {
    static func appKitFrame(position: CGPoint, size: CGSize, zeroScreenFrame: CGRect?) -> CGRect? {
        guard let zeroScreenFrame,
              zeroScreenFrame.origin == .zero,
              zeroScreenFrame.size.width.isFinite, zeroScreenFrame.size.height.isFinite,
              zeroScreenFrame.size.width > 0, zeroScreenFrame.size.height > 0,
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let result = CGRect(x: position.x,
                            y: zeroScreenFrame.maxY - position.y - size.height,
                            width: size.width, height: size.height)
        guard result.origin.x.isFinite, result.origin.y.isFinite,
              result.size.width.isFinite, result.size.height.isFinite,
              result.maxX.isFinite, result.maxY.isFinite else { return nil }
        return result
    }

    // This is only the existing target prerequisite; it grants no action permission.
    static func nativeTargetIsEligible(localMatchCount: Int, nativeMatchCount: Int,
                                       traversalComplete: Bool, hasNativeRole: Bool) -> Bool {
        localMatchCount == 1 && nativeMatchCount == 1 && traversalComplete && hasNativeRole
    }
}
