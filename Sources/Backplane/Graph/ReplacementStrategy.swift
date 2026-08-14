//
//  ReplacementStrategy.swift
//  swift-backplane
//

/// How the ``ServiceGraph`` replaces a service when it is restarted.
///
/// Declared per entry on ``EntryDescriptor`` (`replacement:`), or via
/// ``BackplaneService/replacementStrategy`` for self-describing service
/// types. The graph reads the strategy from the descriptor *before*
/// constructing the replacement instance.
///
/// The default is ``standard`` — blue-green with a 30-second grace
/// period. Most services should accept this default. Override with
/// ``coldRestart`` when the service exclusively owns a resource that
/// prevents two instances coexisting.
public enum ReplacementStrategy: Sendable {
    /// Start a new generation alongside the old; atomically swap the
    /// active pointer once the new generation's ``ManagedService/start()``
    /// returns; drain the old generation for up to `grace` before
    /// calling ``ManagedService/shutdown()`` on it.
    ///
    /// **Default.** Eliminates the service-unavailable window that would
    /// otherwise require sentinel machinery on the consumer side.
    case blueGreen(grace: Duration)

    /// Shut the old instance down before starting the new one.
    /// Callers landing in the gap receive nil from
    /// ``ServiceGraph/resolve(_:)``; ``ServiceGraph/requireService(_:timeout:)``
    /// callers wait through the gap. Use when two instances cannot
    /// coexist (bound TCP ports, exclusive file locks, single-writer
    /// database connections).
    ///
    /// A failure while the replacement constructs or starts leaves the
    /// entry ``ServiceState/failed(fault:)`` — nothing is serving — and
    /// recoverable via ``ServiceGraph/recover(at:)``.
    case coldRestart

    /// The package-wide default: ``blueGreen(grace:)`` with a 30-second
    /// grace period.
    public static var standard: ReplacementStrategy {
        .blueGreen(grace: .seconds(30))
    }
}
