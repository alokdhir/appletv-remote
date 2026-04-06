import Foundation
import Network
import Combine
import CryptoKit

/// Manages a connection to an Apple TV via the Media Remote Protocol (MRP).
///
/// MRP message framing:
///   - Each message is prefixed with a variable-length integer (protobuf varint encoding)
///     that gives the byte length of the following protobuf payload.
///   - Messages are exchanged over a plain TCP connection (port resolved via Bonjour).
///   - Before any commands can be sent, the client must complete the SRP-based pairing
///     handshake. Once paired, the credentials are cached locally.
///
/// References:
///   - pyatv open-source implementation: https://github.com/postlund/pyatv
///   - MRP protobuf definitions mirrored from the pyatv project
@MainActor
final class MRPConnection: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var nowPlaying: NowPlayingInfo?

    private var connection: NWConnection?
    private let credentialStore = CredentialStore()
    private var receiveBuffer = Data()

    // MARK: - Connect

    func connect(to device: AppleTVDevice) {
        guard state == .disconnected else { return }
        state = .connecting

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
    }

    // MARK: - Remote Commands

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        guard let data = MRPMessage.remoteCommand(command).encoded() else { return }
        sendRaw(data)
    }

    // MARK: - Pairing

    /// Submit the 4-digit PIN shown on the Apple TV screen.
    func submitPairingPin(_ pin: String) {
        // TODO: Complete SRP pairing exchange using the provided PIN.
        // The full SRP flow involves:
        //   1. Client sends DEVICE_INFO_MESSAGE with client credentials
        //   2. Apple TV responds with a challenge
        //   3. Client computes SRP proof using PIN and sends it back
        //   4. Apple TV sends final verification
        // See pyatv/protocols/mrp/pairing.py for the reference implementation.
        print("Pairing PIN submitted: \(pin) — SRP exchange not yet implemented")
    }

    // MARK: - Private

    private func handleConnectionState(_ newState: NWConnection.State, device: AppleTVDevice) {
        switch newState {
        case .ready:
            startReceiving()
            if credentialStore.hasCredentials(for: device.id) {
                sendDeviceInfo(deviceID: device.id)
            } else {
                state = .awaitingPairingPin
            }
        case .failed(let error):
            state = .error(error.localizedDescription)
        case .cancelled:
            state = .disconnected
        default:
            break
        }
    }

    private func sendDeviceInfo(deviceID: String) {
        guard let data = MRPMessage.deviceInfo.encoded() else { return }
        sendRaw(data) { [weak self] in
            self?.state = .connected
        }
    }

    private func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("Send error: \(error)")
            }
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
        // MRP uses protobuf varint length-prefixed framing.
        while !receiveBuffer.isEmpty {
            var offset = 0
            guard let length = receiveBuffer.readVarint(at: &offset) else { break }

            let messageEnd = offset + Int(length)
            guard receiveBuffer.count >= messageEnd else { break }

            let messageData = receiveBuffer[offset..<messageEnd]
            receiveBuffer.removeFirst(messageEnd)

            handleMessage(Data(messageData))
        }
    }

    private func handleMessage(_ data: Data) {
        // TODO: Decode protobuf payload into typed MRP messages and update state.
        // Key message types to handle:
        //   SET_STATE_MESSAGE      — playback state (playing/paused/stopped)
        //   CONTENT_ITEM_UPDATE    — now-playing metadata (title, artist, artwork)
        //   DEVICE_INFO_MESSAGE    — device capabilities
        //   CRYPTO_PAIRING_MESSAGE — pairing handshake steps
        print("Received MRP message: \(data.count) bytes")
    }
}

// MARK: - Now Playing Info

struct NowPlayingInfo {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var playbackRate: Float = 0  // 0 = paused, 1 = playing
    var elapsedTime: TimeInterval?
    var duration: TimeInterval?
}

// MARK: - Data + Varint

private extension Data {
    /// Reads a protobuf-style varint from `offset`, advancing `offset` past it.
    func readVarint(at offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < count {
            let byte = self[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
