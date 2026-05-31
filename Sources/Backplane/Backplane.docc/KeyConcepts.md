# Key Concepts

A tour of Backplane's architecture: how applications, commands,
services, and the bootstrap pipeline fit together.

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
    ↓ App.configure(&registry)
    ↓ topologically sort required services
    ↓ build services in dependency order
    ↓ ServiceGroup.run()
```

## BackplaneApplication

``BackplaneApplication`` is the type marked `@main`. It declares
the application's identity (used as the default logger label and
tracing service name), the `RootCommand` ArgumentParser entry
point, the `ServiceRegistry` populated in `configure(_:)`, and
optionally a custom `ConfigReader` factory.

A single conformance is the bottleneck where everything else hangs
together; in practice you only write one of these per binary.

## BackplaneCommand

``BackplaneCommand`` builds on `AsyncParsableCommand` to add three
hooks the framework needs:

- **`requiredServices: [any ServiceKey.Type]`** — the registry
  keys whose transitive dependencies must be running before this
  command runs.
- **`bootstrap(config:environment:) -> BootstrapPlan`** — the
  one-shot configuration of the global logging / metrics /
  tracing systems. Called after CLI parsing, before any `Logger`
  is constructed. Default returns an empty plan.
- **`execute(with:)`** — for ``TaskCommand``: the work to do once
  services are up. For ``PersistentCommand``: defaulted to a no-op.

Two specialisations capture the common shapes:

- ``PersistentCommand`` — services run until the process is
  signalled to stop. Suits HTTP servers, queue consumers, gRPC
  listeners.
- ``TaskCommand`` — services come up, `execute(with:)` runs to
  completion, the group shuts down gracefully. Suits database
  migrations, scheduled jobs, ad-hoc backfills.

## ServiceKey, ServiceRegistry, ServiceValues

Backplane uses a typed key pattern modelled on SwiftUI's
`EnvironmentKey`:

- ``ServiceKey`` declares a key type with an associated `Value`
  type and a `defaultValue`.
- ``ServiceRegistry`` is the build-time registration map: each
  key is associated with a ``ConcreteServiceEntry`` (or any
  ``ServiceEntry``) describing the service's label, lifecycle
  mode, dependencies, and a build closure.
- ``ServiceValues`` is the run-time snapshot. After services are
  built, the key → value pairs are frozen in a `ServiceValues`
  and passed to ``TaskCommand/execute(with:)``.

`ServiceValues` is intentionally distinct from
`ServiceContext` (which is task-local and mutable). `ServiceValues`
is the immutable post-build view; `ServiceContext` is what
propagates through async calls.

```swift
struct UserStoreKey: ServiceKey {
    static var defaultValue: UserStore? { nil }
}

extension ServiceValues {
    var userStore: UserStore? {
        get { self[UserStoreKey.self] }
        set { self[UserStoreKey.self] = newValue }
    }
}
```

## Service entries and dependencies

A ``ConcreteServiceEntry`` carries the build closure and metadata.
Dependencies are declared as other key types; the runner
topologically sorts them and validates lifecycle modes (a
persistent service may not depend on a task service):

```swift
ConcreteServiceEntry<UserStoreKey>(
    label: "user-store",
    mode: .persistent,
    dependencies: [PostgresServiceKey.self]
) { values, config, logger in
    UserStore(client: values.postgres!, logger: logger)
}
```

Two helpers cover edge cases:

- ``AnchorService`` — a no-op service for values whose lifecycle
  is tied to something else. Optionally runs an `onShutdown`
  closure when the group is cancelled.
- ``AnyService`` — type-erased `Service` wrapper for the rare
  case where the concrete type can't be expressed.

## Lifecycle modes

``ServiceLifecycleMode`` has two cases:

- `.persistent` — the service runs until the group shuts down.
  When its `run()` returns, the group keeps going. This is the
  default.
- `.task` — when the service's `run()` returns successfully, the
  group performs a graceful shutdown.

The runner checks one invariant: a `.persistent` service may not
depend on a `.task` service (the dependency would terminate the
group while the dependent is still running). Violations throw
`ApplicationError.persistentDependsOnTask` *before* any service
is built.

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
values — services that aren't keyed in the ``ServiceRegistry`` but
must run alongside user services. The OTel exporter
(`BackplaneOTel.makeBootstrap(...)`) is the canonical example:
swift-otel returns a single `Service` that owns the export loop;
Backplane prepends it to the ``ServiceGroup`` ahead of user
services so telemetry flows from the very first span.

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
in ``BackplaneGCP``) live in opt-in trait-gated targets and extend
``StructuredLogProfile`` with `static let` factories. Consumers
can add their own (Datadog, Elastic, …) the same way.

## Trait-gated optional integrations

The package declares three opt-in traits:

| Trait      | Library product   | What it enables                        |
|------------|-------------------|----------------------------------------|
| `Postgres` | `BackplanePostgres`| `postgres-nio` service, migrations.    |
| `OTel`     | `BackplaneOTel`    | `swift-otel`-backed bootstrap helper.  |
| `GCP`      | `BackplaneGCP`     | Cloud Trace + Cloud Logging integration. |

Consumers enable only the traits they need; with no traits the
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
