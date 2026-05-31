//
//  ServiceHealthReporter.swift
//  swift-backplane
//

/// Self-report channel for a running service to signal its own degradation.
///
/// Distinct from ``ServiceLifecycleHandle`` (read-only, consumer-side).
/// The two protocols are split so a service cannot accidentally observe
/// its own state through the same handle it reports on — and so the
/// reporter can carry write-only methods without confusing the
/// observer's API surface.
///
/// Both methods are `nonisolated`. State lives behind the per-entry
/// mutex (the same one that protects lifecycle state and the active
/// generation pointer); a service reporting health from a hot path
/// pays no actor hop. State-stream subscribers are notified after the
/// mutex is released — nested locking does not occur.
///
/// **Semantics:**
/// - ``markDegraded(fault:)`` transitions the entry from a
///   resolution-ready state (`.starting`, `.running`, `.degraded`,
///   `.replacing`) to `.degraded(fault:)`. No-op for any other state —
///   a service mid-shutdown or already `.failed` cannot drag the entry
///   back into `.degraded`.
/// - ``markHealthy()`` transitions the entry from `.degraded` back to
///   `.running`. No-op for any other state — `markHealthy` cannot
///   promote a service out of `.failed` or `.stopped`.
public protocol ServiceHealthReporter: Sendable {
    nonisolated func markDegraded(fault: ServiceFault)
    nonisolated func markHealthy()
}

// MARK: - ServiceEntryHealthReporter

/// Concrete ``ServiceHealthReporter`` backed by a weak reference to the
/// owning ``ServiceGraph``. Avoids the retain cycle that a strong
/// reference would create through the entry's stored service instance.
/// Once the consumer releases the graph, the entire tree deallocates
/// cleanly.
///
/// `@unchecked Sendable`: `weak var graph` is mutated atomically by the
/// runtime when the referent deallocates; strict-concurrency checking
/// doesn't know that, so the `@unchecked` is the minimal annotation.
/// Same pattern as ``ServiceEntryLifecycleHandle``.
package final class ServiceEntryHealthReporter: ServiceHealthReporter, @unchecked Sendable {
    package let entryID: String
    private weak var graph: ServiceGraph?

    package init(entryID: String, graph: ServiceGraph) {
        self.entryID = entryID
        self.graph = graph
    }

    package func markDegraded(fault: ServiceFault) {
        graph?.markDegraded(entryID: entryID, fault: fault)
    }

    package func markHealthy() {
        graph?.markHealthy(entryID: entryID)
    }
}
