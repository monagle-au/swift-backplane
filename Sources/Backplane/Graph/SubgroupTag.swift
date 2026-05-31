//
//  SubgroupTag.swift
//  swift-backplane
//

/// A named partition of the service graph.
///
/// Subgroups carry distinct failure policies, completion modes, and
/// restartability. Every service belongs to exactly one subgroup;
/// entries without an explicit `subgroup:` parameter land in ``core``.
///
/// `ExpressibleByStringLiteral` so call-sites can write
/// `subgroup: "workers"` without ceremony.
public struct SubgroupTag: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SubgroupTag {
    /// Default subgroup for entries that don't declare one.
    /// Resolves to ``SubgroupPolicy/core`` by default — failure cascades,
    /// not restartable.
    public static let core: SubgroupTag = "core"

    /// Conventional subgroup for "degraded mode acceptable" integrations.
    /// Resolves to ``SubgroupPolicy/integrations`` by default — failures
    /// stay isolated, restartable.
    public static let integrations: SubgroupTag = "integrations"
}
