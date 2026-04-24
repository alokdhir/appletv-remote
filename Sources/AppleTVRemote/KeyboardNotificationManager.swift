import Foundation
import AppKit
import AppleTVLogging

/// Manages keyboard-input notifications for Apple TV remote requests.
///
/// UNUserNotificationCenter is non-functional for ad-hoc signed apps
/// (UNErrorDomain Code=1). Instead we use two mechanisms:
///   1. osascript `display notification` — fires immediately, no signing required,
///      appears attributed to "Script Editor". No click action.
///   2. NSApp.requestUserAttention — bounces the dock icon as a secondary signal.
///
/// Dock icon click (applicationShouldHandleReopen) opens the keyboard sheet
/// directly when keyboardActive is true.
final class KeyboardNotificationManager: NSObject {

    static let shared = KeyboardNotificationManager()

    /// Posted on the main thread to open the keyboard input sheet.
    static let openKeyboardSheetNotification = Notification.Name(
        "com.adhir.appletv-remote.openKeyboardSheet"
    )

    private var attentionRequestToken: Int = -1
    private var notified = false

    private override init() { super.init() }

    // MARK: - Public API

    /// Send an osascript notification and bounce the dock icon.
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

            // osascript notification — works without signing, appears immediately.
            let script = "display notification \"Click the dock icon to type\" with title \"\(deviceName) wants keyboard input\""
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            try? task.run()

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
