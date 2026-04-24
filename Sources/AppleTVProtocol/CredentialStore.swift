import Foundation
import AppleTVLogging

/// Persists Companion pairing credentials as JSON files in Application Support.
///
/// Stored at: ~/Library/Application Support/AppleTVRemote/<deviceID>.json
/// No Keychain access required — avoids macOS password prompts for unsigned apps.
///
/// Concurrent access (app + atv CLI) is serialised with per-file advisory locks
/// (flock(2) on a companion .lock file). Reads acquire a shared lock; writes
/// acquire an exclusive lock. Lock files are never deleted so their fd stays valid.
public struct CredentialStore {

    public init() {}

    private static let appDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppleTVRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }()

    private func url(for deviceID: String) -> URL {
        let safe = deviceID.replacingOccurrences(of: "/", with: "_")
        return Self.appDir.appendingPathComponent("\(safe).json")
    }

    private func airPlayURL(for deviceID: String) -> URL {
        let safe = deviceID.replacingOccurrences(of: "/", with: "_")
        return Self.appDir.appendingPathComponent("\(safe).airplay.json")
    }

    private func lockURL(for path: String) -> URL {
        Self.appDir.appendingPathComponent(
            (URL(fileURLWithPath: path).lastPathComponent) + ".lock")
    }

    // MARK: - File locking

    /// Execute `body` under an exclusive (write) flock on `path`.
    private func withExclusiveLock<T>(on path: String, body: () throws -> T) rethrows -> T {
        let lockPath = lockURL(for: path).path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 { flock(fd, LOCK_EX) }
        return try body()
    }

    // MARK: - Check

    public func hasCredentials(for deviceID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: deviceID).path)
    }

    public func hasAirPlayCredentials(for deviceID: String) -> Bool {
        FileManager.default.fileExists(atPath: airPlayURL(for: deviceID).path)
    }

    // MARK: - Save

    public func save(credentials: PairingCredentials, for deviceID: String) {
        guard let data = try? JSONEncoder().encode(credentials) else {
            Log.credentials.fail("CredentialStore: encode failed for \(deviceID)")
            return
        }
        let path = url(for: deviceID).path
        withExclusiveLock(on: path) {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                Log.credentials.report("CredentialStore: saved credentials for \(deviceID)")
            } catch {
                Log.credentials.fail("CredentialStore: save failed: \(error)")
            }
        }
    }

    // MARK: - Load

    public func load(deviceID: String) -> PairingCredentials? {
        guard let data = try? Data(contentsOf: url(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    // MARK: - Delete

    public func delete(deviceID: String) {
        let path = url(for: deviceID).path
        withExclusiveLock(on: path) {
            try? FileManager.default.removeItem(atPath: path)
            Log.credentials.report("CredentialStore: deleted credentials for \(deviceID)")
        }
    }

    // MARK: - AirPlay

    public func saveAirPlay(_ credentials: AirPlayCredentials, for deviceID: String) {
        guard let data = try? JSONEncoder().encode(credentials) else {
            Log.credentials.fail("CredentialStore: airplay encode failed for \(deviceID)")
            return
        }
        let path = airPlayURL(for: deviceID).path
        withExclusiveLock(on: path) {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                Log.credentials.report("CredentialStore: saved airplay credentials for \(deviceID)")
            } catch {
                Log.credentials.fail("CredentialStore: airplay save failed: \(error)")
            }
        }
    }

    public func loadAirPlay(deviceID: String) -> AirPlayCredentials? {
        guard let data = try? Data(contentsOf: airPlayURL(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(AirPlayCredentials.self, from: data)
    }

    public func deleteAirPlay(deviceID: String) {
        let path = airPlayURL(for: deviceID).path
        withExclusiveLock(on: path) {
            try? FileManager.default.removeItem(atPath: path)
            Log.credentials.report("CredentialStore: deleted airplay credentials for \(deviceID)")
        }
    }
}

/// Credentials obtained after a successful Companion pairing handshake.
public struct PairingCredentials: Codable {
    public let clientID: String      // UUID this client registered with
    public let ltsk: Data            // Long-term secret key (Ed25519 private key bytes)
    public let ltpk: Data            // Long-term public key (Ed25519 public key bytes)
    public let deviceLTPK: Data      // Apple TV's long-term public key
    public let deviceID: String      // Apple TV's pairing identifier
    /// Random 6-byte hex string sent as `_i` in `_systemInfo` (pyatv's `rp_id`).
    /// Generated once at pair-setup time and stable per device.
    public let rpID: String
    /// Name sent in HAP pair-setup M5 tag=0x11 and `_systemInfo` `name` field.
    /// Must match what was used at pair-setup time.
    public let name: String

    public init(clientID: String, ltsk: Data, ltpk: Data, deviceLTPK: Data, deviceID: String,
                rpID: String? = nil, name: String = "Mac Remote") {
        self.clientID = clientID
        self.ltsk = ltsk
        self.ltpk = ltpk
        self.deviceLTPK = deviceLTPK
        self.deviceID = deviceID
        self.rpID = rpID ?? PairingCredentials.newRpID()
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID   = try c.decode(String.self, forKey: .clientID)
        ltsk       = try c.decode(Data.self,   forKey: .ltsk)
        ltpk       = try c.decode(Data.self,   forKey: .ltpk)
        deviceLTPK = try c.decode(Data.self,   forKey: .deviceLTPK)
        deviceID   = try c.decode(String.self, forKey: .deviceID)
        rpID       = (try? c.decode(String.self, forKey: .rpID)) ?? PairingCredentials.newRpID()
        name       = (try? c.decode(String.self, forKey: .name)) ?? "Mac Remote"
    }

    private static func newRpID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
