import Foundation
import Network
import Combine

/// Discovers Apple TV devices on the local network via Bonjour.
///
/// Apple TVs advertise two relevant services:
///   _mediaremotetv._tcp  — Media Remote Protocol (MRP), used for playback control
///   _airplay._tcp        — AirPlay, used for media casting
///
/// We browse for `_mediaremotetv._tcp` to find controllable Apple TVs.
@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published var devices: [AppleTVDevice] = []
    @Published var isSearching = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    // Bonjour service type for the Apple TV Media Remote Protocol
    private let serviceType = "_mediaremotetv._tcp"

    func startDiscovery() {
        guard browser == nil else { return }
        isSearching = true
        devices.removeAll()

        let params = NWParameters()
        params.includePeerToPeer = false

        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    self?.isSearching = false
                    print("Browser failed: \(error)")
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    // MARK: - Private

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var updated: [AppleTVDevice] = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // Use the service name as a stable ID (Apple TV names are typically unique per device)
            let id = name
            var device = AppleTVDevice(id: id, name: name, endpoint: result.endpoint)

            // Carry over pairing status from existing entry
            if let existing = devices.first(where: { $0.id == id }) {
                device.isPaired = existing.isPaired
            }

            // Extract host/port from metadata if available
            if case .bonjour(let record) = result.metadata {
                device.host = extractHost(from: record)
            }

            updated.append(device)
        }

        devices = updated.sorted { $0.name < $1.name }
    }

    private func extractHost(from record: NWTXTRecord) -> String? {
        // TXT records for _mediaremotetv._tcp may include a "Name" key
        guard let data = record.dictionary["Name"] else { return nil }
        return String(data)
    }
}
