# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from `1.0.0` onwards.

## [Unreleased]

### Added

- **`ServiceGraph.recover(at:)`** — re-runs a `.failed` entry's factory and
  `start()` as a fresh generation. `.failed` was previously terminal:
  `restart(at:)` only acts on `.running`/`.degraded`, so an entry whose
  boot-time `start()` threw could never be revived. `recover(at:)` is the
  missing edge: gated on the same subgroup restartability as
  `restart(at:)`, `.failed`-only, with failure paths that land back in
  `.failed` (never `.degraded` — a resolution-ready state always means a
  live serving instance). The swapped-out failed generation is drained
  with zero grace so a `start()` that acquired resources before throwing
  still gets its `shutdown()`. Consumers can now build retry-with-backoff
  supervisors for boot failures entirely on the public API
  (`stateStream(of:)` + `recover(at:)`), as the design note intends.

## [1.1.0] — 2026-06-06

A backward-compatible release: decouples a key's resolved value from the
lifecycle-managed unit, and adds an opt-in declaration macro. Existing
code continues to compile unchanged.

### Added

- **Projection-decoupled keys** — a key's `Value` (what `requireService`
  returns) is now independent of the `ManagedService` the graph
  lifecycles, via a projection captured at registration. Two new
  `EntryDescriptor` initialisers:
  - `passive:` — the factory returns the key's `Value` directly (any
    `Sendable`, including a protocol existential); the graph wraps it in
    a `PassiveService` and unwraps on resolution, so the wrapper no
    longer surfaces and `.inner` is gone at the call site.
  - `factory:as:` — a concrete `ManagedService` is lifecycled while the
    key resolves as a (typically protocol) `Value`; `as:` projects the
    concrete onto the abstraction.
  This lets a `ServiceKey<any Protocol>` be backed by a concrete
  registration — the case type-keyed registries can't express. The
  identity form is unchanged.
- **`#service` macro** (`Macros` trait, off by default) — shorthand for
  declaring a key on `Services`:
  `#service(PostgresClient.self, name: "database")` expands to the
  hand-written computed property. Pulls `swift-syntax` only when the
  trait is enabled; consumers who don't opt in build none of it.
- **`ServiceKey: ExpressibleByStringLiteral`** — a declaration body can
  be just the `id` literal:
  `var database: ServiceKey<PostgresClient> { "database" }`. Equivalent
  to `ServiceKey(id: "database")`; trims the per-key boilerplate without
  a macro or dependency.

### Changed

- Service-key declarations no longer use a `Key` suffix by convention —
  e.g. `Services.postgres` (was `Services.postgresKey`). The suffix
  carried no meaning and read poorly at keypath call sites.

### Deprecated

- **`Services.postgresKey`** — renamed to `Services.postgres`. The old
  name remains as a deprecated alias resolving the same entry, and is
  scheduled for removal in 2.0.0.

## [1.0.0] — 2026-05-31

The first stable release. From this point on, public-API changes
follow strict SemVer.

### Added

#### Core service-management substrate

- **`ServiceGraph`** — actor managing the live set of entries.
  Coordinates boot (factory + start), blue-green replacement
  (`restart(at:)`), hot reload (`reload(at:)`), and shutdown. Boots
  pruned to the transitive closure of the boot roots; failure
  policies partition per-subgroup.
- **`EntryDescriptor`** — value-type declaration of one service
  entry. Carries the `id`, factory closure, `ConfigurationRequirement`,
  `SubgroupTag`, and dependency list. Factory receives a
  `ServiceContext`.
- **`ServiceContext`** — per-entry context object passed into
  factories. Exposes the entry's logger, the `ConfigReader` scoped
  to the entry, environment, and `requireService(_:timeout:)` /
  `service(_:)` for cross-entry resolution.
- **`ServiceKey<Value>`** — typed key value identifying an entry.
  `AnyServiceKey` is the type-erased form used in dependency lists.
  Keys are exposed as computed properties on the ``Services``
  namespace and referenced via keypath (`\.databaseKey`) at every
  consumer call site — `requireService`, dependency lists on
  `EntryDescriptor`, `requiredServices` on a command. The keypath
  carries the typed `Value`, so `requireService(\.databaseKey)`
  infers the returned type without a call-site cast.
- **`ManagedService`** — the protocol entries implement.
  `start()` / `shutdown()` plus a `replacementStrategy` that
  controls blue-green grace timing.
- **`HotReloadable`** — opt-in protocol for services that can
  apply a new `ConfigReader` in-place without restart.
- **`ServiceHealthReporter`** — entries can self-report
  degradation (`.running → .degraded`) without leaving the
  resolution-ready set.
- **`LifecycleAdapter<S: Service>`** — wraps a
  `ServiceLifecycle.Service`-conforming inner type as a
  `ManagedService`. `start()` spawns a detached task running
  `inner.run()`; `shutdown()` cancels and awaits it.
- **`PassiveService<T>`** — `ManagedService` wrapper for a
  passive value (an actor or value with no run loop). `start()` and
  `shutdown()` are no-ops; the graph holds the wrapper for the
  surrounding `ServiceGroup`'s lifetime.
- **Subgroups** — `SubgroupTag` partitions entries; per-subgroup
  `SubgroupPolicy` carries failure mode (`.failFast` / `.degraded`)
  and restartability. Stock policies for `.core` and `.integrations`.
- **`ServiceContext.requireConfig()`** — returns the entry's
  `ConfigReader` or throws `ServiceGraphError.missingConfigReader`.
- **Blue-green replacement** — `ServiceGraph.restart(at:)` starts a
  new generation alongside the old one; the active-pointer swap is
  atomic; `resolve(_:)` never returns nil during a restart.

#### Application & command harness

- **`BackplaneApplication`** — marks the `@main` entry point.
  `services()` returns `[EntryDescriptor]` declaratively; the
  framework wires `RootCommand` (an `AsyncParsableCommand`) and
  drives the `ServiceGroup`.
- **`BackplaneCommand`** — protocol over `AsyncParsableCommand`
  carrying `requiredServices: [AnyServiceKey]` and
  `bootstrap(config:environment:)` returning a `BootstrapPlan`.
  `PersistentCommand` and `TaskCommand` capture the two common
  shapes (services run until signal vs. services run alongside a
  one-shot `execute(with:)`).
- **`ApplicationRunner`** — drives boot, runs the graph inside a
  `ServiceGroup`, executes the command's `execute(with:)` (if any),
  and handles graceful shutdown.
- **`AnchorService`** — bootstrap-only lifecycle service that
  starts and runs until cancellation; used to anchor a `ServiceGroup`
  with no other services.

#### Bootstrap pipeline

- **`BootstrapPlan`** — value-type description of what the global
  logging/metrics/tracing systems should install.
- **`BootstrapCoordinator`** — applies plans per-subsystem-idempotently,
  in tracing → metrics → logging order, after CLI parsing and
  before any `Logger` is built.
- **Static escape hatches**
  (`BackplaneApplication.bootstrapLogging`, `bootstrapTracing`,
  `bootstrapMetrics`) route through the same coordinator.
- **`LifecycleService`** — bootstrap-related services (e.g. an
  OTel exporter) start alongside user services without being keyed
  in the registry.

#### Observability

- **`StructuredLogHandler`** — vendor-neutral structured logging
  emitting JSON-per-line, shaped by an extensible
  `StructuredLogProfile`. The `.plain` profile is the vendor-neutral
  default; vendor dialects extend the profile via `static let`
  factories.
- **CLI option groups** — `LoggingOptions`, `TracingOptions`,
  `MetricsOptions` are reusable `ParsableArguments` types that
  compose via `@OptionGroup`. Each carries a
  `merging(from: ConfigReader)` method. Precedence is
  CLI > config > built-in default.

#### Trait-gated satellite libraries

- **`BackplanePostgres`** (`Postgres` trait) — `postgresKey:
  ServiceKey<BackplanePostgresService>` and the helper
  `postgresEntryDescriptor()` returning an `EntryDescriptor`.
  Configuration builder mapping a `ConfigReader` scope onto
  pool/timeout/TLS knobs. `PostgresMigrator` for transactional,
  idempotent migrations. Optional-binding helpers and a
  multi-row INSERT helper. DEBUG-only `PGReflectableError`
  reflection.
- **`BackplaneOTel`** (`OTel` trait) —
  `BackplaneOTel.makeBootstrap(...)` wraps swift-otel's
  `OTel.bootstrap(...)` and returns a `BootstrapPlan`. Opinionated
  `OTelTracingOptions` and `OTelMetricsOptions` carry the most-used
  OTel knobs as CLI flags + ConfigReader merging.
- **`BackplaneGCP`** (`GCP` trait) — `GCPLogHandler` (Cloud
  Logging-shaped JSON, a thin wrapper over `StructuredLogHandler`
  with the `.gcp(projectID:)` profile). `GCPTracer` / `GCPSpan` /
  `CloudTraceExporter` for Cloud Trace export with W3C Trace
  Context propagation.
  `BackplaneApplication.bootstrapGCPTracing(projectID:)` static
  helper. `BackplaneGCP.cloudRunOrStream` selector.
- **`BackplaneVault`** (`KeyfileEncryption` trait) — augments
  swift-configuration's read-only `ConfigReader` with a write path,
  secret-aware fields, and persistence. The `ConfigEncryption`
  protocol and `PassthroughEncryption` no-op are always available;
  the `KeyfileEncryption` trait additionally enables
  `LocalKeyfileEncryption` (AES-256-GCM, machine-local keyfile
  reference implementation), pulling `swift-crypto` only when
  enabled.
  Declare a key in one line:

  ```swift
  extension Services {
      public var databaseKey: ServiceKey<PostgresClient> {
          ServiceKey(id: "database")
      }
  }
  ```

#### Documentation

- **DocC catalogs** — one per library product (Backplane,
  BackplaneGCP, BackplaneOTel, BackplanePostgres). The `Backplane`
  catalog contains *Getting Started*, *Key Concepts*,
  *Local Deployment*, and *Cloud Deployment* articles. Each
  satellite ships a walkthrough article. `swift-docc-plugin` is
  added so consumers can build docs locally with
  `swift package generate-documentation`.

### Requirements

- Swift 6.2+
- macOS 15+

[Unreleased]: https://github.com/monagle-au/swift-backplane/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/monagle-au/swift-backplane/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/monagle-au/swift-backplane/releases/tag/v1.0.0
