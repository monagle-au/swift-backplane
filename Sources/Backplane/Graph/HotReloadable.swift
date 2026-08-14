//
//  HotReloadable.swift
//  swift-backplane
//

import Configuration

/// Optional protocol for services that support in-place reconfiguration.
///
/// When ``ServiceGraph/reload(at:)`` is called for an entry whose service
/// conforms to ``HotReloadable``, the graph calls ``reload(config:)``
/// instead of starting a new generation, passing the entry-scoped
/// `ConfigReader` — the same reader the factory saw. The service is
/// responsible for atomic application of the new configuration (e.g.
/// swapping a TLS context, changing a logger level, updating a
/// feature-flag table) — no new generation is created, no shutdown of
/// the old instance.
///
/// If ``reload(config:)`` throws, the graph transitions the entry to
/// ``ServiceState/degraded(fault:)`` and leaves the existing instance in
/// place. Escalation to full replacement is the operator's call via
/// ``ServiceGraph/restart(at:)`` — the graph does not auto-escalate.
///
/// Thread safety: ``reload(config:)`` runs while the service is
/// `.running`. If the service is an actor, the call is actor-isolated.
/// If the service is a `Sendable` class, the graph serialises the call
/// through the detached task that drives it.
public protocol HotReloadable: ManagedService {
    /// Apply new configuration in place.
    ///
    /// - Parameter config: reader scoped to the entry's id — the same
    ///   scope the factory received via ``BackplaneContext/config``.
    ///   When the graph was constructed without a config, an empty
    ///   reader is passed (every key reads as absent).
    func reload(config: ConfigReader) async throws
}
