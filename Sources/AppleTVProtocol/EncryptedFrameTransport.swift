import Foundation
import CryptoKit

/// ChaCha20-Poly1305 sealing/opening for E_OPACK frames over the Companion link.
///
/// Owns the directional ChaCha20 keys (one for sending, one for receiving) and
/// their nonce counters. Knows nothing about sockets or feature messages — just
/// turns plaintext into authenticated ciphertext (and back).
///
/// Caller responsibilities:
///   1. After pair-verify completes, call `installSessionKeys(encrypt:decrypt:)`
///      with the keys derived from the verify session.
///   2. To send an E_OPACK frame: `seal(plaintext)` → wrap the bytes in a
///      `CompanionFrame(.eOPACK, payload:)` and write to the socket.
///   3. To receive: read a `CompanionFrame`, pass its payload to `open(_:)`.
///   4. On disconnect (or fresh connect attempt): `reset()` zeroes nonces and
///      drops keys.
///
/// `@MainActor` so the keys + nonce counters share the rest of the connection's
/// isolation domain. Encrypt/decrypt themselves are pure — they could run off-
/// main if needed, but doing so would create a race with `installSessionKeys`
/// and `reset`, so we keep everything on main like the rest of the connection.
@MainActor
public final class EncryptedFrameTransport {
    private var encryptKey: SymmetricKey?
    private var decryptKey: SymmetricKey?
    private var sendNonce:  UInt64 = 0
    private var recvNonce:  UInt64 = 0

    public init() {}
    /// True once both directional keys have been installed via `installSessionKeys`.
    public var isReady: Bool { encryptKey != nil && decryptKey != nil }

    /// Adopt the directional session keys produced by pair-verify and reset
    /// the nonce counters to zero. Called once, immediately after the verify
    /// M4 step succeeds.
    public func installSessionKeys(encrypt: SymmetricKey, decrypt: SymmetricKey) {
        encryptKey = encrypt
        decryptKey = decrypt
        sendNonce = 0
        recvNonce = 0
    }

    /// Drop the keys and zero the nonce counters. Idempotent. Called from
    /// the connection's disconnect / cleanup path.
    public func reset() {
        encryptKey = nil
        decryptKey = nil
        sendNonce = 0
        recvNonce = 0
    }

    /// Zero just the nonce counters — used when starting a new connection
    /// attempt before keys are installed. Leaves any stale keys cleared
    /// only via `reset()`.
    public func resetNonces() {
        sendNonce = 0
        recvNonce = 0
    }

    /// Encrypt + authenticate `plaintext` for transmission as the body of an
    /// E_OPACK frame. Returns ciphertext concatenated with the 16-byte
    /// Poly1305 tag — wrap in `CompanionFrame(.eOPACK, payload:)`.
    ///
    /// AAD = the frame header that *will* be on the wire: type byte + 3-byte
    /// big-endian payload length, where payload length = `plaintext.count + 16`
    /// (ciphertext + tag). The peer reconstructs the same AAD when decrypting.
    public func seal(_ plaintext: Data) throws -> Data {
        guard let key = encryptKey else { throw TransportError.notReady }
        let nonce = try ChaChaPoly.Nonce(data: nonceData(sendNonce))
        sendNonce += 1
        let payloadLen = plaintext.count + 16
        let aad = aadHeader(payloadLength: payloadLen)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    /// Decrypt + authenticate the body of a received E_OPACK frame. Returns
    /// the plaintext OPACK bytes. AAD is reconstructed from the on-wire
    /// header: type byte + 3-byte big-endian length where length is the
    /// payload size as observed on the wire (already includes the tag).
    public func open(_ payload: Data) throws -> Data {
        guard let key = decryptKey else { throw TransportError.notReady }
        let nonce = try ChaChaPoly.Nonce(data: nonceData(recvNonce))
        recvNonce += 1
        let aad = aadHeader(payloadLength: payload.count)
        let box = try ChaChaPoly.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + payload)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    // MARK: - Helpers

    /// 12-byte ChaCha20 nonce: counter serialised little-endian into bytes 0–7,
    /// bytes 8–11 zero-padded. Matches pyatv's `Chacha20Cipher(nonce_length=12)`
    /// (`counter.to_bytes(12, "little")`).
    private func nonceData(_ counter: UInt64) -> Data {
        var n = counter.littleEndian
        return Data(bytes: &n, count: 8) + Data(repeating: 0, count: 4)
    }

    /// Frame-header bytes used as additional authenticated data: type byte
    /// followed by 3-byte big-endian payload length.
    private func aadHeader(payloadLength: Int) -> Data {
        Data([
            CompanionFrame.FrameType.eOPACK.rawValue,
            UInt8((payloadLength >> 16) & 0xFF),
            UInt8((payloadLength >>  8) & 0xFF),
            UInt8( payloadLength        & 0xFF),
        ])
    }

    public enum TransportError: Error {
        /// `seal` or `open` was called before `installSessionKeys` ran.
        case notReady
    }
}
