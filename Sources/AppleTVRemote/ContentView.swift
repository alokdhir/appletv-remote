import SwiftUI
import AppleTVProtocol

struct ContentView: View {
    @EnvironmentObject private var discovery:  DeviceDiscovery
    @EnvironmentObject private var connection: CompanionConnection
    @State private var selectedDevice: AppleTVDevice?
    @State private var previousSelectedID: String?
    @AppStorage("com.adhir.appletv-remote.lastDeviceID") private var lastDeviceID = ""
    @AppStorage("com.adhir.appletv-remote.sidebarCollapsed") private var sidebarCollapsed = false

    /// When no device is selected the statusBar (which owns the sidebar toggle)
    /// isn't visible, so we pin the sidebar open — otherwise the user can't
    /// get it back. The collapsed preference is still remembered.
    private var effectivelyCollapsed: Bool {
        sidebarCollapsed && selectedDevice != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if !effectivelyCollapsed {
                DeviceListView(selectedDevice: $selectedDevice)
                    .frame(width: 220)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
                    .transition(.opacity)
            }

            if let device = selectedDevice {
                RemoteControlView(device: device, connection: connection)
                    .frame(minWidth: 300)
            } else {
                placeholderView
                    .frame(minWidth: 300)
            }
        }
        // idealWidth/idealHeight — .windowResizability(.contentSize) uses
        // ideal sizes to pin the initial window size to the content, while
        // keeping the window resizable (min…max range) so edge-hover resize
        // cursors still work. A plain minWidth with no maxWidth would let
        // the HStack expand to full screen width on open.
        .frame(minWidth: effectivelyCollapsed ? 300 : 521,
               idealWidth: effectivelyCollapsed ? 300 : 521,
               maxWidth: .infinity,
               minHeight: 480,
               idealHeight: 620,
               maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: effectivelyCollapsed)
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
        .onChange(of: effectivelyCollapsed) { collapsed in
            guard let window = MenuBarController.shared.mainWindow else { return }
            let currentSize = window.contentView?.frame.size
                           ?? window.contentRect(forFrameRect: window.frame).size
            // Add or remove exactly the sidebar width — don't touch the right pane.
            let sidebarWidth: CGFloat = 220 + 1  // 220 sidebar + 1 divider
            let delta: CGFloat = collapsed ? -(sidebarWidth) : sidebarWidth
            let newWidth = max(300, currentSize.width + delta)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                window.animator().setContentSize(
                    NSSize(width: newWidth, height: currentSize.height)
                )
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
