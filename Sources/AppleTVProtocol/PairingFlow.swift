import Foundation
import CryptoKit
import AppleTVLogging

/// Drives the Companion pair-setup (SRP) and pair-verify (ECDH) state machines.
///
/// Owns `HAPPairing`, `CompanionPairVerify`, and the pending-M2 buffer. Knows
/// nothing about sockets, `ConnectionState`, or session logic — it communicates
/// entirely via the `PairingFlowDelegate` callbacks.
///
/// Lifetime: one instance per `CompanionConnection`, reset via `reset()` between
/// connections. `@MainActor` so it shares the connection's isolation domain.
@MainActor
public final class PairingFlow {

    // MARK: - Delegate

    /// Callbacks the flow fires back to `CompanionConnection`.
    public struct Delegate {
        /// Send a raw Companion frame (e.g. `.psStart`, `.psNext`, `.pvStart`, `.pvNext`).
        public var sendFrame: (CompanionFrame.FrameType, Data) -> Void
        /// The flow needs to change the connection's published state.
        public var setState: (ConnectionState) -> Void
        /// Pair-verify M4 succeeded — install these session keys into the transport.
        public var installKeys: (SymmetricKey, SymmetricKey) -> Void
        /// Pair-setup M6 completed successfully — reconnect to start pair-verify.
        public var reconnect: (AppleTVDevice) -> Void
        /// Save credentials after successful pair-setup.
        public var saveCredentials: (PairingCredentials, String) -> Void
        /// Delete credentials after a definitive pair-verify server rejection.
        public var deleteCredentials: (String) -> Void

        public init(
            sendFrame: @escaping (CompanionFrame.FrameType, Data) -> Void,
            setState: @escaping (ConnectionState) -> Void,
            installKeys: @escaping (SymmetricKey, SymmetricKey) -> Void,
            reconnect: @escaping (AppleTVDevice) -> Void,
            saveCredentials: @escaping (PairingCredentials, String) -> Void,
            deleteCredentials: @escaping (String) -> Void
        ) {
            self.sendFrame = sendFrame
            self.setState = setState
            self.installKeys = installKeys
            self.reconnect = reconnect
            self.saveCredentials = saveCredentials
            self.deleteCredentials = deleteCredentials
        }
    }

    // MARK: - State

    private var pairing: HAPPairing?
    private var pairVerify: CompanionPairVerify?
    private var pendingM2Data: Data?
    private let delegate: Delegate

    public init(delegate: Delegate) {
        self.delegate = delegate
    }

    /// Discard all in-progress pairing state. Called from `disconnect()`.
    public func reset() {
        pairing    = nil
        pairVerify = nil
        pendingM2Data = nil
    }

    // MARK: - Entry points (called by CompanionConnection)

    /// Begin pair-setup: generate M1 and send PS_Start.
    public func startPairSetup() {
        let p = HAPPairing()
        pairing = p
        let payload = p.m1Payload()
        delegate.sendFrame(.psStart, OPACK.wrapPsStartData(payload))
    }

    /// Begin pair-verify with stored credentials: generate M1 and send PV_Start.
    public func startPairVerify(credentials: PairingCredentials) {
        let verify = CompanionPairVerify(credentials: credentials)
        pairVerify = verify
        delegate.sendFrame(.pvStart, OPACK.wrapPvStartData(verify.m1Payload()))
    }

    /// Handle an incoming PS_Next frame (pair-setup steps M2/M4/M6).
    public func handlePsNext(_ payload: Data, device: AppleTVDevice) {
        let opackExtracted = OPACK.extractPairingData(from: payload)
        let extracted = opackExtracted ?? payload
        if opackExtracted == nil {
            let hex = payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            Log.companion.fail("Companion psNext: OPACK extraction failed, raw payload hex: \(hex)")
        }
        let tlv  = TLV8.decode(extracted)
        let step = tlv[.state]?.first ?? 0

        switch step {
        case 2:  // M2: ATV sent salt + public key → need PIN
            pendingM2Data = extracted
            delegate.setState(.awaitingPairingPin)

        case 4:  // M4: server proof verified → send M5
            do {
                let m5 = try pairing?.processM4(extracted) ?? Data()
                delegate.sendFrame(.psNext, OPACK.wrapPsNextData(m5))
            } catch {
                delegate.setState(.error("Pairing M4 failed: \(error)"))
            }

        case 6:  // M6: ATV identity → pairing complete, reconnect for verify
            do {
                let creds = try pairing?.processM6(extracted)
                guard let creds = creds as PairingCredentials? else {
                    delegate.setState(.error("Pairing M6: missing credentials"))
                    return
                }
                delegate.saveCredentials(creds, device.id)
                // Companion protocol requires pair-verify on a fresh TCP connection.
                delegate.reconnect(device)
            } catch {
                delegate.setState(.error("Pairing M6 failed: \(error)"))
            }

        default:
            Log.companion.fail("Companion: unexpected PS_Next state \(step)")
        }
    }

    /// Handle an incoming PV_Next frame (pair-verify steps M2/M4).
    public func handlePvNext(_ payload: Data, deviceID: String) {
        let extracted = OPACK.extractPairingData(from: payload) ?? payload
        let tlv  = TLV8.decode(extracted)
        let step = tlv[.state]?.first ?? 0
        Log.companion.trace("Companion pvNext step=\(step) (\(extracted.count) bytes TLV8)")

        switch step {
        case 2:  // M2: ATV sent ephemeral key + encrypted identity
            do {
                let m3 = try pairVerify?.processM2(extracted) ?? Data()
                delegate.sendFrame(.pvNext, OPACK.wrapPairingData(m3))
            } catch {
                delegate.setState(.error("Pair verify M2 failed: \(error)"))
            }

        case 4:  // M4: success or explicit server rejection
            do {
                try pairVerify?.verifyM4(extracted)
                if let enc = pairVerify?.sessionEncryptKey,
                   let dec = pairVerify?.sessionDecryptKey {
                    delegate.installKeys(enc, dec)
                }
                delegate.setState(.connected)
            } catch {
                if case CompanionPairVerify.VerifyError.serverError = error {
                    delegate.deleteCredentials(deviceID)
                }
                delegate.setState(.error("Pair verify failed: \(error)\nPress Connect to re-pair."))
            }

        default:
            Log.companion.fail("Companion: unexpected PV_Next state \(step)")
        }
    }

    /// Called from `CompanionConnection.submitPairingPin(_:)` after the user
    /// enters their PIN. Runs SRP off-main to avoid beachballing.
    public func submitPin(_ pin: String, onSend: @escaping (Data) -> Void, onError: @escaping (String) -> Void) {
        guard let m2 = pendingM2Data else { return }
        let capturedPairing = pairing
        Task.detached {
            do {
                let m3 = try capturedPairing?.processM2(m2, pin: pin) ?? Data()
                await MainActor.run { onSend(m3) }
            } catch {
                await MainActor.run { onError("Pairing M3 failed: \(error)") }
            }
        }
    }
}
