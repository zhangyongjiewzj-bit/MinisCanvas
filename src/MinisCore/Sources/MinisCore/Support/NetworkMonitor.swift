import Foundation
import Network

/// Network reachability monitor (ported from OpenMinis `NetworkMonitor.swift`,
/// UIKit/iSH-free). Wraps `NWPathMonitor` and exposes a lock-protected snapshot
/// of connectivity state for offline banners / retry decisions.
///
/// Test contract: before `start()` the monitor reports deterministic defaults
/// (`isConnected() == false`, `isExpensive() == false`) regardless of the real
/// network — no path callbacks are delivered until started.
public final class NetworkMonitor: @unchecked Sendable {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.miniscanvas.networkmonitor")
    private let lock = NSLock()

    private var _isStarted = false
    private var _isConnected = false
    private var _isExpensive = false

    public init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePath(path)
        }
    }

    /// Whether monitoring is active.
    public func isStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isStarted
    }

    /// True when the current path is satisfied. Returns `false` while not
    /// started (deterministic default for test environments with no callbacks).
    public func isConnected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isStarted && _isConnected
    }

    /// True when the current path is expensive (cellular / personal hotspot).
    /// Returns `false` while not started.
    public func isExpensive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isStarted && _isExpensive
    }

    /// Starts delivering path updates. Idempotent.
    public func start() {
        lock.lock()
        guard !_isStarted else {
            lock.unlock()
            return
        }
        _isStarted = true
        lock.unlock()
        monitor.start(queue: queue)
    }

    /// Stops monitoring. Idempotent.
    public func stop() {
        lock.lock()
        guard _isStarted else {
            lock.unlock()
            return
        }
        _isStarted = false
        lock.unlock()
        monitor.cancel()
    }

    private func handlePath(_ path: NWPath) {
        lock.lock()
        _isConnected = path.status == .satisfied
        _isExpensive = path.isExpensive
        lock.unlock()
    }
}
