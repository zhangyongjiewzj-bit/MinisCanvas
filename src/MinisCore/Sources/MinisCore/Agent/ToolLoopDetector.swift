// Historical source: OpenMinis ToolLoopDetector, with simplified detection and MinisCanvas lifecycle wiring.
// Reimplemented from an independent behavior specification.
import Foundation

public final class ToolLoopLifecycle: @unchecked Sendable {
    public struct Identity: Hashable, Sendable {
        public let turnID: Int
        public let stopGeneration: Int

        public init(turnID: Int, stopGeneration: Int) {
            self.turnID = turnID
            self.stopGeneration = stopGeneration
        }
    }

    private let mutex = NSRecursiveLock()
    private var counters: [Int: Int] = [:]
    private var running: [Int: Identity] = [:]

    public init() {}

    public func begin(turnID: Int) -> Identity {
        mutex.lock()
        defer { mutex.unlock() }
        let identity = advance(turnID)
        running[turnID] = identity
        return identity
    }

    @discardableResult
    public func stop(turnID: Int) -> Identity {
        mutex.lock()
        defer { mutex.unlock() }
        running.removeValue(forKey: turnID)
        return advance(turnID)
    }

    public func finish(turnID: Int) {
        stop(turnID: turnID)
    }

    public func isCurrent(_ identity: Identity) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return running[identity.turnID] == identity
    }

    fileprivate func whileCurrent<T>(_ identity: Identity, work: () -> T) -> T? {
        mutex.lock()
        defer { mutex.unlock() }
        guard running[identity.turnID] == identity else { return nil }
        return work()
    }

    private func advance(_ turn: Int) -> Identity {
        let generation = (counters[turn] ?? 0) &+ 1
        counters[turn] = generation
        return Identity(turnID: turn, stopGeneration: generation)
    }
}

public final class ToolLoopDetector: @unchecked Sendable {
    public struct InvocationRecord: @unchecked Sendable {
        public let signature: String
        public let toolName: String
        public let input: [String: Any]
        public let timestamp: TimeInterval
    }

    public let lifecycle: ToolLoopLifecycle
    private let mutex = NSRecursiveLock()
    private var threshold: Int
    private var limit: Int
    private var records: [InvocationRecord] = []
    private var generation: ToolLoopLifecycle.Identity?

    public init(loopThreshold: Int = 3, historyLimit: Int = 100,
                lifecycle: ToolLoopLifecycle = ToolLoopLifecycle()) {
        threshold = max(1, loopThreshold)
        limit = max(max(1, loopThreshold), historyLimit)
        self.lifecycle = lifecycle
    }

    public var loopThreshold: Int {
        get { synchronized { threshold } }
        set { synchronized { threshold = max(1, newValue) } }
    }

    public var historyLimit: Int {
        get { synchronized { limit } }
        set { synchronized { limit = max(threshold, newValue) } }
    }

    @discardableResult
    public func recordInvocation(tool: String, input: [String: Any]) -> String {
        synchronized { append(tool: tool, input: input) }
    }

    @discardableResult
    public func recordInvocation(tool: String, input: [String: Any],
                                 identity: ToolLoopLifecycle.Identity) -> Bool {
        synchronized {
            lifecycle.whileCurrent(identity) {
                if generation != identity {
                    records.removeAll(keepingCapacity: true)
                    generation = identity
                }
                append(tool: tool, input: input)
                if hasLoop { lifecycle.stop(turnID: identity.turnID) }
                return true
            } ?? false
        }
    }

    @discardableResult
    public func stop(identity: ToolLoopLifecycle.Identity) -> Bool {
        synchronized {
            lifecycle.whileCurrent(identity) {
                lifecycle.stop(turnID: identity.turnID)
                return true
            } ?? false
        }
    }

    public func accepts(_ identity: ToolLoopLifecycle.Identity) -> Bool {
        lifecycle.isCurrent(identity)
    }

    public func isLooping() -> Bool { synchronized { hasLoop } }
    public func lastSignature() -> String? { synchronized { records.last?.signature } }
    public func historySnapshot() -> [InvocationRecord] { synchronized { records } }

    public var terminalReason: ToolTerminalReason? {
        isLooping() ? .loopDetected : nil
    }

    public func reset() {
        synchronized {
            records.removeAll(keepingCapacity: true)
            generation = nil
        }
    }

    public static func signature(tool: String, input: [String: Any]) -> String {
        let value = jsonValue(input)
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return tool + ":" + encoded
    }

    private static func jsonValue(_ value: Any) -> Any {
        if let object = value as? [String: Any] { return object.mapValues { jsonValue($0) } }
        if let array = value as? [Any] { return array.map { jsonValue($0) } }
        if value is String || value is NSNull { return value }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number }
        return String(describing: value)
    }

    /// 轮询类（后台命令状态）与只读查询类工具连续同参调用是正常工作方式，
    /// 阈值按倍数放宽；写入、命令等其他工具仍按基础阈值判定。
    private static let pollingTools: Set<String> = ["shell_output"]
    private static let readOnlyQueryTools: Set<String> = [
        "file_read", "file_grep", "file_glob", "web_fetch", "session_read"
    ]

    private func effectiveThreshold(for tool: String) -> Int {
        let factor = Self.pollingTools.contains(tool) ? 4
            : (Self.readOnlyQueryTools.contains(tool) ? 2 : 1)
        return min(threshold * factor, limit)
    }

    private var hasLoop: Bool {
        guard let last = records.last else { return false }
        let needed = effectiveThreshold(for: last.toolName)
        guard records.count >= needed else { return false }
        return records.suffix(needed).allSatisfy { $0.signature == last.signature }
    }

    @discardableResult
    private func append(tool: String, input: [String: Any]) -> String {
        let signature = Self.signature(tool: tool, input: input)
        records.append(InvocationRecord(signature: signature, toolName: tool,
                                        input: input, timestamp: Date().timeIntervalSince1970))
        if records.count > limit { records.removeFirst(records.count - limit) }
        return signature
    }

    private func synchronized<T>(_ action: () -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return action()
    }
}
