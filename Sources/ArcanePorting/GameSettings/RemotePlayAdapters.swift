import Darwin

public struct RemotePlayAdapters: Equatable {
    public let zeroTier: Int
    public let other: Int
    public var isAmbiguous: Bool { zeroTier + other > 1 }

    public init(zeroTier: Int = 0, other: Int = 0) {
        self.zeroTier = zeroTier
        self.other = other
    }

    public static func current() -> Self {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return Self() }
        defer { freeifaddrs(list) }
        let control = socket(AF_INET, SOCK_DGRAM, 0)
        defer { if control >= 0 { close(control) } }
        var zeroTier = 0
        var other = 0
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP) else { continue }
            let ipv4 = UInt32(bigEndian: UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
            guard ipv4 != 0, ipv4 >> 16 != 0xa9fe,
                  isVPNCandidate(entry.ifa_name, control: control) else { continue }
            // shortcut: feth identifies ZeroTier heuristically; use provider identity if macOS exposes it.
            if String(cString: entry.ifa_name).hasPrefix("feth") { zeroTier += 1 }
            else { other += 1 }
        }
        return Self(zeroTier: zeroTier, other: other)
    }

    // Match nxnative's physical interface exclusions, including tunnels not named utun.
    private static func isVPNCandidate(_ name: UnsafePointer<CChar>, control: Int32) -> Bool {
        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { bytes in
            _ = strlcpy(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), name, bytes.count)
        }
        // SIOCGIFFUNCTIONALTYPE is _IOWR('i', 173, struct ifreq) in sys/sockio.h, not imported by Swift.
        let operation = UInt(IOC_INOUT) | (UInt(MemoryLayout<ifreq>.size) << 16) | (UInt(105) << 8) | 173
        guard control >= 0, ioctl(control, operation, &request) == 0 else { return true }
        switch Int32(request.ifr_ifru.ifru_functional_type) {
        case IFRTYPE_FUNCTIONAL_LOOPBACK, IFRTYPE_FUNCTIONAL_WIRED, IFRTYPE_FUNCTIONAL_WIFI_INFRA,
             IFRTYPE_FUNCTIONAL_WIFI_AWDL, IFRTYPE_FUNCTIONAL_CELLULAR, IFRTYPE_FUNCTIONAL_INTCOPROC,
             IFRTYPE_FUNCTIONAL_COMPANIONLINK:
            return false
        default:
            return true
        }
    }
}
