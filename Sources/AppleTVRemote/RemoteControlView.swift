import SwiftUI

struct RemoteControlView: View {
    let device: AppleTVDevice
    @ObservedObject var connection: CompanionConnection
    @State private var pairingPin = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            Divider()

            switch connection.state {
            case .disconnected:
                connectPrompt
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView("Connecting…")
                    Button("Cancel") { connection.disconnect() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if connection.state == .connected {
                Button("Disconnect") { connection.disconnect() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
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
                connection.connect(to: device)
            }
            .buttonStyle(.borderedProminent)
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
                .onSubmit { submitPin() }
            Button("Pair") { submitPin() }
                .buttonStyle(.borderedProminent)
                .disabled(pairingPin.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var remoteLayout: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let info = connection.nowPlaying {
                    NowPlayingCard(info: info)
                }

                // Navigation pad
                VStack(spacing: 4) {
                    RemoteButton(label: "chevron.up",    action: { connection.send(.up) })
                    HStack(spacing: 4) {
                        RemoteButton(label: "chevron.left",   action: { connection.send(.left) })
                        RemoteButton(label: "return",          action: { connection.send(.select) }, size: 52)
                        RemoteButton(label: "chevron.right",  action: { connection.send(.right) })
                    }
                    RemoteButton(label: "chevron.down",  action: { connection.send(.down) })
                }

                // Menu + Home
                HStack(spacing: 16) {
                    LabeledRemoteButton(sfSymbol: "arrow.uturn.backward", label: "Menu") {
                        connection.send(.menu)
                    }
                    LabeledRemoteButton(sfSymbol: "tv", label: "Home") {
                        connection.send(.home)
                    }
                }

                // Playback controls
                HStack(spacing: 16) {
                    RemoteButton(label: "backward.end.fill",  action: { connection.send(.skipBackward) })
                    RemoteButton(label: "playpause.fill",     action: { connection.send(.playPause) }, size: 52)
                    RemoteButton(label: "forward.end.fill",   action: { connection.send(.skipForward) })
                }

                // Volume
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
            Button("Retry") { connection.connect(to: device) }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch connection.state {
        case .connected:          return .green
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: sfSymbol)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.caption2)
            }
            .frame(width: 64, height: 52)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now Playing Card

struct NowPlayingCard: View {
    let info: NowPlayingInfo

    var body: some View {
        HStack(spacing: 12) {
            if let artworkData = info.artworkData,
               let nsImage = NSImage(data: artworkData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title = info.title {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                if let artist = info.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let album = info.album {
                    Text(album)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: info.playbackRate > 0 ? "pause.fill" : "play.fill")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
