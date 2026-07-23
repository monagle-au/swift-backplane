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
between `@main` and your services running in a
`ServiceGroup`:

- Parsing CLI arguments via ArgumentParser
- Building a typed `ConfigReader` for the active ``Environment``
- Applying a ``BootstrapPlan`` to the global
  logging / metrics / tracing systems in the right order
- Booting the transitive closure of each command's required
  ``ServiceKey``s through a ``ServiceGraph``, with per-subgroup
  failure policies, blue-green replacement, hot reload, and
  recovery of failed entries
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
- ``ServiceLifecycleMode``

### Service graph

- ``ServiceGraph``
- ``EntryDescriptor``
- ``ServiceKey``
- ``Services``
- ``AnyServiceKey``
- ``ServiceKeyConvertible``
- ``ServiceContext``
- ``ServiceState``
- ``ServiceFault``
- ``ServiceGraphError``

### Managed services

- ``ManagedService``
- ``LifecycleAdapter``
- ``PassiveService``
- ``HotReloadable``
- ``ReplacementStrategy``
- ``AnchorService``
- ``AnyService``

### Subgroups & health

- ``SubgroupTag``
- ``SubgroupPolicy``
- ``ServiceHealthReporter``
- ``ServiceLifecycleHandle``
- ``ConfigurationRequirement``

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
- ``LoggingTraceContextKey``
- ``LogHandlerFactory``
