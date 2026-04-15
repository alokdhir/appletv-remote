import Foundation
import Darwin

/// Sends Wake-on-LAN magic packets over UDP.
///
/// The magic packet is the de-facto WoL standard:
///   6 × 0xFF  followed by  the target MAC address repeated 16 times (102 bytes total).
/// It is sent to the limited broadcast address 255.255.255.255 on port 9,
/// and also directly to the device's last known IP (port 9) as a unicast fallback
/// for networks that block limited broadcast.
///
/// Call off the main thread — this blocks briefly on the sendto syscall.
public enum WakeOnLAN {

    public enum WoLError: LocalizedError {
        case invalidMAC(String)
        case socketFailed(errno: Int32)
        case sendFailed(errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidMAC(let m):    return "Invalid MAC address: '\(m)'"
            case .socketFailed(let e):  return "Socket creation failed (errno \(e))"
            case .sendFailed(let e):    return "Send failed (errno \(e))"
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

        // Send to one or two destinations
        var destinations = ["255.255.255.255"]
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
