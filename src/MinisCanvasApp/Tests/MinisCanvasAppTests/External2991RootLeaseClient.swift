import Foundation
import Darwin
import CryptoKit

struct External2991Identity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    let mode: UInt16
    static func held(_ fd: Int32) throws -> Self {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw External2991Failure("fstat", errno) }
        guard s.st_mode & S_IFMT == S_IFDIR else { throw External2991Failure("not-directory", EINVAL) }
        return Self(device: UInt64(s.st_dev), inode: UInt64(s.st_ino), uid: s.st_uid,
                    mode: UInt16(s.st_mode & 0o7777))
    }
}
struct External2991Failure: Error, CustomStringConvertible {
    let stage: String
    let code: Int32
    init(_ stage: String, _ code: Int32 = EINVAL) { self.stage = stage; self.code = code }
    var description: String { "External2991Failure(stage=\(stage), code=\(code))" }
}

/// Tests-only real IPC. It never reports framework pass, Task join, or root cleanup.
final class External2991RootLeaseClient {
    let root: URL
    let runID: String
    let nonce: String
    let identity: External2991Identity
    private var rootFD: Int32 = -1
    private var parentFD: Int32 = -1
    private var socketFD: Int32 = -1
    private var terminalSent = false

    static func nonce(for runID: String) throws -> String {
        guard runID.hasPrefix("ARCH2991_"), runID.count == 9 + 36,
              let value = UUID(uuidString: String(runID.suffix(36))) else {
            throw External2991Failure("run-id-must-be-ARCH2991_UUID")
        }
        return value.uuidString
    }
    static func endpoint(for runID: String) throws -> URL {
        URL(fileURLWithPath: "/System/Volumes/Data/private/tmp/a3-\(try nonce(for: runID))/s")
    }

    init(root: URL, actualFM: URL, suite: String, usageKey: String, usageLock: String,
         runID: String) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.runID = runID
        self.nonce = try Self.nonce(for: runID)
        let parent = actualFM.standardizedFileURL.resolvingSymlinksInPath()
        guard self.root.deletingLastPathComponent().path == parent.path else {
            throw External2991Failure("actual-FM-parent-mismatch")
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw External2991Failure("open-actual-FM", errno) }
        self.parentFD = parentFD
        let fd = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { Darwin.close(parentFD); self.parentFD = -1; throw External2991Failure("open-owned-root", errno) }
        self.rootFD = fd
        do { self.identity = try External2991Identity.held(fd) }
        catch { Darwin.close(fd); Darwin.close(parentFD); self.rootFD = -1; self.parentFD = -1; throw error }
        do {
            let p = try External2991Identity.held(parentFD)
            guard identity.uid == geteuid(), identity.mode == 0o700,
                  p.uid == identity.uid, p.mode == 0o700, p.device == identity.device,
                  p.inode != identity.inode else { throw External2991Failure("root-parent-identity") }
            let endpoint = try Self.endpoint(for: runID)
            var d = stat()
            guard lstat(endpoint.deletingLastPathComponent().path, &d) == 0,
                  d.st_mode & S_IFMT == S_IFDIR, d.st_mode & 0o7777 == 0o700,
                  d.st_uid == geteuid() else { throw External2991Failure("IPC-directory-identity") }
            var s = stat()
            guard lstat(endpoint.path, &s) == 0, s.st_mode & S_IFMT == S_IFSOCK,
                  s.st_uid == geteuid() else { throw External2991Failure("IPC-socket-identity") }
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else { throw External2991Failure("socket", errno) }
            socketFD = sock
            var one: Int32 = 1
            guard setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
                throw External2991Failure("SO_NOSIGPIPE", errno)
            }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            guard setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
                  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw External2991Failure("socket-timeout", errno)
            }
            var address = sockaddr_un()
            let bytes = Array(endpoint.path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw External2991Failure("IPC-path-too-long") }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                for i in bytes.indices { target[i] = UInt8(bitPattern: bytes[i]) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw External2991Failure("connect-real-owner", errno) }
            var uid: uid_t = 0; var gid: gid_t = 0
            var peerPID: pid_t = 0; var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getpeereid(sock, &uid, &gid) == 0, uid == geteuid(),
                  getsockopt(sock, 0, LOCAL_PEERPID, &peerPID, &size) == 0, peerPID > 1 else {
                throw External2991Failure("owner-peer-credentials", errno)
            }
            let record: [String: Any] = ["phase": "register", "protocol": 1, "run_id": runID,
                "nonce": nonce, "sdk_pid": getpid(), "sdk_ppid": getppid(), "root": self.root.path,
                "actual_fm": parent.path, "profile_root": root.path, "root_identity": try Self.object(identity),
                "parent_identity": try Self.object(p), "suite": suite, "usage_key": usageKey,
                "usage_lock": usageLock]
            try send(record)
            let ack = try receive()
            guard ack["phase"] as? String == "ownership_ack",
                  ack["run_id"] as? String == runID, ack["nonce"] as? String == nonce,
                  (ack["owner_pid"] as? NSNumber)?.int32Value == peerPID,
                  (ack["sdk_pid"] as? NSNumber)?.int32Value == getpid(),
                  ack["root"] as? String == self.root.path,
                  try Self.decodeIdentity(ack["root_identity"]) == identity,
                  try External2991Identity.held(fd) == identity else {
                throw External2991Failure("real-ACK-identity-mismatch")
            }
        } catch {
            if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
            Darwin.close(fd); Darwin.close(parentFD); rootFD = -1; self.parentFD = -1
            throw error
        }
    }
    deinit {
        if socketFD >= 0 { Darwin.close(socketFD) }
        if rootFD >= 0 { Darwin.close(rootFD) }
        if parentFD >= 0 { Darwin.close(parentFD) }
    }
    func finish(files: [URL], defaultsSynchronized: Bool, usageJoined: Bool) throws {
        guard !terminalSent, files.count == 5, defaultsSynchronized, usageJoined,
              try External2991Identity.held(rootFD) == identity else {
            throw External2991Failure("terminal-precondition")
        }
        let rows = try files.map { file -> [String: Any] in
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(root.path + "/"), canonical.path == file.standardizedFileURL.path else {
                throw External2991Failure("terminal-file-outside-or-alias")
            }
            let fd = open(canonical.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw External2991Failure("terminal-open", errno) }
            defer { Darwin.close(fd) }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
                  s.st_uid == identity.uid, UInt64(s.st_dev) == identity.device, s.st_nlink == 1 else {
                throw External2991Failure("terminal-file-identity")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            var after = stat()
            guard fstat(fd, &after) == 0, s.st_dev == after.st_dev, s.st_ino == after.st_ino,
                  s.st_size == after.st_size, s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  data.count == after.st_size else { throw External2991Failure("terminal-file-mutated-during-read") }
            return ["relative": String(canonical.path.dropFirst(root.path.count + 1)),
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    "device": UInt64(s.st_dev), "inode": UInt64(s.st_ino), "uid": s.st_uid,
                    "size": data.count]
        }
        try send(["phase": "terminal", "run_id": runID, "nonce": nonce, "sdk_pid": getpid(),
                  "status": "business-returned-not-framework-pass", "files": rows,
                  "defaults_synchronized": true, "usage_joined": true,
                  "task_join_claim": false, "root_cleanup_claim": false])
        let ack = try receive()
        guard ack["phase"] as? String == "terminal_received", ack["nonce"] as? String == nonce else {
            throw External2991Failure("terminal-receipt-ACK")
        }
        terminalSent = true
    }
    func abort() {
        guard !terminalSent else { return }
        // Best effort notice never replaces the original business error.
        try? send(["phase": "abort", "run_id": runID, "nonce": nonce, "sdk_pid": getpid()])
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func decodeIdentity(_ value: Any?) throws -> External2991Identity {
        guard let value else { throw External2991Failure("missing-ACK-identity") }
        return try JSONDecoder().decode(External2991Identity.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw External2991Failure("empty-message") }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(socketFD, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw External2991Failure("socket-write", errno) }
                offset += count
            }
        }
    }
    private func receive() throws -> [String: Any] {
        var data = Data(); var byte: UInt8 = 0
        while data.count < 65536 {
            let count = Darwin.read(socketFD, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw External2991Failure("socket-read-or-owner-refused", errno) }
            if byte == 10 {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw External2991Failure("owner-message-not-object")
                }
                return value
            }
            data.append(byte)
        }
        throw External2991Failure("owner-message-too-large")
    }
}
