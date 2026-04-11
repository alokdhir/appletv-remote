import Foundation
import Network
import Combine
import Darwin

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
    private var resolvers: [String: ServiceResolver] = [:]

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
                    // Bonjour never signals "done"; stop spinner after 3 s if no results yet.
                    try? await Task.sleep(for: .seconds(3))
                    self?.isSearching = false
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
                self?.isSearching = false   // first callback = initial scan done
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        resolvers.removeAll()
        isSearching = false
    }

    // MARK: - Private

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        // Filter to Apple TVs only — HomePods and Macs also advertise _companion-link._tcp.
        // Companion TXT records use `rpMd` for model (e.g. AppleTV14,1). HomePods use
        // AudioAccessory*, Macs use Mac*. Fall back to allowing the result if metadata is absent
        // (some firmwares omit TXT records in browse results).
        let appletvResults = results.filter { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return false }
            guard case .bonjour(let txt) = result.metadata else {
                print("Discovery: \(name) — no TXT metadata, allowing")
                return true
            }
            let model = txt.dictionary["rpMd"] ?? ""
            print("Discovery: \(name) rpMd='\(model)'")
            return model.isEmpty || model.hasPrefix("AppleTV")
        }

        // Cancel resolvers for services that disappeared
        let currentNames = Set(appletvResults.compactMap { result -> String? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return name
        })
        for name in resolvers.keys where !currentNames.contains(name) {
            resolvers[name] = nil
        }

        for result in appletvResults {
            guard case .service(let name, let type_, let domain, _) = result.endpoint else { continue }

            let id = name
            // Update or insert the device (keeps existing host/port if already resolved)
            if devices.first(where: { $0.id == id }) == nil {
                let device = AppleTVDevice(id: id, name: name, endpoint: result.endpoint)
                devices.append(device)
                devices.sort { $0.name < $1.name }
                resolveService(name: name, type: type_, domain: domain.isEmpty ? "local." : domain)
            }
        }

        // Remove devices that are no longer present
        devices = devices.filter { currentNames.contains($0.id) }
        devices.sort { $0.name < $1.name }
    }

    private func resolveService(name: String, type: String, domain: String) {
        let resolver = ServiceResolver(name: name, type: type, domain: domain)
        resolvers[name] = resolver
        resolver.resolve { [weak self] host, port in
            Task { @MainActor in
                guard let self else { return }
                print("Resolved \(name) → \(host):\(port)")
                if let idx = self.devices.firstIndex(where: { $0.id == name }) {
                    self.devices[idx].host = host
                    self.devices[idx].port = UInt16(port)
                }
            }
        }
    }
}

// MARK: - ServiceResolver

/// Resolves a Bonjour service name to a hostname and port via NetService.
final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var completion: ((String, Int) -> Void)?

    init(name: String, type: String, domain: String) {
        // NetService expects type without trailing dot
        let t = type.hasSuffix(".") ? String(type.dropLast()) : type
        let d = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        service = NetService(domain: d, type: t, name: name)
        super.init()
        service.delegate = self
    }

    func resolve(completion: @escaping (String, Int) -> Void) {
        self.completion = completion
        service.resolve(withTimeout: 10.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        let port = sender.port

        // Prefer IPv4 (AF_INET=2) over IPv6. On BSD/macOS sockaddr layout:
        // byte 0 = sa_len, byte 1 = sa_family
        let sorted = addresses.sorted { a, _ in
            a.withUnsafeBytes { $0.load(fromByteOffset: 1, as: UInt8.self) == 2 }
        }

        for addressData in sorted {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = addressData.withUnsafeBytes { rawPtr -> Bool in
                let sa = rawPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                return getnameinfo(sa, socklen_t(addressData.count),
                                   &hostname, socklen_t(NI_MAXHOST),
                                   nil, 0, NI_NUMERICHOST) == 0
            }
            if ok {
                let nullIdx = hostname.firstIndex(of: 0) ?? hostname.endIndex
                let ip = String(decoding: hostname[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                completion?(ip, port)
                completion = nil
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("ServiceResolver: failed to resolve \(sender.name) — \(errorDict)")
    }
}
