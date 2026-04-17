import Foundation
import Darwin
import SystemConfiguration
import AppleTVLogging

/// Binds outbound sockets to the system's primary network interface before
/// `connect()` / `sendto()` so kernel-level source-interface selection is
/// deterministic.
///
/// **Why this exists.** On Macs with more than one interface on the same
/// subnet (Wi-Fi + Ethernet both on 192.168.1.0/24) or with VPN tunnels up
/// (Tailscale, corp VPN), a BSD socket opened with no binding can land on
/// the "wrong" NIC during `connect()` and return EHOSTUNREACH — even when
/// `route get <target>` would pick a working interface. Binding the socket
/// to the primary interface via `IP_BOUND_IF` forces the kernel down the
/// same path `route get` uses, which matches what `/sbin/ping` does
/// and what the user expects.
///
/// "Primary" is the first-ordered service in System Settings → Network,
/// read from `SCDynamicStore`'s `State:/Network/Global/IPv4` key. This is
/// the same value used by `route get` as its scope hint and by
/// `CFNetwork` for its default source-address selection.
public enum PrimaryInterface {

    /// The kernel's primary IPv4 interface name (e.g. "en0"), or `nil` if
    /// no default IPv4 route is configured.
    public static func name() -> String? {
        guard let store = SCDynamicStoreCreate(nil,
                                               "com.adhir.appletv-remote.primary-iface" as CFString,
                                               nil, nil),
              let dict  = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                            as? [String: Any],
              let name  = dict["PrimaryInterface"] as? String
        else { return nil }
        return name
    }

    /// `if_nametoindex` of the primary interface, or `nil` if unavailable.
    public static func index() -> UInt32? {
        guard let name = name() else { return nil }
        let idx = if_nametoindex(name)
        return idx > 0 ? idx : nil
    }

    /// The IPv4 broadcast address of `interfaceName` (e.g. `192.168.1.255` for
    /// a 192.168.1.x/24 interface), or `nil`.
    ///
    /// Using the *directed* broadcast rather than the limited broadcast
    /// (255.255.255.255) avoids a macOS routing ambiguity on machines with
    /// multiple NICs on the same subnet: the directed broadcast is resolved
    /// unambiguously through the named interface's subnet route.
    public static func broadcastAddress(of interfaceName: String) -> in_addr? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var cur = ifap
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let n = String(cString: p.pointee.ifa_name)
            guard n == interfaceName,
                  let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET),
                  Int32(p.pointee.ifa_flags) & IFF_BROADCAST != 0,
                  let bsa = p.pointee.ifa_dstaddr,
                  bsa.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            return bsa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        return nil
    }

    /// The IPv4 address of `interfaceName` as an `in_addr`, or `nil`.
    public static func ipv4Address(of interfaceName: String) -> in_addr? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var cur = ifap
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let n = String(cString: p.pointee.ifa_name)
            guard n == interfaceName,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        return nil
    }

    /// Bind the socket to the primary interface's IPv4 address via `bind(2)`,
    /// which forces source-address selection to that IP. This is the
    /// traditional pattern for UDP broadcast — some macOS code paths route
    /// broadcast through source-address lookup (not the output-interface
    /// hint set by `IP_BOUND_IF`), so `IP_BOUND_IF` alone isn't enough to
    /// stop EHOSTUNREACH when multiple NICs share a subnet.
    ///
    /// Returns the interface name on success, `nil` on failure.
    @discardableResult
    public static func bindSourceAddress(fd: Int32, logHost: String? = nil) -> String? {
        guard fd >= 0,
              let name = name(),
              let addr = ipv4Address(of: name)
        else { return nil }

        var sin = sockaddr_in()
        sin.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr   = addr
        sin.sin_port   = 0

        let rc = withUnsafePointer(to: sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            Log.companion.fail("bind(\(name)) failed: \(String(cString: strerror(errno)))")
            return nil
        }
        if let host = logHost {
            let ipStr = String(cString: inet_ntoa(addr))
            Log.companion.report("Bound source IP \(ipStr) (\(name)) for \(host)")
        }
        return name
    }

    /// Bind `fd` to the primary interface via `IP_BOUND_IF`. Silently no-ops
    /// if the primary interface can't be determined — the caller then falls
    /// through to the kernel's default source selection, which is usually
    /// correct in single-NIC setups.
    ///
    /// Logs which interface was bound (at trace level) on the first call per
    /// remote host so diagnostics show which NIC outbound traffic took.
    @discardableResult
    public static func bind(fd: Int32, logHost: String? = nil) -> String? {
        guard fd >= 0, let name = name() else { return nil }
        let idx = if_nametoindex(name)
        guard idx > 0 else { return nil }
        var idxVal = idx
        let rc = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idxVal,
                            socklen_t(MemoryLayout<UInt32>.size))
        if rc != 0 {
            Log.companion.fail("IP_BOUND_IF(\(name)) failed: \(String(cString: strerror(errno)))")
            return nil
        }
        if let host = logHost {
            Log.companion.report("Bound socket to \(name) (idx=\(idx)) for \(host)")
        }
        return name
    }
}
