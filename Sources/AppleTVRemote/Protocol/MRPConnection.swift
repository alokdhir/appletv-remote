import Foundation
import Network
import CryptoKit

/// Manages a connection to an Apple TV via the Media Remote Protocol (MRP).
///
/// MRP message framing:
///   Each message is prefixed by a protobuf varint giving the byte length of
///   the following protobuf ProtocolMessage payload.
///
/// Pairing flow (first connection):
///   1. TCP connect → send DEVICE_INFO_MESSAGE
///   2. Apple TV may respond with a pairing challenge (CRYPTO_PAIRING_MESSAGE)
///   3. Run HAP Pair Setup (M1–M6) using the 4-digit PIN shown on screen
///   4. Store credentials in Keychain via CredentialStore
///
/// Subsequent connections skip pairing and go straight to DEVICE_INFO → connected.
@MainActor
final class MRPConnection: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var nowPlaying: NowPlayingInfo?

    private var connection: NWConnection?
    private let credentialStore = CredentialStore()
    private var receiveBuffer = Data()
    private var pairing = HAPPairing()
    private var currentDevice: AppleTVDevice?

    // MARK: - Connect / Disconnect

    func connect(to device: AppleTVDevice) {
        guard state == .disconnected else { return }
        state = .connecting
        currentDevice = device
        pairing = HAPPairing()

        let connection = NWConnection(to: device.endpoint, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.handleConnectionState(newState, device: device)
            }
        }

        connection.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        state = .disconnected
        nowPlaying = nil
        currentDevice = nil
    }

    // MARK: - Remote Commands

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        guard let data = MRPMessage.remoteCommand(command).encoded() else { return }
        sendRaw(data)
    }

    // MARK: - Pairing PIN

    /// Submit the 4-digit PIN displayed on the Apple TV.
    func submitPairingPin(_ pin: String) {
        guard state == .awaitingPairingPin else { return }
        Task { @MainActor in
            do {
                // M3: process M2 data stored from server, build M3 payload
                // (the stored M2 TLV8 was cached on the pairing object already)
                if let m3 = try? pairing.processM2(pendingM2Data ?? Data(), pin: pin) {
                    sendCryptoPairingMessage(m3)
                }
            }
        }
    }

    // MARK: - Private state

    /// Temporarily stores the M2 TLV8 payload until the user enters their PIN.
    private var pendingM2Data: Data?

    // MARK: - Connection state handler

    private func handleConnectionState(_ newState: NWConnection.State, device: AppleTVDevice) {
        switch newState {
        case .ready:
            receiveBuffer.removeAll()
            startReceiving()
            sendDeviceInfo()
        case .failed(let error):
            state = .error(error.localizedDescription)
        case .cancelled:
            state = .disconnected
        default:
            break
        }
    }

    // MARK: - Sending

    private func sendDeviceInfo() {
        guard let data = MRPMessage.deviceInfo.encoded() else { return }
        sendRaw(data) { [weak self] in
            // After DEVICE_INFO, subscribe to now-playing updates
            self?.sendClientUpdatesSubscription()
        }
    }

    private func sendClientUpdatesSubscription() {
        guard let data = MRPMessage.clientUpdatesConfig.encoded() else { return }
        sendRaw(data)
    }

    private func sendCryptoPairingMessage(_ tlv8: Data) {
        guard let data = MRPMessage.cryptoPairing(tlv8).encoded() else { return }
        sendRaw(data)
    }

    private func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error { print("MRP send error: \(error)") }
            completion?()
        })
    }

    // MARK: - Receiving

    private func startReceiving() {
        receiveNextMessage()
    }

    private func receiveNextMessage() {
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

                if !isComplete {
                    self.receiveNextMessage()
                }
            }
        }
    }

    private func processBuffer() {
        while !receiveBuffer.isEmpty {
            var offset = 0
            guard let length = receiveBuffer.readVarint(at: &offset) else { break }
            let messageEnd = offset + Int(length)
            guard receiveBuffer.count >= messageEnd else { break }
            let messageData = Data(receiveBuffer[offset..<messageEnd])
            receiveBuffer.removeFirst(messageEnd)
            handleMessage(messageData)
        }
    }

    // MARK: - Message dispatch

    private func handleMessage(_ data: Data) {
        // Decode the ProtocolMessage type from field 1
        guard let msgType = data.protobufVarintField(fieldNumber: 1) else { return }

        switch msgType {
        case 6:  // CRYPTO_PAIRING_MESSAGE
            handleCryptoPairingMessage(data)
        case 1:  // DEVICE_INFO_MESSAGE — Apple TV acknowledged our hello
            if state == .connecting { state = .connected }
        default:
            if let update = MRPDecoder.decodeNowPlaying(from: data) {
                nowPlaying = update.applied(to: nowPlaying)
            }
        }
    }

    // MARK: - Pairing message handler

    private func handleCryptoPairingMessage(_ outerData: Data) {
        // CryptoPairingMessage is at extension field 6 in ProtocolMessage
        guard let innerData = outerData.protobufBytesField(fieldNumber: 6) else { return }
        // pairingData is field 1 of CryptoPairingMessage
        guard let tlv8Data = innerData.protobufBytesField(fieldNumber: 1) else { return }

        let tlv = TLV8.decode(tlv8Data)
        let serverState = tlv[.state]?.first ?? 0

        switch serverState {
        case 2:  // M2: server sent salt + public key
            handleM2(tlv8Data)
        case 4:  // M4: server proof
            handleM4(tlv8Data)
        case 6:  // M6: Apple TV identity
            handleM6(tlv8Data)
        default:
            print("Unexpected pairing state from server: \(serverState)")
        }
    }

    private func handleM2(_ data: Data) {
        pendingM2Data = data
        state = .awaitingPairingPin

        // Send M1 first if we haven't yet (initiate pairing)
        sendCryptoPairingMessage(pairing.m1Payload())
    }

    private func handleM4(_ data: Data) {
        do {
            let m5 = try pairing.processM4(data)
            sendCryptoPairingMessage(m5)
        } catch {
            state = .error("Pairing M4 failed: \(error)")
        }
    }

    private func handleM6(_ data: Data) {
        do {
            let creds = try pairing.processM6(data)
            if let device = currentDevice {
                credentialStore.save(credentials: creds, for: device.id)
            }
            state = .connected
        } catch {
            state = .error("Pairing M6 failed: \(error)")
        }
    }
}

// MARK: - Now Playing Info

struct NowPlayingInfo {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var playbackRate: Float = 0
    var elapsedTime: TimeInterval?
    var duration: TimeInterval?
}

// MARK: - Data + Varint framing

extension Data {
    /// Read a protobuf varint at `offset`, advancing offset past it.
    func readVarint(at offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < count {
            let byte = self[index(startIndex, offsetBy: offset)]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Decode the value of a varint field with the given field number.
    func protobufVarintField(fieldNumber: Int) -> UInt64? {
        var i = 0
        while i < count {
            guard let tag = readVarint(at: &i) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)
            switch wireType {
            case 0:  // varint
                guard let value = readVarint(at: &i) else { return nil }
                if field == fieldNumber { return value }
            case 2:  // length-delimited
                guard let len = readVarint(at: &i) else { return nil }
                if field == fieldNumber { return nil }  // not a varint field
                i += Int(len)
            default:
                return nil
            }
        }
        return nil
    }

    /// Decode the bytes value of a length-delimited field with the given field number.
    func protobufBytesField(fieldNumber: Int) -> Data? {
        var i = 0
        while i < count {
            guard let tag = readVarint(at: &i) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)
            switch wireType {
            case 0:  // varint — skip
                guard readVarint(at: &i) != nil else { return nil }
            case 2:  // length-delimited
                guard let len = readVarint(at: &i) else { return nil }
                let end = i + Int(len)
                if field == fieldNumber, end <= count {
                    return Data(self[index(startIndex, offsetBy: i)..<index(startIndex, offsetBy: end)])
                }
                i = end
            default:
                return nil
            }
        }
        return nil
    }
}
