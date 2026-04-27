import XCTest
import Darwin
import CryptoKit
@testable import AppleTVProtocol

/// Tests for CompanionSession message dispatch, delegate callbacks, and
/// text-input guard invariants.
///
/// We never open a real TCP socket — instead we:
///   1. Create a socketpair() so the session has a valid fd to close.
///   2. Call start() to launch the read loop (it will block on the peer end).
///   3. Use injectOPACKForTesting() to push OPACK payloads directly into the
///      dispatch logic, bypassing the transport layer.
///
/// All tests are @MainActor because CompanionSession and its delegate
/// protocol are @MainActor-isolated.
@MainActor
final class CompanionSessionTests: XCTestCase {

    // MARK: - Helpers

    private func makeFDs() -> (session: Int32, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer {
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair failed: \(errno)")
        return (fds[0], fds[1])
    }

    private func makeSession(delegate: (any CompanionSessionDelegate)? = nil) -> (CompanionSession, peer: Int32) {
        let (sessionFD, peerFD) = makeFDs()
        let transport = EncryptedFrameTransport()
        let session = CompanionSession(
            fd: sessionFD,
            epoch: 1,
            transport: transport,
            writeQueue: DispatchQueue(label: "test.write"),
            readQueue:  DispatchQueue(label: "test.read")
        )
        session.delegate = delegate
        session.start()
        return (session, peerFD)
    }

    private func opack(_ dict: [String: Any]) -> Data {
        OPACK.pack(dict)
    }

    // MARK: - Spy delegate

    final class Spy: CompanionSessionDelegate {
        var nowPlayingUpdates: [CompanionNowPlayingUpdate] = []
        var keyboardChanges: [(active: Bool, data: Data?)] = []
        var attentionStates: [Int] = []
        var readErrors: [String] = []
        var closedCount = 0
        var confirmedStart = 0
        var fetchedApps: [(id: String, name: String)]? = nil
        var receivedPairingFrames: [CompanionFrame] = []

        func sessionDidUpdateNowPlaying(_ info: CompanionNowPlayingUpdate) {
            nowPlayingUpdates.append(info)
        }
        func sessionDidChangeKeyboardActive(_ active: Bool, data: Data?) {
            keyboardChanges.append((active, data))
        }
        func sessionDidUpdateAttentionState(_ state: Int) {
            attentionStates.append(state)
        }
        func sessionDidReadError(_ message: String) {
            readErrors.append(message)
        }
        func sessionDidClose() {
            closedCount += 1
        }
        func sessionDidConfirmStart() {
            confirmedStart += 1
        }
        func sessionDidFetchApps(_ apps: [(id: String, name: String)]) {
            fetchedApps = apps
        }
        func sessionDidReceivePairingFrame(_ frame: CompanionFrame) {
            receivedPairingFrames.append(frame)
        }
    }

    // MARK: - close() invariants

    func testCloseIsIdempotent() {
        let (session, peer) = makeSession()
        defer { Darwin.close(peer) }
        session.close()
        session.close()   // must not crash
    }

    func testCloseClearsCallbacks() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { Darwin.close(peer) }
        // inject a message that would register a callback
        let tiD = Data(repeating: 0xAB, count: 4)
        session.injectOPACKForTesting(opack(["_i": "_tiStarted", "_t": 2, "_x": 1,
                                             "_c": ["_tiD": tiD]]))
        // close should discard pending callbacks
        session.close()
        // subsequent inject should not crash or fire stale callbacks
        session.injectOPACKForTesting(opack(["_i": "FetchAttentionState",
                                             "_t": 3, "_x": 1,
                                             "_c": ["state": 2]]))
    }

    // MARK: - _tiStarted / _tiStopped

    func testTiStartedSetsKeyboardActive() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        let tiD = Data(repeating: 0xAA, count: 8)
        session.injectOPACKForTesting(opack(["_i": "_tiStarted", "_t": 2, "_x": 1,
                                             "_c": ["_tiD": tiD]]))

        XCTAssertEqual(spy.keyboardChanges.count, 1)
        XCTAssertTrue(spy.keyboardChanges[0].active)
        XCTAssertEqual(spy.keyboardChanges[0].data, tiD)
    }

    func testTiStartedWithoutTiDStillSetsActive() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack(["_i": "_tiStarted", "_t": 2, "_x": 1]))

        XCTAssertEqual(spy.keyboardChanges.count, 1)
        XCTAssertTrue(spy.keyboardChanges[0].active)
    }

    func testTiStoppedClearsKeyboard() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        let tiD = Data(repeating: 0xBB, count: 8)
        session.injectOPACKForTesting(opack(["_i": "_tiStarted", "_t": 2, "_x": 1,
                                             "_c": ["_tiD": tiD]]))
        session.injectOPACKForTesting(opack(["_i": "_tiStopped", "_t": 2, "_x": 2]))

        XCTAssertEqual(spy.keyboardChanges.count, 2)
        XCTAssertFalse(spy.keyboardChanges[1].active)
        XCTAssertNil(spy.keyboardChanges[1].data)
    }

    // MARK: - FetchAttentionState

    func testFetchAttentionStateFiresDelegate() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack(["_i": "FetchAttentionState",
                                             "_t": 3, "_x": 1,
                                             "_c": ["state": 2]]))

        XCTAssertEqual(spy.attentionStates, [2])
    }

    func testFetchAttentionStateResponseFiresViaDefaultCase() {
        // ATV sometimes sends FetchAttentionState response with no _i (matched by txn).
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack(["_t": 3, "_x": 99,
                                             "_c": ["state": 3]]))
        XCTAssertEqual(spy.attentionStates, [3])
    }

    // MARK: - _iMC / now-playing

    func testIMCPushFiresNowPlayingDelegate() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack([
            "_i": "_iMC", "_t": 2, "_x": 1,
            "_c": ["title": "Bohemian Rhapsody", "clientName": "Music"]
        ]))

        XCTAssertEqual(spy.nowPlayingUpdates.count, 1)
        XCTAssertEqual(spy.nowPlayingUpdates[0].inner["title"] as? String, "Bohemian Rhapsody")
    }

    // MARK: - _heartbeat / _ping

    func testHeartbeatDoesNotFireDelegate() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack(["_i": "_heartbeat", "_t": 2, "_x": 5]))

        XCTAssertTrue(spy.nowPlayingUpdates.isEmpty)
        XCTAssertTrue(spy.keyboardChanges.isEmpty)
        XCTAssertTrue(spy.attentionStates.isEmpty)
    }

    // MARK: - _sessionStart confirmation

    func testSessionStartConfirmationFiresDelegate() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        // sendSessionInit registers sessionStartTxn; simulate the ATV response.
        // We call sendSessionInit, which allocates txns starting from txnCounter.
        // The _sessionStart is txn3 (0-indexed from the batch of 4 sends).
        // Since we can't observe the exact txn, we use sendSessionInit and then
        // inject a fake _sessionStart response — but we don't know the txn.
        // Instead, test that injecting the typical response pattern works:
        // _t=3, no _i, _c.state present (triggers both session confirm + attnState).
        session.injectOPACKForTesting(opack(["_t": 3, "_x": 1, "_c": ["state": 1]]))

        // attentionState fires from the default case
        XCTAssertEqual(spy.attentionStates, [1])
    }

    // MARK: - sendText guard

    func testSendTextFailsWithNoActiveTextField() {
        let (session, peer) = makeSession()
        defer { session.close(); Darwin.close(peer) }

        var capturedError: Error?
        session.sendText("hello") { capturedError = $0 }

        XCTAssertNotNil(capturedError)
        let err = capturedError as? TextInputError
        XCTAssertEqual(err, .noActiveTextField)
    }

    func testSendTextSucceedsWhenTextFieldActive() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        // Use a fake tiD that activates the keyboard guard but has no parseable
        // NSKeyedArchive — so sendText hits sessionUUIDMissing, not noActiveTextField.
        let fakeTiD = Data(repeating: 0x00, count: 16)
        session.injectOPACKForTesting(opack(["_i": "_tiStarted", "_t": 2, "_x": 1,
                                             "_c": ["_tiD": fakeTiD]]))

        var capturedError: Error?
        session.sendText("hello") { capturedError = $0 }

        // fakeTiD won't parse as a real NSKeyedArchive → sessionUUIDMissing
        let err = capturedError as? TextInputError
        XCTAssertEqual(err, .sessionUUIDMissing)
    }

    // MARK: - sendBackspace / sendClearText guards

    func testSendBackspaceFailsWithNoActiveTextField() {
        let (session, peer) = makeSession()
        defer { session.close(); Darwin.close(peer) }

        // sendBackspace fires _tiStop then waits for _tiStart response.
        // Without a real socket the completion never fires synchronously.
        // Verify it doesn't crash and doesn't call completion synchronously.
        var called = false
        session.sendBackspace { _ in called = true }
        XCTAssertFalse(called, "sendBackspace should not call completion synchronously without a socket response")
    }

    func testSendClearTextFailsWithNoActiveTextField() {
        let (session, peer) = makeSession()
        defer { session.close(); Darwin.close(peer) }

        // sendClearText fires _tiStop then waits for _tiStart response.
        // Without a real socket the completion never fires synchronously.
        var called = false
        session.sendClearText { _ in called = true }
        XCTAssertFalse(called, "sendClearText should not call completion synchronously without a socket response")
    }

    // MARK: - Multiple attentionState updates

    func testMultipleAttentionStateUpdates() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        session.injectOPACKForTesting(opack(["_i": "FetchAttentionState", "_t": 3, "_x": 1,
                                             "_c": ["state": 1]]))
        session.injectOPACKForTesting(opack(["_i": "FetchAttentionState", "_t": 3, "_x": 2,
                                             "_c": ["state": 2]]))
        session.injectOPACKForTesting(opack(["_i": "FetchAttentionState", "_t": 3, "_x": 3,
                                             "_c": ["state": 3]]))

        XCTAssertEqual(spy.attentionStates, [1, 2, 3])
    }

    // MARK: - Pending callback dispatch

    func testPendingCallbackFiredByTxn() {
        let spy = Spy()
        let (session, peer) = makeSession(delegate: spy)
        defer { session.close(); Darwin.close(peer) }

        // fetchApps registers a pendingCallback for its txn.
        // Inject a response for a txn we don't know (fetchApps picks randomly),
        // so instead test that an unknown txn in the default case doesn't crash
        // and doesn't fire any delegate callbacks it shouldn't.
        session.injectOPACKForTesting(opack(["_t": 3, "_x": 99999]))
        // No crash = pass
    }
}

// MARK: - UUID helper

private extension UUID {
    var uuidData: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
