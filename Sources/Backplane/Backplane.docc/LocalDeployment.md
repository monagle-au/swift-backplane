# Local Deployment

Run, observe, and iterate on a Backplane application on your own
machine.

## Overview

Backplane is an executable Swift package that defaults to plain-text
stream logging and a no-op tracer when run outside a managed cloud
environment. The same binary you'll later ship to production runs
locally with no extra configuration.

This guide assumes a project laid out like the
<doc:GettingStarted> walkthrough.

## Run the binary

```bash
swift run my-app
```

The default flow:

1. ArgumentParser parses arguments and dispatches to the command's
   `run()`.
2. ``BackplaneCommand/run()`` reads the active ``Environment`` from
   the ambient `ServiceContextModule.ServiceContext` (defaulting to
   `.development`).
3. ``BackplaneApplication/configReader(for:)`` builds the configuration
   reader (default: process environment variables).
4. ``BackplaneCommand/bootstrap(config:environment:)`` returns a
   ``BootstrapPlan``; the default implementation returns an empty
   plan so the global subsystems stay on swift-log /
   swift-distributed-tracing / swift-metrics defaults.
5. The root `Logger` is built. With no bootstrap, swift-log writes
   plain text to stderr.
6. ``BackplaneApplication/services()`` supplies the descriptors, the
   ``ServiceGraph`` boots the transitive closure of the command's
   `requiredServices`, and the `ServiceGroup` runs until the
   process is signalled.

## Pick a log level

The simplest knob is `LOG_LEVEL`:

```bash
LOG_LEVEL=debug swift run my-app
```

When a command composes ``LoggingOptions`` and calls
``LoggingOptions/merging(from:)`` with the app's
`ConfigReader`, the level can also come from a
config key — typically `logging.level`, which an
`EnvironmentVariablesProvider` reads as `LOGGING_LEVEL=debug`.
CLI takes precedence over config, which takes precedence over
the legacy `LOG_LEVEL` env var read by
``BackplaneLogging/resolveLogLevel(envVar:)``, which takes
precedence over the in-code default (`.info`).

## Pick a log format

For machine-friendly local logs (e.g. piping to `jq` or a local log
viewer), pass `--log-format=json` if your command composes
``LoggingOptions``:

```bash
swift run my-app --log-level=info --log-format=json
```

This selects ``BackplaneLogging/plain`` —
``StructuredLogHandler`` with ``StructuredLogProfile/plain``. Output
is one JSON object per line with `severity`, `time`, `logger`,
`message`, and a `source` block.

## Configuration via .env files

Override `configReader(for:)` to layer providers — for example, a
`.env` file plus in-memory defaults:

```swift
import Configuration

extension MyApp {
    public static func configReader(for environment: Environment) async throws -> ConfigReader {
        try await ConfigReader(providers: [
            EnvironmentVariablesProvider(environmentFilePath: ".env", allowMissing: true),
            InMemoryProvider(values: [
                "postgres.database": .init(.string("myapp_\(environment.name)"), isSecret: false),
            ]),
        ])
    }
}
```

The first provider wins on key collision. Secrets read with
`ConfigReader`'s `isSecret: true` are redacted from any
diagnostic output.

## Talk to a local Postgres

When the `Postgres` package trait is enabled, add the supplied
descriptor to `services()`:

```swift
import BackplanePostgres

extension MyApp {
    static func services() -> [EntryDescriptor] {
        [postgresEntryDescriptor()]
    }
}
```

Commands that need the client declare `\.postgres` in their
`requiredServices` and resolve it via
`context.requireService(\.postgres)`.

Drive the connection via env vars — an
`EnvironmentVariablesProvider` maps each `postgres.*` config key
to its upper-snake-case form:

```bash
POSTGRES_HOST=localhost \
POSTGRES_PORT=5432 \
POSTGRES_USERNAME=postgres \
POSTGRES_PASSWORD=postgres \
POSTGRES_DATABASE=myapp_development \
swift run my-app
```

For the full set of pool / TLS / timeout knobs, see the
`BackplanePostgres` product's documentation.

## Run a one-shot task

`TaskCommand`s share the same descriptors and configuration but
exit when their work is done. To run a migration:

```bash
swift run my-app migrate
```

The framework brings up Postgres (because the migration command
declared `\.postgres` in `requiredServices`), runs
`execute(with:)`, and shuts the group down gracefully.

## Local tracing

For local trace inspection, run an OTel collector locally and enable
the `OTel` trait. See the `BackplaneOTel` product's walkthrough —
the same bootstrap plan that works in production works in dev with
a collector listening on `localhost:4317`.

If you don't run a collector, leave tracing off:
`withSpan(_:)` calls become near-zero-cost passthroughs
because swift-distributed-tracing's `NoOpInstrument` is the default
when no bootstrap occurs.

## Test inside the harness

Backplane's own integration tests use a `makeRunner(descriptors:)`
helper plus a no-op `Service` that waits for graceful shutdown.
Apps can do the same to exercise the descriptors → graph → group
flow without touching real I/O. The pattern lives in
`ApplicationRunner` (internal — `@testable import Backplane` to
reach it) and `Tests/BackplaneTests/ApplicationRunnerTests.swift`.

## Debug: what was bootstrapped?

``BootstrapCoordinator`` exposes three read-only properties for
diagnostics:

```swift
BootstrapCoordinator.shared.hasBootstrappedTracing
BootstrapCoordinator.shared.hasBootstrappedMetrics
BootstrapCoordinator.shared.hasBootstrappedLogging
```

Useful when an `override main()` and an in-`run()` plan disagree
about who installed what.

## What's next

- <doc:CloudDeployment> — taking the same binary to production.
- `BackplanePostgres` — full Postgres walkthrough.
- `BackplaneOTel` — OTel collector + sampling configuration.
- `BackplaneGCP` — Cloud Trace + Cloud Logging.
