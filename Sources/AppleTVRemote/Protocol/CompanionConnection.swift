import Foundation
import CryptoKit
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

    private var socketFD: Int32 = -1
    private var connectionEpoch: Int = 0
    private let writeQueue = DispatchQueue(label: "companion.write", qos: .userInitiated)
    private let readQueue  = DispatchQueue(label: "companion.read",  qos: .userInitiated)
    private let credentialStore = CredentialStore()
    private var receiveBuffer = Data()
    @Published var currentDevice: AppleTVDevice?

    // Pairing state
    private var pairing: HAPPairing?
    private var pairVerify: CompanionPairVerify?
    private var pendingM2Data: Data?

    // Session encryption (after pair-verify completes)
    private var encryptKey: SymmetricKey?
    private var decryptKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var recvNonce: UInt64 = 0
    private var txnCounter: UInt32 = 0

    // Transaction ID of the _sessionStart request. Once the ATV responds to
    // this txn, we know the session is fully established and safe to subscribe
    // to _iMC events. Sending _interest before this causes the ATV to ignore
    // the subscription (it hasn't finished setting up the session yet).
    private var sessionStartTxn: UInt32?

    // Pending response callbacks keyed by txn. Used for _tiStop/_tiStart
    // round-trips where we need the ATV's response before proceeding.
    private var pendingCallbacks: [UInt32: ([String: Any]) -> Void] = [:]

    /// Most recent _tiD payload from _tiStart response.
    /// Non-nil when the ATV has an active text field; nil otherwise.
    private var currentTextInputData: Data?

    // Heartbeat — the ATV closes idle Companion sockets at ~38 s.
    // FetchAttentionState is a real Request the ATV actually replies to,
    // so the reply traffic refreshes its idle timer. _systemInfo is ignored
    // silently, so it doesn't work as a keepalive.
    private var keepaliveTimer: DispatchSourceTimer?

    // Set to true when connect() was initiated via wakeAndConnect() so we
    // auto-send the Wake HID command after the session is established.
    private var sendWakeOnConnect = false

    /// Wake the device and send a Wake HID command once connected (HDMI-CEC TV power-on).
    func wakeAndPowerOn(to device: AppleTVDevice) {
        sendWakeOnConnect = true
        wakeAndConnect(to: device)
    }

    /// Set when the user explicitly tore down the connection (via `disconnect()`).
    /// Auto-retry logic checks this to distinguish user-intent cancellation from
    /// network-driven drops/failures.
    @Published var userInitiatedDisconnect = false

    /// Most recent Now Playing payload the ATV has volunteered via `_iMC`
    /// event subscription. Nil until the ATV pushes its first update after
    /// a media-state change occurs while connected.
    @Published var nowPlaying: NowPlayingInfo?

    /// Most recent attention state reported by `FetchAttentionState`.
    /// 1 = screensaver/idle, 2 = app in foreground, 3 = some apps use other values.
    /// Nil until first keepalive response.
    @Published var attentionState: Int?

    /// True when the ATV has an active text field waiting for keyboard input.
    /// Set by _tiStarted / _tiStopped Companion events.
    @Published var keyboardActive: Bool = false

    /// Apps available for launch on the ATV, fetched after each session start.
    /// Each entry is (id: bundleID, name: displayName).
    @Published var appList: [(id: String, name: String)] = []

    /// Live AirPlay MRP tunnel — opened after Companion session is established.
    /// Provides real-time now-playing pushes (title, artist, position) that the
    /// Companion `_iMC` channel only delivers reactively on state changes.
    private var airPlayTunnel: AirPlayTunnel.Tunnel?
    private var lastPlaybackStateTimestamp: Double = 0

    // MARK: - Connect / Disconnect

    /// Smart connect: probes the device first (1 s TCP timeout).
    /// - If it responds → connect directly (device is already on, no wait).
    /// - If it doesn't  → send WoL then poll every 3 s (up to 60 s) until the
    ///   device's Companion port opens, then connect. If still unreachable after
    ///   60 s, attempt a connect anyway so the user gets a proper error message.
    ///
    /// Uses Task.detached so blocking probes never touch the main thread.
    func wakeAndConnect(to device: AppleTVDevice) {
        // Accept from `.disconnected` (fresh user action) OR `.error` (Retry
        // button click — the previous attempt failed and left us in an error
        // state). Any other state means a connect is already in flight.
        switch state {
        case .disconnected, .error: break
        default: return
        }
        userInitiatedDisconnect = false
        state = .waking
        currentDevice = device

        guard let host = device.host, let port = device.port else {
            state = .error("Device not yet resolved — try again")
            return
        }

        let mac = MACStore.load(for: device.id)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Fast path: device is already on — skip WoL and boot wait entirely.
            let reachable = Self.isReachableSync(host: host, port: Int(port), timeoutSeconds: 1)
            Log.companion.report("SmartConnect: \(device.name) reachable=\(reachable)")

            if reachable {
                let s = self
                await MainActor.run {
                    guard let conn = s, conn.state == .waking else { return }
                    conn.state = .disconnected
                    conn.connect(to: device)
                }
                return
            }

            // Slow path: device is off (or sleeping). Send WoL then poll.
            if let mac { try? WakeOnLAN.send(mac: mac, targetIP: host) }

            // Poll every 3 s for up to 60 s for the Companion port to open.
            // Probing the actual port (not just ping) ensures the MRP service
            // is ready, not just the network stack.
            let deadline = Date().addingTimeInterval(90)
            var wolSent = 1          // already sent once above

            while Date() < deadline {
                // Bail if the user cancelled (tapped Disconnect) while we wait.
                let s1 = self
                let cancelled = await MainActor.run { s1?.state != .waking }
                if cancelled { return }

                try? await Task.sleep(for: .seconds(3))

                // Re-check state after sleeping (user might have disconnected).
                let s2 = self
                let stillWaking = await MainActor.run { s2?.state == .waking }
                if !stillWaking { return }

                if Self.isReachableSync(host: host, port: Int(port), timeoutSeconds: 2) {
                    Log.companion.report("SmartConnect: \(device.name) responded after \(wolSent) WoL packet(s)")
                    let s3 = self
                    await MainActor.run {
                        guard let conn = s3, conn.state == .waking else { return }
                        conn.sendWakeOnConnect = true
                        conn.state = .disconnected
                        conn.connect(to: device)
                    }
                    return
                }

                // Re-send WoL every ~15 s (every 5th poll) in case the first
                // packet was lost before the NIC's WoL listener was ready.
                wolSent += 1
                if wolSent % 5 == 0, let mac {
                    Log.wol.report("WoL: resending (attempt \(wolSent / 5 + 1))")
                    try? WakeOnLAN.send(mac: mac, targetIP: host)
                }
            }

            // Timed out — attempt connect anyway so the user sees a real error.
            Log.companion.report("SmartConnect: \(device.name) did not respond in 90 s, trying connect")
            let s4 = self
            await MainActor.run {
                guard let conn = s4, conn.state == .waking else { return }
                conn.sendWakeOnConnect = true
                conn.state = .disconnected
                conn.connect(to: device)
            }
        }
    }

    private nonisolated static func isReachableSync(host: String, port: Int, timeoutSeconds: Double) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // Force RST-on-close (SO_LINGER with zero timeout) so the probe socket
        // does NOT park its local ephemeral port in TIME_WAIT. Otherwise the
        // real connect() that follows can hit EADDRINUSE when the kernel
        // happens to pick the same ephemeral port for the same remote 4-tuple.
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        defer { Darwin.close(fd) }

        // Pin the source address to the primary interface's IPv4 address.
        // On multi-NIC setups where two NICs share a subnet (en0+en1 both on
        // 192.168.1.0/24), neither the kernel's default source selection nor
        // IP_BOUND_IF(en0) are enough — the kernel still picks the wrong
        // source IP and connect() synchronously returns EHOSTUNREACH. A
        // bind(2) to the primary IPv4 address matches what `nc -s` does and
        // what works for `route get`.
        let boundSrc = PrimaryInterface.bindSourceAddress(fd: fd, logHost: host)
        if boundSrc == nil {
            Log.companion.report("isReachableSync: bindSourceAddress returned nil for \(host)")
        }

        // Set non-blocking
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

        if result == 0 { return true }           // immediate connect (rare but possible)
        if errno != EINPROGRESS {
            Log.companion.report("isReachableSync: connect() returned \(result), errno \(errno) (\(String(cString: strerror(errno))))")
            return false
        }

        // Wait for writability with poll()
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms    = Int32(timeoutSeconds * 1000)
        let ready = poll(&pfd, 1, ms)
        if ready <= 0 {
            Log.companion.report("isReachableSync: poll() returned \(ready) (timeout \(ms)ms), errno \(errno)")
            return false
        }

        // Check for async connect error
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if err != 0 {
            Log.companion.report("isReachableSync: SO_ERROR=\(err) (\(String(cString: strerror(err))))")
        }
        return err == 0
    }

    func connect(to device: AppleTVDevice) {
        // Accept from `.disconnected` or `.error` — see wakeAndConnect for why.
        switch state {
        case .disconnected, .error: break
        default: return
        }
        userInitiatedDisconnect = false
        guard let host = device.host, let port = device.port else {
            state = .error("Device not yet resolved — try again")
            return
        }
        state = .connecting
        currentDevice = device
        pairing = HAPPairing()
        sendNonce = 0
        recvNonce = 0

        let deviceCopy = device
        writeQueue.async { [weak self] in
            // Build sockaddr_in once — address doesn't change between retries.
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

            // Connect — retry up to 3 times for transient network errors
            // (EHOSTUNREACH / ENETUNREACH / ETIMEDOUT) which resolve on their own
            // after the ATV finishes waking or the ARP cache refreshes.
            // EADDRINUSE can happen when a recent probe socket's TIME_WAIT
            // entry collides with the ephemeral port the kernel picks here.
            // Each attempt uses a FRESH fd — BSD sockets refuse a second connect()
            // on an fd that already attempted one (returns EISCONN/EALREADY/EINVAL),
            // so reusing the fd would burn every retry after the first failure.
            let transientErrnos: Set<Int32> = [EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EADDRINUSE]
            var fd: Int32 = -1
            var lastErrno: Int32 = 0
            var lastFailStage = "socket"
            for attempt in 0..<3 {
                // Fresh fd per attempt.
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

                // Same source-IP pinning as isReachableSync — prevents
                // EHOSTUNREACH from the kernel picking the wrong NIC on
                // multi-NIC hosts that share a subnet.
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

            // Enable TCP keepalive so the kernel sends probes if traffic stops.
            // This prevents routers from silently dropping idle TCP state.
            var enable: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, socklen_t(MemoryLayout<Int32>.size))
            var idleSec: Int32 = 10   // start probing after 10 s idle
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idleSec, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionEpoch &+= 1
                self.socketFD = fd
                self.receiveBuffer.removeAll()
                // Start blocking read loop on its own queue
                self.startReadLoop(fd: Int(fd), epoch: self.connectionEpoch)
                // Kick off pairing
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
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connectionEpoch &+= 1
        let fd = socketFD
        socketFD = -1
        if fd >= 0 { Darwin.close(fd) }   // unblocks the read loop
        state = .disconnected
        currentDevice = nil
        pairing = nil
        pairVerify = nil
        encryptKey = nil
        decryptKey = nil
        sendWakeOnConnect = false
        sessionStartTxn = nil
        attentionState = nil
        keyboardActive = false
        pendingCallbacks.removeAll()
        currentTextInputData = nil
        lastPlaybackStateTimestamp = 0
        nowPlaying = nil
        txnCounter = 0
        sendNonce = 0
        recvNonce = 0
        airPlayTunnel?.close()
        airPlayTunnel = nil
    }

    // MARK: - Remote Commands (post-session)

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        let keycode = command.hidKeycode

        if command.sendReleaseOnly {
            // Wake/Sleep: single "button up" (release) event only — no press first.
            // The Companion protocol triggers the power/CEC action on the release edge.
            let txn = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn))
        } else {
            // Normal buttons: down then up
            let txn = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 1, txn: txn))
            let txn2 = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn2))
        }
    }

    /// Sends a long-press: holds the button down for `ms` milliseconds before releasing.
    func sendLongPress(_ command: RemoteCommand, ms: Int = 700) {
        guard state == .connected else { return }
        let keycode = command.hidKeycode
        let txn = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 1, txn: txn))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(ms))
            guard self.state == .connected else { return }
            let txn2 = self.txnCounter; self.txnCounter &+= 1
            self.sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn2))
        }
    }

    /// Send a trackpad swipe gesture in the given direction.
    /// Uses `_hidT` touch events (press → hold × N → release) across the
    /// 1000×1000 coordinate space declared in `_touchStart`.
    func sendSwipe(_ direction: SwipeDirection) {
        guard state == .connected else { return }
        Task { @MainActor in
            guard self.state == .connected else { return }
            let (start, end) = direction.coordinates
            let baseNs = DispatchTime.now().uptimeNanoseconds

            // Press
            self.sendEncrypted(OPACK.encodeTouchEvent(x: start.x, y: start.y, phase: 1,
                                                      txn: self.txnCounter, nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
            self.txnCounter &+= 1
            // Hold / move
            for pt in direction.interpolatedSteps() {
                self.sendEncrypted(OPACK.encodeTouchEvent(x: pt.x, y: pt.y, phase: 3,
                                                          txn: self.txnCounter, nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
                self.txnCounter &+= 1
                try? await Task.sleep(for: .milliseconds(18))
            }
            // Release
            self.sendEncrypted(OPACK.encodeTouchEvent(x: end.x, y: end.y, phase: 4,
                                                      txn: self.txnCounter, nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
            self.txnCounter &+= 1
            try? await Task.sleep(for: .milliseconds(50))
            let tStop = self.txnCounter; self.txnCounter &+= 1
            self.sendEncrypted(OPACK.encodeTouchStop(txn: tStop))
        }
    }

    // MARK: - Session Init

    /// Send text to the active text field on the Apple TV.
    ///
    /// Flow: _tiStop → _tiStart (parse session UUID from response) → _tiC event.
    /// Calls `completion` on the main actor with nil on success or an Error on failure.
    func sendText(_ text: String, completion: @escaping (Error?) -> Void) {
        guard state == .connected else {
            completion(TextInputError.notConnected)
            return
        }
        guard keyboardActive, let tiD = currentTextInputData else {
            completion(TextInputError.noActiveTextField)
            return
        }
        guard let uuid = RTITextOperations.extractSessionUUID(from: tiD) else {
            completion(TextInputError.sessionUUIDMissing)
            return
        }
        let payload = RTITextOperations.inputPayload(sessionUUID: uuid, text: text)
        let cmdTxn = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeTextInputCommand(tiD: payload, txn: cmdTxn))
        Log.companion.report("Companion: sent text input (\(text.count) chars)")
        completion(nil)
    }

    /// Clear the active text field on the ATV by sending an empty `textToAssert` RTI payload.
    func sendClearText(completion: @escaping (Error?) -> Void) {
        guard state == .connected else { completion(TextInputError.notConnected); return }
        guard keyboardActive, let tiD = currentTextInputData else {
            completion(TextInputError.noActiveTextField); return
        }
        guard let uuid = RTITextOperations.extractSessionUUID(from: tiD) else {
            completion(TextInputError.sessionUUIDMissing); return
        }
        let payload = RTITextOperations.clearPayload(sessionUUID: uuid)
        let cmdTxn = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeTextInputCommand(tiD: payload, txn: cmdTxn))
        Log.companion.report("Companion: sent clear text input")
        completion(nil)
    }

    /// Fetch the list of launchable apps from the ATV and store in `appList`.
    func fetchApps() {
        let txn = txnCounter; txnCounter &+= 1
        Log.companion.report("Companion: fetchApps txn=\(txn)")
        pendingCallbacks[txn] = { [weak self] response in
            guard let self else { return }
            let cVal = response["_c"]
            Log.companion.report("Companion: fetchApps callback fired, _c type=\(type(of: cVal))")
            guard let content = response["_c"] as? [String: Any] else {
                Log.companion.report("Companion: fetchApps — unexpected response format")
                return
            }
            let apps = content.compactMap { (key, value) -> (id: String, name: String)? in
                guard let name = value as? String else { return nil }
                return (id: key, name: name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.appList = apps
            Log.companion.report("Companion: fetched \(apps.count) apps")
        }
        sendEncrypted(OPACK.encodeFetchLaunchableApplicationsEvent(txn: txn))
    }

    /// Launch an app on the ATV by bundle ID.
    func launchApp(bundleID: String) {
        guard state == .connected else { return }
        let txn = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeLaunchApp(bundleID: bundleID, txn: txn))
        Log.companion.report("Companion: launching app \(bundleID)")
    }

    private func startAirPlayMRP() {
        guard let device = currentDevice,
              let host = device.host,
              let creds = credentialStore.loadAirPlay(deviceID: device.id) else { return }
        let airPlayClientID = String(data: creds.clientID, encoding: .utf8)
        let writeQueue = self.writeQueue
        writeQueue.async { [weak self] in
            do {
                let tunnel = try AirPlayTunnel.open(
                    host: host,
                    credentials: creds,
                    mrpClientID: airPlayClientID,
                    onMessage: { [weak self] msgData in
                        guard let update = MRPDecoder.decodeNowPlaying(from: msgData) else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            var info = self.nowPlaying ?? NowPlayingInfo()
                            if let v = update.title       { info.title        = v }
                            if let v = update.artist      { info.artist       = v }
                            if let v = update.album       { info.album        = v }
                            if let v = update.duration    { info.duration     = v }
                            if let v = update.elapsedTime { info.elapsedTime  = v }
                            // Only accept playbackRate if this message has a newer
                            // playbackStateTimestamp than what we've seen before.
                            // Ghost messages from inactive apps share stale timestamps
                            // and would otherwise clobber the real playing state.
                            if let v = update.playbackRate {
                                let ts = update.playbackStateTimestamp ?? 0
                                if ts >= self.lastPlaybackStateTimestamp {
                                    self.lastPlaybackStateTimestamp = ts
                                    info.playbackRate = v
                                }
                            }
                            self.nowPlaying = info
                        }
                    }
                )
                DispatchQueue.main.async { [weak self] in
                    self?.airPlayTunnel = tunnel
                }
            } catch {
                Log.pairing.report("AirPlay MRP tunnel: \(error) — now-playing will use Companion only")
            }
        }
    }

    private func startCompanionSession() {
        guard let stored = credentialStore.load(deviceID: currentDevice?.id ?? "") else {
            return
        }
        let clientID = stored.clientID
        let rpID     = stored.rpID
        let name     = stored.name
        // The ATV's Companion handshake expects all five of these messages,
        // in order, before it considers the session established. Skipping
        // `_touchStart` or `_tiStart` leaves the session half-open and the
        // ATV closes the socket after ~35 s. Mirrors pyatv's CompanionAPI
        // setup in api.py:151-158.
        let txn1 = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeSystemInfo(clientID: clientID, rpID: rpID, name: stored.name, txn: txn1))

        let txn2 = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeTouchStart(txn: txn2))

        let txn3 = txnCounter; txnCounter &+= 1
        let localSID = UInt32.random(in: 0..<UInt32.max)
        sessionStartTxn = txn3
        sendEncrypted(OPACK.encodeSessionStart(txn: txn3, localSID: localSID))

        let txn4 = txnCounter; txnCounter &+= 1
        pendingCallbacks[txn4] = { [weak self] response in
            guard let self else { return }
            let tiD = (response["_c"] as? [String: Any])?["_tiD"] as? Data
            self.currentTextInputData = tiD
            let wasActive = self.keyboardActive
            self.keyboardActive = tiD != nil
            if self.keyboardActive && !wasActive {
                Log.companion.report("Companion: keyboard active (text field focused at connect)")
            }
        }
        sendEncrypted(OPACK.encodeTextInputStart(txn: txn4))

        // _interest subscriptions are sent from handleOPACKMessage once we
        // receive the ATV's _sessionStart response — sending them before that
        // causes the ATV to silently ignore them (session not yet ready).
    }

    /// Send a `FetchAttentionState` Request every 25 s. The ATV drops idle
    /// Companion sockets at ~38 s; any real Request the ATV responds to
    /// refreshes its idle timer, and FetchAttentionState is the cheapest
    /// one pyatv's API exposes.
    ///
    /// `_systemInfo` does *not* work as a keepalive — the ATV silently
    /// ignores it and no response means no timer refresh.
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 25.0, repeating: 25.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connected else {
                self?.keepaliveTimer?.cancel()
                self?.keepaliveTimer = nil
                return
            }
            let txn = self.txnCounter; self.txnCounter &+= 1
            self.sendEncrypted(OPACK.encodeFetchAttentionState(txn: txn))
            // Keyboard focus is tracked via _tiStarted / _tiStopped push
            // events (subscribed via _interest). No need to poll _tiStart.
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Pairing PIN

    func submitPairingPin(_ pin: String) {
        guard state == .awaitingPairingPin, let m2 = pendingM2Data else { return }
        state = .connecting   // block re-entry; SRP modular exponentiation is slow
        let capturedPairing = pairing
        Task.detached {       // run off main thread — avoids beachball
            do {
                let m3 = try capturedPairing?.processM2(m2, pin: pin) ?? Data()
                await MainActor.run {
                    self.sendFrame(.psNext, payload: OPACK.wrapPsNextData(m3))
                }
            } catch {
                await MainActor.run {
                    self.state = .error("Pairing M3 failed: \(error)")
                }
            }
        }
    }

    // MARK: - Pair Setup

    private func startPairSetup() {
        guard let payload = pairing?.m1Payload() else { return }
        sendFrame(.psStart, payload: OPACK.wrapPsStartData(payload))
    }

    private func handlePsNext(_ payload: Data) {
        let opackExtracted = OPACK.extractPairingData(from: payload)
        let extracted = opackExtracted ?? payload
        if opackExtracted == nil {
            let hex = payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            Log.companion.fail("Companion psNext: OPACK extraction failed, raw payload hex: \(hex)")
        }
        let tlv = TLV8.decode(extracted)
        let step = tlv[.state]?.first ?? 0

        switch step {
        case 2:  // M2: ATV sent salt + public key → need PIN
            pendingM2Data = extracted   // store TLV8, not OPACK wrapper
            state = .awaitingPairingPin

        case 4:  // M4: server proof verified → auto-send M5
            do {
                let m5 = try pairing?.processM4(extracted) ?? Data()
                sendFrame(.psNext, payload: OPACK.wrapPsNextData(m5))
            } catch {
                state = .error("Pairing M4 failed: \(error)")
            }

        case 6:  // M6: ATV identity → pairing complete
            do {
                let creds = try pairing?.processM6(extracted)
                guard let device = currentDevice, let creds else {
                    state = .error("Pairing M6: missing device or credentials")
                    return
                }
                credentialStore.save(credentials: creds, for: device.id)
                // Companion protocol requires pair-verify on a fresh TCP connection.
                // Close now; reconnect() will see stored credentials and start pair-verify.
                let deviceToVerify = device
                disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.connect(to: deviceToVerify)
                }
            } catch {
                state = .error("Pairing M6 failed: \(error)")
            }

        default:
            Log.companion.fail("Companion: unexpected PS_Next state \(step)")
        }
    }

    // MARK: - Pair Verify

    private func startPairVerify(device: AppleTVDevice) {
        guard let creds = credentialStore.load(deviceID: device.id) else {
            startPairSetup()
            return
        }
        let verify = CompanionPairVerify(credentials: creds)
        pairVerify = verify
        sendFrame(.pvStart, payload: OPACK.wrapPvStartData(verify.m1Payload()))
    }

    private func handlePvNext(_ payload: Data) {
        let extracted = OPACK.extractPairingData(from: payload) ?? payload
        let tlv = TLV8.decode(extracted)
        let step = tlv[.state]?.first ?? 0
        Log.companion.trace("Companion pvNext step=\(step) (\(extracted.count) bytes TLV8)")

        switch step {
        case 2:  // M2: ATV sent its ephemeral key + encrypted identity
            do {
                let m3 = try pairVerify?.processM2(extracted) ?? Data()
                sendFrame(.pvNext, payload: OPACK.wrapPairingData(m3))
            } catch {
                state = .error("Pair verify M2 failed: \(error)")
            }

        case 4:  // M4: success or error
            do {
                try pairVerify?.verifyM4(extracted)
                encryptKey = pairVerify?.sessionEncryptKey
                decryptKey = pairVerify?.sessionDecryptKey
                state = .connected
                startCompanionSession()
                startKeepalive()
                startAirPlayMRP()
                if sendWakeOnConnect {
                    sendWakeOnConnect = false
                    // Small delay to let the session handshake complete before
                    // sending the Wake HID event — triggers HDMI-CEC TV power-on
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.send(.wake)
                    }
                }
            } catch {
                // Only delete credentials if the ATV explicitly rejected them (serverError).
                // Transient failures (TCP reset, timeout, crypto) should not wipe valid credentials.
                if case CompanionPairVerify.VerifyError.serverError = error,
                   let device = currentDevice {
                    credentialStore.delete(deviceID: device.id)
                }
                state = .error("Pair verify failed: \(error)\nPress Connect to re-pair.")
            }

        default:
            Log.companion.fail("Companion: unexpected PV_Next state \(step)")
        }
    }

    // MARK: - Encrypted E_OPACK

    private func handleEOPACK(_ payload: Data) {
        guard let key = decryptKey else { return }
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData(recvNonce))
            recvNonce += 1
            // AAD = frame header: type byte + 3-byte big-endian payload length
            let aad = Data([
                CompanionFrame.FrameType.eOPACK.rawValue,
                UInt8((payload.count >> 16) & 0xFF),
                UInt8((payload.count >> 8)  & 0xFF),
                UInt8( payload.count        & 0xFF),
            ])
            let box   = try ChaChaPoly.SealedBox(combined: nonce.withUnsafeBytes { Data($0) } + payload)
            let plain = try ChaChaPoly.open(box, using: key, authenticating: aad)
            handleOPACKMessage(plain)
        } catch {
            Log.companion.fail("Companion: E_OPACK decrypt failed: \(error)")
        }
    }

    private func handleOPACKMessage(_ data: Data) {
        guard let msg = OPACK.decodeDict(data) else {
            Log.companion.fail("Companion: E_OPACK decode failed (\(data.count)B) hex: \(data.prefix(32).map{String(format:"%02x",$0)}.joined(separator:" "))")
            return
        }
        let identifier = msg["_i"] as? String ?? ""
        // _x is decoded as Int by decodeDict; cast via Int before UInt32
        let txn        = (msg["_x"] as? Int).map { UInt32($0) } ?? 0

        // Log every message so we can see what the ATV sends
        if Log.companion.isEnabled(type: .debug) {
            func describeValue(_ v: Any?) -> String {
                switch v {
                case let s as String:        return "\"\(s)\""
                case let i as Int:           return "\(i)"
                case let f as Double:        return "\(f)"
                case let d as Data:          return "<\(d.count)B>"
                case let dict as [String: Any]:
                    let inner = dict.keys.sorted().map { "\($0)=\(describeValue(dict[$0]))" }.joined(separator: ",")
                    return "{\(inner)}"
                default:                     return "?"
                }
            }
            let kvDesc = msg.keys.sorted().map { k in "\(k)=\(describeValue(msg[k]))" }.joined(separator: " ")
            Log.companion.report("Companion ← OPACK[\(data.count)B]: \(kvDesc)")
        }

        switch identifier {
        case "_heartbeat":
            sendEncrypted(OPACK.encodeHeartbeatResponse(txn: txn))
            Log.companion.trace("Companion → _heartbeat response txn=\(txn) ✓")
        case "_ping":
            sendEncrypted(OPACK.encodePong(txn: txn))
            Log.companion.trace("Companion → _pong txn=\(txn) ✓")
        case "_pong":
            break
        case "_tiStarted":
            // Capture the text-input archive from the push if present.
            // Some tvOS builds omit `_tiD` from the push and require a
            // follow-up `_tiStart` request to fetch it — handle both.
            let c = msg["_c"] as? [String: Any]
            if let tiD = c?["_tiD"] as? Data {
                currentTextInputData = tiD
            }
            keyboardActive = true
            Log.companion.report("Companion: keyboard active (text field focused)")
            if currentTextInputData == nil {
                let tiTxn = txnCounter; txnCounter &+= 1
                pendingCallbacks[tiTxn] = { [weak self] resp in
                    guard let self else { return }
                    self.currentTextInputData = (resp["_c"] as? [String: Any])?["_tiD"] as? Data
                }
                sendEncrypted(OPACK.encodeTextInputStart(txn: tiTxn))
            }
        case "_tiStopped":
            keyboardActive = false
            currentTextInputData = nil
            Log.companion.report("Companion: keyboard inactive (text field lost focus)")
        case "_iMC":
            // Media-control push event. Payload is in `_c`.
            updateNowPlaying(from: msg)
        case "FetchAttentionState":
            // Some ATV firmwares include _i in the response; handle here too.
            if let inner = msg["_c"] as? [String: Any],
               let st = inner["state"] as? Int {
                attentionState = st
                Log.companion.report("Companion: attentionState=\(st)")
            }
        default:
            let msgType = msg["_t"] as? Int ?? 0
            // Fire any pending response callback for this txn.
            if let cb = pendingCallbacks.removeValue(forKey: txn) {
                cb(msg)
            }
            // Detect _sessionStart response (has no _i, matched by txn).
            if let sst = sessionStartTxn, txn == sst, msgType == 3 {
                sessionStartTxn = nil
                Log.companion.report("Companion: session confirmed, subscribing to events")
                // Mirror pyatv's wire sequence exactly: one event per _interest,
                // _iMC first, then FetchAttentionState, then the other events,
                // then FetchLaunchableApplicationsEvent. Bulk _interest with
                // unrecognized event names appears to break FetchLaunchable.
                let t1 = txnCounter; txnCounter &+= 1
                sendEncrypted(OPACK.encodeInterest(events: ["_iMC"], txn: t1))

                let attnTxn = self.txnCounter; self.txnCounter &+= 1
                self.pendingCallbacks[attnTxn] = { [weak self] resp in
                    guard let self else { return }
                    let st = (resp["_c"] as? [String: Any])?["state"] as? Int
                    if let st { self.attentionState = st }
                    // Subscribe remaining events, then fetch apps.
                    for evt in ["SystemStatus", "TVSystemStatus",
                                "_tiStarted", "_tiStopped"] {
                        let t = self.txnCounter; self.txnCounter &+= 1
                        self.sendEncrypted(OPACK.encodeInterest(events: [evt], txn: t))
                    }
                    if self.appList.isEmpty { self.fetchApps() }
                }
                self.sendEncrypted(OPACK.encodeFetchAttentionState(txn: attnTxn))
            }
            // Detect FetchAttentionState response (no _i, has _c.state).
            if msgType == 3,
               let inner = msg["_c"] as? [String: Any],
               let st = inner["state"] as? Int {
                attentionState = st
                Log.companion.report("Companion: attentionState=\(st)")
            }
        }
    }

    private func updateNowPlaying(from msg: [String: Any]) {
        // Media-control data lives in `_c`; some responses put it top-level.
        let inner = (msg["_c"] as? [String: Any]) ?? msg
        let update = NowPlayingInfo(from: inner)
        // Merge into existing state so fields absent from this event (e.g.
        // playbackRate not included in a title-only push) don't overwrite
        // previously-known good values.
        var info = nowPlaying ?? NowPlayingInfo()
        // If the app changed, reset stale metadata so old title/artist don't linger.
        if let newApp = update.app, newApp != info.app {
            info.title = nil; info.artist = nil; info.album = nil
            info.elapsedTime = nil; info.duration = nil; info.playbackRate = nil
        }
        if let v = update.title        { info.title        = v }
        if let v = update.artist       { info.artist       = v }
        if let v = update.album        { info.album        = v }
        if let v = update.app          { info.app          = v }
        if let v = update.elapsedTime  { info.elapsedTime  = v }
        if let v = update.duration     { info.duration     = v }
        if let v = update.playbackRate { info.playbackRate = v }
        info.raw.merge(update.raw) { _, new in new }
        nowPlaying = info
        Log.companion.report("Companion: now-playing update (keys: \(inner.keys.sorted().joined(separator: ",")))")
    }

    private func sendEncrypted(_ opackData: Data) {
        guard let key = encryptKey else {
            Log.companion.report("Companion → sendEncrypted DROPPED (no key, \(opackData.count)B)")
            return
        }
        // Peek at the OPACK dict so we can see what we tried to send
        if Log.companion.isEnabled(type: .debug) {
            let peek = OPACK.decodeDict(opackData).map { d -> String in
                let i = d["_i"] as? String ?? "?"
                let t = d["_t"] as? Int ?? -1
                let x = d["_x"] as? Int ?? -1
                return "_i=\(i) _t=\(t) _x=\(x)"
            } ?? "<undecodable \(opackData.count)B>"
            Log.companion.report("Companion → OPACK[\(opackData.count)B]: \(peek)")
        }
        do {
            let nonce = try ChaChaPoly.Nonce(data: nonceData(sendNonce))
            sendNonce += 1
            // AAD = frame header: type byte + 3-byte big-endian payload length
            // Payload length = ciphertext (same as plaintext) + 16-byte Poly1305 tag
            let payloadLen = opackData.count + 16
            let aad = Data([
                CompanionFrame.FrameType.eOPACK.rawValue,
                UInt8((payloadLen >> 16) & 0xFF),
                UInt8((payloadLen >> 8)  & 0xFF),
                UInt8( payloadLen        & 0xFF),
            ])
            let sealed = try ChaChaPoly.seal(opackData, using: key, nonce: nonce, authenticating: aad)
            sendFrame(.eOPACK, payload: sealed.ciphertext + sealed.tag)
        } catch {
            Log.companion.fail("Companion: encrypt failed: \(error)")
        }
    }

    /// 12-byte nonce: counter serialized as 12-byte little-endian integer.
    /// For counters that fit in 64 bits: bytes 0–7 = LE counter, bytes 8–11 = 0x00.
    /// Matches pyatv's Chacha20Cipher(nonce_length=12): counter.to_bytes(12, 'little').
    private func nonceData(_ counter: UInt64) -> Data {
        var n = counter.littleEndian
        return Data(bytes: &n, count: 8) + Data(repeating: 0, count: 4)
    }

    // MARK: - Sending

    private func sendFrame(_ type: CompanionFrame.FrameType, payload: Data) {
        let fd = socketFD
        guard fd >= 0 else {
            Log.companion.fail("Companion: sendFrame called with no socket")
            return
        }
        Log.companion.trace("Companion → sending \(type) (\(payload.count) bytes)")
        let frameData = CompanionFrame(type: type, payload: payload).encoded
        writeQueue.async {
            frameData.withUnsafeBytes { rawBuf in
                var offset = 0
                let base   = rawBuf.baseAddress!
                let total  = rawBuf.count
                while offset < total {
                    let n = Darwin.write(fd, base + offset, total - offset)
                    if n <= 0 {
                        Log.companion.fail("Companion send error (errno \(errno))")
                        return
                    }
                    offset += n
                }
            }
        }
    }

    // MARK: - Receiving

    /// Blocking read loop — runs entirely on readQueue, never touches main thread directly.
    private func startReadLoop(fd: Int, epoch: Int) {
        readQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(Int32(fd), &buf, buf.count)
                if n <= 0 {
                    // EOF or error (or socket closed by disconnect())
                    let err = n < 0 ? errno : 0
                    let reason = err == 0 ? "EOF (ATV closed connection)" :
                                 "errno \(err): \(String(cString: strerror(err)))"
                    Log.companion.report("Companion: read loop ended — \(reason)")
                    DispatchQueue.main.async {
                        guard let self, self.connectionEpoch == epoch else { return }
                        self.keyboardActive = false
                        self.currentTextInputData = nil
                        if err != 0 {
                            self.state = .error("Read error: \(reason)")
                        } else {
                            self.state = .disconnected
                        }
                    }
                    return
                }
                let chunk = Data(buf[..<n])
                Log.companion.trace("Companion ← \(n) bytes")
                DispatchQueue.main.async {
                    guard let self, self.connectionEpoch == epoch else { return }
                    self.receiveBuffer.append(chunk)
                    self.processBuffer()
                }
            }
        }
    }

    private func processBuffer() {
        while let frame = CompanionFrame.read(from: &receiveBuffer) {
            Log.companion.trace("Companion ← frame \(frame.type) (\(frame.payload.count) bytes)")
            switch frame.type {
            case .psNext:  handlePsNext(frame.payload)
            case .pvNext:  handlePvNext(frame.payload)
            case .eOPACK:  handleEOPACK(frame.payload)
            default:
                Log.companion.fail("Companion: unhandled frame 0x\(String(frame.type.rawValue, radix: 16))")
            }
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
    /// Every key/value we saw, stringified. Useful for debugging and for any
    /// field we haven't named above yet.
    public var raw: [String: String]

    public init() {
        self.title = nil; self.artist = nil; self.album = nil; self.app = nil
        self.elapsedTime = nil; self.duration = nil; self.playbackRate = nil
        self.raw = [:]
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
        self.album        = str("album", "kMRMediaRemoteNowPlayingInfoAlbum")
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
}

// MARK: - Text input errors

enum TextInputError: LocalizedError {
    case notConnected
    case noActiveTextField
    case sessionUUIDMissing

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Not connected to an Apple TV"
        case .noActiveTextField:  return "No text input active on Apple TV"
        case .sessionUUIDMissing: return "Text input session UUID missing from ATV response"
        }
    }
}
