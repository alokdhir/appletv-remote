import Foundation
import Network
import CryptoKit
import AppleTVLogging

/// Thread-safe one-shot flag for use inside NWConnection/NWBrowser callbacks.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns true the first time called; false every subsequent call.
    func fire() -> Bool { lock.withLock { if fired { return false }; fired = true; return true } }
}

/// One-shot helper to open an encrypted AirPlay 2 RTSP tunnel and bring up
/// the MRP data-stream channel.
///
/// Full sequence (mirrors pyatv/protocols/airplay/ap2_session.py):
///
///   1. TCP connect to host:7000
///   2. AirPlay pair-verify → derive Control-Write/Read keys
///   3. Detach NWConnection → wrap in HAPSession → EncryptedAirPlayRTSP
///   4. RTSP SETUP #1 — event channel plist → get `eventPort`
///   5. RTSP RECORD
///   6. RTSP SETUP #2 — data stream plist (type=130, seed) → get `dataPort`
///   7. New TCP connection to host:dataPort
///   8. Derive DataStream keys from Control ECDH shared secret:
///        salt = "DataStream-Salt\(seed)"
///        outKey  info = "DataStream-Output-Encryption-Key"
///        inKey   info = "DataStream-Input-Encryption-Key"
///   9. Wrap new connection in HAPSession → MRPDataChannel
///  10. MRP init: DEVICE_INFO → SET_CONNECTION_STATE → CLIENT_UPDATES_CONFIG
public enum AirPlayTunnel {

    public enum OpenError: Error, CustomStringConvertible {
        case connect(Error)
        case verify(Error)
        case setup(String)
        case record(String)
        case dataConnect(String)
        case mrpInit(String)

        public var description: String {
            switch self {
            case .connect(let e):     return "tcp connect failed: \(e)"
            case .verify(let e):      return "pair-verify failed: \(e)"
            case .setup(let m):       return "RTSP SETUP failed: \(m)"
            case .record(let m):      return "RTSP RECORD failed: \(m)"
            case .dataConnect(let m): return "data channel connect failed: \(m)"
            case .mrpInit(let m):     return "MRP init failed: \(m)"
            }
        }
    }

    /// Result of a successful tunnel open.
    public struct Tunnel: @unchecked Sendable {
        /// The encrypted RTSP control channel (keep alive / send feedback).
        public let rtsp:      EncryptedAirPlayRTSP
        /// The MRP data channel — ready to receive now-playing pushes.
        public let mrp:       MRPDataChannel
        /// Event channel — HAP-encrypted RTSP channel used by the ATV to push
        /// device capabilities. Must be kept alive (and responded to) so the
        /// ATV sends MRP now-playing pushes on the data channel.
        public let event: AirPlayEventChannel

        /// Cancel all three underlying NWConnections. Idempotent via NWConnection.cancel.
        public func close() {
            rtsp.close()
            mrp.close()
            event.close()
        }
    }

    // MARK: - Open (control only, for pair-verify gate)

    /// Open only the encrypted RTSP control channel (no MRP). Used by the
    /// `airplay-tunnel` CLI command for Phase 1 / 2 gate testing.
    public static func openControl(host: String,
                                   credentials: AirPlayCredentials,
                                   connectTimeout: TimeInterval = 5) throws -> EncryptedAirPlayRTSP {
        let (rtsp, _) = try openHTTP(host: host, credentials: credentials,
                                     connectTimeout: connectTimeout)
        return rtsp
    }

    // MARK: - Open (full MRP tunnel)

    /// Open the control channel + negotiate the MRP data stream.
    /// On return, `mrp.onMessage` is ready to be set; the MRP init sequence
    /// (DEVICE_INFO → SET_CONNECTION_STATE → CLIENT_UPDATES_CONFIG) has been sent.
    /// Long-lived serial queue for blocking tunnel-open work. Reused across
    /// every `open()` call so we don't allocate a kernel thread per
    /// invocation (matters under reconnect storms — flaky network, repeated
    /// auto-reconnect cycles, dev iteration).
    ///
    /// Serial because open() runs a self-contained handshake; concurrent
    /// opens against the same ATV would race on the device-side state
    /// machine anyway.
    private static let openQueue = DispatchQueue(label: "AirPlayTunnel.open",
                                                 qos: .userInitiated)

    public static func open(host: String,
                            credentials: AirPlayCredentials,
                            mrpClientID: String? = nil,
                            onMessage: (@Sendable (Data) -> Void)? = nil,
                            connectTimeout: TimeInterval = 5) async throws -> Tunnel {
        // All BSD socket I/O (openHTTP + RTSP requests) is blocking — run it on
        // a dedicated queue so we never stall the cooperative thread pool.
        try await withCheckedThrowingContinuation { cont in
            openQueue.async {
                do {
                    let tunnel = try openOnThread(host: host,
                                                 credentials: credentials,
                                                 mrpClientID: mrpClientID,
                                                 onMessage: onMessage,
                                                 connectTimeout: connectTimeout)
                    cont.resume(returning: tunnel)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous implementation — must be called from a dedicated thread, not
    /// from the Swift cooperative thread pool.
    private static func openOnThread(host: String,
                                     credentials: AirPlayCredentials,
                                     mrpClientID: String?,
                                     onMessage: (@Sendable (Data) -> Void)?,
                                     connectTimeout: TimeInterval) throws -> Tunnel {
        let (rtsp, sharedSecret) = try openHTTP(host: host, credentials: credentials,
                                                connectTimeout: connectTimeout)
        // Hoist so the catch can cancel whichever channels were already started
        // before the failing step — the outer catch only had rtsp.close().
        var eventChannel: AirPlayEventChannel?
        var dataConn: NWConnection?
        var mrp: MRPDataChannel?
        do {

        // SETUP #1 — event channel. The RTSP URI format MUST be
        // `rtsp://<client-ip>/<random-32bit-id>` (same as pyatv). tvOS 18
        // silently drops requests whose URI has the server's IP or a UUID
        // in the path — confirmed by diffing our wire trace against pyatv.
        let sessionUUID = UUID().uuidString.uppercased()   // still used in body
        let rtspURI = rtsp.rtspURI
        let setup1Data = try encodePlist(eventSetupBody(sessionUUID: sessionUUID))
        let r1 = try rtsp.request(method: "SETUP", uri: rtspURI,
                                  headers: ["Content-Type": "application/x-apple-binary-plist"],
                                  body: setup1Data)
        guard r1.status == 200 else {
            throw OpenError.setup("SETUP #1 returned \(r1.status)")
        }
        guard let plist1 = decodePlist(r1.body),
              let eventPort = plist1["eventPort"] as? Int else {
            throw OpenError.setup("SETUP #1 response missing eventPort")
        }
        guard let eventPortValue = NWEndpoint.Port(rawValue: UInt16(exactly: eventPort) ?? 0),
              eventPort > 0 else {
            throw OpenError.setup("SETUP #1 returned invalid eventPort=\(eventPort)")
        }
        Log.pairing.report("AirPlayTunnel: SETUP #1 → eventPort=\(eventPort)")

        // Connect to the event channel TCP socket before sending RECORD.
        // pyatv does this in _setup_event_channel() before calling record().
        // tvOS 18 apparently waits for the event channel connection before
        // responding to RECORD — omitting this causes RECORD to time out
        // (~10 s) before the ATV eventually responds. The event channel
        // carries no useful data for our use-case (remote-control only),
        // but the TCP connection must exist. Keys are derived the same way
        // as pair-verify but with fixed "Events-Salt" salt.
        // pyatv verify2(salt, output_info="Events-Read-Encryption-Key",
        //                     input_info="Events-Write-Encryption-Key"):
        //   output_key (encrypt outgoing, client→ATV) = hkdf(info="Events-Read-Encryption-Key")
        //   input_key  (decrypt incoming, ATV→client) = hkdf(info="Events-Write-Encryption-Key")
        // So our HAPSession writeKey = Read-info, readKey = Write-info.
        let evWriteKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt:             Data("Events-Salt".utf8),
            info:             Data("Events-Read-Encryption-Key".utf8),
            outputByteCount:  32
        )
        let evReadKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt:             Data("Events-Salt".utf8),
            info:             Data("Events-Write-Encryption-Key".utf8),
            outputByteCount:  32
        )
        let eventEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: eventPortValue
        )
        let eventConn = NWConnection(to: eventEndpoint, using: .tcp)
        let eventGroup = DispatchGroup()
        let eventReady = OnceFlag()
        eventGroup.enter()
        eventConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if eventReady.fire() { eventGroup.leave() }
            case .failed, .cancelled, .waiting:
                if eventReady.fire() { eventGroup.leave() }
            default: break
            }
        }
        eventConn.start(queue: DispatchQueue(label: "AirPlayTunnel.event"))
        guard eventGroup.wait(timeout: .now() + 10) == .success else {
            throw OpenError.setup("event channel TCP connect to \(host):\(eventPort) timed out")
        }
        guard eventConn.state == .ready else {
            throw OpenError.setup("event channel TCP connect to \(host):\(eventPort) failed — state=\(eventConn.state)")
        }
        Log.pairing.report("AirPlayTunnel: event channel TCP connected (\(host):\(eventPort))")
        let evSession = HAPSession(
            writeKey: evWriteKey.withUnsafeBytes { Data($0) },
            readKey:  evReadKey.withUnsafeBytes  { Data($0) }
        )
        let eventCh = AirPlayEventChannel(connection: eventConn, session: evSession)
        eventCh.start()
        eventChannel = eventCh

        // RECORD.
        let rRecord = try rtsp.request(method: "RECORD", uri: rtspURI)
        guard rRecord.status == 200 else {
            throw OpenError.record("RECORD returned \(rRecord.status)")
        }
        Log.pairing.report("AirPlayTunnel: RECORD ✓")

        // SETUP #2 — data stream channel.
        let channelID  = UUID().uuidString.uppercased()
        let clientUUID = UUID().uuidString.uppercased()
        let seed       = UInt64.random(in: 0..<(1 << 63))
        let setupBody2: [String: Any] = [
            "streams": [[
                "controlType":           2,
                "channelID":             channelID,
                "seed":                  seed,
                "clientUUID":            clientUUID,
                "type":                  130,
                "wantsDedicatedSocket":  true,
                "clientTypeUUID":        "1910A70F-DBC0-4242-AF95-115DB30604E1",
            ] as [String: Any]]
        ]
        let setup2Data = try encodePlist(setupBody2)
        let r2 = try rtsp.request(method: "SETUP", uri: rtspURI,
                                  headers: ["Content-Type": "application/x-apple-binary-plist"],
                                  body: setup2Data)
        guard r2.status == 200 else {
            throw OpenError.setup("SETUP #2 returned \(r2.status)")
        }
        guard let plist2 = decodePlist(r2.body),
              let streams = plist2["streams"] as? [[String: Any]],
              let dataPort = streams.first?["dataPort"] as? Int else {
            throw OpenError.setup("SETUP #2 response missing dataPort")
        }
        guard let dataPortValue = NWEndpoint.Port(rawValue: UInt16(exactly: dataPort) ?? 0),
              dataPort > 0 else {
            throw OpenError.setup("SETUP #2 returned invalid dataPort=\(dataPort)")
        }
        Log.pairing.report("AirPlayTunnel: SETUP #2 → dataPort=\(dataPort)")

        // Connect new TCP socket to dataPort.
        let dataEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: dataPortValue
        )
        let _dataConn = NWConnection(to: dataEndpoint, using: .tcp)
        dataConn = _dataConn
        let dataGroup = DispatchGroup()
        let dataConnReady = OnceFlag()
        dataGroup.enter()
        _dataConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if dataConnReady.fire() { dataGroup.leave() }
            case .failed, .cancelled, .waiting:
                if dataConnReady.fire() { dataGroup.leave() }
            default: break
            }
        }
        _dataConn.start(queue: DispatchQueue(label: "MRPDataChannel.connect"))
        guard dataGroup.wait(timeout: .now() + 10) == .success else {
            throw OpenError.dataConnect("TCP connect to \(host):\(dataPort) timed out")
        }
        guard _dataConn.state == .ready else {
            throw OpenError.dataConnect("TCP connect to \(host):\(dataPort) failed — state=\(_dataConn.state)")
        }
        Log.pairing.report("AirPlayTunnel: data TCP connected to \(host):\(dataPort)")

        // Derive DataStream keys from the Control ECDH shared secret.
        let saltStr = "DataStream-Salt\(seed)"
        let outKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt:             Data(saltStr.utf8),
            info:             Data("DataStream-Output-Encryption-Key".utf8),
            outputByteCount:  32
        )
        let inKey = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt:             Data(saltStr.utf8),
            info:             Data("DataStream-Input-Encryption-Key".utf8),
            outputByteCount:  32
        )
        let dataSession = HAPSession(
            writeKey: outKey.withUnsafeBytes { Data($0) },
            readKey:  inKey.withUnsafeBytes  { Data($0) }
        )
        let mrpChannel = MRPDataChannel(connection: _dataConn, session: dataSession)
        // Install the message callback BEFORE starting the receive loop and
        // sending init messages — the ATV may send its DEVICE_INFO response
        // and now-playing burst immediately after receiving our DEVICE_INFO,
        // which would arrive while open() is still executing (before the caller
        // can set onMessage on the returned Tunnel).
        mrpChannel.onMessage = onMessage
        mrpChannel.start()
        mrp = mrpChannel
        Log.pairing.report("AirPlayTunnel: MRP data channel up")

        // MRP init sequence. Use the Companion client ID if provided — the ATV
        // recognizes it from prior Companion pairing and immediately pushes
        // now-playing state. Without it the ATV silently accepts our messages
        // but does not push state (confirmed by comparing with pyatv's wire trace).
        let uid = mrpClientID ?? UUID().uuidString.uppercased()
        do {
            try mrpChannel.send(MRPMessage.deviceInfo(uniqueIdentifier: uid))
            Log.pairing.report("AirPlayTunnel: sent DEVICE_INFO")
            try mrpChannel.send(MRPMessage.setConnectionState())
            Log.pairing.report("AirPlayTunnel: sent SET_CONNECTION_STATE")
            try mrpChannel.send(MRPMessage.clientUpdatesConfig())
            Log.pairing.report("AirPlayTunnel: sent CLIENT_UPDATES_CONFIG")
            try mrpChannel.send(MRPMessage.getKeyboardSession())
            Log.pairing.report("AirPlayTunnel: sent GET_KEYBOARD_SESSION")
        } catch {
            throw OpenError.mrpInit("\(error)")
        }

        return Tunnel(rtsp: rtsp, mrp: mrpChannel, event: eventCh)
        } catch {
            mrp?.close()
            if mrp == nil { dataConn?.cancel() }
            eventChannel?.close()
            rtsp.close()
            throw error
        }
    }

    // MARK: - Shared HTTP setup (pair-verify + HAP session)

    /// Returns (rtsp, sharedSecret). The shared secret is kept so SETUP #2 can
    /// derive DataStream keys from the same ECDH material.
    private static func openHTTP(host: String,
                                 credentials: AirPlayCredentials,
                                 connectTimeout: TimeInterval) throws -> (EncryptedAirPlayRTSP, Data) {
        let http = AirPlayHTTP(host: host, port: 7000)
        do { try http.connect(timeoutSeconds: connectTimeout) }
        catch { throw OpenError.connect(error) }

        let keys: AirPlaySessionKeys
        do { keys = try AirPlayPairVerify(http: http, credentials: credentials).verify() }
        catch {
            http.close()
            throw OpenError.verify(error)
        }

        let session = HAPSession(writeKey: keys.writeKey, readKey: keys.readKey)
        // The sink we hand to detach must call into rtsp, but rtsp needs the
        // connection that detach returns. Route through a WeakBox so the sink
        // references rtsp weakly — otherwise rtsp → http (retainHTTP) → sink
        // → rtsp forms a retain cycle and the tunnel never frees.
        let box = RTSPWeakBox()
        let connection = http.detach { [box] data, err, isComplete in
            box.value?.handle(data: data, err: err, isComplete: isComplete)
        }
        let rtsp = EncryptedAirPlayRTSP(connection: connection, session: session, host: host)
        box.value = rtsp
        // Keep the AirPlayHTTP alive — its receiveLoop is what actually reads
        // bytes off the wire and forwards them to our sink. Without this the
        // local `http` deallocates when `openHTTP` returns, its `[weak self]`
        // receive callback fires with nil self when the SETUP response
        // arrives, and the bytes are silently discarded (kernel ACKs, but
        // userspace never processes). Four rounds of debugging, confirmed via
        // tcpdump: ATV sends 309B response, we ACK it, then nothing.
        rtsp.retainHTTP(http)
        rtsp.start()
        Log.pairing.report("AirPlayTunnel: control channel encrypted (\(host))")
        return (rtsp, keys.sharedSecret)
    }

    // MARK: - Helpers

    /// Standard RTSP SETUP body for the event channel (SETUP #1).
    /// Exposed so CLI diagnostic commands can build the same request without
    /// duplicating the field values.
    public static func eventSetupBody(sessionUUID: String) -> [String: Any] {
        [
            "isRemoteControlOnly": true,
            "osName":              "iPhone OS",
            "sourceVersion":       "550.10",
            "timingProtocol":      "None",
            "model":               "iPhone10,6",
            "deviceID":            "AA:BB:CC:DD:EE:FF",
            "osVersion":           "15.0",
            "osBuildVersion":      "19A5297e",
            "macAddress":          "AA:BB:CC:DD:EE:FF",
            "sessionUUID":         sessionUUID,
            "name":                "AppleTVRemote",
        ]
    }

    private static func encodePlist(_ obj: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
    }

    private static func decodePlist(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }
}

/// Weak holder used by `openHTTP` to break a retain cycle between the
/// `EncryptedAirPlayRTSP` instance and the HTTP detach sink that forwards
/// bytes back into it.
private final class RTSPWeakBox {
    weak var value: EncryptedAirPlayRTSP?
}
