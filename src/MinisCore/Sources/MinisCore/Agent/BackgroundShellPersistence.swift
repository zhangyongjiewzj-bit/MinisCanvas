import Darwin
import Foundation
import os

/// Durable ownership and redacted output for background commands, bounded per job.
struct BackgroundShellPersistence {
    static let maximumOutputBytes = 16 * 1024 * 1024
    let root: URL
    struct Ownership: Codable {
        let snapshot: BackgroundShellSnapshot
        let processStart: UInt64?
    }
    static func processStart(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }
    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    func outputURL(_ id: String) -> URL { root.appendingPathComponent(id + ".log") }
    func write(_ record: Ownership) throws {
        try prepare()
        let data = try JSONEncoder().encode(record)
        let url = root.appendingPathComponent(record.snapshot.id + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func append(_ text: String, id: String) throws {
        try prepare()
        let url = outputURL(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        let bytes = Data(text.utf8)
        guard end + UInt64(bytes.count) <= UInt64(Self.maximumOutputBytes) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try file.write(contentsOf: bytes)
    }
    func read(id: String, offset: Int, cap: Int) throws -> (String, Int, Bool) {
        let file = try FileHandle(forReadingFrom: outputURL(id))
        defer { try? file.close() }
        let end = try file.seekToEnd()
        let start = min(UInt64(max(0, offset)), end)
        try file.seek(toOffset: start)
        let data = try file.read(upToCount: cap) ?? Data()
        var count = data.count
        if start + UInt64(count) < end { count -= BackgroundShellRegistry.incompleteUTF8Suffix(data) }
        return (String(decoding: data.prefix(count), as: UTF8.self), Int(start) + count,
                start + UInt64(count) < end)
    }
    func records() throws -> [Ownership] {
        try prepare()
        // 逐条解析：一条记录损坏只跳过它并记日志，其余照常恢复；损坏文件原样保留。
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Ownership? in
                do {
                    return try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: url))
                } catch {
                    Self.log.error("后台命令记录损坏，已跳过：\(url.lastPathComponent, privacy: .public)")
                    return nil
                }
            }
    }
    private static let log = Logger(subsystem: "com.miniscanvas.core", category: "BackgroundShellPersistence")
    func discardLog(id: String) throws {
        let url = outputURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func remove(id: String) throws {
        for url in [root.appendingPathComponent(id + ".json"), outputURL(id)]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
