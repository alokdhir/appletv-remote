import Foundation
import CryptoKit

/// Bidirectional ChaCha20-Poly1305 frame codec used over the AirPlay control /
/// event / data TCP sockets once pair-verify has derived per-direction keys.
///
/// Wire format (one frame = one plaintext chunk, max 1024B):
///
///     [2-byte length LE] [ciphertext] [16-byte Poly1305 tag]
///
///   - AAD is the 2-byte length header itself.
///   - Nonce is an 8-byte little-endian counter, LEFT-padded with 4 zero
///     bytes to a 12-byte ChaCha20 nonce.
///   - Counters are per-direction and never reset.
///
/// Reference: pyatv/auth/hap_session.py + pyatv/support/chacha20.py.
/// We use two counters — one for encrypt (outbound), one for decrypt (inbound)
/// — kept in sync with the peer.
public final class HAPSession: @unchecked Sendable {

    public enum FramingError: Error, CustomStringConvertible {
        case authenticationFailed
        case frameTooLarge(Int)
        case malformedFrame(String)

        public var description: String {
            switch self {
            case .authenticationFailed: return "Poly1305 tag mismatch"
            case .frameTooLarge(let n): return "frame plaintext too large: \(n)"
            case .malformedFrame(let m): return "malformed frame: \(m)"
            }
        }
    }

    /// Maximum plaintext bytes per frame — values above this are split.
    public static let maxFramePlaintext = 1024

    private let writeKey: SymmetricKey
    private let readKey:  SymmetricKey
    private var writeCounter: UInt64 = 0
    private var readCounter:  UInt64 = 0

    /// Incoming byte buffer — fed raw bytes from the socket; `decrypt()`
    /// returns whatever complete plaintext frames are now available.
    private var inbound = Data()

    public init(writeKey: Data, readKey: Data) {
        precondition(writeKey.count == 32 && readKey.count == 32,
                     "HAP session keys must be 32 bytes each")
        self.writeKey = SymmetricKey(data: writeKey)
        self.readKey  = SymmetricKey(data: readKey)
    }

    // MARK: - Nonce

    /// 8-byte counter, little-endian, LEFT-padded to 12 bytes with zeros.
    /// The left-padding is required by the HAP spec — getting endian or
    /// pad position wrong causes Poly1305 to fail silently until you
    /// cross a byte boundary, which makes it a pain to debug.
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var nonceBytes = Data(count: 12)
        var c = counter.littleEndian
        withUnsafeBytes(of: &c) { raw in
            for i in 0..<8 { nonceBytes[4 + i] = raw[i] }
        }
        // Force-unwrap is safe: 12 bytes is a valid nonce length.
        return try! ChaChaPoly.Nonce(data: nonceBytes)
    }

    // MARK: - Encrypt

    /// Encrypt `plaintext` into one or more framed ciphertext chunks.
    /// Plaintexts larger than `maxFramePlaintext` are split automatically.
    public func encrypt(_ plaintext: Data) throws -> Data {
        var remaining = plaintext
        var output = Data()
        while !remaining.isEmpty {
            let chunkLen = min(remaining.count, Self.maxFramePlaintext)
            let chunk    = remaining.prefix(chunkLen)
            remaining.removeFirst(chunkLen)

            var lengthHeader = Data(count: 2)
            lengthHeader[0] = UInt8(chunkLen & 0xFF)
            lengthHeader[1] = UInt8((chunkLen >> 8) & 0xFF)

            let sealed = try ChaChaPoly.seal(
                chunk,
                using: writeKey,
                nonce: Self.nonce(writeCounter),
                authenticating: lengthHeader
            )
            writeCounter &+= 1

            output.append(lengthHeader)
            output.append(sealed.ciphertext)
            output.append(sealed.tag)
        }
        return output
    }

    // MARK: - Decrypt

    /// Feed raw bytes from the socket. Returns every complete plaintext
    /// frame that is now decryptable; partial frames remain buffered.
    public func feed(_ bytes: Data) throws -> Data {
        inbound.append(bytes)
        var output = Data()
        while true {
            // Need at least a 2B length header.
            guard inbound.count >= 2 else { break }
            let plainLen = Int(inbound[inbound.startIndex]) |
                           (Int(inbound[inbound.startIndex + 1]) << 8)
            let frameLen = 2 + plainLen + 16 // header + ciphertext + tag
            guard inbound.count >= frameLen else { break }

            let headerEnd  = inbound.startIndex + 2
            let cipherEnd  = headerEnd + plainLen
            let tagEnd     = cipherEnd + 16
            let lengthAAD  = inbound[inbound.startIndex..<headerEnd]
            let cipher     = inbound[headerEnd..<cipherEnd]
            let tag        = inbound[cipherEnd..<tagEnd]

            let sealed: ChaChaPoly.SealedBox
            do {
                sealed = try ChaChaPoly.SealedBox(
                    nonce:      Self.nonce(readCounter),
                    ciphertext: cipher,
                    tag:        tag
                )
            } catch {
                throw FramingError.malformedFrame("seal construct: \(error)")
            }
            let plain: Data
            do {
                plain = try ChaChaPoly.open(
                    sealed,
                    using: readKey,
                    authenticating: Data(lengthAAD)
                )
            } catch {
                throw FramingError.authenticationFailed
            }
            readCounter &+= 1
            output.append(plain)

            // Advance by rebuilding (Foundation Data leaves non-zero
            // startIndex after removeFirst — same gotcha that bit
            // AirPlayHTTP).
            inbound = Data(inbound[tagEnd...])
        }
        return output
    }
}
