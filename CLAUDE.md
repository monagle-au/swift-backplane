# swift-backplane

Service-management scaffold for Swift server applications. Plugs
together `swift-service-lifecycle`, `swift-argument-parser`,
`swift-service-context`, `swift-log`, `swift-metrics`,
`swift-distributed-tracing`, and `swift-configuration` into a single
harness for CLI-driven services.

## Build & Test

```bash
swift build
swift test
swift test --traits Postgres,OTel,GCP,KeyfileEncryption,Macros   # everything
```

Requires Swift 6.2+, macOS 15+.

## Architecture

### Core types (always available, target: `Backplane`)

**`ServiceGraph`** — actor managing the live entry set. Coordinates
boot (factory + start), replacement (`restart(at:)` — blue-green or
cold, per the descriptor's declared strategy), hot reload
(`reload(at:)`), cold re-boot of `.failed` entries (`recover(at:)`),
and shutdown. Boots only the transitive closure of the boot roots.
Failure policies partition per-subgroup.
`ServiceGraph.materializedDescriptors(explicit:roots:)` combines
explicit descriptors with defaults materialised from
`BackplaneService`-conforming keys.

**`BackplaneService`** — the self-describing service protocol
(refines `ManagedService`). Carries `static make(context:)`,
`static dependencies: ServiceList`, `static subgroup`, and
`static replacementStrategy`. A `ServiceKey` whose `Value` conforms
needs **no** `services()` entry — the graph materialises its default
descriptor when a command requires it. Conforming classes should be
`final`.

**`EntryDescriptor`** — value-type declaration of one entry. Carries
`id`, factory closure `(BackplaneContext) async throws -> any ManagedService`,
`SubgroupTag`, dependency list, and `replacement: ReplacementStrategy`.
Closure-free form for conforming types
(`EntryDescriptor(\.database, subgroup: …)` — nil params fall back to
the type's statics); closure forms (`factory:` / `passive:` /
`factory:as:`) for third-party types and protocol-key bindings.

**`BackplaneContext`** — passed into factories and `make(context:)`.
Exposes the entry's logger, a `ConfigReader?` **scoped to the entry
id** (plus `rootConfig` for cross-cutting keys), environment, and both
keypath-flavoured (`requireService(\.foo)`) and explicit-key
(`requireService(ServiceKey<T>)`) resolution. Distinct from
`ServiceContextModule.ServiceContext` (swift-service-context's
tracing-baggage type), which keeps its name.

**`ServiceKey<Value>`** — typed identity for an entry. Exposed to
consumers as keypath-addressable computed properties on the
``Services`` namespace. The `id` doubles as the entry's config scope.
`AnyServiceKey` is the type-erased form the graph indexes on; the
keypath-erasing initialiser `AnyServiceKey(keyPath:)` handles the
conversion at the framework boundary.

**`Services`** — the consumer-extension namespace. A `public struct`
with a no-arg initialiser; consumers extend it with computed
properties returning `ServiceKey<T>` so keys are addressable via
`\.…` keypaths.

**`ServiceList`** — the currency for keypath lists
(`requiredServices`, `dependencies`). Array-literal
(`[\.postgres, \.http]`) and variadic (`ServiceList(\.postgres)`)
forms; hides the `PartialKeyPath<Services> & Sendable` composition
from signatures.

**`ManagedService`** — the lifecycle protocol: `start()` /
`shutdown()`. Replacement strategy is *not* on the instance — it's
declared on the descriptor (or `BackplaneService` static) and read
before a replacement is built.

**`ReplacementStrategy`** — `.blueGreen(grace:)` (default via
`.standard`, 30 s grace) or `.coldRestart` (old shut down before new
is built — for listeners and other exclusive-resource services;
failures land `.failed`, recoverable via `recover(at:)`).

**`LifecycleAdapter<S: Service>`** — wraps a
`ServiceLifecycle.Service` as a `ManagedService`. `start()` spawns
a detached `inner.run()`; `shutdown()` cancels and awaits.

**`PassiveService<T>`** — wraps a passive value (actor or `Sendable`)
as a `ManagedService` with no-op start/shutdown.

**`HotReloadable`** — opt-in. `ServiceGraph.reload(at:)` calls
`reload(config:)` (entry-scoped reader) instead of starting a new
generation; non-conforming services fall back to `restart(at:)` under
their declared strategy.

**`SubgroupTag` / `SubgroupPolicy`** — partition entries by failure
mode (`.failFast` / `.degraded`) and restartability. Stock policies
for `.core` and `.integrations`.

### Application harness

**`BackplaneApplication`** — `@main` entry point. Declares
`identifier` and `RootCommand: AsyncParsableCommand`.
`services() -> [EntryDescriptor]` defaults to `[]` and is the
**override surface** — protocol-key bindings, third-party closures,
test doubles, per-app overrides (explicit descriptors beat defaults).

**`BackplaneCommand`** — protocol over `AsyncParsableCommand` with
`requiredServices: ServiceList` and
`bootstrap(config:environment:) async throws -> BootstrapPlan`.

- `PersistentCommand` — runs services until signal. No `execute`.
- `TaskCommand` — services come up, `execute(with: BackplaneContext)`
  runs, group shuts down gracefully.

**`ApplicationRunner`** — internal. Drives boot, runs the graph
inside a `ServiceGroup`, executes `execute(with:)` if any, handles
graceful shutdown. Command contexts keep root-scoped config.

**`BootstrapPlan` / `BootstrapCoordinator`** — value-type plan
applied per-subsystem-idempotently in tracing → metrics → logging
order, after CLI parsing, before the first `Logger` is built.

### Adding a service

1. Write the type as a `BackplaneService` — construction,
   dependencies, and policies live on the type:

```swift
final class Notifier: BackplaneService {
    static func make(context: BackplaneContext) async throws -> Notifier {
        // context.config is pre-scoped to the entry id ("notifier").
        Notifier(webhookURL: try context.requireConfig().requiredString(forKey: "webhookURL"))
    }
    static var dependencies: ServiceList { [\.postgres] }
    static var subgroup: SubgroupTag { .integrations }

    func start() async throws { … }
    func shutdown() async { … }
}
```

2. Extend `Services` with a computed property returning a typed
   `ServiceKey<T>`. No naming convention is imposed — name it for the
   value, not `…Key`:

```swift
extension Services {
    public var notifier: ServiceKey<Notifier> { "notifier" }
}
```

3. Declare it on commands that need it — that's the whole
   registration; the entry, its static dependencies, and their config
   scopes materialise from the key:

```swift
var requiredServices: ServiceList { [\.notifier] }

func execute(with context: BackplaneContext) async throws {
    let notifier = try await context.requireService(\.notifier)
}
```

The same type may back multiple keys — each entry reads its own
config scope (two Postgres keys = two databases).

**When a conformance can't express it, use `services()`** (explicit
descriptors always win over defaults):

- Third-party passive values via `passive:` — the graph wraps in
  `PassiveService` for lifecycle and unwraps on resolution, so the
  resolved type is the value itself, no `.inner`:

```swift
static func services() -> [EntryDescriptor] {
    [
        EntryDescriptor(Services().database) { context in   // passive:
            try await PostgresClient(...)
        }
    ]
}
```

- A key's resolved `Value` can be a **protocol**. Register a concrete
  passive value behind a protocol key with `passive:`, or project a
  concrete `ManagedService` onto a protocol key with `factory:as:`:

```swift
extension Services {
    public var auditStore: ServiceKey<any AuditStore> { ServiceKey(id: "audit-store") }
}

// passive value behind a protocol key:
EntryDescriptor(Services().auditStore) { _ in ClickHouseAuditStore(...) }

// lifecycle service projected onto a protocol key:
EntryDescriptor(Services().auditStore,
    factory: { _ in ClickHouseAuditService(...) },   // a ManagedService
    as: { $0 })                                      // -> any AuditStore
```

- Overriding a conforming type's defaults:
  `EntryDescriptor(\.postgres, subgroup: .integrations, replacement: .coldRestart)`.

### Writing a command

Single-command app (no `services()` needed when the required types
conform to `BackplaneService`):
```swift
@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = ServeCommand
    static let identifier = "my-app"
}

struct ServeCommand: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(abstract: "Run the server")
    var requiredServices: ServiceList { [\.database] }
}
```

Multi-command app: compose with `CommandConfiguration.subcommands`.
The `RootCommand` associated type is the outer `AsyncParsableCommand`.

## Trait-gated satellite targets

Each is opt-in via a Swift Package trait — consumers pay nothing
for what they don't enable.

- **`BackplanePostgres`** (`Postgres`) — `Services.postgres`
  (`BackplanePostgresService: BackplaneService`, so requiring the key
  is the whole registration), `PostgresMigrator`, config builder.
- **`BackplaneOTel`** (`OTel`) — `BackplaneOTel.makeBootstrap(...)`,
  `OTelTracingOptions`, `OTelMetricsOptions`.
- **`BackplaneGCP`** (`GCP`) — `GCPLogHandler`, `GCPTracer`,
  `CloudTraceExporter`, `BackplaneGCP.cloudRunOrStream`.
- **`BackplaneVault`** — `ConfigStore`, `ConfigEncryption`,
  `PassthroughEncryption`, `FileLock` always available;
  `LocalKeyfileEncryption` (AES-256-GCM) behind the
  `KeyfileEncryption` trait (pulls `swift-crypto`).
  `ConfigStore` writes are locked read-merge-writes (`flock(2)` on a
  sidecar `<file>.lock`), so concurrent stores on one file — across
  processes or within one — never lose each other's keys.
- **`#service` macro** (`Macros` trait, **off by default**) — shorthand
  for declaring a key on `Services`. Pulls `swift-syntax` only when the
  trait is enabled; consumers without it pay nothing:

  ```swift
  extension Services {
      #service(PostgresClient.self)                       // var postgresClient
      #service(PostgresClient.self, name: "database")     // var database
      #service((any AuditStore).self, name: "auditStore") // ServiceKey<any AuditStore>
  }
  ```

  Expands to a `public var …: ServiceKey<…> { ServiceKey(id: …) }`. The
  property name is derived from the type's trailing identifier (override
  with `name:`); `id` defaults to the name (override with `id:`). The
  generated property is always `public` — hand-write the key if you need
  a non-public one. The macro plugin is built into the **`BackplaneMacros`**
  target. Note: this repo's own `swift build`/CI compiles `swift-syntax`
  because SwiftPM builds every declared target — but a downstream consumer
  that doesn't enable the `Macros` trait builds none of it.

## Concurrency

Swift 6.2 strict concurrency throughout. All public types are
`Sendable` or actor-isolated. `ServiceGraph` is an actor; per-entry
state lives in `Mutex<State>` for nonisolated reads. `LifecycleAdapter`
uses an internal `Mutex<Task<Void, Never>?>` for the run-task handle.
Key-path lists travel as `ServiceList`
(`PartialKeyPath<Services> & Sendable` elements — literals satisfy the
constraint automatically).

## Testing

Swift Testing (`@Suite`, `@Test`, `#expect`). `ApplicationRunner` is
internal but accessible via `@testable import Backplane`. Integration
tests use `makeRunner(descriptors:)` and an `IntegrationRecordingService`
that observes lifecycle ordering. Test helpers live alongside the
suites that use them.

## Design notes

- `docs/design/backplane.md` — service-graph design (2.0 addendum:
  environment-model registration), replacement strategies, subgroups,
  BackplaneContext, keypath-on-`Services` declaration pattern.
- `docs/design/backplane-vault.md` — `BackplaneVault`'s
  encryption-aware config story.
