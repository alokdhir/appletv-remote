import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct AppleTVRemoteApp: App {
    @StateObject private var discovery   = DeviceDiscovery()
    @StateObject private var connection  = CompanionConnection()
    @StateObject private var autoConnect = AutoConnectStore()
    @StateObject private var reconnector = AutoReconnector()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(autoConnect)
                .preferredColorScheme(.dark)
                .background(MainWindowConfigurator())   // hide-on-close, no disconnect
                .onAppear {
                    MenuBarController.shared.setUp(discovery: discovery, connection: connection, autoConnect: autoConnect)
                    reconnector.setUp(connection: connection, discovery: discovery, autoConnect: autoConnect)
                }
                .onChange(of: discovery.devices) { devices in
                    guard connection.state == .disconnected else { return }
                    if let device = devices.first(where: {
                        autoConnect.isEnabled($0.id) && $0.host != nil
                    }) {
                        connection.connect(to: device)
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Hide main window on close (don't disconnect)

/// Intercepts the window close button and hides instead of closing,
/// so the connection stays alive when the user dismisses the main window.
@MainActor
private final class WindowHider: NSObject, NSWindowDelegate {
    static let shared = WindowHider()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// NSView subclass that intercepts window attachment to hide the window before
/// it ever appears on screen (avoiding the startup flash).
private class WindowSetupView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.delegate = WindowHider.shared
        // Store a direct reference so MenuBarController can show it reliably.
        MenuBarController.shared.mainWindow = window
        guard UserDefaults.standard.bool(forKey: "hideWindowAtStartup") else { return }
        // Zero alpha hides the window even if SwiftUI calls makeKeyAndOrderFront
        // before our async orderOut runs.
        window.alphaValue = 0
        DispatchQueue.main.async {
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }
}

/// Background view that attaches window lifecycle hooks at the earliest possible point.
private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowSetupView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Menu bar controller

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem:       NSStatusItem?
    private var popover:          NSPopover?
    private var stateCancellable: AnyCancellable?
    weak var mainWindow:          NSWindow?

    func setUp(discovery: DeviceDiscovery, connection: CompanionConnection, autoConnect: AutoConnectStore) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }

        let img = NSImage(systemSymbolName: "appletv.remote.gen2", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv",      accessibilityDescription: nil)
        img?.isTemplate = true
        button.image = img
        button.imageScaling = .scaleProportionallyDown
        button.action = #selector(toggle(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let vc = NSHostingController(rootView:
            MenuBarRemoteView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(autoConnect)
                .preferredColorScheme(.dark)
        )
        vc.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.delegate = self
        popover = pop

        // Re-key the popover window when state changes while it's visible,
        // so it doesn't look washed-out after a disconnect/reconnect.
        stateCancellable = connection.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.popover?.isShown == true, NSApp.isActive else { return }
                self.popover?.contentViewController?.view.window?.makeKey()
            }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.deactivate()
        }
    }

    @objc private func toggle(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }

        // Right-click → context menu instead of popover.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if pop.isShown {
            // Deactivate before closing so the main window never gets a chance
            // to surface between performClose and the popoverDidClose callback.
            NSApp.deactivate()
            pop.performClose(nil)
        } else {
            // Activate before showing so the popover renders with active (non-washed-out) colours.
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async {
                let popWin = pop.contentViewController?.view.window
                popWin?.makeKey()
                popWin?.makeFirstResponder(nil)
                // Fully hide every non-popover window so macOS has nothing to
                // surface as the next key window when the popover closes.
                NSApp.windows.filter { $0 !== popWin }.forEach { $0.orderOut(nil) }
            }
        }
    }

    // MARK: - Open main window

    func openMainWindow() {
        if let pop = popover, pop.isShown {
            NSApp.deactivate()
            pop.performClose(nil)
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // About
        let about = NSMenuItem(title: "About Apple TV Remote",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        // Show Main Window
        let show = NSMenuItem(title: "Show Main Window",
                              action: #selector(showMainWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())

        // Launch at Startup
        let launch = NSMenuItem(title: "Launch at Startup",
                                action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit Apple TV Remote",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        // Temporarily assign the menu so the status item shows it anchored correctly.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    // Called by NSMenuDelegate when the menu closes so left-click continues to show the popover.
    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in self.statusItem?.menu = nil }
    }

    @objc private func showMainWindow(_ sender: Any?) {
        openMainWindow()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Apple TV Remote",
            .credits: NSAttributedString(
                string: "Control your Apple TV from the menu bar.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ])
    }

    @objc private func toggleLaunchAtStartup(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Launch at startup toggle failed: \(error)")
        }
    }
}

// MARK: - Menu bar remote view

struct MenuBarRemoteView: View {
    @EnvironmentObject var discovery:  DeviceDiscovery
    @EnvironmentObject var connection: CompanionConnection

    var body: some View {
        Group {
            if connection.state == .connected {
                connectedView
            } else {
                disconnectedView
            }
        }
        .frame(width: 220)
    }

    // ── Connected ─────────────────────────────────────────────────────────────

    private var connectedView: some View {
        VStack(spacing: 14) {
            Text(connection.currentDevice?.name ?? "Apple TV")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 148, height: 148)
                VStack(spacing: 2) {
                    RemoteButton(label: "chevron.up",    action: { connection.send(.up) })
                    HStack(spacing: 2) {
                        RemoteButton(label: "chevron.left",  action: { connection.send(.left) })
                        RemoteButton(label: "return",         action: { connection.send(.select) }, size: 48)
                        RemoteButton(label: "chevron.right", action: { connection.send(.right) })
                    }
                    RemoteButton(label: "chevron.down",  action: { connection.send(.down) })
                }
            }

            HStack(spacing: 28) {
                LabeledRemoteButton(sfSymbol: "chevron.backward", label: "Back") {
                    connection.send(.menu)
                }
                LabeledRemoteButton(sfSymbol: "playpause.fill", label: "Play/Pause") {
                    connection.send(.playPause)
                }
                LabeledRemoteButton(sfSymbol: "app.fill", label: "Home") {
                    connection.send(.home)
                }
            }

            HStack(spacing: 20) {
                LabeledRemoteButton(sfSymbol: "speaker.minus.fill", label: "Vol −") {
                    connection.send(.volumeDown)
                }
                LabeledRemoteButton(sfSymbol: "speaker.plus.fill", label: "Vol +") {
                    connection.send(.volumeUp)
                }
            }

            Button("Open Full Remote…") { openMainWindow() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // ── Disconnected ──────────────────────────────────────────────────────────

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Apple TV Connected")
                .font(.subheadline.weight(.medium))
            Button("Open Remote") { openMainWindow() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func openMainWindow() {
        MenuBarController.shared.openMainWindow()
    }
}

// MARK: - Auto-reconnect on connection drop

/// Watches for unexpected disconnects on auto-connect devices and retries up to 3 times.
@MainActor
final class AutoReconnector: ObservableObject {
    private var cancellable: AnyCancellable?
    private var retryTask:   Task<Void, Never>?
    private var retryCount  = 0
    private let maxRetries  = 3
    private let retryDelay: TimeInterval = 5

    func setUp(connection: CompanionConnection,
               discovery: DeviceDiscovery,
               autoConnect: AutoConnectStore) {
        cancellable = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak connection, weak discovery, weak autoConnect] state in
                guard let self, let connection, let discovery, let autoConnect else { return }
                switch state {
                case .disconnected, .error:
                    // Only retry if the device that just dropped has auto-connect on.
                    guard let device = connection.currentDevice,
                          autoConnect.isEnabled(device.id),
                          self.retryCount < self.maxRetries else {
                        self.retryCount = 0
                        return
                    }
                    self.scheduleRetry(device: device, connection: connection, discovery: discovery)
                case .connected:
                    // Successful connection — reset retry counter.
                    self.retryCount = 0
                    self.retryTask?.cancel()
                    self.retryTask = nil
                default:
                    break
                }
            }
    }

    private func scheduleRetry(device: AppleTVDevice,
                               connection: CompanionConnection,
                               discovery: DeviceDiscovery) {
        retryTask?.cancel()
        retryCount += 1
        let attempt = retryCount
        print("AutoReconnector: scheduling retry \(attempt)/\(maxRetries) in \(retryDelay)s for \(device.name)")
        retryTask = Task {
            try? await Task.sleep(for: .seconds(retryDelay))
            guard !Task.isCancelled else { return }
            // Use the freshest resolved device from discovery in case IP changed.
            let target = discovery.devices.first { $0.id == device.id } ?? device
            guard target.host != nil else {
                print("AutoReconnector: device not yet resolved, skipping retry \(attempt)")
                return
            }
            print("AutoReconnector: connecting (attempt \(attempt)/\(maxRetries))")
            connection.connect(to: target)
        }
    }
}
