import Foundation
import Network
import Combine

/// Discovers Apple TV devices on the local network via Bonjour.
///
/// Modern Apple TVs (tvOS 15+) advertise `_companion-link._tcp` — the Companion
/// protocol used by the Apple Remote app. Older tvOS 14 and earlier used
/// `_mediaremotetv._tcp` (MRP), but that service is no longer advertised on
/// current firmware.
@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published var devices: [AppleTVDevice] = []
    @Published var isSearching = false
    @Published var browserError: String?

    private var browser: NWBrowser?

    // Bonjour service type for the Apple TV Companion protocol (tvOS 15+)
    private let serviceType = "_companion-link._tcp"

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
                    self?.browserError = nil
                case .failed(let error):
                    self?.isSearching = false
                    self?.browserError = error.localizedDescription
                    print("Bonjour browser failed: \(error)")
                case .cancelled:
                    self?.isSearching = false
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
