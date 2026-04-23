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
///   • set `Log.verbose = true` to mirror all output to stderr (used by `atv --verbose`)
public enum Log {
    private static let subsystem = "com.adhir.appletv-remote"

    /// When true, all trace/report/fail messages are also written to stderr.
    public static var verbose: Bool = false

    /// Optional sink called (in addition to os_log and stderr) for every message.
    /// Set by `LogForwarder`; nil when no forwarder is active.
    /// Access must be serialised — callers hold the main actor lock or use `logLock`.
    public static var _sink: ((String) -> Void)? = nil
    public static let _lock = NSLock()

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
        if Log.verbose { fputs("[trace] \(message)\n", stderr) }
        Log._lock.withLock { Log._sink?("[trace] \(message)") }
    }

    /// Routine state transitions and user-visible progress.
    /// Emitted at `.notice` level; always visible in `log stream`.
    func report(_ message: String) {
        self.notice("\(message, privacy: .public)")
        if Log.verbose { fputs("[info]  \(message)\n", stderr) }
        Log._lock.withLock { Log._sink?("[info]  \(message)") }
    }

    /// Errors and unexpected conditions. Always visible; persisted.
    func fail(_ message: String) {
        self.error("\(message, privacy: .public)")
        if Log.verbose { fputs("[error] \(message)\n", stderr) }
        Log._lock.withLock { Log._sink?("[error] \(message)") }
    }
}

/// RAII log forwarder. Installs a sink on `Log` for its lifetime; removes it on deinit.
/// Only one forwarder can be active at a time (last writer wins).
public final class LogForwarder {
    public init(_ sink: @escaping (String) -> Void) {
        Log._lock.withLock { Log._sink = sink }
    }
    deinit {
        Log._lock.withLock { Log._sink = nil }
    }
}
