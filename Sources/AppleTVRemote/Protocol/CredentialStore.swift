import Foundation
import Security

/// Persists MRP pairing credentials in the macOS Keychain.
///
/// After a successful pairing handshake, the Apple TV issues a unique
/// identifier and a shared secret. We store these keyed by the device's
/// Bonjour service name so that subsequent connections skip the pairing step.
struct CredentialStore {
    private let service = "com.adhir.appletv-remote"

    // MARK: - Check

    func hasCredentials(for deviceID: String) -> Bool {
        load(deviceID: deviceID) != nil
    }

    // MARK: - Save

    func save(credentials: PairingCredentials, for deviceID: String) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     deviceID,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock
        ]

        // Try update first, then add
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    // MARK: - Load

    func load(deviceID: String) -> PairingCredentials? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: deviceID,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairingCredentials.self, from: data)
    }

    // MARK: - Delete

    func delete(deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: deviceID
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Credentials obtained after a successful MRP pairing handshake.
struct PairingCredentials: Codable {
    let clientID: String      // UUID this client registered with
    let ltsk: Data            // Long-term secret key (Ed25519 private key bytes)
    let ltpk: Data            // Long-term public key (Ed25519 public key bytes)
    let deviceLTPK: Data      // Apple TV's long-term public key
    let deviceID: String      // Apple TV's pairing identifier
}
