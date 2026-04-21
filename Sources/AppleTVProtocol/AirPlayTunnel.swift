import Foundation
import Network
import CryptoKit
import AppleTVLogging

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
    public struct Tunnel {
        /// The encrypted RTSP control channel (keep alive / send feedback).
        public let rtsp: EncryptedAirPlayRTSP
        /// The MRP data channel — ready to receive now-playing pushes.
        public let mrp:  MRPDataChannel
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
    public static func open(host: String,
                            credentials: AirPlayCredentials,
                            connectTimeout: TimeInterval = 5) throws -> Tunnel {
        let (rtsp, sharedSecret) = try openHTTP(host: host, credentials: credentials,
                                                connectTimeout: connectTimeout)

        // SETUP #1 — event channel.
        let sessionUUID = UUID().uuidString.uppercased()
        let rtspURI = "rtsp://\(host)/\(sessionUUID)"
        let setupBody1: [String: Any] = [
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
        let setup1Data = try encodePlist(setupBody1)
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
        Log.pairing.report("AirPlayTunnel: SETUP #1 → eventPort=\(eventPort)")

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
        Log.pairing.report("AirPlayTunnel: SETUP #2 → dataPort=\(dataPort)")

        // Connect new TCP socket to dataPort.
        let dataEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(dataPort))!
        )
        let dataConn = NWConnection(to: dataEndpoint, using: .tcp)
        let dataQueue = DispatchGroup()
        dataQueue.enter()
        var dataConnReady = false
        dataConn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                dataConnReady = true
                dataQueue.leave()
            case .failed, .cancelled, .waiting:
                dataQueue.leave()
            default: break
            }
        }
        dataConn.start(queue: DispatchQueue(label: "MRPDataChannel.connect"))
        guard dataQueue.wait(timeout: .now() + 10) == .success, dataConnReady else {
            throw OpenError.dataConnect("TCP connect to \(host):\(dataPort) timed out or failed")
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
        let mrp = MRPDataChannel(connection: dataConn, session: dataSession)
        mrp.start()
        Log.pairing.report("AirPlayTunnel: MRP data channel up")

        // MRP init sequence.
        let uid = UUID().uuidString
        do {
            try mrp.send(MRPMessage.deviceInfo(uniqueIdentifier: uid))
            Log.pairing.report("AirPlayTunnel: sent DEVICE_INFO")
            try mrp.send(MRPMessage.setConnectionState())
            Log.pairing.report("AirPlayTunnel: sent SET_CONNECTION_STATE")
            try mrp.send(MRPMessage.clientUpdatesConfig())
            Log.pairing.report("AirPlayTunnel: sent CLIENT_UPDATES_CONFIG")
        } catch {
            throw OpenError.mrpInit("\(error)")
        }

        return Tunnel(rtsp: rtsp, mrp: mrp)
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

        let connection = http.detach()
        let session = HAPSession(writeKey: keys.writeKey, readKey: keys.readKey)
        let rtsp = EncryptedAirPlayRTSP(connection: connection, session: session, host: host)
        rtsp.start()
        Log.pairing.report("AirPlayTunnel: control channel encrypted (\(host))")
        return (rtsp, keys.sharedSecret)
    }

    // MARK: - Helpers

    private static func encodePlist(_ obj: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
    }

    private static func decodePlist(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }
}
