import SwiftUI
import AppKit
import Combine
import AppleTVProtocol
import AppleTVLogging

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
        // .automatic (not .contentMinSize) is intentional: .contentMinSize
        // triggers a SwiftUI centering pass 50-500ms after launch that fights
        // our frame restoration in WindowSetupView.
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    /// Called by AppDelegate.applicationDidFinishLaunching — fires regardless
    /// of whether a window is visible (handles `open -g` headless launches).
    /// Idempotent: safe to call again from .onAppear.
    private func setUp() {
        appDelegate.onFinishLaunching = nil  // clear after first real call
        if ProcessInfo.processInfo.environment["ATV_VERBOSE"] != nil { Log.verbose = true }
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
                        // Probe-only: if the ATV is asleep we transition to
                        // .sleeping rather than firing WoL. Avoids waking an
                        // ATV the user intentionally slept just because the
                        // Mac app relaunched (or woke from sleep itself).
                        connection.connectIfAwake(to: device)
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
                Task { @MainActor in
                    guard let ids = connection?.appList.map({ $0.id }), !ids.isEmpty else { return }
                    AppIconCache.shared.refreshIfStale(bundleIDs: ids)
                }
            }
        }
    }
}

// MARK: - App delegate

/// Keeps the app alive when all windows close. Without this, SwiftUI's default
/// Settle delay used after first appear to suppress visual flashes from
/// transient state (sidebar reflow, connection state churn). Long enough
/// that device restore + the first round-trip can complete; short enough
/// that the user just sees a single ProgressView, not a beat of nothing.
/// Centralised here so the three on-appear timers stay in sync.
enum LaunchSettle {
    static let delay: TimeInterval = 0.5
}

/// `applicationShouldTerminateAfterLastWindowClosed == true` terminates the
/// process whenever the user closes a secondary window (e.g. the standard
/// About panel) while the main window is hidden — since the menu-bar status
/// item is not a window, AppKit considers the app window-less and quits it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AppleTVRemoteApp after SwiftUI initialises its @StateObjects.
    var onFinishLaunching: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit's NSWindow frame autosave writes under the executable-name
        // domain (`getprogname()` → "AppleTVRemote.plist"), NOT the bundle-id
        // domain that UserDefaults.standard reads. Sweep both here — before
        // any window appears — so SwiftUI can't re-apply a stale autosave key
        // after WindowSetupView's setFrame call.
        // UserDefaults.standard never returns nil; compactMap protects against
        // the suiteName: init failing (e.g. sandboxed environments).
        for suite in [UserDefaults.standard, UserDefaults(suiteName: "AppleTVRemote")].compactMap({ $0 }) {
            for key in suite.dictionaryRepresentation().keys
            where key.hasPrefix("NSWindow Frame ") {
                suite.removeObject(forKey: key)
            }
        }
    }

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

    /// ⌘Q / programmatic quit. WindowHider.windowWillClose also fires during
    /// termination, but its timing relative to process exit is not guaranteed
    /// on all macOS versions. Writing here as well ensures the final frame is
    /// captured. The duplicate write is harmless (same value, same key).
    func applicationWillTerminate(_ notification: Notification) {
        if let w = MenuBarController.shared.mainWindow {
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: mainWindowFrameKey)
        }
    }

    weak var connection: CompanionConnection?
}
