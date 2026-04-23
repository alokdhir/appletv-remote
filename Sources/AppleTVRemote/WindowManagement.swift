import SwiftUI
import AppKit

// MARK: - Hide main window on close (don't disconnect)

/// Intercepts the window close button and hides instead of closing,
/// so the connection stays alive when the user dismisses the main window.
@MainActor
final class WindowHider: NSObject, NSWindowDelegate {
    static let shared = WindowHider()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// NSView subclass that intercepts window attachment to hide the window before
/// it ever appears on screen (avoiding the startup flash), and to configure
/// translucency so the sibling NSVisualEffectView background shows through.
class WindowSetupView: NSView {
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
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

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
        let collapsed = UserDefaults.standard.bool(forKey: "com.adhir.appletv-remote.sidebarCollapsed")
        window.setContentSize(NSSize(width: collapsed ? 300 : 520, height: 620))

        // Default true: hide window on startup so CLI-launched app doesn't steal
        // focus, but the window is still created so dock-click can surface it.
        let hide = UserDefaults.standard.object(forKey: "com.adhir.appletv-remote.hideWindowAtStartup") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "com.adhir.appletv-remote.hideWindowAtStartup")
        guard hide else { return }
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
struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowSetupView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
