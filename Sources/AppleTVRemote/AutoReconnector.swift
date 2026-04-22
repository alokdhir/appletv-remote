import Foundation
import Combine
import AppleTVLogging
import AppleTVProtocol

// MARK: - Auto-reconnect on connection drop

/// Watches for unexpected disconnects on auto-connect devices and retries up to 3 times.
///
/// The retry is debounced: the counter only increments if the connection stays
/// in `.disconnected`/`.error` for the full `retryDelay` window. Transitions
/// into `.waking`/`.connecting`/`.awaitingPairingPin` cancel the pending retry
/// without consuming an attempt — this is what prevents the internal
/// `.waking → .disconnected → .connecting` transition in `wakeAndConnect` from
/// burning through the retry budget on every successful connect.
@MainActor
final class AutoReconnector: ObservableObject {
    /// True while an auto-reconnect cycle is in flight (between EOF and either
    /// a successful `.connected` or exhaustion of the retry budget). Consumed
    /// by `RemoteControlView` so it can keep the remote buttons on screen and
    /// only surface "Reconnecting…" in the status bar instead of flashing back
    /// to the connect prompt.
    @Published var isReconnecting: Bool = false

    deinit {
        retryTask?.cancel()
        cancellable?.cancel()
    }

    private var cancellable: AnyCancellable?
    private var retryTask:   Task<Void, Never>?
    private var retryCount  = 0
    private let maxRetries  = 3
    /// Only start surfacing the "reconnecting" UI after we've been connected
    /// at least once. Otherwise the transient `.disconnected` inside the very
    /// first `wakeAndConnect` call flips `isReconnecting` true and hides the
    /// Connecting spinner / initial error behind the remote layout.
    private var hasEverConnected = false
    // Short debounce — the ATV drops idle Companion sockets at ~30 s, and a
    // pair-verify reconnect only takes ~70 ms. Waiting 5 s here was the main
    // source of the user-visible "blip" on every idle-close cycle.
    private let retryDelay: TimeInterval = 0.25

    func setUp(connection: CompanionConnection,
               discovery: DeviceDiscovery,
               autoConnect: AutoConnectStore) {
        cancellable = connection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak connection, weak discovery] state in
                guard let self, let connection, let discovery else { return }
                switch state {
                case .connected:
                    // Success — reset counter and cancel any pending retry.
                    self.retryCount = 0
                    self.retryTask?.cancel()
                    self.retryTask = nil
                    self.isReconnecting = false
                    self.hasEverConnected = true
                case .connecting, .waking, .awaitingPairingPin:
                    // Mid-handshake — cancel any pending retry so the transient
                    // `.disconnected` that happened before this doesn't count
                    // against the retry budget.
                    self.retryTask?.cancel()
                    self.retryTask = nil
                case .disconnected, .error:
                    // Retry on any unexpected drop/failure — not just auto-connect
                    // devices. The only case we *don't* retry is a user-initiated
                    // Disconnect (via the button), which sets
                    // userInitiatedDisconnect = true on the connection.
                    guard let device = connection.currentDevice,
                          !connection.userInitiatedDisconnect else {
                        self.retryCount = 0
                        self.retryTask?.cancel()
                        self.retryTask = nil
                        self.isReconnecting = false
                        self.hasEverConnected = false
                        return
                    }
                    // If a retry is already pending, let the debounce finish.
                    if let task = self.retryTask, !task.isCancelled { return }
                    // Only surface the "reconnecting" UI once we've actually
                    // been connected at least once — otherwise the transient
                    // `.disconnected` inside the initial wakeAndConnect would
                    // hide the Connecting spinner / first-attempt error.
                    if self.hasEverConnected { self.isReconnecting = true }
                    self.scheduleRetry(device: device, connection: connection, discovery: discovery)
                }
            }
    }

    private func scheduleRetry(device: AppleTVDevice,
                               connection: CompanionConnection,
                               discovery: DeviceDiscovery) {
        let delay = retryDelay
        retryTask = Task { [weak self, weak connection, weak discovery] in
            // Debounce: sleep first, then re-check. If state flipped out of
            // .disconnected/.error during this window the sink has already
            // cancelled us — the check below short-circuits without touching
            // the counter.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self, let connection, let discovery else { return }
            guard self.retryCount < self.maxRetries else {
                Log.companion.fail("AutoReconnector: max retries reached, giving up")
                self.retryCount = 0
                self.retryTask = nil
                self.isReconnecting = false
                return
            }
            self.retryCount += 1
            let attempt = self.retryCount
            let target = discovery.devices.first { $0.id == device.id } ?? device
            guard target.host != nil else {
                Log.companion.report("AutoReconnector: device not yet resolved, skipping retry \(attempt)")
                self.retryTask = nil
                self.isReconnecting = false
                return
            }
            Log.companion.report("AutoReconnector: connecting (attempt \(attempt)/\(self.maxRetries))")
            connection.wakeAndConnect(to: target)
            self.retryTask = nil
        }
    }
}
