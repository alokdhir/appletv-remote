import XCTest
@testable import AppleTVIPC

final class IPCFrameTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - IPCFrame.decode — Request

    func testDecodeRequest_ping() throws {
        let data = json(#"{"id":"1","cmd":"ping"}"#)
        guard case .request(let req) = try IPCFrame.decode(data) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(req.id, "1")
        XCTAssertEqual(req.cmd, .ping)
        XCTAssertNil(req.args)
    }

    func testDecodeRequest_keyWithArgs() throws {
        let data = json(#"{"id":"42","cmd":"key","args":{"key":"play-pause"}}"#)
        guard case .request(let req) = try IPCFrame.decode(data) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(req.id, "42")
        XCTAssertEqual(req.cmd, .key)
        XCTAssertEqual(req.args?["key"], "play-pause")
    }

    func testDecodeRequest_pairPin() throws {
        let data = json(#"{"id":"3","cmd":"pair-pin","args":{"pin":"1234"}}"#)
        guard case .request(let req) = try IPCFrame.decode(data) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(req.cmd, .pairPin)
        XCTAssertEqual(req.args?["pin"], "1234")
    }

    func testDecodeRequest_select() throws {
        let data = json(#"{"id":"9","cmd":"select","args":{"id":"device-uuid"}}"#)
        guard case .request(let req) = try IPCFrame.decode(data) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(req.cmd, .select)
    }

    // MARK: - IPCFrame.decode — Response

    func testDecodeResponse_ok() throws {
        let data = json(#"{"id":"1","ok":true}"#)
        guard case .response(let resp) = try IPCFrame.decode(data) else {
            return XCTFail("expected .response")
        }
        XCTAssertEqual(resp.id, "1")
        XCTAssertTrue(resp.ok)
        XCTAssertNil(resp.error)
        XCTAssertNil(resp.devices)
        XCTAssertNil(resp.status)
    }

    func testDecodeResponse_failure() throws {
        let data = json(#"{"id":"2","ok":false,"error":"not connected"}"#)
        guard case .response(let resp) = try IPCFrame.decode(data) else {
            return XCTFail("expected .response")
        }
        XCTAssertEqual(resp.id, "2")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "not connected")
    }

    func testDecodeResponse_withDevices() throws {
        let data = json(#"{"id":"3","ok":true,"devices":[{"id":"d1","name":"Living Room","host":"192.168.1.5","paired":true,"autoConnect":true,"isDefault":true,"resolved":true}]}"#)
        guard case .response(let resp) = try IPCFrame.decode(data) else {
            return XCTFail("expected .response")
        }
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.devices?.count, 1)
        XCTAssertEqual(resp.devices?.first?.name, "Living Room")
        XCTAssertEqual(resp.devices?.first?.host, "192.168.1.5")
    }

    func testDecodeResponse_withStatus() throws {
        let data = json(#"{"id":"4","ok":true,"status":{"deviceID":"d1","deviceName":"ATV","host":"10.0.0.1","connectionState":"connected","isReconnecting":false}}"#)
        guard case .response(let resp) = try IPCFrame.decode(data) else {
            return XCTFail("expected .response")
        }
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.status?.deviceName, "ATV")
        XCTAssertEqual(resp.status?.connectionState, "connected")
        XCTAssertFalse(resp.status?.isReconnecting ?? true)
    }

    func testDecodeResponse_withNowPlaying() throws {
        let data = json(#"{"id":"5","ok":true,"status":{"connectionState":"connected","isReconnecting":false,"nowPlaying":{"title":"Song","artist":"Artist","album":"Album","app":"Music","elapsedTime":30.5,"duration":240.0,"playbackRate":1.0}}}"#)
        guard case .response(let resp) = try IPCFrame.decode(data) else {
            return XCTFail("expected .response")
        }
        let np = resp.status?.nowPlaying
        XCTAssertEqual(np?.title, "Song")
        XCTAssertEqual(np?.artist, "Artist")
        XCTAssertEqual(np?.album, "Album")
        XCTAssertEqual(np?.app, "Music")
        XCTAssertEqual(np?.elapsedTime, 30.5)
        XCTAssertEqual(np?.duration, 240.0)
        XCTAssertEqual(np?.playbackRate, 1.0)
    }

    // MARK: - IPCFrame.decode — Event

    func testDecodeEvent_pinRequired() throws {
        let data = json(#"{"id":"e1","event":"pin-required"}"#)
        guard case .event(let evt) = try IPCFrame.decode(data) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(evt.id, "e1")
        XCTAssertEqual(evt.event, .pinRequired)
        XCTAssertNil(evt.message)
    }

    func testDecodeEvent_paired() throws {
        let data = json(#"{"id":"e2","event":"paired"}"#)
        guard case .event(let evt) = try IPCFrame.decode(data) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(evt.event, .paired)
    }

    func testDecodeEvent_connected() throws {
        let data = json(#"{"id":"e3","event":"connected","message":"Living Room"}"#)
        guard case .event(let evt) = try IPCFrame.decode(data) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(evt.event, .connected)
        XCTAssertEqual(evt.message, "Living Room")
    }

    func testDecodeEvent_disconnected() throws {
        let data = json(#"{"id":"e4","event":"disconnected"}"#)
        guard case .event(let evt) = try IPCFrame.decode(data) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(evt.event, .disconnected)
    }

    func testDecodeEvent_error() throws {
        let data = json(#"{"id":"e5","event":"error","message":"connection refused"}"#)
        guard case .event(let evt) = try IPCFrame.decode(data) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(evt.event, .error)
        XCTAssertEqual(evt.message, "connection refused")
    }

    // MARK: - IPCFrame.decode — Unknown frame throws

    func testDecodeUnknownFrameThrows() {
        let data = json(#"{"foo":"bar"}"#)
        XCTAssertThrowsError(try IPCFrame.decode(data))
    }

    func testDecodeEmptyObjectThrows() {
        let data = json(#"{}"#)
        XCTAssertThrowsError(try IPCFrame.decode(data))
    }

    func testDecodeInvalidJSONThrows() {
        let data = json("not json")
        XCTAssertThrowsError(try IPCFrame.decode(data))
    }

    // MARK: - IPCFrame.encode — Request

    func testEncodeRequest_roundTrip() throws {
        let req = IPCRequest(id: "r1", cmd: .key, args: ["key": "menu"])
        let encoded = try IPCFrame.request(req).encode()
        guard case .request(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(decoded.id, req.id)
        XCTAssertEqual(decoded.cmd, req.cmd)
        XCTAssertEqual(decoded.args, req.args)
    }

    func testEncodeRequest_noArgs_roundTrip() throws {
        let req = IPCRequest(id: "r2", cmd: .list)
        let encoded = try IPCFrame.request(req).encode()
        guard case .request(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .request")
        }
        XCTAssertEqual(decoded.cmd, .list)
        XCTAssertNil(decoded.args)
    }

    // MARK: - IPCFrame.encode — Response

    func testEncodeResponse_ok_roundTrip() throws {
        let resp = IPCResponse.ok("r1")
        let encoded = try IPCFrame.response(resp).encode()
        guard case .response(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .response")
        }
        XCTAssertEqual(decoded.id, "r1")
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
    }

    func testEncodeResponse_failure_roundTrip() throws {
        let resp = IPCResponse.failure("r2", "oops")
        let encoded = try IPCFrame.response(resp).encode()
        guard case .response(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .response")
        }
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "oops")
    }

    func testEncodeResponse_withDevices_roundTrip() throws {
        let device = IPCDevice(id: "d1", name: "Bedroom", host: "10.0.0.2",
                               paired: false, autoConnect: false, isDefault: false, resolved: true)
        let resp = IPCResponse(id: "r3", ok: true, devices: [device])
        let encoded = try IPCFrame.response(resp).encode()
        guard case .response(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .response")
        }
        XCTAssertEqual(decoded.devices?.first?.id, "d1")
        XCTAssertEqual(decoded.devices?.first?.name, "Bedroom")
        XCTAssertFalse(decoded.devices?.first?.paired ?? true)
    }

    func testEncodeResponse_withStatus_roundTrip() throws {
        let np = IPCNowPlaying(title: "T", artist: "A", album: nil, app: "Music",
                               elapsedTime: 10.0, duration: 200.0, playbackRate: 1.0)
        let status = IPCStatus(deviceID: "d1", deviceName: "ATV", host: "10.0.0.1",
                               connectionState: "connected", isReconnecting: false,
                               nowPlaying: np, attentionState: 2)
        let resp = IPCResponse(id: "r4", ok: true, status: status)
        let encoded = try IPCFrame.response(resp).encode()
        guard case .response(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .response")
        }
        XCTAssertEqual(decoded.status?.nowPlaying?.title, "T")
        XCTAssertEqual(decoded.status?.attentionState, 2)
    }

    // MARK: - IPCFrame.encode — Event

    func testEncodeEvent_roundTrip() throws {
        let evt = IPCEvent(id: "e1", event: .pinRequired, message: nil)
        let encoded = try IPCFrame.event(evt).encode()
        guard case .event(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(decoded.id, "e1")
        XCTAssertEqual(decoded.event, .pinRequired)
        XCTAssertNil(decoded.message)
    }

    func testEncodeEvent_withMessage_roundTrip() throws {
        let evt = IPCEvent(id: "e2", event: .error, message: "timeout")
        let encoded = try IPCFrame.event(evt).encode()
        guard case .event(let decoded) = try IPCFrame.decode(encoded) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(decoded.event, .error)
        XCTAssertEqual(decoded.message, "timeout")
    }

    // MARK: - Compact encoding (no whitespace)

    func testEncodeIsCompact() throws {
        let req = IPCRequest(id: "1", cmd: .ping)
        let data = try IPCFrame.request(req).encode()
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(str.contains("\n"), "encoded frame must be single line")
        XCTAssertFalse(str.contains("  "), "encoded frame must be compact (no double-spaces)")
    }

    // MARK: - IPCResponse factory methods

    func testResponseOkFactory() {
        let r = IPCResponse.ok("x")
        XCTAssertEqual(r.id, "x")
        XCTAssertTrue(r.ok)
        XCTAssertNil(r.error)
    }

    func testResponseFailureFactory() {
        let r = IPCResponse.failure("y", "bad input")
        XCTAssertEqual(r.id, "y")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, "bad input")
    }

    // MARK: - IPCKey.isSwipe

    func testSwipeKeysAreSwipes() {
        XCTAssertTrue(IPCKey.swipeUp.isSwipe)
        XCTAssertTrue(IPCKey.swipeDown.isSwipe)
        XCTAssertTrue(IPCKey.swipeLeft.isSwipe)
        XCTAssertTrue(IPCKey.swipeRight.isSwipe)
    }

    func testNonSwipeKeysAreNotSwipes() {
        let nonSwipes: [IPCKey] = [.up, .down, .left, .right, .select,
                                   .menu, .home, .playPause, .volumeUp, .volumeDown]
        for key in nonSwipes {
            XCTAssertFalse(key.isSwipe, "\(key.rawValue) should not be a swipe")
        }
    }

    // MARK: - IPCKey raw values

    func testIPCKeyRawValues() {
        XCTAssertEqual(IPCKey.playPause.rawValue, "play-pause")
        XCTAssertEqual(IPCKey.volumeUp.rawValue, "vol-up")
        XCTAssertEqual(IPCKey.volumeDown.rawValue, "vol-down")
        XCTAssertEqual(IPCKey.swipeUp.rawValue, "swipe-up")
        XCTAssertEqual(IPCKey.swipeDown.rawValue, "swipe-down")
        XCTAssertEqual(IPCKey.swipeLeft.rawValue, "swipe-left")
        XCTAssertEqual(IPCKey.swipeRight.rawValue, "swipe-right")
    }

    // MARK: - IPCCommand raw values

    func testIPCCommandRawValues() {
        XCTAssertEqual(IPCCommand.pairStart.rawValue, "pair-start")
        XCTAssertEqual(IPCCommand.pairPin.rawValue, "pair-pin")
        XCTAssertEqual(IPCCommand.longPress.rawValue, "long-press")
        XCTAssertEqual(IPCCommand.ping.rawValue, "ping")
        XCTAssertEqual(IPCCommand.list.rawValue, "list")
        XCTAssertEqual(IPCCommand.select.rawValue, "select")
        XCTAssertEqual(IPCCommand.status.rawValue, "status")
        XCTAssertEqual(IPCCommand.key.rawValue, "key")
        XCTAssertEqual(IPCCommand.power.rawValue, "power")
        XCTAssertEqual(IPCCommand.disconnect.rawValue, "disconnect")
    }

    // MARK: - IPCEvent default id is non-empty

    func testIPCEventDefaultIdIsNonEmpty() {
        let evt = IPCEvent(event: .connected)
        XCTAssertFalse(evt.id.isEmpty)
    }

    // MARK: - IPCSocket path

    func testIPCSocketPathContainsExpectedComponents() {
        XCTAssertTrue(IPCSocket.path.hasSuffix("AppleTVRemote/atv.sock"))
        XCTAssertEqual(IPCSocket.directory,
                       (IPCSocket.path as NSString).deletingLastPathComponent)
    }

    // MARK: - Probe discriminator precedence (cmd wins over ok)

    func testProbeCmdWinsOverOk() throws {
        // A frame that has both "cmd" and "ok" — should be decoded as request
        let data = json(#"{"id":"x","cmd":"ping","ok":true}"#)
        guard case .request = try IPCFrame.decode(data) else {
            return XCTFail("cmd key should take precedence")
        }
    }
}
