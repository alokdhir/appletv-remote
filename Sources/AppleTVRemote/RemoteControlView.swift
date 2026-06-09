import SwiftUI
import AppKit
import AppleTVProtocol
import AppleTVLogging

struct RemoteControlView: View {
    /// Distance from the d-pad centre to each swipe chevron, in points.
    /// The d-pad circle is 182pt across (radius 91); 80pt places the
    /// 11pt chevron glyphs just inside the rim with ~5pt visual margin.
    static let swipeChevronRadius: CGFloat = 80

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

    /// Currently-flashing command from a keyboard shortcut. Set when KeyCatcher
    /// fires `onCommand` / `onLongCommand`, cleared after `keyFlashDuration`.
    /// Each button checks if it matches and OR's the result into its press
    /// visual so keyboard shortcuts feel like mouse presses.
    @State private var keyFlashCommand: RemoteCommand?
    /// Same idea for swipe chevrons.
    @State private var keyFlashSwipe: SwipeDirection?
    static let keyFlashDuration: TimeInterval = 0.15

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
                case .disconnected, .sleeping:
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
        .onDisappear {
            // Cancel any in-flight notification debounce so it can't post a
            // notification for a device the user has already switched away
            // from (the Task's 2-second sleep would otherwise outlive us).
            keyboardNotifyTask?.cancel()
            keyboardNotifyTask = nil
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
        // Drive the footer's slide-up/fade-in transition off its visibility
        // predicate (not on `connection.nowPlaying != nil`) so a track
        // change between two non-nil values doesn't re-animate.
        .animation(.easeOut(duration: 0.25), value: footerVisible)
    }

    /// True when the now-playing footer should be on-screen. Mirrors the
    /// condition inside `nowPlayingFooter` so `.animation(_:value:)` can
    /// observe a single Equatable bool rather than the whole NowPlayingInfo.
    private var footerVisible: Bool {
        guard let np = connection.nowPlaying else { return false }
        return hasFooterContent(np)
    }

    @ViewBuilder
    private var nowPlayingFooter: some View {
        if let np = connection.nowPlaying, hasFooterContent(np) {
            TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                // Read connection.nowPlaying fresh on each tick rather than
                // relying on the outer `np` capture. SwiftUI sometimes reuses
                // a TimelineView's content closure across body re-evaluations,
                // so a play→pause that changes np (new playbackRate, new
                // elapsedAnchor) doesn't always rebuild the closure — leaving
                // it ticking off a stale NowPlayingInfo. Reading the
                // @Published value inside the closure picks up the live
                // anchor on the next tick (≤1s staleness, fine for a clock).
                // The `?? np` fallback covers the unlikely case where
                // connection.nowPlaying went back to nil mid-render.
                let live = connection.nowPlaying ?? np
                VStack(spacing: 0) {
                    // Progress bar — only when duration is known. ZStack +
                    // scaleEffect avoids GeometryReader's per-frame layout
                    // invalidation; the background rect provides a track so
                    // 0% playback doesn't look like a missing bar.
                    if let duration = live.duration, duration > 0 {
                        let progress = min(max((live.liveElapsed(at: ctx.date) ?? 0) / duration, 0), 1)
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(.quaternary)
                            Rectangle()
                                .fill(Color.accentColor)
                                .scaleEffect(x: progress, y: 1, anchor: .leading)
                        }
                        .frame(height: 4)
                        .accessibilityElement()
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                    }
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
                }
                .background(.quaternary.opacity(0.4))
            }
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .opacity
            ))
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
                KeyCatcher(onCommand: { cmd in connection.send(cmd); flashKey(cmd) },
                            onLongCommand: { cmd in connection.sendLongPress(cmd) },
                            onPressingChanged: { cmd, pressing in
                                if pressing {
                                    keyFlashCommand = cmd
                                } else if keyFlashCommand == cmd {
                                    keyFlashCommand = nil
                                }
                            },
                            onSwipe: { dir in connection.sendSwipe(dir); flashKeySwipe(dir) },
                            onShowApps: { withAnimation(.easeInOut(duration: 0.18)) { showAppLauncher = true } },
                            onBackspace: connection.keyboardActive ? { connection.sendBackspace { _ in } } : nil)
                    .frame(width: 0, height: 0)
                // Navigation pad — circular ring matching the real Apple TV remote
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 182, height: 182)
                    VStack(spacing: 4) {
                        RemoteButton(label: "chevron.up",    action: { connection.send(.up) },    size: 38,
                                     flash: keyFlashCommand == .up)
                        HStack(spacing: 4) {
                            RemoteButton(label: "chevron.left",   action: { connection.send(.left) },  size: 38,
                                         flash: keyFlashCommand == .left)
                            SelectButton(action: { connection.send(.select) }, size: 52,
                                         flash: keyFlashCommand == .select,
                                         longPressAction: { connection.sendLongPress(.select) })
                            RemoteButton(label: "chevron.right",  action: { connection.send(.right) }, size: 38,
                                         flash: keyFlashCommand == .right)
                        }
                        RemoteButton(label: "chevron.down",  action: { connection.send(.down) },  size: 38,
                                     flash: keyFlashCommand == .down)
                    }
                    // Swipe chevrons — rendered after VStack so they sit on top.
                    // Each is offset by `swipeChevronRadius` so the glyphs sit
                    // just inside the d-pad rim at the four compass points.
                    Group {
                        SwipeChevronButton(symbol: "chevron.up.2", label: "Swipe up",
                                            flash: keyFlashSwipe == .up) {
                            connection.sendSwipe(.up)
                        }
                        .offset(y: -RemoteControlView.swipeChevronRadius)
                        SwipeChevronButton(symbol: "chevron.down.2", label: "Swipe down",
                                            flash: keyFlashSwipe == .down) {
                            connection.sendSwipe(.down)
                        }
                        .offset(y: RemoteControlView.swipeChevronRadius)
                        SwipeChevronButton(symbol: "chevron.left.2", label: "Swipe left",
                                            flash: keyFlashSwipe == .left) {
                            connection.sendSwipe(.left)
                        }
                        .offset(x: -RemoteControlView.swipeChevronRadius)
                        SwipeChevronButton(symbol: "chevron.right.2", label: "Swipe right",
                                            flash: keyFlashSwipe == .right) {
                            connection.sendSwipe(.right)
                        }
                        .offset(x: RemoteControlView.swipeChevronRadius)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    let isSleeping = connection.state == .sleeping
                    Button {
                        if connection.state == .connected {
                            connection.sleep()
                        } else if isSleeping {
                            let fresh = discovery.devices.first(where: { $0.id == device.id }) ?? device
                            connection.wakeAndConnect(to: fresh)
                        }
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 38 * 0.38, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(PressableFillStyle())
                    .noFocusRing()
                    .help(isSleeping ? "Wake" : "Sleep")
                    .offset(x: 20, y: -20)
                }

                // Back + Home — mirrors physical button positions on the Siri Remote
                HStack(spacing: 48) {
                    LabeledRemoteButton(sfSymbol: "chevron.backward", label: "Back",
                                        flash: keyFlashCommand == .menu) {
                        connection.send(.menu)
                    } longPressAction: {
                        connection.sendLongPress(.menu)
                    }
                    LabeledRemoteButton(sfSymbol: "app.fill", label: "Home",
                                        flash: keyFlashCommand == .home) {
                        connection.send(.home)
                    } longPressAction: {
                        connection.sendLongPress(.home)
                    }
                }

                // Play/Pause — centered, matching the physical remote
                RemoteButton(label: "playpause.fill", action: { connection.send(.playPause) }, size: 52,
                             flash: keyFlashCommand == .playPause)

                // Volume — side buttons on the real remote; shown as a row here
                HStack(spacing: 24) {
                    LabeledRemoteButton(sfSymbol: "speaker.minus.fill", label: "Vol −",
                                        flash: keyFlashCommand == .volumeDown) {
                        connection.send(.volumeDown)
                    }
                    LabeledRemoteButton(sfSymbol: "speaker.plus.fill", label: "Vol +",
                                        flash: keyFlashCommand == .volumeUp) {
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

    /// Trigger a brief press-style flash on the on-screen button matching `cmd`.
    /// Captures the value into the closure so a rapid second key event (which
    /// overwrites `keyFlashCommand`) doesn't get its flash truncated by the
    /// first event's pending reset.
    private func flashKey(_ cmd: RemoteCommand) {
        keyFlashCommand = cmd
        let captured = cmd
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyFlashDuration) {
            if keyFlashCommand == captured { keyFlashCommand = nil }
        }
    }

    private func flashKeySwipe(_ dir: SwipeDirection) {
        keyFlashSwipe = dir
        let captured = dir
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyFlashDuration) {
            if keyFlashSwipe == captured { keyFlashSwipe = nil }
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
        case .sleeping:           return .gray
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
///   return      — select (D-pad centre, hold for long-press)
///   esc         — menu / back (hold for long-press)
///   space       — play / pause
///   ⌃A          — show app grid
///   ⌃H          — home (hold for Control Center)
///   ⌃M          — menu / back (hold long-press)
///   ⌃P          — play / pause
///   delete      — backspace (when ATV text field is focused)
///   PgUp PgDn   — volume up / down
///   ⇧↑ ⇧↓ ⇧← ⇧→ — trackpad swipe
///
/// The letter shortcuts require Control because bare letters were too easy
/// to fire accidentally when remote-pane focus drifted while the user was
/// typing in another window.
///
/// Other ⌘/⌃/⌥ shortcuts pass through so app-level commands (⌘Q, ⌘W, ⌘,)
/// keep working.
private struct KeyCatcher: NSViewRepresentable {
    let onCommand: (RemoteCommand) -> Void
    var onLongCommand: (RemoteCommand) -> Void = { _ in }
    /// Fires (cmd, true) on the first non-repeat keyDown of a long-press-able
    /// command, and (cmd, false) when the key is released. Lets the parent
    /// drive a sustained press visual that mirrors a held mouse click.
    var onPressingChanged: (RemoteCommand, Bool) -> Void = { _, _ in }
    var onSwipe: (SwipeDirection) -> Void = { _ in }
    var onShowApps: () -> Void = {}
    var onBackspace: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = KeyCatcherView()
        v.onCommand = onCommand
        v.onLongCommand = onLongCommand
        v.onPressingChanged = onPressingChanged
        v.onSwipe = onSwipe
        v.onShowApps = onShowApps
        v.onBackspace = onBackspace
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCatcherView)?.onCommand = onCommand
        (nsView as? KeyCatcherView)?.onLongCommand = onLongCommand
        (nsView as? KeyCatcherView)?.onPressingChanged = onPressingChanged
        (nsView as? KeyCatcherView)?.onSwipe = onSwipe
        (nsView as? KeyCatcherView)?.onShowApps = onShowApps
        (nsView as? KeyCatcherView)?.onBackspace = onBackspace
    }
}

private final class KeyCatcherView: NSView {
    var onCommand: (RemoteCommand) -> Void = { _ in }
    var onLongCommand: (RemoteCommand) -> Void = { _ in }
    var onPressingChanged: (RemoteCommand, Bool) -> Void = { _, _ in }
    var onSwipe: (SwipeDirection) -> Void = { _ in }
    var onShowApps: () -> Void = {}
    var onBackspace: (() -> Void)? = nil

    /// Long-press tracking for keys whose UI buttons support a hold gesture:
    /// Home (⌃H), Menu (⌃M and Esc), Select (Return/Enter). The first
    /// non-repeat keyDown schedules a 0.4s DispatchWorkItem; if the user
    /// releases first we cancel it and fire `onCommand`, otherwise the work
    /// item fires `onLongCommand` and the eventual keyUp is consumed without
    /// re-firing. Without this, holding `H` produces a stream of auto-repeat
    /// keyDowns and the long-press behaviour (Control Center) never triggers.
    private var pressedKeyCode: UInt16?
    private var pressedCommand: RemoteCommand?
    private var longPressItem: DispatchWorkItem?
    private var longPressFired = false

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

    override func resignFirstResponder() -> Bool {
        // Steal focus back on the next tick whenever something else (a SwiftUI
        // button receiving Tab focus) tries to take it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Swallow Tab/Shift-Tab so they never reach SwiftUI's focus engine
        // and shift keyboard focus away from this view.
        if event.keyCode == 48 { return }

        // `mods` excludes shift on purpose — shift is a modifier we own (for
        // swipe shortcuts) but never combines with ⌘/⌃/⌥ in our bindings.
        // Tracking it separately keeps the bail-out check below uncluttered.
        let mods  = event.modifierFlags.intersection([.command, .control, .option])
        let shift = event.modifierFlags.contains(.shift)

        // ⇧↑↓←→ → trackpad swipe (plain shift only — no ⌘⇧, ⌃⇧, ⌥⇧).
        if shift, mods.isEmpty {
            switch event.keyCode {
            case 126: onSwipe(.up);    return
            case 125: onSwipe(.down);  return
            case 123: onSwipe(.left);  return
            case 124: onSwipe(.right); return
            default:  break
            }
        }

        // ⌃ + letter shortcuts. Bare letters used to fire commands but were
        // too easy to send accidentally if remote-pane focus drifted while
        // the user was typing elsewhere. Now require Control.
        if mods == .control, !shift {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                if !event.isARepeat { onShowApps() }
                return
            case "h":
                handleHoldableKey(.home, event: event)
                return
            case "m":
                handleHoldableKey(.menu, event: event)
                return
            case "p":
                onCommand(.playPause)
                return
            default:
                break  // any other ⌃-letter falls through to system handling
            }
        }

        // Let other ⌘/⌃/⌥ shortcuts reach the menu bar and other handlers.
        if !mods.isEmpty { super.keyDown(with: event); return }

        // Backspace while ATV has a text field focused — delete last character.
        if event.keyCode == 51, let handler = onBackspace {
            handler()
            return
        }
        // Bare arrows / Return / Space / Esc / PgUp / PgDn.
        if let cmd = bareCommand(for: event) {
            // Return (select) and Esc (menu) support long-press —
            // handleHoldableKey gates auto-repeat and schedules the timer.
            if cmd == .select || cmd == .menu {
                handleHoldableKey(cmd, event: event)
                return
            }
            // Auto-repeat fires repeatedly — useful so holding ↑ scrolls
            // a tvOS list smoothly.
            onCommand(cmd)
            return
        }
        super.keyDown(with: event)
    }

    /// Begin press tracking on the first non-repeat keyDown of a holdable
    /// key (⌃H, ⌃M, Return, Esc). Auto-repeat keyDowns are no-ops — the
    /// release in `keyUp` is what fires `onCommand` or the work item what
    /// fires `onLongCommand`.
    private func handleHoldableKey(_ cmd: RemoteCommand, event: NSEvent) {
        if event.isARepeat { return }
        startPressTracking(cmd: cmd, keyCode: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        guard pressedKeyCode == event.keyCode, let cmd = pressedCommand else {
            super.keyUp(with: event)
            return
        }
        longPressItem?.cancel()
        longPressItem = nil
        let fired = longPressFired
        pressedKeyCode = nil
        pressedCommand = nil
        longPressFired = false
        // Clear the press visual BEFORE firing onCommand. Order matters: the
        // tap-release path then re-flashes via onCommand → flashKey for the
        // brief tap ack, while the long-press path (already-fired) just clears.
        onPressingChanged(cmd, false)
        if !fired { onCommand(cmd) }
    }

    private func startPressTracking(cmd: RemoteCommand, keyCode: UInt16) {
        longPressItem?.cancel()
        pressedKeyCode = keyCode
        pressedCommand = cmd
        longPressFired = false
        onPressingChanged(cmd, true)
        // Capture cmd locally so a delayed item firing after a fast re-press
        // can't fire with the wrong (newly-pressed) command.
        let cmdToFire = cmd
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.longPressFired = true
            self.onLongCommand(cmdToFire)
        }
        longPressItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Bare-modifier keys: arrows, Return, Space, Page Up/Down. Letters are
    /// handled in the ⌃-letter branch above and are NOT returned here.
    private func bareCommand(for event: NSEvent) -> RemoteCommand? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .select          // return, keypad enter
        case 53: return .menu               // escape
        case 49: return .playPause           // space
        case 116: return .volumeUp           // Page Up
        case 121: return .volumeDown         // Page Down
        default: return nil
        }
    }
}

// MARK: - Reusable button components

struct RemoteButton: View {
    let label: String
    let action: () -> Void
    var size: CGFloat = 44
    /// Externally-driven press visual — used by `RemoteControlView` to flash
    /// the button when its keyboard shortcut fires.
    var flash: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: label)
                .font(.system(size: size * 0.38, weight: .medium))
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(PressableFillStyle(externalPressed: flash))
        .noFocusRing()
    }
}

/// Press feedback for filled circular/rounded buttons (RemoteButton, SelectButton).
/// Mirrors `.plain`'s subtle dim on press AND honours an externally-driven
/// `externalPressed` so keyboard shortcuts flash the same as mouse presses.
private struct PressableFillStyle: ButtonStyle {
    var externalPressed: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || externalPressed
        return configuration.label
            .opacity(pressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

/// Small chevron button positioned at a compass point inside the d-pad rim.
/// Uses `PressableChevronStyle` so the glyph dims and shrinks on press —
/// `.buttonStyle(.plain)` would render dead. The `label` becomes the hover
/// tooltip — the chevrons read as decoration without it.
struct SwipeChevronButton: View {
    let symbol: String
    let label: String
    var flash: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(PressableChevronStyle(externalPressed: flash))
        .noFocusRing()
        .overlay(
            DelayedTooltip(text: label, delay: 0.4)
                .allowsHitTesting(false)
        )
    }
}

/// Press feedback for chevron-style accent buttons that don't have their own
/// background. Default `.plain` style on macOS gives no visual on press.
/// `externalPressed` lets a keyboard-shortcut flash drive the same visual.
private struct PressableChevronStyle: ButtonStyle {
    var externalPressed: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || externalPressed
        return configuration.label
            .scaleEffect(pressed ? 0.85 : 1.0)
            .opacity(pressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.1), value: pressed)
    }
}

struct SelectButton: View {
    let action: () -> Void
    var size: CGFloat = 52
    var flash: Bool = false
    var longPressAction: (() -> Void)? = nil

    @State private var isPressed = false
    @State private var longPressFired = false

    var body: some View {
        // Custom gesture-driven button — the Circle isn't an AppKit Button so
        // we provide the a11y traits explicitly. The long-press path is
        // surfaced as a custom action so VoiceOver users can invoke it from
        // the rotor menu without having to physically hold the gesture.
        let content = Circle()
            .fill(.primary)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .fill(Color.black.opacity((isPressed || flash) ? 0.15 : 0))
                    .animation(.easeOut(duration: 0.1), value: isPressed || flash)
            )
            .noFocusRing()
            .accessibilityElement()
            .accessibilityLabel("Select")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }

        if let longPress = longPressAction {
            content
                .accessibilityAction(named: Text("Long Press")) { longPress() }
                .onLongPressGesture(
                    minimumDuration: 0.4,
                    perform: {
                        longPressFired = true
                        longPress()
                    },
                    onPressingChanged: { pressing in
                        isPressed = pressing
                        if !pressing {
                            if !longPressFired { action() }
                            longPressFired = false
                        }
                    }
                )
        } else {
            content.onLongPressGesture(
                minimumDuration: 0.001,
                perform: action,
                onPressingChanged: { isPressed = $0 }
            )
        }
    }
}

struct LabeledRemoteButton: View {
    let sfSymbol: String
    let label: String
    var flash: Bool = false
    let action: () -> Void
    var longPressAction: (() -> Void)? = nil

    @State private var isPressed = false
    /// Set true when the long-press gesture meets its minimum duration. The
    /// release handler reads it to decide whether `action()` should also fire
    /// (it shouldn't, if a long-press already succeeded — otherwise the tap's
    /// quick down/up collapses the held press into a short tap on the ATV).
    @State private var longPressFired = false

    var body: some View {
        let dim = isPressed || flash
        // Custom gesture-driven button — the Image isn't an AppKit Button so
        // we provide the a11y traits explicitly. The long-press path is
        // surfaced as a custom action so VoiceOver users can invoke it from
        // the rotor menu without having to physically hold the gesture.
        let content = Image(systemName: sfSymbol)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 52, height: 44)
            .background(.quaternary.opacity(dim ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.1), value: dim)
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }

        if let longPress = longPressAction {
            // Long-press path: fire action() on release if the long-press
            // threshold wasn't reached, or longPress() if it was. longPressFired
            // guards against a spurious action() firing after a successful hold.
            content
                .accessibilityAction(named: Text("Long Press")) { longPress() }
                .onLongPressGesture(
                    minimumDuration: 0.4,
                    perform: {
                        longPressFired = true
                        longPress()
                    },
                    onPressingChanged: { pressing in
                        isPressed = pressing
                        if !pressing {
                            if !longPressFired { action() }
                            longPressFired = false
                        }
                    }
                )
        } else {
            // No long-press behaviour: fire on press and dim while held.
            content.onLongPressGesture(
                minimumDuration: 0.001,
                perform: action,
                onPressingChanged: { isPressed = $0 }
            )
        }
    }
}

private extension View {
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
