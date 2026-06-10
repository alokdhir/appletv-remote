import Foundation
import AppKit
import Darwin
import Combine
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
    /// Queue for blocking MRP sends (now-playing refresh). Kept separate from
    /// `writeQueue` so a stalled Companion socket doesn't also block AirPlay
    /// refreshes — the two transports are independent.
    private let mrpSendQueue = DispatchQueue(label: "companion.mrp-send", qos: .userInitiated)
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
    /// In-flight `startAirPlayMRP` task. Cancelled and replaced on every new
    /// start so overlapping triggers (pair-verify completion, tunnel close,
    /// system wake mid-open) can't race two opens against the same epoch —
    /// the loser would overwrite `airPlayTunnel` and leak the other tunnel's
    /// three NWConnections.
    private var airPlayOpenTask: Task<Void, Never>?
    /// Wall-clock of the most recent close-triggered tunnel teardown. Used to
    /// detect a close storm (tunnel dies right after every open) and insert a
    /// cooldown so we don't hammer the ATV with back-to-back handshakes.
    private var lastTunnelCloseAt: Date?
    private var lastPlaybackStateTimestamp: Double = 0

    /// Per-bundle now-playing state. tvOS multiplexes several players over
    /// the same MRP socket (Netflix, the TV app, AirPlay, HBO Max, …); each
    /// publishes its own SET_STATE_MESSAGE. Without per-bundle tracking the
    /// chatty paused players overwrite the active foreground player.
    private var airPlayStateByBundle: [String: NowPlayingInfo] = [:]
    /// Most-recent timestamp gate per bundle (the merge needs one).
    private var airPlayLastTSByBundle: [String: Double] = [:]
    /// Wall-clock time we last received an update for a bundle. Used as the
    /// fallback ranking when tvOS hasn't announced an active client.
    private var airPlayLastUpdateAtByBundle: [String: Date] = [:]
    /// The bundle tvOS told us is the foreground "now playing" client via
    /// SET_NOW_PLAYING_CLIENT_MESSAGE. Nil when no active client is known.
    private var activeAirPlayBundle: String?

    /// Wake-from-sleep observer. Mac sleep silently kills the AirPlay
    /// MRP TCP socket without NWConnection ever firing `.failed`, so the
    /// receive loop just stops delivering messages and the now-playing
    /// footer goes stale until the user manually relaunches.
    /// Subscribing to `NSWorkspace.didWakeNotification` lets us proactively
    /// tear down + reopen the tunnel as soon as the Mac comes back, instead
    /// of waiting for an event that never fires.
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWake() }
        }
    }

    // No deinit needed: CompanionConnection is held as a @StateObject by
    // AppleTVRemoteApp and lives the entire process lifetime, so the
    // wake observer is implicitly cleaned up at exit. Adding a deinit
    // here would also require crossing MainActor isolation under Swift 6
    // strict concurrency for what amounts to dead cleanup code.

    // MARK: - Connect / Disconnect

    /// Smart connect: probes the device first (0.3 s TCP timeout).
    func wakeAndConnect(to device: AppleTVDevice) {
        switch state {
        case .disconnected, .sleeping, .error: break
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
            let probe = Self.probeReachability(host: host, port: Int(port), timeoutSeconds: 0.3)
            Log.companion.report("SmartConnect: \(device.name) probe=\(probe)")

            // .reachable: Companion service is accepting → connect now.
            // .refused:   Host is alive on the network but the Companion
            //             service is briefly refusing (mid-restart, post-EOF
            //             grace window, sleep-state transition). WoL is
            //             pointless — the host isn't sleeping. Fall through
            //             to connect(); its built-in transient-errno retry
            //             handles the brief refusal window, and on failure
            //             AutoReconnector's exponential backoff covers
            //             outages longer than that.
            if probe == .reachable || probe == .refused {
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

                let p = Self.probeReachability(host: host, port: Int(port), timeoutSeconds: 2)
                // The host has come back online once the network stack starts
                // RST-ing instead of timing out (.refused), or the Companion
                // service is fully up (.reachable). Either way, stop WoL'ing.
                if p == .reachable || p == .refused {
                    Log.companion.report("SmartConnect: \(device.name) responded (\(p)) after \(wolSent) WoL packet(s)")
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

    /// Result of a fast TCP-handshake probe.
    ///
    /// `.refused` means the kernel got a TCP RST back (typically
    /// `ECONNREFUSED`): the host is alive on the network — we exchanged
    /// SYN/RST — but no process is currently bound to that port. Treating
    /// this as "asleep" and entering the WoL flow burns 90 s of yellow-ball
    /// while sending packets that do nothing (the ATV is already awake).
    enum Reachability: CustomStringConvertible {
        case reachable
        case refused
        case unreachable
        var description: String {
            switch self {
            case .reachable:   return "reachable"
            case .refused:     return "refused"
            case .unreachable: return "unreachable"
            }
        }
    }

    private nonisolated static func probeReachability(host: String, port: Int, timeoutSeconds: Double) -> Reachability {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }

        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        defer { Darwin.close(fd) }

        let boundSrc = PrimaryInterface.bindSourceAddress(fd: fd, logHost: host)
        if boundSrc == nil {
            Log.companion.report("probeReachability: bindSourceAddress returned nil for \(host)")
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

        if result == 0 { return .reachable }
        if errno != EINPROGRESS {
            let immediateErr = errno
            Log.companion.report("probeReachability: connect() returned \(result), errno \(immediateErr) (\(String(cString: strerror(immediateErr))))")
            // Some non-blocking stacks complete the RST synchronously
            // before EINPROGRESS — surface ECONNREFUSED as .refused.
            return immediateErr == ECONNREFUSED ? .refused : .unreachable
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms    = Int32(timeoutSeconds * 1000)
        let ready = poll(&pfd, 1, ms)
        if ready <= 0 {
            Log.companion.report("probeReachability: poll() returned \(ready) (timeout \(ms)ms), errno \(errno)")
            return .unreachable
        }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if err == 0 { return .reachable }
        Log.companion.report("probeReachability: SO_ERROR=\(err) (\(String(cString: strerror(err))))")
        // ECONNREFUSED → host alive, port refusing. Skip WoL.
        return err == ECONNREFUSED ? .refused : .unreachable
    }

    /// Probe-only connect. If the ATV answers TCP we connect; if it doesn't,
    /// state goes to `.sleeping` and we stop. No WoL, no AutoReconnector retry.
    /// Used by the launch auto-connect path so an ATV the user intentionally
    /// slept (in this app, via Siri Remote, or via a previous session) stays
    /// asleep across app relaunches. Manual user actions (Connect button,
    /// `atv power`, the in-app power button while sleeping) still go through
    /// `wakeAndConnect()` and will WoL.
    func connectIfAwake(to device: AppleTVDevice) {
        switch state {
        case .disconnected, .sleeping, .error: break
        default: return
        }
        userInitiatedDisconnect = false
        // Set currentDevice + .connecting before the resolved-host guard so
        // AutoReconnector's retry path has a target if a still-resolving
        // device slipped past the caller's filter (the host/port @Published
        // updates are atomic now, but defense in depth).
        state = .connecting
        currentDevice = device
        guard let host = device.host, let port = device.port else {
            state = .error("Device not yet resolved — try again")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let probe = Self.probeReachability(host: host, port: Int(port), timeoutSeconds: 0.3)
            Log.companion.report("connectIfAwake: \(device.name) probe=\(probe)")
            await MainActor.run { [weak self] in
                // Guard against a concurrent user action having moved us
                // out of the .connecting we just installed.
                guard let self, self.state == .connecting else { return }
                switch probe {
                case .reachable, .refused:
                    self.connect(to: device)
                case .unreachable:
                    // ATV is asleep — surface that, don't WoL, don't retry.
                    self.state = .sleeping
                }
            }
        }
    }

    func connect(to device: AppleTVDevice) {
        switch state {
        case .disconnected, .sleeping, .connecting, .waking, .error: break
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
        resetNowPlayingState()
    }

    /// Tears down all now-playing state: per-bundle maps, AirPlay tunnel,
    /// any in-flight tunnel open, published nowPlaying, and timestamp
    /// bookkeeping. Called on user-initiated `disconnect()`, on `sleep()`,
    /// and from `AutoReconnector` once retries are exhausted — NOT on every
    /// transient socket close, since the ATV's 30s idle-EOF reconnect would
    /// flicker the footer on each cycle.
    func resetNowPlayingState() {
        lastPlaybackStateTimestamp = 0
        lastNowPlayingRefreshAt = nil
        nowPlaying = nil
        airPlayStateByBundle.removeAll()
        airPlayLastTSByBundle.removeAll()
        airPlayLastUpdateAtByBundle.removeAll()
        activeAirPlayBundle = nil
        airPlayOpenTask?.cancel()
        airPlayOpenTask = nil
        lastTunnelCloseAt = nil
        airPlayTunnel?.close()
        airPlayTunnel = nil
    }

    // MARK: - Remote Commands (post-session)

    /// Send the sleep command and transition to `.sleeping` immediately.
    /// The state flip prevents AutoReconnector from retrying when the ATV
    /// drops the Companion socket on its way down, and gives the UI an
    /// instant visual cue without waiting for the (lossy) socket close.
    func sleep() {
        guard state == .connected else { return }
        session?.send(.sleep)
        // Bump epoch so the old session's pending sessionDidClose (which the
        // ATV will fire as it goes down) is ignored if a quick wake-and-connect
        // races it on the main queue. Without this, the stale close lands
        // after wakeAndConnect set state to .connecting and clobbers it back
        // to .disconnected, leaving the wake stuck.
        connectionEpoch &+= 1
        state = .sleeping
        // Clear the footer and tear down the AirPlay tunnel now: the epoch
        // bump above makes the tunnel's eventual onMRPClose a stale no-op,
        // so nothing else would ever close it — and the now-playing card
        // would keep showing pre-sleep playback for as long as the ATV
        // sleeps. The Companion session is left alone so the queued .sleep
        // write can flush; its EOF is epoch-guarded out in sessionDidClose.
        resetNowPlayingState()
    }

    /// Wake from `.sleeping` on user input (button press in the UI).
    /// Returns true if the press was consumed as a wake gesture and the
    /// caller should NOT also treat it as a remote command.
    @discardableResult
    private func wakeOnInputIfSleeping() -> Bool {
        guard state == .sleeping, let device = currentDevice else { return false }
        wakeAndConnect(to: device)
        return true
    }

    func send(_ command: RemoteCommand) {
        if wakeOnInputIfSleeping() { return }
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
        if wakeOnInputIfSleeping() { return }
        guard state == .connected else { return }
        session?.sendLongPress(command, ms: ms)
    }

    func sendSwipe(_ direction: SwipeDirection) {
        if wakeOnInputIfSleeping() { return }
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
        // One open task at a time. A tunnel close or system wake can retrigger
        // while a previous open is still awaiting its blocking handshake; the
        // cancelled task notices after its await and closes whatever it opened
        // instead of installing it over ours.
        airPlayOpenTask?.cancel()
        guard let device = currentDevice,
              let host = device.host,
              let creds = credentialStore.loadAirPlay(deviceID: device.id) else { return }
        let airPlayClientID = String(data: creds.clientID, encoding: .utf8)
        let openEpoch = connectionEpoch
        // Inherit MainActor from the calling @MainActor context. AirPlayTunnel.open
        // suspends while its dedicated openQueue does the blocking I/O, so MainActor
        // isn't held during the wait — no need for Task.detached + MainActor.run.
        airPlayOpenTask = Task { [weak self] in
            // Retry with backoff: a single-shot open commonly fails on
            // sleep/wake when the network stack is still settling, leaving
            // us in Companion-only mode where MRP pushes never arrive and
            // the now-playing footer goes stale until the user quits and
            // relaunches. 4 attempts × ~7 s of total backoff is enough to
            // ride out a typical wake-from-sleep network reattach.
            let backoff: [TimeInterval] = [0, 0.5, 1.5, 5.0]
            for delay in backoff {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                // Bail if a newer open superseded us (cancellation), the user
                // disconnected, or we reconnected in the meantime (a newer
                // epoch is already opening its own tunnel).
                guard !Task.isCancelled, let self else { return }
                let stillCurrent = await MainActor.run { openEpoch == self.connectionEpoch && self.state == .connected }
                guard stillCurrent else { return }
                do {
                    let tunnel = try await AirPlayTunnel.open(
                        host: host,
                        credentials: creds,
                        mrpClientID: airPlayClientID,
                        onMessage: { [weak self] msgData in
                            guard let decoded = MRPDecoder.decodeNowPlaying(from: msgData) else { return }
                            Task { @MainActor [weak self] in
                                self?.handleAirPlayMessage(decoded)
                            }
                        },
                        onMRPClose: { [weak self] in
                            // The AirPlay MRP socket died (NWConnection error,
                            // EOF, or peer drop). Without this, the tunnel
                            // silently stops delivering now-playing pushes —
                            // observed across overnight Mac sleep where the
                            // kernel dropped the TCP sockets, NWConnection
                            // never fired .failed, and the footer stayed
                            // stuck on the pre-sleep snapshot until the user
                            // manually quit and relaunched.
                            Task { @MainActor [weak self] in
                                self?.handleAirPlayTunnelClose(epoch: openEpoch)
                            }
                        }
                    )
                    await MainActor.run {
                        // Post-await guard: connection epoch advances on
                        // disconnect()/wakeAndConnect(), but `sessionDidClose`
                        // (the EOF path) only flips state to .disconnected
                        // without bumping the epoch. Cancellation means a
                        // newer open superseded this one. Any of these means
                        // the tunnel we just opened is orphaned — close it
                        // and let the current owner spin up a fresh one.
                        guard !Task.isCancelled,
                              openEpoch == self.connectionEpoch,
                              self.state == .connected else {
                            tunnel.close()
                            return
                        }
                        // The EOF-reconnect path deliberately leaves the dead
                        // tunnel reference in place (footer continuity), so a
                        // stale tunnel can still be sitting here — close it
                        // rather than leak its NWConnections on overwrite.
                        self.airPlayTunnel?.close()
                        self.airPlayTunnel = tunnel
                    }
                    return
                } catch {
                    Log.pairing.report("AirPlay MRP tunnel open failed (delay=\(delay)s): \(error)")
                }
            }
            Log.pairing.report("AirPlay MRP tunnel: giving up after retries — now-playing will use Companion only")
        }
    }

    /// A tunnel that closes again within this window of the previous close is
    /// treated as a close storm (dies right after every open).
    private static let tunnelCloseStormWindow: TimeInterval = 30
    /// Cooldown applied between reopen attempts during a close storm.
    private static let tunnelReopenCooldown: TimeInterval = 10

    /// Reactive recovery: the AirPlay MRP receive loop exited (NWConnection
    /// error / EOF / decrypt failure). Drop our tunnel reference if it
    /// belongs to this open's epoch and reopen if we're still connected.
    private func handleAirPlayTunnelClose(epoch: Int) {
        // Stale callback from a tunnel that's already been replaced — ignore.
        guard epoch == connectionEpoch else { return }
        // Don't fight a healthy reconnect already in flight via wakeAndConnect.
        guard state == .connected else { return }
        airPlayTunnel?.close()
        airPlayTunnel = nil
        let now = Date()
        let stormy = lastTunnelCloseAt.map { now.timeIntervalSince($0) < Self.tunnelCloseStormWindow } ?? false
        lastTunnelCloseAt = now
        guard stormy else {
            Log.pairing.report("AirPlay MRP tunnel closed — reopening")
            startAirPlayMRP()
            return
        }
        // Tunnel died again within the storm window: every reopen is a full
        // RTSP + pair-verify handshake, so back off instead of spinning
        // open/close cycles against a flaky AirPlay daemon. The reopen task
        // re-checks epoch/state/tunnel after the cooldown — a user
        // disconnect, reconnect, or wake-triggered open during the sleep
        // makes it a no-op.
        Log.pairing.report("AirPlay MRP tunnel closed again within \(Int(Self.tunnelCloseStormWindow))s — cooling down \(Int(Self.tunnelReopenCooldown))s")
        let cooldownEpoch = connectionEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.tunnelReopenCooldown))
            guard let self,
                  self.connectionEpoch == cooldownEpoch,
                  self.state == .connected,
                  self.airPlayTunnel == nil else { return }
            self.startAirPlayMRP()
        }
    }

    /// Proactive recovery: the Mac just woke from sleep. NWConnection
    /// usually doesn't notice that its sockets died during sleep — they
    /// just stop delivering reads. Tear the AirPlay tunnel down and let
    /// `startAirPlayMRP`'s retry loop spin up a fresh one.
    ///
    /// Companion is left alone: it has TCP keepalive (10s idle timer set
    /// in connect()) so if its socket actually died the read loop will
    /// notice within ~30s and AutoReconnector takes over. We don't preempt
    /// that path because connecting too eagerly post-wake races with
    /// Wi-Fi reattach and burns reconnect attempts.
    private func handleSystemWake() {
        guard state == .connected else { return }
        Log.pairing.report("System woke — refreshing AirPlay tunnel")
        airPlayTunnel?.close()
        airPlayTunnel = nil
        startAirPlayMRP()
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
        mrpSendQueue.async {
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

    /// Apply an incoming now-playing update to `self.nowPlaying`.
    /// Delegates all logic to `NowPlayingInfo.merging(_:lastTimestamp:anchorDate:)`
    /// in `AppleTVProtocol`.
    @discardableResult
    private func mergeNowPlaying(_ input: NowPlayingMergeInput) -> NowPlayingMergeResult {
        let current = nowPlaying ?? NowPlayingInfo()
        let out = current.merging(input, lastTimestamp: lastPlaybackStateTimestamp)
        lastPlaybackStateTimestamp = out.newTimestamp
        nowPlaying = out.info
        return out.result
    }

    /// AirPlay-MRP path entry point. Routes one decoded MRP message to the
    /// per-bundle store and re-publishes whichever bundle is currently the
    /// foreground / playing one to `nowPlaying`.
    private func handleAirPlayMessage(_ msg: MRPDecodedMessage) {
        switch msg {
        case .activeClient(let bid):
            activeAirPlayBundle = bid
            Log.companion.report("AirPlay: active client → \(bid ?? "(none)")")
            republishActiveBundle()

        case .removeClient(let bid):
            airPlayStateByBundle.removeValue(forKey: bid)
            airPlayLastTSByBundle.removeValue(forKey: bid)
            if activeAirPlayBundle == bid {
                activeAirPlayBundle = nil
            }
            republishActiveBundle()

        case .stateUpdate(let update):
            applyAirPlayUpdate(update)
        }
    }

    /// AirPlay-MRP path (where elapsed/title/artist/album really come from).
    /// Stores the update under its bundle id and re-publishes only if it
    /// belongs to the foreground player.
    private func applyAirPlayUpdate(_ update: MRPNowPlayingUpdate) {
        // Type 56 (UPDATE_CONTENT_ITEM_MESSAGE) carries no bundleIdentifier
        // — by definition it updates the *active* player's currently-showing
        // item. Without this routing, type 56 pushes (which carry fresh
        // elapsed every ~1s while the user scrubs/skips) accumulate under
        // a phantom "_unknown" bucket that never drives the display, while
        // the active bundle's state stays anchored to whatever stale
        // elapsed arrived in the last (rare) type 4 push. Net effect:
        // the displayed elapsed lagged TV reality by 10+ minutes. See
        // `MRPNowPlayingUpdate.routedBundle` for the fallback chain.
        let bundle = update.routedBundle(
            active: activeAirPlayBundle,
            fallback: { [weak self] in self?.fallbackBundle() },
            unknownLogger: { Log.companion.fail($0) }
        )
        let current = airPlayStateByBundle[bundle] ?? NowPlayingInfo()
        let lastTS = airPlayLastTSByBundle[bundle] ?? 0
        let out = current.merging(NowPlayingMergeInput.from(airplay: update),
                                  lastTimestamp: lastTS)
        airPlayStateByBundle[bundle] = out.info
        airPlayLastTSByBundle[bundle] = out.newTimestamp
        airPlayLastUpdateAtByBundle[bundle] = Date()

        if Log.verbose {
            let parts: [String] = [
                "bundle=\(bundle)",
                update.title.map       { "title=\"\($0)\"" },
                update.artist.map      { "artist=\"\($0)\"" },
                update.duration.map    { "duration=\($0)" },
                update.elapsedTime.map { "elapsed=\($0)" },
                update.playbackRate.map { "rate=\($0)" },
            ].compactMap { $0 }
            Log.companion.report(
                "AirPlay → state [\(parts.joined(separator: " "))]" +
                (out.result.trackChanged ? " — track change, cohort reset" : "")
            )
        }

        // Only the active / foreground bundle drives the published state.
        if isDisplayBundle(bundle) {
            nowPlaying = out.info
            lastPlaybackStateTimestamp = out.newTimestamp
        } else {
            // A non-active bundle's state landed; re-evaluate in case our
            // ranking now prefers it (e.g. user just hit play in Netflix
            // while the TV app is still our last active client).
            republishActiveBundle()
        }

        let isSeeking = update.playbackState == 5
        if out.result.didResume || out.result.didPause || out.result.trackChanged || isSeeking {
            requestNowPlayingRefresh()
        }
    }

    /// Returns true if `bundle` is the one whose state should drive the UI.
    /// Preference order (matches `republishActiveBundle()`):
    ///   1. tvOS-announced active client (SET_NOW_PLAYING_CLIENT_MESSAGE)
    ///   2. otherwise whichever bundle would win the fallback ranking.
    private func isDisplayBundle(_ bundle: String) -> Bool {
        if let active = activeAirPlayBundle { return bundle == active }
        return bundle == fallbackBundle()
    }

    /// Pick the best bundle when tvOS hasn't named an active client.
    /// Prefers a currently-playing bundle; otherwise the most-recently-
    /// updated one (so paused metadata doesn't disappear).
    private func fallbackBundle() -> String? {
        let playing = airPlayStateByBundle.filter { ($0.value.playbackRate ?? 0) > 0 }
        let pool = playing.isEmpty ? airPlayStateByBundle : playing
        return pool.keys.max { (a, b) in
            (airPlayLastUpdateAtByBundle[a] ?? .distantPast)
                < (airPlayLastUpdateAtByBundle[b] ?? .distantPast)
        }
    }

    /// Push whichever bundle currently wins the display rules to
    /// `nowPlaying`. Clears `nowPlaying` when no bundles remain *and* the
    /// AirPlay tunnel is active (the tunnel is the authoritative source —
    /// "no clients" means nothing is playing). If there's no tunnel yet,
    /// leaves `nowPlaying` alone so Companion `_iMC` data isn't wiped
    /// before AirPlay connects.
    private func republishActiveBundle() {
        let winner = activeAirPlayBundle ?? fallbackBundle()
        guard let winner else {
            if airPlayTunnel != nil {
                nowPlaying = nil
                lastPlaybackStateTimestamp = 0
            }
            return
        }
        if let info = airPlayStateByBundle[winner] {
            nowPlaying = info
            lastPlaybackStateTimestamp = airPlayLastTSByBundle[winner] ?? 0
            return
        }
        // Active bundle announced (SET_NOW_PLAYING_CLIENT) but no state has
        // landed yet, or the player ships zero metadata (Netflix). Surface
        // at least the app name so the footer doesn't vanish entirely.
        if let appName = NowPlayingInfo.appName(fromBundle: winner) {
            var stub = NowPlayingInfo()
            stub.app = appName
            nowPlaying = stub
            lastPlaybackStateTimestamp = 0
        } else if airPlayTunnel != nil {
            nowPlaying = nil
            lastPlaybackStateTimestamp = 0
        }
    }

    /// Companion `_iMC` path. Companion only carries `_mcF` flags in practice
    /// — title/artist/elapsed/rate are all from AirPlay — but we still wire
    /// it through the same merge so the (rare) push that does include
    /// metadata is handled consistently.
    private func mergeNowPlaying(from inner: [String: Any]) {
        let update = NowPlayingInfo(from: inner)
        mergeNowPlaying(NowPlayingMergeInput.from(companion: update))
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

    func sessionDidReadError(_ message: String, epoch: Int) {
        // Stale callback from a session that's been replaced. Could fire after
        // the user slept-then-woke quickly: the old socket's EOF lands after
        // wakeAndConnect() has already installed a new .connecting state.
        guard epoch == connectionEpoch else { return }
        keyboardActive = false
        // Expected when the ATV drops the socket after we asked it to sleep.
        if state == .sleeping { return }
        state = .error(message)
    }

    func sessionDidClose(epoch: Int) {
        guard epoch == connectionEpoch else { return }
        keyboardActive = false
        if state == .sleeping { return }
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
        case .psNext:
            // currentDevice is niled by disconnect(); a frame already in flight
            // from the read loop can land here after that, so guard.
            guard let device = currentDevice else { return }
            pairingFlow.handlePsNext(frame.payload, device: device)
        case .pvNext: pairingFlow.handlePvNext(frame.payload, deviceID: currentDevice?.id ?? "")
        default: break
        }
    }
}


