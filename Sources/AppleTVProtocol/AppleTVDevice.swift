import Foundation
import Network

/// Represents an Apple TV discovered on the local network.
public struct AppleTVDevice: Identifiable, Hashable, @unchecked Sendable {
    public let id: String          // unique identifier (e.g. model ID from TXT record)
    public let name: String
    public let endpoint: NWEndpoint

    // Populated after resolving the Bonjour service
    public var host: String?
    public var port: UInt16?

    // Populated after successful connection / pairing
    public var isPaired: Bool = false

    public init(id: String,
                name: String,
                endpoint: NWEndpoint,
                host: String? = nil,
                port: UInt16? = nil,
                isPaired: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.host = host
        self.port = port
        self.isPaired = isPaired
    }

    public static func == (lhs: AppleTVDevice, rhs: AppleTVDevice) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Possible states of the connection to an Apple TV.
public enum ConnectionState: Equatable {
    case disconnected
    case waking           // WoL packet sent, waiting for Apple TV to boot
    case connecting
    case awaitingPairingPin
    case connected
    case error(String)

    public var displayText: String {
        switch self {
        case .disconnected:       return "Disconnected"
        case .waking:             return "Waking up Apple TV…"
        case .connecting:         return "Connecting…"
        case .awaitingPairingPin: return "Enter PIN shown on Apple TV"
        case .connected:          return "Connected"
        case .error(let msg):     return "Error: \(msg)"
        }
    }
}

/// Commands that can be sent to an Apple TV.
public enum RemoteCommand {
    case up, down, left, right
    case select
    case menu
    case home
    case playPause
    case volumeUp, volumeDown
    case siri
    case wake   // power on — also triggers HDMI-CEC TV power-on
    case sleep  // power off

    /// Companion protocol HID keycode for this command.
    public var hidKeycode: UInt8 {
        switch self {
        case .up:          return 1
        case .down:        return 2
        case .left:        return 3
        case .right:       return 4
        case .menu:        return 5
        case .select:      return 6
        case .home:        return 7
        case .volumeUp:    return 8
        case .volumeDown:  return 9
        case .siri:        return 10
        case .sleep:       return 12
        case .wake:        return 13
        case .playPause:   return 14
        }
    }

    /// True if this command should be sent as a single "button up" event only,
    /// rather than a down+up pair.  The Companion protocol requires Wake/Sleep
    /// to be sent as a release event to trigger the power/CEC action.
    public var sendReleaseOnly: Bool {
        switch self {
        case .wake, .sleep: return true
        default:            return false
        }
    }
}

/// Trackpad swipe direction for `CompanionConnection.sendSwipe(_:)`.
/// Coordinates are in the 1000×1000 space declared by `_touchStart`.
public enum SwipeDirection: CaseIterable, Sendable {
    case up, down, left, right

    /// (start, end) touch coordinates for this swipe direction.
    public var coordinates: (start: (x: Double, y: Double), end: (x: Double, y: Double)) {
        switch self {
        case .up:    return (start: (500, 1000), end: (500, 0))
        case .down:  return (start: (500, 0), end: (500, 1000))
        case .left:  return (start: (1000, 500), end: (0, 500))
        case .right: return (start: (0, 500), end: (1000, 500))
        }
    }

    /// Linearly interpolated (x, y) coordinates across `steps` evenly-spaced
    /// points from start to end. Used by both CompanionConnection and
    /// StandaloneSession to generate the hold/move phase of a swipe gesture.
    public func interpolatedSteps(steps: Int = 8) -> [(x: Double, y: Double)] {
        let (start, end) = coordinates
        return (1...steps).map { i in
            let f = Double(i) / Double(steps)
            return (x: start.x + (end.x - start.x) * f,
                    y: start.y + (end.y - start.y) * f)
        }
    }
}

// MARK: - Device collection helpers

extension Array where Element == AppleTVDevice {
    /// Finds a device by exact ID match first, then by case-insensitive name prefix.
    public func resolving(_ nameOrID: String) -> AppleTVDevice? {
        if let byID = first(where: { $0.id == nameOrID }) { return byID }
        let lower = nameOrID.lowercased()
        return first { $0.name.lowercased().hasPrefix(lower) }
    }
}

// MARK: - Companion-link TXT record filtering

/// Returns true if the Bonjour TXT record fields indicate an Apple TV.
///
/// Filters based on:
/// - `rpMd` model string (e.g. "AppleTV14,1") — present on most Apple TVs
/// - `rpFl` bit 0x4000 — "PIN pairing supported", set only on Apple TVs
///   (Macs: 0x20000, HomePods: 0x627B2/0x62792)
/// - If neither field is present, returns true (Apple TVs sometimes omit TXT at browse time)
public func companionTXTIsAppleTV(_ dict: [String: String]) -> Bool {
    let model = dict["rpMd"] ?? ""
    if model.hasPrefix("AppleTV") { return true }
    if !model.isEmpty { return false }
    let rpflRaw = dict["rpFl"] ?? dict["rpfl"] ?? ""
    if !rpflRaw.isEmpty,
       let rpfl = UInt32(rpflRaw.hasPrefix("0x") ? String(rpflRaw.dropFirst(2)) : rpflRaw, radix: 16) {
        return (rpfl & 0x4000) != 0
    }
    return true
}
