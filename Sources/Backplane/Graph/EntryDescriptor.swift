//
//  EntryDescriptor.swift
//  swift-backplane
//

/// A type-erased descriptor of one declared service entry.
///
/// Consumed by ``ServiceGraph`` at boot time. The factory is called
/// once at first boot and again on every replacement cycle, receiving a
/// ``BackplaneContext`` for identity, logging, and cross-service
/// resolution.
///
/// Descriptors come from two places:
/// - **Defaults** — a key whose `Value` conforms to ``BackplaneService``
///   materialises its own descriptor on demand; no `services()` entry
///   needed. The closure-free initialisers below are the explicit form
///   of the same thing, for overriding a default's subgroup,
///   dependencies, or replacement strategy.
/// - **Closures** — the `factory:` / `passive:` / `factory:as:` forms,
///   for third-party types, protocol-key bindings, and test doubles.
public struct EntryDescriptor: Sendable {
    /// Entry identity — drives log labels, the entry's config scope, and
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

    /// How the graph replaces this entry when ``ServiceGraph/restart(at:)``
    /// is called. Read from the descriptor *before* the replacement
    /// instance is constructed. Defaults to
    /// ``ReplacementStrategy/standard``.
    package let replacement: ReplacementStrategy

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

    /// The keypath forms of ``dependencies``, retained when the
    /// descriptor was built from keypaths (the keypath-flavoured inits
    /// and ``BackplaneService`` defaults). Drives **default
    /// materialisation**: ``ServiceGraph/materializedDescriptors(explicit:roots:)``
    /// walks these to pull in defaults for conforming `Value` types.
    /// Empty for descriptors declared with bare ``AnyServiceKey``
    /// dependencies — those dependencies must be registered explicitly,
    /// exactly as in 1.x.
    package let dependencyKeyPaths: ServiceList

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

    /// Designated initialiser — every public form funnels through here.
    package init(
        id: String,
        factory: @escaping @Sendable (BackplaneContext) async throws -> any ManagedService,
        replacement: ReplacementStrategy,
        subgroup: SubgroupTag,
        dependencies: [AnyServiceKey],
        dependencyKeyPaths: ServiceList,
        project: @escaping @Sendable (any ManagedService) -> any Sendable
    ) {
        self.id = id
        self.factory = factory
        self.replacement = replacement
        self.subgroup = subgroup
        self.dependencies = dependencies
        self.dependencyKeyPaths = dependencyKeyPaths
        self.project = project
    }

    // MARK: - Closure-free: BackplaneService defaults

    /// Closure-free initialiser for a key whose `Value` conforms to
    /// ``BackplaneService`` — the explicit-override form of the default
    /// the graph would materialise on its own. Every parameter left nil
    /// falls back to the type's static declaration; a supplied
    /// `dependencies:` **replaces** the static list (no merge).
    ///
    /// ```swift
    /// EntryDescriptor(\.database, subgroup: .integrations)
    /// ```
    public init<T: BackplaneService>(
        _ key: ServiceKey<T>,
        subgroup: SubgroupTag? = nil,
        dependencies: ServiceList? = nil,
        replacement: ReplacementStrategy? = nil
    ) {
        let deps = dependencies ?? T.dependencies
        self.init(
            id: key.id,
            factory: { context in try await T.make(context: context) },
            replacement: replacement ?? T.replacementStrategy,
            subgroup: subgroup ?? T.subgroup,
            dependencies: deps.elements.map { AnyServiceKey(keyPath: $0) },
            dependencyKeyPaths: deps,
            project: { $0 }
        )
    }

    /// Keypath-flavoured ``init(_:subgroup:dependencies:replacement:)``.
    public init<T: BackplaneService>(
        _ keyPath: KeyPath<Services, ServiceKey<T>>,
        subgroup: SubgroupTag? = nil,
        dependencies: ServiceList? = nil,
        replacement: ReplacementStrategy? = nil
    ) {
        self.init(
            Services()[keyPath: keyPath],
            subgroup: subgroup,
            dependencies: dependencies,
            replacement: replacement
        )
    }

    // MARK: - Form 1: identity factory

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
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        replacement: ReplacementStrategy = .standard,
        factory: @escaping @Sendable (BackplaneContext) async throws -> T
    ) {
        self.init(
            id: key.id,
            factory: factory,
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies,
            dependencyKeyPaths: ServiceList(),
            project: { $0 }
        )
    }

    /// Keypath-flavoured initialiser. Use this with a
    /// ``Services``-rooted keypath:
    ///
    /// ```swift
    /// EntryDescriptor(
    ///     \.http,
    ///     dependencies: [\.database]
    /// ) { context in
    ///     try await HTTPService(db: context.requireService(\.database))
    /// }
    /// ```
    ///
    /// `T` is inferred from the keypath's `Value` type. Dependencies
    /// declared as keypaths participate in default materialisation —
    /// see ``ServiceGraph/materializedDescriptors(explicit:roots:)``.
    public init<T: ManagedService>(
        _ keyPath: KeyPath<Services, ServiceKey<T>>,
        subgroup: SubgroupTag = .core,
        dependencies: ServiceList = [],
        replacement: ReplacementStrategy = .standard,
        factory: @escaping @Sendable (BackplaneContext) async throws -> T
    ) {
        self.init(
            id: Services()[keyPath: keyPath].id,
            factory: factory,
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies.elements.map { AnyServiceKey(keyPath: $0) },
            dependencyKeyPaths: dependencies,
            project: { $0 }
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
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        replacement: ReplacementStrategy = .standard,
        passive: @escaping @Sendable (BackplaneContext) async throws -> Value
    ) {
        self.init(
            id: key.id,
            factory: { context in PassiveService(try await passive(context)) },
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies,
            dependencyKeyPaths: ServiceList(),
            // Safe by construction: this initialiser is the only producer
            // of the managed unit, and it always wraps in PassiveService<Value>.
            project: { ($0 as! PassiveService<Value>).inner }
        )
    }

    /// Keypath-flavoured ``init(_:subgroup:dependencies:replacement:passive:)``.
    public init<Value: Sendable>(
        _ keyPath: KeyPath<Services, ServiceKey<Value>>,
        subgroup: SubgroupTag = .core,
        dependencies: ServiceList = [],
        replacement: ReplacementStrategy = .standard,
        passive: @escaping @Sendable (BackplaneContext) async throws -> Value
    ) {
        self.init(
            id: Services()[keyPath: keyPath].id,
            factory: { context in PassiveService(try await passive(context)) },
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies.elements.map { AnyServiceKey(keyPath: $0) },
            dependencyKeyPaths: dependencies,
            project: { ($0 as! PassiveService<Value>).inner }
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
    ///     as: { $0 })                                      // -> any AuditStore
    /// ```
    ///
    /// Requires both `factory:` and `as:`; the `as:` label distinguishes
    /// this from Form 1 even when `Value == Service`.
    public init<Value: Sendable, Service: ManagedService>(
        _ key: ServiceKey<Value>,
        subgroup: SubgroupTag = .core,
        dependencies: [AnyServiceKey] = [],
        replacement: ReplacementStrategy = .standard,
        factory: @escaping @Sendable (BackplaneContext) async throws -> Service,
        as project: @escaping @Sendable (Service) -> Value
    ) {
        self.init(
            id: key.id,
            factory: { context in try await factory(context) },
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies,
            dependencyKeyPaths: ServiceList(),
            // Safe by construction: `factory`'s declared return type is
            // `Service`, so the stored managed unit is always a `Service`.
            project: { project($0 as! Service) }
        )
    }

    /// Keypath-flavoured ``init(_:subgroup:dependencies:replacement:factory:as:)``.
    public init<Value: Sendable, Service: ManagedService>(
        _ keyPath: KeyPath<Services, ServiceKey<Value>>,
        subgroup: SubgroupTag = .core,
        dependencies: ServiceList = [],
        replacement: ReplacementStrategy = .standard,
        factory: @escaping @Sendable (BackplaneContext) async throws -> Service,
        as project: @escaping @Sendable (Service) -> Value
    ) {
        self.init(
            id: Services()[keyPath: keyPath].id,
            factory: { context in try await factory(context) },
            replacement: replacement,
            subgroup: subgroup,
            dependencies: dependencies.elements.map { AnyServiceKey(keyPath: $0) },
            dependencyKeyPaths: dependencies,
            project: { project($0 as! Service) }
        )
    }
}
