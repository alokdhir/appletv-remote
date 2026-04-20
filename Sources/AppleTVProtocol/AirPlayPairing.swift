import Foundation
import CryptoKit
import AppleTVLogging

// AirPlay pair-setup and pair-verify, wrapping our existing SRPClient + TLV8
// + CryptoKit primitives. Deliberately kept separate from `HAPPairing` (which
// bakes in Companion-specific TLV fields like `.name` OPACK) so we don't risk
// regressing the working Companion flow.
//
// Wire protocol is plain HTTP/1.1 on port 7000 — see `AirPlayHTTP`.
//
// References (byte-for-byte):
//   pyatv/protocols/airplay/auth/hap.py      — HTTP plumbing
//   pyatv/auth/hap_srp.py                    — SRP + Ed25519/Curve25519 steps
// The salts and info strings below MUST match pyatv exactly or key derivation
// diverges and the ATV rejects our traffic.

// MARK: - Credentials

/// AirPlay HAP credentials. Persisted per-device alongside Companion creds.
///
/// Field semantics match pyatv's `HapCredentials` exactly so the wire format
/// is interoperable and we can sanity-check against `atvremote` output:
///   ltpk     — the ATV's long-term public key   (verify its signatures)
///   ltsk     — OUR Ed25519 private key (32B raw) (sign our payloads)
///   atvID    — ATV's pairing identifier bytes   (ASCII UUID on real devices)
///   clientID — our pairing identifier bytes     (ASCII UUID we generated)
public struct AirPlayCredentials: Codable, Sendable {
    public let ltpk:      Data
    public let ltsk:      Data
    public let atvID:     Data
    public let clientID:  Data

    public init(ltpk: Data, ltsk: Data, atvID: Data, clientID: Data) {
        self.ltpk = ltpk; self.ltsk = ltsk; self.atvID = atvID; self.clientID = clientID
    }

    /// Encode as pyatv-style `hex:hex:hex:hex` for inspection / debugging.
    public var pyatvString: String {
        [ltpk, ltsk, atvID, clientID].map { $0.map { String(format: "%02x", $0) }.joined() }
            .joined(separator: ":")
    }

    /// Decode a pyatv-style credentials string.
    public static func fromPyatvString(_ s: String) -> AirPlayCredentials? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 4 else { return nil }
        func hex(_ h: String) -> Data? {
            guard h.count % 2 == 0 else { return nil }
            var out = Data(); out.reserveCapacity(h.count / 2)
            var i = h.startIndex
            while i < h.endIndex {
                let j = h.index(i, offsetBy: 2)
                guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
                out.append(b); i = j
            }
            return out
        }
        guard let a = hex(parts[0]), let b = hex(parts[1]),
              let c = hex(parts[2]), let d = hex(parts[3]) else { return nil }
        return AirPlayCredentials(ltpk: a, ltsk: b, atvID: c, clientID: d)
    }
}

// MARK: - Session keys

/// Session keys derived after a successful pair-verify. These keys are used
/// to encrypt all subsequent traffic on the same TCP connection.
public struct AirPlaySessionKeys: Sendable {
    public let readKey:  Data   // "Control-Read-Encryption-Key"  — decrypt ATV→us
    public let writeKey: Data   // "Control-Write-Encryption-Key" — encrypt us→ATV
}

// MARK: - Pair Setup

/// Drives AirPlay pair-setup over an `AirPlayHTTP` connection.
///
/// Typical use (interactive; caller prompts for PIN between `beginPairing`
/// and `completePairing`):
///
///     let http = AirPlayHTTP(host: ip, port: 7000)
///     try http.connect()
///     let pair = AirPlayPairSetup(http: http)
///     try pair.beginPairing()           // TV shows a PIN
///     let creds = try pair.completePairing(pin: "1234")
///     CredentialStore().saveAirPlay(creds, for: deviceID)
public final class AirPlayPairSetup {

    public enum PairError: Error, CustomStringConvertible {
        case httpStatus(Int, Data)
        case missingTLV(String)
        case serverError(UInt8)
        case cryptoFailed(String)

        public var description: String {
            switch self {
            case .httpStatus(let c, let b):
                return "HTTP \(c): \(String(data: b, encoding: .utf8) ?? "<\(b.count)B>")"
            case .missingTLV(let f):   return "missing TLV field: \(f)"
            case .serverError(let e):  return "server reported error=\(e)"
            case .cryptoFailed(let m): return "crypto failed: \(m)"
            }
        }
    }

    /// Shared headers that AirPlay servers expect. `X-Apple-HKP: 3` selects
    /// the HAP-with-PIN flow (value 4 would be transient, value 6 is M-FI).
    /// pyatv uses this exact UA (`AirPlay/320.20`). Some tvOS builds gate the
    /// HAP TLV8 pair-setup path on this UA — with a custom UA the server
    /// silently falls back to a legacy binary-plist response. Do not change
    /// this string without testing against a modern Apple TV.
    static let headers: [String: String] = [
        "User-Agent":   "AirPlay/320.20",
        "Connection":   "keep-alive",
        "X-Apple-HKP":  "3",
        "Content-Type": "application/octet-stream",
    ]

    private let http: AirPlayHTTP
    private let srp  = SRPClient()

    // Random Ed25519 long-term keypair for this pairing. Persisted only after
    // the flow succeeds — if pairing fails we throw this away.
    private let ltKeyPair = Curve25519.Signing.PrivateKey()

    // Fresh UUID per pairing — identifies us to the ATV's pairing table.
    // AirPlay and Companion get distinct clientIDs so they occupy separate
    // pair records on the device.
    private let clientID: String = UUID().uuidString

    // State captured between M2 and M5.
    private var atvSalt:    Data?
    private var atvPubKey:  Data?
    private var sessionK:   Data?
    private var encryptKey: SymmetricKey?

    public init(http: AirPlayHTTP) {
        self.http = http
    }

    // MARK: Public flow

    /// POST /pair-pin-start + /pair-setup(M1). Causes the Apple TV to display
    /// the PIN the user must type into `completePairing`.
    public func beginPairing() throws {
        // /pair-pin-start tells the TV to render a PIN. Some tvOS versions
        // require it, others don't — pyatv always sends it so we do too.
        let r0 = try http.post("/pair-pin-start", body: Data(), headers: Self.headers)
        if r0.status != 200 {
            Log.pairing.fail("AirPlay: /pair-pin-start status=\(r0.status) — continuing")
            // Don't hard-fail; some models return 404 yet still honor /pair-setup.
        }

        // M1: Method=0 (HAP pair setup, no MFi), State=1
        var tlv = TLV8()
        tlv.append(.method, byte: 0x00)
        tlv.append(.state,  byte: 0x01)

        let r = try http.post("/pair-setup", body: tlv.encode(), headers: Self.headers)
        guard r.status == 200 else { throw PairError.httpStatus(r.status, r.body) }

        let resp = TLV8.decode(r.body)
        if let err = resp[.error]?.first { throw PairError.serverError(err) }
        guard let salt = resp[.salt]      else { throw PairError.missingTLV("salt") }
        guard let bPub = resp[.publicKey] else { throw PairError.missingTLV("publicKey") }
        self.atvSalt   = salt
        self.atvPubKey = bPub
        Log.pairing.report("AirPlay pair-setup M2 received (salt=\(salt.count)B pub=\(bPub.count)B)")
    }

    /// POST /pair-setup(M3) + (M5). Returns credentials on success; they are
    /// ready to be persisted by the caller.
    public func completePairing(pin: String) throws -> AirPlayCredentials {
        guard let salt = atvSalt, let bPub = atvPubKey else {
            throw PairError.missingTLV("beginPairing() not called")
        }

        // M3: send our public key (A) + proof (M1).
        let session = try srp.computeSession(salt: salt, serverPublicKey: bPub, pin: pin)
        self.sessionK = session.sessionKeyK

        var m3 = TLV8()
        m3.append(.state,     byte: 0x03)
        m3.append(.publicKey, pad(srp.publicKey.toData(), to: SRPClient.Nbytes))
        m3.append(.proof,     session.clientProof)

        let r4 = try http.post("/pair-setup", body: m3.encode(), headers: Self.headers)
        guard r4.status == 200 else { throw PairError.httpStatus(r4.status, r4.body) }
        let resp4 = TLV8.decode(r4.body)
        if let err = resp4[.error]?.first { throw PairError.serverError(err) }
        guard let serverProof = resp4[.proof] else { throw PairError.missingTLV("proof (M4)") }
        guard serverProof == session.expectedServerProof else {
            throw PairError.cryptoFailed("server proof mismatch — PIN wrong?")
        }
        Log.pairing.report("AirPlay pair-setup M4 server proof verified ✓")

        // M5: encrypted identity + signature. This is where we commit the
        // long-term keypair to the TV's pair table.
        let encryptKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: session.sessionKeyK),
            salt:             Data("Pair-Setup-Encrypt-Salt".utf8),
            info:             Data("Pair-Setup-Encrypt-Info".utf8),
            outputByteCount:  32
        )
        self.encryptKey = encryptKey

        let signSalt = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: session.sessionKeyK),
            salt:             Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info:             Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount:  32
        )
        let clientIDBytes = Data(clientID.utf8)
        let ltpk          = Data(ltKeyPair.publicKey.rawRepresentation)
        let deviceInfo    = signSalt.withUnsafeBytes { Data($0) } + clientIDBytes + ltpk
        let signature     = try ltKeyPair.signature(for: deviceInfo)

        var inner = TLV8()
        inner.append(.identifier, clientIDBytes)
        inner.append(.publicKey,  ltpk)
        inner.append(.signature,  Data(signature))

        let innerEncoded = inner.encode()
        let nonce = try ChaChaPoly.Nonce(data: noncePadded("PS-Msg05"))
        let sealed = try ChaChaPoly.seal(innerEncoded, using: encryptKey, nonce: nonce)
        let encPayload = sealed.ciphertext + sealed.tag

        var m5 = TLV8()
        m5.append(.state,         byte: 0x05)
        m5.append(.encryptedData, encPayload)

        let r6 = try http.post("/pair-setup", body: m5.encode(), headers: Self.headers)
        guard r6.status == 200 else { throw PairError.httpStatus(r6.status, r6.body) }
        let resp6 = TLV8.decode(r6.body)
        if let err = resp6[.error]?.first { throw PairError.serverError(err) }
        guard let encData = resp6[.encryptedData] else {
            throw PairError.missingTLV("encryptedData (M6)")
        }

        // Decrypt M6 to learn the ATV's identifier + long-term public key.
        guard encData.count > 16 else { throw PairError.cryptoFailed("M6 too short") }
        let nonce6 = try ChaChaPoly.Nonce(data: noncePadded("PS-Msg06"))
        let box    = try ChaChaPoly.SealedBox(
            combined: nonce6.withUnsafeBytes { Data($0) } + encData
        )
        let plain  = try ChaChaPoly.open(box, using: encryptKey)
        let innerM6 = TLV8.decode(plain)
        guard let atvID   = innerM6[.identifier] else { throw PairError.missingTLV("atv identifier") }
        guard let atvLTPK = innerM6[.publicKey]  else { throw PairError.missingTLV("atv ltpk") }
        // Note: we don't verify the ATV's signature in M6. pyatv also skips
        // this (has a // TODO in step4). The verify step below will catch a
        // mismatched long-term key anyway — the ATV signs with `atvLTPK` and
        // we reject if that signature doesn't check out.
        _ = innerM6[.signature]

        let creds = AirPlayCredentials(
            ltpk:     atvLTPK,                      // ATV's LT public key (for signature verification)
            ltsk:     ltKeyPair.rawRepresentation,  // our LT private key
            atvID:    atvID,
            clientID: clientIDBytes
        )
        Log.pairing.report("AirPlay pair-setup complete — atvID=\(atvID.map { String(format: "%02x", $0) }.joined().prefix(16))…")
        return creds
    }

    // MARK: - Helpers

    private func pad(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data }
        return Data(repeating: 0, count: length - data.count) + data
    }

    private func noncePadded(_ s: String) -> Data {
        let b = Data(s.utf8)
        assert(b.count <= 12)
        return Data(repeating: 0, count: 12 - b.count) + b
    }
}

// MARK: - Pair Verify

/// Pair-verify exchange. Returns session keys suitable for encrypting the
/// AirPlay control channel. After this succeeds the caller should switch the
/// underlying TCP connection to encrypted framing.
public final class AirPlayPairVerify {

    public enum VerifyError: Error, CustomStringConvertible {
        case httpStatus(Int, Data)
        case missingTLV(String)
        case serverError(UInt8)
        case cryptoFailed(String)

        public var description: String {
            switch self {
            case .httpStatus(let c, let b): return "HTTP \(c): \(String(data: b, encoding: .utf8) ?? "<\(b.count)B>")"
            case .missingTLV(let f):        return "missing TLV: \(f)"
            case .serverError(let e):       return "server reported error=\(e)"
            case .cryptoFailed(let m):      return "crypto failed: \(m)"
            }
        }
    }

    private let http: AirPlayHTTP
    private let credentials: AirPlayCredentials
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()

    public init(http: AirPlayHTTP, credentials: AirPlayCredentials) {
        self.http = http; self.credentials = credentials
    }

    /// Runs /pair-verify M1 + M3. On success, returns derived session keys.
    public func verify() throws -> AirPlaySessionKeys {
        let ourPub = Data(ephemeral.publicKey.rawRepresentation)

        // M1: { state=1, publicKey=ourEphemeralPub }
        var m1 = TLV8()
        m1.append(.state,     byte: 0x01)
        m1.append(.publicKey, ourPub)

        let r2 = try http.post("/pair-verify", body: m1.encode(), headers: AirPlayPairSetup.headers)
        guard r2.status == 200 else { throw VerifyError.httpStatus(r2.status, r2.body) }
        let resp2 = TLV8.decode(r2.body)
        if let err = resp2[.error]?.first { throw VerifyError.serverError(err) }
        guard let atvPub = resp2[.publicKey]     else { throw VerifyError.missingTLV("publicKey") }
        guard let encData = resp2[.encryptedData] else { throw VerifyError.missingTLV("encryptedData") }

        // ECDH shared secret.
        let atvKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: atvPub)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: atvKey)
        let sharedData = shared.withUnsafeBytes { Data($0) }

        let sessionKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt:             Data("Pair-Verify-Encrypt-Salt".utf8),
            info:             Data("Pair-Verify-Encrypt-Info".utf8),
            outputByteCount:  32
        )

        // Decrypt M2 payload (contains ATV identifier + signature).
        guard encData.count > 16 else { throw VerifyError.cryptoFailed("M2 too short") }
        let nonce2 = try ChaChaPoly.Nonce(data: noncePadded("PV-Msg02"))
        let box    = try ChaChaPoly.SealedBox(
            combined: nonce2.withUnsafeBytes { Data($0) } + encData
        )
        let plain  = try ChaChaPoly.open(box, using: sessionKey)
        let inner  = TLV8.decode(plain)
        guard let atvID   = inner[.identifier] else { throw VerifyError.missingTLV("atv identifier") }
        guard let atvSig  = inner[.signature]  else { throw VerifyError.missingTLV("atv signature") }

        guard atvID == credentials.atvID else {
            throw VerifyError.cryptoFailed("atv id mismatch — wrong device or stale creds")
        }
        // The ATV signed (atvPub || atvID || ourPub) with its long-term
        // Ed25519 key. Verifying proves it actually knows this pairing and
        // guards against an attacker presenting arbitrary bytes on the wire.
        let atvLTPubKey = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk)
        let signedInfo  = atvPub + atvID + ourPub
        guard atvLTPubKey.isValidSignature(atvSig, for: signedInfo) else {
            throw VerifyError.cryptoFailed("ATV signature invalid — wrong ltpk or MITM")
        }

        // M3: sign (ourPub || ourID || atvPub) with our long-term Ed25519 key,
        // encrypt, and send. On success the server switches to encrypted framing.
        let signKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        let deviceInfo = ourPub + credentials.clientID + atvPub
        let signature  = try signKey.signature(for: deviceInfo)

        var m3Inner = TLV8()
        m3Inner.append(.identifier, credentials.clientID)
        m3Inner.append(.signature,  Data(signature))

        let nonce3 = try ChaChaPoly.Nonce(data: noncePadded("PV-Msg03"))
        let sealed = try ChaChaPoly.seal(m3Inner.encode(), using: sessionKey, nonce: nonce3)

        var m3 = TLV8()
        m3.append(.state,         byte: 0x03)
        m3.append(.encryptedData, sealed.ciphertext + sealed.tag)

        let r4 = try http.post("/pair-verify", body: m3.encode(), headers: AirPlayPairSetup.headers)
        guard r4.status == 200 else { throw VerifyError.httpStatus(r4.status, r4.body) }
        let resp4 = TLV8.decode(r4.body)
        if let err = resp4[.error]?.first { throw VerifyError.serverError(err) }

        // Derive the two control channel keys from the same shared secret.
        let writeKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt:             Data("Control-Salt".utf8),
            info:             Data("Control-Write-Encryption-Key".utf8),
            outputByteCount:  32
        )
        let readKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedData),
            salt:             Data("Control-Salt".utf8),
            info:             Data("Control-Read-Encryption-Key".utf8),
            outputByteCount:  32
        )

        Log.pairing.report("AirPlay pair-verify complete ✓ control channel keys derived")
        return AirPlaySessionKeys(
            readKey:  readKey.withUnsafeBytes  { Data($0) },
            writeKey: writeKey.withUnsafeBytes { Data($0) }
        )
    }

    private func noncePadded(_ s: String) -> Data {
        let b = Data(s.utf8)
        return Data(repeating: 0, count: 12 - b.count) + b
    }
}
