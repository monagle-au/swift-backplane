//
//  BootstrapPlan.swift
//  swift-backplane
//

import Logging
import Metrics
import Instrumentation
import ServiceLifecycle

// MARK: - LifecycleService

/// A pre-built service that should run alongside user services to back a
/// bootstrap (e.g. an OpenTelemetry collector exporter, a metrics scraper, a
/// log shipper).
///
/// Lifecycle services are not registered through ``ServiceRegistry`` because
/// they're not addressed by ``ServiceKey`` — user code doesn't pull them out
/// of ``ServiceValues``. They're started by ``ApplicationRunner`` before the
/// user's required services so that telemetry is flowing as soon as the
/// application's own services come up.
public struct LifecycleService: Sendable {
    public let label: String
    public let mode: ServiceLifecycleMode
    public let service: any Service

    public init(label: String, mode: ServiceLifecycleMode, service: any Service) {
        self.label = label
        self.mode = mode
        self.service = service
    }
}

// MARK: - BootstrapPlan

/// A plan for the global one-shot bootstraps that swift-log, swift-metrics,
/// and swift-distributed-tracing each require.
///
/// Returned from ``BackplaneCommand/bootstrap(config:environment:)`` and
/// applied by ``BootstrapCoordinator`` after CLI parsing and before any
/// `Logger` is constructed. Every field is optional — an empty plan is a
/// valid no-op.
///
/// ## Ordering
///
/// When applied, the coordinator installs subsystems in this order:
///
/// 1. Tracing — `InstrumentationSystem.bootstrap(instrument)`
/// 2. Metrics — `MetricsSystem.bootstrap(metricsFactory)`
/// 3. Logging — `LoggingSystem.bootstrap(logHandlerFactory, metadataProvider:)`
///
/// Logging comes last so that any `Logger.MetadataProvider` you supply can
/// reference task-local context that the tracer set on its first span.
public struct BootstrapPlan: Sendable {
    /// Factory used to build per-label `LogHandler`s. When `nil`, logging is
    /// not bootstrapped by this plan and swift-log's default handler stays
    /// in place.
    public var logHandlerFactory: LogHandlerFactory?

    /// Default level to apply to every handler built by ``logHandlerFactory``.
    /// When `nil`, ``BackplaneLogging/resolveLogLevel(envVar:)`` reads the
    /// `LOG_LEVEL` env var; if that is also unset, `.info` is used.
    public var logLevel: Logger.Level?

    /// Optional cross-cutting metadata provider, attached to every logger
    /// constructed after bootstrap.
    public var loggerMetadataProvider: Logger.MetadataProvider?

    /// Tracer (or any `Instrument`) to install as the process-wide
    /// instrumentation system. When `nil`, swift-distributed-tracing's
    /// `NoOpInstrument` remains in effect.
    public var instrument: (any Instrument)?

    /// Metrics factory to install as the process-wide metrics system. When
    /// `nil`, swift-metrics' default no-op handler remains in effect.
    public var metricsFactory: (any MetricsFactory)?

    /// Pre-built services to start alongside the user's services (e.g. an
    /// OTel collector exporter). These run with ``ApplicationRunner`` ahead
    /// of services from ``ServiceRegistry`` so telemetry flows from the very
    /// first user-service span.
    public var lifecycleServices: [LifecycleService]

    public init(
        logHandlerFactory: LogHandlerFactory? = nil,
        logLevel: Logger.Level? = nil,
        loggerMetadataProvider: Logger.MetadataProvider? = nil,
        instrument: (any Instrument)? = nil,
        metricsFactory: (any MetricsFactory)? = nil,
        lifecycleServices: [LifecycleService] = []
    ) {
        self.logHandlerFactory = logHandlerFactory
        self.logLevel = logLevel
        self.loggerMetadataProvider = loggerMetadataProvider
        self.instrument = instrument
        self.metricsFactory = metricsFactory
        self.lifecycleServices = lifecycleServices
    }

    /// `true` when no field is set — applying it is a no-op.
    public var isEmpty: Bool {
        logHandlerFactory == nil
            && logLevel == nil
            && loggerMetadataProvider == nil
            && instrument == nil
            && metricsFactory == nil
            && lifecycleServices.isEmpty
    }

    /// `true` when at least one logging-related field is set, so the
    /// coordinator should bootstrap `LoggingSystem`.
    public var hasLoggingConfiguration: Bool {
        logHandlerFactory != nil || logLevel != nil || loggerMetadataProvider != nil
    }
}
