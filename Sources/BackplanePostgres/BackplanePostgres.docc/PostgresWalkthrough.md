# Postgres Walkthrough

Configure, register, and run Postgres-backed services and tasks
in a Backplane application.

## Overview

Backplane treats Postgres as a regular keyed service: declare the
dependency via `\.postgres`, and the framework brings up a
`PostgresClient` before your services start. The `Postgres`
package trait gates the entire integration so apps that don't
need it don't pull in `postgres-nio`.

## Enable the trait

In your `Package.swift`:

```swift
.package(
    url: "https://github.com/<org>/swift-backplane.git",
    from: "2.0.0",
    traits: ["Postgres"]
),

.executableTarget(
    name: "MyService",
    dependencies: [
        .product(name: "Backplane", package: "swift-backplane"),
        .product(name: "BackplanePostgres", package: "swift-backplane"),
    ]
),
```

## Register the service

``BackplanePostgresService`` conforms to `BackplaneService`, so
declaring the dependency **is** the registration — no `services()`
entry needed:

```swift
import Backplane
import BackplanePostgres

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    static let identifier = "my-app"
    // No services() override required for \.postgres.
}

struct Serve: PersistentCommand {
    typealias App = MyApp
    var requiredServices: ServiceList { [\.postgres] }
}
```

The graph materialises an `EntryDescriptor` with id `"postgres"`
(subgroup `.core` by default). Its `make(context:)` reads the
entry's config scope — `postgres.*` for the stock key (default
source: process environment variables) — constructs a
`PostgresClient`, and wraps it in a ``BackplanePostgresService``,
which spawns and cancels the client's run loop for the graph. The
key is exposed as `Services.postgres`, so commands and factories
address it as `\.postgres`.

To override the entry's policies, add an explicit descriptor to
`services()` — explicit descriptors always win over materialised
defaults:

```swift
static func services() -> [EntryDescriptor] {
    [EntryDescriptor(\.postgres, subgroup: .integrations)]
}
```

For a second database, declare another key with a different id and
the same type — its entry reads its own config scope
(`analytics.*` below), because a factory's config is scoped to the
entry id:

```swift
extension Services {
    public var analyticsDB: ServiceKey<BackplanePostgresService> {
        ServiceKey(id: "analytics")     // reads analytics.host, …
    }
}
```

> Note: `postgresEntryDescriptor()` and the deprecated
> `Services.postgresKey` alias were removed in 2.0.0.

## Configuration keys

Read by ``PostgresNIO/PostgresClient/Configuration/init(config:)``
under the entry's config scope — `postgres` for the stock key
(a second key with id `"analytics"` reads the same keys under
`analytics.*`). With the default
`EnvironmentVariablesProvider`, each key maps to its
upper-snake-case env var (`postgres.host` → `POSTGRES_HOST`,
`postgres.unixSocketPath` → `POSTGRES_UNIX_SOCKET_PATH`, …).

| Key                                       | Type   | Default     | Notes                                            |
|-------------------------------------------|--------|-------------|--------------------------------------------------|
| `postgres.username`                       | String | `"postgres"`|                                                  |
| `postgres.password`                       | String | (required)  | Read with `isSecret: true` — redacted in diagnostics. |
| `postgres.database`                       | String | (required)  |                                                  |
| `postgres.host`                           | String | `"localhost"`| Ignored when `unixSocketPath` is set.            |
| `postgres.port`                           | Int    | `5432`      | Ignored when `unixSocketPath` is set.            |
| `postgres.unixSocketPath`                 | String | unset       | When set, takes precedence over host/port.       |
| `postgres.tls.mode`                       | enum   | `disable`   | TLS mode: `disable` / `prefer` / `require`.      |
| `postgres.tls.minimumVersion`             | enum   | unset       | `tlsv1` / `tlsv11` / `tlsv12` / `tlsv13`.        |
| `postgres.tls.maximumVersion`             | enum   | unset       | Same range.                                      |
| `postgres.tls.cipherSuites`               | String | unset       | Pass-through to NIOSSL.                          |
| `postgres.pool.minimumConnections`        | Int    | (NIO default) |                                                |
| `postgres.pool.maximumConnections`        | Int    | (NIO default) |                                                |
| `postgres.pool.connectionIdleTimeoutSeconds` | Int | (NIO default) |                                                |
| `postgres.connectTimeoutSeconds`          | Int    | (NIO default) |                                                |
| `postgres.statementTimeoutSeconds`        | Int    | unset       | When set, sent as `statement_timeout` startup parameter (milliseconds). `0` disables explicitly. |

> Note: the TLS keys moved in 2.0.0 — they were previously flat at the
> entry scope (`postgres.base`, `postgres.minimumTLSVersion`,
> `postgres.maximumTLSVersion`, `postgres.cipherSuites`). The old keys
> are no longer read. As env vars the new keys are `POSTGRES_TLS_MODE`,
> `POSTGRES_TLS_MINIMUM_VERSION`, `POSTGRES_TLS_MAXIMUM_VERSION`, and
> `POSTGRES_TLS_CIPHER_SUITES`. Trust roots and client certificates are
> not yet configurable; connections verify against the platform default
> trust store.

For Cloud SQL via Cloud Run, the unix-socket path follows GCP's
convention:

```
postgres.unixSocketPath=/cloudsql/<project>:<region>:<instance>/.s.PGSQL.5432
```

## Use the client

Inside any command's `execute(with:)` (or service factory),
resolve the service by keypath and drive queries through its
``BackplanePostgresService/client``:

```swift
struct ListUsers: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(commandName: "list-users")
    var requiredServices: ServiceList { [\.postgres] }

    func execute(with context: BackplaneContext) async throws {
        let pg = try await context.requireService(\.postgres)
        let rows = try await pg.client.query(
            "SELECT id, email FROM users ORDER BY id LIMIT 100",
            logger: context.logger
        )
        for try await (id, email) in rows.decode((Int, String).self) {
            print("\(id)\t\(email)")
        }
    }
}
```

`requireService(\.postgres)` returns the
``BackplanePostgresService`` (its `client` property is the
`PostgresClient`; `inner` is an alias). Because the command
declared `\.postgres` in `requiredServices`, the graph boots the
entry before `execute` runs; `requireService` waits for it to be
resolution-ready and throws a `ServiceGraphError` — e.g.
`missingService(id:expectedType:)` for an unregistered key — if
it cannot resolve.

## Migrations

A migration is anything that conforms to ``PostgresMigration``:

```swift
struct CreateUsers: PostgresMigration {
    var name: String { "0001_create_users" }
    var queries: [PostgresQuery] {
        [
            """
            CREATE TABLE users (
                id BIGSERIAL PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );
            """
        ]
    }
}
```

Run them via ``PostgresMigrator``:

```swift
struct Migrate: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(commandName: "migrate")
    var requiredServices: ServiceList { [\.postgres] }

    func execute(with context: BackplaneContext) async throws {
        let pg = try await context.requireService(\.postgres)
        try await PostgresMigrator.migrate(
            [CreateUsers()],
            on: pg.client,
            logger: context.logger
        )
    }
}
```

The migrator:

1. Ensures the `_migrations` table exists.
2. For each migration, checks whether its `name` is already
   recorded.
3. If not, runs the migration's queries inside a transaction
   and inserts the row on success.
4. Logs at `info` for applied migrations, `debug` for skipped.

The order of migrations is the order you pass them. Use a
file-numbering convention (`0001_`, `0002_`, …) to keep ordering
explicit.

## Multi-row INSERT helper

`PostgresQuery.multiValueRowQuery(...)` builds a parameterised
multi-row VALUES clause:

```swift
let users: [(email: String, name: String)] = [
    ("a@example.com", "Anna"),
    ("b@example.com", "Bert"),
]

let query = PostgresQuery.multiValueRowQuery(
    from: users,
    unsafeSQL: { placeholders in
        "INSERT INTO users (email, name) VALUES \(placeholders)"
    },
    bindings: { user in
        [PostgresData(string: user.email), PostgresData(string: user.name)]
    }
)

try await pg.client.query(query, logger: logger)
```

The helper handles placeholder offsets (`$1, $2, $3, $4, …`) and
accumulates bindings in the right order. Only the
`unsafeSQL` closure can introduce SQL injection — keep it free of
caller-supplied data.

## Optional binding helpers

```swift
PostgresData.optional(uuid: maybeUUID)   // nil → .null
PostgresData.optional(date: maybeDate)
PostgresData.optional(int:  maybeInt)
```

Useful when binding nullable columns from optional Swift values.

## Error reflection (DEBUG)

To unwrap `PSQLError` / `PostgresDecodingError` reflections at
the boundary of a request handler:

```swift
try await logUnwrappedPostgreSQLErrors(logger: logger) {
    try await pg.client.query(...)
}
```

In DEBUG builds, this catches anything conforming to
`PGReflectableError`, logs a concise `String(reflecting:)` view
at `.error`, and rethrows the original. In release builds the
wrapper is a pass-through with no overhead.

## Connection sizing on Cloud Run

Cloud Run instances are short-lived. Set
`postgres.pool.maximumConnections` low enough that a 1000-instance
fanout doesn't exhaust the database (e.g. 5–10), and set
`postgres.pool.connectionIdleTimeoutSeconds` short (e.g. 30) so
idle pools don't hold connections during scale-down. As env vars:

```bash
POSTGRES_POOL_MINIMUM_CONNECTIONS=0
POSTGRES_POOL_MAXIMUM_CONNECTIONS=8
POSTGRES_POOL_CONNECTION_IDLE_TIMEOUT_SECONDS=30
POSTGRES_CONNECT_TIMEOUT_SECONDS=5
POSTGRES_STATEMENT_TIMEOUT_SECONDS=10
```

For Cloud SQL specifically, prefer the unix socket — it bypasses
the IP-based per-instance quota:

```bash
POSTGRES_UNIX_SOCKET_PATH=/cloudsql/<project>:<region>:<instance>/.s.PGSQL.5432
```

## Testing

Unit tests for configuration parsing live in
`Tests/BackplanePostgresTests/PostgresConfigTests.swift`. Build a
configuration in-memory and assert on the resolved
`PostgresClient.Configuration` values without ever opening a
connection:

```swift
let config = ConfigReader(provider: InMemoryProvider(values: [
    "postgres.host": .init(.string("db.internal"), isSecret: false),
    "postgres.database": .init(.string("test"), isSecret: false),
    // …
]))
let pg = PostgresClient.Configuration(config: config.scoped(to: "postgres"))
#expect(pg.options.maximumConnections == 20)
```

## Next

- `Backplane` — the framework's core concepts.
- `BackplaneGCP` — Cloud Logging / Cloud Trace integration when
  running on Cloud SQL + Cloud Run.
