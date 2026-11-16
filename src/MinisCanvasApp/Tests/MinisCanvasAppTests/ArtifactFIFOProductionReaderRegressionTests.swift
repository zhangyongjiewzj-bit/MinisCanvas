import AppKit
import Foundation
import CryptoKit
import Darwin
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite(.serialized)
@MainActor
struct ArtifactFIFOProductionReaderRegressionTests {
    private static let acceptedSDKHelperSHA256 = "da2601bc562f2e0dd0cd7e00e923aee763ce94bdbf3eddccdebf1a4b8d5d313d"

    private func absent(_ pid: Int32) throws -> Bool {
        let observer = Process()
        observer.executableURL = URL(fileURLWithPath: "/bin/ps")
        observer.arguments = ["-p", String(pid), "-o", "pid=,stat=,command="]
        let out = Pipe(), err = Pipe(), ended = DispatchSemaphore(value: 0)
        observer.standardOutput = out; observer.standardError = err
        observer.terminationHandler = { _ in ended.signal() }
        try observer.run()
        guard ended.wait(timeout: .now() + 1) == .success else {
            observer.terminate()
            guard ended.wait(timeout: .now() + 0.2) == .success else {
                if observer.isRunning { _ = Darwin.kill(observer.processIdentifier, SIGKILL) }
                guard ended.wait(timeout: .now() + 0.2) == .success else {
                    throw NSError(domain: "ArtifactFIFOObserverUNJOINED", code: 1)
                }
                observer.waitUntilExit()
                throw NSError(domain: "ArtifactFIFOObserverTimeout", code: 1)
            }
            observer.waitUntilExit()
            throw NSError(domain: "ArtifactFIFOObserverTimeout", code: 1)
        }
        observer.waitUntilExit()
        let bytes = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        print("ARTIFACT_FIFO_PS observerPID=\(observer.processIdentifier) targetPID=\(pid) code=\(observer.terminationStatus) out=\(String(decoding: bytes, as: UTF8.self)) err=\(String(decoding: errors, as: UTF8.self))")
        return observer.terminationStatus == 1 && bytes.isEmpty && errors.isEmpty
    }

    @Test
    func regularFileReplacedByOwnedFIFOCannotBlockProductionDigest() throws {
        #expect(NSApp == nil)
        let args = CommandLine.arguments
        let slots = args.indices.filter { args[$0] == "--test-bundle-path" }
        let slot = try #require(slots.count == 1 ? slots.first : nil)
        try #require(slot + 1 < args.count)
        let bundle = URL(fileURLWithPath: args[slot + 1]).resolvingSymlinksInPath().standardizedFileURL
        let executable = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        var binaryInfo = stat()
        try #require(lstat(executable.path, &binaryInfo) == 0 && binaryInfo.st_mode & S_IFMT == S_IFREG && binaryInfo.st_uid == 0)
        let measured = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        try #require(measured == Self.acceptedSDKHelperSHA256)
        let owned = try ArtifactAOwnedPhysicalRoot(label: "Artifact-FIFO-")
        var safelyRetired = false
        defer {
            if safelyRetired { #expect(owned.cleanup()) }
            else { print("ARTIFACT_FIFO_UNJOINED_RETAIN_ROOT path=\(owned.root.path)") }
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing",
            "--filter", "ownedFIFOReaderChild", "--no-parallel", "--verbose",
            "--event-stream-output-path", owned.root.appendingPathComponent("child-events.ndjson").path]
        // Real formal host whitelist comes from the actual parent process.
        // No arbitrary target/file/mode is accepted by this fixed worker.
        var environment = ProcessInfo.processInfo.environment
        environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_ROOT"] = owned.root.path
        environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_DEVICE"] = String(owned.device)
        environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_INODE"] = String(owned.inode)
        environment["MINISCANVAS_ARTIFACT_FIFO_PARENT_PID"] = String(getpid())
        child.environment = environment
        let out = Pipe(), err = Pipe(), ended = DispatchSemaphore(value: 0)
        child.standardOutput = out; child.standardError = err
        child.terminationHandler = { _ in ended.signal() }
        let start = ContinuousClock.now
        try child.run()
        print("ARTIFACT_FIFO_CHILD_STARTED pid=\(child.processIdentifier) workerSHA=\(measured) root=\(owned.root.path)")
        let timedOut = ended.wait(timeout: .now() + 2.2) != .success
        if timedOut {
            child.terminate()
            if ended.wait(timeout: .now() + 0.3) != .success {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                guard ended.wait(timeout: .now() + 0.2) == .success else {
                    Issue.record("Owned FIFO worker did not terminate; parent must preserve its root")
                    throw NSError(domain: "ArtifactFIFOWorkerUNJOINED", code: 1)
                }
            }
        }
        child.waitUntilExit()
        let elapsed = start.duration(to: .now)
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        print("ARTIFACT_FIFO_CHILD_TERMINAL pid=\(child.processIdentifier) timedOut=\(timedOut) actualExit=\(child.terminationStatus) actualWait=true stdoutEOF=true stderrEOF=true elapsed=\(elapsed)")
        print("ARTIFACT_FIFO_CHILD_STDOUT_B64 \(stdout.base64EncodedString())")
        print("ARTIFACT_FIFO_CHILD_STDERR_B64 \(stderr.base64EncodedString())")
        let childEvents = try Data(contentsOf: owned.root.appendingPathComponent("child-events.ndjson"))
        print("ARTIFACT_FIFO_CHILD_EVENTS_B64 \(childEvents.base64EncodedString())")
        let firstAbsent = try absent(child.processIdentifier)
        // Observation after real termination/wait; this is not a fake join.
        Thread.sleep(forTimeInterval: 5)
        let laterAbsent = try absent(child.processIdentifier)
        safelyRetired = firstAbsent && laterAbsent
        #expect(firstAbsent && laterAbsent)
        let records = try String(decoding: stdout, as: UTF8.self).split(separator: "\n").filter { $0.first == "{" }.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0 }
        let positive = try #require(records.first { $0["phase"] as? String == "POSITIVE" })
        try #require(positive["matched"] as? Bool == true)
        try #require(records.first { $0["phase"] as? String == "FIFO_REPLACED" }?["replaced"] as? Bool == true)
        // On the old reader the preceding two real markers prove admission,
        // and this assertion is a genuine framework RED after bounded reap.
        #expect(!timedOut)
        #expect(child.terminationReason == .exit && child.terminationStatus == 0)
        let result = records.first { $0["phase"] as? String == "FIFO_RESULT" }
        #expect(result?["digest_nil"] as? Bool == true)
        #expect(result?["not_a_file"] as? Bool == true)
        #expect(records.allSatisfy { ($0["NSApp_nil"] as? Bool) != false })
        let eventObjects = try String(decoding: childEvents, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }.compactMap { $0?["payload"] as? [String: Any] }
        let ownEvents = eventObjects.filter { ($0["testID"] as? String)?.contains("/ownedFIFOReaderChild()") == true }
        #expect(ownEvents.filter { $0["kind"] as? String == "testStarted" }.count == 1)
        #expect(ownEvents.filter { $0["kind"] as? String == "testEnded" }.count == 1)
        #expect(eventObjects.allSatisfy { !["issueRecorded", "errorRecorded"].contains($0["kind"] as? String ?? "") })
        #expect(NSApp == nil)
    }
    // A real framework test in the same bundle, skipped unless our parent
    // supplies its fresh formal-owned fixture identity. No external path or
    // arbitrary helper can be selected. No user file is accessed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_ROOT"] != nil))
    func ownedFIFOReaderChild() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_ROOT"])
        let device = try #require(environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_DEVICE"].flatMap(Int32.init))
        let inode = try #require(environment["MINISCANVAS_ARTIFACT_FIFO_CHILD_INODE"].flatMap(UInt64.init))
        let parentPID = try #require(environment["MINISCANVAS_ARTIFACT_FIFO_PARENT_PID"].flatMap(Int32.init))
        try #require(getppid() == parentPID)
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let parentPath = try #require(PolicyRuntimePathBoundary.canonicalPath(formal.rootDirectory.path))
        let canonical = try #require(PolicyRuntimePathBoundary.canonicalPath(path))
        let root = URL(fileURLWithPath: canonical, isDirectory: true)
        let prefix = "Artifact-FIFO-"
        try #require(root.deletingLastPathComponent().path == parentPath)
        try #require(root.lastPathComponent.hasPrefix(prefix))
        try #require(UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil)
        var info = stat()
        try #require(lstat(root.path, &info) == 0 && info.st_dev == device && info.st_ino == inode)
        try #require(info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700)
        try #require(NSApp == nil)
        func emit(_ phase: String, _ fields: [String: Any]) throws {
            var object = fields; object["phase"] = phase
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
            fflush(nil)
        }
        let bytes = Data("isolated FIFO regression positive control\n".utf8)
        let positive = root.appendingPathComponent("positive.txt")
        try bytes.write(to: positive)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let positiveDigest = AgentFileOutputTargetResolver.generatedFileDigest(positive)
        try emit("POSITIVE", ["matched": positiveDigest == expected, "NSApp_nil": NSApp == nil])
        try #require(positiveDigest == expected)
        let file = root.appendingPathComponent("record-regular.txt")
        try bytes.write(to: file)
        var replaced = false
        let verified = AgentFileOutputTargetResolver.resolve(path: "record-regular.txt", workspaceRoot: root.path) { target in
            let observed = AgentFileOutputTargetResolver.fileSystemProbe(target)
            guard target.lastPathComponent == "record-regular.txt", target.deletingLastPathComponent() == root else { return .unavailable }
            if case .readableFile = observed {
                replaced = unlink(target.path) == 0 && mkfifo(target.path, 0o600) == 0
                print("{\"phase\":\"FIFO_REPLACED\",\"replaced\":\(replaced)}"); fflush(nil)
            }
            return observed
        }
        try #require(replaced)
        let target: URL
        switch verified {
        case .success(let value): target = value
        case .failure: throw NSError(domain: "ArtifactFIFOResolution", code: 1)
        }
        let digest = AgentFileOutputTargetResolver.generatedFileDigest(target)
        let probe = AgentFileOutputTargetResolver.fileSystemProbe(target)
        let notAFile: Bool
        if case .notAFile = probe { notAFile = true } else { notAFile = false }
        try emit("FIFO_RESULT", ["digest_nil": digest == nil, "not_a_file": notAFile, "NSApp_nil": NSApp == nil])
        #expect(digest == nil)
        #expect(notAFile)
        #expect(NSApp == nil)
    }

}
