//
//  BootstrapCoordinator.swift
//  swift-backplane
//

import Logging
import Metrics
import Instrumentation
import Synchronization

// MARK: - BootstrapCoordinator

/// Process-wide one-shot guard for the global bootstraps.
///
/// `LoggingSystem.bootstrap`, `MetricsSystem.bootstrap`, and
/// `InstrumentationSystem.bootstrap` are each callable exactly once per
/// process. `BootstrapCoordinator` wraps that constraint behind a single
/// idempotent ``apply(_:)`` so multi-subcommand applications (where every
/// subcommand may build its own ``BootstrapPlan``) can call it without fear
/// of double-bootstrap.
///
/// ## Behaviour
///
/// - Each subsystem is bootstrapped at most once. ``apply(_:)`` is
///   idempotent per subsystem: a second plan that sets a field already
///   installed by an earlier plan silently no-ops that field. This lets
///   apps split bootstrap into multiple calls (e.g. tracing first, then
///   logging) and lets multiple subcommands each call ``apply(_:)``
///   without coordination.
/// - Each subsystem is bootstrapped only if its corresponding field is
///   set. A plan that supplies only a tracer leaves logging and metrics
///   on their swift-log / swift-metrics defaults.
/// - Empty plans are always no-ops.
///
/// ## Ordering
///
/// Subsystems install in this order so logging metadata providers can read
/// trace context populated by the tracer on the first span:
///
/// 1. `InstrumentationSystem.bootstrap(plan.instrument)`
/// 2. `MetricsSystem.bootstrap(plan.metricsFactory)`
/// 3. `LoggingSystem.bootstrap(plan.logHandlerFactory, metadataProvider:)`
///
/// ## Interaction with the static escape-hatch methods
///
/// ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``
/// and ``BackplaneApplication/bootstrapTracing(using:)`` route through this
/// coordinator so that an app calling them in an overridden `main()` is
/// observed as "already bootstrapped" by the in-`run()` flow. Either path
/// works; the coordinator just enforces single-application semantics.
public final class BootstrapCoordinator: Sendable {

    /// Process-wide instance used by ``BackplaneCommand/run()`` and the
    /// static escape-hatch methods on ``BackplaneApplication``. Tests should
    /// construct their own instance via ``init(installInstrument:installMetrics:installLogging:)``
    /// to avoid mutating the global subsystems (which would crash on the
    /// second test that tries to bootstrap).
    public static let shared = BootstrapCoordinator()

    /// Hook called when a tracer should be installed. Default routes to
    /// `InstrumentationSystem.bootstrap`.
    private let installInstrument: @Sendable (any Instrument) -> Void

    /// Hook called when a metrics factory should be installed. Default
    /// routes to `MetricsSystem.bootstrap`.
    private let installMetrics: @Sendable (any MetricsFactory) -> Void

    /// Hook called when a logging factory should be installed. The factory
    /// is passed pre-leveled — ``apply(_:)`` resolves the level (explicit
    /// > env > `.info`) and wraps the caller-supplied factory before
    /// invoking the hook. Default routes to `LoggingSystem.bootstrap` (with
    /// or without a metadata provider depending on whether one is supplied).
    private let installLogging: @Sendable (@escaping LogHandlerFactory, Logger.Level, Logger.MetadataProvider?) -> Void

    private let state: Mutex<State>

    private struct State: Sendable {
        var loggingBootstrapped = false
        var metricsBootstrapped = false
        var tracingBootstrapped = false
    }

    public init(
        installInstrument: @escaping @Sendable (any Instrument) -> Void = { instrument in
            InstrumentationSystem.bootstrap(instrument)
        },
        installMetrics: @escaping @Sendable (any MetricsFactory) -> Void = { factory in
            MetricsSystem.bootstrap(factory)
        },
        installLogging: @escaping @Sendable (@escaping LogHandlerFactory, Logger.Level, Logger.MetadataProvider?) -> Void = { factory, level, provider in
            // Wrap the caller-supplied factory so every handler gets the
            // resolved level applied at construction. `LogHandler.logLevel`
            // is `var` on the protocol — assignment after init is the
            // documented swift-log path for level overrides.
            let leveledFactory: LogHandlerFactory = { label in
                var handler = factory(label)
                handler.logLevel = level
                return handler
            }
            if let provider {
                LoggingSystem.bootstrap(
                    { label, _ in leveledFactory(label) },
                    metadataProvider: provider
                )
            } else {
                LoggingSystem.bootstrap(leveledFactory)
            }
        }
    ) {
        self.installInstrument = installInstrument
        self.installMetrics = installMetrics
        self.installLogging = installLogging
        self.state = Mutex(.init())
    }

    // MARK: - apply

    /// Apply a ``BootstrapPlan``. Safe to call multiple times — only the
    /// first non-empty apply per coordinator instance has an effect.
    public func apply(_ plan: BootstrapPlan) {
        // Phase 1 — under the lock, decide which subsystems we'll install.
        // We don't call into LoggingSystem/MetricsSystem/InstrumentationSystem
        // while holding our lock; those have their own internal locking and
        // we don't want to nest.
        let (installTracing, installMetricsFlag, installLoggingFlag) = state.withLock { state -> (Bool, Bool, Bool) in
            if plan.isEmpty {
                return (false, false, false)
            }

            let tracing = plan.instrument != nil && !state.tracingBootstrapped
            let metrics = plan.metricsFactory != nil && !state.metricsBootstrapped
            let logging = plan.hasLoggingConfiguration && !state.loggingBootstrapped

            if tracing { state.tracingBootstrapped = true }
            if metrics { state.metricsBootstrapped = true }
            if logging { state.loggingBootstrapped = true }

            return (tracing, metrics, logging)
        }

        // Phase 2 — outside the lock, perform the actual one-shot bootstraps
        // in the documented order.
        if installTracing, let instrument = plan.instrument {
            self.installInstrument(instrument)
        }
        if installMetricsFlag, let factory = plan.metricsFactory {
            self.installMetrics(factory)
        }
        if installLoggingFlag {
            let resolvedLevel = plan.logLevel
                ?? BackplaneLogging.resolveLogLevel()
                ?? .info
            let factory = plan.logHandlerFactory
                ?? BackplaneLogging.cloudRunOrStream.asFactory
            self.installLogging(factory, resolvedLevel, plan.loggerMetadataProvider)
        }
    }

    // MARK: - State queries (used by the static escape-hatch methods)

    /// `true` when the logging system has been bootstrapped through this
    /// coordinator. Read by the static
    /// ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``
    /// to skip a duplicate `LoggingSystem.bootstrap` call.
    public var hasBootstrappedLogging: Bool {
        state.withLock { $0.loggingBootstrapped }
    }

    /// `true` when the metrics system has been bootstrapped through this
    /// coordinator.
    public var hasBootstrappedMetrics: Bool {
        state.withLock { $0.metricsBootstrapped }
    }

    /// `true` when the instrumentation system has been bootstrapped through
    /// this coordinator.
    public var hasBootstrappedTracing: Bool {
        state.withLock { $0.tracingBootstrapped }
    }

    // MARK: - Static escape-hatch markers

    /// Mark the logging subsystem as already bootstrapped without going
    /// through ``apply(_:)``. Used by
    /// ``BackplaneApplication/bootstrapLogging(using:metadataProvider:logLevel:)``
    /// when an app installs logging via the static method before
    /// ``BackplaneCommand/run()`` runs.
    public func markLoggingBootstrapped() {
        state.withLock { $0.loggingBootstrapped = true }
    }

    /// Mark the metrics subsystem as already bootstrapped without going
    /// through ``apply(_:)``.
    public func markMetricsBootstrapped() {
        state.withLock { $0.metricsBootstrapped = true }
    }

    /// Mark the instrumentation subsystem as already bootstrapped without
    /// going through ``apply(_:)``. Used by
    /// ``BackplaneApplication/bootstrapTracing(using:)`` when an app
    /// installs a tracer via the static method before
    /// ``BackplaneCommand/run()`` runs.
    public func markTracingBootstrapped() {
        state.withLock { $0.tracingBootstrapped = true }
    }
}
