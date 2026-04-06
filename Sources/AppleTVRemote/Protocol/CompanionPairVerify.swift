import Foundation
import CryptoKit

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
final class CompanionPairVerify {

    enum VerifyError: Error {
        case invalidServerPublicKey
        case decryptionFailed
        case signatureInvalid
        case missingTLVField(String)
        case serverError(UInt8)
    }

    private let creds: PairingCredentials
    private let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    private(set) var sessionEncryptKey: SymmetricKey?
    private(set) var sessionDecryptKey: SymmetricKey?

    init(credentials: PairingCredentials) {
        self.creds = credentials
    }

    // MARK: - M1

    /// TLV8 payload for PV_Start (M1).
    func m1Payload() -> Data {
        var tlv = TLV8()
        tlv.append(.state, byte: 1)
        tlv.append(.publicKey, Data(ephemeralPrivate.publicKey.rawRepresentation))
        return tlv.encode()
    }

    // MARK: - M2 → M3

    /// Process PV_Next M2 from ATV; returns TLV8 payload for M3.
    func processM2(_ data: Data) throws -> Data {
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
        let nonce = try ChaChaPoly.Nonce(data: noncePadded("PV-Msg02"))
        guard encData.count > 16 else { throw VerifyError.decryptionFailed }
        let box   = try ChaChaPoly.SealedBox(combined: nonceBytes("PV-Msg02") + encData)
        let plain = try ChaChaPoly.open(box, using: encKey)

        let inner = TLV8.decode(plain)
        guard let atvID  = inner[.identifier] else { throw VerifyError.missingTLVField("identifier") }
        guard let atvSig = inner[.signature]  else { throw VerifyError.missingTLVField("signature") }

        // Verify ATV's signature: sign(atvEphemeralKey || atvID || ourEphemeralKey)
        let atvInfo = atvEphemeralKeyData + atvID + Data(ephemeralPrivate.publicKey.rawRepresentation)
        let atvLTPK = try Curve25519.Signing.PublicKey(rawRepresentation: creds.deviceLTPK)
        guard (try? atvLTPK.isValidSignature(atvSig, for: atvInfo)) == true else {
            throw VerifyError.signatureInvalid
        }

        // Build M3: sign our identity, encrypt, send
        let ltsk  = try Curve25519.Signing.PrivateKey(rawRepresentation: creds.ltsk)
        let idData = Data(creds.clientID.utf8)
        let ourInfo = Data(ephemeralPrivate.publicKey.rawRepresentation) + idData + atvEphemeralKeyData
        let sig = try ltsk.signature(for: ourInfo)

        var innerOut = TLV8()
        innerOut.append(.identifier, idData)
        innerOut.append(.signature, Data(sig))

        let nonceM3  = try ChaChaPoly.Nonce(data: noncePadded("PV-Msg03"))
        let sealedBox = try ChaChaPoly.seal(innerOut.encode(), using: encKey, nonce: nonceM3)

        var tlvOut = TLV8()
        tlvOut.append(.state, byte: 3)
        tlvOut.append(.encryptedData, sealedBox.ciphertext + sealedBox.tag)

        // Derive session encryption keys from the shared ECDH secret
        deriveSessionKeys(shared: shared)

        return tlvOut.encode()
    }

    // MARK: - M4 verification

    func verifyM4(_ data: Data) throws {
        let tlv = TLV8.decode(data)
        if let err = tlv[.error] { throw VerifyError.serverError(err.first ?? 0) }
        // State=4 with no error means success
    }

    // MARK: - Private helpers

    private func deriveSessionKeys(shared: SharedSecret) {
        sessionEncryptKey = shared.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Control-Salt".utf8),
            sharedInfo: Data("Control-Write-Encryption-Key".utf8),
            outputByteCount: 32
        )
        sessionDecryptKey = shared.hkdfDerivedSymmetricKey(
            using: SHA512.self,
            salt: Data("Control-Salt".utf8),
            sharedInfo: Data("Control-Read-Encryption-Key".utf8),
            outputByteCount: 32
        )
    }

    private func noncePadded(_ string: String) throws -> Data {
        let bytes = Data(string.utf8)
        precondition(bytes.count <= 12)
        return Data(repeating: 0, count: 12 - bytes.count) + bytes
    }

    private func nonceBytes(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return Data(repeating: 0, count: 12 - bytes.count) + bytes
    }
}
