import Foundation
import Darwin
import AppleTVIPC

// `atv` — command-line companion to the AppleTVRemote.app, connecting to its
// IPC Unix-domain socket. Commands mirror the app's remote UI; when the app
// isn't running we launch it and spin on the socket until it answers.

// MARK: - ANSI colors

enum Color {
    static let reset  = "\u{001B}[0m"
    static let red    = "\u{001B}[31m"
    static let green  = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan   = "\u{001B}[36m"
    static let dim    = "\u{001B}[2m"

    /// Colors on only when stdout is a TTY and NO_COLOR is unset — matches
    /// the no-color.org convention every other modern CLI follows.
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(fileno(stdout)) != 0
    }()

    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? code + s + reset : s
    }
}

func red   (_ s: String) -> String { Color.wrap(s, Color.red)    }
func green (_ s: String) -> String { Color.wrap(s, Color.green)  }
func yellow(_ s: String) -> String { Color.wrap(s, Color.yellow) }
func cyan  (_ s: String) -> String { Color.wrap(s, Color.cyan)   }
func dim   (_ s: String) -> String { Color.wrap(s, Color.dim)    }

// MARK: - Exit helpers

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((red("error: ") + message + "\n").utf8))
    exit(code)
}

// MARK: - IPC client (blocking, single-connection)

final class IPCConnection {
    private let fd: Int32
    private var buffer = Data()

    private init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }

    /// Attempts to open `socketPath` with the given receive timeout. Returns nil
    /// on ECONNREFUSED / ENOENT (app isn't running); throws on unexpected errors.
    static func open(path: String, timeoutSeconds: Double) -> IPCConnection? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < cap else { Darwin.close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = path.withCString { strcpy(dst, $0) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        if rc != 0 { Darwin.close(fd); return nil }

        // SO_RCVTIMEO so waitResponse() can bail rather than block forever.
        let usec = Int32(timeoutSeconds * 1_000_000)
        var tv = timeval(tv_sec: time_t(usec / 1_000_000),
                         tv_usec: suseconds_t(usec % 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return IPCConnection(fd: fd)
    }

    func send(_ frame: IPCFrame) throws {
        var data = try frame.encode()
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, p.advanced(by: sent), data.count - sent)
                if n <= 0 { throw IPCClientError.writeFailed(errno) }
                sent += n
            }
        }
    }

    /// Reads frames until one matches `isWanted` (typically "response matching
    /// id"). Intervening events are forwarded to `onEvent`.
    func awaitResponse(id: String, onEvent: (IPCEvent) -> Void = { _ in }) throws -> IPCResponse {
        while true {
            let frame = try readFrame()
            switch frame {
            case .response(let r) where r.id == id: return r
            case .response:                         continue
            case .event(let e):                     onEvent(e)
            case .request:                          continue
            }
        }
    }

    func readFrame() throws -> IPCFrame {
        while true {
            if let nlIdx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nlIdx)
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if line.isEmpty { continue }
                return try IPCFrame.decode(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0  { throw IPCClientError.closed }
            if n < 0   { throw IPCClientError.readFailed(errno) }
            buffer.append(chunk, count: n)
        }
    }
}

enum IPCClientError: Error, LocalizedError {
    case writeFailed(Int32), readFailed(Int32), closed
    var errorDescription: String? {
        switch self {
        case .writeFailed(let e): return "write failed (errno \(e))"
        case .readFailed(let e):  return "read failed (errno \(e))"
        case .closed:             return "server closed the connection"
        }
    }
}

// MARK: - Auto-launch

/// Braille spinner frame glyphs — single-width, renders nicely in any terminal.
let spinnerFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

func connectOrLaunch() -> IPCConnection {
    // Fast path: app is running, answer in <50ms.
    if let c = IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 2) {
        return c
    }

    // Launch the app (non-interactively, don't steal focus).
    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments = ["-g", "-b", "com.adhir.appletv-remote"]
    do {
        try launch.run()
    } catch {
        die("failed to launch AppleTVRemote.app: \(error.localizedDescription)")
    }

    // Braille spinner while we poll, 150ms cadence, 10s cap.
    let showSpinner = Color.enabled
    let message = "starting AppleTVRemote.app…"
    let start = Date()
    var frame = 0
    while Date().timeIntervalSince(start) < 10 {
        if let c = IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 2) {
            if showSpinner {
                // Clear spinner line.
                fputs("\r\u{001B}[2K", stdout)
                fflush(stdout)
            }
            print(cyan("✓ started"))
            return c
        }
        if showSpinner {
            let glyph = spinnerFrames[frame % spinnerFrames.count]
            fputs("\r\(cyan(glyph)) \(message)", stdout)
            fflush(stdout)
            frame += 1
        }
        usleep(150_000)
    }
    if showSpinner { fputs("\r\u{001B}[2K", stdout); fflush(stdout) }
    die("timed out waiting for AppleTVRemote.app to start")
}

// MARK: - Command dispatch

extension IPCConnection {
    func request(_ cmd: IPCCommand, args: [String: String]? = nil,
                 onEvent: (IPCEvent) -> Void = { _ in }) throws -> IPCResponse {
        let id = String(UUID().uuidString.prefix(8))
        try send(.request(IPCRequest(id: id, cmd: cmd, args: args)))
        return try awaitResponse(id: id, onEvent: onEvent)
    }
}

func expectOk(_ r: IPCResponse) {
    guard r.ok else { die(r.error ?? "unknown error") }
}

// MARK: - Commands

func cmdList(_ conn: IPCConnection) throws {
    let r = try conn.request(.list)
    expectOk(r)
    let devices = r.devices ?? []
    if devices.isEmpty {
        print(yellow("No Apple TVs discovered yet — the app may still be scanning."))
        return
    }
    // Columns: marker, name, host/status, flags
    let nameWidth = max(12, devices.map { $0.name.count }.max() ?? 12)
    for d in devices {
        let marker = d.isDefault ? green("●") : " "
        var flags: [String] = []
        if d.paired     { flags.append(green("paired")) }
        if d.autoConnect { flags.append(cyan("auto")) }
        if !d.resolved  { flags.append(yellow("resolving")) }
        let host = d.host.map { dim($0) } ?? dim("—")
        let name = d.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        print("\(marker) \(name)  \(host)  \(flags.joined(separator: " "))")
    }
}

func cmdStatus(_ conn: IPCConnection) throws {
    let r = try conn.request(.status)
    expectOk(r)
    guard let s = r.status else { die("server returned no status") }
    let name = s.deviceName ?? dim("(no device)")
    let host = s.host.map { dim(" · \($0)") } ?? ""
    let state = colorForState(s.connectionState)
    print("\(name)\(host)  \(state)")
}

func colorForState(_ text: String) -> String {
    switch text {
    case "Connected":                      return green(text)
    case "Disconnected":                   return dim(text)
    case let t where t.hasPrefix("Error"): return red(text)
    case let t where t.hasPrefix("Waking"): return cyan(text)
    default:                                return cyan(text)
    }
}

func cmdKey(_ conn: IPCConnection, key: IPCKey, longPress: Bool = false) throws {
    let r = try conn.request(longPress ? .longPress : .key, args: ["key": key.rawValue])
    expectOk(r)
}

func cmdSelect(_ conn: IPCConnection, device: String) throws {
    let r = try conn.request(.select, args: ["device": device])
    expectOk(r)
    print(green("✓ default device set to \(device)"))
}

func cmdPower(_ conn: IPCConnection) throws {
    let r = try conn.request(.power)
    expectOk(r)
}

func cmdPair(_ conn: IPCConnection, device: String) throws {
    // Start pairing — server responds to the original pair-start request
    // only after pairing completes (or fails). PIN is requested via event.
    let stderr = FileHandle.standardError
    print(cyan("Starting pairing with \(device)…"))
    let id = String(UUID().uuidString.prefix(8))
    try conn.send(.request(IPCRequest(id: id, cmd: .pairStart, args: ["device": device])))
    var promptedForPin = false
    let final = try conn.awaitResponse(id: id) { event in
        switch event.event {
        case .pinRequired:
            promptedForPin = true
            fputs(cyan("Enter PIN shown on Apple TV: "), stdout); fflush(stdout)
            guard let pin = readLine(strippingNewline: true), !pin.isEmpty else {
                FileHandle.standardError.write(Data(red("no PIN supplied\n").utf8))
                return
            }
            do {
                try conn.send(.request(IPCRequest(id: id + ".pin", cmd: .pairPin, args: ["pin": pin])))
                // We deliberately share the same request-id stream; the pair-pin
                // ack is a separate id that we silently ignore — the final
                // pair-start response still arrives once the ATV confirms.
            } catch {
                stderr.write(Data(red("failed to send PIN: \(error)\n").utf8))
            }
        case .paired:
            print(green("✓ paired"))
        case .error:
            stderr.write(Data(red("pair error: \(event.message ?? "unknown")\n").utf8))
        default:
            break
        }
    }
    _ = promptedForPin
    expectOk(final)
}

// MARK: - Arg parsing

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let text = """
    atv — control Apple TV from the command line

    Usage:
      atv list                     List discovered Apple TVs
      atv status                   Default device + connection state
      atv select <name>            Set default device (enables auto-connect)
      atv pair <name>              Pair with an Apple TV (prompts for PIN)
      atv l | r | u | d            D-pad left / right / up / down
      atv select-btn               Click (D-pad centre)
      atv pp                       Play / Pause
      atv home [--long]            Home button (long-press opens Control Center)
      atv menu                     Menu / Back
      atv vol+ | vol-              Volume up / down
      atv power                    Toggle (wake if asleep, sleep if on)
      atv disconnect               Drop the connection
      atv ping                     Round-trip ping to the app

    Colors honor NO_COLOR and are auto-disabled on non-TTY stdout.
    """
    print(text)
    exit(args.isEmpty ? 0 : 2)
}

guard !args.isEmpty else { usage() }

do {
    // ping doesn't need auto-launch — if the app isn't running, say so.
    if args[0] == "ping" {
        guard let conn = IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 2) else {
            die("AppleTVRemote.app is not running (no socket at \(IPCSocket.path))")
        }
        let r = try conn.request(.ping)
        expectOk(r)
        print(green("pong"))
        exit(0)
    }

    let conn = connectOrLaunch()

    switch args[0] {
    case "list":        try cmdList(conn)
    case "status":      try cmdStatus(conn)
    case "select":
        guard args.count >= 2 else { die("select requires a device name") }
        try cmdSelect(conn, device: args[1])
    case "pair":
        guard args.count >= 2 else { die("pair requires a device name") }
        try cmdPair(conn, device: args[1])
    case "l":           try cmdKey(conn, key: .left)
    case "r":           try cmdKey(conn, key: .right)
    case "u":           try cmdKey(conn, key: .up)
    case "d":           try cmdKey(conn, key: .down)
    case "select-btn":  try cmdKey(conn, key: .select)
    case "pp":          try cmdKey(conn, key: .playPause)
    case "menu":        try cmdKey(conn, key: .menu)
    case "home":
        let long = args.contains("--long")
        try cmdKey(conn, key: .home, longPress: long)
    case "vol+":        try cmdKey(conn, key: .volumeUp)
    case "vol-":        try cmdKey(conn, key: .volumeDown)
    case "power":       try cmdPower(conn)
    case "disconnect":
        let r = try conn.request(.disconnect)
        expectOk(r)
        print(green("✓ disconnected"))
    case "-h", "--help", "help":
        usage()
    default:
        die("unknown command: \(args[0])")
    }
} catch {
    die(error.localizedDescription)
}
