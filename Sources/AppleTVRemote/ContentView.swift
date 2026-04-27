import SwiftUI
import AppleTVProtocol

/// Layout constants shared between the body's `.frame(width: ...)` calls and
/// the window-resize math in the sidebar-toggle handler. Keeping these in one
/// place prevents the two from drifting (e.g. the previous 221 magic number
/// was 220 sidebar + 1 divider point — if either side changed without the
/// other, every toggle would push the window by the difference).
enum SidebarLayout {
    /// Width of the device list column.
    static let listWidth: CGFloat = 220
    /// Width of the SwiftUI Divider between sidebar and content.
    static let dividerWidth: CGFloat = 1
    /// Total horizontal space the sidebar consumes (list + divider).
    static var totalWidth: CGFloat { listWidth + dividerWidth }
    /// Minimum content-area width (the right pane's minWidth).
    static let contentMinWidth: CGFloat = 300
    /// Window's ideal width with sidebar visible.
    static var expandedIdealWidth: CGFloat { contentMinWidth + totalWidth }
}

struct ContentView: View {
    @EnvironmentObject private var discovery:  DeviceDiscovery
    @EnvironmentObject private var connection: CompanionConnection
    @State private var selectedDevice: AppleTVDevice?
    @State private var previousSelectedID: String?
    @AppStorage("com.adhir.appletv-remote.lastDeviceID") private var lastDeviceID = ""
    @AppStorage("com.adhir.appletv-remote.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var animateSidebar = false
    @State private var deviceRestored = false
    @State private var isKeyWindow = true

    /// When no device is selected the statusBar (which owns the sidebar toggle)
    /// isn't visible, so we pin the sidebar open — otherwise the user can't
    /// get it back. The collapsed preference is still remembered.
    /// Before device selection is restored, use sidebarCollapsed directly so
    /// we start in the right visual state without a startup animation.
    private var effectivelyCollapsed: Bool {
        if !deviceRestored { return sidebarCollapsed }
        return sidebarCollapsed && selectedDevice != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if !effectivelyCollapsed {
                DeviceListView(selectedDevice: $selectedDevice)
                    .frame(width: SidebarLayout.listWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
                    .transition(.opacity)
            }

            if let device = selectedDevice {
                RemoteControlView(device: device, connection: connection)
                    .frame(minWidth: SidebarLayout.contentMinWidth)
            } else {
                placeholderView
                    .frame(minWidth: SidebarLayout.contentMinWidth)
            }
        }
        // idealWidth/idealHeight — .windowResizability(.contentSize) uses
        // ideal sizes to pin the initial window size to the content, while
        // keeping the window resizable (min…max range) so edge-hover resize
        // cursors still work. A plain minWidth with no maxWidth would let
        // the HStack expand to full screen width on open.
        .frame(minWidth: effectivelyCollapsed ? SidebarLayout.contentMinWidth
                                              : SidebarLayout.expandedIdealWidth,
               idealWidth: effectivelyCollapsed ? SidebarLayout.contentMinWidth
                                                : SidebarLayout.expandedIdealWidth,
               maxWidth: .infinity,
               minHeight: 480,
               idealHeight: 620,
               maxHeight: .infinity)
        .opacity(isKeyWindow ? 1.0 : 0.50)
        .animation(.easeInOut(duration: 0.2), value: isKeyWindow)
        .animation(animateSidebar ? .easeInOut(duration: 0.22) : nil, value: effectivelyCollapsed)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isKeyWindow = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isKeyWindow = false
        }
        .onAppear {
            discovery.startDiscovery()
            // After the launch-settle window, switch to the live
            // effectivelyCollapsed logic (which pins sidebar open when no
            // device is selected) — the delay lets device restore complete
            // without a startup animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + LaunchSettle.delay) {
                deviceRestored = true
                animateSidebar = true
            }
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
            let currentFrame = window.frame
            // Anchor the right edge: snapshot it before the resize so any
            // discrepancy between SidebarLayout.totalWidth and the actual
            // rendered sidebar width can't drift the window over repeated
            // toggles. The width changes by ±totalWidth; x is computed
            // from the snapshotted right edge.
            let rightEdge = currentFrame.maxX
            let delta = collapsed ? -SidebarLayout.totalWidth : SidebarLayout.totalWidth
            let targetWidth = max(SidebarLayout.contentMinWidth,
                                  currentFrame.width + delta)
            let newFrame = NSRect(
                x: rightEdge - targetWidth,
                y: currentFrame.origin.y,
                width: targetWidth,
                height: currentFrame.height
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(newFrame, display: true)
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
