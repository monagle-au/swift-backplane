//
//  ConfigurationRequirement.swift
//  swift-backplane
//

/// Whether `.unconfigured` is a hard failure or a transient pre-config state.
///
/// Declared per ``EntryDescriptor`` because only the service author knows
/// whether their service can legitimately spend time in `.unconfigured`. A
/// Postgres client almost always needs config at boot; a vendor agent
/// awaiting an out-of-band pairing flow legitimately doesn't.
///
/// ## Current status: typed annotation; behavioural effect lands with the configuration story
///
/// In the current single-phase boot model, ``ServiceState/unconfigured`` is
/// reachable in exactly one way: "boot hasn't started for this entry yet."
/// There's no path back to `.unconfigured` after the boot pass completes,
/// so observing `.unconfigured` always means "pre-boot," which is a
/// transient state regardless of the author's intent.
///
/// The annotation becomes load-bearing when **factory-failure
/// categorisation** lands alongside the production `ConfigReader`
/// integration — the pattern where a factory throwing a typed "missing
/// config" error parks the entry at `.unconfigured` rather than
/// transitioning to `.failed`. At that point:
///
/// - ``required`` + post-boot `.unconfigured` → ``ServiceContext/requireService(_:timeout:)``
///   throws ``ServiceGraphError/entryTerminated(id:expectedType:state:)``
///   with `.unconfigured`. Config is genuinely missing for a service that
///   needs it; fail fast.
/// - ``deferred`` + post-boot `.unconfigured` → `requireService` waits.
///   Admin will configure the service at runtime.
/// - Pre-boot `.unconfigured` → wait regardless. Boot will start
///   shortly; the boot race must not produce false failures.
///
/// Shipping the annotation now lets consumers express intent that the
/// framework will start to act on later, without a semver-breaking
/// change at that point.
public enum ConfigurationRequirement: Sendable {
    /// The service must be configured at boot. Once factory-failure
    /// categorisation lands, observing post-boot `.unconfigured` will be
    /// a terminal failure for dependent callers.
    ///
    /// Default — covers cloud-service shapes (databases, HTTP servers,
    /// message queues) where missing config at boot is a startup failure.
    case required

    /// The service may be configured at runtime via an out-of-band flow
    /// (admin pairing, OAuth, commissioning). Once factory-failure
    /// categorisation lands, dependent callers will wait through
    /// `.unconfigured` for the service to be configured.
    ///
    /// Covers vendor-integration shapes.
    case deferred
}
