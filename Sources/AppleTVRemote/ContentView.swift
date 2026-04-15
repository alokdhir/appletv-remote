import SwiftUI
import AppleTVProtocol

struct ContentView: View {
    @EnvironmentObject private var discovery:  DeviceDiscovery
    @EnvironmentObject private var connection: CompanionConnection
    @State private var selectedDevice: AppleTVDevice?
    @State private var previousSelectedID: String?
    @AppStorage("lastDeviceID") private var lastDeviceID = ""

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
        }
        .onChange(of: selectedDevice) { newDevice in
            if let id = newDevice?.id { lastDeviceID = id }
            // Only tear down the connection on a genuine user-initiated switch
            // to a different device. The initial restore-from-lastDeviceID path
            // (previousSelectedID == nil) and same-device re-selection must NOT
            // disconnect — that would race against any auto-connect the app
            // just kicked off from AppleTVRemoteApp.onChange(of: discovery.devices).
            let oldID = previousSelectedID
            previousSelectedID = newDevice?.id
            guard let oldID, oldID != newDevice?.id else { return }
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
