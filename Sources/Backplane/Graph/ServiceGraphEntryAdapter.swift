//
//  ServiceGraphEntryAdapter.swift
//  swift-backplane
//

import Logging
import ServiceLifecycle

/// Per-entry `ServiceLifecycle.Service` adapter.
///
/// Drives the **phase-2 lifecycle** of one entry inside the graph's
/// inner ``ServiceGroup``: calls `start()` on the live instance,
/// waits for graceful shutdown, then calls `shutdown()`. The entry's
/// lifecycle state is transitioned accordingly.
///
/// Phase 1 — factory + active-generation swap — runs in
/// ``ServiceGraph/bootPhase1Entry(_:)`` before this adapter is
/// constructed, so by the time `run()` is called the entry is already
/// in ``ServiceState/starting`` with a live handle observable via
/// ``ServiceGraph/resolve(_:)``.
///
/// The adapter is `Sendable` because all of its stored properties are:
/// ``ServiceEntry`` is a `Sendable` final class, and ``Logger`` is
/// `Sendable`.
package struct ServiceGraphEntryAdapter: ServiceLifecycle.Service {
    package let entry: ServiceEntry
    package let logger: Logger?

    package init(entry: ServiceEntry, logger: Logger?) {
        self.entry = entry
        self.logger = logger
    }

    package func run() async throws {
        // Phase 1 must already have stashed the instance and swapped
        // the active generation. If the handle is nil here, the graph
        // has a bug. Fail open — the inner group treats this slot as
        // immediately complete.
        guard let instance = entry.currentManagedService() else {
            logger?.warning(
                "Adapter run() for '\(entry.descriptor.id)' has no live instance; phase 1 must not have completed."
            )
            return
        }

        // Phase 2a: start().
        do {
            try await instance.start()
        } catch is CancellationError {
            // Shutdown arrived mid-start. This is a stop, not a fault: the
            // group is draining and this entry simply never opened. Marking
            // it `.failed` would be actively harmful, because a recovery
            // supervisor watching for `.failed` would schedule a fresh
            // factory + start() *while the process is shutting down* — an
            // instance nobody supervises, built to be abandoned. Fall
            // through to the same shutdown sequence a started service gets,
            // so a half-open connection is still closed.
            logger?.debug(
                "Adapter: '\(entry.descriptor.id)' cancelled during start() — stopping"
            )
            await instance.shutdown()
            entry.transition(to: .stopped)
            return
        } catch {
            entry.transition(to: .failed(fault: ServiceFault(from: error)))
            logger?.error(
                "Adapter start() failed for '\(entry.descriptor.id)': \(error)"
            )
            throw error
        }
        entry.transition(to: .running)
        logger?.debug("Adapter: '\(entry.descriptor.id)' is .running")

        // Phase 2b: block until the surrounding ``ServiceGroup`` signals
        // graceful shutdown OR the task is cancelled. Both paths exit
        // through the same shutdown sequence — cancellation does not
        // skip cleanup. We swallow the cancellation here and proceed
        // to ``ManagedService/shutdown()``; the adapter's contract is
        // "run() returns ⇒ shutdown() has been called."
        try? await gracefulShutdown()

        // Phase 2c: shutdown(). Async, non-throwing, expected to be
        // idempotent and bounded.
        //
        // Re-read the live instance rather than shutting down the one
        // captured at phase 2a. `restart(at:)` and `recover(at:)` build a
        // new generation and start it inline, without an adapter, so by the
        // time we get here the entry may be serving something this task has
        // never seen. Shutting down the captured value would close an
        // already-drained generation while the live one keeps its
        // connection open for the life of the process — and for an entry
        // whose shutdown releases shared claims, it would release them out
        // from under the generation still using them. Fall back to the
        // captured instance only if the entry no longer resolves.
        let live = entry.currentManagedService() ?? instance
        logger?.debug("Adapter: '\(entry.descriptor.id)' shutdown signalled — calling shutdown()")
        await live.shutdown()
        entry.transition(to: .stopped)
        logger?.debug("Adapter: '\(entry.descriptor.id)' is .stopped")
    }
}
