import Foundation
import Darwin
import Combine
import AppleTVIPC
import AppleTVLogging
import AppleTVProtocol

// Unix-domain-socket IPC server that exposes the running app's state and
// connection to the `atv` CLI companion. Wire format: newline-delimited JSON
// frames as defined in AppleTVIPC.IPCProtocol.
//
// Lifecycle: started once at app launch (setUp called from AppleTVRemoteApp).
// The listen socket lives at `~/Library/Application Support/AppleTVRemote/atv.sock`
// with mode 0600. Clients are accepted onto a GCD queue; each connection has
// its own DispatchSourceRead that parses newline-delimited frames and dispatches
// commands back to the main actor for execution.
//
// Events (pin-required, connected, etc.) are fanned out to all connected clients
// by piggybacking on the CompanionConnection Combine publisher.
@MainActor
final class IPCServer {
    private let connection:  CompanionConnection
    private let discovery:   DeviceDiscovery
    private let autoConnect: AutoConnectStore
    private let reconnector: AutoReconnector

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "AppleTVRemote.IPCServer", qos: .userInitiated)

    // Keep client handles alive so we can broadcast events to them.
    private var clients: [ClientID: IPCClient] = [:]
    private var nextClientSeq: UInt64 = 0

    private var stateObserver: AnyCancellable?
    private var pendingPairClient: ClientID?
    private var pendingPairRequestID: String?
    private var lastBroadcastState: ConnectionState = .disconnected

    init(connection: CompanionConnection,
         discovery: DeviceDiscovery,
         autoConnect: AutoConnectStore,
         reconnector: AutoReconnector) {
        self.connection  = connection
        self.discovery   = discovery
        self.autoConnect = autoConnect
        self.reconnector = reconnector
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try createSocketDirectory()
            try bindAndListen()
            installAcceptLoop()
            observeConnectionState()
            Log.app.report("IPCServer: listening at \(IPCSocket.path)")
        } catch {
            Log.app.fail("IPCServer: failed to start: \(error)")
            teardown()
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        try? FileManager.default.removeItem(atPath: IPCSocket.path)
        for client in clients.values { client.close() }
        clients.removeAll()
    }

    // MARK: - Socket setup

    private func createSocketDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: IPCSocket.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Remove any stale socket file from a previous crash.
        try? FileManager.default.removeItem(atPath: IPCSocket.path)
    }

    private func bindAndListen() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.posix(errno, "socket") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = IPCSocket.path
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathCapacity else {
            Darwin.close(fd)
            throw IPCError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                _ = path.withCString { strcpy(dst, $0) }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
        }
        guard bindRC == 0 else {
            let err = errno
            Darwin.close(fd)
            throw IPCError.posix(err, "bind")
        }

        // Enforce 0600 on the socket file — only the owning user can talk to us.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 8) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw IPCError.posix(err, "listen")
        }

        listenFD = fd
    }

    private func installAcceptLoop() {
        // Run the accept loop on the main queue so `self` (a @MainActor class)
        // can be touched directly without cross-isolation assertions. A
        // DispatchSourceRead only fires when a connection is waiting, so
        // accept() won't block and there's no main-thread starvation risk.
        // We set O_NONBLOCK on the listen fd too so a spurious wake never
        // hangs us (accept returns EAGAIN, we bail).
        _ = Darwin.fcntl(listenFD, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let fd = Darwin.accept(self.listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = Darwin.fcntl(fd, F_SETFL, O_NONBLOCK)
            self.registerClient(fd: fd)
        }
        src.resume()
        acceptSource = src
    }

    private func registerClient(fd: Int32) {
        nextClientSeq &+= 1
        let cid = ClientID(value: nextClientSeq)
        let client = IPCClient(id: cid, fd: fd, queue: ioQueue) { [weak self] frame, clientID in
            guard let self else { return }
            Task { @MainActor in self.handle(frame: frame, clientID: clientID) }
        } onClose: { [weak self] clientID in
            guard let self else { return }
            Task { @MainActor in self.clients.removeValue(forKey: clientID) }
        }
        clients[cid] = client
    }

    // MARK: - Connection state → events

    private func observeConnectionState() {
        lastBroadcastState = connection.state
        stateObserver = connection.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.handle(stateChange: state)
            }
    }

    private func handle(stateChange state: ConnectionState) {
        defer { lastBroadcastState = state }
        switch state {
        case .awaitingPairingPin:
            // Relay the PIN prompt to the client that started pairing (if any).
            if let cid = pendingPairClient, let client = clients[cid] {
                client.send(.event(IPCEvent(event: .pinRequired,
                                            message: "Enter the PIN shown on your Apple TV")))
            }
        case .connected:
            if pendingPairClient != nil,
               let cid = pendingPairClient,
               let client = clients[cid],
               let rid = pendingPairRequestID {
                client.send(.event(IPCEvent(event: .paired)))
                client.send(.response(.ok(rid)))
                pendingPairClient = nil
                pendingPairRequestID = nil
            }
            broadcast(.event(IPCEvent(event: .connected,
                                      message: connection.currentDevice?.name)))
        case .disconnected:
            // Only broadcast if we actually came down from something alive.
            switch lastBroadcastState {
            case .connected, .connecting, .awaitingPairingPin, .waking:
                broadcast(.event(IPCEvent(event: .disconnected)))
            default: break
            }
        case .error(let msg):
            if let cid = pendingPairClient,
               let client = clients[cid],
               let rid = pendingPairRequestID {
                client.send(.response(.failure(rid, msg)))
                pendingPairClient = nil
                pendingPairRequestID = nil
            }
            broadcast(.event(IPCEvent(event: .error, message: msg)))
        default:
            break
        }
    }

    private func broadcast(_ frame: IPCFrame) {
        for client in clients.values { client.send(frame) }
    }

    // MARK: - Request dispatch

    private func handle(frame: IPCFrame, clientID: ClientID) {
        guard case .request(let req) = frame else { return }
        guard let client = clients[clientID] else { return }
        do {
            switch req.cmd {
            case .ping:
                client.send(.response(.ok(req.id)))
            case .list:
                client.send(.response(IPCResponse(id: req.id, ok: true, devices: listDevices())))
            case .status:
                if connection.nowPlaying == nil, connection.state == .connected {
                    Task { @MainActor [weak self, weak client] in
                        guard let self, let client else { return }
                        let deadline = Date().addingTimeInterval(4.0)
                        while Date() < deadline {
                            if self.connection.nowPlaying != nil { break }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        client.send(.response(IPCResponse(id: req.id, ok: true,
                                                           status: self.currentStatus())))
                    }
                } else {
                    client.send(.response(IPCResponse(id: req.id, ok: true, status: currentStatus())))
                }
            case .select:
                guard let name = req.args?["device"] else {
                    throw IPCError.badArgs("select requires args.device")
                }
                try handleSelect(id: req.id, nameOrID: name, client: client)
            case .pairStart:
                guard let name = req.args?["device"] else {
                    throw IPCError.badArgs("pair-start requires args.device")
                }
                try handlePairStart(id: req.id, nameOrID: name, client: client)
            case .pairPin:
                guard let pin = req.args?["pin"] else {
                    throw IPCError.badArgs("pair-pin requires args.pin")
                }
                try handlePairPin(id: req.id, pin: pin, client: client)
            case .key:
                try handleKey(id: req.id, keyName: req.args?["key"], client: client, longPress: false)
            case .longPress:
                try handleKey(id: req.id, keyName: req.args?["key"], client: client, longPress: true)
            case .power:
                handlePower(id: req.id, client: client)
            case .disconnect:
                connection.userInitiatedDisconnect = true
                connection.disconnect()
                client.send(.response(.ok(req.id)))
            }
        } catch {
            client.send(.response(.failure(req.id, error.localizedDescription)))
        }
    }

    // MARK: - Command implementations

    private func listDevices() -> [IPCDevice] {
        let defaultID = DefaultDevice.id
        return discovery.devices.map { d in
            IPCDevice(id: d.id,
                      name: d.name,
                      host: d.host,
                      paired: CredentialStore().hasCredentials(for: d.id),
                      autoConnect: autoConnect.isEnabled(d.id),
                      isDefault: d.id == defaultID,
                      resolved: d.host != nil)
        }
    }

    private func currentStatus() -> IPCStatus {
        let np = connection.nowPlaying.map {
            IPCNowPlaying(title: $0.title,
                          artist: $0.artist,
                          album: $0.album,
                          app: $0.app,
                          elapsedTime: $0.elapsedTime,
                          duration: $0.duration,
                          playbackRate: $0.playbackRate)
        }
        return IPCStatus(deviceID: connection.currentDevice?.id,
                         deviceName: connection.currentDevice?.name,
                         host: connection.currentDevice?.host,
                         connectionState: connection.state.displayText,
                         isReconnecting: reconnector.isReconnecting,
                         nowPlaying: np,
                         attentionState: connection.attentionState)
    }

    private func resolveDevice(_ nameOrID: String) -> AppleTVDevice? {
        discovery.devices.resolving(nameOrID)
    }

    private func handleSelect(id: String, nameOrID: String, client: IPCClient) throws {
        guard let device = resolveDevice(nameOrID) else {
            throw IPCError.notFound("No device matching \"\(nameOrID)\"")
        }
        DefaultDevice.id = device.id
        // Also enable auto-connect for it so the app will reconnect on launch.
        autoConnect.setEnabled(device.id, true)
        client.send(.response(.ok(id)))
    }

    private func handlePairStart(id: String, nameOrID: String, client: IPCClient) throws {
        guard let device = resolveDevice(nameOrID) else {
            throw IPCError.notFound("No device matching \"\(nameOrID)\"")
        }
        pendingPairClient = client.id
        pendingPairRequestID = id
        // Fresh pair — wipe any stale credential so the ATV re-prompts for PIN.
        CredentialStore().delete(deviceID: device.id)
        connection.userInitiatedDisconnect = true
        connection.disconnect()
        connection.userInitiatedDisconnect = false
        connection.connect(to: device)
        // We don't respond yet — the response is sent from the state observer
        // once we reach .connected (paired) or .error.
    }

    private func handlePairPin(id: String, pin: String, client: IPCClient) throws {
        guard connection.state == .awaitingPairingPin else {
            throw IPCError.badState("Not awaiting a PIN (state: \(connection.state.displayText))")
        }
        pendingPairRequestID = id
        pendingPairClient = client.id
        connection.submitPairingPin(pin)
    }

    private func handleKey(id: String, keyName: String?, client: IPCClient, longPress: Bool) throws {
        guard let keyName, let key = IPCKey(rawValue: keyName) else {
            throw IPCError.badArgs("unknown key \"\(keyName ?? "")\"")
        }
        guard connection.state == .connected else {
            throw IPCError.notConnected
        }
        if key.isSwipe {
            if let dir = swipeDirection(for: key) {
                connection.sendSwipe(dir)
            }
        } else {
            let cmd = remoteCommand(for: key)
            if longPress {
                connection.sendLongPress(cmd)
            } else {
                connection.send(cmd)
            }
        }
        client.send(.response(.ok(id)))
    }

    private func swipeDirection(for key: IPCKey) -> SwipeDirection? {
        switch key {
        case .swipeUp:    return .up
        case .swipeDown:  return .down
        case .swipeLeft:  return .left
        case .swipeRight: return .right
        default: return nil
        }
    }

    private func handlePower(id: String, client: IPCClient) {
        if connection.state == .connected {
            connection.send(.sleep)
            client.send(.response(.ok(id)))
            return
        }
        // Not connected — treat power as wake: connect and send Wake HID.
        // Route through handleKey so the response waits until connected.
        let target: AppleTVDevice? = connection.currentDevice
            ?? discovery.devices.first(where: { $0.id == DefaultDevice.id })
            ?? discovery.devices.first(where: { $0.host != nil })
        guard let device = target else {
            client.send(.response(.failure(id, "No device available to wake")))
            return
        }
        connection.wakeAndPowerOn(to: device)
        client.send(.response(.ok(id)))
    }

    private func remoteCommand(for key: IPCKey) -> RemoteCommand {
        switch key {
        case .up:         return .up
        case .down:       return .down
        case .left:       return .left
        case .right:      return .right
        case .select:     return .select
        case .menu:       return .menu
        case .home:       return .home
        case .playPause:  return .playPause
        case .volumeUp:   return .volumeUp
        case .volumeDown: return .volumeDown
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight:
            // Swipe keys are handled before this path via swipeDirection(for:).
            return .up
        }
    }
}

// MARK: - Client handle

/// Stable, dictionary-safe client identifier. Plain struct so we don't
/// accidentally pin the lifetime of an NSObject just to get uniqueness.
struct ClientID: Hashable { let value: UInt64 }

// All mutable state is accessed from the owning DispatchQueue — mark unchecked
// so closures passed to MainActor tasks can cross the concurrency boundary.
private final class IPCClient: @unchecked Sendable {
    let id: ClientID
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var isClosed = false
    private let onFrame: (IPCFrame, ClientID) -> Void
    private let onClose: (ClientID) -> Void

    init(id: ClientID,
         fd: Int32,
         queue: DispatchQueue,
         onFrame: @escaping (IPCFrame, ClientID) -> Void,
         onClose: @escaping (ClientID) -> Void) {
        self.id = id
        self.fd = fd
        self.queue = queue
        self.onFrame = onFrame
        self.onClose = onClose
        startReading()
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let myID = self.id
        src.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                Darwin.read(self.fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { self.close(); return }
            self.buffer.append(chunk, count: n)
            while let nlIdx = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<nlIdx)
                self.buffer.removeSubrange(self.buffer.startIndex...nlIdx)
                guard !line.isEmpty else { continue }
                do {
                    let frame = try IPCFrame.decode(line)
                    self.onFrame(frame, myID)
                } catch {
                    Log.app.fail("IPCClient: decode failed: \(error)")
                }
            }
        }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        src.resume()
        readSource = src
    }

    func send(_ frame: IPCFrame) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            guard var data = try? frame.encode() else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                guard let p = raw.baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let n = Darwin.write(self.fd, p.advanced(by: sent), data.count - sent)
                    if n <= 0 { self.close(); return }
                    sent += n
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose(id)
    }
}

// MARK: - Errors

private enum IPCError: LocalizedError {
    case posix(Int32, String)
    case pathTooLong
    case badArgs(String)
    case notFound(String)
    case badState(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .posix(let code, let op):
            return "\(op) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .pathTooLong:    return "socket path too long"
        case .badArgs(let m): return m
        case .notFound(let m): return m
        case .badState(let m): return m
        case .notConnected:   return "not connected"
        }
    }
}

// MARK: - Default device preference

@MainActor
enum DefaultDevice {
    static var id: String {
        get { UserDefaults.standard.string(forKey: "defaultDeviceID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "defaultDeviceID") }
    }
}

