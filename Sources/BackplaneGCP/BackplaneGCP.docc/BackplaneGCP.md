# ``BackplaneGCP``

Cloud Trace and Cloud Logging integration for Backplane
applications running on Google Cloud Run, Cloud Run Jobs, or GKE.

## Overview

`BackplaneGCP` is opt-in: enable the `GCP` package trait to bring
this target into the dependency graph. It contributes:

- ``GCPLogHandler`` — a `LogHandler` that emits Cloud Logging's
  structured-JSON shape (severity, timestamp, source location,
  trace correlation magic keys). Implemented as a thin wrapper
  around `StructuredLogHandler` with the
  ``Backplane/StructuredLogProfile/gcp(projectID:)`` profile.
- ``GCPTracer`` — a `Tracer` that exports spans to Cloud Trace's
  v2 REST API and writes `LoggingTraceContext` into the active
  `ServiceContext` so log lines automatically carry the magic
  keys Cloud Logging needs to render the `view trace` link.
- A ``BackplaneGCP/cloudRunOrStream`` selector that picks
  Cloud-Logging-shaped JSON when running on Cloud Run / Cloud Run
  Jobs (`K_SERVICE` or `CLOUD_RUN_JOB` env vars) and plain
  stream output everywhere else.
- ``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)`` — an
  escape-hatch convenience for installing ``GCPTracer`` directly
  via the static-bootstrap path.

When `K_SERVICE` is set (Cloud Run) or `CLOUD_RUN_JOB` (Cloud
Run Jobs), Cloud Logging auto-ingests stdout. Combined with
``GCPTracer`` writing the trace ID into `LoggingTraceContext`,
you get clickable trace links on every log entry without running
a sidecar collector.

## Topics

### Walkthrough

- <doc:CloudLoggingWalkthrough>

### Tracing

- ``GCPTracer``
- ``GCPSpan``
- ``GCPFinishedSpan``
- ``CloudTraceExporter``

### Logging

- ``GCPLogHandler``
- ``BackplaneGCP``

### Bootstrap helpers

- ``Backplane/BackplaneApplication/bootstrapGCPTracing(projectID:)``

### Profile (extension on core)

- ``Backplane/StructuredLogProfile/gcp(projectID:)``
