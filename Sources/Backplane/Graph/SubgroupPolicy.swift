//
//  SubgroupPolicy.swift
//  swift-backplane
//

/// Policy applied to every entry in a ``SubgroupTag``-named partition.
///
/// Carries the failure mode and restartability. Completion modes
/// (`.shutdownGroup`, `.shutdownSubgroup`, `.ignore`) belong to the
/// future `ManagedTaskService` integration — see open question §11.14
/// in `docs/design/backplane.md`; they require a "task completed"
/// signal that the current `ManagedService` protocol doesn't express.
public struct SubgroupPolicy: Sendable {

    // MARK: - FailureMode

    public enum FailureMode: Sendable {
        /// A failure of any entry in this subgroup cancels in-flight boot
        /// tasks for its siblings and propagates a thrown
        /// ``ServiceGraphError/subgroupBootFailed(tag:faulted:)`` from
        /// ``ServiceGraph/boot(roots:)``.
        case failFast

        /// A failure transitions only the failing entry to
        /// ``ServiceState/failed(fault:)``. Siblings continue independently;
        /// ``ServiceGraph/boot(roots:)`` returns normally for this subgroup.
        case degraded
    }

    // MARK: - Stored properties

    public let failure: FailureMode

    /// Whether ``ServiceGraph/restart(at:)`` is honoured for entries in
    /// this subgroup. When `false`, restart requests are logged and
    /// dropped — the entry's state is not modified.
    public let restartable: Bool

    public init(failure: FailureMode, restartable: Bool) {
        self.failure = failure
        self.restartable = restartable
    }

    // MARK: - Stock policies

    /// Default policy for ``SubgroupTag/core``. Failure cascades to
    /// siblings; not restartable. Suits foundational services that
    /// must boot successfully for the rest of the system to function
    /// (databases, HTTP servers, queue clients).
    public static let core = SubgroupPolicy(failure: .failFast, restartable: false)

    /// Default policy for ``SubgroupTag/integrations``. Failures stay
    /// isolated to the failing entry; restartable. Suits vendor agents
    /// and external integrations whose outages should not bring the
    /// rest of the system down.
    public static let integrations = SubgroupPolicy(failure: .degraded, restartable: true)
}
