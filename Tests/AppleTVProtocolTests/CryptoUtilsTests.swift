import XCTest
@testable import AppleTVProtocol

final class CryptoUtilsTests: XCTestCase {

    func testConstantTimeEqualsTrueForEqualData() {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertTrue(a.constantTimeEquals(b))
    }

    func testConstantTimeEqualsFalseForDifferingBytes() {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x01, 0x02, 0x03, 0x05])
        XCTAssertFalse(a.constantTimeEquals(b))
    }

    func testConstantTimeEqualsFalseForDifferingLengths() {
        let a = Data([0x01, 0x02, 0x03])
        let b = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertFalse(a.constantTimeEquals(b))
    }

    func testConstantTimeEqualsFirstByteDiff() {
        let a = Data([0x01, 0x02, 0x03, 0x04])
        let b = Data([0x99, 0x02, 0x03, 0x04])
        XCTAssertFalse(a.constantTimeEquals(b))
    }

    func testConstantTimeEqualsEmpty() {
        XCTAssertTrue(Data().constantTimeEquals(Data()))
    }
}
