import Foundation
import Network
import CryptoKit

/// Manages a connection to an Apple TV via the Companion protocol (_companion-link._tcp).
///
/// Connection flow:
///   First connection (no stored credentials):
///     TCP → PS_Start M1 → PS_Next M2 (show PIN) → M3 → M4 → M5 → M6 → session
///   Subsequent connections (stored credentials):
///     TCP → PV_Start M1 → PV_Next M2 → M3 → M4 → session
///   After session:
///     E_OPACK frames (ChaCha20-Poly1305 encrypted) for commands and events
@MainActor
final class CompanionConnection: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var nowPlaying: NowPlayingInfo?

    private var connection: NWConnection?
    private let credentialStore = CredentialStore()
    private var receiveBuffer = Data()
    private var currentDevice: AppleTVDevice?

    // Pairing state
    private var pairing: HAPPairing?
    private var pairVerify: CompanionPairVerify?
    private var pendingM2Data: Data?

    // Session encryption (after pair-verify completes)
    private var encryptKey: SymmetricKey?
    private var decryptKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var recvNonce: UInt64 = 0

    // MARK: - Connect / Disconnect

    func connect(to device: AppleTVDevice) {
        guard state == .disconnected else { return }
        state = .connecting
        currentDevice = device
        pairing = HAPPairing()
        sendNonce = 0
        recvNonce = 0

        let conn = NWConnection(to: device.endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.handleTCPState(newState, device: device)
            }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .disconnected
        nowPlaying = nil
        currentDevice = nil
        pairing = nil
        pairVerify = nil
        encryptKey = nil
        decryptKey = nil
    }

    // MARK: - Remote Commands (post-session)

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        // TODO: encode as OPACK HID event and send via encrypted E_OPACK frame
        // HID command format: {"_i": "sendHIDEvent", "_c": {"hidEventData": <encoded>}}
        print("Command \(command) — encrypted channel not yet implemented")
    }

    // MARK: - Pairing PIN

    func submitPairingPin(_ pin: String) {
        guard state == .awaitingPairingPin, let m2 = pendingM2Data else { return }
        Task { @MainActor in
            do {
                let m3 = try pairing?.processM2(m2, pin: pin) ?? Data()
                sendFrame(.psNext, payload: m3)
            } catch {
                self.state = .error("Pairing M3 failed: \(error)")
            }
        }
    }

    // MARK: - TCP state

    private func handleTCPState(_ tcpState: NWConnection.State, device: AppleTVDevice) {
        switch tcpState {
        case .ready:
            receiveBuffer.removeAll()
            startReceiving()
            if credentialStore.hasCredentials(for: device.id) {
                startPairVerify(device: device)
            } else {
                startPairSetup()
            }
        case .failed(let error):
            state = .error(error.localizedDescription)
        case .cancelled:
            state = .disconnected
        default:
            break
        }
    }

    // MARK: - Pair Setup

    private func startPairSetup() {
        guard let payload = pairing?.m1Payload() else { return }
        sendFrame(.psStart, payload: payload)
    }

    private func handlePsNext(_ payload: Data) {
        let tlv = TLV8.decode(payload)
        let step = tlv[.state]?.first ?? 0

        switch step {
        case 2:  // M2: ATV sent salt + public key → need PIN
            pendingM2Data = payload
            state = .awaitingPairingPin

        case 4:  // M4: server proof verified → auto-send M5
            do {
                let m5 = try pairing?.processM4(payload) ?? Data()
                sendFrame(.psNext, payload: m5)
            } catch {
                state = .error("Pairing M4 failed: \(error)")
            }

        case 6:  // M6: ATV identity → pairing complete
            do {
                let creds = try pairing?.processM6(payload)
                if let device = currentDevice, let creds {
                    credentialStore.save(credentials: creds, for: device.id)
                }
                // After setup, immediately verify to establish session keys
                startPairVerify(device: currentDevice!)
            } catch {
                state = .error("Pairing M6 failed: \(error)")
            }

        default:
            print("Companion: unexpected PS_Next state \(step)")
        }
    }

    // MARK: - Pair Verify

    private func startPairVerify(device: AppleTVDevice) {
        guard let creds = credentialStore.load(deviceID: device.id) else {
            // Credentials not found — start fresh pairing
            startPairSetup()
            return
        }
        let verify = CompanionPairVerify(credentials: creds)
        pairVerify = verify
        sendFrame(.pvStart, payload: verify.m1Payload())
    }

    private func handlePvNext(_ payload: Data) {
        let tlv = TLV8.decode(payload)
        let step = tlv[.state]?.first ?? 0

        switch step {
        case 2:  // M2: ATV sent its ephemeral key + encrypted identity
            do {
                let m3 = try pairVerify?.processM2(payload) ?? Data()
                sendFrame(.pvNext, payload: m3)
            } catch {
                state = .error("Pair verify M2 failed: \(error)")
            }

        case 4:  // M4: success
            do {
                try pairVerify?.verifyM4(payload)
                encryptKey = pairVerify?.sessionEncryptKey
                decryptKey = pairVerify?.sessionDecryptKey
                state = .connected
            } catch {
                // Verify failed — credentials may be stale, re-pair
                if let device = currentDevice {
                    credentialStore.delete(deviceID: device.id)
                }
                state = .error("Pair verify failed — re-pair required")
            }

        default:
            print("Companion: unexpected PV_Next state \(step)")
        }
    }

    // MARK: - Encrypted E_OPACK

    private func handleEOPACK(_ payload: Data) {
        guard let key = decryptKey else { return }
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData(recvNonce))
            recvNonce += 1
            let box   = try ChaChaPoly.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + payload)
            let plain = try ChaChaPoly.open(box, using: key)
            // TODO: decode OPACK from plain and dispatch now-playing updates
            _ = plain
        } catch {
            print("Companion: E_OPACK decrypt failed: \(error)")
        }
    }

    private func sendEncrypted(_ opackData: Data) {
        guard let key = encryptKey else { return }
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData(sendNonce))
            sendNonce += 1
            let sealed = try ChaChaPoly.seal(opackData, using: key, nonce: nonce)
            sendFrame(.eOPACK, payload: sealed.ciphertext + sealed.tag)
        } catch {
            print("Companion: encrypt failed: \(error)")
        }
    }

    /// 12-byte little-endian nonce from a counter.
    private func nonceData(_ counter: UInt64) -> Data {
        var n = counter.littleEndian
        return Data(bytes: &n, count: 8) + Data(repeating: 0, count: 4)
    }

    // MARK: - Sending

    private func sendFrame(_ type: CompanionFrame.FrameType, payload: Data) {
        let frame = CompanionFrame(type: type, payload: payload)
        connection?.send(content: frame.encoded, completion: .contentProcessed { error in
            if let error { print("Companion send error: \(error)") }
        })
    }

    // MARK: - Receiving

    private func startReceiving() {
        receiveNext()
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
                if let error {
                    self.state = .error(error.localizedDescription)
                    return
                }
                if !isComplete { self.receiveNext() }
            }
        }
    }

    private func processBuffer() {
        while let frame = CompanionFrame.read(from: &receiveBuffer) {
            switch frame.type {
            case .psNext:  handlePsNext(frame.payload)
            case .pvNext:  handlePvNext(frame.payload)
            case .eOPACK:  handleEOPACK(frame.payload)
            default:
                print("Companion: unhandled frame type \(frame.type)")
            }
        }
    }
}
