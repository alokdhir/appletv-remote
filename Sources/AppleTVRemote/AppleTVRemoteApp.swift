import SwiftUI
import AppKit

@main
struct AppleTVRemoteApp: App {
    @StateObject private var discovery  = DeviceDiscovery()
    @StateObject private var connection = CompanionConnection()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .preferredColorScheme(.dark)
                .onAppear {
                    MenuBarController.shared.setUp(discovery: discovery, connection: connection)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Menu bar controller

/// Owns the NSStatusItem and NSPopover for the menu bar remote.
/// Implemented as a singleton so the status item is never deallocated.
/// setUp() is called once from ContentView.onAppear after the app is running.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover:    NSPopover?

    func setUp(discovery: DeviceDiscovery, connection: CompanionConnection) {
        guard statusItem == nil else { return }   // only once

        // Status item — squareLength ensures it's always visible even if the image fails
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }

        // Try successively simpler symbols; all are available on macOS 13+
        let img = NSImage(systemSymbolName: "appletv.remote.gen2", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv",      accessibilityDescription: nil)
        img?.isTemplate = true
        button.image = img
        button.imageScaling = .scaleProportionallyDown
        button.action = #selector(toggle(_:))
        button.target = self

        // Popover
        let vc = NSHostingController(rootView:
            MenuBarRemoteView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .preferredColorScheme(.dark)
        )
        vc.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        popover = pop
    }

    @objc private func toggle(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Clear first responder so no button shows a focus ring on open
            DispatchQueue.main.async {
                pop.contentViewController?.view.window?.makeFirstResponder(nil)
            }
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
                        RemoteButton(label: "return",         action: { connection.send(.select) }, size: 48)
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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
