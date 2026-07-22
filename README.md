# Backplane

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2015+-blue.svg)](https://swift.org)

**Backplane** is a small server-side Swift framework that ties together
the SSWG ecosystem (`swift-service-lifecycle`, `swift-argument-parser`,
`swift-service-context`, `swift-log`, `swift-metrics`,
`swift-distributed-tracing`, `swift-configuration`) into a single
ergonomic harness for building CLI-driven services. It abstracts away
the boilerplate of the bootstrap dance — installing the global
logging/metrics/tracing systems in the right order, after CLI parsing,
before any service is built — without taking power away from the
underlying libraries.

Backplane is structured for both long-running services (HTTP servers,
queue workers) and one-shot tasks (migrations, backfills) sharing the
same service registry and configuration story.

---

## Features

- **Declarative service graph**. Services are registered via typed
  `ServiceKey<T>` values exposed as keypath-accessible properties on
  the `Services` namespace. Backplane topologically sorts them
  before handing them to a `ServiceGroup`.
- **Keypath-driven references**. `\.databaseKey` style references
  everywhere — autocomplete-friendly and the resolved type is
  inferred from the keypath.
- **Two command shapes**: `PersistentCommand` (services run until
  signalled) and `TaskCommand` (services come up, the command does
  its work, the group shuts down gracefully).
- **Bootstrap pipeline**. `BackplaneCommand.bootstrap(...)` returns a
  `BootstrapPlan` that the framework applies through
  `BootstrapCoordinator` — globals install in tracing → metrics →
  logging order, after CLI flags are parsed, before the first
  `Logger` is built.
- **Vendor-neutral structured logging** via `StructuredLogHandler`
  driven by an extensible `StructuredLogProfile`.
- **CLI option groups** for common observability flags
  (`LoggingOptions`, `TracingOptions`, `MetricsOptions`).
- **Trait-gated optional integrations**: every cloud-vendor or
  ecosystem dependency is opt-in via a Swift Package trait, so apps
  pay nothing for what they don't use.

## Requirements

- Swift 6.2+
- macOS 15+

## Installation

Add Backplane to `Package.swift`:

```swift
.package(url: "https://github.com/<org>/swift-backplane.git", from: "1.0.0"),
```

By default, only the core `Backplane` library is resolved. Optional
integrations are enabled per-consumer via package traits — add only
the ones you need:

```swift
.package(
    url: "https://github.com/<org>/swift-backplane.git",
    from: "1.0.0",
    traits: ["Postgres", "OTel", "GCP"]
),
```

| Trait      | Library product   | Adds                                                     |
|------------|-------------------|----------------------------------------------------------|
| (none)     | `Backplane`        | Core framework, always available.                        |
| (none)     | `BackplaneVault`   | `ConfigStore` (writable, secret-aware config; safe for concurrent stores on one file via locked read-merge-writes) + `ConfigEncryption` protocol + `PassthroughEncryption` + `FileLock` (cross-process advisory lock). Imported on its own, no extra deps. |
| `Postgres` | `BackplanePostgres`| `PostgresNIO`-backed service key, configuration, migrations. |
| `OTel`     | `BackplaneOTel`    | `swift-otel` integration: `BootstrapPlan` factory + CLI flags. |
| `GCP`      | `BackplaneGCP`     | Cloud Trace tracer/exporter + Cloud Logging `LogHandler`. |
| `KeyfileEncryption` | (extends `BackplaneVault`) | `LocalKeyfileEncryption` — AES-256-GCM reference impl backed by a machine-local keyfile. Pulls `swift-crypto`. |

Then depend on each library product in the targets that need it:

```swift
.executableTarget(
    name: "MyService",
    dependencies: [
        .product(name: "Backplane", package: "swift-backplane"),
        .product(name: "BackplanePostgres", package: "swift-backplane"),
        .product(name: "BackplaneOTel", package: "swift-backplane"),
    ]
),
```

## At a glance

```swift
import Backplane
import BackplanePostgres

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    static let identifier = "my-app"

    static func services() -> [EntryDescriptor] {
        [postgresEntryDescriptor()]
    }
}

struct AppCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        subcommands: [Serve.self, Migrate.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(abstract: "Run the server")

    @OptionGroup var logging: LoggingOptions
    @OptionGroup var tracing: TracingOptions

    var requiredServices: [PartialKeyPath<Services>] { [\.postgresKey] }

    func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
        var plan = BootstrapPlan()
        plan.logLevel = logging.resolvedLogLevel
        plan.logHandlerFactory = logging.format.factory(default: BackplaneLogging.cloudRunOrStream.asFactory)
        return plan
    }
}

struct Migrate: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(abstract: "Run database migrations")
    var requiredServices: [PartialKeyPath<Services>] { [\.postgresKey] }

    func execute(with context: ServiceContext) async throws {
        let pg = try await context.requireService(\.postgresKey)
        try await PostgresMigrator.migrate(
            myMigrations,
            on: pg.client,
            logger: context.logger
        )
    }
}
```

## Declaring service keys

A service key is a computed `var` on the `Services` namespace, returning
a typed `ServiceKey<T>`. Consumers extend `Services` once per key:

```swift
extension Services {
    public var databaseKey: ServiceKey<PostgresClient> {
        ServiceKey(id: "database")
    }
}
```

That's the entire boilerplate. The keypath `\.databaseKey` is then
usable wherever Backplane accepts a service key — `requireService`,
dependency lists on `EntryDescriptor`, `requiredServices` on a
command. The return type of `requireService(\.databaseKey)` is
inferred from the keypath, so no cast is needed at the call site.

Satellite targets ship their keys the same way: `BackplanePostgres`
exposes `Services.postgresKey`, which is why the snippet above writes
`\.postgresKey` without declaring it itself.

## Documentation

Full DocC documentation lives alongside each module:

- [`Backplane`](Sources/Backplane/Backplane.docc/) — getting started,
  key concepts, local + cloud deployment guides.
- [`BackplanePostgres`](Sources/BackplanePostgres/BackplanePostgres.docc/)
  — Postgres walkthrough.
- [`BackplaneOTel`](Sources/BackplaneOTel/BackplaneOTel.docc/) — OTel
  walkthrough.
- [`BackplaneGCP`](Sources/BackplaneGCP/BackplaneGCP.docc/) — Cloud
  Trace + Cloud Logging walkthrough.

Build the docs locally with the
[Swift DocC Plugin](https://github.com/swiftlang/swift-docc-plugin):

```bash
swift package --traits Postgres,OTel,GCP \
    generate-documentation --target Backplane
```

## Testing

```bash
swift test                                 # core only
swift test --traits Postgres,OTel,GCP      # everything
```

The test suite covers dependency resolution, lifecycle modes,
bootstrap ordering, structured logging, CLI option parsing, and the
optional integrations.

## License

See [LICENSE](LICENSE).
