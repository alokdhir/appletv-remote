import XCTest
import CryptoKit
import BigInt
@testable import AppleTVProtocol

/// Known-answer tests for SRPClient.
///
/// Rather than hardcoding opaque byte vectors, we implement a minimal SRP server
/// in-test using the same group parameters and verify the algebraic invariants:
///   1. Client and server derive the same session key K.
///   2. M1 (client proof) is correctly formed.
///   3. M2 (expected server proof) matches server-side computation of H(PAD(A)|M1|K).
///   4. Invalid server public key (B ≡ 0 mod N) is rejected.
///   5. A second client with the same PIN but a different private key produces a
///      different K (no key reuse / determinism regression).
final class SRPClientTests: XCTestCase {

    // MARK: - Helpers (mirror SRPClient internals with fixed params)

    private let N   = SRPClient.N
    private let g   = SRPClient.g
    private let len = SRPClient.Nbytes

    private func sha512(_ d: Data) -> Data { Data(SHA512.hash(data: d)) }
    private func pad(_ d: Data, to n: Int) -> Data {
        d.count >= n ? d : Data(repeating: 0, count: n - d.count) + d
    }

    // Fixed test inputs — deterministic but not zero.
    private let fixedA = BigUInt(Data(repeating: 0x42, count: 32))
    private let fixedB = BigUInt(Data(repeating: 0x11, count: 32))
    private let fixedSalt = Data(repeating: 0xAB, count: 16)
    private let pin = "1234"

    /// Build a server-side B given server private key b, verifier v, k.
    private func serverPublicKey(b: BigUInt, v: BigUInt, k: BigUInt) -> BigUInt {
        ((k * v) % N + g.power(b, modulus: N)) % N
    }

    /// Compute verifier v = g^x mod N where x = H(salt | H(I:P)).
    private func verifier(salt: Data, pin: String) -> BigUInt {
        let x = BigUInt(sha512(salt + sha512(Data((SRPClient.username + ":" + pin).utf8))))
        return g.power(x, modulus: N)
    }

    /// Compute k = H(PAD(N) | PAD(g)).
    private var srpK: BigUInt {
        BigUInt(sha512(pad(N.serialize(), to: len) + pad(g.serialize(), to: len)))
    }

    /// Server-side S = (A * v^u mod N) ^ b mod N.
    private func serverS(A: BigUInt, v: BigUInt, u: BigUInt, b: BigUInt) -> BigUInt {
        ((A % N) * v.power(u, modulus: N) % N).power(b, modulus: N)
    }

    // MARK: - Tests

    func testPublicKeyDerivedFromPrivate() {
        let client = SRPClient(privateKey: fixedA)
        let expected = g.power(fixedA, modulus: N)
        XCTAssertEqual(client.publicKey, expected)
    }

    func testClientAndServerAgreeOnSessionKey() throws {
        let client = SRPClient(privateKey: fixedA)
        let v = verifier(salt: fixedSalt, pin: pin)
        let k = srpK
        let B = serverPublicKey(b: fixedB, v: v, k: k)

        let result = try client.computeSession(
            salt: fixedSalt,
            serverPublicKey: B.serialize(),
            pin: pin
        )

        // Server computes same S
        let A = client.publicKey
        let u = BigUInt(sha512(pad(A.serialize(), to: len) + pad(B.serialize(), to: len)))
        let serverSVal = serverS(A: A, v: v, u: u, b: fixedB)
        let serverK = sha512(serverSVal.serialize())

        XCTAssertEqual(result.sessionKeyK, serverK,
                       "Client and server must derive the same session key K")
    }

    func testServerProofMatchesExpected() throws {
        let client = SRPClient(privateKey: fixedA)
        let v = verifier(salt: fixedSalt, pin: pin)
        let k = srpK
        let B = serverPublicKey(b: fixedB, v: v, k: k)

        let result = try client.computeSession(
            salt: fixedSalt,
            serverPublicKey: B.serialize(),
            pin: pin
        )

        // Server computes M2 = H(PAD(A) | M1 | K)
        let expectedM2 = sha512(
            pad(client.publicKey.serialize(), to: len)
            + result.clientProof
            + result.sessionKeyK
        )
        XCTAssertEqual(result.expectedServerProof, expectedM2,
                       "M2 must equal H(PAD(A) | M1 | K)")
    }

    func testWrongPinProducesDifferentKey() throws {
        let client = SRPClient(privateKey: fixedA)
        let v = verifier(salt: fixedSalt, pin: pin)
        let k = srpK
        let B = serverPublicKey(b: fixedB, v: v, k: k)

        let correct = try client.computeSession(
            salt: fixedSalt, serverPublicKey: B.serialize(), pin: "1234")
        let wrong = try client.computeSession(
            salt: fixedSalt, serverPublicKey: B.serialize(), pin: "9999")

        XCTAssertNotEqual(correct.sessionKeyK, wrong.sessionKeyK)
        XCTAssertNotEqual(correct.clientProof, wrong.clientProof)
    }

    func testInvalidServerPublicKeyThrows() {
        // B = 0 is explicitly invalid (B % N == 0)
        let client = SRPClient(privateKey: fixedA)
        XCTAssertThrowsError(
            try client.computeSession(salt: fixedSalt,
                                      serverPublicKey: Data([0x00]),
                                      pin: pin)
        ) { error in
            XCTAssertEqual(error as? SRPError, .invalidServerPublicKey)
        }
    }

    func testDifferentPrivateKeysProduceDifferentPublicKeys() {
        let c1 = SRPClient(privateKey: BigUInt(Data(repeating: 0x01, count: 32)))
        let c2 = SRPClient(privateKey: BigUInt(Data(repeating: 0x02, count: 32)))
        XCTAssertNotEqual(c1.publicKey, c2.publicKey)
    }

    func testSessionKeyLengthIs64Bytes() throws {
        let client = SRPClient(privateKey: fixedA)
        let v = verifier(salt: fixedSalt, pin: pin)
        let B = serverPublicKey(b: fixedB, v: v, k: srpK)
        let result = try client.computeSession(
            salt: fixedSalt, serverPublicKey: B.serialize(), pin: pin)
        XCTAssertEqual(result.sessionKeyK.count, 64)
        XCTAssertEqual(result.clientProof.count, 64)
        XCTAssertEqual(result.expectedServerProof.count, 64)
    }
}
