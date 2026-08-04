//
//  EntryDescriptor.swift
//  swift-backplane
//

/// A type-erased descriptor of one declared service entry.
///
/// Produced by the `service(key:factory:)` helper and consumed by
/// ``ServiceGraph`` at boot time. The factory is called once at first
/// boot and again on every replacement cycle, receiving a
/// ``BackplaneContext`` for identity, logging, and cross-service
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
    package let factory: @Sendable (BackplaneContext) async throws -> any ManagedService

    /// How the graph interprets `.unconfigured` for dependent callers.
    /// Defaults to ``ConfigurationRequirement/required``.
    package let configuration: ConfigurationRequirement

    /// Subgroup the entry belongs to. Drives failure-policy partitioning
    /// at boot and restartability checks. Defaults to
    /// ``SubgroupTag/core``.
    package let subgroup: SubgroupTag

    /// Other entries this entry's factory will resolve via
    /// ``BackplaneContext/requireService(_:timeout:)``.
    ///
    /// Drives **pruning** (only entries in the transitive closure of
    /// the boot roots are booted) and **cycle detection** (at graph
    /// init). Dependencies do *not* enforce boot ordering — concurrent
    /// boot continues to use
    /// ``BackplaneContext/requireService(_:timeout:)`` as the runtime
    /// synchronization point.
    package let dependencies: [AnyServiceKey]

    /// Projects the lifecycled managed instance to the key's resolved
    /// value at resolution time.
    ///
    /// The graph stores and lifecycles an `any ManagedService` (the
    /// *managed unit*), but a key's `Value` (the *resolved value*) need
    /// not be that same type. This closure bridges the two:
    ///
    /// - **Identity** (Form 1) — `Value == ManagedService`; projection is
    ///   `{ $0 }`.
    /// - **Passive** (Form 2) — the managed unit is a framework-supplied
    ///   ``PassiveService`` wrapper; projection unwraps `.inner`.
    /// - **Projected** (Form 3) — the managed unit is a concrete
    ///   ``ManagedService``; projection upcasts it to the key's protocol
    ///   `Value`.
    ///
    /// Returns `any Sendable` because every resolved value is provably
    /// `Sendable` (`ManagedService: Sendable`; `Value: Sendable`).
    /// ``ServiceEntry/currentHandle(_:)`` applies this and then casts to
    /// the requested type — the cast is guaranteed to succeed by the
    /// matching of key `Value` to projection result.
    package let project: @Sendable (any ManagedService) -> any Sendable

    /// Generic convenience initialiser. Type-erases `T` to
    /// `any ManagedService` while preserving the typed return in the
    /// closure signature for callers.
    ///
    /// **Form 1 (identity).** The key's `Value`, the factory's return,
    /// and the managed unit are the same `T`; resolution returns the
    /// managed instance directly. This is the only form usable as a bare
    /// trailing closure — Form 2 and Form 3 require their `passive:` /
    /// `as:` labels.
    public init<T: ManagedService>(
        _ key: ServiceKey<T>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        factory: @escaping @Sendable (BackplaneContext) async throws -> T
    ) {
        self.id = key.id
        self.factory = factory
        self.configuration = configuration
        self.subgroup = subgroup
        self.dependencies = dependencies
        self.project = { $0 }
    }

    /// Keypath-flavoured initialiser. Use this with a
    /// ``Services``-rooted keypath:
    ///
    /// ```swift
    /// EntryDescriptor(
    ///     \.database,
    ///     dependencies: [\.config]
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
        factory: @escaping @Sendable (BackplaneContext) async throws -> T
    ) {
        self.init(
            Services()[keyPath: keyPath],
            configuration: configuration,
            subgroup: subgroup,
            dependencies: dependencies.map { AnyServiceKey(keyPath: $0) },
            factory: factory
        )
    }

    // MARK: - Form 2: passive value

    /// Passive initialiser. The factory returns the key's resolved
    /// `Value` directly — any `Sendable` value, including a protocol
    /// existential — and the graph wraps it in a ``PassiveService`` for
    /// lifecycle (no-op `start()`/`shutdown()`). Resolution unwraps the
    /// wrapper, so the `PassiveService` never surfaces at the call site.
    ///
    /// Use this to key on a protocol while registering a concrete passive
    /// value:
    ///
    /// ```swift
    /// EntryDescriptor(auditStoreKey) { _ in        // ServiceKey<any AuditStore>
    ///     ClickHouseAuditStore(...)                // concrete, upcast to any AuditStore
    /// }
    /// ```
    ///
    /// Requires the explicit `passive:` label; a bare trailing closure
    /// binds to Form 1's `factory:` instead.
    public init<Value: Sendable>(
        _ key: ServiceKey<Value>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        passive: @escaping @Sendable (BackplaneContext) async throws -> Value
    ) {
        self.id = key.id
        self.factory = { context in PassiveService(try await passive(context)) }
        self.configuration = configuration
        self.subgroup = subgroup
        self.dependencies = dependencies
        // Safe by construction: this initialiser is the only producer of
        // the managed unit, and it always wraps in PassiveService<Value>.
        self.project = { ($0 as! PassiveService<Value>).inner }
    }

    /// Keypath-flavoured ``init(_:configuration:subgroup:dependencies:passive:)``.
    public init<Value: Sendable>(
        _ keyPath: KeyPath<Services, ServiceKey<Value>>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [PartialKeyPath<Services>] = [],
        passive: @escaping @Sendable (BackplaneContext) async throws -> Value
    ) {
        self.init(
            Services()[keyPath: keyPath],
            configuration: configuration,
            subgroup: subgroup,
            dependencies: dependencies.map { AnyServiceKey(keyPath: $0) },
            passive: passive
        )
    }

    // MARK: - Form 3: projected lifecycle service

    /// Projected initialiser. The factory returns a concrete
    /// ``ManagedService`` (`Service`) which the graph lifecycles, while
    /// the key's resolved `Value` is a — typically protocol — type that
    /// `Service` projects to via `as:`. Lifecycle runs on the concrete;
    /// consumers resolve the abstraction.
    ///
    /// ```swift
    /// EntryDescriptor(auditStoreKey,               // ServiceKey<any AuditStore>
    ///     factory: { _ in ClickHouseAuditService(...) },   // a ManagedService
    ///     as: { $0 }                                       // -> any AuditStore
    /// )
    /// ```
    ///
    /// Requires both `factory:` and `as:`; the `as:` label distinguishes
    /// this from Form 1 even when `Value == Service`.
    public init<Value: Sendable, Service: ManagedService>(
        _ key: ServiceKey<Value>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        factory: @escaping @Sendable (BackplaneContext) async throws -> Service,
        as project: @escaping @Sendable (Service) -> Value
    ) {
        self.id = key.id
        self.factory = { context in try await factory(context) }
        self.configuration = configuration
        self.subgroup = subgroup
        self.dependencies = dependencies
        // Safe by construction: `factory`'s declared return type is
        // `Service`, so the stored managed unit is always a `Service`.
        self.project = { project($0 as! Service) }
    }

    /// Keypath-flavoured ``init(_:configuration:subgroup:dependencies:factory:as:)``.
    public init<Value: Sendable, Service: ManagedService>(
        _ keyPath: KeyPath<Services, ServiceKey<Value>>,
        configuration: ConfigurationRequirement = .required,
        subgroup: SubgroupTag = .core,
        dependencies: [PartialKeyPath<Services>] = [],
        factory: @escaping @Sendable (BackplaneContext) async throws -> Service,
        as project: @escaping @Sendable (Service) -> Value
    ) {
        self.init(
            Services()[keyPath: keyPath],
            configuration: configuration,
            subgroup: subgroup,
            dependencies: dependencies.map { AnyServiceKey(keyPath: $0) },
            factory: factory,
            as: project
        )
    }
}
