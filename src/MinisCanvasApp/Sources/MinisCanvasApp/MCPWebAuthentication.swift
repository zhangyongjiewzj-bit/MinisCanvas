import AppKit
import AuthenticationServices
import MinisCore

/// ASWebAuthenticationSession owns external browser presentation, not a WebView/login form.
@MainActor
final class MCPWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    private var session: ASWebAuthenticationSession?
    private var completion: CheckedContinuation<URL, Error>?

    init(window: NSWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The UI requires an actual window before creating this adapter.
        window ?? ASPresentationAnchor()
    }
    func authenticate(url: URL, scheme: String) async throws -> URL {
        try Task.checkCancellation()
        guard session == nil, window != nil else { throw MCPOAuthError.cancelled }
        let cancellation = MCPWebAuthenticationCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    finish(.failure(MCPOAuthError.cancelled)); return
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let callback { self.finish(.success(callback)) }
                        else { self.finish(.failure(MCPOAuthError.cancelled)) }
                    }
                }
                session = browser
                browser.presentationContextProvider = self
                if cancellation.isCancelled { finish(.failure(MCPOAuthError.cancelled)); return }
                if !browser.start() { finish(.failure(MCPOAuthError.cancelled)) }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in
                self?.session?.cancel()
                self?.finish(.failure(MCPOAuthError.cancelled))
            }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        let pending = completion
        completion = nil; session = nil
        pending?.resume(with: result)
    }
}

/// Cancellation may arrive before the MainActor installs the session/continuation.
private final class MCPWebAuthenticationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
