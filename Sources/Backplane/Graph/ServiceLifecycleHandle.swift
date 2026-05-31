//
//  ServiceLifecycleHandle.swift
//  swift-backplane
//

/// Read-only view of a service entry's lifecycle.
///
/// Each registered entry in a ``ServiceGraph`` has an associated handle.
/// The handle is `Sendable` and safe to capture into closures (timer
/// callbacks, supervisor tasks, admin RPC handlers).
public protocol ServiceLifecycleHandle: Sendable {
    /// Current entry-level state.
    ///
    /// Synchronous: the per-entry state lives behind a `Mutex`, not the
    /// graph actor, so no actor hop is required. See
    /// `docs/design/backplane.md` §6 ("Per-entry mutex pattern,
    /// generalised") for the rationale.
    var state: ServiceState { get }

    /// Stream of state transitions. Each call returns a fresh
    /// ``AsyncStream`` whose first element is the current state
    /// (replay-first semantic).
    func stateStream() -> AsyncStream<ServiceState>

    /// Trigger replacement of this entry from the consumer side.
    /// Forwards to ``ServiceGraph/restart(at:)``.
    func requestRestart() async
}

// MARK: - ServiceEntryLifecycleHandle

/// Concrete ``ServiceLifecycleHandle`` backed by a weak reference to the
/// owning ``ServiceGraph``. Avoids a retain cycle (graph → entry →
/// handle → graph) — once the consumer releases the graph, the entire
/// tree deallocates cleanly.
///
/// `@unchecked Sendable`: the `weak var graph` is mutated atomically by
/// the runtime when the referent deallocates; strict-concurrency
/// checking doesn't know that, so the `@unchecked` is the minimal
/// annotation.
package final class ServiceEntryLifecycleHandle: ServiceLifecycleHandle, @unchecked Sendable {
    package let entryID: String
    private weak var graph: ServiceGraph?

    package init(entryID: String, graph: ServiceGraph) {
        self.entryID = entryID
        self.graph = graph
    }

    package var state: ServiceState {
        graph?.state(of: entryID) ?? .unconfigured
    }

    package func stateStream() -> AsyncStream<ServiceState> {
        graph?.stateStream(of: entryID) ?? AsyncStream { $0.finish() }
    }

    package func requestRestart() async {
        await graph?.restart(at: entryID)
    }
}
