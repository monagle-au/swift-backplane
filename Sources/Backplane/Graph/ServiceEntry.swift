//
//  ServiceEntry.swift
//  swift-backplane
//

import Synchronization

/// One registered service entry. Owns the entry-level lifecycle state,
/// the active generation pointer, draining generations, and stream
/// subscribers.
///
/// All mutable state lives behind a single `Mutex<State>`. This is the
/// per-entry mutex pattern described in `docs/design/backplane.md`
/// §6: synchronous access to per-entry state without an actor hop.
/// `nonisolated` methods on the entry read/write through this lock.
package final class ServiceEntry: Sendable {

    // MARK: - Bundled state

    private struct State {
        var lifecycleState: ServiceState = .unconfigured
        /// The currently-active generation. ``ServiceGraph/resolve(_:)`` reads this.
        var active: Generation?
        /// Generations waiting to drain before their ``ManagedService/shutdown()`` runs.
        var draining: [Generation] = []
        /// Continuations for state-stream subscribers. Keyed by subscriber id.
        var continuations: [UInt64: AsyncStream<ServiceState>.Continuation] = [:]
        /// Monotonically increasing generation ID counter.
        var generationCounter: UInt64 = 0
        /// The in-flight replacement task, if any. Cancelling it aborts
        /// an in-progress swap.
        var replacementTask: Task<Void, Never>?
        /// Subscriber counter for unique continuation IDs without UUID
        /// allocation.
        var subscriberCounter: UInt64 = 0
        /// Lazily-allocated lifecycle handle. Shared across all callers of
        /// ``lifecycle(in:)``.
        var lifecycleHandle: (any ServiceLifecycleHandle)?
    }

    private let _state: Mutex<State>

    package let descriptor: EntryDescriptor

    package init(descriptor: EntryDescriptor) {
        self.descriptor = descriptor
        self._state = Mutex(State())
    }

    // MARK: - Read API (nonisolated — uses mutex)

    package var currentState: ServiceState {
        _state.withLock { $0.lifecycleState }
    }

    /// Return the live instance cast to `T`, or nil.
    ///
    /// Returns non-nil during `.starting`, `.running`, `.degraded`, and
    /// `.replacing` (the old generation serves throughout a blue-green
    /// swap). Returns nil during `.unconfigured`, `.stopped`, and
    /// `.failed` — and during a cold-restart gap, where the entry is
    /// `.replacing` but the active generation has been taken.
    ///
    /// The state filter matters because `active` is set *before*
    /// `start()` runs (swap-before-notify ordering — see
    /// `docs/design/backplane.md` §7 "Swap-and-notify ordering"):
    /// a `.failed` entry whose `start()` threw still has `active`
    /// pointing at the failed instance until the failure transition
    /// runs. Filtering by state ensures consumers don't observe a
    /// service that the graph considers terminally failed.
    package func currentHandle<T: Sendable>(_ type: T.Type) -> T? {
        _state.withLock { state in
            guard let active = state.active else { return nil }
            guard Self.isResolutionReady(state.lifecycleState) else { return nil }
            // Project the managed instance to the key's resolved value
            // before casting. Identity for Form 1, unwrap for Form 2,
            // upcast for Form 3 — see ``EntryDescriptor/project``.
            return descriptor.project(active.instance) as? T
        }
    }

    /// Type-erased counterpart to ``currentHandle(_:)``. Returns the
    /// active generation's instance as `any ManagedService` when the
    /// entry's state is resolution-ready, nil otherwise.
    ///
    /// Used by ``ServiceGraphEntryAdapter`` which doesn't know the
    /// concrete service type at adapter-construction time.
    package func currentManagedService() -> (any ManagedService)? {
        _state.withLock { state in
            guard let active = state.active else { return nil }
            return Self.isResolutionReady(state.lifecycleState) ? active.instance : nil
        }
    }

    /// Resolution-ready states share the same filter for both
    /// ``currentHandle(_:)`` and ``currentManagedService()``.
    private static func isResolutionReady(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .running, .degraded, .replacing:
            return true
        case .unconfigured, .stopped, .failed:
            return false
        }
    }

    // MARK: - Lifecycle state transitions

    /// Update the entry's lifecycle state and notify all stream
    /// subscribers.
    ///
    /// Yield while holding the state lock so concurrent transitions are
    /// delivered in the same order in which they update the state. AsyncStream
    /// continuations only enqueue here; they do not run subscriber code.
    package func transition(to newState: ServiceState) {
        _state.withLock { s in
            s.lifecycleState = newState
            for continuation in s.continuations.values {
                continuation.yield(newState)
            }
        }
    }

    // MARK: - Self-reported health (ServiceHealthReporter backing)

    /// Conditional transition from a resolution-ready state to
    /// `.degraded(fault:)`. No-op for any other current state. Used by
    /// the entry's own service via
    /// ``ServiceHealthReporter/markDegraded(fault:)``. Routing through
    /// ``ServiceGraph/resolve(_:)`` is unaffected.
    package func markDegraded(fault: ServiceFault) {
        _state.withLock { s in
            guard Self.isResolutionReady(s.lifecycleState) else { return }
            s.lifecycleState = .degraded(fault: fault)
            for continuation in s.continuations.values {
                continuation.yield(.degraded(fault: fault))
            }
        }
    }

    /// Conditional transition `.degraded` → `.running`. No-op for any
    /// other current state — `markHealthy` cannot promote a service
    /// out of `.failed`, `.stopped`, or any other non-degraded state.
    /// Used by the entry's own service via
    /// ``ServiceHealthReporter/markHealthy()``.
    package func markHealthy() {
        _state.withLock { s in
            guard case .degraded = s.lifecycleState else { return }
            s.lifecycleState = .running
            for continuation in s.continuations.values {
                continuation.yield(.running)
            }
        }
    }

    // MARK: - Generation management

    /// Allocate the next monotonic generation ID.
    package func nextGenerationID() -> UInt64 {
        _state.withLock { s in
            s.generationCounter += 1
            return s.generationCounter
        }
    }

    /// Atomically swap the active generation to `new`.
    ///
    /// The old generation (if any) is moved to the draining list and
    /// its per-generation state set to `.draining`. Returns the old
    /// generation so the caller can schedule the drain task.
    package func swapActiveGeneration(to new: Generation) -> Generation? {
        _state.withLock { s in
            let old = s.active
            new.state.withLock { $0 = .running }
            s.active = new
            if let old {
                old.state.withLock { $0 = .draining }
                s.draining.append(old)
            }
            return old
        }
    }

    /// Take the active generation out of service without a replacement.
    ///
    /// The generation moves to the draining list (per-generation state
    /// `.draining`) and `active` becomes nil, so ``currentHandle(_:)``
    /// returns nil — the intentional cold-restart gap. Returns the taken
    /// generation so the caller can drive its drain, or nil if nothing
    /// was active.
    package func takeActiveGeneration() -> Generation? {
        _state.withLock { s in
            guard let old = s.active else { return nil }
            s.active = nil
            old.state.withLock { $0 = .draining }
            s.draining.append(old)
            return old
        }
    }

    /// Remove a drained generation from the draining list.
    package func removeDraining(_ generation: Generation) {
        _state.withLock { s in
            s.draining.removeAll { $0 === generation }
        }
    }

    // MARK: - Replacement task bookkeeping

    /// Swap in a new in-flight replacement task; return the previous one.
    ///
    /// The caller should cancel the returned task to enforce "latest
    /// restart wins" semantics.
    @discardableResult
    package func swapReplacementTask(_ task: Task<Void, Never>?) -> Task<Void, Never>? {
        _state.withLock { s in
            let previous = s.replacementTask
            s.replacementTask = task
            return previous
        }
    }

    // MARK: - Lifecycle handle (lazy)

    /// Return the lifecycle handle, constructing it on first request.
    ///
    /// The handle is cached in the entry's state so all callers receive
    /// the same instance. It holds a weak reference to the graph, so
    /// this caching does not introduce a retain cycle.
    package func lifecycle(in graph: ServiceGraph) -> any ServiceLifecycleHandle {
        _state.withLock { s in
            if let existing = s.lifecycleHandle { return existing }
            let handle = ServiceEntryLifecycleHandle(entryID: descriptor.id, graph: graph)
            s.lifecycleHandle = handle
            return handle
        }
    }

    // MARK: - State stream subscription

    /// Subscribe to lifecycle state transitions.
    ///
    /// The stream yields the current state immediately (replay-first
    /// semantic), then every subsequent transition until the stream is
    /// cancelled.
    package func stateStream() -> AsyncStream<ServiceState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let subID = _state.withLock { s -> UInt64 in
                s.subscriberCounter += 1
                let id = s.subscriberCounter
                s.continuations[id] = continuation
                // Register and replay atomically with transitions. Otherwise
                // a transition can enqueue its new value after registration
                // but before this older replay, leaving subscribers stale.
                continuation.yield(s.lifecycleState)
                return id
            }
            continuation.onTermination = { [weak self] _ in
                self?._state.withLock { $0.continuations[subID] = nil }
            }
        }
    }
}
