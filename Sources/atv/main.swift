import Foundation
import Darwin
import AppleTVIPC
import AppleTVProtocol

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

// MARK: - Shell completion scripts

let zshCompletion = #"""
#compdef atv
# zsh completion for atv — install via: eval "$(atv completion zsh)"
# or save to a file in $fpath (e.g. ~/.zsh/completions/_atv).

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
"""#

let bashCompletion = #"""
# bash completion for atv — install via: eval "$(atv completion bash)"
# or save to /usr/local/etc/bash_completion.d/atv (or /etc/bash_completion.d/).

_atv() {
    local cur prev words cword
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    cword=$COMP_CWORD
    local subcmds="list status select pair l r u d click pp home menu vol+ vol- power disconnect ping completion"

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
    let r = try conn.request(.status)
    expectOk(r)
    guard let s = r.status else { die("server returned no status") }
    let name = s.deviceName ?? dim("(no device)")
    let host = s.host.map { dim(" · \($0)") } ?? ""
    let state = colorForState(s.connectionState)
    print("\(name)\(host)  \(state)")
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
            print("  \(glyph) \(bits.joined(separator: " — "))")
        } else if let label {
            // No track metadata but we do know the transport state — still
            // worth surfacing so `atv status` tells you whether ATV is paused.
            print("  \(glyph) \(dim(label))")
        }
        if let app = np.app, !app.isEmpty {
            print("  \(dim("app: "))\(app)")
        }
        if let elapsed = np.elapsedTime {
            let total = np.duration.map { "/\(fmtTime($0))" } ?? ""
            let rateSuffix = label.map { " (\($0))" } ?? ""
            print("  \(dim("time:")) \(fmtTime(elapsed))\(total)\(rateSuffix)")
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

// MARK: - Command abbreviation

/// Canonical list of top-level subcommands. Used by `resolveCommand` to expand
/// unique prefixes (e.g. `m` → `menu`, `se` → `select`). Keep in sync with the
/// dispatch switch, standalone dispatch, and usage().
let knownCommands: [String] = [
    "list", "status", "select", "pair",
    "l", "r", "u", "d",
    "click", "pp", "home", "menu",
    "vol+", "vol-",
    "power", "disconnect", "ping", "completion",
    "help",
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
    case "l":          try standaloneSendKey(deviceName: device, command: .left)
    case "r":          try standaloneSendKey(deviceName: device, command: .right)
    case "u":          try standaloneSendKey(deviceName: device, command: .up)
    case "d":          try standaloneSendKey(deviceName: device, command: .down)
    case "click":      try standaloneSendKey(deviceName: device, command: .select)
    case "pp":         try standaloneSendKey(deviceName: device, command: .playPause)
    case "menu":       try standaloneSendKey(deviceName: device, command: .menu)
    case "home":       try standaloneSendKey(deviceName: device, command: .home)
    case "vol+":       try standaloneSendKey(deviceName: device, command: .volumeUp)
    case "vol-":       try standaloneSendKey(deviceName: device, command: .volumeDown)
    case "power":
        // Without a live session we don't know the ATV's power state, so
        // "power" always sends wake. (The app-backed path can toggle.)
        try standaloneSendKey(deviceName: device, command: .wake)
    case "status", "select", "pair", "ping", "disconnect":
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
    print(row("l | r | u | d",           "D-pad left / right / up / down"))
    print(row("click",                   "Click (D-pad centre)"))
    print(row("pp",                      "Play / Pause"))
    print(row("home [--long]",           "Home button (long-press opens Control Center)"))
    print(row("menu",                    "Menu / Back"))
    print(row("vol+ | vol-",             "Volume up / down"))
    print(row("power",                   "Toggle (wake if asleep, sleep if on)"))
    print(row("disconnect",              "Drop the connection"))
    print(row("ping",                    "Round-trip ping to the app"))
    print(row("completion <bash|zsh>",   "Emit shell completion script to stdout"))
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
    "l", "r", "u", "d", "click", "pp", "menu", "home", "vol+", "vol-",
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
        "list", "l", "r", "u", "d", "click", "pp", "menu", "home",
        "vol+", "vol-", "power",
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
                case "l":    return .left
                case "r":    return .right
                case "u":    return .up
                case "d":    return .down
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
    case "l":           try cmdKey(conn, key: .left)
    case "r":           try cmdKey(conn, key: .right)
    case "u":           try cmdKey(conn, key: .up)
    case "d":           try cmdKey(conn, key: .down)
    case "click":  try cmdKey(conn, key: .select)
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
    default:
        die("unknown command: \(args[0])")   // show original, not the no-op pass-through
    }
} catch {
    die(error.localizedDescription)
}
