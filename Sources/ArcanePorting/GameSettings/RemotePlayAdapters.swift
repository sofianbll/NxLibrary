import Darwin

public struct RemotePlayAdapters: Equatable {
    public private(set) var zeroTier: Set<String> = []

    public init() {}

    mutating func consider(_ name: String, flags: UInt32, ipv4: UInt32) {
        guard flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP),
              ipv4 != 0, ipv4 >> 16 != 0xa9fe else { return }
        // shortcut: feth/zt identify ZeroTier by name even when macOS reports it as wired; use provider identity if available.
        if name.hasPrefix("feth") || name.hasPrefix("zt") { zeroTier.insert(name) }
    }

    public static func current() -> Self {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return Self() }
        defer { freeifaddrs(list) }
        var adapters = Self()
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            let ipv4 = UInt32(bigEndian: UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
            adapters.consider(String(cString: entry.ifa_name), flags: entry.ifa_flags, ipv4: ipv4)
        }
        return adapters
    }
}
