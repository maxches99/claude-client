#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One reachable IPv4 address of this Mac.
public struct NetworkAddress: Equatable, Hashable, Sendable {
    public let interface: String
    public let address: String
    public init(interface: String, address: String) {
        self.interface = interface
        self.address = address
    }
}

public enum NetworkInfo {
    /// IPv4 addresses of non-loopback interfaces, Wi-Fi/Ethernet first, then VPN/Tailscale (utun).
    public static func lanAddresses() -> [NetworkAddress] {
        var result: [NetworkAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_INET else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            result.append(NetworkAddress(interface: name, address: ip))
        }
        return result.sorted { a, b in
            func rank(_ n: String) -> Int { n.hasPrefix("en") || n.hasPrefix("eth") || n.hasPrefix("wl") ? 0 : n.hasPrefix("utun") || n.hasPrefix("wg") || n.hasPrefix("tailscale") ? 1 : 2 }
            return rank(a.interface) < rank(b.interface)
        }
    }
}
#endif
