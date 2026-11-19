import Foundation
import Network

/// One-shot HTTP listener bound to 127.0.0.1 on a random port. It only serves the
/// OAuth callback path and hands the first matching request URL to the waiter.
final class LoopbackOAuthListener: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MinisCanvas.ChatGPTAccount.loopback")
    private let callbackPath: String
    private var listener: NWListener?
    private var port: UInt16?
    private var outcome: Result<URL, ChatGPTAccountError>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var started = false

    private let expectedState: String?

    /// With `expectedState`, only a request on the callback path that carries exactly that
    /// state and a `code` or `error` completes the wait; anything else gets 404 and the
    /// listener keeps waiting, so a stray local request cannot burn the one-time callback.
    init(callbackPath: String, expectedState: String? = nil) {
        self.callbackPath = callbackPath
        self.expectedState = expectedState
    }

    /// Starts listening and returns the bound port once the listener is ready.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let created: NWListener
        do { created = try NWListener(using: parameters) }
        catch { throw ChatGPTAccountError.listenerUnavailable }
        lock.withLock { listener = created }
        created.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            created.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let value = self.markStarted() {
                        if let bound = self.currentListenerPort() {
                            self.lock.withLock { self.port = bound }
                            value.resume(returning: bound)
                        } else {
                            value.resume(throwing: ChatGPTAccountError.listenerUnavailable)
                        }
                    }
                case .failed, .cancelled:
                    if let value = self.markStarted() {
                        value.resume(throwing: ChatGPTAccountError.listenerUnavailable)
                    } else {
                        self.finish(.failure(.listenerUnavailable))
                    }
                default:
                    break
                }
            }
            lock.withLock { startContinuation = continuation }
            created.start(queue: queue)
        }
    }

    private var startContinuation: CheckedContinuation<UInt16, Error>?

    /// Returns the start continuation exactly once.
    private func markStarted() -> CheckedContinuation<UInt16, Error>? {
        lock.withLock {
            guard !started, let continuation = startContinuation else { return nil }
            started = true
            startContinuation = nil
            return continuation
        }
    }

    private func currentListenerPort() -> UInt16? {
        lock.withLock { listener?.port?.rawValue }
    }

    /// Waits for the OAuth callback. Cancelling the task closes the listener.
    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(.loginTimedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let ready: Result<URL, ChatGPTAccountError>? = lock.withLock {
                    if let outcome { return outcome }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready.mapError { $0 as Error }) }
            }
        } onCancel: {
            self.finish(.failure(.cancelled))
        }
    }

    func cancel() { finish(.failure(.cancelled)) }

    private func finish(_ result: Result<URL, ChatGPTAccountError>) {
        let (pending, closing): (CheckedContinuation<URL, Error>?, NWListener?) = lock.withLock {
            guard outcome == nil else { return (nil, nil) }
            outcome = result
            let pending = waiter
            waiter = nil
            let closing = listener
            listener = nil
            return (pending, closing)
        }
        closing?.cancel()
        pending?.resume(with: result.mapError { $0 as Error })
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            if let data, let target = Self.requestTarget(data), let url = self.callbackURL(target: target) {
                Self.respond(connection, status: "200 OK", body: Self.successPage)
                self.finish(.success(url))
            } else {
                Self.respond(connection, status: "404 Not Found", body: "")
            }
        }
    }

    private func callbackURL(target: String) -> URL? {
        guard let port = lock.withLock({ self.port }) else { return nil }
        return Self.matchCallback(target: target, port: port, callbackPath: callbackPath, expectedState: expectedState)
    }

    static func matchCallback(target: String, port: UInt16, callbackPath: String, expectedState: String?) -> URL? {
        guard let components = URLComponents(string: "http://127.0.0.1:\(port)" + target),
              components.path == callbackPath else { return nil }
        if let expectedState {
            let items = components.queryItems ?? []
            let states = items.filter { $0.name == "state" }
            guard states.count == 1, states[0].value == expectedState,
                  items.contains(where: { ($0.name == "code" || $0.name == "error") && !($0.value ?? "").isEmpty }) else { return nil }
        }
        return components.url
    }

    /// Request target of a `GET <target> HTTP/1.x` request line; anything else is rejected.
    static func requestTarget(_ data: Data) -> String? {
        guard let text = String(data: data.prefix(8 * 1024), encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
              parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static let successPage = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>MinisCanvas</title></head>\
    <body style="font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh">\
    <h2>登录已完成</h2><p>可以关闭此页面，回到 MinisCanvas。</p></body></html>
    """

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
