import Foundation
import Network

/// Represents an Apple TV discovered on the local network.
struct AppleTVDevice: Identifiable, Hashable {
    let id: String          // unique identifier (e.g. model ID from TXT record)
    let name: String
    let endpoint: NWEndpoint

    // Populated after resolving the Bonjour service
    var host: String?
    var port: UInt16?

    // Populated after successful connection / pairing
    var isPaired: Bool = false

    static func == (lhs: AppleTVDevice, rhs: AppleTVDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Possible states of the connection to an Apple TV.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case awaitingPairingPin
    case connected
    case error(String)

    var displayText: String {
        switch self {
        case .disconnected:      return "Disconnected"
        case .connecting:        return "Connecting…"
        case .awaitingPairingPin: return "Enter PIN shown on Apple TV"
        case .connected:         return "Connected"
        case .error(let msg):    return "Error: \(msg)"
        }
    }
}

/// Commands that can be sent to an Apple TV.
enum RemoteCommand {
    case up, down, left, right
    case select
    case menu
    case home
    case playPause
    case volumeUp, volumeDown

    /// Companion protocol HID keycode for this command.
    var hidKeycode: UInt8 {
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
        case .playPause:   return 14
        }
    }
}
