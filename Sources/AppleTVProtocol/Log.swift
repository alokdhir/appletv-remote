import Foundation
import os

/// Centralized os.Logger instances keyed by subsystem category.
///
/// Three convenience levels are provided via the `Logger` extension:
///   • `trace(_:)`  — verbose per-frame traces; filtered in release by default.
///   • `report(_:)` — routine state transitions; visible in `log stream` by default.
///   • `fail(_:)`   — errors and unexpected conditions.
///
/// To see `trace` output in a release build, either:
///   • toggle per-boot via the log CLI:
///       sudo log config --subsystem com.adhir.appletv-remote --mode "level:debug"
///   • stream ad-hoc with a higher level filter:
///       log stream --subsystem com.adhir.appletv-remote --level debug
public enum Log {
    private static let subsystem = "com.adhir.appletv-remote"

    public static let companion   = Logger(subsystem: subsystem, category: "companion")
    public static let pairing     = Logger(subsystem: subsystem, category: "pairing")
    public static let discovery   = Logger(subsystem: subsystem, category: "discovery")
    public static let credentials = Logger(subsystem: subsystem, category: "credentials")
    public static let wol         = Logger(subsystem: subsystem, category: "wol")
    public static let app         = Logger(subsystem: subsystem, category: "app")
}

public extension Logger {
    /// Verbose trace — frame-level byte counts, hex dumps, chatty protocol traces.
    /// Emitted at `.debug` level; filtered out of default log stream output.
    func trace(_ message: String) {
        self.debug("\(message, privacy: .public)")
    }

    /// Routine state transitions and user-visible progress.
    /// Emitted at `.notice` level; always visible in `log stream`.
    func report(_ message: String) {
        self.notice("\(message, privacy: .public)")
    }

    /// Errors and unexpected conditions. Always visible; persisted.
    func fail(_ message: String) {
        self.error("\(message, privacy: .public)")
    }
}
