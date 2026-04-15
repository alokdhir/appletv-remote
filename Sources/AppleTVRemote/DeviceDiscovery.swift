import Foundation
import Network
import Combine
import Darwin
import AppleTVProtocol

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
        // AudioAccessory*, Macs use Mac*. Only exclude if rpMd is present and is NOT an
        // Apple TV — browse results sometimes omit TXT records entirely for real Apple TVs.
        let appletvResults = results.filter { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return false }
            guard case .bonjour(let txt) = result.metadata else {
                print("Discovery: \(name) — no TXT metadata, allowing")
                return true
            }
            let model = txt.dictionary["rpMd"] ?? ""
            print("Discovery: \(name) rpMd='\(model)'")
            // rpMd present and identifies as Apple TV → allow
            if model.hasPrefix("AppleTV") { return true }
            // rpMd present and identifies as something else → reject
            if !model.isEmpty { return false }
            // rpMd absent — use rpFl flags as tiebreaker.
            // Bit 0x4000 = PIN pairing supported; only Apple TVs have this bit set.
            // Macs: 0x20000, HomePods: 0x627B2/0x62792 — neither sets 0x4000.
            let rpflRaw = txt.dictionary["rpFl"] ?? txt.dictionary["rpfl"] ?? ""
            if !rpflRaw.isEmpty,
               let rpfl = UInt32(rpflRaw.hasPrefix("0x") ? String(rpflRaw.dropFirst(2)) : rpflRaw, radix: 16) {
                let pairable = (rpfl & 0x4000) != 0
                print("Discovery: \(name) rpFl=\(rpflRaw) PIN-pairable=\(pairable)")
                return pairable
            }
            // Neither rpMd nor rpFl present — allow (Apple TVs sometimes omit TXT at browse time)
            return true
        }

        // Cancel resolvers for services that disappeared.
        // Collect stale keys first — mutating `resolvers` while iterating
        // `resolvers.keys` (a live view) is undefined behavior in Swift.
        let currentNames = Set(appletvResults.compactMap { result -> String? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return name
        })
        let staleKeys = resolvers.keys.filter { !currentNames.contains($0) }
        for name in staleKeys { resolvers.removeValue(forKey: name) }

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
        resolver.resolve { [weak self] host, port, txt in
            Task { @MainActor in
                guard let self else { return }
                // Filter at resolve time using rpMd first, then rpFl fallback.
                if let model = txt["rpMd"] {
                    if !model.hasPrefix("AppleTV") {
                        print("Discovery: \(name) resolved rpMd='\(model)' — not an Apple TV, removing")
                        self.devices.removeAll { $0.id == name }
                        self.resolvers[name] = nil
                        return
                    }
                } else {
                    // rpMd absent at resolve time — check rpFl PIN-pairing bit
                    let rpflRaw = txt["rpFl"] ?? txt["rpfl"] ?? ""
                    if !rpflRaw.isEmpty,
                       let rpfl = UInt32(rpflRaw.hasPrefix("0x") ? String(rpflRaw.dropFirst(2)) : rpflRaw, radix: 16),
                       (rpfl & 0x4000) == 0 {
                        print("Discovery: \(name) resolved rpFl=\(rpflRaw) — not PIN-pairable, removing")
                        self.devices.removeAll { $0.id == name }
                        self.resolvers[name] = nil
                        return
                    }
                }
                print("Resolved \(name) → \(host):\(port)")
                if let idx = self.devices.firstIndex(where: { $0.id == name }) {
                    self.devices[idx].host = host
                    self.devices[idx].port = UInt16(port)
                }
                // Cache MAC address from ARP so Wake-on-LAN works when the ATV sleeps.
                // Run off-main so the blocking ARP lookup doesn't stall the UI.
                let deviceID = name
                let resolvedIP = host
                DispatchQueue.global(qos: .utility).async {
                    if let mac = MACStore.lookupFromARP(ip: resolvedIP) {
                        print("Discovery: \(deviceID) ARP MAC=\(mac)")
                        MACStore.save(mac: mac, for: deviceID)
                    }
                }
            }
        }
    }
}

// MARK: - ServiceResolver

/// Resolves a Bonjour service name to a hostname and port via NetService.
final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var completion: ((String, Int, [String: String]) -> Void)?

    init(name: String, type: String, domain: String) {
        // NetService expects type without trailing dot
        let t = type.hasSuffix(".") ? String(type.dropLast()) : type
        let d = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        service = NetService(domain: d, type: t, name: name)
        super.init()
        service.delegate = self
    }

    /// Resolves the service. Completion receives `(host, port, txtFields)` — txtFields contains
    /// all decoded TXT record key/value pairs (empty dict if TXT record is absent).
    func resolve(completion: @escaping (String, Int, [String: String]) -> Void) {
        self.completion = completion
        service.resolve(withTimeout: 10.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        let port = sender.port

        // Read TXT record fields at resolve time (more complete than browse-time metadata).
        var txtFields: [String: String] = [:]
        if let txtData = sender.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: txtData)
            txtFields = txt.compactMapValues { String(data: $0, encoding: .utf8) }
            print("ServiceResolver: \(sender.name) TXT: \(txtFields)")
        } else {
            print("ServiceResolver: \(sender.name) — txtRecordData() nil at resolve time")
        }

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
                completion?(ip, port, txtFields)
                completion = nil
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("ServiceResolver: failed to resolve \(sender.name) — \(errorDict)")
    }
}
