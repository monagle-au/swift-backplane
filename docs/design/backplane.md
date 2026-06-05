# Backplane: Service Management for Swift Server Applications

> Design note for Backplane's service-management subsystem.

---

## 0. Framing

Backplane is a lightweight scaffold for Swift server applications: a
small set of well-chosen SSWG libraries (swift-service-lifecycle,
swift-argument-parser, swift-log, swift-service-context) drawn together
with typed-key registration, dependency-ordered boot, and a
`ServiceContext` for cross-service resolution. Restart-aware machinery
(blue-green replacement, hot reload, self-reported degradation) is
available as an explicit opt-in for consumers who need it, but no
consumer pays for it on the lead path.

The design must serve three deployment shapes without forcing any of them
to wear the others' ceremony:

- **(a) Stateless cloud microservice** — deployed via CloudRun / k8s /
  Cloud Run-equivalent. The orchestrator owns restart. The consumer
  wants typed keys, dependency boot, lifecycle composition, and the
  ability to mark a degraded-but-running service in metrics. They never
  call `restart(at:)`; the restart-aware sections of this document are
  skim-or-skip.

- **(b) Single-binary deployment** — Raspberry Pi, NAS, on-prem,
  development. No external orchestrator. The process owns restart. A
  wedged database client (or any other in-process state-rotted service)
  has to be replaced *inside* the process without bouncing everything
  else. Blue-green replacement of one entry while siblings keep
  serving is the load-bearing feature here.

- **(c) Embedded framework** — Acumen-shaped: a long-running app that
  orchestrates a population of sub-services inside one process,
  composing role taxonomies, admin RPC surfaces, and runtime
  reconfiguration on top of Backplane's primitives. Uses essentially
  every feature in this document.

The benchmark is *not* "can Acumen run on this" — it is "is this the
right shape for a Swift service-management library, full stop, knowing
that one realistic consumer happens to look like Acumen." References
to Acumen below are illustrative of an upper-bound consumer shape; they
are not migration instructions.

---

## 1. Positioning

Backplane combines a service-graph subsystem (typed keys, per-entry
FSM, replacement strategies, subgroups, `ServiceContext`) with a thin
CLI/command-routing layer (`BackplaneApplication`, `BackplaneCommand`,
`PersistentCommand`, `TaskCommand`, `BootstrapPlan`,
`BootstrapCoordinator`). Underneath sits
`swift-service-lifecycle`'s `ServiceGroup` as the
structured-concurrency substrate — no fork.

The two layers live together in a single package because the
primitives interact closely with the CLI layer: which command is
running determines which subset of services boot. Splitting them
would either lose the composition-by-CLI property or require a
duplicate command abstraction.

---

## 2. Core model

The core model has five concepts: **`ManagedService`** (the lifecycle
protocol), **`ServiceState`** (the per-entry FSM), **`ServiceGraph`** (the
registry, an actor), **`ServiceContext`** (the reader), and the
**keypath-on-`Services`** declaration pattern for typed keys. Underneath
sits `swift-service-lifecycle`'s `ServiceGroup`, which Backplane
continues to use as the structured-concurrency substrate. No fork.

### 2.1 `ServiceState` — the per-entry FSM

```swift
/// Lifecycle state of a registered service entry.
///
/// Transitions are driven by the ``ServiceGraph``. Consumers observe state
/// via ``ServiceLifecycleHandle/stateStream()`` or read
/// ``ServiceLifecycleHandle/state`` directly.
///
/// This is the *entry-level* state — the entry's notion of "is there a
/// usable service here?" For replacement-aware entries (see §7), each
/// active generation also carries its own per-generation state; the
/// entry-level state aggregates across generations.
public enum ServiceState: Sendable, Hashable {
    /// Entry declared but no usable configuration available.
    case unconfigured

    /// An external flow is gathering configuration for this entry
    /// (interactive setup, OAuth redirect, etc.).
    case configuring

    /// First instance is constructing; ``ManagedService/start()`` is
    /// running. The entry has no live handle yet.
    case starting

    /// Operational. At least one generation is serving.
    case running

    /// Running but reporting a transient fault.
    case degraded(fault: ServiceFault)

    /// A blue-green replacement is in flight — old generation still
    /// serves new resolves, new generation is starting. The entry has
    /// a live handle (the old one) throughout. See §7.
    case replacing

    /// All generations have shut down; no live handle. Restart needed.
    case stopped

    /// Unrecoverable failure. The entry is dead until explicit restart.
    case failed(fault: ServiceFault)
}
```

`ServiceFault` is `Sendable + Hashable`, carries `description: String`,
`errorType: String`, `firstObservedAt: Date`, and `consecutiveCount: Int`.
Keeping `ServiceState` `Hashable` avoids the existential-`Error`
complications that arise when state is emitted over `AsyncStream`s with
backpressure.

Note `.replacing` is new compared to a textbook FSM. It is the externally
visible signal that "a swap is in flight"; from the consumer's perspective,
the entry continues to resolve to a live handle throughout. The state exists
so admin/observability surfaces can show "this entry is mid-deploy."

### 2.2 `ServiceLifecycleHandle` — read-only lifecycle view

```swift
/// Read-only view of a service entry's lifecycle.
///
/// Each registered entry in a ``ServiceGraph`` has an associated handle.
/// The handle is ``Sendable`` and safe to capture into closures.
public protocol ServiceLifecycleHandle: Sendable {
    /// Current entry-level state.
    var state: ServiceState { get async }

    /// State transitions. Each call returns a fresh ``AsyncStream``.
    /// The first element is the current state (replay-first semantic).
    func stateStream() -> AsyncStream<ServiceState>

    /// Request a restart of this entry from the consumer side.
    /// Restart strategy is determined by the service's declared
    /// ``ReplacementStrategy`` (see §7).
    func requestRestart() async
}
```

### 2.3 `ManagedService` — the lifecycle protocol

the predecessor design's `ServiceEntry` is an abstract build-closure. Backplane
replaces it with a concrete lifecycle protocol:

```swift
/// A service whose lifecycle is managed by a ``ServiceGraph``.
///
/// The graph calls the service's factory closure to construct it, then
/// ``start()``, then waits for shutdown. Replacement is governed by the
/// service's ``replacementStrategy`` — see §7.
///
/// Not the same as `ServiceLifecycle.Service`. That protocol's single
/// `run()` owns its task's lifetime; ``ManagedService`` is two-phase
/// (start / shutdown) with the graph owning the lifetime. An adapter
/// (``ManagedServiceGroupAdapter``) bridges the two when ``ManagedService``
/// runs inside a ``ServiceGroup``.
public protocol ManagedService: Sendable {
    /// How the graph replaces this service when it is restarted or
    /// reconfigured. See §7.
    var replacementStrategy: ReplacementStrategy { get }

    /// Begin operation. The service is in ``ServiceState/starting``
    /// (or, for blue-green replacement, in a new generation while the
    /// previous generation continues serving) while this method runs.
    ///
    /// A throw transitions the (generation, not necessarily the entry)
    /// to a failed state; see §7 for how this interacts with the
    /// entry-level state.
    func start() async throws

    /// Tear down. Called after the service has been drained by the
    /// graph (no in-flight resolves point at this instance). Must
    /// complete in bounded time.
    func shutdown() async
}

extension ManagedService {
    /// Default replacement strategy: blue-green with a 30-second grace
    /// period for the old generation to drain.
    public var replacementStrategy: ReplacementStrategy {
        .blueGreen(grace: .seconds(30))
    }
}
```

Two important things this protocol does *not* require:

- It does not require a `reload(config:)` method. Hot reload is a separate,
  opt-in protocol (§7).
- It does not require any health-check or readiness method. The contract
  is: `start()` returns ⇒ ready to receive requests. Services that need
  warm-up perform it before returning from `start()`.

### 2.4 Typed service keys on the `Services` namespace

```swift
/// Namespace for service entry declarations.
///
/// Extend with computed properties returning a typed
/// ``ServiceKey``:
///
/// ```swift
/// extension Services {
///     public var databaseKey: ServiceKey<PostgresClient> {
///         ServiceKey(id: "database")
///     }
///     public var httpKey: ServiceKey<MyHTTPServer> {
///         ServiceKey(id: "http")
///     }
/// }
/// ```
///
/// `Services` is a `public struct` with a no-arg `init`; the
/// framework instantiates one at the keypath-resolution boundary
/// (when erasing a `PartialKeyPath<Services>` back to an
/// ``AnyServiceKey``). Consumers never construct it explicitly —
/// the `\.…` keypath syntax is the consumer-facing surface.
public struct Services: Sendable {
    public init() {}
}

/// Phantom-typed identity for one service entry.
///
/// `Value` is the resolved type. `ServiceKey<T>` is `Hashable` on `id`,
/// `Sendable`, and the only thing a `Services` extension property
/// needs to return.
public struct ServiceKey<Value: Sendable>: Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}
```

**Why keypaths against a struct?** Compared to the predecessor design's
per-service `ServiceKey` conformer struct (one struct, a
`defaultValue`, an `ObjectIdentifier`-based registry), the
keypath-on-`Services` pattern is one line per entry, identical to the
SwiftUI `EnvironmentValues` shape developers already know, and the
keypath carries the typed `Value` so `requireService(\.databaseKey)`
infers the return type without a cast.

**One namespace.** Backplane ships exactly one namespace, `Services`.
A consumer that wants its own (e.g. an `Agents`-style population)
defines its own struct and adds matching `requireService` / dependency-
list overloads on top of Backplane's runtime — the graph indexes on
`AnyServiceKey` (a string id), so any keypath-keyed namespace plugs in
via the `ServiceKeyConvertible` protocol. Backplane does not ship a
generic namespace-extension protocol because the single-namespace
majority case shouldn't pay the abstraction cost.

**No macro.** Earlier drafts of this design proposed a `@Register`
peer macro to halve the per-key boilerplate. With the keypath-on-
struct shape, the hand-written declaration is already a single line
and reads exactly as a SwiftUI `@Entry` declaration would expand to.
Backplane has no macro target.

### 2.5 `ServiceGraph` — the registry

The `ServiceGraph` is an actor that owns every registered entry's
lifecycle, the inner `ServiceGroup` that supervises them, and the
replacement machinery.

```swift
/// Service registry. Owns entry lifecycles, drives the inner
/// ``ServiceGroup``, exposes typed lookup.
///
/// Constructed from a list of ``EntryDescriptor``s — typically via
/// a ``@ServiceGraphBuilder`` block. After construction the entry set
/// is fixed for the process lifetime.
public actor ServiceGraph {
    /// Construct the graph from a fixed descriptor set.
    ///
    /// `throws` because construction performs eager validation: every
    /// declared dependency must point at a registered keypath, and the
    /// dependency graph must be acyclic. Both failures throw
    /// ``ServiceGraphError`` synchronously, before any service runs.
    /// See §11 for the spike-validated rationale.
    public init(
        descriptors: [EntryDescriptor],
        subgroupPolicies: [SubgroupTag: SubgroupPolicy] = [:],
        logger: Logger,
        config: ConfigReader? = nil
    ) throws

    /// Boot the transitive closure of `roots` to terminal-or-running.
    ///
    /// Pass `nil` (the default) to boot every registered entry —
    /// equivalent to the 1.0 `ApplicationRunner` behaviour. Pass a list
    /// of keypath identifiers (typically a command's `requiredServices`)
    /// to prune to that subset. Unknown root identifiers throw
    /// ``ServiceGraphError/unknownRoot`` — stringified IDs are validated
    /// eagerly so typos surface immediately rather than silently
    /// dropping services.
    public func boot(roots: [String]? = nil) async throws

    /// Synchronous entry lookup. Returns the *currently-active*
    /// generation's handle, or nil if the entry has no live handle
    /// (never-booted, stopped, or failed).
    nonisolated public func resolve<T>(
        _ keyPath: KeyPath<Services, T>
    ) -> T?

    /// Async entry lookup that waits for the entry to reach
    /// resolution-ready. See §5 for the boot-time semantics.
    public func require<T>(
        _ keyPath: KeyPath<Services, T>
    ) async throws -> T

    /// First running entry whose handle conforms to ``T``.
    nonisolated public func firstService<T>(
        conformingTo type: T.Type
    ) -> T?

    /// Subscribe to state transitions for an entry.
    public func stateStream(
        of keyPath: AnyKeyPath
    ) -> AsyncStream<ServiceState>

    /// Trigger replacement of an entry, using its declared strategy.
    public func restart(at keyPath: AnyKeyPath) async

    /// Trigger a hot reload (if supported) — no new generation, the
    /// existing service applies new configuration in place.
    /// Falls back to ``restart(at:)`` if the service does not
    /// conform to ``HotReloadable``.
    public func reload(at keyPath: AnyKeyPath) async

    public func state(of keyPath: AnyKeyPath) -> ServiceState
}

extension ServiceGraph: ServiceLifecycle.Service {
    /// Drives the inner ``ServiceGroup`` that supervises per-entry
    /// adapters. Designed to be added to an outer ``ServiceGroup``.
    public func run() async throws
}
```

The graph is itself a `ServiceLifecycle.Service`. It runs an inner
`ServiceGroup` for per-entry supervision, and is in turn supervised by an
outer `ServiceGroup` owned by `ApplicationRunner`. Two levels.

### 2.6 `EntryDescriptor` and the factory

```swift
/// Type-erased descriptor of one declared entry.
public struct EntryDescriptor: Sendable {
    /// Entry keypath — identity. Nil for anonymous entries (§3).
    public let keyPath: AnyKeyPath?

    /// Leaf name — drives log labels, config-file paths, admin IDs.
    public let leafName: String

    /// Subgroup tag. Defaults to ``SubgroupTag/core``. See §4.
    public let subgroup: SubgroupTag

    /// Declared dependencies (other entry keypaths this factory or
    /// service will call ``ServiceContext/requireService(_:)`` for).
    /// Drives topological-sort cycle detection. Optional — services
    /// that don't cross-resolve omit this.
    public let dependencies: [AnyKeyPath]

    /// Factory closure. Called at first boot and at every replacement.
    /// Receives the per-entry ``ConfigReader`` and ``ServiceContext``.
    public let factory: @Sendable (
        ConfigReader, ServiceContext
    ) async throws -> any ManagedService

    /// Optional in-memory configuration layer.
    public let defaultConfig: [String: any Sendable]?
}
```

**Factory closures persist across restarts.** The closure stored in
`EntryDescriptor.factory` is captured once at descriptor construction
and reused for every replacement cycle. Consumers who need
restart-aware behaviour — e.g. retry with a different upstream after
the first attempt fails, or rotate through a credential list — must
encode that mutable state *inside* the closure (a `Mutex<State>`
captured by the closure, or an actor the closure calls). The graph
itself never re-creates descriptors or swaps closures.

```swift
// Restart-aware factory: rotate through a credential list.
let credentials = Mutex<[Credential]>(initialCredentials)
service(\.upstream, label: "upstream") { _, context in
    let cred = credentials.withLock { creds -> Credential in
        let next = creds.removeFirst()
        creds.append(next)
        return next
    }
    return UpstreamClient(credentials: cred)
}
```

The framework offers no descriptor-replacement API in v1. Replacing
the factory wholesale would mean dropping the type erasure that
`EntryDescriptor` performs, which leaks the concrete service type
back to the graph's surface. The mutable-state-in-closure pattern is
the recommended idiom; it's the same one Acumen uses for its
multi-instance integrations.

### 2.7 `ServiceContext` — the reader

```swift
/// Context passed to a service's factory closure, and available at
/// runtime for cross-service resolution.
public final class ServiceContext: Sendable {
    /// Entry identifier — the keypath leaf as a string.
    public let entryID: String

    /// Pre-scoped logger.
    public let logger: Logger

    /// Per-entry configuration reader (layered: per-entry file >
    /// per-entry default > project-wide).
    public let config: ConfigReader

    /// Lifecycle handle for this entry.
    public let lifecycle: any ServiceLifecycleHandle

    /// Resolve a service by keypath. Returns nil if not running.
    public func service<T>(_ keyPath: KeyPath<Services, T>) -> T?

    /// Resolve a required service, waiting if necessary. See §5.
    public func requireService<T>(
        _ keyPath: KeyPath<Services, T>
    ) async throws -> T

    public func firstService<T>(conformingTo type: T.Type) -> T?
    public func requireFirstService<T>(
        conformingTo type: T.Type
    ) async throws -> T
}
```

The graph is reachable from a `ServiceContext` via private internals;
public consumers go through the typed accessors above. This keeps the
graph existential off the context's public API.

---

## 3. Composition by CLI

The central tension: `BackplaneApplication.configure(_:)` registers *all*
services the app may need, but each command needs a subset. the predecessor design
solves this with `requiredServices: [any ServiceKey.Type]` and a
topological prune. The principle is sound; the mechanism is what changes.

### 3.1 `services()` produces descriptors

`BackplaneApplication.configure(_:)` becomes a descriptor-producing method:

```swift
public protocol BackplaneApplication: Sendable {
    static var identifier: String { get }

    /// Produce the full set of service descriptors the app may need.
    /// Commands select which subset boots.
    @ServiceGraphBuilder
    static func services() -> [EntryDescriptor]

    static func configReader(
        for environment: Environment
    ) async throws -> ConfigReader

    associatedtype RootCommand: AsyncParsableCommand
}
```

### 3.2 Commands declare required keypaths

```swift
public protocol BackplaneCommand: AsyncParsableCommand {
    associatedtype App: BackplaneApplication

    /// Keypaths of required services. The graph is pruned to the
    /// transitive closure of these entries.
    var requiredServices: [PartialKeyPath<Services>] { get }

    var lifecycleMode: ServiceLifecycleMode { get }

    func execute(with context: ServiceContext) async throws

    func bootstrap(
        config: ConfigReader,
        environment: Environment
    ) async throws -> BootstrapPlan
}
```

### 3.3 Tiny example — single-command HTTP server

```swift
extension Services {
    public var httpKey: ServiceKey<MyHTTPServer> { ServiceKey(id: "http") }
}

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = ServeCommand
    static let identifier = "my-app"

    static func services() -> [EntryDescriptor] {
        let services = Services()
        return [
            // From BackplanePostgres — ships an EntryDescriptor that
            // wraps PostgresClient in a BackplanePostgresService
            // conforming to ManagedService.
            postgresEntryDescriptor(),

            EntryDescriptor(
                services.httpKey,
                dependencies: [AnyServiceKey(keyPath: \.postgres)]
            ) { context in
                let pg = try await context.requireService(\.postgres)
                return MyHTTPServer(database: pg.client)
            },
        ]
    }
}

struct ServeCommand: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(abstract: "Run the server")
    var requiredServices: [PartialKeyPath<Services>] { [\.httpKey] }
}
```

Ceremony reduction from the predecessor design: no `ServiceKey`-as-
protocol-conformer struct, no `ConcreteServiceEntry<K>`, no
`ServiceValues` accessor. One computed property on `Services`
returning `ServiceKey<T>`, one `EntryDescriptor` per entry (or a
shipped descriptor helper like `postgresEntryDescriptor()`), one
keypath in `requiredServices`.

#### Services are managed units, not values

`requireService(\.database)` returns the *service* — a
``ManagedService`` that owns whatever resources it manages — not the
underlying resource directly. A `BackplanePostgresService` exposes its
`PostgresClient` as `.client`; consumers reach for `pg.client` to run
queries. Treating the resource as the resolve return type would be a
leaky abstraction: it would hide the lifecycle, restart strategy, and
health surface that the service genuinely has and the consumer may
want to observe.

```swift
let pg = try await context.requireService(\.databaseKey)
try await pg.client.query("SELECT 1")     // resource access
let state = pg.context.lifecycle.state    // lifecycle observability
// pg.context.health is the service-side write surface; the consumer
// observes degradation via the lifecycle stream.
```

When the resource is a Backplane-defined type the consumer authors
themselves (e.g. `MyHTTPServer`), the service *is* the consumer-facing
type — make it conform to `ManagedService` directly. When the resource
is supplied by an external library (`PostgresClient`, gRPC channels,
`RedisClient`), a thin Backplane-defined wrapper service holds the
resource and conforms to `ManagedService` on its behalf. Satellite
targets (`BackplanePostgres`, etc.) ship those wrappers; consumers
write their own for clients we don't have a satellite for.

#### Helpers for the common wrapper shapes

Most wrappers fall into one of two boilerplate-only shapes. Backplane
ships generic helpers for both so consumers don't write the same code
each time:

- **``LifecycleAdapter<S: Service>``** — wraps any
  `ServiceLifecycle.Service`-conforming inner type as a
  `ManagedService`. `start()` spawns a detached task running
  `inner.run()`; `shutdown()` cancels it. Inner exposed as
  `.inner`. Use when the inner already conforms to `Service` and
  the wrapper would otherwise be pure spawn-task / cancel-task
  boilerplate (e.g. wrapping `FirebasePublicKeys`,
  `GoogleOIDCKeys`, a grpc-swift `GRPCServer` via `AnyService`).

- **``PassiveService<T>``** — wraps any `Sendable` value as a
  `ManagedService` with empty start/shutdown. The graph holds the
  wrapper for the surrounding `ServiceGroup` lifetime; the inner
  value's state persists across resolutions. Use when the value
  has no run loop (e.g. wrapping a passive actor like `KMSClient`
  whose only job is on-demand calls).

Both helpers expose the inner as `.inner`. When the wrapper warrants
a more semantic accessor name (`.client`, `.server`), write a thin
domain wrapper around the generic helper that adds the alias —
`BackplanePostgresService` does this: it holds a `PostgresClient` and
exposes both `.client` (semantic) and `.inner` (Backplane-wide
convention).

A wrapper that owns resources beyond the inner type — a shared
`HTTPClient`, a connection pool, a key-rotation timer — should stay
hand-rolled. The generic helpers don't fit because shutdown needs to
release the owned resources too. Acumen's `PushRouterService`
(wrapping `PushRouter` plus a shared `HTTPClient`) is an example of
the hand-rolled shape.

### 3.4 Multi-command example

A typical service binary needs `serve`, `migrate`, and an admin tool:

```swift
struct AppCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        subcommands: [ServeCommand.self, MigrateCommand.self, AdminCommand.self],
        defaultSubcommand: ServeCommand.self
    )
}

struct ServeCommand: PersistentCommand {
    typealias App = MyApp
    var requiredServices: [PartialKeyPath<Services>] {
        [\.httpKey, \.metricsExporterKey]
    }
}

struct MigrateCommand: TaskCommand {
    typealias App = MyApp
    // Migrations need only the database.
    var requiredServices: [PartialKeyPath<Services>] {
        [\.databaseKey]
    }

    func execute(with context: ServiceContext) async throws {
        let pg = try await context.requireService(\.databaseKey)
        try await runMigrations(on: pg.client)
    }
}

struct AdminCommand: TaskCommand {
    typealias App = MyApp
    @Argument var operation: String

    var requiredServices: [PartialKeyPath<Services>] {
        [\.databaseKey, \.adminAPIKey]
    }

    func execute(with context: ServiceContext) async throws { ... }
}
```

The graph prunes to each command's transitive closure. `MigrateCommand`
boots only Postgres; `ServeCommand` boots the HTTP server + metrics
exporter (which transitively boots Postgres if the HTTP server depends on
it); `AdminCommand` boots Postgres + admin API.

This composition is identity-preserving across commands: a migration that
reads `\Services.database` resolves through the same keypath as the HTTP
server does, with the same per-entry configuration story.

---

## 4. Subgroups

### Motivation

A subgroup is a named partition of the entry set with its own failure
policy. The core distinction it surfaces — and the load-bearing reason
subgroups exist — is between *must-run* and *best-effort* services.
Any non-trivial server has both:

- **Must-run, fail-fast** — the database connection pool, the metrics
  exporter, the HTTP server. If any of these die, the process should
  exit so its supervisor (CloudRun, k8s, systemd, the developer's
  terminal) can replace it.

- **Degradation-tolerant** — a webhook listener, an outbound integration
  to a flaky third-party API, an analytics shipper, a structure-sync.
  If any of these die, the rest of the process should continue and the
  failed entry should be marked degraded; surfacing the failure to
  monitoring is the consumer's job.

the predecessor design has no concept of either category — every service runs in
one flat `ServiceGroup` with one failure policy, which means a flaky
webhook listener can take down a healthy HTTP server. Backplane makes
the distinction first-class via subgroups. This is the *spine* feature
of subgroups; restart policy (`restartable: Bool` on `SubgroupPolicy`)
is a secondary attribute that only matters once you opt in to
restart-aware behaviour (§7).

### Design: subgroups as a first-class concept

A subgroup is a named partition of the entry set with its own failure and
restart policy:

```swift
public struct SubgroupTag: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension SubgroupTag {
    public static let core: SubgroupTag = "core"
}

public struct SubgroupPolicy: Sendable {
    public enum FailureMode: Sendable {
        /// A failure of any entry in this subgroup shuts down the
        /// outer process via the outer ``ServiceGroup``.
        case failFast
        /// A failure transitions the entry to ``.failed`` (or
        /// ``.degraded``) and leaves siblings running.
        case degraded
    }

    public enum CompletionMode: Sendable {
        /// Successful completion shuts down the outer process.
        case shutdownGroup
        /// Successful completion is ignored; siblings continue.
        case ignore
        /// Successful completion shuts down only this subgroup.
        case shutdownSubgroup
    }

    public let failure: FailureMode
    public let completion: CompletionMode

    /// Whether the graph honours ``ServiceGraph/restart(at:)`` requests
    /// for entries in this subgroup. Entries in non-restartable
    /// subgroups (e.g. one-shot task subgroups) cannot be hot-restarted.
    public let restartable: Bool

    public static let core = SubgroupPolicy(
        failure: .failFast, completion: .ignore, restartable: false
    )
    public static let integrations = SubgroupPolicy(
        failure: .degraded, completion: .ignore, restartable: true
    )
    public static let task = SubgroupPolicy(
        failure: .failFast, completion: .shutdownGroup, restartable: false
    )
}
```

### Implementation

Each subgroup maps to one inner `ServiceGroup` nested inside the graph's
`run()`. The graph starts subgroups in declaration order; `ServiceGroup`'s
natural LIFO shutdown then gives the right ordering: core services start
first and shut down last; integration services start last and shut down
first.

- A `.failFast` subgroup propagates its first error to the outer group,
  which cancels everything else.
- A `.degraded` subgroup catches per-entry errors and transitions only that
  entry, leaving siblings untouched.

### Example

```swift
@ServiceGraphBuilder
static func services() -> [EntryDescriptor] {
    // Core — fail-fast, not restartable.
    service(\.database,        label: "postgres") { ... }
    service(\.metricsExporter, label: "metrics")  { ... }

    // Integrations — degraded mode, restartable.
    service(\.slackWebhook, label: "slack",   subgroup: "integrations") { ... }
    service(\.s3Backup,     label: "s3",      subgroup: "integrations") { ... }

    // One-shot — completion shuts the group down.
    service(\.migration,    label: "migrate", subgroup: "task") { ... }
}
```

### Progressive disclosure

If you never mention subgroups, everything lands in `.core` with
`failFast` policy — the the predecessor design behaviour. The keyword `subgroup:`
on `service()` and the `subgroupPolicies:` argument on `ServiceGraph.init`
are both optional. Small services pay zero ceremony for the feature.

---

## 5. ServiceContext resolution semantics

### Resolution API

```swift
extension ServiceContext {
    /// Synchronous resolve. Returns nil only when the entry has never
    /// reached ``.running`` (first boot still in progress, or no
    /// configuration), or has reached a terminal state
    /// (``.stopped`` / ``.failed``).
    public func service<T>(_ keyPath: KeyPath<Services, T>) -> T?

    /// Async resolve that waits for the entry to reach
    /// resolution-ready. Throws ``ServiceGraphError/missingService``
    /// if the entry settles into a terminal non-running state.
    public func requireService<T>(
        _ keyPath: KeyPath<Services, T>
    ) async throws -> T

    public func firstService<T>(conformingTo type: T.Type) -> T?
    public func requireFirstService<T>(
        conformingTo type: T.Type
    ) async throws -> T
}
```

Two important properties (one enabled by §7's blue-green replacement,
one specific to first-boot factory cross-resolution):

- `service(\.x)` is nil-bearing only at the FSM endpoints
  (never-ran / stopped / failed). It is *not* nil during a replacement —
  blue-green keeps the old generation available throughout (§7).
  Optional return is therefore an honest signal: it means "the entry
  has never had a usable instance, or has been deliberately stopped."

- `requireService(\.x)` retains the boot-time `.starting`-with-instance
  resolution-ready semantics for first-boot factory cross-resolution.
  This handles the corner case where service A's factory calls
  `requireService(\.b)` and B's factory closure has returned an instance
  but B's `start()` hasn't yet finished. Resolving against the
  not-yet-fully-started instance is the documented behaviour: the consumer
  captures the reference, B's `start()` completes in parallel, and by the
  time A actually *calls* methods on B those methods are ready.

### Cycle detection

The the predecessor design `ApplicationRunner` already topologically sorts entries
via declared dependencies. Backplane keeps that: `EntryDescriptor`
carries `dependencies: [AnyKeyPath]`, and `ServiceGraph.init` performs a
topological sort. A cycle throws `ServiceGraphError.cyclicDependency(path:)`
at construction — before any service runs.

Runtime `requireService` calls inside `start()` (after the factory has
returned) are not statically checkable. The graph doesn't try; cycles
introduced at runtime time out (via the standard `requireService` timeout)
rather than deadlocking.

### `service(_:)` from non-async contexts

The graph's synchronous lookup is `nonisolated` — backed by a `Mutex`
inside each entry rather than an actor hop. This matches the Acumen design
and is load-bearing for any callers in non-async contexts: timer
callbacks, property wrapper getters, Combine sinks. Forcing an actor hop
for every service lookup would be a significant ergonomic and performance
regression.

---

## 6. Service-driven health reporting

This section is in the spine — `markDegraded` / `markHealthy` is useful
at any deployment shape, including (a) cloud microservices that surface
partial degradation to monitoring without dying. The §7 restart-aware
machinery is *not* a prerequisite — a service can self-report
degradation, have it picked up by monitoring, and never be restarted
at all.

### The gap

The lifecycle model so far has three actors:

- The **graph** drives transitions: boot, start, replace, stop.
- A **service** signals hard failure during `start()` by throwing.
- A **consumer** observes the resulting state via `stateStream()`.

What is missing is the case where a *running* service learns it is
unwell but isn't dead. Plausible examples:

- A database client whose connection pool has just lost its primary
  replica and is now serving from a stale read replica.
- An HTTP client whose upstream has been returning 503s for the last
  thirty seconds.
- A worker whose queue depth has crossed a saturation threshold.
- A cache that is operating but whose hit rate has collapsed because
  an upstream invalidation flood drained it.

None of these are reasons for the graph to tear the instance down. The
service is still answering, and a fresh replacement may not help (the
upstream is the problem, not the local instance). But the *entry's
visible state should change* so:

- Operators see the issue.
- Higher-level supervisors can decide whether replacement is warranted.
- Admin tooling can surface a degradation banner.
- Log scrapers can correlate the timestamp with the upstream incident.

Today the service has no way to express this. Backplane adds one.

### `ServiceHealthReporter`

Each service receives a `ServiceHealthReporter` via its `ServiceContext`.
The reporter affects only the service's own entry — it cannot reach
siblings.

```swift
/// Self-report channel for a service to signal its own degradation.
///
/// Distinct from ``ServiceLifecycleHandle`` (read-only, consumer-side).
/// The two protocols are split so a service cannot accidentally observe
/// its own state through the same handle it reports on — and so the
/// reporter can carry write-only methods without confusing the
/// observer's API surface.
///
/// Both methods are ``nonisolated``. State lives behind the per-entry
/// mutex (the same one that protects lifecycle state and the active
/// generation pointer); a service reporting health from a hot path
/// pays no actor hop. State-stream subscribers are notified after the
/// mutex is released — nested locking does not occur.
public protocol ServiceHealthReporter: Sendable {
    /// Transition the entry's reported state to ``.degraded(fault:)``
    /// without affecting the running instance. The instance keeps
    /// serving; only the externally-observable state changes.
    ///
    /// Valid only when the entry is in a resolution-ready state
    /// (``.starting``, ``.running``, ``.degraded``, ``.replacing``).
    /// Calls from any other state are no-ops — a service mid-shutdown
    /// or in ``.failed`` cannot drag the entry back into ``.degraded``.
    /// Repeated calls with the same fault description deduplicate;
    /// calls with a different fault overwrite (last write wins).
    nonisolated func markDegraded(fault: ServiceFault)

    /// Transition back to ``.running`` if the entry is currently
    /// ``.degraded``. No-op for any other state — markHealthy() cannot
    /// promote a service out of ``.failed`` or ``.stopped``.
    nonisolated func markHealthy()
}

extension ServiceContext {
    /// Self-report channel for this service.
    public var health: any ServiceHealthReporter { get }
}
```

### Worked example

```swift
final class PostgresService: ManagedService, Sendable {
    let client: PostgresClient
    let context: ServiceContext

    func start() async throws {
        try await client.run()
        // Subscribe to connection-pool health events.
        Task { [client, health = context.health] in
            for await event in client.poolEvents {
                switch event {
                case .primaryLost(let cause):
                    health.markDegraded(fault: ServiceFault(
                        description: "Postgres primary unreachable",
                        errorType: "PostgresConnectionError",
                        firstObservedAt: Date()
                    ))
                case .primaryRecovered:
                    health.markHealthy()
                }
            }
        }
    }

    func shutdown() async { await client.shutdown() }
}
```

### What the graph does (and does not do) with a degradation report

- **Does:** update the entry's `ServiceState` to `.degraded(fault:)`.
- **Does:** yield the new state to every stream subscriber.
- **Does:** keep routing resolves to the live instance — degradation
  is a health signal, not a routing change. The service's job continues.
- **Does not:** automatically trigger replacement. Whether to restart
  a degraded entry is operational policy. Backplane ships the
  primitive; consumers ship the policy.
- **Does not:** escalate to `.failed` after some duration. A degraded
  service stays degraded until either it reports `.markHealthy()` or
  an explicit `restart(at:)` is issued.

A consumer that wants "auto-replace after N seconds of sustained
degradation" writes a supervisor task that subscribes to the lifecycle
stream and calls `graph.restart(at:)`. Five lines of code; not a
framework concern.

### Symmetry with consumer-side `ServiceLifecycleHandle`

The two protocols intentionally do not share a type:

|                            | `ServiceLifecycleHandle` (consumer) | `ServiceHealthReporter` (service self) |
|----------------------------|-------------------------------------|----------------------------------------|
| Direction                  | Read                                | Write                                  |
| Access                     | Anyone via `ServiceContext.lifecycle` of any entry | Only the entry's own service via `ServiceContext.health` |
| Methods                    | `state`, `stateStream()`, `requestRestart()` | `markDegraded(fault:)`, `markHealthy()` |
| Concurrency                | Mixed (async for `state`/`requestRestart`, sync for `stateStream`) | `nonisolated` |

The asymmetry — observer is mixed, reporter is fully `nonisolated` — is
deliberate: services report from hot paths and shouldn't take actor
hops; consumers observe from event-driven points where actor hops are
acceptable.

### Per-entry mutex pattern, generalised

This change generalises an internal pattern already used by `resolve(_:)`:
synchronous access to per-entry state via a `Mutex<State>` on each
entry, with `nonisolated` reads and writes that yield to stream
subscribers after the lock is released. The `ServiceGraph` actor still
owns the *graph-level* invariants (descriptor set, subgroup
membership, dependency topology, restart serialisation), but per-entry
state — current generation pointer, lifecycle state, health state — is
protected by the entry's own mutex.

This means three things are now `nonisolated` on `ServiceGraph`:

- `resolve(_:)` — synchronous service lookup.
- `state(of:)` — current state read.
- `ServiceHealthReporter` methods — self-report.

Together they form a coherent contract: any read or write that pertains
to a single entry's current state can happen without an actor hop. The
actor exists for graph-wide operations (boot, replace, descriptor
validation), not for per-entry hot paths.

---

## 7. Restart-aware behaviour (optional)

> **Reader, route yourself.** If you're deploying to CloudRun, k8s, or
> any CI-orchestrated environment with healthy replica counts, you can
> skim or skip this section — the orchestrator owns restart, and
> nothing in this section is reached unless your code explicitly calls
> `restart(at:)` / `reload(at:)` or your service conforms to
> `HotReloadable`. Read this section if any of the following apply:
> (a) you've been burned by a stuck database client, gRPC channel, or
> message-broker consumer that survived a process-level health check
> but stopped doing useful work; (b) you're deploying to a single-binary
> target (Pi, NAS, on-prem) where the process owns restart; (c) you're
> building a framework that orchestrates sub-services inside one
> process. The default blue-green strategy costs nothing if never
> exercised — it just sits behind `restart(at:)` waiting for someone to
> call it.

### The problem with cold restart

Cold restart means: tear the old instance down (`shutdown`), then start a
new one (`init` + `start`). Between those two events, no instance exists.
Callers landing in that gap have three bad options:

1. **Block** — wait for the new instance. Latency spikes, requests pile up.
2. **Fail** — return an error. Cascading failures upstream.
3. **Use a sentinel** — return a typed handle whose every method throws.
   This is what Acumen does today; it works but is structurally noisy: one
   sentinel conformer per role protocol, a runtime branch in
   `currentHandle()`, and an error taxonomy (`unconfigured`, `restarting`,
   `degraded`, etc.) that exists only to describe the gap.

The sentinel is a symptom. The real defect is that cold restart creates a
gap in the first place. Eliminate the gap and the sentinel becomes
unnecessary.

### Blue-green replacement

Modelled on the Cloud Run / blue-green deployment pattern. When an entry
is restarted:

1. The old generation continues serving. Its state inside the entry
   stays `.running`. Resolves landing on the entry get the old generation.
2. A new generation is started in parallel — fresh factory invocation,
   fresh `start()`. The new generation's per-generation state is
   `.starting`; the entry's state becomes `.replacing`.
3. When the new generation's `start()` returns successfully, the graph
   atomically swaps the "active" generation pointer. New resolves get the
   new generation; existing references to the old generation keep working.
   The entry's state returns to `.running`.
4. The old generation enters a `.draining` substate. After a grace period
   (the swap point + `grace`), the graph calls `shutdown()` on the old
   generation. Any in-flight reference still using it gets cut off — but
   if callers re-resolve any time after the swap, they get the new one.
5. If the new generation's `start()` throws, the new generation is
   discarded. The old continues serving. The entry's state transitions to
   `.degraded` with the new generation's fault as the cause; a future
   `restart` can try again.

The contract is: *at any time after the entry has reached `.running` once,
`resolve(\.x)` returns a live, usable instance.* No sentinel needed —
either the new generation, or the old one mid-drain. The only times
`resolve` returns nil are before first boot and after `.stopped` /
`.failed`. Those are clearly observable conditions, expressed as
`Optional` rather than as a throwing handle.

### `restart(at:)` return semantics

`ServiceGraph.restart(at:)` returns as soon as the entry has been
transitioned to `.replacing` and the replacement task has been spawned.
It does **not** await the swap. The new generation may still be
constructing (`factory()`) or starting (`start()`) when the call
returns. The actor is held only briefly — long enough to validate the
entry state, flip it to `.replacing`, and hand work to a detached task.

Callers that want to wait for the swap to complete subscribe to the
lifecycle stream and observe `.running` (or `.degraded`):

```swift
await graph.restart(at: "x")
for await state in graph.stateStream(of: "x") {
    if state == .running { break }                         // swap done
    if case .degraded = state { break }                    // start() failed
}
```

This is deliberate. Awaiting completion would hold the actor through the
entire start sequence (typically slow — schema checks, upstream
handshakes, connection-pool warm-up), serialising every other actor
operation behind one restart. The lifecycle stream is the right tool
for "tell me when the swap landed."

### Initialisation failure on replacement

Step 5 above is worth expanding: a major reason previous designs forced
full teardown is that some services do non-trivial setup in `start()` —
schema checks, certificate validation, upstream handshake — that can
fail. With cold restart, if the new instance's `start()` throws, the
service is already gone (the old one was torn down first) and the
process is left without it.

Blue-green inverts the cost model: the new instance's `start()` is
attempted *while the old one is still serving*. Failure modes:

- **`start()` throws synchronously** — the new generation is discarded
  immediately. The old continues. The entry's state becomes
  `.degraded(fault:)` carrying the new generation's error so admin
  tooling and log scraping can pick it up. The `.replacing` state is
  exited; the entry is back at `.degraded` (or `.running` if the prior
  state was `.running` — see resolution rules below).
- **`start()` hangs / doesn't return** — the graph times out the new
  generation's `start()` (default 60s; configurable per service). The
  pending generation is cancelled and discarded; the old continues.
  Lifecycle stream emits `.degraded(fault: .startTimedOut)`.
- **`start()` returns successfully but the new instance is broken**
  (passes init, fails at first real call) — undetectable at swap time
  by definition. The new instance reports itself degraded via
  `ServiceHealthReporter` (see §6); a consumer-level supervisor can
  react.

The graph does **not** retry automatically. The next replacement is
explicitly triggered via `graph.restart(at:)`. Consumers that want
retry-with-backoff write a thin supervisor task that watches the
lifecycle stream and re-issues `restart(at:)` on `.degraded` events
according to whatever policy fits. This is deliberately not a
framework feature — retry policy is an operational concern with too
many local optima for one default to be right.

After a configurable threshold of consecutive failed replacement
attempts (default: 5 within a 10-minute window), the graph transitions
the entry to `.failed`. This is the only state from which automatic
recovery is *not* attempted; `.failed` requires an explicit operator
action. The threshold values are constants in the graph and not part
of the public surface in v1 — see §11.12.

### The `ReplacementStrategy` enum

Three strategies, declared per service:

```swift
public enum ReplacementStrategy: Sendable {
    /// Spin up a new generation alongside the old; swap atomically
    /// once the new one's ``start()`` returns; drain the old for
    /// up to ``grace`` before its ``shutdown()`` runs.
    ///
    /// **Default.** Suitable for the majority of stateless or
    /// externally-stateful services.
    case blueGreen(grace: Duration)

    /// Apply new configuration in place via the ``HotReloadable``
    /// protocol. No new generation; the existing instance reads
    /// new settings atomically.
    ///
    /// Cheapest. Requires that the service support runtime
    /// reconfiguration without service-level state change.
    case hotReload

    /// Tear down the old instance before starting the new one.
    /// Necessary for services that conflict on resources two
    /// instances can't share — bound TCP ports, exclusive file
    /// locks, single-writer database connections.
    ///
    /// Callers landing in the gap get nil from ``resolve``; they
    /// can subscribe to the lifecycle stream to know when the
    /// new instance arrives.
    case coldRestart
}
```

The default is `.blueGreen` with a 30-second grace, deliberately. The
overwhelming majority of services *can* tolerate brief coexistence of two
instances — they don't bind exclusive resources. Defaulting to blue-green
gives the no-gap property for free; services that genuinely can't coexist
declare `.coldRestart` explicitly.

### `HotReloadable` — opt-in protocol

```swift
/// Optional protocol for services that support in-place reconfiguration.
///
/// When ``ServiceGraph/reload(at:)`` is called for an entry whose
/// service conforms to ``HotReloadable``, the graph calls
/// ``reload(config:)`` instead of starting a new generation. The
/// service is responsible for atomic application of the new config.
///
/// If ``reload(config:)`` throws, the graph transitions the entry to
/// ``ServiceState/degraded`` and (depending on the service's
/// ``replacementStrategy``) may schedule a blue-green replacement.
///
/// Thread safety: ``reload(config:)`` runs while the service is
/// ``.running``. If the service is an actor, the call is actor-isolated.
/// If the service is a `Sendable` class, the graph serialises the call
/// through its own actor.
public protocol HotReloadable: ManagedService {
    func reload(config: ConfigReader) async throws
}
```

`HotReloadable` is independent of `ReplacementStrategy`. A service can
declare both — `replacementStrategy = .hotReload` says "config changes
prefer hot reload; if reload fails, escalate to blue-green." A service can
also declare `.hotReload` *without* conforming to `HotReloadable` (this is
a programmer error; the graph detects and falls back to blue-green with a
logged warning).

#### What hot-reload is for

The point of `HotReloadable` is not theoretical. A non-trivial slice of
"configuration changes" that consumers traditionally associate with
restarts are actually hot-reloadable. Concrete examples that fit cleanly:

- **TLS certificate rotation** — the most common production case.
  Production deployments rotate certs frequently; bouncing the service
  every time is operationally noisy and erodes the no-gap property.
  A `HotReloadable` HTTP server reads its new cert and updates its
  `TLSConfiguration` atomically; in-flight connections complete on the
  old cert, new connections negotiate the new one.
- **Log-level changes** — adjusting verbosity at runtime to diagnose a
  live issue.
- **Feature-flag updates** — toggling behaviour without dropping
  connections.
- **Timeout / retry budget tuning** — adjusting client-side budgets.
- **Rate-limit ceilings** — raising or lowering caps without resetting
  bucket state.
- **Allow / deny lists** — adding or removing entries without
  invalidating active sessions.

What is **not** a hot-reload candidate:

- Changing the backing store (Postgres host swap, Redis cluster
  migration).
- Changing the network protocol (HTTP/1.1 → HTTP/2, plain → TLS).
- Changing the listening port.
- Anything that resets in-memory state by design (cache invalidation,
  session-table wipe, queue purge).

A service whose configuration change falls in the second list declares
`.blueGreen` (or `.coldRestart` if it conflicts on resources). The
choice between `.hotReload` and `.blueGreen` is a real one — the
service author decides on a per-config-key basis whether the change
shape fits in-place application.

### Choice matrix

| Service shape                          | Strategy        |
|----------------------------------------|-----------------|
| Stateless HTTP handler                 | `.blueGreen`    |
| Database connection pool               | `.blueGreen`    |
| Service that adjusts a tuning value    | `.hotReload`    |
| Service holding a logger level         | `.hotReload`    |
| HTTP server bound to a fixed port      | `.coldRestart` (or `.blueGreen` with `SO_REUSEPORT`) |
| Singleton with exclusive file lock     | `.coldRestart`  |
| Migration that mutates schema          | `.coldRestart` (one-shot, not restarted) |

### Generation tracking — internal

```swift
package final class ServiceEntry: Sendable {
    package let descriptor: EntryDescriptor

    /// Atomically swapped pointer to the active generation.
    /// `resolve(\.x)` reads through this. Backed by `Mutex<Generation?>`.
    private let _active: Mutex<Generation?>

    /// Draining generations, indexed by their start instant. The
    /// graph removes them when their grace period elapses.
    private let _draining: Mutex<[Generation]>

    // ... continuations, lifecycle handle, etc.
}

package final class Generation: Sendable {
    let id: UInt64                // monotonic per entry
    let instance: any ManagedService
    let startedAt: Date
    let state: Mutex<GenerationState>
}

package enum GenerationState: Sendable {
    case starting
    case running
    case draining(swapAt: Date, deadline: Date)
    case stopping
    case stopped
    case failed(fault: ServiceFault)
}
```

The `_active` mutex makes the swap a single atomic write. Readers of
`resolve(\.x)` see either the old generation (until the moment of swap) or
the new one (after); never both, never nothing.

### What this dissolves

The `.starting`+instance lesson from Acumen (boot-deadlock fix where
factories that need each other don't have to wait for full `.running`)
still applies at *first boot only*. For all subsequent replacements, the
question doesn't arise — there's already a running generation, so a factory
calling `requireService` resolves against it immediately, regardless of
what generation the dependent entry is currently building.

Sentinels disappear entirely. Their entire reason to exist — bridging the
gap during restart — has no gap to bridge.

Hot restart (Acumen's `IntegrationRegistry.restart`) maps to
`ServiceGraph.restart(at:)`. Its semantics are stronger: with blue-green
the default, callers don't observe a service-unavailable window.

### Recovering from a stuck instance

A second motivation for restart, distinct from configuration change, is
*recovering from a service whose internal state has rotted* — a connection
pool deadlocked on a half-closed socket, a worker whose queue thread has
silently died, a client whose retry loop has wedged. The instance is
still answering `.running` but doesn't function. Operators need to
replace it.

Blue-green handles this case naturally with no extra mechanism:

- `ServiceGraph.restart(at:)` starts a fresh generation alongside the
  stuck one. The fresh instance's `start()` builds new connections, new
  threads, new state — entirely independent of whatever the stuck
  instance is doing internally.
- The atomic swap routes new resolves to the fresh instance. New work
  flows through it from that moment on.
- The stuck instance enters draining. Its `shutdown()` is called after
  the grace period. **If `shutdown()` itself hangs** (as is likely for
  a deeply stuck instance), the graph cancels the `shutdown()` task at
  grace expiration. The instance is leaked at the GC / task level — but
  the entry has long since moved on. No subsequent restart is blocked
  by it.

This is the explicit answer to "killing off a dead client": you don't
need to. You start a new generation; the dead one is no longer in the
serving path within milliseconds; whatever it does next is invisible to
callers. The grace window means even an unresponsive `shutdown()` is
bounded.

Cold restart is structurally worse for this case. With `.coldRestart`,
the graph must first call `shutdown()` on the stuck instance and wait
for it to return before constructing the new one. A wedged `shutdown()`
blocks the whole restart. The consumer ends up writing a timeout
supervisor outside the graph to kill the process and let the supervisor
restart it. Blue-green absorbs that supervisor into the graph.

### When blue-green is wrong

Two cases where blue-green won't fit naturally:

1. **Resource exclusivity** — two instances can't coexist. The declared
   `.coldRestart` strategy handles this; the consumer accepts a brief
   nil-resolve window. The graph documents this clearly.

2. **State carry-over** — the service has expensive in-memory state (a hot
   cache, an active session table) that should survive the swap. Backplane
   does not provide a state-transfer protocol. Recommendations:
   - Externalise the state (Redis, disk).
   - Use `.hotReload` if the reconfiguration doesn't require resetting
     state.
   - Accept rebuild cost on blue-green swap.

   A handoff protocol where v2 reads state from v1 before the swap is
   appealing but invites a long tail of failure modes (what if v2's read
   throws? what if the state shape diverges across versions?). Out of
   scope for v1.

### Swap-and-notify ordering

Implementation note relevant to anyone building the inner machinery:
the order in which the active-generation pointer is swapped and the
state-stream subscribers are notified matters for race-free
cross-service resolution.

When boot transitions an entry to `.starting`, the sequence inside the
entry's per-entry mutex must be:

1. Build the new `Generation`.
2. Swap the active-generation pointer to it (so `resolve(\.x)` returns
   the new instance).
3. *Then* yield the `.starting` event to stream subscribers.

If the order is reversed — notify subscribers of `.starting` *before*
the swap — an observer woken by the event reads a nil active pointer
and ends up waiting for the next transition (`.running`, which arrives
after `start()` completes). The boot-deadlock fix the design relies
on (`.starting`+instance is resolution-ready) collapses back into
"wait for `.running`" by accident.

The swap-then-notify ordering preserves the design's contract that
the resolution-ready states (`.starting`, `.running`, `.degraded`,
`.replacing`) all imply a live `Generation` is reachable through the
active pointer at the moment the event fires. This is load-bearing
for cross-service resolution during boot; document it in the
implementation guide.

A related implementation detail: the synchronous handle accessor on
each entry (`currentHandle<T>()` / `currentManagedService()`) must
gate on entry state, not on the active pointer alone. A service whose
factory ran successfully but whose `start()` later failed sits in
`.failed` while the active pointer still references its (now-dead)
instance until the failure transition runs. Filtering on
`isResolutionReady` inside the handle accessor ensures `.failed` and
`.stopped` entries return nil even between the failure observation and
the active-pointer clear.

---

## 8. No sentinels

This section was a recommendation in the first draft; with §7 in place it
becomes definitive.

### Why no sentinels

A sentinel is a typed instance whose every method short-circuits to an
error (`IntegrationError.unconfigured`, `.restarting`, etc.). Sentinels
exist to keep `@ServiceReader` accesses non-Optional in component trees
that may run during service transitions.

With blue-green replacement, there is no `.restarting` gap. The cases that
remain — never-booted, stopped, failed — are honest absences. Returning
`Optional<T>` from `resolve(\.x)` for those cases is structurally truthful
and forces the consumer to acknowledge them.

The decision-tree for a consumer becomes:

```swift
guard let svc = context.service(\.myService) else {
    // Entry has never been usable. Three possibilities:
    //   - First boot still in progress (early in app lifecycle)
    //   - Admin stopped the entry
    //   - Entry settled into .failed
    // Subscribe to lifecycle stream to wait or report.
    return
}
// Live instance — use it. Even if a restart is in flight,
// this reference works until at least the next grace boundary.
```

The cost of dropping sentinels: callers that previously wrote `@ServiceReader(\.x) var svc` and called methods without checking now write `context.service(\.x)` with an `Optional` unwrap. That is the right pressure — the optional makes the failure mode explicit at the call site.

### Sentinel-style ergonomics for consumers that want them

A consumer (e.g. a component framework) can build a non-optional reader on
top of Backplane's optional-returning primitives with minimal effort:

```swift
// In the consumer's module, not in Backplane.
public struct LiveOrFallback<T: ManagedService>: Sendable {
    private let graph: ServiceGraph
    private let keyPath: KeyPath<Services, T?>
    private let fallback: T

    public func current() -> T {
        graph.resolve(keyPath) ?? fallback
    }
}
```

Backplane doesn't provide this because it doesn't need to. The framework
gives the optional; the consumer wraps it however suits their consumption
pattern.

### What about `IntegrationError`?

`ServiceGraphError` covers the cases Backplane needs:

```swift
public enum ServiceGraphError: Error, Sendable {
    /// No entry registered at the keypath.
    case missingService(keyPath: String, expectedType: String)

    /// No registered service conforms to the requested protocol type.
    case missingConformer(type: String)

    /// A cyclic dependency was detected at graph construction.
    case cyclicDependency(path: [String])

    /// An entry's lifecycle has transitioned to a terminal state
    /// while a caller was awaiting resolution.
    case entryTerminated(keyPath: String, state: ServiceState)
}
```

The `restarting` / `unconfigured` cases that bloat Acumen's
`IntegrationError` are gone. Restart isn't observable at the resolve layer
(blue-green dissolves it), and "unconfigured" is just "stateful equivalent
of nil" — `service(\.x)` returns nil. Consumers that want to differentiate
*why* the entry isn't live read the lifecycle state directly.

---

## 9. Range of supported consumers

A spot-check that the design above accommodates the breadth of imagined
consumers — from a one-binary CLI to a long-running framework — without
either end paying for the other's complexity.

### One-Service CLI

```swift
extension Services {
    public var httpKey: ServiceKey<MyHTTPServer> { ServiceKey(id: "http") }
}

@main
struct App: BackplaneApplication {
    typealias RootCommand = Serve
    static let identifier = "app"

    static func services() -> [EntryDescriptor] {
        [
            EntryDescriptor(Services().httpKey) { _ in
                PassiveService(MyHTTPServer())
            },
        ]
    }
}

struct Serve: PersistentCommand {
    typealias App = App
    var requiredServices: [AnyKeyPath] { [\Services.http] }
}
```

No subgroups, no replacement-strategy declaration (default blue-green is
fine), no hot reload, no namespaces beyond `Services`. The cost surface is
exactly what a single-service consumer expects.

### Multi-command service with mixed lifetimes

The §3.4 example — `serve` / `migrate` / `admin` over one descriptor set,
each command pulling its own subset. Migrations land in the `task`
subgroup so their completion gracefully shuts down the group; `serve`
and `admin` use `core`.

### Component framework (Acumen-shaped)

The patterns Acumen needs are all expressible:

- **Per-entry FSM** — `ServiceState` carries it; `ServiceLifecycleHandle`
  exposes it.
- **Typed keys on `Services`** — Backplane ships exactly one
  namespace; a framework that needs more (e.g. an `Agents` population)
  defines its own struct + `requireService` overloads on top of the
  same `ServiceGraph` runtime (§11.5).
- **Hot restart** — `ServiceGraph.restart(at:)` triggers replacement using
  the service's declared strategy (typically blue-green).
- **Hot config reload** — `ServiceGraph.reload(at:)` for `HotReloadable`
  services.
- **ServiceReader** — `ServiceContext.service(\.x)` from any context the
  framework threads through. Acumen-style "always non-optional" reader is
  a thin wrapper in Acumen's layer over Backplane's optional-returning
  primitive.
- **Sentinels** — not needed (§8); Acumen sheds them when it adopts
  Backplane.
- **Subgroups for distinct failure policies** — `core` / `integrations` /
  `task` patterns map cleanly.
- **Conformance-based lookup** — `firstService(conformingTo:)` matches
  Acumen's `runningRegisterables` use case.

### Satellite targets

Backplane's package already ships satellite targets — `BackplanePostgres`,
`BackplaneOTel`, `BackplaneGCP`, `BackplaneMetrics` — that bundle SSWG
libraries behind a Backplane-shaped façade. Two more are planned as
satellite targets in the Backplane family, each opt-in via its own
`import`:

- **`BackplaneVault`** — writable, encryption-aware config persistence.
  An augmentation of swift-configuration's read-only `ConfigReader`
  with a write path, secret-aware fields, and persistence to disk.
  Useful where a service learns state at runtime that needs to survive
  process restart and is sometimes sensitive (OAuth tokens, learned
  device addresses, last-known-good credentials). Designed in
  `docs/design/backplane-vault.md`.

Satellite-target placement keeps the core lightweight: a one-service
CLI that imports `Backplane` gets registry + lifecycle + typed keys,
nothing more. Consumers that need encrypted persistence add
`BackplaneVault` to their `Package.swift`.

### What's deliberately *not* in Backplane (even as a satellite)

These are framework-specific concerns the consumer keeps. Backplane
provides primitives, the consumer builds the ergonomics:

- Role taxonomy (Acumen's `Service` / `Agent` distinction).
- Device-mapping APIs (Acumen's `AgentContext.mapDevice`).
- Component-DSL property wrappers (`@ServiceReader`).
- Per-role admin RPC surfaces (Acumen's `IntegrationAdmin` gRPC service).
- Tree-snapshot capture, broadcast streams, event injectors.

Putting any of these in Backplane would chain Backplane to one framework's
shape.


## 11. Open questions

The behaviour of the blue-green grace period (default 30s) and of a
hung `shutdown()` (cancel-and-log at grace expiration) are documented
inline — see §7 — and no longer appear here as open questions.

Items marked **[§7-tier]** apply only to consumers using the
restart-aware machinery in §7 (blue-green replacement, `restart(at:)`,
`HotReloadable`, the `.task` subgroup completion modes). Consumers
operating purely against the §2–§6 spine — typed keys, dependency boot,
resolution, health reporting — can skip them.

### 11.1 Macro: not shipped

**Resolved.** Backplane does not ship a `@Register` (or equivalent)
peer macro. Earlier drafts of this design carried one behind a
`Macros` package trait. Once the consumer-facing surface became
`extension Services { var fooKey: ServiceKey<T> { ... } }` — a single
line whose readability is identical to the macro's expansion — the
macro stopped earning the `swift-syntax` dependency it imposed. A
consumer who finds the per-key declaration verbose can write their
own peer macro on top of Backplane in a few hundred lines and bring
their own `swift-syntax`.

### 11.2 What signals "new generation is healthy enough to swap"? [§7-tier]

This design says: `start()` returns successfully. No separate readiness
check.

Alternatives:
- An `isReady` async property that the graph polls.
- A `waitForReady()` method.
- A separate `ServiceLifecycle.Service`-style "first event" signal.

**Lean:** Keep the design's answer. `start()` returning is the contract:
the service is responsible for not returning until it can serve. Services
that need warm-up perform it in `start()`. Adding a separate readiness
signal invites the "ready but not really" failure mode common in
distributed systems.

### 11.3 Should `dependencies:` be richer than `[AnyKeyPath]`?

A richer `Dependency` type could carry: keypath, required-vs-optional,
factory-time-vs-runtime, replacement-cascade flag.

**Lean:** Start with `[AnyKeyPath]` meaning "required at factory time."
Add structure when the simple model demonstrably fails — most consumer
graphs are shallow.

### 11.4 Naming: `ManagedService` vs `Service`

`ManagedService` avoids collision with `ServiceLifecycle.Service`, but is
verbose. The collision is one import away because Backplane re-exports
`ServiceLifecycle`. Frameworks that have done this rename (Acumen
qualified ~9 sites as `AcumenIntegration.Service`) report the cost as
mechanical and grep-friendly, not painful.

**Lean:** `ManagedService` for the initial release. The cost is in
writing slightly longer protocol conformances; the benefit is consumers
can `import Backplane` without thinking about module qualification.
Rename to plain `Service` later if the qualification burden proves
manageable.

### 11.5 Consumer namespaces beyond `Services`

Backplane ships one namespace (`Services`). The runtime indexes on
`AnyServiceKey` (a string id), and `ServiceContext` exposes
keypath overloads typed against `Services`. A consumer that wants a
parallel namespace (an `Agents` population, an RPC-services
namespace, etc.) defines its own struct, adds matching
`requireService` overloads, and conforms the keys' value type to
`ServiceKeyConvertible` — the existing protocol Backplane uses to
erase a typed `ServiceKey<T>` back to `AnyServiceKey` at the
dependency-list boundary. The open question is whether Backplane
should ship a shared `ServiceNamespace` marker protocol to formalise
this, or leave it as a documented extension point.

- **(A)** Ship nothing beyond the runtime contract. Consumer macros
  generate their own bespoke key-type plumbing.
- **(B)** Ship a `ServiceNamespace` marker protocol plus a small
  `NamespacedKey` helper that consumer macros can use to produce
  `AnyKeyPath`-keyed entries.

**Lean:** (A) until a second consumer macro is in flight. There is
exactly one known consumer that wants this (Acumen), and shipping a
shared helper before there's a second consumer is premature
abstraction.

A separate, narrower question: should namespaces map to *separate*
`ServiceGraph` instances, or to one graph that resolves across
multiple namespaces? Backplane takes no position — the runtime's
`AnyKeyPath` keying means either pattern works; the consumer picks.

### 11.6 Per-entry config layering

Per-entry config layers: per-entry file > per-entry default >
project-wide. The file is discovered how?

- **(A)** Convention: `<configRoot>/<subgroup>/<leafName>.json`.
- **(B)** Explicit: declared by the `EntryDescriptor`'s `configFile:`
  parameter.
- **(C)** None — entry config is in-memory only via `defaultConfig`,
  and project-wide is for everything else.

**Lean:** (A) with (B) as override. The convention makes admin tooling
simple, and the override slot exists for unusual cases.

### 11.7 Anonymous (non-keypath) descriptors

The `BootstrapPlan.lifecycleServices` pattern from the predecessor design —
pre-built services with no keypath identity, running alongside named
entries — should be supported.

**Lean:** Yes, via `EntryDescriptor` with `keyPath: nil`. Anonymous
entries participate in the inner `ServiceGroup` but aren't resolvable
via `service(\.x)`. Use cases: OTel exporters, log shippers, signal
handlers, anything that needs lifecycle integration but no consumer
lookup.

### 11.8 Should the graph own the outer `ServiceGroup`?

Currently `ApplicationRunner` builds the outer group, adds bootstrap
lifecycle services, adds the graph, optionally adds a
`CommandExecutionService` for task mode. The graph itself runs an
inner group.

Alternative: the graph owns the outer group too, `ApplicationRunner`
shrinks to "build graph, call run."

**Lean:** Keep `ApplicationRunner` as the orchestrator. The outer
group has non-graph services in it (bootstrap exporters, the task-mode
execution service); those belong to a level the graph shouldn't have
to know about.

### 11.9 What does `state(of:)` return for a not-yet-booted entry?

Before `boot()` runs, every entry is conceptually `.unconfigured` (or
`.starting` once the boot task has begun, but before it has resolved).
Is this state observable, or does `state(of:)` block until first
transition?

**Lean:** Non-blocking. Pre-boot entries return `.unconfigured`. The
lifecycle stream's first element is whatever the current state is at
subscription time. Consumers that want to react to "entry has become
live" filter on `.running`.

### 11.10 `@MainActor`-isolated services?

Some services (e.g. an in-process UI binding) need `@MainActor`.
the predecessor design has no support; the design above is `Sendable`-only.

**Lean:** Out of scope for v1. Document that `ManagedService` requires
`Sendable`, which excludes `@MainActor`-isolated services. A future
extension could add a `MainActorService` variant.

### 11.11 Restart-retry policy [§7-tier]

When a replacement's `start()` fails, the graph leaves the entry
`.degraded` and does not retry. The next replacement requires an
explicit `restart(at:)` call. Should Backplane ship a retry-with-backoff
supervisor, or leave it entirely to consumers?

- **Ship it:** consumers get a sensible default ("retry 3 times with
  exponential backoff, then escalate to `.failed`"). One less thing to
  build.
- **Don't ship it:** retry policy is operational; one size doesn't
  fit. A persistent-connection service wants exponential backoff with
  jitter; a one-shot migration wants immediate failure; a flaky
  upstream wants circuit-breaker semantics. Backplane shipping a
  default would push consumers to layer their own on top, which is
  worse than nothing.

**Lean:** Don't ship it. Backplane exposes `restart(at:)` and the
lifecycle stream; consumers wire whatever supervisor matches their
operational shape. A reference implementation in the Backplane DocC
catalog is fine; it doesn't need to be in the framework binary.

### 11.12 Replacement-failure escalation threshold [§7-tier]

§7 mentions "after a configurable threshold of consecutive failed
replacement attempts (default: 5 within a 10-minute window), the graph
transitions to `.failed`." Two sub-questions:

- Should the threshold be configurable per-service (on
  `EntryDescriptor`) or graph-wide (on `ServiceGraph.init`)?
- Should `.failed` be a terminal state requiring operator intervention,
  or should the graph auto-recover from `.failed` after a longer
  cool-down?

**Lean:** Graph-wide config in v1; per-service if a clear use case
emerges. `.failed` is terminal — consumers explicitly issue
`restart(at:)` to leave it. Auto-recovery from `.failed` blurs the
line between transient and permanent failure.

### 11.13 Health-report rate limiting

`ServiceHealthReporter.markDegraded(fault:)` and `markHealthy()` are
`nonisolated`. A pathological service could call them at request
frequency. Should the graph rate-limit stream emissions, deduplicate
consecutive identical reports, or trust the caller?

**Lean:** Deduplicate identical consecutive states (don't emit on
`.degraded(X) → .degraded(X)`); otherwise trust the caller. Rate
limiting is a different concern — stream backpressure handles bursty
emissions; deduplication is the cheap correctness improvement that
also avoids noise on subscribers.

### 11.14 `ManagedTaskService` for one-shot subgroup completion [§7-tier]

The `SubgroupPolicy.CompletionMode` cases (`.shutdownGroup`,
`.shutdownSubgroup`, `.ignore`) are intended for one-shot work like a
migration, where "task complete" should cascade through the group.
`ManagedService.start()` returns *when ready*, not *when done* — the
adapter then blocks on `gracefulShutdown()` until the surrounding
group signals teardown. From the inner `ServiceGroup`'s perspective,
adapters only "complete" on shutdown, so a service that does its
real work in `start()` and then exits has no way to signal
natural completion.

A clean answer is a sibling protocol:

```swift
public protocol ManagedTaskService: Sendable {
    /// Run to completion. Returning normally means the work is done;
    /// throwing means the work failed. The graph drives subgroup
    /// completion semantics off this signal.
    func run() async throws
}
```

The adapter for `ManagedTaskService` plumbs the return directly into
the inner group's `successTerminationBehavior` so `.shutdownGroup`
behaves the way the design promises. The graph supports both protocols
on `EntryDescriptor.factory` (returning `any ManagedService` or
`any ManagedTaskService`). Spike does not implement this; deferred to
the first consumer that needs `.task` subgroup semantics for real.

**Lean:** Introduce `ManagedTaskService` when the first one-shot
consumer arrives. Until then, ship `ManagedService` only and document
that `CompletionMode` is best-effort (no service completes
naturally under `ManagedService`).

### 11.15 `reload(at:)` on a non-`HotReloadable` service [§7-tier]

Two options when `reload(at:)` is called on an entry whose service
doesn't conform to `HotReloadable`:

- **(A)** Log a warning and fall back to `restart(at:)` (blue-green).
  Operator intent ("reload this entry") is preserved at the cost of
  silent escalation.
- **(B)** Throw `ServiceGraphError.notReloadable(keyPath:)`. Operator
  intent surfaces explicitly; the caller decides whether to retry as
  a restart.

**Lean:** (A). The spike implements this. Falling back matches
ergonomic intent — admin tooling that fires "reload" at a mixed
descriptor set shouldn't need per-entry knowledge of which conform to
`HotReloadable`. The logged warning lets operators detect the
escalation in production logs.


## Summary

Backplane is a general-purpose service-management library. The core
surface — `Services` namespace, keypath-addressable `ServiceKey<T>`
declarations, `ServiceGraph` actor with per-entry FSM,
`ServiceContext` for cross-service resolution, subgroups with
configurable policies — accommodates the trivial CLI without
ceremony and the elaborate framework without contortion.

The substantive design choice is to make **blue-green replacement the
default restart strategy**. By keeping the old generation alive until
the new one has cleanly started, the design eliminates the
service-unavailable window that motivates other frameworks' sentinel
machinery and makes `Optional<T>` the honest return type for
`service(\.x)`. Sentinels do not appear in Backplane. Hot reload and
cold restart remain available as explicit opt-ins for services whose
state model demands them.

Each open question in §11 has a recommended path; none are blocking.
