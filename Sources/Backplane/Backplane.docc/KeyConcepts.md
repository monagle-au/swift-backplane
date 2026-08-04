# Key Concepts

A tour of Backplane's architecture: how applications, commands,
the service graph, and the bootstrap pipeline fit together.

## Overview

Backplane sits between `@main` and a running `ServiceGroup`. The
sequence is fixed and deterministic — knowing the order is enough
to reason about everything else.

```
@main
  ↓
BackplaneApplication.main()         ← `swift-argument-parser` entry
  ↓
RootCommand.main()                 ← parses CLI flags
  ↓
BackplaneCommand.run() (default)
    ↓ resolve Environment
    ↓ build ConfigReader
    ↓ bootstrap(config:environment:) → BootstrapPlan
    ↓ BootstrapCoordinator.shared.apply(plan)
    ↓ build root Logger
    ↓ App.services() → ServiceGraph
    ↓ boot the transitive closure of requiredServices
    ↓ ServiceGroup.run()
```

## BackplaneApplication

``BackplaneApplication`` is the type marked `@main`. It declares
the application's identity (used as the default logger label and
tracing service name), the `RootCommand` ArgumentParser entry
point, the service descriptors returned from `services()`, and
optionally a custom `ConfigReader` factory
(``BackplaneApplication/configReader(for:)``).

A single conformance is the bottleneck where everything else hangs
together; in practice you only write one of these per binary.

## BackplaneCommand

``BackplaneCommand`` builds on `AsyncParsableCommand` to add three
hooks the framework needs:

- **`requiredServices: [PartialKeyPath<Services>]`** — the keys
  whose transitive dependencies must be running before this
  command runs, written as keypaths: `[\.postgres, \.auditStore]`.
- **`bootstrap(config:environment:) async throws -> BootstrapPlan`**
  — the one-shot configuration of the global logging / metrics /
  tracing systems. Called after CLI parsing, before any `Logger`
  is constructed. Default returns an empty plan.
- **`execute(with:)`** — for ``TaskCommand``: the work to do once
  services are up, receiving a ``BackplaneContext`` for resolution.
  For ``PersistentCommand``: defaulted to a no-op.

Two specialisations capture the common shapes:

- ``PersistentCommand`` — services run until the process is
  signalled to stop. Suits HTTP servers, queue consumers, gRPC
  listeners.
- ``TaskCommand`` — services come up, `execute(with:)` runs to
  completion, the group shuts down gracefully. Suits database
  migrations, scheduled jobs, ad-hoc backfills.

The distinction is carried by ``ServiceLifecycleMode``, a
per-command property: ``BackplaneCommand`` defaults `lifecycleMode`
to `.persistent`; ``TaskCommand`` overrides it to `.task`. Prefer
conforming to one of the two specialisations over setting the mode
directly.

## ServiceKey, Services, EntryDescriptor

Service identity is a typed key declared once and addressed by
keypath everywhere else:

- ``ServiceKey`` is a phantom-typed identity — `ServiceKey<Value>`
  carries an `id` string and the *resolved* type `Value`. It is
  `ExpressibleByStringLiteral`, so a declaration body is just the
  id string.
- ``Services`` is the declaration namespace. Consumers extend it
  with computed properties returning typed keys, which makes every
  key addressable as `\.name` with autocomplete.
- ``EntryDescriptor`` pairs a key with the factory that builds the
  service, plus its ``SubgroupTag``, dependency list, and
  ``ConfigurationRequirement``.

```swift
extension Services {
    public var userStore: ServiceKey<UserStore> { "user-store" }
}
```

With the package's `Macros` trait enabled, the `#service` macro is
an opt-in shorthand for the same declaration:
`#service(UserStore.self)` expands to the computed property above.
The trait is off by default and pulls `swift-syntax` only for
consumers who enable it.

### Three registration forms

A key's resolved `Value` need not equal the concrete type the
graph lifecycles. ``EntryDescriptor`` has three initialiser forms
that bridge the two:

**Identity** — the factory returns a ``ManagedService`` and the key
resolves to that same type. The only form usable as a bare
trailing closure:

```swift
EntryDescriptor(\.postgres) { context in
    try await PostgresService(logger: context.logger)
}
```

**Passive** (`passive:`) — the factory returns any `Sendable`
value (including a protocol existential); the graph wraps it in a
``PassiveService`` for lifecycle and unwraps it on resolution, so
the wrapper never surfaces:

```swift
extension Services {
    public var auditStore: ServiceKey<any AuditStore> { "audit-store" }
}

EntryDescriptor(\.auditStore) { _ in          // passive:
    ClickHouseAuditStore(...)                 // concrete, resolved as any AuditStore
}
```

**Projected** (`factory:as:`) — the factory returns a concrete
``ManagedService`` the graph lifecycles, while resolution returns
a projection of it (typically a protocol the concrete conforms
to):

```swift
EntryDescriptor(\.auditStore,
    factory: { _ in ClickHouseAuditService(...) },   // a ManagedService
    as: { $0 })                                      // -> any AuditStore
```

For third-party `ServiceLifecycle.Service` types, wrap them in a
``LifecycleAdapter`` (see <doc:GettingStarted>); for generic inner
types that won't survive as a stored property, erase through
``AnyService`` first.

### Resolution

Factories and task commands resolve dependencies through the
``BackplaneContext`` they receive:

```swift
let db = try await context.requireService(\.database)   // waits, throws
if let cache = context.service(\.cache) { ... }         // sync, optional
```

`requireService` suspends until the entry is resolution-ready
(pass `timeout:` to bound the wait); `service` returns `nil`
unless the entry currently has a live instance. Failures surface
as ``ServiceGraphError``.

## BackplaneContext

Each factory (and a task command's `execute`) receives a
``BackplaneContext`` scoped to its entry: `entryID`, a pre-scoped
`logger`, the application `config` reader (`requireConfig()` for
the non-optional form), the entry's ``ServiceLifecycleHandle``,
a ``ServiceHealthReporter`` for self-reported degradation, and
the resolution methods above.

> Note: Backplane's ``BackplaneContext`` class is distinct from
> `ServiceContextModule.ServiceContext`, swift-service-context's
> task-local baggage type. Backplane also extends the latter with
> `active`, `environment`, `logger`, and `loggingTraceContext`
> accessors for trace propagation.

## ServiceGraph

``ServiceGraph`` is the actor that owns the entries. It boots only
the transitive closure of the boot roots (a command's
`requiredServices`), tracks each entry through ``ServiceState``
(`unconfigured` → `configuring` → `starting` → `running`, with
`degraded`, `replacing`, `stopped`, and `failed` branches), and
exposes the mutation surface:

- `restart(at:)` — blue-green replacement: a new generation starts
  and is swapped in before the old one drains, per the service's
  ``ReplacementStrategy``.
- `reload(at:)` — in-place reconfiguration for entries whose
  service conforms to ``HotReloadable``, avoiding a generation
  swap entirely.
- `recover(at:)` — cold re-boot of a `.failed` entry (factory +
  start from scratch). Failure during recovery lands back in
  `.failed`, never `.degraded`.

Failure policy is partitioned by ``SubgroupTag``: each subgroup
maps to a ``SubgroupPolicy`` combining a failure mode (`.failFast`
aborts boot; `.degraded` continues with the entry marked) and a
restartability flag. The stock policies: `.core` fails fast and is
not restartable; `.integrations` degrades and is restartable.

## BootstrapPlan and BootstrapCoordinator

`LoggingSystem.bootstrap`, `MetricsSystem.bootstrap`, and
`InstrumentationSystem.bootstrap` are each one-shot global
side-effects. Calling them twice crashes the process. Backplane
wraps that constraint behind ``BootstrapCoordinator``:

- ``BackplaneCommand/bootstrap(config:environment:)`` returns a
  ``BootstrapPlan`` describing what to install.
- The default ``BackplaneCommand/run()`` calls
  ``BootstrapCoordinator/apply(_:)`` once per process.
- The coordinator is **per-subsystem idempotent**: a second plan
  whose tracing field is set is a no-op if tracing already
  installed; the same plan's metrics field can still install if
  metrics hasn't.
- Static escape hatches (``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``,
  ``BackplaneApplication/bootstrapTracing(using:)``,
  ``BackplaneApplication/bootstrapMetrics(using:)``) all route
  through the same coordinator, so an `override main()` style
  bootstrap and the in-`run()` style coexist safely.

The ordering applied is **tracing → metrics → logging**, so any
`Logger.MetadataProvider` you supply can read trace context the
tracer set on its first span.

## Lifecycle services in the plan

A ``BootstrapPlan`` can also carry pre-built ``LifecycleService``
values — services that aren't declared as graph entries but must
run alongside them. The OTel exporter
(`BackplaneOTel.makeBootstrap(...)`) is the canonical example:
swift-otel returns a single `Service` that owns the export loop;
Backplane prepends it to the `ServiceGroup` ahead of graph
entries so telemetry flows from the very first span.

## Observability

Three reusable `@OptionGroup` types let commands take
configuration via CLI flags:

- ``LoggingOptions`` — `--log-level`, `--log-format`.
- ``TracingOptions`` — `--trace`, `--otel-endpoint`,
  `--otel-service-name`, `--trace-sample`.
- ``MetricsOptions`` — `--metrics`, `--metrics-endpoint`,
  `--metrics-interval`.

These are vendor-neutral data containers; the command's
`bootstrap(...)` method consumes their values and produces a
``BootstrapPlan``. Apps that prefer different flag spellings
write their own `ParsableArguments` — these types are
conveniences, not requirements.

Each option group also exposes a `merging(from: ConfigReader)`
method so the same fields can be populated from env vars, `.env`
files, or any other `ConfigProvider`. Precedence is CLI > config
> default — explicitly-passed CLI flags always win, config
fills any field the user didn't set, and built-in defaults
(`nil` / `false` / `.auto`) are the final fallback. See
``LoggingOptions/merging(from:)``,
``TracingOptions/merging(from:)``, and
``MetricsOptions/merging(from:)``.

For the actual log handler, ``StructuredLogHandler`` emits
JSON-per-line shaped by a ``StructuredLogProfile``.
``StructuredLogProfile/plain`` is the vendor-neutral default.
Vendor-flavoured profiles (e.g. Cloud Logging's magic-key dialect
in the `BackplaneGCP` product) live in opt-in trait-gated targets
and extend ``StructuredLogProfile`` with `static let` factories.
Consumers can add their own (Datadog, Elastic, …) the same way.

## Trait-gated optional surface

The package declares five opt-in traits:

| Trait      | What it enables |
|------------|-----------------|
| `Postgres` | The `BackplanePostgres` product: `postgres-nio` service, config builder, migrations. |
| `OTel`     | The `BackplaneOTel` product: `swift-otel`-backed bootstrap helper. |
| `GCP`      | The `BackplaneGCP` product: Cloud Trace + Cloud Logging integration. |
| `KeyfileEncryption` | `LocalKeyfileEncryption` (AES-256-GCM) inside the `BackplaneVault` product; pulls `swift-crypto`. |
| `Macros`   | The `#service` declaration macro; pulls `swift-syntax` at build time. |

The `BackplaneVault` product itself (writable, encryption-aware
configuration) is always available without a trait — only its
keyfile encryption backend is gated. With no traits enabled the
core `Backplane` library is the entire dependency closure (plus
its always-resolved SSWG-stack deps).

## What Backplane *doesn't* do

- It doesn't provide an HTTP server. Use Hummingbird, Vapor, or
  raw NIO and register them as services.
- It doesn't provide a job scheduler, queue runner, or workflow
  engine. Build those as services or use existing libraries.
- It doesn't replace `swift-argument-parser`. Commands stay plain
  `AsyncParsableCommand` types — Backplane adds protocol
  requirements on top, not a parallel CLI system.
- It doesn't replace `swift-service-lifecycle`. Backplane builds a
  declarative dependency layer over `ServiceGroup`'s flat
  collection.
