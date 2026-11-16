import Foundation
import Darwin

/// Fixed executable runner for one already-authorized, already-resolved hop.
/// No shell, temporary output files, inherited environment or fallback route.
enum WebFetchPinnedBackend {
    static let remoteIPPrefix = "\n\u{1}MINIS_REMOTE_IP:"
    static let remoteIPSuffix = "\u{2}\n"
    static let remoteIPWriteOut = remoteIPPrefix + "%{remote_ip}" + remoteIPSuffix
    static func load(_ invocation: WebFetchPinnedCurlInvocation, url: URL) async throws -> WebFetchHop {
        try Task.checkCancellation()
        let cancellation = HookCancellationFlag()
        let output: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try run(invocation, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        return try parseCurlOutput(output, url: url, pinnedAddress: invocation.pinnedAddress)
    }

    private static func run(_ invocation: WebFetchPinnedCurlInvocation,
                            cancellation: HookCancellationFlag) throws -> Data {
        let process = Process()
        process.executableURL = invocation.executableURL
        // --include supplies response metadata; the sole fixed write-out is
        // the actual remote IP trailer. No model format or output path is used.
        process.arguments = [invocation.arguments[0], "--include"] + Array(invocation.arguments.dropFirst())
        process.environment = invocation.environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        guard !cancellation.isCancelled else { throw CancellationError() }
        try process.run()
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [outputFD, errorFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var output = Data(), discardedError = 0
        var failure: Error?
        var terminatedAt: TimeInterval?
        var outputEOF = false, errorEOF = false
        func consume(_ fd: Int32, isOutput: Bool) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count == 0 {
                    if isOutput { outputEOF = true } else { errorEOF = true }
                    return
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if isOutput {
                    // Header allowance reuses the existing subprocess output
                    // bound; body retains the existing web-fetch byte limit.
                    if output.count + count > WebFetchTransport.maximumBytes + HookProcessRunner.outputLimit {
                        failure = WebFetchError.responseTooLarge
                        return
                    }
                    output.append(contentsOf: buffer.prefix(count))
                } else {
                    discardedError += count
                    if discardedError > HookProcessRunner.outputLimit {
                        failure = WebFetchError.responseTooLarge
                        return
                    }
                }
            }
        }
        while process.isRunning || !outputEOF || !errorEOF {
            consume(outputFD, isOutput: true)
            consume(errorFD, isOutput: false)
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation.isCancelled { failure = CancellationError() }
            if now >= deadline { failure = WebFetchPinnedError.connectionFailed }
            if failure != nil, process.isRunning {
                if let terminatedAt, now - terminatedAt >= 0.3 {
                    _ = kill(process.processIdentifier, SIGKILL)
                } else if terminatedAt == nil {
                    process.terminate()
                    terminatedAt = now
                }
            }
            if !process.isRunning && (failure != nil || (outputEOF && errorEOF)) { break }
            var descriptors = [pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 25)
        }
        process.waitUntilExit()
        if let failure { throw failure }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw WebFetchPinnedError.connectionFailed
        }
        return output
    }

    static func parseCurlOutput(_ raw: Data, url: URL,
                                pinnedAddress: WebFetchNumericAddress) throws -> WebFetchHop {
        let prefix = Data(remoteIPPrefix.utf8), suffix = Data(remoteIPSuffix.utf8)
        guard raw.suffix(suffix.count).elementsEqual(suffix) else {
            throw WebFetchPinnedError.connectionFailed
        }
        let addressEnd = raw.count - suffix.count
        // A numeric IPv6 literal is at most INET6_ADDRSTRLEN-1 bytes. Search
        // only this exact terminal record window, never page content generally.
        let start = max(0, addressEnd - (Int(INET6_ADDRSTRLEN) - 1) - prefix.count)
        guard let marker = raw.range(of: prefix, options: .backwards, in: start..<addressEnd),
              marker.upperBound < addressEnd,
              let text = String(data: raw[marker.upperBound..<addressEnd], encoding: .utf8),
              let remote = try? WebFetchNumericAddress(text),
              remote.representsSameAddress(as: pinnedAddress) else {
            throw WebFetchPinnedError.connectionFailed
        }
        // The write-out record is removed before header/body parsing. Body
        // marker text cannot override the final record emitted by curl.
        return try parse(Data(raw[..<marker.lowerBound]), url: url)
    }

    static func parse(_ raw: Data, url: URL) throws -> WebFetchHop {
        var remainder = raw
        while true {
            guard let separator = remainder.range(of: Data([13, 10, 13, 10])),
                  separator.lowerBound <= HookProcessRunner.outputLimit,
                  let header = String(data: remainder[..<separator.lowerBound], encoding: .isoLatin1) else {
                throw WebFetchError.invalidResponse
            }
            let lines = header.components(separatedBy: "\r\n")
            let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
            guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
                  let status = Int(statusParts[1]) else { throw WebFetchError.invalidResponse }
            remainder = Data(remainder[separator.upperBound...])
            if (100..<200).contains(status), status != 101 { continue }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw WebFetchError.invalidResponse }
                let key = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // Only metadata needed by this reader is retained. Cookies,
                // authentication and unrelated repeated headers are discarded.
                guard ["location", "content-type", "content-encoding", "content-length"].contains(key) else { continue }
                guard fields[key] == nil else { throw WebFetchError.invalidResponse }
                fields[key] = value
            }
            if let rawLength = fields["content-length"],
               let length = Int(rawLength), length > WebFetchTransport.maximumBytes {
                throw WebFetchError.responseTooLarge
            }
            guard fields["content-encoding"] == nil || fields["content-encoding"]?.lowercased() == "identity" else {
                throw WebFetchError.unsupportedEncoding
            }
            guard remainder.count <= WebFetchTransport.maximumBytes,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: String(statusParts[0]), headerFields: fields) else {
                throw WebFetchError.responseTooLarge
            }
            return WebFetchHop(response: response, body: remainder)
        }
    }
}
