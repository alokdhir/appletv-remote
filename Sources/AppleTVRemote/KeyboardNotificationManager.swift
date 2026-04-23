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

    private var permissionGranted = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Public API

    func notify(deviceName: String) {
        requestPermissionIfNeeded { [weak self] granted in
            guard granted else {
                // Fallback: just raise the window; user will see the keyboard button lit up
                DispatchQueue.main.async {
                    MenuBarController.shared.openMainWindow()
                }
                return
            }
            self?.fireNotification(deviceName: deviceName)
        }
    }

    // MARK: - Private

    private func requestPermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        if permissionGranted { completion(true); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
            self?.permissionGranted = granted
            if granted { self?.registerCategory() }
            completion(granted)
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
