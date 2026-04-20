import Foundation
import AppleTVLogging

/// Persists Companion pairing credentials as JSON files in Application Support.
///
/// Stored at: ~/Library/Application Support/AppleTVRemote/<deviceID>.json
/// No Keychain access required — avoids macOS password prompts for unsigned apps.
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
        do {
            try data.write(to: url(for: deviceID), options: .atomic)
            Log.credentials.report("CredentialStore: saved credentials for \(deviceID)")
        } catch {
            Log.credentials.fail("CredentialStore: save failed: \(error)")
        }
    }

    // MARK: - Load

    public func load(deviceID: String) -> PairingCredentials? {
        guard let data = try? Data(contentsOf: url(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    // MARK: - Delete

    public func delete(deviceID: String) {
        try? FileManager.default.removeItem(at: url(for: deviceID))
        Log.credentials.report("CredentialStore: deleted credentials for \(deviceID)")
    }

    // MARK: - AirPlay

    public func saveAirPlay(_ credentials: AirPlayCredentials, for deviceID: String) {
        guard let data = try? JSONEncoder().encode(credentials) else {
            Log.credentials.fail("CredentialStore: airplay encode failed for \(deviceID)")
            return
        }
        do {
            try data.write(to: airPlayURL(for: deviceID), options: .atomic)
            Log.credentials.report("CredentialStore: saved airplay credentials for \(deviceID)")
        } catch {
            Log.credentials.fail("CredentialStore: airplay save failed: \(error)")
        }
    }

    public func loadAirPlay(deviceID: String) -> AirPlayCredentials? {
        guard let data = try? Data(contentsOf: airPlayURL(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(AirPlayCredentials.self, from: data)
    }

    public func deleteAirPlay(deviceID: String) {
        try? FileManager.default.removeItem(at: airPlayURL(for: deviceID))
        Log.credentials.report("CredentialStore: deleted airplay credentials for \(deviceID)")
    }
}

/// Credentials obtained after a successful Companion pairing handshake.
public struct PairingCredentials: Codable {
    public let clientID: String      // UUID this client registered with
    public let ltsk: Data            // Long-term secret key (Ed25519 private key bytes)
    public let ltpk: Data            // Long-term public key (Ed25519 public key bytes)
    public let deviceLTPK: Data      // Apple TV's long-term public key
    public let deviceID: String      // Apple TV's pairing identifier

    public init(clientID: String, ltsk: Data, ltpk: Data, deviceLTPK: Data, deviceID: String) {
        self.clientID = clientID
        self.ltsk = ltsk
        self.ltpk = ltpk
        self.deviceLTPK = deviceLTPK
        self.deviceID = deviceID
    }
}
