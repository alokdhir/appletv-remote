import Foundation
import CryptoKit
import AppleTVLogging

/// HAP Pair Setup state machine (Steps M1–M6).
///
/// Flow:
///   M1 → (client sends)   State=1, Method=0 (no MFi)
///   M2 ← (server sends)   State=2, Salt, PublicKey
///   M3 → (client sends)   State=3, PublicKey (A), Proof (M1)
///   M4 ← (server sends)   State=4, Proof (M2)
///   M5 → (client sends)   State=5, EncryptedData (identity + signature)
///   M6 ← (server sends)   State=6, EncryptedData (Apple TV identity)
///
/// After M6 completes the pairing, credentials are available via `credentials`.
///
/// Reference: HAP specification §5.6, pyatv protocols/mrp/pairing.py
public final class HAPPairing: @unchecked Sendable {

    public enum Step: Int { case m1 = 1, m2, m3, m4, m5, m6, done }
    public enum PairingError: Error {
        case unexpectedState(UInt8)
        case serverError(UInt8)
        case serverProofMismatch
        case decryptionFailed
        case missingTLVField(String)
    }

    public private(set) var step: Step = .m1
    private var srp = SRPClient()
    private var sessionResult: SRPClient.SessionResult?
    private var encryptKey: SymmetricKey?
    private let ltKeyPair = Curve25519.Signing.PrivateKey()
    public private(set) var credentials: PairingCredentials?

    // A stable identifier for this Mac client — persisted in UserDefaults so
    // re-pairings present the same ID to the Apple TV.
    private static let clientIDKey = "com.adhir.appletv-remote.clientID"
    private let clientID: String = {
        if let saved = UserDefaults.standard.string(forKey: clientIDKey) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: clientIDKey)
        return id
    }()

    public init() {}

    // MARK: - Step generators

    /// Returns the TLV8 payload for M1 (initial client hello).
    public func m1Payload() -> Data {
        var tlv = TLV8()
        tlv.append(.method, byte: 0x00)   // 0 = Pair Setup without MFi (method before state, per pyatv)
        tlv.append(.state,  byte: UInt8(Step.m1.rawValue))
        return tlv.encode()
    }

    /// Process server's M2 response; returns TLV8 payload for M3, needs pin.
    public func processM2(_ data: Data, pin: String) throws -> Data {
        let tlv = TLV8.decode(data)
        try checkState(tlv, expected: .m2)

        guard let salt = tlv[.salt]      else { throw PairingError.missingTLVField("salt") }
        guard let bPub = tlv[.publicKey] else { throw PairingError.missingTLVField("publicKey") }

        let result = try srp.computeSession(salt: salt, serverPublicKey: bPub, pin: pin)
        sessionResult = result

        // Derive encryption key for M5 using HKDF over the SRP session key
        encryptKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: result.sessionKeyK),
            salt:             Data("Pair-Setup-Encrypt-Salt".utf8),
            info:             Data("Pair-Setup-Encrypt-Info".utf8),
            outputByteCount:  32
        )

        var tlvOut = TLV8()
        tlvOut.append(.state,     byte: UInt8(Step.m3.rawValue))
        tlvOut.append(.publicKey, srp.publicKey.toData())
        tlvOut.append(.proof,     result.clientProof)

        step = .m3
        return tlvOut.encode()
    }

    /// Process server's M4 response (server proof verification); returns TLV8 payload for M5.
    public func processM4(_ data: Data) throws -> Data {
        let tlv = TLV8.decode(data)
        try checkState(tlv, expected: .m4)

        guard let serverProof = tlv[.proof] else { throw PairingError.missingTLVField("proof") }
        guard let expected = sessionResult?.expectedServerProof else {
            throw PairingError.missingTLVField("sessionResult (M3 not completed?)")
        }
        guard serverProof == expected else { throw PairingError.serverProofMismatch }
        Log.pairing.report("HAPPairing: server proof verified ✓")

        step = .m4
        return try buildM5Payload()
    }

    /// Process server's M6 response (Apple TV identity); returns PairingCredentials on success.
    @discardableResult
    public func processM6(_ data: Data) throws -> PairingCredentials {
        let tlv = TLV8.decode(data)
        try checkState(tlv, expected: .m6)

        guard let encData = tlv[.encryptedData] else {
            throw PairingError.missingTLVField("encryptedData")
        }
        guard let key = encryptKey else { throw PairingError.decryptionFailed }

        // Decrypt: last 16 bytes are the Poly1305 auth tag (ChaChaPoly appends it)
        guard encData.count > 16 else { throw PairingError.decryptionFailed }
        let nonce = try ChaChaPoly.Nonce(data: Data.noncePadded("PS-Msg06"))
        let box   = try ChaChaPoly.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + encData)
        let plain = try ChaChaPoly.open(box, using: key)

        let inner = TLV8.decode(plain)
        guard let atv_id   = inner[.identifier] else { throw PairingError.missingTLVField("identifier") }
        guard let atv_ltpk = inner[.publicKey]  else { throw PairingError.missingTLVField("publicKey") }

        let creds = PairingCredentials(
            clientID:     clientID,
            ltsk:         ltKeyPair.rawRepresentation,
            ltpk:         Data(ltKeyPair.publicKey.rawRepresentation),
            deviceLTPK:   atv_ltpk,
            deviceID:     String(data: atv_id, encoding: .utf8) ?? atv_id.hexString
        )
        credentials = creds
        step = .done
        return creds
    }

    // MARK: - Private

    private func buildM5Payload() throws -> Data {
        guard let result = sessionResult, let key = encryptKey else {
            throw PairingError.missingTLVField("session")
        }

        // Derive signing material for our identity
        let signingKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: result.sessionKeyK),
            salt:             Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info:             Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount:  32
        )

        // iOSDeviceInfo = signingKey || clientID || iOSDeviceLTPK
        let ltpkData = Data(ltKeyPair.publicKey.rawRepresentation)
        let idData   = Data(clientID.utf8)
        let deviceInfo = signingKey.withUnsafeBytes { Data($0) } + idData + ltpkData

        // Sign with Ed25519 long-term key
        let signature = try ltKeyPair.signature(for: deviceInfo)

        // Build inner TLV8
        var inner = TLV8()
        inner.append(.identifier, idData)
        inner.append(.publicKey,  ltpkData)
        inner.append(.signature,  Data(signature))
        // Companion-specific: tag=0x11 with OPACK {"name": ...}.
        // Without this the ATV stores us in the HAP-only controller store, which the
        // Companion pair-verify service does not check → error=2 (Authentication) in M4.
        inner.append(.name, OPACK.encodeDeviceName("Mac Remote"))

        // Encrypt with ChaCha20-Poly1305, nonce = "PS-Msg05" zero-padded to 12 bytes
        let nonceData = Data.noncePadded("PS-Msg05")
        let nonce    = try ChaChaPoly.Nonce(data: nonceData)
        let innerEncoded = inner.encode()
        let sealedBox = try ChaChaPoly.seal(innerEncoded, using: key, nonce: nonce)
        // combined = nonce(12) + ciphertext + tag(16); we want ciphertext + tag
        let encPayload = sealedBox.ciphertext + sealedBox.tag

        var tlvOut = TLV8()
        tlvOut.append(.state,         byte: UInt8(Step.m5.rawValue))
        tlvOut.append(.encryptedData, encPayload)

        step = .m5
        return tlvOut.encode()
    }


    private func checkState(_ tlv: TLV8, expected: Step) throws {
        if let errByte = tlv[.error] {
            throw PairingError.serverError(errByte.first ?? 0)
        }
        guard let stateByte = tlv[.state]?.first else { return }
        guard stateByte == UInt8(expected.rawValue) else {
            throw PairingError.unexpectedState(stateByte)
        }
    }
}

// MARK: - Helpers


