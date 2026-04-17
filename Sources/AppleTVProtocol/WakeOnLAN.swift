import Foundation
import Darwin
import AppleTVLogging

/// Sends Wake-on-LAN magic packets over UDP.
///
/// The magic packet is the de-facto WoL standard:
///   6 × 0xFF  followed by  the target MAC address repeated 16 times (102 bytes total).
///
/// Packet destinations (in order):
///   1. Directed broadcast  — e.g. 192.168.1.255 (derived from primary interface)
///   2. Limited broadcast   — 255.255.255.255 (fallback)
///   3. Unicast to targetIP — reaches the device when broadcast is blocked by the router
///
/// The directed broadcast is preferred over the limited broadcast because macOS
/// resolves it unambiguously through the interface's own subnet route even when
/// multiple NICs share the same subnet. The limited broadcast is kept as a
/// belt-and-suspenders fallback.
///
/// Call off the main thread — this blocks briefly on the sendto syscall.
public enum WakeOnLAN {

    public enum WoLError: LocalizedError {
        case invalidMAC(String)
        case socketFailed(errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidMAC(let m):    return "Invalid MAC address: '\(m)'"
            case .socketFailed(let e):  return "Socket creation failed (errno \(e))"
            }
        }
    }

    /// Send a WoL magic packet for `mac` (colon-separated hex, e.g. "a1:b2:c3:d4:e5:f6").
    /// Pass `targetIP` to also send a unicast copy to the device's last known address.
    public static func send(mac: String, targetIP: String? = nil) throws {
        // Normalise and parse MAC
        let norm    = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        let octets  = norm.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard octets.count == 6 else { throw WoLError.invalidMAC(mac) }

        // Build magic packet: FF FF FF FF FF FF + MAC × 16
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: octets) }

        // Open UDP socket
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw WoLError.socketFailed(errno: errno) }
        defer { Darwin.close(sock) }

        // Enable broadcast
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        // Pin to the primary interface (en0 on most Macs). IP_BOUND_IF is enough
        // here — we intentionally do NOT also call bind(2) to a specific source IP
        // because combining bind(2) with SO_BROADCAST can confuse macOS's broadcast
        // routing when multiple NICs share the same subnet.
        PrimaryInterface.bind(fd: sock, logHost: targetIP)

        // Build the destination list:
        //   • directed broadcast (e.g. 192.168.1.255) — preferred; no routing ambiguity
        //   • limited broadcast  (255.255.255.255)    — fallback
        //   • unicast            (targetIP)            — for routers that block broadcast
        var destinations: [String] = []
        if let name = PrimaryInterface.name(),
           let bcast = PrimaryInterface.broadcastAddress(of: name) {
            destinations.append(String(cString: inet_ntoa(bcast)))
        }
        destinations.append("255.255.255.255")
        if let ip = targetIP { destinations.append(ip) }

        for dest in destinations {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port   = in_port_t(9).bigEndian
            inet_pton(AF_INET, dest, &addr.sin_addr)

            let n = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(sock, raw.baseAddress!, raw.count, 0,
                                      $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n < 0 {
                Log.wol.fail("WoL: sendto \(dest) failed errno \(errno)")
            } else {
                Log.wol.report("WoL: sent \(n)-byte magic packet → \(dest) for MAC \(mac)")
            }
        }
    }
}
