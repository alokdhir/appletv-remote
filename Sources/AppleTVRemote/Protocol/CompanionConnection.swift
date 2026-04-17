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

    // Keepalive — DispatchSourceTimer is used instead of Task.sleep because
    // the MainActor cooperative scheduler can delay Task resumptions when
    // DispatchQueue.main is busy with the read-loop dispatches.
    private var keepaliveTimer: DispatchSourceTimer?

    // Set to true when connect() was initiated via wakeAndConnect() so we
    // auto-send the Wake HID command after the session is established.
    private var sendWakeOnConnect = false

    /// Set when the user explicitly tore down the connection (via `disconnect()`).
    /// Auto-retry logic checks this to distinguish user-intent cancellation from
    /// network-driven drops/failures.
    @Published var userInitiatedDisconnect = false

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
        guard errno == EINPROGRESS else { return false }

        // Wait for writability with poll()
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms    = Int32(timeoutSeconds * 1000)
        let ready = poll(&pfd, 1, ms)
        guard ready > 0 else { return false }

        // Check for async connect error
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
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
                self.socketFD = fd
                self.receiveBuffer.removeAll()
                // Start blocking read loop on its own queue
                self.startReadLoop(fd: Int(fd))
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
    }

    // MARK: - Remote Commands (post-session)

    func send(_ command: RemoteCommand) {
        guard state == .connected else { return }
        let keycode = command.hidKeycode

        if command.sendReleaseOnly {
            // Wake/Sleep: single "button up" (release) event only — no press first.
            // The Companion protocol triggers the power/CEC action on the release edge.
            let txn = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.pack([
                "_i": "_hidC", "_t": 2, "_x": txn,
                "_c": ["_hBtS": 2, "_hidC": Int(keycode)] as [String: Any],
            ] as [String: Any]))
        } else {
            // Normal buttons: down then up
            let txn = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.pack([
                "_i": "_hidC", "_t": 2, "_x": txn,
                "_c": ["_hBtS": 1, "_hidC": Int(keycode)] as [String: Any],
            ] as [String: Any]))
            let txn2 = txnCounter; txnCounter &+= 1
            sendEncrypted(OPACK.pack([
                "_i": "_hidC", "_t": 2, "_x": txn2,
                "_c": ["_hBtS": 2, "_hidC": Int(keycode)] as [String: Any],
            ] as [String: Any]))
        }
    }

    /// Sends a long-press: holds the button down for `ms` milliseconds before releasing.
    func sendLongPress(_ command: RemoteCommand, ms: Int = 700) {
        guard state == .connected else { return }
        let keycode = command.hidKeycode
        let txn = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.pack([
            "_i": "_hidC", "_t": 2, "_x": txn,
            "_c": ["_hBtS": 1, "_hidC": Int(keycode)] as [String: Any],
        ] as [String: Any]))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(ms))
            guard self.state == .connected else { return }
            let txn2 = self.txnCounter; self.txnCounter &+= 1
            self.sendEncrypted(OPACK.pack([
                "_i": "_hidC", "_t": 2, "_x": txn2,
                "_c": ["_hBtS": 2, "_hidC": Int(keycode)] as [String: Any],
            ] as [String: Any]))
        }
    }

    // MARK: - Session Init

    private func startCompanionSession() {
        guard let clientID = credentialStore.load(deviceID: currentDevice?.id ?? "")?.clientID else {
            return
        }
        let txn1 = txnCounter; txnCounter &+= 1
        sendEncrypted(OPACK.encodeSystemInfo(clientID: clientID, txn: txn1))

        let txn2 = txnCounter; txnCounter &+= 1
        let localSID = UInt32.random(in: 0..<UInt32.max)
        sendEncrypted(OPACK.encodeSessionStart(txn: txn2, localSID: localSID))
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
                if sendWakeOnConnect {
                    sendWakeOnConnect = false
                    // Small delay to let the session handshake complete before
                    // sending the Wake HID event — triggers HDMI-CEC TV power-on
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.send(.wake)
                    }
                }
            } catch {
                // Authentication error (code=2) = credentials mismatch; delete and re-pair.
                // Other errors also delete since stale credentials are the likely cause.
                if let device = currentDevice { credentialStore.delete(deviceID: device.id) }
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
        let kvDesc = msg.keys.sorted().map { k -> String in
            switch msg[k] {
            case let s as String: return "\(k)=\"\(s)\""
            case let i as Int:    return "\(k)=\(i)"
            case let d as Data:   return "\(k)=<\(d.count)B>"
            default:              return "\(k)=?"
            }
        }.joined(separator: " ")
        Log.companion.trace("Companion ← OPACK[\(data.count)B]: \(kvDesc)")

        switch identifier {
        case "_heartbeat":
            sendEncrypted(OPACK.encodeHeartbeatResponse(txn: txn))
            Log.companion.trace("Companion → _heartbeat response txn=\(txn) ✓")
        case "_ping":
            sendEncrypted(OPACK.encodePong(txn: txn))
            Log.companion.trace("Companion → _pong txn=\(txn) ✓")
        case "_pong":
            break
        default:
            break
        }
    }

    // MARK: - Keepalive

    /// Resends _systemInfo every 20 s to keep the ATV's idle-session timer from firing.
    /// The ATV processes _systemInfo silently (no "No request handler" error), so it is
    /// the safest known message to use as a keepalive without triggering a disconnect.
    /// _ping and _heartbeat are ignored by the ATV for timer purposes; _interest returns
    /// "No request handler" and causes an immediate close.
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        guard let clientID = credentialStore.load(deviceID: currentDevice?.id ?? "")?.clientID else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // First fire at 10 s — keeps us well inside any idle window the ATV enforces.
        timer.schedule(deadline: .now() + 10.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connected else {
                self?.keepaliveTimer?.cancel()
                self?.keepaliveTimer = nil
                return
            }
            let txn = self.txnCounter
            self.txnCounter &+= 1
            Log.companion.trace("Companion → keepalive _systemInfo txn=\(txn)")
            self.sendEncrypted(OPACK.encodeSystemInfo(clientID: clientID, txn: txn))
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func sendEncrypted(_ opackData: Data) {
        guard let key = encryptKey else { return }
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
    private func startReadLoop(fd: Int) {
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
                        guard let self, self.socketFD >= 0 else { return }
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
                    guard let self else { return }
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
