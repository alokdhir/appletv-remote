import Foundation

// MARK: - Shared crypto utilities for the AppleTVProtocol layer

extension Data {
    /// Returns a 12-byte ChaCha20-Poly1305 nonce: the UTF-8 bytes of `string`
    /// zero-padded on the left to exactly 12 bytes.
    ///
    /// Used by HAP pairing, AirPlay pairing, and Companion pair-verify to
    /// construct per-message nonces ("PS-Msg05", "PV-Msg02", etc.).
    static func noncePadded(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        precondition(bytes.count <= 12, "nonce string too long: \(string)")
        return Data(repeating: 0, count: 12 - bytes.count) + bytes
    }

    /// Lowercase hex string with no separators, e.g. "deadbeef".
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Constant-time equality. Use when comparing authentication tags, proofs,
    /// or any other byte string where leaking a matching-prefix length via early
    /// `==` short-circuit could aid an attacker. Length is allowed to leak.
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self, other) {
            diff |= a ^ b
        }
        return diff == 0
    }
}
