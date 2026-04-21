import Foundation
import Darwin
import Network
import CryptoKit
import AppleTVLogging
import AppleTVProtocol

// `atv --standalone` — single-shot Companion client that runs without the
// AppleTVRemote.app. Discovers Apple TVs via Bonjour, performs a pair-verify
// using credentials already in the Keychain (from a previous app pairing),
// and fires one command before tearing down.
//
// Scope:
//   - list         — enumerate Apple TVs on the LAN
//   - key / pp / … — send one HID press (down+up)
//   - power        — send wake (release-only; no state knowledge without a
//                    live session, so we always send wake in standalone)
//
// Not supported: pair-setup (PIN-based initial pairing), status/now-playing
// (would need a live subscription). For those, run AppleTVRemote.app first.
//
// The orchestration here is intentionally single-shot: no keepalive, no
// auto-reconnect, no event loop. That keeps the code below ~200 lines rather
// than mirroring CompanionConnection's 770-line long-lived session.

// MARK: - Discovery

enum StandaloneDiscovery {
    /// Discover + resolve Apple TVs on the LAN. Returns once at least one
    /// device is fully resolved (host + port) or `timeout` elapses.
    ///
    /// Implementation detail: we use NWBrowser to find services and then
    /// NWConnection to resolve each endpoint to an (IP, port) pair. NWConnection
    /// does the resolution on its own internal queue, so we don't need to pump
    /// a run loop or own one like NetService requires. That was the hang bug
    /// in an earlier draft — NetService was scheduled on RunLoop.main but
    /// delegate callbacks never fired because this CLI tool doesn't run the
    /// main loop by default.
    static func discover(timeout: TimeInterval = 3.0) -> [AppleTVDevice] {
        let queue = DispatchQueue(label: "atv.standalone.discovery")
        let lock  = NSLock()
        var found: [String: AppleTVDevice] = [:]
        var seenNames: Set<String> = []
        var resolvers: [NWConnection] = []

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_companion-link._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }

                // Deduplicate — the browser fires again when TXT records update.
                lock.lock()
                let isNew = seenNames.insert(name).inserted
                lock.unlock()
                if !isNew { continue }

                // Filter at browse time where possible. Apple TVs advertise
                // rpMd like "AppleTV14,1". HomePods and Macs also appear on
                // _companion-link._tcp; we drop them here if the TXT is present.
                if case .bonjour(let txt) = result.metadata {
                    let model = txt.dictionary["rpMd"] ?? ""
                    if !model.isEmpty && !model.hasPrefix("AppleTV") { continue }
                }

                // Resolve via UDP NWConnection — we want only the IP, not a
                // real connection. UDP avoids a TCP handshake to the companion
                // port, which would confuse the ATV's pairing state machine.
                // IPv4-only: StandaloneSession uses AF_INET + inet_pton.
                let udpParams = NWParameters.udp
                if let ipOpts = udpParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOpts.version = .v4
                }
                let conn = NWConnection(to: result.endpoint, using: udpParams)
                lock.lock(); resolvers.append(conn); lock.unlock()

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .preparing:
                        if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint ?? .hostPort(host: "0.0.0.0", port: 0) {
                            let h: String = {
                                switch host {
                                case .ipv4(let a): return "\(a)"
                                case .ipv6(let a): return "\(a)"
                                case .name(let n, _): return n
                                @unknown default: return ""
                                }
                            }()
                            if !h.isEmpty, h != "0.0.0.0" {
                                lock.lock()
                                var dev = AppleTVDevice(id: name, name: name, endpoint: result.endpoint)
                                dev.host = h.split(separator: "%").first.map(String.init) ?? h
                                dev.port = port.rawValue
                                found[name] = dev
                                lock.unlock()
                                conn.cancel()
                            }
                        }
                    case .failed, .cancelled:
                        break
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
            }
        }

        browser.start(queue: queue)

        // Simple blocking wait — all callbacks run on the browser's queue so
        // there's no run-loop to pump. Poll every 50 ms.
        let deadline = Date().addingTimeInterval(timeout)
        var graceUntil: Date?
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            let anyResolved = !found.isEmpty
            lock.unlock()
            if anyResolved && graceUntil == nil {
                graceUntil = Date().addingTimeInterval(0.3)
            }
            if let g = graceUntil, Date() >= g { break }
        }
        browser.cancel()
        for r in resolvers { r.cancel() }

        lock.lock()
        let devices = Array(found.values).sorted { $0.name < $1.name }
        lock.unlock()
        return devices
    }
}

// MARK: - Standalone session

/// Thrown from StandaloneSession when the operation can't complete.
enum StandaloneError: Error, LocalizedError {
    case notFound(String)
    case noCredentials(String)
    case tcpConnectFailed(String)
    case protocolFailure(String)
    case deviceNotResolved(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let m):           return "device not found: \(m)"
        case .noCredentials(let m):      return "no pairing credentials for \(m) — run AppleTVRemote.app first and pair there, or `atv pair \(m)`"
        case .tcpConnectFailed(let m):   return "TCP connect failed: \(m)"
        case .protocolFailure(let m):    return "protocol error: \(m)"
        case .deviceNotResolved(let m):  return "device not resolved: \(m)"
        }
    }
}

/// Single-shot Companion session: TCP connect → pair-verify → send one HID
/// (or series) → close. Blocking synchronous API; no keepalive, no events.
final class StandaloneSession {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var encryptKey: SymmetricKey?
    private var decryptKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var recvNonce: UInt64 = 0
    private var txn: UInt32 = 0
    private let creds: PairingCredentials
    private let device: AppleTVDevice

    init(device: AppleTVDevice, credentials: PairingCredentials) {
        self.device = device
        self.creds = credentials
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    // MARK: Open TCP

    func open() throws {
        guard let host = device.host, let port = device.port else {
            throw StandaloneError.deviceNotResolved(device.name)
        }
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            throw StandaloneError.tcpConnectFailed("socket(): \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            Darwin.close(s)
            throw StandaloneError.tcpConnectFailed("inet_pton failed for \(host)")
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let err = String(cString: strerror(errno))
            Darwin.close(s)
            throw StandaloneError.tcpConnectFailed("\(host):\(port) — \(err)")
        }
        // Modest receive timeout so we don't hang forever if the ATV stops responding.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
    }

    // MARK: Pair-verify

    func pairVerify() throws {
        let verify = CompanionPairVerify(credentials: creds)
        // M1 — must be OPACK-wrapped with {"_pd": tlv8, "_auTy": 4}
        try writeFrame(.pvStart, payload: OPACK.wrapPvStartData(verify.m1Payload()))
        // M2 — ATV sends OPACK dict; extract raw TLV8 before processing
        let m2Raw = try readFrame(expected: .pvNext)
        let m2 = OPACK.extractPairingData(from: m2Raw) ?? m2Raw
        let m3 = try verify.processM2(m2)
        // M3 — wrap raw TLV8 in {"_pd": ...}
        try writeFrame(.pvNext, payload: OPACK.wrapPairingData(m3))
        // M4 — extract TLV8 then verify
        let m4Raw = try readFrame(expected: .pvNext)
        let m4 = OPACK.extractPairingData(from: m4Raw) ?? m4Raw
        try verify.verifyM4(m4)
        // Derive session keys
        guard let enc = verify.sessionEncryptKey, let dec = verify.sessionDecryptKey else {
            throw StandaloneError.protocolFailure("pair-verify did not produce session keys")
        }
        encryptKey = enc
        decryptKey = dec
    }

    /// Minimal post-verify session bring-up: send the Companion handshake dicts
    /// the ATV expects before it will honour HID commands. Mirrors
    /// CompanionConnection.startCompanionSession() (sans _interest subscriptions,
    /// which are only useful for long-lived sessions).
    func startSession() throws {
        let t1 = nextTxn()
        try sendEncrypted(OPACK.encodeSystemInfo(clientID: creds.clientID, txn: t1))
        let t2 = nextTxn()
        try sendEncrypted(OPACK.encodeTouchStart(txn: t2))
        let t3 = nextTxn()
        try sendEncrypted(OPACK.encodeSessionStart(txn: t3, localSID: UInt32.random(in: 0..<UInt32.max)))
        let t4 = nextTxn()
        try sendEncrypted(OPACK.encodeTextInputStart(txn: t4))
        // Small grace period so the ATV actually finishes establishing before
        // we fire HID. On fast LANs this is usually already satisfied by the
        // pair-verify round trips, but 50ms of slack costs us nothing.
        Thread.sleep(forTimeInterval: 0.05)
    }

    // MARK: HID send

    func sendHID(_ command: RemoteCommand) throws {
        let keycode = command.hidKeycode
        if command.sendReleaseOnly {
            try sendEncrypted(hidOPACK(state: 2, keycode: keycode))
        } else {
            try sendEncrypted(hidOPACK(state: 1, keycode: keycode))
            try sendEncrypted(hidOPACK(state: 2, keycode: keycode))
        }
        // Give the ATV a moment to apply the event before we close — otherwise
        // the TCP RST can race with the last encrypted write.
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Send a trackpad swipe gesture (series of _hidT touch events).
    func sendSwipe(_ direction: SwipeDirection) throws {
        let (start, end) = direction.coordinates
        let steps = 8

        // Re-send _touchStart before each swipe; use timestamps relative to
        // that moment — matches pyatv's _base_timestamp pattern.
        try sendEncrypted(OPACK.encodeTouchStart(txn: nextTxn()))
        Thread.sleep(forTimeInterval: 0.02)
        let baseNs = DispatchTime.now().uptimeNanoseconds

        // Press
        try sendEncrypted(OPACK.encodeTouchEvent(x: start.x, y: start.y, phase: 0,
                                                  txn: nextTxn(), nanoseconds: 0))
        // Hold / move
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            let x = start.x + (end.x - start.x) * f
            let y = start.y + (end.y - start.y) * f
            let relNs = DispatchTime.now().uptimeNanoseconds - baseNs
            try sendEncrypted(OPACK.encodeTouchEvent(x: x, y: y, phase: 1,
                                                      txn: nextTxn(), nanoseconds: relNs))
            Thread.sleep(forTimeInterval: 0.016)
        }
        // Release
        let relNsEnd = DispatchTime.now().uptimeNanoseconds - baseNs
        try sendEncrypted(OPACK.encodeTouchEvent(x: end.x, y: end.y, phase: 2,
                                                  txn: nextTxn(), nanoseconds: relNsEnd))
        Thread.sleep(forTimeInterval: 0.05)
        try sendEncrypted(OPACK.encodeTouchStop(txn: nextTxn()))
        Thread.sleep(forTimeInterval: 0.1)
    }

    private func hidOPACK(state: Int, keycode: UInt8) -> Data {
        let t = nextTxn()
        return OPACK.pack([
            "_i": "_hidC", "_t": 2, "_x": t,
            "_c": ["_hBtS": state, "_hidC": Int(keycode)] as [String: Any],
        ] as [String: Any])
    }

    private func nextTxn() -> UInt32 { let v = txn; txn &+= 1; return v }

    // MARK: Frame I/O

    private func writeFrame(_ type: CompanionFrame.FrameType, payload: Data) throws {
        let frame = CompanionFrame(type: type, payload: payload).encoded
        try writeAll(frame)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, p.advanced(by: sent), data.count - sent)
                if n <= 0 {
                    throw StandaloneError.protocolFailure("write failed: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    private func readFrame(expected: CompanionFrame.FrameType) throws -> Data {
        while true {
            if let frame = CompanionFrame.read(from: &buffer) {
                guard frame.type == expected else {
                    throw StandaloneError.protocolFailure("unexpected frame 0x\(String(frame.type.rawValue, radix: 16)), wanted 0x\(String(expected.rawValue, radix: 16))")
                }
                return frame.payload
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { throw StandaloneError.protocolFailure("connection closed by ATV") }
            if n  < 0 { throw StandaloneError.protocolFailure("read failed: \(String(cString: strerror(errno)))") }
            buffer.append(chunk, count: n)
        }
    }

    // MARK: Encrypted send (ChaCha20-Poly1305)

    private func sendEncrypted(_ opackData: Data) throws {
        guard let key = encryptKey else {
            throw StandaloneError.protocolFailure("no session key (pair-verify not run)")
        }
        let nonce = try ChaChaPoly.Nonce(data: nonceData(sendNonce))
        sendNonce &+= 1
        let payloadLen = opackData.count + 16
        let aad = Data([
            CompanionFrame.FrameType.eOPACK.rawValue,
            UInt8((payloadLen >> 16) & 0xFF),
            UInt8((payloadLen >>  8) & 0xFF),
            UInt8( payloadLen        & 0xFF),
        ])
        let sealed = try ChaChaPoly.seal(opackData, using: key, nonce: nonce, authenticating: aad)
        try writeFrame(.eOPACK, payload: sealed.ciphertext + sealed.tag)
    }

    private func nonceData(_ counter: UInt64) -> Data {
        var n = counter.littleEndian
        return Data(bytes: &n, count: 8) + Data(repeating: 0, count: 4)
    }
}

// MARK: - Top-level helpers called from main.swift

/// Pick a device by name, id, or — if `nameOrNil` is nil — the single device
/// discovered. Errors out if zero or multiple devices match.
func pickStandaloneDevice(nameOrNil: String?, discovered: [AppleTVDevice]) throws -> AppleTVDevice {
    if discovered.isEmpty { throw StandaloneError.notFound("no Apple TVs discovered") }
    if let q = nameOrNil {
        if let byID = discovered.first(where: { $0.id == q }) { return byID }
        if let byName = discovered.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return byName }
        throw StandaloneError.notFound("no device matching \"\(q)\"")
    }
    if discovered.count == 1 { return discovered[0] }
    let names = discovered.map(\.name).joined(separator: ", ")
    throw StandaloneError.notFound("multiple devices discovered (\(names)) — specify one with --device <name>")
}

func standaloneSendKey(deviceName: String?, command: RemoteCommand) throws {
    let devices = StandaloneDiscovery.discover(timeout: 8.0)
    let device = try pickStandaloneDevice(nameOrNil: deviceName, discovered: devices)
    let store = CredentialStore()
    guard store.hasCredentials(for: device.id), let creds = store.load(deviceID: device.id) else {
        throw StandaloneError.noCredentials(device.name)
    }
    let session = StandaloneSession(device: device, credentials: creds)
    try session.open()
    try session.pairVerify()
    try session.startSession()
    try session.sendHID(command)
}

func standaloneSwipe(deviceName: String?, direction: SwipeDirection) throws {
    let devices = StandaloneDiscovery.discover(timeout: 8.0)
    let device = try pickStandaloneDevice(nameOrNil: deviceName, discovered: devices)
    let store = CredentialStore()
    guard store.hasCredentials(for: device.id), let creds = store.load(deviceID: device.id) else {
        throw StandaloneError.noCredentials(device.name)
    }
    let session = StandaloneSession(device: device, credentials: creds)
    try session.open()
    try session.pairVerify()
    try session.startSession()
    try session.sendSwipe(direction)
}

func standaloneList() throws {
    let devices = StandaloneDiscovery.discover(timeout: 8.0)
    if devices.isEmpty {
        print(yellow("No Apple TVs discovered."))
        return
    }
    let store = CredentialStore()
    let nameWidth = max(12, devices.map { $0.name.count }.max() ?? 12)
    for d in devices {
        let paired = store.hasCredentials(for: d.id)
        let host = d.host.map { "\($0):\(d.port ?? 0)" } ?? "?"
        let name = d.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let pairedStr = paired ? green("paired") : yellow("unpaired")
        print("  \(name)  \(dim(host))  \(pairedStr)")
    }
}

// MARK: - Auto-fallback detection

/// Returns true if we appear to be in a headless/SSH session where `open -b`
/// is likely to fail (no WindowServer/Aqua). We detect this by the absence of
/// `SECURITYSESSIONID` in the environment — Aqua sessions always set it;
/// SSH and launchd sessions don't.
func isHeadlessSession() -> Bool {
    ProcessInfo.processInfo.environment["SECURITYSESSIONID"] == nil
}

