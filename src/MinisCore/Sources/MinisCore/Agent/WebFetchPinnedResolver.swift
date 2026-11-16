import Foundation
import Darwin

/// Called only after the original Composer/Hook authorization for this hop.
/// A DNS result is not a permission. Every returned address must pass the B
/// public-address floor before any one address is pinned to the HTTP socket.
enum WebFetchPinnedResolver {
    static func resolve(_ endpoint: WebFetchEndpoint) async throws -> [WebFetchNumericAddress] {
        try Task.checkCancellation()
        let addresses: [WebFetchNumericAddress] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try resolveBlocking(endpoint)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return addresses
    }

    private static func resolveBlocking(_ endpoint: WebFetchEndpoint) throws -> [WebFetchNumericAddress] {
        guard endpoint.host != "localhost", !endpoint.host.hasSuffix(".localhost"),
              !endpoint.host.hasSuffix(".local") else { throw WebFetchPinnedError.nonPublicDestination }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(endpoint.connectionHost, String(endpoint.port), &hints, &results) == 0,
              let first = results else { throw WebFetchPinnedError.connectionFailed }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [WebFetchNumericAddress] = []
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            guard [AF_INET, AF_INET6].contains(entry.pointee.ai_family),
                  let address = entry.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else {
                throw WebFetchPinnedError.connectionFailed
            }
            let hostBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let numeric = try WebFetchNumericAddress(String(decoding: hostBytes, as: UTF8.self))
            // A mixed public/private answer is rejected as a whole. Selecting
            // only its public subset would hide a local destination from review.
            guard numeric.isPublic else { throw WebFetchPinnedError.nonPublicDestination }
            if !addresses.contains(numeric) { addresses.append(numeric) }
        }
        guard !addresses.isEmpty else { throw WebFetchPinnedError.connectionFailed }
        return addresses
    }
}
