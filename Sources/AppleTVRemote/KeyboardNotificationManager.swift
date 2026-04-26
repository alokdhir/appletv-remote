import Foundation
import AppKit
import AppleTVLogging

/// Manages keyboard-input notifications for Apple TV remote requests.
///
/// UNUserNotificationCenter is non-functional for ad-hoc signed apps
/// (UNErrorDomain Code=1). Instead we use two mechanisms:
///   1. terminal-notifier (if found at /opt/homebrew/bin/terminal-notifier) —
///      shows a proper macOS notification attributed to AppleTVRemote; clicking
///      it focuses the app. Install with: brew install terminal-notifier
///   2. osascript `display notification` fallback — works without any extra
///      install but appears attributed to "Script Editor" with no click action.
///   3. NSApp.requestUserAttention — bounces the dock icon as a secondary signal.
///
/// Dock icon click (applicationShouldHandleReopen) opens the keyboard sheet
/// directly when keyboardActive is true.
final class KeyboardNotificationManager: NSObject {

    static let shared = KeyboardNotificationManager()

    /// Posted on the main thread to open the keyboard input sheet.
    static let openKeyboardSheetNotification = Notification.Name(
        "com.adhir.appletv-remote.openKeyboardSheet"
    )

    private static let terminalNotifierPath = "/opt/homebrew/bin/terminal-notifier"
    private static let bundleID = "com.adhir.appletv-remote"

    private var attentionRequestToken: Int = -1
    private var notified = false

    private override init() { super.init() }

    // MARK: - Public API

    /// Send a notification and bounce the dock icon.
    /// Idempotent — only fires once until resetNotify() is called.
    func notify(deviceName: String) {
        DispatchQueue.main.async {
            if Log.verbose { Log.app.report("notify() called — notified=\(self.notified) isActive=\(NSApp.isActive)") }

            if NSApp.isActive {
                // App is already focused — open the sheet directly.
                NotificationCenter.default.post(name: Self.openKeyboardSheetNotification, object: nil)
                return
            }

            guard !self.notified else {
                if Log.verbose { Log.app.report("notify() skipped — already notified") }
                return
            }
            self.notified = true

            let title = "\(deviceName) wants keyboard input"
            let body  = "Click to type"

            if FileManager.default.isExecutableFile(atPath: Self.terminalNotifierPath) {
                // terminal-notifier: proper notification attributed to our app;
                // clicking it activates AppleTVRemote. -sender fakes the sender
                // so our icon appears and clicking opens our app.
                let task = Process()
                task.executableURL = URL(fileURLWithPath: Self.terminalNotifierPath)
                task.arguments = [
                    "-title",   title,
                    "-message", body,
                    "-sender",  Self.bundleID,
                    "-group",   "keyboard-input",
                ]
                try? task.run()
            } else {
                // Fallback: osascript — no signing required, but opens Script Editor on click.
                let script = "display notification \"\(body)\" with title \"\(title)\""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                try? task.run()
            }

            // Also bounce the dock icon as a secondary visual cue.
            if self.attentionRequestToken == -1 {
                self.attentionRequestToken = NSApp.requestUserAttention(.informationalRequest)
                if Log.verbose { Log.app.report("notify() bounced — token=\(self.attentionRequestToken)") }
            }
        }
    }

    /// Reset so the next notify() call fires again (call when keyboardActive → false).
    func resetNotify() {
        DispatchQueue.main.async {
            if Log.verbose { Log.app.report("resetNotify() called") }
            NSApp.cancelUserAttentionRequest(self.attentionRequestToken)
            self.attentionRequestToken = -1
            self.notified = false
        }
    }

    /// Cancel the attention request (call when keyboard sheet opens).
    func cancelAttention() {
        DispatchQueue.main.async {
            NSApp.cancelUserAttentionRequest(self.attentionRequestToken)
            self.attentionRequestToken = -1
        }
    }
}

