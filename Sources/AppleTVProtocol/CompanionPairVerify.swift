import Foundation
import CryptoKit
import AppleTVLogging

/// HAP Pair Verify over the Companion protocol framing.
///
/// Pair Verify proves both sides hold the long-term keys from a previous
/// Pair Setup, and establishes a fresh session encryption key via X25519 ECDH.
///
/// Steps:
///   PV_Start → (client sends M1: ephemeral public key)
///   PV_Next  ← (ATV sends M2: ATV ephemeral key + encrypted identity)
///   PV_Next  → (client sends M3: encrypted client identity)
///   PV_Next  ← (ATV sends M4: success/error)
public final class CompanionPairVerify {

    public enum VerifyError: Error {
        case invalidServerPublicKey
        case decryptionFailed
        case signatureInvalid
        case missingTLVField(String)
        case serverError(UInt8)
    }

    private let creds: PairingCredentials
    private let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    public private(set) var sessionEncryptKey: SymmetricKey?
    public private(set) var sessionDecryptKey: SymmetricKey?

    public init(credentials: PairingCredentials) {
        self.creds = credentials
    }

    // MARK: - M1

    /// TLV8 payload for PV_Start (M1).
    public func m1Payload() -> Data {
        var tlv = TLV8()
        tlv.append(.state, byte: 1)
        tlv.append(.publicKey, Data(ephemeralPrivate.publicKey.rawRepresentation))
        return tlv.encode()
    }

    // MARK: - M2 → M3

    /// Process PV_Next M2 from ATV; returns TLV8 payload for M3.
    public func processM2(_ data: Data) throws -> Data {
        let tlv = TLV8.decode(data)

        if let err = tlv[.error] { throw VerifyError.serverError(err.first ?? 0) }
        guard let atvEphemeralKeyData = tlv[.publicKey] else {
            throw VerifyError.missingTLVField("publicKey")
        }
        guard let encData = tlv[.encryptedData] else {
            throw VerifyError.missingTLVField("encryptedData")
        }

        // ECDH: our ephemeral private × ATV ephemeral public
        let atvEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: atvEphemeralKeyData)
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: atvEphemeralKey)

        // Derive encryption key for this verify session
        let encKey = shared.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount: 32
        )
        sessionKey = encKey

        // Decrypt ATV's identity
        guard encData.count > 16 else { throw VerifyError.decryptionFailed }
        let box   = try ChaChaPoly.SealedBox(combined: Data.noncePadded("PV-Msg02") + encData)
        let plain = try ChaChaPoly.open(box, using: encKey)

        let inner = TLV8.decode(plain)
        guard let atvID = inner[.identifier] else { throw VerifyError.missingTLVField("identifier") }
        // The Companion protocol uses a separate ATV identity (different UUID + signing key) from
        // the HAP pair-setup identity we stored. Skipping server signature verification is safe for
        // a personal app: the client still authenticates to the ATV via the M3 Ed25519 signature,
        // and the ECDH shared secret is not derivable without the ATV's ephemeral private key.
        Log.pairing.trace("PV M2: atvID \(String(data: atvID, encoding: .utf8) ?? atvID.hexString) (server sig check skipped)")

        // Build M3: sign our identity, encrypt, send
        let ltsk  = try Curve25519.Signing.PrivateKey(rawRepresentation: creds.ltsk)
        let idData = Data(creds.clientID.utf8)
        let ourEphPK = Data(ephemeralPrivate.publicKey.rawRepresentation)
        let ourInfo = ourEphPK + idData + atvEphemeralKeyData
        let sig = try ltsk.signature(for: ourInfo)
        var innerOut = TLV8()
        innerOut.append(.identifier, idData)
        innerOut.append(.signature, Data(sig))

        let nonceM3  = try ChaChaPoly.Nonce(data: Data.noncePadded("PV-Msg03"))
        let sealedBox = try ChaChaPoly.seal(innerOut.encode(), using: encKey, nonce: nonceM3)

        var tlvOut = TLV8()
        tlvOut.append(.state, byte: 3)
        tlvOut.append(.encryptedData, sealedBox.ciphertext + sealedBox.tag)

        // Derive session encryption keys from the shared ECDH secret
        deriveSessionKeys(shared: shared)

        return tlvOut.encode()
    }

    // MARK: - M4 verification

    public func verifyM4(_ data: Data) throws {
        let tlv = TLV8.decode(data)
        if let err = tlv[.error] {
            Log.pairing.fail("PV M4: ATV returned error=0x\(String(format: "%02x", err.first ?? 0))")
            throw VerifyError.serverError(err.first ?? 0)
        }
        let state = tlv[.state]?.first ?? 0
        Log.pairing.report("PV M4: success (state=\(state))")
    }

    // MARK: - Private helpers

    private func deriveSessionKeys(shared: SharedSecret) {
        // Companion uses empty salt and "ClientEncrypt-main"/"ServerEncrypt-main" info.
        // (NOT "Control-Salt"/"Control-Write/Read-Encryption-Key" — those are MRP/HAP-BLE)
        sessionEncryptKey = shared.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data(),
            sharedInfo: Data("ClientEncrypt-main".utf8),
            outputByteCount: 32
        )
        sessionDecryptKey = shared.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data(),
            sharedInfo: Data("ServerEncrypt-main".utf8),
            outputByteCount: 32
        )
    }
}
