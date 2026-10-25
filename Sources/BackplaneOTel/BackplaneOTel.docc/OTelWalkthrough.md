# OpenTelemetry Walkthrough

Wire OpenTelemetry tracing, metrics and logs into a Backplane
application using `swift-otel`.

## Overview

OpenTelemetry has three subsystems: traces, metrics, and logs.
`swift-otel` provides `LoggingSystem` / `MetricsSystem` /
`InstrumentationSystem` backends for all three plus a
single-`Service` lifecycle that owns the export loops. Backplane's
``BackplaneOTel/makeBootstrap(serviceName:tracing:metrics:logsEnabled:configure:localLogs:)``
turns CLI flags + an optional configuration closure into a
`BootstrapPlan` ready to apply. It installs nothing itself.

## Enable the trait

```swift
.package(
    url: "https://github.com/<org>/swift-backplane.git",
    from: "1.0.0",
    traits: ["OTel"]
),

.executableTarget(
    name: "MyService",
    dependencies: [
        .product(name: "Backplane", package: "swift-backplane"),
        .product(name: "BackplaneOTel", package: "swift-backplane"),
    ]
),
```

## Compose the option groups

```swift
import Backplane
import BackplaneOTel

struct Serve: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(commandName: "serve")

    @OptionGroup var logging: LoggingOptions
    @OptionGroup var tracing: OTelTracingOptions
    @OptionGroup var metrics: OTelMetricsOptions

    var requiredServices: ServiceList { [] }

    func bootstrap(config: ConfigReader, environment: Environment) async throws -> BootstrapPlan {
        try BackplaneOTel.makeBootstrap(
            serviceName: App.identifier,
            tracing: tracing,
            metrics: metrics,
            logsEnabled: false  // keep your own log handler
        )
    }
}
```

`makeBootstrap` installs nothing. It builds swift-otel's backends and
returns them in the plan (`instrument`, `metricsFactory` and, with logs
on, `logHandlerFactory`), and `BackplaneCommand.run()` hands the plan to
`BootstrapCoordinator`, which installs each subsystem exactly once. An
app that does not use `BackplaneCommand` applies the plan itself with
`BootstrapCoordinator.shared.apply(plan)` and runs
each entry of `plan.lifecycleServices` (its `service`) in its own
`ServiceGroup`.

The returned plan carries a single `LifecycleService`, labelled `otel`,
whose `ServiceGroup` runs the export loops of every enabled backend
until graceful shutdown. A caller that copies only `lifecycleServices`
into another plan gets the export loops but loses the tracer and
metrics factory, so nothing is recorded.

## Run the service

```bash
swift run my-app serve \
    --trace --otel-endpoint=http://otel-collector:4318/v1/traces \
    --metrics --otel-metrics-endpoint=http://otel-collector:4318/v1/metrics
```

(The service name isn't a flag on these option groups — it's
supplied programmatically as `serviceName: App.identifier`.)

Per OpenTelemetry's spec, environment variables override CLI
defaults. Useful for production:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.example.com:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc  # gRPC, so port 4317
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production
```

These hit the same `OTel.Configuration` `swift-otel` builds
internally; see
[`OTel+Configuration`](https://github.com/swift-otel/swift-otel/blob/main/Sources/OTel/OTelAPI/OTel%2BConfiguration.swift)
for the full list.

### Backplane-style config (env via swift-configuration)

Beyond the OTel-spec env vars, the
``OTelTracingOptions/merging(from:)`` and
``OTelMetricsOptions/merging(from:)`` methods let env vars flow
through the same `ConfigReader` an app already
uses for its other settings. Pair the option groups with a
config-driven fallback:

```swift
func bootstrap(config: ConfigReader, environment: Environment) throws -> BootstrapPlan {
    let trace = tracing.merging(from: config.scoped(to: "tracing"))
    let metrics = metrics.merging(from: config.scoped(to: "metrics"))
    return try BackplaneOTel.makeBootstrap(
        serviceName: App.identifier,
        tracing: trace,
        metrics: metrics
    )
}
```

Operators can now drive the same fields via env vars:

```bash
TRACING_ENABLED=true
TRACING_ENDPOINT=http://otel-collector:4318/v1/traces
TRACING_SAMPLE_RATE=0.1
METRICS_ENABLED=true
METRICS_ENDPOINT=http://otel-collector:4318/v1/metrics
```

…or via a `.env` file, secret-manager-backed provider, or
anything else `ConfigReader` supports. CLI flags still win when
explicitly passed.

## Logs over OTLP, with console output and runtime levels

With `logsEnabled: true`, OTLP log records go through the level table
like any other handler. Pass `localLogs` to keep console output too.
Both legs sit behind one `LevelTableLogHandler`, so `--log-rule`,
`logging.rules` and runtime `set` change what reaches both:

```swift
func bootstrap(config: ConfigReader, environment: Environment) throws -> BootstrapPlan {
    var plan = try BackplaneOTel.makeBootstrap(
        serviceName: App.identifier,
        tracing: tracing,
        metrics: metrics,
        logsEnabled: true,
        localLogs: BackplaneLogging.stream   // after `configure:` when both are given
    )
    let merged = logging.merging(from: config.scoped(to: "logging"))
    plan.logLevel = merged.resolvedLogLevel
    plan.logRules = merged.resolvedLogRules
    plan.rejectedLogRules = merged.rejectedLogRules
    return plan
}
```

Each OTLP record carries its logger label as the attribute `logger`
(``BackplaneOTel/loggerLabelKey``). With traces on as well, the plan's
metadata provider is `OTel.makeLoggingMetadataProvider()`, so console
lines inside a span carry `trace_id` / `span_id` / `trace_flags`. The
OTLP records take their ids from the span context directly.

To keep your own log handler and export only traces and metrics, pass
`logsEnabled: false` and set `plan.logHandlerFactory` yourself, adding
`plan.loggerMetadataProvider = OTel.makeLoggingMetadataProvider()` for
trace ids in log lines.

An endpoint set through the options or `configure:` is used as-is. For
OTLP/HTTP, give the signal's full URL
(`http://127.0.0.1:4318/v1/traces`); left unset, swift-otel's default
`http://localhost:4318` gets the `/v1/<signal>` path appended.

## Pre-flight checks

A common debug step: enable OTel diagnostic logging to see what
swift-otel is doing.

```swift
func bootstrap(config: ConfigReader, environment: Environment) throws -> BootstrapPlan {
    try BackplaneOTel.makeBootstrap(
        serviceName: App.identifier,
        tracing: tracing,
        metrics: metrics,
        logsEnabled: false
    ) { config in
        config.diagnosticLogger = .console
        config.diagnosticLogLevel = .debug
    }
}
```

The `configure:` closure is the last-mile escape hatch: the
helper applies CLI flags first, then runs your closure on the
resulting `OTel.Configuration` before building the backends. Use it for
mTLS paths, custom headers, resource attributes, sampling, or
batch tuning.

## Local development

OTel collector runs locally as a single Docker container:

```bash
docker run --rm -p 4317:4317 -p 4318:4318 \
    -v $(pwd)/otel-collector.yaml:/etc/otelcol/config.yaml \
    otel/opentelemetry-collector:latest
```

A minimal `otel-collector.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  debug:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      exporters: [debug]
```

Start the collector, then `swift run my-app serve --trace
--otel-endpoint=http://localhost:4318/v1/traces`. Spans appear in the collector's
stdout, easy to inspect.

## Sampling

In production you usually don't want 100% trace sampling.
`OTelTracingOptions.sampleRate` maps to OTel's
`traceIDRatio` sampler:

```bash
swift run my-app serve --trace --trace-sample=0.1
```

Above 0.5 the sampler still respects parent-based decisions for
incoming requests, so a sampled trace stays sampled across
service hops.

## What you get out of the box

With OTel enabled, every `withSpan(_:)` / `startSpan(_:)` call in
your code (or in libraries you depend on, e.g. NIOPosix's HTTP
server) produces spans that:

- Inherit the active trace context via the configured
  propagators (default: W3C `traceparent` / `traceparent`).
- Carry the OTel resource attributes you set in the configuration
  (`service.name`, `service.version`, `deployment.environment`,
  `host.name`, …).
- Stream out via the configured OTLP exporter — gRPC by default,
  HTTP+Protobuf or HTTP+JSON also supported via
  `OTel.Configuration`.

## Next

- `Backplane` — the bootstrap pipeline these helpers feed into.
- `BackplaneGCP` — when you want the OTel data to land in Cloud
  Trace and the logs in Cloud Logging.
