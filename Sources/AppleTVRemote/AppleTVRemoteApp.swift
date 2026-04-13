import SwiftUI
import AppKit
import Combine

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
                .background(MainWindowConfigurator())   // hide-on-close, no disconnect
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

// MARK: - Hide main window on close (don't disconnect)

/// Intercepts the window close button and hides instead of closing,
/// so the connection stays alive when the user dismisses the main window.
@MainActor
private final class WindowHider: NSObject, NSWindowDelegate {
    static let shared = WindowHider()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

/// Background view that attaches WindowHider as the window delegate.
private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = WindowHider.shared }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Menu bar controller

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem:       NSStatusItem?
    private var popover:          NSPopover?
    private var stateCancellable: AnyCancellable?

    func setUp(discovery: DeviceDiscovery, connection: CompanionConnection) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }

        let img = NSImage(systemSymbolName: "appletv.remote.gen2", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv.fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "tv",      accessibilityDescription: nil)
        img?.isTemplate = true
        button.image = img
        button.imageScaling = .scaleProportionallyDown
        button.action = #selector(toggle(_:))
        button.target = self

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
        pop.delegate = self
        popover = pop

        // Re-key the popover window when state changes while it's visible,
        // so it doesn't look washed-out after a disconnect/reconnect.
        stateCancellable = connection.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.popover?.isShown == true, NSApp.isActive else { return }
                self.popover?.contentViewController?.view.window?.makeKey()
            }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            NSApp.deactivate()
        }
    }

    @objc private func toggle(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        if pop.isShown {
            // Deactivate before closing so the main window never gets a chance
            // to surface between performClose and the popoverDidClose callback.
            NSApp.deactivate()
            pop.performClose(nil)
        } else {
            // Activate before showing so the popover renders with active (non-washed-out) colours.
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async {
                let popWin = pop.contentViewController?.view.window
                popWin?.makeKey()
                popWin?.makeFirstResponder(nil)
                // Fully hide every non-popover window so macOS has nothing to
                // surface as the next key window when the popover closes.
                NSApp.windows.filter { $0 !== popWin }.forEach { $0.orderOut(nil) }
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
        // orderFront brings the window forward without stealing key status from
        // the popover — the menu bar remote stays active and non-washed-out.
        NSApp.windows.first { $0.canBecomeMain }?.orderFront(nil)
    }
}
