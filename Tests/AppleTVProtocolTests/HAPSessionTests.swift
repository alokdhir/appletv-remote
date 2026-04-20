import XCTest
@testable import AppleTVProtocol

/// Round-trip tests for the HAP ChaCha20-Poly1305 frame codec.
///
/// The two "sides" in these tests each use two counters — one for what it
/// encrypts (write) and one for what it decrypts (read). For a bidirectional
/// channel to work the peer's writeKey == our readKey and vice versa.
final class HAPSessionTests: XCTestCase {

    private func pair() -> (HAPSession, HAPSession) {
        let k1 = Data(repeating: 0xAA, count: 32)
        let k2 = Data(repeating: 0x55, count: 32)
        let a  = HAPSession(writeKey: k1, readKey: k2)   // A → B uses k1
        let b  = HAPSession(writeKey: k2, readKey: k1)   // B → A uses k2
        return (a, b)
    }

    func testRoundTripShort() throws {
        let (a, b) = pair()
        let plain  = Data("hello, apple tv".utf8)
        let cipher = try a.encrypt(plain)
        let out    = try b.feed(cipher)
        XCTAssertEqual(out, plain)
    }

    func testRoundTripMultipleFrames() throws {
        let (a, b) = pair()
        // Exactly on the chunk boundary + some tail.
        let plain  = Data(repeating: 0x42, count: HAPSession.maxFramePlaintext * 2 + 37)
        let cipher = try a.encrypt(plain)
        let out    = try b.feed(cipher)
        XCTAssertEqual(out, plain)
    }

    func testPartialBufferingReassembles() throws {
        let (a, b) = pair()
        let plain  = Data("the quick brown fox jumps over the lazy dog".utf8)
        let cipher = try a.encrypt(plain)

        // Feed one byte at a time — only the last byte should yield output.
        var assembled = Data()
        for byte in cipher {
            assembled.append(try b.feed(Data([byte])))
        }
        XCTAssertEqual(assembled, plain)
    }

    func testCounterAdvancesPerFrame() throws {
        let (a, b) = pair()
        let out1 = try a.encrypt(Data("one".utf8))
        let out2 = try a.encrypt(Data("two".utf8))
        // Two separate frames → decrypt in order.
        XCTAssertEqual(try b.feed(out1), Data("one".utf8))
        XCTAssertEqual(try b.feed(out2), Data("two".utf8))
    }

    func testTamperedTagFailsAuth() throws {
        let (a, b) = pair()
        var cipher = try a.encrypt(Data("sensitive".utf8))
        // Flip a byte in the Poly1305 tag (last 16B of the frame).
        let idx = cipher.count - 1
        cipher[idx] ^= 0x01
        XCTAssertThrowsError(try b.feed(cipher)) { error in
            guard case HAPSession.FramingError.authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testBidirectional() throws {
        let (a, b) = pair()
        // A → B
        XCTAssertEqual(try b.feed(try a.encrypt(Data("ping".utf8))), Data("ping".utf8))
        // B → A uses independent counter pair
        XCTAssertEqual(try a.feed(try b.encrypt(Data("pong".utf8))), Data("pong".utf8))
        // A → B again, counter incremented
        XCTAssertEqual(try b.feed(try a.encrypt(Data("ping2".utf8))), Data("ping2".utf8))
    }
}
