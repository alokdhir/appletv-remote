import SwiftUI
import AppKit

// MARK: - Hide main window on close (don't disconnect)

/// Key under which we persist the main window's frame across launches.
/// Read on startup by `WindowSetupView`, written here on every move/resize
/// and once more on windowWillClose so ⌘Q captures the final position.
let mainWindowFrameKey = "com.adhir.appletv-remote.windowFrame"

/// Intercepts the window close button and hides instead of closing,
/// so the connection stays alive when the user dismisses the main window.
/// Also persists the window frame on move / resize / close so position
/// survives both ⌘Q (graceful terminate) and pkill (signal kill).
@MainActor
final class WindowHider: NSObject, NSWindowDelegate {
    static let shared = WindowHider()

    /// Persistence is locked until this timestamp passes. WindowSetupView
    /// pushes it ~800ms into the future on launch so SwiftUI's centering
    /// pass (which moves the window away from our restored frame even with
    /// .windowResizability(.automatic), but only on Dock-launches after
    /// ⌘Q quit — pkill quits skip it somehow) doesn't overwrite the saved
    /// frame with the centered position.
    var persistenceUnlocksAt: Date = .distantPast

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistFrame(sender, forced: true)
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        if let w = notification.object as? NSWindow { persistFrame(w) }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow { persistFrame(w) }
    }

    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { persistFrame(w, forced: true) }
    }

    private func persistFrame(_ w: NSWindow, forced: Bool = false) {
        guard forced || Date() >= persistenceUnlocksAt else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: mainWindowFrameKey)
        UserDefaults.standard.synchronize()
    }
}

/// NSView subclass that intercepts window attachment to hide the window before
/// it ever appears on screen (avoiding the startup flash), and to configure
/// translucency so the sibling NSVisualEffectView background shows through.
@MainActor
class WindowSetupView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            return
        }
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
        window.collectionBehavior = [.fullScreenAuxiliary]

        // Disable AppKit's saved-state restoration. macOS otherwise persists
        // the window frame to ~/Library/Saved Application State on ⌘Q and
        // restores from there on next launch, ignoring the autosave key.
        // The savedState bundle tends to capture stale/center frames and
        // overrides UserDefaults, so ⌘Q + relaunch loses position while
        // pkill + relaunch (which skips state restoration) preserves it.
        window.isRestorable = false

        // Window frame persistence. WindowHider's delegate methods
        // (windowDidMove/Resize/WillClose) write the frame to
        // mainWindowFrameKey; we restore from it below. SwiftUI's
        // own autosave keys are swept at App.init time (in the
        // exec-name "AppleTVRemote" suite where AppKit puts them)
        // before SwiftUI can read and re-apply them after our
        // setFrame here.
        let defaults = UserDefaults.standard
        window.setFrameAutosaveName("")

        // Restore our saved frame if present and visible on some current
        // screen. Otherwise pin a starting size from sidebar state.
        // Note: this restore only sticks because the scene uses
        // .windowResizability(.automatic) — .contentMinSize triggers a
        // SwiftUI centering pass that moves the window to horizontal
        // center 50-500ms after our setFrame.
        // Determine target frame from saved value (or nil for first-run / off-screen).
        var targetFrame: NSRect?
        if let saved = defaults.string(forKey: mainWindowFrameKey) {
            let r = NSRectFromString(saved)
            if !r.isEmpty, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                targetFrame = r
            }
        }

        // SwiftUI's WindowGroup runs a late centering pass at ~50–500ms
        // after viewDidMoveToWindow on Dock-launches after ⌘Q. (pkill
        // launches skip it.) The pass ignores .windowResizability and
        // moves the window to horizontal center. Hide the window with
        // alpha=0, re-assert our frame across the pass window, then
        // reveal. Persistence is locked so the intermediate centered
        // frame doesn't overwrite the user's saved one.
        WindowHider.shared.persistenceUnlocksAt = Date().addingTimeInterval(0.8)
        window.alphaValue = 0
        if let r = targetFrame {
            window.setFrame(r, display: false)
            for delay in [0.05, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    window?.setFrame(r, display: false)
                }
            }
        } else {
            let collapsed = defaults.bool(forKey: "com.adhir.appletv-remote.sidebarCollapsed")
            window.setContentSize(NSSize(width: collapsed ? 300 : 520, height: 620))
        }

        let nc = NotificationCenter.default

        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                // Suppress focus-fade reveal while restore is thrashing —
                // the window must stay at alpha=0 until the reveal hop
                // below fires, otherwise SwiftUI's centering pass is
                // visible behind the fade.
                guard Date() >= WindowHider.shared.persistenceUnlocksAt else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    window?.animator().alphaValue = 1.0
                }
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    window?.animator().alphaValue = 0.8
                }
            }
        })

        // Reveal once SwiftUI's centering pass has settled (≥0.5s reapply
        // + headroom). For hideWindowAtStartup=true (CLI/headless launches)
        // we orderOut instead of fading in — alpha is restored to 1 so the
        // next show (Dock click) appears normally.
        let hide = UserDefaults.standard.object(forKey: "com.adhir.appletv-remote.hideWindowAtStartup") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "com.adhir.appletv-remote.hideWindowAtStartup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak window] in
            guard let window else { return }
            if hide {
                window.orderOut(nil)
                window.alphaValue = 1
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    window.animator().alphaValue = 1
                }
            }
        }
    }
}

/// Background view that attaches window lifecycle hooks at the earliest possible point.
struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowSetupView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
