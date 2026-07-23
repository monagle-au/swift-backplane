# ``BackplanePostgres``

PostgresNIO-backed service, configuration, migrations, and
ergonomic query helpers for Backplane applications.

## Overview

`BackplanePostgres` is opt-in: enable the `Postgres` package trait
to bring `postgres-nio` into the dependency graph and link this
target. It contributes:

- ``BackplanePostgresService`` — a `ManagedService` wrapper around
  `PostgresClient` — plus the `Services.postgres` key and the
  ``postgresEntryDescriptor(subgroup:dependencies:)`` factory, so
  commands declare a Postgres dependency the same way as any other
  service (`\.postgres`).
- A configuration builder (`PostgresClient.Configuration(config:)`)
  that maps a `ConfigReader` scope onto the full set of
  postgres-nio knobs — connection mode (host/port or unix socket),
  TLS, pool sizing, timeouts, statement timeout.
- A migration runner (``PostgresMigrator``) that's transactional,
  idempotent, and tracked via a `_migrations` table.
- Helper extensions for binding optional values
  (`PostgresData.optional(...)`) and building multi-row INSERTs
  (`PostgresQuery.multiValueRowQuery(...)`).
- DEBUG-only error reflection (`PGReflectableError` /
  `logUnwrappedPostgreSQLErrors`).

## Topics

### Walkthrough

- <doc:PostgresWalkthrough>

### Service registration

- ``BackplanePostgresService``
- ``postgresEntryDescriptor(subgroup:dependencies:)``

### Configuration

- ``PostgresNIO/PostgresClient/Configuration/init(config:)``
- ``PostgresNIO/PostgresClient/Configuration/applyPoolAndTimeoutOverrides(from:)``

### Migrations

- ``PostgresMigration``
- ``PostgresMigrator``
