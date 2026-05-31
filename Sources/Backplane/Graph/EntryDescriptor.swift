//
//  EntryDescriptor.swift
//  swift-backplane
//

/// A type-erased descriptor of one declared service entry.
///
/// Produced by the `service(key:factory:)` helper and consumed by
/// ``ServiceGraph`` at boot time. The factory is called once at first
/// boot and again on every replacement cycle, receiving a
/// ``ServiceContext`` for identity, logging, and cross-service
/// resolution.
public struct EntryDescriptor: Sendable {
    /// Entry identity — drives log labels and
    /// ``ServiceGraph/restart(at:)`` lookup.
    package let id: String

    /// Factory closure. Called at boot and on every replacement.
    ///
    /// **Factory closures persist across restarts.** The closure stored
    /// here is captured once at descriptor construction and reused for
    /// every replacement cycle. Consumers who need restart-aware
    /// behaviour — e.g. retry with a different upstream after the first
    /// attempt fails, or rotate through a credential list — must encode
    /// that mutable state *inside* the closure (a `Mutex<State>` the
    /// closure captures, or an actor the closure calls). The graph
    /// never re-creates descriptors or swaps closures.
    package let factory: @Sendable (ServiceContext) async throws -> any ManagedService

    /// How the graph interprets `.unconfigured` for dependent callers.
    /// Defaults to ``ConfigurationRequirement/required``.
    package let configuration: ConfigurationRequirement

    /// Subgroup the entry belongs to. Drives failure-policy partitioning
    /// at boot and restartability checks. Defaults to
    /// ``SubgroupTag/core``.
    package let subgroup: SubgroupTag

    /// Other entries this entry's factory will resolve via
    /// ``ServiceContext/requireService(_:timeout:)``.
    ///
    /// Drives **pruning** (only entries in the transitive closure of
    /// the boot roots are booted) and **cycle detection** (at graph
    /// init). Dependencies do *not* enforce boot ordering — concurrent
    /// boot continues to use
    /// ``ServiceContext/requireService(_:timeout:)`` as the runtime
    /// synchronization point.
    package let dependencies: [AnyServiceKey]

    /// Generic convenience initialiser. Type-erases `T` to
    /// `any ManagedService` while preserving the typed return in the
    /// closure signature for callers.
    public init<T: ManagedService>(
        _ key: ServiceKey<T>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        factory: @escaping @Sendable (ServiceContext) async throws -> T
    ) {
        self.id = key.id
        self.factory = factory
        self.configuration = configuration
        self.subgroup = subgroup
        self.dependencies = dependencies
    }

    /// Keypath-flavoured initialiser. Use this with a
    /// ``Services``-rooted keypath:
    ///
    /// ```swift
    /// EntryDescriptor(
    ///     \.databaseKey,
    ///     dependencies: [\.configKey]
    /// ) { context in
    ///     try await PostgresService(...)
    /// }
    /// ```
    ///
    /// `T` is inferred from the keypath's `Value` type.
    /// `dependencies:` accepts keypaths into ``Services`` — each is
    /// erased to ``AnyServiceKey`` for the graph's internal index.
    public init<T: ManagedService>(
        _ keyPath: KeyPath<Services, ServiceKey<T>>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [PartialKeyPath<Services>] = [],
        factory: @escaping @Sendable (ServiceContext) async throws -> T
    ) {
        self.init(
            Services()[keyPath: keyPath],
            configuration: configuration,
            subgroup: subgroup,
            dependencies: dependencies.map { AnyServiceKey(keyPath: $0) },
            factory: factory
        )
    }
}
