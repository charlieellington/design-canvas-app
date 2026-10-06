// Probes localhost on a given port for any TCP listener.
// Tries IPv4 (127.0.0.1) first, then IPv6 (::1) as a fallback.
// Vite 6+ binds to [::1] only on macOS, so an IPv4-only probe misses it entirely.

import Foundation
import Darwin

/// Returns `true` if a TCP listener responds on either 127.0.0.1:port or [::1]:port.
/// Used by `PortScanner` and `DevServerManager` — produces zero console noise on connection refused.
func probeLocalhost(port: Int) async -> Bool {
    if await probeLoopbackIPv4(port: port) { return true }
    return await probeLoopbackIPv6(port: port)
}

private func probeLoopbackIPv4(port: Int) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                continuation.resume(returning: false)
                return
            }
            defer { Darwin.close(sock) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            continuation.resume(returning: result == 0)
        }
    }
}

private func probeLoopbackIPv6(port: Int) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let sock = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
            guard sock >= 0 else {
                continuation.resume(returning: false)
                return
            }
            defer { Darwin.close(sock) }

            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            // ::1 — IPv6 loopback. inet_pton is portable across SDK versions.
            _ = "::1".withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            continuation.resume(returning: result == 0)
        }
    }
}
