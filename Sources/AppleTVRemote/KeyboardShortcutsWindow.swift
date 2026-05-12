import SwiftUI
import AppKit

// MARK: - Shortcut listing

/// Lists every shortcut handled by `KeyCatcherView` in `RemoteControlView`.
/// Kept here as a single source of truth — when a shortcut changes, update
/// the table and `KeyCatcherView.keyDown` together.
private struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let entries: [Shortcut]
}

private struct Shortcut: Identifiable {
    let id = UUID()
    let keys: String
    let description: String
}

private let shortcutGroups: [ShortcutGroup] = [
    ShortcutGroup(title: "Navigation", entries: [
        Shortcut(keys: "↑  ↓  ←  →", description: "D-pad"),
        Shortcut(keys: "Return",      description: "Select (hold for long-press)"),
        Shortcut(keys: "Esc",         description: "Menu / Back (hold for long-press)"),
    ]),
    ShortcutGroup(title: "Playback", entries: [
        Shortcut(keys: "⌃P",    description: "Play / Pause"),
        Shortcut(keys: "Space", description: "Play / Pause"),
    ]),
    ShortcutGroup(title: "Volume", entries: [
        Shortcut(keys: "Page Up",   description: "Volume up"),
        Shortcut(keys: "Page Down", description: "Volume down"),
    ]),
    ShortcutGroup(title: "Trackpad swipe", entries: [
        Shortcut(keys: "⇧↑", description: "Swipe up"),
        Shortcut(keys: "⇧↓", description: "Swipe down"),
        Shortcut(keys: "⇧←", description: "Swipe left"),
        Shortcut(keys: "⇧→", description: "Swipe right"),
    ]),
    ShortcutGroup(title: "System", entries: [
        Shortcut(keys: "⌃A",     description: "Apps grid"),
        Shortcut(keys: "⌃H",     description: "Home (hold for Control Center)"),
        Shortcut(keys: "⌃M",     description: "Menu / Back (hold for long-press)"),
        Shortcut(keys: "Delete", description: "Backspace (when ATV text input is active)"),
    ]),
]

// MARK: - SwiftUI view

struct KeyboardShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Text("Available when the remote pane has focus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(shortcutGroups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(group.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(entry.keys)
                                        .font(.system(.body, design: .monospaced).weight(.medium))
                                        .frame(width: 100, alignment: .leading)
                                    Text(entry.description)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Window controller

/// Lazily constructs and shows the Keyboard Shortcuts window. Single shared
/// instance so reopening from the menu raises the existing window instead of
/// stacking duplicates.
@MainActor
final class KeyboardShortcutsWindowController {
    static let shared = KeyboardShortcutsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView:
                KeyboardShortcutsView()
                    .preferredColorScheme(.dark)
            )
            let win = NSWindow(contentViewController: host)
            win.title = "Keyboard Shortcuts"
            win.styleMask = [.titled, .closable, .resizable]
            // Tall enough to show all five groups (Navigation through System)
            // without scrolling on a default macOS layout.
            win.setContentSize(NSSize(width: 460, height: 720))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
