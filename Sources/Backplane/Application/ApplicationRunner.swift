//
//  ApplicationRunner.swift
//  swift-backplane
//

import Configuration
import Logging
import ServiceLifecycle

/// Internal orchestrator that boots a ``ServiceGraph`` and drives the
/// outer `ServiceGroup`.
///
/// You do not normally interact with `ApplicationRunner` directly. It is
/// created and used by the default ``BackplaneCommand/run()``
/// implementation.
struct ApplicationRunner: Sendable {
    /// The application identifier (used in logging and tracing).
    let identifier: String

    /// The pre-constructed service graph.
    let graph: ServiceGraph

    /// Application configuration reader.
    let config: ConfigReader

    /// The active deployment environment.
    let environment: Environment

    /// Root logger for the application.
    let logger: Logger

    /// Boot the required subset of the graph and run the outer
    /// `ServiceGroup` containing the graph plus any bootstrap lifecycle
    /// services.
    ///
    /// - Parameters:
    ///   - requiredServices: The keys whose transitive dependencies
    ///     should be booted. Pass the keys declared by the active
    ///     command. An empty array boots every registered entry.
    ///   - mode: Whether the invocation is a persistent or task run.
    ///   - lifecycleServices: Pre-built services from the active
    ///     ``BootstrapPlan`` (e.g. an OTel exporter). They start
    ///     alongside the graph so telemetry is flowing as entries come
    ///     up.
    ///   - execute: An optional async closure to wrap in a
    ///     ``CommandExecutionService`` (task mode only). Pass `nil` for
    ///     persistent commands.
    func run(
        requiredServices: [AnyServiceKey],
        mode: ServiceLifecycleMode = .persistent,
        lifecycleServices: [LifecycleService] = [],
        execute: (@Sendable (BackplaneContext) async throws -> Void)? = nil
    ) async throws {
        // Configure the graph's boot roots so its `run()` boots only
        // the transitive closure of `requiredServices`. Don't drive
        // `graph.boot(roots:)` explicitly here — graph.run() (invoked
        // as a member of the outer ServiceGroup below) does the boot,
        // and double-booting is undefined.
        let roots: [AnyServiceKey]? = requiredServices.isEmpty ? nil : requiredServices
        await graph.setBootRoots(roots)

        var serviceConfigs: [ServiceGroupConfiguration.ServiceConfiguration] = []

        // Bootstrap lifecycle services first so exporters/shippers are
        // active before the graph's entries come up under the inner group.
        for ls in lifecycleServices {
            var cfg = ServiceGroupConfiguration.ServiceConfiguration(service: ls.service)
            if ls.mode == .task {
                cfg.successTerminationBehavior = .gracefullyShutdownGroup
            }
            serviceConfigs.append(cfg)
        }

        // The graph itself is a `ServiceLifecycle.Service`. Its `run()`
        // supervises the per-entry adapters inside an inner group.
        serviceConfigs.append(
            ServiceGroupConfiguration.ServiceConfiguration(service: graph)
        )

        // If a task execute closure was provided, wrap it in a
        // `CommandExecutionService` and append. Its success termination
        // gracefully shuts the outer group down.
        if let execute {
            let context = makeCommandContext()
            let executionService = CommandExecutionService {
                try await execute(context)
            }
            var cfg = ServiceGroupConfiguration.ServiceConfiguration(service: executionService)
            cfg.successTerminationBehavior = .gracefullyShutdownGroup
            serviceConfigs.append(cfg)
        }

        let groupConfig = ServiceGroupConfiguration(
            services: serviceConfigs,
            logger: logger
        )
        try await ServiceGroup(configuration: groupConfig).run()
    }

    /// Construct a command-scoped ``BackplaneContext`` for passing to a
    /// task command's `execute(with:)`. The lifecycle/health surfaces
    /// are no-ops — a command is not an entry in the graph; the only
    /// meaningful operations are `service(_:)` / `requireService(_:)`
    /// forwarded to the graph.
    private func makeCommandContext() -> BackplaneContext {
        BackplaneContext(
            entryID: "command:\(identifier)",
            logger: logger,
            lifecycle: CommandLifecycleHandle(),
            health: CommandHealthReporter(),
            config: config,
            graph: graph
        )
    }
}

// MARK: - Command-scoped no-op handles

/// Lifecycle handle used for the command-scoped ``BackplaneContext``. The
/// command isn't an entry in the graph; this handle reports `.running`
/// and ignores restart requests.
private struct CommandLifecycleHandle: ServiceLifecycleHandle {
    var state: ServiceState { .running }

    func stateStream() -> AsyncStream<ServiceState> {
        AsyncStream { continuation in
            continuation.yield(.running)
            continuation.finish()
        }
    }

    func requestRestart() async {
        // No-op: commands have no replacement strategy.
    }
}

/// Health reporter used for the command-scoped ``BackplaneContext``. The
/// command isn't an entry in the graph; nothing observes its health.
private struct CommandHealthReporter: ServiceHealthReporter {
    nonisolated func markDegraded(fault: ServiceFault) {
        // No-op: nothing observes command-scoped degradation.
    }

    nonisolated func markHealthy() {
        // No-op.
    }
}
