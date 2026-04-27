import XCTest
import Network
import CryptoKit
@testable import AppleTVProtocol

/// Focused tests for PairingFlow delegate wiring.
///
/// We test the dispatch/callback logic, not the underlying crypto
/// (covered by SRPClientTests / HAPSessionTests). Three invariants matter:
///   1. Credentials are deleted ONLY on a definitive server rejection (not transient failures)
///   2. Credentials are NOT saved and reconnect is NOT triggered on a malformed M6
///   3. reset() leaves the flow in a state where garbage frames don't reach .connected
@MainActor
final class PairingFlowTests: XCTestCase {

    // MARK: - Helpers

    private func makeDevice() -> AppleTVDevice {
        AppleTVDevice(
            id: "test-device",
            name: "Test ATV",
            endpoint: NWEndpoint.hostPort(host: "10.0.0.1", port: 49152),
            host: "10.0.0.1",
            port: 49152
        )
    }

    private func tlv8(step: UInt8) -> Data {
        var t = TLV8()
        t.append(.state, byte: step)
        return t.encode()
    }

    private func tlv8(step: UInt8, error errorCode: UInt8) -> Data {
        var t = TLV8()
        t.append(.state, byte: step)
        t.append(.error, byte: errorCode)
        return t.encode()
    }

    private func makeCreds() -> PairingCredentials {
        let ltsk = Curve25519.Signing.PrivateKey()
        return PairingCredentials(
            clientID:   "test-client",
            ltsk:       ltsk.rawRepresentation,
            ltpk:       ltsk.publicKey.rawRepresentation,
            deviceLTPK: ltsk.publicKey.rawRepresentation,
            deviceID:   "test-device"
        )
    }

    private func makeFlow(
        sendFrame:        @escaping (CompanionFrame.FrameType, Data) -> Void = { _, _ in },
        setState:         @escaping (ConnectionState) -> Void               = { _ in },
        installKeys:      @escaping (SymmetricKey, SymmetricKey) -> Void    = { _, _ in },
        reconnect:        @escaping (AppleTVDevice) -> Void                 = { _ in },
        saveCredentials:  @escaping (PairingCredentials, String) -> Void    = { _, _ in },
        deleteCredentials: @escaping (String) -> Void                       = { _ in }
    ) -> PairingFlow {
        PairingFlow(delegate: PairingFlow.Delegate(
            sendFrame:         sendFrame,
            setState:          setState,
            installKeys:       installKeys,
            reconnect:         reconnect,
            saveCredentials:   saveCredentials,
            deleteCredentials: deleteCredentials
        ))
    }

    // MARK: - 1. Credentials deleted on server rejection, not on transient failure

    func testCredentialsDeletedOnServerErrorM4() {
        var deletedID: String?
        var finalState: ConnectionState?

        let flow = makeFlow(
            setState:          { finalState = $0 },
            deleteCredentials: { deletedID = $0 }
        )
        flow.startPairVerify(credentials: makeCreds())

        // PV_Next M4 with explicit HAP error tag → serverError path
        let payload = OPACK.wrapPairingData(tlv8(step: 4, error: 2))
        flow.handlePvNext(payload, deviceID: "test-device")

        XCTAssertEqual(deletedID, "test-device")
        if case .error = finalState { } else {
            XCTFail("expected .error state, got \(String(describing: finalState))")
        }
    }

    func testCredentialsNotDeletedOnTransientCryptoFailure() {
        var deletedID: String?

        let flow = makeFlow(deleteCredentials: { deletedID = $0 })
        flow.startPairVerify(credentials: makeCreds())

        // Garbage M4 — will throw a crypto error, not a serverError
        let garbage = OPACK.wrapPairingData(Data([0x04, 0x01, 0x04]))
        flow.handlePvNext(garbage, deviceID: "test-device")

        XCTAssertNil(deletedID, "credentials must NOT be deleted on transient crypto failure")
    }

    // MARK: - 2. Malformed M6 does not save credentials or reconnect

    func testMalformedM6DoesNotSaveOrReconnect() {
        var savedID: String?
        var reconnectCalled = false

        let flow = makeFlow(
            reconnect:       { _ in reconnectCalled = true },
            saveCredentials: { _, id in savedID = id }
        )

        let badM6 = OPACK.wrapPsNextData(tlv8(step: 6))
        flow.handlePsNext(badM6, device: makeDevice())

        XCTAssertNil(savedID,           "credentials must not be saved on malformed M6")
        XCTAssertFalse(reconnectCalled, "reconnect must not be triggered on malformed M6")
    }

    // MARK: - 3. reset() prevents reaching .connected on subsequent garbage frames

    func testResetPreventsConnectedState() {
        var states: [ConnectionState] = []

        let flow = makeFlow(setState: { states.append($0) })
        flow.startPairVerify(credentials: makeCreds())
        flow.reset()

        // Garbage M4 after reset must not reach .connected
        let garbage = OPACK.wrapPairingData(Data([0x04, 0x01, 0x04]))
        flow.handlePvNext(garbage, deviceID: "x")

        XCTAssertFalse(states.contains(.connected))
    }

    // MARK: - 4. startPairVerify sends pvStart frame

    func testStartPairVerifySendsPvStartFrame() {
        var sentType: CompanionFrame.FrameType?

        let flow = makeFlow(sendFrame: { type, _ in sentType = type })
        flow.startPairVerify(credentials: makeCreds())

        XCTAssertEqual(sentType, .pvStart)
    }

    // MARK: - 5. startPairSetup sends psStart frame

    func testStartPairSetupSendsPsStartFrame() {
        var sentType: CompanionFrame.FrameType?

        let flow = makeFlow(sendFrame: { type, _ in sentType = type })
        flow.startPairSetup()

        XCTAssertEqual(sentType, .psStart)
    }

    // MARK: - 6. M2 pair-setup triggers awaitingPairingPin state

    func testPsNextM2SetsAwaitingPairingPin() {
        var finalState: ConnectionState?

        let flow = makeFlow(setState: { finalState = $0 })

        let m2payload = OPACK.wrapPsNextData(tlv8(step: 2))
        flow.handlePsNext(m2payload, device: makeDevice())

        XCTAssertEqual(finalState, .awaitingPairingPin)
    }
}
