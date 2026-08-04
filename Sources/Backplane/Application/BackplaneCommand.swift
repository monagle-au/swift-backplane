//
//  BackplaneCommand.swift
//  swift-backplane
//

import ArgumentParser
import Configuration
import Logging
import ServiceContextModule
import ServiceLifecycle

// MARK: - UncheckedSendableBox

/// A minimal wrapper that bridges a non-`Sendable` value into a
/// `@Sendable` closure context.
///
/// Used internally to capture `self` (a `BackplaneCommand`, which is not
/// required to be `Sendable`) inside the `@Sendable` execute closure
/// passed to ``ApplicationRunner``. Safe because the command's
/// `execute(with:)` call happens sequentially on a single task and does
/// not escape to other concurrency domains.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

// MARK: - BackplaneCommand

/// A command within a Backplane application.
///
/// Commands declare which services they need via ``requiredServices``.
/// The framework boots the transitive closure of those services through
/// the application's ``ServiceGraph`` before running the command body.
///
/// For persistent commands (e.g. an HTTP server), conform to
/// ``PersistentCommand`` — the services simply run until the process
/// receives a termination signal.
///
/// For task commands (e.g. a database migration), conform to
/// ``TaskCommand`` which requires ``TaskCommand/execute(with:)`` —
/// when the closure returns, the service group is gracefully shut down.
///
/// ```swift
/// struct Migrate: TaskCommand {
///     typealias App = MyApp
///     static let configuration = CommandConfiguration(abstract: "Run migrations")
///
///     var requiredServices: [PartialKeyPath<Services>] { [\.postgres] }
///
///     func execute(with context: BackplaneContext) async throws {
///         let db = try await context.requireService(\.postgres)
///         try await runMigrations(db)
///     }
/// }
/// ```
public protocol BackplaneCommand: AsyncParsableCommand {
    /// The application type that owns this command and supplies service
    /// descriptors.
    associatedtype App: BackplaneApplication

    /// The service keys whose transitive dependencies will be booted
    /// before the command runs. Declared as keypaths over the
    /// ``Services`` namespace — `\.postgres`, `\.database`, etc.
    var requiredServices: [PartialKeyPath<Services>] { get }

    /// Called after all required services have been built and started.
    ///
    /// The default implementation is a no-op, suitable for
    /// ``PersistentCommand`` conformances where the services themselves
    /// constitute the entire workload.
    ///
    /// Override this in ``TaskCommand`` conformances to perform work
    /// and then allow the service group to shut down.
    ///
    /// - Parameter context: A command-scoped ``BackplaneContext`` carrying
    ///   the application logger and forwarding `service(_:)`
    ///   / `requireService(_:timeout:)` calls to the
    ///   running ``ServiceGraph``.
    func execute(with context: BackplaneContext) async throws

    /// The lifecycle mode for this command.
    ///
    /// Defaults to `.persistent`. ``TaskCommand`` overrides this to
    /// `.task`. Prefer conforming to ``PersistentCommand`` or
    /// ``TaskCommand`` rather than setting this directly.
    var lifecycleMode: ServiceLifecycleMode { get }

    /// Build a ``BootstrapPlan`` from this command's parsed flags, the
    /// application's `ConfigReader`, and the active ``Environment``.
    ///
    /// Called by the default ``run()`` implementation after
    /// ArgumentParser has parsed the command but before any service is
    /// built or any `Logger` is constructed. The returned plan is
    /// applied through ``BootstrapCoordinator/shared`` so the global
    /// one-shots (`InstrumentationSystem.bootstrap`,
    /// `MetricsSystem.bootstrap`, `LoggingSystem.bootstrap`) happen at
    /// the right point in the lifecycle and can be driven by `@Option`
    /// / `@Flag` values on the command.
    ///
    /// The default implementation returns an empty plan, which leaves
    /// the global subsystems on their swift-log / swift-metrics /
    /// swift-distributed-tracing defaults.
    func bootstrap(
        config: ConfigReader,
        environment: Environment
    ) async throws -> BootstrapPlan
}

extension BackplaneCommand {
    /// Default no-op execute — appropriate for persistent commands.
    public func execute(with context: BackplaneContext) async throws {}

    /// Default lifecycle mode — persistent.
    public var lifecycleMode: ServiceLifecycleMode { .persistent }

    /// Default empty bootstrap plan — leaves global subsystems on their
    /// library defaults. Apps that want CLI-flag-driven log levels,
    /// telemetry endpoints, or metadata providers override this method.
    public func bootstrap(
        config: ConfigReader,
        environment: Environment
    ) async throws -> BootstrapPlan {
        BootstrapPlan()
    }

    /// Default `run()` implementation wired into ArgumentParser.
    ///
    /// This implementation:
    /// 1. Reads the active ``Environment`` from the current
    ///    `ServiceContextModule.ServiceContext`, falling back to
    ///    `.development` if not set.
    /// 2. Calls `App.configReader(for:)` to build the `ConfigReader`.
    /// 3. Calls ``bootstrap(config:environment:)`` and applies the
    ///    returned plan via ``BootstrapCoordinator/shared``.
    /// 4. Constructs the application's root `Logger`.
    /// 5. Calls `App.services()` to gather descriptors and builds a
    ///    ``ServiceGraph``.
    /// 6. Creates an `ApplicationRunner` and invokes its `run`,
    ///    passing the plan's ``BootstrapPlan/lifecycleServices`` so
    ///    things like an OTel exporter run alongside graph entries.
    public func run() async throws {
        let environment = ServiceContextModule.ServiceContext.active.environment ?? .development
        let config = try await App.configReader(for: environment)

        let plan = try await bootstrap(config: config, environment: environment)
        BootstrapCoordinator.shared.apply(plan)

        let logger = Logger(label: App.identifier)

        let descriptors = App.services()
        let graph = try ServiceGraph(
            descriptors: descriptors,
            logger: logger,
            config: config
        )

        let runner = ApplicationRunner(
            identifier: App.identifier,
            graph: graph,
            config: config,
            environment: environment,
            logger: logger
        )

        let requiredCopy = requiredServices.map { AnyServiceKey(keyPath: $0) }
        let lifecycleServicesCopy = plan.lifecycleServices

        if lifecycleMode == .task {
            try await _runAsTask(
                runner: runner,
                requiredServices: requiredCopy,
                lifecycleServices: lifecycleServicesCopy
            )
        } else {
            let noExecute: (@Sendable (BackplaneContext) async throws -> Void)? = nil
            try await runner.run(
                requiredServices: requiredCopy,
                mode: .persistent,
                lifecycleServices: lifecycleServicesCopy,
                execute: noExecute
            )
        }
    }

    /// Internal helper that runs this command in task mode.
    private func _runAsTask(
        runner: ApplicationRunner,
        requiredServices: [AnyServiceKey],
        lifecycleServices: [LifecycleService]
    ) async throws {
        let box = UncheckedSendableBox(value: self)
        let executeClosure: @Sendable (BackplaneContext) async throws -> Void = { context in
            try await box.value.execute(with: context)
        }
        try await runner.run(
            requiredServices: requiredServices,
            mode: .task,
            lifecycleServices: lifecycleServices,
            execute: executeClosure
        )
    }
}

// MARK: - PersistentCommand

/// A persistent command whose services run until the application
/// receives a termination signal.
///
/// Use this for long-running workloads such as HTTP servers or message
/// consumers. You do not need to implement
/// ``BackplaneCommand/execute(with:)`` — the default no-op is used.
///
/// ```swift
/// struct Serve: PersistentCommand {
///     typealias App = MyApp
///     static let configuration = CommandConfiguration(abstract: "Start the server")
///     var requiredServices: [PartialKeyPath<Services>] { [\.httpKey] }
/// }
/// ```
public protocol PersistentCommand: BackplaneCommand {}

// MARK: - TaskCommand

/// A task command that performs a finite unit of work and then shuts
/// down.
///
/// Implement ``execute(with:)`` to run your task logic. When the
/// closure returns (or throws), the framework gracefully shuts down all
/// running services.
///
/// ```swift
/// struct Migrate: TaskCommand {
///     typealias App = MyApp
///     static let configuration = CommandConfiguration(abstract: "Run migrations")
///     var requiredServices: [PartialKeyPath<Services>] { [\.postgres] }
///
///     func execute(with context: BackplaneContext) async throws {
///         let db = try await context.requireService(\.postgres)
///         try await PostgresMigrator(client: db).migrate()
///     }
/// }
/// ```
public protocol TaskCommand: BackplaneCommand {
    /// Performs the command's task work.
    ///
    /// Called after all required services have been started. When this
    /// method returns or throws, the service group is gracefully shut
    /// down.
    func execute(with context: BackplaneContext) async throws
}

extension TaskCommand {
    /// Task commands always use `.task` lifecycle mode.
    public var lifecycleMode: ServiceLifecycleMode { .task }
}
