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
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar remote: window-style floating panel
        MenuBarExtra {
            MenuBarRemoteView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar icon (d-pad chevrons, monochrome template)

private struct MenuBarIconView: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width  / 2
            let cy = size.height / 2
            let r  = min(cx, cy) * 0.82

            // Outer ring
            ctx.stroke(
                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r)),
                with: .foreground, lineWidth: 1.2
            )

            // Four chevrons
            let reach = r * 0.55
            let span  = r * 0.28
            let back  = r * 0.18
            let lw: CGFloat = 1.4

            func chevron(tx: CGFloat, ty: CGFloat,
                         lx: CGFloat, ly: CGFloat,
                         rx: CGFloat, ry: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: lx, y: ly))
                p.addLine(to: CGPoint(x: tx, y: ty))
                p.addLine(to: CGPoint(x: rx, y: ry))
                return p
            }

            // Up
            ctx.stroke(chevron(tx: cx,        ty: cy - reach,
                               lx: cx - span, ly: cy - reach + back,
                               rx: cx + span, ry: cy - reach + back),
                       with: .foreground, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            // Down
            ctx.stroke(chevron(tx: cx,        ty: cy + reach,
                               lx: cx - span, ly: cy + reach - back,
                               rx: cx + span, ry: cy + reach - back),
                       with: .foreground, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            // Left
            ctx.stroke(chevron(tx: cx - reach, ty: cy,
                               lx: cx - reach + back, ly: cy - span,
                               rx: cx - reach + back, ry: cy + span),
                       with: .foreground, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            // Right
            ctx.stroke(chevron(tx: cx + reach, ty: cy,
                               lx: cx + reach - back, ly: cy - span,
                               rx: cx + reach - back, ry: cy + span),
                       with: .foreground, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            // Centre dot
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.5, y: cy - 1.5, width: 3, height: 3)),
                     with: .foreground)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Menu bar remote window

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

    // ── Connected: compact remote ─────────────────────────────────────────────

    private var connectedView: some View {
        VStack(spacing: 14) {
            // Device name + disconnect
            HStack {
                Text(connection.currentDevice?.name ?? "Apple TV")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    connection.disconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
            }

            // Navigation pad
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

            // Back · Play/Pause · Home
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

            // Volume
            HStack(spacing: 20) {
                LabeledRemoteButton(sfSymbol: "speaker.minus.fill", label: "Vol −") {
                    connection.send(.volumeDown)
                }
                LabeledRemoteButton(sfSymbol: "speaker.plus.fill", label: "Vol +") {
                    connection.send(.volumeUp)
                }
            }

            // Open main window link
            Button("Open Full Remote…") {
                openMainWindow()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // ── Disconnected: activate main window ───────────────────────────────────

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Apple TV Connected")
                .font(.subheadline.weight(.medium))
            Button("Open Remote") {
                openMainWindow()
            }
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
