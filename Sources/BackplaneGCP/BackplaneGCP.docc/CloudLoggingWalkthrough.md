# Cloud Logging & Cloud Trace Walkthrough

Wire Backplane up to Cloud Run / Cloud Run Jobs / GKE so logs land
in Cloud Logging and spans land in Cloud Trace, with a clickable
"view trace" link from every log line.

## Overview

Cloud Logging treats stdout/stderr from Cloud Run as a stream of
log entries. When the captured line is valid JSON, it promotes
recognised top-level fields (`severity`, `timestamp`, source
location, trace, span) to first-class log-entry properties and
exposes the rest as `jsonPayload`.

Three magic keys make the trace ↔ log link work:

- `logging.googleapis.com/trace` =
  `projects/<id>/traces/<trace-id>` — the W3C trace ID prefixed
  with the project path.
- `logging.googleapis.com/spanId` — the W3C span ID.
- `logging.googleapis.com/trace_sampled` — `"true"` / `"false"`.

The `BackplaneGCP` target writes those keys for you when you use
``GCPLogHandler`` (or `StructuredLogHandler` with the
``Backplane/StructuredLogProfile/gcp(projectID:)`` profile) **and**
something has populated `LoggingTraceContext` on the active
`ServiceContext`. ``GCPTracer`` does the population
automatically; other tracers can do it via a
`Logger.MetadataProvider` or a per-span shim.

## Enable the trait

```swift
.package(
    url: "https://github.com/<org>/swift-backplane.git",
    from: "1.0.0",
    traits: ["GCP"]
),

.executableTarget(
    name: "MyService",
    dependencies: [
        .product(name: "Backplane", package: "swift-backplane"),
        .product(name: "BackplaneGCP", package: "swift-backplane"),
    ]
),
```

## Wire up logging

The simplest setup uses ``BackplaneGCP/cloudRunOrStream`` — Cloud
Logging-shaped JSON when on Cloud Run / Cloud Run Jobs, plain
stream output elsewhere:

```swift
import Backplane
import BackplaneGCP

struct Serve: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(commandName: "serve")

    @OptionGroup var logging: LoggingOptions

    var requiredServices: [PartialKeyPath<Services>] { [] }

    func bootstrap(config: ConfigReader, environment: Environment) async throws -> BootstrapPlan {
        var plan = BootstrapPlan()
        plan.logHandlerFactory = BackplaneGCP.cloudRunOrStream.asFactory
        plan.logLevel = logging.resolvedLogLevel
        return plan
    }
}
```

The selector reads `K_SERVICE` / `CLOUD_RUN_JOB` at bootstrap
time. On a developer's terminal these are absent, so the fallback
`BackplaneLogging.stream` is used. In production on Cloud Run
they're injected automatically and ``GCPLogHandler`` takes over.

## Wire up tracing

For Cloud Trace export, install ``GCPTracer`` via the static
bootstrap path:

```swift
@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    static let identifier = "my-app"

    public static func main() async {
        bootstrapGCPTracing()
        await RootCommand.main()
    }

    static func services() -> [EntryDescriptor] { [ ... ] }
}
```

``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)`` reads
`GOOGLE_CLOUD_PROJECT` from the environment by default — Cloud
Run injects it for every service. It installs ``GCPTracer`` on
the global instrumentation system and starts an unstructured
flush task that drains spans every 5 seconds.

`bootstrapGCPTracing` installs the tracer directly on the global
instrumentation system — it does **not** route through
`BootstrapCoordinator`. Call it once, before any command whose
`BackplaneCommand.bootstrap(config:environment:)` plan would
also install an instrument; a second instrumentation bootstrap
crashes the process.

The tracer:

1. Generates W3C trace IDs / span IDs at every
   `withSpan(_:)` / `startSpan(_:)`.
2. Writes the IDs into `LoggingTraceContext` on the active
   `ServiceContext` so ``GCPLogHandler`` reads them on every
   log call.
3. Sends finished spans to ``CloudTraceExporter``, which batches
   them and uploads to `cloudtrace.googleapis.com/v2/...`.

## Run with Cloud SQL + Cloud Logging + Cloud Trace

A typical Cloud Run service:

```bash
# Cloud Run injects these automatically — shown for clarity.
K_SERVICE=my-app
GOOGLE_CLOUD_PROJECT=my-project

# Application config you set on the service.
LOG_LEVEL=info
POSTGRES_UNIX_SOCKET_PATH=/cloudsql/my-project:us-central1:db/.s.PGSQL.5432
POSTGRES_USERNAME=app
POSTGRES_PASSWORD=...                                  # from Secret Manager
POSTGRES_DATABASE=production
POSTGRES_POOL_MAXIMUM_CONNECTIONS=8
POSTGRES_CONNECT_TIMEOUT_SECONDS=5
POSTGRES_STATEMENT_TIMEOUT_SECONDS=10
```

Build a container per the deployment guide and deploy. Cloud
Logging shows JSON entries with `view trace` links; Cloud Trace
shows the corresponding distributed trace.

## Permissions

The Cloud Run service account needs:

- `roles/cloudtrace.agent` — for Cloud Trace span uploads.
- `roles/logging.logWriter` — granted by default on Cloud Run.
- `roles/cloudsql.client` — if using Cloud SQL.

Cloud Trace export uses Application Default Credentials. Cloud
Run automatically vends a token from the service account.

## Use Cloud Trace alongside OpenTelemetry

For services that already export to OpenTelemetry but want Cloud
Logging's "view trace" link, use the OTel collector's `googlecloud`
exporter rather than ``GCPTracer``. The trick is bridging
trace IDs into `LoggingTraceContext` so ``GCPLogHandler`` can
emit the magic keys. With swift-otel, write a custom
`Logger.MetadataProvider` that reads the active span and
populates `LoggingTraceContext` — the `BackplaneOTel`
walkthrough's metadata-provider section shows the hook to build
on.

## Project ID corner cases

- **Missing project ID**: ``GCPLogHandler`` continues to log
  but *suppresses* the trace correlation fields when
  `gcpProjectID` is `nil` or empty. The logs still land in
  Cloud Logging; the "view trace" link won't render.
- **Different projects**: if the trace export writes to a
  different project from the logs (e.g. centralised tracing
  project), pass the trace project explicitly to
  ``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)`` and
  the log project to ``GCPLogHandler``'s `gcpProjectID`.

## Local testing

With the `GCP` trait enabled but no Cloud Run env vars,
``BackplaneGCP/cloudRunOrStream`` falls back to stream output so
local terminals stay readable. Trace export is a no-op when
`GOOGLE_CLOUD_PROJECT` is unset (or set to an empty string).

For end-to-end testing against Cloud Trace, set
`GOOGLE_CLOUD_PROJECT` and authenticate with
`gcloud auth application-default login` — the exporter will
upload to your real project.

## Next

- The core `Backplane` catalog's Cloud Deployment article — the cross-cutting deployment
  guide.
- `BackplaneOTel` — for vendor-neutral tracing or
  OTel-collector-based pipelines that fan out to Cloud Trace plus
  other backends.
- `BackplanePostgres` — Cloud SQL configuration walkthrough.
