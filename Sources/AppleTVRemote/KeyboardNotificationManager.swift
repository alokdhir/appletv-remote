import Foundation
import UserNotifications
import AppKit
import AppleTVLogging

/// Manages macOS notifications for keyboard input requests from the Apple TV.
///
/// When the ATV wants text input and the app window is not key, fires a
/// UNUserNotificationCenter banner. Clicking it raises the main window and
/// opens the keyboard input sheet via NSNotification.
final class KeyboardNotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = KeyboardNotificationManager()

    /// Posted on the main thread when the user clicks a keyboard notification.
    /// Observers (RemoteControlView) should open the keyboard input sheet.
    static let openKeyboardSheetNotification = Notification.Name(
        "com.adhir.appletv-remote.openKeyboardSheet"
    )

    private static let categoryID   = "keyboard-input"
    private static let actionOpenID  = "open"

    private var attentionRequestToken: Int = -1

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Public API

    /// Bounce the dock icon to signal the ATV wants keyboard input.
    /// No UNUserNotificationCenter involved — works regardless of signing.
    /// Idempotent: subsequent calls while a bounce is already active are ignored.
    func bounce() {
        DispatchQueue.main.async {
            Log.app.report("bounce() called — token=\(self.attentionRequestToken) isActive=\(NSApp.isActive)")
            if NSApp.isActive {
                // App is already active — open the sheet directly instead of bouncing.
                NotificationCenter.default.post(name: Self.openKeyboardSheetNotification, object: nil)
                return
            }
            guard self.attentionRequestToken == -1 else {
                Log.app.report("bounce() skipped — already bouncing")
                return
            }
            self.attentionRequestToken = NSApp.requestUserAttention(.informationalRequest)
            Log.app.report("bounce() fired — new token=\(self.attentionRequestToken)")
        }
    }

    func resetBounce() {
        DispatchQueue.main.async {
            Log.app.report("resetBounce() called — token=\(self.attentionRequestToken)")
            NSApp.cancelUserAttentionRequest(self.attentionRequestToken)
            self.attentionRequestToken = -1
        }
    }

    func notify(deviceName: String) {
        requestPermissionIfNeeded { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.attentionRequestToken = NSApp.requestUserAttention(.informationalRequest)
                }
                return
            }
            self?.fireNotification(deviceName: deviceName)
        }
    }

    func cancelAttention() {
        DispatchQueue.main.async {
            NSApp.cancelUserAttentionRequest(self.attentionRequestToken)
            self.attentionRequestToken = -1
        }
    }

    // MARK: - Private

    private func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(true)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                    [weak self] granted, _ in
                    if granted { self?.registerCategory() }
                    completion(granted)
                }
            default:
                completion(false)
            }
        }
    }

    private func registerCategory() {
        let openAction = UNNotificationAction(
            identifier: Self.actionOpenID,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func fireNotification(deviceName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(deviceName) wants keyboard input"
        content.body  = "Click to open the keyboard input field."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID

        let request = UNNotificationRequest(
            identifier: "keyboard-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.fail("Keyboard notification failed: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MenuBarController.shared.openMainWindow()
            NotificationCenter.default.post(
                name: Self.openKeyboardSheetNotification, object: nil)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping
                                    (UNNotificationPresentationOptions) -> Void) {
        // Show banner even when app is active (window might be hidden)
        completionHandler([.banner, .sound])
    }
}
