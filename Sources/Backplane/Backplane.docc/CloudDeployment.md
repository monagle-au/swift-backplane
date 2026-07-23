# Cloud Deployment

Ship a Backplane application to a managed runtime — Cloud Run,
Kubernetes, ECS, Fly.io — without forking the binary.

## Overview

Backplane's deployment model is "one binary, profile-driven
configuration". The same executable that runs locally with
plain-text logs and no telemetry runs in the cloud with structured
JSON logs, OpenTelemetry export, and Cloud-vendor-specific
correlation — driven by environment variables, CLI flags, or
constants in the command's ``BackplaneCommand/bootstrap(config:environment:)``.

This guide covers the cross-cutting concerns. For vendor-specific
walkthroughs see the `BackplaneGCP` and `BackplaneOTel` products.

## The shape of a cloud-deployed Backplane app

```
container starts
  → swift binary launches
  → ArgumentParser parses CLI flags
  → BackplaneCommand.bootstrap() returns a BootstrapPlan
  → BootstrapCoordinator installs:
       1. tracing       (e.g. swift-otel exporter via BackplaneOTel)
       2. metrics       (e.g. swift-otel meter)
       3. logging       (e.g. StructuredLogHandler with .plain or .gcp profile)
  → root Logger is built
  → ServiceGraph boots the command's required services
  → ServiceGroup runs until SIGTERM
  → graceful shutdown drains exporters, closes pools, returns
```

A managed runtime that respects `SIGTERM` (Cloud Run, Kubernetes,
ECS) and gives the process a few seconds to drain is all Backplane
needs. The framework relies on
[swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle)'s
graceful-shutdown propagation.

## Containerise the binary

Backplane apps are plain `swift build -c release` executables. A
minimal Dockerfile based on Swift's official slim image:

```dockerfile
FROM swift:6.2-jammy AS build
WORKDIR /workspace
COPY . .
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:jammy
RUN apt-get update && apt-get install -y \
    ca-certificates libcurl4 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/.build/release/my-app /usr/local/bin/my-app
ENTRYPOINT ["/usr/local/bin/my-app"]
```

For Cloud Run / GKE you'll typically run in the foreground and let
the runtime route stdout/stderr to the log aggregator.

## Environment vs. configuration

Backplane distinguishes `Environment` from `ConfigReader`:

- ``Environment`` (`.development`, `.testing`, `.production`)
  describes *which* configuration profile to use. It is resolved
  from the ambient `ServiceContextModule.ServiceContext`
  (defaulting to `.development`); ``Environment/Arguments`` is an
  opt-in `ParsableArguments` for apps that want to select it from
  the CLI. Process env vars are read via ``Environment/get(_:)``.
- `ConfigReader` is the typed key/value lookup —
  env vars by default, layered with `.env`, in-memory defaults,
  or any other `ConfigProvider`.

In a managed runtime, set configuration-driving env vars on the
service — an `EnvironmentVariablesProvider` maps each dotted
config key to its upper-snake-case form:

```bash
LOGGING_LEVEL=info                # logging.level
LOGGING_FORMAT=json               # logging.format
TRACING_ENABLED=true              # tracing.enabled
TRACING_ENDPOINT=otel-collector:4317
POSTGRES_HOST=10.0.0.42           # postgres.host
POSTGRES_PASSWORD=...             # set via secret manager
```

Override ``BackplaneApplication/configReader(for:)`` to layer
secrets from your vendor's secret manager via an
`InMemoryProvider`-style adapter loaded at startup.

### Driving observability from env vars

Each observability option group (``LoggingOptions``,
``TracingOptions``, ``MetricsOptions``, plus the OTel-specific
ones in the `BackplaneOTel` product) exposes a `merging(from:)`
method that fills any unset CLI fields from a `ConfigReader`
scope. CLI takes precedence; config fills the gap. This lets a
managed-runtime operator set everything via env vars without
touching the binary or its arguments:

```swift
struct Serve: PersistentCommand {
    typealias App = MyApp
    @OptionGroup var logging: LoggingOptions
    @OptionGroup var tracing: TracingOptions

    func bootstrap(config: ConfigReader, environment: Environment) async throws -> BootstrapPlan {
        let log = logging.merging(from: config.scoped(to: "logging"))
        let trace = tracing.merging(from: config.scoped(to: "tracing"))

        var plan = BootstrapPlan()
        plan.logLevel = log.resolvedLogLevel
        plan.logHandlerFactory = log.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
        // ... use trace.endpoint etc. to build an Instrument and assign plan.instrument
        return plan
    }
}
```

Precedence on every field is:

1. **CLI flag** (when explicitly set on the command line).
2. **`ConfigReader` value** (env var, `.env`, in-memory provider).
3. **Built-in default** (typically `nil` / `false` / `.auto`).

Booleans deserve a small footnote: ArgumentParser can't tell
"the user left `--trace` at its default" from "the user passed
`--no-trace`", so config can *enable* a flag when CLI is silent
or false but can't be overridden by `--no-trace` once enabled in
config. To explicitly disable, omit the env var or set the
config key to `false`.

## Picking a logging dialect

Three combinations cover most production setups:

| Aggregator | Library            | Bootstrap factory                          |
|------------|--------------------|--------------------------------------------|
| Cloud Logging (Cloud Run / GKE) | `BackplaneGCP` | `BackplaneGCP.cloudRunOrStream` or `BackplaneGCP.logHandlerFactory` |
| Generic JSON ingester (Datadog, Loki, CloudWatch) | core `Backplane` | ``BackplaneLogging/plain`` |
| OTel collector | `BackplaneOTel` | `BackplaneOTel.makeBootstrap(serviceName:tracing:metrics:logsEnabled:)` |
| Local terminal | core `Backplane` | ``BackplaneLogging/stream`` |

These aren't mutually exclusive. A `MultiplexLogHandler` can wrap
multiple sinks if you need both stdout JSON for the cloud
aggregator AND OTLP export for a separate trace backend. Compose
the factory yourself and assign it to
``BootstrapPlan/logHandlerFactory``.

## Trace correlation in logs

Backplane carries trace identity through the active
`ServiceContextModule.ServiceContext` via ``LoggingTraceContext``.
The active ``StructuredLogProfile``'s
``StructuredLogProfile/traceCorrelation`` formatter decides what to
emit:

- ``StructuredLogProfile/plain`` emits nothing — apps that want
  trace IDs in logs should attach a `Logger.MetadataProvider` (e.g.
  swift-otel's `OTel.makeLoggingMetadataProvider()`) to
  ``BootstrapPlan/loggerMetadataProvider``.
- The `.gcp(projectID:)` profile (in the `BackplaneGCP` product)
  emits the three magic Cloud Logging keys so the "view trace"
  link renders next to each log entry.
- Custom profiles can emit Datadog/ECS/your-platform-of-choice
  shapes.

## Graceful shutdown

`ServiceGroup` propagates `SIGTERM` (and `SIGINT`) as a graceful
shutdown signal. Each running service can:

- Cancel its own work via the structured `for try await` over
  `cancelOnGracefulShutdown()`.
- Run cleanup logic by registering an ``AnchorService`` with an
  `onShutdown` closure.

OpenTelemetry exporters drain in-flight spans before returning
from their `run()` method, so a clean SIGTERM keeps trace data.

## Resource sizing

Backplane itself adds essentially no per-request overhead — it's
all setup-time orchestration. Sizing concerns live in your
services:

- Postgres pool size: `BackplanePostgres` exposes
  `pool.minimumConnections`, `pool.maximumConnections`,
  `pool.connectionIdleTimeoutSeconds`, plus
  `connectTimeoutSeconds` and `statementTimeoutSeconds`.
- HTTP server backpressure: configured via the server library
  you're using (Hummingbird, Vapor, NIO).
- OTel batch sizing: configured on `OTel.Configuration` before
  passing it to `BackplaneOTel.makeBootstrap`.

## Cloud-vendor walkthroughs

The same binary deploys to several runtimes; the distinguishing
work is which traits you enable and how `bootstrap(...)` builds
the plan:

- `BackplaneGCP` — Cloud Run / Cloud Run Jobs / GKE: enable the
  `GCP` trait and use `BackplaneGCP.cloudRunOrStream` to wire
  Cloud Logging + Cloud Trace correlation.
- `BackplaneOTel` — any runtime with an OpenTelemetry collector
  reachable on the network: enable the `OTel` trait and call
  `BackplaneOTel.makeBootstrap(serviceName:tracing:metrics:)`.
- For AWS / Datadog / Honeycomb: build a custom
  ``StructuredLogProfile`` (a `static let` extension on
  ``StructuredLogProfile``) and wire your own tracer in
  `bootstrap(...)`.

## Anti-patterns to avoid

- **Don't** call `LoggingSystem.bootstrap` directly. The static
  ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``
  routes through the coordinator; bypassing it invites a second
  bootstrap from inside `BackplaneCommand.run()` to crash the
  process.
- **Don't** create `Logger(label:)` instances at module-init or
  static-let scope. Bootstrap may not have run yet. Build loggers
  lazily inside `Service.run()` or accept them as init parameters.
- **Don't** rely on environment-variable layering inside
  ``BackplaneApplication/configReader(for:)`` for secrets — use a
  secret-manager-backed `ConfigProvider` so secrets aren't shell
  history or process listings.
