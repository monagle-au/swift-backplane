//
//  ServiceGraphError.swift
//  swift-backplane
//

/// Errors thrown by the graph's resolution and boot helpers.
///
/// Distinct from per-service errors — these surface mistakes about the
/// graph's topology (missing entries, terminated entries, type mismatches)
/// rather than failures within a service's own protocol.
public enum ServiceGraphError: Error, Sendable {
    /// No entry is registered at the given key.
    case missingService(id: String, expectedType: String)

    /// The entry's lifecycle has reached a terminal non-running state
    /// (`.failed`, `.stopped`, `.unconfigured`) while a caller was
    /// awaiting it.
    case entryTerminated(id: String, state: ServiceState)

    /// The entry has a live instance but it does not conform to the
    /// expected type. Indicates a programming error in the descriptor
    /// or in the ``ServiceKey`` declaration.
    case typeMismatch(id: String, expectedType: String)

    /// A timed ``ServiceGraph/requireService(_:timeout:)`` call exceeded
    /// its supplied timeout before the entry reached a resolution-ready
    /// state. Distinct from ``entryTerminated(id:state:)`` (which signals permanent
    /// failure) — `.timedOut` means "this is taking too long", and a
    /// caller may choose to retry, back off, or escalate.
    case timedOut(id: String, expectedType: String, after: Duration)

    /// A descriptor declares a dependency on an id that no other
    /// descriptor provides. Thrown from `ServiceGraph.init` so
    /// misconfiguration surfaces before any boot work happens.
    case unknownDependency(id: String, referencedBy: String)

    /// The declared dependency graph contains a cycle. The `path` names
    /// the entries forming the cycle, beginning and ending at the same
    /// id. Thrown from `ServiceGraph.init`.
    case cyclicDependency(path: [String])

    /// ``ServiceGraph/boot(roots:)`` was called with a root id that
    /// does not correspond to any registered descriptor. Surfaces
    /// stringified-id typos (e.g. `AnyServiceKey(id: "...")`) at
    /// boot time rather than letting them produce a silently
    /// smaller-than-expected closure.
    case unknownRoot(id: String)

    /// One or more entries in a ``SubgroupPolicy/FailureMode/failFast``
    /// subgroup failed during boot. The graph cancelled in-flight
    /// siblings within that subgroup and reports the offenders.
    /// Other subgroups (with different policies) are isolated from this
    /// failure — their entries continue booting independently. If
    /// multiple `.failFast` subgroups failed in the same boot, the
    /// first observed failure wins.
    case subgroupBootFailed(tag: SubgroupTag, faulted: [String])

    /// ``BackplaneContext/requireConfig()`` was called on a context
    /// whose graph was constructed without a `ConfigReader`. Most
    /// production paths (driven by ``BackplaneApplication``) pass one
    /// through; this surfaces in unit tests where the graph is
    /// constructed directly without config, but a descriptor's
    /// factory unconditionally needs one.
    case missingConfigReader(entryID: String)

    /// A required key has no explicit descriptor and its `Value` does
    /// not conform to ``BackplaneService``, so no default can be
    /// materialised. Thrown from
    /// ``ServiceGraph/materializedDescriptors(explicit:roots:)`` —
    /// register the key in `services()` or conform the type.
    case unresolvableService(id: String, valueType: String)
}
