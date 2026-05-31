# ``Backplane``

A small server-side Swift framework that wraps the SSWG ecosystem
into a single ergonomic harness for CLI-driven services.

## Overview

Backplane ties together `swift-service-lifecycle`,
`swift-argument-parser`, `swift-service-context`, `swift-log`,
`swift-metrics`, `swift-distributed-tracing`, and
`swift-configuration` so that an application is a single
``BackplaneApplication`` declaration plus one or more
``BackplaneCommand`` conformances. The framework handles everything
between `@main` and your `Service`s running in a
`ServiceGroup`:

- Parsing CLI arguments via ArgumentParser
- Building a typed `ConfigReader` for the active ``Environment``
- Applying a ``BootstrapPlan`` to the global
  logging / metrics / tracing systems in the right order
- Topologically sorting ``ServiceKey`` dependencies and building
  services in dependency order
- Running the resulting `ServiceGroup` with graceful shutdown

Backplane is opinionated about *order* and *ergonomics*; it stays
deliberately neutral about *what* you log to, *what* you trace
with, and *what* services you build. Vendor-specific dialects
(Cloud Logging, Cloud Trace, OpenTelemetry export, PostgresNIO)
live behind opt-in package traits so consumers pay nothing for
integrations they don't use.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:KeyConcepts>

### Deployment guides

- <doc:LocalDeployment>
- <doc:CloudDeployment>

### Application & commands

- ``BackplaneApplication``
- ``BackplaneCommand``
- ``PersistentCommand``
- ``TaskCommand``
- ``Environment``

### Service registry

- ``ServiceKey``
- ``ServiceRegistry``
- ``ServiceValues``
- ``ServiceEntry``
- ``ConcreteServiceEntry``
- ``ServiceLifecycleMode``
- ``AnchorService``
- ``AnyService``
- ``ApplicationError``

### Bootstrap pipeline

- ``BootstrapPlan``
- ``BootstrapCoordinator``
- ``LifecycleService``

### Observability

- ``LoggingOptions``
- ``TracingOptions``
- ``MetricsOptions``
- ``StructuredLogHandler``
- ``StructuredLogProfile``
- ``BackplaneLogging``
- ``LoggingTraceContext``
- ``LogHandlerFactory``

### Service context

- ``ServiceContext/active``
- ``ServiceContext/environment``
- ``ServiceContext/logger``
- ``ServiceContext/loggingTraceContext``
