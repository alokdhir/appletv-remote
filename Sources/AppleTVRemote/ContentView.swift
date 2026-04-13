import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var discovery:  DeviceDiscovery
    @EnvironmentObject private var connection: CompanionConnection
    @State private var selectedDevice: AppleTVDevice?
    @AppStorage("lastDeviceID") private var lastDeviceID = ""
    @AppStorage("hideWindowAtStartup") private var hideWindowAtStartup = false

    var body: some View {
        HStack(spacing: 0) {
            DeviceListView(selectedDevice: $selectedDevice)
                .frame(width: 220)

            Divider()

            if let device = selectedDevice {
                RemoteControlView(device: device, connection: connection)
                    .frame(minWidth: 300)
            } else {
                placeholderView
                    .frame(minWidth: 300)
            }
        }
        .frame(minHeight: 480)
        .onAppear {
            discovery.startDiscovery()
            if hideWindowAtStartup {
                DispatchQueue.main.async {
                    NSApp.windows.first { $0.canBecomeMain }?.orderOut(nil)
                }
            }
        }
        .onDisappear {
            discovery.stopDiscovery()
            connection.disconnect()
        }
        .onChange(of: selectedDevice) { newDevice in
            if let id = newDevice?.id { lastDeviceID = id }
            connection.disconnect()
        }
        .onChange(of: discovery.devices) { devices in
            if selectedDevice == nil, !lastDeviceID.isEmpty {
                selectedDevice = devices.first { $0.id == lastDeviceID }
            }
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select an Apple TV")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
