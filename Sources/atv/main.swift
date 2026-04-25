import Foundation
import Darwin
import AppleTVIPC
import AppleTVProtocol
import AppleTVLogging

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

// MARK: - Version

/// Prints "1.0-YYYYMMDDHHMM" where the suffix is the binary's mtime in the
/// local timezone. No build-system hooks needed — relinking updates it.
func printVersion() {
    let exePath = CommandLine.arguments.first.flatMap {
        $0.hasPrefix("/") ? $0 : nil
    } ?? Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    let stamp: String = {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
              let mtime = attrs[.modificationDate] as? Date else { return "unknown" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmm"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: mtime)
    }()
    print("1.0-\(stamp)")
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
var didJustLaunchApp = false

func connectOrLaunch() -> IPCConnection {
    // Fast path: app is running, answer in <50ms.
    if let c = IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 2) {
        return c
    }

    // Launch the app. -g (background/no-window) is intentionally omitted: with
    // -g SwiftUI never creates the WindowGroup window, so dock-click has nothing
    // to show. hideWindowAtStartup defaults to true so the window is hidden on
    // launch but still created — dock-click can then surface it normally.
    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments = ["-b", "com.adhir.appletv-remote"]
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
            didJustLaunchApp = true
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
        try send(.request(IPCRequest(id: id, cmd: cmd, args: args,
                                     verbose: Log.verbose ? true : nil)))
        return try awaitResponse(id: id, onEvent: { event in
            if event.event == .log {
                fputs("\(event.message ?? "")\n", stderr)
            } else {
                onEvent(event)
            }
        })
    }
}

func expectOk(_ r: IPCResponse) {
    guard r.ok else { die(r.error ?? "unknown error") }
}

// MARK: - Commands

func cmdList(_ conn: IPCConnection, namesOnly: Bool = false) throws {
    let r = try conn.request(.list)
    expectOk(r)
    let devices = r.devices ?? []
    // --names: plain one-name-per-line output, used by shell completion
    // scripts. Kept silent even when zero devices are discovered — completion
    // just gets no candidates, no yellow warning text to confuse the user.
    if namesOnly {
        for d in devices { print(d.name) }
        return
    }
    if devices.isEmpty {
        print(yellow("No Apple TVs discovered yet — the app may still be scanning."))
        return
    }
    // Columns: marker, name, host (fixed width), flags
    let nameWidth = max(12, devices.map { $0.name.count }.max() ?? 12)
    let hostWidth = max(15, devices.compactMap { $0.host?.count }.max() ?? 15)
    for d in devices {
        let marker = d.isDefault ? green("●") : " "
        var flags: [String] = []
        if d.paired     { flags.append(green("paired")) }
        if d.autoConnect { flags.append(cyan("auto")) }
        if !d.resolved  { flags.append(yellow("resolving")) }
        let hostRaw = d.host ?? "—"
        let hostPadded = hostRaw.padding(toLength: hostWidth, withPad: " ", startingAt: 0)
        let name = d.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        print("\(marker) \(name)  \(dim(hostPadded))  \(flags.joined(separator: " "))")
    }
}

// MARK: - Shell completion scripts

let zshCompletion = #"""
# zsh completion for atv — install via: eval "$(atv completion zsh)"
# or save to a file in $fpath as _atv (then #compdef atv replaces the compdef line).

_atv() {
    local -a subcommands
    subcommands=(
        'list:List discovered Apple TVs'
        'status:Default device + connection state'
        'select:Set default device (enables auto-connect)'
        'pair:Pair with an Apple TV (prompts for PIN)'
        'l:D-pad left'
        'r:D-pad right'
        'u:D-pad up'
        'd:D-pad down'
        'sl:Trackpad swipe left'
        'sr:Trackpad swipe right'
        'su:Trackpad swipe up'
        'sd:Trackpad swipe down'
        'click:Click (D-pad centre)'
        'pp:Play / Pause'
        'home:Home button'
        'menu:Menu / Back'
        'vol+:Volume up'
        'vol-:Volume down'
        'power:Toggle (wake if asleep, sleep if on)'
        'disconnect:Drop the connection'
        'ping:Round-trip ping to the app'
        'completion:Emit shell completion script'
    )
    if (( CURRENT == 2 )); then
        _describe 'command' subcommands
        return
    fi
    case "$words[2]" in
        select|pair)
            if (( CURRENT == 3 )); then
                local -a devices
                # newline-split so device names with spaces survive intact
                devices=("${(@f)$(atv list --names 2>/dev/null)}")
                _describe 'device' devices
            fi
            ;;
        home)
            if (( CURRENT == 3 )); then
                _describe 'flag' '(--long:long-press\ \(Control\ Center\))'
            fi
            ;;
        completion)
            if (( CURRENT == 3 )); then
                _describe 'shell' 'bash zsh'
            fi
            ;;
    esac
}

_atv "$@"
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit; }
compdef _atv atv
"""#

let bashCompletion = #"""
# bash completion for atv — install via: eval "$(atv completion bash)"
# or save to /usr/local/etc/bash_completion.d/atv (or /etc/bash_completion.d/).

_atv() {
    local cur prev words cword
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cword=$COMP_CWORD
    local subcmds="list status select pair l r u d sl sr su sd click pp home menu vol+ vol- power disconnect ping completion"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcmds" -- "$cur") )
        return
    fi

    case "${COMP_WORDS[1]}" in
        select|pair)
            if [[ $cword -eq 2 ]]; then
                # Read one name per line so names with spaces stay intact.
                local -a names
                while IFS= read -r line; do names+=("$line"); done \
                    < <(atv list --names 2>/dev/null)
                local n
                for n in "${names[@]}"; do
                    if [[ "$n" == "$cur"* ]]; then
                        COMPREPLY+=("$n")
                    fi
                done
            fi
            ;;
        home)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "--long" -- "$cur") )
            fi
            ;;
        completion)
            if [[ $cword -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "bash zsh" -- "$cur") )
            fi
            ;;
    esac
}

complete -F _atv atv
"""#

func cmdStatus(_ conn: IPCConnection) throws {
    // If we just launched the app, wait up to 8s for it to connect to a device
    // before reporting status — otherwise we'd always show "Disconnected" on
    // first launch even when an auto-connect device is configured.
    if didJustLaunchApp {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let r = try conn.request(.status)
            if let s = r.status,
               s.connectionState != "Disconnected",
               !s.connectionState.hasPrefix("Error") { break }
            usleep(300_000)
        }
    }
    let r = try conn.request(.status)
    expectOk(r)
    guard let s = r.status else { die("server returned no status") }
    let name = s.deviceName ?? dim("(no device)")
    let host = s.host.map { dim(" · \($0)") } ?? ""
    let state = colorForState(s.connectionState)
    print("\(name)\(host)  \(state)")
    // Show attention state when no _iMC media info has arrived yet.
    // _iMC events only fire on state *changes* — if media started before
    // this session connected, run a command (pp) to trigger the first push.
    if s.nowPlaying == nil, let attn = s.attentionState {
        let hint: String
        switch attn {
        case 1: hint = dim("screensaver / idle")
        case 2: hint = dim("app active")
        case 3: hint = dim("media active")
        default: hint = dim("attention state \(attn)")
        }
        print("  \(dim("·")) \(hint)")
    }
    if let np = s.nowPlaying {
        // Transport-state glyph: ▶ playing, ⏸ paused, ⏵ unknown/other.
        // Derived from playbackRate where possible (0 = paused, 1 = playing).
        let (glyph, label): (String, String?) = {
            switch np.playbackRate {
            case .some(0):          return (red("⏸"), "paused")
            case .some(let r) where r == 1: return (green("▶"), "playing")
            case .some(let r):      return (cyan("▶"), "×\(r)")
            case .none:             return (dim("⏵"), nil)
            }
        }()
        let bits = [np.title, np.artist, np.album].compactMap { $0 }.filter { !$0.isEmpty }
        if !bits.isEmpty {
            let titleYellow = bits[0...0].map { yellow($0) }
            let rest = bits.dropFirst().map { $0 }
            print("  \(glyph) \((titleYellow + rest).joined(separator: " — "))")
        } else if let label {
            print("  \(glyph) \(dim(label))")
        }
        if let app = np.app, !app.isEmpty {
            print("  \(dim("app: "))\(app)")
        }
        if let elapsed = np.elapsedTime {
            let pct = np.duration.map { d in d > 0 ? " \(Int(elapsed / d * 100))%" : "" } ?? ""
            let total = np.duration.map { "/\(fmtTime($0))" } ?? ""
            print("  \(dim("time:")) \(fmtTime(elapsed))\(total)\(pct)")
        }
    }
}

private func fmtTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, sec)
        : String(format: "%d:%02d", m, sec)
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
    // If the app is mid-auto-reconnect we'll briefly see "not connected" —
    // retry silently at 200 ms intervals for up to ~2 s before surfacing the
    // error. This swallows the window between EOF and the reconnect landing.
    let maxAttempts = 10
    for attempt in 1...maxAttempts {
        let r = try conn.request(longPress ? .longPress : .key, args: ["key": key.rawValue])
        if r.ok { return }
        if r.error == "not connected", attempt < maxAttempts {
            usleep(200_000)
            continue
        }
        die(r.error ?? "unknown error")
    }
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

func cmdApps(_ conn: IPCConnection) throws {
    let r = try conn.request(.apps)
    guard r.ok else { die(r.error ?? "apps failed") }
    let apps = r.apps ?? []
    if apps.isEmpty { print("No apps found"); return }
    print("─────────── \(apps.count) apps ───────────")
    for a in apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
        print("  \(a.name)  \(dim(a.id))")
    }
}

func cmdLaunch(_ conn: IPCConnection, bundleID: String) throws {
    let r = try conn.request(.launch, args: ["bundleID": bundleID])
    expectOk(r)
    print(green("✓ launched \(bundleID)"))
}

// MARK: - AirPlay pair / verify (Phase 1 probe)

/// Runs AirPlay pair-setup against a TV directly — no IPC/app involvement.
/// Asks the app for the device list only to resolve a name → (host, id).
/// On success writes <id>.airplay.json to Application Support.
func cmdPairAirPlay(_ conn: IPCConnection, device: String) throws {
    let listResp = try conn.request(.list)
    guard let devices = listResp.devices else { die("no device list from server") }
    guard let tv = devices.first(where: { $0.name == device || $0.id == device }) else {
        die("device '\(device)' not found — run 'atv list' to see known TVs")
    }
    guard let host = tv.host else {
        die("device '\(device)' has no resolved host yet — try 'atv list' first")
    }
    try runAirPlayPair(host: host, deviceID: tv.id, displayName: tv.name)
}

/// Shared AirPlay pair flow used by both IPC-backed and --standalone paths.
func runAirPlayPair(host: String, deviceID: String, displayName: String) throws {
    let http = AirPlayHTTP(host: host, port: 7000)
    print(cyan("AirPlay: connecting to \(displayName) (\(host):7000)…"))
    do {
        try http.connect(timeoutSeconds: 5)
    } catch {
        die("AirPlay: TCP connect failed: \(error)")
    }
    defer { http.close() }

    let setup = AirPlayPairSetup(http: http)
    do {
        try setup.beginPairing()
    } catch {
        die("AirPlay pair-setup M1/M2 failed: \(error)")
    }

    fputs(cyan("Enter PIN shown on \(displayName): "), stdout); fflush(stdout)
    guard let pin = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces),
          !pin.isEmpty else {
        die("no PIN supplied")
    }

    let creds: AirPlayCredentials
    do {
        creds = try setup.completePairing(pin: pin)
    } catch {
        die("AirPlay pair-setup M3-M6 failed: \(error)")
    }

    CredentialStore().saveAirPlay(creds, for: deviceID)
    print(green("✓ AirPlay paired with \(displayName)"))
    print(dim("  atvID:    \(String(data: creds.atvID, encoding: .utf8) ?? creds.atvID.map { String(format: "%02x", $0) }.joined())"))
    print(dim("  clientID: \(String(data: creds.clientID, encoding: .utf8) ?? "?")"))
    print(dim("  pyatv-format credentials:"))
    print(dim("  \(creds.pyatvString)"))

    // Immediately try pair-verify to confirm the credentials actually work
    // before the user moves on. This is the Phase 1 end-to-end gate.
    print(cyan("AirPlay: verifying credentials…"))
    // Need a fresh connection — pair-verify is a separate TCP session.
    let http2 = AirPlayHTTP(host: host, port: 7000)
    do { try http2.connect(timeoutSeconds: 5) } catch {
        die("AirPlay verify: TCP connect failed: \(error)")
    }
    defer { http2.close() }
    do {
        let keys = try AirPlayPairVerify(http: http2, credentials: creds).verify()
        print(green("✓ AirPlay pair-verify succeeded"))
        print(dim("  writeKey: \(keys.writeKey.prefix(8).map{String(format:"%02x",$0)}.joined())…"))
        print(dim("  readKey:  \(keys.readKey.prefix(8).map{String(format:"%02x",$0)}.joined())…"))
    } catch {
        die("AirPlay pair-verify failed: \(error)")
    }
}

/// Re-runs pair-verify using previously saved credentials. Useful for
/// debugging after the initial pair, and serves as the Phase 1 gate when
/// chained with `pair-airplay`.
func cmdAirPlayVerify(_ conn: IPCConnection, device: String) throws {
    let listResp = try conn.request(.list)
    guard let devices = listResp.devices else { die("no device list from server") }
    guard let tv = devices.first(where: { $0.name == device || $0.id == device }) else {
        die("device '\(device)' not found")
    }
    guard let host = tv.host else {
        die("device '\(device)' has no resolved host")
    }
    guard let creds = CredentialStore().loadAirPlay(deviceID: tv.id) else {
        die("no AirPlay credentials for \(tv.name) — run 'atv pair-airplay \(device)' first")
    }
    let http = AirPlayHTTP(host: host, port: 7000)
    try http.connect(timeoutSeconds: 5)
    defer { http.close() }
    let keys = try AirPlayPairVerify(http: http, credentials: creds).verify()
    print(green("✓ AirPlay pair-verify succeeded against \(tv.name)"))
    print(dim("  writeKey: \(keys.writeKey.prefix(8).map{String(format:"%02x",$0)}.joined())…"))
    print(dim("  readKey:  \(keys.readKey.prefix(8).map{String(format:"%02x",$0)}.joined())…"))
}

/// Phase 2a gate: open the encrypted AirPlay tunnel control channel and do
/// SETUP #1 (event channel). A successful decoded plist response containing
/// `eventPort` proves HAP framing and RTSP parser work end-to-end.
func cmdAirPlayTunnel(_ conn: IPCConnection, device: String) throws {
    let listResp = try conn.request(.list)
    guard let devices = listResp.devices else { die("no device list from server") }
    guard let tv = devices.first(where: { $0.name == device || $0.id == device }) else {
        die("device '\(device)' not found")
    }
    guard let host = tv.host else { die("device '\(device)' has no resolved host") }
    guard let creds = CredentialStore().loadAirPlay(deviceID: tv.id) else {
        die("no AirPlay credentials for \(tv.name) — run 'atv pair-airplay \(device)' first")
    }

    print(cyan("AirPlay tunnel: opening to \(tv.name) (\(host))…"))
    let rtsp: EncryptedAirPlayRTSP
    do { rtsp = try AirPlayTunnel.openControl(host: host, credentials: creds) }
    catch { die("tunnel open failed: \(error)") }
    defer { rtsp.close() }
    print(green("✓ encrypted RTSP control channel established"))

    let sessionUUID = UUID().uuidString.uppercased()
    let bodyData: Data
    do {
        bodyData = try PropertyListSerialization.data(
            fromPropertyList: AirPlayTunnel.eventSetupBody(sessionUUID: sessionUUID),
            format: .binary, options: 0)
    } catch { die("plist encode failed: \(error)") }

    let resp: EncryptedAirPlayRTSP.Response
    do {
        resp = try rtsp.request(
            method: "SETUP",
            uri:    "rtsp://\(host)/\(sessionUUID)",
            headers: ["Content-Type": "application/x-apple-binary-plist"],
            body:    bodyData)
    } catch { die("SETUP (event) failed: \(error)") }

    print(green("✓ SETUP response: \(resp.status) \(resp.reason)"))
    print(dim("  body: \(resp.body.count)B (\(resp.headers["content-type"] ?? "?"))"))

    guard resp.status == 200 else {
        die("SETUP returned \(resp.status); cannot continue")
    }

    let decoded: [String: Any]
    do {
        decoded = (try PropertyListSerialization.propertyList(
            from: resp.body, options: [], format: nil) as? [String: Any]) ?? [:]
    } catch { die("plist decode failed: \(error)") }

    if let eventPort = decoded["eventPort"] {
        print(green("✓ eventPort = \(eventPort)"))
        print(cyan("Control-channel gate passed — use 'atv airplay-mrp' for full MRP tunnel."))
    } else {
        let keyList = decoded.keys.sorted().joined(separator: ", ")
        print(dim("response keys: \(keyList)"))
        die("response did not include eventPort")
    }
}

/// Phase 2b gate: open the full AirPlay MRP tunnel (control + data channels).
/// Waits up to 10s for at least one MRP message from the ATV, then prints it.
func cmdAirPlayMRP(_ conn: IPCConnection, device: String) throws {
    let listResp = try conn.request(.list)
    guard let devices = listResp.devices else { die("no device list from server") }
    guard let tv = devices.first(where: { $0.name == device || $0.id == device }) else {
        die("device '\(device)' not found")
    }
    guard let host = tv.host else { die("device '\(device)' has no resolved host") }
    guard let creds = CredentialStore().loadAirPlay(deviceID: tv.id) else {
        die("no AirPlay credentials for \(tv.name) — run 'atv pair-airplay \(device)' first")
    }
    let airPlayClientID = String(data: creds.clientID, encoding: .utf8)

    print(cyan("AirPlay MRP tunnel: opening to \(tv.name) (\(host))…"))
    let lock = NSCondition()
    var received: [Data] = []
    let msgCallback: (Data) -> Void = { msg in
        lock.lock()
        received.append(msg)
        lock.broadcast()
        lock.unlock()
    }

    let tunnel: AirPlayTunnel.Tunnel
    do { tunnel = try AirPlayTunnel.open(host: host, credentials: creds,
                                         mrpClientID: airPlayClientID,
                                         onMessage: msgCallback) }
    catch { die("tunnel open failed: \(error)") }
    defer { tunnel.close() }
    print(green("✓ MRP data channel up — waiting for messages (10s)…"))

    // Wait up to 15 seconds collecting all messages.
    // The ATV typically sends a burst: SET_CONNECTION_STATE then
    // SET_STATE (type 30) + CONTENT_ITEM_UPDATE (40/45) with
    // now-playing metadata, then goes quiet. We wait for the first
    // message, then hold for 5 more seconds to catch the full burst.
    let firstDeadline = Date().addingTimeInterval(15)
    lock.lock()
    while received.isEmpty && Date() < firstDeadline {
        lock.wait(until: firstDeadline)
    }
    if !received.isEmpty {
        let burstDeadline = Date().addingTimeInterval(5)
        while Date() < burstDeadline {
            lock.wait(until: burstDeadline)
        }
    }
    let msgs = received
    lock.unlock()

    if msgs.isEmpty {
        print(yellow("No MRP messages received in 10s — ATV may need media playing."))
        return
    }

    // Merge all SET_STATE messages into a single now-playing picture.
    var merged = MRPNowPlayingUpdate()
    for msg in msgs {
        guard let np = MRPDecoder.decodeNowPlaying(from: msg) else { continue }
        if let v = np.title    { merged.title    = v }
        if let v = np.artist   { merged.artist   = v }
        if let v = np.album    { merged.album    = v }
        if let v = np.playbackRate { merged.playbackRate = v }
        if let v = np.playbackState { merged.playbackState = v }
        if let v = np.duration     { merged.duration = v }
        if let v = np.elapsedTime  { merged.elapsedTime = v }
        if let v = np.playbackStateTimestamp { merged.playbackStateTimestamp = v }
    }

    let stateName: String
    switch merged.playbackState {
    case 1: stateName = "Playing"
    case 2: stateName = "Paused"
    case 3: stateName = "Stopped"
    default: stateName = "Unknown"
    }

    print(green("✓ Now playing:"))
    if let t = merged.title  { print("       Title: \(t)") }
    if let a = merged.artist { print("      Artist: \(a)") }
    if let a = merged.album  { print("       Album: \(a)") }
    print("       State: \(stateName)")
    if let pos = merged.elapsedTime, let dur = merged.duration, dur > 0 {
        let pct = Int(pos / dur * 100)
        print("    Position: \(Int(pos))/\(Int(dur))s (\(pct)%)")
    }
    print(cyan("Phase 2 gate passed — MRP tunnel works end-to-end."))
}

func cmdPair(_ conn: IPCConnection, device: String) throws {
    // Start pairing — server responds to the original pair-start request
    // only after pairing completes (or fails). PIN is requested via event.
    let stderr = FileHandle.standardError
    print(cyan("Starting pairing with \(device)…"))
    let id = String(UUID().uuidString.prefix(8))
    try conn.send(.request(IPCRequest(id: id, cmd: .pairStart, args: ["device": device])))
    let final = try conn.awaitResponse(id: id) { event in
        switch event.event {
        case .pinRequired:
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
    expectOk(final)
}

// MARK: - Command abbreviation

/// Canonical list of top-level subcommands. Used by `resolveCommand` to expand
/// unique prefixes (e.g. `m` → `menu`, `se` → `select`). Keep in sync with the
/// dispatch switch, standalone dispatch, and usage().
let knownCommands: [String] = [
    "list", "status", "select", "pair",
    "l", "r", "u", "d",
    "sl", "sr", "su", "sd",    // trackpad swipe left/right/up/down
    "click", "pp", "home", "menu",
    "ff", "rew",               // aliases: ff = r (right), rew = l (left)
    "vol+", "vol-",
    "power", "disconnect", "ping", "completion", "apps", "launch",
    "pair-airplay", "airplay-verify", "airplay-tunnel", "airplay-mrp",
    "version", "help",
]

/// Expand an abbreviated command to its canonical form, or return `input`
/// unchanged if nothing matches. Exact matches always win over prefix matches,
/// so `l` still means "left" even though `list` also starts with `l`.
/// Ambiguous prefixes (e.g. `p` — pair/pp/power/ping) die with a helpful list.
func resolveCommand(_ input: String) -> String {
    if knownCommands.contains(input) { return input }
    let matches = knownCommands.filter { $0.hasPrefix(input) }
    switch matches.count {
    case 0:  return input                       // let dispatch produce the usual "unknown command"
    case 1:  return matches[0]
    default: die("ambiguous command '\(input)' — matches: \(matches.joined(separator: ", "))")
    }
}

// MARK: - Standalone dispatch

/// Dispatches a command in --standalone mode — no IPC, no app required.
/// Only supports the subset of commands that make sense without a live session.
func runStandalone(args: [String], device: String?) throws {
    let cmd = resolveCommand(args.first ?? "")
    switch cmd {
    case "list":
        try standaloneList()
    case "l", "rew": try standaloneSendKey(deviceName: device, command: .left)
    case "r", "ff":  try standaloneSendKey(deviceName: device, command: .right)
    case "u":          try standaloneSendKey(deviceName: device, command: .up)
    case "d":          try standaloneSendKey(deviceName: device, command: .down)
    case "sl":         try standaloneSwipe(deviceName: device, direction: .left)
    case "sr":         try standaloneSwipe(deviceName: device, direction: .right)
    case "su":         try standaloneSwipe(deviceName: device, direction: .up)
    case "sd":         try standaloneSwipe(deviceName: device, direction: .down)
    case "click":      try standaloneSendKey(deviceName: device, command: .select)
    case "pp":         try standaloneSendKey(deviceName: device, command: .playPause)
    case "menu":       try standaloneSendKey(deviceName: device, command: .menu)
    case "home":       try standaloneSendKey(deviceName: device, command: .home)
    case "vol+":       try standaloneSendKey(deviceName: device, command: .volumeUp)
    case "vol-":       try standaloneSendKey(deviceName: device, command: .volumeDown)
    case "apps":       try standaloneFetchApps(deviceName: device)
    case "launch":
        guard args.count >= 2 else { die("launch requires a bundle ID") }
        try standaloneLaunchApp(deviceName: device, bundleID: args[1])
    case "status", "select", "pair", "ping", "disconnect", "power":
        die("--standalone does not support '\(cmd)' — run AppleTVRemote.app for that")
    default:
        die("unknown command: \(cmd)")
    }
}

// MARK: - Arg parsing

// Extract and strip flags before subcommand dispatch. We support:
//   --standalone          skip the app+socket entirely; run discovery + one-shot
//                         pair-verify + HID locally in this process
//   --device <name>       select target device for standalone mode (otherwise
//                         the single discovered device; error if multiple)
//   --verbose             mirror all trace/report/fail log output to stderr
var rawArgs = Array(CommandLine.arguments.dropFirst())
var useStandalone = false
var standaloneDevice: String?

do {
    var filtered: [String] = []
    var i = 0
    while i < rawArgs.count {
        let a = rawArgs[i]
        if a == "--standalone" {
            useStandalone = true
        } else if a == "--device" {
            guard i + 1 < rawArgs.count else { die("--device requires a value") }
            standaloneDevice = rawArgs[i + 1]
            i += 1
        } else if a == "--verbose" {
            Log.verbose = true
        } else {
            filtered.append(a)
        }
        i += 1
    }
    rawArgs = filtered
}
let args = rawArgs



func usage() -> Never {
    // Fixed left-column width so descriptions always line up, regardless of
    // whether the command string is short ("pp") or long ("select <name>").
    // Colors are applied after padding so ANSI escape sequences don't inflate
    // the visible column width.
    func row(_ cmd: String, _ desc: String) -> String {
        let width = 34
        // If cmd is longer than our column, don't truncate — break onto the
        // next line with the description indented to match the column.
        if cmd.count >= width {
            let indent = String(repeating: " ", count: width + 2)
            return "  \(yellow(cmd))\n\(indent)\(desc)"
        }
        let padded = cmd.padding(toLength: width, withPad: " ", startingAt: 0)
        return "  \(yellow(padded))\(desc)"
    }

    let header = cyan("atv") + " — control Apple TV from the command line"
    print(header)
    print("")
    print(cyan("Usage:"))
    print(row("list",                    "List discovered Apple TVs"))
    print(row("status",                  "Default device + connection state"))
    print(row("select <name>",           "Set default device (enables auto-connect)"))
    print(row("pair <name>",             "Pair with an Apple TV (prompts for PIN)"))
    print(row("pair-airplay <name>",     "Pair for now-playing info (AirPlay; prompts for PIN)"))
    print(row("airplay-verify <name>",   "Test stored AirPlay credentials"))
    print(row("airplay-mrp <name>",       "Open full MRP tunnel (now-playing gate test)"))
    print(row("l | r | u | d",           "D-pad left / right / up / down"))
    print(row("rew | ff",                "Aliases for l / r (rewind / fast-forward)"))
    print(row("sl | sr | su | sd",       "Trackpad swipe left / right / up / down"))
    print(row("click",                   "Click (D-pad centre)"))
    print(row("pp",                      "Play / Pause"))
    print(row("home [--long]",           "Home button (long-press opens Control Center)"))
    print(row("menu",                    "Menu / Back"))
    print(row("vol+ | vol-",             "Volume up / down"))
    print(row("power",                   "Toggle (wake if asleep, sleep if on)"))
    print(row("text <string>",            "Send text to active text field"))
    print(row("text --clear",             "Clear the active text field"))
    print(row("disconnect",              "Drop the connection"))
    print(row("ping",                    "Round-trip ping to the app"))
    print(row("version",                 "Print atv version (1.0-<build timestamp>)"))
    print(row("completion <bash|zsh>",   "Emit shell completion script to stdout"))
    print("")
    print(cyan("Command chaining") + " (navigation + playback commands):")
    print(dim("  atv r u d          → right, up, down in sequence"))
    print(dim("  atv 3 r            → right × 3"))
    print(dim("  atv 3 r u          → right+up sequence × 3"))
    print("")
    print(cyan("Standalone mode") + " (no app required, single-shot):")
    print(row("--standalone list",                    "Discover over Bonjour directly"))
    print(row("--standalone [--device <n>] <cmd>",    "Send one HID command"))
    print(dim("""
      Supported cmds: list, l, r, u, d, click, pp, menu, home,
                      vol+, vol-, power (always wakes)
      Requires credentials from a previous pair-setup via the app.
      Auto-falls-back to standalone when run over SSH without a GUI session.
    """))
    print("")
    print(cyan("Global flags") + ":")
    print(row("--verbose",                            "Mirror all debug output to stderr"))
    print(row("--standalone",                         "Run without the app (single-shot HID)"))
    print("")
    print(cyan("Install completions:"))
    print(row("zsh",  #"eval "$(atv completion zsh)""#))
    print(row("bash", #"eval "$(atv completion bash)""#))
    print("")
    print(dim("Colors honor NO_COLOR and are auto-disabled on non-TTY stdout."))
    exit(args.isEmpty ? 0 : 2)
}

guard !args.isEmpty else { usage() }

// MARK: - Command chaining
//
// Two supported shapes (both tokenised at this point — flags already stripped):
//   atv r u d u      → four separate key presses, in order
//   atv 5 r          → five rights
//   atv 3 r u        → rightup rightup rightup  (count applies to the sequence)
//
// Only "fire-and-forget" commands chain — device-selecting / long-running ones
// (select, pair, status, list, ping, completion, disconnect, power) still run
// solo. If args don't match a chainable shape, we fall through to the normal
// single-command dispatch path below.

let chainable: Set<String> = [
    "l", "r", "u", "d", "sl", "sr", "su", "sd",
    "click", "pp", "menu", "home", "vol+", "vol-",
    "ff", "rew",
]

/// Expand a chain of args into the final sequence of commands to run, or nil
/// if the input isn't a valid chain. Expects args to have at least 2 tokens
/// (a single token goes through normal dispatch).
func expandChain(_ tokens: [String]) -> [String]? {
    guard tokens.count >= 2 else { return nil }
    // Leading positive integer? Repeat the rest N times.
    var rest = tokens
    var count = 1
    if let n = Int(tokens[0]), n > 0 {
        count = n
        rest = Array(tokens.dropFirst())
        guard !rest.isEmpty else { return nil }
    }
    // Every remaining token must resolve to a chainable command.
    let resolved = rest.map(resolveCommand)
    guard resolved.allSatisfy(chainable.contains) else { return nil }
    return Array(repeating: resolved, count: count).flatMap { $0 }
}

// Expand abbreviations up-front — `atv m` → menu, `atv se foo` → select foo,
// etc. Ambiguous prefixes die here; unknown strings pass through so dispatch
// produces the normal "unknown command" error.
let resolvedCommand = resolveCommand(args[0])
var dispatchArgs = args
dispatchArgs[0] = resolvedCommand

// Detect a chain before picking the dispatch path. We only run chains against
// the IPC path (app / standalone connection), so detection happens here and
// execution lives below once we've decided which connection to use.
let chain = expandChain(args)

do {
    // Help / usage — handle before anything that could auto-launch the app.
    if resolvedCommand == "help" || args[0] == "-h" || args[0] == "--help" {
        usage()
    }

    // version prints "1.0-<build timestamp>" derived from the binary's mtime,
    // so every fresh `swift build` bumps it automatically.
    if resolvedCommand == "version" || args[0] == "-v" || args[0] == "--version" {
        printVersion(); exit(0)
    }

    // completion doesn't touch the socket at all — just dumps the script.
    if resolvedCommand == "completion" {
        guard args.count >= 2 else { die("completion requires a shell: bash | zsh") }
        switch args[1] {
        case "zsh":  print(zshCompletion)
        case "bash": print(bashCompletion)
        default:     die("unknown shell: \(args[1]) (supported: bash, zsh)")
        }
        exit(0)
    }

    // ping doesn't need auto-launch — if the app isn't running, say so.
    if resolvedCommand == "ping" {
        guard let conn = IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 2) else {
            die("AppleTVRemote.app is not running (no socket at \(IPCSocket.path))")
        }
        let r = try conn.request(.ping)
        expectOk(r)
        print(green("pong"))
        exit(0)
    }

    // --standalone: skip the app/socket entirely. Only a subset of commands
    // works without a live app session — see Standalone.swift for the list.
    if useStandalone {
        if let chain {
            for cmd in chain {
                try runStandalone(args: [cmd], device: standaloneDevice)
            }
        } else {
            try runStandalone(args: dispatchArgs, device: standaloneDevice)
        }
        exit(0)
    }

    // Auto-fallback to standalone when the app isn't installed / can't launch
    // (typical over SSH without an Aqua session). Only fall back for commands
    // that actually work standalone — status / select / pair need the app.
    let standaloneCapable: Set<String> = [
        "list", "l", "r", "u", "d", "sl", "sr", "su", "sd",
        "ff", "rew",
        "click", "pp", "menu", "home", "vol+", "vol-",
    ]
    // Either a regular single-command run fits standalone, or every command
    // in the chain does (chains are all keys, so by construction they do).
    let firstIsStandaloneCapable = chain != nil || standaloneCapable.contains(resolvedCommand)
    if isHeadlessSession(), firstIsStandaloneCapable,
       IPCConnection.open(path: IPCSocket.path, timeoutSeconds: 1) == nil {
        fputs(dim("(headless session — falling back to --standalone)\n"), stderr)
        if let chain {
            for cmd in chain {
                try runStandalone(args: [cmd], device: standaloneDevice)
            }
        } else {
            try runStandalone(args: dispatchArgs, device: standaloneDevice)
        }
        exit(0)
    }

    let conn = connectOrLaunch()

    // Run a chain over the one established IPC connection, then exit.
    if let chain {
        for cmd in chain {
            let key: IPCKey? = {
                switch cmd {
                case "l", "rew": return .left
                case "r", "ff":  return .right
                case "u":    return .up
                case "d":    return .down
                case "sl":   return .swipeLeft
                case "sr":   return .swipeRight
                case "su":   return .swipeUp
                case "sd":   return .swipeDown
                case "click":return .select
                case "pp":   return .playPause
                case "menu": return .menu
                case "home": return .home
                case "vol+": return .volumeUp
                case "vol-": return .volumeDown
                default:     return nil
                }
            }()
            guard let k = key else { die("chain: unsupported command \(cmd)") }
            try cmdKey(conn, key: k)
        }
        exit(0)
    }

    switch resolvedCommand {
    case "list":        try cmdList(conn, namesOnly: args.contains("--names"))
    case "status":      try cmdStatus(conn)
    case "select":
        guard args.count >= 2 else { die("select requires a device name") }
        try cmdSelect(conn, device: args[1])
    case "pair":
        guard args.count >= 2 else { die("pair requires a device name") }
        try cmdPair(conn, device: args[1])
    case "pair-airplay":
        guard args.count >= 2 else { die("pair-airplay requires a device name") }
        try cmdPairAirPlay(conn, device: args[1])
    case "airplay-verify":
        guard args.count >= 2 else { die("airplay-verify requires a device name") }
        try cmdAirPlayVerify(conn, device: args[1])
    case "airplay-tunnel":
        guard args.count >= 2 else { die("airplay-tunnel requires a device name") }
        try cmdAirPlayTunnel(conn, device: args[1])
    case "airplay-mrp":
        guard args.count >= 2 else { die("airplay-mrp requires a device name") }
        try cmdAirPlayMRP(conn, device: args[1])
    case "l", "rew":  try cmdKey(conn, key: .left)
    case "r", "ff":   try cmdKey(conn, key: .right)
    case "u":           try cmdKey(conn, key: .up)
    case "d":           try cmdKey(conn, key: .down)
    case "sl":          try cmdKey(conn, key: .swipeLeft)
    case "sr":          try cmdKey(conn, key: .swipeRight)
    case "su":          try cmdKey(conn, key: .swipeUp)
    case "sd":          try cmdKey(conn, key: .swipeDown)
    case "click":  try cmdKey(conn, key: .select)
    case "pp":          try cmdKey(conn, key: .playPause)
    case "menu":        try cmdKey(conn, key: .menu)
    case "home":
        let long = args.contains("--long")
        try cmdKey(conn, key: .home, longPress: long)
    case "vol+":        try cmdKey(conn, key: .volumeUp)
    case "vol-":        try cmdKey(conn, key: .volumeDown)
    case "power":       try cmdPower(conn)
    case "text":
        let isClear = args.contains("--clear")
        if isClear {
            let maxAttempts = 10
            var sent = false
            for attempt in 1...maxAttempts {
                let r = try conn.request(.clearText)
                if r.ok { sent = true; break }
                if r.error == "not connected", attempt < maxAttempts {
                    usleep(200_000)
                    continue
                }
                die(r.error ?? "unknown error")
            }
            if sent { print(green("✓ cleared text")) }
        } else {
            guard args.count >= 2 else { die("text requires a string argument or --clear") }
            let text = args[1...].filter { $0 != "--clear" }.joined(separator: " ")
            guard !text.isEmpty else { die("text requires a non-empty string argument") }
            // Retry through the reconnect window, same pattern as cmdKey.
            let maxAttempts = 10
            var sent = false
            for attempt in 1...maxAttempts {
                let r = try conn.request(.text, args: ["text": text])
                if r.ok { sent = true; break }
                if r.error == "not connected", attempt < maxAttempts {
                    usleep(200_000)
                    continue
                }
                die(r.error ?? "unknown error")
            }
            if sent { print(green("✓ sent text")) }
        }
    case "disconnect":
        let r = try conn.request(.disconnect)
        expectOk(r)
        print(green("✓ disconnected"))
    case "apps":
        try cmdApps(conn)
    case "launch":
        guard args.count >= 2 else { die("launch requires a bundle ID") }
        try cmdLaunch(conn, bundleID: args[1])
    default:
        die("unknown command: \(args[0])")   // show original, not the no-op pass-through
    }
} catch {
    die(error.localizedDescription)
}
