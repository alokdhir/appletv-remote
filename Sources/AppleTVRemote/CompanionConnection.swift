import Foundation
import Darwin
import AppleTVLogging
import AppleTVProtocol

/// Manages a connection to an Apple TV via the Companion protocol (_companion-link._tcp).
///
/// Uses raw BSD sockets (bypasses NWConnection TCC restrictions on macOS 14+).
/// Writes: Darwin.write() on writeQueue.
/// Reads:  blocking Darwin.read() loop on readQueue.
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

    private var connectionEpoch: Int = 0
    private let writeQueue = DispatchQueue(label: "companion.write", qos: .userInitiated)
    private let readQueue  = DispatchQueue(label: "companion.read",  qos: .userInitiated)
    private let credentialStore = CredentialStore()
    @Published var currentDevice: AppleTVDevice?

    // Session encryption — keys installed by PairingFlow after pair-verify.
    private let transport = EncryptedFrameTransport()

    // Pairing state machine — pair-setup (SRP) and pair-verify (ECDH).
    private lazy var pairingFlow = PairingFlow(delegate: makePairingDelegate())

    // Live session — non-nil from the moment the TCP connection is made until
    // disconnect(). Replaced on each reconnect.
    private var session: CompanionSession?

    /// Set when the user explicitly tore down the connection (via `disconnect()`).
    @Published var userInitiatedDisconnect = false

    /// Most recent Now Playing payload the ATV has volunteered via `_iMC`.
    @Published var nowPlaying: NowPlayingInfo?

    /// Most recent attention state reported by `FetchAttentionState`.
    @Published var attentionState: Int?

    /// True when the ATV has an active text field waiting for keyboard input.
    @Published var keyboardActive: Bool = false

    /// Apps available for launch on the ATV, fetched after each session start.
    @Published var appList: [(id: String, name: String)] = []

    /// Live AirPlay MRP tunnel — provides real-time now-playing pushes.
    private var airPlayTunnel: AirPlayTunnel.Tunnel?
    private var lastPlaybackStateTimestamp: Double = 0

    // MARK: - Connect / Disconnect

    /// Smart connect: probes the device first (0.3 s TCP timeout).
    func wakeAndConnect(to device: AppleTVDevice) {
        switch state {
        case .disconnected, .error: break
        default: return
        }
        userInitiatedDisconnect = false
        state = .connecting
        currentDevice = device

        guard let host = device.host, let port = device.port else {
            state = .error("Device not yet resolved — try again")
            return
        }

        let mac = MACStore.load(for: device.id)
        guard let mac else {
            connect(to: device)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let reachable = Self.isReachableSync(host: host, port: Int(port), timeoutSeconds: 0.3)
            Log.companion.report("SmartConnect: \(device.name) reachable=\(reachable)")

            if reachable {
                let s = self
                await MainActor.run {
                    guard let conn = s, conn.state == .connecting else { return }
                    conn.connect(to: device)
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self, self.state == .connecting else { return }
                self.state = .waking
            }
            try? WakeOnLAN.send(mac: mac, targetIP: host)

            let deadline = Date().addingTimeInterval(90)
            var wolSent = 1

            while Date() < deadline {
                let s1 = self
                let cancelled = await MainActor.run { s1?.state != .waking }
                if cancelled { return }

                try? await Task.sleep(for: .seconds(3))

                let s2 = self
                let stillWaking = await MainActor.run { s2?.state == .waking }
                if !stillWaking { return }

                if Self.isReachableSync(host: host, port: Int(port), timeoutSeconds: 2) {
                    Log.companion.report("SmartConnect: \(device.name) responded after \(wolSent) WoL packet(s)")
                    let s3 = self
                    await MainActor.run {
                        guard let conn = s3, conn.state == .waking else { return }
                        conn.connect(to: device)
                    }
                    return
                }

                wolSent += 1
                if wolSent % 5 == 0 {
                    Log.wol.report("WoL: resending (attempt \(wolSent / 5 + 1))")
                    try? WakeOnLAN.send(mac: mac, targetIP: host)
                }
            }

            Log.companion.report("SmartConnect: \(device.name) did not respond in 90 s, trying connect")
            let s4 = self
            await MainActor.run {
                guard let conn = s4, conn.state == .waking else { return }
                conn.connect(to: device)
            }
        }
    }

    private nonisolated static func isReachableSync(host: String, port: Int, timeoutSeconds: Double) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        defer { Darwin.close(fd) }

        let boundSrc = PrimaryInterface.bindSourceAddress(fd: fd, logHost: host)
        if boundSrc == nil {
            Log.companion.report("isReachableSync: bindSourceAddress returned nil for \(host)")
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }
        if errno != EINPROGRESS {
            Log.companion.report("isReachableSync: connect() returned \(result), errno \(errno) (\(String(cString: strerror(errno))))")
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms    = Int32(timeoutSeconds * 1000)
        let ready = poll(&pfd, 1, ms)
        if ready <= 0 {
            Log.companion.report("isReachableSync: poll() returned \(ready) (timeout \(ms)ms), errno \(errno)")
            return false
        }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if err != 0 {
            Log.companion.report("isReachableSync: SO_ERROR=\(err) (\(String(cString: strerror(err))))")
        }
        return err == 0
    }

    func connect(to device: AppleTVDevice) {
        switch state {
        case .disconnected, .connecting, .waking, .error: break
        default: return
        }
        userInitiatedDisconnect = false
        guard let host = device.host, let port = device.port else {
            state = .error("Device not yet resolved — try again")
            return
        }
        state = .connecting
        currentDevice = device
        transport.resetNonces()

        let deviceCopy = device
        writeQueue.async { [weak self] in
            var addr = sockaddr_in()
            addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port   = in_port_t(port).bigEndian
            let inetResult = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            guard inetResult == 1 else {
                let msg = "inet_pton failed for '\(host)'"
                DispatchQueue.main.async { self?.state = .error(msg) }
                return
            }

            let transientErrnos: Set<Int32> = [EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EADDRINUSE]
            var fd: Int32 = -1
            var lastErrno: Int32 = 0
            var lastFailStage = "socket"
            for attempt in 0..<3 {
                let trialFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                if trialFD < 0 {
                    lastErrno = errno
                    lastFailStage = "socket"
                    if attempt < 2 {
                        Log.companion.report("Companion: socket() attempt \(attempt + 1) failed (\(String(cString: strerror(lastErrno)))), retrying in 1 s…")
                        Thread.sleep(forTimeInterval: 1)
                        continue
                    }
                    break
                }

                PrimaryInterface.bindSourceAddress(fd: trialFD,
                                                   logHost: attempt == 0 ? host : nil)

                let rc = withUnsafePointer(to: addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(trialFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 {
                    fd = trialFD
                    break
                }

                lastErrno = errno
                lastFailStage = "connect"
                Darwin.close(trialFD)
                guard transientErrnos.contains(lastErrno), attempt < 2 else { break }
                Log.companion.report("Companion: connect attempt \(attempt + 1) failed (\(String(cString: strerror(lastErrno)))), retrying in 1 s…")
                Thread.sleep(forTimeInterval: 1)
            }
            guard fd >= 0 else {
                let msg = "\(lastFailStage)() failed: \(String(cString: strerror(lastErrno)))"
                DispatchQueue.main.async { self?.state = .error(msg) }
                return
            }

            Log.companion.report("Companion: TCP connected to \(host):\(port)")

            var enable: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, socklen_t(MemoryLayout<Int32>.size))
            var idleSec: Int32 = 10
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idleSec, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionEpoch &+= 1
                let sess = CompanionSession(
                    fd: fd,
                    epoch: self.connectionEpoch,
                    transport: self.transport,
                    writeQueue: self.writeQueue,
                    readQueue: self.readQueue
                )
                sess.delegate = self
                self.session = sess
                sess.start()
                if self.credentialStore.hasCredentials(for: deviceCopy.id) {
                    Log.companion.report("Companion: starting pair-verify")
                    self.startPairVerify(device: deviceCopy)
                } else {
                    Log.companion.report("Companion: starting pair-setup")
                    self.startPairSetup()
                }
            }
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        connectionEpoch &+= 1
        session?.close()
        session = nil
        state = .disconnected
        currentDevice = nil
        pairingFlow.reset()
        transport.reset()
        attentionState = nil
        keyboardActive = false
        lastPlaybackStateTimestamp = 0
        lastNowPlayingRefreshAt = nil
        nowPlaying = nil
        airPlayTunnel?.close()
        airPlayTunnel = nil
    }

    // MARK: - Remote Commands (post-session)

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        session?.send(command)
        // Left / right while watching video acts as ff / rew — the ATV
        // scrubs ~10s. Nudge the AirPlay tunnel for a fresh state push so
        // the displayed elapsed snaps to the new position rather than
        // waiting for the ATV's own (sometimes delayed) reactive push.
        // Small delay so the scrub completes before we ask for state.
        if command == .left || command == .right {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.requestNowPlayingRefresh()
            }
        }
    }

    func sendLongPress(_ command: RemoteCommand, ms: Int = 1000) {
        guard state == .connected else { return }
        session?.sendLongPress(command, ms: ms)
    }

    func sendSwipe(_ direction: SwipeDirection) {
        guard state == .connected else { return }
        session?.sendSwipe(direction)
    }

    func sendText(_ text: String, completion: @escaping (Error?) -> Void) {
        guard state == .connected else { completion(TextInputError.notConnected); return }
        guard keyboardActive else { completion(TextInputError.noActiveTextField); return }
        session?.sendText(text, completion: completion) ?? completion(TextInputError.notConnected)
    }

    func sendBackspace(completion: @escaping (Error?) -> Void) {
        guard state == .connected else { completion(TextInputError.notConnected); return }
        guard keyboardActive else { completion(TextInputError.noActiveTextField); return }
        session?.sendBackspace(completion: completion) ?? completion(TextInputError.notConnected)
    }

    func sendClearText(completion: @escaping (Error?) -> Void) {
        guard state == .connected else { completion(TextInputError.notConnected); return }
        guard keyboardActive else { completion(TextInputError.noActiveTextField); return }
        session?.sendClearText(completion: completion) ?? completion(TextInputError.notConnected)
    }

    func fetchApps(completion: ((Result<[(id: String, name: String)], Error>) -> Void)? = nil) {
        session?.fetchApps(completion: completion)
    }

    func launchApp(bundleID: String,
                   completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard state == .connected else {
            completion?(.failure(CompanionError.unexpectedResponse))
            return
        }
        session?.launchApp(bundleID: bundleID, completion: completion)
    }

    // MARK: - AirPlay MRP

    private func startAirPlayMRP() {
        guard let device = currentDevice,
              let host = device.host,
              let creds = credentialStore.loadAirPlay(deviceID: device.id) else { return }
        let airPlayClientID = String(data: creds.clientID, encoding: .utf8)
        // Inherit MainActor from the calling @MainActor context. AirPlayTunnel.open
        // suspends while its dedicated openQueue does the blocking I/O, so MainActor
        // isn't held during the wait — no need for Task.detached + MainActor.run.
        Task { [weak self] in
            do {
                let tunnel = try await AirPlayTunnel.open(
                    host: host,
                    credentials: creds,
                    mrpClientID: airPlayClientID,
                    onMessage: { [weak self] msgData in
                        guard let update = MRPDecoder.decodeNowPlaying(from: msgData) else { return }
                        Task { @MainActor [weak self] in
                            self?.applyAirPlayUpdate(update)
                        }
                    }
                )
                self?.airPlayTunnel = tunnel
            } catch {
                Log.pairing.report("AirPlay MRP tunnel: \(error) — now-playing will use Companion only")
            }
        }
    }

    /// Minimum interval between nudges. Prevents a cascade if the ATV's
    /// response to our nudge itself contains a state we treat as a change
    /// trigger (e.g., playbackState == 5 during a long scrub).
    private static let nowPlayingRefreshDebounce: TimeInterval = 1.0
    /// Wall-clock timestamp of the most recent fired nudge, used by
    /// `requestNowPlayingRefresh` for debouncing.
    private var lastNowPlayingRefreshAt: Date?

    /// Ask the ATV to push a fresh now-playing SET_STATE so elapsed time
    /// snaps to ground truth. Used after the user issues a command that
    /// likely changed playback position (resume, scrub, ff/rew). Cheap —
    /// two MRP frames; the ATV ignores GET_STATE post-init, but the
    /// CLIENT_UPDATES_CONFIG + GET_KEYBOARD_SESSION pair is the sequence
    /// that empirically triggers a fresh push including elapsed time.
    ///
    /// Debounced to once per `nowPlayingRefreshDebounce` so callers fired
    /// in rapid succession (e.g. seek-state echo + ff/rew tap landing
    /// within the same animation frame) don't spam the wire.
    private func requestNowPlayingRefresh() {
        guard let tunnel = airPlayTunnel else { return }
        let now = Date()
        if let last = lastNowPlayingRefreshAt,
           now.timeIntervalSince(last) < Self.nowPlayingRefreshDebounce {
            return
        }
        lastNowPlayingRefreshAt = now
        writeQueue.async {
            try? tunnel.mrp.send(MRPMessage.clientUpdatesConfig())
            try? tunnel.mrp.send(MRPMessage.getKeyboardSession())
        }
    }

    // MARK: - Pairing PIN

    func submitPairingPin(_ pin: String) {
        guard state == .awaitingPairingPin else { return }
        state = .connecting
        pairingFlow.submitPin(pin,
            onSend: { [weak self] m3 in
                self?.session?.sendFrame(.psNext, payload: OPACK.wrapPsNextData(m3))
            },
            onError: { [weak self] msg in
                self?.state = .error(msg)
            }
        )
    }

    // MARK: - Pair Setup / Verify

    private func startPairSetup() {
        pairingFlow.startPairSetup()
    }

    private func startPairVerify(device: AppleTVDevice) {
        guard let creds = credentialStore.load(deviceID: device.id) else {
            startPairSetup()
            return
        }
        pairingFlow.startPairVerify(credentials: creds)
    }

    // MARK: - Pairing delegate factory

    private func makePairingDelegate() -> PairingFlow.Delegate {
        PairingFlow.Delegate(
            sendFrame: { [weak self] type, payload in
                self?.session?.sendFrame(type, payload: payload)
            },
            setState: { [weak self] newState in
                guard let self else { return }
                self.state = newState
                if case .connected = newState {
                    guard let stored = self.credentialStore.load(deviceID: self.currentDevice?.id ?? "") else { return }
                    self.session?.sendSessionInit(clientID: stored.clientID, name: stored.name)
                    self.session?.startKeepalive()
                    self.startAirPlayMRP()
                }
            },
            installKeys: { [weak self] enc, dec in
                self?.transport.installSessionKeys(encrypt: enc, decrypt: dec)
            },
            reconnect: { [weak self] device in
                self?.disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.connect(to: device)
                }
            },
            saveCredentials: { [weak self] creds, deviceID in
                self?.credentialStore.save(credentials: creds, for: deviceID)
            },
            deleteCredentials: { [weak self] deviceID in
                self?.credentialStore.delete(deviceID: deviceID)
            }
        )
    }

    // MARK: - Now Playing merge

    /// Source-agnostic snapshot of the fields we may receive in a single
    /// now-playing push, as fed into `mergeNowPlaying(_:)`. Lets the AirPlay
    /// (MRPNowPlayingUpdate) and Companion (`NowPlayingInfo` from a `_iMC`
    /// inner dict) paths share one merge implementation — without it, the
    /// two had to be kept in lockstep by hand and a fix to one routinely
    /// missed the other.
    private struct NowPlayingMergeInput {
        var title: String?
        var artist: String?
        var album: String?
        /// User-facing app name (Companion-only).
        var app: String?
        var duration: Double?
        var elapsedTime: Double?
        var playbackRate: Double?
        var playbackStateTimestamp: Double?
        /// MRP playback state enum (1=playing, 2=paused, 3=stopped, 5=seeking).
        /// AirPlay-only — used to nudge a refresh during scrubs.
        var playbackState: Int?
        /// Companion `_iMC` raw dict, merged into `NowPlayingInfo.raw` for
        /// debugging. AirPlay path passes nil.
        var rawCompanion: [String: String]?

        static func from(airplay u: MRPNowPlayingUpdate) -> Self {
            Self(title: u.title, artist: u.artist, album: u.album,
                 duration: u.duration, elapsedTime: u.elapsedTime,
                 playbackRate: u.playbackRate,
                 playbackStateTimestamp: u.playbackStateTimestamp,
                 playbackState: u.playbackState)
        }

        static func from(companion u: NowPlayingInfo) -> Self {
            Self(title: u.title, artist: u.artist, album: u.album,
                 app: u.app,
                 duration: u.duration, elapsedTime: u.elapsedTime,
                 playbackRate: u.playbackRate,
                 rawCompanion: u.raw)
        }
    }

    private struct NowPlayingMergeResult {
        let trackChanged: Bool
        let didResume: Bool
        let didPause: Bool
    }

    /// Apply an incoming now-playing update to `self.nowPlaying`. Handles:
    ///   • cohort reset on app/title/artist change or duration shift >5s
    ///   • album-injection filter (`Season N, Episode M`)
    ///   • play→pause edge: freeze interpolated elapsed into elapsedTime
    ///   • anchor invariant: set while playing, nil while paused
    ///   • Companion `raw` merge for debugging
    @discardableResult
    private func mergeNowPlaying(_ input: NowPlayingMergeInput) -> NowPlayingMergeResult {
        var info = nowPlaying ?? NowPlayingInfo()

        // Cohort reset triggers — kept as named locals so the result struct
        // can report `trackChanged` to callers (used for verbose logging).
        let appChanged    = (input.app    != nil) && (input.app    != info.app)
        let titleChanged  = (input.title  != nil) && (input.title  != info.title)
        let artistChanged = (input.artist != nil) && (input.artist != info.artist)
        let durationChanged: Bool = {
            guard let new = input.duration, let old = info.duration else { return false }
            return abs(new - old) > 5
        }()
        let trackChanged = appChanged || titleChanged || artistChanged || durationChanged
        if trackChanged {
            info.title       = nil
            info.artist      = nil
            info.album       = nil
            info.elapsedTime = nil
            info.duration    = nil
            info.playbackRate = nil
            info.elapsedAnchor = nil
        }

        if let v = input.title       { info.title       = v }
        if let v = input.artist      { info.artist      = v }
        if let v = input.album       { info.album       = NowPlayingInfo.filterAlbum(v) }
        if let v = input.app         { info.app         = v }
        if let v = input.duration    { info.duration    = v }
        if let v = input.elapsedTime { info.elapsedTime = v }

        let prevRate = info.playbackRate ?? 0
        if let v = input.playbackRate {
            // Loosened ordering gate: a push with `ts == 0` (or missing
            // entirely) is allowed through — without this, a pause arriving
            // with a reset timestamp would be silently dropped, leaving us
            // ticking forward forever (P2 issue 3ht). Strict-greater-or-equal
            // is enforced only when we have a non-zero ts to compare to.
            let ts = input.playbackStateTimestamp ?? 0
            let pass = ts == 0 || ts >= lastPlaybackStateTimestamp
            if pass {
                if ts > 0 { lastPlaybackStateTimestamp = ts }
                // play → pause edge: bake the live-interpolated value before
                // flipping rate so liveElapsed returns the right
                // "where we paused" number after the flip.
                if v == 0, prevRate > 0, let live = info.liveElapsed() {
                    info.elapsedTime = live
                }
                info.playbackRate = v
            }
        }
        let nowRate = info.playbackRate ?? 0

        // Anchor invariant: while playing (rate > 0), `elapsedAnchor` MUST be set
        // — liveElapsed needs it to interpolate. While paused, anchor is nil.
        //   • elapsedTime fresh from the push → re-anchor to now (start, seek).
        //   • paused → playing transition → anchor existing elapsedTime to now,
        //     even when the resume push didn't carry a fresh elapsed.
        //   • now paused → clear anchor (liveElapsed returns frozen value).
        if nowRate == 0 {
            info.elapsedAnchor = nil
        } else if input.elapsedTime != nil || prevRate == 0 {
            info.elapsedAnchor = Date()
        }

        if let raw = input.rawCompanion {
            info.raw.merge(raw) { _, new in new }
        }
        nowPlaying = info

        return NowPlayingMergeResult(
            trackChanged: trackChanged,
            didResume:    nowRate > 0 && prevRate == 0,
            didPause:     nowRate == 0 && prevRate > 0
        )
    }

    /// AirPlay-MRP path (where elapsed/title/artist/album really come from).
    private func applyAirPlayUpdate(_ update: MRPNowPlayingUpdate) {
        let result = mergeNowPlaying(.from(airplay: update))

        if Log.verbose {
            let parts: [String] = [
                update.title.map       { "title=\"\($0)\"" },
                update.artist.map      { "artist=\"\($0)\"" },
                update.duration.map    { "duration=\($0)" },
                update.elapsedTime.map { "elapsed=\($0)" },
                update.playbackRate.map { "rate=\($0)" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                Log.companion.report(
                    "AirPlay → now-playing [\(parts.joined(separator: " "))]" +
                    (result.trackChanged ? " — track change, cohort reset" : "")
                )
            }
        }

        // Pull fresh state from the ATV when playback context likely just
        // changed. The first push often arrives without elapsedTime (rate-
        // only push) or before the ATV has stamped the real position; asking
        // again promptly replaces our interpolated estimate with ground truth.
        let isSeeking = update.playbackState == 5
        if result.didResume || result.didPause || result.trackChanged || isSeeking {
            requestNowPlayingRefresh()
        }
    }

    /// Companion `_iMC` path. Companion only carries `_mcF` flags in practice
    /// — title/artist/elapsed/rate are all from AirPlay — but we still wire
    /// it through the same merge so the (rare) push that does include
    /// metadata is handled consistently.
    private func mergeNowPlaying(from inner: [String: Any]) {
        let update = NowPlayingInfo(from: inner)
        mergeNowPlaying(.from(companion: update))
        Log.companion.report("Companion: now-playing update (keys: \(inner.keys.sorted().joined(separator: ",")))")
    }
}

// MARK: - CompanionSessionDelegate

extension CompanionConnection: CompanionSessionDelegate {
    func sessionDidUpdateNowPlaying(_ update: CompanionNowPlayingUpdate) {
        mergeNowPlaying(from: update.inner)
    }

    func sessionDidChangeKeyboardActive(_ active: Bool, data: Data?) {
        keyboardActive = active
        if !active { return }
    }

    func sessionDidUpdateAttentionState(_ st: Int) {
        attentionState = st
    }

    func sessionDidReadError(_ message: String) {
        keyboardActive = false
        state = .error(message)
    }

    func sessionDidClose() {
        keyboardActive = false
        state = .disconnected
    }

    func sessionDidConfirmStart() {
        if appList.isEmpty { session?.fetchApps() }
    }

    func sessionDidFetchApps(_ apps: [(id: String, name: String)]) {
        appList = apps
        Log.companion.report("Companion: fetched \(apps.count) apps")
    }

    func sessionDidReceivePairingFrame(_ frame: CompanionFrame) {
        switch frame.type {
        case .psNext: pairingFlow.handlePsNext(frame.payload, device: currentDevice!)
        case .pvNext: pairingFlow.handlePvNext(frame.payload, deviceID: currentDevice?.id ?? "")
        default: break
        }
    }
}

// MARK: - Now Playing

/// Snapshot of the Apple TV's current media-playback state, as pushed via
/// Companion `_iMC` event subscription. All fields are optional because tvOS
/// is inconsistent about which keys populate for which apps — the `raw` map
/// preserves everything we saw (stringified) so unknown keys stay inspectable.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// User-facing app name (e.g. "TV", "Music", "Netflix"). Usually under key
    /// `clientName` or `displayName` — we check both.
    public var app: String?
    public var elapsedTime: Double?
    public var duration: Double?
    /// 0.0 = paused, 1.0 = playing at normal speed. Some apps report other rates.
    public var playbackRate: Double?
    /// Wall-clock time on this Mac when `elapsedTime` was last stamped by the ATV.
    public var elapsedAnchor: Date?
    /// Every key/value we saw, stringified. Useful for debugging and for any
    /// field we haven't named above yet.
    public var raw: [String: String]

    public init() {
        self.title = nil; self.artist = nil; self.album = nil; self.app = nil
        self.elapsedTime = nil; self.duration = nil; self.playbackRate = nil
        self.elapsedAnchor = nil
        self.raw = [:]
    }

    /// Elapsed time ticking forward from the last ATV push while playing.
    /// Returns the raw `elapsedTime` when paused or unanchored.
    public func liveElapsed(at date: Date = Date()) -> Double? {
        guard let elapsed = elapsedTime else { return nil }
        guard let anchor = elapsedAnchor, let rate = playbackRate, rate > 0 else {
            return elapsed
        }
        let computed = elapsed + date.timeIntervalSince(anchor) * rate
        if let dur = duration { return min(computed, dur) }
        return computed
    }

    public init(from dict: [String: Any]) {
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = dict[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        func num(_ keys: String...) -> Double? {
            for k in keys {
                if let v = dict[k] as? Double { return v }
                if let v = dict[k] as? Int    { return Double(v) }
                if let v = dict[k] as? String, let d = Double(v) { return d }
            }
            return nil
        }
        self.title        = str("title", "kMRMediaRemoteNowPlayingInfoTitle")
        self.artist       = str("artist", "kMRMediaRemoteNowPlayingInfoArtist")
        self.album        = NowPlayingInfo.filterAlbum(
            str("album", "kMRMediaRemoteNowPlayingInfoAlbum"))
        self.app          = str("clientName", "displayName", "bundleIdentifier")
        self.elapsedTime  = num("elapsedTime", "kMRMediaRemoteNowPlayingInfoElapsedTime")
        self.duration     = num("duration", "kMRMediaRemoteNowPlayingInfoDuration")
        self.playbackRate = num("playbackRate", "kMRMediaRemoteNowPlayingInfoPlaybackRate")

        var r: [String: String] = [:]
        for (k, v) in dict {
            r[k] = String(describing: v)
        }
        self.raw = r
    }

    /// Drop "Season N, Episode N" album values that Apple TV's catalog injects
    /// for video content. Those numbers are the catalog's internal index, not
    /// the show's real season/episode (we've seen the same "Season 8,
    /// Episode 3" string attached to two unrelated shows). Real album
    /// metadata for music ("A Night at the Opera" etc.) doesn't match the
    /// pattern and is preserved.
    static func filterAlbum(_ album: String?) -> String? {
        guard let album else { return nil }
        return album.range(of: #"^\p{L}+\s+\d+,\s*\p{L}+\s+\d+$"#,
                           options: .regularExpression) != nil ? nil : album
    }
}


