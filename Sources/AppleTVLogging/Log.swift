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
    public nonisolated(unsafe) static var verbose: Bool = false

    /// Active log sinks, keyed by forwarder identity.
    /// Fan-out: every active LogForwarder receives every message.
    /// Access must be serialised via `_lock`.
    public nonisolated(unsafe) static var _sinks: [UUID: (String) -> Void] = [:]
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
        let sinks = Log._lock.withLock { Array(Log._sinks.values) }
        sinks.forEach { $0("[trace] \(message)") }
    }

    /// Routine state transitions and user-visible progress.
    /// Emitted at `.notice` level; always visible in `log stream`.
    func report(_ message: String) {
        self.notice("\(message, privacy: .public)")
        if Log.verbose { fputs("[info]  \(message)\n", stderr) }
        let sinks = Log._lock.withLock { Array(Log._sinks.values) }
        sinks.forEach { $0("[info]  \(message)") }
    }

    /// Errors and unexpected conditions. Always visible; persisted.
    func fail(_ message: String) {
        self.error("\(message, privacy: .public)")
        if Log.verbose { fputs("[error] \(message)\n", stderr) }
        let sinks = Log._lock.withLock { Array(Log._sinks.values) }
        sinks.forEach { $0("[error] \(message)") }
    }
}

/// RAII log forwarder. Installs a sink on `Log` for its lifetime; removes it on deinit.
/// Multiple forwarders can be active simultaneously — all receive every message.
public final class LogForwarder {
    private let key: UUID
    public init(_ sink: @escaping (String) -> Void) {
        key = UUID()
        Log._lock.withLock { Log._sinks[key] = sink }
    }
    deinit {
        Log._lock.withLock { Log._sinks[key] = nil }
    }
}
