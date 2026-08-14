//
//  ManagedService.swift
//  swift-backplane
//

/// A service whose lifecycle is owned by a ``ServiceGraph``.
///
/// The graph calls the service's factory closure to construct an instance,
/// then calls ``start()``. On replacement, the graph starts a new generation
/// before calling ``shutdown()`` on the old one (blue-green default).
///
/// Distinct from `ServiceLifecycle.Service`, which has a single `run()` that
/// owns its task's lifetime. ``ManagedService`` uses a two-phase
/// (`start` / `shutdown`) contract; the graph owns the lifetime envelope and
/// drives an internal per-entry adapter that bridges the two.
///
/// Replacement strategy is not part of this protocol — it is declared
/// per entry on ``EntryDescriptor`` (`replacement:`), or via
/// ``BackplaneService/replacementStrategy`` for self-describing types.
public protocol ManagedService: Sendable {
    /// Begin operation. Return when the service is ready to handle requests.
    ///
    /// A throw transitions this generation to a failed state; the active
    /// (old) generation continues serving if a blue-green swap is in flight.
    /// See `docs/design/backplane.md` §7 ("Initialisation failure on
    /// replacement") for the full failure-mode taxonomy.
    func start() async throws

    /// Release resources. Called by the graph after this generation has been
    /// drained. Must complete in bounded time; the graph cancels the task
    /// after the configured shutdown timeout.
    func shutdown() async
}
