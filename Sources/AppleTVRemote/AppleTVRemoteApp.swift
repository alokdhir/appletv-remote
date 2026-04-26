import SwiftUI
import AppKit
import Combine
import AppleTVProtocol

@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var discovery   = DeviceDiscovery()
    @StateObject private var connection  = CompanionConnection()
    @StateObject private var autoConnect = AutoConnectStore()
    @StateObject private var reconnector = AutoReconnector()
    @State       private var ipcServer:  IPCServer?
    @State       private var autoConnectObserver: AnyCancellable?
    @State       private var appListObserver: AnyCancellable?
    @State       private var iconRefreshTimer: Timer?

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
        appDelegate.connection = connection
        discovery.startDiscovery()
        MenuBarController.shared.setUp(discovery: discovery, connection: connection, autoConnect: autoConnect, reconnector: reconnector)
        reconnector.setUp(connection: connection, discovery: discovery, autoConnect: autoConnect)
        if ipcServer == nil {
            let server = IPCServer(connection: connection,
                                   discovery: discovery,
                                   autoConnect: autoConnect,
                                   reconnector: reconnector)
            server.start()
            ipcServer = server
        }
        if autoConnectObserver == nil {
            autoConnectObserver = discovery.$devices
                .receive(on: DispatchQueue.main)
                .sink { [connection, autoConnect] devices in
                    guard connection.state == .disconnected else { return }
                    if let device = devices.first(where: {
                        autoConnect.isEnabled($0.id) && $0.host != nil
                    }) {
                        connection.wakeAndConnect(to: device)
                    }
                }
        }
        if appListObserver == nil {
            appListObserver = connection.$appList
                .receive(on: DispatchQueue.main)
                .sink { apps in
                    guard !apps.isEmpty else { return }
                    let ids = apps.map { $0.id }
                    AppIconCache.shared.refresh(bundleIDs: ids)
                }
        }
        if iconRefreshTimer == nil {
            iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak connection] _ in
                guard let ids = connection?.appList.map({ $0.id }), !ids.isEmpty else { return }
                AppIconCache.shared.refreshIfStale(bundleIDs: ids)
            }
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
        onFinishLaunching?();
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click while no windows are visible: re-show the main window
    /// (which WindowHider ordered out rather than closed). Returning `false`
    /// tells AppKit we've handled the reopen ourselves so it doesn't try to
    /// un-miniaturize or surface some other window on top.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MenuBarController.shared.openMainWindow()
        if connection?.keyboardActive == true {
            KeyboardNotificationManager.shared.cancelAttention()
            NotificationCenter.default.post(
                name: KeyboardNotificationManager.openKeyboardSheetNotification, object: nil)
        }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Fires when app is activated from outside (e.g. terminal-notifier click).
        // Only open the keyboard sheet if we previously sent a notification
        // (notified flag is set) — avoids spurious opens on normal activation.
        guard KeyboardNotificationManager.shared.wasNotified,
              connection?.keyboardActive == true else { return }
        KeyboardNotificationManager.shared.cancelAttention()
        NotificationCenter.default.post(
            name: KeyboardNotificationManager.openKeyboardSheetNotification, object: nil)
    }

    weak var connection: CompanionConnection?
}
