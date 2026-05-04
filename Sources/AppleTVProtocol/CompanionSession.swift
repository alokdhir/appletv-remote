import Foundation
import Darwin
import AppleTVLogging

// MARK: - Delegate

/// Callbacks from `CompanionSession` to its owner (`CompanionConnection`).
/// All calls are dispatched to the main queue before firing.
@MainActor
public protocol CompanionSessionDelegate: AnyObject {
    func sessionDidUpdateNowPlaying(_ info: CompanionNowPlayingUpdate)
    func sessionDidChangeKeyboardActive(_ active: Bool, data: Data?)
    func sessionDidUpdateAttentionState(_ state: Int)
    func sessionDidReadError(_ message: String)
    func sessionDidClose()
    func sessionDidConfirmStart()
    func sessionDidReceivePairingFrame(_ frame: CompanionFrame)
    func sessionDidFetchApps(_ apps: [(id: String, name: String)])
}

// MARK: - CompanionNowPlayingUpdate

/// Raw now-playing key/value map as received from an `_iMC` push, passed
/// straight through to `CompanionConnection` for merging into `NowPlayingInfo`.
public struct CompanionNowPlayingUpdate {
    public let inner: [String: Any]
    public init(_ inner: [String: Any]) { self.inner = inner }
}

// MARK: - CompanionSession

/// Owns the live Companion session: the TCP socket fd, the blocking read loop,
/// the encrypted frame transport, the transaction counter, pending-callback
/// dispatch, keepalive timer, and all feature-level send methods (HID, swipe,
/// text-input, app-list, launch).
///
/// `CompanionSession` is ignorant of SwiftUI, `@Published` state, pairing, and
/// device discovery — those stay in `CompanionConnection`. Events flow back via
/// `CompanionSessionDelegate`.
///
/// Threading: created and torn down on `@MainActor`. The blocking read loop
/// runs on `readQueue`; writes run on `writeQueue`. State mutations (txnCounter,
/// pendingCallbacks, keepaliveTimer, etc.) always happen on the main actor.
@MainActor
public final class CompanionSession {

    // MARK: - Init / teardown

    public weak var delegate: (any CompanionSessionDelegate)?

    private let transport: EncryptedFrameTransport
    private let fd: Int32
    private let epoch: Int
    private let writeQueue: DispatchQueue
    private let readQueue: DispatchQueue

    private var receiveBuffer = Data()
    private var txnCounter: UInt32
    private var pendingCallbacks: [UInt32: ([String: Any]) -> Void] = [:]
    private var sessionStartTxn: UInt32?
    private var currentTextInputData: Data?
    private var keepaliveTimer: DispatchSourceTimer?
    /// Wall-clock of the most recent text-input op (sendText/sendBackspace/
    /// sendClearText). Used to skip the keepalive's stop+start poll while the
    /// user is actively typing — otherwise that poll's transient stale-UUID
    /// window can race with a user send.
    private var lastTextOpAt: Date?

    /// Create a session over an already-connected socket fd.
    /// - Parameters:
    ///   - fd: Connected TCP socket. `CompanionSession` takes ownership; it will
    ///     close the fd when `close()` is called.
    ///   - epoch: Connection epoch from `CompanionConnection` — read-loop
    ///     callbacks bail if the epoch changes (i.e. we reconnected).
    ///   - transport: Encryption layer with keys already installed.
    ///   - writeQueue: Serial queue for Darwin.write calls.
    ///   - readQueue: Serial queue for the blocking Darwin.read loop.
    public init(fd: Int32,
                epoch: Int,
                transport: EncryptedFrameTransport,
                writeQueue: DispatchQueue,
                readQueue: DispatchQueue) {
        self.fd = fd
        self.epoch = epoch
        self.transport = transport
        self.writeQueue = writeQueue
        self.readQueue = readQueue
        self.txnCounter = UInt32.random(in: 1...65535)
    }

    /// Start the blocking read loop. Call once immediately after init.
    public func start() {
        startReadLoop()
    }

    /// Tear down the session: cancel keepalive, close the socket, clear callbacks.
    /// Safe to call multiple times.
    public func close() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        pendingCallbacks.removeAll()
        currentTextInputData = nil
        // Closing the fd unblocks the blocking read() in startReadLoop.
        Darwin.close(fd)
    }

    // MARK: - Session startup

    /// Send the five session-init messages (_systemInfo, _touchStart, _sessionStart,
    /// _tiStart) that the ATV requires before it considers the session open.
    public func sendSessionInit(clientID: String, name: String) {
        let txn1 = nextTxn()
        sendEncrypted(OPACK.encodeSystemInfo(clientID: clientID, name: name, txn: txn1))

        let txn2 = nextTxn()
        sendEncrypted(OPACK.encodeTouchStart(txn: txn2))

        let txn3 = nextTxn()
        let localSID = UInt32.random(in: 0..<UInt32.max)
        sessionStartTxn = txn3
        sendEncrypted(OPACK.encodeSessionStart(txn: txn3, localSID: localSID))

        let txn4 = nextTxn()
        pendingCallbacks[txn4] = { [weak self] response in
            guard let self else { return }
            let tiD = (response["_c"] as? [String: Any])?["_tiD"] as? Data
            self.currentTextInputData = tiD
            self.delegate?.sessionDidChangeKeyboardActive(tiD != nil, data: tiD)
        }
        sendEncrypted(OPACK.encodeTextInputStart(txn: txn4))
    }

    // MARK: - Keepalive

    public func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 25.0, repeating: 25.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let txn = self.nextTxn()
            self.sendEncrypted(OPACK.encodeFetchAttentionState(txn: txn))
            if self.currentTextInputData != nil {
                // Skip the stop+start poll if the user typed within the last
                // keepalive interval — recent activity already confirms the
                // keyboard is alive, and racing the poll's stale-UUID window
                // against a user send breaks sendText with sessionUUIDMissing.
                if let last = self.lastTextOpAt,
                   Date().timeIntervalSince(last) < 25 {
                    return
                }
                let stopTxn = self.nextTxn()
                self.sendEncrypted(OPACK.encodeTextInputStop(txn: stopTxn))
                let tiTxn = self.nextTxn()
                self.pendingCallbacks[tiTxn] = { [weak self] resp in
                    guard let self else { return }
                    let tiD = (resp["_c"] as? [String: Any])?["_tiD"] as? Data
                    self.currentTextInputData = tiD
                    if tiD == nil {
                        Log.companion.report("Companion: keyboard inactive (poll detected no text field)")
                        self.delegate?.sessionDidChangeKeyboardActive(false, data: nil)
                    }
                }
                self.sendEncrypted(OPACK.encodeTextInputStart(txn: tiTxn))
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Remote Commands

    public func send(_ command: RemoteCommand) {
        let keycode = command.hidKeycode
        if command.sendReleaseOnly {
            let txn = nextTxn()
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn))
        } else {
            let txn = nextTxn()
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 1, txn: txn))
            let txn2 = nextTxn()
            sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn2))
        }
    }

    public func sendLongPress(_ command: RemoteCommand, ms: Int = 1000) {
        let keycode = command.hidKeycode
        let txn = nextTxn()
        sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 1, txn: txn))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self else { return }
            let txn2 = self.nextTxn()
            self.sendEncrypted(OPACK.encodeHIDCommand(keycode: keycode, state: 2, txn: txn2))
        }
    }

    public func sendSwipe(_ direction: SwipeDirection) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (start, end) = direction.coordinates
            let baseNs = DispatchTime.now().uptimeNanoseconds

            self.sendEncrypted(OPACK.encodeTouchEvent(x: start.x, y: start.y, phase: 1,
                                                      txn: self.nextTxn(),
                                                      nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
            for pt in direction.interpolatedSteps() {
                self.sendEncrypted(OPACK.encodeTouchEvent(x: pt.x, y: pt.y, phase: 3,
                                                          txn: self.nextTxn(),
                                                          nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
                try? await Task.sleep(for: .milliseconds(18))
            }
            self.sendEncrypted(OPACK.encodeTouchEvent(x: end.x, y: end.y, phase: 4,
                                                      txn: self.nextTxn(),
                                                      nanoseconds: DispatchTime.now().uptimeNanoseconds - baseNs))
            try? await Task.sleep(for: .milliseconds(50))
            self.sendEncrypted(OPACK.encodeTouchStop(txn: self.nextTxn()))
        }
    }

    // MARK: - Text Input

    public func sendText(_ text: String, completion: @escaping (Error?) -> Void) {
        guard let tiD = currentTextInputData else {
            completion(TextInputError.noActiveTextField); return
        }
        guard let uuid = RTITextOperations.extractSessionUUID(from: tiD) else {
            completion(TextInputError.sessionUUIDMissing); return
        }
        lastTextOpAt = Date()
        let payload = RTITextOperations.inputPayload(sessionUUID: uuid, text: text)
        sendEncrypted(OPACK.encodeTextInputCommand(tiD: payload, txn: nextTxn()))
        Log.companion.report("Companion: sent text input (\(text.count) chars)")
        completion(nil)
    }

    public func sendBackspace(completion: @escaping (Error?) -> Void) {
        lastTextOpAt = Date()
        let stopTxn = nextTxn()
        sendEncrypted(OPACK.encodeTextInputStop(txn: stopTxn))
        let startTxn = nextTxn()
        pendingCallbacks[startTxn] = { [weak self] response in
            guard let self else { return }
            guard let tiD = (response["_c"] as? [String: Any])?["_tiD"] as? Data else {
                completion(TextInputError.noActiveTextField); return
            }
            self.currentTextInputData = tiD
            guard let uuid = RTITextOperations.extractSessionUUID(from: tiD) else {
                completion(TextInputError.sessionUUIDMissing); return
            }
            let current = RTITextOperations.extractCurrentText(from: tiD) ?? ""
            let updated = String(current.dropLast())
            let payload = RTITextOperations.assertPayload(sessionUUID: uuid, text: updated)
            self.sendEncrypted(OPACK.encodeTextInputCommand(tiD: payload, txn: self.nextTxn()))
            Log.companion.report("Companion: sent backspace (was \(current.count) chars)")
            completion(nil)
        }
        sendEncrypted(OPACK.encodeTextInputStart(txn: startTxn))
    }

    public func sendClearText(completion: @escaping (Error?) -> Void) {
        lastTextOpAt = Date()
        let stopTxn = nextTxn()
        sendEncrypted(OPACK.encodeTextInputStop(txn: stopTxn))
        let startTxn = nextTxn()
        pendingCallbacks[startTxn] = { [weak self] response in
            guard let self else { return }
            guard let tiD = (response["_c"] as? [String: Any])?["_tiD"] as? Data else {
                completion(TextInputError.noActiveTextField); return
            }
            self.currentTextInputData = tiD
            guard let uuid = RTITextOperations.extractSessionUUID(from: tiD) else {
                completion(TextInputError.sessionUUIDMissing); return
            }
            let payload = RTITextOperations.clearPayload(sessionUUID: uuid)
            self.sendEncrypted(OPACK.encodeTextInputCommand(tiD: payload, txn: self.nextTxn()))
            Log.companion.report("Companion: sent clear text input")
            completion(nil)
        }
        sendEncrypted(OPACK.encodeTextInputStart(txn: startTxn))
    }

    // MARK: - App List / Launch

    public func fetchApps(completion: ((Result<[(id: String, name: String)], Error>) -> Void)? = nil) {
        let txn = nextTxn()
        Log.companion.report("Companion: fetchApps txn=\(txn)")
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.pendingCallbacks.removeValue(forKey: txn) != nil {
                Log.companion.report("Companion: fetchApps timed out (no response from ATV)")
                completion?(.failure(CompanionError.unexpectedResponse))
            }
        }
        pendingCallbacks[txn] = { [weak self] response in
            timeoutItem.cancel()
            guard let self else { return }
            let cVal = response["_c"]
            Log.companion.report("Companion: fetchApps callback fired, _c type=\(type(of: cVal))")
            guard let content = response["_c"] as? [String: Any] else {
                Log.companion.report("Companion: fetchApps — unexpected response format")
                completion?(.failure(CompanionError.unexpectedResponse))
                return
            }
            let apps = content.compactMap { (key, value) -> (id: String, name: String)? in
                guard let name = value as? String else { return nil }
                return (id: key, name: name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.delegate?.sessionDidFetchApps(apps)
            completion?(.success(apps))
        }
        sendEncrypted(OPACK.encodeFetchLaunchableApplicationsEvent(txn: txn))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeoutItem)
    }

    public func launchApp(bundleID: String,
                          completion: ((Result<Void, Error>) -> Void)? = nil) {
        let txn = nextTxn()
        Log.companion.report("Companion: launching app \(bundleID) txn=\(txn)")
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.pendingCallbacks.removeValue(forKey: txn) != nil {
                Log.companion.report("Companion: launchApp \(bundleID) timed out")
                completion?(.failure(CompanionError.unexpectedResponse))
            }
        }
        pendingCallbacks[txn] = { _ in
            timeoutItem.cancel()
            completion?(.success(()))
        }
        sendEncrypted(OPACK.encodeLaunchApp(bundleID: bundleID, txn: txn))
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchApp.timeout, execute: timeoutItem)
    }

    private enum LaunchApp {
        static let timeout: TimeInterval = 3
    }

    // MARK: - Encrypted send

    public func sendEncrypted(_ opackData: Data) {
        // Gate on Log.verbose, not Logger.isEnabled(type:) — the latter is a
// macOS 15+ API and we deploy to macOS 13.
if Log.verbose {
            let peek = OPACK.decodeDict(opackData).map { d -> String in
                let i = d["_i"] as? String ?? "?"
                let t = d["_t"] as? Int ?? -1
                let x = d["_x"] as? Int ?? -1
                return "_i=\(i) _t=\(t) _x=\(x)"
            } ?? "<undecodable \(opackData.count)B>"
            Log.companion.report("Companion → OPACK[\(opackData.count)B]: \(peek)")
        }
        do {
            let body = try transport.seal(opackData)
            sendFrame(.eOPACK, payload: body)
        } catch {
            Log.companion.fail("Companion: encrypt failed: \(error)")
        }
    }

    // MARK: - Frame send

    public func sendFrame(_ type: CompanionFrame.FrameType, payload: Data) {
        let fd = self.fd
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

    // MARK: - Test injection

    /// Feed a raw OPACK-encoded message directly into the session's dispatch
    /// logic, bypassing the socket and transport layer. Tests only.
    #if DEBUG
    public func injectOPACKForTesting(_ data: Data) {
        handleOPACKMessage(data)
    }
    #endif

    // MARK: - Read loop

    private func startReadLoop() {
        readQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                guard let self else { return }
                let fd = self.fd
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 {
                    let err = n < 0 ? errno : 0
                    let reason = err == 0 ? "EOF (ATV closed connection)" :
                                 "errno \(err): \(String(cString: strerror(err)))"
                    Log.companion.report("Companion: read loop ended — \(reason)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if err != 0 {
                            self.delegate?.sessionDidReadError("Read error: \(reason)")
                        } else {
                            self.delegate?.sessionDidClose()
                        }
                    }
                    return
                }
                let chunk = Data(buf[..<n])
                Log.companion.trace("Companion ← \(n) bytes")
                DispatchQueue.main.async { [weak self] in
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
            case .psNext, .pvNext:
                delegate?.sessionDidReceivePairingFrame(frame)
            case .eOPACK:
                handleEOPACK(frame.payload)
            default:
                Log.companion.fail("Companion: unhandled frame 0x\(String(frame.type.rawValue, radix: 16))")
            }
        }
    }

    // MARK: - E_OPACK handling

    private func handleEOPACK(_ payload: Data) {
        do {
            let plain = try transport.open(payload)
            handleOPACKMessage(plain)
        } catch {
            Log.companion.fail("Companion: E_OPACK decrypt failed: \(error)")
        }
    }

    private func handleOPACKMessage(_ data: Data) {
        let isLarge = data.count > 2000
        guard let msg = isLarge
            ? OPACK.decodeDictShallow(data)
            : OPACK.decodeDict(data)
        else {
            Log.companion.fail("Companion: E_OPACK decode failed (\(data.count)B) hex: \(data.prefix(32).map{String(format:"%02x",$0)}.joined(separator:" "))")
            return
        }
        let identifier = msg["_i"] as? String ?? ""
        let txn        = (msg["_x"] as? Int).map { UInt32($0) } ?? 0

        func fullMsg() -> [String: Any] {
            if isLarge, identifier != "_systemInfo" {
                return OPACK.decodeDict(data) ?? msg
            }
            return msg
        }

        // Gate on Log.verbose, not Logger.isEnabled(type:) — the latter is a
// macOS 15+ API and we deploy to macOS 13.
if Log.verbose {
            func describeValue(_ v: Any?) -> String {
                switch v {
                case let s as String:           return "\"\(s)\""
                case let i as Int:              return "\(i)"
                case let f as Double:           return "\(f)"
                case let d as Data:             return "<\(d.count)B>"
                case let dict as [String: Any]:
                    let inner = dict.keys.sorted().map { "\($0)=\(describeValue(dict[$0]))" }.joined(separator: ",")
                    return "{\(inner)}"
                default:                        return "?"
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
            let c = fullMsg()["_c"] as? [String: Any]
            let tiD = c?["_tiD"] as? Data
            currentTextInputData = tiD
            delegate?.sessionDidChangeKeyboardActive(true, data: tiD)
            Log.companion.report("Companion: keyboard active (text field focused)")
            if tiD == nil {
                let tiTxn = nextTxn()
                pendingCallbacks[tiTxn] = { [weak self] resp in
                    guard let self else { return }
                    let d = (resp["_c"] as? [String: Any])?["_tiD"] as? Data
                    self.currentTextInputData = d
                }
                sendEncrypted(OPACK.encodeTextInputStart(txn: tiTxn))
            }
        case "_tiStopped":
            currentTextInputData = nil
            delegate?.sessionDidChangeKeyboardActive(false, data: nil)
            Log.companion.report("Companion: keyboard inactive (text field lost focus)")
        case "_iMC":
            let inner = (fullMsg()["_c"] as? [String: Any]) ?? fullMsg()
            delegate?.sessionDidUpdateNowPlaying(CompanionNowPlayingUpdate(inner))
        case "FetchAttentionState":
            if let inner = msg["_c"] as? [String: Any],
               let st = inner["state"] as? Int {
                delegate?.sessionDidUpdateAttentionState(st)
                Log.companion.report("Companion: attentionState=\(st)")
            }
        default:
            let msgType = msg["_t"] as? Int ?? 0
            if let cb = pendingCallbacks.removeValue(forKey: txn) {
                cb(fullMsg())
            }
            if let sst = sessionStartTxn, txn == sst, msgType == 3 {
                sessionStartTxn = nil
                Log.companion.report("Companion: session confirmed, subscribing to events")
                let t = nextTxn()
                sendEncrypted(OPACK.encodeInterest(
                    events: ["_iMC", "SystemStatus", "TVSystemStatus",
                             "_tiStarted", "_tiStopped"], txn: t))
                let attnTxn = nextTxn()
                pendingCallbacks[attnTxn] = { [weak self] resp in
                    guard let self else { return }
                    if let st = (resp["_c"] as? [String: Any])?["state"] as? Int {
                        self.delegate?.sessionDidUpdateAttentionState(st)
                    }
                    self.delegate?.sessionDidConfirmStart()
                }
                sendEncrypted(OPACK.encodeFetchAttentionState(txn: attnTxn))
            }
            if msgType == 3,
               let inner = msg["_c"] as? [String: Any],
               let st = inner["state"] as? Int {
                delegate?.sessionDidUpdateAttentionState(st)
                Log.companion.report("Companion: attentionState=\(st)")
            }
        }
    }

    // MARK: - Helpers

    private func nextTxn() -> UInt32 {
        let t = txnCounter; txnCounter &+= 1; return t
    }
}

// MARK: - Errors

public enum CompanionError: LocalizedError {
    case unexpectedResponse
    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse: return "Unexpected response from Apple TV"
        }
    }
}

public enum TextInputError: LocalizedError {
    case notConnected
    case noActiveTextField
    case sessionUUIDMissing

    public var errorDescription: String? {
        switch self {
        case .notConnected:       return "Not connected to an Apple TV"
        case .noActiveTextField:  return "No text input active on Apple TV"
        case .sessionUUIDMissing: return "Text input session UUID missing from ATV response"
        }
    }
}
