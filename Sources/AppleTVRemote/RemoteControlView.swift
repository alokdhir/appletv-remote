import SwiftUI
import AppKit
import AppleTVProtocol
import AppleTVLogging

struct RemoteControlView: View {
    let device: AppleTVDevice
    @ObservedObject var connection: CompanionConnection
    @EnvironmentObject var discovery: DeviceDiscovery
    @EnvironmentObject var reconnector: AutoReconnector
    @State private var pairingPin = ""
    @State private var cancelEnabled = false
    @State private var showKeyboardInput = false
    @State private var keyboardInputText = ""
    @State private var keyboardNotifyTask: Task<Void, Never>?
    @State private var showAppLauncher = false
    @FocusState private var pinFocused: Bool
    @FocusState private var keyboardInputFocused: Bool
    @AppStorage("com.adhir.appletv-remote.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var readyToShowState = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            // While AutoReconnector is cycling, keep the remote buttons on
            // screen — the transient `.disconnected`/`.connecting`/`.error`
            // would otherwise flash the connect prompt for ~350 ms on every
            // idle-socket reconnect. The status bar shows "Reconnecting…" so
            // the user still knows what's happening.
            //
            // We key on hasEverConnected (not isReconnecting) because
            // isReconnecting is set one Combine frame after the state change,
            // leaving a single SwiftUI render where state==.disconnected and
            // isReconnecting==false — exactly the flash we want to suppress.
            if reconnector.hasEverConnected,
               !connection.userInitiatedDisconnect,
               connection.state != .awaitingPairingPin {
                if showAppLauncher {
                    AppLauncherView(
                        connection: connection,
                        iconCache: AppIconCache.shared,
                        showAppLauncher: $showAppLauncher
                    )
                } else {
                    remoteLayout
                }
            } else if !readyToShowState {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                    // Transitional — hasEverConnected will flip and take over shortly.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let msg):
                    errorView(msg)
                }
            }
        }
        .onAppear {
            // Delay showing connection state UI so the initial connecting/error
            // flash doesn't appear during app launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + LaunchSettle.delay) {
                readyToShowState = true
            }
        }
        .sheet(isPresented: $showKeyboardInput, onDismiss: {
            keyboardInputText = ""
        }) {
            keyboardInputSheet
        }
        .onChange(of: connection.keyboardActive) { active in
            guard active else {
                keyboardNotifyTask?.cancel()
                keyboardNotifyTask = nil
                KeyboardNotificationManager.shared.resetNotify()
                return
            }
            keyboardNotifyTask?.cancel()
            KeyboardNotificationManager.shared.resetNotify()
            let deviceName = connection.currentDevice?.name ?? "Apple TV"
            keyboardNotifyTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if NSApp.mainWindow?.isKeyWindow == true {
                    showKeyboardInput = true
                } else {
                    KeyboardNotificationManager.shared.notify(deviceName: deviceName)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: KeyboardNotificationManager.openKeyboardSheetNotification)
        ) { _ in
            KeyboardNotificationManager.shared.cancelAttention()
            showKeyboardInput = true
        }
    }

    // MARK: - Sub-views

    private var statusBar: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show devices" : "Hide devices")
            Circle()
                .fill(reconnector.isReconnecting ? .yellow : statusColor)
                .frame(width: 8, height: 8)
            Text(reconnector.isReconnecting ? "Reconnecting…" : connection.state.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if connection.state == .connected {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showAppLauncher.toggle()
                    }
                } label: {
                    Image(systemName: showAppLauncher ? "appletvremote.gen2" : "square.grid.3x3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showAppLauncher ? "Show remote" : "Show apps")
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
        VStack(spacing: 0) {
            remoteScrollContent
            nowPlayingFooter
        }
    }

    @ViewBuilder
    private var nowPlayingFooter: some View {
        if let np = connection.nowPlaying, hasFooterContent(np) {
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                let live = connection.nowPlaying ?? np
                HStack(alignment: .center, spacing: 8) {
                    Text(footerTitle(live) ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(footerDetail(live).map { tip in
                            DelayedTooltip(text: tip, delay: 0.4)
                                .allowsHitTesting(true)
                        })
                    Text(footerTime(live, at: ctx.date) ?? "")
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4))
            }
        }
    }

    private func hasFooterContent(_ np: NowPlayingInfo) -> Bool {
        footerTitle(np) != nil || np.elapsedTime != nil
    }

    private func footerTitle(_ np: NowPlayingInfo) -> String? {
        if let t = np.title, !t.isEmpty { return t }
        if let a = np.app,   !a.isEmpty { return a }
        return nil
    }

    private func footerDetail(_ np: NowPlayingInfo) -> String? {
        let bits = [np.title, np.artist, np.album].compactMap { $0 }.filter { !$0.isEmpty }
        guard bits.count > 1 else { return nil }
        return bits.joined(separator: " — ")
    }

    private func footerTime(_ np: NowPlayingInfo, at date: Date) -> String? {
        guard let elapsed = np.liveElapsed(at: date) else { return nil }
        if let total = np.duration, total > 0 {
            return "\(Self.formatTime(elapsed)) / \(Self.formatTime(total))"
        }
        return Self.formatTime(elapsed)
    }

    /// "1:23" or "1:02:34" — same convention as `atv status`.
    private static func formatTime(_ seconds: Double) -> String {
        let s   = Int(seconds.rounded())
        let h   = s / 3600
        let m   = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private var remoteScrollContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                KeyCatcher(onCommand: { connection.send($0) },
                            onShowApps: { withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = true } },
                            onBackspace: connection.keyboardActive ? { connection.sendBackspace { _ in } } : nil)
                    .frame(width: 0, height: 0)
                // Navigation pad — circular ring matching the real Apple TV remote
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 164, height: 164)
                    VStack(spacing: 4) {
                        RemoteButton(label: "chevron.up",    action: { connection.send(.up) })
                        HStack(spacing: 4) {
                            RemoteButton(label: "chevron.left",   action: { connection.send(.left) })
                            SelectButton(action: { connection.send(.select) }, size: 52)
                            RemoteButton(label: "chevron.right",  action: { connection.send(.right) })
                        }
                        RemoteButton(label: "chevron.down",  action: { connection.send(.down) })
                    }
                }

                // Back + Home — mirrors physical button positions on the Siri Remote
                HStack(spacing: 48) {
                    LabeledRemoteButton(sfSymbol: "chevron.backward", label: "Back") {
                        connection.send(.menu)
                    } longPressAction: {
                        connection.sendLongPress(.menu)
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

                // Keyboard — always visible, enabled only when ATV wants text input
                LabeledRemoteButton(sfSymbol: "keyboard", label: "Keyboard") {
                    showKeyboardInput = true
                }
                .disabled(!connection.keyboardActive)
                .opacity(connection.keyboardActive ? 1.0 : 0.4)
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

    // MARK: - Keyboard input sheet

    private var keyboardInputSheet: some View {
        VStack(spacing: 16) {
            Text("Keyboard Input")
                .font(.headline)
            Text(connection.currentDevice?.name ?? "Apple TV")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Type here…", text: $keyboardInputText)
                .textFieldStyle(.roundedBorder)
                .focused($keyboardInputFocused)
                .onSubmit { submitKeyboardText() }
                .onAppear { keyboardInputFocused = true }
            HStack(spacing: 12) {
                Button("Cancel") {
                    showKeyboardInput = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Clear") { clearKeyboardText() }
                    .foregroundStyle(.red)
                Button("Send") { submitKeyboardText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyboardInputText.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 280)
    }

    private func submitKeyboardText() {
        guard !keyboardInputText.isEmpty else { return }
        let text = keyboardInputText
        connection.sendText(text) { error in
            if let error {
                Log.companion.fail("Keyboard input failed: \(error)")
            }
        }
        keyboardInputText = ""
        showKeyboardInput = false
    }

    private func clearKeyboardText() {
        keyboardInputText = ""
        connection.sendClearText { error in
            if let error {
                Log.companion.fail("Keyboard clear failed: \(error)")
            }
        }
    }
}

// MARK: - Keyboard shortcuts

/// Zero-size NSView that claims first-responder inside the remote layout so
/// hardware keys dispatch to the connected Apple TV:
///
///   ↑ ↓ ← →     — D-pad
///   return      — select (D-pad centre)
///   space, p    — play / pause
///   m           — menu / back
///   h           — home
///   a           — show app grid
///   delete      — backspace (when ATV text field is focused)
///   ⌥↑ ⌥↓       — volume up / down
///                  (⌃↑/⌃↓ would conflict with macOS Mission Control)
///
/// Other keys with modifiers (⌘/⌃, plus ⌥ outside the volume bindings) are
/// passed through so app-level shortcuts (⌘Q, ⌘W, ⌘,) keep working.
private struct KeyCatcher: NSViewRepresentable {
    let onCommand: (RemoteCommand) -> Void
    var onShowApps: () -> Void = {}
    var onBackspace: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = KeyCatcherView()
        v.onCommand = onCommand
        v.onShowApps = onShowApps
        v.onBackspace = onBackspace
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCatcherView)?.onCommand = onCommand
        (nsView as? KeyCatcherView)?.onShowApps = onShowApps
        (nsView as? KeyCatcherView)?.onBackspace = onBackspace
    }
}

private final class KeyCatcherView: NSView {
    var onCommand: (RemoteCommand) -> Void = { _ in }
    var onShowApps: () -> Void = {}
    var onBackspace: (() -> Void)? = nil

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Defer to the next runloop tick so SwiftUI finishes wiring up the
        // window's responder chain before we try to seize focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])

        // ⌥↑ / ⌥↓ → volume up / down. Using Option rather than Control
        // because macOS reserves ⌃↑ / ⌃↓ for Mission Control. Caught before
        // the modifier bail-out below; only fires on plain ⌥ (not ⌘⌥, ⌃⌥)
        // so we don't shadow other shortcuts.
        if mods == .option {
            switch event.keyCode {
            case 126: onCommand(.volumeUp);   return
            case 125: onCommand(.volumeDown); return
            default:  break
            }
        }

        // Let other ⌘/⌃/⌥ shortcuts reach the menu bar and other handlers.
        if !mods.isEmpty { super.keyDown(with: event); return }

        if event.charactersIgnoringModifiers?.lowercased() == "a" {
            onShowApps()
            return
        }
        // Backspace while ATV has a text field focused — delete last character.
        if event.keyCode == 51, let handler = onBackspace {
            handler()
            return
        }
        if let cmd = command(for: event) {
            onCommand(cmd)
            return
        }
        super.keyDown(with: event)
    }

    private func command(for event: NSEvent) -> RemoteCommand? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .select          // return, keypad enter
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": return .menu
        case "h": return .home
        case " ", "p": return .playPause
        default:  return nil
        }
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

struct SelectButton: View {
    let action: () -> Void
    var size: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(.primary)
                .frame(width: size, height: size)
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