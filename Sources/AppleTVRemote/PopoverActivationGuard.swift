import Foundation
import AppKit

/// Stamps the time whenever the app becomes active. SwiftUI views check this
/// to suppress the first tap that activates the popover window, matching the
/// standard AppKit `acceptsFirstMouse = false` behavior that NSPopover bypasses.
///
/// @MainActor ensures lastActivation is only read/written on the main thread,
/// eliminating the data race between AppKit notifications and SwiftUI renders.
@MainActor
final class PopoverActivationGuard {
    static let shared = PopoverActivationGuard()

    private(set) var lastActivation: Date = .distantPast
    private let guardWindow: TimeInterval = 0.35

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lastActivation = Date() }
        }
    }

    var isActivationClick: Bool {
        Date().timeIntervalSince(lastActivation) < guardWindow
    }
}
