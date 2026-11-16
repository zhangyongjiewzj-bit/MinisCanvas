import Foundation
import CryptoKit
import Darwin

/// Tool-owned multipart spool, never a model-accessible root or a page File.
/// Its name is generated, created exclusively with mode 0600, and removed
/// after transport settles. No original filename or additional form values
/// are sent: the supported contract is one approved file field only.
struct BrowserMultipartArtifact: Sendable {
    let url: URL
    let boundary: String
    let length: Int64
    func remove() async throws {
        let path = url
        try await Task.detached { try FileManager.default.removeItem(at: path) }.value
    }
}

final class BrowserNativeFormUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let endpoint: URL
    let origin: URL
    private let lock = NSLock()
    private var completion: CheckedContinuation<Int, Error>?
    private var task: URLSessionUploadTask?
    private var cancelled = false

    init(endpoint: URL, origin: URL) { self.endpoint = endpoint; self.origin = origin }

    static func prepare(file: BrowserTransferFileIdentity, fieldName: String) async throws -> BrowserMultipartArtifact {
        guard !fieldName.isEmpty, fieldName.utf8.count <= 128,
              fieldName.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }) else {
            throw BrowserTransferError.prohibitedTarget
        }
        let worker = Task.detached(priority: .userInitiated) { try prepareOnDisk(file: file, fieldName: fieldName) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw BrowserTransferError.failed }
                offset += written
            }
        }
    }

    private static func prepareOnDisk(file: BrowserTransferFileIdentity, fieldName: String) throws -> BrowserMultipartArtifact {
        let source = URL(fileURLWithPath: file.path)
        guard try BrowserTransferFileIdentity.captureOnDisk(url: source, upload: true) == file else { throw BrowserTransferError.changedFile }
        var template = Array(FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("browser-native-upload-XXXXXX").path.utf8CString)
        let output = Darwin.mkstemp(&template)
        guard output >= 0 else { throw BrowserTransferError.failed }
        let spool = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        defer { Darwin.close(output) }
        let boundary = "MinisCanvas" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            guard Darwin.fchmod(output, 0o600) == 0 else { throw BrowserTransferError.failed }
            let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw BrowserTransferError.changedFile }
            defer { Darwin.close(input) }
            var before = stat()
            guard Darwin.fstat(input, &before) == 0, before.st_nlink == 1,
                  (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw BrowserTransferError.changedFile }
            try write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"upload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8), to: output)
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
                guard count >= 0 else { throw BrowserTransferError.changedFile }
                if count == 0 { break }
                let chunk = Data(buffer.prefix(count))
                hash.update(data: chunk)
                try write(chunk, to: output)
            }
            var after = stat(), actualPath = stat()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == file.contentDigest, Darwin.fstat(input, &after) == 0,
                  Darwin.lstat(source.path, &actualPath) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  after.st_dev == actualPath.st_dev, after.st_ino == actualPath.st_ino,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_nlink == 1, after.st_nlink == 1, actualPath.st_nlink == 1 else {
                throw BrowserTransferError.changedFile
            }
            try write(Data("\r\n--\(boundary)--\r\n".utf8), to: output)
            var info = stat()
            guard Darwin.fstat(output, &info) == 0 else { throw BrowserTransferError.failed }
            return BrowserMultipartArtifact(url: spool, boundary: boundary, length: info.st_size)
        } catch {
            // Report an undeletable owned spool instead of swallowing cleanup.
            do { try FileManager.default.removeItem(at: spool) }
            catch { throw BrowserTransferFailure(cancelled: false, partialOutputPath: spool.path, code: "upload_spool_cleanup_failed") }
            throw error
        }
    }

    func send(_ artifact: BrowserMultipartArtifact) async throws -> Int {
        guard BrowserNavigationPolicy.isValidWebURL(endpoint), BrowserNavigationPolicy.sameOrigin(endpoint, origin),
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw BrowserTransferError.prohibitedTarget
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=" + artifact.boundary, forHTTPHeaderField: "Content-Type")
        request.setValue(String(artifact.length), forHTTPHeaderField: "Content-Length")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: BrowserTransferError.cancelled); return
                }
                completion = continuation
                let upload = session.uploadTask(with: request, fromFile: artifact.url)
                task = upload
                lock.unlock()
                upload.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Discard response bytes. No unbounded response buffer or page execution.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = completion
        completion = nil
        let wasCancelled = cancelled
        self.task = nil
        lock.unlock()
        guard let continuation else { return }
        if wasCancelled { continuation.resume(throwing: BrowserTransferError.cancelled) }
        else if error == nil, let response = task.response as? HTTPURLResponse,
                response.url == endpoint, (200...299).contains(response.statusCode) {
            continuation.resume(returning: response.statusCode)
        } else {
            // A failed response can follow a transmitted POST; do not promise
            // that the server received no bytes and never retry automatically.
            let status = (task.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "transport"
            continuation.resume(throwing: BrowserTransferFailure(cancelled: false, partialOutputPath: nil,
                code: "native_upload_failed_" + status))
        }
    }
}
