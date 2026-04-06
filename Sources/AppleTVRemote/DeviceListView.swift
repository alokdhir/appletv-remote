import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject private var discovery: DeviceDiscovery
    @Binding var selectedDevice: AppleTVDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if discovery.devices.isEmpty {
                emptyState
            } else {
                List(discovery.devices, selection: $selectedDevice) { device in
                    DeviceRow(device: device)
                        .tag(device)
                }
                .listStyle(.sidebar)
            }
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
        }
        .padding(.vertical, 2)
    }
}
