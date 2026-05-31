//
//  ServiceLifecycleMode.swift
//  swift-backplane
//

/// Whether a command runs persistently or as a finite task.
///
/// Used by ``BackplaneCommand`` to inform the runner whether the
/// `ServiceGroup` should wait for an external termination signal
/// (``persistent``) or shut down when the command's
/// ``TaskCommand/execute(with:)`` returns (``task``).
public enum ServiceLifecycleMode: Sendable, Hashable {
    /// Services run until the process receives a termination signal.
    /// The default for ``PersistentCommand``.
    case persistent

    /// Services run while the command's ``TaskCommand/execute(with:)``
    /// is in flight, then the group shuts down gracefully.
    case task
}
