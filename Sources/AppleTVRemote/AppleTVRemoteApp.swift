import SwiftUI
import AppKit
import Combine
import ServiceManagement
import AppleTVLogging
import AppleTVProtocol

@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var discovery   = DeviceDiscovery()
    @StateObject private var connection  = CompanionConnection()
    @StateObject private var autoConnect = AutoConnectStore()
    @StateObject private var reconnector = AutoReconnector()
    @State       private var ipcServer:  IPCServer?

    var body: some Scene {
        // Register setUp on the delegate here — body evaluates before
        // applicationDidFinishLaunching fires on macOS, so this is guaranteed
        // to be set in time for headless (`open -g`) launches.
        let _ = { appDelegate.onFinishLaunching = setUp }()

        return WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(autoConnect)
                .environmentObject(reconnector)
                .preferredColorScheme(.dark)
                .background(VisualEffectBackground(material: .underWindowBackground,
                                                   blendingMode: .behindWindow))
                .background(MainWindowConfigurator())   // hide-on-close + translucency + no disconnect
                .onAppear {
                    // Fallback for Dock/normal launches where the window appears.
                    setUp()
                }
                .onChange(of: discovery.devices) { devices in
                    guard connection.state == .disconnected else { return }
                    if let device = devices.first(where: {
                        autoConnect.isEnabled($0.id) && $0.host != nil
                    }) {
                        connection.wakeAndConnect(to: device)
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    /// Called by AppDelegate.applicationDidFinishLaunching — fires regardless
    /// of whether a window is visible (handles `open -g` headless launches).
    /// Idempotent: safe to call again from .onAppear.
    private func setUp() {
        appDelegate.onFinishLaunching = nil  // clear after first real call
        MenuBarController.shared.setUp(discovery: discovery, connection: connection, autoConnect: autoConnect)
        reconnector.setUp(connection: connection, discovery: discovery, autoConnect: autoConnect)
        if ipcServer == nil {
            let server = IPCServer(connection: connection,
                                   discovery: discovery,
                                   autoConnect: autoConnect,
                                   reconnector: reconnector)
            server.start()
            ipcServer = server
        }
    }
}

// MARK: - App delegate

/// Keeps the app alive when all windows close. Without this, SwiftUI's default
/// `applicationShouldTerminateAfterLastWindowClosed == true` terminates the
/// process whenever the user closes a secondary window (e.g. the standard
/// About panel) while the main window is hidden — since the menu-bar status
/// item is not a window, AppKit considers the app window-less and quits it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppleTVRemoteApp after SwiftUI initialises its @StateObjects.
    var onFinishLaunching: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        onFinishLaunching?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click while no windows are visible: re-show the main window
    /// (which WindowHider ordered out rather than closed). Returning `false`
    /// tells AppKit we've handled the reopen ourselves so it doesn't try to
    /// un-miniaturize or surface some other window on top.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MenuBarController.shared.openMainWindow()
        }
        return false
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
/// it ever appears on screen (avoiding the startup flash), and to configure
/// translucency so the sibling NSVisualEffectView background shows through.
private class WindowSetupView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.delegate = WindowHider.shared
        // Store a direct reference so MenuBarController can show it reliably.
        MenuBarController.shared.mainWindow = window

        // Translucency — pair with the VisualEffectBackground sibling SwiftUI
        // places behind ContentView. Without these three lines the window's
        // default opaque backing paints over the visual-effect view and you
        // just see a solid dark fill.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true

        // Disable SwiftUI's auto-generated frame autosave. SwiftUI derives
        // the autosave name from the full view-modifier type signature, so
        // any modifier tweak creates a new orphan UserDefaults key and AppKit
        // restores a stale (often screen-sized) frame under the current
        // signature — which defeats .windowResizability(.contentSize).
        // ContentView now has a FIXED .frame(width:), so .contentSize will
        // pin the window to the content width without any restoration race.
        window.setFrameAutosaveName("")

        // Sweep out orphan "NSWindow Frame SwiftUI.ModifiedContent<…>" keys
        // accumulated from previous view-modifier shapes. Scoped strictly to
        // the "NSWindow Frame " prefix so AppStorage-backed state
        // (lastDeviceID, autoConnectDeviceIDs, hideWindowAtStartup, etc.)
        // is never touched.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame ") {
            defaults.removeObject(forKey: key)
        }

        // Explicitly pin the initial content size. .contentMinSize leaves the
        // initial size up to SwiftUI, which — given ContentView's maxWidth:
        // .infinity — yields a screen-wide window. Set it before the window
        // becomes visible so the user never sees the wrong size.
        let collapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
        window.setContentSize(NSSize(width: collapsed ? 300 : 520, height: 620))

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

// MARK: - Visual effect background

/// SwiftUI wrapper around NSVisualEffectView. Placed behind ContentView so the
/// window picks up macOS's native blurred-translucency look (adapts to dark/light
/// mode automatically, blurs whatever's behind the window).
private struct VisualEffectBackground: NSViewRepresentable {
    let material:     NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Menu bar controller

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem:       NSStatusItem?
    private var popover:          NSPopover?
    private var stateCancellable: AnyCancellable?
    weak var mainWindow:          NSWindow?

    /// Set while `openMainWindow()` is transitioning from popover → main window.
    /// Tells `popoverDidClose` to skip its deactivate (which would otherwise
    /// steal focus from the main window we just raised).
    private var suppressPopoverDeactivate = false

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
            if self.suppressPopoverDeactivate {
                self.suppressPopoverDeactivate = false
                return
            }
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
                // Previously we orderOut'd every other window to stop the main
                // window from taking over on popover dismiss, but that hid the
                // main window whenever the user clicked the menu-bar icon —
                // unwanted. Leave other windows alone.
            }
        }
    }

    // MARK: - Open main window

    func openMainWindow() {
        if let pop = popover, pop.isShown {
            // Suppress the deactivate that popoverDidClose would otherwise queue
            // — if it ran after our activate+show below, it would steal focus
            // from the main window we just raised.
            suppressPopoverDeactivate = true
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
            Log.app.fail("Launch at startup toggle failed: \(error)")
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
                        RemoteButton(label: "circle.fill",    action: { connection.send(.select) }, size: 48)
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
                } longPressAction: {
                    connection.sendLongPress(.home)
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
///
/// The retry is debounced: the counter only increments if the connection stays
/// in `.disconnected`/`.error` for the full `retryDelay` window. Transitions
/// into `.waking`/`.connecting`/`.awaitingPairingPin` cancel the pending retry
/// without consuming an attempt — this is what prevents the internal
/// `.waking → .disconnected → .connecting` transition in `wakeAndConnect` from
/// burning through the retry budget on every successful connect.
@MainActor
final class AutoReconnector: ObservableObject {
    /// True while an auto-reconnect cycle is in flight (between EOF and either
    /// a successful `.connected` or exhaustion of the retry budget). Consumed
    /// by `RemoteControlView` so it can keep the remote buttons on screen and
    /// only surface "Reconnecting…" in the status bar instead of flashing back
    /// to the connect prompt.
    @Published var isReconnecting: Bool = false

    private var cancellable: AnyCancellable?
    private var retryTask:   Task<Void, Never>?
    private var retryCount  = 0
    private let maxRetries  = 3
    /// Only start surfacing the "reconnecting" UI after we've been connected
    /// at least once. Otherwise the transient `.disconnected` inside the very
    /// first `wakeAndConnect` call flips `isReconnecting` true and hides the
    /// Connecting spinner / initial error behind the remote layout.
    private var hasEverConnected = false
    // Short debounce — the ATV drops idle Companion sockets at ~30 s, and a
    // pair-verify reconnect only takes ~70 ms. Waiting 5 s here was the main
    // source of the user-visible "blip" on every idle-close cycle.
    private let retryDelay: TimeInterval = 0.25

    func setUp(connection: CompanionConnection,
               discovery: DeviceDiscovery,
               autoConnect: AutoConnectStore) {
        cancellable = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak connection, weak discovery] state in
                guard let self, let connection, let discovery else { return }
                switch state {
                case .connected:
                    // Success — reset counter and cancel any pending retry.
                    self.retryCount = 0
                    self.retryTask?.cancel()
                    self.retryTask = nil
                    self.isReconnecting = false
                    self.hasEverConnected = true
                case .connecting, .waking, .awaitingPairingPin:
                    // Mid-handshake — cancel any pending retry so the transient
                    // `.disconnected` that happened before this doesn't count
                    // against the retry budget.
                    self.retryTask?.cancel()
                    self.retryTask = nil
                case .disconnected, .error:
                    // Retry on any unexpected drop/failure — not just auto-connect
                    // devices. The only case we *don't* retry is a user-initiated
                    // Disconnect (via the button), which sets
                    // userInitiatedDisconnect = true on the connection.
                    guard let device = connection.currentDevice,
                          !connection.userInitiatedDisconnect else {
                        self.retryCount = 0
                        self.retryTask?.cancel()
                        self.retryTask = nil
                        self.isReconnecting = false
                        self.hasEverConnected = false
                        return
                    }
                    // If a retry is already pending, let the debounce finish.
                    if let task = self.retryTask, !task.isCancelled { return }
                    // Only surface the "reconnecting" UI once we've actually
                    // been connected at least once — otherwise the transient
                    // `.disconnected` inside the initial wakeAndConnect would
                    // hide the Connecting spinner / first-attempt error.
                    if self.hasEverConnected { self.isReconnecting = true }
                    self.scheduleRetry(device: device, connection: connection, discovery: discovery)
                }
            }
    }

    private func scheduleRetry(device: AppleTVDevice,
                               connection: CompanionConnection,
                               discovery: DeviceDiscovery) {
        let delay = retryDelay
        retryTask = Task { [weak self, weak connection, weak discovery] in
            // Debounce: sleep first, then re-check. If state flipped out of
            // .disconnected/.error during this window the sink has already
            // cancelled us — the check below short-circuits without touching
            // the counter.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self, let connection, let discovery else { return }
            guard self.retryCount < self.maxRetries else {
                Log.companion.fail("AutoReconnector: max retries reached, giving up")
                self.retryCount = 0
                self.retryTask = nil
                self.isReconnecting = false
                return
            }
            self.retryCount += 1
            let attempt = self.retryCount
            let target = discovery.devices.first { $0.id == device.id } ?? device
            guard target.host != nil else {
                Log.companion.report("AutoReconnector: device not yet resolved, skipping retry \(attempt)")
                self.retryTask = nil
                self.isReconnecting = false
                return
            }
            Log.companion.report("AutoReconnector: connecting (attempt \(attempt)/\(self.maxRetries))")
            connection.wakeAndConnect(to: target)
            self.retryTask = nil
        }
    }
}
