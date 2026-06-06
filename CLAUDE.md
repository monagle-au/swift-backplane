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
swift test --traits Postgres,OTel,GCP,KeyfileEncryption   # everything
```

Requires Swift 6.2+, macOS 15+.

## Architecture

### Core types (always available, target: `Backplane`)

**`ServiceGraph`** — actor managing the live entry set. Coordinates
boot (factory + start), blue-green replacement (`restart(at:)`), hot
reload (`reload(at:)`), and shutdown. Boots only the transitive
closure of the boot roots. Failure policies partition per-subgroup.

**`EntryDescriptor`** — value-type declaration of one entry. Carries
`id`, factory closure `(ServiceContext) async throws -> any ManagedService`,
`ConfigurationRequirement`, `SubgroupTag`, dependency list. Initialise
via `EntryDescriptor(key, …) { context in … }`.

**`ServiceContext`** — passed into factories. Exposes the entry's
logger, `ConfigReader?` scoped to the entry, environment, and both
keypath-flavoured (`requireService(\.foo)`) and explicit-key
(`requireService(ServiceKey<T>)`) resolution.

**`ServiceKey<Value>`** — typed identity for an entry. Exposed to
consumers as keypath-addressable computed properties on the
``Services`` namespace. `AnyServiceKey` is the type-erased form the
graph indexes on; the keypath-erasing initialiser
`AnyServiceKey(keyPath:)` handles the conversion at the framework
boundary.

**`Services`** — the consumer-extension namespace. A `public struct`
with a no-arg initialiser; consumers extend it with computed
properties returning `ServiceKey<T>` so keys are addressable via
`\.…` keypaths.

**`ManagedService`** — the protocol entries implement. `start()` /
`shutdown()` plus `replacementStrategy` (controls blue-green grace).

**`LifecycleAdapter<S: Service>`** — wraps a
`ServiceLifecycle.Service` as a `ManagedService`. `start()` spawns
a detached `inner.run()`; `shutdown()` cancels and awaits.

**`PassiveService<T>`** — wraps a passive value (actor or `Sendable`)
as a `ManagedService` with no-op start/shutdown.

**`HotReloadable`** — opt-in. `ServiceGraph.reload(at:)` calls
`reload(config:)` instead of starting a new generation.

**`SubgroupTag` / `SubgroupPolicy`** — partition entries by failure
mode (`.failFast` / `.degraded`) and restartability. Stock policies
for `.core` and `.integrations`.

### Application harness

**`BackplaneApplication`** — `@main` entry point. Declares
`identifier`, `RootCommand: AsyncParsableCommand`, and
`services() -> [EntryDescriptor]`.

**`BackplaneCommand`** — protocol over `AsyncParsableCommand` with
`requiredServices: [PartialKeyPath<Services>]` and
`bootstrap(config:environment:) -> BootstrapPlan`.

- `PersistentCommand` — runs services until signal. No `execute`.
- `TaskCommand` — services come up, `execute(with: ServiceContext)`
  runs, group shuts down gracefully.

**`ApplicationRunner`** — internal. Drives boot, runs the graph
inside a `ServiceGroup`, executes `execute(with:)` if any, handles
graceful shutdown.

**`BootstrapPlan` / `BootstrapCoordinator`** — value-type plan
applied per-subsystem-idempotently in tracing → metrics → logging
order, after CLI parsing, before the first `Logger` is built.

### Adding a service

1. Extend `Services` with a computed property returning a typed
   `ServiceKey<T>`. No naming convention is imposed — name it for the
   value, not `…Key`:

```swift
extension Services {
    public var database: ServiceKey<PostgresClient> {
        ServiceKey(id: "database")
    }
}
```

2. Return an `EntryDescriptor` from `services()`. `PostgresClient` is a
   passive value (no `start()`/`shutdown()` of its own), so register it
   with the `passive:` initialiser — the graph wraps it in a
   `PassiveService` for lifecycle and unwraps it on resolution, so the
   wrapper never surfaces:

```swift
static func services() -> [EntryDescriptor] {
    [
        EntryDescriptor(Services().database) { context in   // passive:
            try await PostgresClient(...)
        }
    ]
}
```

3. Declare it as a `requiredService` on commands that need it and
   resolve via `context.requireService(\.database)` — the resolved type
   is `PostgresClient`, no `.inner`:

```swift
var requiredServices: [PartialKeyPath<Services>] { [\.database] }

func execute(with context: ServiceContext) async throws {
    let db = try await context.requireService(\.database)
}
```

A key's resolved `Value` need not equal the registered concrete type —
it can be a **protocol**. Register a concrete passive value behind a
protocol key with `passive:`, or project a concrete `ManagedService`
onto a protocol key with `factory:as:`:

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

### Writing a command

Single-command app:
```swift
@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = ServeCommand
    static let identifier = "my-app"
    static func services() -> [EntryDescriptor] { [...] }
}

struct ServeCommand: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(abstract: "Run the server")
    var requiredServices: [PartialKeyPath<Services>] { [\.database] }
}
```

Multi-command app: compose with `CommandConfiguration.subcommands`.
The `RootCommand` associated type is the outer `AsyncParsableCommand`.

## Trait-gated satellite targets

Each is opt-in via a Swift Package trait — consumers pay nothing
for what they don't enable.

- **`BackplanePostgres`** (`Postgres`) — `Services.postgres`,
  `postgresEntryDescriptor()`, `PostgresMigrator`, config builder.
- **`BackplaneOTel`** (`OTel`) — `BackplaneOTel.makeBootstrap(...)`,
  `OTelTracingOptions`, `OTelMetricsOptions`.
- **`BackplaneGCP`** (`GCP`) — `GCPLogHandler`, `GCPTracer`,
  `CloudTraceExporter`, `BackplaneGCP.cloudRunOrStream`.
- **`BackplaneVault`** — `ConfigStore`, `ConfigEncryption`,
  `PassthroughEncryption` always available;
  `LocalKeyfileEncryption` (AES-256-GCM) behind the
  `KeyfileEncryption` trait (pulls `swift-crypto`).
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

## Testing

Swift Testing (`@Suite`, `@Test`, `#expect`). `ApplicationRunner` is
internal but accessible via `@testable import Backplane`. Integration
tests use `makeRunner(descriptors:)` and an `IntegrationRecordingService`
that observes lifecycle ordering. Test helpers live alongside the
suites that use them.

## Design notes

- `docs/design/backplane.md` — service-graph design, blue-green
  replacement, subgroups, ServiceContext, keypath-on-`Services`
  declaration pattern.
- `docs/design/backplane-vault.md` — `BackplaneVault`'s
  encryption-aware config story.
