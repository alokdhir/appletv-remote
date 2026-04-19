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
    static func discover(timeout: TimeInterval = 3.0) -> [AppleTVDevice] {
        let queue = DispatchQueue(label: "atv.standalone.discovery")
        let lock  = NSLock()
        var found: [String: AppleTVDevice] = [:]
        var resolvers: [String: StandaloneResolver] = [:]

        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_companion-link._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
                // Filter to Apple TVs (mirrors DeviceDiscovery.handleBrowseResults).
                if case .bonjour(let txt) = result.metadata {
                    let model = txt.dictionary["rpMd"] ?? ""
                    if !model.isEmpty && !model.hasPrefix("AppleTV") { continue }
                    if model.isEmpty {
                        let rpflRaw = txt.dictionary["rpFl"] ?? txt.dictionary["rpfl"] ?? ""
                        if !rpflRaw.isEmpty,
                           let rpfl = UInt32(rpflRaw.hasPrefix("0x") ? String(rpflRaw.dropFirst(2)) : rpflRaw, radix: 16),
                           (rpfl & 0x4000) == 0 { continue }
                    }
                }

                lock.lock()
                let already = resolvers[name] != nil
                lock.unlock()
                if already { continue }

                let resolver = StandaloneResolver(name: name,
                                               type: type,
                                               domain: domain.isEmpty ? "local." : domain)
                lock.lock(); resolvers[name] = resolver; lock.unlock()

                resolver.resolve { host, port, txt in
                    // Double-check at resolve time (browse-time TXT may omit rpMd).
                    if let model = txt["rpMd"], !model.hasPrefix("AppleTV") { return }
                    lock.lock()
                    var dev = AppleTVDevice(id: name, name: name, endpoint: result.endpoint)
                    dev.host = host
                    dev.port = UInt16(port)
                    found[name] = dev
                    lock.unlock()
                }
            }
        }

        browser.start(queue: queue)

        // Wait until timeout, or until we have at least one resolved device.
        // We must pump the main runloop — StandaloneResolver schedules its
        // NetService on RunLoop.main, and without runloop ticks its delegate
        // callbacks never fire (resolution silently hangs).
        let deadline = Date().addingTimeInterval(timeout)
        var graceUntil: Date?
        while Date() < deadline {
            // Run the runloop for up to 100 ms at a time — returns early when
            // any source fires, so resolved callbacks unblock us promptly.
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            lock.lock()
            let anyResolved = found.values.contains { $0.host != nil }
            lock.unlock()
            if anyResolved && graceUntil == nil {
                // Give late resolutions 300 ms of additional grace.
                graceUntil = Date().addingTimeInterval(0.3)
            }
            if let g = graceUntil, Date() >= g { break }
        }
        browser.cancel()

        lock.lock()
        let devices = Array(found.values).filter { $0.host != nil }.sorted { $0.name < $1.name }
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
        // M1
        try writeFrame(.pvStart, payload: verify.m1Payload())
        // M2
        let m2 = try readFrame(expected: .pvNext)
        let m3 = try verify.processM2(m2)
        // M3
        try writeFrame(.pvNext, payload: m3)
        // M4
        let m4 = try readFrame(expected: .pvNext)
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
    let devices = StandaloneDiscovery.discover(timeout: 3.0)
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

func standaloneList() throws {
    let devices = StandaloneDiscovery.discover(timeout: 3.0)
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

// MARK: - Minimal NetService resolver (self-contained)

/// Compact Bonjour resolver for standalone mode. Mirrors the app's
/// ServiceResolver but lives inside the atv target — the app's version is
/// coupled to main-actor logging and we don't want to pull it along.
final class StandaloneResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var completion: ((String, Int, [String: String]) -> Void)?

    init(name: String, type: String, domain: String) {
        let t = type.hasSuffix(".") ? String(type.dropLast()) : type
        let d = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        service = NetService(domain: d, type: t, name: name)
        super.init()
        service.delegate = self
    }

    func resolve(completion: @escaping (String, Int, [String: String]) -> Void) {
        self.completion = completion
        // NetService insists on running on a run-loop; schedule on main so the
        // background DispatchQueue the browser runs on doesn't ignore it.
        DispatchQueue.main.async {
            self.service.schedule(in: RunLoop.main, forMode: .default)
            self.service.resolve(withTimeout: 5.0)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        var txt: [String: String] = [:]
        if let txtData = sender.txtRecordData() {
            let raw = NetService.dictionary(fromTXTRecord: txtData)
            txt = raw.compactMapValues { String(data: $0, encoding: .utf8) }
        }
        // Prefer IPv4 (AF_INET). On BSD: byte 1 of sockaddr = sa_family.
        let sorted = addresses.sorted { a, _ in
            a.withUnsafeBytes { $0.load(fromByteOffset: 1, as: UInt8.self) == 2 }
        }
        for addressData in sorted {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = addressData.withUnsafeBytes { rawPtr -> Bool in
                let sa = rawPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                return getnameinfo(sa, socklen_t(addressData.count),
                                   &hostname, socklen_t(NI_MAXHOST),
                                   nil, 0, NI_NUMERICHOST) == 0
            }
            if ok {
                let nullIdx = hostname.firstIndex(of: 0) ?? hostname.endIndex
                let ip = String(decoding: hostname[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                completion?(ip, sender.port, txt)
                completion = nil
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        completion = nil
    }
}
