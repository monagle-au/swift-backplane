# Postgres Walkthrough

Configure, register, and run Postgres-backed services and tasks
in a Backplane application.

## Overview

Backplane treats Postgres as a regular ``ServiceKey``-keyed
service: declare the dependency, and the framework brings up a
`PostgresClient` before your services start. The `Postgres`
package trait gates the entire integration so apps that don't
need it don't pull in `postgres-nio`.

## Enable the trait

In your `Package.swift`:

```swift
.package(
    url: "https://github.com/<org>/swift-backplane.git",
    from: "1.0.0",
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

```swift
import Backplane
import BackplanePostgres

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    static let identifier = "my-app"

    static func configure(_ services: inout ServiceRegistry) {
        services.register(PostgresServiceKey.self, entry: postgresServiceEntry())
    }
}
```

`postgresServiceEntry()` is a ``ConcreteServiceEntry`` configured
as ``ServiceLifecycleMode/persistent`` with the label `"postgres"`.
Its build closure reads the `postgres.*` scope of your
`ConfigReader` (default: process environment variables) and
constructs a `PostgresClient`.

## Configuration keys

Read by ``PostgresNIO/PostgresClient/Configuration/init(config:)``
under the `postgres` scope:

| Key                                       | Type   | Default     | Notes                                            |
|-------------------------------------------|--------|-------------|--------------------------------------------------|
| `postgres.username`                       | String | `"postgres"`|                                                  |
| `postgres.password`                       | String | (required)  | Read with `isSecret: true` — redacted in diagnostics. |
| `postgres.database`                       | String | (required)  |                                                  |
| `postgres.host`                           | String | `"localhost"`| Ignored when `unixSocketPath` is set.            |
| `postgres.port`                           | Int    | `5432`      | Ignored when `unixSocketPath` is set.            |
| `postgres.unixSocketPath`                 | String | unset       | When set, takes precedence over host/port.       |
| `postgres.tls.base`                       | enum   | `disable`   | `disable` / `prefer` / `require`.                |
| `postgres.tls.minimumTLSVersion`          | enum   | unset       | `tlsv1` / `tlsv11` / `tlsv12` / `tlsv13`.        |
| `postgres.tls.maximumTLSVersion`          | enum   | unset       | Same range.                                      |
| `postgres.tls.cipherSuites`               | String | unset       | Pass-through to NIOSSL.                          |
| `postgres.pool.minimumConnections`        | Int    | (NIO default) |                                                |
| `postgres.pool.maximumConnections`        | Int    | (NIO default) |                                                |
| `postgres.pool.connectionIdleTimeoutSeconds` | Int | (NIO default) |                                                |
| `postgres.connectTimeoutSeconds`          | Int    | (NIO default) |                                                |
| `postgres.statementTimeoutSeconds`        | Int    | unset       | When set, sent as `statement_timeout` startup parameter (milliseconds). `0` disables explicitly. |

For Cloud SQL via Cloud Run, the unix-socket path follows GCP's
convention:

```
postgres.unixSocketPath=/cloudsql/<project>:<region>:<instance>/.s.PGSQL.5432
```

## Use the client

Inside any command's `execute(with:)` (or service `run()`),
unwrap the registered client:

```swift
struct ListUsers: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(commandName: "list-users")
    var requiredServices: [any ServiceKey.Type] { [PostgresServiceKey.self] }

    func execute(with services: ServiceValues) async throws {
        let pg = services.postgres!
        let rows = try await pg.query("SELECT id, email FROM users ORDER BY id LIMIT 100", logger: .init(label: "list-users"))
        for try await (id, email) in rows.decode((Int, String).self) {
            print("\(id)\t\(email)")
        }
    }
}
```

`services.postgres` returns the `PostgresClient?` registered
under ``PostgresServiceKey``. Force-unwrapping is safe because
``BackplaneCommand/requiredServices`` guarantees the service was
built before `execute` runs — the runner would have failed at
startup with ``ApplicationError/missingService(key:)`` otherwise.

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
    var requiredServices: [any ServiceKey.Type] { [PostgresServiceKey.self] }

    func execute(with services: ServiceValues) async throws {
        let logger = ServiceContext.active.logger ?? Logger(label: "migrate")
        try await PostgresMigrator.migrate(
            [CreateUsers()],
            on: services.postgres!,
            logger: logger
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

try await services.postgres!.query(query, logger: logger)
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
    try await services.postgres!.query(...)
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
idle pools don't hold connections during scale-down.

```bash
postgres.pool.minimumConnections=0
postgres.pool.maximumConnections=8
postgres.pool.connectionIdleTimeoutSeconds=30
postgres.connectTimeoutSeconds=5
postgres.statementTimeoutSeconds=10
```

For Cloud SQL specifically, prefer the unix socket — it bypasses
the IP-based per-instance quota:

```bash
postgres.unixSocketPath=/cloudsql/<project>:<region>:<instance>/.s.PGSQL.5432
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

- ``Backplane`` — the framework's core concepts.
- ``Backplane/CloudDeployment`` — production deployment notes.
- ``BackplaneGCP`` — Cloud Logging / Cloud Trace integration when
  running on Cloud SQL + Cloud Run.
