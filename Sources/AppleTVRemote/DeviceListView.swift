import SwiftUI
import AppleTVProtocol

// MARK: - Auto-connect store

final class AutoConnectStore: ObservableObject {
    private let key = "autoConnectDeviceIDs"

    @Published private(set) var deviceIDs: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "autoConnectDeviceIDs") ?? []
        deviceIDs = Set(saved)
    }

    func isEnabled(_ id: String) -> Bool { deviceIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { deviceIDs.insert(id) } else { deviceIDs.remove(id) }
        UserDefaults.standard.set(Array(deviceIDs), forKey: key)
    }
}

// MARK: - Device list

struct DeviceListView: View {
    @EnvironmentObject private var discovery: DeviceDiscovery
    @EnvironmentObject private var autoConnect: AutoConnectStore
    @Binding var selectedDevice: AppleTVDevice?
    @AppStorage("hideWindowAtStartup") private var hideWindowAtStartup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if discovery.devices.isEmpty {
                emptyState
            } else {
                List(discovery.devices, selection: $selectedDevice) { device in
                    DeviceRow(
                        device: device,
                        autoConnect: Binding(
                            get: { autoConnect.isEnabled(device.id) },
                            set: { autoConnect.setEnabled(device.id, $0) }
                        )
                    )
                    .tag(device)
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack {
                Text("Hide window at startup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $hideWindowAtStartup)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack {
            Text("Apple TVs")
                .font(.headline)
            Spacer()
            if discovery.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
            Button {
                discovery.stopDiscovery()
                discovery.startDiscovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Searching…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Make sure your Apple TV is on\nthe same Wi-Fi network.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct DeviceRow: View {
    let device: AppleTVDevice
    @Binding var autoConnect: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                if device.isPaired {
                    Text("Paired")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Auto-connect", isOn: $autoConnect)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.7)
                .help("Connect to this Apple TV at startup")
        }
        .padding(.vertical, 2)
    }
}
