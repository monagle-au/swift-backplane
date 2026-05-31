//
//  HotReloadable.swift
//  swift-backplane
//

/// Optional protocol for services that support in-place reconfiguration.
///
/// When ``ServiceGraph/reload(at:)`` is called for an entry whose service
/// conforms to ``HotReloadable``, the graph calls ``reload()`` instead of
/// starting a new generation. The service is responsible for atomic
/// application of the new configuration (e.g. swapping a TLS context,
/// changing a logger level, updating a feature-flag table) — no new
/// generation is created, no shutdown of the old instance.
///
/// If ``reload()`` throws, the graph transitions the entry to
/// ``ServiceState/degraded(fault:)`` and leaves the existing instance in
/// place. Escalation to blue-green replacement is the operator's call
/// via ``ServiceGraph/restart(at:)`` — the graph does not auto-escalate.
///
/// Thread safety: ``reload()`` runs while the service is `.running`.
/// If the service is an actor, the call is actor-isolated. If the
/// service is a `Sendable` class, the graph serialises the call through
/// the detached task that drives it.
///
/// **Configuration plumbing:** the design note (§7 "HotReloadable —
/// opt-in protocol") proposes a `reload(config: ConfigReader)` signature.
/// That arrives once the production `ConfigReader` integration lands.
/// Until then real consumers capture mutable config state in their own
/// `Mutex<Config>` and re-read it inside `reload()`; the architectural
/// shape is preserved.
public protocol HotReloadable: ManagedService {
    func reload() async throws
}
