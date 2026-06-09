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
    /// True once the first successful `.connected` has been observed.
    /// Published so the view can suppress the connect-prompt flash on
    /// transient disconnects before `isReconnecting` is set.
    @Published var hasEverConnected = false

    deinit {
        retryTask?.cancel()
    }

    private var cancellable: AnyCancellable?
    private var retryTask:   Task<Void, Never>?
    private var retryCount  = 0
    // Exponential backoff schedule. retryCount indexes this array; once we
    // pass the end we keep using the last delay. The first attempt is
    // cheap (250 ms) so the common case — ATV drops the idle Companion
    // socket at ~30 s and pair-verify recovers in ~70 ms — still feels
    // instant. Later attempts back off to ride out longer outages
    // (ATV-side service restart, network blip, brief Wi-Fi reattach).
    //
    // Total budget: ~61 s across 8 attempts. Previously 3 attempts × 250 ms
    // gave up after under a second of true unavailability, which left the
    // app stuck in error-with-no-retry whenever the ATV briefly refused
    // Companion connections (observed: ATV closes socket, refuses for
    // ~10–20 s, then accepts again — old code surrendered way before).
    private let backoffSchedule: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 15, 30]
    private var maxRetries: Int { backoffSchedule.count }

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
                case .sleeping:
                    // User put the ATV to sleep intentionally — clear retry
                    // budget and stay quiet until the user explicitly wakes
                    // the device (which transitions through .connecting).
                    self.retryCount = 0
                    self.retryTask?.cancel()
                    self.retryTask = nil
                    self.isReconnecting = false
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
                        // No device or user disconnected — clear the footer
                        // so the connect prompt doesn't show stale metadata.
                        // (User disconnect already cleared via disconnect();
                        // this is a defensive idempotent reset.)
                        connection.resetNowPlayingState()
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
        // retryCount has been bumped by every prior in-flight attempt that
        // settled into a .disconnected/.error before the next .connected.
        // Use it to index the backoff schedule for the *upcoming* attempt.
        let index = min(self.retryCount, backoffSchedule.count - 1)
        let delay = backoffSchedule[index]
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
                // Reconnect won't happen — clear the footer so we stop
                // showing what was playing when the ATV was last reachable.
                connection.resetNowPlayingState()
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
            Log.companion.report("AutoReconnector: connecting (attempt \(attempt)/\(self.maxRetries), delay=\(delay)s)")
            connection.wakeAndConnect(to: target)
            self.retryTask = nil
        }
    }
}
