import Foundation

// Wire protocol between the AppleTVRemote app (server) and the `atv` CLI
// (client). Framed as newline-delimited JSON over a Unix domain socket at
// ~/Library/Application Support/AppleTVRemote/atv.sock
//
// Three message shapes:
//   Request:   {"id":"1","cmd":"key","args":{"key":"play-pause"}}
//   Response:  {"id":"1","ok":true}                      (or ok:false + error)
//   Event:     {"id":"e1","event":"pin-required"}         (async, server→client)
//
// All three ride on the same channel and are distinguished by top-level keys:
//   - "cmd"   ⇒ client-bound Request
//   - "event" ⇒ server-bound Event
//   - "ok"    ⇒ server-bound Response

// MARK: - Socket path

public enum IPCSocket {
    /// Absolute path to the atv IPC socket under the user's Application Support.
    public static var path: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/AppleTVRemote/atv.sock"
    }

    /// Parent directory for the socket. Caller is responsible for creating
    /// it with the appropriate mode before binding.
    public static var directory: String {
        (path as NSString).deletingLastPathComponent
    }
}

// MARK: - Commands

public enum IPCCommand: String, Codable, Sendable, CaseIterable {
    case ping
    case list
    case pairStart    = "pair-start"
    case pairPin      = "pair-pin"
    case select
    case status
    case key
    case longPress    = "long-press"
    case power
    case disconnect
    case text
    case clearText    = "clear-text"
    case apps
    case launch
}

/// Button names carried as `args.key`. String-backed so the wire format is
/// human-readable.
public enum IPCKey: String, Codable, Sendable, CaseIterable {
    case up, down, left, right
    case select
    case menu, home
    case playPause = "play-pause"
    case volumeUp  = "vol-up"
    case volumeDown = "vol-down"
    // Trackpad swipe gestures — implemented as touch events, not HID buttons.
    case swipeUp    = "swipe-up"
    case swipeDown  = "swipe-down"
    case swipeLeft  = "swipe-left"
    case swipeRight = "swipe-right"

    /// True if this key is a touch-based swipe gesture rather than a HID button.
    public var isSwipe: Bool {
        switch self {
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: return true
        default: return false
        }
    }
}

// MARK: - Request

public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let cmd: IPCCommand
    public let args: [String: String]?
    public let verbose: Bool?

    public init(id: String, cmd: IPCCommand, args: [String: String]? = nil, verbose: Bool? = nil) {
        self.id = id
        self.cmd = cmd
        self.args = args
        self.verbose = verbose
    }
}

// MARK: - Response

public struct IPCDevice: Codable, Sendable {
    public let id: String
    public let name: String
    public let host: String?
    public let paired: Bool
    public let autoConnect: Bool
    public let isDefault: Bool
    public let resolved: Bool

    public init(id: String, name: String, host: String?, paired: Bool,
                autoConnect: Bool, isDefault: Bool, resolved: Bool) {
        self.id = id
        self.name = name
        self.host = host
        self.paired = paired
        self.autoConnect = autoConnect
        self.isDefault = isDefault
        self.resolved = resolved
    }
}

public struct IPCNowPlaying: Codable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let app: String?
    public let elapsedTime: Double?
    public let duration: Double?
    public let playbackRate: Double?

    public init(title: String?, artist: String?, album: String?, app: String?,
                elapsedTime: Double?, duration: Double?, playbackRate: Double?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.app = app
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.playbackRate = playbackRate
    }
}

public struct IPCStatus: Codable, Sendable {
    public let deviceID: String?
    public let deviceName: String?
    public let host: String?
    public let connectionState: String     // matches ConnectionState.displayText
    public let isReconnecting: Bool
    public let nowPlaying: IPCNowPlaying?
    /// Companion FetchAttentionState result. 1 = idle/screensaver, 2 = app focused.
    /// Nil until the first keepalive fires (25 s after connect).
    public let attentionState: Int?
    /// True when the ATV has an active text field waiting for keyboard input.
    public let keyboardActive: Bool

    public init(deviceID: String?, deviceName: String?, host: String?,
                connectionState: String, isReconnecting: Bool,
                nowPlaying: IPCNowPlaying? = nil,
                attentionState: Int? = nil,
                keyboardActive: Bool = false) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.host = host
        self.connectionState = connectionState
        self.isReconnecting = isReconnecting
        self.nowPlaying = nowPlaying
        self.attentionState = attentionState
        self.keyboardActive = keyboardActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID        = try c.decodeIfPresent(String.self,        forKey: .deviceID)
        deviceName      = try c.decodeIfPresent(String.self,        forKey: .deviceName)
        host            = try c.decodeIfPresent(String.self,        forKey: .host)
        connectionState = try c.decode(String.self,                 forKey: .connectionState)
        isReconnecting  = try c.decode(Bool.self,                   forKey: .isReconnecting)
        nowPlaying      = try c.decodeIfPresent(IPCNowPlaying.self, forKey: .nowPlaying)
        attentionState  = try c.decodeIfPresent(Int.self,           forKey: .attentionState)
        keyboardActive  = try c.decodeIfPresent(Bool.self,          forKey: .keyboardActive) ?? false
    }
}

public struct IPCApp: Codable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id; self.name = name
    }
}

public struct IPCResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let error: String?
    public let devices: [IPCDevice]?
    public let status: IPCStatus?
    public let apps: [IPCApp]?

    public init(id: String, ok: Bool, error: String? = nil,
                devices: [IPCDevice]? = nil, status: IPCStatus? = nil,
                apps: [IPCApp]? = nil) {
        self.id = id
        self.ok = ok
        self.error = error
        self.devices = devices
        self.status = status
        self.apps = apps
    }

    public static func ok(_ id: String) -> IPCResponse {
        IPCResponse(id: id, ok: true)
    }
    public static func failure(_ id: String, _ message: String) -> IPCResponse {
        IPCResponse(id: id, ok: false, error: message)
    }
}

// MARK: - Event

public enum IPCEventKind: String, Codable, Sendable {
    case pinRequired   = "pin-required"
    case paired
    case connected
    case disconnected
    case error
    case log
}

public struct IPCEvent: Codable, Sendable {
    public let id: String
    public let event: IPCEventKind
    public let message: String?

    public init(id: String = UUID().uuidString, event: IPCEventKind, message: String? = nil) {
        self.id = id
        self.event = event
        self.message = message
    }
}

// MARK: - Line-framed codec

/// Decodes any message flowing over the socket. Callers distinguish by which
/// field is populated — `cmd`, `event`, or `ok` — exactly matching the spec in
/// the header comment.
public enum IPCFrame: Sendable {
    case request(IPCRequest)
    case response(IPCResponse)
    case event(IPCEvent)

    public static func decode(_ line: Data) throws -> IPCFrame {
        let decoder = JSONDecoder()
        // Probe which shape this is with a minimal discriminator.
        struct Probe: Decodable {
            let cmd:   String?
            let event: String?
            let ok:    Bool?
        }
        let probe = try decoder.decode(Probe.self, from: line)
        if probe.cmd != nil   { return .request(try decoder.decode(IPCRequest.self, from: line)) }
        if probe.event != nil { return .event(try decoder.decode(IPCEvent.self,   from: line)) }
        if probe.ok != nil    { return .response(try decoder.decode(IPCResponse.self, from: line)) }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Unrecognised IPC frame")
        )
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []     // compact, single line
        switch self {
        case .request(let r):  return try encoder.encode(r)
        case .response(let r): return try encoder.encode(r)
        case .event(let e):    return try encoder.encode(e)
        }
    }
}
