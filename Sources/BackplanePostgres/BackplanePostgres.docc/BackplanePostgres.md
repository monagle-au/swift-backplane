# ``BackplanePostgres``

PostgresNIO-backed service key, configuration, migrations, and
ergonomic query helpers for Backplane applications.

## Overview

`BackplanePostgres` is opt-in: enable the `Postgres` package trait
to bring `postgres-nio` into the dependency graph and link this
target. It contributes:

- A typed ``PostgresServiceKey`` so commands declare a Postgres
  dependency the same way as any other service.
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

- ``PostgresServiceKey``
- ``postgresServiceEntry()``

### Configuration

- The ``PostgresNIO/PostgresClient/Configuration/init(config:)``
  initializer maps a `ConfigReader` scope onto the postgres-nio
  configuration.
- The `applyPoolAndTimeoutOverrides(from:)` method layers pool
  + timeout knobs on top of an existing configuration.

### Migrations

- ``PostgresMigration``
- ``PostgresMigrator``

### Helpers

- The `PostgresData.optional(...)` extensions map optional Swift
  values to `PostgresData` (`.null` when nil).
- The `PostgresQuery.multiValueRowQuery(...)` helper builds a
  parameterised multi-row INSERT.

### Error reflection (DEBUG only)

- `PGReflectableError` and `PGReflectedError` wrap PostgresNIO
  errors with stable codes for diagnostic output.
- `logUnwrappedPostgreSQLErrors(logger:operation:)` is a
  pass-through wrapper that logs and rethrows any reflected
  error in DEBUG builds; release builds compile away the
  overhead.
