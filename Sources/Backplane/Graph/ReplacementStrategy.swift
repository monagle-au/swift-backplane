//
//  ReplacementStrategy.swift
//  swift-backplane
//

/// How the ``ServiceGraph`` replaces a service when it is restarted.
///
/// The default is ``blueGreen(grace:)`` with a 30-second grace period. Most
/// services should accept this default. Override when the service
/// exclusively owns a resource that prevents two instances coexisting.
public enum ReplacementStrategy: Sendable {
    /// Start a new generation alongside the old; atomically swap the
    /// active pointer once the new generation's ``ManagedService/start()``
    /// returns; drain the old generation for up to `grace` before
    /// calling ``ManagedService/shutdown()`` on it.
    ///
    /// **Default.** Eliminates the service-unavailable window that would
    /// otherwise require sentinel machinery on the consumer side.
    case blueGreen(grace: Duration)

    /// Apply new configuration in place — no new generation, no swap.
    /// Requires the service to conform to ``HotReloadable``. If it does
    /// not, the graph logs a warning and falls back to ``blueGreen(grace:)``.
    case hotReload

    /// Shut the old instance down before starting the new one.
    /// Callers landing in the gap receive nil from
    /// ``ServiceGraph/resolve(_:)``. Use only when two instances cannot
    /// coexist (bound TCP ports, exclusive file locks, single-writer
    /// database connections).
    case coldRestart
}
