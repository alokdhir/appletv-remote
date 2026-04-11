import Foundation

/// Persists Companion pairing credentials as JSON files in Application Support.
///
/// Stored at: ~/Library/Application Support/AppleTVRemote/<deviceID>.json
/// No Keychain access required — avoids macOS password prompts for unsigned apps.
struct CredentialStore {

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

    // MARK: - Check

    func hasCredentials(for deviceID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: deviceID).path)
    }

    // MARK: - Save

    func save(credentials: PairingCredentials, for deviceID: String) {
        guard let data = try? JSONEncoder().encode(credentials) else {
            print("CredentialStore: encode failed for \(deviceID)")
            return
        }
        do {
            try data.write(to: url(for: deviceID), options: .atomic)
            print("CredentialStore: saved credentials for \(deviceID)")
        } catch {
            print("CredentialStore: save failed: \(error)")
        }
    }

    // MARK: - Load

    func load(deviceID: String) -> PairingCredentials? {
        guard let data = try? Data(contentsOf: url(for: deviceID)) else { return nil }
        return try? JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    // MARK: - Delete

    func delete(deviceID: String) {
        try? FileManager.default.removeItem(at: url(for: deviceID))
        print("CredentialStore: deleted credentials for \(deviceID)")
    }
}

/// Credentials obtained after a successful Companion pairing handshake.
struct PairingCredentials: Codable {
    let clientID: String      // UUID this client registered with
    let ltsk: Data            // Long-term secret key (Ed25519 private key bytes)
    let ltpk: Data            // Long-term public key (Ed25519 public key bytes)
    let deviceLTPK: Data      // Apple TV's long-term public key
    let deviceID: String      // Apple TV's pairing identifier
}
