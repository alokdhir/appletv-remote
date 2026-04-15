import Foundation

/// Persists Apple TV MAC addresses in UserDefaults so we can send Wake-on-LAN
/// packets even when the device is asleep (and its Bonjour record may be stale).
///
/// The MAC is looked up from the OS ARP cache right after a device's IP is resolved.
/// It stays valid indefinitely — MAC addresses don't change unless hardware is replaced.
public enum MACStore {

    private static func key(for deviceID: String) -> String {
        "com.adhir.appletv-remote.mac.\(deviceID)"
    }

    public static func save(mac: String, for deviceID: String) {
        UserDefaults.standard.set(mac, forKey: key(for: deviceID))
    }

    public static func load(for deviceID: String) -> String? {
        UserDefaults.standard.string(forKey: key(for: deviceID))
    }

    // MARK: - ARP lookup

    /// Queries the OS ARP cache for the hardware address of `ip`.
    /// Returns a colon-separated lowercase MAC string, or nil if not found.
    /// Runs the system `arp` tool — call off the main thread.
    public static func lookupFromARP(ip: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ip]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        // Typical output: "? (192.168.1.50) at a1:b2:c3:d4:e5:f6 on en0 ifscope [ethernet]"
        guard let range = output.range(
            of: #"(?<=\bat\s)[0-9a-f]{1,2}(?::[0-9a-f]{1,2}){5}"#,
            options: .regularExpression
        ) else { return nil }
        return String(output[range])
    }
}
