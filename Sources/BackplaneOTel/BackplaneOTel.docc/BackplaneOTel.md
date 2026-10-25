# ``BackplaneOTel``

OpenTelemetry integration for Backplane via
[`swift-otel`](https://github.com/swift-otel/swift-otel).

## Overview

`BackplaneOTel` is opt-in: enable the `OTel` package trait to bring
`swift-otel` into the dependency graph. The target adds:

- A bootstrap factory ``BackplaneOTel/makeBootstrap(serviceName:tracing:metrics:logsEnabled:configure:localLogs:)``
  that builds `swift-otel`'s backends and returns them in a
  `BootstrapPlan` ready to feed into
  `BackplaneCommand.bootstrap(config:environment:)`. It installs
  nothing itself.
- Opinionated CLI option groups (``OTelTracingOptions``,
  ``OTelMetricsOptions``) covering the most-used OTel knobs.
- Coordination with `BootstrapCoordinator`: the plan carries the
  tracer, metrics factory and log handler factory, and the
  coordinator installs each of `InstrumentationSystem` /
  `MetricsSystem` / `LoggingSystem` once, so OTel never conflicts
  with another bootstrap path. OTLP logs go through the runtime
  level table.

## Topics

### Walkthrough

- <doc:OTelWalkthrough>

### Bootstrap

- ``BackplaneOTel``
- ``BackplaneOTel/makeBootstrap(serviceName:tracing:metrics:logsEnabled:configure:localLogs:)``

### CLI option groups

- ``OTelTracingOptions``
- ``OTelMetricsOptions``
