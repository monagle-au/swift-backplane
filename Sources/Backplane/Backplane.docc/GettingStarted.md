# Getting Started

Build your first Backplane application — a single binary that runs
either as an HTTP-style persistent service or as a one-shot task.

## Overview

A Backplane app has three ingredients:

1. A type that conforms to ``BackplaneApplication`` and is marked
   `@main`. It declares an `identifier`, returns the app's service
   descriptors from `services()`, and names a `RootCommand`.
2. One or more ``BackplaneCommand`` conformances (typically
   ``PersistentCommand`` or ``TaskCommand``). Each declares the
   services it needs as keypaths over the ``Services`` namespace,
   optionally builds a ``BootstrapPlan``, and — for tasks —
   implements `execute(with:)`.
3. Typed ``ServiceKey`` declarations on ``Services``, each paired
   with an ``EntryDescriptor`` whose factory builds the service.

## Add the package

```swift
.package(url: "https://github.com/<org>/swift-backplane.git", from: "1.0.0"),
```

In the target that depends on it:

```swift
.executableTarget(
    name: "MyService",
    dependencies: [
        .product(name: "Backplane", package: "swift-backplane"),
    ]
),
```

## A minimal application

```swift
import ArgumentParser
import Backplane
import ServiceLifecycle

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = Serve
    static let identifier = "my-app"

    static func services() -> [EntryDescriptor] {
        []   // No services yet — Serve will run with an empty graph.
    }
}

struct Serve: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(
        abstract: "Run the service forever."
    )

    var requiredServices: [PartialKeyPath<Services>] { [] }
}
```

`swift run my-app` boots the app, parses CLI args, applies the
default (empty) ``BootstrapPlan``, builds an empty ``ServiceGraph``,
and runs an empty `ServiceGroup` until the process receives
`SIGINT`/`SIGTERM`. Not very useful yet — but the harness is fully
wired.

## Add a real service

A long-lived component is anything conforming to
[`ServiceLifecycle.Service`](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/servicelifecycle/service)
— for HTTP servers, queue consumers, or gRPC listeners the
conformance is usually provided by the upstream library. For a
hello-world example, define your own:

```swift
import Logging
import ServiceLifecycle

struct ClockService: Service, Sendable {
    let logger: Logger
    func run() async throws {
        let timer = ContinuousClock().timer(every: .seconds(1))
        for try await _ in timer.cancelOnGracefulShutdown() {
            logger.info("tick")
        }
    }
}
```

Declare a key for it on ``Services``, wrapping the `Service` in a
``LifecycleAdapter`` so the graph can manage it:

```swift
extension Services {
    public var clock: ServiceKey<LifecycleAdapter<ClockService>> { "clock" }
}
```

The declaration body is just the key's `id` string —
``ServiceKey`` is `ExpressibleByStringLiteral`, so `"clock"` and
`ServiceKey(id: "clock")` are equivalent. Then return an
``EntryDescriptor`` for it from `services()`:

```swift
extension MyApp {
    static func services() -> [EntryDescriptor] {
        [
            EntryDescriptor(\.clock) { context in
                LifecycleAdapter(ClockService(logger: context.logger))
            }
        ]
    }
}
```

Update the command to declare its dependency:

```swift
struct Serve: PersistentCommand {
    typealias App = MyApp
    var requiredServices: [PartialKeyPath<Services>] { [\.clock] }
}
```

Now `swift run my-app` boots `ClockService` and logs `tick` every
second until you stop it. Only the transitive closure of a
command's `requiredServices` boots — descriptors nothing depends on
stay cold.

Passive values (a client with no run loop, a shared cache) skip
the adapter: register them with `EntryDescriptor`'s `passive:`
initialiser and the graph wraps and unwraps a ``PassiveService``
for you. See <doc:KeyConcepts> for the three registration forms.

## Add a task command

Tasks share the same descriptors but exit when their work is done.
Implement ``TaskCommand`` and supply `execute(with:)` — the
``ServiceContext`` argument resolves services by keypath:

```swift
struct PrintHello: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(
        commandName: "hello",
        abstract: "Print a greeting and exit."
    )

    var requiredServices: [PartialKeyPath<Services>] { [] }

    func execute(with context: ServiceContext) async throws {
        context.logger.info("Hello from \(MyApp.identifier).")
    }
}
```

Then make the root a multi-command parser:

```swift
struct AppCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "my-app",
        subcommands: [Serve.self, PrintHello.self],
        defaultSubcommand: Serve.self
    )
}

@main
struct MyApp: BackplaneApplication {
    typealias RootCommand = AppCommand
    // … as before …
}
```

`swift run my-app hello` runs the task and exits; `swift run
my-app` (or `swift run my-app serve`) runs the persistent service.

## Drive bootstrap from CLI flags

To add `--log-level` and pick a log format, compose the supplied
``LoggingOptions`` and override ``BackplaneCommand/bootstrap(config:environment:)``:

```swift
struct Serve: PersistentCommand {
    typealias App = MyApp
    @OptionGroup var logging: LoggingOptions

    var requiredServices: [PartialKeyPath<Services>] { [\.clock] }

    func bootstrap(config: ConfigReader, environment: Environment) async throws -> BootstrapPlan {
        var plan = BootstrapPlan()
        plan.logLevel = logging.resolvedLogLevel
        plan.logHandlerFactory = logging.format.factory(
            default: BackplaneLogging.cloudRunOrStream.asFactory
        )
        return plan
    }
}
```

`swift run my-app --log-level=debug --log-format=json` now applies
those flags through the ``BootstrapCoordinator`` before any
`Logger` is constructed.

## Next steps

- <doc:KeyConcepts> covers the architecture in more depth.
- <doc:LocalDeployment> walks through a full local-dev workflow.
- <doc:CloudDeployment> shows how the same binary deploys to a
  managed cloud runtime.
- For database access, see the `BackplanePostgres` product
  (`Postgres` trait).
- For OpenTelemetry export, see the `BackplaneOTel` product
  (`OTel` trait).
- For Cloud Logging / Cloud Trace, see the `BackplaneGCP` product
  (`GCP` trait).
