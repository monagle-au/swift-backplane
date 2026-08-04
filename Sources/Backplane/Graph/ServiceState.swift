//
//  ServiceState.swift
//  swift-backplane
//

/// Entry-level lifecycle state of a registered service.
///
/// Transitions are driven by the ``ServiceGraph``. The state aggregates
/// across all active generations — during a blue-green swap the entry
/// reports ``replacing`` rather than exposing per-generation detail.
///
/// `Hashable` so state values can be emitted over `AsyncStream`s with
/// backpressure and deduplicated by stream subscribers.
public enum ServiceState: Sendable, Hashable {
    /// Entry declared but no usable configuration available.
    case unconfigured

    /// First instance is constructing; ``ManagedService/start()`` is
    /// running. The active-generation pointer is already populated, so
    /// resolves landing during ``starting`` see the new instance (this
    /// is the boot-deadlock fix — see the design note §5
    /// "Swap-and-notify ordering").
    case starting

    /// Operational — at least one generation is serving.
    case running

    /// Running but reporting a transient fault via ``ServiceHealthReporter``.
    /// Routing is unchanged; the live instance keeps serving.
    case degraded(fault: ServiceFault)

    /// A blue-green replacement is in flight. The old generation continues
    /// to serve ``ServiceGraph/resolve(_:)`` calls throughout.
    case replacing

    /// All generations have shut down. Restart needed.
    case stopped

    /// Unrecoverable failure. Explicit restart required.
    case failed(fault: ServiceFault)
}
