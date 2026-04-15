import SwiftUI
import AppleTVProtocol

struct RemoteControlView: View {
    let device: AppleTVDevice
    @ObservedObject var connection: CompanionConnection
    @EnvironmentObject var discovery: DeviceDiscovery
    @State private var pairingPin = ""
    @State private var cancelEnabled = false
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            Divider()

            switch connection.state {
            case .disconnected:
                connectPrompt
            case .waking:
                wakingView
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView("Connecting…")
                    Button("Cancel") { connection.disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(!cancelEnabled)
                        .opacity(cancelEnabled ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    cancelEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { cancelEnabled = true }
                }
            case .awaitingPairingPin:
                pairingView
            case .connected:
                remoteLayout
            case .error(let msg):
                errorView(msg)
            }
        }
    }

    // MARK: - Sub-views

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(connection.state.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text(device.name)
                .font(.title3.weight(.medium))
            Button("Connect") {
                let fresh = discovery.devices.first(where: { $0.id == device.id }) ?? device
                if MACStore.load(for: fresh.id) != nil {
                    connection.wakeAndConnect(to: fresh)
                } else {
                    connection.connect(to: fresh)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wakingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "power.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .opacity(0.85)
            Text("Waking up \(device.name)…")
                .font(.title3.weight(.medium))
            Text("Sent wake signal · connecting in ~5 s")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { connection.disconnect() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pairingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text("Pair with \(device.name)")
                .font(.title3.weight(.medium))
            Text("Enter the PIN shown on your Apple TV screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("PIN", text: $pairingPin)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .focused($pinFocused)
                .onAppear { pinFocused = true }
                .onChange(of: pairingPin) { new in
                    let digits = new.filter(\.isNumber)
                    if digits != new { pairingPin = digits }
                    if digits.count >= 4 {
                        pairingPin = String(digits.prefix(4))
                        submitPin()
                    }
                }
                .onSubmit { submitPin() }
            Button("Pair") { submitPin() }
                .buttonStyle(.borderedProminent)
                .disabled(pairingPin.count < 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var remoteLayout: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Navigation pad — circular ring matching the real Apple TV remote
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 164, height: 164)
                    VStack(spacing: 4) {
                        RemoteButton(label: "chevron.up",    action: { connection.send(.up) })
                        HStack(spacing: 4) {
                            RemoteButton(label: "chevron.left",   action: { connection.send(.left) })
                            RemoteButton(label: "circle.fill",     action: { connection.send(.select) }, size: 52)
                            RemoteButton(label: "chevron.right",  action: { connection.send(.right) })
                        }
                        RemoteButton(label: "chevron.down",  action: { connection.send(.down) })
                    }
                }

                // Back + Home — mirrors physical button positions on the Siri Remote
                HStack(spacing: 48) {
                    LabeledRemoteButton(sfSymbol: "chevron.backward", label: "Back") {
                        connection.send(.menu)
                    }
                    LabeledRemoteButton(sfSymbol: "app.fill", label: "Home") {
                        connection.send(.home)
                    } longPressAction: {
                        connection.sendLongPress(.home)
                    }
                }

                // Play/Pause — centered, matching the physical remote
                RemoteButton(label: "playpause.fill", action: { connection.send(.playPause) }, size: 52)

                // Volume — side buttons on the real remote; shown as a row here
                HStack(spacing: 24) {
                    LabeledRemoteButton(sfSymbol: "speaker.minus.fill", label: "Vol −") {
                        connection.send(.volumeDown)
                    }
                    LabeledRemoteButton(sfSymbol: "speaker.plus.fill", label: "Vol +") {
                        connection.send(.volumeUp)
                    }
                }
            }
            .padding(24)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                let fresh = discovery.devices.first { $0.id == device.id } ?? device
                if MACStore.load(for: fresh.id) != nil {
                    connection.wakeAndConnect(to: fresh)
                } else {
                    connection.connect(to: fresh)
                }
            }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch connection.state {
        case .connected:          return .green
        case .waking:             return .blue
        case .connecting:         return .yellow
        case .awaitingPairingPin: return .orange
        case .error:              return .red
        case .disconnected:       return .gray
        }
    }

    private func submitPin() {
        guard !pairingPin.isEmpty else { return }
        connection.submitPairingPin(pairingPin)
    }
}

// MARK: - Reusable button components

struct RemoteButton: View {
    let label: String
    let action: () -> Void
    var size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: label)
                .font(.system(size: size * 0.38, weight: .medium))
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct LabeledRemoteButton: View {
    let sfSymbol: String
    let label: String
    let action: () -> Void
    var longPressAction: (() -> Void)? = nil

    @GestureState private var isPressed = false

    var body: some View {
        let content = Image(systemName: sfSymbol)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 52, height: 44)
            .background(.quaternary.opacity(isPressed ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help(label)

        if let longPress = longPressAction {
            content
                .gesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .updating($isPressed) { v, s, _ in s = v }
                        .onEnded { _ in longPress() }
                )
                .simultaneousGesture(TapGesture().onEnded { action() })
        } else {
            content
                .gesture(
                    LongPressGesture(minimumDuration: 0.001)
                        .updating($isPressed) { v, s, _ in s = v }
                        .onEnded { _ in action() }
                )
        }
    }
}