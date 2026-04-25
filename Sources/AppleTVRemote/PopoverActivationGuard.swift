import Foundation

/// Stamps the time whenever the app becomes active. SwiftUI views check this
/// to suppress the first tap that activates the popover window, matching the
/// standard AppKit `acceptsFirstMouse = false` behavior that NSPopover bypasses.
final class PopoverActivationGuard {
    static let shared = PopoverActivationGuard()
    private init() {}

    private(set) var lastActivation: Date = .distantPast
    private let window: TimeInterval = 0.35

    func stamp() { lastActivation = Date() }

    var isActivationClick: Bool {
        Date().timeIntervalSince(lastActivation) < window
    }
}
