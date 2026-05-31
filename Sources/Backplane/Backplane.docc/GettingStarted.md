# Getting Started

Build your first Backplane application — a single binary that runs
either as an HTTP-style persistent service or as a one-shot task.

## Overview

A Backplane app has three ingredients:

1. A type that conforms to ``BackplaneApplication`` and is marked
   `@main`. It declares an `identifier`, registers services, and
   names a `RootCommand`.
2. One or more ``BackplaneCommand`` conformances (typically
   ``PersistentCommand`` or ``TaskCommand``). Each declares the
   ``ServiceKey``s it needs, optionally builds a
   ``BootstrapPlan``, and — for tasks — implements
   `execute(with:)`.
3. A `ServiceRegistry` populated in `configure(_:)` mapping each
   `ServiceKey` to a build closure that returns the service value
   plus its lifecycle service.

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

    static func configure(_ services: inout ServiceRegistry) {
        // No services yet — Serve will run with an empty registry.
    }
}

struct Serve: PersistentCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(
        abstract: "Run the service forever."
    )

    var requiredServices: [any ServiceKey.Type] { [] }
}
```

`swift run my-app` boots the app, parses CLI args, applies the
default (empty) ``BootstrapPlan``, builds an empty service
registry, and runs an empty `ServiceGroup` until the process
receives `SIGINT`/`SIGTERM`. Not very useful yet — but the harness
is fully wired.

## Add a real service

A "service" is anything conforming to
[`ServiceLifecycle.Service`](https://swiftpackageindex.com/swift-server/swift-service-lifecycle/main/documentation/servicelifecycle/service).
For long-lived components (HTTP servers, queue consumers, gRPC
listeners) the conformance is usually provided by the upstream
library. For a hello-world example, define your own:

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

Register it via a ``ServiceKey`` and ``ConcreteServiceEntry``:

```swift
struct ClockServiceKey: ServiceKey {
    static var defaultValue: ClockService? { nil }
}

extension ServiceValues {
    var clock: ClockService? {
        get { self[ClockServiceKey.self] }
        set { self[ClockServiceKey.self] = newValue }
    }
}

extension MyApp {
    static func configure(_ services: inout ServiceRegistry) {
        services.register(ClockServiceKey.self, entry: ConcreteServiceEntry<ClockServiceKey>(
            label: "clock",
            mode: .persistent
        ) { _, _, logger in
            ClockService(logger: logger)
        })
    }
}
```

Update the command to declare its dependency:

```swift
struct Serve: PersistentCommand {
    typealias App = MyApp
    var requiredServices: [any ServiceKey.Type] { [ClockServiceKey.self] }
}
```

Now `swift run my-app` boots `ClockService` and logs `tick` every
second until you stop it.

## Add a task command

Tasks share the same registry but exit when their work is done.
Implement ``TaskCommand`` and supply `execute(with:)`:

```swift
struct PrintHello: TaskCommand {
    typealias App = MyApp
    static let configuration = CommandConfiguration(
        commandName: "hello",
        abstract: "Print a greeting and exit."
    )

    var requiredServices: [any ServiceKey.Type] { [] }

    func execute(with services: ServiceValues) async throws {
        print("Hello from \(MyApp.identifier).")
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

    var requiredServices: [any ServiceKey.Type] { [ClockServiceKey.self] }

    func bootstrap(config: ConfigReader, environment: Environment) -> BootstrapPlan {
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
- For database access, see ``BackplanePostgres``.
- For OpenTelemetry export, see ``BackplaneOTel``.
- For Cloud Logging / Cloud Trace, see ``BackplaneGCP``.
